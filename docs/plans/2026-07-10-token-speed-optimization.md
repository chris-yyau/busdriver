# Token & Speed Optimization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use busdriver:subagent-driven-development (recommended) or busdriver:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** (A) Repo-landed: cut ~7k tokens of per-session registry/context overhead (registry −4-5k + injection −2.5k + CLAUDE.md −0.7k) and −~400ms of per-tool-call hook latency, verified by `measure-overhead.sh` — this is the PR success criterion. (B) Operator-local (Task 8, approval-gated, tracked separately): a further ~3.7k tokens from the installed user rules. Only provenance-safe mechanisms (vault archive, local edits, sync→custom forks).

**Architecture:** Seven independent optimizations ordered cheapest/safest first. Registry cost is attacked via the ADR 0010 vault mechanism (never deletion) and description diet on local/custom skills only (sync files are never edited in place — ADR 0014). Hook latency is attacked by forking `observe.sh` (sync→custom, precedent: obs 37607 CLV2 divergence) and collapsing its 3 python3 spawns + uncached project detection into one cached fast path.

**Tech Stack:** bash, python3, JSON manifests. No new dependencies.

**Global Constraints (every task must honor):**
- **Never edit a `status: sync` file's content.** If content must change, the same commit flips its manifest entry to `status: custom` (documented fork). Check any file before editing: `python3 -c "import json;print([m for m in json.load(open('.upstream-sources.json'))['files'] if m['path']=='<PATH>'])"`
- **Never delete a skill/command — vault it** (`git mv` to `skills-archive/` / `commands-archive/` + manifest path rewrite + `(vault)` markers). ADR 0010 rejected deletion; do not re-litigate.
- After every task that touches `.upstream-sources.json` or moves files: run `bash tests/test-provenance-guard.sh && bash tests/test-vault-references.sh && bash tests/test-upstream-manifest.sh` — all three must PASS (`test-upstream-manifest.sh` enforces unique paths, the custom-must-keep-`source`+`upstream_path` schema, and that every tracked path exists on disk).
- ShellCheck clean for any touched `*.sh`: `shellcheck <file>`.
- Conventional commits, lowercase subjects. One commit per task. Work on branch `optimize/token-speed`, PR at the end (litmus gate fires per commit — expected, do not bypass).
- Do NOT touch: gate scripts' fail-closed behavior, the arbiter chain, provider scrub, impeccable integration (all SETTLED per CLAUDE.md).

**Prior decisions this plan builds on (do not re-open):**
- ADR 0010 — vault mechanism, deletion rejected, usage telemetry rejected, win = latency + rate-limit headroom.
- ADR 0014 — provenance guard; sync/custom/local semantics.
- Session audit (2026-07-10) measured: live registry ~26k desc tokens (busdriver ~14k of it), local/custom skills avg 475 chars/desc vs vendored 210, `observe.sh` ~570ms × 2 per tool call, `load-orchestrator.sh` injects 15.4KB per session.

