#!/usr/bin/env bash
# Tests for the excluded-only PR auto-pass (#226).
#
# A PR branch whose ENTIRE base...HEAD diff is excluded from review (lockfile /
# rules / manifest-only) was permanently blocked from `gh pr create`: the
# all-excluded auto-pass in run-review-loop.sh wrote only the COMMIT marker
# (litmus-passed.local), which the pre-PR gate intentionally rejects.
#
# Fix: in PR mode that branch now writes a DISTINCT diff-bound + age-bound marker
# `PASS-EXCLUDED-<hash>-<epoch>`, and pre-pr-gate.sh accepts it via the same
# fast-bypass branch (hash == current AND within max-age).
#
# Scenarios:
#   1. Producer (PR mode, excluded-only)  -> writes PASS-EXCLUDED (right hash),
#      logs pr-excluded-only-autopass, and does NOT write litmus-passed.local.
#   2. Gate accepts a fresh PASS-EXCLUDED marker (allow).
#   3. No-escape (hash mismatch): a PASS-EXCLUDED marker bound to an old diff,
#      then the diff changes -> gate blocks.
#   4. No-escape (stale age): a PASS-EXCLUDED marker older than max-age -> blocks.
#   5. Producer (commit mode, excluded-only) -> still writes litmus-passed.local.
#   6. Producer (PR mode, MIXED diff) -> does NOT write PASS-EXCLUDED (the
#      short-circuit is not taken; the safety claim "reviewable diffs unaffected").
#
# Producer scenarios run run-review-loop.sh, which calls validate_review_cli and
# validate_state_file BEFORE the all-excluded branch — so they need a resolvable
# `codex` (a PATH stub) and an initialized litmus-state.md (init-review-loop.sh).
# The excluded-only path exits before any review dispatch, so the stub is only
# resolved, never invoked for review.
#
# Usage: bash tests/test-pr-excluded-only-autopass.sh
# Exit: 0 if all pass, 1 if any fail.

set -euo pipefail
cd "$(dirname "$0")/.."

export BUSDRIVER_STATE_DIR=.claude

REPO_ROOT="$(pwd)"
GATE_SCRIPT="$REPO_ROOT/hooks/gate-scripts/pre-pr-gate.sh"
LOOP_SCRIPT="$REPO_ROOT/skills/litmus/scripts/run-review-loop.sh"
INIT_SCRIPT="$REPO_ROOT/skills/litmus/scripts/init-review-loop.sh"

PASS=0
FAIL=0
TOTAL=0

check() {
    local name="$1" expected="$2" got="$3"
    TOTAL=$((TOTAL + 1))
    if [[ "$got" == "$expected" ]]; then
        printf "  PASS  %s\n" "$name"
        PASS=$((PASS + 1))
    else
        printf "  FAIL  %s (expected=%s got=%s)\n" "$name" "$expected" "$got"
        FAIL=$((FAIL + 1))
    fi
}

sha256() { (sha256sum 2>/dev/null || shasum -a 256) | cut -d' ' -f1; }

# ── Temp repo + fake-codex stub ───────────────────────────────────────
TMPREPO=$(mktemp -d 2>/dev/null || mktemp -d -t prexcl)
STUBDIR=$(mktemp -d 2>/dev/null || mktemp -d -t prexclstub)
# shellcheck disable=SC2329  # invoked indirectly via trap
cleanup() { rm -rf "$TMPREPO" "$STUBDIR" 2>/dev/null || true; }
trap cleanup EXIT

# Fake codex: satisfies `command -v codex` + version probes; logs any review
# invocation so we can prove the excluded-only path never dispatched it.
STUB_LOG="$STUBDIR/codex-invocations.log"
: > "$STUB_LOG"
cat > "$STUBDIR/codex" <<EOF
#!/bin/sh
case "\$1" in --version|-V|version) echo "codex 0.0.0 (fake)"; exit 0;; esac
echo "invoked: \$*" >> "$STUB_LOG"
exit 0
EOF
chmod +x "$STUBDIR/codex"

