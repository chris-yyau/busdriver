#!/usr/bin/env bash
# build-evidence-pack.sh — deterministic, read-only repo evidence pack for ultraOracle.
# ADR 0007 Phase 1/2. Builds a pack of raw repo artifacts to attach to an Oracle
# consult, and DECIDES the review-type label from what was actually included
# (settling check #2: a summary-only pack must NOT be upgraded to a repo review).
#
# Prints, on the LAST stdout line, exactly one label token:
#   ORACLE_REPO_ATTACHED_REVIEW  — at least one raw repo file is in the pack
#   ORACLE_SUMMARY_REVIEW        — only question/summary text, no raw repo files
# Any earlier stdout lines are human progress; the caller reads only the last line.
# Exits non-zero (no label) on misuse so the skill fails CLOSED rather than mislabel.
#
# Read-only: never writes inside the repo except under --out-dir. EVERY artifact that
# leaves in the pack — selected files AND the generated git context — passes the same
# secret-scan + byte-budget gate, with NO override path (ADR line 348). Conditional
# style mirrors the adjacent ultra-oracle.sh: [[ ]] for string/file tests; POSIX [ ]
# for integer -gt/-ge comparisons (base-10 strtol, no arithmetic eval).
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage: build-evidence-pack.sh --mode <repo|upstream-audit> --out-dir <dir>
         [--question-file <path>] [--file <path>]... [--byte-budget <n>]
         [--upstream <path>]...
  --mode repo            attach changed/selected repo files + git context
  --mode upstream-audit  as repo, plus inventory of each --upstream path
  --mode retrieval-loop  REJECTED — Phase 5, not implemented (fails closed)
EOF
}

MODE="" OUT_DIR="" QUESTION_FILE="" BYTE_BUDGET=2000000
FILES=() UPSTREAM=()
while [ $# -gt 0 ]; do
  case "$1" in
    --mode|--out-dir|--question-file|--byte-budget|--file|--upstream)
      [ $# -ge 2 ] || { echo "error: $1 needs a value" >&2; exit 2; } ;;
  esac
  case "$1" in
    --mode) MODE="$2"; shift 2;;
    --out-dir) OUT_DIR="$2"; shift 2;;
    --question-file) QUESTION_FILE="$2"; shift 2;;
    --byte-budget) BYTE_BUDGET="$2"; shift 2;;
    --file) FILES+=("$2"); shift 2;;
    --upstream) UPSTREAM+=("$2"); shift 2;;
    -h|--help) usage; exit 0;;
    *) echo "error: unknown arg '$1'" >&2; exit 2;;
  esac
done

# Phase 5 guard — reject retrieval-loop loudly so no caller can claim
# ORACLE_RETRIEVAL_REVIEW before the two-round protocol exists.
case "$MODE" in
  repo|upstream-audit) : ;;
  retrieval-loop) echo "error: retrieval-loop mode is Phase 5 — not implemented" >&2; exit 3;;
  *) echo "error: --mode must be repo or upstream-audit" >&2; usage; exit 2;;
esac
[[ -n "$OUT_DIR" ]] || { echo "error: --out-dir required" >&2; exit 2; }
case "$BYTE_BUDGET" in ''|*[!0-9]*|0) echo "error: --byte-budget must be a positive integer" >&2; exit 2;; esac

GIT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$GIT_ROOT" ]] || { echo "error: not inside a git repo" >&2; exit 4; }
# Canonicalize so the path-containment check compares against a symlink-resolved root
# (e.g. macOS /var -> /private/var); otherwise a legitimate in-repo file could be
# rejected, or a symlinked sibling slip through.
GIT_ROOT="$(cd "$GIT_ROOT" && pwd -P)"
GIT_SHA="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
# RUN_ID must be unique per run; this is a plain operator-run script, so date is fine.
RUN_ID="evpack-$(date -u +%Y%m%d-%H%M%S)-$$"

