#!/usr/bin/env bash
# Acceptance tests for scripts/design-clear.sh (#405 / ADR 0017).
#
# The four invariants the issue names:
#   (1) no args  -> lists pending tokens, changes NO state
#   (2) clearing a named token removes exactly that <sha>.<nonce> file, writes
#       one bypass-log event, and leaves every other pending token untouched
#   (3) no confirmation and no --yes -> nothing is deleted
#   (4) the gate still fires for any un-cleared pending doc (weakens nothing)
#
# Usage: bash tests/test-design-clear.sh
# Exit:  0 if all pass, 1 if any fail.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLEAR="$REPO_ROOT/scripts/design-clear.sh"
LIB="$REPO_ROOT/hooks/gate-scripts/lib/resolve-repo-dir.sh"

PASS=0
FAIL=0

ok() { printf "  PASS  %s\n" "$1"; PASS=$((PASS + 1)); }
no() { printf "  FAIL  %s\n        %s\n" "$1" "${2:-}"; FAIL=$((FAIL + 1)); }

check() {  # <name> <expected> <actual>
  if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "expected: $2 / actual: $3"; fi
}

command -v git >/dev/null 2>&1 || { echo "SKIP: git not available"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 not available"; exit 0; }

# ── Fixture: a throwaway repo with two armed design docs ──────────────────────
# The suite runs without `set -e`, so an unchecked fixture failure would leave
# TMP empty, point REPO at /repo, and produce dozens of misleading assertion
# failures instead of naming the real problem. Check each setup step.
TMP="$(mktemp -d)" || { echo "ERROR: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT
REPO="$TMP/repo"
mkdir -p "$REPO/docs/plans" || { echo "ERROR: fixture mkdir failed" >&2; exit 1; }
git init -q "$REPO" || { echo "ERROR: fixture git init failed" >&2; exit 1; }
git -C "$REPO" config user.email t@t.t
git -C "$REPO" config user.name t
: >"$REPO/docs/plans/alpha-design.md"
: >"$REPO/docs/plans/beta-design.md"
: >"$REPO/docs/plans/gamma-design.md"
: >"$REPO/docs/plans/delta-design.md"
git -C "$REPO" add -A >/dev/null 2>&1 || { echo "ERROR: fixture git add failed" >&2; exit 1; }
git -C "$REPO" commit -qm init >/dev/null 2>&1 || { echo "ERROR: fixture commit failed" >&2; exit 1; }

# Run a gate-lib function inside the fixture repo (one place that sources $LIB,
# so the shellcheck source directive lives in exactly one spot).
in_repo() {
  (
    cd "$REPO" || exit 2
    # shellcheck source=hooks/gate-scripts/lib/resolve-repo-dir.sh
    source "$LIB"
    "$@"
  )
}

arm() { in_repo gate_marker_arm "$1"; }

# Run $CLEAR with NO controlling terminal, deterministically, whether or not the
# suite itself was started from a tty (setsid detaches; stdin redirection does
# not — the child would inherit /dev/tty and could block on real input).
no_tty_run() {
  python3 -c '
import os, subprocess, sys
p = subprocess.run(sys.argv[1:], cwd=os.environ["REPO"], start_new_session=True,
                   stdin=subprocess.DEVNULL, capture_output=True, text=True)
sys.stdout.write(p.stdout + p.stderr)
sys.exit(p.returncode)
' "$CLEAR" "$@"
}

# Run $CLEAR attached to a real PTY and answer the prompt, so the confirm and
# decline branches are actually exercised instead of short-circuiting at the
# no-terminal guard. pty.fork() is the portable primitive here: it setsid()s the
# child AND makes the pty its CONTROLLING terminal, which is what /dev/tty
# resolves to. (Inheriting an already-open slave fd across start_new_session
# happens to work on macOS but is not guaranteed — notably not on Linux CI.)
tty_run() {   # <answer> <args...>
  ANSWER="$1"; shift
  ANSWER="$ANSWER" python3 -c '
import os, pty, sys

answer = (os.environ["ANSWER"] + "\n").encode()
pid, master = pty.fork()
if pid == 0:                          # child: owns the pty as its ctty
    os.chdir(os.environ["REPO"])
    os.execv(sys.argv[1], sys.argv[1:])
    os._exit(127)
os.write(master, answer)
chunks = []
try:
    while True:
        data = os.read(master, 4096)
        if not data:
            break
        chunks.append(data)
except OSError:
    pass                              # EIO when the child closes the pty
_, status = os.waitpid(pid, 0)
os.close(master)
sys.stdout.buffer.write(b"".join(chunks))
sys.exit(os.waitstatus_to_exitcode(status))
' "$CLEAR" "$@"
}
export REPO
tokens() { find "$MARKER_DIR" -type f 2>/dev/null | sort; }
token_count() { tokens | grep -c . || true; }

arm "$REPO/docs/plans/alpha-design.md"
arm "$REPO/docs/plans/beta-design.md"
MARKER_DIR="$(in_repo gate_marker_dir "$REPO")"
check "fixture: two tokens armed" "2" "$(token_count)"

# ── (1) No args lists and changes nothing ─────────────────────────────────────
BEFORE="$(tokens)"
OUT="$( cd "$REPO" && "$CLEAR" 2>&1 )"; RC=$?
check "list: exit 0" "0" "$RC"
check "list: state unchanged" "$BEFORE" "$(tokens)"
case "$OUT" in
  *alpha-design.md*beta-design.md*|*beta-design.md*alpha-design.md*) ok "list: names both docs" ;;
  *) no "list: names both docs" "$OUT" ;;
