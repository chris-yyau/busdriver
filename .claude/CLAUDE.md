# Busdriver Plugin

## Version Sync

Version numbers are managed across three manifests (declared in `.version-bump.json`):

- `package.json` — `version` field
- `.claude-plugin/plugin.json` — `version` field
- `.claude-plugin/marketplace.json` — `version` field (inside `plugins[0]`)

**Automated (preferred):** semantic-release bumps all manifests via `@semantic-release/exec` → `bump-version.sh` on every merge to main. No manual version management needed.

**Manual escape hatch:** `./scripts/release.sh VERSION` for local releases.

**Drift detection:** `./scripts/bump-version.sh --check` runs in CI on PRs to catch version desync.
