# Orchestrator Installation

This skill is auto-loaded into context on every SessionStart by `hooks/gate-scripts/load-orchestrator.sh`, registered via the plugin's `hooks/hooks.json`. No manual setup required when installed as part of the busdriver plugin.

## File Layout

```
skills/orchestrator/
├── SKILL.md              # Always-loaded (~3k tokens) — pipeline + gates + entry routing
├── tasks-catalog.md      # On-demand (~3k tokens) — non-pipeline task routes
├── domain-supplements.md # On-demand (~3k tokens) — language/framework detection
├── README.md             # Overview
└── INSTALL.md            # This file
```

`SKILL.md` is injected as `additionalContext` on SessionStart. The other two files are read by Claude on demand when the active task requires their content (catalog lookup or domain detection).

## When You Add a New Skill

1. **Determine the route type:**
   - **Pipeline phase work** (planning/execution/verification of features) → no orchestrator change; the new skill is invoked from within a phase.
   - **Domain/language pattern** (e.g., new framework patterns) → add a row to `domain-supplements.md`.
   - **Standalone task** (refactoring, ops, content, etc.) → add a row to `tasks-catalog.md`.
   - **Always-on discipline** (TDD, verification, code review type) → add to Phase 4 disciplines in `SKILL.md`.

2. **Add a trigger keyword and the route format:**
   ```
   | **<Task name>** | <comma-separated trigger words> | <skill-name-or-command> |
   ```
   Use `agent`/`command` suffix only when the route is not a Skill-tool invocation.

3. **If the new skill provides a specialized agent** (e.g., new `{lang}-reviewer`):
   - Add to Phase 4 DISPATCH rules in `SKILL.md`.
   - Add to `domain-supplements.md` for that language.

4. **Avoid duplicating skill descriptions.** The system-prompt skill registry already shows all skill descriptions to Claude automatically — `tasks-catalog.md` only needs to add value where the trigger → skill mapping is non-obvious or where curated multi-skill groupings beat picking single skills.

## When You Modify a Gate

Implementation details (TOCTOU parsing, weighted quorum, CLI backend matrix) live in the gate's own SKILL.md, not in the orchestrator. The orchestrator's "Gates" table in `SKILL.md` only needs the trigger, skip-file path, and a pointer.

If you change skip-file behavior, update:
- The gate's own SKILL.md
- The "Emergency Gate Recovery" block in `SKILL.md` (only if user-facing protocol changes)
- `blueprint-review/SKILL.md`'s "User-Created Skip File" section (canonical failure-mode taxonomy)

## Verifying After Changes

```bash
# Estimate token cost of always-loaded content
wc -c skills/orchestrator/SKILL.md
# Target: stay under ~14KB / ~3.5k tokens

# Check that referenced skills exist
grep -oE 'busdriver:[a-z][a-z0-9-]+' skills/orchestrator/SKILL.md | \
  sed 's/.*busdriver://' | sort -u | while read s; do
    [ -d "skills/$s" ] || echo "MISSING: $s"
  done
```

## Disabling for Diagnostic A/B

If you want to measure whether the orchestrator earns its tokens:
1. Comment out the `SessionStart` hook in `hooks/hooks.json` that points to `load-orchestrator.sh`.
2. Restart Claude Code.
3. Run varied tasks for several sessions; observe whether routing degrades.
4. Re-enable when done.

The gate hooks (litmus, blueprint-review, pre-implementation, freeze, pre-merge) are independent and remain active even if the orchestrator skill isn't loaded.
