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

# The out-dir MUST NOT already exist: a pre-existing tree (in an untrusted checkout)
# could contain committed child symlinks that redirect our writes outside the repo.
# We create it fresh and own every node under it. Canonicalize from the PARENT (the
# target doesn't exist yet), validate it's inside the repo BEFORE any mkdir so a
# rejected path leaves nothing behind, then `mkdir` (not -p) so a race that pre-creates
# the path fails loudly rather than reusing a planted dir.
[[ -e "$OUT_DIR" ]] && { echo "error: --out-dir must not already exist (a fresh dir is required)" >&2; exit 4; }
_op="$(cd "$(dirname -- "$OUT_DIR")" 2>/dev/null && pwd -P)" \
  || { echo "error: --out-dir parent does not exist" >&2; exit 4; }
OUT_DIR="$_op/$(basename -- "$OUT_DIR")"
case "$OUT_DIR" in
  "$GIT_ROOT"/*) : ;;
  *) echo "error: --out-dir must be inside the repo ($GIT_ROOT)" >&2; exit 4;;
esac
if ! mkdir "$OUT_DIR" || ! mkdir "$OUT_DIR/files"; then echo "error: cannot create out-dir" >&2; exit 4; fi
MANIFEST="$OUT_DIR/manifest.txt"
: > "$MANIFEST"

# secret-like? filename denylist + known secret-content prefixes. No override (ADR 348).
# The sk- pattern allows '-'/'_' so namespaced keys (sk-proj-…, sk-ant-api03-…) match.
# Filename denylist only (no content read) — reused by is_secret_like AND the git-diff
# pathspec filter so a tracked secret file never rides out inside the aggregated diff.
is_secret_basename() {
  # Case-INSENSITIVE so API_TOKEN / SERVICE_CREDENTIALS / Cookies.txt are caught too.
  # Scope nocasematch to this function (bash 3.2 has no ${x,,}) and restore the prior
  # setting so no other case statement in the script is affected.
  local restore rc=1
  restore="$(shopt -p nocasematch)"
  shopt -s nocasematch
  # `*_key*`/`*-key*`/`*apikey*` catch api_key, api-key, access_key, private-key.json
  # WITHOUT over-matching ordinary names (keyboard, keymap, monkey, hotkeys) the way a
  # bare `*key*` would. Content secret-values are caught separately by is_secret_like.
  case "$1" in
    .env|.env.*|*.pem|*.key|*.pfx|*.p12|id_rsa|id_dsa|id_ecdsa|id_ed25519|\
    *secret*|*token*|*credential*|*cookie*|*.keystore|*.jks|\
    *_key*|*-key*|*apikey*) rc=0;;
  esac
  eval "$restore"
  return "$rc"
}

# True if ANY component of the path is secret-like (not just the leaf). Walks
# right-to-left via parameter expansion — no word-split/glob hazard. Catches a safe
# leaf under a secret-named dir, e.g. secrets/config.yml or .env.d/app.
is_secret_path() {
  local p="$1" comp
  while [ -n "$p" ]; do
    comp="${p##*/}"
    [ -n "$comp" ] && is_secret_basename "$comp" && return 0
    [ "$p" = "${p%/*}" ] && break
    p="${p%/*}"
  done
  return 1
}

