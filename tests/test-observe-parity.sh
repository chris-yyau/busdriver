#!/usr/bin/env bash
# Parity: fast-path observe.sh must (a) keep the legacy observation schema,
# (b) keep secret scrubbing on BOTH phases, (c) keep guard early-exits,
# (d) purge recursively like legacy find, (e) run <200ms on 5-run average
# (budget = the verbatim guard spawns' floor + one fast-path spawn).
set -euo pipefail
repo_root=$(git rev-parse --show-toplevel)
cd "$repo_root"
CLV2_HOMUNCULUS_DIR="$(mktemp -d)"
export CLV2_HOMUNCULUS_DIR
trap 'rm -rf "$CLV2_HOMUNCULUS_DIR"' EXIT
HOOK=skills/continuous-learning-v2/hooks/observe.sh

pre_payload='{"tool_name":"Bash","tool_input":{"command":"export api_key=abcdefgh12345678"},"cwd":"'"$PWD"'","session_id":"parity"}'
post_payload='{"tool_name":"Bash","tool_input":{"command":"ls"},"tool_response":"token=zyxwvuts87654321 done","cwd":"'"$PWD"'","session_id":"parity"}'

echo "$pre_payload"  | bash "$HOOK" pre
echo "$post_payload" | bash "$HOOK" post
obs=$(find "$CLV2_HOMUNCULUS_DIR" -name observations.jsonl | head -1)
[[ -n "$obs" ]] || { echo "FAIL: no observations.jsonl written"; exit 1; }
python3 - "$obs" <<'EOF'
import json, sys
lines = [json.loads(l) for l in open(sys.argv[1])]
start = [o for o in lines if o["event"] == "tool_start"][-1]
done  = [o for o in lines if o["event"] == "tool_complete"][-1]
for o in (start, done):
    req = {"timestamp", "event", "tool", "session", "project_id", "project_name"}
    assert req <= set(o), f"missing fields: {req - set(o)}"
assert "[REDACTED]" in start["input"], "pre-phase input scrubbing lost"
assert "[REDACTED]" in done["output"], "post-phase output scrubbing lost"
assert "input" not in done and "output" not in start, "phase field leakage"
print("schema OK")
EOF

# Guard parity: skip conditions must still write NOTHING
before=$(wc -l < "$obs") || before=0
echo "$post_payload" | ECC_SKIP_OBSERVE=1 bash "$HOOK" post
echo "$post_payload" | ECC_HOOK_PROFILE=minimal bash "$HOOK" post
after=$(wc -l < "$obs") || after=-1
[[ "$after" -eq "$before" ]] || { echo "FAIL: guard early-exit lost"; exit 1; }

# Purge parity: old ARCHIVED rotation file removed, fresh one kept (recursive find semantics)
pdir=$(dirname "$obs")
mkdir -p "$pdir/observations.archive"
old="$pdir/observations.archive/observations-20200101-000000-1.jsonl"
fresh="$pdir/observations.archive/observations-20991231-000000-1.jsonl"
touch "$fresh"
touch -t 200001010000 "$old"
rm -f "$pdir/.last-purge"
echo "$post_payload" | bash "$HOOK" post
[[ ! -f "$old" ]]  || { echo "FAIL: old archived file not purged (recursion lost)"; exit 1; }
[[ -f "$fresh" ]]  || { echo "FAIL: fresh archived file wrongly purged"; exit 1; }
echo "purge OK"

# Latency budget (5-run avg; runs above already warmed the project cache)
total=0
for _ in 1 2 3 4 5; do
  s=$(python3 -c 'import time;print(int(time.time()*1000))')
  echo "$post_payload" | bash "$HOOK" post >/dev/null 2>&1
  e=$(python3 -c 'import time;print(int(time.time()*1000))')
  total=$((total + e - s))
done
avg=$((total / 5))
echo "avg ${avg}ms"
[[ "$avg" -lt 200 ]] || { echo "FAIL: avg ${avg}ms >= 200ms budget"; exit 1; }
echo "PASS"
