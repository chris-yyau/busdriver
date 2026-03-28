# Test Setup Skill Implementation Plan

<!-- design-reviewed: PASS -->

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Create a busdriver skill that bootstraps test infrastructure (framework, config, smoke test, template test) for repos with testable code but no tests.

**Architecture:** Single SKILL.md file containing all detection logic, installation instructions, and output templates organized by phase (0-4). The skill is a prompt-based guide — Claude reads the SKILL.md and executes the phases in the target repo. No scripts or compiled code.

**Tech Stack:** Markdown skill (SKILL.md), busdriver plugin conventions

**Spec:** `docs/superpowers/specs/2026-03-28-test-setup-design.md`

---

### Task 1: Create SKILL.md Skeleton with Frontmatter and Phase 0

**Files:**
- Create: `skills/test-setup/SKILL.md`

- [ ] **Step 1: Create the skill directory and SKILL.md with frontmatter + Phase 0**

```markdown
---
name: test-setup
description: Bootstrap test infrastructure for repos with no tests — detects language and framework, installs test runner + coverage provider, creates config, and generates a smoke test + gold-standard template test. Use when onboarding a repo or starting a new project.
origin: busdriver
---

# Test Setup

Bootstrap test infrastructure for repos with testable code but no tests. Detects language and framework, installs the test runner + coverage provider, creates config, and generates a smoke test + gold-standard template test.

## When to Use

- Onboarding an existing repo that has application code but no test suite
- Starting a new project and want test infrastructure from the start
- CI audit found missing test infrastructure (e.g., Codecov marked N/A)

## Phase 0: Precondition Check

Before running detection, verify the repo has testable application code.

**A repo is "testable" when BOTH conditions are met:**
1. At least one language config file exists: `package.json`, `go.mod`, `Cargo.toml`, `pyproject.toml`, `setup.py`, `requirements.txt`, `Package.swift`, or a `*.xcodeproj` directory
2. At least one non-test source file exists in that language (`.ts`, `.tsx`, `.js`, `.jsx`, `.py`, `.go`, `.rs`, `.swift`)

**Exclude from source file count:** `node_modules/`, `vendor/`, `.git/`, `dist/`, `build/`, generated files.

**If neither condition is met**, stop and report:
> "This repo has no testable application code. Test infrastructure is not applicable. Consider shellcheck for shell scripts or JSON schema validation for config files."
```

- [ ] **Step 2: Verify file exists and frontmatter is valid**

Run: `head -5 skills/test-setup/SKILL.md`
Expected: Shows the `---` frontmatter block with name, description, origin

- [ ] **Step 3: Commit**

```bash
git add skills/test-setup/SKILL.md
git commit -m "feat: add test-setup skill skeleton with Phase 0 precondition check"
```

---

### Task 2: Add Phase 1 — Language Detection

**Files:**
- Modify: `skills/test-setup/SKILL.md`

- [ ] **Step 1: Add Phase 1a (Language Detection) after Phase 0**

```markdown
## Phase 1: Detection

### 1a. Language Detection

Detect languages in order of confidence. Check config files first (highest signal), then fall back to file extension counts.

**Primary signal — config files:**

| Config File | Language |
|-------------|----------|
| `package.json` | TypeScript/JavaScript |
| `go.mod` | Go |
| `Cargo.toml` | Rust |
| `pyproject.toml`, `setup.py`, `requirements.txt` | Python |
| `Package.swift`, `*.xcodeproj` (directory, not file) | Swift |

**Fallback — file extension count** (when no config file found for a language):

| Extensions | Language |
|------------|----------|
| `.ts`, `.tsx`, `.js`, `.jsx` | TypeScript/JavaScript |
| `.go` | Go |
| `.rs` | Rust |
| `.py` | Python |
| `.swift` | Swift |

**Mixed repos:** Detect ALL languages present. Scope each language's setup to its root directory:
- Find the nearest config file (`package.json`, `go.mod`, etc.) and treat that directory as the language root.
- Example: `package.json` at repo root + `go.mod` in `services/api/` → run TS setup at root, Go setup scoped to `services/api/`.
- Each language gets independent detection, installation, and output. They do not share test directories or configs.
```

- [ ] **Step 2: Verify the section renders correctly**

