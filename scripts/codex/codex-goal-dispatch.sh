#!/usr/bin/env bash
# codex-goal-dispatch.sh — single codex exec call for the codex-goal-handover skill.
#
# Runs ONE Codex iteration with a fresh session (no resume). Enforces the
# CodexGoalIterationReport schema on the final response. Writes the result
# to the caller-supplied path and prints that path to stdout.
#
# Fresh-context-per-iter is intentional. Rationale:
#   - `codex exec resume` does not accept --sandbox or --output-schema, so
#     iter >= 2 would lose schema enforcement.
#   - Geoffrey Huntley's published Ralph Loop principle is fresh context per
#     iter; preserved context is documented as a failure-prone variant.
#   - Each call is therefore independent — the calling skill is responsible
#     for replaying the spec and any steering prompt on subsequent iters.
#
# Usage:
#   codex-goal-dispatch.sh --result-file PATH [--model M] [--effort E] -- "$PROMPT"
#
# Prompt is read from the trailing arg OR stdin if no arg is given after `--`.
#
# Writes:
#   $RESULT_FILE              (schema-enforced final response from Codex)
#   $RESULT_FILE.codex.log    (codex stderr/stdout for debug)
#   $RESULT_FILE.pre-head.txt (HEAD before this iter, for caller commit-detect)
# Prints to stdout:
#   $RESULT_FILE              (caller reads and parses)
#
# Exit codes:
#   0 — Codex returned a schema-valid response, dispatcher commit (if any) succeeded
#   1 — Codex exited non-zero
#   2 — Result file missing or schema-invalid
#   3 — Codex modified files outside files_changed (out-of-scope detection).
#       Override with BUSDRIVER_CODEX_ALLOW_UNCLAIMED=1 to suppress and return 0.
#   4 — Working tree was not clean at dispatcher entry.
#       Override with BUSDRIVER_CODEX_ALLOW_DIRTY_TREE=1 to proceed anyway.
#   5 — Staging failed for one or more declared files (partial commit avoided).
#   6 — Codex modified gitignored files (paranoid mode only).
#       Default is informative-only; enable with BUSDRIVER_CODEX_FAIL_ON_IGNORED=1.
#  64 — Bad usage / invalid arg value
#  66 — Required file (schema) not found
# 127 — Required CLI not installed

set -euo pipefail

RESULT_FILE=""
MODEL=""
EFFORT=""
PROMPT=""

# Explicit value check (NOT ${2:?...}) so missing-value errors exit with the
# documented bad-usage code 64 rather than Bash's parameter-expansion default (1).
require_value() {
  if [[ -z "${2:-}" ]]; then
    echo "[codex-goal-dispatch] $1 requires a value" >&2
    exit 64
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --result-file) require_value "$1" "${2:-}"; RESULT_FILE="$2"; shift 2 ;;
    --model)       require_value "$1" "${2:-}"; MODEL="$2";       shift 2 ;;
    --effort)      require_value "$1" "${2:-}"; EFFORT="$2";      shift 2 ;;
    --)            shift; PROMPT="$*"; break ;;
    -h|--help)     sed -n '2,/^$/p' "$0" >&2; exit 0 ;;
    *)             echo "[codex-goal-dispatch] unknown arg: $1 (prompt must be after --)" >&2; exit 64 ;;
  esac
done

[[ -z "$RESULT_FILE" ]] && { echo "[codex-goal-dispatch] specify --result-file" >&2; exit 64; }

# Allowlist MODEL and EFFORT to prevent TOML-string breakout via `-c key="value"`
# which could otherwise escalate to sandbox_mode=danger-full-access etc.
if [[ -n "$MODEL" && ! "$MODEL" =~ ^[A-Za-z0-9._/:-]+$ ]]; then
  echo "[codex-goal-dispatch] --model contains unsupported characters: $MODEL" >&2
  exit 64
fi
case "${EFFORT:-}" in
  ''|minimal|low|medium|high|xhigh) ;;
  *) echo "[codex-goal-dispatch] --effort must be one of: minimal|low|medium|high|xhigh (got: $EFFORT)" >&2; exit 64 ;;
esac

command -v codex >/dev/null 2>&1 || { echo "[codex-goal-dispatch] codex CLI not on PATH" >&2; exit 127; }
command -v jq    >/dev/null 2>&1 || { echo "[codex-goal-dispatch] jq required" >&2; exit 127; }

if [[ -z "$PROMPT" ]] && ! [[ -t 0 ]]; then
  PROMPT="$(cat)"
