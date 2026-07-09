#!/usr/bin/env bash
# Measures (a) registry desc tokens by provenance status, (b) observe.sh latency,
# (c) SessionStart injection size. Run before/after each optimization task.
# Universe: repo skills/*/SKILL.md + commands/*.md frontmatter ONLY (session-level
# totals including other installed plugins are larger and out of scope).
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

echo "== skill desc chars by status =="
python3 - <<'EOF'
import json, re, glob
idx = {m['path']: m for m in json.load(open('.upstream-sources.json'))['files']}
def desc(p):
    txt = open(p, encoding='utf-8', errors='replace').read()
    m = re.match(r'^---\n(.*?)\n---', txt, re.S)
    if not m: return ''
    d = re.search(r'^description:\s*(.*?)(?=^\w[\w-]*:|\Z)', m.group(1), re.S | re.M)
    return d.group(1) if d else ''
tot = {}
for f in glob.glob('skills/*/SKILL.md') + glob.glob('commands/*.md'):
    st = idx.get(f, {}).get('status', 'local')
    tot.setdefault(st, [0, 0])
    tot[st][0] += 1; tot[st][1] += len(desc(f))
for st, (n, c) in sorted(tot.items()):
    print(f"  {st:8} {n:4} files {c:7} chars ~{c//4} tokens")
print(f"  TOTAL    {sum(v[0] for v in tot.values()):4} files ~{sum(v[1] for v in tot.values())//4} tokens")
EOF

echo "== observe.sh latency (1 warmup + 5-run avg; fails loud on hook error) =="
payload='{"tool_name":"Bash","tool_input":{"command":"ls"},"cwd":"'"$PWD"'","session_id":"bench"}'
if ! err=$(echo "$payload" | bash skills/continuous-learning-v2/hooks/observe.sh post 2>&1 >/dev/null); then
  echo "observe.sh FAILED: $err"; exit 1
fi
total=0
for _ in 1 2 3 4 5; do
  s=$(python3 -c 'import time;print(int(time.time()*1000))')
  echo "$payload" | bash skills/continuous-learning-v2/hooks/observe.sh post >/dev/null
  e=$(python3 -c 'import time;print(int(time.time()*1000))')
  total=$((total + e - s))
done
echo "  avg: $((total / 5))ms"

echo "== SessionStart injection size (fails loud on hook error) =="
# CLAUDE_PLUGIN_ROOT must point at THIS repo (else the script resolves the
# installed plugin copy or errors), and the payload is a JSON envelope — measure
# the additionalContext field, not the envelope string.
out=$(echo '{"session_id":"bench","cwd":"'"$PWD"'"}' | CLAUDE_PLUGIN_ROOT="$PWD" bash hooks/gate-scripts/load-orchestrator.sh) \
  || { echo "load-orchestrator.sh FAILED"; exit 1; }
printf '%s' "$out" | python3 -c "
import json, sys
ctx = json.load(sys.stdin)['hookSpecificOutput']['additionalContext']
print(f'  additionalContext bytes: {len(ctx)}')"
