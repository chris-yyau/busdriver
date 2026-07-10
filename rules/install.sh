#!/usr/bin/env bash
# install.sh — Install busdriver rules to ~/.claude/rules/
#
# Usage:
#   ./install.sh                    # Install common rules only
#   ./install.sh typescript python  # Install common + language-specific
#   ./install.sh --all              # Install common + all languages
#
# Always installs common/ first. Language directories are additive.
# Uses cp -r to preserve directory structure (do NOT flatten).
#
# Install exclusions: paths listed in rules/.install-exclude are copied into the
# repo tree but NOT installed to ~/.claude/rules/ (they duplicate on-demand
# busdriver skills or are stale, so they stay out of always-loaded context). The
# files REMAIN in the repo so cross-references resolve and sync-upstream keeps
# them current. Override with RULES_INSTALL_NO_EXCLUDE=1 to install everything.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET_DIR="${HOME}/.claude/rules"
EXCLUDE_FILE="${SCRIPT_DIR}/.install-exclude"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

ALL_LANGS=(typescript python golang swift php java kotlin cpp perl rust csharp)

# Load exclude list (paths relative to rules/, one per line; '#' comments and
# blank lines ignored). Absent/empty file or RULES_INSTALL_NO_EXCLUDE=1 → no
# exclusions (install everything).
EXCLUDES=()
if [[ "${RULES_INSTALL_NO_EXCLUDE:-0}" != "1" && -f "$EXCLUDE_FILE" ]]; then
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"                          # strip trailing comment
    line="${line#"${line%%[![:space:]]*}"}"     # ltrim
    line="${line%"${line##*[![:space:]]}"}"      # rtrim
    [[ -z "$line" ]] && continue
    # Strict shape: exactly <dir>/<file>, each a single path segment of
    # [A-Za-z0-9._-] (no leading/trailing slash, no subdirs, no "."/".."
    # segments). This is all real rule layout needs (rules/<dir>/<file>.md) and
    # structurally forecloses the whole path-traversal / intermediate-symlink
    # class before the rm -f below — a hostile or typo'd entry can never escape
    # ~/.claude/rules. (Symlinked <dir> itself is caught in install_dir.)
    if [[ ! "$line" =~ ^[A-Za-z0-9_-][A-Za-z0-9._-]*/[A-Za-z0-9_-][A-Za-z0-9._-]*$ ]] \
       || [[ "$line" == *".."* ]]; then
      echo -e "${RED}WARNING: ignoring unsafe exclude entry: ${line}${NC}" >&2
      continue
    fi
    EXCLUDES+=("$line")
  done < "$EXCLUDE_FILE"
fi

install_dir() {
  local name="$1"
  local src="${SCRIPT_DIR}/${name}"
  local dst="${TARGET_DIR}/${name}"

  if [[ ! -d "$src" ]]; then
    echo -e "${RED}ERROR: ${name}/ not found in ${SCRIPT_DIR}${NC}"
    return 1
  fi

  mkdir -p "$dst"

  # Physical containment: the fully-resolved install dir (pwd -P follows every
  # symlink — leaf, ancestor like a symlinked ~/.claude, or intermediate) MUST
  # stay under the resolved $HOME. A legitimately symlinked ~/.claude that lives
  # under $HOME (dotfiles repos) passes; a symlink escaping outside $HOME is
  # rejected, so neither the cp below nor the exclusion rm can touch files
  # outside the operator's home tree. Fail-CLOSED on unresolvable paths.
  local home_real dst_real
  home_real="$(cd "$HOME" 2>/dev/null && pwd -P)" || home_real=""
  dst_real="$(cd "$dst" 2>/dev/null && pwd -P)" || dst_real=""
  if [[ -z "$home_real" || -z "$dst_real" || ( "$dst_real/" != "$home_real/"* && "$dst_real" != "$home_real" ) ]]; then
    echo -e "${RED}ERROR: install dir ${dst} resolves outside \$HOME (${dst_real:-unresolved}) — refusing${NC}" >&2
    return 1
  fi

  cp -r "$src"/. "$dst"/

  # Prune any excluded paths that fall under this just-installed dir. Removal is
  # contained by construction, not by a runtime path check: every entry is a
  # validated <dir>/<file> pair (strict-shape regex above rejects absolute
  # paths, ".." and any intermediate component), and this <dir> ($dst) was just
  # confirmed non-symlink above — so "${TARGET_DIR}/${excl}" can only ever be a
  # real file directly inside a real install dir. Only count an exclusion when
  # the file existed and is gone afterward; any failure is fail-CLOSED.
  local excl target skipped=0
  for excl in ${EXCLUDES[@]+"${EXCLUDES[@]}"}; do
    [[ "$excl" == "${name}/"* ]] || continue
    target="${TARGET_DIR}/${excl}"
    [[ -e "$target" ]] || continue
    if ! rm -f -- "$target" || [[ -e "$target" ]]; then
      echo -e "${RED}ERROR: failed to exclude ${excl} (still present at ${target})${NC}" >&2
      return 1
    fi
    skipped=$((skipped + 1))
  done

  if [[ "$skipped" -gt 0 ]]; then
    echo -e "${GREEN}  ✓ ${name}/${NC} ${YELLOW}(${skipped} excluded — see rules/.install-exclude)${NC}"
  else
    echo -e "${GREEN}  ✓ ${name}/${NC}"
  fi
}

echo "Installing busdriver rules → ${TARGET_DIR}"
if [[ "${#EXCLUDES[@]}" -gt 0 ]]; then
  echo -e "${YELLOW}Excluding ${#EXCLUDES[@]} rule(s) per rules/.install-exclude (RULES_INSTALL_NO_EXCLUDE=1 to install all).${NC}"
fi
echo ""

# Always install common
install_dir "common"

if [[ $# -eq 0 ]]; then
  echo ""
  echo -e "${YELLOW}Tip: Pass language names to install language-specific rules:${NC}"
  echo "  ./install.sh typescript python golang"
  exit 0
fi

if [[ "$1" == "--all" ]]; then
  for lang in "${ALL_LANGS[@]}"; do
    install_dir "$lang"
  done
else
  for lang in "$@"; do
    install_dir "$lang"
  done
fi

echo ""
echo -e "${GREEN}Done.${NC}"