esac

# ── (3) No confirmation and no --yes -> no deletion ───────────────────────────
# stdin is /dev/null and the confirm reads /dev/tty; under a non-interactive
# runner there is no tty, so the helper must refuse rather than proceed.
OUT="$(no_tty_run 1 2>&1)"; RC=$?
if [ "$RC" -eq 0 ]; then
  no "no-confirm: refuses" "exited 0 — it went ahead: $OUT"
else
  ok "no-confirm: refuses"
fi
case "$OUT" in
  *"no terminal to confirm on"*) ok "no-confirm: hits the no-terminal guard" ;;
  *) no "no-confirm: hits the no-terminal guard" "$OUT" ;;
esac
check "no-confirm: nothing deleted" "2" "$(token_count)"

# Answering "n" at a REAL prompt must abort. Driven over a PTY so the decline
# branch is genuinely reached rather than short-circuiting at the tty guard.
OUT="$(tty_run n 1 2>&1)"; RC=$?
if [ "$RC" -eq 0 ]; then no "decline: aborts" "exited 0: $OUT"; else ok "decline: aborts"; fi
case "$OUT" in
  *"Aborted"*) ok "decline: reached the prompt and declined" ;;
  *) no "decline: reached the prompt and declined" "$OUT" ;;
esac
check "decline: nothing deleted" "2" "$(token_count)"

# ...and answering "y" at that same prompt clears, recording confirmed:tty.

# ── (2) Clearing a named token removes exactly it, and logs ───────────────────
ALPHA_TOKEN="$(grep -rl "alpha-design.md" "$MARKER_DIR" 2>/dev/null | head -1)"
BETA_TOKEN="$(grep -rl "beta-design.md" "$MARKER_DIR" 2>/dev/null | head -1)"
OUT="$( cd "$REPO" && "$CLEAR" "$REPO/docs/plans/alpha-design.md" --yes 2>&1 )"; RC=$?
check "clear: exit 0" "0" "$RC"
check "clear: one token left" "1" "$(token_count)"
[ ! -e "$ALPHA_TOKEN" ] && ok "clear: named token gone" || no "clear: named token gone" "$ALPHA_TOKEN still present"
[ -e "$BETA_TOKEN" ] && ok "clear: other token untouched" || no "clear: other token untouched" "$BETA_TOKEN was removed"

LOG="$REPO/.claude/bypass-log.jsonl"
if [ -f "$LOG" ]; then
  check "audit: exactly one event" "1" "$(grep -c 'design-marker-cleared' "$LOG" || true)"
  if python3 -S -c '
import json, sys
line = [l for l in open(sys.argv[1]) if "design-marker-cleared" in l][-1]
r = json.loads(line)
assert r["event"] == "design-marker-cleared", r
assert r["doc"].endswith("alpha-design.md"), r
assert len(r["token_sha"]) == 64, r
assert "ts" in r and "head" in r, r
' "$LOG" 2>/dev/null; then
    ok "audit: event is well-formed JSON with doc+token_sha+ts+head"
  else
    no "audit: event is well-formed" "$(tail -1 "$LOG")"
  fi
else
  no "audit: bypass-log written" "$LOG missing"
fi