fi
[[ -z "$PROMPT" ]] && { echo "[codex-goal-dispatch] empty prompt" >&2; exit 64; }

mkdir -p "$(dirname "$RESULT_FILE")"
LOG_FILE="${RESULT_FILE}.codex.log"
PRE_HEAD_FILE="${RESULT_FILE}.pre-head.txt"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCHEMA="$SCRIPT_DIR/goal-result.schema.json"
[[ -f "$SCHEMA" ]] || { echo "[codex-goal-dispatch] schema not found at $SCHEMA" >&2; exit 66; }

git rev-parse HEAD 2>/dev/null > "$PRE_HEAD_FILE" || echo "no-git" > "$PRE_HEAD_FILE"

# Resolve repo root for path-safe git operations. All file/git operations
# downstream use this explicitly via `git -C` (commits) or path prefixing
# (filesystem checks) so the helper works regardless of caller's CWD.
# If we're not in a git repo, REPO_ROOT falls back to pwd — git operations
# below will be no-ops or fail predictably.
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)

# Clean-tree precondition. The dispatcher's commit logic stages codex's
# declared files using `git add -A`, which captures the FULL working-tree
# state of those paths — including any pre-existing user dirt that would
# get mixed into the iter commit. Refusing to start unless the tree is clean
# eliminates a class of correctness bugs (pre-existing changes silently
# committed under codex's commit message) and simplifies the post-commit
# out-of-scope detector. `--ignored` is NOT used here — gitignored files
# (e.g., .env) staying dirty is fine; the post-commit check surfaces them
# separately. `|| true` silences SC2312 (process substitution masks return).
#
# Escape hatch: BUSDRIVER_CODEX_ALLOW_DIRTY_TREE=1 for advanced callers that
# explicitly handle pre-existing dirt (e.g., scripted test fixtures).
DIRT=$(git -C "$REPO_ROOT" status --porcelain=v1 2>/dev/null || true)
if [[ -n "$DIRT" && "${BUSDRIVER_CODEX_ALLOW_DIRTY_TREE:-}" != "1" ]]; then
  echo "[codex-goal-dispatch] FAIL: working tree is not clean. The dispatcher needs a clean tree to scope iter commits to codex's declared files. Either commit/stash your changes first or set BUSDRIVER_CODEX_ALLOW_DIRTY_TREE=1." >&2
  echo "$DIRT" >&2
  exit 4
fi

# Snapshot pre-codex dirty state (paths + content hashes). Used after codex
# returns to detect codex's modifications, including modifications to files
# that were ALREADY dirty before codex ran. Tracking the content hash (not
# just presence) catches the edge case where codex modifies a pre-existing
# dirty file outside its declared scope — without hashing, presence-only
# tracking would suppress the change as "already dirty."
#
# Storage: TWO PARALLEL bash 3.2 arrays indexed by position. The earlier
# implementation used a tab-delimited "<hash>TAB<path>" string and
# `awk -F'\t' '$2==p'` lookups; a path containing a literal TAB (rare but
# POSIX-legal) collapsed $2 to only the substring before the second tab, so
# the lookup falsely missed the baseline entry. Any single-byte delimiter
# has the same hazard (NUL bytes also can't be held in a bash string),
# so parallel arrays — paths preserved verbatim per element, no
# flattening — are the only structurally-safe storage. For untracked
# files we hash the working-tree content; for modified tracked files we
# also hash working-tree content (NOT the index) since that's what the
# verifiers will see.
declare -a PRE_DIRTY_PATHS=()
declare -a PRE_DIRTY_HASH_VALUES=()
# Modified tracked files (working tree vs HEAD). -z + read -r -d '' for safe
# NUL-delimited parsing. `|| true` silences SC2312 (process substitution
# masks return code) — failure here just means an empty list, not fatal.
while IFS= read -r -d '' p; do
  [[ -z "$p" ]] && continue
  h=$(git -C "$REPO_ROOT" hash-object -- "$p" 2>/dev/null || echo "MISSING")
  PRE_DIRTY_PATHS+=("$p")
  PRE_DIRTY_HASH_VALUES+=("$h")
done < <(git -C "$REPO_ROOT" diff -z --name-only HEAD 2>/dev/null || true)
# Untracked files (not gitignored).
while IFS= read -r -d '' p; do
  [[ -z "$p" ]] && continue
  h=$(git -C "$REPO_ROOT" hash-object -- "$p" 2>/dev/null || echo "MISSING")
  PRE_DIRTY_PATHS+=("$p")
  PRE_DIRTY_HASH_VALUES+=("$h")
