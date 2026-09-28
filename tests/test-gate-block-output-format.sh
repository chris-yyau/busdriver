#!/usr/bin/env bash
# Every PreToolUse gate that blocks by printing JSON must emit BOTH shapes:
#   - legacy top-level {"decision":"block","reason":R}, which Claude Code still honours
#     and which the OMP and Devin adapters read first;
#   - hookSpecificOutput {hookEventName:"PreToolUse", permissionDecision:"deny",
#     permissionDecisionReason:R}, the only shape the Claude Code hook docs document
#     for PreToolUse and the only one Cursor's claude-plugin translation honours.
# A gate that emitted only the legacy shape was silently ignored by cursor-agent
# (measured 2026-09-28: a plain `git commit` passed the litmus gate under Cursor).
#
# Each emission path is exercised for real, not grepped: block_emit's jq, python3 and
# last-resort printf tiers (selected by hiding jq / python3 from PATH), the ERR trap,
# and one end-to-end pre-commit block.
#
# Usage: bash tests/test-gate-block-output-format.sh
# Exit: 0 if all pass, 1 if any fail.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
ROOT="$PWD"
GATES=(pre-commit-gate.sh pre-pr-gate.sh pre-merge-gate.sh ref-ff-gate.sh freeze-guard.sh pre-implementation-gate.sh)

PASS=0; FAIL=0
ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '        %s\n' "$2"; FAIL=$((FAIL + 1)); }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
PY3=$(command -v python3)
# Resolve through any version-manager shim (pyenv/asdf shims are bash scripts that
# cannot run once PATH is isolated below) to the real interpreter.
PY3=$("$PY3" -c 'import sys; print(sys.executable)')
mkdir -p "$TMP/py-only" "$TMP/no-tools"
ln -s "$PY3" "$TMP/py-only/python3"
# The last-resort tier runs with NO tools on PATH at all: it must escape in pure
# bash, because a gate reaches it exactly when the environment is stripped, and a
# missing tool under set -e would exit the gate with no output (fail-OPEN).

# check <label> <json-text> <expected-reason or empty to skip the reason check> [substr]
# With a 4th arg "substr", the reason need only CONTAIN <expected-reason>.
check() {
    local label="$1" out="$2" want="$3" mode="${4:-exact}" verdict
    verdict=$(printf '%s' "$out" | "$PY3" -c '
import json, sys
want, mode = sys.argv[1], sys.argv[2]
try:
    d = json.loads(sys.stdin.read())
except Exception as e:
    print("not JSON: %s" % e); sys.exit()
h = d.get("hookSpecificOutput") or {}
errs = []
if d.get("decision") != "block": errs.append("decision=%r" % d.get("decision"))
if h.get("hookEventName") != "PreToolUse": errs.append("hookEventName=%r" % h.get("hookEventName"))
if h.get("permissionDecision") != "deny": errs.append("permissionDecision=%r" % h.get("permissionDecision"))
if d.get("reason") != h.get("permissionDecisionReason"): errs.append("reason != permissionDecisionReason")
if want and mode == "substr" and want not in (d.get("reason") or ""): errs.append("reason=%r" % d.get("reason"))
if want and mode != "substr" and d.get("reason") != want: errs.append("reason=%r" % d.get("reason"))
if not d.get("reason"): errs.append("empty reason")
print("; ".join(errs) or "OK")
' "$want" "$mode")
    [ "$verdict" = "OK" ] && ok "$label" || bad "$label" "$verdict"
}

# The function text of block_emit, extracted from the gate so the REAL body runs.
emit_fn() { awk '/^block_emit\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$ROOT/hooks/gate-scripts/$1"; }

HARD=$'quote " backslash \\ newline\nend'
PLAIN='gate blocked: run litmus first'
echo "== block_emit tiers =="
for g in "${GATES[@]}"; do
    fn=$(emit_fn "$g")
    [ -n "$fn" ] || { bad "$g: block_emit not found"; continue; }
    if command -v jq >/dev/null; then
        check "$g jq tier" "$(bash -c "$fn"$'\nblock_emit "$1"' _ "$HARD")" "$HARD"
    else
        printf '  SKIP  %s jq tier (jq not on PATH)\n' "$g"
    fi
    # Every gate carries the python3 tier; a missing one is a regression, not a skip.
    if grep -q 'python3 -I -c' <<<"$fn"; then
        check "$g python3 tier" "$(PATH="$TMP/py-only" "$BASH" -c "$fn"$'\nblock_emit "$1"' _ "$HARD")" "$HARD"
    else
        bad "$g python3 tier" "block_emit has no 'python3 -I -c' tier"
    fi
    check "$g printf tier" "$(PATH="$TMP/no-tools" "$BASH" -c "$fn"$'\nblock_emit "$1"' _ "$PLAIN")" "$PLAIN"
    # Lossy by design, but a quote/backslash/newline reason must still be valid JSON.
    check "$g printf tier (hard reason)" "$(PATH="$TMP/no-tools" "$BASH" -c "$fn"$'\nblock_emit "$1"' _ "$HARD")" ""
done

echo "== ERR traps =="
for g in "${GATES[@]}"; do
    line=$(grep -m1 "^trap 'printf" "$ROOT/hooks/gate-scripts/$g") || { [ "$g" = freeze-guard.sh ] && continue; bad "$g: ERR trap not found"; continue; }
    out=$(STATE_DIR=.claude REPO_DIR=/r bash -c "set -E; $line"$'\nfalse' 2>/dev/null)
    check "$g ERR trap" "$out" ""
done

echo "== end to end: pre-commit gate blocks an unreviewed commit =="
R="$TMP/repo"; mkdir -p "$R"
git -C "$R" init -q && git -C "$R" config user.email t@local && git -C "$R" config user.name t
echo x >"$R/a.txt" && git -C "$R" add a.txt
payload=$("$PY3" -c 'import json,sys; print(json.dumps({"tool_name":"Bash","tool_input":{"command":"git commit -m x"},"cwd":sys.argv[1]}))' "$R")
out=$(cd "$R" && printf '%s' "$payload" | bash "$ROOT/hooks/gate-scripts/pre-commit-gate.sh" 2>/dev/null)
check "pre-commit gate end-to-end block" "$out" "Code review required before committing" substr

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
