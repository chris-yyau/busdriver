#!/bin/bash -p
# #803: same clean-child scrub as run-review-loop.sh -- privileged mode stops THIS
# shell from honouring BASH_ENV/ENV and importing BASH_FUNC_*, but leaves those
# entries in the environment for any unprivileged child to re-process.
# #803: last-resort -p re-exec, matching the run-* sibling. The shebang above covers
# direct execution, but a caller that runs this as `bash <script>` bypasses it, and the
# clean-env rebuild below only fires when a BASH_FUNC_* entry is present -- so a
# BASH_ENV-only poisoning would already have executed its startup code in THIS shell
# (DEBUG trap, readonly pins, function definitions) before the `unset` below runs.
# `exec` is itself shadowable, so this closes the ordinary case, not a hostile parent
# -- the same accepted residual the run-* siblings document.
if [[ "$-" != *p* ]]; then
    exec "${BASH:-/bin/bash}" -p "$0" "$@"
fi
# BD803-CLEAN-ENV-BEGIN
# #803: privileged mode protects THIS shell only. It makes bash ignore BASH_ENV/ENV
# and refuse BASH_FUNC_* imports, but it leaves every one of those entries sitting in
# the ENVIRONMENT, so any unprivileged descendant re-imports them -- including a
# plain `#!/bin/bash` helper reached through a sourced library, which no amount of
# care in THIS file would cover. Measured: BASH_ENV pointing at a file containing
# `exit 0` made a child exit 0 without running its body, and a forged
# BASH_FUNC_python3%% was imported by an unprivileged grandchild.
# BASH_FUNC_* entries cannot be removed with `unset` -- their names are not valid
# identifiers and the environ entry survives (measured) -- so strip them by rebuilding
# the environment once, here. SHELLOPTS/BASHOPTS are readonly and cannot be unset;
# -p already ignores them.
unset BASH_ENV ENV
# Blank the dynamic-loader variables BEFORE anything below runs a binary. The
# `-u` list built further down only cleans the FINAL re-exec's child, but the
# enumerator (`env -0` / `perl`) and `printf` are themselves dynamically linked:
# on Linux a hostile LD_PRELOAD/LD_AUDIT executes inside THOSE processes first,
# and a preloaded enumerator can simply lie about the environment it reports.
# Assignment, not `unset`: `unset` is a shadowable builtin (see the note above),
# while assignment is grammar no exported function can intercept — and an EMPTY
# LD_PRELOAD/LD_AUDIT is inert to the loader, so blanking is as good as removing.
# Scope, stated honestly: this protects the binaries this block runs and every
# descendant. It CANNOT protect the interpreter already executing these lines --
# the loader acted before bash ran its first instruction, which no in-script step
# can undo. DYLD_* is not blanked here (it is a family, not a fixed name); it is
# still carried into the `-u` list below, and macOS ignores DYLD_* for the
# SIP-protected /usr/bin binaries this block invokes.
# Not locals: these arrive EXPORTED from the caller's environment, so assigning
# empty keeps them exported and inert for every child -- hence SC2034 per line.
# shellcheck disable=SC2034
LD_PRELOAD=
# shellcheck disable=SC2034
LD_AUDIT=
# shellcheck disable=SC2034
LD_LIBRARY_PATH=
# Same treatment for the Python loader variables, and for the same reason the LD_*
# trio needs the ASSIGNMENT form rather than the `-u` list below: the re-exec is
# conditional on that list being non-empty, so an environment carrying only
# PYTHONPATH would skip it entirely and hand every `python3 -c` here an attacker
# import path. That is not a theoretical descendant -- the backstop VERDICT
# VALIDATOR is one of those calls, so a forged `sitecustomize.py` runs before the
# code that decides whether a review passed. Measured: a hostile PYTHONPATH
# executed sitecustomize.py ahead of the `-c` body, and a hostile PYTHONUSERBASE
# got its usercustomize.py found, read and executed. Blanking is inert to Python
# for all three (measured), exactly as an empty LD_PRELOAD is inert to the loader.
# PYTHONSTARTUP is deliberately NOT here: measured, it applies only to interactive
# sessions and never to `-c`, so adding it would be hardening with no vector.
# Blanking PYTHONUSERBASE is NOT sufficient on its own: with it empty, site.py
# falls back to deriving the user site directory from $HOME, which this block does
# not strip -- so a hostile HOME still reaches usercustomize.py by a second route
# (measured: it executed). PYTHONNOUSERSITE closes that, because it disables user
# site-packages outright rather than relocating them, so no $HOME value can point
# at anything. It is the one entry here that must be EXPORTED and NON-EMPTY: the
# other three arrive exported already and are being emptied, while this one is
# usually absent and is a flag Python tests for presence, not value. It is
# deliberately absent from the `-u` strip list below -- this is the one Python
# variable that must SURVIVE into every descendant. Measured: ENABLE_USER_SITE
# becomes False, and ordinary stdlib use (json, sys -- all these call sites import)
# is unaffected.
# shellcheck disable=SC2034
PYTHONPATH=
# shellcheck disable=SC2034
PYTHONHOME=
# shellcheck disable=SC2034
PYTHONUSERBASE=
export PYTHONNOUSERSITE=1
# Enumerate NUL-delimited (`env -0`), never newline-delimited. `env` output is NOT one
# line per variable: a value holding an embedded newline followed by text shaped like
# `BASH_FUNC_x%%=...` renders as its own line, and the name parsed out of that PHANTOM
# names no real variable -- so `env -u` strips nothing, the carrier survives the exec,
# the child re-detects the same phantom, and the block re-execs forever. Measured: an
# unbounded exec loop, armed by one ordinary variable, by the very poisoned environment
# this block exists to strip. A NUL can appear in neither an environment name nor a
# value, so NUL-delimited entries are exact and that phantom cannot be constructed.
# The trailing sentinel is the exit-status channel `env -0` otherwise loses through the
# process substitution: `&&` emits it only when env succeeded, and it can only arrive
# LAST. A final entry that is not the sentinel therefore covers BOTH a failed
# enumeration AND a substitution that never opened (no /dev/fd, unwritable TMPDIR).
# Neither may be read as "nothing to strip" -- that skips the clean re-exec and hands
# every descendant the inherited entries -- so both refuse. The count bound stays as a
# backstop against a pathological environment; NUL parsing is already O(n).
_bd803_envclean=()
_bd803_last=
_bd803_count=0
# shellcheck disable=SC2312  # `env -0`'s status is deliberately not read here: the
# sentinel below IS the status channel, and splitting the substitution would
# reintroduce a capture that cannot carry NUL bytes.
while IFS= read -r -d '' _bd803_e; do
  _bd803_last=$_bd803_e
  _bd803_count=$((_bd803_count + 1))
  if [[ ${_bd803_count} -gt 4096 ]]; then
    printf '%s\n' "$0: environment listing too large — refusing to run unprivileged descendants (#803)" >&2
    exit 1
  fi
  # Dynamic-loader variables are stripped alongside the forged functions. Be exact
  # about what this does and does not buy: on Linux the loader honours LD_PRELOAD /
  # LD_AUDIT before bash executes a single instruction, so `-p` cannot protect THIS
  # process — that residual is unreachable from here, and a parent able to set them
  # is the parent, which could as easily have exec'd a different binary outright
  # (the same boundary the shadowable-`exec` note draws). What the strip does buy is
  # that the re-exec'd shell and EVERY descendant start loader-clean, which is the
  # same treatment resolve-cli.sh already gives each of its `env -i` children.
  case "$_bd803_e" in
    BASH_FUNC_*|LD_PRELOAD=*|LD_AUDIT=*|LD_LIBRARY_PATH=*|DYLD_*|PYTHONPATH=*|PYTHONHOME=*|PYTHONUSERBASE=*)
      _bd803_envclean+=(-u "${_bd803_e%%=*}") ;;
  esac
