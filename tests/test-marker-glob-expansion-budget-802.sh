#!/usr/bin/env bash
# #802 — class-expansion probes must charge the command-wide budgets so a repeated
# bracket-glob payload cannot sit near the pre-implementation gate's 5s timeout
# (a timeout emits no decision, which the harness reads as ALLOW).
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLASSIFIER="$ROOT/hooks/gate-scripts/lib/marker_check.py"
PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
no() { FAIL=$((FAIL + 1)); printf '  FAIL  %s :: %s\n' "$1" "${2:-}"; }

# Classifier verdict for a Bash command. Status is captured separately from stdout so a
# crash that already printed a partial BLOCK_ line cannot satisfy a blocking assertion
# (same contract as tests/test-marker-numeric-case-776.sh).
verdict() {
  local payload out
  payload=$(python3 -c 'import json,sys;print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]}}))' \
    "$1") || { printf 'ERROR'; return; }
  if ! out=$(python3 -I "$CLASSIFIER" <<<"$payload" 2>/dev/null); then
    printf 'ERROR'
    return
  fi
  printf '%s' "$out"
}

# True for a real classification BLOCK, not a crash-shaped BLOCK_CLASSIFIER_ERROR.
is_real_block() {
  case "$1" in
    BLOCK_CLASSIFIER_ERROR|BLOCK_CLASSIFIER_ERROR\|*) return 1 ;;
    BLOCK_*) return 0 ;;
    *) return 1 ;;
  esac
}

# The band measured in #802: 5000 × `[!0-9]x|$A;` (~55KB) previously spent ~3.5s on
# glob-class expansion. Bound by the production 5s hook timeout; after the per-probe
# charge the same shape must return a verdict well inside that window.
# shellcheck disable=SC2016  # $A must stay literal inside the generated payload
PAYLOAD=$(python3 -c 'print("[!0-9]x|$A;" * 5000)')
got=$(python3 - "$CLASSIFIER" "$PAYLOAD" <<'PYEOF' 2>/dev/null || echo TIMEOUT_OR_ERROR
import json, subprocess, sys, time

PROD_TIMEOUT_S = 5
# Headroom guard: the pre-fix band was ~3.5s; require clear clearance under 5s so a
# slow runner still fails this check before production would fail open.
SOFT_MAX_S = 2.0
try:
    t0 = time.perf_counter()
    p = subprocess.run(
        [sys.executable, "-I", sys.argv[1]],
        input=json.dumps({"tool_name": "Bash",
                          "tool_input": {"command": sys.argv[2]}}),
        capture_output=True, text=True, timeout=PROD_TIMEOUT_S,
    )
    dt = time.perf_counter() - t0
except subprocess.TimeoutExpired:
    print("TIMEOUT_OR_ERROR")
else:
    # A non-zero exit is NOT a verdict, even when stdout already carries a BLOCK-prefixed
    # partial line (crash-shaped false pass).
    if p.returncode != 0:
        print("TIMEOUT_OR_ERROR")
    else:
        out = (p.stdout or "").strip() or "TIMEOUT_OR_ERROR"
        print(f"{out}|DT={dt:.3f}")
PYEOF
)

verdict_line="${got%%|DT=*}"
dt_field="${got##*|DT=}"
if [[ "$got" == TIMEOUT_OR_ERROR ]]; then
  no "#802 5000x digit-negation pipeline returns a verdict under the 5s gate" "timed out or errored"
elif [[ "$verdict_line" == BLOCK_CLASSIFIER_ERROR || "$verdict_line" == BLOCK_CLASSIFIER_ERROR\|* ]]; then
  no "#802 5000x digit-negation pipeline returns a verdict under the 5s gate" "classifier crashed: ${verdict_line}"
elif [[ "$verdict_line" != BLOCK_* && "$verdict_line" != "OK|" && "$verdict_line" != "OK" ]]; then
  no "#802 5000x digit-negation pipeline returns a verdict under the 5s gate" "got=${got:-<empty>}"
elif ! python3 -c "import sys; sys.exit(0 if float(sys.argv[1]) <= 2.0 else 1)" "${dt_field:-9}" 2>/dev/null; then
  no "#802 5000x digit-negation pipeline stays under 2s soft bound" "dt=${dt_field:-?}s got=${verdict_line}"
else
  ok "#802 5000x digit-negation pipeline returns ${verdict_line} in ${dt_field}s"
fi

# Precision preserved: a single-character class that cannot reach a helper still misses.
HELPER_MISS=$(python3 -c 'print("python3 hooks/gate-scripts/lib/lease_slo[a].py")')
miss=$(verdict "$HELPER_MISS")
if [[ "$miss" == "OK|" ]]; then
  ok "#802 precise [a] miss still allowed"
else
  no "#802 precise [a] miss still allowed" "got=${miss:-<empty>}"
fi

# Targeted bracket still blocks — crash-shaped BLOCK_CLASSIFIER_ERROR is not a hit.
HELPER_HIT=$(python3 -c 'print("python3 hooks/gate-scripts/lib/lease_slo[t].py")')
hit=$(verdict "$HELPER_HIT")
if is_real_block "$hit"; then
  ok "#802 precise [t] hit still blocks"
else
  no "#802 precise [t] hit still blocks" "got=${hit:-<empty>}"
fi

# Budget-boundary precise miss: a single 2048-byte operand ending in [a] must remain
# OK after the prepaid deep family (Codex on #802). Built inside the classifier driver
# so this shell script does not itself assemble a helper-shaped path in tool_input.
bound=$(python3 - "$CLASSIFIER" <<'PYEOF' 2>/dev/null || echo ERROR
import json, subprocess, sys
stem = "lease" + "_" + "slo"
op = ("a" * (2048 - len(stem + "[a].py"))) + stem + "[a].py"
assert len(op) == 2048
cmd = "python3 " + op
p = subprocess.run(
    [sys.executable, "-I", sys.argv[1]],
    input=json.dumps({"tool_name": "Bash", "tool_input": {"command": cmd}}),
    capture_output=True, text=True,
)
print((p.stdout or "").strip() if p.returncode == 0 else "ERROR")
PYEOF
)
if [[ "$bound" == "OK|" ]]; then
  ok "#802 2048-byte operand ending in [a] still allowed"
else
  no "#802 2048-byte operand ending in [a] still allowed" "got=${bound:-<empty>}"
fi

echo
echo "════ marker-glob-expansion-budget-802: $PASS passed, $FAIL failed ════"
[[ "$FAIL" -eq 0 ]]
