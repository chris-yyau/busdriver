<!-- design-reviewed: PASS -->
# Codex-Reviewer Coverage Boost Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Increase codex-reviewer empirical coverage from 19% toward ~40-55% against paid review tools (CodeRabbit, Greptile, Cubic, Copilot) by adding shell-specific checklist prompts, strengthening docs-consistency, tuning ShellCheck config, fixing numeric validation gaps, and fixing fail-open SAST parsing.

**Architecture:** Five independent improvements to the existing review pipeline — each modifies a different layer. (1) Prompt checklist additions in `init-review-loop.sh` templates. (2) Docs-context strengthening in `docs-context.sh`. (3) ShellCheck configuration in `sast-runner.sh`. (4) Numeric validation for all env-var-to-head-n patterns. (5) Fix fail-open SAST JSON parsing in `sast-runner.sh`. All changes are additive — no refactoring of existing logic.

**Tech Stack:** Bash (shell scripts), Python 3 (merge-findings.py), ShellCheck

**Baseline data:** 263 paid-tool findings across 21 PRs in 3 repos (busdriver, seatbelt, ECC). Audit results at `/tmp/coverage-audit-results.json`, `/tmp/seatbelt-audit-results.json`, `/tmp/ecc-codex-findings.json`.

---

## File Structure

| File | Responsibility | Action |
|------|---------------|--------|
| `skills/codex-reviewer/scripts/init-review-loop.sh:109-117,175-181` | Review prompt templates (commit + PR modes) | Modify: add shell-specific + docs-accuracy checklist items |
| `skills/codex-reviewer/scripts/lib/docs-context.sh` | Docs context collection for prompt enrichment | Modify: strengthen claim extraction and cross-reference instructions |
| `skills/codex-reviewer/scripts/lib/sast-runner.sh:95-144` | ShellCheck runner configuration | Modify: add curated --enable rules |
| `skills/codex-reviewer/scripts/run-review-loop.sh:341-354` | Enrichment injection into final prompt | Modify: add numeric validation for `CODEX_MAX_ENRICHMENT_LINES` |
| `skills/codex-reviewer/SKILL.md` | Skill documentation | Modify: update env var documentation |
| `tests/test-prompt-checklist.sh` | Test: verify prompt templates contain expected checklist items | Create |
| `tests/test-shellcheck-config.sh` | Test: verify ShellCheck runs with expected flags | Create |
| `tests/test-docs-context.sh` | Test: verify strengthened docs-context output | Create |
| `tests/test-numeric-validation.sh` | Test: verify numeric guards on env vars | Create |
| `tests/test-sast-merge.sh` | Test: verify SAST merge logs failures | Create |

---

### Task 1: Shell-Specific Prompt Checklist

**Files:**
- Modify: `skills/codex-reviewer/scripts/init-review-loop.sh:109-117` (PR prompt)
- Modify: `skills/codex-reviewer/scripts/init-review-loop.sh:175-181` (commit prompt)
- Test: `tests/test-prompt-checklist.sh`

The audit showed the biggest coverage gaps are: shell portability, path/CWD assumptions, stale file cleanup ordering, boolean normalization, fail-open timeout behavior, and docs-code mismatches. Adding explicit checklist items to the prompt directly addresses these.

- [ ] **Step 1: Write the test**