# `env -0` is GNU; BSD/older macOS `env` rejects it and exits non-zero having
# written nothing, which would refuse to start every hardened entry point on a
# platform this repo explicitly supports (bash 3.2 is the macOS default). perl is
# the fallback because it is already the portable stand-in `_portable_timeout`
# relies on, and %ENV is read straight from environ, so a BASH_FUNC_x%% key —
# not a valid shell identifier — is still visible to it. If BOTH are unavailable
# the sentinel never arrives and the entry point refuses, which is the correct
# direction: unknowable environment, no unprivileged descendants.
#
# The perl arm is itself environment-steerable, and it is reached with the hostile
# environment still in place: PERL5OPT/PERL5LIB load attacker code BEFORE the
# script runs, and a module that merely exits 0 produces an EMPTY enumeration that
# the outer `&&` still stamps with the sentinel — "nothing to strip", every
# BASH_FUNC_* inherited (measured: 0 bytes, rc 0). Closed twice over: `-T` makes
# perl ignore PERL5LIB/PERLLIB/PERL5OPT outright, the assignment prefixes blank
# them for belt and braces, and the count check after the loop refuses an
# enumeration that returned nothing at all — no real environment is empty, so a
# silent zero is a failure however it was produced.
done < <( { /usr/bin/env -0 2>/dev/null \
            || PERL5OPT='' PERL5LIB='' PERLLIB='' /usr/bin/perl -T -e 'print map { "$_=$ENV{$_}\0" } keys %ENV'; } \
          && /usr/bin/printf 'BD803-ENV-OK\0' )
# -lt 2, not -lt 1: the SENTINEL is itself one of the entries the loop counted, so
# an enumeration that returned nothing at all still arrives here with a count of 1.
# Any real environment carries at least PATH alongside it.
if [[ "$_bd803_last" != "BD803-ENV-OK" || "$_bd803_count" -lt 2 ]]; then
  printf '%s\n' "$0: cannot enumerate the environment — refusing to run unprivileged descendants (#803)" >&2
  exit 1
