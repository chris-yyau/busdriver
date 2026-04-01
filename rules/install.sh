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

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET_DIR="${HOME}/.claude/rules"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

ALL_LANGS=(typescript python golang swift php java kotlin cpp perl rust csharp zh)

install_dir() {
  local name="$1"
  local src="${SCRIPT_DIR}/${name}"
  local dst="${TARGET_DIR}/${name}"

  if [[ ! -d "$src" ]]; then
    echo -e "${RED}ERROR: ${name}/ not found in ${SCRIPT_DIR}${NC}"
    return 1
  fi

  mkdir -p "$dst"
  cp -r "$src"/. "$dst"/
  echo -e "${GREEN}  ✓ ${name}/${NC}"
}

echo "Installing busdriver rules → ${TARGET_DIR}"
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
