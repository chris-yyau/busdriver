#!/usr/bin/env bash
set -euo pipefail

# Release script for bumping plugin version
# Usage: ./scripts/release.sh VERSION
#
# NOTE: On main, semantic-release handles this automatically via CI.
# This script exists as a manual escape hatch for local releases.

VERSION="${1:-}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

usage() {
  echo "Usage: $0 VERSION"
  echo "Example: $0 1.5.0"
  exit 1
}

if [[ -z "$VERSION" ]]; then
  echo "Error: VERSION argument is required"
  usage
fi

if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Error: VERSION must be in semver format (e.g., 1.5.0)"
  exit 1
fi

CURRENT_BRANCH=$(git branch --show-current)
if [[ "$CURRENT_BRANCH" != "main" ]]; then
  echo "Error: Must be on main branch (currently on $CURRENT_BRANCH)"
  exit 1
fi

if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "Error: Working tree is not clean. Commit or stash changes first."
  exit 1
fi

# Bump all declared manifests via the config-driven script
"$SCRIPT_DIR/bump-version.sh" "$VERSION"

# Stage, commit, tag, and push
git add package.json .claude-plugin/plugin.json .claude-plugin/marketplace.json
git commit -m "chore(release): $VERSION"
git tag -a "v$VERSION" -m "v$VERSION"
git push origin main "v$VERSION"

echo "Released v$VERSION"
