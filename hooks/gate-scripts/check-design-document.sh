#!/usr/bin/env bash
# Design Review — PostToolUse Hook (Write|Edit|Bash matcher)
#
# Detects when design/plan documents are written and flags them for review.
# Sets a state file that the pre-commit gate enforces.
# Supports Write/Edit (file_path) and Bash (extracts paths from redirects/tee).
#
# Fail-open: never block file writes — only warn and set state.

set -euo pipefail
trap 'exit 0' ERR

# Consume stdin
INPUT=$(cat 2>/dev/null || true)
[ -z "$INPUT" ] && exit 0

# Extract file_path and tool_name from JSON input using Python (robust parsing)
# For Write/Edit: uses file_path from tool input
# For Bash: extracts file paths from redirect/tee targets matching design patterns
PARSED=$(printf '%s' "$INPUT" | python3 -c "
import sys, json, re
try:
    d = json.load(sys.stdin)
    tool = d.get('tool_name', d.get('toolName', ''))
    inp = d.get('tool_input', d.get('toolInput', {}))
    if isinstance(inp, str):
        inp = json.loads(inp)
    if tool in ('Write', 'Edit'):
        path = inp.get('file_path', inp.get('filePath', ''))
        print(f'{tool}|{path}')
    elif tool == 'Bash':
        # Extract file paths from Bash commands that create design docs
        # Patterns: echo/cat/printf > file, tee file, cp ... file
        cmd = inp.get('command', '')
        # Match redirect targets and tee arguments
        targets = []
        # Shell redirects: > file or >> file (skip /dev/null)
        for m in re.finditer(r'>{1,2}\s*([^\s;&|]+)', cmd):
            t = m.group(1).strip('\"').strip(\"'\")
            if t != '/dev/null':
                targets.append(t)
        # tee targets
        for m in re.finditer(r'\btee\s+(?:-a\s+)?([^\s;&|]+)', cmd):
            t = m.group(1).strip('\"').strip(\"'\")
            targets.append(t)
        # cp/mv destination (last arg)
        for m in re.finditer(r'\b(?:cp|mv)\s+.*?\s+([^\s;&|]+)\s*(?:[;&|]|$)', cmd):
            t = m.group(1).strip('\"').strip(\"'\")
            targets.append(t)
        # Filter to only design-doc patterns
        design_re = re.compile(r'(?:^|/)(?:PLAN|DESIGN|ARCHITECTURE)[^/]*\.md$', re.IGNORECASE)
        plans_re = re.compile(r'(?:\.claude|docs)/(?:[^/]+/)*(?:plans|specs)/.*\.md$')
        for t in targets:
            if design_re.search(t) or plans_re.search(t):
                print(f'Bash|{t}')
                break
        else:
            print('|')
    else:
        print('|')
except Exception:
    print('|')
" 2>/dev/null || true)
TOOL_NAME="${PARSED%%|*}"
FILE_PATH="${PARSED#*|}"

# No file path → silent pass
if [ -z "$FILE_PATH" ]; then
  exit 0
fi

# Exclude review output files (design-review-*.md, design-review-*.json, etc.)
# These are produced by /design-reviewer itself — flagging them creates a loop
if echo "$FILE_PATH" | grep -qiE '(reviews/|review-needed|review-state|review-gemini|review-codex|review-claude|review-consensus|review-autofix|review-decisions)'; then
  exit 0
fi

# Exclude memory/lesson files and memory archive — contain "design" in slugs but aren't design docs
if echo "$FILE_PATH" | grep -qE '(memory/|lesson-)'; then
  exit 0
fi

# Check if file matches design document pattern:
# 1. Basename STARTS WITH PLAN, DESIGN, or ARCHITECTURE (case-insensitive)
#    This prevents false positives like "lesson-council-reflection-design.md"
# 2. File is inside a plans/ or specs/ directory under .claude/ or docs/
#    (covers docs/plans/, docs/superpowers/plans/, docs/superpowers/specs/, etc.)
#
# Exclusion: files in structural directories that never contain design docs
# (agents/, commands/, scripts/, hooks/, tests/, src/, lib/, skills/)
# Prevents false positives like agents/plan-code-reviewer.md
if echo "$FILE_PATH" | grep -qE '(^|/)(agents|commands|scripts|hooks|tests|src|lib|skills)/'; then
  exit 0
fi

BASENAME=$(basename "$FILE_PATH")
IS_DESIGN=false
if echo "$BASENAME" | grep -qiE '^(PLAN|DESIGN|ARCHITECTURE).*\.md$'; then
  IS_DESIGN=true
fi
if echo "$FILE_PATH" | grep -qE '(\.claude|docs)/([^/]+/)*(plans|specs)/.*\.md$'; then
  IS_DESIGN=true
fi
if [ "$IS_DESIGN" = true ]; then
  # Determine if file needs flagging:
  # - Write/Bash on NEW file: flag + strip PASS (anti-self-stamp)
  #   Claude can embed <!-- design-reviewed: PASS --> at creation time to bypass review.
  # - Write/Bash on PREVIOUSLY REVIEWED file: flag but PRESERVE PASS marker.
  #   Rewrites of already-reviewed files (e.g. applying review findings) should not
  #   reset review status. "Previously reviewed" = git committed version has PASS.
  # - Edit: Only flag if PASS marker is ABSENT (design-reviewer adds it via Edit)
  NEEDS_FLAG=false
  if [ "$TOOL_NAME" = "Write" ] || [ "$TOOL_NAME" = "Bash" ]; then
    NEEDS_FLAG=true
    # Anti-self-stamp: strip PASS only for truly new or unreviewed files.
    # If git's committed version already has PASS, this is a rewrite of a
    # reviewed file — preserve the marker to avoid infinite review loops.
    if grep -q "<!-- design-reviewed: PASS -->" "$FILE_PATH" 2>/dev/null; then
      PREVIOUSLY_REVIEWED=false
      if git show "HEAD:$FILE_PATH" 2>/dev/null | grep -q "<!-- design-reviewed: PASS -->"; then
        PREVIOUSLY_REVIEWED=true
      fi
      if [ "$PREVIOUSLY_REVIEWED" = false ]; then
        # New or unreviewed file with embedded PASS — strip (anti-self-stamp)
        if [[ "$(uname)" == "Darwin" ]]; then
          sed -i '' 's/<!-- design-reviewed: PASS -->/<!-- design-reviewed: PENDING -->/' "$FILE_PATH" 2>/dev/null || true
        else
          sed -i 's/<!-- design-reviewed: PASS -->/<!-- design-reviewed: PENDING -->/' "$FILE_PATH" 2>/dev/null || true
        fi
      fi
    fi
  else
    # Edit — trust the marker (design-reviewer adds it legitimately via Edit)
    if ! grep -q "<!-- design-reviewed: PASS -->" "$FILE_PATH" 2>/dev/null; then
      NEEDS_FLAG=true
    fi
  fi

  if [ "$NEEDS_FLAG" = true ]; then
    # Set state file for pre-commit gate enforcement
    STATE_FILE=".claude/design-review-needed.local.md"
    mkdir -p .claude

    # Append file to review list (avoid duplicates)
    if [ -f "$STATE_FILE" ]; then
      if ! grep -qF "$FILE_PATH" "$STATE_FILE" 2>/dev/null; then
        echo "- $FILE_PATH" >> "$STATE_FILE"
      fi
    else
      cat > "$STATE_FILE" << EOF
---
active: true
created_at: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
---

# Design documents pending review

- $FILE_PATH
EOF
    fi

    echo "Design document written: $BASENAME"
    echo "REQUIRED: Invoke /design-reviewer skill (Skill tool) before committing."
    echo "Do NOT use code-reviewer agent — it cannot mark design docs as reviewed."
  fi
fi

exit 0
