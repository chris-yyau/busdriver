#!/usr/bin/env bash
# Tests for the pr-grind COMPLETION blocks moved into scripts by #1078:
#   scripts/completion-ack-requery.sh, scripts/approver-gap-compose.sh,
#   scripts/approver-gap-admin.sh
# Covers argument validation (bad input never reaches GitHub), approver-gap-admin's
# fail-CLOSED authorization (only `auto-admin-merge` + trigger flag|solo-admin-auto logs and
# exits 0), and `settle` on both merge outcomes. `gh` and the sibling scripts are stubs;
# nothing here talks to GitHub.
set -u
. "$(dirname "$0")/lib/git-env-isolation.sh" || exit 1

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
no() { FAIL=$((FAIL + 1)); printf '  FAIL  %s :: %s\n' "$1" "${2:-}"; }
expect_rc() { # <want> <label> <cmd...>
  local want="$1" label="$2" got
  shift 2
  "$@" >/dev/null 2>&1
  got=$?
  if [ "$got" = "$want" ]; then ok "$label"; else no "$label" "rc=$got want=$want"; fi
}

T="$(mktemp -d -t pr-grind-completion-scripts.XXXXXX)"
trap 'rm -rf "$T"' EXIT

echo "== argument validation exits 2 before any network call"
for s in completion-ack-requery.sh approver-gap-compose.sh; do
  expect_rc 2 "$s: no arguments" bash "$ROOT/scripts/$s"
  expect_rc 2 "$s: non-numeric PR" bash "$ROOT/scripts/$s" 12x o r "$T" 0
  expect_rc 2 "$s: relative WORKTREE_DIR" bash "$ROOT/scripts/$s" 12 o r rel 0
done
expect_rc 2 "approver-gap-compose.sh: ADMIN_FLAG_PASSED not 0/1" bash "$ROOT/scripts/approver-gap-compose.sh" 12 o r "$T" yes
expect_rc 2 "approver-gap-admin.sh: unknown mode" bash "$ROOT/scripts/approver-gap-admin.sh" merge 12 o r "$T" 0
expect_rc 2 "approver-gap-admin.sh: authorize arity" bash "$ROOT/scripts/approver-gap-admin.sh" authorize 12 o r "$T"
expect_rc 2 "approver-gap-admin.sh: settle non-numeric PR" bash "$ROOT/scripts/approver-gap-admin.sh" settle 12x "$T"

# A plugin root holding the real approver-gap-admin.sh beside stub siblings, and a stub gh.
P="$T/plugin"
mkdir -p "$P/scripts" "$T/bin"
cp "$ROOT/scripts/approver-gap-admin.sh" "$P/scripts/"
cat >"$P/scripts/approver-gap-compose.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$FAKE_DECISION"
EOF
cat >"$P/scripts/design-clear.sh" <<'EOF'
#!/usr/bin/env bash
echo "design-clear $*" >>"$CALLS"
EOF
cat >"$P/scripts/codex-retrigger-gc.sh" <<'EOF'
#!/usr/bin/env bash
echo "gc $*" >>"$CALLS"
EOF
cat >"$T/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"--json baseRefName"*) echo "$*" >>"${GHREPO_LOG:-/dev/null}"; echo main ;;
  *"/reviews --paginate") echo '[]' ;;
  *"--json author"*) [ -n "${FAKE_NO_AUTHOR:-}" ] && exit 1; echo alice ;;
  *"--json state"*) echo "$FAKE_STATE" ;;
  *"repo view"*) if [ -n "${FAKE_WT_REPO:-}" ] && [ "$PWD" = "${FAKE_WT_DIR:-}" ]; then echo "$FAKE_WT_REPO"; else echo "${FAKE_REPO:-o/r}"; fi ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$P/scripts/"*.sh "$T/bin/gh"
# W is the session checkout (main repo); LW a linked worktree like Step 0's ../pr-grind-<PR>.
W="$T/wt"
LW="$T/linked"
git init -q "$W" && git -C "$W" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
git -C "$W" worktree add -q --detach "$LW"
export CALLS="$T/calls" FAKE_STATE=OPEN PATH="$T/bin:$PATH"
LOG="$W/.claude/bypass-log.jsonl"
ADMIN="$P/scripts/approver-gap-admin.sh"

