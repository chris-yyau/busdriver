<!-- design-reviewed: PASS -->
# Busdriver Plugin Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use busdriver:subagent-driven-development (recommended) or busdriver:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Create a standalone Claude Code plugin called `busdriver` that consolidates Superpowers pipeline (14 skills), ECC domain tools (126 skills, 28 agents, 60 commands, hooks/scripts), and custom workflow tools into one owned plugin with upstream sync capability.

**Architecture:** Grouped directory structure (`pipeline/`, `domain/`, `gates/`, `workflow/`) preserving provenance. Single `busdriver:*` namespace. Unified hook wrapper with ordering guarantees. Two separate upstream sync scripts. `.upstream-sources` manifest tracking file origins.

**Tech Stack:** Bash (bulk copy + sync scripts), JSON (plugin.json, hooks.json), sed (namespace migration)

---

## File Structure

```
/Volumes/Work/Projects/busdriver/
├── .claude-plugin/
│   └── plugin.json                    # NEW: plugin manifest
├── .upstream-sources                  # NEW: maps files to upstream origins
├── skills/
│   ├── pipeline/                      # FROM: superpowers (14 skills)
│   │   ├── brainstorming/SKILL.md
│   │   ├── writing-plans/SKILL.md
│   │   ├── using-git-worktrees/SKILL.md
│   │   ├── executing-plans/SKILL.md
│   │   ├── subagent-driven-development/SKILL.md
│   │   ├── dispatching-parallel-agents/SKILL.md
│   │   ├── test-driven-development/SKILL.md
│   │   ├── systematic-debugging/SKILL.md
│   │   ├── verification-before-completion/SKILL.md
│   │   ├── finishing-a-development-branch/SKILL.md
│   │   ├── requesting-code-review/SKILL.md
│   │   ├── receiving-code-review/SKILL.md
│   │   ├── writing-skills/SKILL.md
│   │   └── using-superpowers/SKILL.md
│   ├── domain/                        # FROM: ECC (126 skills)
│   │   ├── golang-patterns/SKILL.md
│   │   ├── python-patterns/SKILL.md
│   │   ├── ... (126 skill dirs)
│   │   └── continuous-learning-v2/    # includes config, agents, scripts, hooks
│   ├── gates/                         # FROM: local skills
│   │   ├── codex-reviewer/SKILL.md
│   │   └── design-reviewer/SKILL.md
│   ├── workflow/                      # FROM: local skills
│   │   ├── orchestrator/
│   │   │   ├── SKILL.md
│   │   │   └── domain-supplements.md
│   │   ├── council/SKILL.md
│   │   ├── reflect/SKILL.md
│   │   ├── canary/SKILL.md
│   │   ├── web-research/SKILL.md
│   │   ├── browser-automation/SKILL.md
│   │   └── dispatch-cli/
│   │       ├── SKILL.md
│   │       └── scripts/dispatch.sh
│   └── supplements/                   # FROM: local skills/supplements
│       ├── MANIFEST.md
│       ├── anti-sycophancy.md
│       └── ... (10 files)
├── agents/                            # FROM: superpowers (1) + ECC (28)
│   ├── plan-code-reviewer.md          # superpowers (renamed to avoid collision)
│   ├── code-reviewer.md               # ECC
│   ├── go-reviewer.md                 # ECC
│   ├── ... (29 total)
├── commands/                          # FROM: superpowers (3) + ECC (60) + local (1)
│   ├── brainstorm.md                  # superpowers
│   ├── tdd.md                         # ECC
│   ├── refine-notes.md                # local
│   ├── ... (64 total)
├── hooks/
│   ├── hooks.json                     # NEW: unified (gates + ECC hooks merged)
│   ├── gate-scripts/                  # FROM: ~/.claude/hooks/
│   │   ├── pre-commit-gitleaks.sh
│   │   ├── pre-commit-gate.sh
│   │   ├── pre-pr-gate.sh
│   │   ├── pre-implementation-gate.sh
│   │   ├── pre-commit-iac-scan.sh
│   │   ├── check-design-document.sh
│   │   ├── post-commit-consume-marker.sh
│   │   ├── go-post-edit.sh
│   │   ├── load-orchestrator.sh
│   │   ├── auto-push-config.sh
│   │   └── check-plugin-updates.sh
├── scripts/                           # FROM: ECC scripts/
│   ├── hooks/                         # ECC hook scripts (28 .js files)
│   │   ├── quality-gate.js
│   │   ├── session-start.js
│   │   ├── cost-tracker.js
│   │   └── ...
│   └── prune-notes.py                 # FROM: local scripts/
└── README.md                          # NEW: for OSS users
```