Run: `grep -c "Language Detection" skills/test-setup/SKILL.md`
Expected: At least 1 match

- [ ] **Step 3: Commit**

```bash
git add skills/test-setup/SKILL.md
git commit -m "feat(test-setup): add Phase 1a language detection"
```

---

### Task 3: Add Phase 1b — Framework Detection

**Files:**
- Modify: `skills/test-setup/SKILL.md`

- [ ] **Step 1: Add Phase 1b (Framework Detection) after 1a**

```markdown
### 1b. Framework Detection

After detecting the language, inspect dependency declarations for framework-specific packages. The detected framework determines which test patterns the template test will demonstrate.

**TypeScript/JavaScript** (check `dependencies` + `devDependencies` in `package.json`):

| Dependency | Framework | Template test approach |
|------------|-----------|----------------------|
| `express` | Express | supertest route tests |
| `next` | Next.js | Route handler tests, API route tests |
| `hono` | Hono | Hono test client |
| `fastify` | Fastify | `app.inject()` tests |
| None matched | Generic | Export/function-level unit tests |

**Python** (check `pyproject.toml` `[project.dependencies]` or `requirements.txt`):

| Dependency | Framework | Template test approach |
|------------|-----------|----------------------|
| `fastapi` | FastAPI | TestClient, dependency overrides |
| `django` | Django | TestCase, Client, model tests |
| `flask` | Flask | Test client, route tests |
| None matched | Generic | Module/function-level tests |

**Go** (check `require` block in `go.mod`):

| Dependency | Framework | Template test approach |
|------------|-----------|----------------------|
| `github.com/gin-gonic/gin` | Gin | httptest + gin test context |
| `github.com/go-chi/chi` | Chi | httptest + chi router |
| `net/http` (stdlib) | Stdlib | httptest handler tests |
| None matched | Generic | Table-driven function tests |

**Rust** (check `[dependencies]` in `Cargo.toml`):

| Dependency | Framework | Template test approach |
|------------|-----------|----------------------|
| `actix-web` | Actix | `actix_web::test`, `TestRequest` |
| `axum` | Axum | Tower service tests |
| None matched | Generic | `#[cfg(test)]` module tests |

**Swift** (check `Package.swift` dependencies or project structure):

| Signal | Framework | Template test approach |
|--------|-----------|----------------------|
| SwiftUI imports + `*.xcodeproj` dir | SwiftUI app | ViewInspector, `@Observable` state tests |
| `Package.swift` (library) | Swift package | XCTest module tests |
| Vapor in dependencies | Vapor | `XCTVapor` request tests |
```

- [ ] **Step 2: Commit**

```bash
git add skills/test-setup/SKILL.md
git commit -m "feat(test-setup): add Phase 1b framework detection"
```

---

### Task 4: Add Phase 1c — Existing Test Detection

**Files:**
- Modify: `skills/test-setup/SKILL.md`

- [ ] **Step 1: Add Phase 1c (Existing Test Detection) after 1b**

```markdown
### 1c. Existing Test Detection

Before installing, check if test infrastructure already exists for each detected language. Skip or fill gaps as needed.

**Signals to check:**

| Signal | Means |
|--------|-------|
| Test directories (`__tests__/`, `tests/`, `test/`, `*_test.go` files) | Tests may exist |
| Test config files (`vitest.config.*`, `jest.config.*`, `pytest.ini`, `pyproject.toml` with `[tool.pytest]`) | Test framework configured |
| Test scripts in `package.json` (`"test"`, `"test:coverage"`) or Makefile (`test:` target) | Test runner registered |
| Coverage config (`.coveragerc`, `.nycrc`, `codecov.yml`) | Coverage already set up |

**Decision rules:**

| Config exists | Test dir exists | Test script exists | Action |
|:---:|:---:|:---:|---|
| Yes | Yes | Yes | **Skip** — fully set up |
| Yes | No | — | **Create directory only**, keep existing config |
| No | Yes | — | **Create config only**, keep existing directory |
| — | — | No (but config + dir exist) | **Add script only** |
| No | No | No | **Full setup** |