echo "== compose: detection does not need the Step 0 worktree on disk"
# The real composer beside a stub detector, run with a WORKTREE_DIR that does not exist.
CP="$T/compose-plugin"
mkdir -p "$CP/scripts"
cp "$ROOT/scripts/approver-gap-compose.sh" "$CP/scripts/"
printf '#!/usr/bin/env bash\necho %s\n' "'{\"decision\":\"no-gap\",\"trigger\":\"none\"}'" >"$CP/scripts/approver-gap-detect.sh"
export GHREPO_LOG="$T/ghrepo"
COMPOSE_OUT=$(cd "$T" && bash "$CP/scripts/approver-gap-compose.sh" 12 o r "$T/no-such-worktree" 0 2>/dev/null)
COMPOSE_RC=$?
[ "$COMPOSE_RC" = 0 ] && [ "$COMPOSE_OUT" = '{"decision":"no-gap","trigger":"none"}' ] \
  && ok "a missing WORKTREE_DIR still returns the detector's decision" \
  || no "a missing WORKTREE_DIR still returns the detector's decision" "rc=$COMPOSE_RC out=$COMPOSE_OUT"
case "$(cat "$GHREPO_LOG" 2>/dev/null)" in "-R o/r pr view 12 "*) true ;; *) false ;; esac && ok "  ...and gh pr view is pinned to OWNER/REPO" \
  || no "  ...and gh pr view is pinned to OWNER/REPO" "$(cat "$GHREPO_LOG" 2>/dev/null)"
unset GHREPO_LOG

echo "== authorize: only a verified auto-admin-merge decision logs and exits 0"
authorize_case() { # <rc> <label> <decision json>
  rm -f "$LOG"
  FAKE_DECISION="$3" expect_rc "$1" "$2" bash "$ADMIN" authorize 12 o r "$W" 1
}
authorize_case 1 "empty decision refuses" ""
[ ! -e "$LOG" ] && ok "  ...and writes no bypass-log entry" || no "  ...and writes no bypass-log entry" "log exists"
authorize_case 1 "no-gap refuses" '{"decision":"no-gap","trigger":"none"}'
authorize_case 1 "surface-decision refuses" '{"decision":"surface-decision","trigger":"none"}'
authorize_case 1 "unknown trigger refuses" '{"decision":"auto-admin-merge","trigger":"other"}'
authorize_case 1 "malformed JSON refuses" 'not json'
[ ! -e "$LOG" ] && ok "  ...none of the refusals wrote a log entry" || no "  ...none of the refusals wrote a log entry" "log exists"
authorize_case 0 "flag trigger authorizes" '{"decision":"auto-admin-merge","trigger":"flag","author_perm":"admin","required_approving_review_count":1,"human_approvals":0,"human_admin_count":1}'
if [ "$(jq -r '[.event,.trigger,.pr,.owner,.repo,.branch,.author,.author_perm,.required_approving_review_count] | map(tostring) | join(" ")' "$LOG" 2>/dev/null)" \
   = "pr-grind-admin-on-approver-gap flag 12 o r main alice admin 1" ]; then
  ok "  ...and logs one entry with the decision's fields"
else
  no "  ...and logs one entry with the decision's fields" "$(cat "$LOG" 2>/dev/null)"
fi
authorize_case 0 "solo-admin-auto trigger authorizes" '{"decision":"auto-admin-merge","trigger":"solo-admin-auto"}'
[ "$(jq -r .event "$LOG" 2>/dev/null)" = "pr-grind-admin-on-approver-gap-solo-admin-auto" ] \
  && ok "  ...with the solo-admin event name" || no "  ...with the solo-admin event name" "$(cat "$LOG" 2>/dev/null)"
FAKE_DECISION='{"decision":"auto-admin-merge","trigger":"flag"}' BRANCH=evil AUTHOR=mallory \
  bash "$ADMIN" authorize 12 o r "$W" 1 >/dev/null 2>&1
[ "$(jq -r '.branch + " " + .author' "$LOG" | tail -1)" = "main alice" ] \
  && ok "inherited BRANCH/AUTHOR do not reach the audit entry" || no "inherited BRANCH/AUTHOR do not reach the audit entry" "$(tail -1 "$LOG")"

rm -f "$LOG"
FAKE_NO_AUTHOR=1 FAKE_DECISION='{"decision":"auto-admin-merge","trigger":"flag"}' \
  expect_rc 1 "an unresolvable PR author refuses (the audit entry is load-bearing)" bash "$ADMIN" authorize 12 o r "$W" 1
[ ! -e "$LOG" ] && ok "  ...and writes no bypass-log entry" || no "  ...and writes no bypass-log entry (no author)" "log exists"
rm -f "$LOG"
FAKE_REPO=other/repo FAKE_DECISION='{"decision":"auto-admin-merge","trigger":"flag"}' \
  expect_rc 1 "a cwd resolving to another repository refuses (the typed merge would land there)" bash "$ADMIN" authorize 12 o r "$W" 1
[ ! -e "$LOG" ] && ok "  ...and writes no bypass-log entry" || no "  ...and writes no bypass-log entry (other repo)" "log exists"
rm -f "$LOG"
FAKE_WT_DIR="$W" FAKE_WT_REPO=other/repo FAKE_DECISION='{"decision":"auto-admin-merge","trigger":"flag"}' \
  expect_rc 1 "a WORKTREE_DIR of another repository refuses (the decision would mix two repositories)" bash "$ADMIN" authorize 12 o r "$W" 1