---

### Task 1: Scaffold Plugin Directory and Manifest

**Files:**
- Create: `/Volumes/Work/Projects/busdriver/.claude-plugin/plugin.json`
- Create: `/Volumes/Work/Projects/busdriver/README.md`

- [ ] **Step 1: Create directory structure**

```bash
mkdir -p /Volumes/Work/Projects/busdriver/.claude-plugin
mkdir -p /Volumes/Work/Projects/busdriver/skills/{pipeline,domain,gates,workflow}
mkdir -p /Volumes/Work/Projects/busdriver/skills/supplements
mkdir -p /Volumes/Work/Projects/busdriver/agents
mkdir -p /Volumes/Work/Projects/busdriver/commands
mkdir -p /Volumes/Work/Projects/busdriver/hooks/gate-scripts
mkdir -p /Volumes/Work/Projects/busdriver/scripts/hooks
```

- [ ] **Step 2: Write plugin.json**

```json
{
  "name": "busdriver",
  "version": "0.1.0",
  "description": "Unified workflow orchestrator — consolidates pipeline process, domain tools, and enforcement gates into one plugin",
  "author": {
    "name": "Chris Yau"
  },
  "license": "MIT",
  "keywords": [
    "claude-code", "orchestrator", "workflow", "pipeline",
    "tdd", "code-review", "security", "gates", "agents"
  ]
}
```

- [ ] **Step 3: Write minimal README.md**

One paragraph: what busdriver is, how to install, link to docs.

- [ ] **Step 4: Verify directory structure**

```bash
find /Volumes/Work/Projects/busdriver -type d | sort
```

Expected: all directories from the file structure above.

- [ ] **Step 5: Commit**

```bash
git add /Volumes/Work/Projects/busdriver/.claude-plugin/plugin.json /Volumes/Work/Projects/busdriver/README.md
git commit -m "feat: scaffold busdriver plugin structure"
```

---

### Task 2: Bulk Copy — Pipeline Skills (Superpowers)

**Files:**
- Copy: `plugins/forked/superpowers/skills/*` → `/Volumes/Work/Projects/busdriver/skills/pipeline/`
- Copy: `plugins/forked/superpowers/agents/*` → `/Volumes/Work/Projects/busdriver/agents/`
- Copy: `plugins/forked/superpowers/commands/*` → `/Volumes/Work/Projects/busdriver/commands/`

- [ ] **Step 1: Copy superpowers skills**

```bash
cp -r ~/.claude/plugins/forked/superpowers/skills/* \
  /Volumes/Work/Projects/busdriver/skills/pipeline/
```

- [ ] **Step 2: Copy superpowers agents (rename code-reviewer to avoid collision)**

```bash
cp ~/.claude/plugins/forked/superpowers/agents/code-reviewer.md \
  /Volumes/Work/Projects/busdriver/agents/plan-code-reviewer.md
cp ~/.claude/plugins/forked/superpowers/commands/*.md \
  /Volumes/Work/Projects/busdriver/commands/
```

- [ ] **Step 3: Verify file count**

```bash
ls /Volumes/Work/Projects/busdriver/skills/pipeline/ | wc -l
# Expected: 14
ls /Volumes/Work/Projects/busdriver/agents/ | wc -l
# Expected: 1 (plan-code-reviewer.md)
ls /Volumes/Work/Projects/busdriver/commands/ | wc -l
# Expected: 3 (brainstorm.md, execute-plan.md, write-plan.md)
```

- [ ] **Step 4: Commit**

```bash
git add /Volumes/Work/Projects/busdriver/skills/pipeline/ /Volumes/Work/Projects/busdriver/agents/ /Volumes/Work/Projects/busdriver/commands/
git commit -m "feat(busdriver): add pipeline skills from superpowers"
```

---

### Task 3: Bulk Copy — Domain Skills (ECC)

**Files:**
- Copy: `plugins/forked/everything-claude-code/skills/*` → `/Volumes/Work/Projects/busdriver/skills/domain/`
- Copy: `plugins/forked/everything-claude-code/agents/*` → `/Volumes/Work/Projects/busdriver/agents/`
- Copy: `plugins/forked/everything-claude-code/commands/*` → `/Volumes/Work/Projects/busdriver/commands/`
- Copy: `plugins/forked/everything-claude-code/scripts/hooks/*` → `/Volumes/Work/Projects/busdriver/scripts/hooks/`

