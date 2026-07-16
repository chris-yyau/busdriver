#!/usr/bin/env bash
# Design Review — PostToolUse Hook (Write|Edit|MultiEdit|Bash matcher)
#
# Detects when design/plan documents are written and flags them for review.
# Sets a state file that the pre-commit gate enforces.
# Supports Write/Edit/MultiEdit (file_path) and Bash (extracts paths from redirects/tee).
#
# Fail-open: never block file writes — only warn and set state.

set -euo pipefail
# ── Harness-portable root/state resolution ─────────────────────────────
# BUSDRIVER_PLUGIN_ROOT: plugin-root override; falls back to CLAUDE_PLUGIN_ROOT.
# Falls back to relative path from this script's location.
# BUSDRIVER_STATE_DIR: state-dir override, defaults to .claude.
# shellcheck disable=SC2034  # PLUGIN_ROOT used in env-var fallback chains
PLUGIN_ROOT="${BUSDRIVER_PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}}"
STATE_DIR="${BUSDRIVER_STATE_DIR:-.claude}"
# Constrain to a safe relative name (reject absolute/traversal/unsafe chars) and
# re-export so every gate writes/consumes markers from the same state dir.
case "$STATE_DIR" in ""|/*|*..*|*[!a-zA-Z0-9._/-]*) STATE_DIR=".claude" ;; esac
export BUSDRIVER_STATE_DIR="$STATE_DIR"
trap 'exit 0' ERR

# Shared marker helpers (gate_marker_arm / gate_marker_relpath — Task 2).
# Guard the source explicitly: the `trap 'exit 0' ERR` above would otherwise turn
# a missing/unreadable resolver into a silent exit-0 that arms nothing and warns
# nothing (fail-open). Warn, then keep the pre-existing disabled-gate behavior.
# shellcheck source=lib/resolve-repo-dir.sh disable=SC1091
if ! source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/resolve-repo-dir.sh"; then
  echo "WARNING: design-review marker helpers unavailable; no marker was armed." >&2
  exit 0
fi

# Consume stdin
INPUT=$(cat 2>/dev/null || true)
[ -z "$INPUT" ] && exit 0

# Extract file_path and tool_name from JSON input using Python (robust parsing)
# For Write/Edit: uses file_path from tool input
# For Bash: extracts file paths from redirect/tee targets matching design patterns
PARSED=$(printf '%s' "$INPUT" | python3 -c "
import sys, json, re, os
try:
    d = json.load(sys.stdin)
    tool = d.get('tool_name', d.get('toolName', ''))
    inp = d.get('tool_input', d.get('toolInput', {}))
    if isinstance(inp, str):
        inp = json.loads(inp)
    if tool in ('Write', 'Edit'):
        path = inp.get('file_path', inp.get('filePath', ''))
        print(f'{tool}|{path}')
    elif tool == 'MultiEdit':
        # MultiEdit's tool_input carries file_path at the top level in the
        # common case, but mirror the sibling hooks (post-edit-accumulator.js,
        # gateguard-fact-force.js) that also fall back to the first edit's own
        # file_path — defensive against harness variants that nest it there.
        path = inp.get('file_path', inp.get('filePath', ''))
        if not path:
            edits = inp.get('edits', [])
            if isinstance(edits, list) and edits and isinstance(edits[0], dict):
                path = edits[0].get('file_path', edits[0].get('filePath', ''))
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
        state_dir = os.environ.get('BUSDRIVER_STATE_DIR', '.claude')
        design_re = re.compile(r'(?:^|/)(?:PLAN|DESIGN|ARCHITECTURE)[^/]*\.md$', re.IGNORECASE)
        plans_re = re.compile(r'(?:' + re.escape(state_dir) + r'|docs)/(?:[^/]+/)*(?:plans|specs)/.*\.md$')
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
# These are produced by /blueprint-review itself — flagging them creates a loop
if echo "$FILE_PATH" | grep -qiE '(reviews/|review-needed|review-state|review-agy|review-codex|review-claude|review-consensus|review-autofix|review-decisions)'; then
  exit 0
fi

# Exclude memory/lesson files and memory archive — contain "design" in slugs but aren't design docs
if echo "$FILE_PATH" | grep -qE '(memory/|lesson-)'; then
  exit 0
fi

# Check if file matches design document pattern:
# 1. Basename STARTS WITH PLAN, DESIGN, or ARCHITECTURE (case-insensitive)
#    This prevents false positives like "lesson-council-reflection-design.md"
# 2. File is inside a plans/ or specs/ directory under $STATE_DIR/ or docs/
#    (covers docs/plans/, docs/specs/, $STATE_DIR/plans/, etc.)
#
# Exclusion: files in structural directories that never contain design docs
# (agents/, commands/, scripts/, hooks/, tests/, src/, lib/, skills/)
# Prevents false positives like agents/plan-code-reviewer.md.
# ADR-B: match the REPO-RELATIVE path, not the full path — a repo checked out
# under /home/u/src/proj/ must not have its own docs/plans/X.md un-flagged just
# because the ancestor path contains /src/. Fall back to the full path when the
# repo root can't be resolved.
_EXCL_TARGET="$(gate_marker_relpath "$FILE_PATH" 2>/dev/null || printf '%s' "$FILE_PATH")"
if echo "$_EXCL_TARGET" | grep -qE '(^|/)(agents|commands|scripts|hooks|tests|src|lib|skills)/'; then
  exit 0
fi

BASENAME=$(basename "$FILE_PATH")
IS_DESIGN=false
if echo "$BASENAME" | grep -qiE '^(PLAN|DESIGN|ARCHITECTURE).*\.md$'; then
  IS_DESIGN=true
fi
if echo "$FILE_PATH" | grep -qE "($STATE_DIR|docs)/([^/]+/)*(plans|specs)/.*\\.md\$"; then
  IS_DESIGN=true
fi
if [ "$IS_DESIGN" = true ]; then
  # Determine if file needs flagging:
  # - Write/Bash on NEW file: flag + strip PASS (anti-self-stamp)
  #   Claude can embed <!-- design-reviewed: PASS --> at creation time to bypass review.
  # - Write/Bash on PREVIOUSLY REVIEWED file: flag but PRESERVE PASS marker.
  #   Rewrites of already-reviewed files (e.g. applying review findings) should not
  #   reset review status. "Previously reviewed" = git committed version has PASS.
  # - Edit: Only flag if PASS marker is ABSENT (blueprint-review adds it via Edit)
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
    # Edit — trust the marker (blueprint-review adds it legitimately via Edit)
    if ! grep -q "<!-- design-reviewed: PASS -->" "$FILE_PATH" 2>/dev/null; then
      NEEDS_FLAG=true
    fi
  fi

  if [ "$NEEDS_FLAG" = true ]; then
    # ADR-D: arm an immutable per-arming token under the shared git-common-dir so
    # the pending state is visible from every linked worktree. This replaces the
    # single CWD-relative design-review-needed.local.md whose per-worktree
    # divergence was the fail-open this PR closes.
    #
    # DEFERRED (design §2/§9 — "Bash-write effective-directory resolution"): for a
    # Bash tool call, FILE_PATH is the raw redirect/tee target. If the command
    # changed directory inline (`cd /other && > docs/plans/X.md`), the effective
    # dir differs from the hook CWD and the wrong repo could be armed (or, more
    # commonly, norm() fails → best-effort miss). This is UNCHANGED from the prior
    # append-to-file code (equally cd-blind) and NOT a regression; a correct fix
    # needs a shell-aware cd parser, deferred to the follow-up issue. For every
    # non-inline-cd write the hook CWD equals the command's effective dir, so
    # arming is correct.
    if ! gate_marker_arm "$FILE_PATH"; then
      # Best-effort miss — this is the design-DEFERRED "fail-closed arming" item
      # (§2). Arming lives in this PostToolUse detector, which cannot block; making
      # it truly fail-closed means moving it into a PreToolUse gate (deferred to the
      # follow-up issue). Some failure modes DO stay fail-CLOSED here: an
      # unresolvable common-dir also makes the READ gates return exit 2 → block, and
      # a partial-token write leaves an `unparseable` token → block. The residual
      # (a pre-token mkdir/normalize failure while the common-dir is resolvable)
      # is the accepted best-effort miss — UNCHANGED from the prior detector (which
      # was silently fail-open on write failure; this at least warns). We do NOT
      # write a repo-relative legacy marker fallback: a `>>`/`>` to a computed path
      # is a symlink / TOCTOU surface for marginal coverage. The D3 legacy UNION
      # reader still honours any pre-existing migration markers.
      echo "WARNING: could not arm the design-review marker for $BASENAME. If the repo state is resolvable the review gate may not fire for this doc — re-save it, or run /blueprint-review before implementing." >&2
    fi

    echo "Design document written: $BASENAME"
    echo "REQUIRED: Invoke /blueprint-review skill (Skill tool) before committing."
    echo "Do NOT use code-reviewer agent — it cannot mark design docs as reviewed."
  fi
fi

exit 0
