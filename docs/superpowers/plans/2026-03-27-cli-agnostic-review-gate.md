# CLI-Agnostic Review Gate Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the pre-commit review gate work with any CLI (codex, gemini, claude, aider) instead of hardcoding Codex, with auto-detection fallback and built-in agent review.

**Architecture:** A shared `resolve-cli.sh` adapter library resolves `BUSDRIVER_REVIEW_CLI` env var to the effective CLI binary. Both `run-review-loop.sh` (review execution) and `validation.sh` (prerequisite check) source this adapter. The gate script accepts markers from any CLI and from a new `SKIPPED-NONE` path.

**Tech Stack:** Bash (adapter + gate scripts), Node.js (doctor.js), Markdown (README, SKILL.md)

**Spec:** `docs/superpowers/specs/2026-03-27-cli-agnostic-review-gate-design.md`

---

## File Structure

| File | Responsibility | Change |
|------|---------------|--------|
| `skills/codex-reviewer/scripts/lib/resolve-cli.sh` | CLI resolution + execution adapter | **NEW** |
| `skills/codex-reviewer/scripts/lib/validation.sh` | Prerequisite validation | Replace `validate_codex_installed` |
| `skills/codex-reviewer/scripts/run-review-loop.sh` | Review loop orchestration | Use resolved CLI |
| `hooks/gate-scripts/pre-commit-gate.sh` | Pre-commit enforcement gate | Accept SKIPPED-NONE, rename messages |
| `scripts/doctor.js` | Health check diagnostics | Add review CLI section |
| `README.md` | User documentation | Update requirements section |
| `skills/codex-reviewer/SKILL.md` | Skill documentation | Add exit code 3 handler, update CLI refs |

---

### Task 1: Create `resolve-cli.sh` Adapter Library

**Files:**
- Create: `skills/codex-reviewer/scripts/lib/resolve-cli.sh`

- [ ] **Step 1: Create the adapter file with both functions**

```bash
#!/bin/bash
# Shared CLI resolution adapter for review gate
# Single source of truth — sourced by run-review-loop.sh and validation.sh
#
# Env var: BUSDRIVER_REVIEW_CLI
# Values: auto (default) | codex | gemini | claude | aider | builtin | none

resolve_review_cli() {
  local cli="${BUSDRIVER_REVIEW_CLI:-auto}"
  case "$cli" in
    auto)
      command -v codex &>/dev/null && echo "codex" && return
      command -v gemini &>/dev/null && echo "gemini" && return
      echo "builtin" ;;
    none)    echo "none" ;;
    builtin) echo "builtin" ;;
    *)
      command -v "$cli" &>/dev/null && echo "$cli" && return
      echo "missing:$cli" ;;
  esac
}

execute_review() {
  local cli="$1"
  local prompt="$2"
  local timeout="${3:-1200}"

  case "$cli" in
    codex)   timeout "$timeout" codex review "$prompt" 2>&1 ;;
    gemini)  echo "$prompt" | timeout "$timeout" gemini 2>&1 ;;
    claude)  echo "$prompt" | timeout "$timeout" claude -p --output-format text 2>&1 ;;
    aider)   echo "$prompt" | timeout "$timeout" aider --message - --no-auto-commits 2>&1 ;;
    builtin) echo "BUILTIN_FALLBACK"; return 3 ;;
    none)    echo '{"status":"PASS","issues":[]}'; return 0 ;;
    *)       echo "Unsupported CLI: $cli" >&2; return 1 ;;
  esac
}

get_cli_install_hint() {
  local cli="$1"
  case "$cli" in
    codex)  echo "npm install -g @openai/codex" ;;
    gemini) echo "See https://github.com/google-gemini/gemini-cli" ;;
    claude) echo "See https://docs.anthropic.com/en/docs/claude-code" ;;
    aider)  echo "pip install aider-chat" ;;
    *)      echo "Install '$cli' and ensure it is in your PATH" ;;
  esac
}
```

- [ ] **Step 2: Verify shellcheck-clean**

Run: `shellcheck skills/codex-reviewer/scripts/lib/resolve-cli.sh`
Expected: No warnings

- [ ] **Step 3: Commit**

```bash
git add skills/codex-reviewer/scripts/lib/resolve-cli.sh
git commit -m "feat: add resolve-cli.sh adapter for CLI-agnostic review gate"
```

---

### Task 2: Update `validation.sh` — Replace `validate_codex_installed`

**Files:**
- Modify: `skills/codex-reviewer/scripts/lib/validation.sh:22-37`

- [ ] **Step 1: Source resolve-cli.sh at the top of validation.sh**