# ── (4) The gate still fires for the un-cleared doc ───────────────────────────
in_repo gate_marker_pending "$REPO" >/dev/null 2>&1; RC=$?
check "gate: still pending after clearing one" "1" "$RC"

# And returns to clean only once the LAST token is released.
( cd "$REPO" && "$CLEAR" "$REPO/docs/plans/beta-design.md" --yes >/dev/null 2>&1 )
in_repo gate_marker_pending "$REPO" >/dev/null 2>&1; RC=$?
check "gate: clean after clearing all" "0" "$RC"
check "audit: second clear also logged" "2" "$(grep -c 'design-marker-cleared' "$LOG" || true)"

# ── Selector safety ───────────────────────────────────────────────────────────
arm "$REPO/docs/plans/alpha-design.md"
OUT="$( cd "$REPO" && "$CLEAR" 99 2>&1 )"; RC=$?
if [ "$RC" -eq 0 ]; then no "selector: out-of-range refused" "exited 0"; else ok "selector: out-of-range refused"; fi
check "selector: no deletion on bad index" "1" "$(token_count)"

OUT="$( cd "$REPO" && "$CLEAR" 1 2 2>&1 )"; RC=$?
check "selector: two selectors rejected (exit 2)" "2" "$RC"
check "selector: no deletion on double selector" "1" "$(token_count)"

# ── Unvalidated markers are NOT clearable ─────────────────────────────────────
# _classify_tokens emits kind="token" for stray/truncated files too, with an
# EMPTY doc_path — gating on kind alone would let an index selector delete a
# fail-CLOSED marker whose subject is unknown.
STRAY="$MARKER_DIR/not-a-valid-token-name"
: >"$STRAY"
OUT="$( cd "$REPO" && "$CLEAR" 2>&1 )"
case "$OUT" in
  *unparseable*) ok "unvalidated: listed as unparseable" ;;
  *) no "unvalidated: listed as unparseable" "$OUT" ;;
esac
# The stray sorts unpredictably, so find its index from the listing.
IDX="$( cd "$REPO" && "$CLEAR" 2>/dev/null | grep -B1 "token: $STRAY" | grep -o '^  \[[0-9]*\]' | tr -dc '0-9' )"
OUT="$( cd "$REPO" && printf 'y\n' | "$CLEAR" "$IDX" 2>&1 )"; RC=$?
if [ "$RC" -eq 0 ]; then no "unvalidated: refuses to clear" "exited 0"; else ok "unvalidated: refuses to clear"; fi
[ -e "$STRAY" ] && ok "unvalidated: stray file untouched" || no "unvalidated: stray file untouched" "deleted"
check "unvalidated: no audit event for the refusal" "2" "$(grep -c 'design-marker-cleared' "$LOG" || true)"
rm -f "$STRAY"

# ── Audit-before-unlink: an unwritable log REFUSES the clear ──────────────────
# ADR 0017 promises a durable record; a failed append must not yield a silent,
# unlogged release. Make the log path unwritable and prove nothing is deleted.
BEFORE="$(token_count)"
chmod 0444 "$LOG" 2>/dev/null || true
if [ -w "$LOG" ]; then
  printf "  SKIP  audit-refusal (running as root — log stayed writable)\n"
else
  OUT="$( cd "$REPO" && "$CLEAR" "$REPO/docs/plans/alpha-design.md" --yes 2>&1 )"; RC=$?
  check "audit-refusal: exits 2" "2" "$RC"
  check "audit-refusal: nothing deleted" "$BEFORE" "$(token_count)"
  case "$OUT" in
    *REFUSING*) ok "audit-refusal: says why" ;;
    *) no "audit-refusal: says why" "$OUT" ;;
  esac
fi
chmod 0644 "$LOG" 2>/dev/null || true

# ── Index selectors are refused under --yes ──────────────────────────────────
# An index is a position in an unsorted listing; --yes skips the prompt that
# would name the doc, so a concurrent arming could slide a different token under
# the same number and release the wrong review unattended.
BEFORE="$(token_count)"
OUT="$( cd "$REPO" && "$CLEAR" 1 --yes 2>&1 )"; RC=$?
check "index+--yes: exits 2" "2" "$RC"
check "index+--yes: nothing deleted" "$BEFORE" "$(token_count)"
case "$OUT" in
  *"Name the design doc"*) ok "index+--yes: points at the doc-path form" ;;
  *) no "index+--yes: points at the doc-path form" "$OUT" ;;
esac

