---
name: diff-aware-qa
description: Diff-aware QA routing loaded alongside e2e-runner agent to auto-detect affected pages from git diff and target testing
targets: e2e-runner agent
type: supplement
source: gstack /qa
added: 2026-03-23
---

# Diff-Aware QA Routing

> Load alongside `e2e-runner` agent to enable targeted testing based on code changes.

## When to Apply

When the e2e-runner is invoked on a feature branch without a specific URL or test target, use diff-aware routing instead of running the full test suite.

## Process

### 1. Analyze the Diff

```bash
# Get changed files on this branch vs base
# Use origin/main or origin/master as remote-tracking refs (works without local branch)
# Falls back to diffing all uncommitted changes if no remote base found
BASE_REF=$(git rev-parse --verify origin/main 2>/dev/null || git rev-parse --verify origin/master 2>/dev/null) || { echo "No remote base branch found — diffing all tracked files"; git diff --name-only HEAD; exit 0; }
git diff --name-only "$(git merge-base HEAD "$BASE_REF")...HEAD"
```

### 2. Map Files to Pages/Routes

| File pattern | Likely affected routes |
|---|---|
| `app/**/page.tsx` | Route = dir path minus `app/` and `/page.tsx` (e.g., `app/dashboard/page.tsx` → `/dashboard`) |
| `pages/**/*.tsx` | Route = file path minus `pages/` and extension, `index` → `/` (e.g., `pages/about.tsx` → `/about`) |
| `components/**` | Grep for imports → find which pages use the component |
| `lib/**`, `utils/**` | Grep for imports → find which pages/API routes use them |
| `api/**`, `app/api/**` | API route match → find which pages call that API |
| `styles/**`, `*.css` | Grep for imports → visual regression on importing pages |
| `middleware.*` | All routes potentially affected |
| `*.config.*` | All routes potentially affected |

### 3. Detect Running Local App

Before launching tests, check if a dev server is already running:

```bash
# Check common dev server ports
# Check if any common dev port is listening (any HTTP response = server is up)
for port in 3000 3001 4000 5173 5174 8000 8080; do
  if curl -s -o /dev/null -w "" --connect-timeout 1 "http://localhost:$port" 2>/dev/null; then
    echo "App detected on port $port"
    break
  fi
done
```

If no server is running, check `package.json` for the dev command and suggest starting it.

### 4. Prioritize Test Targets

Order affected pages by risk:

1. **Pages with direct file changes** — highest confidence of impact
2. **Pages importing changed components** — high confidence
3. **Pages calling changed API routes** — medium confidence
4. **All pages** (if middleware/config changed) — broad impact, run full suite

### 5. Report Scope

Before running tests, report the diff-aware scope:

```
Diff-Aware QA Scope:
- Branch: feature/xyz vs main
- Changed files: 12
- Affected routes: 4 identified
  1. /dashboard (direct: app/dashboard/page.tsx changed)
  2. /settings (component: UserProfile imported)
  3. /profile (depends on: /api/users which changed — test the UI page, not the API endpoint directly)
- Skipped routes: 23 (no diff impact detected)
```

## Limitations

- Component-level mapping requires static import analysis (may miss dynamic imports)
- API route mapping may miss indirect dependencies
- When in doubt, include the route (false positive > false negative for QA)
