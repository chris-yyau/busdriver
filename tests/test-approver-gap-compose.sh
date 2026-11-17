#!/usr/bin/env bash
# Tests for scripts/approver-gap-compose.sh (#1078): the composer pr-grind's Completion
# path used to paste inline, now a script so the lease_slot guard never has to scan it.
#
# A stub `gh` on PATH serves fixtures, so nothing here touches the network. The detector
# itself has its own suite (test-approver-gap-detect.sh); these rows pin what the
# composer adds: argument validation, the repo pinned with -R, and the solo-admin
# opt-in/snapshot resolution that feeds SOLO_ADMIN_OPT_IN and HUMAN_ADMIN_COUNT.
#
# Usage: bash tests/test-approver-gap-compose.sh
set -u
. "$(dirname "$0")/lib/git-env-isolation.sh" || exit 1
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/approver-gap-compose.sh"
PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
no() { FAIL=$((FAIL + 1)); printf '  FAIL  %s :: %s\n' "$1" "${2:-}"; }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/fx"
# Answers only the exact calls the composer should make. `pr view` without `-R o/r`
# falls through to the error branch, so a composer that resolved the repo from CWD
# would lose the branch name and every gap row below would fail.
cat > "$T/bin/gh" <<'STUB'
#!/usr/bin/env bash
F="$GH_FIXTURES"
case "$*" in
  "-R o/r pr view 7 --json baseRefName -q .baseRefName") echo main ;;
  "-R o/r pr view 7 --json author -q .author.login") echo alice ;;
  "api repos/o/r/rules/branches/main") cat "$F/rules" ;;
  "api repos/o/r/branches/main/protection") cat "$F/classic" ;;
  "api repos/o/r/pulls/7/reviews --paginate") cat "$F/reviews" ;;
  "api repos/o/r/collaborators/alice/permission") cat "$F/perm" ;;
  "api repos/o/r/contents/.github/workflows/bypass-audit.yml") [ -f "$F/audit" ] ;;
  "api repos/o/r/collaborators?affiliation=all --paginate") cat "$F/collab" ;;
  *) echo "stub gh: unexpected: $*" >&2; exit 1 ;;
esac
STUB
chmod +x "$T/bin/gh"

# A repo whose .claude/ holds the operator's opt-in and Step 0's snapshot.
REPO="$T/repo"
git init -q "$REPO"
mkdir -p "$REPO/.claude"
OPTIN="$REPO/.claude/pr-grind-auto-admin-solo.local"
SNAP="$REPO/.claude/.pr-grind-solo-opt-in-snapshot-7.local"
setmtime() { python3 -c 'import os,sys; t=int(sys.argv[2]); os.utime(sys.argv[1], (t, t))' "$1" "$2"; }

# Fixtures: main requires one review the author cannot give, no approvals yet.
printf '%s' '[{"type":"pull_request","parameters":{"required_approving_review_count":1}}]' > "$T/fx/rules"
printf '%s' '{}' > "$T/fx/classic"
printf '%s' '[]' > "$T/fx/reviews"
printf '%s' '{"permission":"admin"}' > "$T/fx/perm"
: > "$T/fx/audit"
# Two bots, one per filter: by account type, and by a [bot] login on a User-typed account.
SOLE='[{"login":"alice","type":"User","permissions":{"push":true}},{"login":"ci[bot]","type":"Bot","permissions":{"push":true}},{"login":"app[bot]","type":"User","permissions":{"push":true}}]'
TWO='[{"login":"alice","type":"User","permissions":{"push":true}},{"login":"bob","type":"User","permissions":{"push":true}}]'
printf '%s' "$SOLE" > "$T/fx/collab"