```bash
# tests/test-prompt-checklist.sh
#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
INIT_SCRIPT="$SCRIPT_DIR/skills/codex-reviewer/scripts/init-review-loop.sh"

passed=0
failed=0
fail() { echo "FAIL: $1"; failed=$((failed + 1)); }
ok()   { echo "OK:   $1"; passed=$((passed + 1)); }

# Split the file at the 'else' between PR and commit heredocs
# PR prompt is in the first cat block, commit prompt is in the second
CONTENT=$(cat "$INIT_SCRIPT")
PR_PROMPT=$(sed -n '/^if \[ "\$REVIEW_MODE" = "pr" \]/,/^else$/p' "$INIT_SCRIPT")
COMMIT_PROMPT=$(sed -n '/^else$/,/^fi$/p' "$INIT_SCRIPT")

# Shell-specific checks must be in BOTH commit and PR prompts
CHECKS=(
  "local.*outside.*function"
  "CWD.*REPO_DIR|absolute.*path|relative.*path"
  "shasum.*sha256sum|portability"
  "stale.*cleanup|cleanup.*ordering"
  "fail-open.*timeout|timeout.*fail"
  "boolean.*normalization|true.*false.*yes.*no"
  "factual.*claim|claim.*code"
  "count.*match|number.*match"
  "example.*match|stale.*example"
)

for check in "${CHECKS[@]}"; do
  for section in "PR" "COMMIT"; do
    if [ "$section" = "PR" ]; then
      text="$PR_PROMPT"
    else
      text="$COMMIT_PROMPT"
    fi
    if echo "$text" | grep -qiE "$check"; then
      ok "$section prompt contains: $check"
    else
      fail "$section prompt missing: $check"
    fi
  done
done

echo ""
echo "Results: $passed passed, $failed failed"
[ "$failed" -eq 0 ] && exit 0 || exit 1
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-prompt-checklist.sh`
Expected: FAIL — none of the new checklist items exist yet

- [ ] **Step 3: Add shell-specific checklist to both prompt templates**

In `init-review-loop.sh`, replace the "Check for:" section in BOTH the PR prompt (lines ~109-117) and the commit prompt (lines ~175-181) with this expanded version:

```
Check for:
- Security: dangerous functions (eval, exec), SQL injection, XSS, command injection, path traversal, SSRF
- Bugs: null/undefined errors, race conditions, off-by-one errors, infinite loops
- Performance: N+1 queries, unnecessary re-renders, memory leaks, blocking operations
- Maintainability: code duplication, unclear naming, missing error handling
- Shell portability: flag every use of `local` and verify it is inside a function, not at top-level. Check `shasum` vs `sha256sum` portability. Check `\b` in grep (not portable — use `-w` instead). Check `mktemp -t` (macOS-only — use `mktemp "${TMPDIR:-/tmp}/prefix-XXXXXX"`)
- Path/CWD safety: for every file write operation, verify the path uses `$REPO_DIR` or an absolute path, not a bare relative path like `.claude/...`. Scripts invoked from subdirectories will write to the wrong location with relative paths
- Stale file cleanup ordering: if a script has an early-exit path (e.g., config-disabled check), verify that stale result/temp file cleanup runs BEFORE the early exit, not after
- Timeout and fail-open: if a timeout or error causes an early exit, verify the exit path does not silently skip scanning (fail-open). Timeouts should emit degraded warnings, not silent passes
- Boolean normalization: if code checks `= "true"` or `= "false"`, verify it handles variant forms (True/TRUE/yes/on/1 and False/FALSE/no/off/0) or documents that only exact strings are accepted
- Doc/code accuracy: for every factual claim in .md files (counts, function names, behavior descriptions, examples), verify the claim matches the actual code. Flag stale counts (e.g., "16 skills" when the list has 18), wrong function signatures in examples, and example output that doesn't match actual output format
- Cross-commit issues: inconsistent changes across files, partial refactors, broken dependencies
- Property testing gap: if changes touch parsers, validators, serializers, auth, or financial logic — flag as LOW severity if no property-based tests exist (Hypothesis, fast-check, testing/quick). Advisory only, not blocking.
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test-prompt-checklist.sh`
Expected: PASS — all checklist items now present

- [ ] **Step 5: Commit**

```bash
git add tests/test-prompt-checklist.sh skills/codex-reviewer/scripts/init-review-loop.sh
git commit -m "feat: add shell-specific and docs-accuracy checklist to review prompts"
```

---

### Task 2: Strengthen Docs-Consistency Context

**Files:**
- Modify: `skills/codex-reviewer/scripts/lib/docs-context.sh:19-35`
- Test: `tests/test-docs-context.sh`

The audit showed the reviewer misses docs-code mismatches because the current docs-context collector only finds files that mention changed modules by name. It does not extract factual claims or cross-reference them. We add structured instructions to the context output that tell the LLM what to verify.