done < <(git -C "$REPO_ROOT" ls-files -z --others --exclude-standard 2>/dev/null || true)
# Staged but not committed (index vs HEAD) — pre-existing staged changes
# shouldn't be flagged as codex's work. Hash from the index, not working tree.
while IFS= read -r -d '' p; do
  [[ -z "$p" ]] && continue
  h=$(git -C "$REPO_ROOT" ls-files --stage -- "$p" 2>/dev/null | awk '{print $2}')
  [[ -z "$h" ]] && h="MISSING"
  PRE_DIRTY_PATHS+=("$p")
  PRE_DIRTY_HASH_VALUES+=("$h")
done < <(git -C "$REPO_ROOT" diff -z --cached --name-only HEAD 2>/dev/null || true)

# Helper: linear-search PRE_DIRTY_PATHS for an exact match of $1. Emits the
# matching index on stdout and returns 0 on found; returns 1 on miss
# (stdout silent). Bash 3.2 lacks associative arrays so we cannot do O(1)
# lookups; pre-dirty trees are tiny in practice (typically zero entries
# under the clean-tree precondition, a handful at most under
# BUSDRIVER_CODEX_ALLOW_DIRTY_TREE=1), so linear scan is fine.
_pre_dirty_idx_of() {
  local target="$1"
  local k
  if [[ "${#PRE_DIRTY_PATHS[@]}" -eq 0 ]]; then return 1; fi
  for k in "${!PRE_DIRTY_PATHS[@]}"; do
    if [[ "${PRE_DIRTY_PATHS[$k]}" == "$target" ]]; then
      echo "$k"
      return 0
    fi
  done
  return 1
}

# Build codex exec invocation. Fresh session every call (no resume).
# NOTE: `-c sandbox_workspace_write.allow_git_writes=true` is INTENTIONALLY
# omitted. Empirical evidence (2026-05-21, /Volumes/Work mount with
# com.apple.provenance xattrs on .git/) shows that flag is insufficient on
# protected macOS mounts — codex still fails with `Operation not permitted`
# creating .git/index.lock. Rather than fight the seatbelt+xattr+mount
# interaction, the dispatcher executes the commit itself AFTER codex returns,
# using codex's `intended_commit_message` + `files_changed`. Codex describes
# the commit; the dispatcher (running outside codex's sandbox) executes it.
# This makes the workflow robust on any mount/sandbox configuration.
CODEX_ARGS=(exec --sandbox workspace-write --output-schema "$SCHEMA" -o "$RESULT_FILE")
[[ -n "$MODEL" ]] && CODEX_ARGS+=(--model "$MODEL")
# Pass effort as a separate -c key=value (no embedded quotes) so even if EFFORT
# ever bypasses the allowlist it cannot expand into additional TOML keys.
[[ -n "$EFFORT" ]] && CODEX_ARGS+=(-c "model_reasoning_effort=$EFFORT")
CODEX_ARGS+=("$PROMPT")

if ! codex "${CODEX_ARGS[@]}" >"$LOG_FILE" 2>&1; then
  echo "[codex-goal-dispatch] codex exec failed; see $LOG_FILE" >&2
  exit 1
fi

if [[ ! -s "$RESULT_FILE" ]]; then
  echo "[codex-goal-dispatch] codex did not write a result file at $RESULT_FILE (see $LOG_FILE)" >&2
  exit 2
fi
# Strict type check (not null-only): defense in depth against future CLI regressions
# where --output-schema enforcement could be weakened or bypassed via -c overrides.
# `intended_commit_message` may be string OR null (null when no commit needed).
if ! jq -e '
  (.summary | type == "string") and
  (.self_assessed_status as $s | $s == "complete" or $s == "in_progress" or $s == "blocked") and
  (.files_changed | type == "array") and
  ((.intended_commit_message | type == "string") or .intended_commit_message == null)
' "$RESULT_FILE" >/dev/null 2>&1; then
  echo "[codex-goal-dispatch] result JSON failed type check. See $RESULT_FILE" >&2
  exit 2
fi

# Execute the commit on codex's behalf — codex's sandbox may not have .git/
# write access (protected mounts, etc.). The dispatcher stages files declared
# in `files_changed` and commits with `intended_commit_message`, then injects
# `committed` + `commit_sha` into the result file for caller compatibility.
INTENDED_MSG=$(jq -r '.intended_commit_message // ""' "$RESULT_FILE")
COMMITTED=false
COMMIT_SHA=""