run() { # <composer args...> -> its stdout; its exit status lands in $T/rc (read by rc)
    PATH="$T/bin:$PATH" GH_FIXTURES="$T/fx" bash "$SCRIPT" "$@" 2>/dev/null
    echo $? > "$T/rc"
}
rc() { cat "$T/rc"; }
field() { printf '%s' "$1" | jq -r ".$2" 2>/dev/null; }
expect() { # <label> <json> <decision> <trigger>
    local d t
    d="$(field "$2" decision)"; t="$(field "$2" trigger)"
    if [[ "$(rc)" -eq 0 && "$d" == "$3" && "$t" == "$4" ]]; then ok "$1"
    else no "$1" "rc=$(rc) decision=$d trigger=$t (want $3/$4)"; fi
}

echo "== arguments are validated before any gh call"
for args in "7 o r $REPO" "x o r $REPO 0" "7 o r $REPO 2" "7 '' r $REPO 0"; do
    eval "set -- $args"
    out="$(run "$@")"
    if [[ "$(rc)" -eq 2 && -z "$out" ]]; then ok "refused: $args"; else no "refused: $args" "rc=$(rc) out=$out"; fi
done

echo "== decisions"
NOW="$(date +%s)"
out="$(run 7 o r "$REPO" 0)"
expect "no opt-in file: the gap is surfaced" "$out" surface-decision none
out="$(run 7 o r "$REPO" 1)"
expect "--admin-on-approver-gap: auto-admin via the flag" "$out" auto-admin-merge flag

: > "$OPTIN"; setmtime "$OPTIN" $((NOW - 100))
printf '%s\n' $((NOW - 100)) > "$SNAP"
out="$(run 7 o r "$REPO" 0)"
expect "opt-in with a Step 0 snapshot, sole approver: solo-admin-auto" "$out" auto-admin-merge solo-admin-auto
if [[ "$(field "$out" human_admin_count)" == "1" ]]; then ok "the bot collaborator is not counted"
else no "the bot collaborator is not counted" "$out"; fi

printf '%s' "$TWO" > "$T/fx/collab"
out="$(run 7 o r "$REPO" 0)"
expect "a second human who can approve revokes the opt-in" "$out" surface-decision none
printf '%s' "$SOLE" > "$T/fx/collab"

printf '%s\n' $((NOW - 99)) > "$SNAP"
out="$(run 7 o r "$REPO" 0)"
expect "snapshot naming another mtime: opt-in ignored" "$out" surface-decision none

printf '%s\n' $((NOW - 100)) > "$SNAP"; setmtime "$SNAP" $((NOW - 90))
out="$(run 7 o r "$REPO" 0)"
expect "snapshot written under 30s after the opt-in: forge refused" "$out" surface-decision none

printf '%s\n' $((NOW - 100)) > "$SNAP"; setmtime "$SNAP" "$NOW"
out="$(run 7 o r "/nonexistent-$$" 0)"
expect "a WORKTREE_DIR that is not a repo finds no opt-in" "$out" surface-decision none

# Two pages, as `gh api --paginate` prints them: the approval is on page 2.
printf '%s\n%s\n' '[{"user":{"login":"ci[bot]","type":"Bot"},"state":"COMMENTED"}]' \
    '[{"user":{"login":"bob","type":"User"},"state":"APPROVED","submitted_at":"2026-01-01T00:00:00Z"}]' > "$T/fx/reviews"
out="$(run 7 o r "$REPO" 0)"
expect "an approval on the second page of reviews is counted: no-gap" "$out" no-gap none
# A failed page must not read as zero approvals, which would authorize the bypass.
rm "$T/fx/reviews"
out="$(run 7 o r "$REPO" 1)"
if [[ "$(rc)" -eq 1 && -z "$out" ]]; then ok "a failed reviews fetch exits 1 with no decision"
else no "a failed reviews fetch exits 1 with no decision" "rc=$(rc) out=$out"; fi
printf '%s' '[]' > "$T/fx/reviews"

printf '%s' '[]' > "$T/fx/rules"
out="$(run 7 o r "$REPO" 0)"
expect "no review required: no-gap" "$out" no-gap none

echo
echo "════ approver-gap-compose: $PASS passed, $FAIL failed ════"
[[ "$FAIL" -eq 0 ]]
