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
# Reject absolute, traversal, bad chars — AND any value os.path.normpath would
# collapse (bare `.`, trailing `/`, `./` prefix, `/.` suffix, `//` or `/./`
# segments). The detector greps STATE_DIR against the RAW path while the
# exemption greps the NORMALIZED path; a normalize-unstable STATE_DIR would arm a
# review the exemption then can't match — deadlocking that doc. Default is stable.
case "$STATE_DIR" in ""|.|/*|*/|./*|*/.|*//*|*/./*|*..*|*[!a-zA-Z0-9._/-]*) STATE_DIR=".claude" ;; esac
export BUSDRIVER_STATE_DIR="$STATE_DIR"
trap 'exit 0' ERR

# Shared marker helpers (gate_marker_arm / gate_marker_relpath — Task 2).
# Guard the source explicitly: the `trap 'exit 0' ERR` above would otherwise turn
# a missing/unreadable resolver into a silent exit-0 that arms nothing and warns
# nothing (fail-open). Warn, then keep the pre-existing disabled-gate behavior.
_LIBDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
# shellcheck source=lib/resolve-repo-dir.sh disable=SC1091
if ! source "$_LIBDIR/resolve-repo-dir.sh"; then
  echo "WARNING: design-review marker helpers unavailable; no marker was armed." >&2
  exit 0
fi

# Consume stdin
INPUT=$(cat 2>/dev/null || true)
[ -z "$INPUT" ] && exit 0

