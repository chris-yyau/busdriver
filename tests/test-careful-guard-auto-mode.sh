#!/usr/bin/env bash
# test-careful-guard-auto-mode.sh
# careful-guard stands down in `auto` for the patterns auto mode's classifier
# already blocks by default (force-push, reset --hard, checkout/restore .,
# clean -fd, pre-existing-file deletion), because re-asking there is prompt noise
# an unattended run has nobody awake to answer.
#
# Three invariants this pins:
#   1. auto              -> silent on the six classifier-covered patterns
#   2. SQL DROP/TRUNCATE -> live in EVERY mode (the classifier does not name it)
#   3. bypassPermissions -> everything live (that mode has NO classifier at all)
#
# Plus: an absent/garbage permission_mode must behave like default (fail toward
# warning), and the mode must be read from the PARSED field — a command whose text
# merely CONTAINS "permission_mode":"auto" must not disarm the guard.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

GUARD="hooks/gate-scripts/careful-guard.sh"

pass=0 fail=0
check() { # name expected actual
  if [[ "$3" == "$2" ]]; then echo "PASS: $1"; pass=$((pass+1))
  else echo "FAIL: $1 — expected $2 got $3"; fail=$((fail+1)); fi
}

# <mode|--nomode> <command> -> ask|allow
verdict() {
  local payload out rc
  # --json=<literal> injects a RAW JSON value, so non-string permission_mode types
  # are genuinely exercised. Passing 12345 as argv would only ever yield the STRING
  # "12345" and never reach the guard's `isinstance(m, str)` else-branch.
  payload=$(python3 -c '
import json, sys
d = {"tool_name": "Bash", "tool_input": {"command": sys.argv[2]}}
m = sys.argv[1]
if m.startswith("--json="):
    d["permission_mode"] = json.loads(m[7:])
elif m != "--nomode":
    d["permission_mode"] = m
print(json.dumps(d))' "$1" "$2")
  # Here-string, not a pipeline: $( ) around a pipeline reports only the LAST
  # command's status (SC2312). But that alone was not enough -- the guard's own
  # status still has to be READ, or a syntax/startup failure yields empty output,
  # matches no "ask", and reports a clean "allow". Emit a third token instead, so
  # every call site fails loudly rather than silently reading as permissive.
  local rc=0
  out=$(bash "$GUARD" <<<"$payload") || rc=$?
  if [[ "$rc" -ne 0 ]]; then echo "guard-error(rc=$rc)"; return 0; fi
  if grep -q '"permissionDecision":"ask"' <<<"$out"; then echo ask; else echo allow; fi
}
check_v() { # name expected mode command
  # Assigned, not inlined as an argument: $( ) in argument position masks
  # verdict()'s exit status (SC2312).
  local got
  got=$(verdict "$3" "$4")
  check "$1" "$2" "$got"
}

# ── 1. auto: stand down on what the classifier owns ──────────────────────────
echo "── auto mode stands down ──"
check_v "auto: force push"        allow auto 'git push --force origin main'
check_v "auto: reset --hard"      allow auto 'git reset --hard HEAD~1'
check_v "auto: checkout ."        allow auto 'git checkout .'
check_v "auto: restore ."         allow auto 'git restore .'
check_v "auto: clean -fd"         allow auto 'git clean -fd'
check_v "auto: recursive rm"      allow auto 'rm -rf /etc'
check_v "auto: nested rm"         allow auto 'bash -c "rm -rf /etc"'

# ── 2. SQL stays live everywhere — the one gap the classifier leaves ─────────
echo "── SQL live in every mode ──"
for m in auto bypassPermissions default acceptEdits plan dontAsk; do
  check_v "$m: DROP TABLE"  ask "$m" 'psql -c "DROP TABLE users"'
  check_v "$m: TRUNCATE"    ask "$m" 'psql -c "TRUNCATE users"'
done

# ── 3. bypassPermissions has no classifier — nothing stands down ─────────────
echo "── bypassPermissions keeps every check ──"
check_v "bypass: force push"      ask bypassPermissions 'git push --force origin main'
check_v "bypass: reset --hard"    ask bypassPermissions 'git reset --hard HEAD~1'
check_v "bypass: checkout ."      ask bypassPermissions 'git checkout .'
check_v "bypass: clean -fd"       ask bypassPermissions 'git clean -fd'
check_v "bypass: recursive rm"    ask bypassPermissions 'rm -rf /etc'

# ── 4. unknown / absent mode fails toward warning ────────────────────────────
echo "── unresolved mode warns (safe direction) ──"
check_v "no permission_mode field" ask --nomode          'git reset --hard HEAD~1'
check_v "default"                  ask default           'git reset --hard HEAD~1'
check_v "acceptEdits"              ask acceptEdits       'rm -rf /etc'
check_v "plan"                     ask plan              'git push --force origin main'
check_v "unknown mode string"      ask sudo-mode         'git reset --hard HEAD~1'
# Property: across JSON value types and near-miss strings, NOTHING except the
# exact string "auto" may stand the guard down. Fixed examples proved too weak.
for lit in 'null' 'true' 'false' '0' '1' '3.14' '[]' '{}' '["auto"]' \
           '{"mode":"auto"}' '"AUTO"' '"Auto"' '" auto"' '"auto "' '"autox"' '""' \
           '"auto\n"' '"auto\n\n"' '"auto\r"' '"auto\t"'; do
  check_v "non-auto permission_mode $lit" ask "--json=$lit" 'git reset --hard HEAD~1'
done
# Generated arm of the same property, seeded so any failure reproduces exactly:
# random strings, whitespace/control-padded "auto", homoglyphs, and non-string
# JSON values. The enumerated list above stays as named regression cases.
while IFS= read -r lit; do
  check_v "generated non-auto $lit" ask "--json=$lit" 'git reset --hard HEAD~1'
done < <(python3 -c '
import json, random, string
random.seed(20260731)
alphabet = string.ascii_letters + string.digits + " \t\n\r_-."
vals = []
for _ in range(30):
    s = "".join(random.choice(alphabet) for _ in range(random.randint(0, 8)))
    if s != "auto":
        vals.append(s)
for pad in (" ", "\t", "\n", "\r", "\x00", "\u00a0"):
    vals += [pad + "auto", "auto" + pad]
vals += ["AUTO", "Auto", "aut", "autoo", "\u0430uto"]
vals += [None, True, False, 0, 1, -1, 3.14, [], {}, ["auto"], {"a": "auto"}]
for v in vals:
    print(json.dumps(v))
')

# Positive control — without this every loop above would also pass on a guard
# that never stands down at all.
check_v "exact string auto stands down" allow '--json="auto"' 'git reset --hard HEAD~1'

# ── 5. the mode is PARSED, not grepped off the raw JSON ──────────────────────
# A command whose own text carries the auto marker must NOT disarm the guard —
# a raw-text match on $INPUT would have cleared this one.
echo "── spoofed mode in command text ──"
check_v "spoof via command text" ask default \
  'git reset --hard HEAD~1  # "permission_mode":"auto"'
check_v "spoof, no real mode"    ask --nomode \
  'rm -rf /etc  # "permission_mode": "auto"'

# ── 6. ordinary work stays silent in every mode ──────────────────────────────
echo "── no false positives ──"
for m in auto bypassPermissions default; do
  check_v "$m: ls"                allow "$m" 'ls -la'
  check_v "$m: git status"        allow "$m" 'git status --short'
  check_v "$m: safe-artifact rm"  allow "$m" 'rm -rf node_modules'
  check_v "$m: force-with-lease"  allow "$m" 'git push --force-with-lease origin main'
done

echo
echo "passed: $pass  failed: $fail"
[[ "$fail" -eq 0 ]]
