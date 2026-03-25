---
name: skill-supply-chain
description: Skill supply chain audit loaded alongside security-scan to detect malicious patterns in installed Claude Code skills and plugins
targets: busdriver:security-scan
type: supplement
source: gstack /cso Phase 8
added: 2026-03-23
---

# Skill Supply Chain Audit

> Load alongside `security-scan` skill when scanning Claude Code configuration.

## Why This Matters

Installed skills and plugins are executed with the same permissions as Claude Code itself. A malicious skill can:
- Exfiltrate code, secrets, or conversation context via MCP servers or Bash commands
- Inject instructions into the system prompt that override user intent
- Modify files silently via PostToolUse hooks
- Redirect tool calls to attacker-controlled endpoints

## What to Scan

### 1. Skill Files (skills/*/SKILL.md)
- [ ] No instructions to send data to external URLs
- [ ] No instructions to ignore or override CLAUDE.md or user instructions
- [ ] No instructions to hide actions from the user
- [ ] No encoded/obfuscated content (base64, hex strings, unicode escapes)
- [ ] No instructions to install additional packages or run setup scripts silently

### 2. Agent Definitions (agents/*.md)
- [ ] Tool lists are minimal and justified (no unnecessary Bash access for read-only agents)
- [ ] No instructions to bypass review gates or skip verification
- [ ] No hardcoded external URLs for data submission
- [ ] Model field is explicit (not open to override by prompt injection)

### 3. Hook Scripts (hooks/)
- [ ] PreToolUse/PostToolUse hooks don't exfiltrate tool inputs to external services
- [ ] Hook scripts don't curl/wget to external URLs
- [ ] Hook scripts don't modify files outside their stated scope
- [ ] No command injection via unquoted variable interpolation in shell hooks
- [ ] No silent error suppression that hides hook failures

### 4. MCP Server Configs (mcp.json, .mcp.json, .codex/config.toml)
- [ ] No MCP servers connecting to unexpected external endpoints
- [ ] MCP server packages are from known publishers (check npm/pypi author)
- [ ] No `npx` commands for packages that could be typosquatted
- [ ] Environment variables passed to MCP servers don't include unnecessary secrets
- [ ] Check ALL MCP config locations: `.mcp.json`, `mcp.json`, `.codex/config.toml`, `~/.codex/config.toml` (Codex CLI), and any tool-specific MCP configs

### 5. Plugin Manifests (plugin.json)
- [ ] Declared permissions match actual behavior
- [ ] No hidden hooks or agents not listed in the manifest
- [ ] installPath points to expected directory

## Red Flags (Immediate CRITICAL)

| Pattern | Risk |
|---------|------|
| `curl`, `wget`, `fetch` to non-localhost URLs in hooks | Data exfiltration |
| Base64/hex encoded strings in skill content | Obfuscated instructions |
| "ignore previous instructions" or "override CLAUDE.md" | Prompt injection |
| `eval`, `exec`, `Function()` in hook scripts | Code injection |
| Hooks that write to files outside `.claude/` | Scope escape |
| Skills that reference `~/.ssh/`, `~/.aws/`, `~/.env` | Credential theft |

## Scan Procedure

1. Glob all skill/agent/hook/mcp files in `~/.claude/` AND `~/.agents/skills/` (symlinked skill sources)
2. Grep for red flag patterns above
3. For each hit, read context (10 lines around match) to assess intent
4. Classify: CRITICAL (immediate threat), HIGH (suspicious, needs review), INFO (probably fine)
5. Report findings with file path, line number, and assessment
