# Test Setup Skill Design

<!-- design-reviewed: PASS -->

> **Status:** Approved
> **Date:** 2026-03-28
> **Location:** busdriver plugin (`skills/test-setup/`)
> **Chain:** Loosely coupled with ci-pipeline-setup (personal skill) and `busdriver:tdd` command

## SKILL.md Frontmatter

```yaml
---
name: test-setup
description: Bootstrap test infrastructure for repos with no tests — detects language and framework, installs test runner + coverage provider, creates config, and generates a smoke test + gold-standard template test. Use when onboarding a repo or starting a new project.
origin: busdriver
---
```

## Problem

Repos with testable application code but no test infrastructure cannot use Codecov or participate in coverage-gated CI. The ci-pipeline-setup skill correctly marks these as "N/A" but offers no path forward. The `busdriver:tdd` command assumes test infrastructure already exists.

The gap: nothing bootstraps the local test infrastructure (framework + config + coverage provider + scripts).

## Scope

A busdriver plugin skill that detects the repo's language and framework, installs test tooling, and produces a working test setup with one smoke test and one gold-standard template test.

### In Scope

- Language and framework detection
- Test framework + coverage provider installation
- Test config file creation
- Test/coverage script registration
- Test directory structure creation
- One smoke test (real, runnable)
- One gold-standard template test (heavily commented, 2-3 implemented tests)

### Out of Scope

