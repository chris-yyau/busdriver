#!/bin/bash
# Initialize litmus review loop state file
# Follows Ralph Loop pattern for robust state management

set -euo pipefail

STATE_DIR="${BUSDRIVER_STATE_DIR:-.claude}"

# Parse arguments
FORCE=false
POSITIONAL_ARGS=()
for arg in "$@"; do
    case "$arg" in
        --force|-f) FORCE=true ;;
        *) POSITIONAL_ARGS+=("$arg") ;;
    esac
done
MAX_ITERATIONS="${POSITIONAL_ARGS[0]:-10}"
COMPLETION_PROMISE="${POSITIONAL_ARGS[1]:-null}"

# Validate max iterations
if ! [[ "$MAX_ITERATIONS" =~ ^[0-9]+$ ]] || [ "$MAX_ITERATIONS" -lt 1 ]; then
    echo "❌ Error: MAX_ITERATIONS must be a positive integer" >&2
    echo "   Usage: $0 [--force] [max_iterations] [completion_promise]" >&2
    echo "   Example: $0 10" >&2
    echo "   Example: $0 10 \"REVIEW PASSED\"" >&2
    exit 1
fi

# Source iteration history library
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/iteration-history.sh
source "$SCRIPT_DIR/lib/iteration-history.sh"

