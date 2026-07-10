#!/usr/bin/env bash
# install.sh — Install the busdriver rules canon to ~/.claude/rules/common/
#
# Usage:
#   ./install.sh          # replace ~/.claude/rules/common/ with rules/common/
#
# The busdriver rules are a small, hand-written, always-loaded canon under
# rules/common/ (see rules/README.md) — currently the four files listed there.
# There are no language-specific rule packs: they were retired (the source tree
# has no rules/<language>/ dirs left), procedural guidance lives in on-demand
# skills, and mechanically checkable rules are enforced by the gates.
#
# This is a CLEAN install of common/ (the target dir is replaced, not merged),
# so a re-install never leaves stale files behind. The retired language packs
# are separate directories (~/.claude/rules/<language>/) this never touches —
# remove any you still have by hand (see rules/README.md → Installation).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET_DIR="${HOME}/.claude/rules"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

# Legacy usage was `./install.sh <language> ...` / `--all`. The packs are gone,
# so arguments now mean nothing — say so loudly rather than silently ignoring
# them and installing only common.
if [[ $# -gt 0 ]]; then
  echo -e "${YELLOW}Note: language rule packs were retired — argument(s) '$*' are ignored.${NC}" >&2
  echo -e "${YELLOW}Only the common canon is installed now (see rules/README.md).${NC}" >&2
fi

src="${SCRIPT_DIR}/common"
dst="${TARGET_DIR}/common"

if [[ ! -d "$src" ]]; then
  echo -e "${RED}ERROR: common/ not found in ${SCRIPT_DIR}${NC}" >&2
  exit 1
fi

echo "Installing busdriver rules → ${TARGET_DIR}"

# Physical containment, checked BEFORE touching anything: walk up to the deepest
# EXISTING ancestor of $dst and verify it resolves under $HOME. A symlinked
# directory at ANY level (~/.claude, rules/, or common/ — leaf, ancestor, or
# intermediate) that escapes $HOME is refused before a single file is removed or
# created. (pwd -P resolves every symlink in the path.) Fail-CLOSED on
# unresolvable paths.
home_real="$(cd "$HOME" 2>/dev/null && pwd -P)" || home_real=""
[[ -z "$home_real" ]] && { echo -e "${RED}ERROR: cannot resolve \$HOME${NC}" >&2; exit 1; }
anc="$dst"
while [[ ! -e "$anc" ]]; do anc="$(dirname "$anc")"; done
anc_real="$(cd "$anc" 2>/dev/null && pwd -P)" || anc_real=""
if [[ -z "$anc_real" || ( "$anc_real/" != "$home_real/"* && "$anc_real" != "$home_real" ) ]]; then
  echo -e "${RED}ERROR: install path ${anc} resolves outside \$HOME (${anc_real:-unresolved}) — refusing${NC}" >&2
  exit 1
fi

# Source-safety: never clean-install in a way that would delete the source.
# `rm`/swap the target while the source ($src) is the SAME dir, or a dir NESTED
# UNDER the target, would delete the source (or the whole checkout) out from
# under us. Resolve both and compare.
src_real="$(cd "$src" 2>/dev/null && pwd -P)" || src_real=""
if [[ -e "$dst" ]]; then
  dst_real="$(cd "$dst" 2>/dev/null && pwd -P)" || dst_real=""
  if [[ -n "$src_real" && -n "$dst_real" ]]; then
    if [[ "$src_real" == "$dst_real" ]]; then
      echo -e "${GREEN}  ✓ common/ (already in place — install target resolves to the source)${NC}"
      echo -e "${GREEN}Done.${NC}"
      exit 0
    fi
    if [[ "$src_real" == "$dst_real"/* ]]; then
      echo -e "${RED}ERROR: source (${src_real}) lives under the install target (${dst_real}); a clean install would delete it. Move the checkout outside ${dst}.${NC}" >&2
      exit 1
    fi
  fi
fi

# Clean install via staging dir + swap, all on the SAME filesystem ($staging is
# a mktemp-unique sibling of $dst under $TARGET_DIR, so the mv is a rename, not a
# copy):
#   1. copy the new canon into $staging        (fails → old canon untouched)
#   2. remove the old $dst                      (unlinks a planted dest symlink;
#                                                confirmed above to be under $HOME)
#   3. rename $staging into the now-free slot   (atomic)
# The EXIT trap makes step 2→3 crash-safe WITHOUT a fragile backup copy:
# "complete-or-drop" — if we were interrupted after removing $dst but before the
# rename, it finishes the rename so the canon is never left missing; otherwise it
# just drops $staging. It only ever moves $staging into $dst or removes $staging
# — it never deletes $dst or any pre-existing/unrelated path.
mkdir -p "$TARGET_DIR"
staging="$(mktemp -d "${TARGET_DIR}/.common-new.XXXXXX")"
_finish_or_drop() {
  if [[ -d "$staging" && ! -e "$dst" ]]; then
    mv "$staging" "$dst" 2>/dev/null || rm -rf "$staging" 2>/dev/null || true
  else
    rm -rf "$staging" 2>/dev/null || true
  fi
}
trap _finish_or_drop EXIT
cp -r "$src"/. "$staging"/
rm -rf "$dst"
mv "$staging" "$dst"
trap - EXIT
echo -e "${GREEN}  ✓ common/${NC}"
echo -e "${GREEN}Done.${NC}"