git -C "$TMPREPO" init -q
git -C "$TMPREPO" config user.email "test@example.com"
git -C "$TMPREPO" config user.name "Test"
# review-exclude: rules/**/*.md is a PROJECT pattern (not a hardcoded default).
mkdir -p "$TMPREPO/.claude"
printf 'rules/**/*.md\n' > "$TMPREPO/.claude/review-exclude"
echo "hello" > "$TMPREPO/file.txt"
git -C "$TMPREPO" add file.txt .claude/review-exclude
git -C "$TMPREPO" commit -qm "initial"
# Anchor origin/main = initial commit so base...HEAD is a real, fixed diff.
git -C "$TMPREPO" update-ref refs/remotes/origin/main HEAD
git -C "$TMPREPO" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main

MARKER="$TMPREPO/.claude/pr-review-passed.local"
COMMIT_MARKER="$TMPREPO/.claude/litmus-passed.local"
BYPASS_LOG="$TMPREPO/.claude/bypass-log.jsonl"

run_gate() {
    local input="$1" output exit_code
    output=$(printf '%s' "$input" | env -u SKIP_LITMUS bash "$GATE_SCRIPT" 2>/dev/null) && exit_code=0 || exit_code=$?
    if printf '%s' "$output" | grep -q '"block"'; then echo "block"
    elif [ "$exit_code" -ne 0 ] && [ -z "$output" ]; then echo "crash"
    else echo "allow"; fi
}

gate_input() {
    python3 -c "
import json, sys
print(json.dumps({'tool_name':'Bash','tool_input':{'command':'gh pr create --fill'},'cwd':sys.argv[1]}))
" "$TMPREPO"
}

# Run the producer (run-review-loop.sh) inside the temp repo with the stub on PATH.
# $1 = LITMUS_MODE (pr|commit)
run_producer() {
    local mode="$1"
    ( cd "$TMPREPO" \
        && env PATH="$STUBDIR:$PATH" \
               BUSDRIVER_STATE_DIR=.claude \
               BUSDRIVER_REVIEW_CLI=codex \
               LITMUS_MODE="$mode" \
               LITMUS_PR_BASE=main \
               bash "$INIT_SCRIPT" --force 10 >/dev/null 2>&1
      cd "$TMPREPO" \
        && env PATH="$STUBDIR:$PATH" \
               BUSDRIVER_STATE_DIR=.claude \
               BUSDRIVER_REVIEW_CLI=codex \
               LITMUS_MODE="$mode" \
               LITMUS_PR_BASE=main \
               bash "$LOOP_SCRIPT" >/dev/null 2>&1 ) || true
}

marker_is_excluded() {
    [ -f "$MARKER" ] && grep -qE '^PASS-EXCLUDED-[a-f0-9]{64}-[0-9]+$' "$MARKER" \
        && echo "yes" || echo "no"
}

# ── 1. Producer: excluded-only PR writes PASS-EXCLUDED, not the commit marker ──
rm -f "$MARKER" "$COMMIT_MARKER" "$BYPASS_LOG"
# Nested under rules/ — `rules/**/*.md` matches rules/<dir>/<file>.md (mirrors the
# real repo's rules/common/, rules/typescript/), NOT a top-level rules/*.md.
mkdir -p "$TMPREPO/rules/sub"
printf '# rule\nbody\n' > "$TMPREPO/rules/sub/x.md"
git -C "$TMPREPO" add rules/sub/x.md
git -C "$TMPREPO" commit -qm "rules only"
: > "$STUB_LOG"
run_producer pr
check "excluded-only PR writes a PASS-EXCLUDED marker" "yes" "$(marker_is_excluded)"
check "excluded-only PR does NOT write the commit marker" "absent" \
    "$([ -f "$COMMIT_MARKER" ] && echo present || echo absent)"