Proceed automatically in all cases (no user prompt). Report what was created vs. what was skipped.
```

- [ ] **Step 2: Commit**

```bash
git add skills/test-setup/SKILL.md
git commit -m "feat(test-setup): add Phase 1c existing test detection with partial setup rules"
```

---

### Task 5: Add Phase 2 — Installation

**Files:**
- Modify: `skills/test-setup/SKILL.md`

- [ ] **Step 1: Add Phase 2 (Installation) with package manager detection and per-language instructions**

```markdown
## Phase 2: Installation

Install the test framework and coverage provider for each detected language. If installation fails (network, permissions, version conflict), stop and report the error — do not proceed to Phase 3.

### Package Manager Detection (TypeScript/JavaScript)

Detect the package manager from the lock file. Fall back to npm.

| Lock File | Package Manager | Install Command |
|-----------|----------------|-----------------|
| `bun.lockb` or `bun.lock` | bun | `bun add -D vitest @vitest/coverage-v8` |
| `pnpm-lock.yaml` | pnpm | `pnpm add -D vitest @vitest/coverage-v8` |
| `yarn.lock` | yarn | `yarn add -D vitest @vitest/coverage-v8` |
| `package-lock.json` or none | npm | `npm install -D vitest @vitest/coverage-v8` |

### Per-Language Installation

#### TypeScript/JavaScript

1. Install vitest + coverage provider via detected package manager
2. Create `vitest.config.ts`:

```typescript
import { defineConfig } from 'vitest/config'

export default defineConfig({
  test: {
    coverage: {
      provider: 'v8',
      reporter: ['text', 'lcov'],  // lcov for Codecov compatibility
      exclude: ['node_modules/', 'dist/', '**/*.config.*'],
    },
  },
})
```

3. Add to `package.json` scripts:
   - `"test": "vitest run"`
   - `"test:coverage": "vitest run --coverage"`
4. Create `__tests__/` directory

#### Python

1. Determine installation method:
   - `pyproject.toml` exists → add `pytest` and `pytest-cov` to `[project.optional-dependencies]` dev group, run `pip install -e ".[dev]"`
   - No `pyproject.toml` → create `requirements-dev.txt` with `pytest` and `pytest-cov`, run `pip install -r requirements-dev.txt`
2. If `$VIRTUAL_ENV` is unset, warn: "No virtual environment detected. Consider `python -m venv .venv` first." Proceed anyway.
3. Add pytest config to `pyproject.toml` (create or append):

```toml
[tool.pytest.ini_options]
testpaths = ["tests"]
addopts = "--cov --cov-report=xml --cov-report=term"
```

4. Create `tests/` directory with `__init__.py` and `conftest.py`

#### Go

1. No installation needed (testing is built-in)
2. If `Makefile` exists, add targets:

```makefile
test:
	go test ./...

test-coverage:
	go test -coverprofile=coverage.out ./... && go tool cover -html=coverage.out -o coverage.html
```

3. No separate test directory — Go test files go alongside source files (`*_test.go`)

#### Rust

1. No test framework installation needed (built-in `#[test]`)
2. Attempt coverage tool install:
   ```bash
   cargo install cargo-llvm-cov
   ```
   If install fails, warn: "cargo-llvm-cov not installed. Tests will work but coverage reports require it. Install manually or use CI-only coverage." Continue with setup.
3. Create `tests/` directory for integration tests

#### Swift

1. XCTest is built-in — no installation needed
2. For `Package.swift` projects: add test target if missing:
   ```swift
   .testTarget(name: "AppTests", dependencies: ["App"])
   ```
3. For Xcode projects: verify test target exists, warn if missing (cannot auto-create Xcode test targets reliably)
4. Create `Tests/AppTests/` directory structure
```

- [ ] **Step 2: Commit**

```bash
git add skills/test-setup/SKILL.md
git commit -m "feat(test-setup): add Phase 2 installation with package manager detection"
```

---

### Task 6: Add Phase 3A — Smoke Test Templates

**Files:**
- Modify: `skills/test-setup/SKILL.md`

- [ ] **Step 1: Add Phase 3 header and smoke test section with all 5 language templates**

```markdown
## Phase 3: Output Files

### A. Smoke Test

Generate one real, runnable test that proves the app can be imported without crashing.

