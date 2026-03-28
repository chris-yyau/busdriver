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
- Example: `package.json` at repo root + `go.mod` in `services/api/` -> run TS setup at root, Go setup scoped to `services/api/`.
- Each language gets independent detection, installation, and output. They do not share test directories or configs.

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
| Yes | Yes | Yes | **Skip** -- fully set up |
| Yes | No | -- | **Create directory only**, keep existing config |
| No | Yes | -- | **Create config only**, keep existing directory |
| -- | -- | No (but config + dir exist) | **Add script only** |
| No | No | No | **Full setup** |

Proceed automatically in all cases (no user prompt). Report what was created vs. what was skipped.

## Phase 2: Installation

Install the test framework and coverage provider for each detected language. If installation fails (network, permissions, version conflict), stop and report the error -- do not proceed to Phase 3.

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
2. Install framework-specific test helpers based on detected framework:

| Framework | Additional dev dependency |
|-----------|-------------------------|
| Express | `supertest` |
| Hono | (built-in test client, no extra dep) |
| Fastify | (built-in `app.inject()`, no extra dep) |
| Next.js | (no extra dep for route handler tests) |
| Generic | (no extra dep) |

3. Create `vitest.config.ts`:

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

4. Add to `package.json` scripts:
   - `"test": "vitest run"`
   - `"test:coverage": "vitest run --coverage"`
5. Create `__tests__/` directory

#### Python

1. Determine installation method:
   - `pyproject.toml` with PEP 621 `[project]` section -> add `pytest` and `pytest-cov` to `[project.optional-dependencies]` dev group, run `pip install -e ".[dev]"`
   - `pyproject.toml` with Poetry (`[tool.poetry]`), PDM, or other non-PEP-621 format -> fall back to `requirements-dev.txt` approach
   - No `pyproject.toml` -> create `requirements-dev.txt` with `pytest` and `pytest-cov`, run `pip install -r requirements-dev.txt`
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

3. No separate test directory -- Go test files go alongside source files (`*_test.go`)

#### Rust

1. No test framework installation needed (built-in `#[test]`)
2. Attempt coverage tool install:
   ```bash
   cargo install cargo-llvm-cov
   ```
   If install fails, warn: "cargo-llvm-cov not installed. Tests will work but coverage reports require it. Install manually or use CI-only coverage." Continue with setup.
3. Create `tests/` directory for integration tests

#### Swift

1. XCTest is built-in -- no installation needed
2. For `Package.swift` projects: add test target if missing:
   ```swift
   .testTarget(name: "AppTests", dependencies: ["App"])
   ```
3. For Xcode projects: verify test target exists, warn if missing (cannot auto-create Xcode test targets reliably)
4. Create `Tests/AppTests/` directory structure

## Phase 3: Output Files

### A. Smoke Test

Generate one real, runnable test that proves the app can be imported without crashing.

**Scope:** Import-only. Does NOT start servers, connect to databases, or trigger side effects. If the app performs side effects on import (e.g., `mongoose.connect()` at module level), the smoke test will fail -- report this with the suggestion: "Your app performs side effects on import. Consider wrapping startup logic in a function."

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

### B. Gold-Standard Template Test

Generate one heavily commented test file showing the right patterns for the detected language+framework. Contains 2-3 real implemented tests (not TODOs) demonstrating:

1. **Happy path** -- basic operation with expected input
2. **Error case** -- how to test error handling
3. **Framework pattern** -- one idiomatic framework-specific test (e.g., authenticated route, middleware)

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
- `busdriver:tdd` -- for generating tests for specific modules
- Language-specific testing skill -- `busdriver:golang-testing`, `busdriver:python-testing`, `busdriver:rust-testing`, etc.

<details><summary>TypeScript/JavaScript -- Express example</summary>

```typescript
/**
 * TEMPLATE TEST -- Copy this file as a starting point for new test files.
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

<details><summary>TypeScript/JavaScript -- Generic (no framework)</summary>

```typescript
/**
 * TEMPLATE TEST -- Copy this file as a starting point for new test files.
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

<details><summary>Python -- FastAPI example</summary>

```python
"""
TEMPLATE TEST -- Copy this file as a starting point for new test files.

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

<details><summary>Python -- Generic (no framework)</summary>

```python
"""
TEMPLATE TEST -- Copy this file as a starting point for new test files.

Pattern: pytest for unit testing functions and classes.
Run: pytest
Coverage: pytest --cov

For full TDD workflow, use `busdriver:tdd`.
For more patterns, see `busdriver:python-testing`.
"""
# from your_module import your_function


# Happy path: verify function returns expected result
def test_happy_path():
    # result = your_function("valid input")
    # assert result == expected
    assert True  # Replace with real test


# Error case: verify error handling
def test_error_case():
    # with pytest.raises(ValueError):
    #     your_function(None)
    assert True  # Replace with real test
```

</details>

<details><summary>Go -- net/http example</summary>

```go
// Template test -- copy this file as a starting point for new test files.
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

<details><summary>Go -- Generic (no framework)</summary>

```go
// Template test -- copy this file as a starting point for new test files.
//
// Pattern: table-driven tests for pure functions.
// Run: go test ./...
// Coverage: go test -coverprofile=coverage.out ./...
//
// For full TDD workflow, use `busdriver:tdd`.
// For more patterns, see `busdriver:golang-testing`.

package main

import "testing"

// Happy path: verify function returns expected result.
func TestYourFunction(t *testing.T) {
	// result := YourFunction("valid input")
	// if result != expected {
	//     t.Errorf("expected %v, got %v", expected, result)
	// }
	t.Log("Replace with real test")
}

// Error case: table-driven test pattern.
func TestYourFunction_EdgeCases(t *testing.T) {
	tests := []struct {
		name    string
		input   string
		wantErr bool
	}{
		{"valid input", "hello", false},
		{"empty input", "", true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			// _, err := YourFunction(tt.input)
			// if (err != nil) != tt.wantErr {
			//     t.Errorf("wantErr=%v, got err=%v", tt.wantErr, err)
			// }
			t.Log("Replace with real test")
		})
	}
}
```

</details>

<details><summary>Rust -- Generic example</summary>

```rust
//! TEMPLATE TEST -- Copy this file as a starting point for new integration tests.
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

<details><summary>Swift -- XCTest example</summary>

```swift
/// TEMPLATE TEST -- Copy this file as a starting point for new test files.
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

Adapt all import paths and function names to match the actual codebase. The template is a starting point -- the tests should compile and pass as-is (with placeholder assertions), so the developer can immediately see the pattern and replace with real tests.

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
| **Smoke test fails -- import side effects** | Report: "Your app performs side effects on import (e.g., DB connections, env vars). Consider wrapping startup logic in a function. The smoke test verifies import-only." |
| **Smoke test fails -- missing dependencies** | Report: "Install missing dependencies first, then re-run `/test-setup`." |
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

**Skipped:** (nothing -- full setup)

**Test results:** 4 tests passing
**Coverage baseline:** 12.3%

**Next steps:**
- Wire coverage in your CI workflow
- Use `busdriver:tdd` when ready to write tests for specific modules
```