fi
if [[ ${#_bd803_envclean[@]} -gt 0 ]]; then
  # A FAILED exec must not fall through. Non-interactive bash normally exits when
  # exec cannot run the command, but that behaviour is switchable (`execfail`), and
  # relying on an implicit exit for a security boundary means relying on a shell
  # option to stay off. The realistic failure is E2BIG: every stripped name adds a
  # `-u NAME` argument to an environment that is already large, and past ARG_MAX
  # the exec fails — at which point falling through would run the whole script with
  # exactly the BASH_FUNC_* entries this block exists to remove.
  exec /usr/bin/env "${_bd803_envclean[@]}" "${BASH:-/bin/bash}" -p "$0" "$@"
  printf '%s\n' "$0: cannot re-exec with a rebuilt environment — refusing to run unprivileged descendants (#803)" >&2
  exit 1
fi
unset _bd803_envclean _bd803_e _bd803_last _bd803_count
# BD803-CLEAN-ENV-END
# Initialize litmus review loop state file
# Follows Ralph Loop pattern for robust state management

set -euo pipefail

STATE_DIR="${BUSDRIVER_STATE_DIR:-.claude}"
# Same normalization run-review-loop.sh and the pr-grind commit block apply — this
# script has to agree with them, not merely be safe on its own. Normalizing the lock
# path alone (in lib/review-lock.sh) would leave this script locking `.claude/…` while
# reading and REWRITING a different state file, which is worse than either doing it or
# not: the lock would guard the wrong thing. A leading hyphen is rejected because the
# path reaches dirname/mkdir/ln/mktemp as an OPTION otherwise.
case "$STATE_DIR" in ""|-*|/*|*..*|*[!a-zA-Z0-9._/-]*) STATE_DIR=".claude" ;; esac
export BUSDRIVER_STATE_DIR="$STATE_DIR"

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

# This script REWRITES litmus-state.md — with --force, unconditionally. That makes it a
# writer, so it takes the review lock like every other writer; a mutual-exclusion
# contract that some writers opt out of is not a contract. Without this, an operator
# running init directly could reset the state file out from under a review that owns
# the lock. Callers that already hold it (run-review-loop.sh, the pr-grind commit block)
# export their pid, and review_lock_acquire treats an inherited owner as ours rather
# than deadlocking against the parent.
# shellcheck source=lib/review-lock.sh
source "$SCRIPT_DIR/lib/review-lock.sh"
_INIT_LOCK_RC=0
review_lock_acquire || _INIT_LOCK_RC=$?
if [ "$_INIT_LOCK_RC" = "2" ]; then
    echo "❌ Cannot use the litmus state directory: $STATE_DIR" >&2
    echo "   The lock could not be created: $(review_lock_path)" >&2
    echo "   Inspect that path — a file or directory may already occupy it, a stale" >&2
    echo "   symlink may point at an unreadable target, or the directory may reject" >&2
    echo "   symlink creation." >&2
    exit 1
fi
if [ "$_INIT_LOCK_RC" != "0" ]; then
    echo "❌ A litmus review holds the review lock in $STATE_DIR" >&2
    echo "   Owner: pid $(review_lock_owner) ($(review_lock_owner_state))" >&2
    echo "   Lock:  $(review_lock_path)" >&2
    echo "" >&2
    echo "   Re-initializing now would reset the state file underneath it." >&2
    echo "   If the owner is running, wait. If it is NOT running, that review was" >&2
    echo "   killed and the lock is an orphan: rm -f $(review_lock_path)" >&2
    exit 1
fi
# Release on exit unless we inherited the lock — a child must never unlink its
# parent's, which is still held for the rest of the parent's run.
#
# Note the handoff this leaves for a STANDALONE caller: init releases, and whatever runs
# the review next must acquire again, so a third party could slip in between. That gap
# is inherent to invoking init and run as two separate commands — an interactive
# operator has always had it, and this script cannot close it alone.
#
# The contract for closing it, for any caller that wants init→review to be one
# transaction: acquire the lock yourself, call review_lock_export_owner, then invoke
# both scripts as children. They will inherit rather than re-acquire, and neither will
# release what it did not take.
if review_lock_minted_here; then
    # #803: compose the staging cleanup — see run-review-loop.sh for why the library
    # will not install its own EXIT trap once this script owns one.
    trap 'review_lock_release; declare -F _bd803_cleanup_review_lib_exec >/dev/null && _bd803_cleanup_review_lib_exec || true' EXIT
fi

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
        # _MODE_SHOWN, not the raw $EXISTING_MODE: the latter is defaulted to "commit"
        # for the guard's own comparison, and printing that default here would assert
        # "resume in commit mode" for a legacy file that will actually follow
        # $LITMUS_MODE — contradicting this message's own header two lines up.
        echo "       → resume it in its own mode ($_MODE_SHOWN), which keeps the counter:" >&2
        echo "         /bin/bash -p $SCRIPT_DIR/run-review-loop.sh" >&2
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
echo "   1. Run: /bin/bash -p scripts/run-review-loop.sh"
echo "   2. Fix any issues found"
echo "   3. Loop continues automatically until PASS"
echo ""
