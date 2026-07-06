#!/usr/bin/env bash
#
# vault-promote.sh — promote a vaulted skill/agent/command back into
# auto-discovery (the manual-on-friction path from ADR 0010).
#
# Does the two error-prone mechanical steps that MUST be correct:
#   1. git mv the archived item back to its live dir (resurrection-guarded).
#   2. Rewrite its .upstream-sources.json path archive->live, so the next
#      sync-upstream updates the live copy instead of re-creating the archive.
# Then runs the contract test and hands you the exact `(vault)` marker lines
# to trim by hand (auto-sed would corrupt shared multi-item lines).
#
# Usage:
#   vault-promote.sh <name>            Promote and verify
#   vault-promote.sh <name> --dry-run  Show what would change, touch nothing
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

NAME="${1:-}"
DRY_RUN=0
if [[ -z "$NAME" || "$NAME" == --* ]]; then
  echo "usage: vault-promote.sh <name> [--dry-run]" >&2
  exit 2
fi
# Reject any unrecognized argument — a typo like --dryrun must NOT silently
# fall through to the real (destructive) git mv + manifest rewrite.
case "${2:-}" in
  "")        ;;
  --dry-run) DRY_RUN=1 ;;
  *)         echo "error: unknown argument '$2'" >&2
             echo "usage: vault-promote.sh <name> [--dry-run]" >&2; exit 2 ;;
esac
if [[ $# -gt 2 ]]; then
  echo "error: too many arguments" >&2
  echo "usage: vault-promote.sh <name> [--dry-run]" >&2; exit 2
fi
# Validate at the trust boundary: skill/agent/command names are strict
# lowercase kebab-case. Rejecting anything else keeps NAME free of regex
# metacharacters (so the marker grep can't be subverted) and rejects
# non-names like -leading, trailing-, or CONSECUTIVE__UNDERSCORES up front.
if [[ ! "$NAME" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]]; then
  echo "error: invalid name '$NAME' (expected lowercase kebab-case, e.g. django-patterns)" >&2
  exit 2
fi

# ── 1. Locate the archived item — must resolve to exactly one archive kind ─
# Collect every match so a name living in two archive dirs is rejected, not
# silently resolved to whichever check ran last.
declare -a MATCHES=()
[[ -d "skills-archive/$NAME"      ]] && MATCHES+=("skill:skills-archive/$NAME:skills/$NAME")
[[ -f "agents-archive/$NAME.md"   ]] && MATCHES+=("agent:agents-archive/$NAME.md:agents/$NAME.md")
[[ -f "commands-archive/$NAME.md" ]] && MATCHES+=("command:commands-archive/$NAME.md:commands/$NAME.md")

if [[ ${#MATCHES[@]} -eq 0 ]]; then
  echo "error: '$NAME' not found in skills-archive/, agents-archive/, or commands-archive/" >&2
  exit 1
fi
if [[ ${#MATCHES[@]} -gt 1 ]]; then
  echo "error: '$NAME' is ambiguous — matches multiple archive kinds:" >&2
  printf '  %s\n' "${MATCHES[@]%%:*}" >&2
  echo "promote each kind manually (git mv + manifest edit) so they stay consistent." >&2
  exit 1
fi
IFS=: read -r KIND SRC DST <<<"${MATCHES[0]}"

# Resurrection guard — never clobber a live item.
if [[ -e "$DST" ]]; then
  echo "error: live path '$DST' already exists (would resurrect a duplicate)" >&2
  exit 1
fi

echo "promoting $KIND: $SRC -> $DST"

# ── 2. Manifest hits (archive paths that must flip to live) ──────────────
MANIFEST=".upstream-sources.json"
MANIFEST_HITS=""
if [[ -f "$MANIFEST" ]]; then
  # Fail CLOSED: without jq we can't flip the manifest path, and a stale
  # archive path resurrects the skill on the next sync — the contract test
  # can't catch it (invariant 3 only checks names still IN the archive).
  if ! command -v jq >/dev/null 2>&1; then
    echo "error: jq is required to rewrite $MANIFEST — refusing to promote without the manifest flip" >&2
    exit 1
  fi
  # Match manifest paths by literal SRC (no regex) — a file entry equal to SRC
  # (agent/command) or any file under the SRC dir (skill). Immune to any
  # metacharacter a name could carry. Fail CLOSED on a jq parse error: a
  # swallowed error would look like "no matches" and skip the required flip.
  if ! MANIFEST_HITS="$(jq -r --arg src "$SRC" \
    '.files[].path | select(. == $src or startswith($src + "/"))' \
    "$MANIFEST")"; then
    echo "error: failed to parse $MANIFEST (jq error) — aborting before any move" >&2
    exit 1
  fi
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "--- dry run, nothing changed ---"
  echo "git mv $SRC $DST"
  [[ -n "$MANIFEST_HITS" ]] && echo "manifest paths to flip archive->live:" && printf '%s\n' "$MANIFEST_HITS" | sed 's/^/  /'
  echo "marker lines to trim by hand afterward:"
  grep -rInE "(^|[^a-z0-9@-])$NAME([^a-z0-9-]|\$)" skills agents commands hooks scripts rules 2>/dev/null \
    | grep '(vault)' | sed 's/^/  /' || echo "  (none)"
  exit 0
fi

# ── 3. Prepare the manifest rewrite BEFORE moving, so a jq failure aborts ─
# with nothing changed — never a half-done promote (moved file, stale manifest).
# Temp lives beside the manifest so the final mv is an atomic same-fs rename.
MANIFEST_TMP=""
if [[ -n "$MANIFEST_HITS" ]]; then
  MANIFEST_TMP="$(mktemp "${MANIFEST}.XXXXXX")"
  trap 'rm -f "$MANIFEST_TMP"' EXIT
  if ! jq --arg src "$SRC" \
      '(.files[] | select(.path == $src or (.path | startswith($src + "/"))) | .path) |= sub("-archive"; "")' \
      "$MANIFEST" > "$MANIFEST_TMP"; then
    echo "error: failed to rewrite $MANIFEST (jq error) — aborting before any move (nothing changed)" >&2
    exit 1
  fi
fi

# ── 4. Move the item, then commit the prepared manifest rewrite ───────────
git mv "$SRC" "$DST"
if [[ -n "$MANIFEST_TMP" ]]; then
  mv "$MANIFEST_TMP" "$MANIFEST"   # atomic same-fs rename
  trap - EXIT
  # Stage the manifest rewrite so it rides with the git-mv'd rename in the
  # SAME commit. git mv auto-stages the rename; a plain filesystem mv does
  # not — without this a bare `git commit` would land the rename but drop the
  # manifest flip, and the next sync-upstream would resurrect the archive.
  git add "$MANIFEST"
  hit_count="$(grep -c . <<<"$MANIFEST_HITS" || true)"
  echo "rewrote ${hit_count} manifest path(s) archive->live (staged)"
fi

# ── 5. Verify contract, then hand off the marker cleanup ─────────────────
echo
bash tests/test-vault-references.sh || {
  echo "!! contract test failed — inspect above before committing" >&2
  exit 1
}

echo
echo "hand-trim these stale '(vault)' markers referencing '$NAME' (test stays green either way,"
echo "but leaving them is misleading; shared reviewer/build lines carry per-item markers — edit by hand):"
grep -rInE "(^|[^a-z0-9@-])$NAME([^a-z0-9-]|\$)" skills agents commands hooks scripts rules 2>/dev/null \
  | grep '(vault)' | sed 's/^/  /' || echo "  (none — clean)"

echo
echo "done. review, then: git commit"