# Constrain the only write target to live under the repo, and validate BEFORE any
# mkdir so a rejected out-of-repo path leaves nothing behind. Canonicalize from the
# existing dir, or from the parent when the target does not exist yet.
if [[ -d "$OUT_DIR" ]]; then
  OUT_DIR="$(cd "$OUT_DIR" && pwd -P)"
else
  _op="$(cd "$(dirname -- "$OUT_DIR")" 2>/dev/null && pwd -P)" \
    || { echo "error: --out-dir parent does not exist" >&2; exit 4; }
  OUT_DIR="$_op/$(basename -- "$OUT_DIR")"
fi
case "$OUT_DIR" in
  "$GIT_ROOT"/*) : ;;
  *) echo "error: --out-dir must be inside the repo ($GIT_ROOT)" >&2; exit 4;;
esac
mkdir -p "$OUT_DIR/files" || { echo "error: cannot create out-dir" >&2; exit 4; }
MANIFEST="$OUT_DIR/manifest.txt"
: > "$MANIFEST"

# secret-like? filename denylist + known secret-content prefixes. No override (ADR 348).
# The sk- pattern allows '-'/'_' so namespaced keys (sk-proj-…, sk-ant-api03-…) match.
# Filename denylist only (no content read) — reused by is_secret_like AND the git-diff
# pathspec filter so a tracked secret file never rides out inside the aggregated diff.
is_secret_basename() {
  case "$1" in
    .env|.env.*|*.pem|*.key|*.pfx|*.p12|id_rsa|id_dsa|id_ecdsa|id_ed25519|\
    *secret*|*Secret*|*SECRET*|*token*|*Token*|*credential*|*Credential*|\
    *.keystore|*.jks|cookies|Cookies|*.cookie) return 0;;
  esac
  return 1
}

is_secret_like() {
  local p="$1" base; base="$(basename "$p")"
  is_secret_basename "$base" && return 0
  # Content scan over the WHOLE file (a token past an arbitrary byte cap must not
  # slip through); -a treats binary as text. Files are bounded by the byte budget.
  if LC_ALL=C grep -aqE \
    -e '-----BEGIN [A-Z ]*PRIVATE KEY-----' \
    -e '(AKIA|ASIA)[0-9A-Z]{16}' \
    -e 'sk-[A-Za-z0-9_-]{20,}' \
    -e 'xox[baprs]-[A-Za-z0-9-]{10,}' \
    -e 'gh[pousr]_[A-Za-z0-9]{30,}' -- "$p"; then
    return 0
  fi
  return 1
}

# Canonicalize a --file path and require it to live under GIT_ROOT. Echoes the
# resolved path on success; returns non-zero for anything outside the repo (absolute
# escapes, ../ traversal, symlinked siblings) so it is never attached.
contained_path() {
  local src="$1" dir base canon
  # Reject a symlinked final component: cd+pwd -P resolves intermediate dir symlinks,
  # but a repo-local link (repo/leak -> /outside/file) would otherwise canonicalize to
  # an in-repo name yet cp through to outside content. Regular evidence files only.
  [[ -L "$src" ]] && return 1
  dir="$(cd "$(dirname -- "$src")" 2>/dev/null && pwd -P)" || return 1
  base="$(basename -- "$src")"
  canon="$dir/$base"
  [[ -L "$canon" ]] && return 1
  case "$canon" in
    "$GIT_ROOT"/*) printf '%s' "$canon"; return 0;;
    *) return 1;;
  esac
}

bytes_of() { wc -c < "$1" 2>/dev/null | tr -d ' ' || echo 0; }

# Running budget accounting — shared by selected files AND generated git context, so
# nothing escapes the boundary. attach_idx guarantees collision-free flattened names.
attached_files=0 spent=0 attach_idx=0

{
  echo "run_id: $RUN_ID"
  echo "repo_root: $GIT_ROOT"
  echo "git_sha: $GIT_SHA"
  echo "generated_utc: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "mode: $MODE"
  echo "byte_budget: $BYTE_BUDGET"
} >> "$MANIFEST"

# Question / summary text (advisory only — does NOT count as a raw repo file, and is
# scanned for secrets like everything else).
if [[ -n "$QUESTION_FILE" ]]; then
  if [[ -r "$QUESTION_FILE" && -s "$QUESTION_FILE" ]]; then
    if is_secret_like "$QUESTION_FILE"; then
      echo "error: --question-file looks secret-like — refusing to send" >&2; exit 4
    fi
    cp -- "$QUESTION_FILE" "$OUT_DIR/question.txt"
    echo "question: question.txt ($(bytes_of "$QUESTION_FILE") bytes)" >> "$MANIFEST"
  else
    echo "error: --question-file unreadable or empty" >&2; exit 4
  fi
fi

# Gate an already-generated artifact in the pack: drop it unless it is secret-free
# AND fits the remaining byte budget. Keeps git context inside the same boundary as
# selected files (closes the unfiltered-git-diff transmission path).
gate_generated() {
  local p="$1" label="$2"
  [[ -s "$p" ]] || { rm -f -- "$p"; return 0; }
  if is_secret_like "$p"; then
    echo "secret_excluded: $label (generated)" >> "$MANIFEST"
    rm -f -- "$p"; echo "EXCLUDED secret-like generated: $label" >&2; return 0
  fi
  local sz; sz="$(bytes_of "$p")"
  if [ $((spent + sz)) -gt "$BYTE_BUDGET" ]; then
    echo "budget_skipped: $label (generated, $sz bytes)" >> "$MANIFEST"
    rm -f -- "$p"; echo "SKIP over budget: $label" >&2; return 0
  fi
  spent=$((spent + sz))
  echo "$label: $(basename "$p") ($sz bytes)" >> "$MANIFEST"
}

# Git context — deterministic, read-only, then gated like any other artifact.
# --no-ext-diff/--no-textconv stop git from invoking configured external diff or
# textconv commands while building a supposedly read-only pack. Secret-pathed files
# are excluded from the diff up front (pathspec), so a tracked .env/*.pem change can
# never ride out inside the aggregated diff even when its value matches no token regex.
diff_excludes=()
while IFS= read -r _p; do
  [[ -n "$_p" ]] || continue
  is_secret_basename "${_p##*/}" && diff_excludes+=(":(exclude)$_p")
