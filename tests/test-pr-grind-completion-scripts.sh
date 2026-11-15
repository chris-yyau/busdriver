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
  *"--json baseRefName"*) echo main ;;
  *"--json author"*) [ -n "${FAKE_NO_AUTHOR:-}" ] && exit 1; echo alice ;;
  *"--json state"*) echo "$FAKE_STATE" ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$P/scripts/"*.sh "$T/bin/gh"
W="$T/wt"
git init -q "$W" && git -C "$W" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
export CALLS="$T/calls" FAKE_STATE=OPEN PATH="$T/bin:$PATH"
LOG="$W/.claude/bypass-log.jsonl"
ADMIN="$P/scripts/approver-gap-admin.sh"

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
(cd "$P" && FAKE_DECISION='{"decision":"auto-admin-merge","trigger":"flag"}' bash scripts/approver-gap-admin.sh authorize 12 o r "$W" 1 >/dev/null 2>&1)
[ -s "$LOG" ] && ok "a relative script path still finds its own plugin's composer after the cd" \
  || no "a relative script path still finds its own plugin's composer after the cd" "no log entry"

echo "== settle: MERGED drains and GCs; anything else removes the marker and exits 1"
MARKER="$W/.claude/pr-grind-clean.local"
echo "12 abc" >"$MARKER"; : >"$CALLS"
FAKE_STATE=MERGED expect_rc 0 "MERGED exits 0" bash "$ADMIN" settle 12 "$W"
grep -q '^design-clear --skip pr-grind-clean.local --yes$' "$CALLS" && ok "  ...drains the spent marker" || no "  ...drains the spent marker" "$(cat "$CALLS")"
grep -q '^gc 12$' "$CALLS" && ok "  ...GCs the codex-retrigger markers" || no "  ...GCs the codex-retrigger markers" "$(cat "$CALLS")"
echo "12 abc" >"$MARKER"; : >"$CALLS"
FAKE_STATE=OPEN expect_rc 1 "not MERGED exits 1" bash "$ADMIN" settle 12 "$W"
[ ! -e "$MARKER" ] && ok "  ...and removes the clean marker" || no "  ...and removes the clean marker" "marker kept"
[ ! -s "$CALLS" ] && ok "  ...and drains nothing" || no "  ...and drains nothing" "$(cat "$CALLS")"

echo "════ pr-grind-completion-scripts: $PASS passed, $FAIL failed ════"
[ "$FAIL" -eq 0 ]