**Measured baseline (re-verify in Task 0; universe = repo `skills/*/SKILL.md` + `commands/*.md` frontmatter ONLY):** repo desc total ≈ 15.8k tokens, of which local+custom ≈ 6.9k; `observe.sh` wall ≈ 570ms; SessionStart orchestrator injection ≈ 15.4KB. (The ~26k figure from the session audit includes other installed plugins' skills — context only, never a task target or verification number.)

---

### Task 0: Baseline measurement harness

**Files:**
- Create: `scripts/audit/measure-overhead.sh`

This script is the verifier for every later task — savings claims must come from it, not estimates.

- [ ] **Step 1: Write the measurement script**

```bash
#!/usr/bin/env bash
# Measures (a) registry desc tokens by provenance status, (b) observe.sh latency,
# (c) SessionStart injection size. Run before/after each optimization task.
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
```

- [ ] **Step 2: Make executable, run, record baseline numbers in the PR description**

Run: `chmod +x scripts/audit/measure-overhead.sh && ./scripts/audit/measure-overhead.sh`
Expected: status table (sync ≈ 137 skills, custom ≈ 33, local ≈ 36+), observe.sh avg in the 400-700ms range, injection ≈ 15000+ bytes.

- [ ] **Step 3: Commit**

```bash
git checkout -b optimize/token-speed
git add scripts/audit/measure-overhead.sh
git commit -m "chore: add overhead measurement harness for optimization audit"
```

---

### Task 1: Register ultraoracle in the provenance manifest (audit item 7)

**Files:**
- Modify: `.upstream-sources.json`

`skills/ultraoracle/` (SKILL.md + scripts/) is git-tracked but absent from `.upstream-sources.json` — the only live skill missing from the manifest. (No `git add` needed; this is manifest registration only.)

- [ ] **Step 1: Add entries for every file under skills/ultraoracle/**

```bash
python3 - <<'EOF'
import json, glob
p = '.upstream-sources.json'
d = json.load(open(p))
tracked = {m['path'] for m in d['files']}
added = []
for f in sorted(glob.glob('skills/ultraoracle/**/*', recursive=True)):
    import os
    if os.path.isfile(f) and f not in tracked:
        d['files'].append({'path': f, 'source': 'local', 'status': 'local'})
        added.append(f)
with open(p, 'w') as fh:
    json.dump(d, fh, indent=2)
    fh.write('\n')   # manifest ends with a newline — avoid whole-file churn
print('added:', added)
EOF
```

Expected: `added:` lists `skills/ultraoracle/SKILL.md` plus files under `skills/ultraoracle/scripts/`.

- [ ] **Step 2: Run guard tests**

Run: `bash tests/test-provenance-guard.sh && bash tests/test-vault-references.sh && bash tests/test-upstream-manifest.sh`
Expected: all three PASS.

- [ ] **Step 3: Commit**

```bash
git add .upstream-sources.json
git commit -m "fix(upstream): register untracked ultraoracle skill as local in manifest"
```

---

### Task 2: Project CLAUDE.md diet (audit item 4)

**Files:**
- Modify: `.claude/CLAUDE.md` (12,785 bytes → target ≤ 10,000; exact arithmetic: 12,785 − 3,806 removed + 883 added = 9,862)

The three pr-grind opt-in blocks restate ADRs 0012/0013 and the solo-admin design at paragraph length. Replace with a pointer table; the ADRs and `skills/pr-grind/SKILL.md` remain the source of truth.

- [ ] **Step 1: Replace the three opt-in paragraphs**

Locate the block starting `**Related per-repo operator-consent file (NOT a gate...**` through the end of the ADR 0012 paragraph (the three consecutive `**Related...**` paragraphs under the gates table). Replace all three with:

```markdown
**Per-repo pr-grind opt-in files** (all gitignored `.local`; full semantics in the linked ADR / `skills/pr-grind/SKILL.md` flag table — read those before touching):

| File | One-line effect | Source of truth |
|------|-----------------|-----------------|
| `.claude/pr-grind-auto-admin-solo.local` | Solo-admin repos: `--admin-on-approver-gap` implicit, snapshot-anchored anti-self-bypass, self-revokes if a 2nd approver appears | `skills/pr-grind/SKILL.md` flag table |
| `.claude/pr-grind-codex-expected.local` | One-shot `@codex review` nudge when Codex never auto-triggered (`none`) before merge | `docs/adr/0013-codex-none-nudge-opt-in.md` |
| `.claude/pr-grind-advisory-downgrade.local` | At `--max-wait` exhaustion, may downgrade a 0-finding advisory bot's stale ack `stale→none`; never touches merge authority | `docs/adr/0012-advisory-bot-stale-timeout-downgrade.md` |
```

- [ ] **Step 2: Verify size and content integrity**

Run: `wc -c .claude/CLAUDE.md && grep -c "pr-grind" .claude/CLAUDE.md`
Expected: ≤ 10,000 bytes (9,862 if the replacement is applied exactly); pr-grind references still present. Confirm the gates table, version-sync, CI, and Conventions sections are untouched (`git diff` shows only the three paragraphs replaced).

- [ ] **Step 3: Commit**

```bash
git add .claude/CLAUDE.md
git commit -m "docs: replace pr-grind opt-in paragraphs with adr pointer table"
```

---

### Task 3: Archive legacy command shims (audit item 5)

**Files:**
- Move: `commands/<shim>.md` → `commands-archive/<shim>.md` (for each confirmed shim)
- Modify: `.upstream-sources.json` (path rewrite, same pattern as ADR 0010)

- [ ] **Step 1: Confirm the shim list — only self-described legacy shims**

Run: `grep -l "Legacy slash-entry shim" commands/*.md`
Expected (verify against actual output; archive ONLY what this grep returns): `e2e.md`, `eval.md`, `orchestrate.md`, `prompt-optimize.md`, `rules-distill.md`, `tdd.md`, `verify.md`. **Accepted tradeoff:** the `/e2e`, `/eval`, etc. slash entry points disappear; the backing skills stay live and invocable (Skill tool + natural language), and any shim promotes back with one `git mv`. This tradeoff is approved by approving this plan.

- [ ] **Step 2: Move shims and rewrite manifest paths**

```bash
mkdir -p commands-archive
for f in $(grep -l "Legacy slash-entry shim" commands/*.md); do git mv "$f" "commands-archive/$(basename "$f")"; done
# Manifest rewrite scoped to EXACTLY the moved shims (never existence-driven —
# archives already exist, a blanket rewrite could touch unrelated entries)
moved=$(grep -l "Legacy slash-entry shim" commands-archive/*.md | xargs -n1 basename)
# shellcheck disable=SC2086
python3 - $moved <<'EOF'
import json, sys
names = set(sys.argv[1:])
p = '.upstream-sources.json'
d = json.load(open(p))
for m in d['files']:
    base = m['path'].rsplit('/', 1)[-1]
    if m['path'].startswith('commands/') and base in names:
        m['path'] = 'commands-archive/' + base
with open(p, 'w') as fh:
    json.dump(d, fh, indent=2)
    fh.write('\n')
EOF
```

- [ ] **Step 3: Mark active-surface references with (vault) — driven by the guard test itself**

Run `bash tests/test-vault-references.sh`. It scans ALL active surfaces (`skills agents commands hooks scripts rules` — do not substitute a narrower ad-hoc grep). For every violation line it reports, append ` (vault)` on that line. Re-run until PASS.

- [ ] **Step 4: Run guard tests + commit**

Run: `bash tests/test-vault-references.sh && bash tests/test-provenance-guard.sh && bash tests/test-upstream-manifest.sh`
Expected: all three PASS.

```bash
git add -A commands commands-archive .upstream-sources.json skills agents hooks scripts rules
git commit -m "refactor: archive legacy command shims to commands-archive"
```

(The wide `git add` list matters: `(vault)` markers from Step 3 can land in any surface `test-vault-references.sh` scans — skills/agents/hooks/scripts/rules — and an unstaged marker would pass locally but fail in CI.)

---

### Task 4: Vault the firecrawl/tavily long tail (audit item 2a)

**Files:**
- Move: 20 skill dirs → `skills-archive/` (see list)
- Modify: `.upstream-sources.json`, any referencing active surface (add `(vault)` markers)

**Decision (default — operator can veto individual skills):** keep the two umbrellas live — `firecrawl` and `tavily-cli` (their descriptions cover search/scrape/crawl/interact, and `deep-research` references only these two). Vault the 20 family members — 16 are `status: local`; the 4 `firecrawl-build-*` dirs are `status: custom` (source=firecrawl, `upstream_path` set), which vault fine per ADR 0010: the path-rewrite script below rewrites only `path`, preserving `source`/`status`/`upstream_path`, so upstream sync keeps landing updates in the archive:

`firecrawl-agent, firecrawl-build-interact, firecrawl-build-onboarding, firecrawl-build-scrape, firecrawl-build-search, firecrawl-crawl, firecrawl-download, firecrawl-interact, firecrawl-map, firecrawl-monitor, firecrawl-parse, firecrawl-scrape, firecrawl-search, tavily-best-practices, tavily-crawl, tavily-dynamic-search, tavily-extract, tavily-map, tavily-research, tavily-search`

(That is 13 firecrawl + 7 tavily = 20 dirs; keep `firecrawl` and `tavily-cli` live.) Promotion back is one `git mv` (ADR 0010 manual-on-friction model — >3 promotions in 60 days is the recorded revisit trigger).

- [ ] **Step 1: Move the dirs**

```bash
mkdir -p skills-archive
VAULT_SKILLS="firecrawl-agent firecrawl-build-interact firecrawl-build-onboarding firecrawl-build-scrape firecrawl-build-search firecrawl-crawl firecrawl-download firecrawl-interact firecrawl-map firecrawl-monitor firecrawl-parse firecrawl-scrape firecrawl-search tavily-best-practices tavily-crawl tavily-dynamic-search tavily-extract tavily-map tavily-research tavily-search"
for s in $VAULT_SKILLS; do
  git mv "skills/$s" "skills-archive/$s"
done
```

- [ ] **Step 2: Rewrite manifest paths — scoped to EXACTLY the moved dirs**

```bash
# shellcheck disable=SC2086
python3 - $VAULT_SKILLS <<'EOF'
import json, sys
names = set(sys.argv[1:])
p = '.upstream-sources.json'
d = json.load(open(p))
for m in d['files']:
    parts = m['path'].split('/')
    if parts[0] == 'skills' and len(parts) > 1 and parts[1] in names:
        m['path'] = 'skills-archive/' + '/'.join(parts[1:])
with open(p, 'w') as fh:
    json.dump(d, fh, indent=2)
    fh.write('\n')
EOF
```

(Run Steps 1-2 in the same shell invocation so `$VAULT_SKILLS` is defined for both; or paste the list twice — never fall back to an existence-driven blanket rewrite.)

- [ ] **Step 3: Add (vault) markers to active references — driven by the guard test itself**

Run `bash tests/test-vault-references.sh` (scans `skills agents commands hooks scripts rules`). For every violation it reports, append ` (vault)` on that line; re-run until PASS. Likely hit sites include `skills/orchestrator/tasks-catalog.md` and `skills/deep-research/SKILL.md`, but the test output is authoritative — do not treat that list as exhaustive. Umbrella names `firecrawl`/`tavily-cli` stay live and need NO marker.

- [ ] **Step 4: Guard tests, measure, commit**

Run: `bash tests/test-vault-references.sh && bash tests/test-provenance-guard.sh && bash tests/test-upstream-manifest.sh && ./scripts/audit/measure-overhead.sh`
Expected: tests PASS; local+custom desc tokens drop by ~2,500-3,000.

```bash
git add -A skills skills-archive .upstream-sources.json commands agents hooks scripts rules
git commit -m "refactor: vault firecrawl/tavily long-tail skills behind umbrellas"
```

---

### Task 5: Description diet on live local/custom skills (audit item 2b)

**Files:**
- Modify: frontmatter `description:` of every live `local`/`custom` skill whose description exceeds 400 chars (~15 files after Task 4)

**Quality guard:** descriptions are trigger metadata — keep the highest-signal trigger phrases, cut enumerations and prose. Never trim a `sync` skill (they average 210 chars already and edits would drift).

- [ ] **Step 1: List offenders**

```bash
python3 - <<'EOF'
import json, re, glob
idx = {m['path']: m for m in json.load(open('.upstream-sources.json'))['files']}
for f in sorted(glob.glob('skills/*/SKILL.md')):
    st = idx.get(f, {}).get('status', 'local')
    if st == 'sync': continue
    txt = open(f, encoding='utf-8', errors='replace').read()
    m = re.match(r'^---\n(.*?)\n---', txt, re.S)
    d = re.search(r'^description:\s*(.*?)(?=^\w[\w-]*:|\Z)', m.group(1), re.S | re.M) if m else None
    n = len(d.group(1)) if d else 0
    cap = 600 if '/council/' in f else 400   # council: documented routing-vocabulary exception
    if n > cap: print(f"{n:5} {st:7} {f}")
EOF
```

- [ ] **Step 2: Rewrite each listed description to ≤300 chars**

Exact replacements for the known top offenders (apply with Edit on each SKILL.md frontmatter; the surrounding body is untouched). YAML rule: emit every rewritten description as a folded block scalar (`description: >-` with indented text) so embedded colons like `Triggers:` cannot parse as a nested mapping. For each rewrite, list the dropped trigger phrases in the commit message body (retained-trigger checklist):

`skills/council/SKILL.md` (1,119 → ~520; council is the single documented exception to the 400-char cap — its trigger vocabulary routes three modes). The `ultra-council`, `ultimate-council`, UltraOracle, and Mythos Witness trigger words MUST survive the diet:

```yaml
description: >-
  Convene a 5-voice AI council (Architect, Skeptic, Pragmatist, Critic,
  Researcher) for ambiguous decisions needing multiple lenses — design,
  tradeoffs, architecture, strategy. Triggers include council, roundtable,
  perspectives, group wisdom, ideas/feedback/advice; "ultra-council" adds the
  UltraOracle (GPT-5.5 Pro) expert witness; "ultimate-council" adds BOTH the
  UltraOracle AND the Mythos Witness (Claude Fable via the zenmux gateway),
  each rendered separately, never a vote. Not for simple tasks with clear
  answers.
```

`skills/agent-browser/SKILL.md` (925 → ~300):
```yaml
description: >-
  Browser automation CLI for AI agents — navigate, click, fill forms,
  screenshot, extract data, test web apps, automate Electron apps, or drive
  cloud browsers. Prefer over built-in browser automation. Triggers include
  open/test a website, fill a form, click, scrape a page, login, QA/bug-hunt
  a web app.
```

`skills/tavily-cli/SKILL.md` (809 → ~240):
```yaml
description: >-
  Web search, extract, crawl, and site-map via the vendored Tavily CLI. Use
  for real-time web research, finding articles/news/docs, or grounding
  answers in live sources. Triggers include search the web, look up, find
  articles, research a topic online.
```

`skills/firecrawl/SKILL.md` (704 → ~290):
```yaml
description: >-
  Search, scrape, crawl, and interact with the web via the Firecrawl CLI —
  any URL as clean markdown, JS-rendered pages included, plus
  clicks/logins/forms. Triggers include fetch/scrape/grab a page, get content
  from a URL, crawl docs, search the web, interact with a page. Prefer over
  WebFetch.
```

(`deep-research` is 378 chars — already under the 400 threshold; leave it alone.) For the remaining offenders from Step 1 (`loop-design-check`, `ui-ux-pro-max`, `ultraoracle`, `caveman`, etc. — sync-status skills like `token-budget-advisor`/`blueprint` are SKIPPED), apply the formula: sentence 1 = capability, sentence 2 = strongest 4-6 trigger phrases from the original, optional sentence 3 = one NOT-for exclusion. Emit as `description: >-` folded scalars like the examples above. Hard cap 400 chars (300 where no routing vocabulary is at stake; council is the one documented exception at ≤600). Never invent triggers not present in the original; never drop a trigger word that is the ONLY route to a mode (grep the skill body + orchestrator routing files for the candidate word before dropping it).

- [ ] **Step 3: Verify no offender remains and nothing else changed**

Run: the Step 1 script again.
Expected: no output (no live local/custom desc over its cap — 400, council 600). Then validate every edited frontmatter with a real YAML parser (not the regex):

```bash
# uv is already a project tool (scripts/test-python.sh) — pyyaml is fetched
# ephemerally for validation only, NOT added as a dependency.
for f in $(git diff --name-only -- 'skills/*/SKILL.md'); do
  uv run --with pyyaml python3 -c "
import re, sys, yaml
t = open('$f').read()
m = re.match(r'^---\n(.*?)\n---', t, re.S)
d = yaml.safe_load(m.group(1))
assert isinstance(d.get('description'), str) and d['description'].strip(), '$f: bad description'
" || exit 1
done; echo "YAML OK"
```

Run `git diff --stat` — only SKILL.md files, only frontmatter lines.

- [ ] **Step 4: Measure + commit**

Run: `./scripts/audit/measure-overhead.sh`
Expected: local+custom desc tokens ≤ ~4,000 (from ~6,600 pre-Task-4).

```bash
git add skills/*/SKILL.md
git commit -m "refactor: trim local and custom skill descriptions to trigger essentials"
```

---

### Task 6: Slim the SessionStart orchestrator injection (audit item 3)

**Files:**
- Create: `skills/orchestrator/session-brief.md` (~2.5KB)
- Modify: `hooks/gate-scripts/load-orchestrator.sh` (local file — free to edit)
- Test: manual invocation + shellcheck

**Interfaces:**
- Consumes: `skills/orchestrator/SKILL.md` sections (pipeline directive, gates table, supplement protocol, vault convention)
- Produces: `session-brief.md` injected at SessionStart; full SKILL.md still loads via the Skill tool when routing is actually needed

**Quality guard:** the brief MUST retain verbatim: the `<EXTREMELY-IMPORTANT>` pipeline directive, the gates table (all 6 gates + skip files), the supplement-loading protocol sentence, the vault `(vault)` loading convention, the design-review CRITICAL block (the instruction to invoke `busdriver:blueprint-review`, never code-reviewer, for plans/design docs), and the Emergency Gate Recovery hard rules. Everything else (architecture prose, examples, per-phase detail) moves behind `Skill(busdriver:orchestrator)`.

- [ ] **Step 1: Extract the brief**

Read `skills/orchestrator/SKILL.md`; create `skills/orchestrator/session-brief.md` with exactly these sections, copied verbatim from the SKILL.md (do not paraphrase the directive or the gates table):

```markdown
# Orchestrator Session Brief

<EXTREMELY-IMPORTANT>
[copy the pipeline directive block verbatim from SKILL.md]
</EXTREMELY-IMPORTANT>

## Gates (Hook-Enforced)
[copy the gates table verbatim from SKILL.md]

## Routing
For any task beyond a trivial Q&A: INVOKE `busdriver:orchestrator` (Skill tool) for full
routing, or Read `skills/orchestrator/tasks-catalog.md` (non-pipeline tasks) /
`domain-supplements.md` (domain detection). Rows marked `(vault)` point at archived
skills — Read the archived file on demand and apply it.

## Supplements
[copy the Supplement Loading Protocol paragraph verbatim from SKILL.md]

## Design Review (CRITICAL)
[copy the CRITICAL block verbatim from SKILL.md — invoke busdriver:blueprint-review
(never code-reviewer) for plans/design docs]

## Emergency Gate Recovery
[copy the Emergency Gate Recovery hard rules verbatim from SKILL.md]
```

Verify size: `wc -c skills/orchestrator/session-brief.md` — expected ≤ 4,000 bytes.

- [ ] **Step 2: Point load-orchestrator.sh at the brief**

In `hooks/gate-scripts/load-orchestrator.sh`, locate the line(s) that read the orchestrator SKILL.md for injection (`grep -n "orchestrator/SKILL.md" hooks/gate-scripts/load-orchestrator.sh`). Replace the path with `skills/orchestrator/session-brief.md`, keeping the fallback: if the brief is missing, fall back to the full SKILL.md (never inject nothing — the pipeline directive is load-bearing):

```bash
ORCH_CONTEXT_FILE="${PLUGIN_ROOT}/skills/orchestrator/session-brief.md"
[ -f "$ORCH_CONTEXT_FILE" ] || ORCH_CONTEXT_FILE="${PLUGIN_ROOT}/skills/orchestrator/SKILL.md"
```

(Adapt variable names to what the script actually uses at the grep'd line; all other logic — health checks, instinct loading, observer-session skip — stays untouched.)

- [ ] **Step 3: Test the hook end-to-end**

Run:
```bash
shellcheck hooks/gate-scripts/load-orchestrator.sh
out=$(echo '{"session_id":"t","cwd":"'"$PWD"'"}' | CLAUDE_PLUGIN_ROOT="$PWD" bash hooks/gate-scripts/load-orchestrator.sh)
for marker in "EXTREMELY-IMPORTANT" "blueprint-review" "skip-design-review" "Supplement" "(vault)" "Emergency Gate Recovery"; do
  echo "$out" | grep -qF "$marker" || { echo "MISSING: $marker"; exit 1; }
done; echo "markers OK"
./scripts/audit/measure-overhead.sh
```
Expected: shellcheck clean; all six markers present in the hook output; `measure-overhead.sh`'s additionalContext measurement drops from ~15,000+ to ≤ 6,000 bytes (brief + health warnings + instincts). (`CLAUDE_PLUGIN_ROOT="$PWD"` is required — without it the script resolves the installed plugin cache, not this repo's edit.)

- [ ] **Step 4: Add both new/changed files to the manifest check + commit**

`session-brief.md` is a new local file — add `{"path": "skills/orchestrator/session-brief.md", "source": "local", "status": "local"}` to `.upstream-sources.json` (same python pattern as Task 1, trailing newline included). Run `bash tests/test-provenance-guard.sh && bash tests/test-vault-references.sh && bash tests/test-upstream-manifest.sh` — all three PASS.

```bash
git add skills/orchestrator/session-brief.md hooks/gate-scripts/load-orchestrator.sh .upstream-sources.json
git commit -m "perf: inject condensed orchestrator brief at sessionstart instead of full skill"
```

---

### Task 7: Fork and fast-path observe.sh (audit item 1)

**Files:**
- Modify: `skills/continuous-learning-v2/hooks/observe.sh` (sync → **fork to custom first**)
- Modify: `.upstream-sources.json` (status flip)
- Create: `skills/continuous-learning-v2/hooks/observe_fast.py`
- Create: `tests/test-observe-parity.sh`

**Interfaces:**
- Consumes: Claude Code hook stdin JSON (`tool_name`, `tool_input`, `tool_response`, `session_id`, `cwd`) + phase arg `pre|post`
- Produces: byte-compatible observation lines in `${PROJECT_DIR}/observations.jsonl` (schema: `timestamp,event,tool,session,project_id,project_name[,input][,output]`) — the observer agent and `instinct-cli.py` consume this file and must see no format change

**Decision (default):** keep BOTH observation pipelines' functions (CLV2 → instincts, claude-mem → memory are different capabilities); fix the latency instead of disabling. observe.sh is registered in `hooks/hooks.json` via `scripts/hooks/run-with-flags-shell.sh` — rewriting observe.sh in place keeps that registration working. (The parity test and Task 0 harness call observe.sh directly; the wrapper adds a small constant overhead present in both before and after measurements, so deltas stay valid.)

**Why fork is safe:** CLV2 already diverges from upstream ECC (obs 37607); ADR 0014's `custom` status exists exactly for this. Consider PRing the optimization to ECC upstream afterwards (out of scope here).

**Split contract (bash keeps the guards, python replaces only the spawns):**
- **bash keeps VERBATIM** (cheap and load-bearing): stdin read + empty-input exit, phase-arg handling, cwd extraction with the `[ -n "$STDIN_CWD" ] && [ -d "$STDIN_CWD" ]` existence guard (~line 117), the `CLAUDE_PROJECT_DIR`/`CLV2_NO_PROJECT` exports (~lines 106-126), ALL five anti-self-loop guards (disabled-config ~141-146, `CLAUDE_CODE_ENTRYPOINT` allowlist ~157-160, `ECC_HOOK_PROFILE=minimal` ~163, `ECC_SKIP_OBSERVE=1` ~166, agent-id + skip-paths ~168-182), python-interpreter resolution incl. the Windows-stub guard, project detection, and the observer lazy-start + throttled SIGUSR1 block at the end.
- **bash gains ONE thing:** a project-detection cache — before `source detect-project.sh`, source a cwd-keyed cache file if <5 min old; else detect and write the cache atomically (Step 4).
- **python replaces ONLY** the three inline python blocks + rotation + purge + append, as a single **non-exec child** process (`observe_fast.py`). Contract: `INPUT_JSON` on stdin; `HOOK_PHASE`, `PROJECT_ID`, `PROJECT_NAME`, `PROJECT_DIR` via env — all computed bash-side, so nothing flows back from python to bash; the lazy-start block after it uses the same bash variables as today. Do NOT use `exec` (it would kill the lazy-start/signal block).
- **Serialization parity note:** the legacy `str()` fallback for non-dict tool I/O (observe.sh ~237-245) is INTENTIONAL parity behavior — port it byte-for-byte. Do NOT "fix" it to json.dumps inside this task; that would be a separately-scoped behavior change with its own test.

- [ ] **Step 1: Profile to confirm the breakdown before rewriting**

Run:
```bash
payload='{"tool_name":"Bash","tool_input":{"command":"ls"},"cwd":"'"$PWD"'","session_id":"bench"}'
echo "$payload" | bash -x skills/continuous-learning-v2/hooks/observe.sh post 2>&1 | grep -c "^+"   # spawn count
time (echo "$payload" | bash skills/continuous-learning-v2/hooks/observe.sh post)
time bash skills/continuous-learning-v2/scripts/detect-project.sh 2>/dev/null || true
```
Record which dominates (expected: 3× python3 spawns + `detect-project.sh` git calls + du/find/date spawns). If the measured total is already < 150ms on this machine, STOP this task and report — the earlier 571ms measurement would then be run-with-flags wrapper overhead and the fix belongs there instead.

- [ ] **Step 2: Flip provenance to custom**

```bash
python3 - <<'EOF'
import json
p = '.upstream-sources.json'
d = json.load(open(p))
for m in d['files']:
    if m['path'] == 'skills/continuous-learning-v2/hooks/observe.sh':
        m['status'] = 'custom'
json.dump(d, open(p, 'w'), indent=2)
EOF
bash tests/test-provenance-guard.sh && bash tests/test-upstream-manifest.sh
```
Expected: both PASS. The flip changes ONLY `status` — `source: ecc` and the existing `upstream_path` stay (the custom schema requires both), so upstream sync still tracks the file.

- [ ] **Step 3: Write the parity test FIRST (red on latency ONLY)**

Create `tests/test-observe-parity.sh`. Isolation uses `CLV2_HOMUNCULUS_DIR` (an absolute path — first in `homunculus-dir.sh`'s resolution order), NOT `HOME` redirection. Secrets are placed phase-correctly: `tool_input` asserted on the `tool_start` line (pre), `tool_response` on the `tool_complete` line (post) — legacy writes only `input` on pre and only `output` on post (observe.sh ~247-256).

```bash
#!/usr/bin/env bash
# Parity: fast-path observe.sh must (a) keep the legacy observation schema,
# (b) keep secret scrubbing on BOTH phases, (c) keep guard early-exits,
# (d) purge recursively like legacy find, (e) run <200ms on 5-run average
# (budget = the verbatim guard spawns' floor + one fast-path spawn).
# On the legacy script, (a)-(d) PASS and only (e) fails — that is the red state.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
CLV2_HOMUNCULUS_DIR="$(mktemp -d)"
export CLV2_HOMUNCULUS_DIR
trap 'rm -rf "$CLV2_HOMUNCULUS_DIR"' EXIT
HOOK=skills/continuous-learning-v2/hooks/observe.sh

pre_payload='{"tool_name":"Bash","tool_input":{"command":"export api_key=abcdefgh12345678"},"cwd":"'"$PWD"'","session_id":"parity"}'
post_payload='{"tool_name":"Bash","tool_input":{"command":"ls"},"tool_response":"token=zyxwvuts87654321 done","cwd":"'"$PWD"'","session_id":"parity"}'

echo "$pre_payload"  | bash "$HOOK" pre
echo "$post_payload" | bash "$HOOK" post
obs=$(find "$CLV2_HOMUNCULUS_DIR" -name observations.jsonl | head -1)
[ -n "$obs" ] || { echo "FAIL: no observations.jsonl written"; exit 1; }
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
before=$(wc -l < "$obs")
echo "$post_payload" | ECC_SKIP_OBSERVE=1 bash "$HOOK" post
echo "$post_payload" | ECC_HOOK_PROFILE=minimal bash "$HOOK" post
[ "$(wc -l < "$obs")" -eq "$before" ] || { echo "FAIL: guard early-exit lost"; exit 1; }

# Purge parity: old ARCHIVED rotation file removed, fresh one kept (recursive find semantics)
pdir=$(dirname "$obs")
mkdir -p "$pdir/observations.archive"
old="$pdir/observations.archive/observations-20200101-000000-1.jsonl"
fresh="$pdir/observations.archive/observations-20991231-000000-1.jsonl"
touch "$fresh"
touch -t 200001010000 "$old"
rm -f "$pdir/.last-purge"
echo "$post_payload" | bash "$HOOK" post
[ ! -f "$old" ]  || { echo "FAIL: old archived file not purged (recursion lost)"; exit 1; }
[ -f "$fresh" ]  || { echo "FAIL: fresh archived file wrongly purged"; exit 1; }

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
[ "$avg" -lt 200 ] || { echo "FAIL: avg ${avg}ms >= 200ms budget"; exit 1; }
echo "PASS"
```

Run: `chmod +x tests/test-observe-parity.sh && bash tests/test-observe-parity.sh`
Expected: schema, scrubbing, guard, and purge assertions PASS against the legacy script; the test FAILS on the latency assertion only (~570ms ≥ 200ms). If any earlier assertion fails on legacy, the test itself is wrong — fix the test before touching the hook.

- [ ] **Step 4: Write the fast path**

Two changes, per the Split contract above. The legacy file is authoritative for every ported behavior — read observe.sh in full while porting; the code below is the skeleton.

**(4a) `observe.sh`: add the project-detection cache.** Replace the bare `source "${SKILL_ROOT}/scripts/detect-project.sh"` (~line 193) with a cwd-keyed cached version (CONFIG_DIR is already resolved at ~line 138). All guards before it and the lazy-start/signal block after the write stay byte-identical:

The cached variable set MUST be derived from the script itself at implementation time — run `grep -n 'export' skills/continuous-learning-v2/scripts/lib/../detect-project.sh` (i.e. `skills/continuous-learning-v2/scripts/detect-project.sh`) and cache EVERY variable it exports, not just the four PROJECT_* ones. As of this plan that includes at least `CLV2_OBSERVER_SENTINEL_FILE`, `CLV2_PYTHON_CMD`, and `CLV2_OBSERVER_PROMPT_PATTERN`, which the preserved lazy-start/observer block depends on — a 4-variable cache breaks the observer on warm-cache runs. Directory side-effects are re-applied on every run (`mkdir -p`), cheap and idempotent:

```bash
# ponytail: cwd-keyed detect-project cache, 5-min TTL — delete the cache file
# (or wait 5 min) after a git init/root change; atomic mktemp+mv write.
# CACHE CONTRACT: every `export`ed var of detect-project.sh must be cached
# (grep the script; extend the printf below if upstream adds exports).
_PROJ_CACHE=""
if command -v shasum >/dev/null 2>&1; then
  _key=$(printf '%s' "$STDIN_CWD" | shasum -a 256 | cut -c1-16)
  _PROJ_CACHE="${CONFIG_DIR}/.proj-cache-${_key}"
fi
if [ -n "$_PROJ_CACHE" ] && [ -f "$_PROJ_CACHE" ] \
   && [ -z "$(find "$_PROJ_CACHE" -mmin +5 2>/dev/null)" ]; then
  # shellcheck disable=SC1090
  . "$_PROJ_CACHE"
  mkdir -p "$PROJECT_DIR" 2>/dev/null || true   # re-apply dir side-effect
else
  source "${SKILL_ROOT}/scripts/detect-project.sh"
  if [ -n "$_PROJ_CACHE" ]; then
    _tmp=$(mktemp "${CONFIG_DIR}/.proj-cache.XXXXXX" 2>/dev/null) && {
      printf 'export PROJECT_ID=%q PROJECT_NAME=%q PROJECT_ROOT=%q PROJECT_DIR=%q\n' \
        "$PROJECT_ID" "$PROJECT_NAME" "$PROJECT_ROOT" "$PROJECT_DIR" > "$_tmp"
      printf 'export CLV2_OBSERVER_SENTINEL_FILE=%q CLV2_PYTHON_CMD=%q CLV2_OBSERVER_PROMPT_PATTERN=%q\n' \
        "${CLV2_OBSERVER_SENTINEL_FILE:-}" "${CLV2_PYTHON_CMD:-}" "${CLV2_OBSERVER_PROMPT_PATTERN:-}" >> "$_tmp"
      mv "$_tmp" "$_PROJ_CACHE"
    }
  fi
fi
```

**(4b) Replace the three payload-processing python blocks + rotation + purge + append** (observe.sh ~lines 200-362) with ONE non-exec child call — bash keeps everything after it. Spawn-count honesty: observe.sh has 6+ `$PYTHON_CMD` sites in total; this consolidates the three payload-processing ones (~L212/L262/L316). The guard-related spawns earlier in the file (~L106 cwd extraction, ~L169 agent-id check) stay — they are part of the verbatim-guard contract. That guard floor is why the latency budget below is 200ms, not 50ms.

```bash
# printf, NOT a heredoc: an unquoted heredoc would shell-expand $/backticks
# inside the JSON payload; a quoted delimiter would block $INPUT_JSON itself.
printf '%s' "$INPUT_JSON" | HOOK_PHASE="$HOOK_PHASE" PROJECT_ID="$PROJECT_ID" \
  PROJECT_NAME="$PROJECT_NAME" PROJECT_DIR="$PROJECT_DIR" \
  "$PYTHON_CMD" "${SCRIPT_DIR}/observe_fast.py" || true
```

Create `skills/continuous-learning-v2/hooks/observe_fast.py`. Port verbatim (they encode fixed bugs — #2278 catastrophic backtracking, #2300 SIGALRM orphan): `_SECRET_RE`, `signal.alarm(8)` bail, 5000-char truncate-then-scrub order, the conditional field emission (`input` only if truthy, `output` only if not None), the `str()` fallback (intentional — see Split contract), the parse-error fallback line format, 10MB rotation, and the **recursive** 30-day purge matching `find "$PROJECT_DIR" -name "observations-*.jsonl" -mtime +30 -delete` (includes `observations.archive/`):

```python
#!/usr/bin/env python3
"""CLV2 fast-path writer: replaces observe.sh's three inline python blocks
(parse, validate, build+scrub+write) plus rotation/purge with ONE spawn.
Bash owns: all guards, project detection (cached), observer lazy-start/signal.
Contract: INPUT_JSON on stdin; HOOK_PHASE, PROJECT_ID, PROJECT_NAME,
PROJECT_DIR via env. Output is schema-parity with legacy
(tests/test-observe-parity.sh); the str() fallback for non-dict tool I/O is
INTENTIONAL parity behavior (legacy observe.sh:237-245) — do not "fix" here."""
import json, os, re, signal, sys, time

def _bail(*_):
    print("[observe] SIGALRM timeout: observation dropped before write (#2300)",
          file=sys.stderr)
    sys.exit(0)
try:
    signal.signal(signal.SIGALRM, _bail)
    signal.alarm(8)
except Exception:
    pass

_SECRET_RE = re.compile(
    r"(?i)(api[_-]?key|token|secret|password|authorization|credentials?|auth)"
    r"(['\"\s:=]{1,8})"
    r"((?:bearer|basic|token|bot)\s+)?"
    r"([A-Za-z0-9_\-/.+=]{8,256})"
)
def scrub(v):
    return None if v is None else _SECRET_RE.sub(
        lambda m: m.group(1) + m.group(2) + (m.group(3) or "") + "[REDACTED]",
        str(v))

pdir = os.environ.get("PROJECT_DIR", "")
if not pdir:
    sys.exit(0)
obs_file = os.path.join(pdir, "observations.jsonl")
ts = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
raw = sys.stdin.read()
if not raw.strip():
    sys.exit(0)
phase = os.environ.get("HOOK_PHASE", "post")

try:
    data = json.loads(raw)
except Exception:
    os.makedirs(pdir, exist_ok=True)
    with open(obs_file, "a") as fh:
        fh.write(json.dumps({"timestamp": ts, "event": "parse_error",
                             "raw": scrub(raw[:2000])}) + "\n")
    sys.exit(0)

# 10MB rotation — port of observe.sh ~298-306
try:
    if os.path.getsize(obs_file) >= 10 * 1024 * 1024:
        adir = os.path.join(pdir, "observations.archive")
        os.makedirs(adir, exist_ok=True)
        os.rename(obs_file, os.path.join(
            adir,
            f"observations-{time.strftime('%Y%m%d-%H%M%S')}-{os.getpid()}.jsonl"))
except OSError:
    pass

# 30-day purge, once/day, RECURSIVE — parity with
# `find "$PROJECT_DIR" -name "observations-*.jsonl" -mtime +30 -delete`
marker = os.path.join(pdir, ".last-purge")
try:
    stale = os.path.getmtime(marker) < time.time() - 86400
except OSError:
    stale = True
if stale:
    cutoff = time.time() - 30 * 86400
    for root, _dirs, names in os.walk(pdir):
        for n in names:
            if n.startswith("observations-") and n.endswith(".jsonl"):
                p = os.path.join(root, n)
                try:
                    if os.path.getmtime(p) < cutoff:
                        os.remove(p)
                except OSError:
                    pass
    try:
        open(marker, "w").close()
    except OSError:
        pass

tool = data.get("tool_name", data.get("tool", "unknown"))
ti = data.get("tool_input", data.get("input", {}))
to = data.get("tool_response")
if to is None:
    to = data.get("tool_output", data.get("output", ""))

obs = {"timestamp": ts,
       "event": "tool_start" if phase == "pre" else "tool_complete",
       "tool": tool,
       "session": data.get("session_id", "unknown"),
       "project_id": os.environ.get("PROJECT_ID") or "global",
       "project_name": os.environ.get("PROJECT_NAME") or "global"}
# truncate-then-scrub + str() fallback: byte-parity with legacy ~237-245, 356-359
if phase == "pre":
    v = scrub((json.dumps(ti) if isinstance(ti, dict) else str(ti))[:5000])
    if v:
        obs["input"] = v
else:
    v = scrub((json.dumps(to) if isinstance(to, dict) else str(to))[:5000])
    if v is not None:
        obs["output"] = v

os.makedirs(pdir, exist_ok=True)
with open(obs_file, "a") as fh:
    fh.write(json.dumps(obs) + "\n")
```

Register `observe_fast.py` in `.upstream-sources.json` as `{"path": "skills/continuous-learning-v2/hooks/observe_fast.py", "source": "local", "status": "local"}`.

- [ ] **Step 5: Green + full test sweep**

Run:
```bash
bash tests/test-observe-parity.sh
shellcheck skills/continuous-learning-v2/hooks/observe.sh
./scripts/test-python.sh
bash tests/test-provenance-guard.sh
bash tests/test-upstream-manifest.sh
./scripts/audit/measure-overhead.sh
python3 -c "import json; m=[x for x in json.load(open('.upstream-sources.json'))['files'] if x['path']=='skills/continuous-learning-v2/hooks/observe.sh'][0]; assert m['status']=='custom' and m['source']=='ecc' and m.get('upstream_path'), m; print('provenance OK')"
```
Expected: parity PASS with avg < 200ms; shellcheck clean; CLV2 pytest suite green; provenance + manifest PASS; observe.sh remains `custom` with `source`/`upstream_path` intact; harness shows observe.sh avg down from ~570ms.

- [ ] **Step 6: Commit**

```bash
git add skills/continuous-learning-v2/hooks/ tests/test-observe-parity.sh .upstream-sources.json
git commit -m "perf: single-spawn cached fast path for clv2 observe hook (fork sync->custom)"
```

---

### Task 8: Trim installed user rules (audit item 6 — USER-LEVEL, needs operator approval)

**Files:**
- Modify: `~/.claude/rules/common/` (installed copies only — the repo's `rules/common/*` are `sync/ecc`, DO NOT touch them)

**This task is not a repo commit and runs only after the operator approves the keep/drop split.** All dropped files remain in the busdriver repo and reinstall with one `cp` — fully reversible.

**Recommended split (default):**

| Keep (distilled from operator's own lessons / load-bearing) | Drop (generic ECC boilerplate duplicated by busdriver skills+gates) |
|---|---|
| `investigate-before-acting.md` | `code-review.md` (litmus + code-review skill own this) |
| `tool-discipline.md` | `testing.md` (tdd-workflow skill owns this) |
| `validate-before-building.md` | `development-workflow.md` (orchestrator pipeline owns this) |
| `hooks.md` (fail-closed doctrine) | `agents.md` (Agent tool registry already lists all agents) |
| `git-workflow.md` (distilled pre-commit discipline) | `performance.md` (stale model guidance) |
| `security.md` (short) | `patterns.md`, `coding-style.md` (coding-standards skill owns these) |

- [ ] **Step 1 (after approval): Archive, don't delete**

```bash
mkdir -p ~/.claude/rules-disabled
for f in code-review testing development-workflow agents performance patterns coding-style; do
  mv ~/.claude/rules/common/$f.md ~/.claude/rules-disabled/ 2>/dev/null || true
done
```

- [ ] **Step 2: Verify next session**

Start a fresh Claude Code session; confirm the removed rules no longer appear in the injected context and gates/skills still fire. Expected saving: ~14.9KB ≈ 3.7k tokens/session.

---

## Verification Summary (run after all tasks)

```bash
./scripts/audit/measure-overhead.sh          # registry + latency + injection deltas
bash tests/test-provenance-guard.sh          # PASS
bash tests/test-vault-references.sh          # PASS
bash tests/test-upstream-manifest.sh         # PASS
bash tests/test-observe-parity.sh            # PASS, <150ms
./scripts/test-python.sh                     # CLV2 pytest green
npm test                                     # JS suite green
```

**Expected totals vs baseline — (A) repo-landed (the PR success criterion):** registry descriptions −5.5-6.5k tokens; SessionStart injection −~9-10KB (~2.5k tokens); CLAUDE.md −~2.9KB (~730 tokens); per-tool-call hook wall-clock −~420ms on the busdriver side. **(B) operator-local, approval-gated, measured separately, NOT part of the PR criterion:** user rules −~3.7k tokens (Task 8). claude-mem's ~512ms PostToolUse hook remains — third-party, out of scope, operator may tune separately.

## Out of Scope (recorded so nobody re-opens them mid-implementation)

- Deleting any skill/command (ADR 0010: vault only)
- Editing `sync` file content without a manifest fork (ADR 0014)
- Usage telemetry / auto-GC for the vault (ADR 0010 rejected)
- claude-mem / seatbelt / other third-party plugin internals
- Merging firecrawl/tavily content into single files (vaulting achieves the registry saving without a content refactor)
- Re-vendoring impeccable, provider scrub, arbiter chain (SETTLED per CLAUDE.md)

<!-- design-reviewed: PASS -->
<!-- design-review-coverage: FULL 3/3  -->