done < <(git -C "$GIT_ROOT" diff --no-ext-diff --name-only 2>/dev/null || true)
git -C "$GIT_ROOT" status --porcelain > "$OUT_DIR/git-status.txt" 2>/dev/null || true
# Expand the exclude array only when non-empty — "${arr[@]}" on an empty array trips
# set -u under bash 3.2, and an empty pathspec arg would confuse git diff.
if [ "${#diff_excludes[@]}" -gt 0 ]; then
  git -C "$GIT_ROOT" diff --no-ext-diff --no-textconv -- . "${diff_excludes[@]}" \
    > "$OUT_DIR/git-diff.txt" 2>/dev/null || true
else
  git -C "$GIT_ROOT" diff --no-ext-diff --no-textconv > "$OUT_DIR/git-diff.txt" 2>/dev/null || true
fi
gate_generated "$OUT_DIR/git-status.txt" "git_status"
gate_generated "$OUT_DIR/git-diff.txt"   "git_diff"

# Attach selected raw files, honoring the byte budget and secret exclusion.
attach_one() {
  local src="$1"
  [[ -f "$src" ]] || { echo "skip (not a file): $src" >&2; return 0; }
  # Containment first: never attach anything outside the repo, regardless of content.
  if ! src="$(contained_path "$src")"; then
    echo "path_excluded (outside repo): $1" >> "$MANIFEST"
    echo "EXCLUDED outside repo: $1" >&2; return 0
  fi
  if is_secret_like "$src"; then
    echo "secret_excluded: $src" >> "$MANIFEST"
    echo "EXCLUDED secret-like: $src" >&2; return 0
  fi
  local sz; sz="$(bytes_of "$src")"
  if [ $((spent + sz)) -gt "$BYTE_BUDGET" ]; then
    echo "budget_skipped: $src ($sz bytes)" >> "$MANIFEST"
    echo "SKIP over budget: $src" >&2; return 0
  fi
  # Unique, collision-free name: a monotonic index prefix means two source paths that
  # flatten to the same string (a/b.txt vs a_b.txt) never overwrite each other.
  attach_idx=$((attach_idx + 1))
  local flat; flat="${attach_idx}_$(printf '%s' "$src" | tr '/' '_')"
  cp -- "$src" "$OUT_DIR/files/$flat" || { echo "skip (copy failed): $src" >&2; return 0; }
  spent=$((spent + sz))
  attached_files=$((attached_files + 1))
  echo "file: files/$flat <= $src ($sz bytes)" >> "$MANIFEST"
}