# ── A symlinked audit log is refused, not followed ────────────────────────────
# .claude/ is repo-controlled, so a plain append would follow a symlink and
# redirect the trail to another writable file while the clear still succeeded.
DECOY="$TMP/decoy.jsonl"
: >"$DECOY"
rm -f "$LOG"
ln -s "$DECOY" "$LOG"
BEFORE="$(token_count)"
OUT="$( cd "$REPO" && "$CLEAR" "$REPO/docs/plans/alpha-design.md" --yes 2>&1 )"; RC=$?
check "symlinked-log: exits 2" "2" "$RC"
check "symlinked-log: nothing deleted" "$BEFORE" "$(token_count)"
check "symlinked-log: decoy target untouched" "0" "$(grep -c . "$DECOY" || true)"
rm -f "$LOG"

# ── The audit event records HOW the release was authorized ────────────────────
OUT="$( cd "$REPO" && "$CLEAR" "$REPO/docs/plans/alpha-design.md" --yes 2>&1 )"; RC=$?
check "confirm-mode: clear succeeds" "0" "$RC"
if python3 -S -c '
import json, sys
r = json.loads([l for l in open(sys.argv[1]) if "design-marker-cleared" in l][-1])
# No controlling terminal under the test runner + --yes => the unattended
# fingerprint, exactly. Accepting "assumed-yes" here would hide a broken probe.
assert r["confirmed"] == "no-tty-assumed-yes", r
' "$LOG" 2>/dev/null; then
  ok "confirm-mode: event records the --yes authorization"
else
  no "confirm-mode: event records the --yes authorization" "$(tail -1 "$LOG")"
fi

# ── A symlinked INTERMEDIATE state-dir component is refused ───────────────────
# STATE_DIR may be nested (a/b). A shell `mkdir -p` plus O_NOFOLLOW on only the
# final component would let a symlinked intermediate redirect the audit log
# outside the repo — clear succeeds, documented path stays empty.
arm "$REPO/docs/plans/alpha-design.md"   # the confirm-mode case cleared it
OUTSIDE="$TMP/outside"
mkdir -p "$OUTSIDE"

# The audit destination is pinned to .claude/ and must NOT follow a caller-set
# BUSDRIVER_STATE_DIR — otherwise a clear could land its only record somewhere
# nobody monitors while still deleting the shared token.
rm -rf "$REPO/elsewhere"
EVENTS_BEFORE="$(grep -c 'design-marker-cleared' "$LOG" || true)"
OUT="$( cd "$REPO" && BUSDRIVER_STATE_DIR=elsewhere "$CLEAR" "$REPO/docs/plans/alpha-design.md" --yes 2>&1 )"; RC=$?
check "pinned-log: clear still succeeds" "0" "$RC"
check "pinned-log: no log at the caller-chosen path" "0" \
  "$(find "$REPO/elsewhere" -name bypass-log.jsonl 2>/dev/null | grep -c . || true)"
check "pinned-log: event landed in .claude" "$(( EVENTS_BEFORE + 1 ))" "$(grep -c 'design-marker-cleared' "$LOG" || true)"

# A symlinked .claude/ must not redirect the append outside the repo.
arm "$REPO/docs/plans/alpha-design.md"
mv "$REPO/.claude" "$REPO/.claude-real"
ln -s "$OUTSIDE" "$REPO/.claude"
BEFORE="$(token_count)"
OUT="$( cd "$REPO" && "$CLEAR" "$REPO/docs/plans/alpha-design.md" --yes 2>&1 )"; RC=$?
check "symlinked-statedir: exits 2" "2" "$RC"
check "symlinked-statedir: nothing deleted" "$BEFORE" "$(token_count)"
check "symlinked-statedir: no log written outside repo" "0" \
  "$(find "$OUTSIDE" -name bypass-log.jsonl 2>/dev/null | grep -c . || true)"
rm -f "$REPO/.claude"
mv "$REPO/.claude-real" "$REPO/.claude"

# ── A torn trailing line in the log is refused, not compounded ────────────────
# Appending onto a fragment would concatenate into a single invalid JSONL line,
# so a partial write must poison the next clear rather than be papered over.
arm "$REPO/docs/plans/beta-design.md"
printf '{"event":"design-marker-cleared","truncated' >>"$LOG"
BEFORE="$(token_count)"
OUT="$( cd "$REPO" && "$CLEAR" "$REPO/docs/plans/beta-design.md" --yes 2>&1 )"; RC=$?
check "torn-log: exits 2" "2" "$RC"
check "torn-log: nothing deleted" "$BEFORE" "$(token_count)"
check "torn-log: fragment not appended to" "1" \
  "$(tail -c 200 "$LOG" | grep -c 'truncated$' || true)"
