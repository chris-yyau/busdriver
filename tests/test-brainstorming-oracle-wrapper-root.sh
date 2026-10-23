#!/usr/bin/env bash
# Regression tests for #885 — brainstorming's Step 5.6 oracle wrapper resolution and
# prompt-file transport — and #975 — per-run prompt/verdict isolation by run tag. Case
# numbers track the two design docs' Tests tables (cases 20+ are #975's).
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
. "$(dirname "$0")/lib/git-env-isolation.sh" || exit 1

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
CLEAN=""
for _f in "${FENCES[@]}"; do
    if [[ "$_f" == *'--surface-check'* ]]; then
        PREP="$_f"
    elif [[ "$_f" == *'--surface brainstorming --mode'* ]]; then
        CONS_B="$_f"
    elif [[ "$_f" == *'--prompt-file'* ]]; then
        CONS_A="$_f"
    elif [[ "$_f" == *'cannot remove run files'* ]]; then
        CLEAN="$_f"
    fi
done
if [[ ${#FENCES[@]} -eq 4 && -n "$PREP" && -n "$CONS_A" && -n "$CONS_B" && -n "$CLEAN" ]]; then
    ok "extract: exactly 4 bash fences, identified by needle (prepare/consult-A/consult-B/cleanup)"
else
    no "extract: exactly 4 bash fences, identified by needle" \
        "fences=${#FENCES[@]} prep=${#PREP} consA=${#CONS_A} consB=${#CONS_B} clean=${#CLEAN}"
    printf '%s PASS, %s FAIL — extraction failed, aborting exec cases\n' "$PASS" "$FAIL"
    exit 1
fi

# ── Harness helpers ───────────────────────────────────────────────────────────
# A consult writes `verdict:<prompt bytes>` to --out. STUB_MODE (exported by a case preamble,
# inherited through the fence) simulates the adapter's other outcomes: fail = stdout left in
# <out>.err and exit 1; salvage = a <out>.sv.Ab12Cd temp, then killed; late = verdict written
# by a detached child after the consult returned, only once the test creates $STUB_RELEASE;
# $STUB_RELEASE.done records `released`, or `cap-expired` (30s, nothing written).
mkstub() { # <plugin root> <label> <invocation log>
    mkdir -p "$1/scripts"
    cat > "$1/scripts/ultra-oracle-consult-run.sh" <<EOF
#!/usr/bin/env bash
echo "$2 \$*" >> "$3"
if [[ "\${1:-}" == "--surface-check" ]]; then
    echo enabled
    exit 0
fi
pf=""
out=""
while [[ \$# -gt 0 ]]; do
    [[ "\$1" == "--prompt-file" ]] && pf="\$2"
    [[ "\$1" == "--out" ]] && out="\$2"
    shift
done
cat "\$pf" > "$3.prompt"
case "\${STUB_MODE:-}" in
    fail) echo partial > "\$out.err"; echo error; exit 1 ;;
    salvage) echo partial > "\$out.sv.Ab12Cd"; kill -9 \$\$ ;;
    late) ( for _ in \$(seq 300); do [[ -e "\$STUB_RELEASE" ]] && break; sleep 0.1; done
            if [[ -e "\$STUB_RELEASE" ]]; then echo late > "\$out"; echo released > "\$STUB_RELEASE.tmp"
            else echo cap-expired > "\$STUB_RELEASE.tmp"; fi
            mv "\$STUB_RELEASE.tmp" "\$STUB_RELEASE.done" ) > /dev/null 2>&1 & echo "ok-$2"; exit 0 ;;
esac
{ printf 'verdict:'; cat "\$pf"; } > "\$out"
echo "ok-$2"
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

# Case-23 stub: records whether the prompt file exists, creates <ready>, then holds the call
# open until the test creates <release> — the test, not a timer, ends the call. <ready>.end
# records how the hold ended: `released`, or `cap-expired` (30s, exit 3) — never a silent ok.
mkheldstub() { # <plugin root> <label> <invocation log> <existence record> <ready> <release>
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
    [[ "\$1" == "--prompt-file" ]] && pfarg="\$2"
    shift
done
[[ -e "\$pfarg" ]] && echo existed >> "$4"
: > "$5"
for _ in \$(seq 300); do [[ -e "$6" ]] && break; sleep 0.1; done
if [[ ! -e "$6" ]]; then
    echo cap-expired > "$5.end"
    exit 3
fi
echo released > "$5.end"
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

# RUN is the run tag pasted over RUN_TAG in the consult/cleanup fences — what the model does
# with prepare's `run=` line. Cases without a prepare use this fixed well-formed value.
RUN=0123456789abcdef
fence_body() {
    case $1 in
        prep) printf '%s' "$PREP";;
        a) printf '%s' "${CONS_A/T=RUN_TAG/T=$RUN}";;
        b) printf '%s' "${CONS_B/T=RUN_TAG/T=$RUN}";;
        clean) printf '%s' "${CLEAN/T=RUN_TAG/T=$RUN}";;
    esac
}

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

run_fence() { # <shell> <prep|a|b|clean> <casedir> <rundir> [preamble lines...]
    local shell=$1 which=$2 casedir=$3 rundir=$4; shift 4
    run_body "$shell" "$(fence_body "$which")" "$casedir" "$rundir" "$@"
}

wire_prompt_at() { # <absolute prompt path> — what the model's Write tool does
    mkdir -p "${1%/*}"
    printf 'Critique this approved design adversarially.\n\nplaceholder body\n' > "$1"
}
wire_prompt() { wire_prompt_at "$1/.claude/ultra-oracle/critique-prompt-$RUN.txt"; } # <git rundir>
pf_of() { grep '^pf=' "$1/out" | cut -d= -f2-; } # <casedir> -> printed prompt path
run_of() { grep '^run=' "$1/out" | cut -d= -f2-; } # <casedir> -> printed run tag
prep_run() { # <shell> <casedir> <rundir> [preamble...] -> prepare, then RUN = its run= value
    run_fence "$1" prep "${@:2}"
    local rc=$? r
    r=$(run_of "$2")
    [[ -z "$r" ]] || RUN=$r   # a failed prepare keeps the old RUN; callers check rc
    return $rc
}

DIAG='ultra-oracle wrapper not found:'

# ── Case 1: cache dirs 2.2.3 / 2.2.10 / 2.3.0-rc1 / current, all with stubs ────
cd1=$(newcase c1)
mkcache "$cd1" '2.2.3@2.2.3' '2.2.10@2.2.10' '2.3.0-rc1@2.3.0-rc1' 'current@current'
prep_run bash "$cd1" "$cd1/repo"
_rc1=$?
wire_prompt "$cd1/repo"
cp "$cd1/repo/.claude/ultra-oracle/critique-prompt-$RUN.txt" "$cd1/expected-prompt"
run_fence bash a "$cd1" "$cd1/repo"
_rcA=$?
cmp -s "$cd1/expected-prompt" "$cd1/invocations.log.prompt"; _cmpA=$?   # before B overwrites the capture
wire_prompt "$cd1/repo"          # consult A's trap deleted it
run_fence bash b "$cd1" "$cd1/repo"
_rcB=$?
cmp -s "$cd1/expected-prompt" "$cd1/invocations.log.prompt"; _cmpB=$?
if [[ $_rc1 -eq 0 && $_rcA -eq 0 && $_rcB -eq 0 && $_cmpA -eq 0 && $_cmpB -eq 0 ]] \
    && [[ "$(wc -l < "$cd1/invocations.log" | tr -d ' ')" -eq 3 ]] \
    && ! grep -vq '^2\.2\.10 ' "$cd1/invocations.log" \
    && grep -q '^oracle_status=ok-2.2.10$' "$cd1/out"; then
    ok "1: all three fences pick newest X.Y.Z (2.2.10); consult A prints oracle_status=ok-2.2.10"
