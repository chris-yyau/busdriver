#!/usr/bin/env bash
# test-upstream-manifest.sh - semantic integrity of .upstream-sources.json
#
# Repo-side invariants (these run everywhere, incl. CI with no upstream clones):
#   1. The manifest parses as JSON (fail CLOSED on parse error).
#   2. Every entry has a non-empty `path`; paths are unique.
#   3. Every entry's `status` is one of: sync | custom | local.
#   4. A `sync` or `custom` entry MUST carry `upstream_path` AND a `source`, and
#      that `source` MUST be a key in the top-level `upstreams` map.
#   5. A `local` entry carries no upstream requirement (source/upstream_path
#      optional) - it originates in this repo.
#   6. Every tracked `path` exists on disk - NO exceptions. A change that deletes
#      a tracked file MUST remove its manifest entry in the same commit; a
#      dangling entry is stale manifest state and fails here.
#   7. An `upstreams` entry with zero referencing `files[]` is VALID - a
#      pattern-derived upstream (e.g. gstack) is tracked for provenance only.
#   8. Unknown extra keys on an `upstreams` entry (note / license / adoption)
#      are permitted - they are provenance annotations, not schema violations.
#
# Boundary: repo-side only. Whether an `upstream_path` still exists in the
# upstream, and whether a `sync` file is byte-identical to it, are SYNC-TIME
# concerns (they need the upstream clone at a pinned commit) and are NOT checked
# here - except opt-in: set UPSTREAM_CACHE_DIR to a dir holding per-source clones
# (<dir>/<source>/...) and the existence of each `upstream_path` is also checked
# when its clone is present. Byte-identity is deliberately still out of scope
# (it needs the pinned SHA, which the manifest does not record).
set -u
cd "$(dirname "$0")/.." || exit 1

MANIFEST=".upstream-sources.json"
FAIL=0
fail() { echo "FAIL: $1"; FAIL=1; }

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not available"; exit 0; }
[[ -f "$MANIFEST" ]] || { echo "SKIP: $MANIFEST not present"; exit 0; }

# -- 1. Parses as JSON ----------------------------------------------------
if ! jq empty "$MANIFEST" 2>/dev/null; then
  echo "FAIL: $MANIFEST does not parse as JSON"
  exit 1
fi

# Top-level shape must be right or later checks silently mis-validate. Fail
# CLOSED on either: `.files` not an array makes `.files | length` == 0 (loop
# validates nothing → false PASS); `.upstreams` not an object makes the key
# extraction below exit non-zero while the assignment masks it (empty key set →
# every sync/custom source misreported as unknown, or an all-local manifest
# passing on a malformed schema).
FILES_TYPE="$(jq -r '.files | type' "$MANIFEST" 2>/dev/null)"
if [[ "$FILES_TYPE" != "array" ]]; then
  echo "FAIL: .files is missing or not a JSON array (got: ${FILES_TYPE:-null})"
  exit 1
fi
UPSTREAMS_TYPE="$(jq -r '.upstreams | type' "$MANIFEST" 2>/dev/null)"
if [[ "$UPSTREAMS_TYPE" != "object" ]]; then
  echo "FAIL: .upstreams is missing or not a JSON object (got: ${UPSTREAMS_TYPE:-null})"
  exit 1
fi

# -- upstreams key set (for invariant 4) ----------------------------------
# Newline-delimited string + a fixed-string exact-line grep. `grep -qxF` is
# metacharacter-safe (-F: a source with glob chars like * or [ cannot match a
# different key) and exact (-x: whole-line only), the here-string avoids a
# masked-return pipe (SC2312), and it is bash-3.2 safe (no associative arrays).
UPSTREAMS="$(jq -r '.upstreams | keys[]' "$MANIFEST" 2>/dev/null)"
is_upstream() { grep -qxF -- "$1" <<< "$UPSTREAMS"; }

# -- 2. Path uniqueness ---------------------------------------------------
# here-strings (not a pipe) so no intermediate command's return is masked (SC2312)
ALL_PATHS="$(jq -r '.files[].path' "$MANIFEST")"
SORTED_PATHS="$(sort <<< "$ALL_PATHS")"
DUPES="$(uniq -d <<< "$SORTED_PATHS")"
if [[ -n "$DUPES" ]]; then
  fail "duplicate manifest paths:"
  printf '%s\n' "$DUPES" | sed 's/^/    /'
fi

# -- 3-6. Per-entry checks ------------------------------------------------
# Read one TSV record per file straight from jq via process substitution: the
# loop runs in the CURRENT shell (so fail() persists FAIL), and @tsv escapes any
# tab/newline INSIDE a field to a literal \t / \n - so every file is exactly one
# output line and no field value can split a record. Fail CLOSED when the
# processed count != the declared file count, so a partial jq extraction can
# never let the script print PASS without validating every entry.
EXPECTED="$(jq '.files | length' "$MANIFEST")"
PROCESSED=0
# shellcheck disable=SC2312  # jq's exit in the process substitution below is masked, but a partial/failed extraction is caught fail-closed by the PROCESSED==EXPECTED check after the loop
while IFS=$'\t' read -r path status source upstream_path; do
  PROCESSED=$((PROCESSED + 1))
  [[ -n "$path" ]] || { fail "an entry has an empty/absent path"; continue; }
  case "$status" in
    sync|custom)
      [[ -n "$upstream_path" ]] || fail "$path: status=$status requires upstream_path"
      if [[ -z "$source" ]]; then
        fail "$path: status=$status requires source"
      elif ! is_upstream "$source"; then
        fail "$path: source '$source' is not a key in upstreams{}"
      fi
      ;;
    local) : ;;  # invariant 5 - no upstream requirement
    "") fail "$path: missing status" ;;
    *)  fail "$path: invalid status '$status' (must be sync|custom|local)" ;;
  esac
  # invariant 6 - tracked path must exist on disk, no exceptions
  [[ -e "$path" ]] || fail "$path: tracked path missing on disk (stale entry - remove it in the same change that deleted the file)"
  # opt-in clone-side existence check
  if [[ -n "${UPSTREAM_CACHE_DIR:-}" && -n "$upstream_path" && -n "$source" && -d "$UPSTREAM_CACHE_DIR/$source" ]]; then
    [[ -e "$UPSTREAM_CACHE_DIR/$source/$upstream_path" ]] \
      || fail "$path: upstream_path '$upstream_path' not found in $UPSTREAM_CACHE_DIR/$source"
  fi
done < <(jq -r '.files[] | [.path, (.status // ""), (.source // ""), (.upstream_path // "")] | @tsv' "$MANIFEST")
[[ "$PROCESSED" -eq "$EXPECTED" ]] \
  || fail "validated $PROCESSED entries but manifest declares $EXPECTED (incomplete - closing)"

# Invariants 7 & 8 need no active check - the schema deliberately does NOT
# require every upstream to be referenced by a file, nor restrict the key set of
# an upstreams entry. They are asserted here as documentation of intent.

if [[ "$FAIL" -eq 0 ]]; then
  # precompute counts into assignments (command-subst return in an assignment is
  # not a masked-return per SC2312, unlike interpolating $(...) into echo)
  FILE_COUNT="$(jq '.files | length' "$MANIFEST")"
  UPSTREAM_COUNT="$(jq '.upstreams | length' "$MANIFEST")"
  echo "PASS: upstream manifest valid (${FILE_COUNT} entries, ${UPSTREAM_COUNT} upstreams)"
  exit 0
fi
exit 1
