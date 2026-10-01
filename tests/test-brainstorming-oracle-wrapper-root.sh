#!/usr/bin/env bash
# Regression tests for #885 — brainstorming's Step 5.6 oracle wrapper resolution and
# prompt-file transport. Case numbers track the design doc's Tests table verbatim.
#
# The fences under test are EXECUTED here, not just read: each ```bash block is extracted
# from the live SKILL.md by needle and run verbatim (or with the one textual substitution a
# case calls for) under bash — and under zsh where the table says so — against stub
# wrappers in a fake HOME. The stubs never touch the real oracle: they print `enabled` for
# --surface-check, `ok-<label>` for a consult, and append `<label> <args>` to an invocation
# log outside the state dir so each case proves WHICH root resolved.
#
# Resolution order pinned by the exec cases: BUSDRIVER_PLUGIN_ROOT override > a
# substituted/exported plugin root > newest pure X.Y.Z cache dir. Fail-closed cases pin
# the diagnostics: an explicit override that lacks the wrapper never falls back to the
# cache, and a failed pick leaves R at the cache root so the named path is complete.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL_MD="$ROOT/skills/brainstorming/SKILL.md"
WPLANS_MD="$ROOT/skills/writing-plans/SKILL.md"
CLASSIFIER="$ROOT/hooks/gate-scripts/lib/marker_check.py"
LIBDIR="$ROOT/hooks/gate-scripts/lib"
PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
no() { FAIL=$((FAIL + 1)); printf '  FAIL  %s :: %s\n' "$1" "${2:-}"; }
skip() { printf '  skip  %s\n' "$1"; }

ZSH="$(command -v zsh || true)"
_tmp="$(mktemp -d)" || exit 1
[[ -n "$_tmp" && -d "$_tmp" ]] || exit 1
WORK="$(cd "$_tmp" && pwd -P)" || exit 1   # physical path: git rev-parse reports one
trap 'rm -rf "$WORK"' EXIT

# #821 convention (see tests/test-ultra-oracle.sh): absent zsh is a skip locally but a
# coverage-regression FAIL under GITHUB_ACTIONS=true, where CI installs it.
have_zsh() { # <case label> -> 0 iff zsh is runnable; otherwise records skip/FAIL
    if [[ -n "$ZSH" ]]; then return 0; fi
    if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
        no "$1" "zsh not installed in CI — zsh row would silently skip (#821)"
    else
        skip "$1 (zsh not installed)"
    fi
    return 1
}

# ── Extraction (design "Extraction" block) ────────────────────────────────────
SEC="$(awk '/^## Step 5\.6/ {f=1; next} f && /^## / {exit} f' "$SKILL_MD")"
FENCES=()
_buf=""
while IFS= read -r _line; do
    if [[ "$_line" == '@@FENCE@@' ]]; then
        FENCES+=("$_buf")
        _buf=""
    else
        _buf+="$_line"$'\n'
    fi
