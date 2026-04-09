# Busdriver Plugin

## Version Sync

When bumping the version (for releases, PRs, or `chore: bump version` commits), **always update all three manifests together**:

- `package.json` — `version` field
- `.claude-plugin/plugin.json` — `version` field
- `.claude-plugin/marketplace.json` — `version` field (inside `plugins[0]`)

All three must match. After bumping, create an annotated git tag: `git tag -a v{version} -m "v{version}: {description}"`.