**Scope:** Import-only. Does NOT start servers, connect to databases, or trigger side effects. If the app performs side effects on import (e.g., `mongoose.connect()` at module level), the smoke test will fail — report this with the suggestion: "Your app performs side effects on import. Consider wrapping startup logic in a function."

**File placement:**

| Language | Smoke test file |
|----------|----------------|
| TypeScript/JS | `__tests__/smoke.test.ts` |
| Python | `tests/test_smoke.py` |
| Go | `smoke_test.go` (in root package) |
| Rust | `tests/smoke.rs` |
| Swift | `Tests/AppTests/SmokeTests.swift` |

**Templates:**

<details><summary>TypeScript/JavaScript</summary>

```typescript
import { describe, it, expect } from 'vitest'

describe('smoke', () => {
  it('main module imports without error', async () => {
    const mod = await import('../src/index')
    expect(mod).toBeDefined()
  })
})
```

Adjust the import path (`../src/index`) to match the actual entry point found in `package.json` `"main"` or `"exports"` field.

</details>

<details><summary>Python</summary>

```python
def test_smoke():
    """Verify the main package can be imported."""
    import app  # noqa: F401
```

Adjust `import app` to match the actual package name (the top-level directory containing `__init__.py`, or the module name from `pyproject.toml`).

</details>

<details><summary>Go</summary>

```go
package main

import "testing"

func TestSmoke(t *testing.T) {
    // Verify the package compiles and main symbols are accessible.
    // If this test fails, the package has a build error.
    t.Log("smoke test: package compiles successfully")
}
```

Place in the root package directory. Adjust `package main` to match the actual package name if different.

</details>

<details><summary>Rust</summary>

```rust
#[test]
fn smoke() {
    // Verify the crate compiles and can be used as a dependency.
    // If this fails, there is a build error in the main crate.
    assert!(true, "crate compiles successfully");
}
```

Place as `tests/smoke.rs` (integration test). The crate name is auto-resolved from `Cargo.toml`.

</details>

<details><summary>Swift</summary>

```swift
import XCTest
@testable import App

final class SmokeTests: XCTestCase {
    func testSmoke() {
        // Verify the module can be imported without error.
        XCTAssertTrue(true, "Module imports successfully")
    }
}
```

Adjust `@testable import App` to match the actual module/target name from `Package.swift` or the Xcode project.

</details>
```

- [ ] **Step 2: Commit**

```bash
git add skills/test-setup/SKILL.md
git commit -m "feat(test-setup): add Phase 3A smoke test templates for all 5 languages"
```

---

### Task 7: Add Phase 3B — Gold-Standard Template Tests

**Files:**
- Modify: `skills/test-setup/SKILL.md`

- [ ] **Step 1: Add template test section with framework-specific examples**

```markdown
### B. Gold-Standard Template Test

Generate one heavily commented test file showing the right patterns for the detected language+framework. Contains 2-3 real implemented tests (not TODOs) demonstrating:

1. **Happy path** — basic operation with expected input
2. **Error case** — how to test error handling
3. **Framework pattern** — one idiomatic framework-specific test (e.g., authenticated route, middleware)

Comments explain: import conventions, test structure, mocking approach, and where to find more patterns.

**File placement:**

| Language | Template test file | Naming rationale |
|----------|-------------------|------------------|
| TypeScript/JS | `__tests__/_template.test.ts` | Underscore sorts first |
| Python | `tests/test_template.py` | Follows pytest `test_` convention |
| Go | `example_test.go` (root package) | Go convention for examples |
| Rust | `tests/template.rs` | Integration test in `tests/` |
| Swift | `Tests/AppTests/TemplateTests.swift` | XCTest naming convention |

**Generate the template based on the detected framework.** Use the framework detection from Phase 1b to select the right test patterns. The template must use the actual framework's test helpers (e.g., supertest for Express, TestClient for FastAPI, httptest for Go stdlib).

**References to include in template comments:**
- `busdriver:tdd` — for generating tests for specific modules
- Language-specific testing skill — `busdriver:golang-testing`, `busdriver:python-testing`, `busdriver:rust-testing`, etc.

<details><summary>TypeScript/JavaScript — Express example</summary>

