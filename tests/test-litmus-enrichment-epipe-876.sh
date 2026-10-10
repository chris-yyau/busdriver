#!/usr/bin/env bash
# tests/test-litmus-enrichment-epipe-876.sh — enrichment cap must not SIGPIPE (#876).
#
# run-review-loop.sh truncates SMART_CONTEXT_OUTPUT / DOCS_CONTEXT_OUTPUT to
# MAX_ENRICHMENT_LINES before rendering the review prompt. The pre-fix
# `echo "$VAR" | head -n N` aborts under `set -euo pipefail` whenever a context
# exceeds the 64 KiB pipe buffer: head exits after its N lines, the still-writing
# echo takes SIGPIPE, and the whole review dies before the reviewer is ever
# invoked. The fix replaces both pipelines with a here-string — no pipe, no
# producer, no EPIPE — which must also keep REAL cap failures fail-closed
# (a failing head still aborts; `|| true` would have hidden it).
#
# Sandbox pattern follows tests/test-litmus-mode-transition.sh: a throwaway git
# repo with the litmus scripts copied in, a mock `agy` reviewer living OUTSIDE
# the repo, and the context collectors replaced by stubs that emit a controllable
# number of large numbered lines with no pipe of their own.
#
# Usage: bash tests/test-litmus-enrichment-epipe-876.sh
#
# shellcheck disable=SC2034,SC2016,SC2310  # check expressions are eval'd by check(); `RUN || rc=$?` deliberately captures the runner's exit
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${LITMUS_EPIPE_SRC:-$REPO_ROOT}"
# The sandbox runs must not inherit operator litmus/busdriver settings
# (LITMUS_MODE=pr, a custom state dir, budgets...): clear them all up front.
for _v in $(compgen -e); do
    case "$_v" in LITMUS_*|BUSDRIVER_*) unset "$_v" ;; esac
done
PASS=0; FAIL=0
ok()  { printf "  PASS  %s\n" "$1"; PASS=$((PASS + 1)); }
bad() {
    printf "  FAIL  %s\n" "$1"; FAIL=$((FAIL + 1))
    # Show what the runner said last in this sandbox — the checks only see its results.
    [ -s "${S:-}/.mock/run.log" ] && { tail -n 15 "$S/.mock/run.log" | sed 's/^/        | /'; }
    return 0
}
check() { if eval "$2"; then ok "$1"; else bad "$1  [$2]"; fi; }

ROOT=$(mktemp -d) || exit 1
[ -d "$ROOT" ] || exit 1
# The sandbox writes scripts that embed paths under ROOT as shell source; a
# TMPDIR containing quotes, $, backticks, : or spaces would corrupt them, so
# fall back to a plain /tmp root rather than escaping every generated script.
case "$ROOT" in
    *[!A-Za-z0-9._/-]*) rmdir "$ROOT"; ROOT=$(mktemp -d /tmp/epipe876.XXXXXX) || exit 1 ;;
esac
trap 'cd /; rm -rf "$ROOT"' EXIT

ISSUE='{"file":"test_target.txt","line":1,"severity":"high","category":"bug","description":"deterministic epipe-test issue","suggestion":"none","confidence":95}'
# ~80 bytes of padding so each stub line is ~96 B: 5000 lines ≈ 480 KiB, well over
# four times the 64 KiB pipe buffer that triggers the bug.
PAD='xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'

new_sandbox() {
    S=$(mktemp -d "$ROOT/sb.XXXXXX")
    cd "$S" || exit 1
    git init -q .; git config user.email t@t.com; git config user.name t; git config commit.gpgsign false
    mkdir -p .claude .mock skills/litmus/scripts/lib skills/blueprint-review/scripts/lib scripts/lib
    cp -r "$SRC"/skills/litmus/scripts/. skills/litmus/scripts/
    cp -r "$SRC"/scripts/lib/. scripts/lib/
    cp "$SRC/skills/blueprint-review/scripts/lib/extract_review_json.py" skills/blueprint-review/scripts/lib/
    echo base > seed.txt; git add seed.txt; git commit -q -m seed
    echo "test content" > test_target.txt; git add test_target.txt
    echo 5000 > .mock/ctxlines    # stub payload size; cases may shrink it
    echo fail > .mock/mode        # the runner rebuilds its env; mock reads files

    # Context stubs replace the SANDBOX copies of the real collectors — the only
    # functions run-review-loop.sh calls from these libraries. Each prints N
    # numbered ~96-byte lines via a printf loop: no pipe, so the fixture itself
    # can never SIGPIPE.
    cat > skills/litmus/scripts/lib/smart-context.sh <<EOF
collect_smart_context() {
    local i n
    n=\$(cat "$S/.mock/ctxlines" 2>/dev/null || printf '5000')
    case "\$n" in ''|*[!0-9]*) n=5000 ;; esac
    i=1
    while [ "\$i" -le "\$n" ]; do
        printf 'SMARTCTX-%06d $PAD\n' "\$i"
        i=\$((i + 1))
    done
}
EOF
    cat > skills/litmus/scripts/lib/docs-context.sh <<EOF