# Repair it: the guard is working as designed, so leaving the fragment would
# (correctly) refuse every later case in this suite.
python3 -c '
import sys
p = sys.argv[1]
data = open(p, "rb").read()
open(p, "wb").write(data[:data.rfind(b"\n") + 1])
' "$LOG"

# ── A real tty confirm clears and is recorded as tty-confirmed ────────────────
arm "$REPO/docs/plans/gamma-design.md"
EVENTS_BEFORE="$(grep -c 'design-marker-cleared' "$LOG" || true)"
OUT="$(tty_run y "$REPO/docs/plans/gamma-design.md" 2>&1)"; RC=$?
check "tty-confirm: exits 0" "0" "$RC"
check "tty-confirm: event appended" "$(( EVENTS_BEFORE + 1 ))" \
  "$(grep -c 'design-marker-cleared' "$LOG" || true)"
if python3 -S -c '
import json, sys
r = json.loads([l for l in open(sys.argv[1]) if "design-marker-cleared" in l][-1])
assert r["confirmed"] == "tty", r
' "$LOG" 2>/dev/null; then
  ok "tty-confirm: recorded as confirmed:tty"
else
  no "tty-confirm: recorded as confirmed:tty" "$(tail -1 "$LOG")"
fi

# ── A clear from a LINKED worktree audits to the canonical root ───────────────
# The token lives in the shared git common-dir, so a release recorded only in a
# throwaway worktree's .claude/ would vanish with that worktree. The log must
# anchor to the main worktree root.
if git -C "$REPO" worktree add -q "$TMP/linked" -b linked-branch 2>/dev/null; then
  arm "$REPO/docs/plans/delta-design.md"
  EVENTS_BEFORE="$(grep -c 'design-marker-cleared' "$LOG" || true)"
  OUT="$( cd "$TMP/linked" && "$CLEAR" "$REPO/docs/plans/delta-design.md" --yes 2>&1 )"; RC=$?
  check "linked-worktree: clear succeeds" "0" "$RC"
  check "linked-worktree: event landed in the canonical log" "$(( EVENTS_BEFORE + 1 ))" \
    "$(grep -c 'design-marker-cleared' "$LOG" || true)"
  check "linked-worktree: no log stranded in the linked worktree" "0" \
    "$(find "$TMP/linked/.claude" -name bypass-log.jsonl 2>/dev/null | grep -c . || true)"
else
  printf "  SKIP  linked-worktree (git worktree add unavailable)\n"
fi

# ── --separate-git-dir: the audit log follows the WORKTREE, not the git dir ───
# dirname(--git-common-dir) would name the git dir's parent, which is not the
# worktree at all when the git dir was placed elsewhere.
SEP="$TMP/sep"
mkdir -p "$SEP/work/docs/plans" "$SEP/gitdir"
if git init -q --separate-git-dir "$SEP/gitdir" "$SEP/work" 2>/dev/null; then
  git -C "$SEP/work" config user.email t@t.t
  git -C "$SEP/work" config user.name t
  : >"$SEP/work/docs/plans/sep-design.md"
  git -C "$SEP/work" add -A >/dev/null 2>&1
  git -C "$SEP/work" commit -qm init >/dev/null 2>&1
  sep_arm() (
    cd "$SEP/work" || exit 2
    # shellcheck source=hooks/gate-scripts/lib/resolve-repo-dir.sh
    source "$LIB"
    gate_marker_arm "$SEP/work/docs/plans/sep-design.md"
  )
  sep_arm
  OUT="$( cd "$SEP/work" && "$CLEAR" "$SEP/work/docs/plans/sep-design.md" --yes 2>&1 )"; RC=$?
  check "separate-git-dir: clear succeeds" "0" "$RC"
  check "separate-git-dir: log in the worktree" "1" \
    "$(grep -c 'design-marker-cleared' "$SEP/work/.claude/bypass-log.jsonl" 2>/dev/null || true)"
  check "separate-git-dir: no log beside the git dir" "0" \
    "$(find "$SEP/gitdir" -name bypass-log.jsonl 2>/dev/null | grep -c . || true)"
else
  printf "  SKIP  separate-git-dir (unsupported by this git)\n"
fi

printf "\n%d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