if [[ -n "$INTENDED_MSG" ]]; then
  # Build list of files to stage. Restrict to files codex declared in
  # files_changed — narrows the blast radius if codex incidentally modified
  # files outside its scope (the calling skill's scope-check at Step 7 will
  # also catch this; this is defense in depth).
  declare -a STAGE_FILES=()
  # Per-element iteration (NOT delimiter-based read). NUL-as-delimiter
  # collides with NUL-as-content: a schema-valid value like
  # "safe.txt\u0000bad.txt" would be re-split into two shell records,
  # smuggling an extra path past the declared files_changed contract.
  # Iterating by array index keeps each element a single shell value
  # regardless of its internal byte content. Per-element decoding is also
  # the ONLY layer where we can reject NUL-containing paths — once a
  # path transits bash's `$(...)` command substitution the NUL byte is
  # silently stripped, potentially stitching the pre-NUL and post-NUL
  # halves into a third never-declared path (e.g. "a\u0000b" →
  # bash sees "ab"). We detect NUL via `jq -c` on each element (which
  # encodes NUL as the literal 6-char `\u0000` escape in the JSON
  # output) and reject pre-decode.
  FILES_COUNT=$(jq -r '(.files_changed // []) | length' "$RESULT_FILE" 2>/dev/null || echo 0)
  i=0
  while [[ $i -lt $FILES_COUNT ]]; do
    # JSON-encoded form: NUL surfaces as literal `\u0000` (6 ASCII
    # chars) which a bash glob can match before bash ever sees the decoded
    # value. Single-quote the pattern so the backslash is literal.
    f_json=$(jq -c ".files_changed[$i] // null" "$RESULT_FILE" 2>/dev/null || echo "null")
    case "$f_json" in
      *'\u0000'*)
        echo "[codex-goal-dispatch] WARN: skipping files_changed[$i] — contains NUL byte (bash would silently strip it, potentially smuggling a third path): $f_json" >&2
        i=$((i+1)); continue ;;
    esac
    f=$(jq -r ".files_changed[$i] // empty" "$RESULT_FILE" 2>/dev/null || true)
    i=$((i+1))
    [[ -z "$f" ]] && continue
    # Reject paths containing control chars (TAB or NEWLINE). The parallel-
    # array PRE_DIRTY storage handles them correctly now, but downstream git
    # output (`git diff -z`, `git status -z`) and the surrounding shell
    # ecosystem still misbehave on paths with embedded control chars.
    # Legitimate codex workspace paths essentially never contain them, so
    # rejecting here is a cheap safety net. NUL is implicit — bash variables
    # can't hold NUL, so a NUL-containing path is already truncated by the
    # time we see it (the `\u0000` JSON-encoded check above catches it).
    case "$f" in
      *$'\t'*|*$'\n'*) echo "[codex-goal-dispatch] WARN: skipping path with control char (TAB/NEWLINE): $f" >&2; continue ;;
    esac
    # Skip absolute paths and parent-dir traversal — codex spec is relative paths only
    [[ "$f" = /* ]] && { echo "[codex-goal-dispatch] WARN: skipping absolute path $f" >&2; continue; }
    [[ "$f" = *..* ]] && { echo "[codex-goal-dispatch] WARN: skipping path with .. : $f" >&2; continue; }
    # Skip pathspec-magic prefixes — codex must declare ordinary file paths, not
    # globs or git pathspec sugar. `--literal-pathspecs` below disables magic at
    # the git layer, but rejecting these early surfaces the violation in the log.
    [[ "$f" = :* ]] && { echo "[codex-goal-dispatch] WARN: skipping pathspec-magic path $f" >&2; continue; }
    # Reject paths that match shell glob metacharacters before any expansion —
    # the literal value `.`, `*`, `**`, `[abc]`, etc. would otherwise be
    # treated as ordinary filenames here but become dangerously broad if a
    # future caller drops the --literal-pathspecs flag.
    case "$f" in
      .|..|*\**|*\?*|*\[*) echo "[codex-goal-dispatch] WARN: skipping glob-like path $f" >&2; continue ;;
    esac
    STAGE_FILES+=("$f")
  done

  # Reject directory paths in a second pass. Directories pass all the
  # filename-shape filters above but git treats them recursively even with
  # --literal-pathspecs (matches all files under the directory). codex must
  # name individual files, never directories.
  #
  # Two checks needed:
  #  (a) filesystem `-d` catches directories that exist on disk
  #  (b) git ls-tree HEAD catches paths that were tracked directories but
  #      may have been deleted on disk (codex might declare "scripts/codex"
  #      after deleting it, and (a) alone would miss this — `git add -A`
  #      would still treat the path as a directory and sweep all deletions)
  #  (c) git ls-files <path>/ catches paths that are tracked directories in
  #      the index (covers untracked content under tracked dirs too)
  declare -a FILTERED_STAGE_FILES=()
  # Guard the filter loop: under bash 3.2 + `set -u`, expanding "${arr[@]}" of
  # an empty array crashes with 'unbound variable'. STAGE_FILES is empty when
  # codex returns files_changed:[] (schema-valid) or when every declared path
  # failed the upstream filename-shape filter.
  if [[ "${#STAGE_FILES[@]}" -gt 0 ]]; then
    for f in "${STAGE_FILES[@]}"; do
      if [[ -d "$REPO_ROOT/$f" ]]; then
        echo "[codex-goal-dispatch] WARN: skipping directory path $f (exists as directory on disk)" >&2
        continue
      fi
      # Check git's view: was $f a directory in HEAD, or does anything under
      # $f/ exist in the index? Either case = directory pathspec → reject.
      tree_kind=$(git -C "$REPO_ROOT" ls-tree HEAD -- "$f" 2>/dev/null | awk '{print $2; exit}' || true)
      if [[ "$tree_kind" == "tree" ]]; then
        echo "[codex-goal-dispatch] WARN: skipping path $f (HEAD tracks it as a directory)" >&2
        continue
      fi
      # Trailing slash query: `git ls-files -- foo/` matches files under foo/.
      # If non-empty, foo is a directory in the index. `|| true` silences SC2312.
      under_index=$(git -C "$REPO_ROOT" ls-files -- "$f/" 2>/dev/null | head -1 || true)
      if [[ -n "$under_index" ]]; then
        echo "[codex-goal-dispatch] WARN: skipping path $f (index has files under $f/)" >&2
        continue
      fi
      FILTERED_STAGE_FILES+=("$f")
    done
  fi
  # Same crash hazard on the rebind: empty-array expansion under set -u in
  # bash 3.2 dies. Branch on length and reset explicitly.
  if [[ "${#FILTERED_STAGE_FILES[@]}" -gt 0 ]]; then
    STAGE_FILES=("${FILTERED_STAGE_FILES[@]}")
  else
    STAGE_FILES=()
  fi

  # Defense in depth (only meaningful when BUSDRIVER_CODEX_ALLOW_DIRTY_TREE=1
  # bypassed the clean-tree precondition): reject paths that were already
  # dirty pre-codex. Staging them with `git add -A` would mix user's prior
  # changes with codex's into the iter commit. Detection alone isn't enough
  # — we must refuse to commit them.
  declare -a FILTERED_STAGE_FILES_2=()
  # Guard for empty STAGE_FILES (bash 3.2 + set -u empty-array crash hazard).
  if [[ "${#STAGE_FILES[@]}" -gt 0 ]]; then
    for f in "${STAGE_FILES[@]}"; do
      # Path-exact membership via the parallel-array helper. The earlier
      # `awk -F'\t' '$2==p'` lookup on a tab-delimited "<hash>TAB<path>"
      # baseline was wrong for paths containing a TAB (POSIX-legal, rare):
      # awk's $2 truncated at the second tab, missing the entry and silently
      # failing to skip pre-existing dirt. With parallel arrays the path is
      # preserved verbatim per element and the comparison is exact
      # regardless of internal bytes.
      if _pre_dirty_idx_of "$f" >/dev/null; then
        echo "[codex-goal-dispatch] WARN: skipping path '$f' — was already dirty before codex ran; staging would commit pre-existing changes (unset BUSDRIVER_CODEX_ALLOW_DIRTY_TREE to enforce the clean-tree precondition on the next run)" >&2
        continue
      fi
      FILTERED_STAGE_FILES_2+=("$f")
    done
  fi
  if [[ "${#FILTERED_STAGE_FILES_2[@]}" -gt 0 ]]; then
    STAGE_FILES=("${FILTERED_STAGE_FILES_2[@]}")
  else
    STAGE_FILES=()
  fi

  if [[ "${#STAGE_FILES[@]}" -gt 0 ]]; then
    # Stage declared files. `--literal-pathspecs` disables ALL pathspec magic
    # (globs, :(glob), :(top), etc.) so each element of STAGE_FILES is treated
    # as an exact file path. -A so deletions and renames work too. `--`
    # separates pathspecs from flags. `-C "$REPO_ROOT"` ensures paths resolve
    # against repo root regardless of caller's CWD.
    if ! git -C "$REPO_ROOT" --literal-pathspecs add -A -- "${STAGE_FILES[@]}" 2>>"$LOG_FILE"; then
      # Fail-closed on staging failure. A partial-stage scenario (one file
      # fails, others succeed) would produce a commit that doesn't match the
      # declared files_changed contract — the iter's intended_commit_message
      # would describe work the commit doesn't fully contain. Surface the
      # failure so the caller bails this iter rather than committing partial
      # work that downstream verifiers can't reproduce.
      echo "[codex-goal-dispatch] FAIL: git add failed for one or more declared files; see $LOG_FILE" >&2
      exit 5
    fi
    # Commit, passing the same pathspecs so the commit is scoped to exactly
    # the declared files. Without pathspecs, `git commit -m "$msg"` commits the
    # ENTIRE current index — any pre-existing staged changes from before this
    # dispatch invocation would get swept into the iteration commit, breaking
    # the iter-boundary contract. With pathspecs, git commits only the listed
    # paths' staged state.
    #
    # Use --no-verify to skip any local pre-commit hooks — the loop's
    # verifiers (tests, lint, etc.) are the authoritative quality gate; local
    # hooks would create false discrepancies between iters.
    if git -C "$REPO_ROOT" --literal-pathspecs commit --no-verify -m "$INTENDED_MSG" -- "${STAGE_FILES[@]}" >>"$LOG_FILE" 2>&1; then
      COMMIT_SHA=$(git -C "$REPO_ROOT" rev-parse --short HEAD)
      COMMITTED=true
    else
      # `git commit` exits non-zero for two unrelated reasons:
      #   1. Empty stage (codex's add was a no-op) — benign, not a failure
      #   2. Real failure (gpg.signingkey misconfig, core.hooksPath bypassing
      #      --no-verify, disk full, etc.) — MUST NOT silently swallow, or the
      #      index stays staged and the next iter's clean-tree precondition
      #      reports exit 4 with no breadcrumb back to the half-completed iter
      # Distinguish via the post-attempt cached diff: any remaining staged
      # changes for our paths mean the commit really failed. Reset to leave a
      # clean tree for the next iter and exit 5.
      if ! git -C "$REPO_ROOT" diff --cached --quiet -- "${STAGE_FILES[@]}" 2>/dev/null; then
        echo "[codex-goal-dispatch] FAIL: git commit failed but staged changes remain; resetting index so the next iter's preconditions report cleanly; see $LOG_FILE" >&2
        git -C "$REPO_ROOT" reset -- "${STAGE_FILES[@]}" >>"$LOG_FILE" 2>&1 || true
        exit 5
      fi
      echo "[codex-goal-dispatch] git commit produced no commit (empty stage — codex's edits were no-ops); see $LOG_FILE" >&2
    fi
  fi
else
  echo "[codex-goal-dispatch] intended_commit_message is empty/null — no commit this iter" >&2
fi

# Post-commit out-of-scope detection. Even with our staging restricted to
# files_changed, codex may have modified files NOT in its declared list.
# Those modifications stay uncommitted in the working tree after our commit
# (correctly — we only staged what codex declared). The caller's downstream
# scope check (`git diff PRE_HEAD..HEAD`) ONLY sees committed paths, so it
# misses uncommitted out-of-scope modifications entirely. The verifiers run
# against the dirty working tree though, which can silently change their
# outcomes. Surface this gap so the caller's logic can detect + decide.
#
# Method: collect all currently-dirty paths (modified, untracked, staged).
# For each, compute its current content hash. Look up the path in the
# parallel PRE_DIRTY_PATHS / PRE_DIRTY_HASH_VALUES arrays (via
# _pre_dirty_idx_of). If found, compare hashes — a mismatch means codex
# modified an undeclared pre-existing-dirty file. If not found, the file
# is new since the pre-codex snapshot — also unclaimed. Then subtract
# STAGE_FILES (already committed by us) to leave only out-of-scope dirt.
#
# Hash comparison (vs presence-only) closes the security gap where codex
# modifies a pre-existing dirty file outside its scope — the path is in
# PRE_DIRTY, but the hash changed. Without hashing, presence-only matching
# would suppress the change as "already dirty" and miss the violation.
#
# bash 3.2 compatible: parallel arrays + linear search (no associative
# arrays, no mapfile). `|| true` on every command in process substitution
# silences SC2312.

# Build claimed-paths string (newline-separated, for grep -F lookups).
CLAIMED_NL=""
for p in "${STAGE_FILES[@]:-}"; do
  [[ -n "$p" ]] && CLAIMED_NL+="${p}"$'\n'
done

# Collect all currently-dirty paths into a deduplicated newline-separated list.
POST_DIRTY_PATHS=""
while IFS= read -r -d '' p; do
  [[ -n "$p" ]] && POST_DIRTY_PATHS+="${p}"$'\n'
done < <(git -C "$REPO_ROOT" diff -z --name-only HEAD 2>/dev/null || true)
while IFS= read -r -d '' p; do
  [[ -n "$p" ]] && POST_DIRTY_PATHS+="${p}"$'\n'
done < <(git -C "$REPO_ROOT" ls-files -z --others --exclude-standard 2>/dev/null || true)
while IFS= read -r -d '' p; do
  [[ -n "$p" ]] && POST_DIRTY_PATHS+="${p}"$'\n'
done < <(git -C "$REPO_ROOT" diff -z --cached --name-only HEAD 2>/dev/null || true)
# Deduplicate (a path could appear in multiple categories — e.g., both
# modified and staged with different changes). `|| true` silences SC2312.
POST_DIRTY_PATHS=$(printf '%s' "$POST_DIRTY_PATHS" | awk 'NF && !seen[$0]++' || true)

# Compute UNCLAIMED via content-hash comparison + claimed-file subtraction.
UNCLAIMED_LIST=""
while IFS= read -r p; do
  [[ -z "$p" ]] && continue
  # Skip claimed-and-committed paths.
  if printf '%s' "$CLAIMED_NL" | grep -qFx -- "$p"; then continue; fi
  # Compute current hash. For deleted files, hash-object fails → mark MISSING.
  current_hash=$(git -C "$REPO_ROOT" hash-object -- "$p" 2>/dev/null || echo "MISSING")
  # Find pre-baseline hash for this path. Take the FIRST match (covers index
  # and worktree variants of the same path; either presence in pre-baseline
  # means the file was already dirty in some form).
  # Path-exact lookup via the parallel-array helper. The earlier
  # `awk -F'\t' '$2==path'` truncated TAB-containing paths at the second
  # tab and false-flagged unchanged pre-existing dirt as unclaimed. With
  # parallel arrays the path is preserved verbatim and the hash comparison
  # uses the matching index directly.
  if pre_idx=$(_pre_dirty_idx_of "$p"); then
    # Path was dirty pre-codex. Compare hashes to detect further modification.
    pre_hash="${PRE_DIRTY_HASH_VALUES[$pre_idx]}"
    if [[ "$pre_hash" != "$current_hash" ]]; then
      # Content changed between pre and post → codex modified it.
      UNCLAIMED_LIST+="${p}"$'\n'
    fi
  else
    # Path wasn't dirty pre-codex → codex created/modified it.
    UNCLAIMED_LIST+="${p}"$'\n'
  fi
done <<< "$POST_DIRTY_PATHS"

# Convert to array for downstream use (bash 3 compatible: newline-delimited
# read into array).
UNCLAIMED_CHANGES=()
while IFS= read -r p; do
  [[ -n "$p" ]] && UNCLAIMED_CHANGES+=("$p")
done <<< "$UNCLAIMED_LIST"

if [[ "${#UNCLAIMED_CHANGES[@]}" -gt 0 ]]; then
  echo "[codex-goal-dispatch] WARN: codex modified files NOT in files_changed (still dirty after commit, will be invisible to caller's PRE_HEAD..HEAD scope check):" >&2
  printf '  %s\n' "${UNCLAIMED_CHANGES[@]}" >&2
fi

# Gitignored-file modification detection. The standard `git status --porcelain`
# call above excludes gitignored files via --exclude-standard semantics, so a
# steered codex run that writes to `.env`, local config, gitignored build
# artifacts, or other excluded paths would never appear in unclaimed_changes.
# Verifiers running against the worktree still see those modifications though.
# Use `git status --ignored --porcelain=v1 -z` to surface gitignored entries.
# Information-only (not fail-closed): legitimate verifier-input files may be
# gitignored. Logged + injected into result for caller awareness.
IGNORED_CHANGES=()
while IFS= read -r -d '' rec; do
  [[ -z "$rec" ]] && continue
  # Porcelain v1 status code for ignored: "!!". 3-char prefix: "!! "
  prefix="${rec:0:3}"
  if [[ "$prefix" == "!! " ]]; then
    p="${rec:3}"
    [[ -n "$p" ]] && IGNORED_CHANGES+=("$p")
  fi
done < <(git -C "$REPO_ROOT" status --ignored --porcelain=v1 -z 2>/dev/null || true)

if [[ "${#IGNORED_CHANGES[@]}" -gt 0 ]]; then
  echo "[codex-goal-dispatch] NOTE: gitignored files present (codex may have written to them; not committed; verifiers may see them):" >&2
  printf '  %s\n' "${IGNORED_CHANGES[@]}" >&2
fi

# Paranoid-mode fail-closed on ignored modifications. Default is informative-
# only because gitignored writes are routine for build tools / .env updates /
# cache files. Override for security-sensitive contexts (e.g., when codex is
# editing code that interacts with secrets, or when local-config tampering
# is part of the threat model): BUSDRIVER_CODEX_FAIL_ON_IGNORED=1 makes any
# gitignored modification fatal.
if [[ "${#IGNORED_CHANGES[@]}" -gt 0 && "${BUSDRIVER_CODEX_FAIL_ON_IGNORED:-}" == "1" ]]; then
  echo "[codex-goal-dispatch] FAIL: ${#IGNORED_CHANGES[@]} gitignored file(s) modified by codex (BUSDRIVER_CODEX_FAIL_ON_IGNORED=1 paranoid mode active). See ignored_changes in $RESULT_FILE." >&2
  # Failure exits do NOT echo $RESULT_FILE on stdout — the caller passed
  # --result-file PATH and already knows it. Other failure exits (1, 2, 4, 5)
  # follow the same convention. stdout-on-fail can mask the non-zero exit
  # code from callers that capture stdout via $(...).
  exit 6
fi

# Inject committed + commit_sha + unclaimed_changes + ignored_changes into
# the result file for caller compatibility and threat-detection. Callers that
# previously read codex's self-reported `committed`/`commit_sha` now get the
# dispatcher's authoritative values; `unclaimed_changes` surfaces out-of-scope
# tracked edits the standard scope check would miss; `ignored_changes` surfaces
# gitignored modifications that no scope check sees but verifiers may observe.
TMP_RESULT=$(mktemp)
# Build JSON arrays (empty if none). Use `|| true` on jq pipes to silence
# SC2312 about subshell return masking.
UNCLAIMED_JSON='[]'
if [[ "${#UNCLAIMED_CHANGES[@]}" -gt 0 ]]; then
  UNCLAIMED_JSON=$(printf '%s\n' "${UNCLAIMED_CHANGES[@]}" | jq -R . | jq -s . 2>/dev/null || echo '[]')
fi
IGNORED_JSON='[]'
if [[ "${#IGNORED_CHANGES[@]}" -gt 0 ]]; then
  IGNORED_JSON=$(printf '%s\n' "${IGNORED_CHANGES[@]}" | jq -R . | jq -s . 2>/dev/null || echo '[]')
fi
if jq --argjson committed "$COMMITTED" --arg sha "$COMMIT_SHA" \
      --argjson unclaimed "$UNCLAIMED_JSON" --argjson ignored "$IGNORED_JSON" \
   '. + {committed: $committed, commit_sha: (if $sha == "" then null else $sha end), unclaimed_changes: $unclaimed, ignored_changes: $ignored}' \
   "$RESULT_FILE" > "$TMP_RESULT"; then
  mv "$TMP_RESULT" "$RESULT_FILE"
else
  rm -f "$TMP_RESULT"
  echo "[codex-goal-dispatch] WARN: failed to inject committed/commit_sha/unclaimed_changes/ignored_changes; result file unchanged" >&2
fi

# Fail-closed on unclaimed out-of-scope changes. Reasoning: the documented
# caller scope check (`git diff PRE_HEAD..HEAD`) only sees committed paths,
# so if the dispatcher returns success here, the caller might miss codex's
# out-of-scope modifications (which still affect verifiers running against
# the dirty worktree). Returning non-zero forces the caller to deal with it.
#
# Escape hatch: `BUSDRIVER_CODEX_ALLOW_UNCLAIMED=1` opts back into the
# permissive informative-only behavior for callers that explicitly handle
# `unclaimed_changes` from the result file themselves. Documented in
# skills/codex-goal-handover/SKILL.md.
if [[ "${#UNCLAIMED_CHANGES[@]}" -gt 0 && "${BUSDRIVER_CODEX_ALLOW_UNCLAIMED:-}" != "1" ]]; then
  echo "[codex-goal-dispatch] FAIL: ${#UNCLAIMED_CHANGES[@]} out-of-scope file(s) modified by codex. See unclaimed_changes in $RESULT_FILE. Override with BUSDRIVER_CODEX_ALLOW_UNCLAIMED=1 if intentional." >&2
  # Failure exits do NOT echo $RESULT_FILE on stdout — see exit 6 comment.
  exit 3
fi

echo "$RESULT_FILE"