# Count-guard the expansion (bash-3.2 + set -u safe) — "${arr[@]:-}" would inject one
# empty arg and call attach_one "" spuriously.
if [ "${#FILES[@]}" -gt 0 ]; then
  for f in "${FILES[@]}"; do [[ -n "$f" ]] && attach_one "$f"; done
fi

# upstream-audit: record an inventory (file tree) of each upstream path. The tree
# listing is metadata, not raw repo source, so it does NOT by itself make this a
# repo-attached review.
up_idx=0
if [[ "$MODE" == "upstream-audit" && "${#UPSTREAM[@]}" -gt 0 ]]; then
  for u in "${UPSTREAM[@]}"; do
    [[ -n "$u" && -d "$u" ]] || { echo "skip upstream (not a dir): $u" >&2; continue; }
    # Require an actual git work tree — a bare directory (a home dir, an arbitrary
    # mount) must not be inventoried, since the file listing itself can leak private
    # names. rev-parse handles worktrees (where .git is a file), not just classic
    # repos with a physical .git directory.
    ( cd "$u" && git rev-parse --is-inside-work-tree >/dev/null 2>&1 ) \
      || { echo "skip upstream (not a git work tree): $u" >&2; continue; }
    # Index prefix + alnum-only sanitize: a user-supplied path with newlines, slashes,
    # or leading dashes can never produce a confusing/unsafe output filename.
    up_idx=$((up_idx + 1))
    inv_name="${up_idx}_$(printf '%s' "$u" | tr -c 'A-Za-z0-9' '_')"
    # Tracked files only — no `find` fallback (which could inventory .git internals,
    # untracked files, or run from the wrong dir if cd failed). Skip on any failure.
    if ! ( cd "$u" && git ls-files ) > "$OUT_DIR/upstream-$inv_name.txt" 2>/dev/null; then
      rm -f -- "$OUT_DIR/upstream-$inv_name.txt"
      echo "skip upstream (git ls-files failed): $u" >&2; continue
    fi
    gate_generated "$OUT_DIR/upstream-$inv_name.txt" "upstream_inventory"
  done
fi

echo "attached_file_count: $attached_files" >> "$MANIFEST"
echo "attached_bytes: $spent" >> "$MANIFEST"

# LABEL DECISION (settling check #2): only raw repo files attached can upgrade the
# label. Question text, git context, and upstream inventories are advisory metadata.
if [ "$attached_files" -gt 0 ]; then
  LABEL="ORACLE_REPO_ATTACHED_REVIEW"
else
  LABEL="ORACLE_SUMMARY_REVIEW"
fi
echo "label: $LABEL" >> "$MANIFEST"

echo "evidence pack at: $OUT_DIR" >&2
printf '%s\n' "$LABEL"   # LAST line = the label token for the caller