- [ ] **Step 1: Copy ECC skills**

```bash
cp -r ~/.claude/plugins/forked/everything-claude-code/skills/* \
  /Volumes/Work/Projects/busdriver/skills/domain/
```

- [ ] **Step 2: Copy ECC agents**

```bash
cp ~/.claude/plugins/forked/everything-claude-code/agents/*.md \
  /Volumes/Work/Projects/busdriver/agents/
```

- [ ] **Step 3: Copy ECC commands**

```bash
cp ~/.claude/plugins/forked/everything-claude-code/commands/*.md \
  /Volumes/Work/Projects/busdriver/commands/
```

- [ ] **Step 4: Copy ECC scripts (hook runtime)**

```bash
cp -r ~/.claude/plugins/forked/everything-claude-code/scripts/hooks/* \
  /Volumes/Work/Projects/busdriver/scripts/hooks/
```

- [ ] **Step 5: Verify counts**

```bash
ls /Volumes/Work/Projects/busdriver/skills/domain/ | wc -l
# Expected: ~126
ls /Volumes/Work/Projects/busdriver/agents/ | wc -l
# Expected: ~29 (1 superpowers + 28 ECC)
ls /Volumes/Work/Projects/busdriver/commands/ | wc -l
# Expected: ~63 (3 superpowers + 60 ECC)
ls /Volumes/Work/Projects/busdriver/scripts/hooks/ | wc -l
# Expected: ~28
```

- [ ] **Step 6: Commit**

```bash
git add /Volumes/Work/Projects/busdriver/skills/domain/ /Volumes/Work/Projects/busdriver/agents/ \
  /Volumes/Work/Projects/busdriver/commands/ /Volumes/Work/Projects/busdriver/scripts/
git commit -m "feat(busdriver): add domain skills, agents, commands from ECC"
```

---

### Task 4: Copy Gate and Workflow Skills (Local)

**Files:**
- Copy: `skills/codex-reviewer/` → `/Volumes/Work/Projects/busdriver/skills/gates/codex-reviewer/`
- Copy: `skills/design-reviewer/` → `/Volumes/Work/Projects/busdriver/skills/gates/design-reviewer/`
- Copy: `skills/orchestrator/` → `/Volumes/Work/Projects/busdriver/skills/workflow/orchestrator/`
- Copy: `skills/council/` → `/Volumes/Work/Projects/busdriver/skills/workflow/council/`
- Copy: `skills/reflect/` → `/Volumes/Work/Projects/busdriver/skills/workflow/reflect/`
- Copy: `skills/canary/` → `/Volumes/Work/Projects/busdriver/skills/workflow/canary/`
- Copy: `skills/web-research/` → `/Volumes/Work/Projects/busdriver/skills/workflow/web-research/`
- Copy: `skills/browser-automation/` → `/Volumes/Work/Projects/busdriver/skills/workflow/browser-automation/`
- Copy: `skills/dispatch-cli/` → `/Volumes/Work/Projects/busdriver/skills/workflow/dispatch-cli/`
- Copy: `skills/supplements/` → `/Volumes/Work/Projects/busdriver/skills/supplements/`
- Copy: `commands/refine-notes.md` → `/Volumes/Work/Projects/busdriver/commands/refine-notes.md`
- Copy: `scripts/prune-notes.py` → `/Volumes/Work/Projects/busdriver/scripts/prune-notes.py`

- [ ] **Step 1: Copy gate skills**

```bash
cp -r ~/.claude/skills/codex-reviewer /Volumes/Work/Projects/busdriver/skills/gates/
cp -r ~/.claude/skills/design-reviewer /Volumes/Work/Projects/busdriver/skills/gates/
```

- [ ] **Step 2: Copy workflow skills**

```bash
for skill in orchestrator council reflect canary web-research browser-automation dispatch-cli; do
  cp -r ~/.claude/skills/$skill /Volumes/Work/Projects/busdriver/skills/workflow/
done
```

- [ ] **Step 3: Copy supplements**

```bash
cp ~/.claude/skills/supplements/* /Volumes/Work/Projects/busdriver/skills/supplements/
```

- [ ] **Step 4: Copy local command and script**

```bash
cp ~/.claude/commands/refine-notes.md /Volumes/Work/Projects/busdriver/commands/
cp ~/.claude/scripts/prune-notes.py /Volumes/Work/Projects/busdriver/scripts/
```

- [ ] **Step 5: Verify**