- [ ] **Step 1: Write the test**

```bash
# tests/test-docs-context.sh
#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

source "$SCRIPT_DIR/skills/codex-reviewer/scripts/lib/docs-context.sh"

passed=0
failed=0
fail() { echo "FAIL: $1"; failed=$((failed + 1)); }
ok()   { echo "OK:   $1"; passed=$((passed + 1)); }

# Create a temp repo with a README and a source file
TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT
cd "$TMPDIR_TEST"
git init -q
mkdir -p src

cat > README.md << 'EOF'
# My Project
Has 5 scanners. The processor module handles all input parsing.
EOF

cat > src/processor.sh << 'EOF'
process_data() { echo "done"; }
EOF

git add .
git -c commit.gpgsign=false -c user.name=test -c user.email=test@test.com commit -q -m "init"

# Modify processor
echo 'new_func() { echo "new"; }' >> src/processor.sh
git add src/processor.sh

# Collect docs context
OUTPUT=$(collect_docs_context "src/processor.sh" "$(git diff --cached)")

# Verify the output contains structured verification instructions
if echo "$OUTPUT" | grep -qi "verify.*claim\|cross-reference\|check.*accuracy"; then
  ok "Docs context includes verification instructions"
else
  fail "Docs context missing verification instructions"
fi

# Verify it found the README reference
if echo "$OUTPUT" | grep -q "README.md"; then
  ok "Found README.md referencing changed code"
else
  fail "Did not find README.md reference"
fi

echo ""
echo "Results: $passed passed, $failed failed"
[ "$failed" -eq 0 ] && exit 0 || exit 1
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-docs-context.sh`
Expected: FAIL on "verification instructions" check

- [ ] **Step 3: Add structured verification header to docs-context output**

In `docs-context.sh`, modify the `collect_docs_context` function. Do NOT emit the header unconditionally. Instead, use a flag to track whether any doc content was found, and emit the header/footer only when there is content.

Add a flag variable after `local search_terms=""` (line 69):
```bash
  local found_docs=0
```

Then, inside the inner loop where `_extract_doc_section` is called (the `while IFS= read -r doc_file` loop around line 100), BEFORE the first doc snippet is printed, emit the header on first match:
```bash
    if [ "$found_docs" -eq 0 ]; then
      echo "## Documentation Cross-Reference (verify accuracy of each claim)"
      echo "The following doc files reference the changed code. For each snippet:"
      echo "1. Identify every factual claim (counts, names, behavior descriptions)"
      echo "2. Cross-reference each claim against the actual code in the diff"
      echo "3. Flag any stale counts, wrong function names, or mismatched examples"
      echo ""
      found_docs=1
    fi
```