done < <(printf '%s\n' "$SEC" | awk '
    /^```bash$/ {inb=1; buf=""; next}
    inb && /^```$/ {inb=0; print buf; print "@@FENCE@@"; next}
    inb {buf = buf $0 "\n"}')

PREP=""
CONS_A=""
CONS_B=""
for _f in "${FENCES[@]}"; do
    if [[ "$_f" == *'--surface-check'* ]]; then
        PREP="$_f"
    elif [[ "$_f" == *'--surface brainstorming --mode'* ]]; then
        CONS_B="$_f"
    elif [[ "$_f" == *'--prompt-file'* ]]; then
        CONS_A="$_f"
    fi
done
if [[ ${#FENCES[@]} -eq 3 && -n "$PREP" && -n "$CONS_A" && -n "$CONS_B" ]]; then
    ok "extract: exactly 3 bash fences, identified by needle (prepare/consult-A/consult-B)"
else
    no "extract: exactly 3 bash fences, identified by needle" \
        "fences=${#FENCES[@]} prep=${#PREP} consA=${#CONS_A} consB=${#CONS_B}"
    printf '%s PASS, %s FAIL — extraction failed, aborting exec cases\n' "$PASS" "$FAIL"
    exit 1
fi

# ── Harness helpers ───────────────────────────────────────────────────────────
mkstub() { # <plugin root> <label> <invocation log>
    mkdir -p "$1/scripts"
    cat > "$1/scripts/ultra-oracle-consult-run.sh" <<EOF
#!/usr/bin/env bash
echo "$2 \$*" >> "$3"
if [[ "\${1:-}" == "--surface-check" ]]; then
    echo enabled
else
    echo "ok-$2"
fi
exit 0
EOF
}

# Case-14 stub: sleeps 2s and records whether the prompt file exists DURING the call.
mksleepstub() { # <plugin root> <label> <invocation log> <existence record>
    mkdir -p "$1/scripts"
    cat > "$1/scripts/ultra-oracle-consult-run.sh" <<EOF
#!/usr/bin/env bash
echo "$2 \$*" >> "$3"
if [[ "\${1:-}" == "--surface-check" ]]; then
    echo enabled
    exit 0
fi
pfarg=""
while [[ \$# -gt 0 ]]; do
    if [[ "\$1" == "--prompt-file" ]]; then
        pfarg="\$2"
        shift 2
    else
        shift
    fi
done
sleep 2
[[ -e "\$pfarg" ]] && echo existed >> "$4"
echo "ok-$2"
exit 0
EOF
}

# mkcache <casedir> <entries...> — VER@LABEL installs a stub at that versioned root;
# bare VER makes a wrapper-less directory.
mkcache() {
    local casedir=$1; shift
    local cache="$casedir/home/.claude/plugins/cache/busdriver/busdriver"
    local entry ver label
    for entry in "$@"; do
        ver=${entry%%@*}
        label=${entry#*@}
        if [[ "$label" == "$entry" ]]; then
            mkdir -p "$cache/$ver"
        else
            mkstub "$cache/$ver" "$label" "$casedir/invocations.log"
        fi
    done
}

newcase() { # <name> -> fresh casedir with a git repo at <casedir>/repo
    local d="$WORK/$1"
    mkdir -p "$d/repo"
    git init -q "$d/repo"
    printf '%s' "$d"
}

fence_body() { case $1 in prep) printf '%s' "$PREP";; a) printf '%s' "$CONS_A";; b) printf '%s' "$CONS_B";; esac; }

# run_body <shell> <body> <casedir> <rundir> [preamble lines...]
# Command file = unset of all three env vars + preamble lines + the (verbatim or
# case-substituted) fence, run in <rundir> with a fake HOME under <casedir>.
run_body() {
    local shell=$1 body=$2 casedir=$3 rundir=$4; shift 4
    local e
    {
        printf 'unset CLAUDE_PLUGIN_ROOT BUSDRIVER_PLUGIN_ROOT BUSDRIVER_STATE_DIR\n'
        for e in "$@"; do printf '%s\n' "$e"; done
        printf '%s' "$body"
    } > "$casedir/cmd"
    mkdir -p "$casedir/home" "$rundir"
    (cd "$rundir" && HOME="$casedir/home" "$shell" "$casedir/cmd" \
        > "$casedir/out" 2> "$casedir/err")
}

run_fence() { # <shell> <prep|a|b> <casedir> <rundir> [preamble lines...]
    local shell=$1 which=$2 casedir=$3 rundir=$4; shift 4
    run_body "$shell" "$(fence_body "$which")" "$casedir" "$rundir" "$@"
}

wire_prompt_at() { # <absolute prompt path> — what the model's Write tool does
    mkdir -p "${1%/*}"
    printf 'Critique this approved design adversarially.\n\nplaceholder body\n' > "$1"
}
wire_prompt() { wire_prompt_at "$1/.claude/ultra-oracle/critique-prompt.txt"; } # <git rundir>
pf_of() { grep '^pf=' "$1/out" | cut -d= -f2-; } # <casedir> -> printed prompt path

DIAG='ultra-oracle wrapper not found:'

# ── Case 1: cache dirs 2.2.3 / 2.2.10 / 2.3.0-rc1 / current, all with stubs ────
cd1=$(newcase c1)
mkcache "$cd1" '2.2.3@2.2.3' '2.2.10@2.2.10' '2.3.0-rc1@2.3.0-rc1' 'current@current'
run_fence bash prep "$cd1" "$cd1/repo"
_rc1=$?
wire_prompt "$cd1/repo"
run_fence bash a "$cd1" "$cd1/repo"
_rcA=$?
wire_prompt "$cd1/repo"          # consult A's trap deleted it
run_fence bash b "$cd1" "$cd1/repo"
_rcB=$?
if [[ $_rc1 -eq 0 && $_rcA -eq 0 && $_rcB -eq 0 ]] \
    && [[ "$(wc -l < "$cd1/invocations.log" | tr -d ' ')" -eq 3 ]] \
    && ! grep -vq '^2\.2\.10 ' "$cd1/invocations.log" \
    && grep -q '^oracle_status=ok-2.2.10$' "$cd1/out"; then
    ok "1: all three fences pick newest X.Y.Z (2.2.10); consult A prints oracle_status=ok-2.2.10"
else
    no "1: newest-version pick across fences" \
        "rc=$_rc1/$_rcA/$_rcB log=$(tr '\n' '|' < "$cd1/invocations.log" 2>/dev/null) out=$(cat "$cd1/out")"
fi

# ── Case 2: textual substitution of the bare token (simulates Claude inlining) ─
cd2=$(newcase c2)
mkcache "$cd2" '2.3.0@newer-cache'
mkstub "$cd2/claude-root" claude-root "$cd2/invocations.log"
MOD2=${PREP//'${CLAUDE_PLUGIN_ROOT}'/"$cd2/claude-root"}
run_body bash "$MOD2" "$cd2" "$cd2/repo"   # both env vars unset by the harness
_rc=$?
if [[ $_rc -eq 0 ]] && grep -q '^claude-root --surface-check brainstorming$' "$cd2/invocations.log" \
    && ! grep -q 'newer-cache' "$cd2/invocations.log"; then
    ok "2: textually inlined root wins over a newer cache dir"
else
    no "2: inlined root" "rc=$_rc log=$(cat "$cd2/invocations.log" 2>/dev/null) err=$(cat "$cd2/err")"
fi

# ── Case 3: BUSDRIVER_PLUGIN_ROOT beats an inlined root AND the cache ──────────
cd3=$(newcase c3)
mkcache "$cd3" '2.3.0@newer-cache'
mkstub "$cd3/claude-root" claude-root "$cd3/invocations.log"
mkstub "$cd3/override-root" override-root "$cd3/invocations.log"
MOD3=${PREP//'${CLAUDE_PLUGIN_ROOT}'/"$cd3/claude-root"}
run_body bash "$MOD3" "$cd3" "$cd3/repo" \
    "export BUSDRIVER_PLUGIN_ROOT='$cd3/override-root'"
_rc=$?
if [[ $_rc -eq 0 ]] && grep -q '^override-root --surface-check brainstorming$' "$cd3/invocations.log" \
    && ! grep -qE 'claude-root|newer-cache' "$cd3/invocations.log"; then
    ok "3: explicit BUSDRIVER_PLUGIN_ROOT wins over inlined root and cache"
else
    no "3: override precedence" "rc=$_rc log=$(cat "$cd3/invocations.log" 2>/dev/null) err=$(cat "$cd3/err")"
fi

# ── Case 4: exported CLAUDE_PLUGIN_ROOT wins (token NOT replaced) ───────────────
cd4=$(newcase c4)
mkcache "$cd4" '2.3.0@newer-cache'
mkstub "$cd4/env-root" env-root "$cd4/invocations.log"
run_fence bash prep "$cd4" "$cd4/repo" \
    "export CLAUDE_PLUGIN_ROOT='$cd4/env-root'"
_rc=$?
if [[ $_rc -eq 0 ]] && grep -q '^env-root --surface-check brainstorming$' "$cd4/invocations.log" \
    && ! grep -q 'newer-cache' "$cd4/invocations.log"; then
    ok "4: exported CLAUDE_PLUGIN_ROOT wins over the cache"
else
    no "4: exported env root" "rc=$_rc log=$(cat "$cd4/invocations.log" 2>/dev/null) err=$(cat "$cd4/err")"
fi

# ── Case 5: override root without the wrapper, valid cache — no fallback ───────
cd5=$(newcase c5)
mkcache "$cd5" '9.9.9@valid-cache'
mkdir -p "$cd5/empty-root"
run_fence bash b "$cd5" "$cd5/repo" \
    "export BUSDRIVER_PLUGIN_ROOT='$cd5/empty-root'"
_rc=$?
if [[ $_rc -ne 0 ]] \
    && grep -qF "$DIAG $cd5/empty-root/scripts/ultra-oracle-consult-run.sh" "$cd5/err" \
    && [[ ! -e "$cd5/invocations.log" ]] \
    && ! grep -q 'oracle_status=' "$cd5/out"; then
    ok "5: wrapper-less override fails closed, valid cache never consulted"
else
    no "5: override fail-closed" "rc=$_rc err=$(cat "$cd5/err") out=$(cat "$cd5/out")"
fi

# ── Case 6: newest cache dir has no scripts/ — full missing path named ─────────
cd6=$(newcase c6)
mkcache "$cd6" '2.2.10@2.2.10' '2.3.0'    # 2.3.0 wins the pick but has no wrapper
run_fence bash b "$cd6" "$cd6/repo"
_rc=$?
if [[ $_rc -ne 0 ]] \
    && grep -qF "$DIAG $cd6/home/.claude/plugins/cache/busdriver/busdriver/2.3.0/scripts/ultra-oracle-consult-run.sh" "$cd6/err" \
    && [[ ! -e "$cd6/invocations.log" ]]; then
    ok "6: newest cache dir without scripts/ -> diagnostic names the full missing path"
else
    no "6: wrapper-less newest dir" "rc=$_rc err=$(cat "$cd6/err")"
fi

# ── Case 7: no cache dir; and separately only 2.3.0-rc1 + current ──────────────
cd7a=$(newcase c7a)
mkdir -p "$cd7a/home"
run_fence bash b "$cd7a" "$cd7a/repo"
_rc=$?
if [[ $_rc -ne 0 ]] \
    && grep -qF "$DIAG $cd7a/home/.claude/plugins/cache/busdriver/busdriver/scripts/ultra-oracle-consult-run.sh" "$cd7a/err" \
    && [[ ! -e "$cd7a/invocations.log" ]]; then
    ok "7a: no cache dir -> diagnostic names the cache-root wrapper path (never /scripts/...)"
else
    no "7a: no cache" "rc=$_rc err=$(cat "$cd7a/err")"
fi
cd7b=$(newcase c7b)
mkcache "$cd7b" '2.3.0-rc1' 'current'
run_fence bash b "$cd7b" "$cd7b/repo"
_rc=$?
if [[ $_rc -ne 0 ]] \
    && grep -qF "$DIAG $cd7b/home/.claude/plugins/cache/busdriver/busdriver/scripts/ultra-oracle-consult-run.sh" "$cd7b/err" \
    && [[ ! -e "$cd7b/invocations.log" ]]; then
    ok "7b: prerelease/current-only cache -> same named-path diagnostic"
else
    no "7b: prerelease-only cache" "rc=$_rc err=$(cat "$cd7b/err")"
fi

# ── Case 8: symlinked cache dir AND symlinked version dir ──────────────────────
cd8a=$(newcase c8a)
mkdir -p "$cd8a/realcache"
mkstub "$cd8a/realcache/2.2.10" sym-cache "$cd8a/invocations.log"
mkdir -p "$cd8a/home/.claude/plugins/cache/busdriver"
ln -s "$cd8a/realcache" "$cd8a/home/.claude/plugins/cache/busdriver/busdriver"
run_fence bash prep "$cd8a" "$cd8a/repo"
_rc=$?
if [[ $_rc -eq 0 ]] && grep -q '^sym-cache --surface-check brainstorming$' "$cd8a/invocations.log"; then
    ok "8a: symlinked cache dir resolves through the link"
else
    no "8a: symlinked cache" "rc=$_rc err=$(cat "$cd8a/err")"
fi
cd8b=$(newcase c8b)
mkcache "$cd8b" '2.2.3'
mkstub "$cd8b/realroot" sym-version "$cd8b/invocations.log"
ln -s "$cd8b/realroot" "$cd8b/home/.claude/plugins/cache/busdriver/busdriver/2.2.10"
run_fence bash prep "$cd8b" "$cd8b/repo"
_rc=$?
if [[ $_rc -eq 0 ]] && grep -q '^sym-version --surface-check brainstorming$' "$cd8b/invocations.log"; then
    ok "8b: symlinked version dir wins the pick and resolves"
else
    no "8b: symlinked version dir" "rc=$_rc err=$(cat "$cd8b/err")"
fi

# ── Case 9: consult A and B, pre-written PF, case-6 setup → PF gone, log empty ──
for _w in a b; do
    cd9=$(newcase "c9$_w")
    mkcache "$cd9" '2.2.10@2.2.10' '2.3.0'
    wire_prompt "$cd9/repo"
    run_fence bash "$_w" "$cd9" "$cd9/repo"
    _rc=$?
    if [[ $_rc -ne 0 ]] \
        && [[ ! -e "$cd9/repo/.claude/ultra-oracle/critique-prompt.txt" ]] \
        && [[ ! -e "$cd9/invocations.log" ]] \
        && grep -qF "$DIAG $cd9/home/.claude/plugins/cache/busdriver/busdriver/2.3.0/scripts/ultra-oracle-consult-run.sh" "$cd9/err"; then
        ok "9$_w: resolver failure still removes the written prompt (trap precedes resolver)"
    else
        no "9$_w: trap on resolver failure" \
            "rc=$_rc pf-left=$([[ -e "$cd9/repo/.claude/ultra-oracle/critique-prompt.txt" ]] && echo yes || echo no) err=$(cat "$cd9/err")"
    fi
done

# ── Case 10: missing PF and zero-byte PF, consult A and B ──────────────────────
for _w in a b; do
    for _kind in missing zero; do
        cd10=$(newcase "c10${_w}${_kind}")
        mkcache "$cd10" '2.2.10@2.2.10'
        if [[ "$_kind" == zero ]]; then
            mkdir -p "$cd10/repo/.claude/ultra-oracle"
            : > "$cd10/repo/.claude/ultra-oracle/critique-prompt.txt"
        fi
        run_fence bash "$_w" "$cd10" "$cd10/repo"
        _rc=$?
        if [[ $_rc -ne 0 ]] \
            && grep -qF "prompt file missing or empty: $cd10/repo/.claude/ultra-oracle/critique-prompt.txt" "$cd10/err" \
            && [[ ! -e "$cd10/invocations.log" ]]; then
            ok "10-$_w-$_kind: consult $_w fails closed on a $_kind prompt file"
        else
            no "10-$_w-$_kind: prompt fail-closed" "rc=$_rc err=$(cat "$cd10/err")"
        fi
    done
done

# ── Case 11: end-to-end — prepare prints pf/surface, consult B runs, PF gone ───
cd11=$(newcase c11)
mkcache "$cd11" '2.2.10@2.2.10'
run_fence bash prep "$cd11" "$cd11/repo"
_pf=$(pf_of "$cd11")
_surface=$(grep '^surface=' "$cd11/out")   # the next run overwrites out/
wire_prompt_at "$_pf"
run_fence bash b "$cd11" "$cd11/repo"
_rc=$?
if [[ $_rc -eq 0 ]] \
    && [[ "$_pf" == "$cd11/repo/.claude/ultra-oracle/critique-prompt.txt" ]] \
    && [[ "$_surface" == 'surface=enabled' ]] \
    && grep -q '^2\.2\.10 --surface brainstorming --mode blocking' "$cd11/invocations.log" \
    && grep -q '^oracle_status=ok-2.2.10$' "$cd11/out" \
    && [[ ! -e "$_pf" ]]; then
    ok "11: prepare -> Write at printed pf -> consult B: status printed, prompt gone"
else
    no "11: end-to-end" "rc=$_rc pf=$_pf out=$(cat "$cd11/out") log=$(cat "$cd11/invocations.log" 2>/dev/null)"
fi

# ── Case 12: path agreement, three variants ────────────────────────────────────
# 12a: prepare at repo root, consult from a SUBDIRECTORY
cd12a=$(newcase c12a)
mkcache "$cd12a" '2.2.10@2.2.10'
run_fence bash prep "$cd12a" "$cd12a/repo"
_pf=$(pf_of "$cd12a")
wire_prompt_at "$_pf"
mkdir -p "$cd12a/repo/sub/dir"
run_fence bash b "$cd12a" "$cd12a/repo/sub/dir"
_rc=$?
if [[ $_rc -eq 0 ]] && [[ "$_pf" != *'//'* ]] \
    && grep -q '^oracle_status=ok-2.2.10$' "$cd12a/out" \
    && grep -qF "out=${_pf%/*}/design-critique.md" "$cd12a/out" \
    && [[ ! -e "$_pf" ]]; then
    ok "12a: consult from a repo subdirectory reads the same absolute pf (out= is its sibling)"
else
    no "12a: subdir path agreement" "rc=$_rc pf=$_pf out=$(cat "$cd12a/out") err=$(cat "$cd12a/err")"
fi
# 12b: absolute BUSDRIVER_STATE_DIR
cd12b=$(newcase c12b)
mkcache "$cd12b" '2.2.10@2.2.10'
run_fence bash prep "$cd12b" "$cd12b/repo" \
    "export BUSDRIVER_STATE_DIR='$cd12b/abs-state'"
_pf=$(pf_of "$cd12b")
wire_prompt_at "$_pf"
run_fence bash b "$cd12b" "$cd12b/repo" \
    "export BUSDRIVER_STATE_DIR='$cd12b/abs-state'"
_rc=$?
if [[ $_rc -eq 0 ]] && [[ "$_pf" == "$cd12b/abs-state/ultra-oracle/critique-prompt.txt" ]] \
    && grep -q '^oracle_status=ok-2.2.10$' "$cd12b/out" \
    && grep -qF "out=${_pf%/*}/design-critique.md" "$cd12b/out" \
    && [[ ! -e "$_pf" ]]; then
    ok "12b: absolute BUSDRIVER_STATE_DIR used verbatim by prepare and consult"
else
    no "12b: absolute state dir" "rc=$_rc pf=$_pf out=$(cat "$cd12b/out") err=$(cat "$cd12b/err")"
fi
# 12c: outside any git repo — prepare and consult from TWO DIFFERENT non-repo cwds
cd12c=$(newcase c12c)
mkcache "$cd12c" '2.2.10@2.2.10'
rm -rf "$cd12c/repo"   # no repo anywhere in this case's tree
mkdir -p "$cd12c/d1" "$cd12c/d2"
run_fence bash prep "$cd12c" "$cd12c/d1"
_pf=$(pf_of "$cd12c")
wire_prompt_at "$_pf"
run_fence bash b "$cd12c" "$cd12c/d2"
_rc=$?
if [[ $_rc -eq 0 ]] \
    && [[ "$_pf" == "$cd12c/home/.claude/ultra-oracle/critique-prompt.txt" && "$_pf" != *'//'* ]] \
    && grep -q '^oracle_status=ok-2.2.10$' "$cd12c/out" \
    && grep -qF "out=${_pf%/*}/design-critique.md" "$cd12c/out" \
    && [[ ! -e "$_pf" ]]; then
    ok "12c: non-repo cwds agree on \$HOME/.claude path across two different directories"
else
    no "12c: HOME-anchored agreement" "rc=$_rc pf=$_pf out=$(cat "$cd12c/out") err=$(cat "$cd12c/err")"
fi

# ── Case 13: abandoned PF + case-6 setup → prepare still removes it ────────────
cd13=$(newcase c13)
mkcache "$cd13" '2.2.10@2.2.10' '2.3.0'
wire_prompt "$cd13/repo"   # abandoned prompt from a previous run
run_fence bash prep "$cd13" "$cd13/repo"
_rc=$?
if [[ $_rc -ne 0 ]] \
    && grep -qF "$DIAG $cd13/home/.claude/plugins/cache/busdriver/busdriver/2.3.0/scripts/ultra-oracle-consult-run.sh" "$cd13/err" \
    && [[ ! -e "$cd13/repo/.claude/ultra-oracle/critique-prompt.txt" ]] \
    && [[ ! -e "$cd13/invocations.log" ]]; then
    ok "13: prepare removes an abandoned prompt even though resolution then fails"
else
    no "13: abandoned-prompt cleanup" \
        "rc=$_rc pf-left=$([[ -e "$cd13/repo/.claude/ultra-oracle/critique-prompt.txt" ]] && echo yes || echo no) err=$(cat "$cd13/err")"
fi

# ── Case 14: blocking — stub sleeps 2s, records PF existence during the call ───
cd14=$(newcase c14)
mksleepstub "$cd14/home/.claude/plugins/cache/busdriver/busdriver/2.2.10" \
    sleepy "$cd14/invocations.log" "$cd14/pf-existed.log"
wire_prompt "$cd14/repo"
_t0=$(date +%s)
run_fence bash b "$cd14" "$cd14/repo"
_rc=$?
_t1=$(date +%s)
if [[ $_rc -eq 0 ]] && [[ $((_t1 - _t0)) -ge 2 ]] \
    && grep -q '^oracle_status=ok-sleepy$' "$cd14/out" \
    && grep -q '^existed$' "$cd14/pf-existed.log" \
    && [[ ! -e "$cd14/repo/.claude/ultra-oracle/critique-prompt.txt" ]]; then
    ok "14: consult blocks until the stub returns; PF existed during the call, gone after"
else
    no "14: blocking consult" "rc=$_rc elapsed=$((_t1 - _t0))s out=$(cat "$cd14/out") record=$(cat "$cd14/pf-existed.log" 2>/dev/null)"
fi

# ── Case 15: cases 1, 4, 7 under `set -euo pipefail` ───────────────────────────
cd15a=$(newcase c15a)
mkcache "$cd15a" '2.2.3@2.2.3' '2.2.10@2.2.10' '2.3.0-rc1@rc1' 'current@cur'
run_fence bash prep "$cd15a" "$cd15a/repo" 'set -euo pipefail'
_rcp=$?
wire_prompt "$cd15a/repo"
run_fence bash a "$cd15a" "$cd15a/repo" 'set -euo pipefail'
_rca=$?
if [[ $_rcp -eq 0 && $_rca -eq 0 ]] \
    && ! grep -vq '^2\.2\.10 ' "$cd15a/invocations.log" \
    && grep -q '^oracle_status=ok-2.2.10$' "$cd15a/out"; then
    ok "15a: case-1 result identical under set -euo pipefail"
else
    no "15a: pipefail cache pick" "rc=$_rcp/$_rca out=$(cat "$cd15a/out") err=$(cat "$cd15a/err")"
fi
cd15b=$(newcase c15b)
mkcache "$cd15b" '2.3.0@newer-cache'
mkstub "$cd15b/env-root" env-root "$cd15b/invocations.log"
run_fence bash prep "$cd15b" "$cd15b/repo" \
    'set -euo pipefail' "export CLAUDE_PLUGIN_ROOT='$cd15b/env-root'"
_rc=$?
if [[ $_rc -eq 0 ]] && grep -q '^env-root --surface-check brainstorming$' "$cd15b/invocations.log"; then
    ok "15b: exported-env-root result identical under set -euo pipefail"
else
    no "15b: pipefail env root" "rc=$_rc err=$(cat "$cd15b/err")"
fi
cd15c=$(newcase c15c)
mkdir -p "$cd15c/home"
run_fence bash b "$cd15c" "$cd15c/repo" 'set -euo pipefail'
_rc=$?
if [[ $_rc -ne 0 ]] \
    && grep -qF "$DIAG $cd15c/home/.claude/plugins/cache/busdriver/busdriver/scripts/ultra-oracle-consult-run.sh" "$cd15c/err"; then
    ok "15c: no-cache failure under set -euo pipefail still carries the brainstorming: diagnostic"
else
    no "15c: pipefail no-cache" "rc=$_rc err=$(cat "$cd15c/err")"
fi

# ── Case 16: cases 1, 6, 7 under zsh (#821: absent zsh is a CI FAIL) ───────────
if have_zsh "16a: case-1 setup under zsh"; then
    cd16a=$(newcase c16a)
    mkcache "$cd16a" '2.2.3@2.2.3' '2.2.10@2.2.10' '2.3.0-rc1@rc1' 'current@cur'
    run_fence "$ZSH" prep "$cd16a" "$cd16a/repo"
    _rcp=$?
    wire_prompt "$cd16a/repo"
    run_fence "$ZSH" a "$cd16a" "$cd16a/repo"
    _rca=$?
    wire_prompt "$cd16a/repo"
    run_fence "$ZSH" b "$cd16a" "$cd16a/repo"
    _rcb=$?
    if [[ $_rcp -eq 0 && $_rca -eq 0 && $_rcb -eq 0 ]] \
        && [[ "$(wc -l < "$cd16a/invocations.log" | tr -d ' ')" -eq 3 ]] \
        && ! grep -vq '^2\.2\.10 ' "$cd16a/invocations.log" \
        && grep -q '^oracle_status=ok-2.2.10$' "$cd16a/out"; then
        ok "16a: all three fences pick 2.2.10 under zsh; consult prints oracle_status=ok-2.2.10"
    else
        no "16a: zsh cache pick" "rc=$_rcp/$_rca/$_rcb out=$(cat "$cd16a/out") err=$(cat "$cd16a/err")"
    fi
fi
if have_zsh "16b: case-6 setup under zsh"; then
    cd16b=$(newcase c16b)
    mkcache "$cd16b" '2.2.10@2.2.10' '2.3.0'
    run_fence "$ZSH" b "$cd16b" "$cd16b/repo"
    _rc=$?
    if [[ $_rc -ne 0 ]] \
        && grep -qF "$DIAG $cd16b/home/.claude/plugins/cache/busdriver/busdriver/2.3.0/scripts/ultra-oracle-consult-run.sh" "$cd16b/err" \
        && [[ ! -e "$cd16b/invocations.log" ]]; then
        ok "16b: wrapper-less newest dir fails closed under zsh with the full path"
    else
        no "16b: zsh wrapper-less dir" "rc=$_rc err=$(cat "$cd16b/err")"
    fi
fi
if have_zsh "16c: case-7 setup under zsh"; then
    cd16c=$(newcase c16c)
    mkdir -p "$cd16c/home"
    run_fence "$ZSH" b "$cd16c" "$cd16c/repo"
    _rc=$?
    if [[ $_rc -ne 0 ]] \
        && grep -qF "$DIAG $cd16c/home/.claude/plugins/cache/busdriver/busdriver/scripts/ultra-oracle-consult-run.sh" "$cd16c/err" \
        && [[ ! -e "$cd16c/invocations.log" ]]; then
        ok "16c: no cache dir under zsh -> same named-path diagnostic"
    else
        no "16c: zsh no-cache" "rc=$_rc err=$(cat "$cd16c/err")"
    fi
fi

# ── Case 17: gate budget — classifier sees each fence, padded or not ───────────
# Same payload shape as test-marker-glob-specificity.sh's verdict().
verdict() { # <command> -> the verdict line, or ERROR
    local payload
    payload=$(python3 -c 'import json,sys;print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]}}))' \
        "$1" 2>/dev/null) || { printf 'ERROR'; return; }
    python3 -I "$CLASSIFIER" <<<"$payload" 2>/dev/null || printf 'ERROR'
}
# Measured margin on the current fence bodies (46-char `# pad ...` comment lines, dev
# env): prepare survives ~303 padded lines, each consult ~296, before BLOCK_UNSCANNABLE —
# 20 lines of padding (#813 headroom convention) is well inside the real budget. If this
# ever shrinks under 20, shrink the FENCE, never this assertion.
_pad20="$(printf '# pad padding padding padding padding\n%.0s' {1..20})"$'\n'   # $() strips the last newline
_i=0
_17ok=1
_17detail=""
for _f in "$PREP" "$CONS_A" "$CONS_B"; do
    _v1=$(verdict "$_f")
    _v2=$(verdict "$_pad20$_f")
    if [[ "$_v1" != 'OK|' || "$_v2" != 'OK|' ]]; then
        _17ok=0
        _17detail+="fence$_i: bare=$_v1 padded=$_v2 "
    fi
    _i=$((_i + 1))
done
if [[ $_17ok -eq 1 ]]; then
    ok "17: all 3 fences classify OK| bare and with 20 comment lines prepended"
else
    no "17: classifier budget" "$_17detail"
fi
if ! grep -q 'marker_check' "$SKILL_MD"; then
    ok "17b: SKILL.md never names marker_check.py (self-affection guard)"
else
    no "17b: marker_check named in SKILL.md" "the doc would trip the helper guard it documents"
fi

# ── Case 18: statics on the Step 5.6 section ───────────────────────────────────
if ! printf '%s' "$SEC" | grep -qF 'busdriver/current'; then
    ok "18a: no busdriver/current fallback anywhere in Step 5.6"
else
    no "18a: stale current/ fallback" "found in section"
fi
if ! printf '%s' "$SEC" | grep -qF '${CLAUDE_PLUGIN_ROOT:-'; then
    ok "18b: no nested \${CLAUDE_PLUGIN_ROOT:-…} fallback spelling"
else
    no "18b: nested fallback spelling" "found in section"
fi
_cpr=$(printf '%s' "$SEC" | grep -oF '${CLAUDE_PLUGIN_ROOT}' | wc -l | tr -d ' ')
if [[ "$_cpr" -eq 3 ]]; then
    ok "18c: bare \${CLAUDE_PLUGIN_ROOT} appears exactly 3x (once per fence, R= line)"
else
    no "18c: bare plugin-root count" "got $_cpr, want 3 — Claude substitutes every occurrence"
fi
_nh=0
for _f in "$PREP" "$CONS_A" "$CONS_B"; do
    if printf '%s' "$_f" | grep -q '<<'; then _nh=1; fi
done
if [[ $_nh -eq 0 ]] && ! printf '%s' "$SEC" | grep -q 'ULTRA_ORACLE_EOF'; then
    ok "18d: no heredoc in any Step 5.6 fence (design text never enters a Bash command)"
else
    no "18d: heredoc still present" "found << or ULTRA_ORACLE_EOF"
fi
_trap_ok=1
for _f in "$CONS_A" "$CONS_B"; do
    _t=$(printf '%s\n' "$_f" | grep -nF "trap 'rm -f \"\$PF\"'" | cut -d: -f1)
    _r=$(printf '%s\n' "$_f" | grep -nF ': "${CLAUDE_PLUGIN_ROOT=}"' | cut -d: -f1)
    if [[ -z "$_t" || -z "$_r" || "$_t" -ge "$_r" ]]; then _trap_ok=0; fi
done
if [[ $_trap_ok -eq 1 ]]; then
    ok "18e: trap precedes the resolver in both consult fences (cleanup on ANY exit)"
else
    no "18e: trap ordering" "trap must precede resolver so resolver failures still clean up"
fi
_rm=$(printf '%s\n' "$PREP" | grep -nF 'rm -f "$PF"' | cut -d: -f1)
_res=$(printf '%s\n' "$PREP" | grep -nF ': "${CLAUDE_PLUGIN_ROOT=}"' | cut -d: -f1)
_fw=$(printf '%s\n' "$PREP" | grep -nF '[ -f "$WRAP" ]' | cut -d: -f1)
_mk=$(printf '%s\n' "$PREP" | grep -nF 'mkdir -p' | cut -d: -f1)
if [[ -n "$_rm" && -n "$_res" && -n "$_fw" && -n "$_mk" \
    && "$_rm" -lt "$_res" && "$_res" -lt "$_fw" && "$_fw" -lt "$_mk" ]]; then
    ok "18f: prepare ordering rm < resolver < wrapper-check < mkdir"
else
    no "18f: prepare ordering" "rm=$_rm resolver=$_res wrap=$_fw mkdir=$_mk"
fi
_pfval=$(printf '%s\n' "$PREP" | grep -oE 'PF="[^"]+"' | head -1)
_pfbase=${_pfval##*/}; _pfbase=${_pfbase%\"}
if [[ "$_pfbase" == 'critique-prompt.txt' ]] \
    && ! printf '%s' "$_pfbase" | grep -qiE '^(plan|design|architecture).*\.md$'; then
    ok "18g: prompt basename clears the ^(PLAN|DESIGN|ARCHITECTURE).*\\.md$ detector"
else
    no "18g: prompt basename" "PF basename '$_pfbase' would arm a design-review token"
fi
if ! printf '%s' "$SEC" | grep -qF 'empty stdout'; then
    ok "18h: no '# empty stdout (e.g. missing wrapper)' comment remains"
else
    no "18h: stale empty-stdout comment" "found in section"
fi
_nc=0
for _f in "$PREP" "$CONS_A" "$CONS_B"; do
    if printf '%s\n' "$_f" | grep -qE '^[[:space:]]*#'; then _nc=1; fi
done
if [[ $_nc -eq 0 ]]; then
    ok "18i: zero comment lines inside the fences (classifier budget)"
else
    no "18i: comments in fences" "comments consume the 4000-token walk budget"
fi

# ── Case 18j (design table's 18b): the gate's file-mod classifier pin ──────────
_ismod() { # <command> -> True/False
    python3 -I -c '
import sys
sys.path.insert(0, sys.argv[1])
from cmdword import is_file_mod
print(is_file_mod(sys.argv[2]))' "$LIBDIR" "$1" 2>/dev/null
}
_fm_ok=1
for _f in "$PREP" "$CONS_A" "$CONS_B"; do
    if [[ "$(_ismod "$_f")" != "True" ]]; then _fm_ok=0; fi
done
if [[ $_fm_ok -eq 1 ]]; then
    ok "18j: cmdword.is_file_mod True for all 3 fences — pins the §4 residual analysis"
else
    no "18j: is_file_mod" "a fence is not classified file-modifying — gate screen changed"
fi

# ── Shared-line byte-identity (rest of design case 18) + prose needles ─────────
_res_block() { printf '%s\n' "$1" | grep -F -A5 ': "${CLAUDE_PLUGIN_ROOT=}"'; }
_rb_p=$(_res_block "$PREP"); _rb_a=$(_res_block "$CONS_A"); _rb_b=$(_res_block "$CONS_B")
if [[ "$_rb_p" == "$_rb_a" && "$_rb_a" == "$_rb_b" \
    && "$(printf '%s\n' "$_rb_p" | wc -l | tr -d ' ')" -eq 6 ]]; then
    ok "18k: the 6 resolver lines are byte-identical across all three fences"
else
    no "18k: resolver byte-identity" "blocks differ or wrong length"
fi
_pf_p=$(printf '%s\n' "$PREP" | head -3); _pf_a=$(printf '%s\n' "$CONS_A" | head -3); _pf_b=$(printf '%s\n' "$CONS_B" | head -3)
if [[ "$_pf_p" == "$_pf_a" && "$_pf_a" == "$_pf_b" \
    && "$_pf_p" == *'PF="$S/ultra-oracle/critique-prompt.txt"'* ]]; then
    ok "18l: the 3 path lines are byte-identical across all three fences"
else
    no "18l: path-line byte-identity" "first three lines differ"
fi
_18m=1
for _needle in \
    'ultraOracle.brainstorming.enabled' \
    'TOCTOU' \
    'prepare fence' \
    'skipped:unavailable' \
    'parent directory exists' \
    'timeout: 1100000' \
    'timeout: 3710000' \
    'oracle_status=' \
    'run the prepare fence again' \
    'Critique this approved design adversarially. Name the 3 biggest risks, any simpler alternative, and anything underspecified.'; do
    if ! printf '%s' "$SEC" | grep -qF "$_needle"; then
        _18m=0
        no "18m: prose needle" "missing: $_needle"
    fi
done
if [[ $_18m -eq 1 ]]; then
    ok "18m: prose covers surface key, TOCTOU, prepare step, fail-closed statuses, Write-exemption precondition, both timeout formulas, status-only branching, cleanup rule, critique instruction"
fi

# ── Case 19: writing-plans statics ─────────────────────────────────────────────
if ! grep -qF 'plan-advisory-$$' "$WPLANS_MD"; then
    ok '19a: writing-plans has no plan-advisory-$$ (the Write tool cannot expand $$)'
else
    no '19a: plan-advisory-$$' 'a literal $$ in the name would be inert for Write'
fi
_19ok=1
for _needle in \
    'plan-advisory-<tag>-prompt.txt' \
    'plan-advisory-<tag>.md' \
    'prepare fence' \
    'consult fence' \
    'writingPlans'; do
    if ! grep -qF "$_needle" "$WPLANS_MD"; then
        _19ok=0
        no "19b: writing-plans needle" "missing: $_needle"
    fi
done
if [[ $_19ok -eq 1 ]]; then
    ok "19b: Paths bullet names the tagged prompt/out pair, both fences, and the writingPlans surface"
fi

printf '\n%s PASS, %s FAIL\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