Add after line 4 (`# Provides centralized error handling and validation`):

```bash
# Source CLI resolution adapter
VALIDATION_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=resolve-cli.sh
source "$VALIDATION_SCRIPT_DIR/resolve-cli.sh"
```

- [ ] **Step 2: Replace `validate_codex_installed` with `validate_review_cli`**

Replace the entire function (lines 22-37) with:

```bash
# Validate review CLI is available
validate_review_cli() {
  local resolved
  resolved=$(resolve_review_cli)

  if [[ "$resolved" == missing:* ]]; then
    local cli_name="${resolved#missing:}"
    local hint
    hint=$(get_cli_install_hint "$cli_name")
    echo "Error: review CLI '$cli_name' not found" >&2
    echo "" >&2
    echo "   BUSDRIVER_REVIEW_CLI is set to '$cli_name' but it is not installed." >&2
    echo "   Install: $hint" >&2
    echo "" >&2
    echo "   Or set BUSDRIVER_REVIEW_CLI=auto to auto-detect, or =builtin for agent review." >&2
    return 1
  fi

  echo "$resolved"
  return 0
}
```

- [ ] **Step 3: Verify shellcheck passes**

Run: `shellcheck skills/codex-reviewer/scripts/lib/validation.sh`
Expected: No new warnings

- [ ] **Step 4: Commit**

```bash
git add skills/codex-reviewer/scripts/lib/validation.sh
git commit -m "refactor: replace validate_codex_installed with validate_review_cli"
```

---

### Task 3: Update `run-review-loop.sh` — Use Resolved CLI

**Files:**
- Modify: `skills/codex-reviewer/scripts/run-review-loop.sh`

- [ ] **Step 1: Replace the codex-installed check (lines 26-41) with CLI resolution**

Replace the block starting with `# Fail-closed when codex CLI is not installed.` through `fi` (line 41) with:

```bash
# Source CLI resolution adapter
# shellcheck source=lib/resolve-cli.sh
source "$SCRIPT_DIR/lib/resolve-cli.sh"

# Resolve review CLI (fail-closed on missing binary)
RESOLVED_CLI=$(validate_review_cli 2>/dev/null) || {
  validate_review_cli >&2
  rm -f "$STATE_FILE" 2>/dev/null
  exit 1
}

# Handle 'none' mode — immediate pass with warning
if [ "$RESOLVED_CLI" = "none" ]; then
  echo "⚠️  BUSDRIVER_REVIEW_CLI=none — review gate disabled" >&2
  echo "   Commits will pass without code review." >&2
  echo "" >&2
  mkdir -p .claude
  echo "SKIPPED-NONE-$(date +%s)" > ".claude/codex-review-passed.local"
  printf '{"ts":"%s","event":"review-skipped-none","gate":"pre-commit"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> ".claude/bypass-log.jsonl" 2>/dev/null || true
  clear_iteration_history
  rm -f "$STATE_FILE" 2>/dev/null
  exit 0
fi

echo "   Review CLI: $RESOLVED_CLI"
```

- [ ] **Step 2: Replace the codex review execution block (lines 283-310)**

Replace the block starting with `# Run codex review` through `echo "✅ Review completed"` with:

```bash
# Run review via resolved CLI
echo "🔬 Running $RESOLVED_CLI review (loop attempt $ITERATION/$MAX_ITER)..."
echo ""

REVIEW_TIMEOUT="${CODEX_REVIEW_TIMEOUT:-1200}"
set +e
REVIEW_OUTPUT=$(execute_review "$RESOLVED_CLI" "$FINAL_PROMPT" "$REVIEW_TIMEOUT")
REVIEW_EXIT=$?
set -e

if [ "$REVIEW_EXIT" -eq 3 ]; then
  echo "$FINAL_PROMPT" > /tmp/busdriver-review-prompt.txt
  echo "ℹ️  No external review CLI available — using built-in agent review" >&2
  echo "   Prompt saved to /tmp/busdriver-review-prompt.txt" >&2
  echo "   The codex-reviewer skill will dispatch the code-reviewer agent." >&2
  clear_iteration_history
  rm -f "$STATE_FILE" 2>/dev/null
  exit 3
elif [ "$REVIEW_EXIT" -eq 124 ]; then
  echo "❌ Error: $RESOLVED_CLI review timed out after ${REVIEW_TIMEOUT}s" >&2
  echo "" >&2
  echo "   The review took too long. This usually means the diff is too complex." >&2
  echo "   Try splitting into smaller commits." >&2
  echo "" >&2
  bash "$SCRIPT_DIR/suggest-split.sh" >&2
  exit 124
elif [ "$REVIEW_EXIT" -ne 0 ]; then
  echo "❌ Error: $RESOLVED_CLI review failed (exit code $REVIEW_EXIT)" >&2
  echo "" >&2
  echo "   Output:" >&2
  echo "$REVIEW_OUTPUT" >&2
  exit 1
fi

echo "✅ Review completed"
```

