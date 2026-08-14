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
# Via no_tty_run: invoked directly, this inherits the SUITE's controlling
# terminal when someone runs the tests from a real shell, and the script would
# then correctly record "assumed-yes" — making the assertion depend on the
# caller rather than on the product.
OUT="$(no_tty_run "$REPO/docs/plans/alpha-design.md" --yes 2>&1)"; RC=$?
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

# ── --all-for-doc drains every token for ONE named doc (#665) ─────────────────
# Arming is per-EDIT: the token name is <sha(norm-path)>.<nonce> with a random
# nonce and no dedup, so a doc that went through a few review rounds holds many
# tokens. Before #665 that had no non-interactive release at all — the doc-path
# selector refused (">1 match") and --yes refused an index — which pushed the
# operator toward `rm -rf` on the token dir, destroying the audit trail this
# helper exists to guarantee.
doc_tokens() { grep -rl -- "$1" "$MARKER_DIR" 2>/dev/null | grep -c . || true; }

# Delta-based: earlier sections leave alpha armed on purpose (the refusal cases
# must not delete), so a hard-coded count here would assert the suite's history
# rather than this feature.
ALPHA_N=$(( $(doc_tokens alpha-design.md) + 3 ))
arm "$REPO/docs/plans/alpha-design.md"
arm "$REPO/docs/plans/alpha-design.md"
arm "$REPO/docs/plans/alpha-design.md"
check "all-for-doc fixture: one doc, several tokens" "$ALPHA_N" "$(doc_tokens alpha-design.md)"

# The plain doc selector must STILL refuse a multi-token doc — the bulk mode is
# opt-in, never an implicit widening of what `<doc-path>` releases.
OUT="$( cd "$REPO" && "$CLEAR" "$REPO/docs/plans/alpha-design.md" --yes 2>&1 )"; RC=$?
check "multi-token: plain doc selector still refused" "2" "$RC"
check "multi-token: nothing deleted" "$ALPHA_N" "$(doc_tokens alpha-design.md)"
case "$OUT" in
  *--all-for-doc*) ok "multi-token: refusal points at the bulk mode" ;;
  *) no "multi-token: refusal points at the bulk mode" "$OUT" ;;
esac

# An index cannot name a SET, and it shifts between runs — honoring it would
# reinterpret "index 3" as "everything sharing index 3's doc".
OUT="$( cd "$REPO" && "$CLEAR" --all-for-doc 1 2>&1 )"; RC=$?
check "all-for-doc+index: exits 2" "2" "$RC"
check "all-for-doc+index: nothing deleted" "$ALPHA_N" "$(doc_tokens alpha-design.md)"
OUT="$( cd "$REPO" && "$CLEAR" --all-for-doc 2>&1 )"; RC=$?
check "all-for-doc with no doc: exits 2" "2" "$RC"

# One confirmation covers the whole set, and declining it releases nothing.
BEFORE="$(token_count)"
OUT="$(tty_run n --all-for-doc "$REPO/docs/plans/alpha-design.md" 2>&1)"; RC=$?
if [ "$RC" -eq 0 ]; then no "all-for-doc decline: aborts" "exited 0: $OUT"; else ok "all-for-doc decline: aborts"; fi
check "all-for-doc decline: nothing deleted" "$BEFORE" "$(token_count)"
case "$OUT" in
  *"Clear all $ALPHA_N?"*) ok "all-for-doc decline: prompt names the set size" ;;
  *) no "all-for-doc decline: prompt names the set size" "$OUT" ;;
esac

# The drain itself: every token for the named doc goes, nothing else does, and
# the trail keeps one event per released token rather than one summary event.
arm "$REPO/docs/plans/beta-design.md"
BETA_BEFORE="$(doc_tokens beta-design.md)"
EVENTS_BEFORE="$(grep -c 'design-marker-cleared' "$LOG" || true)"
OUT="$(no_tty_run --all-for-doc "$REPO/docs/plans/alpha-design.md" --yes 2>&1)"; RC=$?
check "all-for-doc: exits 0" "0" "$RC"
check "all-for-doc: every token for the named doc released" "0" "$(doc_tokens alpha-design.md)"
check "all-for-doc: the other doc is untouched" "$BETA_BEFORE" "$(doc_tokens beta-design.md)"
check "all-for-doc: one audit event PER token, not one summary" "$(( EVENTS_BEFORE + ALPHA_N ))" \
  "$(grep -c 'design-marker-cleared' "$LOG" || true)"
