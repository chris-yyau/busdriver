#!/usr/bin/env bash
# retrieve-evidence.sh — ADR 0007 Phase 5 Round-1 executor. Consumes the Oracle's
# UNTRUSTED request JSON and produces a read-only evidence manifest. Every requested
# path and search runs through the shared secret-scan + repo-containment gates; a
# rejected request is recorded and skipped, never copied. Fail-CLOSED on bad JSON.
set -euo pipefail
umask 077   # every artifact this script writes (manifest, copies, search hits) is operator-only
# Treat EVERY git pathspec literally: untrusted Oracle paths ($rel) and tracked filenames fed
# back as pathspecs ($f) could otherwise start with `:(...)` and be read as MAGIC pathspecs —
# `--` stops option parsing but does NOT disable pathspec magic. A magic `$f` could make the
# per-file grep scan files that never passed is_secret_path; a magic `$rel` could glob-match
# the ls-files tracked check. This env var disables all pathspec magic for git in this script.
export GIT_LITERAL_PATHSPECS=1
_RE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$_RE_DIR/lib/evidence-safety.sh"

REQUEST_FILE=""; OUT_DIR=""; BYTE_BUDGET="262144"  # 256 KiB default, matches consult cap intent
while [ $# -gt 0 ]; do
  case "$1" in
    --request-file) [ $# -ge 2 ] || { echo "error: --request-file needs a value" >&2; exit 2; }; REQUEST_FILE="$2"; shift 2;;
    --out-dir)      [ $# -ge 2 ] || { echo "error: --out-dir needs a value" >&2; exit 2; }; OUT_DIR="$2"; shift 2;;
    --byte-budget)  [ $# -ge 2 ] || { echo "error: --byte-budget needs a value" >&2; exit 2; }; BYTE_BUDGET="$2"; shift 2;;
    -h|--help)      echo "usage: retrieve-evidence.sh --request-file <json> --out-dir <dir> [--byte-budget <n>]" >&2; exit 0;;
    *) echo "error: unknown arg '$1'" >&2; exit 2;;
  esac
done
[[ -n "$REQUEST_FILE" ]] || { echo "error: --request-file required" >&2; exit 2; }
[[ -r "$REQUEST_FILE" ]] || { echo "error: --request-file unreadable" >&2; exit 2; }
[[ -n "$OUT_DIR" ]] || { echo "error: --out-dir required" >&2; exit 2; }
case "$BYTE_BUDGET" in ''|*[!0-9]*|0) echo "error: --byte-budget must be positive int" >&2; exit 2;; esac

# Fail CLOSED on malformed JSON — jq -e exits non-zero. Do this BEFORE any retrieval.
jq -e . "$REQUEST_FILE" >/dev/null 2>&1 || { echo "error: request JSON invalid — failing closed" >&2; exit 3; }