- [ ] **Step 3: Update the debug output line**

Change `echo "   Saved to: /tmp/codex-raw-output.txt"` to:
```bash
echo "   Saved to: /tmp/codex-raw-output.txt (CLI: $RESOLVED_CLI)"
```

- [ ] **Step 4: Verify shellcheck passes**

Run: `shellcheck skills/codex-reviewer/scripts/run-review-loop.sh`
Expected: No new warnings (existing SC1091 source warnings are expected)

- [ ] **Step 5: Smoke test with BUSDRIVER_REVIEW_CLI=none**

```bash
git add README.md
bash skills/codex-reviewer/scripts/init-review-loop.sh
BUSDRIVER_REVIEW_CLI=none bash skills/codex-reviewer/scripts/run-review-loop.sh
cat .claude/codex-review-passed.local
```
Expected: Immediate exit 0, marker starts with `SKIPPED-NONE-`

- [ ] **Step 6: Commit**

```bash
git add skills/codex-reviewer/scripts/run-review-loop.sh
git commit -m "feat: use resolved CLI in review loop instead of hardcoded codex"
```

---

### Task 4: Update `pre-commit-gate.sh` — Accept SKIPPED-NONE, Rename Messaging

**Files:**
- Modify: `hooks/gate-scripts/pre-commit-gate.sh`

- [ ] **Step 1: Add SKIPPED-NONE acceptance in Gate 2 marker check**

In the Gate 2 section (around line 302), after the DEGRADED check block, add an `elif` for SKIPPED-NONE. Replace the existing if/else with:

```bash
    if echo "$MARKER_CONTENT" | grep -q "^DEGRADED"; then
        rm -f "$MARKER"
        echo '{"decision":"block","reason":"Code review ran in DEGRADED mode (no review CLI installed). No actual code review was performed. Install a review CLI or create .claude/skip-codex-review.local to bypass."}' >&2
    elif echo "$MARKER_CONTENT" | grep -q "^SKIPPED-NONE"; then
        # BUSDRIVER_REVIEW_CLI=none — user explicitly opted out of review.
        # Accept unconditionally. See design spec for risk analysis.
        exit 0
    else
```

- [ ] **Step 2: Rename "Codex review" to "Code review" in the final block message**

Change line 337 from `"Codex review required before committing."` to `"Code review required before committing."`

- [ ] **Step 3: Verify shellcheck passes**

Run: `shellcheck hooks/gate-scripts/pre-commit-gate.sh`
Expected: No new warnings

- [ ] **Step 4: Commit**

```bash
git add hooks/gate-scripts/pre-commit-gate.sh
git commit -m "feat: accept SKIPPED-NONE markers and rename Codex to Code review in gate"
```

---

### Task 5: Update `scripts/doctor.js` — Add Review CLI Status

**Files:**
- Modify: `scripts/doctor.js`

- [ ] **Step 1: Add review CLI check function**

Add before the `main()` function. Use `execFileSync` (not `execSync`) for safety:

```javascript
function checkReviewCli() {
  const { execFileSync } = require('child_process');
  const path = require('path');
  const configured = process.env.BUSDRIVER_REVIEW_CLI || 'auto';
  let resolved = 'unknown';
  let version = '';
  let status = 'ok';
  let message = '';

  try {
    const resolveScript = path.join(__dirname, '..', 'skills', 'codex-reviewer', 'scripts', 'lib', 'resolve-cli.sh');
    resolved = execFileSync('bash', ['-c', `source "${resolveScript}" && resolve_review_cli`], {
      encoding: 'utf8',
      env: { ...process.env },
      timeout: 5000,
    }).trim();
  } catch {
    resolved = 'error';
  }

  if (resolved === 'none') {
    status = 'warning';
    message = 'review gate disabled, commits pass without review';
  } else if (resolved === 'builtin') {
    message = 'commits will use built-in Claude review (less independent than external CLI)';
  } else if (resolved.startsWith('missing:')) {
    status = 'error';
    message = `CLI '${resolved.slice(8)}' not found — install it or set BUSDRIVER_REVIEW_CLI=auto`;
  } else if (resolved === 'error') {
    status = 'error';
    message = 'could not resolve review CLI';
  } else {
    try {
      version = execFileSync(resolved, ['--version'], {
        encoding: 'utf8',
        timeout: 5000,
      }).trim().split('\n')[0];
    } catch {
      version = 'unknown';
    }
    message = `commits will require ${resolved} review`;
  }

  return { configured, resolved, version, status, message };
}
```