[ ! -e "$LOG" ] && ok "  ...and writes no bypass-log entry" || no "  ...and writes no bypass-log entry (other worktree repo)" "log exists"
FAKE_WT_DIR="$W" FAKE_WT_REPO=other/repo \
  expect_rc 2 "completion-ack-requery.sh: a WORKTREE_DIR of another repository refuses" bash "$ROOT/scripts/completion-ack-requery.sh" 12 o r "$W"
U="$T/unborn"; git init -q "$U"
FAKE_DECISION='{"decision":"auto-admin-merge","trigger":"flag"}' \
  expect_rc 1 "an unresolvable worktree HEAD refuses (head_sha is the audit join key)" bash "$ADMIN" authorize 12 o r "$U" 1
[ ! -e "$U/.claude/bypass-log.jsonl" ] && ok "  ...and writes no bypass-log entry" || no "  ...and writes no bypass-log entry (unborn HEAD)" "log exists"
FAKE_REPO=O/R FAKE_DECISION='{"decision":"auto-admin-merge","trigger":"flag"}' \
  expect_rc 0 "repository names compare case-insensitively" bash "$ADMIN" authorize 12 o r "$W" 1
rm -f "$LOG"
(cd "$P" && FAKE_DECISION='{"decision":"auto-admin-merge","trigger":"flag"}' bash scripts/approver-gap-admin.sh authorize 12 o r "$W" 1 >/dev/null 2>&1)
[ -s "$LOG" ] && ok "a relative script path still finds its own plugin's composer after the cd" \
  || no "a relative script path still finds its own plugin's composer after the cd" "no log entry"

echo "== authorize: the audit entry lands in the MAIN repo's log, not the linked worktree's"
rm -f "$LOG" "$LW/.claude/bypass-log.jsonl"
FAKE_DECISION='{"decision":"auto-admin-merge","trigger":"flag"}' bash "$ADMIN" authorize 12 o r "$LW" 1 >/dev/null 2>&1
[ -s "$LOG" ] && [ ! -e "$LW/.claude/bypass-log.jsonl" ] && ok "a linked WORKTREE_DIR logs to the main repo's .claude/" \
  || no "a linked WORKTREE_DIR logs to the main repo's .claude/" "main=$(cat "$LOG" 2>/dev/null) linked=$(cat "$LW/.claude/bypass-log.jsonl" 2>/dev/null)"
[ "$(jq -r .head_sha "$LOG")" = "$(git -C "$LW" rev-parse HEAD | cut -c1-8)" ] && ok "  ...recording the worktree's HEAD" \
  || no "  ...recording the worktree's HEAD" "$(jq -r .head_sha "$LOG")"

echo "== settle (at the session checkout): MERGED drains and GCs; anything else removes the marker"
# shellcheck disable=SC2016  # the bash -c programs read their own positional arguments
MARKER="$W/.claude/pr-grind-clean.local"
echo "12 abc" >"$MARKER"; : >"$CALLS"
FAKE_STATE=MERGED expect_rc 0 "MERGED exits 0" bash -c 'cd "$1" && bash "$2" settle 12 "$3"' _ "$W" "$ADMIN" "$LW"
grep -q '^design-clear --skip pr-grind-clean.local --yes$' "$CALLS" && ok "  ...drains the spent marker" || no "  ...drains the spent marker" "$(cat "$CALLS")"
grep -q '^gc 12$' "$CALLS" && ok "  ...GCs the codex-retrigger markers" || no "  ...GCs the codex-retrigger markers" "$(cat "$CALLS")"
echo "12 abc" >"$MARKER"; : >"$CALLS"
FAKE_STATE=OPEN expect_rc 1 "not MERGED exits 1" bash -c 'cd "$1" && bash "$2" settle 12 "$3"' _ "$W" "$ADMIN" "$LW"
[ ! -e "$MARKER" ] && ok "  ...and removes the session checkout's clean marker (not the worktree's)" \
  || no "  ...and removes the session checkout's clean marker (not the worktree's)" "marker kept"
[ ! -s "$CALLS" ] && ok "  ...and drains nothing" || no "  ...and drains nothing" "$(cat "$CALLS")"
echo "12 abc" >"$MARKER"
FAKE_STATE=OPEN expect_rc 1 "not MERGED with the worktree gone still exits 1" bash -c 'cd "$1" && bash "$2" settle 12 "$3"' _ "$W" "$ADMIN" "$T/no-such-worktree"
[ ! -e "$MARKER" ] && ok "  ...and still removes the clean marker (#427)" || no "  ...and still removes the clean marker (#427)" "marker kept"

echo "════ pr-grind-completion-scripts: $PASS passed, $FAIL failed ════"
[ "$FAIL" -eq 0 ]