```typescript
/**
 * TEMPLATE TEST — Copy this file as a starting point for new test files.
 *
 * Pattern: supertest + vitest for Express route testing.
 * Run: npm test
 * Coverage: npm run test:coverage
 *
 * For full TDD workflow, use `busdriver:tdd` to generate tests for specific modules.
 * For more patterns, see `busdriver:coding-standards`.
 */
import { describe, it, expect } from 'vitest'
import request from 'supertest'
import { app } from '../src/app'

describe('GET /health', () => {
  // Happy path: verify the endpoint returns expected shape
  it('returns 200 with status ok', async () => {
    const res = await request(app).get('/health')
    expect(res.status).toBe(200)
    expect(res.body).toEqual({ status: 'ok' })
  })

  // Error case: verify proper error response format
  it('returns 404 for unknown routes', async () => {
    const res = await request(app).get('/nonexistent')
    expect(res.status).toBe(404)
  })

  // Framework pattern: testing with auth header
  it('authenticated route returns 401 without token', async () => {
    const res = await request(app).get('/api/protected')
    expect(res.status).toBe(401)
  })
})
```

</details>

<details><summary>TypeScript/JavaScript — Generic (no framework)</summary>

```typescript
/**
 * TEMPLATE TEST — Copy this file as a starting point for new test files.
 *
 * Pattern: vitest for unit testing exported functions.
 * Run: npm test
 * Coverage: npm run test:coverage
 *
 * For full TDD workflow, use `busdriver:tdd`.
 */
import { describe, it, expect } from 'vitest'
// import { yourFunction } from '../src/utils'

describe('yourFunction', () => {
  // Happy path
  it('returns expected result for valid input', () => {
    // const result = yourFunction('valid')
    // expect(result).toBe(expected)
    expect(true).toBe(true) // Replace with real test
  })

  // Error case
  it('throws on invalid input', () => {
    // expect(() => yourFunction(null)).toThrow()
    expect(true).toBe(true) // Replace with real test
  })
})
```

</details>

<details><summary>Python — FastAPI example</summary>

```python
"""
TEMPLATE TEST — Copy this file as a starting point for new test files.

Pattern: pytest + TestClient for FastAPI endpoint testing.
Run: pytest
Coverage: pytest --cov

For full TDD workflow, use `busdriver:tdd`.
For more patterns, see `busdriver:python-testing`.
"""
from fastapi.testclient import TestClient
from app.main import app

client = TestClient(app)


# Happy path: verify endpoint returns expected shape
def test_health_returns_ok():
    response = client.get("/health")
    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


# Error case: verify proper error response
def test_unknown_route_returns_404():
    response = client.get("/nonexistent")
    assert response.status_code == 404


# Framework pattern: dependency override for testing
def test_with_dependency_override():
    """Example of overriding a FastAPI dependency for testing."""
    # from app.dependencies import get_db
    # def mock_db():
    #     return FakeDB()
    # app.dependency_overrides[get_db] = mock_db
    # response = client.get("/items")
    # app.dependency_overrides.clear()
    assert True  # Replace with real test
```

</details>

<details><summary>Go — net/http example</summary>

```go
// Template test — copy this file as a starting point for new test files.
//
// Pattern: table-driven tests with httptest for HTTP handler testing.
// Run: make test (or go test ./...)
// Coverage: make test-coverage
//
// For full TDD workflow, use `busdriver:tdd`.
// For more patterns, see `busdriver:golang-testing`.

package main

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

// Happy path: verify handler returns expected status.
func TestHealthHandler(t *testing.T) {
	req := httptest.NewRequest(http.MethodGet, "/health", nil)
	w := httptest.NewRecorder()
	healthHandler(w, req)

	if w.Code != http.StatusOK {
		t.Errorf("expected 200, got %d", w.Code)
	}
}

// Error case: table-driven test pattern for multiple inputs.
func TestHealthHandler_EdgeCases(t *testing.T) {
	tests := []struct {
		name   string
		method string
		want   int
	}{
		{"GET returns 200", http.MethodGet, http.StatusOK},
		{"POST returns 405", http.MethodPost, http.StatusMethodNotAllowed},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			req := httptest.NewRequest(tt.method, "/health", nil)
			w := httptest.NewRecorder()
			healthHandler(w, req)
			if w.Code != tt.want {
				t.Errorf("expected %d, got %d", tt.want, w.Code)
			}
		})
	}
}
```