check "excluded-only PR does NOT dispatch codex" "no" \
    "$(grep -q '^invoked:' "$STUB_LOG" 2>/dev/null && echo yes || echo no)"
check "bypass-log records pr-excluded-only-autopass" "yes" \
    "$(grep -q 'pr-excluded-only-autopass' "$BYPASS_LOG" 2>/dev/null && echo yes || echo no)"
# Reuse the producer-written hash for the gate cases below — the test must NOT
# reimplement compute_pr_diff_hash (git diff output is config-sensitive). The
# producer↔gate hash agreement is proven by scenario 2 (gate accepts this marker).
PROD_HASH=$(sed -E 's/^PASS-EXCLUDED-([a-f0-9]{64})-[0-9]+$/\1/' "$MARKER" 2>/dev/null || echo "")
check "producer marker carries a 64-hex diff hash" "yes" \
    "$(printf '%s' "$PROD_HASH" | grep -qE '^[a-f0-9]{64}$' && echo yes || echo no)"

# ── 2. Gate accepts the fresh producer marker (proves producer↔gate agree) ──
# HEAD is unchanged since scenario 1, so the producer marker is current + fresh.
check "gate allows on the fresh producer PASS-EXCLUDED marker" "allow" "$(run_gate "$(gate_input)")"

# ── 3. No-escape: stale age (producer hash, old epoch) — done BEFORE mutating HEAD ──
printf 'PASS-EXCLUDED-%s-%s\n' "$PROD_HASH" "$(( $(date +%s) - 4000 ))" > "$MARKER"
check "gate blocks a stale (age>max) PASS-EXCLUDED marker" "block" "$(run_gate "$(gate_input)")"

# ── 4. No-escape: hash mismatch (diff changes after marker) ───────────
printf 'PASS-EXCLUDED-%s-%s\n' "$PROD_HASH" "$(date +%s)" > "$MARKER"
echo "now reviewable" > "$TMPREPO/src.js"
git -C "$TMPREPO" add src.js
git -C "$TMPREPO" commit -qm "add reviewable file"
check "gate blocks PASS-EXCLUDED when diff changed (hash mismatch)" "block" "$(run_gate "$(gate_input)")"

# ── 5. Producer: commit-mode all-excluded still writes litmus-passed.local ──
rm -f "$MARKER" "$COMMIT_MARKER"
# Stage an excluded file (commit mode reviews the staged diff).
printf '# rule2\n' > "$TMPREPO/rules/sub/y.md"
git -C "$TMPREPO" add rules/sub/y.md
run_producer commit
check "commit-mode all-excluded writes litmus-passed.local" "present" \
    "$([ -f "$COMMIT_MARKER" ] && echo present || echo absent)"
git -C "$TMPREPO" commit -qm "rules y" >/dev/null 2>&1 || true

# ── 6. Producer: MIXED diff (excluded + reviewable) does NOT short-circuit ──
rm -f "$MARKER"
printf '# rule3\n' > "$TMPREPO/rules/sub/z.md"
echo "console.log(1)" > "$TMPREPO/app.js"   # reviewable -> diff not excluded-only
git -C "$TMPREPO" add rules/sub/z.md app.js
git -C "$TMPREPO" commit -qm "mixed"
: > "$STUB_LOG"
run_producer pr
check "mixed diff does NOT write a PASS-EXCLUDED marker" "no" "$(marker_is_excluded)"
check "mixed diff dispatches codex review" "yes" \
    "$(grep -q '^invoked:' "$STUB_LOG" 2>/dev/null && echo yes || echo no)"

# ── Summary ───────────────────────────────────────────────────────────
echo ""
echo "  ───────────────────────────────"
echo "  Total: $TOTAL  Pass: $PASS  Fail: $FAIL"
[ "$FAIL" -eq 0 ]