else
    no "1: newest-version pick across fences" \
        "rc=$_rc1/$_rcA/$_rcB cmp=$_cmpA/$_cmpB log=$(tr '\n' '|' < "$cd1/invocations.log" 2>/dev/null) out=$(cat "$cd1/out")"
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
        && [[ ! -e "$cd9/repo/.claude/ultra-oracle/critique-prompt-$RUN.txt" ]] \
        && [[ ! -e "$cd9/invocations.log" ]] \
        && grep -qF "$DIAG $cd9/home/.claude/plugins/cache/busdriver/busdriver/2.3.0/scripts/ultra-oracle-consult-run.sh" "$cd9/err"; then
        ok "9$_w: resolver failure still removes the written prompt (trap precedes resolver)"
    else
        no "9$_w: trap on resolver failure" \
            "rc=$_rc pf-left=$([[ -e "$cd9/repo/.claude/ultra-oracle/critique-prompt-$RUN.txt" ]] && echo yes || echo no) err=$(cat "$cd9/err")"
    fi
done

# ── Case 10: missing PF and zero-byte PF, consult A and B ──────────────────────
for _w in a b; do
    for _kind in missing zero; do
        cd10=$(newcase "c10${_w}${_kind}")
        mkcache "$cd10" '2.2.10@2.2.10'
        if [[ "$_kind" == zero ]]; then
            mkdir -p "$cd10/repo/.claude/ultra-oracle"
            : > "$cd10/repo/.claude/ultra-oracle/critique-prompt-$RUN.txt"
        fi
        run_fence bash "$_w" "$cd10" "$cd10/repo"
        _rc=$?
        if [[ $_rc -ne 0 ]] \
            && grep -qF "prompt file missing or empty: $cd10/repo/.claude/ultra-oracle/critique-prompt-$RUN.txt" "$cd10/err" \
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
prep_run bash "$cd11" "$cd11/repo"
_pf=$(pf_of "$cd11")
_surface=$(grep '^surface=' "$cd11/out")   # the next run overwrites out/
# Shell-active design text — the reason the design travels in a file — must arrive verbatim.
printf 'Critique this.\n\nuse `rm -rf /` and $(id) and "$HOME" literally\n' > "$WORK/c11-design"
mkdir -p "${_pf%/*}" && cp "$WORK/c11-design" "$_pf"
run_fence bash b "$cd11" "$cd11/repo"
_rc=$?
if [[ $_rc -eq 0 ]] \
    && cmp -s "$WORK/c11-design" "$cd11/invocations.log.prompt" \
    && [[ "$_pf" == "$cd11/repo/.claude/ultra-oracle/critique-prompt-$RUN.txt" ]] \
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
prep_run bash "$cd12a" "$cd12a/repo"
_pf=$(pf_of "$cd12a")
wire_prompt_at "$_pf"
mkdir -p "$cd12a/repo/sub/dir"
run_fence bash b "$cd12a" "$cd12a/repo/sub/dir"
_rc=$?
if [[ $_rc -eq 0 && "$RUN" =~ ^[0-9a-f]{16}$ ]] && [[ "$_pf" != *'//'* ]] \
    && grep -q '^oracle_status=ok-2.2.10$' "$cd12a/out" \
    && grep -qF "out=${_pf%/*}/critique-$RUN.md" "$cd12a/out" \
    && [[ ! -e "$_pf" ]]; then
    ok "12a: consult from a repo subdirectory reads the same absolute pf (out= is its sibling, run= is 16 hex)"
else
    no "12a: subdir path agreement" "rc=$_rc pf=$_pf out=$(cat "$cd12a/out") err=$(cat "$cd12a/err")"
fi
# 12b: absolute BUSDRIVER_STATE_DIR
cd12b=$(newcase c12b)
mkcache "$cd12b" '2.2.10@2.2.10'
prep_run bash "$cd12b" "$cd12b/repo" \
    "export BUSDRIVER_STATE_DIR='$cd12b/abs-state'"
_pf=$(pf_of "$cd12b")
wire_prompt_at "$_pf"
run_fence bash b "$cd12b" "$cd12b/repo" \
    "export BUSDRIVER_STATE_DIR='$cd12b/abs-state'"
_rc=$?
if [[ $_rc -eq 0 && "$RUN" =~ ^[0-9a-f]{16}$ ]] && [[ "$_pf" == "$cd12b/abs-state/ultra-oracle/critique-prompt-$RUN.txt" ]] \
    && grep -q '^oracle_status=ok-2.2.10$' "$cd12b/out" \
    && grep -qF "out=${_pf%/*}/critique-$RUN.md" "$cd12b/out" \
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
prep_run bash "$cd12c" "$cd12c/d1"
_pf=$(pf_of "$cd12c")
wire_prompt_at "$_pf"
run_fence bash b "$cd12c" "$cd12c/d2"
_rc=$?
if [[ $_rc -eq 0 && "$RUN" =~ ^[0-9a-f]{16}$ ]] \
    && [[ "$_pf" == "$cd12c/home/.claude/ultra-oracle/critique-prompt-$RUN.txt" && "$_pf" != *'//'* ]] \
    && grep -q '^oracle_status=ok-2.2.10$' "$cd12c/out" \
    && grep -qF "out=${_pf%/*}/critique-$RUN.md" "$cd12c/out" \
    && [[ ! -e "$_pf" ]]; then
    ok "12c: non-repo cwds agree on \$HOME/.claude path across two different directories"
else
    no "12c: HOME-anchored agreement" "rc=$_rc pf=$_pf out=$(cat "$cd12c/out") err=$(cat "$cd12c/err")"
fi

# (Cases 13/13b — prepare removing a stale fixed-name prompt — were removed by #975: with
# per-run names prepare removes nothing; crash residue is reported instead, case 29.)

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
    && [[ ! -e "$cd14/repo/.claude/ultra-oracle/critique-prompt-$RUN.txt" ]]; then
    ok "14: consult blocks until the stub returns; PF existed during the call, gone after"
else
    no "14: blocking consult" "rc=$_rc elapsed=$((_t1 - _t0))s out=$(cat "$cd14/out") record=$(cat "$cd14/pf-existed.log" 2>/dev/null)"
fi

# ── Case 15: cases 1, 4, 7 under `set -euo pipefail` ───────────────────────────
cd15a=$(newcase c15a)
mkcache "$cd15a" '2.2.3@2.2.3' '2.2.10@2.2.10' '2.3.0-rc1@rc1' 'current@cur'
prep_run bash "$cd15a" "$cd15a/repo" 'set -euo pipefail'
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
# 15d/15e (#975), PATH-stubbed: a failing `find` costs only the residue count, never the
# prepare; a failing `od` stops prepare with the run-tag diagnostic before anything exists.
case15de() { # <shell> <label prefix> <casedir key>
    local sh=$1 lp=$2 key=$3 d rc
    d=$(newcase "${key}d")
    mkcache "$d" '2.2.10@2.2.10'
    mkdir -p "$d/bin"
    printf '#!/bin/sh\nexit 1\n' > "$d/bin/find"
    chmod +x "$d/bin/find"
    run_fence "$sh" prep "$d" "$d/repo" 'set -euo pipefail' "export PATH='$d/bin':\"\$PATH\""
    rc=$?
    if [[ $rc -eq 0 ]] && grep -q '^pf=' "$d/out" && grep -q '^surface=enabled$' "$d/out" \
        && grep -qE '^run=[0-9a-f]{16}$' "$d/out" && ! grep -q 'from other runs' "$d/err"; then
        ok "${lp}d: failing find under set -euo pipefail -> prepare exits 0 with pf/surface/run"
    else
        no "${lp}d: failing find" "rc=$rc out=$(cat "$d/out") err=$(cat "$d/err")"
    fi
    d=$(newcase "${key}e")
    mkcache "$d" '2.2.10@2.2.10'
    mkdir -p "$d/bin"
    printf '#!/bin/sh\nexit 1\n' > "$d/bin/od"
    chmod +x "$d/bin/od"
    run_fence "$sh" prep "$d" "$d/repo" 'set -euo pipefail' "export PATH='$d/bin':\"\$PATH\""
    rc=$?
    if [[ $rc -ne 0 ]] && grep -qx 'brainstorming: run tag missing or malformed' "$d/err" \
        && [[ ! -e "$d/repo/.claude" && ! -e "$d/invocations.log" ]] && ! grep -q '^pf=' "$d/out"; then
        ok "${lp}e: failing od under set -euo pipefail -> run-tag diagnostic, nothing created"
    else
        no "${lp}e: failing od" "rc=$rc out=$(cat "$d/out") err=$(cat "$d/err")"
    fi
}
case15de bash 15 c15