</details>

<details><summary>Rust — Generic example</summary>

```rust
//! TEMPLATE TEST — Copy this file as a starting point for new integration tests.
//!
//! Pattern: integration test in tests/ directory.
//! Run: cargo test
//! Coverage: cargo llvm-cov
//!
//! For full TDD workflow, use `busdriver:tdd`.
//! For more patterns, see `busdriver:rust-testing`.

// use your_crate::your_function;

// Happy path: verify function returns expected result
#[test]
fn test_happy_path() {
    // let result = your_function("valid input");
    // assert_eq!(result, expected);
    assert!(true, "Replace with real test");
}

// Error case: verify error handling
#[test]
fn test_error_case() {
    // let result = your_function("");
    // assert!(result.is_err());
    assert!(true, "Replace with real test");
}
```

</details>

<details><summary>Swift — XCTest example</summary>

```swift
/// TEMPLATE TEST — Copy this file as a starting point for new test files.
///
/// Pattern: XCTest for unit testing.
/// Run: swift test (SPM) or xcodebuild test (Xcode)
///
/// For full TDD workflow, use `busdriver:tdd`.
import XCTest
@testable import App

final class TemplateTests: XCTestCase {

    // Happy path: verify function returns expected result
    func testHappyPath() {
        // let result = yourFunction("valid")
        // XCTAssertEqual(result, expected)
        XCTAssertTrue(true, "Replace with real test")
    }

    // Error case: verify error handling
    func testErrorCase() {
        // XCTAssertThrowsError(try yourFunction(nil))
        XCTAssertTrue(true, "Replace with real test")
    }
}
```

</details>

Adapt all import paths and function names to match the actual codebase. The template is a starting point — the tests should compile and pass as-is (with placeholder assertions), so the developer can immediately see the pattern and replace with real tests.
```

- [ ] **Step 2: Commit**

```bash
git add skills/test-setup/SKILL.md
git commit -m "feat(test-setup): add Phase 3B gold-standard template tests for all languages"
```

---

### Task 8: Add Phase 4 — Post-Setup

**Files:**
- Modify: `skills/test-setup/SKILL.md`

- [ ] **Step 1: Add Phase 4 (Post-Setup) with test execution, error handling, and reporting**

```markdown
## Phase 4: Post-Setup

After generating all files, verify the setup works end-to-end.

### 4a. Run the Tests

Execute the test command for the detected language:

| Language | Command |
|----------|---------|
| TypeScript/JS | `npm test` (or `yarn test` / `pnpm test` / `bun test` per detected package manager) |
| Python | `pytest tests/` |
| Go | `go test ./...` |
| Rust | `cargo test` |
| Swift | `swift test` (SPM) or `xcodebuild test` (Xcode) |

### 4b. Handle Results

| Result | Action |
|--------|--------|
| **All tests pass** | Report success, show coverage baseline, proceed to 4c |
| **Smoke test fails — import side effects** | Report: "Your app performs side effects on import (e.g., DB connections, env vars). Consider wrapping startup logic in a function. The smoke test verifies import-only." |
| **Smoke test fails — missing dependencies** | Report: "Install missing dependencies first, then re-run `/test-setup`." |
| **Template test fails** | Report as informational (not an error): "The template test references example endpoints/functions. Adapt it to your actual code." |
| **Installation failed** | Report the error (network, permissions, version conflict). Do not generate output files. |

### 4c. Report Summary

Show a summary of everything that happened:

```
## Test Setup Complete

**Language:** TypeScript (Express)
**Package manager:** npm

**Created:**
- vitest.config.ts (coverage: v8, reporter: lcov)
- package.json scripts: test, test:coverage
- __tests__/smoke.test.ts (1 test, passing)
- __tests__/_template.test.ts (3 tests, passing)

**Skipped:** (nothing — full setup)

**Test results:** 4 tests passing
**Coverage baseline:** 12.3%

**Next steps:**
- Wire coverage in your CI workflow
- Use `busdriver:tdd` when ready to write tests for specific modules
```
```

- [ ] **Step 2: Commit**

```bash
git add skills/test-setup/SKILL.md
git commit -m "feat(test-setup): add Phase 4 post-setup with test execution and reporting"
```

---

### Task 9: Add Orchestrator Route

**Files:**
- Modify: `skills/orchestrator/SKILL.md`

- [ ] **Step 1: Find the Non-Pipeline Tasks table in the orchestrator**

Run: `grep -n "Non-Pipeline Tasks" skills/orchestrator/SKILL.md`
Expected: Line number of the section

- [ ] **Step 2: Add a row to the Non-Pipeline Tasks table**

Add the following row to the table after the **Research** row (or wherever alphabetically appropriate):

```markdown
| **Test infrastructure** | test setup, scaffold tests, add tests | `test-setup` |
```

- [ ] **Step 3: Verify the row was added**

Run: `grep "Test infrastructure" skills/orchestrator/SKILL.md`
Expected: Shows the new row

- [ ] **Step 4: Commit**

```bash
git add skills/orchestrator/SKILL.md
git commit -m "feat(orchestrator): add test-setup to Non-Pipeline Tasks routing table"
```

---

### Task 10: Update ci-pipeline-setup Audit Logic (Personal Skill)

**Files:**
- Modify: `~/.claude/skills/ci-pipeline-setup/SKILL.md` (line ~85, `Codecov config` row)

**Note:** This is a personal skill, not part of busdriver. The change is documented here for completeness but should be applied separately.

- [ ] **Step 1: Find the Codecov audit row**

Run: `grep -n "N/A for non-coverage repos" ~/.claude/skills/ci-pipeline-setup/SKILL.md`
Expected: Line ~85 showing the current Codecov config check

- [ ] **Step 2: Replace the "N/A" check with three-way detection**

Change:
```
| Codecov config | `[ -f codecov.yml ]` | File exists (N/A for non-coverage repos) |
```

To:
```
| Codecov config | See below | Three-way check |
```

And add a note after the table:

```markdown
**Codecov detection logic:**
1. Has test script (`"test"` in package.json / Makefile `test:` target / `go test` / `cargo test`) AND coverage config (`codecov.yml`, `.coveragerc`, vitest coverage config) → **wire Codecov**
2. Has source files (`.ts`/`.py`/`.go`/`.rs`/`.swift`) but no test infrastructure → **`Codecov | ❌ — set up test infrastructure first`**
3. No source files (markdown, JSON, shell only) → **`Codecov | N/A`**
```

- [ ] **Step 3: Verify the change**

Run: `grep "set up test infrastructure" ~/.claude/skills/ci-pipeline-setup/SKILL.md`
Expected: Shows the new three-way check text

- [ ] **Step 4: Commit**

```bash
git add ~/.claude/skills/ci-pipeline-setup/SKILL.md
git commit -m "feat(ci-pipeline-setup): add three-way Codecov detection replacing N/A default"
```

---

### Task 11: Final Verification

**Files:**
- Read: `skills/test-setup/SKILL.md`
- Read: `skills/orchestrator/SKILL.md`

- [ ] **Step 1: Verify SKILL.md has all phases**

Run: `grep "^## Phase" skills/test-setup/SKILL.md`
Expected:
```
## Phase 0: Precondition Check
## Phase 1: Detection
## Phase 2: Installation
## Phase 3: Output Files
## Phase 4: Post-Setup
```

- [ ] **Step 2: Verify frontmatter is valid**

Run: `head -5 skills/test-setup/SKILL.md`
Expected: Shows `name: test-setup`, `description: Bootstrap...`, `origin: busdriver`

- [ ] **Step 3: Verify orchestrator has the route**

Run: `grep "test-setup" skills/orchestrator/SKILL.md`
Expected: Shows the Non-Pipeline Tasks table row

- [ ] **Step 4: Verify no broken references**

Run: `grep -c "busdriver:tdd" skills/test-setup/SKILL.md`
Expected: Multiple matches (template test comments reference it)

Run: `grep -c "ci-pipeline-setup" skills/test-setup/SKILL.md`
Expected: 0 (loose coupling — no hard reference)

- [ ] **Step 5: Final commit (if any fixes needed)**

```bash
git add skills/test-setup/SKILL.md skills/orchestrator/SKILL.md
git commit -m "chore(test-setup): final verification pass"
```