# SCHEMA gate (fail-closed on wrong TYPE — symmetric with the Task 3 validator). The
# streaming `.needed_files // [] | .[]?` below SILENTLY DROPS a wrong-typed value
# (`"needed_files":"x"` yields nothing, exit 0), violating the global type constraint.
# Reject up front: root must be an object; when present, needed_files/search_queries must
# be arrays whose every element is an object with a non-empty string path/query. A
# whole-array ABSENT is allowed (scope note in Global Constraints) — `// []` covers that.
# Also reject any path/query containing a CONTROL char (`\p{Cc}` — newline, NUL, etc.): the
# retrieval loops stream these values NUL-delimited, so a value carrying its own newline OR
# NUL would otherwise split one Oracle field into multiple requests. Reject at the boundary.
jq -e '
  (type=="object")
  and ((.needed_files // [])   | type=="array" and all(.[]; (type=="object") and ((.path  // "")|type=="string") and ((.path  // "")|length>0) and ((.path  // "")|test("\\p{Cc}")|not)))
  and ((.search_queries // []) | type=="array" and all(.[]; (type=="object") and ((.query // "")|type=="string") and ((.query // "")|length>0) and ((.query // "")|test("\\p{Cc}")|not)))
' "$REQUEST_FILE" >/dev/null 2>&1 || { echo "error: request JSON schema invalid (needed_files/search_queries must be arrays of {path|query:non-empty-string}) — failing closed" >&2; exit 3; }

GIT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$GIT_ROOT" ]] || { echo "error: not in git repo" >&2; exit 4; }
GIT_ROOT="$(cd "$GIT_ROOT" && pwd -P)"

# --- out-dir: fresh-dir + symlink guard (NOT in-repo-required) ---
# Design decision (resolves the arbiter's HIGH containment finding): the OUT_DIR is a
# WRITE target the wrapper supplies (e.g. a /tmp mktemp dir — see Task 4 Step 5), so we
# do NOT require it inside GIT_ROOT (that requirement is build-evidence-pack.sh's, and
# only the REQUESTED source paths below need repo-containment). What we DO keep from
# build-evidence-pack.sh is the fresh-dir + symlink guard: create both dirs with plain
# `mkdir` (NOT -p) so a pre-existing dir or a files/ symlink escaping elsewhere fails
# closed before any copy. Canonicalize the parent so a symlinked parent is resolved.
_od="$OUT_DIR"; while [ "$_od" != "/" ] && [ "${_od%/}" != "$_od" ]; do _od="${_od%/}"; done
_odp="${_od%/*}"; [ "$_odp" = "$_od" ] && _odp="."
_op="$(cd "$_odp" 2>/dev/null && pwd -P)" || { echo "error: --out-dir parent missing" >&2; exit 4; }
OUT_DIR="$_op/${_od##*/}"
# `mkdir` (no -p): fails if OUT_DIR already exists. Then files/ likewise — and if files/
# resolves to a symlink the second mkdir fails (mkdir refuses to create over a symlink),
# so a planted escaping files/ symlink cannot be written through.
mkdir "$OUT_DIR" 2>/dev/null || { echo "error: out-dir exists or cannot be created" >&2; exit 4; }
[ -L "$OUT_DIR/files" ] && { echo "error: files/ is a symlink — refusing" >&2; exit 4; }
mkdir "$OUT_DIR/files" 2>/dev/null || { echo "error: cannot create files/ (symlink or exists)" >&2; exit 4; }
MANIFEST="$OUT_DIR/manifest.txt"; : > "$MANIFEST"
{ echo "run_id: retrieve-$(git rev-parse HEAD 2>/dev/null || echo unknown)"
  echo "repo_root: $GIT_ROOT"
  echo "generated_utc: $(date -u +%Y-%m-%dT%H:%M:%SZ)"; } >> "$MANIFEST"

spent=0; idx=0; accepted=0; seen_files=0
MAX_FILES=64; MAX_QUERIES=20; MAX_QUERY_BYTES=256   # untrusted-input backpressure caps
# --- needed_files: each requested path runs the gates ---
# NUL-delimited extraction (jq -j emits each value followed by a \u0000 terminator): a
# schema-valid path STRING can still contain an embedded newline; a newline-delimited
# `read` would split one Oracle field into multiple retrieval requests, breaking the
# one-field-one-request boundary. NUL keeps each Oracle field a single record.
while IFS= read -r -d '' reqpath; do
  [ -n "$reqpath" ] || continue
  seen_files=$((seen_files + 1))
  if [ "$seen_files" -gt "$MAX_FILES" ]; then echo "skipped_excess_files: $reqpath (cap $MAX_FILES)" >> "$MANIFEST"; continue; fi
  case "$reqpath" in /*) cand="$reqpath";; *) cand="$GIT_ROOT/$reqpath";; esac
  canon="$(contained_path "$cand")" || { echo "rejected_outside_repo: $reqpath" >> "$MANIFEST"; continue; }
  rel="${canon#"$GIT_ROOT"/}"
  # GATE ORDER MATTERS (fixes a FIFO/special-file hang). is_secret_like CONTENT-scans the
  # file (grep over its bytes) with NO regular-file guard, so running it on an in-repo
  # FIFO/named-pipe would BLOCK on read forever — a DoS on attacker-influenced input. So
  # gate cheaply first, content-scan last:
  #   1. is_secret_path — path-NAME denylist only, no file read (safe on any node type).
  #   2. ls-files tracked — special files are never tracked, so a FIFO is rejected here.
  #   3. [[ -f && -r ]] — confirm a regular, readable file before ANY content read.
  #   4. byte-budget check — a cheap stat (wc -c). Runs BEFORE the content scan so an
  #      untrusted request for up to 64 oversized files can't force 64 full-file greps that
  #      would be skipped over budget anyway.
  #   5. is_secret_like — content scan, now guaranteed to run only on a regular, in-budget file.
  if is_secret_path "$rel"; then echo "rejected_secret: $reqpath" >> "$MANIFEST"; continue; fi
  # Only transmit TRACKED files — match the inventory the Oracle was shown and
  # build-evidence-pack.sh's tracked-only posture (also excludes FIFOs / untracked scratch
  # such as local notes, build artifacts, an un-gitignored .env.local).
  git -C "$GIT_ROOT" ls-files --error-unmatch -- "$rel" >/dev/null 2>&1 || { echo "rejected_untracked: $reqpath" >> "$MANIFEST"; continue; }
  [ -f "$canon" ] && [ -r "$canon" ] || { echo "skipped_unavailable: $reqpath" >> "$MANIFEST"; continue; }
  sz="$(bytes_of "$canon")"
  if [ "$((spent + sz))" -gt "$BYTE_BUDGET" ]; then echo "skipped_over_budget: $reqpath" >> "$MANIFEST"; continue; fi
  if is_secret_like "$canon"; then echo "rejected_secret: $reqpath" >> "$MANIFEST"; continue; fi
  idx=$((idx + 1)); flat="${idx}_$(printf '%s' "$rel" | tr '/' '_')"
  cp -- "$canon" "$OUT_DIR/files/$flat" || { echo "skipped_copy_failed: $reqpath" >> "$MANIFEST"; continue; }
  spent=$((spent + sz)); accepted=$((accepted + 1))
  echo "file: files/$flat <= $rel ($sz bytes)" >> "$MANIFEST"
done < <(jq -j '.needed_files // [] | .[]? | (.path // empty) + "\u0000"' "$REQUEST_FILE")

# --- search_queries: bounded, read-only, secret-filtered (path AND content) ---
# Search artifacts land UNDER files/ so the Round-2 wrapper's single files/* glob
# attaches them too (resolves the arbiter's "Round-2 omits search context" finding).
MAX_HITS=200
qidx=0; seen_q=0
while IFS= read -r -d '' q; do
  [ -n "$q" ] || continue
  seen_q=$((seen_q + 1))
  if [ "$seen_q" -gt "$MAX_QUERIES" ]; then echo "skipped_excess_queries: query[$seen_q] (cap $MAX_QUERIES)" >> "$MANIFEST"; continue; fi
  # Reject an overlong query before spending a full-tree git grep on it.
  if [ "$(printf '%s' "$q" | wc -c | tr -d ' ')" -gt "$MAX_QUERY_BYTES" ]; then echo "skipped_query_too_long: query[$seen_q]" >> "$MANIFEST"; continue; fi
  qidx=$((qidx + 1))
  # STAGE the hits OUTSIDE files/ first, scan, then mv in only when clean. files/ is the dir
  # attached to the Oracle, so an UNSCANNED secret artifact must never land there even
  # transiently — a crash (or a reader racing a default umask) between write and the secret
  # scan would otherwise leave secret content on disk inside the transmit set. The staging
  # file is a sibling of files/ (never attached) and is removed on every rejection path.
  stage="$OUT_DIR/.search-stage-$qidx"; final="$OUT_DIR/files/search-$qidx.txt"
  # -F fixed-string (query is untrusted; no regex injection), -I skip binary.
  # Pass query as a single -e arg (never interpolated into a pattern string).
  # First get the MATCHING FILE PATHS as NUL-delimited records (`-l -z`) so a path that
  # itself contains a colon stays intact — the secret-path denylist must see the WHOLE
  # path (`${line%%:*}` on `dir:secrets/cfg:12:...` would truncate to `dir`, dropping the
  # secret-named component). Secret-filter on the intact path, THEN per-file grep for hits.
  : > "$stage"
  git -C "$GIT_ROOT" grep -lIF -z -e "$q" -- . 2>/dev/null \
    | while IFS= read -r -d '' f; do
        is_secret_path "$f" && continue
        # Reject a tracked SYMLINK (git tracks symlinks as mode 120000): is_secret_like below
        # greps the WORKING-TREE file, which would read THROUGH the link to its target —
        # outside the repo, or blocking on a device/FIFO target. Skip symlinks and confirm a
        # regular file before any content read (mirrors the needed_files gate order).
        [ -L "$GIT_ROOT/$f" ] && continue
        [ -f "$GIT_ROOT/$f" ] || continue
        # Whole-FILE secret exclusion, matching the needed_files posture: if the matched
        # source file contains a secret ANYWHERE (not just on the hit line), drop ALL its
        # hits — a query line adjacent to a secret must not ride out.
        is_secret_like "$GIT_ROOT/$f" && continue
        git -C "$GIT_ROOT" grep -nIF -e "$q" -- "$f" 2>/dev/null
      done | head -n "$MAX_HITS" | head -c "$((BYTE_BUDGET + 1))" > "$stage" || true
  # head -c caps the staged bytes (head -n caps LINES; one match in a huge single-line tracked
  # file could blow far past BYTE_BUDGET — disk exhaustion). Cap at BUDGET+1 so an OVERFLOW is
  # detectable: reject the whole search rather than TRUNCATE-and-send. A truncated artifact
  # could split a secret at the cut point, leaving a sub-regex partial the scan below misses.
  if [ ! -s "$stage" ]; then rm -f "$stage"; echo "search_empty: query[$qidx]" >> "$MANIFEST"; continue; fi
  if [ "$(bytes_of "$stage")" -gt "$BYTE_BUDGET" ]; then rm -f "$stage"; echo "skipped_over_budget_search: query[$qidx] (truncated)" >> "$MANIFEST"; continue; fi
  # CONTENT scan: a query like `sk-` can match a secret value living in a NON-secret-named
  # file, which the path denylist above misses. is_secret_like scans the whole artifact;
  # if it trips, the staged hits are dropped before they can ever enter files/.
  if is_secret_like "$stage"; then rm -f "$stage"; echo "rejected_secret_search: query[$qidx]" >> "$MANIFEST"; continue; fi
  hsz="$(bytes_of "$stage")"
  if [ "$((spent + hsz))" -gt "$BYTE_BUDGET" ]; then rm -f "$stage"; echo "skipped_over_budget_search: query[$qidx]" >> "$MANIFEST"; continue; fi
  mv "$stage" "$final"     # only a scanned-clean, in-budget artifact enters files/
  spent=$((spent + hsz))   # search bytes count against the same shared budget as files
  echo "search: files/search-$qidx.txt <= query[$qidx] ($(wc -l < "$final" | tr -d ' ') hits)" >> "$MANIFEST"
done < <(jq -j '.search_queries // [] | .[]? | (.query // empty) + "\u0000"' "$REQUEST_FILE")

{ echo "accepted_files: $accepted"; echo "accepted_bytes: $spent"; } >> "$MANIFEST"
# Progress to STDERR only (mirrors build-evidence-pack.sh's stdout discipline) so a caller
# that captures this script's stdout gets nothing but the manifest path it writes — the
# wrapper does not capture it, keeping the wrapper's own stdout token-only.
echo "ORACLE_RETRIEVAL_MANIFEST $MANIFEST" >&2