# ── Case 16: cases 1, 6, 7 under zsh (#821: absent zsh is a CI FAIL) ───────────
if have_zsh "16a: case-1 setup under zsh"; then
    cd16a=$(newcase c16a)
    mkcache "$cd16a" '2.2.3@2.2.3' '2.2.10@2.2.10' '2.3.0-rc1@rc1' 'current@cur'
    prep_run "$ZSH" "$cd16a" "$cd16a/repo"
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
# Measured margin on the #975 fence bodies (the `# pad ...` lines below, dev env, re-measured
# for all 4 fences): prepare survives ~275 padded lines, each consult ~288, cleanup ~318,
# before the classifier stops returning OK| (the 3-fence #885 figures were ~303/~296).
# 20 lines of padding (#813 headroom convention) must stay inside the real budget. If this
# ever shrinks under 20, shrink the FENCE, never this assertion.
_pad20="$(printf '# pad padding padding padding padding\n%.0s' {1..20})"$'\n'   # $() strips the last newline
_i=0
_17ok=1
_17detail=""
for _f in "$PREP" "$CONS_A" "$CONS_B" "$CLEAN"; do
    _v1=$(verdict "$_f")
    _v2=$(verdict "$_pad20$_f")
    if [[ "$_v1" != 'OK|' || "$_v2" != 'OK|' ]]; then
        _17ok=0
        _17detail+="fence$_i: bare=$_v1 padded=$_v2 "
    fi
    _i=$((_i + 1))
done
if [[ $_17ok -eq 1 ]]; then
    ok "17: all 4 fences classify OK| bare and with 20 comment lines prepended"
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
    ok "18c: bare \${CLAUDE_PLUGIN_ROOT} appears exactly 3x (once per wrapper fence, R= line)"
else
    no "18c: bare plugin-root count" "got $_cpr, want 3 — Claude substitutes every occurrence"
fi
_nh=0
for _f in "$PREP" "$CONS_A" "$CONS_B" "$CLEAN"; do
    if printf '%s' "$_f" | grep -q '<<'; then _nh=1; fi
done
if [[ $_nh -eq 0 ]] && ! printf '%s' "$SEC" | grep -q 'ULTRA_ORACLE_EOF'; then
    ok "18d: no heredoc in any of the 4 Step 5.6 fences (design text never enters a Bash command)"
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
_res=$(printf '%s\n' "$PREP" | grep -nF ': "${CLAUDE_PLUGIN_ROOT=}"' | cut -d: -f1)
_fw=$(printf '%s\n' "$PREP" | grep -nF '[ -f "$WRAP" ]' | cut -d: -f1)
_mk=$(printf '%s\n' "$PREP" | grep -nF 'mkdir -p' | cut -d: -f1)
_nt=$(printf '%s\n' "$PREP" | grep -nF 'N="$(find' | cut -d: -f1)
_pr=$(printf '%s\n' "$PREP" | grep -nF "printf 'pf=%s" | cut -d: -f1)
if [[ -n "$_res" && -n "$_fw" && -n "$_mk" && -n "$_nt" && -n "$_pr" \
    && "$_res" -lt "$_fw" && "$_fw" -lt "$_mk" && "$_mk" -lt "$_nt" && "$_nt" -lt "$_pr" ]] \
    && ! printf '%s\n' "$PREP" | grep -qwF 'rm'; then
    ok "18f: prepare ordering resolver < wrapper-check < mkdir < notice < printf, and no rm"
else
    no "18f: prepare ordering" "resolver=$_res wrap=$_fw mkdir=$_mk notice=$_nt printf=$_pr"