# Guard: prevent re-init while a review loop is active.
#
# The guard REFUSES for every active loop, mode-mismatched or not. `active: true`
# cannot tell a KILLED run from a LIVE one, so auto-re-initializing on a mode change
# would clear the iteration history and overwrite the state file of a review that may
# still be running — two writers on one file. That trades a stranded caller (annoying,
# safe) for a race (silent, unsafe), which is the wrong direction for this gate.
#
# What #363 actually needed was the TRUTH, not a re-init. The old message never
# mentioned the mode, so the stranding was invisible: a run killed mid-review (the
# harness Bash timeout — see the timeout note in SKILL.md) leaves `active: true` +
# `review_status: PENDING` behind; the next init refused and exited 1 to stderr, easy
# to miss; review_mode was never rewritten; and run-review-loop.sh — which reads
# review_mode from this file and lets it OVERRIDE $LITMUS_MODE — silently re-ran the
# PREVIOUS mode. A believed commit-mode review of a staged fix actually re-reviewed
# `origin/main...HEAD`, reported the already-fixed issue as still present, and cost a
# full cycle chasing a phantom disagreement with the reviewer.
#
# So the mismatch is now called out explicitly, because it is the case where silently
# continuing is not merely stale but reviews the WRONG DIFF, and the operator is told
# which recovery applies.
STATE_FILE="$STATE_DIR/litmus-state.md"
if [ "$FORCE" != "true" ] && [ -f "$STATE_FILE" ]; then
    # Source validation library for get_yaml_value
    # shellcheck source=lib/validation.sh
    source "$SCRIPT_DIR/lib/validation.sh"
    EXISTING_ACTIVE=$(get_yaml_value "active" "$STATE_FILE" 2>/dev/null || echo "false")
    EXISTING_MODE=$(get_yaml_value "review_mode" "$STATE_FILE" 2>/dev/null || echo "")
    # Track PRESENCE separately from value. run-review-loop.sh only lets the state file
    # override $LITMUS_MODE when the field is non-empty and != "null"; an ABSENT field
    # means it falls back to $LITMUS_MODE. So a legacy state file has no mode to clash
    # with, and claiming one would make this message assert the opposite of what
    # run-review-loop.sh will do — the exact class of lie this change exists to remove.
    EXISTING_MODE_PRESENT=1
    case "$EXISTING_MODE" in ""|null) EXISTING_MODE_PRESENT=0 ;; esac
    # The value still defaults for the guard itself: an active loop is guarded either
    # way (it is the counter that needs protecting, not the mode).
    [ "$EXISTING_MODE_PRESENT" = "0" ] && EXISTING_MODE="commit"
    # Normalize the REQUEST exactly as the state writer below does (anything that is
    # not "pr" is written as "commit"). Without this, LITMUS_MODE=typo would compare
    # as a third, non-existent mode and report a mismatch against a state file that
    # is in fact the very mode it is about to create.
    REQUESTED_MODE="${LITMUS_MODE:-commit}"
    [ "$REQUESTED_MODE" != "pr" ] && REQUESTED_MODE="commit"
    if [ "$EXISTING_ACTIVE" = "true" ]; then
        EXISTING_ITER=$(get_yaml_value "iteration" "$STATE_FILE" 2>/dev/null || echo "?")
        EXISTING_MAX=$(get_yaml_value "max_iterations" "$STATE_FILE" 2>/dev/null || echo "?")
        EXISTING_STATUS=$(get_yaml_value "review_status" "$STATE_FILE" 2>/dev/null || echo "?")
        _MODE_SHOWN="$EXISTING_MODE"
        [ "$EXISTING_MODE_PRESENT" = "0" ] && _MODE_SHOWN="unset (run-review-loop.sh will use \$LITMUS_MODE)"
        echo "⚠️  Active review loop already exists (iteration $EXISTING_ITER/$EXISTING_MAX, mode=$_MODE_SHOWN, status=$EXISTING_STATUS)" >&2
        echo "   Re-initializing would reset the iteration counter!" >&2
        if [ "$EXISTING_MODE_PRESENT" = "1" ] && [ "$EXISTING_MODE" != "$REQUESTED_MODE" ]; then
            echo "" >&2
            echo "   ❗ You requested mode=$REQUESTED_MODE but the state file says mode=$EXISTING_MODE." >&2
            echo "      run-review-loop.sh reads review_mode from this file and it OVERRIDES \$LITMUS_MODE," >&2
            echo "      so running it now reviews the $EXISTING_MODE diff, NOT the $REQUESTED_MODE one" >&2
            echo "      (commit = git diff --cached; pr = <base>...HEAD). Do not just re-run it." >&2
        fi
        echo "" >&2
        echo "   Pick by what is actually true — check first whether a reviewer is running:" >&2
        echo "" >&2
        echo "   (a) A review is RUNNING right now → WAIT for it. Do NOT start another and do" >&2
        echo "       NOT --force: a second run-review-loop.sh writes this same state file, and" >&2
        echo "       two writers are what this guard exists to prevent." >&2
        echo "" >&2
        echo "   (b) The previous run was KILLED (status=PENDING, nothing running) → the state" >&2
        echo "       is stale; discard it:" >&2
        # Carry LITMUS_MODE into the printed remedy. It is an ENV VAR, so a bare
        # `$0 --force N` silently re-creates the DEFAULT (commit) mode — an operator who
        # invoked `LITMUS_MODE=pr init-review-loop.sh` and pasted that would land right
        # back in the wrong-diff behavior this message exists to prevent.
        if [ "$REQUESTED_MODE" = "pr" ]; then
            echo "         LITMUS_MODE=pr $0 --force $MAX_ITERATIONS" >&2
        else
            echo "         $0 --force $MAX_ITERATIONS" >&2
        fi
        echo "" >&2
        echo "   (c) The loop is PAUSED between iterations (status=FAIL, waiting on your fixes)" >&2
        echo "       → resume it in its own mode ($EXISTING_MODE), which keeps the counter:" >&2
        echo "         bash $SCRIPT_DIR/run-review-loop.sh" >&2
        exit 1
    fi
fi

# Clear any previous iteration history
clear_iteration_history

# Ensure we're in a git repository
if ! git rev-parse --git-dir > /dev/null 2>&1; then
    echo "❌ Error: Not a git repository" >&2
    echo "   Run this script from within a git repository" >&2
    exit 1
fi

# Create state directory if it doesn't exist
mkdir -p "$STATE_DIR"

