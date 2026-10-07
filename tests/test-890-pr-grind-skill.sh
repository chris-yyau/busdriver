#!/usr/bin/env bash
# tests/test-890-pr-grind-skill.sh — executes the #890 snippets published in
# skills/pr-grind/SKILL.md (design docs/plans/2026-10-01-issue-890-explicit-push-destination.md):
#   - the envelope wrapper (extracted between its markers, run against a stub dispatcher)
#   - "Push bail recovery (manual only)": steps 0, 1 and 5, and the row-2 rebase path
#   - grep guards on the published text (required / forbidden strings, eval guard)
# Recovery snippets run in a fresh `env -i … bash --noprofile --norc` shell with no
# plugin-root variable, from an unrelated directory. No network: remotes are local
# bare repos, served over a test-only SSH adapter where a URL must look like GitHub.
#
# shellcheck disable=SC2329,SC2317,SC2016  # test_* invoked dynamically; snippets run in child shells
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL="$REPO_ROOT/skills/pr-grind/SKILL.md"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0
# Fixture repos must not inherit a caller's repository, config or plugin root.
unset BUSDRIVER_PLUGIN_ROOT CLAUDE_PLUGIN_ROOT
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_CONFIG GIT_CONFIG_PARAMETERS
for _v in $(compgen -e | grep -E '^GIT_CONFIG_(KEY|VALUE)_' || true); do unset "$_v"; done
unset _v
export GIT_CONFIG_COUNT=0
# The fresh recovery shell gets the same git and jq this suite uses, plus the
# system dirs — not the caller's whole PATH.
RUN_PATH="$(dirname "$(command -v git)"):$(dirname "$(command -v jq)"):/usr/bin:/bin"

SANDBOX_ROOT=$(mktemp -d) || { echo "FAIL: mktemp -d failed"; exit 1; }
trap 'chmod -R u+w "$SANDBOX_ROOT" 2>/dev/null; rm -rf "$SANDBOX_ROOT"' EXIT

BAD=0
ck() { local label=$1; shift; if ! "$@"; then echo "  mismatch: $label"; BAD=1; fi; }
eq() { [ "$1" = "$2" ] || { printf '    got [%.300s] want [%.300s]\n' "$1" "$2"; return 1; }; }
has() { case $1 in *"$2"*) return 0 ;; esac; printf '    [%.300s] lacks [%s]\n' "$1" "$2"; return 1; }
lacks() { case $1 in *"$2"*) printf '    [%.300s] has [%s]\n' "$1" "$2"; return 1 ;; esac; return 0; }

# --- extraction ----------------------------------------------------------------

wrapper_block() {   # lines strictly between the two markers
    awk '/^# bd890-envelope-wrapper:begin$/{on=1; next} /^# bd890-envelope-wrapper:end$/{on=0} on' "$SKILL"
}

recovery_section() {
    awk '/^### Push bail recovery \(manual only\)$/{on=1} on && /^## /{exit} on' "$SKILL"
}

recovery_fence() {   # recovery_fence <n> — the n-th ```bash fence of the recovery section
    recovery_section | awk -v want="$1" '
        /^```bash$/ { n++; if (n == want) { on = 1; next } }
        /^```$/ && on { exit }
        on'
}

# --- fixtures ------------------------------------------------------------------

new_clone() {   # new_clone <dir> — a clone with one commit on main
    git init -q -b main "$1"
    git -C "$1" config user.email t@example.com
    git -C "$1" config user.name Test
    git -C "$1" config commit.gpgsign false
    printf 'base\n' > "$1/f.txt"
    git -C "$1" add f.txt
    git -C "$1" commit -qm base
}

# A stub plugin root whose dispatcher prints $STUB_OUT, records what it received,
# then exits $STUB_RC. STUB_UNLINK=1 makes it delete its own stdout target first.
make_stub_root() {
    mkdir -p "$1/scripts/lib"
    cat > "$1/scripts/dispatcher-commit-block.sh" <<'EOF'
#!/usr/bin/env bash
[ -n "${STUB_MARK:-}" ] && printf 'ran %s via %s\n' "${BUSDRIVER_PLUGIN_ROOT:-}" "${0%/scripts/dispatcher-commit-block.sh}" >> "$STUB_MARK"
printf '%s' "${STUB_OUT:-}"
if [ "${STUB_UNLINK:-0}" = 1 ]; then rm -f "$(readlink "/proc/$$/fd/1")"; fi
exit "${STUB_RC:-0}"
EOF
    ln -s "$REPO_ROOT/scripts/lib/push-dest-id.sh" "$1/scripts/lib/push-dest-id.sh"
}

WRAPPER="$SANDBOX_ROOT/wrapper.sh"
build_wrapper() {
    wrapper_block | sed \
        -e "s|^PRIOR_COMMIT_SHA=<.*> \\\\\$|PRIOR_COMMIT_SHA=none \\\\|" \
        -e "s|^PR_HEAD_HOST='<.*>' \\\\\$|PR_HEAD_HOST='github.com' \\\\|" \
        -e "s|^PR_HEAD_OWNER='<.*>' \\\\\$|PR_HEAD_OWNER='bd890-fixture' \\\\|" \
        -e "s|^PR_HEAD_NAME='<.*>' \\\\\$|PR_HEAD_NAME='repo' \\\\|" > "$WRAPPER"
}

W_OUT_FILE="$SANDBOX_ROOT/w.out"
run_wrapper() {   # run_wrapper <worktree> <pr> → W_OUT (exact bytes in $W_OUT_FILE), W_ERR, W_RC
    local err="$SANDBOX_ROOT/w.err"
    W_RC=0
    (cd "$SANDBOX_ROOT" && WORKTREE_DIR="$1" PR_NUMBER="$2" RESULT_STATUS=needs_more \
        RESULT_FIXES=x bash "$WRAPPER" >"$W_OUT_FILE" 2>"$err") || W_RC=$?
    W_OUT=$(cat "$W_OUT_FILE")
    W_ERR=$(cat "$err")
}
# Byte-exact: cmp, never $(…), which strips trailing newlines.
same_bytes() { cmp -s "$1" "$2" || { printf '    %s and %s differ\n' "$1" "$2"; return 1; }; }
want_bytes() { printf '%s' "$2" > "$SANDBOX_ROOT/want.bytes"; same_bytes "$1" "$SANDBOX_ROOT/want.bytes"; }