# Extract file_path and tool_name from JSON input using Python (robust parsing)
# For Write/Edit: uses file_path from tool input
# For Bash: extracts file paths from redirect/tee targets matching design patterns
PARSED=$(printf '%s' "$INPUT" | python3 -I -c "
import sys
sys.path[:] = [p for p in sys.path if p not in ('', '.')]
sys.path.insert(0, sys.argv[1])   # trusted gate lib dir (BASH_SOURCE-derived)
import json, re, os
try:
    from gitcmd_detect import effective_cwd
except Exception:
    effective_cwd = None
try:
    d = json.load(sys.stdin)
    tool = d.get('tool_name', d.get('toolName', ''))
    inp = d.get('tool_input', d.get('toolInput', {}))
    if isinstance(inp, str):
        inp = json.loads(inp)
    payload_cwd = d.get('cwd') or '.'
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
        plans_re = re.compile(r'(?:^|/)(?:' + re.escape(state_dir) + r'|docs)/(?:[^/]+/)*(?:plans|specs)/.*\.md$')
        for t in targets:
            if design_re.search(t) or plans_re.search(t):
                # #347 item 2a — resolve the redirect target to an ABSOLUTE path via the
                # command's effective cwd (honoring a leading cd), so the arm and the
                # anti-self-stamp PASS-strip target the repo/file the write ACTUALLY
                # lands in, not the process cwd. An unresolvable cd or a non-cd command
                # falls back to the payload cwd (PostToolUse cannot block anyway).
                rt = t
                if not os.path.isabs(rt):
                    base = payload_cwd
                    if effective_cwd is not None:
                        eff, ok = effective_cwd(cmd, payload_cwd)
                        if ok and eff:
                            base = eff
                    rt = os.path.join(base, rt)
                print(f'Bash|{rt}')
                break
        else:
            print('|')
    else:
        print('|')
except Exception:
    print('|')
" "$_LIBDIR" 2>/dev/null || true)
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
# #446 — classify via the SAME physical grammar the pre-implementation gate's
# exemption uses (gate_design_doc_exempt → marker_ops.py dd-exempt): a design doc
# iff it matches the detector grammar BOTH lexically AND after os.path.realpath
# (every symlink on the path resolved). Previously this used two lexical greps, so
# a symlinked `docs/plans -> ../src` armed a spurious repo-wide review for an impl
# write the gate then treated as impl (ADR 0021 claimed "one physical grammar" that
# did not exist). Routing through the shared function makes detector and gate agree.
# rc: 0=design doc → arm; 1=not a design doc → skip; 2=helper error → arm
# (fail-CLOSED for a review gate: an over-block beats a silently skipped review,
# matching the gate's own treatment of rc 2, and the pre-existing lexical arm).
_DDE=0; gate_design_doc_exempt "$FILE_PATH" "$STATE_DIR" || _DDE=$?
IS_DESIGN=false
case "$_DDE" in 0|2) IS_DESIGN=true ;; esac
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
      # #347 item 2a made FILE_PATH absolute for Bash-redirect writes (previously
      # it could be the raw, often repo-relative, redirect-target string) — but
      # `git show HEAD:<path>` requires a path relative to the repo root, not an
      # absolute filesystem path. Reviewer finding (PR #444): resolve to
      # repo-relative via the shared gate_marker_relpath helper before the git
      # show lookup. An unresolvable path (not inside a repo, or escapes the
      # root) leaves PREVIOUSLY_REVIEWED=false — same as "git show found nothing".
      _FILE_PATH_REL="$(gate_marker_relpath "$FILE_PATH" 2>/dev/null || true)"
      # Bind the git-show lookup to the repo CONTAINING the target file, not the
      # hook's process cwd. #347 item 2a resolves a cross-repo Bash write
      # (`cd /other && > docs/plans/DESIGN.md`) to an ABSOLUTE FILE_PATH; a plain
      # `git show HEAD:<rel>` would read HEAD from the ORIGINAL repo, so a reviewed
      # file at the same relative path there could bless a FORGED PASS in the target
      # repo and skip arming it (fail-open, PR #444 review). git -C on a missing
      # parent (a new nested file) yields an empty root → the && short-circuits →
      # PREVIOUSLY_REVIEWED stays false → the PASS is stripped (fail-closed).
      _FILE_REPO_ROOT="$(git -C "$(dirname "$FILE_PATH")" rev-parse --show-toplevel 2>/dev/null || true)"
      if [[ -n "$_FILE_PATH_REL" && -n "$_FILE_REPO_ROOT" ]] \
         && git -C "$_FILE_REPO_ROOT" show "HEAD:$_FILE_PATH_REL" 2>/dev/null | grep -q "<!-- design-reviewed: PASS -->"; then
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
    # Edit — trust the marker (blueprint-review adds it legitimately via Edit),
    # but a PASS over DEGRADED coverage is not honored (#355) → re-arm review.
    if ! gate_design_pass_honored "$FILE_PATH"; then
      NEEDS_FLAG=true
    fi
  fi

  if [ "$NEEDS_FLAG" = true ]; then
    # ADR-D: arm an immutable per-arming token under the shared git-common-dir so
    # the pending state is visible from every linked worktree. This replaces the
    # single CWD-relative design-review-needed.local.md whose per-worktree
    # divergence was the fail-open this PR closes.
    #
    # #347 item 2a (was DEFERRED §2/§9 — "Bash-write effective-directory resolution"):
    # for a Bash tool call, FILE_PATH is now the redirect/tee target RESOLVED to an
    # absolute path against the command's effective cwd (a leading `cd` is honored;
    # see the extraction block above via gitcmd_detect.effective_cwd). So an inline
    # `cd /other && > docs/plans/X.md` arms the repo the write LANDS in, and the
    # anti-self-stamp PASS-strip above hits the right file. An unresolvable cd falls
    # back to the payload cwd (best-effort — PostToolUse cannot block).
    if ! gate_marker_arm "$FILE_PATH"; then
      # #347 item 1 note: the FAIL-CLOSED guarantee for a Write/Edit/MultiEdit design
      # doc now lives in the PreToolUse pre-implementation gate (_design_prearm_or_block),
      # which arms BEFORE the write and BLOCKS if the arm fails while the marker dir is
      # resolvable. This PostToolUse arm remains a best-effort backstop (and the sole
      # arm for Bash-redirect design-doc creation, which the PreToolUse pre-arm does not
      # cover — documented residual). Some failure modes stay fail-CLOSED regardless: an
      # unresolvable common-dir makes the READ gates return exit 2 → block, and a
      # partial-token write leaves an `unparseable` token → block. A repo-relative legacy
      # marker fallback is deliberately NOT written (a `>>`/`>` to a computed path is a
      # symlink / TOCTOU surface); the D3 legacy UNION reader still honours pre-existing
      # migration markers.
      echo "WARNING: could not arm the design-review marker for $BASENAME. If the repo state is resolvable the review gate may not fire for this doc — re-save it, or run /blueprint-review before implementing." >&2
    fi

    echo "Design document written: $BASENAME"
    echo "REQUIRED: Invoke /blueprint-review skill (Skill tool) before committing."
    echo "Do NOT use code-reviewer agent — it cannot mark design docs as reviewed."
  fi
fi

exit 0