- Per-module test stub generation (deferred to `busdriver:tdd` on demand)
- Source code modification
- CI/CD configuration (ci-pipeline-setup's responsibility)
- Test database or external service setup
- E2E test scaffolding

## Design

### Phase 0: Precondition Check

Before running detection, verify the repo has testable application code. A repo is "testable" when:

1. At least one language config file from the Phase 1a table exists, **AND**
2. At least one non-test source file exists in that language (`.ts`, `.py`, `.go`, `.rs`, `.swift`)

Exclude from source file count: `node_modules/`, `vendor/`, `.git/`, `dist/`, `build/`, generated files.

If neither condition is met (e.g., repo is only markdown, JSON, and shell scripts), exit with:
> "This repo has no testable application code. Test infrastructure is not applicable. Consider shellcheck for shell scripts or JSON schema validation for config files."

### Phase 1: Detection

Detection runs in order of confidence. Each phase can short-circuit.

#### 1a. Language Detection

Primary signal — config files (highest confidence):

| Config File | Language |
|-------------|----------|
| `package.json` | TypeScript/JavaScript |
| `go.mod` | Go |
| `Cargo.toml` | Rust |
| `pyproject.toml`, `setup.py`, `requirements.txt` | Python |
| `Package.swift`, `*.xcodeproj` (directory) | Swift |

Note: `*.xcodeproj` is a directory, not a file. Use directory existence check, not file check.

Fallback — file extension count (when no config file found):

| Extensions | Language |
|------------|----------|
| `.ts`, `.tsx`, `.js`, `.jsx` | TypeScript/JavaScript |
| `.go` | Go |
| `.rs` | Rust |
| `.py` | Python |
| `.swift` | Swift |

**Mixed repos:** Detect all languages present. Scope each language's setup to its root directory:
- If `package.json` is at repo root and `go.mod` is in `services/api/`, run TS setup at root and Go setup scoped to `services/api/`.
- Each language gets independent detection, installation, and output — they do not share test directories or configs.
- Detect language roots by finding the nearest config file (`package.json`, `go.mod`, etc.) and treating that directory as the language root.

#### 1b. Framework Detection

Inspect dependency declarations for framework-specific packages:

**TypeScript/JavaScript** (from `package.json` dependencies + devDependencies):

| Dependency | Framework | Test approach |
|------------|-----------|---------------|
| `express` | Express | Supertest route tests |
| `next` | Next.js | Route handler tests, API route tests |
| `hono` | Hono | Hono test client |
| `fastify` | Fastify | `app.inject()` tests |
| None | Generic | Export/function-level unit tests |

**Python** (from `pyproject.toml` dependencies / `requirements.txt`):

| Dependency | Framework | Test approach |
|------------|-----------|---------------|
| `fastapi` | FastAPI | TestClient, dependency overrides |
| `django` | Django | TestCase, Client, model tests |
| `flask` | Flask | Test client, route tests |
| None | Generic | Module/function-level tests |

**Go** (from `go.mod` require):

| Dependency | Framework | Test approach |
|------------|-----------|---------------|
| `github.com/gin-gonic/gin` | Gin | httptest + gin test context |
| `github.com/go-chi/chi` | Chi | httptest + chi router |
| `net/http` imports | Stdlib | httptest handler tests |
| None | Generic | Table-driven function tests |

**Rust** (from `Cargo.toml` [dependencies]):

| Dependency | Framework | Test approach |
|------------|-----------|---------------|
| `actix-web` | Actix | `actix_web::test`, `TestRequest` |
| `axum` | Axum | Tower service tests |
| None | Generic | `#[cfg(test)]` module tests |

**Swift** (from `Package.swift` dependencies or project structure):

| Signal | Framework | Test approach |
|--------|-----------|---------------|
| SwiftUI imports + `*.xcodeproj` dir | SwiftUI app | ViewInspector, `@Observable` state tests |
| `Package.swift` (library) | Swift package | XCTest module tests |
| Vapor in dependencies | Vapor | `XCTVapor` request tests |

#### 1c. Existing Test Detection

Skip languages that already have test infrastructure:

| Signal | Means |
|--------|-------|
| Test directories (`__tests__/`, `tests/`, `test/`, `*_test.go`) | Tests may exist |
| Test config files (`vitest.config.*`, `jest.config.*`, `pytest.ini`) | Test framework configured |
| Test scripts in `package.json` (`test`, `test:coverage`) | Test runner registered |
| Coverage config (`codecov.yml`, `.coveragerc`, `.nycrc`) | Coverage already set up |

**Decision rules for partial setup:**
- Config file exists + test directory exists + test script exists → **skip** (fully set up)
- Config file exists + test directory missing → **create directory only**, keep existing config
- Test directory exists + config file missing → **create config only**, keep existing directory
- Test script missing but config + directory exist → **add script only**
- Nothing exists → **full setup**

In all partial cases, proceed automatically (no user prompt). Report what was created vs. what was skipped.

### Phase 2: Installation

#### Package Manager Detection (TypeScript/JavaScript)

Detect from lock file, fall back to npm:

| Lock File | Package Manager | Install Command |
|-----------|----------------|-----------------|
| `bun.lockb` or `bun.lock` | bun | `bun add -D vitest @vitest/coverage-v8` |
| `pnpm-lock.yaml` | pnpm | `pnpm add -D vitest @vitest/coverage-v8` |
| `yarn.lock` | yarn | `yarn add -D vitest @vitest/coverage-v8` |
| `package-lock.json` or none | npm | `npm install -D vitest @vitest/coverage-v8` |

#### Per-Language Installation

**TypeScript/JavaScript:**
- Install vitest + coverage provider via detected package manager (see above)
- Install framework-specific test helpers: Express -> `supertest`, Hono/Fastify/Next.js/Generic -> no extra dep (built-in test clients or pure unit tests)
- Creates `vitest.config.ts`:
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
- Adds to `package.json` scripts: `"test": "vitest run"`, `"test:coverage": "vitest run --coverage"`
- Creates `__tests__/` directory (or `tests/` if `__tests__` feels non-idiomatic for the project)

**Python:**
- Decision rule for installation method:
  - `pyproject.toml` with PEP 621 `[project]` section → add `pytest` and `pytest-cov` to `[project.optional-dependencies] dev` group, then run `pip install -e ".[dev]"`
  - `pyproject.toml` with Poetry (`[tool.poetry]`), PDM, or other non-PEP-621 format → fall back to `requirements-dev.txt` approach
  - No `pyproject.toml` → create `requirements-dev.txt` with `pytest` and `pytest-cov`, then run `pip install -r requirements-dev.txt`
  - If no virtual env is active (`$VIRTUAL_ENV` unset), warn: "No virtual environment detected. Consider creating one with `python -m venv .venv` first." Proceed anyway but flag the warning.
- Creates `pyproject.toml` `[tool.pytest.ini_options]` section (or appends if pyproject.toml exists):
  ```toml
  [tool.pytest.ini_options]
  testpaths = ["tests"]
  addopts = "--cov --cov-report=xml --cov-report=term"
  ```
- Creates `tests/` directory with `__init__.py` and `conftest.py`

**Go:**
- No installation needed (testing is built-in)
- If `Makefile` exists, adds targets:
  ```makefile
  test:
  	go test ./...

  test-coverage:
  	go test -coverprofile=coverage.out ./... && go tool cover -html=coverage.out -o coverage.html
  ```
- Test files go alongside source files (`*_test.go` convention) — no separate test directory

**Rust:**
- No test framework installation needed (built-in `#[test]`)
- Coverage: install `cargo-llvm-cov` locally:
  ```bash
  cargo install cargo-llvm-cov
  ```
  If install fails (e.g., missing LLVM), warn but continue: "cargo-llvm-cov not installed. Tests will work but coverage reports require it. Install manually or use CI-only coverage."
- Creates `tests/` directory for integration tests
- Unit tests go inside source files as `#[cfg(test)]` modules

**Swift:**
- XCTest is built-in
- For `Package.swift` projects: adds test target if missing:
  ```swift
  .testTarget(name: "AppTests", dependencies: ["App"])
  ```
- Creates `Tests/AppTests/` directory structure
- For Xcode projects: verifies test target exists, warns if missing (cannot auto-create Xcode test targets reliably)

### Phase 3: Output Files

#### A. Smoke Test

One real, runnable test that proves the app can be imported without crashing.

**Scope limitation:** The smoke test only verifies that the main module/entry point can be imported. It does NOT start servers, connect to databases, or trigger side effects. If the app performs side effects on import (e.g., `mongoose.connect()` at module level), the smoke test may fail — this is documented as a known limitation, and the skill reports it with a suggestion to refactor side effects behind a startup function.

**File placement per language:**

| Language | Smoke test location |
|----------|-------------------|
| TypeScript/JS | `__tests__/smoke.test.ts` |
| Python | `tests/test_smoke.py` |
| Go | `smoke_test.go` (in root package) |
| Rust | `tests/smoke.rs` (integration test) |
| Swift | `Tests/AppTests/SmokeTests.swift` |

**Examples:**

TypeScript/JS:
```typescript
import { describe, it, expect } from 'vitest'

describe('smoke', () => {
  it('main module imports without error', async () => {
    const mod = await import('../src/index')
    expect(mod).toBeDefined()
  })
})
```

Python:
```python
def test_smoke():
    """Verify the main package can be imported."""
    import app  # noqa: F401
```

Go:
```go
package main

import "testing"

func TestSmoke(t *testing.T) {
    // Verify the package compiles and main symbols are accessible.
    // If this test fails, the package has a build error.
    t.Log("smoke test: package compiles successfully")
}
```

Rust:
```rust
#[test]
fn smoke() {
    // Verify the crate compiles and can be used as a dependency.
    // If this fails, there is a build error in the main crate.
    assert!(true, "crate compiles successfully");
}
```

Swift:
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

#### B. Gold-Standard Template Test

One heavily commented test file showing the right patterns for that language+framework. Contains 2-3 real implemented tests (not TODOs) demonstrating:

1. **Happy path** — basic operation with expected input
2. **Error case** — how to test error handling
3. **Framework pattern** — one idiomatic framework-specific test

Comments explain: import conventions, test structure, mocking approach, and where to find more patterns (references `busdriver:tdd` and language-specific testing skills like `busdriver:golang-testing`, `busdriver:python-testing`, `busdriver:rust-testing`).

**File placement per language:**

| Language | Template test location | Naming rationale |
|----------|----------------------|------------------|
| TypeScript/JS | `__tests__/_template.test.ts` | Underscore sorts first in file listings |
| Python | `tests/test_template.py` | Follows pytest `test_` convention |
| Go | `example_test.go` (in root package) | Go convention for example/template tests |
| Rust | `tests/template.rs` | Integration test in `tests/` directory |
| Swift | `Tests/AppTests/TemplateTests.swift` | Follows XCTest naming convention |

**Template test example (Express + Supertest):**
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

**Template test example (Go + net/http):**
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

// Happy path: verify handler returns expected status and body.
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

### Phase 4: Post-Setup

After generating all files:

1. **Run the tests** — execute the test command for the detected language
2. **Handle results:**
   - **All pass** → report success, show coverage baseline, proceed to step 3
   - **Smoke test fails** → report failure with the error. Common causes:
     - Import side effects (DB connect, env vars) → suggest: "Your app performs side effects on import. Consider wrapping startup logic in a function."
     - Missing dependencies → suggest: "Install missing dependencies first, then re-run `/test-setup`."
   - **Template test fails** → this is expected if the template references endpoints/functions that don't exist in the actual app. Report as informational, not an error: "The template test references example endpoints. Adapt it to your actual routes."
   - **Installation fails** → report the error (network, permissions, version conflict). Do not proceed with output file generation.
3. **Report summary** — show what was created, what was skipped, test results, and coverage baseline
4. **Suggest next steps** — "Test infrastructure ready. Wire coverage in your CI workflow. Use `busdriver:tdd` when you're ready to write tests for specific modules."

## Skill Chain (Loose Coupling)

```
test-setup (busdriver, generic)        ci-pipeline-setup (personal)
    |                                        |
    | Phase 0: testable code?                | audits repo
    | Phase 1: detect lang+framework         | detects test infra exists?
    | Phase 2: install framework+coverage    |   yes → wire Codecov
    | Phase 3: smoke test + template         |   no + has source files → "set up tests first"
    | Phase 4: run tests, report             |   no source files → N/A
    | "wire coverage in CI"                  |
    |                                        |
    v                                        v
  busdriver:tdd (on demand)            Codecov reporting
    |
    | generates tests for
    | specific modules when
    | developer is ready
```

Neither skill hard-references the other by name. Each detects what it needs independently. They work together when both are present but neither breaks without the other.

## Changes to Existing Skills

| Skill | Change | Detail |
|-------|--------|--------|
| `orchestrator` | Add to Non-Pipeline Tasks table | `Test infrastructure \| test setup, scaffold tests, add tests \| test-setup` |
| `ci-pipeline-setup` (personal) | Update audit logic at line ~85 (`Codecov config` row) | Change "N/A for non-coverage repos" to three-way check: (1) has test script + coverage config → wire Codecov, (2) has source files (`.ts`/`.py`/`.go`/`.rs`/`.swift`) but no test infra → show `Codecov \| ❌ — set up test infrastructure first`, (3) no source files → `Codecov \| N/A` |
| `busdriver:tdd` | No changes | — |
| `busdriver:tdd-workflow` | No changes | — |

## Target Languages

| Language | Test Runner | Coverage Provider | Package Manager Detection |
|----------|-------------|-------------------|--------------------------|
| TypeScript/JS | vitest | @vitest/coverage-v8 | bun.lockb → bun, pnpm-lock.yaml → pnpm, yarn.lock → yarn, default → npm |
| Python | pytest | pytest-cov | pyproject.toml → `pip install -e ".[dev]"`, else → requirements-dev.txt |
| Go | go test | -coverprofile (built-in) | N/A (built-in) |
| Rust | cargo test | cargo-llvm-cov | N/A (cargo) |
| Swift | xcodebuild test / swift test | -enableCodeCoverage YES | N/A (built-in) |

## Design Decisions

1. **No per-module stubs** — Council (2026-03-28) unanimously rejected blanket stubs as automated tech debt. One template test beats 50 TODOs. Let `busdriver:tdd` generate stubs on demand.
2. **Loose coupling** — test-setup and ci-pipeline-setup don't reference each other by name. Busdriver is open-source; ci-pipeline-setup is personal.
3. **Framework detection** — smarter templates justify the detection complexity. Express supertest patterns differ significantly from generic function tests.
4. **Smoke test is import-only** — does not start servers or trigger side effects. If the app has import-time side effects, the smoke test fails and reports why. This is intentional: it surfaces a code quality issue (side effects on import).
5. **Run tests after setup** — proving the pipeline works end-to-end before the user continues. Failure is reported with actionable suggestions, not swallowed.
6. **Package manager detection** — lock file presence determines the package manager for JS/TS. Prevents `npm install` from creating a competing lock file in yarn/pnpm/bun projects.
7. **Python venv warning** — the skill warns if no virtual environment is active but proceeds anyway. It does not create venvs (out of scope).
8. **Rust coverage best-effort** — `cargo-llvm-cov` is installed if possible, warned if not. Tests work without it; only coverage reports require it.
9. **Partial setup completion** — when some test infrastructure exists, the skill fills gaps automatically and reports what was created vs. skipped. No user prompt needed.