if python3 -S -c '
import json, sys
evs = [json.loads(l) for l in open(sys.argv[1]) if "design-marker-cleared" in l][-3:]
assert all(e["doc"].endswith("alpha-design.md") for e in evs), evs
assert all(e["confirmed"] == "no-tty-assumed-yes" for e in evs), evs
assert all(len(e["token_sha"]) == 64 for e in evs), evs
' "$LOG" 2>/dev/null; then
  ok "all-for-doc: each event names the doc and how it was authorized"
else
  no "all-for-doc: each event names the doc and how it was authorized" "$(tail -3 "$LOG")"
fi

# An unvalidated marker in the set aborts the WHOLE drain: releasing the healthy
# siblings around it would lift the block while leaving the anomaly armed.
arm "$REPO/docs/plans/alpha-design.md"
arm "$REPO/docs/plans/alpha-design.md"
STRAY="$MARKER_DIR/not-a-valid-token-name"
: >"$STRAY"
BEFORE="$(token_count)"
EVENTS_BEFORE="$(grep -c 'design-marker-cleared' "$LOG" || true)"
OUT="$(no_tty_run --all-for-doc "$REPO/docs/plans/alpha-design.md" --yes 2>&1)"; RC=$?
check "all-for-doc: still drains alongside an unrelated stray" "0" "$RC"
check "all-for-doc: the stray marker is not touched" "1" "$([ -e "$STRAY" ] && echo 1 || echo 0)"
check "all-for-doc: two more events for the two tokens" "$(( EVENTS_BEFORE + 2 ))" \
  "$(grep -c 'design-marker-cleared' "$LOG" || true)"
rm -f "$STRAY"

# ...but a non-token marker bound to the SAME doc aborts the whole drain, before
# anything is released. A legacy list-file marker holds several docs at once, so
# removing it is the blanket wipe this helper exists to refuse — and draining the
# healthy tokens around it would lift the block while the marker stayed armed,
# quietly turning "inspect this" into "already released most of it".
arm "$REPO/docs/plans/alpha-design.md"
arm "$REPO/docs/plans/alpha-design.md"
ALPHA_NORM="$(cat "$(grep -rl 'alpha-design.md' "$MARKER_DIR" | head -1)")"
printf -- '- %s\n' "$ALPHA_NORM" >"$REPO/.claude/design-review-needed.local.md"
BEFORE="$(token_count)"
EVENTS_BEFORE="$(grep -c 'design-marker-cleared' "$LOG" || true)"
OUT="$(no_tty_run --all-for-doc "$REPO/docs/plans/alpha-design.md" --yes 2>&1)"; RC=$?
if [ "$RC" -eq 0 ]; then
  no "all-or-nothing: refuses the whole drain" "exited 0: $OUT"
else
  ok "all-or-nothing: refuses the whole drain"
fi
check "all-or-nothing: not one token released" "$BEFORE" "$(token_count)"
check "all-or-nothing: no audit event written" "$EVENTS_BEFORE" \
  "$(grep -c 'design-marker-cleared' "$LOG" || true)"
case "$OUT" in
  *"blanket wipe"*) ok "all-or-nothing: says which marker blocked it" ;;
  *) no "all-or-nothing: says which marker blocked it" "$OUT" ;;
esac
rm -f "$REPO/.claude/design-review-needed.local.md"
( cd "$REPO" && "$CLEAR" --all-for-doc "$REPO/docs/plans/alpha-design.md" --yes >/dev/null 2>&1 )
check "all-or-nothing: drains once the anomaly is gone" "0" "$(doc_tokens alpha-design.md)"

# A single-token doc goes through the same path unchanged.
arm "$REPO/docs/plans/gamma-design.md"
EVENTS_BEFORE="$(grep -c 'design-marker-cleared' "$LOG" || true)"
OUT="$(no_tty_run --all-for-doc "$REPO/docs/plans/gamma-design.md" --yes 2>&1)"; RC=$?
check "all-for-doc: single-token doc still clears" "0" "$RC"
check "all-for-doc: single-token doc logs exactly one event" "$(( EVENTS_BEFORE + 1 ))" \
  "$(grep -c 'design-marker-cleared' "$LOG" || true)"

