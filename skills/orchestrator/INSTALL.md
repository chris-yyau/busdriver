# Orchestrator Installation Guide

## Overview

The orchestrator skill replaces `using-superpowers` as the master router for all Claude Code skills. It unifies routing across superpowers, everything-claude-code, and standalone review skills.

## Prerequisites

Ensure you have:
1. Superpowers plugin installed
2. Everything Claude Code plugin installed
3. Codex-reviewer and design-reviewer skills in `~/.claude/skills/`

## Installation Steps

### 1. Disable the using-superpowers SessionStart Hook

First, we need to prevent `using-superpowers` from loading automatically:

```bash
# Check current hooks
cat ~/.claude/settings.json | jq '.hooks'

# If you have a SessionStart hook for using-superpowers, remove it
# Edit ~/.claude/settings.json and remove the SessionStart entry
```

### 2. Configure Orchestrator as SessionStart Hook

Add the orchestrator skill to load on every session:

```json
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash /PATH/TO/.claude/hooks/load-orchestrator.sh",
            "timeout": 10
          }
        ]
      }
    ]
  }
}
```

Replace `/PATH/TO/` with your actual home directory path (e.g., `/Users/yourname`).

### 3. Verify Installation

Start a new Claude Code session and verify:
1. The orchestrator skill loads automatically
2. No duplicate loading of using-superpowers
3. Routing works correctly

Test with:
```
# Should route to busdriver:brainstorming
"Let's build a new feature"

# Should trigger codex-reviewer
"I'm ready to commit these changes"

# Should route to golang-patterns
"Help me with this Go code"
```

## Configuration Options

### Hook Priority

If you have other SessionStart hooks, ensure orchestrator runs first:

```json
{
  "hooks": {
    "SessionStart": [
      {
        "command": "Skill",
        "arguments": {"skill": "orchestrator"},
        "description": "Load master orchestrator"
      },
      {
        "command": "Skill",
        "arguments": {"skill": "other-skill"},
        "description": "Load other skill"
      }
    ]
  }
}
```

### Custom Routes

To add custom routing rules, edit the orchestrator SKILL.md:

1. Add to the appropriate section (gates/process/tasks/domains/utilities)
2. Follow the existing pattern
3. Maintain precedence order

Example adding a custom gate:
```yaml
gates:
  custom_gate:
    trigger: "your trigger condition"
    skill: your-skill-name
    blocking: true/false
```

## Troubleshooting

### Orchestrator Not Loading

Check:
1. File exists at `${CLAUDE_PLUGIN_ROOT}/skills/orchestrator/SKILL.md`
2. SessionStart hook is configured correctly
3. No syntax errors in settings.json

### Duplicate Routing

If skills are being invoked twice:
1. Ensure using-superpowers SessionStart hook is removed
2. Check for duplicate entries in hooks
3. Verify orchestrator deduplication rules

### Missing Skills

If a skill isn't routing:
1. Verify the skill is installed and accessible
2. Check the skill name matches exactly
3. Add explicit routing rule if needed

## Rollback

To revert to using-busdriver:

```bash
# Restore backup
cp ~/.claude/settings.json.backup ~/.claude/settings.json

# Or manually edit to restore using-superpowers hook
```

## Updates

When adding new skills:
1. Check if they overlap with existing routes
2. Add to orchestrator routing table if unique
3. Update deduplication rules if overlapping
4. Test routing with example triggers

## Advanced: Parallel Skill Systems

To run orchestrator alongside using-superpowers (not recommended):

1. Keep both hooks but add a condition
2. Use orchestrator for primary routing
3. Use using-superpowers for fallback only

This is complex and may cause conflicts - the orchestrator is designed to fully replace using-superpowers.