collect_docs_context() {
    local i n
    n=\$(cat "$S/.mock/ctxlines" 2>/dev/null || printf '5000')
    case "\$n" in ''|*[!0-9]*) n=5000 ;; esac
    i=1
    while [ "\$i" -le "\$n" ]; do
        printf 'DOCSCTX-%06d $PAD\n' "\$i"
        i=\$((i + 1))
    done
}
EOF

    # The mock records what it was shown — stdin AND argv, since the resolved
    # transport may pass the prompt either way — then emits a single-line verdict
    # per .mock/mode. A `--version` probe is CLI resolution, not a review: it must
    # answer and exit WITHOUT creating the capture file.
    mkdir -p "$S.bin"
    cat > "$S.bin/agy" <<MOCK
#!/usr/bin/env bash
if [ "\${1:-}" = "--version" ]; then
    printf 'agy 1.1.4\n'
    exit 0
fi
{ cat; printf '%s\n' "\$@"; } > "$S/.mock/prompt"
if [ "\$(cat "$S/.mock/mode")" = pass ]; then
    printf '%s\n' '{"status":"PASS","issues":[]}'
else
    printf '%s\n' '{"status":"FAIL","issues":[$ISSUE]}'
fi
MOCK
    chmod +x "$S.bin/agy"
}

INIT() { PATH="$S.bin:$PATH" bash "$S/skills/litmus/scripts/init-review-loop.sh" "$@"; }
# The cap assertions expect exactly 100 lines, so pin the budget rather than
# inherit an operator's LITMUS_MAX_ENRICHMENT_LINES.
RUN() {
    PATH="$S.bin:$PATH" BUSDRIVER_REVIEW_CLI=agy CLAUDE_PLUGIN_ROOT="$S" LITMUS_SKIP_SAST=1 \
    LITMUS_SKIP_MARKDOWN=1 LITMUS_SHORTCIRCUIT_DISABLED=1 LITMUS_MAX_ENRICHMENT_LINES=100 \
    bash "$S/skills/litmus/scripts/run-review-loop.sh" >> "$S/.mock/run.log" 2>&1
}
fm() { { grep -E "^$1:" .claude/litmus-state.md 2>/dev/null || true; } | head -1 | sed -E "s/^$1:[[:space:]]*//; s/\"//g"; }

# Fixture self-check: prove the stubs exceed the trigger (>100 lines AND >64 KiB
# after line 100), so a fixture that silently shrank could not go unnoticed.
# Computed through temp files — no pipe that could itself SIGPIPE under pipefail.
stub_check() {  # $1 = lib file name, $2 = collector function
    local out lines tailb
    # shellcheck disable=SC1090  # the stub path is a per-sandbox parameter by design
    out=$(cd "$S" && . "skills/litmus/scripts/lib/$1" && "$2")
    printf '%s\n' "$out" > "$S/.mock/stub-out"
    lines=$(wc -l < "$S/.mock/stub-out")
    tail -n +101 "$S/.mock/stub-out" > "$S/.mock/stub-tail"
    tailb=$(wc -c < "$S/.mock/stub-tail")
    rm -f "$S/.mock/stub-out" "$S/.mock/stub-tail"
    [ "$lines" -gt 100 ] && [ "$tailb" -gt 65536 ]
}

echo "── 0. Fixture self-check: stub payloads exceed the EPIPE trigger"
new_sandbox
check "smart-context stub emits >100 lines and >64 KiB past line 100" 'stub_check smart-context.sh collect_smart_context'
check "docs-context stub emits >100 lines and >64 KiB past line 100" 'stub_check docs-context.sh collect_docs_context'