# ── The gate's block message hints a command that actually RUNS (#665) ────────
# The operator meets design-clear.sh through the gate's hint, never through
# --help. Before #665 a multi-token doc got the plain `<doc-path>` hint repeated
# once per token — the same line N times, each naming a command guaranteed to
# refuse (">1 match"). A hint that cannot work is what sent the operator to `rm`.
: >"$REPO/docs/plans/epsilon-design.md"
DELTA_N=$(( $(doc_tokens delta-design.md) + 2 ))
arm "$REPO/docs/plans/delta-design.md"
arm "$REPO/docs/plans/delta-design.md"
arm "$REPO/docs/plans/epsilon-design.md"
RECS="$TMP/recs"
in_repo gate_marker_pending "$REPO" >"$RECS" 2>/dev/null
# The renderer emits literal \n escapes for its caller to expand; do that here so
# the assertions below are per-line rather than against one long string.
RENDER="$(printf '%b' "$(in_repo gate_render_pending_records "$RECS" "$REPO")")"
check "hint: multi-token doc listed once, not once per token" "1" \
  "$(printf '%s\n' "$RENDER" | grep -c 'delta-design.md' || true)"
check "hint: multi-token doc gets the bulk command" "1" \
  "$(printf '%s\n' "$RENDER" | grep 'delta-design.md' | grep -c -- '--all-for-doc' || true)"
check "hint: names how many tokens are bound to it" "1" \
  "$(printf '%s\n' "$RENDER" | grep 'delta-design.md' | grep -c -- "$DELTA_N tokens, one per edit" || true)"
check "hint: single-token doc keeps the plain selector" "0" \
  "$(printf '%s\n' "$RENDER" | grep 'epsilon-design.md' | grep -c -- '--all-for-doc' || true)"
check "hint: single-token doc still hinted at all" "1" \
  "$(printf '%s\n' "$RENDER" | grep -c 'epsilon-design.md' || true)"
# And the hint it prints is the command that works: run it verbatim.
OUT="$(no_tty_run --all-for-doc "$REPO/docs/plans/delta-design.md" --yes 2>&1)"; RC=$?
check "hint: the hinted bulk command succeeds" "0" "$RC"
check "hint: it released every token for that doc" "0" "$(doc_tokens delta-design.md)"

# A doc that ALSO has a non-token marker must NOT be hinted --all-for-doc: the
# drain refuses all-or-nothing on such a set, so counting legacy records as
# tokens would print a command guaranteed to fail — the exact defect this hint
# exists to remove. Mixed state keeps the per-record rendering it has today.
arm "$REPO/docs/plans/delta-design.md"
arm "$REPO/docs/plans/delta-design.md"
DELTA_NORM="$(cat "$(grep -rl 'delta-design.md' "$MARKER_DIR" | head -1)")"
printf -- '- %s\n' "$DELTA_NORM" >"$REPO/.claude/design-review-needed.local.md"
in_repo gate_marker_pending "$REPO" >"$RECS" 2>/dev/null
RENDER="$(printf '%b' "$(in_repo gate_render_pending_records "$RECS" "$REPO")")"
check "hint: mixed token+legacy doc is NOT hinted the bulk command" "0" \
  "$(printf '%s\n' "$RENDER" | grep 'delta-design.md' | grep -c -- '--all-for-doc' || true)"
# Falls back to one line per record (2 tokens + 1 legacy), which is what the
# renderer did before the dedupe existed — withholding the bulk hint must not
# also drop the doc from the message.
check "hint: mixed doc still appears, one line per record" "3" \
  "$(printf '%s\n' "$RENDER" | grep -c 'delta-design.md.*release with an audit record' || true)"
# Prove the hint was right to withhold it: the bulk command does refuse here.
OUT="$(no_tty_run --all-for-doc "$REPO/docs/plans/delta-design.md" --yes 2>&1)"; RC=$?
if [ "$RC" -eq 0 ]; then
  no "hint: withheld because the bulk command would refuse" "it exited 0: $OUT"
else
  ok "hint: withheld because the bulk command would refuse"
fi
rm -f "$REPO/.claude/design-review-needed.local.md"