- [ ] **Step 2: Add review CLI section to `printHuman` output**

At the end of `printHuman()`, before the closing `}`, add:

```javascript
  const cli = checkReviewCli();
  console.log('\nReview Gate:');
  console.log(`  BUSDRIVER_REVIEW_CLI: ${cli.configured}`);
  const versionStr = cli.version ? ` (${cli.version})` : '';
  console.log(`  Resolved CLI: ${cli.resolved}${versionStr}`);
  console.log(`  Status: ${statusLabel(cli.status)} - ${cli.message}`);
```

- [ ] **Step 3: Verify it runs**

Run: `node scripts/doctor.js`
Expected: Existing output plus "Review Gate:" section

- [ ] **Step 4: Commit**

```bash
git add scripts/doctor.js
git commit -m "feat: add review CLI status to doctor output"
```

---

### Task 6: Update `README.md` — Configurable CLI Documentation

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Replace the Requirements section**

Replace the entire "## Requirements" section with the configurable CLI table from the spec. See spec Section 6 for exact content. Key changes:
- Remove hardcoded Codex/Gemini table
- Add `BUSDRIVER_REVIEW_CLI` env var table with all 7 values
- Add "Without any external CLI" note about auto-fallback
- Move dispatch-cli info to a separate subsection

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: update README with configurable review CLI documentation"
```

---

### Task 7: Update `codex-reviewer/SKILL.md` — Exit Code 3 Handler

**Files:**
- Modify: `skills/codex-reviewer/SKILL.md`

- [ ] **Step 1: Add Review CLI Configuration section**

After the first `<EXTREMELY-IMPORTANT>` block, add the configurable CLI table from spec Section 7.

- [ ] **Step 2: Add Exit Code 3 handler section**

Before "## Key Principles", add the builtin fallback handler section from spec Section 8. This documents:
- Read `/tmp/busdriver-review-prompt.txt`
- Dispatch `code-reviewer` agent
- Parse for CRITICAL/HIGH
- Write marker on pass, report FAIL on issues

- [ ] **Step 3: Update hardcoded "codex CLI" references**

Replace user-facing "codex CLI" with "review CLI" where it refers to the configurable CLI (not the skill name).

- [ ] **Step 4: Commit**

```bash
git add skills/codex-reviewer/SKILL.md
git commit -m "docs: add configurable CLI and exit code 3 handler to codex-reviewer SKILL"
```

---

### Task 8: End-to-End Verification

- [ ] **Step 1: Test auto-detection**

```bash
BUSDRIVER_REVIEW_CLI=auto bash -c 'source skills/codex-reviewer/scripts/lib/resolve-cli.sh && resolve_review_cli'
```
Expected: `codex` or `gemini` or `builtin` depending on what's installed

- [ ] **Step 2: Test missing CLI**

```bash
BUSDRIVER_REVIEW_CLI=nonexistent bash -c 'source skills/codex-reviewer/scripts/lib/resolve-cli.sh && resolve_review_cli'
```
Expected: `missing:nonexistent`

- [ ] **Step 3: Test none mode end-to-end**

```bash
git add README.md
bash skills/codex-reviewer/scripts/init-review-loop.sh
BUSDRIVER_REVIEW_CLI=none bash skills/codex-reviewer/scripts/run-review-loop.sh
cat .claude/codex-review-passed.local
```
Expected: File starts with `SKIPPED-NONE-`

- [ ] **Step 4: Run doctor**

```bash
node scripts/doctor.js
```
Expected: Shows "Review Gate:" section

- [ ] **Step 5: Shellcheck all modified bash scripts**

```bash
shellcheck skills/codex-reviewer/scripts/lib/resolve-cli.sh \
  skills/codex-reviewer/scripts/lib/validation.sh \
  skills/codex-reviewer/scripts/run-review-loop.sh \
  hooks/gate-scripts/pre-commit-gate.sh
```
Expected: No errors

- [ ] **Step 6: Full review loop with default CLI**

```bash
git add -A
bash skills/codex-reviewer/scripts/init-review-loop.sh
bash skills/codex-reviewer/scripts/run-review-loop.sh
```
Expected: Review runs with auto-detected CLI. PASS marker written.

- [ ] **Step 7: Commit spec and plan documents**

```bash
git add docs/superpowers/
git commit -m "docs: add CLI-agnostic review gate spec and implementation plan"
```