is_secret_like() {
  # Strip the repo root first so path components ABOVE GIT_ROOT (e.g. a checkout under
  # ~/token-service or /private/secrets) cannot false-positive EVERY file. Only the
  # repo-relative portion is denylist-checked; the content scan still uses the full $p.
  local p="$1" rel="${1#"$GIT_ROOT"/}"
  is_secret_path "$rel" && return 0
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

# Read NUL-delimited paths on stdin; emit (newline-terminated) only the non-secret
# ones. NUL input means git never C-quotes a control-char path, so a secret name with
# an embedded tab/newline can't evade the anchored denylist via a leading quote.
# Applied to git status and upstream ls-files so a secret PATH NAME is never
# transmitted even though its content is already absent.
emit_nonsecret_z() {
  local p
  while IFS= read -r -d '' p; do
    [ -n "$p" ] && is_secret_path "$p" && continue
    printf '%s\n' "$p"
  done
  return 0   # a final dropped record must not look like a pipeline failure under pipefail
}

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
    # Canonicalize FIRST so the GIT_ROOT-relative secret check and the self-copy guard
    # both compare canonical paths — a raw /var arg vs a /private/var GIT_ROOT (macOS
    # symlink) would otherwise miss the prefix-strip and walk secret-named ancestors.
    q_canon="$(cd "$(dirname -- "$QUESTION_FILE")" && pwd -P)/$(basename -- "$QUESTION_FILE")"
    if is_secret_like "$q_canon"; then
      echo "error: --question-file looks secret-like — refusing to send" >&2; exit 4
    fi
    q_sz="$(bytes_of "$QUESTION_FILE")"
    if [ "$q_sz" -gt "$BYTE_BUDGET" ]; then
      echo "error: --question-file ($q_sz bytes) exceeds byte budget ($BYTE_BUDGET)" >&2; exit 4
    fi
    # Skip the copy when the caller already wrote the question INTO the pack dir —
    # the documented SKILL flow does exactly this, and `cp file file` errors under set -e.
    # q_canon was computed above.
    [ "$q_canon" = "$OUT_DIR/question.txt" ] || cp -- "$QUESTION_FILE" "$OUT_DIR/question.txt"
    spent=$((spent + q_sz))   # question counts against the shared byte budget
    echo "question: question.txt ($q_sz bytes)" >> "$MANIFEST"
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
# `git diff HEAD` so STAGED changes are captured too — `git diff` alone shows only
# the unstaged worktree, so a fully-staged change would send an empty patch.
# Build the exclude set from `--name-status -M -z`: detect renames so that when EITHER
# endpoint is secret we exclude BOTH the old AND the new path. Excluding only the old
# path would still leak the file's CONTENT through the add-half of the --no-renames
# content diff. -z keeps control-char paths intact (no C-quoting). The content diff
# below then runs with --no-renames so each excluded endpoint drops its own hunk.
diff_excludes=()
while IFS= read -r -d '' _st; do
  case "$_st" in
    R*|C*)   # rename/copy: two path records follow (old, new)
      IFS= read -r -d '' _old || break
      IFS= read -r -d '' _new || break
      if is_secret_path "$_old" || is_secret_path "$_new"; then
        diff_excludes+=(":(exclude)$_old" ":(exclude)$_new")
      fi ;;
    *)       # everything else: one path record follows
      IFS= read -r -d '' _p || break
      [[ -n "$_p" ]] && is_secret_path "$_p" && diff_excludes+=(":(exclude)$_p") ;;
  esac
done < <(git -C "$GIT_ROOT" diff HEAD --no-ext-diff -M --name-status -z 2>/dev/null || true)
# git status: -z (no C-quoting) + status.renames=false so every record is `XY <path>`,
# letting us strip the fixed 3-byte `XY ` prefix and secret-check the real path.
git -C "$GIT_ROOT" -c status.renames=false status --porcelain -z 2>/dev/null \
  | { while IFS= read -r -d '' _rec; do
        _p="${_rec:3}"
        [ -n "$_p" ] && is_secret_path "$_p" && continue
        printf '%s\n' "$_rec"
      done; } > "$OUT_DIR/git-status.txt" || true
# Expand the exclude array only when non-empty — "${arr[@]}" on an empty array trips
# set -u under bash 3.2, and an empty pathspec arg would confuse git diff.
if [ "${#diff_excludes[@]}" -gt 0 ]; then
  git -C "$GIT_ROOT" diff HEAD --no-ext-diff --no-textconv --no-renames -- . "${diff_excludes[@]}" \
    > "$OUT_DIR/git-diff.txt" 2>/dev/null || true
else
  git -C "$GIT_ROOT" diff HEAD --no-ext-diff --no-textconv --no-renames > "$OUT_DIR/git-diff.txt" 2>/dev/null || true
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
  # Flatten the REPO-RELATIVE path, not the absolute one — an absolute name would leak
  # workstation/user path components into the transmitted file names and could
  # reintroduce a secret-like ancestor name that is_secret_like deliberately ignores
  # above GIT_ROOT. The index prefix still guarantees collision-free names.
  attach_idx=$((attach_idx + 1))
  local rel flat; rel="${src#"$GIT_ROOT"/}"
  flat="${attach_idx}_$(printf '%s' "$rel" | tr '/' '_')"
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
    # Tracked files only (no `find` fallback — that could inventory .git internals or
    # untracked files). -z so a control-char path isn't C-quoted past the denylist.
    if ! ( cd "$u" && git ls-files -z ) 2>/dev/null | emit_nonsecret_z > "$OUT_DIR/upstream-$inv_name.txt"; then
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
