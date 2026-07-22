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
  # - Write/Bash on a design doc: flag (re-open review) AND strip any PASS→PENDING.
  #   A Write is a wholesale rewrite, so it re-opens review — matching the PreToolUse
  #   pre-arm, which arms a token on any Write of a design doc (#347;
  #   test-design-marker-cd-prearm "(1) Write of reviewed doc → re-armed"). The doc's
  #   marker must therefore read PENDING, consistent with that armed token. Older code
  #   PRESERVED a git-HEAD-committed PASS here — but the pre-arm still armed a token,
  #   so the doc read PASS while every worktree stayed blocked: a stale-PASS-with-live-
  #   token lie the operator (seeing PASS) never knew to re-review out of (#449).
  #   Stripping unconditionally makes the marker match the review state and doubles as
  #   the anti-self-stamp (a forged PASS embedded at creation time never survives).
  #   Strictly fail-CLOSED: it can only ADD a PENDING, never bless a PASS a Write could
  #   have changed. A genuine prior PASS is re-earned by re-running blueprint-review,
  #   whose inline loop prunes the token and re-stamps PASS (invisible to this hook).
  # - Edit: Only flag if PASS marker is ABSENT (blueprint-review adds it via Edit; a
  #   small Edit preserves review status — test-design-marker-cd-prearm).
  NEEDS_FLAG=false
  if [ "$TOOL_NAME" = "Write" ] || [ "$TOOL_NAME" = "Bash" ]; then
    NEEDS_FLAG=true
    # #449: a Write re-opens review, so downgrade the doc's honorable PASS→PENDING so its
    # marker matches the (re-)armed token — no HEAD lookup, no preserve branch. The
    # downgrade runs in marker_ops.py `downgrade-pass`, the SAME engine that READS the
    # marker (cmd_reviewed), so strip and honored-set can never diverge: it rewrites only
    # WHOLE-LINE PASS markers (an inline/prose occurrence is ignored by both reader and
    # writer by design), across LF / CRLF / bare-CR endings (cmd_reviewed reads in TEXT
    # mode where all three are line boundaries — a shell grep/sed strip is byte-level and
    # LF-only and silently missed CRLF/CR docs, recreating the lie: repeated Codex PR
    # findings), preserving every other byte and each line's ending.
    #
    # SYMLINK CONTAINMENT: downgrade-pass rewrites in place, so it must never follow a
    # symlink OUT of the repo and rewrite an external file (arbitrary-file-write via a
    # hostile symlink — Codex PR review). Resolve the physical file and downgrade it ONLY
    # when contained in the OPERATOR'S repo — the git top of the EFFECTIVE cwd (payload
    # cwd for Write/Edit, or a leading-`cd` target for a Bash redirect, #347 item 2a).
    # The anchor is the session cwd (harness-set), NOT `git -C "$(dirname FILE_PATH)"`,
    # which a symlinked parent would resolve into a foreign repo (a trivial cross-repo
    # escape); a leaf `-L` test is likewise insufficient (a symlinked PARENT leaves the
    # leaf a regular file). Both anchors are realpath'd via isolated `python3 -I`, so a
    # repo-local sitecustomize.py cannot override realpath to fake containment, while a
    # benign ancestor symlink above the repo (macOS /var→/private/var) is tolerated. On
    # skip, the reader-based post-check below fires and warns; the token is armed anyway.
    _CWD="$(printf '%s' "$INPUT" | python3 -I -c '
import sys, json
sys.path[:] = [p for p in sys.path if p not in ("", ".")]
sys.path.insert(0, sys.argv[1])
try:
    from gitcmd_detect import effective_cwd
except Exception:
    effective_cwd = None
try:
    d = json.load(sys.stdin)
    cwd = d.get("cwd") or "."
    tool = d.get("tool_name", d.get("toolName", ""))
    inp = d.get("tool_input", d.get("toolInput", {}))
    if isinstance(inp, str):
        inp = json.loads(inp)
    base = cwd
    if tool == "Bash" and effective_cwd is not None:
        eff, ok = effective_cwd(inp.get("command", ""), cwd)
        if ok and eff:
            base = eff
    print(base)
except Exception:
    print(".")
' "$_LIBDIR" 2>/dev/null || printf '.')"
    _iso_realpath() {
      python3 -I -c 'import sys
sys.path[:] = [p for p in sys.path if p not in ("", ".")]
import os
print(os.path.realpath(sys.argv[1]) if len(sys.argv) > 1 else "")' "$1" 2>/dev/null || true
    }
    _PHYS="$(_iso_realpath "$FILE_PATH")"
    _TOP="$(git -C "$_CWD" rev-parse --show-toplevel 2>/dev/null || true)"
    [ -n "$_TOP" ] && _TOP="$(_iso_realpath "$_TOP")"
    _DG_TARGET=""
    if [ -n "$_PHYS" ] && [ -n "$_TOP" ] && [ -f "$_PHYS" ]; then
      case "$_PHYS" in "$_TOP"/*) _DG_TARGET="$_PHYS" ;; esac
    fi
    if [ -n "$_DG_TARGET" ]; then
      # -I: same interpreter-hijack isolation as the realpath calls (a repo-local
      # re.py/os.py on cwd/PYTHONPATH cannot subvert the trusted lib script).
      python3 -I "$_LIBDIR/marker_ops.py" downgrade-pass "$_DG_TARGET" 2>/dev/null || true
    fi
    # Fail-open hook: if the downgrade was skipped (symlink escape out of the repo) or
    # failed (unwritable), an honored PASS may remain beside the armed token — the #449
    # lie. Re-check via the reader itself (exit 0 = still honorably reviewed) and warn.
    if python3 -I "$_LIBDIR/marker_ops.py" reviewed "$FILE_PATH" >/dev/null 2>&1; then
      echo "WARNING: $BASENAME still reads PASS (a reviewed 'design-reviewed: PASS' marker) but its review token is armed (this write re-opened review). Run /blueprint-review before implementing, or re-save the doc to retry the downgrade." >&2
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