echo "── 1. Large context reaches the reviewer (regression: unfixed script aborts at the cap)"
new_sandbox
INIT 10 >/dev/null 2>&1
rc=0; RUN || rc=$?
check "reviewer was invoked (capture file exists)" '[ -f .mock/prompt ]'
check "cap kept exactly the first 100 context lines" \
    'grep -q "SMARTCTX-000100" .mock/prompt 2>/dev/null && grep -q "DOCSCTX-000100" .mock/prompt 2>/dev/null && ! grep -q "SMARTCTX-000101" .mock/prompt 2>/dev/null && ! grep -q "DOCSCTX-000101" .mock/prompt 2>/dev/null'
check "run settles on the reviewer verdict" '[ "$rc" = 1 ] && [ "$(fm terminal_status)" = review_findings ]'

# fail_cap_case VAR_NAME — one fail-closed case for the enrichment cap. Rewrites
# the command word of ONLY the named cap assignment in the sandbox copy to a
# shim that logs and exits 3: with the here-string fix the substitution fails
# under set -e before dispatch; an `|| true` variant would swallow it, reach the
# PASS mock, and mint a marker — which is what these assertions pin against.
fail_cap_case() {
    local var="$1"
    new_sandbox
    echo pass > .mock/mode
    SHIM="$S.bin/not-head"
    cat > "$SHIM" <<EOF
#!/usr/bin/env bash
printf 'shim ran\n' >> "$S/.mock/shim.log"
exit 3
EOF
    chmod +x "$SHIM"
    cp skills/litmus/scripts/run-review-loop.sh .mock/runner.orig
    # PATH and exported functions cannot reach the cap — the runner pins
    # /usr/bin:/bin and re-execs under bash -p — so rewrite the command word
    # itself, in the sandbox copy only. Rewrite from .mock/runner.orig rather
    # than an in-place edit; `>` keeps the copy's mode, so the runner stays
    # executable. The shim path comes from TMPDIR, so it is matched and replaced
    # as a literal string (awk index/substr via ENVIRON — no sed metacharacters
    # like & or |) and shell-quoted with %q so spaces or quotes cannot split it.
    rep="$var=\$($(printf '%q' "$SHIM") -n"
    PAT="$var=\$(head -n" REP="$rep" awk '{
        i = index($0, ENVIRON["PAT"])
        if (i) $0 = substr($0, 1, i - 1) ENVIRON["REP"] substr($0, i + length(ENVIRON["PAT"]))
        print
    }' .mock/runner.orig > skills/litmus/scripts/run-review-loop.sh
    changed=$(diff .mock/runner.orig skills/litmus/scripts/run-review-loop.sh | grep -c '^< ' || true)
    newlines=$(diff .mock/runner.orig skills/litmus/scripts/run-review-loop.sh | grep -c '^> ' || true)
    check "rewrite changed exactly one line" '[ "$changed" = 1 ] && [ "$newlines" = 1 ] && [ -x skills/litmus/scripts/run-review-loop.sh ] && grep -qF -- "$rep" skills/litmus/scripts/run-review-loop.sh'
    INIT 10 >/dev/null 2>&1
    rc=0; RUN || rc=$?
    check "failing $var cap aborts the run with the shim's status" '[ "$rc" = 3 ]'
    check "the shim really ran (it is not a dead rewrite)" '[ -f .mock/shim.log ]'
    check "reviewer was never dispatched" '[ ! -f .mock/prompt ]'
    check "no PASS was recorded" '[ ! -e .claude/litmus-passed.local ] && [ -f .claude/litmus-state.md ] && ! grep -q "terminal_status:.*pass" .claude/litmus-state.md'
}

echo "── 2a. A genuinely failing SMART cap stays fail-closed"
fail_cap_case SMART_CONTEXT_OUTPUT

echo "── 2b. A genuinely failing DOCS cap stays fail-closed"
fail_cap_case DOCS_CONTEXT_OUTPUT

echo "── 3. Small context passes through whole"
new_sandbox
echo 20 > .mock/ctxlines
INIT 10 >/dev/null 2>&1
rc=0; RUN || rc=$?
check "all 20 smart-context lines reached the reviewer" 'grep -q "SMARTCTX-000001" .mock/prompt && grep -q "SMARTCTX-000020" .mock/prompt'
check "all 20 docs-context lines reached the reviewer" 'grep -q "DOCSCTX-000001" .mock/prompt && grep -q "DOCSCTX-000020" .mock/prompt'
check "run settles on the reviewer verdict" '[ "$rc" = 1 ] && [ "$(fm terminal_status)" = review_findings ]'

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