# A legacy marker naming the SAME doc through a non-canonical spelling (a `..`
# segment here; a symlinked directory has the identical failure mode) must
# still be recognized as the same document. Tokens are canonicalized at arm
# time (gate_marker_norm_path: realpath the dir, rejoin the basename); a
# legacy marker's doc entry must canonicalize the same way, or the doc-key
# comparison in gate_render_pending_records / design-clear.sh's selector match
# silently reads it as a DIFFERENT document — bulk-draining every token while
# leaving the doc's legacy marker armed, exactly the all-or-nothing refusal
# this feature exists to trigger.
arm "$REPO/docs/plans/gamma-design.md"
GAMMA_NORM="$(cat "$(grep -rl 'gamma-design.md' "$MARKER_DIR" | head -1)")"
GAMMA_DIR="$(dirname "$GAMMA_NORM")"
GAMMA_MIXED_SPELLING="$GAMMA_DIR/../plans/gamma-design.md"
printf -- '- %s\n' "$GAMMA_MIXED_SPELLING" >"$REPO/.claude/design-review-needed.local.md"
BEFORE="$(token_count)"
EVENTS_BEFORE="$(grep -c 'design-marker-cleared' "$LOG" || true)"
OUT="$(no_tty_run --all-for-doc "$REPO/docs/plans/gamma-design.md" --yes 2>&1)"; RC=$?
if [ "$RC" -eq 0 ]; then
  no "all-or-nothing: canonicalizes a mixed-spelling legacy marker" "exited 0: $OUT"
else
  ok "all-or-nothing: canonicalizes a mixed-spelling legacy marker"
fi
check "mixed-spelling legacy: not one token released" "$BEFORE" "$(token_count)"
check "mixed-spelling legacy: no audit event written" "$EVENTS_BEFORE" \
  "$(grep -c 'design-marker-cleared' "$LOG" || true)"
in_repo gate_marker_pending "$REPO" >"$RECS" 2>/dev/null
RENDER="$(printf '%b' "$(in_repo gate_render_pending_records "$RECS" "$REPO")")"
check "mixed-spelling legacy: hint withholds the bulk command" "0" \
  "$(printf '%s\n' "$RENDER" | grep 'gamma-design.md' | grep -c -- '--all-for-doc' || true)"
rm -f "$REPO/.claude/design-review-needed.local.md"
( cd "$REPO" && "$CLEAR" --all-for-doc "$REPO/docs/plans/gamma-design.md" --yes >/dev/null 2>&1 )
check "mixed-spelling legacy: drains once the legacy marker is gone" "0" "$(doc_tokens gamma-design.md)"

# ── Classifier-cap truncation (CAP=20 in design-clear.sh, K=20 in marker_ops.py) ──
# --all-for-doc is not a promise to empty the directory: the classifier stops
# COUNTING at K=20 records total (existence-keyed, ADR-C), so a doc that alone
# holds more than the cap only has its first (cap - other-pending) tokens visible
# to this run. The drain must clear exactly what it saw and say "Others MAY
# remain ... re-run to check" — never claim an exact "N token(s) still pending"
# count it cannot know past the cap.
: >"$REPO/docs/plans/zeta-design.md"
# ZETA itself must exceed the cap — arm 21 regardless of what else is pending.
# Topping the GLOBAL count up to 21 is not equivalent and is flaky: the
# classifier emits an arbitrary os.listdir() subset, so when the one record
# above the cap belongs to another doc, every zeta token is listed and the
# drain leaves nothing behind. With 21 zeta tokens, at most 20 can ever be
# listed, so at least one survives no matter how listdir orders them.
_i=0
while [ "$_i" -lt 21 ]; do
  arm "$REPO/docs/plans/zeta-design.md"
  _i=$(( _i + 1 ))
done
check "cap: enough tokens armed to exceed the classifier cap" "1" \
  "$([ "$(doc_tokens zeta-design.md)" -ge 21 ] && echo 1 || echo 0)"
OUT="$(no_tty_run --all-for-doc "$REPO/docs/plans/zeta-design.md" --yes 2>&1)"; RC=$?
check "cap: all-for-doc still exits 0 past the cap" "0" "$RC"
case "$OUT" in
  *"Others MAY remain"*"re-run to check"*) ok "cap: prints the capped-listing warning, not an exact count" ;;
  *) no "cap: prints the capped-listing warning, not an exact count" "$OUT" ;;
esac
case "$OUT" in
  *"token(s) still pending"*) no "cap: does NOT claim an exact remaining count" "$OUT" ;;
  *) ok "cap: does NOT claim an exact remaining count" ;;
esac
check "cap: at least one zeta token survives the capped drain" "1" \
  "$([ "$(doc_tokens zeta-design.md)" -ge 1 ] && echo 1 || echo 0)"
# Drain the rest so the fixture doesn't leak an armed doc past the suite.
while [ "$(doc_tokens zeta-design.md)" -gt 0 ]; do
  ( cd "$REPO" && "$CLEAR" --all-for-doc "$REPO/docs/plans/zeta-design.md" --yes >/dev/null 2>&1 ) || break
done
check "cap: fully drains once under the cap" "0" "$(doc_tokens zeta-design.md)"

printf "\n%d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