```bash
ls /Volumes/Work/Projects/busdriver/skills/gates/
# Expected: codex-reviewer/ design-reviewer/
ls /Volumes/Work/Projects/busdriver/skills/workflow/
# Expected: orchestrator/ council/ reflect/ canary/ web-research/ browser-automation/ dispatch-cli/
ls /Volumes/Work/Projects/busdriver/skills/supplements/ | wc -l
# Expected: 11 (10 supplements + MANIFEST.md)
```

- [ ] **Step 6: Commit**

```bash
git add /Volumes/Work/Projects/busdriver/skills/gates/ /Volumes/Work/Projects/busdriver/skills/workflow/ \
  /Volumes/Work/Projects/busdriver/skills/supplements/ /Volumes/Work/Projects/busdriver/commands/refine-notes.md \
  /Volumes/Work/Projects/busdriver/scripts/prune-notes.py
git commit -m "feat(busdriver): add gate, workflow skills and supplements"
```

---

### Task 5: Copy Gate Hook Scripts

**Files:**
- Copy: `hooks/*.sh` → `/Volumes/Work/Projects/busdriver/hooks/gate-scripts/`

- [ ] **Step 1: Copy all gate hook scripts**

```bash
cp ~/.claude/hooks/pre-commit-gitleaks.sh \
   ~/.claude/hooks/pre-commit-gate.sh \
   ~/.claude/hooks/pre-pr-gate.sh \
   ~/.claude/hooks/pre-implementation-gate.sh \
   ~/.claude/hooks/pre-commit-iac-scan.sh \
   ~/.claude/hooks/check-design-document.sh \
   ~/.claude/hooks/post-commit-consume-marker.sh \
   ~/.claude/hooks/go-post-edit.sh \
   ~/.claude/hooks/load-orchestrator.sh \
   ~/.claude/hooks/auto-push-config.sh \
   ~/.claude/hooks/check-plugin-updates.sh \
   /Volumes/Work/Projects/busdriver/hooks/gate-scripts/
```

Note: `patch-plugin-overrides.sh` is NOT copied — it's replaced by the sync scripts which stay local.

- [ ] **Step 2: Update gate scripts to use relative paths**

Gate scripts that reference `~/.claude/skills/` or `~/.claude/hooks/` need to be updated to use `${CLAUDE_PLUGIN_ROOT}` or `${BASH_SOURCE[0]}` relative paths. Audit each script:

```bash
grep -l "$HOME/.claude/\|/Users/" /Volumes/Work/Projects/busdriver/hooks/gate-scripts/*.sh
```

Fix any hardcoded absolute paths to use `${CLAUDE_PLUGIN_ROOT}` or relative paths from the script location.

- [ ] **Step 3: Verify**

```bash
ls /Volumes/Work/Projects/busdriver/hooks/gate-scripts/ | wc -l
# Expected: 11
```

- [ ] **Step 4: Commit**

```bash
git add /Volumes/Work/Projects/busdriver/hooks/gate-scripts/
git commit -m "feat(busdriver): add gate hook scripts"
```

---

### Task 6: Create Unified hooks.json

**Files:**
- Create: `/Volumes/Work/Projects/busdriver/hooks/hooks.json`

This is the critical unification step. Merge gate hooks (currently in settings.json) and ECC hooks (currently in ECC hooks.json) into ONE hooks.json with explicit ordering.

- [ ] **Step 1: Write unified hooks.json**

Ordering rules:
1. **Gates FIRST** (PreToolUse) — gitleaks → pre-commit-gate → pre-pr-gate → pre-implementation-gate → iac-scan
2. **ECC hooks SECOND** — block-no-verify, tmux, suggest-compact, config-protection, etc.
3. **Observers LAST** — observe.sh (async, non-blocking)

Gate hooks use `${CLAUDE_PLUGIN_ROOT}/hooks/gate-scripts/` paths.
ECC hooks use `${CLAUDE_PLUGIN_ROOT}/scripts/hooks/` paths (via run-with-flags.js).

Reference the current ECC hooks.json (`plugins/forked/everything-claude-code/hooks/hooks.json`) and current settings.json hooks section. Merge them with gates-first ordering.

Key changes from current ECC hooks.json:
- Gate hooks added as first entries in each phase
- `${CLAUDE_PLUGIN_ROOT}` paths used everywhere (no hardcoded absolute paths)
- Gate hooks use `bash "${CLAUDE_PLUGIN_ROOT}/hooks/gate-scripts/<script>.sh"` format
- ECC hooks keep their existing `node "${CLAUDE_PLUGIN_ROOT}/scripts/hooks/run-with-flags.js"` format