# Get current timestamp in ISO 8601 format
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Determine review mode (commit vs PR)
REVIEW_MODE="${LITMUS_MODE:-commit}"

# Detect base branch for PR mode
if [ "$REVIEW_MODE" = "pr" ]; then
  PR_BASE_BRANCH="${LITMUS_PR_BASE:-$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/||' || echo "origin/main")}"
  # Auto-prefix origin/ if user provided a branch name without remote prefix
  # (e.g. LITMUS_PR_BASE=main → origin/main, LITMUS_PR_BASE=feature/foo → origin/feature/foo)
  if [[ -n "${LITMUS_PR_BASE:-}" && "$PR_BASE_BRANCH" != origin/* ]]; then
    PR_BASE_BRANCH="origin/${PR_BASE_BRANCH}"
  fi
fi

# Create state file with YAML frontmatter
if [ "$REVIEW_MODE" = "pr" ]; then
cat > "$STATE_DIR/litmus-state.md" <<'EOF'
---
active: true
iteration: 1
max_iterations: MAX_ITERATIONS_PLACEHOLDER
completion_promise: COMPLETION_PROMISE_PLACEHOLDER
review_mode: "pr"
review_status: "PENDING"
started_at: "TIMESTAMP_PLACEHOLDER"
last_result: null
---

Perform a DEEP PR REVIEW of the FULL BRANCH DIFF (base...HEAD) — covering bugs, security, cross-commit consistency, project guidelines, history, and documentation drift. You are the lead deep reviewer; cover every lens below in this single pass.

<review_lenses>
This is a DEEP PR REVIEW of the entire branch (base...HEAD), not a single commit. Cover ALL of these
lenses in this one pass. An independent Security/Bugs reviewer runs alongside you — do NOT assume it
will catch what you skip.

1. BUGS — logic errors, off-by-one, null/undefined, race conditions, resource leaks (changed code only).
2. SECURITY — hardcoded secrets, injection (shell/SQL/path), auth bypass, SSRF, unsafe deserialization,
   error messages leaking internals, unsafe or unpinned dependencies. Trace data flow ACROSS files.
3. CROSS-COMMIT CONSISTENCY — inconsistent naming across commits, partial migrations/refactors,
   orphaned imports, incomplete renames, a signature changed in one file but not its callers.
4. GUIDELINES — CLAUDE.md / project conventions, naming consistency, established patterns.
5. HISTORY — use the injected <commit_history> below (the commit log + per-commit stat for this
   branch). Flag reverted-then-reintroduced changes, contradictory commits, debug/WIP code left in.
   Do NOT attempt to run git yourself — review only the injected data and diff.
6. DOCS DRIFT — README/SKILL.md/docs referencing changed code. Flag stale examples, wrong signatures,
   removed functions still documented, new features lacking docs.
</review_lenses>

<commit_history>
{{HISTORY_CONTEXT}}
</commit_history>

{{SAST_PRECHECK}}

<diff>
{{STAGED_DIFF}}
</diff>

<cross_file_context>
{{SMART_CONTEXT}}
</cross_file_context>

<docs_context>
{{DOCS_CONTEXT}}
</docs_context>

<changelog>
{{PREV_CHANGELOG}}
</changelog>

<iteration_history>
{{ITERATION_HISTORY}}
</iteration_history>

<output_contract>
You MUST output a single JSON object conforming to this schema. No markdown, no commentary, no text before or after.

Schema:
{
  "status": "PASS" or "FAIL",
  "issues": [
    {
      "file": "path/to/file.ext",
      "line": 42,
      "severity": "high" | "medium" | "low",
      "category": "security" | "bug" | "performance" | "maintainability",
      "description": "Clear description referencing the actual code",
      "suggestion": "Concrete fix with code example when possible",
      "confidence": 85
    }
  ]
}

Field rules:
- status: "FAIL" if ANY high or medium severity issue exists. "PASS" otherwise.
- file: relative path from repo root. Must match a file in the diff.
- line: integer line number. Use 0 only for file-level issues.
- severity: "high" = bugs, security vulns, data loss. "medium" = perf, error handling. "low" = style, naming.
- category: exactly one of "security", "bug", "performance", "maintainability".
- description: specific, referencing the actual code. Not generic advice.
- suggestion: concrete fix. Not "consider fixing" — show what to change.
- confidence: integer 0-100. How certain this is a real issue, not a false positive. Required.
</output_contract>

<grounding_rules>
- Only report issues in the CHANGED code shown in the diff. Do not report pre-existing issues.
- Every finding must reference a specific file and line from the diff.
- Do not report issues that linters or type checkers would catch (formatting, unused imports).
- Do not re-report issues from the iteration_history that have already been fixed.
- Maximum 10 issues per review. Prioritize by severity, then confidence.
- If all previous issues are fixed and no new issues found, return {"status": "PASS", "issues": []}.
- Maximum 3 new issues per iteration to ensure convergence.
- When reviewing shell scripts, check: unquoted variables, missing error handling, unsafe temp files, local outside functions, shasum vs sha256sum portability, mktemp -t portability, CWD/path safety, cleanup ordering before early exits, timeout fail-open, boolean normalization.
- When reviewing documentation, verify: factual claims match code, examples are correct, counts match reality, no stale references.
- When reviewing cross-commit changes, check: inconsistent naming, partial refactors, broken dependencies.
- Severity calibration: "high" is reserved for correctness, security, data-loss, or interface-breaking risks. Documentation drift, missing/weak comments, naming/style nits, and "function is long but correct" MUST be rated "low" (advisory, never blocking) — never "high" or "medium". Severity reflects IMPACT, not certainty.
- When reviewing CI/CD workflows (.github/workflows/*.yml, .gitlab-ci.yml):
  - Flag `paths` + `paths-ignore` on the same trigger (GitHub Actions ignores one silently).
  - Flag `${{ }}` expressions inside `run:` blocks — use `env:` intermediary to prevent expression injection.
  - Flag `curl | sh`, `curl | sudo sh`, or `wget | sh` patterns — supply chain risk. Pin to a commit SHA or use a versioned action.
  - Flag unpinned `pip install`, `npm install -g`, or `gem install` without version pins in CI steps.
  - Flag action `uses:` references without SHA pins (e.g., `actions/checkout@v4` instead of `actions/checkout@<sha>`).
  - Flag missing top-level `permissions: {}` — workflows should use least-privilege with job-level permissions.
  - Flag conditional skip logic (`grep -q` / `if [ -f ... ]`) that can be bypassed by non-functional references or empty files.
- Property testing gap: if changes touch parsers, validators, serializers, auth, or financial logic — flag as LOW if no property-based tests exist. Advisory only.
</grounding_rules>
EOF
else
cat > "$STATE_DIR/litmus-state.md" <<'EOF'
---
active: true
iteration: 1
max_iterations: MAX_ITERATIONS_PLACEHOLDER
completion_promise: COMPLETION_PROMISE_PLACEHOLDER
review_mode: "commit"
review_status: "PENDING"
started_at: "TIMESTAMP_PLACEHOLDER"
last_result: null
---

Review the following staged changes (git diff --cached) for bugs, security issues, performance problems, and maintainability. Do NOT review unstaged or untracked files.

{{SAST_PRECHECK}}

<diff>
{{STAGED_DIFF}}
</diff>

<cross_file_context>
{{SMART_CONTEXT}}
</cross_file_context>

<docs_context>
{{DOCS_CONTEXT}}
</docs_context>

<changelog>
{{PREV_CHANGELOG}}
</changelog>

<iteration_history>
{{ITERATION_HISTORY}}
</iteration_history>

<output_contract>
You MUST output a single JSON object conforming to this schema. No markdown, no commentary, no text before or after.

Schema:
{
  "status": "PASS" or "FAIL",
  "issues": [
    {
      "file": "path/to/file.ext",
      "line": 42,
      "severity": "high" | "medium" | "low",
      "category": "security" | "bug" | "performance" | "maintainability",
      "description": "Clear description referencing the actual code",
      "suggestion": "Concrete fix with code example when possible",
      "confidence": 85
    }
  ]
}

Field rules:
- status: "FAIL" if ANY high or medium severity issue exists. "PASS" otherwise.
- file: relative path from repo root. Must match a file in the diff.
- line: integer line number. Use 0 only for file-level issues.
- severity: "high" = bugs, security vulns, data loss. "medium" = perf, error handling. "low" = style, naming.
- category: exactly one of "security", "bug", "performance", "maintainability".
- description: specific, referencing the actual code. Not generic advice.
- suggestion: concrete fix. Not "consider fixing" — show what to change.
- confidence: integer 0-100. How certain this is a real issue, not a false positive. Required.
</output_contract>

<grounding_rules>
- Only report issues in the CHANGED code shown in the diff. Do not report pre-existing issues.
- Every finding must reference a specific file and line from the diff.
- Do not report issues that linters or type checkers would catch (formatting, unused imports).
- Do not re-report issues from the iteration_history that have already been fixed.
- Maximum 10 issues per review. Prioritize by severity, then confidence.
- If all previous issues are fixed and no new issues found, return {"status": "PASS", "issues": []}.
- Maximum 3 new issues per iteration to ensure convergence.
- When reviewing shell scripts, check: unquoted variables, missing error handling, unsafe temp files, local outside functions, shasum vs sha256sum portability, mktemp -t portability, CWD/path safety, cleanup ordering before early exits, timeout fail-open, boolean normalization.
- When reviewing documentation, verify: factual claims match code, examples are correct, counts match reality, no stale references.
- When reviewing CI/CD workflows (.github/workflows/*.yml, .gitlab-ci.yml):
  - Flag `paths` + `paths-ignore` on the same trigger (GitHub Actions ignores one silently).
  - Flag `${{ }}` expressions inside `run:` blocks — use `env:` intermediary to prevent expression injection.
  - Flag `curl | sh`, `curl | sudo sh`, or `wget | sh` patterns — supply chain risk. Pin to a commit SHA or use a versioned action.
  - Flag unpinned `pip install`, `npm install -g`, or `gem install` without version pins in CI steps.
  - Flag action `uses:` references without SHA pins (e.g., `actions/checkout@v4` instead of `actions/checkout@<sha>`).
  - Flag missing top-level `permissions: {}` — workflows should use least-privilege with job-level permissions.
  - Flag conditional skip logic (`grep -q` / `if [ -f ... ]`) that can be bypassed by non-functional references or empty files.
- Property testing gap: if changes touch parsers, validators, serializers, auth, or financial logic — flag as LOW if no property-based tests exist. Advisory only.
</grounding_rules>
EOF
fi

# Replace placeholders
sed -i.tmp "s/MAX_ITERATIONS_PLACEHOLDER/$MAX_ITERATIONS/" "$STATE_DIR/litmus-state.md"
sed -i.tmp "s/COMPLETION_PROMISE_PLACEHOLDER/$COMPLETION_PROMISE/" "$STATE_DIR/litmus-state.md"
sed -i.tmp "s/TIMESTAMP_PLACEHOLDER/$TIMESTAMP/" "$STATE_DIR/litmus-state.md"
rm -f "$STATE_DIR/litmus-state.md.tmp"

# Success message
echo "✅ Review loop initialized"
echo ""
echo "   State file: $STATE_DIR/litmus-state.md"
echo "   Max iterations: $MAX_ITERATIONS"
if [ "$COMPLETION_PROMISE" != "null" ]; then
    echo "   Completion promise: $COMPLETION_PROMISE"
fi
echo ""
echo "Next steps:"
echo "   1. Run: bash scripts/run-review-loop.sh"
echo "   2. Fix any issues found"
echo "   3. Loop continues automatically until PASS"
echo ""