At the VERY END of `collect_docs_context` (before the function's closing `}`), append:
```bash
  if [ "$found_docs" -gt 0 ]; then
    echo ""
    echo "## End of Documentation Context"
  fi
```

This ensures the header/footer only appear when doc content exists, avoiding wasted prompt budget on empty reviews.

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test-docs-context.sh`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add tests/test-docs-context.sh skills/codex-reviewer/scripts/lib/docs-context.sh
git commit -m "feat: strengthen docs-context with structured verification instructions"
```

---

### Task 3: ShellCheck Configuration Tuning

**Files:**
- Modify: `skills/codex-reviewer/scripts/lib/sast-runner.sh:95-144` (ShellCheck runner)
- Test: `tests/test-shellcheck-config.sh`

The audit showed ShellCheck is integrated but may not be catching all the issues paid tools find. Key ShellCheck rules to explicitly enable: SC2086 (word splitting), SC2155 (local+assignment), SC2039 (bash-specific in sh), SC2164 (cd without ||), SC2166 (prefer [[ for tests).

- [ ] **Step 1: Write the test**

```bash
# tests/test-shellcheck-config.sh
#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SAST_RUNNER="$SCRIPT_DIR/skills/codex-reviewer/scripts/lib/sast-runner.sh"

passed=0
failed=0
fail() { echo "FAIL: $1"; failed=$((failed + 1)); }
ok()   { echo "OK:   $1"; passed=$((passed + 1)); }

# Verify the sast-runner passes --enable flag or sources a .shellcheckrc
if grep -qE '(--enable|shellcheckrc|CODEX_SHELLCHECK_ENABLE)' "$SAST_RUNNER"; then
  ok "ShellCheck runner has enable/config support"
else
  fail "ShellCheck runner missing enable/config support"
fi

# Verify severity mapping includes all ShellCheck levels
for level in error warning info style; do
  if grep -q "'$level'" "$SAST_RUNNER"; then
    ok "ShellCheck severity map includes: $level"
  else
    fail "ShellCheck severity map missing: $level"
  fi
done

echo ""
echo "Results: $passed passed, $failed failed"
[ "$failed" -eq 0 ] && exit 0 || exit 1
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-shellcheck-config.sh`
Expected: FAIL on "enable/config support" (the current runner uses default shellcheck flags)

- [ ] **Step 3: Add ShellCheck enable flags to sast-runner.sh**

In `_sast_run_shellcheck`, modify the shellcheck invocation (line ~110) to add an `--enable` flag:

```bash
# Configurable extra ShellCheck checks (env var override)
# Curated list targeting audit gap categories: portability, set-e interaction, quoting
local enable_rules="${CODEX_SHELLCHECK_ENABLE:-check-extra-masked-returns,check-set-e-suppressed,quote-safe-variables,require-double-brackets}"

file_output=$(_sast_timeout "$timeout_sec" shellcheck \
  --enable="$enable_rules" \
  -f json "$f" 2>/dev/null) || true
```

This enables a curated set of optional checks targeting the specific gap categories from the audit (portability, set-e interaction, quoting). Using `all` would flood the prompt with style-only findings. Users can override with `CODEX_SHELLCHECK_ENABLE=all` if desired.

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test-shellcheck-config.sh`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add tests/test-shellcheck-config.sh skills/codex-reviewer/scripts/lib/sast-runner.sh
git commit -m "feat: enable curated ShellCheck optional rules for coverage gaps"
```

---

### Task 4: Fix Numeric Validation Gap

**Files:**
- Modify: `skills/codex-reviewer/scripts/run-review-loop.sh:342` (MAX_ENRICHMENT_LINES)
- Modify: `skills/codex-reviewer/scripts/lib/docs-context.sh:22` (MAX_DOC_SNIPPETS)
- Modify: `skills/codex-reviewer/scripts/lib/smart-context.sh` (MAX_CONTEXT_LINES, MAX_FUNCTIONS)
- Test: `tests/test-numeric-validation.sh`

The audit found that `CODEX_MAX_ENRICHMENT_LINES`, `CODEX_MAX_DOC_SNIPPETS`, and `CODEX_MAX_CONTEXT_LINES` are passed to `head -n` without numeric validation, unlike `CODEX_SAST_TIMEOUT` which validates. This was flagged by Cubic on PR #5.

- [ ] **Step 1: Write the test**

```bash
# tests/test-numeric-validation.sh
#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

passed=0
failed=0
fail() { echo "FAIL: $1"; failed=$((failed + 1)); }
ok()   { echo "OK:   $1"; passed=$((passed + 1)); }

# Check that each env var has a case-based numeric guard in its file
check_guard() {
  local file="$1" var_name="$2"
  # Check for the [!0-9] pattern within 3 lines of the variable name
  if grep -A3 "$var_name" "$SCRIPT_DIR/$file" | grep -q '\[!0-9\]'; then
    ok "$var_name has numeric validation in $file"
  else
    fail "$var_name missing numeric validation in $file"
  fi
}

check_guard "skills/codex-reviewer/scripts/run-review-loop.sh" "CODEX_MAX_ENRICHMENT_LINES"
check_guard "skills/codex-reviewer/scripts/lib/docs-context.sh" "CODEX_MAX_DOC_SNIPPETS"
check_guard "skills/codex-reviewer/scripts/lib/smart-context.sh" "CODEX_MAX_CONTEXT_LINES"
check_guard "skills/codex-reviewer/scripts/lib/smart-context.sh" "CODEX_MAX_FUNCTIONS"

echo ""
echo "Results: $passed passed, $failed failed"
[ "$failed" -eq 0 ] && exit 0 || exit 1
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-numeric-validation.sh`
Expected: FAIL — no numeric guards exist yet

- [ ] **Step 3: Add numeric validation to CODEX_MAX_ENRICHMENT_LINES in run-review-loop.sh**

Replace line 342:
```bash
MAX_ENRICHMENT_LINES="${CODEX_MAX_ENRICHMENT_LINES:-100}"
```

With:
```bash
MAX_ENRICHMENT_LINES="${CODEX_MAX_ENRICHMENT_LINES:-100}"
case "$MAX_ENRICHMENT_LINES" in
  ''|*[!0-9]*) echo "⚠️  CODEX_MAX_ENRICHMENT_LINES='$MAX_ENRICHMENT_LINES' is not numeric, using default 100" >&2; MAX_ENRICHMENT_LINES=100 ;;
esac
```

- [ ] **Step 4: Add numeric validation to CODEX_MAX_DOC_SNIPPETS in docs-context.sh**

In `_find_referencing_docs`, after `local max_snippets="${CODEX_MAX_DOC_SNIPPETS:-5}"` (line 22), add:
```bash
case "$max_snippets" in
  ''|*[!0-9]*) max_snippets=5 ;;
esac
```

- [ ] **Step 5: Add numeric validation to CODEX_MAX_CONTEXT_LINES and CODEX_MAX_FUNCTIONS in smart-context.sh**

In `_find_callers`, after `local max_lines="${CODEX_MAX_CONTEXT_LINES:-50}"` (line 80), add:
```bash
case "$max_lines" in
  ''|*[!0-9]*) max_lines=50 ;;
esac
```

Same pattern in `_find_importers` (line 100) and the main `collect_smart_context` function for `CODEX_MAX_FUNCTIONS`.

- [ ] **Step 6: Run test to verify it passes**

Run: `bash tests/test-numeric-validation.sh`
Expected: PASS

- [ ] **Step 7: Commit**

```bash
git add tests/test-numeric-validation.sh \
      skills/codex-reviewer/scripts/run-review-loop.sh \
      skills/codex-reviewer/scripts/lib/docs-context.sh \
      skills/codex-reviewer/scripts/lib/smart-context.sh
git commit -m "fix: add numeric validation for all env-var-to-head-n patterns"
```

---

### Task 5: Fix SAST Merge Fail-Open

**Files:**
- Modify: `skills/codex-reviewer/scripts/lib/sast-runner.sh:40-49` (_sast_merge_json)
- Test: `tests/test-sast-merge.sh`

The audit found that `_sast_merge_json` in `sast-runner.sh` silently swallows JSON parse errors (bare `except: pass`), creating fail-open for crashed SAST tools. A tool crash produces zero findings instead of a failure signal.

- [ ] **Step 1: Write the test**

```bash
# tests/test-sast-merge.sh
#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

source "$SCRIPT_DIR/skills/codex-reviewer/scripts/lib/sast-runner.sh"

passed=0
failed=0
fail() { echo "FAIL: $1"; failed=$((failed + 1)); }
ok()   { echo "OK:   $1"; passed=$((passed + 1)); }

# Valid merge
result=$(_sast_merge_json '[{"a":1}]' '[{"b":2}]')
count=$(echo "$result" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))")
[ "$count" = "2" ] && ok "Valid merge: 2 items" || fail "Valid merge: expected 2, got $count"

# Malformed input should produce a specific stderr warning (not silent, not a crash)
stderr_output=$(_sast_merge_json 'NOT_JSON' '[]' 2>&1 1>/dev/null || true)
if echo "$stderr_output" | grep -q "WARNING: Failed to parse SAST output line"; then
  ok "Malformed input produces expected WARNING message"
else
  fail "Malformed input does not produce expected WARNING (got: $stderr_output)"
fi

# Verify the merge still produces valid JSON output (not a crash)
stdout_output=$(_sast_merge_json 'NOT_JSON' '[{"a":1}]' 2>/dev/null)
count=$(echo "$stdout_output" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))")
[ "$count" = "1" ] && ok "Merge recovers gracefully (1 valid item)" || fail "Merge did not recover (got $count items)"

echo ""
echo "Results: $passed passed, $failed failed"
[ "$failed" -eq 0 ] && exit 0 || exit 1
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test-sast-merge.sh`
Expected: FAIL on "Malformed input" — current code silently swallows

- [ ] **Step 3: Fix _sast_merge_json fail-open**

In `sast-runner.sh` line 47, change the except clause from:
```python
        except (json.JSONDecodeError, ValueError): pass
```
To:
```python
        except (json.JSONDecodeError, ValueError):
            print('WARNING: Failed to parse SAST output line (malformed JSON)', file=sys.stderr)
```

Note: do NOT include raw line content in the warning — TruffleHog output may contain credential material.

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test-sast-merge.sh`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add tests/test-sast-merge.sh skills/codex-reviewer/scripts/lib/sast-runner.sh
git commit -m "fix: log SAST parse failures instead of silent swallow"
```

---

### Task 6: Update SKILL.md Documentation

**Files:**
- Modify: `skills/codex-reviewer/SKILL.md`

- [ ] **Step 1: Update env var documentation**

Add the following to the Environment variables section in SKILL.md:

```markdown
- `CODEX_SHELLCHECK_ENABLE=check-extra-masked-returns,check-set-e-suppressed,quote-safe-variables,require-double-brackets` — ShellCheck optional checks to enable (default: curated list targeting audit gaps). Set to `all` to enable everything, or narrow to specific checks
- `CODEX_MAX_ENRICHMENT_LINES=100` — max lines of smart-context and docs-context injected into prompt (default: 100, validated numeric)
- `CODEX_MAX_DOC_SNIPPETS=5` — max doc file snippets to include (default: 5, validated numeric)
- `CODEX_MAX_CONTEXT_LINES=50` — max context lines per traced function (default: 50, validated numeric)
```

- [ ] **Step 2: Update the "Check for" summary to mention shell-specific checks**

In the "Review Output" or "Key Principles" section, add a note:

```markdown
The review prompt includes targeted checklists for shell scripting (portability, CWD safety, cleanup ordering, timeout fail-open, boolean normalization) and documentation accuracy (factual claims cross-referenced against code). These were added based on empirical coverage audit results showing 19% baseline coverage against paid tools.
```

- [ ] **Step 3: Commit**

```bash
git add skills/codex-reviewer/SKILL.md
git commit -m "docs: update SKILL.md with new env vars and coverage audit context"
```

---

### Task 7: Post-Change Coverage Measurement (Informational)

**Files:**
- No files created — this is a measurement task

This task re-runs the same 21-PR audit to measure before/after coverage. It is informational, not a gate — the improvements are valuable regardless of the measured uplift.

- [ ] **Step 1: Run codex-reviewer on all 21 PR diffs**

Re-run the same audit process from the coverage audit session. The PR diffs are cached at `/tmp/busdriver-pr{2,3,4,5}-diff.txt`, `/tmp/seatbelt-pr{8..14}-diff.txt`, and `/tmp/ecc-pr{892,857,747,725,723,715,701,700,660,645}-diff.txt`.

For each PR, dispatch the code-reviewer agent with the diff and collect JSON findings.

- [ ] **Step 2: Score against paid tool baseline**

Run the same scoring scripts (`/tmp/score-coverage.py`, `/tmp/score-seatbelt.py`) with the new codex-reviewer findings. Compare before/after:
- Overall coverage (was 19%)
- Per-severity coverage
- Per-tool coverage
- Per-repo coverage

- [ ] **Step 3: Document results**

Create a summary noting:
- Which tasks had the most impact
- Whether the 40-55% target range was approached
- Remaining gap categories for future work

Note: if diffs have expired from /tmp, re-fetch with `gh pr diff N --repo owner/repo`.