- [ ] **Step 2: Validate JSON syntax**

```bash
python3 -c "import json; json.load(open('/Volumes/Work/Projects/busdriver/hooks/hooks.json'))"
```

- [ ] **Step 3: Commit**

```bash
git add /Volumes/Work/Projects/busdriver/hooks/hooks.json
git commit -m "feat(busdriver): create unified hooks.json with gate-first ordering"
```

---

### Task 7: Namespace Migration

**Files:**
- Modify: ALL files in `/Volumes/Work/Projects/busdriver/` that reference `busdriver:` or `busdriver:`

- [ ] **Step 1: Audit current namespace references (all file types)**

```bash
cd /Volumes/Work/Projects/busdriver
grep -rl "busdriver:" --include="*.md" --include="*.json" --include="*.js" --include="*.sh" --include="*.py" | head -20
grep -rl "busdriver:" --include="*.md" --include="*.json" --include="*.js" --include="*.sh" --include="*.py" | head -20
```

- [ ] **Step 2: Replace busdriver: namespace (all file types)**

```bash
cd /Volumes/Work/Projects/busdriver
find . -type f \( -name "*.md" -o -name "*.json" -o -name "*.js" -o -name "*.sh" -o -name "*.py" \) \
  -exec sed -i '' 's/busdriver:/busdriver:/g' {} +
```

- [ ] **Step 3: Replace busdriver: namespace (all file types)**

```bash
cd /Volumes/Work/Projects/busdriver
find . -type f \( -name "*.md" -o -name "*.json" -o -name "*.js" -o -name "*.sh" -o -name "*.py" \) \
  -exec sed -i '' 's/busdriver:/busdriver:/g' {} +
```

- [ ] **Step 4: Replace document-skills: namespace references if needed**

Check if any busdriver skills reference `document-skills:` — those stay external (separate plugin).

```bash
grep -r "document-skills:" --include="*.md" | head -10
```

These should NOT be replaced — document-skills is a separate plugin.

- [ ] **Step 5: Verify no stale namespace references remain (all file types)**

```bash
cd /Volumes/Work/Projects/busdriver
grep -r "busdriver:" --include="*.md" --include="*.json" --include="*.js" --include="*.sh" \
  | grep -v "upstream-sources" | grep -v ".upstream-versions" | head -5
grep -r "busdriver:" --include="*.md" --include="*.json" --include="*.js" --include="*.sh" \
  | grep -v "upstream-sources" | grep -v ".upstream-versions" | head -5
# Expected: no results
```

- [ ] **Step 6: Spot-check critical files**

Read and verify these key files have correct `busdriver:` references:
- `skills/workflow/orchestrator/SKILL.md` — all pipeline phases
- `skills/workflow/orchestrator/domain-supplements.md` — all domain skill references
- `skills/pipeline/brainstorming/SKILL.md` — any cross-references to other skills

- [ ] **Step 7: Commit**

```bash
git add -A /Volumes/Work/Projects/busdriver/
git commit -m "refactor(busdriver): migrate namespace from superpowers/ecc to busdriver"
```

---

### Task 7.5: Portability Pass — Fix Hardcoded Paths

**Files:**
- Modify: ALL files in `/Volumes/Work/Projects/busdriver/` with `~/.claude` or `$HOME/.claude` references