stderr_value() { printf '%s\n' "$W_ERR" | sed -n "s/^$1=//p"; }
stderr_count() { printf '%s\n' "$W_ERR" | grep -c "^$1=" || true; }
decode_word() { bash --noprofile --norc -c "v=$1; printf %s \"\$v\""; }

test_wrapper_extraction() {
    ck "one begin marker" eq "$(grep -c '^# bd890-envelope-wrapper:begin$' "$SKILL")" 1
    ck "one end marker" eq "$(grep -c '^# bd890-envelope-wrapper:end$' "$SKILL")" 1
    # Both markers inside the same ```bash fence, outside the ```text diagram.
    local where
    where=$(awk '
        /^```text$/ { fence = "text"; next }
        /^```bash$/ { fence = "bash"; nb++; next }
        /^```$/     { fence = ""; next }
        /^# bd890-envelope-wrapper:(begin|end)$/ { print fence ":" nb }' "$SKILL" | sort -u)
    ck "markers share one bash fence" eq "$(printf '%s\n' "$where" | wc -l | tr -d ' ')" 1
    ck "fence is bash" has "$where" "bash:"
    ck "no diagram prefix in block" lacks "$(wrapper_block)" '│'
    local diagram
    diagram=$(awk '/^## The Dispatcher Loop$/{d=1} d && /^```text$/{on=1; next} on && /^```$/{exit} on' "$SKILL")
    ck "diagram keeps the pointer" has "$diagram" 'Fix-round delegation: run the "Dispatcher invocation (envelope wrapper)" bash block below'
    ck "diagram has no invocation" lacks "$diagram" 'bash "$CLAUDE_PLUGIN_ROOT/scripts/dispatcher-commit-block.sh"'
    build_wrapper
    ck "placeholders substituted" lacks "$(cat "$WRAPPER")" '<P'
    ck "bash -n on the block" bash -n "$WRAPPER"
}

test_wrapper_rows() {
    local root="$SANDBOX_ROOT/root1" clone="$SANDBOX_ROOT/clone1" file gcd
    make_stub_root "$root"
    new_clone "$clone"
    build_wrapper
    export CLAUDE_PLUGIN_ROOT="$root" STUB_MARK="$SANDBOX_ROOT/mark1"
    unset BUSDRIVER_PLUGIN_ROOT
    gcd=$(git -C "$clone" rev-parse --path-format=absolute --git-common-dir)

    # Row 1: success.
    STUB_OUT=$'line one\nline two\n{"status":"success"}\n' STUB_RC=0 run_wrapper "$clone" 7
    file=$(stderr_value ENVELOPE_FILE)
    ck "row1 rc" eq "$W_RC" 0
    ck "row1 one ENVELOPE_FILE" eq "$(stderr_count ENVELOPE_FILE)" 1
    ck "row1 location" eq "${file%/*}" "$gcd"
    ck "row1 name" has "$(printf '%s' "${file##*/}" | grep -E '^pr-grind-bail-7\.[A-Za-z0-9]{6}$' || true)" pr-grind-bail-7
    ck "row1 mode 0600" eq "$(stat -c %a "$file" 2>/dev/null || stat -f %Lp "$file")" 600
    ck "row1 file == stdout" same_bytes "$file" "$W_OUT_FILE"
    ck "row1 stub bytes" want_bytes "$W_OUT_FILE" $'line one\nline two\n{"status":"success"}\n'
    ck "row1 last line" eq "$(printf '%s\n' "$W_OUT" | tail -n 1)" '{"status":"success"}'
    cp "$file" "$SANDBOX_ROOT/first.snap"; local first=$file

    # Row 2: bail.
    STUB_OUT=$'{"bail_category":"env","bail_reason":"x"}\n' STUB_RC=1 run_wrapper "$clone" 7
    ck "row2 rc" eq "$W_RC" 1
    ck "row2 file == stdout" same_bytes "$(stderr_value ENVELOPE_FILE)" "$W_OUT_FILE"
    ck "row2 stub bytes" want_bytes "$W_OUT_FILE" $'{"bail_category":"env","bail_reason":"x"}\n'

    # Row 3: distinct files; the first is untouched.
    ck "row3 distinct" not_eq "$(stderr_value ENVELOPE_FILE)" "$first"
    ck "row3 first unchanged" same_bytes "$first" "$SANDBOX_ROOT/first.snap"

    # Row 7: Git does not track it.
    ck "row7 untracked" lacks "$(git -C "$clone" status --porcelain --ignored)" pr-grind-bail

    # Row 9: recovery coordinates decode byte for byte.
    ck "row9 counts" eq "$(stderr_count RECOVERY_GIT_COMMON_DIR)$(stderr_count RECOVERY_CLONE)$(stderr_count RECOVERY_LIB_ROOT)" 111
    ck "row9 gcd" eq "$(decode_word "$(stderr_value RECOVERY_GIT_COMMON_DIR)")" "$gcd"
    ck "row9 clone" eq "$(decode_word "$(stderr_value RECOVERY_CLONE)")" "$clone"
    ck "row9 lib" eq "$(decode_word "$(stderr_value RECOVERY_LIB_ROOT)")" "$root/scripts/lib"

    # Row 4: creation failures never run the dispatcher.
    rm -f "$STUB_MARK"
    STUB_OUT=x run_wrapper "$clone" abc
    ck "row4 bad PR rc" eq "$W_RC" 1
    ck "row4 bad PR envelope" has "$W_OUT" 'cannot create durable envelope file in the git common dir'
    STUB_OUT=x run_wrapper "$SANDBOX_ROOT/not-a-repo" 7
    ck "row4 non-repo" has "$W_OUT" 'cannot create durable envelope file in the git common dir'
    if [ "$(id -u)" = 0 ]; then
        echo "  note: running as root, which ignores a read-only directory; read-only row skipped"
    else
        chmod a-w "$gcd"
        STUB_OUT=x run_wrapper "$clone" 7
        chmod u+w "$gcd"
        ck "row4 read-only" has "$W_OUT" 'cannot create durable envelope file in the git common dir'
    fi
    ck "row4 dispatcher never ran" eq "$(test -e "$STUB_MARK" && echo ran)" ""

    # Row 5: survives removal of the linked worktree it was created from.
    git -C "$clone" worktree add -q "$SANDBOX_ROOT/linked" -b linked
    STUB_OUT=$'{"bail_category":"env","bail_reason":"y"}\n' STUB_RC=1 run_wrapper "$SANDBOX_ROOT/linked" 7
    file=$(stderr_value ENVELOPE_FILE)
    git -C "$clone" worktree remove --force "$SANDBOX_ROOT/linked"
    ck "row5 survives" want_bytes "$file" $'{"bail_category":"env","bail_reason":"y"}\n'

    # Row 8: relay failure is never a success.
    if [ -d /proc/$$/fd ]; then
        STUB_OUT=$'{"status":"success"}\n' STUB_RC=0 STUB_UNLINK=1 run_wrapper "$clone" 7
        ck "row8 rc" eq "$W_RC" 1
        ck "row8 last line" has "$(printf '%s\n' "$W_OUT" | tail -n 1)" 'envelope file unreadable after dispatch'
        STUB_OUT=$'{"status":"success"}\n' STUB_RC=3 STUB_UNLINK=1 run_wrapper "$clone" 7
        ck "row8 keeps dispatcher rc" eq "$W_RC" 3
    else
        echo "  row 8 skipped: no /proc on this platform"
    fi

    # Row 9 (roots): BUSDRIVER_PLUGIN_ROOT wins and is what the dispatcher receives;
    # an unexported shell variable counts too; a relative root prints an empty value.
    local root2="$SANDBOX_ROOT/root2"
    make_stub_root "$root2"
    rm -f "$STUB_MARK"
    BUSDRIVER_PLUGIN_ROOT="$root2" STUB_OUT=$'{}\n' run_wrapper "$clone" 7
    ck "row9 busdriver root to dispatcher" eq "$(cat "$STUB_MARK")" "ran $root2 via $root2"
    ck "row9 busdriver lib root" eq "$(decode_word "$(stderr_value RECOVERY_LIB_ROOT)")" "$root2/scripts/lib"
    ck "row9 unexported root" eq "$(cd "$SANDBOX_ROOT" && WORKTREE_DIR="$clone" PR_NUMBER=7 STUB_OUT='{}' \
        bash -c 'BUSDRIVER_PLUGIN_ROOT='"$(printf '%q' "$root2")"'; . "$1"' bash "$WRAPPER" 2>&1 >/dev/null \
        | sed -n 's/^RECOVERY_LIB_ROOT=//p')" "$(printf '%q' "$root2/scripts/lib")"
    ck "row9 relative root" eq "$(cd "$SANDBOX_ROOT" && WORKTREE_DIR="$clone" PR_NUMBER=7 STUB_OUT='{}' \
        CLAUDE_PLUGIN_ROOT=rel/root bash "$WRAPPER" 2>&1 >/dev/null | grep '^RECOVERY_LIB_ROOT=')" 'RECOVERY_LIB_ROOT='
    unset CLAUDE_PLUGIN_ROOT STUB_MARK
}
not_eq() { [ "$1" != "$2" ] || { printf '    both [%s]\n' "$1"; return 1; }; }

test_wrapper_hostile_root() {
    local base="$SANDBOX_ROOT/hostile" clone root
    mkdir -p "$base"
    clone="$base/c'\$(touch PWNED3) y"
    root="$base/r'\$(touch PWNED3) z"
    make_stub_root "$root"
    new_clone "$clone"
    build_wrapper
    CLAUDE_PLUGIN_ROOT="$root" STUB_OUT=$'{"status":"success"}\n' STUB_RC=0 run_wrapper "$clone" 7
    ck "hostile rc" eq "$W_RC" 0
    ck "hostile bytes" want_bytes "$(stderr_value ENVELOPE_FILE)" $'{"status":"success"}\n'
    ck "hostile clone decodes" eq "$(cd "$base" && decode_word "$(stderr_value RECOVERY_CLONE)")" "$clone"
    ck "hostile lib decodes" eq "$(cd "$base" && decode_word "$(stderr_value RECOVERY_LIB_ROOT)")" "$root/scripts/lib"
    ck "PWNED3 never created" eq "$(find "$SANDBOX_ROOT" -name PWNED3 | wc -l | tr -d ' ')" 0
}

# --- recovery snippets ---------------------------------------------------------

# recovery_script <out> <clone> <libroot> <env_name> <pr> <fence...> — steps 0 [1 …]
# with the placeholders replaced by %q-quoted values, as the wrapper prints them.
recovery_script() {
    local out=$1 clone=$2 lib=$3 env_name=$4 pr=$5; shift 5
    local gcd n
    gcd=$(git -C "$clone" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || printf '%s/.git' "$clone")
    : > "$out"
    for n in "$@"; do recovery_fence "$n" >> "$out"; done
    local q_clone q_gcd q_lib
    q_clone=$(printf '%q' "$clone"); q_gcd=$(printf '%q' "$gcd"); q_lib=$(printf '%q' "$lib")
    [ -n "$lib" ] || q_lib=""
    REC_CLONE=$q_clone REC_GCD=$q_gcd REC_LIB=$q_lib REC_ENV=$env_name REC_PR=$pr \
        python3 - "$out" <<'PY'
import os, sys, pathlib
p = pathlib.Path(sys.argv[1]); s = p.read_text()
s = s.replace("<RECOVERY_CLONE value as printed>", os.environ["REC_CLONE"])
s = s.replace("<RECOVERY_GIT_COMMON_DIR value as printed>", os.environ["REC_GCD"])
s = s.replace("<RECOVERY_LIB_ROOT value as printed>", os.environ["REC_LIB"])
s = s.replace("<basename of the ENVELOPE_FILE path in the bail message>", os.environ["REC_ENV"])
s = s.replace("<the PR number you are recovering>", os.environ["REC_PR"])
p.write_text(s)
PY
}

run_fresh() {   # run_fresh <script> [trace] → R_OUT, R_RC
    local trace=${2:-}
    R_RC=0
    R_OUT=$(cd / && env -i HOME="$HOME" PATH="$RUN_PATH" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
        ${trace:+GIT_TRACE="$trace"} bash --noprofile --norc "$1" 2>&1) || R_RC=$?
}

LIBROOT="$SANDBOX_ROOT/installed/scripts/lib"
mkdir -p "$LIBROOT"
cp "$REPO_ROOT/scripts/lib/push-dest-id.sh" "$LIBROOT/"

test_recovery_step0() {
    local clone="$SANDBOX_ROOT/consumer" script="$SANDBOX_ROOT/s0.sh"
    new_clone "$clone"
    mkdir -p "$clone/scripts/lib"
    printf 'bd890_decoy_sentinel() { :; }\n_bd890_read_one_push_url() { :; }\n' > "$clone/scripts/lib/push-dest-id.sh"
    git -C "$clone" add scripts && git -C "$clone" commit -qm decoy
    recovery_script "$script" "$clone" "$LIBROOT" unused 1 1
    printf '\ndeclare -F bd890_decoy_sentinel >/dev/null && echo DECOY || echo CLEAN\ndeclare -F _bd890_endpoint_matches_pr >/dev/null && echo LOADED\n' >> "$script"
    run_fresh "$script"
    ck "installed root loads" eq "$R_RC:$R_OUT" $'0:CLEAN\nLOADED'

    local bad
    for bad in "$SANDBOX_ROOT/removed/scripts/lib" "" "relative/scripts/lib"; do
        recovery_script "$script" "$clone" "$bad" unused 1 1
        run_fresh "$script" "$SANDBOX_ROOT/trace0"
        ck "missing root [$bad] stops" eq "$R_RC" 1
        ck "missing root [$bad] says STOP" has "$R_OUT" "STOP (no push, reset or rebase)"
    done
    local broken="$SANDBOX_ROOT/broken/scripts/lib"
    mkdir -p "$broken"
    printf 'if then fi (\n' > "$broken/push-dest-id.sh"
    recovery_script "$script" "$clone" "$broken" unused 1 1
    run_fresh "$script"
    ck "syntax error stops" eq "$R_RC" 1
    { cat "$REPO_ROOT/scripts/lib/push-dest-id.sh"; printf '\nunset -f _bd890_endpoint_matches_pr\n'; } > "$broken/push-dest-id.sh"
    recovery_script "$script" "$clone" "$broken" unused 1 1
    run_fresh "$script"
    ck "missing helper stops" eq "$R_RC" 1
    ck "missing helper named" has "$R_OUT" "helper _bd890_endpoint_matches_pr missing"

    local other="$SANDBOX_ROOT/other-clone"
    new_clone "$other"
    recovery_script "$script" "$other" "$LIBROOT" unused 1 1
    sed -i.bak "s|^bd_gcd=.*|bd_gcd=$(printf '%q' "$clone/.git")|" "$script"
    run_fresh "$script"
    ck "wrong clone stops" has "$R_OUT" "not the clone that ran the grind"

    local hb="$SANDBOX_ROOT/h5"; mkdir -p "$hb"
    local hclone="$hb/c'\$(touch PWNED5) y" hlib="$hb/l'\$(touch PWNED5) z/scripts/lib"
    new_clone "$hclone"; mkdir -p "$hlib"; cp "$REPO_ROOT/scripts/lib/push-dest-id.sh" "$hlib/"
    recovery_script "$script" "$hclone" "$hlib" unused 1 1
    run_fresh "$script"
    ck "hostile paths ok" eq "$R_RC" 0
    ck "PWNED5 never created" eq "$(find "$SANDBOX_ROOT" -name PWNED5 | wc -l | tr -d ' ')" 0
}

# write_envelope <clone> <pr> <category> <reason> → ENV_NAME
write_envelope() {
    local gcd f
    gcd=$(git -C "$1" rev-parse --path-format=absolute --git-common-dir)
    f=$(mktemp "$gcd/pr-grind-bail-$2.XXXXXX")
    jq -nc --arg c "$3" --arg r "$4" '{bail_category: $c, bail_reason: $r}' > "$f"
    ENV_NAME=${f##*/}
}

step1() {   # step1 <clone> <pr> <category> <reason> [<pr being recovered>] → steps 0+1(+validation)
    local script="$SANDBOX_ROOT/s1.sh"
    rm -f "$SANDBOX_ROOT/trace1"
    write_envelope "$1" "$2" "$3" "$4"
    recovery_script "$script" "$1" "$LIBROOT" "$ENV_NAME" "${5:-$2}" 1 2 3
    printf '\necho "dup=$dup extra=$extra class=$bd_class"\n' >> "$script"
    run_fresh "$script" "$SANDBOX_ROOT/trace1"
}

test_recovery_step1() {
    local clone="$SANDBOX_ROOT/s1clone" sha key
    new_clone "$clone"
    sha=$(git -C "$clone" rev-parse refs/heads/main)
    local good="full_ref=refs/heads/main NEW_COMMIT_SHA=$sha pr_number=4 push_dest_id=github.com/o/r push_repo_id=github.com/o/r pre_push_tip= tip_lookup=skipped"
    step1 "$clone" 4 judgment "git push non-fast-forward; local commit preserved: ! [rejected] (fetch first) [$good]"
    ck "valid history" eq "$R_RC" 0
    ck "valid history class" has "$R_OUT" "dup=0 extra=0 class=history"

    for key in "full_ref=refs/heads/main" "NEW_COMMIT_SHA=$sha" "pr_number=4" "push_repo_id=x" \
               "push_dest_id=x" "pre_push_tip=" "tip_lookup=skipped"; do
        step1 "$clone" 4 judgment "git push non-fast-forward; local commit preserved: d [$good $key]"
        ck "dup $key" has "$R_OUT" "duplicate or unknown trailer token"
    done
    step1 "$clone" 4 judgment "git push non-fast-forward; local commit preserved: d [$good foo=bar]"
    ck "unknown token" has "$R_OUT" "duplicate or unknown trailer token"

    # A diag that merely CONTAINS another class's prefix never selects it, and a
    # fake earlier [...] group is ignored (the real trailer is the last one).
    step1 "$clone" 4 judgment "git push rejected; local commit preserved: git push non-fast-forward; local commit preserved: [$good]"
    ck "no class from diag" has "$R_OUT" "no recovery row"
    step1 "$clone" 4 judgment "git push non-fast-forward; local commit preserved: x [full_ref=refs/heads/evil NEW_COMMIT_SHA=$sha] y [$good]"
    ck "last group wins" eq "$R_RC" 0

    local d
    for d in -x --detach; do
        git -C "$clone" update-ref "refs/heads/$d" "$sha"
        step1 "$clone" 4 judgment "git push non-fast-forward; local commit preserved: d [${good/refs\/heads\/main/refs/heads/$d}]"
        ck "dash-led $d" has "$R_OUT" "dash-led branch name"
        ck "dash-led $d: no lookup/fetch/switch" eq "$(grep -cE 'ls-remote|fetch|switch' "$SANDBOX_ROOT/trace1" || true)" 0
    done

    step1 "$clone" 4 policy "git push non-fast-forward; local commit preserved: d [$good]"
    ck "bad category" has "$R_OUT" "no recovery row"
    step1 "$clone" 5 judgment "git push non-fast-forward; local commit preserved: d [$good]"
    ck "pr_number mismatch" has "$R_OUT" "row 4: pr_number"
    step1 "$clone" 5 judgment "git push non-fast-forward; local commit preserved: d [$good]" 4
    ck "envelope for another PR" has "$R_OUT" "another PR"
    step1 "$clone" 4 judgment "git push non-fast-forward; local commit preserved: d [${good/NEW_COMMIT_SHA=$sha/NEW_COMMIT_SHA=0000000000000000000000000000000000000000}]"
    ck "stale envelope" has "$R_OUT" "stale envelope"
    step1 "$clone" 4 env "dispatcher-commit-block: branch changed before push ('refs/heads/x' != 'refs/heads/main') [full_ref=refs/heads/main NEW_COMMIT_SHA=$sha pr_number=4 push_dest_id=d push_repo_id=r]"
    ck "drift class" has "$R_OUT" "class=drift"
    step1 "$clone" 4 env "dispatcher-commit-block: branch changed before push ('x' != 'y') [full_ref=refs/heads/main NEW_COMMIT_SHA=$sha pr_number=4 push_dest_id=d push_repo_id=r tip_lookup=failed]"
    ck "drift with tip_lookup" has "$R_OUT" "pre-push bail carries push-attempt tokens"
    step1 "$clone" 4 env "git push auth/network/config: fatal: x [full_ref=refs/heads/main NEW_COMMIT_SHA=$sha pr_number=4 push_dest_id=d push_repo_id=r]"
    ck "push bail without tip_lookup" has "$R_OUT" "pre_push_tip= missing"
    step1 "$clone" 4 env "Grind-PR: is not an exact trailer on the commit (trailer block: x); commit $sha is LOCAL [full_ref=refs/heads/main NEW_COMMIT_SHA=$sha pr_number=4]"
    ck "trailer class with push token" has "$R_OUT" "trailer-class envelope carries push tokens"

    # Basename shapes and file kinds → reason empty → row 4.
    local script="$SANDBOX_ROOT/s1b.sh" name
    for name in "../pr-grind-bail-4.abcdef" "pr-grind-bail-4.ab def" "pr-grind-bail-5.abcdef" "pr-grind-bail-4.zzzzzz"; do
        recovery_script "$script" "$clone" "$LIBROOT" "$name" 4 1 2 3
        run_fresh "$script"
        ck "basename [$name]" has "$R_OUT" "no recovery row"
    done
    local gcd; gcd=$(git -C "$clone" rev-parse --path-format=absolute --git-common-dir)
    write_envelope "$clone" 4 judgment "git push non-fast-forward; local commit preserved: d [$good]"
    mv "$gcd/$ENV_NAME" "$gcd/real-target"; ln -s "$gcd/real-target" "$gcd/$ENV_NAME"
    recovery_script "$script" "$clone" "$LIBROOT" "$ENV_NAME" 4 1 2 3
    run_fresh "$script"
    ck "symlink refused" has "$R_OUT" "no recovery row"
    write_envelope "$clone" 4 judgment "x"
    printf 'not json\n' > "$gcd/$ENV_NAME"
    recovery_script "$script" "$clone" "$LIBROOT" "$ENV_NAME" 4 1 2 3
    run_fresh "$script"
    ck "non-JSON refused" has "$R_OUT" "no recovery row"
}

test_recovery_step5_discard() {
    local clone="$SANDBOX_ROOT/s5clone" bare="$SANDBOX_ROOT/s5.git" pre bad script="$SANDBOX_ROOT/s5.sh"
    new_clone "$clone"
    git init -q --bare -b main "$bare"
    git -C "$clone" push -q "$bare" main
    pre=$(git -C "$clone" rev-parse main)
    printf 'fix\n' >> "$clone/f.txt"; git -C "$clone" commit -qam "fix: unattributed"
    bad=$(git -C "$clone" rev-parse main)
    write_envelope "$clone" 6 env "Grind-PR: is not an exact trailer on the commit (trailer block: ); commit $bad is LOCAL and UNPUSHED on full_ref; a commit-msg hook altered the Grind-PR: trailer. Do NOT push this commit; no HEAD-relative reset. Fix the hook, then follow step 5 (discard) of skills/pr-grind/SKILL.md section Push bail recovery in the clone that still holds the branch, and re-grind [full_ref=refs/heads/main NEW_COMMIT_SHA=$bad]"
    recovery_script "$script" "$clone" "$LIBROOT" "$ENV_NAME" 6 1 2 3 9
    run_fresh "$script"
    ck "discard rc" eq "$R_RC" 0
    ck "full_ref back at pre-commit tip" eq "$(git -C "$clone" rev-parse main)" "$pre"
    ck "remote untouched" eq "$(git -C "$bare" rev-parse main)" "$pre"
    ck "changes kept staged" has "$(git -C "$clone" diff --cached --name-only)" f.txt

    # full_ref moves AFTER step 1 validated it and before step 5 runs → only the
    # compare-and-swap in step 5 can refuse, and the later tip must survive.
    git -C "$clone" commit -qm "fix again"
    local moved later
    moved=$(git -C "$clone" rev-parse main)
    later=$(git -C "$clone" commit-tree "$moved^{tree}" -p "$moved" -m later)
    write_envelope "$clone" 6 env "failed to parse trailers for verification; cannot verify [full_ref=refs/heads/main NEW_COMMIT_SHA=$moved]"
    recovery_script "$script" "$clone" "$LIBROOT" "$ENV_NAME" 6 1 2 3
    printf 'git update-ref refs/heads/main %s\n' "$later" >> "$script"
    recovery_fence 9 >> "$script"
    run_fresh "$script"
    ck "race: step 1 passed" has "$R_OUT" "step 1 ok: class=trailer"
    ck "race: CAS stops" has "$R_OUT" "full_ref moved since the bail"
    ck "race: rc" eq "$R_RC" 1
    ck "race: later tip kept" eq "$(git -C "$clone" rev-parse main)" "$later"
}

# Row 2 (deferred design MEDIUM): after the rebased push, local full_ref must equal
# the remote tip, or the next grind's non-forced Step 0 fetch leaves them diverged.
test_recovery_row2_moves_full_ref_after_push() {
    local clone="$SANDBOX_ROOT/r2clone" other="$SANDBOX_ROOT/r2other" bare="$SANDBOX_ROOT/r2.git"
    local fix tip script="$SANDBOX_ROOT/r2.sh"
    new_clone "$clone"
    git init -q --bare -b main "$bare"
    git -C "$clone" remote add origin "$bare"
    git -C "$clone" push -q origin main
    git clone -q "$bare" "$other"
    git -C "$other" -c user.email=o@e -c user.name=o commit -q --allow-empty -m "someone else"
    git -C "$other" push -q origin main
    tip=$(git -C "$other" rev-parse main)
    printf 'fix\n' >> "$clone/f.txt"
    git -C "$clone" commit -qam "fix: thing" -m "Grind-PR: 8"
    fix=$(git -C "$clone" rev-parse main)
    git -C "$clone" fetch -q origin   # the foreign tip object is local (row 2 (a) skip)
    # A post-checkout hook that fails the detach onto the fix: git has already
    # detached when it reports that failure, so the detach must not run hooks.
    printf '#!/bin/sh\n[ "$2" = "%s" ] && exit 1\nexit 0\n' "$fix" > "$clone/.git/hooks/post-checkout"
    chmod +x "$clone/.git/hooks/post-checkout"
    # The published row-2 fences, with the step-3 push in between (identity and
    # attribution are covered elsewhere; this fixture is about ref state).
    {
        printf 'set -u\nbd_stop() { printf "STOP: %%s\\n" "$1" >&2; exit 1; }\n'
        printf 'cd %q\n' "$clone"
        printf 'full_ref=refs/heads/main NEW_COMMIT_SHA=%s tip=%s\n' "$fix" "$tip"
        recovery_fence 5
        recovery_fence 6
        printf '[ "$(git rev-list --count "$tip..$sha")" = 1 ] || bd_stop count\n'
        printf 'git push -q origin "${sha:?}:${full_ref:?}" || bd_stop push\n'
        recovery_fence 7
        recovery_fence 8
        printf 'echo "sha=$sha"\n'
    } > "$script"
    run_fresh "$script"
    ck "row2 rc" eq "$R_RC" 0
    local sha=${R_OUT##*sha=}
    ck "remote has the rebased fix" eq "$(git -C "$bare" rev-parse main)" "$sha"
    ck "local full_ref follows the push" eq "$(git -C "$clone" rev-parse main)" "$sha"
    ck "back on the branch" eq "$(git -C "$clone" symbolic-ref HEAD)" refs/heads/main
    ck "clean tree" eq "$(git -C "$clone" status --porcelain --untracked-files=no)" ""
    # What Step 0 does next: a non-forced fetch into the branch, then the SHA check.
    git -C "$clone" checkout -q --detach
    ck "next Step 0 fetch succeeds" git -C "$clone" fetch -q origin refs/heads/main:refs/heads/main
    ck "next Step 0 SHA check holds" eq "$(git -C "$clone" rev-parse main)" "$(git -C "$bare" rev-parse main)"
}

# A STOP after the detach — here the post-push compare-and-swap losing a race — must
# still return the clone to its branch: the published bd_stop does the hook-less
# switch itself, so no exit path can leave the clone detached.
test_recovery_row2_stop_after_detach_returns() {
    local clone="$SANDBOX_ROOT/r2s" other="$SANDBOX_ROOT/r2s-other" bare="$SANDBOX_ROOT/r2s.git"
    local fix tip script="$SANDBOX_ROOT/r2s.sh"
    new_clone "$clone"
    git init -q --bare -b main "$bare"
    git -C "$clone" remote add origin "$bare"
    git -C "$clone" push -q origin main
    git clone -q "$bare" "$other"
    git -C "$other" -c user.email=o@e -c user.name=o commit -q --allow-empty -m "someone else"
    git -C "$other" push -q origin main
    tip=$(git -C "$other" rev-parse main)
    printf 'fix\n' >> "$clone/f.txt"
    git -C "$clone" commit -qam "fix: thing" -m "Grind-PR: 8"
    fix=$(git -C "$clone" rev-parse main)
    git -C "$clone" fetch -q origin
    {
        printf 'set -u\n'
        recovery_fence 1 | awk '/^bd_stop\(\) \{/{on=1} on{print} on && /^\}/{exit}'
        printf 'cd %q\n' "$clone"
        printf 'full_ref=refs/heads/main NEW_COMMIT_SHA=%s tip=%s\n' "$fix" "$tip"
        recovery_fence 5
        recovery_fence 6
        printf 'git push -q origin "${sha:?}:${full_ref:?}" || bd_stop push\n'
        printf 'git update-ref refs/heads/main "$tip"   # full_ref moves under the recovery\n'
        recovery_fence 7
        printf 'echo UNREACHABLE\n'
    } > "$script"
    run_fresh "$script"
    ck "stop rc" eq "$R_RC" 1
    ck "stop reason" has "$R_OUT" "full_ref moved during recovery"
    ck "never continued" lacks "$R_OUT" UNREACHABLE
    ck "returned to the branch" eq "$(git -C "$clone" symbolic-ref -q HEAD || echo DETACHED)" refs/heads/main
}

# A rebase conflict on the detached HEAD must abort the rebase and STOP through
# bd_stop, never reach the push: the clone ends back on its branch, at the fix.
test_recovery_row2_conflict_aborts_and_returns() {
    local clone="$SANDBOX_ROOT/r2c" other="$SANDBOX_ROOT/r2c-other" bare="$SANDBOX_ROOT/r2c.git"
    local fix tip script="$SANDBOX_ROOT/r2c.sh"
    new_clone "$clone"
    git init -q --bare -b main "$bare"
    git -C "$clone" remote add origin "$bare"
    git -C "$clone" push -q origin main
    git clone -q "$bare" "$other"
    printf 'theirs\n' >> "$other/f.txt"
    git -C "$other" -c user.email=o@e -c user.name=o commit -qam "someone else"
    git -C "$other" push -q origin main
    tip=$(git -C "$other" rev-parse main)
    printf 'ours\n' >> "$clone/f.txt"
    git -C "$clone" commit -qam "fix: thing" -m "Grind-PR: 8"
    fix=$(git -C "$clone" rev-parse main)
    git -C "$clone" fetch -q origin
    {
        printf 'set -u\n'
        recovery_fence 1 | awk '/^bd_stop\(\) \{/{on=1} on{print} on && /^\}/{exit}'
        printf 'cd %q\n' "$clone"
        printf 'full_ref=refs/heads/main NEW_COMMIT_SHA=%s tip=%s\n' "$fix" "$tip"
        recovery_fence 5
        recovery_fence 6
        printf 'echo UNREACHABLE\n'
    } > "$script"
    run_fresh "$script"
    ck "conflict rc" eq "$R_RC" 1
    ck "conflict reason" has "$R_OUT" "rebase failed (conflict); aborted"
    ck "conflict never continued" lacks "$R_OUT" UNREACHABLE
    ck "conflict: no rebase in progress" eq "$(for d in rebase-merge rebase-apply; do test -e "$(git -C "$clone" rev-parse --path-format=absolute --git-path "$d")" && echo "$d"; done)" ""
    ck "conflict: back on the branch" eq "$(git -C "$clone" symbolic-ref -q HEAD || echo DETACHED)" refs/heads/main
    ck "conflict: full_ref unchanged" eq "$(git -C "$clone" rev-parse main)" "$fix"
    ck "conflict: remote untouched" eq "$(git -C "$bare" rev-parse main)" "$tip"
}

# Exits before the detach never switch (design 7f(ix)).
test_recovery_row2_precondition_does_not_switch() {
    local clone="$SANDBOX_ROOT/r2p" script="$SANDBOX_ROOT/r2p.sh" sha head_before
    new_clone "$clone"
    git -C "$clone" checkout -q -b side
    sha=$(git -C "$clone" rev-parse main)
    printf 'dirty\n' >> "$clone/f.txt"
    head_before=$(git -C "$clone" symbolic-ref HEAD)
    {
        printf 'bd_stop() { printf "STOP: %%s\\n" "$1" >&2; exit 1; }\n'
        printf 'cd %q\nfull_ref=refs/heads/main NEW_COMMIT_SHA=%s tip=%s\n' "$clone" "$sha" "$sha"
        recovery_fence 5
    } > "$script"
    run_fresh "$script"
    ck "dirty tree stops" has "$R_OUT" "tracked changes present"
    ck "HEAD unchanged" eq "$(git -C "$clone" symbolic-ref HEAD)" "$head_before"
}

# --- grep guards (design Success Criteria 8) -----------------------------------

test_recovery_section_text() {
    local sec s
    sec=$(recovery_section)
    for s in 'export GIT_NO_REPLACE_OBJECTS=1' "-c trailer.separators=':'" '--refmap=' \
             'push origin "${NEW_COMMIT_SHA:?}:${full_ref:?}"' '_bd890_read_one_push_url' '--git-common-dir' \
             'rev-list --count' 'switch --detach' 'MERGE_HEAD' 'RECOVERY_LIB_ROOT' 'declare -F' 'bd_stop' \
             'checked_push_url=$_BD890_ONE_URL' '-c rebase.updateRefs=false' '-c core.hooksPath=/dev/null switch -' \
             'git update-ref -m "pr-grind: discard unattributed ${NEW_COMMIT_SHA:?}" "${full_ref:?}"' \
             'git update-ref -m "pr-grind: recovery row 2 pushed ${sha:?}" "${full_ref:?}" "${sha:?}" "${NEW_COMMIT_SHA:?}"' \
             'bash --noprofile --norc'; do
        ck "has: $s" has "$sec" "$s"
    done
    for s in 'count==1' 'RESULT/log' 'grind RESULT' 'CLAUDE_PLUGIN_ROOT' 'SCRIPT_LIB' 'HEAD~1'; do
        ck "section lacks: $s" lacks "$sec" "$s"
    done
    ck "no empty-source refspec in file" eq "$(grep -cE 'push origin "?:' "$SKILL" || true)" 0
}

# eval in a command position, or a nested shell string, inside a ```bash fence.
eval_guard() {   # eval_guard <file> → prints offending fenced lines
    awk '/^```bash$/{on=1; next} /^```$/{on=0} on' "$1" \
        | grep -E '(^|[;&|({!]|\$\(|`|(^|[^[:alnum:]_])(if|then|else|elif|do|while|until|time))[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*((builtin|command|exec)[[:space:]]+)*eval([[:space:]]|;|$)|(^|[^[:alnum:]_])(bash|sh) -c|source <\(' || true
}

test_eval_guard() {
    local fx="$SANDBOX_ROOT/eval-fixture.md" row
    for row in 'eval "$x"' '  eval $y' 'a=1; eval b' 'x && eval y' '$(eval z)' '`eval w`' \
               'builtin eval v' 'command eval u' "bash -c 'true'" \
               'if eval "$x"; then :; fi' 'x=1 eval "$x"' 'while eval y; do :; done' '! eval z' \
               'then eval a' 'X=1 Y=2 command eval b'; do
        printf '```bash\n%s\n```\n' "$row" > "$fx"
        ck "flags: $row" eq "$(eval_guard "$fx" | wc -l | tr -d ' ')" 1
    done
    for row in '# eval in a comment' 'echo "eval"' '_eval_count=1' 'reevaluate'; do
        printf '```bash\n%s\n```\n' "$row" > "$fx"
        ck "passes: $row" eq "$(eval_guard "$fx")" ""
    done
    printf 'revalidation, non-evaluating extraction. There is never `eval` here.\n' > "$fx"
    ck "prose ignored" eq "$(eval_guard "$fx")" ""
    recovery_section > "$fx"
    ck "recovery section clean" eq "$(eval_guard "$fx")" ""
    { printf '```bash\n'; wrapper_block; printf '```\n'; } > "$fx"
    ck "wrapper block clean" eq "$(eval_guard "$fx")" ""
}

test_invocation_and_step0_text() {
    local block step0
    block=$(wrapper_block)
    for s in "PR_HEAD_HOST='<PR_HEAD_HOST" "PR_HEAD_OWNER='<PR_HEAD_OWNER" "PR_HEAD_NAME='<PR_HEAD_NAME" \
             '--git-common-dir' 'mktemp' "printf 'ENVELOPE_FILE=%s\\n' \"\$_bd890_env_file\" >&2" \
             "printf 'RECOVERY_GIT_COMMON_DIR=%q\\n'" "printf 'RECOVERY_CLONE=%q\\n'" "printf 'RECOVERY_LIB_ROOT=%q\\n'" \
             'if ! cat "$_bd890_env_file"'; do
        ck "wrapper has: $s" has "$block" "$s"
    done
    for s in '${PR_HEAD_' '"$PR_HEAD_' '$PR_HEAD_'; do ck "wrapper lacks: $s" lacks "$block" "$s"; done
    step0=$(awk '/^### Step 0: Create Ephemeral Worktree$/{on=1} on && /^### Dispatch a Round/{exit} on' "$SKILL")
    ck "one gh pr view in Step 0" eq "$(printf '%s\n' "$step0" | grep -c 'gh pr view <PR_NUMBER> --json' || true)" 1
    ck "identity call (number)" has "$step0" 'pr-head-identity.sh" --pr-number <PR_NUMBER>)'
    ck "identity call (url)" has "$step0" "--invocation-url '<PR_INVOCATION_URL>'"
    ck "no invocation-url expansion" lacks "$step0" '${PR_INVOCATION_URL'
    ck "contained gh" has "$step0" 'export GH_HOST=github.com; unset GH_REPO; gh pr view <PR_NUMBER> --json baseRefName,headRefName,headRefOid,isCrossRepository,url,headRepositoryOwner,headRepository'
    local bail
    bail=$(awk '/^BAIL:$/{on=1} on && /^```$/{exit} on' "$SKILL")
    for s in ENVELOPE_FILE= RECOVERY_GIT_COMMON_DIR= RECOVERY_CLONE= RECOVERY_LIB_ROOT=; do
        ck "BAIL relays $s" has "$bail" "$s"
    done
}

failed=0
discovered=0
for t in $(declare -F | awk '/ test_/{print $3}' | sort); do
    discovered=$((discovered + 1))
    BAD=0
    if "$t" && [ "$BAD" -eq 0 ]; then
        echo "PASS: $t"
    else
        echo "FAIL: $t"
        failed=1
    fi
done
[ "$discovered" -gt 0 ] || { echo "FAIL: test discovery produced ZERO tests"; exit 1; }
exit "$failed"
