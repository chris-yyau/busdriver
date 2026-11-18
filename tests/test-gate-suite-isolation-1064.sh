#!/usr/bin/env bash
# test-gate-suite-isolation-1064.sh — gate suites see fixture state only (#1064).
#
# The pre-implementation gate reads its skip file, its lease ledger and (without
# python3) its pending-marker probe from its PROCESS cwd. Suites that ran from the
# checkout's root therefore spent the operator's live design-review lease and failed on
# that checkout's pending design tokens. tests/lib/gate-cwd-isolation.sh moves a suite
# into an empty scratch dir; this pins that every gate suite uses it, and that a run
# from a repo holding a live lease and a pending token leaves both untouched.
set -uo pipefail
. "$(dirname "$0")/lib/git-env-isolation.sh" || exit 1
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SELF="$(basename "$0")"

PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); echo "  ok    $1"; }
no() { FAIL=$((FAIL + 1)); echo "  FAIL  $1${2:+ :: $2}"; }

# Suites that run from the repo root but feed every gate call its own fixture cwd, and
# lean on root-relative paths too heavily to move. Both spent 0 lease slots and passed in
# a leased checkout; the dynamic section below re-proves the fast one on every run.
#   test-impl-gate-scope-519.sh        — ~450s, too slow to re-run here
#   test-pre-impl-deliberation-exempt.sh — re-run below
EXEMPT=" test-impl-gate-scope-519.sh test-pre-impl-deliberation-exempt.sh "

echo "── static: every gate suite sources the isolation helper ──"
for f in "$ROOT"/tests/test-*.sh; do
    [ "$(basename "$f")" = "$SELF" ] && continue
    grep -q 'pre-implementation-gate' "$f" || continue
    case "$EXEMPT" in *" $(basename "$f") "*) continue ;; esac
    if grep -q '^\. "\$[A-Z_]*/tests/lib/gate-cwd-isolation\.sh" || exit 1' "$f"; then
        ok "$(basename "$f") sources gate-cwd-isolation.sh"
    else
        no "$(basename "$f") runs the gate but does not source tests/lib/gate-cwd-isolation.sh"
    fi
done

echo "── dynamic: a live lease and a pending token in the suites' own checkout ──"
# The suites cd to their own root, so the leased repo must BE that root: copy this
# checkout's files (working tree, so local edits are what runs) into a fresh repo.
# Untracked, non-ignored files are copied on purpose: they are the local edits under test.
# Only regular files and symlinks are listed: tar recurses into a listed directory (a
# submodule, or a file replaced by a directory), which would pull in ignored content and
# a .git file pointing back at this checkout. Deleted, unstaged paths drop out the same way.
OUTER="$(mktemp -d)"
trap 'rm -rf "$OUTER"' EXIT
unset BUSDRIVER_STATE_DIR   # the gates and the snapshot must both mean .claude
(cd "$ROOT" && git ls-files -z -co --exclude-standard \
    | while IFS= read -r -d '' p; do
          if [ -L "$p" ] || [ -f "$p" ]; then printf '%s\0' "$p"; fi
      done \
    | tar --null -T - -cf -) \
    | tar -xf - -C "$OUTER" \
    && git init -q "$OUTER" \
    && git -C "$OUTER" -c core.hooksPath=/dev/null add -A \
    && git -C "$OUTER" -c core.hooksPath=/dev/null -c commit.gpgsign=false \
           -c user.name=t -c user.email=t@t commit -q -m copy \
    || { no "copying the checkout into a scratch repo"; exit 1; }
# The copy can carry symlinks: never write a fixture file through one.
for d in .claude docs docs/plans; do
    [ ! -L "$OUTER/$d" ] || { no "fixture dir $d is a symlink in the copy"; exit 1; }
done
mkdir -p "$OUTER/.claude" "$OUTER/docs/plans"
rm -f "$OUTER/docs/plans/outer-plan.md" "$OUTER/.claude/skip-design-review.local"
printf '# plan\n' > "$OUTER/docs/plans/outer-plan.md"
# Arm it, and record the exact marker dir the gate resolves for this repo.
MARKER_DIR="$(
    cd "$OUTER" || exit 1
    # shellcheck source=../hooks/gate-scripts/lib/resolve-repo-dir.sh
    . "$ROOT/hooks/gate-scripts/lib/resolve-repo-dir.sh"
    gate_marker_arm "$OUTER/docs/plans/outer-plan.md" >/dev/null || exit 1
    gate_marker_dir "$OUTER/docs/plans"
)" && [ -d "$MARKER_DIR" ] || { no "arming the outer repo's design token"; exit 1; }
# A lease the gate would honour: an operator skip file past its 30s anti-self-bypass age.
: > "$OUTER/.claude/skip-design-review.local"
touch -t "$(date -r "$(( $(date +%s) - 120 ))" +%Y%m%d%H%M.%S 2>/dev/null \
    || date -d @"$(( $(date +%s) - 120 ))" +%Y%m%d%H%M.%S)" "$OUTER/.claude/skip-design-review.local"
mtime() {   # GNU first: GNU `stat -f` is the filesystem form and would succeed with no mtime.
    stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null
}
_skip_mtime=$(mtime "$OUTER/.claude/skip-design-review.local")
[ -n "$_skip_mtime" ] && [ $(( $(date +%s) - _skip_mtime )) -ge 60 ] \
    || { no "backdating the skip file past the 30s anti-self-bypass window"; exit 1; }
[ -n "$(find "$MARKER_DIR" -type f 2>/dev/null)" ] \
    || { no "the outer design token is in the marker dir"; exit 1; }

snapshot() {   # skip-file mtime, lease slots, consumed events, the tokens and their bytes
    local lease="$OUTER/.claude/.skip-design-review-lease.d" log="$OUTER/.claude/bypass-log.jsonl" rc
    mtime "$OUTER/.claude/skip-design-review.local" || echo gone
    if [ -e "$lease" ]; then find "$lease" -mindepth 1 | sort || return 1; fi
    if [ -e "$log" ]; then
        grep -c skip-review-consumed "$log"; rc=$?
        [ "$rc" -le 1 ] || return 1   # 1 = no match (prints 0); 2 = unreadable
    fi
    find "$MARKER_DIR" -type f -exec cksum {} + | sort || return 1
}
before="$(snapshot)" || { no "snapshotting the outer gate state"; exit 1; }

# The two suites that reached each leak on main (lease spend, the "." pending probe),
# plus the fast exempt one.
for t in test-pre-implementation-gate.sh test-gate-classifier-fail-closed.sh \
         test-pre-impl-deliberation-exempt.sh; do
    if (cd "$OUTER" && bash "tests/$t") >/dev/null 2>&1; then
        ok "$t passes in a checkout with a live lease and a pending token"
    else
        no "$t fails in a checkout with a live lease and a pending token"
    fi
done

after="$(snapshot)" || { no "snapshotting the outer gate state after the suites"; exit 1; }
if [ "$before" = "$after" ]; then
    ok "lease, skip file and pending token are untouched"
else
    no "the suites changed the surrounding repo's gate state" "$(diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") | head -5 | tr '\n' ' ')"
fi

echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