This task classifies every `~/.claude` reference as either **internal** (should be `${CLAUDE_PLUGIN_ROOT}`) or **external** (intentionally points to user's local data).

- [ ] **Step 1: Find all hardcoded path references**

```bash
cd /Volumes/Work/Projects/busdriver
grep -rn '~/\.claude\|$HOME/\.claude\|/Users/' \
  --include="*.md" --include="*.sh" --include="*.js" --include="*.py" --include="*.json" \
  | grep -v ".upstream-sources" | grep -v "README.md" > /tmp/busdriver-paths-audit.txt
wc -l /tmp/busdriver-paths-audit.txt
cat /tmp/busdriver-paths-audit.txt
```

- [ ] **Step 2: Classify and fix internal references**

**Convert to `${CLAUDE_PLUGIN_ROOT}`** (plugin-internal assets):
- `~/.claude/skills/orchestrator/` → `${CLAUDE_PLUGIN_ROOT}/skills/workflow/orchestrator/`
- `~/.claude/skills/design-reviewer/scripts/` → `${CLAUDE_PLUGIN_ROOT}/skills/gates/design-reviewer/scripts/`
- `~/.claude/hooks/` → `${CLAUDE_PLUGIN_ROOT}/hooks/gate-scripts/`
- `~/.claude/skills/dispatch-cli/scripts/` → `${CLAUDE_PLUGIN_ROOT}/skills/workflow/dispatch-cli/scripts/`
- `~/.claude/skills/supplements/` → `${CLAUDE_PLUGIN_ROOT}/skills/supplements/`

**Keep as `~/.claude` (external user data — document as host prerequisites):**
- `~/.claude/notes/` — user's personal notes
- `~/.claude/homunculus/` — user's instinct data
- `~/.claude/sessions/` — user's session history
- `~/.claude/projects/` — user's project memory
- `~/.claude/.claude/` — user's settings
- `~/.claude/codex-review-passed.local` — per-session gate markers
- `~/.claude/plugins/marketplaces/` — user's marketplace cache (for update checking)

- [ ] **Step 3: Verify no broken internal references remain**

```bash
cd /Volumes/Work/Projects/busdriver
# Should NOT find references to old skill/hook locations that were moved:
grep -rn '~/.claude/skills/orchestrator\|~/.claude/skills/codex-reviewer\|~/.claude/skills/design-reviewer\|~/.claude/skills/council\|~/.claude/hooks/pre-commit' \
  --include="*.md" --include="*.sh" --include="*.js" --include="*.py" | head -10
# Expected: no results
```

- [ ] **Step 4: Commit**

```bash
git add -A /Volumes/Work/Projects/busdriver/
git commit -m "refactor(busdriver): convert internal paths to CLAUDE_PLUGIN_ROOT"
```

---

### Task 8: Create .upstream-sources Manifest

**Files:**
- Create: `/Volumes/Work/Projects/busdriver/.upstream-sources`

- [ ] **Step 1: Write the manifest as JSON**

Use JSON format (not TSV) for machine-readability and extensibility. One entry per file, no globs.

Create `/Volumes/Work/Projects/busdriver/.upstream-sources.json`:

```json
{
  "version": "1.0",
  "upstreams": {
    "superpowers": { "repo": "obra/superpowers", "ref": "main" },
    "ecc": { "repo": "affaan-m/everything-claude-code", "ref": "main" }
  },
  "files": [
    { "path": "skills/pipeline/brainstorming/SKILL.md", "source": "superpowers", "upstream_path": "skills/brainstorming/SKILL.md", "status": "sync" },
    { "path": "skills/pipeline/writing-plans/SKILL.md", "source": "superpowers", "upstream_path": "skills/writing-plans/SKILL.md", "status": "custom" },
    { "path": "skills/domain/golang-patterns/SKILL.md", "source": "ecc", "upstream_path": "skills/golang-patterns/SKILL.md", "status": "sync" },
    { "path": "agents/plan-code-reviewer.md", "source": "superpowers", "upstream_path": "agents/code-reviewer.md", "status": "custom" },
    { "path": "agents/code-reviewer.md", "source": "ecc", "upstream_path": "agents/code-reviewer.md", "status": "sync" },
    { "path": "skills/workflow/orchestrator/SKILL.md", "source": "local", "status": "local" },
    { "path": "hooks/hooks.json", "source": "local", "status": "local" },
    { "path": "hooks/gate-scripts/pre-commit-gitleaks.sh", "source": "local", "status": "local" }
  ]
}
```

(Abbreviated — full manifest generated programmatically in Step 2. Each file gets its own entry, no globs.)

- [ ] **Step 2: Generate manifest programmatically**

Write a script to generate the manifest by walking the directory and matching files against known origins:

```bash
# For each file in busdriver:
# - If it came from superpowers fork → superpowers source
# - If it came from ECC fork → ecc source
# - If it came from local → local source
# - If in .fork-custom-files → status = custom
# - Else → status = sync
```

- [ ] **Step 3: Verify manifest completeness**

```bash
# Count files in busdriver (excluding .claude-plugin/, .git, .upstream-sources)
find /Volumes/Work/Projects/busdriver -type f \
  -not -path "*/.claude-plugin/*" \
  -not -name ".upstream-sources" \
  -not -name "README.md" | wc -l

# Count lines in manifest (excluding comments/blanks)
grep -v "^#\|^$" /Volumes/Work/Projects/busdriver/.upstream-sources | wc -l

# These should match
```

- [ ] **Step 4: Commit**

```bash
git add /Volumes/Work/Projects/busdriver/.upstream-sources
git commit -m "feat(busdriver): add upstream sources manifest"
```

---

### Task 9: Wire Plugin (Staged Rollout)

**Files:**
- Modify: `plugins/installed_plugins.json`
- Modify: `settings.json`

**STAGED APPROACH:** Enable busdriver ALONGSIDE old plugins first. Verify. Then remove old plugins in Task 11 only after Task 10 passes.

- [ ] **Step 1: Back up config files**

```bash
cp ~/.claude/settings.json ~/.claude/settings.json.pre-busdriver
cp ~/.claude/plugins/installed_plugins.json ~/.claude/plugins/installed_plugins.json.pre-busdriver
```

- [ ] **Step 2: Register busdriver in installed_plugins.json**

Add entry (keep old entries for now):
```json
"busdriver@busdriver": [
  {
    "scope": "user",
    "installPath": "/Volumes/Work/Projects/busdriver",
    "version": "0.1.0",
    "installedAt": "2026-03-25T00:00:00.000Z",
    "lastUpdated": "2026-03-25T00:00:00.000Z"
  }
]
```

- [ ] **Step 3: Add busdriver to enabledPlugins in settings.json**

Add: `"busdriver@busdriver": true`
**DO NOT remove old plugin entries yet — they stay as fallback.**

- [ ] **Step 4: Remove gate hooks from settings.json hooks section**

Remove ALL hooks entries from settings.json — they now live in busdriver's hooks.json. The `settings.json` hooks section should become empty (`"hooks": {}`).

**NOTE:** Gate hooks in settings.json and busdriver's hooks.json would duplicate if both active. Since busdriver's hooks.json now contains the unified hooks, the settings.json hooks MUST be removed to avoid double-firing.

- [ ] **Step 5: Remove old fork entries from enabledPlugins**

Remove:
- `"everything-claude-code@everything-claude-code": true`
- `"superpowers@superpowers-marketplace": true`

- [ ] **Step 4: Remove gate hooks from settings.json**

Remove ALL hooks entries from settings.json — they now live in busdriver's hooks.json. The only things that should remain in settings.json hooks are truly personal hooks that are NOT part of busdriver (currently: none — all hooks are being absorbed).

If keeping settings.json hooks section empty, remove the entire `"hooks"` key.

**CAUTION:** Back up settings.json first:
```bash
cp ~/.claude/settings.json ~/.claude/settings.json.pre-busdriver
```

- [ ] **Step 5: Remove old fork entries from installed_plugins.json**

Remove:
- `"everything-claude-code@everything-claude-code"` entry
- `"superpowers@superpowers-marketplace"` entry

- [ ] **Step 6: Verify settings.json is valid JSON**

```bash
python3 -c "import json; json.load(open('$HOME/.claude/settings.json'))"
python3 -c "import json; json.load(open('$HOME/.claude/plugins/installed_plugins.json'))"
```

- [ ] **Step 7: Commit**

```bash
git add settings.json plugins/installed_plugins.json
git commit -m "feat(busdriver): wire plugin, remove old fork entries"
```

---

### Task 10: Verification

- [ ] **Step 1: Start a fresh Claude Code session**

```bash
claude --no-profile  # or just start a new session
```

- [ ] **Step 2: Check skill resolution**

Try invoking skills with new namespace:
- `busdriver:brainstorming` — should load pipeline brainstorming skill
- `busdriver:golang-patterns` — should load domain Go patterns
- `busdriver:codex-reviewer` — should load gate skill

- [ ] **Step 3: Check hooks fire**

- Try `git commit` on a dummy change — gitleaks and codex-reviewer gates should fire
- Try writing a PLAN.md — design doc detector should fire
- ECC hooks (suggest-compact, config-protection, etc.) should appear in hook output

- [ ] **Step 4: Check agents resolve**

Try dispatching: `go-reviewer`, `code-reviewer`, `typescript-reviewer`

- [ ] **Step 5: Check commands resolve**

Try: `/tdd`, `/refine-notes`, `/verify`

- [ ] **Step 6: Document any failures and fix**

If skills don't resolve, check:
1. Plugin registered correctly in installed_plugins.json
2. Plugin enabled in settings.json
3. Skill has correct frontmatter (name, description)
4. No path issues in hooks.json

---

### Task 11: Cleanup (After Verification Passes)

**CAUTION:** Only proceed after Task 10 passes. Back up first.

- [ ] **Step 1: Back up old infrastructure**

```bash
cp -r ~/.claude/plugins/forked ~/.claude/backups/forked-pre-busdriver
cp -r ~/.claude/skills ~/.claude/backups/skills-pre-busdriver
cp -r ~/.claude/hooks ~/.claude/backups/hooks-pre-busdriver
```

- [ ] **Step 2: Remove old fork directories**

```bash
rm -rf ~/.claude/plugins/forked/superpowers
rm -rf ~/.claude/plugins/forked/everything-claude-code
```

- [ ] **Step 3: Remove migrated local skills**

```bash
# Remove skills that moved to busdriver (keep ci-pipeline-setup)
for skill in orchestrator council reflect codex-reviewer design-reviewer canary web-research browser-automation dispatch-cli; do
  rm -rf ~/.claude/skills/$skill
done
rm -rf ~/.claude/skills/supplements
```

- [ ] **Step 4: Remove migrated hooks, commands, scripts**

```bash
# Remove hook scripts (now in busdriver)
rm ~/.claude/hooks/pre-commit-gitleaks.sh
rm ~/.claude/hooks/pre-commit-gate.sh
rm ~/.claude/hooks/pre-pr-gate.sh
rm ~/.claude/hooks/pre-implementation-gate.sh
rm ~/.claude/hooks/pre-commit-iac-scan.sh
rm ~/.claude/hooks/check-design-document.sh
rm ~/.claude/hooks/post-commit-consume-marker.sh
rm ~/.claude/hooks/go-post-edit.sh
rm ~/.claude/hooks/load-orchestrator.sh
rm ~/.claude/hooks/auto-push-config.sh
rm ~/.claude/hooks/check-plugin-updates.sh
# Keep: patch-plugin-overrides.sh stays until sync scripts replace it

rm ~/.claude/commands/refine-notes.md
rm ~/.claude/scripts/prune-notes.py
```

- [ ] **Step 5: Remove overrides directory**

```bash
rm -rf ~/.claude/overrides
```

- [ ] **Step 6: Verify clean state**

```bash
ls ~/.claude/skills/
# Expected: only ci-pipeline-setup/
ls ~/.claude/hooks/
# Expected: only patch-plugin-overrides.sh (until replaced)
ls ~/.claude/plugins/forked/
# Expected: empty or nonexistent
```

- [ ] **Step 7: Final verification — start new session**

Same checks as Task 10. Everything should still work with old files removed.

- [ ] **Step 8: Commit cleanup**

```bash
git add -A
git commit -m "chore(busdriver): remove migrated forks, local skills, and hooks"
```

---

### Task 12: Write Sync Scripts (Maintainer Tooling — Stays Local)

**Files:**
- Create: `scripts/sync-superpowers.sh` (stays in `~/.claude/scripts/`)
- Create: `scripts/sync-ecc.sh` (stays in `~/.claude/scripts/`)

These are NOT part of busdriver — they're maintainer tools for pulling upstream changes.

- [ ] **Step 1: Write sync-superpowers.sh**

The script should:
1. Clone/pull latest superpowers from `obra/superpowers`
2. Read `.upstream-sources` for files with source=superpowers and status=sync
3. For each sync file: compare upstream vs busdriver, show diff if changed
4. For each custom file: show semantic diff (what changed behaviorally)
5. Prompt maintainer: accept/skip/review each change
6. Update `.upstream-sources` with new upstream version info

- [ ] **Step 2: Write sync-ecc.sh**

Same pattern as sync-superpowers.sh but for `affaan-m/everything-claude-code`.

- [ ] **Step 3: Test sync scripts in dry-run mode**

```bash
bash ~/.claude/scripts/sync-superpowers.sh --dry-run
bash ~/.claude/scripts/sync-ecc.sh --dry-run
```

- [ ] **Step 4: Commit sync scripts**

```bash
git add scripts/sync-superpowers.sh scripts/sync-ecc.sh
git commit -m "feat: add upstream sync scripts for busdriver maintenance"
```

---

## Execution Notes

- **Tasks 2-4 are bulk mechanical copies** — can be parallelized via subagents
- **Task 6 (unified hooks.json) is the hardest** — requires careful merging and ordering
- **Task 7 (namespace migration) has blast radius** — verify thoroughly after sed
- **Task 9 (wire plugin) is the point of no return** — back up settings.json first
- **Task 11 (cleanup) is destructive** — only after full verification
- **Task 12 (sync scripts) is independent** — can be deferred

## Risk Mitigations

1. **Silent semantic drift** — sync scripts must show behavioral deltas, not just text diffs
2. **Hook ordering bugs** — unified hooks.json has gates FIRST, ECC hooks SECOND
3. **Namespace breakage** — verify no stale busdriver:/busdriver: references after migration
4. **Settings.json corruption** — back up before modifying