fi
_18g=1
for _v in PF OUT; do
    _val=$(printf '%s\n' "$PREP" | grep -oE "^$_v=\"[^\"]+\"" | head -1)
    _base=${_val##*/}; _base=${_base%\"}
    if [[ "$_base" != *'$T'* ]] \
        || printf '%s' "${_base//\$T/0123456789abcdef}" | grep -qiE '^(plan|design|architecture).*\.md$'; then
        _18g=0
        no "18g: $_v basename" "'$_base' lacks the run tag or would arm a design-review token"
    fi
done
if [[ $_18g -eq 1 ]]; then
    ok "18g: prompt and verdict basenames carry \$T and clear the ^(PLAN|DESIGN|ARCHITECTURE).*\\.md$ detector"
fi
if ! printf '%s' "$SEC" | grep -qF 'empty stdout'; then
    ok "18h: no '# empty stdout (e.g. missing wrapper)' comment remains"
else
    no "18h: stale empty-stdout comment" "found in section"
fi
_nc=0
for _f in "$PREP" "$CONS_A" "$CONS_B" "$CLEAN"; do
    if printf '%s\n' "$_f" | grep -qE '^[[:space:]]*#'; then _nc=1; fi
done
if [[ $_nc -eq 0 ]]; then
    ok "18i: zero comment lines inside the 4 fences (classifier budget)"
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
for _f in "$PREP" "$CONS_A" "$CONS_B" "$CLEAN"; do
    if [[ "$(_ismod "$_f")" != "True" ]]; then _fm_ok=0; fi
done
if [[ $_fm_ok -eq 1 ]]; then
    ok "18j: cmdword.is_file_mod True for all 4 fences (cleanup's rm sits in a bash -c operand)"
else
    no "18j: is_file_mod" "a fence is not classified file-modifying — gate screen changed"
fi

# ── Shared-line byte-identity (rest of design case 18) + prose needles ─────────
_res_block() { printf '%s\n' "$1" | grep -F -A5 ': "${CLAUDE_PLUGIN_ROOT=}"'; }
_rb_p=$(_res_block "$PREP"); _rb_a=$(_res_block "$CONS_A"); _rb_b=$(_res_block "$CONS_B")
if [[ "$_rb_p" == "$_rb_a" && "$_rb_a" == "$_rb_b" \
    && "$(printf '%s\n' "$_rb_p" | wc -l | tr -d ' ')" -eq 6 ]]; then
    ok "18k: the 6 resolver lines are byte-identical across the 3 wrapper fences"
else
    no "18k: resolver byte-identity" "blocks differ or wrong length"
fi
_TAGCHK='[[ "$T" =~ ^[0-9a-f]{16}$ ]] || { echo "brainstorming: run tag missing or malformed" >&2; exit 1; }'
_path_block() { printf '%s\n' "$1" | sed -n '2,6p'; }
_pb=$(_path_block "$PREP")
_18l=1
for _f in "$CONS_A" "$CONS_B" "$CLEAN"; do
    [[ "$(_path_block "$_f")" == "$_pb" && "$(printf '%s\n' "$_f" | head -1)" == 'T=RUN_TAG' ]] || _18l=0
done
[[ "$(printf '%s\n' "$PREP" | head -1)" == "T=\"\$(od -An -N8 -tx1 /dev/urandom | tr -d ' \\n')\" || T=" ]] || _18l=0
[[ "$(printf '%s\n' "$_pb" | sed -n 3p)" == "$_TAGCHK" \
    && "$(printf '%s\n' "$_pb" | sed -n 4p)" == 'PF="$S/ultra-oracle/critique-prompt-$T.txt"' \
    && "$(printf '%s\n' "$_pb" | sed -n 5p)" == 'OUT="$S/ultra-oracle/critique-$T.md"' ]] || _18l=0
if [[ $_18l -eq 1 ]]; then
    ok "18l: the 5 path lines are byte-identical across all 4 fences, each after its tag line"
else
    no "18l: path-line byte-identity" "tag line or lines 2-6 differ"
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
    'Critique this approved design adversarially. Name the 3 biggest risks, any simpler alternative, and anything underspecified.' \
    'RUN_TAG' \
    "never a value from another run or another conversation" \
    "no tag could be drawn from \`/dev/urandom\` — Retry" \
    "paste this run's \`run=\` value" \
    "A fence given **another run's** valid \`run=\` value acts as that run" \
    '**When to run the cleanup fence**' \
    '`skipped:disabled` or `skipped:user` from the consult → immediately' \
    'on Retry, before the new prepare' \
    '**A prompt was written and no `oracle_status=` line came back**' \
    '**The prepare failed and printed no `run=` line** → there is nothing to clean up: skip the cleanup fence, and on Retry go straight to a new prepare' \
    '(skip the cleanup when the failed prepare printed no `run=` line)' \
    '**Never while a consult is still running.**' \
    '**Never run the cleanup fence or Retry while an earlier consult task is still running**' \
    'attached by its original path' \
    '**Cleanup-fence exception:**' \
    'never sets `oracle_status`, never offers Retry / skip-once / abort, and never blocks Step 6' \
    'If the user already chose Retry, a failed cleanup does not cancel it' \
    'A prepare that exits 0 with the notice on stderr is a success' \
    '**If the cleanup fence is refused by a gate**' \
    '`critique-prompt-<tag>.txt`, `critique-<tag>.md`, `critique-<tag>.md.err` and any `critique-<tag>.md.sv.*`' \
    'Do not retry the refused call in another form' \
    '**Crash residue and the operator (accepted risk).**' \
    "ls -lt '<state dir>/ultra-oracle'" \
    '`critique-prompt.txt`, `design-critique.md`, `design-critique.md.err`' \
    'plaintext copies' \
    'delete only files of runs you know have ended' \
    'its attachment of the **original** prompt path via `--file`' \
    'transport-selection branches are unchanged' \
    'Retry means cleanup → prepare → Write → consult'; do
    if ! printf '%s' "$SEC" | grep -qF -- "$_needle"; then
        _18m=0
        no "18m: prose needle" "missing: $_needle"
    fi
done
for _gone in \
    'run the prepare fence again' \
    "Retry's prepare step deletes the prompt" \
    'doubles as the cleanup command' \
    'removes any stale prompt' \
    'stale-prompt-removal' \
    'same 9 lines' \
    '9 shared lines' \
    'In the prepare fence `rm` precedes' \
    'The next prepare run removes a stale prompt' \
    'Retry means prepare → Write → consult again' \
    '--browser-attachments'; do
    if printf '%s' "$SEC" | grep -qF -- "$_gone"; then
        _18m=0
        no "18m: stale prose" "still present: $_gone"
    fi
done
_nd=0
for _f in "$PREP" "$CONS_A" "$CONS_B" "$CLEAN"; do
    [[ "$(printf '%s\n' "$_f" | grep -cF 'run tag')" -eq 1 ]] \
        && printf '%s\n' "$_f" | grep -qxF "$_TAGCHK" || _nd=1
done
if printf '%s\n' "$PREP" | grep -qF "list: ls -lt \$(printf '%q' \"\${PF%/*}\") ;" && [[ $_nd -eq 0 ]] && [[ $_18m -eq 1 ]]; then
    ok "18m: prose covers run tag, cleanup rule, exceptions, refusal fallback, operator section, transport; stale prose gone; short in-fence diagnostic; %q-quoted listing"
else
    no "18m: prose / in-fence diagnostic / quoted listing" "needles-ok=$_18m diag-mismatch=$_nd"
fi

# ── Case 19: writing-plans statics ─────────────────────────────────────────────
if ! grep -qF 'plan-advisory-$$' "$WPLANS_MD"; then
    ok '19a: writing-plans has no plan-advisory-$$ (the Write tool cannot expand $$)'
else
    no '19a: plan-advisory-$$' 'a literal $$ in the name would be inert for Write'
fi
_19ok=1
_pfl=$(printf '%s\n' "$PREP" | grep -E '^PF=')
_outl=$(printf '%s\n' "$PREP" | grep -E '^OUT=')
for _needle in \
    "(a) keep brainstorming's run tag — the copied prepare draws it from \`/dev/urandom\` and prints it as \`run=\`" \
    "never another run's or one you make up (the \`[[ \"\$T\" =~\` line checks its format only)" \
    "replace the whole line \`$_pfl\` with \`PF=\"\$S/ultra-oracle/plan-advisory-\$T-prompt.txt\"\`" \
    "replace the whole line \`$_outl\` with \`OUT=\"\$S/ultra-oracle/plan-advisory-\$T.md\"\`" \
    '(f) delete from the prepare copy only the two residue-notice lines (`N="$(find …` and `[ "${N:-0}" -eq 0 ] …`)' \
    'the tag line (`T="$(od …` or `T=RUN_TAG`) and the `[[ "$T" =~` line stay in all three copies' \
    "the prepare copy's \`printf\` line still prints \`run=\`" \
    "Each run's pair carries its own 64-bit tag, so concurrent plan-writing runs get distinct files" \
    'a wrong but valid pasted tag acts as that run' \
    'in the prepare and consult copies' \
    'the prepare fence, the consult fence for the active path (A or B), and the cleanup fence' \
    'Clean up per run with the copied cleanup fence' \
    'never pauses plan-writing' \
    'Neither surface has a cross-run backstop' \
    "brainstorming's own four fences; these three copies differ by exactly the substitutions above" \
    'writingPlans'; do
    if ! grep -qF -- "$_needle" "$WPLANS_MD"; then
        _19ok=0
        no "19b: writing-plans needle" "missing: $_needle"
    fi
done
for _gone in "brainstorming's own three fences" 'fixed-name stale-prompt backstop' 'only the consult fence has an `OUT=` line' \
    'plan-advisory-<tag>' '6-character' '#990' '(g)'; do
    if grep -qF -- "$_gone" "$WPLANS_MD"; then
        _19ok=0
        no "19b: writing-plans stale prose" "still present: $_gone"
    fi
done
if [[ $_19ok -eq 1 ]]; then
    ok "19b: Paths bullet quotes the live PF/OUT lines, (a) tag keeping, (f), the copied cleanup fence, backstop and four-fences sentences"
fi

# ── #975 harness: runs sharing one state dir ───────────────────────────────────
# A run is a casedir (own out/err/cmd/HOME/stub log) acting in a shared rundir. r_prep saves
# its printed run= and pf=; every later step pastes that run's own tag. α/β differ in length,
# carry a non-ASCII byte and a trailing newline.
ALPHA=$'Critique this approved design adversarially.\n\nalpha design \xc3\xa9\n'
BETA=$'Critique this approved design adversarially.\n\nbeta design \xe2\x82\xac, longer\n'
r_prep() { # <shell> <casedir> <rundir> [preamble...]
    run_fence "$1" prep "${@:2}"
    local rc=$?
    run_of "$2" > "$2/tag"
    pf_of "$2" > "$2/pf"
    return $rc
}
r_fence() { # <shell> <a|b|clean> <casedir> <rundir> [preamble...] — pastes the run's own tag
    local RUN
    RUN=$(cat "$3/tag")
    run_fence "$@"
}
pfp() { cat "$1/pf"; }
outp() { local p; p=$(cat "$1/pf"); printf '%s' "${p%/*}/critique-$(cat "$1/tag").md"; }
r_write() { printf '%s' "$2" > "$(pfp "$1")"; } # <casedir> <bytes> — the Write tool
is_bytes() { cmp -s "$1" <(printf '%s' "$2"); } # <file> <expected bytes>
snap() { local f; for f in "$@"; do if [[ -e "$f" ]]; then cksum < "$f"; else echo "MISSING $f"; fi; done; }
has_run_files() { # <any path in the dir> <tag>
    local f
    for f in "${1%/*}"/*"$2"*; do [[ -e "$f" || -L "$f" ]] && return 0; done
    return 1
}

# ── Case 20 / 20b: interleaved runs never mix prompts or verdicts ──────────────
case20() { # <shell> <label> <casedir key> <shared-env 0|1>
    local sh=$1 lb=$2 key=$3 ra rb repo pa pb capb why=""
    ra=$(newcase "${key}a"); rb=$(newcase "${key}b")
    mkcache "$ra" '2.2.10@stub'; mkcache "$rb" '2.2.10@stub'
    repo="$ra/repo"
    if [[ $4 -eq 1 ]]; then   # one agent: byte-identical environment, one stub
        pa="export HOME='$ra/home'"; pb=$pa; capb="$ra/invocations.log.prompt"
    else                      # two sessions sharing the state dir
        pa='export CLAUDE_CODE_SESSION_ID=session-A'; pb='export CLAUDE_CODE_SESSION_ID=session-B'
        capb="$rb/invocations.log.prompt"
    fi
    r_prep "$sh" "$ra" "$repo" "$pa" || why+="A-prep "
    r_write "$ra" "$ALPHA"
    r_prep "$sh" "$rb" "$repo" "$pb" || why+="B-prep "
    is_bytes "$(pfp "$ra")" "$ALPHA" || why+="B-prep-touched-alpha "
    r_write "$rb" "$BETA"
    r_fence "$sh" a "$ra" "$repo" "$pa" || why+="A-consult "
    is_bytes "$ra/invocations.log.prompt" "$ALPHA" || why+="A-sent-wrong "
    r_fence "$sh" b "$rb" "$repo" "$pb" || why+="B-consult "
    is_bytes "$capb" "$BETA" || why+="B-sent-wrong "
    [[ "$(cat "$ra/tag")" =~ ^[0-9a-f]{16}$ && "$(cat "$ra/tag")" != "$(cat "$rb/tag")" ]] || why+="tags "
    grep -qxF "out=$(outp "$ra")" "$ra/out" && grep -qxF "out=$(outp "$rb")" "$rb/out" || why+="out= "
    is_bytes "$(outp "$ra")" "verdict:$ALPHA" || why+="A-verdict "
    is_bytes "$(outp "$rb")" "verdict:$BETA" || why+="B-verdict "
    if [[ -z "$why" ]]; then
        ok "$lb: A and B each sent and got back only their own design; B's prepare left A's prompt intact"
    else
        no "$lb: interleaved runs" "$why"
    fi
}
case20 bash 20 c20 0
case20 bash 20b c20b 1

# ── Case 21: A's consult, cleanup and retry never touch a live B ───────────────
case21() { # <shell> <label> <casedir key>
    local sh=$1 lb=$2 key=$3 ra rb repo before why="" step
    ra=$(newcase "${key}a"); rb=$(newcase "${key}b")
    mkcache "$ra" '2.2.10@stub'; mkcache "$rb" '2.2.10@stub'
    repo="$ra/repo"
    r_prep "$sh" "$rb" "$repo" || why+="B-prep "
    r_write "$rb" "$BETA"   # B is live: written, not yet consulted
    printf 'verdict:B\n' > "$(outp "$rb")"
    printf 'B stdout\n' > "$(outp "$rb").err"
    before=$(snap "$(pfp "$rb")" "$(outp "$rb")" "$(outp "$rb").err")
    for step in prep write a clean prep write a clean; do
        case $step in
            prep) r_prep "$sh" "$ra" "$repo" || why+="A-prep ";;
            write) r_write "$ra" "$ALPHA";;
            a) r_fence "$sh" a "$ra" "$repo"; grep -q '^oracle_status=ok-stub$' "$ra/out" || why+="A-consult ";;
            clean) r_fence "$sh" clean "$ra" "$repo" || why+="A-clean "
                   ! has_run_files "$(pfp "$ra")" "$(cat "$ra/tag")" || why+="A-left-files ";;
        esac
        [[ "$(snap "$(pfp "$rb")" "$(outp "$rb")" "$(outp "$rb").err")" == "$before" ]] || why+="B-changed-after-$step "
    done
    if [[ -z "$why" ]]; then
        ok "$lb: B's prompt/verdict/.err byte-identical after every A step; A leaves no files after each cleanup"
    else
        no "$lb: retry/cleanup isolation" "$why"
    fi
}
case21 bash 21 c21

# ── Case 22: an aborted run's prompt survives other runs and is reported ────────
c22a=$(newcase c22a); c22b=$(newcase c22b)
mkcache "$c22a" '2.2.10@stub'; mkcache "$c22b" '2.2.10@stub'
_why=""
r_prep bash "$c22a" "$c22a/repo" || _why+="A-prep "
r_write "$c22a" "$ALPHA"   # A is abandoned here
r_prep bash "$c22b" "$c22a/repo" || _why+="B-prep "
grep -qF "brainstorming: 1 oracle prompt/critique file(s) from other runs" "$c22b/err" || _why+="notice "
r_write "$c22b" "$BETA"
r_fence bash b "$c22b" "$c22a/repo" || _why+="B-consult "
is_bytes "$c22b/invocations.log.prompt" "$BETA" || _why+="B-sent-wrong "
r_fence bash clean "$c22b" "$c22a/repo" || _why+="B-clean "
is_bytes "$(pfp "$c22a")" "$ALPHA" || _why+="alpha-touched "
! grep -qF "$(pfp "$c22a")" "$c22b/invocations.log" || _why+="alpha-sent "
r_fence bash clean "$c22a" "$c22a/repo" || _why+="A-clean "
[[ ! -e "$(pfp "$c22a")" ]] || _why+="A-clean-left-alpha "
if [[ -z "$_why" ]]; then
    ok "22: abandoned prompt intact and never sent; B's notice counts it; A's own cleanup removes it"
else
    no "22: aborted gap" "$_why"
fi

# ── Case 22b: lost or malformed tag ────────────────────────────────────────────
case22b() { # <shell> <label> <casedir key> — malformed values, then a well-formed unmatched one
    local sh=$1 lb=$2 key=$3 d before bad which rc why="" RUN
    d=$(newcase "$key")
    mkcache "$d" '2.2.10@stub'
    r_prep "$sh" "$d" "$d/repo" || why+="prep "
    r_write "$d" "$ALPHA"
    before=$(ls -A "$d/repo/.claude/ultra-oracle"; snap "$(pfp "$d")")
    for bad in RUN_TAG xyz 0123abcd; do
        for which in a clean; do
            RUN=$bad
            run_fence "$sh" "$which" "$d" "$d/repo"
            rc=$?
            [[ $rc -ne 0 ]] && [[ "$(cat "$d/err")" == 'brainstorming: run tag missing or malformed' ]] \
                || why+="$bad/$which-diag "
        done
    done
    [[ "$(wc -l < "$d/invocations.log" | tr -d ' ')" -eq 1 ]] || why+="wrapper-called "
    [[ "$(ls -A "$d/repo/.claude/ultra-oracle"; snap "$(pfp "$d")")" == "$before" ]] || why+="touched "
    RUN=fedcba9876543210
    run_fence "$sh" a "$d" "$d/repo"
    rc=$?
    [[ $rc -ne 0 ]] && grep -qF 'prompt file missing or empty' "$d/err" && ! grep -q '^oracle_status=' "$d/out" \
        || why+="unmatched-consult "
    run_fence "$sh" clean "$d" "$d/repo" || why+="unmatched-clean-rc "
    [[ "$(ls -A "$d/repo/.claude/ultra-oracle"; snap "$(pfp "$d")")" == "$before" ]] || why+="unmatched-touched "
    if [[ -z "$why" ]]; then
        ok "$lb: RUN_TAG/xyz/8-hex stop with the run-tag diagnostic, no wrapper call; an unmatched tag errors and removes nothing"
    else
        no "$lb: lost tag" "$why"
    fi
}
case22b bash 22b c22bt

# ── Case 23: B runs fully while A's consult is in flight; then A gets TERM ─────
c23a=$(newcase c23a); c23b=$(newcase c23b)
mkheldstub "$c23a/sleeproot" sleepy "$c23a/invocations.log" "$c23a/pf-existed.log" \
    "$c23a/ready" "$c23a/release"
mkcache "$c23b" '2.2.10@stub'
_pa="export BUSDRIVER_PLUGIN_ROOT='$c23a/sleeproot'"
_why=""
r_prep bash "$c23a" "$c23a/repo" "$_pa" || _why+="A-prep "
r_write "$c23a" "$ALPHA"
RUN=$(cat "$c23a/tag")
{ printf 'unset CLAUDE_PLUGIN_ROOT BUSDRIVER_PLUGIN_ROOT BUSDRIVER_STATE_DIR\n%s\n' "$_pa"; fence_body a; } > "$c23a/cmd"
(cd "$c23a/repo" && HOME="$c23a/home" exec bash "$c23a/cmd" > "$c23a/out" 2> "$c23a/err") &
_apid=$!
for _ in $(seq 100); do [[ -e "$c23a/ready" ]] && break; sleep 0.1; done
[[ -e "$c23a/ready" ]] || _why+="A-never-ready "
r_prep bash "$c23b" "$c23a/repo" || _why+="B-prep "
r_write "$c23b" "$BETA"
r_fence bash b "$c23b" "$c23a/repo" || _why+="B-consult "
_bsnap=$(snap "$(outp "$c23b")")
# A's call is held open until the release below, so TERM provably reaches a consult in flight.
kill -0 "$_apid" 2>/dev/null && ! grep -q '^oracle_status=' "$c23a/out" || _why+="A-not-in-flight-at-TERM "
[[ -e "$(pfp "$c23a")" ]] || _why+="A-pf-removed-before-TERM "
kill -TERM "$_apid" 2>/dev/null
: > "$c23a/release"
wait "$_apid"
# `released` can only be observed after the release above, which follows TERM: the call was
# still held — not ended by its cap — when TERM was sent.
[[ "$(cat "$c23a/ready.end" 2>/dev/null)" == released ]] \
    || _why+="A-hold-ended-by:$(cat "$c23a/ready.end" 2>/dev/null || echo nothing) "
grep -q '^existed$' "$c23a/pf-existed.log" 2>/dev/null || _why+="A-pf-missing-during-call "
[[ ! -e "$(pfp "$c23a")" ]] || _why+="A-pf-left "
is_bytes "$c23b/invocations.log.prompt" "$BETA" && grep -q '^oracle_status=ok-stub$' "$c23b/out" || _why+="B-result "
is_bytes "$(outp "$c23b")" "verdict:$BETA" && [[ "$(snap "$(outp "$c23b")")" == "$_bsnap" ]] || _why+="B-touched "
if [[ -z "$_why" ]]; then
    ok "23: A's prompt existed during its call and is gone after TERM; B ran during it with its own bytes, untouched"
else
    no "23: overlap + cancellation" "$_why"
fi

# ── Case 24: names do not depend on session/process environment ────────────────
c24=$(newcase c24)
mkcache "$c24" '2.2.10@stub'
_why=""
for _envs in "export CLAUDE_CODE_SESSION_ID=s1 CLAUDE_PID=111|unset CLAUDE_CODE_SESSION_ID CLAUDE_PID" \
             "unset CLAUDE_CODE_SESSION_ID CLAUDE_PID|export CLAUDE_CODE_SESSION_ID=s2 CLAUDE_PID=222"; do
    r_prep bash "$c24" "$c24/repo" "${_envs%%|*}" || _why+="prep "
    [[ "$(pfp "$c24")" == "$c24/repo/.claude/ultra-oracle/critique-prompt-$(cat "$c24/tag").txt" ]] || _why+="pf "
    r_write "$c24" "$ALPHA"
    r_fence bash a "$c24" "$c24/repo" "${_envs#*|}" || _why+="consult "
    grep -q '^oracle_status=ok-stub$' "$c24/out" && grep -qxF "out=$(outp "$c24")" "$c24/out" || _why+="status "
done
if [[ -z "$_why" ]]; then
    ok "24: session id / pid set, unset or different between prepare and consult -> same names, consult ok"
else
    no "24: environment independence" "$_why"
fi

# ── Case 25: a failed consult's .err is removed by its own cleanup only ────────
c25a=$(newcase c25a); c25b=$(newcase c25b)
mkcache "$c25a" '2.2.10@stub'; mkcache "$c25b" '2.2.10@stub'
_why=""
r_prep bash "$c25b" "$c25a/repo" || _why+="B-prep "
r_write "$c25b" "$BETA"
r_fence bash a "$c25b" "$c25a/repo" 'export STUB_MODE=fail'
_bsnap=$(snap "$(outp "$c25b").err")
r_prep bash "$c25a" "$c25a/repo" || _why+="A-prep "
r_write "$c25a" "$ALPHA"
r_fence bash a "$c25a" "$c25a/repo" 'export STUB_MODE=fail'
grep -q '^oracle_status=error$' "$c25a/out" && [[ -e "$(outp "$c25a").err" ]] || _why+="A-no-err "
r_fence bash clean "$c25a" "$c25a/repo" || _why+="A-clean "
[[ ! -e "$(outp "$c25a").err" ]] || _why+="A-err-left "
[[ -e "$(outp "$c25b").err" && "$(snap "$(outp "$c25b").err")" == "$_bsnap" ]] || _why+="B-err-touched "
if [[ -z "$_why" ]]; then
    ok "25: failed consult leaves OUT.err; A's cleanup removes it; B's OUT.err byte-identical"
else
    no "25: failed consult" "$_why"
fi

# ── Case 25b: a salvage temp left by a killed consult ──────────────────────────
case25b() { # <shell> <label> <casedir key>
    local sh=$1 lb=$2 key=$3 ra rb sv why=""
    ra=$(newcase "${key}a"); rb=$(newcase "${key}b")
    mkcache "$ra" '2.2.10@stub'; mkcache "$rb" '2.2.10@stub'
    r_prep "$sh" "$ra" "$ra/repo" || why+="A-prep "
    r_write "$ra" "$ALPHA"
    r_fence "$sh" a "$ra" "$ra/repo" 'export STUB_MODE=salvage'
    sv="$(outp "$ra").sv.Ab12Cd"
    grep -q '^oracle_status=error$' "$ra/out" && [[ -e "$sv" ]] || why+="no-sv "
    r_prep "$sh" "$rb" "$ra/repo" || why+="B-prep "
    grep -qF 'brainstorming: 1 oracle prompt/critique file(s) from other runs' "$rb/err" || why+="not-counted "
    r_fence "$sh" clean "$ra" "$ra/repo" || why+="A-clean "
    [[ ! -e "$sv" ]] || why+="sv-left "
    if [[ -z "$why" ]]; then
        ok "$lb: killed salvage leaves OUT.sv.Ab12Cd; another run's prepare counts it; A's cleanup removes it"
    else
        no "$lb: salvage temp" "$why"
    fi
}
case25b bash 25b c25s

# ── Case 27: a consult that never ran — cleanup alone removes the prompt ────────
c27a=$(newcase c27a); c27b=$(newcase c27b)
mkcache "$c27a" '2.2.10@stub'; mkcache "$c27b" '2.2.10@stub'
_why=""
r_prep bash "$c27a" "$c27a/repo" || _why+="A-prep "
r_write "$c27a" "$ALPHA"
r_prep bash "$c27b" "$c27a/repo" || _why+="B-prep "
r_write "$c27b" "$BETA"
r_fence bash clean "$c27a" "$c27a/repo" || _why+="A-clean "
[[ ! -e "$(pfp "$c27a")" ]] || _why+="A-pf-left "
is_bytes "$(pfp "$c27b")" "$BETA" || _why+="B-touched "
if [[ -z "$_why" ]]; then
    ok "27: blocked consult — the cleanup fence removes this run's prompt; B's prompt untouched"
else
    no "27: blocked consult" "$_why"
fi

# ── Case 28: cleanup fence failures exit 1 with their diagnostic ───────────────
c28=$(newcase c28)
mkcache "$c28" '2.2.10@stub'
_why=""
r_prep bash "$c28" "$c28/repo" || _why+="prep "
mkdir -p "$(outp "$c28")/x"   # rm -f cannot remove a non-empty directory
r_fence bash clean "$c28" "$c28/repo"
_rc=$?
[[ $_rc -eq 1 ]] && grep -qF "brainstorming: cannot remove run files: $(pfp "$c28") $(outp "$c28")" "$c28/err" \
    && ! grep -q 'oracle_status' "$c28/out" || _why+="removal-failure rc=$_rc "
RUN=xyz
run_fence bash clean "$c28" "$c28/repo"
_rc=$?
[[ $_rc -eq 1 ]] && grep -qxF 'brainstorming: run tag missing or malformed' "$c28/err" \
    && ! grep -q 'oracle_status' "$c28/out" || _why+="tag-failure rc=$_rc "
if [[ -z "$_why" ]]; then
    ok "28: cleanup exits 1 with 'cannot remove run files' / 'run tag', never an oracle_status (18m pins the exception)"
else
    no "28: cleanup failures" "$_why"
fi

# ── Case 29 / 29b / 29c: residue notice counts other runs' files, touches nothing ─
# listing_ok runs the notice's printed `ls -lt …` command in bash, from /, and requires it
# to list <file> — the printed command must work as pasted, whatever the path holds.
listing_ok() { # <stderr file> <a file the listing must show>
    local cmd
    cmd=$(sed -n 's/.*; list: \(.*\) ; delete only files of runs you know have ended$/\1/p' "$1")
    [[ $cmd == "ls -lt "* ]] && (cd / && bash -c "$cmd" 2>/dev/null) | grep -qF -- "$2"
}
case29() { # <shell> <label> <casedir key>
    local sh=$1 lb=$2 key=$3 d u x=aaaaaaaaaaaaaaaa before why="" f
    d=$(newcase "$key")
    mkcache "$d" '2.2.10@stub'
    u="$d/repo/.claude/ultra-oracle"
    mkdir -p "$u/critique-bbbbbbbbbbbbbbbb.md"
    for f in "critique-prompt-$x.txt" "critique-$x.md" "critique-$x.md.err" "critique-$x.md.sv.Ab12Cd" \
        critique-prompt.txt design-critique.md.err plan-advisory-Ab12Cd-prompt.txt plan-advisory-Ab12Cd.md; do
        printf 'bytes of %s\n' "$f" > "$u/$f"
    done
    printf 'outside\n' > "$d/target"
    ln -s "$d/target" "$u/critique-cccccccccccccccc.md"
    before=$(ls -lA "$u" | sed 1d; cd "$u" && snap ./* 2>/dev/null; readlink "$u/critique-cccccccccccccccc.md")
    run_fence "$sh" prep "$d" "$d/repo" || why+="rc "
    grep -q '^pf=' "$d/out" && grep -q '^surface=enabled$' "$d/out" && grep -qE '^run=[0-9a-f]{16}$' "$d/out" || why+="output "
    grep -qF "brainstorming: 6 oracle prompt/critique file(s) from other runs are in $u " "$d/err" || why+="count "
    listing_ok "$d/err" "critique-$x.md" || why+="listing "
    [[ "$(ls -lA "$u" | sed 1d; cd "$u" && snap ./* 2>/dev/null; readlink "$u/critique-cccccccccccccccc.md")" == "$before" ]] || why+="touched "
    if [[ -z "$why" ]]; then
        ok "$lb: prepare exits 0, notice counts 6 (not plan-advisory, dir or symlink); every entry untouched"
    else
        no "$lb: residue notice" "$why err=$(cat "$d/err")"
    fi
}
case29 bash 29 c29
c29b=$(newcase c29b)
mkcache "$c29b" '2.2.10@stub'
run_fence bash prep "$c29b" "$c29b/repo"
_rc=$?
if [[ $_rc -eq 0 ]] && [[ ! -s "$c29b/err" ]]; then
    ok "29b: no residue -> no notice line"
else
    no "29b: no residue" "rc=$_rc err=$(cat "$c29b/err")"
fi
case29c() { # <shell> <label> <casedir key> — a state dir holding an apostrophe, a space and a
    # backslash (zsh's echo would rewrite `\\` and `\b`, undoing the %q escaping)
    local sh=$1 lb=$2 key=$3 d st why=""
    d=$(newcase "$key")
    mkcache "$d" '2.2.10@stub'
    st="$d/it's a\\b state"
    mkdir -p "$st/ultra-oracle"
    printf 'old\n' > "$st/ultra-oracle/critique-aaaaaaaaaaaaaaaa.md"
    run_fence "$sh" prep "$d" "$d/repo" "export BUSDRIVER_STATE_DIR=$(printf '%q' "$st")" || why+="rc "
    grep -qF "pf=$st/ultra-oracle/critique-prompt-" "$d/out" || why+="pf "
    grep -qF "brainstorming: 1 oracle prompt/critique file(s) from other runs are in $st/ultra-oracle " "$d/err" || why+="count "
    listing_ok "$d/err" critique-aaaaaaaaaaaaaaaa.md || why+="listing "
    if [[ -z "$why" ]]; then
        ok "$lb: state dir with an apostrophe, a space and a backslash -> the printed listing command runs as pasted"
    else
        no "$lb: apostrophe-safe listing" "$why err=$(cat "$d/err")"
    fi
}
case29c bash 29c c29c

# ── Case 30: a late verdict written after cleanup stays and is reported ────────
c30a=$(newcase c30a); c30b=$(newcase c30b)
mkcache "$c30a" '2.2.10@stub'; mkcache "$c30b" '2.2.10@stub'
_why=""
r_prep bash "$c30a" "$c30a/repo" || _why+="A-prep "
r_write "$c30a" "$ALPHA"
_rel="$c30a/release"
r_fence bash a "$c30a" "$c30a/repo" "export STUB_MODE=late STUB_RELEASE='$_rel'"
grep -q '^oracle_status=ok-stub$' "$c30a/out" || _why+="A-consult "
r_fence bash clean "$c30a" "$c30a/repo" || _why+="A-clean "
# The late writer is held until the release, so the write is ordered after the cleanup.
[[ ! -e "$(outp "$c30a")" && ! -e "$_rel.done" ]] \
    || _why+="writer-ended-before-release:$(cat "$_rel.done" 2>/dev/null || echo wrote) "
: > "$_rel"
for _ in $(seq 100); do [[ -e "$_rel.done" ]] && break; sleep 0.1; done
[[ "$(cat "$_rel.done" 2>/dev/null)" == released ]] \
    || _why+="late-writer-ended-by:$(cat "$_rel.done" 2>/dev/null || echo nothing) "
r_prep bash "$c30b" "$c30a/repo" || _why+="B-prep "
grep -qF 'brainstorming: 1 oracle prompt/critique file(s) from other runs' "$c30b/err" || _why+="not-counted "
[[ "$(cat "$(outp "$c30a")" 2>/dev/null)" == late ]] || _why+="late-file-gone "
if [[ -z "$_why" ]]; then
    ok "30: verdict written after A's cleanup stays; the next prepare counts it; no fence removes it"
else
    no "30: late write" "$_why"
fi

# ── Case 31: large prompt — the REAL wrapper attaches the original path ────────
# Runs scripts/ultra-oracle-consult-run.sh from this checkout with a PATH-stubbed oracle
# (argv recorded one per line, as tests/test-ultra-oracle.sh does) and a 2048-byte inline cap.
c31=$(newcase c31)
mkdir -p "$c31/bin" "$c31/home/.claude"
cat > "$c31/bin/oracle" <<'EOF'
#!/bin/bash
for a in "$@"; do printf '%s\n' "$a"; done >> "$ULTRA_ORACLE_ARGV_OUT"
out=""
while [ $# -gt 0 ]; do case "$1" in --write-output) out="$2"; shift 2;; *) shift;; esac; done
[ -n "$out" ] && printf 'ULTRA-ORACLE VERDICT: looks good\n' > "$out"
exit 0
EOF
chmod +x "$c31/bin/oracle"
_pre31=("export BUSDRIVER_PLUGIN_ROOT='$ROOT'" "export PATH='$c31/bin':\"\$PATH\"" 'export ULTRA_ORACLE_TEST_NO_LOCK=1' \
    'export ULTRA_ORACLE_INLINE_BYTES=2048' "export ULTRA_ORACLE_ARGV_OUT='$c31/argv.log'")
_why=""
r_prep bash "$c31" "$c31/repo" "${_pre31[@]}" || _why+="prep "
{ printf 'Critique this approved design adversarially.\n\n'; head -c 4096 /dev/zero | tr '\0' 'y'; } > "$(pfp "$c31")"
r_fence bash a "$c31" "$c31/repo" "${_pre31[@]}" || _why+="consult "
grep -q '^oracle_status=ok$' "$c31/out" || _why+="status "
grep -qxF -- '--file' "$c31/argv.log" 2>/dev/null && grep -qxF -- "$(pfp "$c31")" "$c31/argv.log" || _why+="not-original-path "
[[ "$(ls -A "$c31/repo/.claude/ultra-oracle")" == "critique-$(cat "$c31/tag").md" ]] || _why+="extra-files "
if [[ -z "$_why" ]]; then
    ok "31: over-cap prompt is attached by its original critique-prompt-<T>.txt path; no copy under the state dir"
else
    no "31: large prompt" "$_why out=$(cat "$c31/out") err=$(tail -3 "$c31/err") files=$(ls -A "$c31/repo/.claude/ultra-oracle" | tr '\n' ' ')"
fi

# ── Case 32: writing-plans copies built by its (a)–(f) substitutions ────────────
wp_copy() { # <fence> -> the writing-plans copy: plan-advisory-$T names, notice lines dropped
    local line
    while IFS= read -r line; do
        case "$line" in
            'N="$(find'*|'[ "${N:-0}" -eq 0 ]'*) continue ;;
            'PF="$S/ultra-oracle/critique-prompt-$T.txt"') line='PF="$S/ultra-oracle/plan-advisory-$T-prompt.txt"' ;;
            'OUT="$S/ultra-oracle/critique-$T.md"') line='OUT="$S/ultra-oracle/plan-advisory-$T.md"' ;;
        esac
        line="${line//--surface-check brainstorming/--surface-check writingPlans}"
        line="${line//design critique/plan advisory}" # (d) the --slug text
        printf '%s\n' "${line//--surface brainstorming/--surface writingPlans}"
    done <<< "$1"
}
_wp_prep=$(wp_copy "$PREP"); _wp_b=$(wp_copy "$CONS_B"); _wp_clean=$(wp_copy "$CLEAN")
_why=""
for _c in "$_wp_prep" "$_wp_b" "$_wp_clean"; do
    printf '%s\n' "$_c" | grep -qxF "$_TAGCHK" && printf '%s\n' "$_c" | grep -qE '^T=' || _why+="tag-lines-dropped "
    ! printf '%s\n' "$_c" | grep -qE '^N="\$\(find|critique' || _why+="leftover-brainstorming-lines "
    printf '%s\n' "$_c" | grep -qxF 'PF="$S/ultra-oracle/plan-advisory-$T-prompt.txt"' \
        && printf '%s\n' "$_c" | grep -qxF 'OUT="$S/ultra-oracle/plan-advisory-$T.md"' || _why+="paths "
    [[ "$(verdict "$_c")" == 'OK|' && "$(verdict "$_pad20$_c")" == 'OK|' ]] || _why+="classifier "
done
[[ $(printf '%s\n' "$_wp_prep" | grep -c .) -eq $(($(printf '%s\n' "$PREP" | grep -c .) - 2)) ]] || _why+="prep-line-count "
printf '%s\n' "$_wp_prep" | grep -qF "run=%s" || _why+="no-run-line "
printf '%s\n' "$_wp_b" | grep -qF -- '--slug "ultra oracle plan advisory"' || _why+="slug "
printf '%s\n' "$_wp_clean" | grep -qxF "$(printf '%s\n' "$CLEAN" | grep -F 'cannot remove run files')" || _why+="removal-line "
if [[ -z "$_why" ]]; then
    ok "32: writing-plans copies keep the tag/[[ lines and run=, drop only the notice lines, carry plan-advisory-\$T; all classify OK| bare and +20"
else
    no "32: writing-plans copy shape" "$_why"
fi

case32() { # <shell> <label> <casedir key> — runs A and B concurrent, crashed run C
    local sh=$1 lb=$2 key=$3 ca cb u ta tb tc=c0ffee00c0ffee00 t f rc why="" before
    ca=$(newcase "${key}a"); cb=$(newcase "${key}b")
    mkcache "$ca" '2.2.10@stub'; mkcache "$cb" '2.2.10@stub'
    u="$ca/repo/.claude/ultra-oracle"
    run_body "$sh" "$_wp_prep" "$ca" "$ca/repo" || why+="A-prep "
    run_body "$sh" "$_wp_prep" "$cb" "$ca/repo" || why+="B-prep "
    ta=$(run_of "$ca"); tb=$(run_of "$cb")
    [[ $ta =~ ^[0-9a-f]{16}$ && $tb =~ ^[0-9a-f]{16}$ && $ta != "$tb" ]] || why+="tags:$ta/$tb "
    grep -qxF "pf=$u/plan-advisory-$ta-prompt.txt" "$ca/out" && grep -q '^surface=enabled$' "$ca/out" \
        && grep -q 'surface-check writingPlans$' "$ca/invocations.log" || why+="A-prep-out "
    grep -qxF "pf=$u/plan-advisory-$tb-prompt.txt" "$cb/out" || why+="B-prep-out "
    for t in "$ta" "$tb" "$tc"; do # what each run's Write, consult, failure and salvage leave
        for f in "plan-advisory-$t-prompt.txt" "plan-advisory-$t.md" "plan-advisory-$t.md.err" "plan-advisory-$t.md.sv.1"; do
            printf '%s %s\n' "$t" "$f" > "$u/$f"
        done
    done
    mkdir -p "$ca/repo/w"
    printf 'stray\n' > "$ca/repo/w/.err"; printf 'stray\n' > "$ca/repo/w/x.sv.1"
    before=$(snap "$u"/plan-advisory-"$tb"* "$u"/plan-advisory-"$tc"*)
    run_body "$sh" "${_wp_clean/T=RUN_TAG/T=$ta}" "$ca" "$ca/repo/w" || why+="A-clean-rc "
    has_run_files "$u/x" "$ta" && why+="A-files-left "
    [[ "$(snap "$u"/plan-advisory-"$tb"* "$u"/plan-advisory-"$tc"*)" == "$before" ]] \
        && [[ $(find "$u" -maxdepth 1 -name "*$tb*" | grep -c .) -eq 4 && $(find "$u" -maxdepth 1 -name "*$tc*" | grep -c .) -eq 4 ]] || why+="B-or-C-touched "
    [[ -e "$ca/repo/w/.err" && -e "$ca/repo/w/x.sv.1" ]] || why+="cwd-touched "
    before=$(snap "$u"/*)
    for t in Ab12Cd RUN_TAG; do # the pre-amendment model-chosen shape, and the unpasted placeholder
        run_body "$sh" "${_wp_clean/T=RUN_TAG/T=$t}" "$ca" "$ca/repo/w"
        rc=$?
        [[ $rc -eq 1 ]] && grep -qF 'brainstorming: run tag missing or malformed' "$ca/err" || why+="bad-tag-$t:rc=$rc "
        [[ "$(snap "$u"/*)" == "$before" ]] || why+="bad-tag-$t-removed "
    done
    run_body "$sh" "${_wp_clean/T=RUN_TAG/T=$tb}" "$cb" "$ca/repo" || why+="B-clean-rc "
    has_run_files "$u/x" "$tb" && why+="B-files-left "
    [[ "$(find "$u" -maxdepth 1 -name "*$tc*" | grep -c .)" -eq 4 ]] || why+="C-residue-gone "
    mkdir -p "$u/plan-advisory-$ta.md/x"
    run_body "$sh" "${_wp_clean/T=RUN_TAG/T=$ta}" "$ca" "$ca/repo/w"
    rc=$?
    [[ $rc -eq 1 ]] && grep -qF 'cannot remove run files' "$ca/err" || why+="failure-path:rc=$rc "
    if [[ -z "$why" ]]; then
        ok "$lb: concurrent A/B get distinct tags; A's cleanup copy removes only A's 4 files from a fresh shell, sparing B, crashed C and the cwd; bad tags remove nothing; B's own cleanup works; C's residue stays; failure is loud"
    else
        no "$lb: writing-plans runs" "$why"
    fi
}
case32 bash 32b c32

# ── Case 26: zsh rows (#821: absent zsh is a CI FAIL) ──────────────────────────
if have_zsh "26: #975 rows under zsh"; then
    case20 "$ZSH" 26/20 c26-20 0
    case21 "$ZSH" 26/21 c26-21
    case25b "$ZSH" 26/25b c26-25b
    case29 "$ZSH" 26/29 c26-29
    case29c "$ZSH" 26/29c c26-29c
    case15de "$ZSH" 26/15 c26-15
    case22b "$ZSH" 26/22b c26-22b
    case32 "$ZSH" 26/32b c26-32
fi

printf '\n%s PASS, %s FAIL\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
