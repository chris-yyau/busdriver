#!/usr/bin/env bash
# test-vault-references.sh — vault contract test
#
# Invariants:
#  1. No archived name may exist in BOTH the live dir and its archive dir
#     (resurrection guard — e.g. sync-upstream re-copying an archived skill).
#  2. Any line in an ACTIVE surface (skills/ agents/ commands/ hooks/ scripts/)
#     that references an archived name must carry the literal token "(vault)"
#     on the same line — the single loading convention defined in
#     skills/orchestrator/SKILL.md.
#  3. .upstream-sources.json must not track an archived name at a live path
#     (skills/<name>/ etc.) — moved files must point at skills-archive/.
set -u
cd "$(dirname "$0")/.." || exit 1

FAIL=0
fail() { echo "FAIL: $1"; FAIL=1; }

archived_names() {
  for d in skills-archive/*/; do [[ -d "$d" ]] && basename "$d"; done
  for f in agents-archive/*.md commands-archive/*.md; do
    [[ -f "$f" ]] && basename "$f" .md
  done
}

NAMES="$(archived_names)"
[[ -n "$NAMES" ]] || { echo "SKIP: no archives present"; exit 0; }

# ── 1. Resurrection guard ────────────────────────────────────────────────
for d in skills-archive/*/; do
  n="$(basename "$d")"
  [[ -e "skills/$n" ]] && fail "resurrected skill: skills/$n also exists in skills-archive/"
done
for f in agents-archive/*.md; do
  [[ -f "$f" ]] || continue
  [[ -e "agents/$(basename "$f")" ]] && fail "resurrected agent: agents/$(basename "$f") also exists in agents-archive/"
done
for f in commands-archive/*.md; do
  [[ -f "$f" ]] || continue
  [[ -e "commands/$(basename "$f")" ]] && fail "resurrected command: commands/$(basename "$f") also exists in commands-archive/"
done

# ── 2. Active-surface references must be (vault)-annotated ──────────────
# Escape regex metacharacters in each name, then build one alternation,
# word-bounded on the skill-name alphabet [a-z0-9-].
# shellcheck disable=SC2016  # literal sed pattern — $ is a regex anchor here, not an expansion
ESCAPED="$(printf '%s\n' "$NAMES" | sed 's/[][\.|$(){}?+*^]/\\&/g')"
PATTERN="$(printf '%s\n' "$ESCAPED" | paste -sd'|' -)"
# shellcheck disable=SC2312  # first grep's exit is intentionally masked; no-match is handled by || true
# Excludes matches preceded by '@' — a short archived name (e.g. "jira") can
# collide with an unrelated email-domain/mention token (e.g. "@jira") that has
# nothing to do with the archived command. Without this exclusion those
# collisions force a semantically misleading "(vault)" annotation onto lines
# that don't actually reference the archive.
VIOLATIONS="$(grep -rInE "(^|[^a-z0-9@-])(${PATTERN})([^a-z0-9-]|\$)" \
  skills agents commands hooks scripts 2>/dev/null | grep -v '(vault)' || true)"
if [[ -n "$VIOLATIONS" ]]; then
  fail "un-annotated references to archived names (add \"(vault)\" on the line or archive the referrer):"
  echo "$VIOLATIONS" | head -50
  COUNT="$(printf '%s\n' "$VIOLATIONS" | wc -l | tr -d ' ')"
  [[ "$COUNT" -gt 50 ]] && echo "  ... and $((COUNT - 50)) more"
fi

# ── 3. Manifest must not point archived names at live paths ─────────────
if [[ -f .upstream-sources.json ]]; then
  if command -v jq >/dev/null 2>&1; then
    # Robust: parse JSON, check every tracked path against archived names.
    # Parse and match separately so a jq failure fails CLOSED, not open.
    if ! MANIFEST_PATHS="$(jq -r '.files[].path' .upstream-sources.json 2>&1)"; then
      fail ".upstream-sources.json failed to parse: $MANIFEST_PATHS"
      MANIFEST_PATHS=""
    fi
    MANIFEST_HITS="$(printf '%s\n' "$MANIFEST_PATHS" \
      | grep -E "^(skills|agents|commands)/(${PATTERN})(/|\.md\$)" || true)"
  else
    # Fallback without jq: match the pretty-printed "path" field format.
    MANIFEST_HITS="$(grep -nE "\"path\": *\"(skills|agents|commands)/(${PATTERN})(/|\.md\")" \
      .upstream-sources.json || true)"
  fi
  if [[ -n "$MANIFEST_HITS" ]]; then
    fail ".upstream-sources.json tracks archived names at live paths (sync would resurrect them):"
    echo "$MANIFEST_HITS" | head -20
  fi
fi

if [[ "$FAIL" -eq 0 ]]; then
  echo "PASS: vault references clean ($(printf '%s\n' "$NAMES" | wc -l | tr -d ' ') archived names checked)"
  exit 0
fi
exit 1
