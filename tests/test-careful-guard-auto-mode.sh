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
  # stderr suppressed: the guard-error section below runs a deliberately broken
  # guard, whose bash syntax error would otherwise print inside a PASSING run.
  out=$(bash "$GUARD" <<<"$payload" 2>/dev/null) || rc=$?
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

# ── 7. guard-error path itself is exercised (CodeRabbit, PR #543) ────────────
# verdict()'s rc-tracking exists to catch guard startup failures (e.g. a future
# syntax error in careful-guard.sh) instead of silently reading empty output as
# "allow" — but nothing above actually drives the guard into that state. Since
# careful-guard.sh's own ERR trap fail-opens to `{}`/exit 0 for ordinary runtime
# errors, the only case this rc check can ever catch is a failure that happens
# BEFORE the trap is installed: a parse-time syntax error.
echo "── guard-error path is exercised ──"
# Checked: this suite deliberately runs without `set -e`, so an unchecked
# mktemp would leave the var empty and resolve every path below against / —
# writing outside any temp dir when privileged, and escaping the cleanup trap.
BROKEN_GUARD_DIR=$(mktemp -d) || BROKEN_GUARD_DIR=""
if [[ -z "$BROKEN_GUARD_DIR" ]]; then
  echo "FAIL: mktemp -d failed — refusing to run the broken-guard probe with an empty prefix"
  fail=$((fail+1)); echo; echo "passed: $pass  failed: $fail"; exit 1
fi
trap 'rm -rf "$BROKEN_GUARD_DIR"' EXIT
BROKEN_GUARD="$BROKEN_GUARD_DIR/careful-guard-broken.sh"
{
  # PREPENDED, not appended. bash parses and executes command-by-command, so a
  # syntax error at the END is never reached: the guard hits `echo '{}'; exit 0`
  # on an empty payload and exits 0 first (measured: rc=0, out={}). An unterminated
  # `if` as the FIRST command makes bash consume the rest of the file looking for
  # `then`/`fi`, hit EOF, and abort with rc=2 before anything runs — which is the
  # only failure class this rc check can catch, since careful-guard.sh's ERR trap
  # fail-opens every RUNTIME error to `{}`/exit 0.
  echo 'if [[ true'
  cat "$GUARD"
} > "$BROKEN_GUARD"
BROKEN_OUT=$(bash "$BROKEN_GUARD" <<<'{}' 2>/dev/null)
BROKEN_RC=$?
if [[ "$BROKEN_RC" -ne 0 && "$BROKEN_OUT" != *'"permissionDecision"'* ]]; then
  echo "PASS: broken guard exits non-zero, not a silent allow"; pass=$((pass+1))
else
  echo "FAIL: broken guard exits non-zero, not a silent allow — rc=$BROKEN_RC out=$BROKEN_OUT"; fail=$((fail+1))
fi
# Same assertion via verdict()'s own guard-error(...) reporting path, pointed at
# the broken copy instead of $GUARD.
GUARD="$BROKEN_GUARD"
check_v "verdict() reports guard-error on broken guard" 'guard-error(rc=2)' --nomode 'ls -la'
GUARD="hooks/gate-scripts/careful-guard.sh"

# ── 8. python3-unavailable AUTO_MODE fallback (CodeRabbit, PR #543) ──────────
# careful-guard.sh documents that when python3 isn't available, AUTO_MODE must
# stay 0 even under permission_mode "auto" (fail toward warning) — a security-
# relevant invariant of this PR's own design that section 1 never exercises
# because it always runs with a real python3 on PATH.
echo "── python3-unavailable: auto mode does NOT stand down ──"
NO_PY_DIR=$(mktemp -d) || NO_PY_DIR=""
if [[ -z "$NO_PY_DIR" ]]; then
  echo "FAIL: mktemp -d failed — refusing to write a python3 stub to /"
  fail=$((fail+1)); echo; echo "passed: $pass  failed: $fail"; exit 1
fi
trap 'rm -rf "$BROKEN_GUARD_DIR" "$NO_PY_DIR"' EXIT
# An EXECUTABLE stub that always fails. It must be executable or `command -v`
# skips it and finds the real interpreter further down PATH — which is exactly
# what a chmod -x stub did, letting AUTO_MODE reach 1 and stand down (measured:
# all six cases returned allow). Executable-but-failing exercises the same
# fallback as outright absence: every python3 call in the guard returns empty,
# so CMD falls back to the grep extractor, the rm scanner yields no verdict and
# defers to its grep fallback, and PERM_MODE never equals "1" -> AUTO_MODE=0.
printf '#!/bin/sh\nexit 127\n' > "$NO_PY_DIR/python3"
chmod +x "$NO_PY_DIR/python3"
verdict_no_py() { # command -> ask|allow|guard-error(...)
  local payload out rc=0
  payload=$(python3 -c '
import json, sys
print(json.dumps({"tool_name": "Bash", "tool_input": {"command": sys.argv[1]},
                   "permission_mode": "auto"}))' "$1")
  out=$(PATH="$NO_PY_DIR:$PATH" bash "$GUARD" <<<"$payload") || rc=$?
  if [[ "$rc" -ne 0 ]]; then echo "guard-error(rc=$rc)"; return 0; fi
  if grep -q '"permissionDecision":"ask"' <<<"$out"; then echo ask; else echo allow; fi
}
for c in 'git push --force origin main' 'git reset --hard HEAD~1' 'git checkout .' \
         'git restore .' 'git clean -fd' 'rm -rf /etc'; do
  got=$(verdict_no_py "$c")
  check "no-python3, auto: $c" ask "$got"
done

echo
echo "passed: $pass  failed: $fail"
[[ "$fail" -eq 0 ]]
