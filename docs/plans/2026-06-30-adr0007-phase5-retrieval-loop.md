# ADR 0007 Phase 5 — Two-Round Oracle Retrieval Loop (Deterministic Core) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use busdriver:subagent-driven-development (recommended) or busdriver:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the deterministic, shell-testable core of ADR 0007 Phase 5 — an Oracle-directed read-only retrieval executor, a fail-closed Round-2 verdict validator, and a thin two-round loop wrapper — without any live GPT-5.5 Pro billing.

**Architecture:** The Oracle's Round-1 request JSON and Round-2 review JSON are **untrusted input**. A new sourceable library `evidence-safety.sh` single-sources the secret-scan + repo-containment gates (extracted from the already-audited `build-evidence-pack.sh`). `retrieve-evidence.sh` consumes a Round-1 request, runs every requested path/search through those gates, and writes a read-only evidence manifest. `validate-retrieval-review.sh` fail-closes on empty/uncited Round-2 verdicts. `run-retrieval-loop.sh` is a thin wrapper that chains `consult → retrieve → consult → validate`, with the two live `ultra_oracle_consult` calls gated behind the existing default-OFF `ultraOracle.blueprintReview.enabled` flag. The live round-trip is exercised only by a static contract test (mirrors how Phase 4 shipped) — never billed in CI.

**Tech Stack:** Bash (3.2-compatible, matching existing scripts), `jq` 1.7.x (untrusted-JSON parsing — already a repo dependency), `git grep`/`git ls-files` (bounded read-only search), shell gate-tests under `tests/test-*.sh`.

**Global Constraints (every task must honor):**
- **Fail-CLOSED everywhere.** Any ambiguity (invalid JSON, unreadable file, out-of-repo path, secret-like path, a **per-item field present but of the wrong JSON type** — e.g. `claims`/`evidence` as a string instead of an array) → reject with a typed non-zero exit / typed status token, never a silent pass. **Scope note:** a *whole optional array absent* (`needed_files`/`search_queries` missing entirely) is NOT an error — it yields an empty manifest, and the Round-2 validator's empty-claims guard is the backstop. "Missing field → reject" applies to malformed/wrong-typed values, not to absent optional collections.
- **Type-check untrusted JSON before counting it.** `jq '... | length'` on a string returns its character count, not 0 — so every guard that gates on an array length MUST first assert the value is actually an array (`if (.x|type)=="array" then (.x|length) else 0 end`). A string where an array was expected is a fail-closed rejection, never a silent pass.
- **No new runtime dependencies.** `jq` and `git` only; both already required by the repo.
- **Bash 3.2 idioms** (macOS default): `[[ ]]` for string/file tests, POSIX `[ ]` for integer `-gt/-ge`, indexed arrays only (no associative arrays), no `${x,,}` — match the style in `build-evidence-pack.sh` / `ultra-oracle.sh`.
- **No live Oracle dispatch in tests.** Tests must never invoke `oracle`/`ultra_oracle_consult` against a real session. The two-round wrapper is verified by a static grep-anchored contract test only.
- **Security boundary is single-sourced.** The secret-scan and repo-containment logic exists in exactly ONE place (`evidence-safety.sh`) after Task 1. No duplicated denylists.
- **`set -euo pipefail`** at the top of every executable script (libs sourced by others do NOT set `-e`; the caller owns shell options).
- **TDD + frequent commits.** Each task: failing test → run-fails → implement → run-passes → commit.

---

## File Structure

| File | Responsibility | Change |
|------|----------------|--------|
| `skills/ultraoracle/scripts/lib/evidence-safety.sh` | Sourceable lib: `is_secret_basename`, `is_secret_path`, `is_secret_like`, `contained_path`, `bytes_of`, `emit_nonsecret_z`. Documents required global `GIT_ROOT` (canonicalized). | **Create** |
| `skills/ultraoracle/scripts/build-evidence-pack.sh` | Existing static pack builder. Refactor to `source` the new lib instead of carrying inline copies. Behavior unchanged. | **Modify** |
| `skills/ultraoracle/scripts/retrieve-evidence.sh` | Round-1 executor: consume request JSON, gate every requested path + search through `evidence-safety.sh`, write read-only manifest + copied evidence. | **Create** |
| `skills/ultraoracle/scripts/validate-retrieval-review.sh` | Round-2 validator: fail-close on invalid JSON, wrong `review_type`, bad `verdict`, empty claims, or any uncited claim. | **Create** |
| `skills/ultraoracle/scripts/run-retrieval-loop.sh` | Thin two-round wrapper. Gated by `ultra_oracle_surface_enabled blueprintReview`. Chains consult → retrieve → consult → validate. | **Create** |
| `tests/test-ultraoracle-evidence-safety.sh` | Unit test for the extracted lib (secret detection, containment, symlink rejection). | **Create** |
| `tests/test-ultraoracle-retrieve.sh` | Executor test: unsafe requested paths (out-of-repo, traversal, secret, symlink) rejected; legit file copied; malformed JSON fails closed. | **Create** |
| `tests/test-ultraoracle-retrieval-review.sh` | Validator test: empty/uncited verdicts rejected; wrong review_type/verdict rejected; valid cited review passes. | **Create** |
| `tests/test-ultraoracle-retrieval-loop-contract.sh` | Static contract test: wrapper gates on the flag, calls retrieve then validate, makes two consults, has fail-closed tokens. | **Create** |
| `docs/adr/0007-ultraoracle-expert-witness-and-ultra-council.md` | Mark Phase 5 `Completed`. | **Modify** |
| `skills/ultraoracle/SKILL.md` | Document the retrieval-loop scripts + that live dispatch stays default-OFF. | **Modify** |

**Note on `build-evidence-pack.sh:53-58` Phase 5 guard:** leave the guard in place (build-evidence-pack still does NOT implement retrieval-loop — the new `run-retrieval-loop.sh` does). `test-ultraoracle-evidence.sh`'s "retrieval-loop rejected" assertion stays valid and untouched.

---

### Task 1: Extract security primitives into a sourceable lib

**Files:**
- Create: `skills/ultraoracle/scripts/lib/evidence-safety.sh`
- Modify: `skills/ultraoracle/scripts/build-evidence-pack.sh` (replace inline `is_secret_basename`/`is_secret_path`/`is_secret_like`/`contained_path`/`bytes_of`/`emit_nonsecret_z` with `source .../lib/evidence-safety.sh`)
- Test: `tests/test-ultraoracle-evidence-safety.sh`
- Regression guard: `tests/test-ultraoracle-evidence.sh` must still pass unchanged.

**Interfaces:**
- Produces (sourced functions; caller MUST set `GIT_ROOT` to a canonicalized `pwd -P` repo root first):
  - `is_secret_basename <name>` → exit 0 if name matches the secret denylist (case-insensitive).
  - `is_secret_path <relpath>` → exit 0 if ANY path component is secret-like.
  - `is_secret_like <abs-path>` → exit 0 if repo-relative path is secret-like OR file content matches a known secret prefix.
  - `contained_path <path>` → prints canonical absolute path on stdout and returns 0 if it resolves inside `GIT_ROOT` and is not a symlink; returns 1 otherwise (prints nothing).
  - `bytes_of <file>` → prints byte count (0 on error).
  - `emit_nonsecret_z` → stdin NUL-delimited paths → stdout newline-delimited non-secret paths.

- [ ] **Step 1: Write the failing lib unit test**

Create `tests/test-ultraoracle-evidence-safety.sh`:

```bash
#!/usr/bin/env bash
# tests/test-ultraoracle-evidence-safety.sh
# Unit test for the extracted evidence-safety.sh lib (ADR 0007 Phase 5 Task 1).
# Verifies the secret-scan + containment gates in isolation so both
# build-evidence-pack.sh and retrieve-evidence.sh inherit a single audited copy.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB="$REPO_ROOT/skills/ultraoracle/scripts/lib/evidence-safety.sh"

passed=0; failed=0
fail() { echo "FAIL: $1"; failed=$((failed + 1)); }
ok()   { echo "OK:   $1"; passed=$((passed + 1)); }

[[ -f "$LIB" ]] || { fail "evidence-safety.sh missing at $LIB"; echo "Results: 0 passed, 1 failed"; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
cd "$TMP"; git init -q
GIT_ROOT="$(pwd -P)"
# shellcheck source=/dev/null
source "$LIB"

# secret basename detection (case-insensitive)
is_secret_basename ".env"        && ok "secret: .env" || fail ".env not flagged"
is_secret_basename "API_TOKEN"   && ok "secret: API_TOKEN" || fail "API_TOKEN not flagged"
is_secret_basename "deploy.pem"  && ok "secret: *.pem" || fail "*.pem not flagged"
is_secret_basename "app.sh"      && fail "app.sh wrongly flagged" || ok "non-secret: app.sh"

# secret in an ancestor directory component
is_secret_path "secrets/config.yml" && ok "secret ancestor dir" || fail "secrets/ dir not flagged"

# containment: in-repo file resolves; out-of-repo / traversal rejected
echo hi > "$GIT_ROOT/real.txt"
contained_path "$GIT_ROOT/real.txt" >/dev/null && ok "in-repo contained" || fail "in-repo rejected"
contained_path "/etc/passwd"        >/dev/null && fail "abs out-of-repo accepted" || ok "abs out-of-repo rejected"
contained_path "$GIT_ROOT/../../etc/passwd" >/dev/null && fail "traversal accepted" || ok "traversal rejected"

# symlink rejection (a symlink whose target is outside must not slip through)
ln -s /etc/hosts "$GIT_ROOT/link"
contained_path "$GIT_ROOT/link" >/dev/null && fail "symlink accepted" || ok "symlink rejected"

echo "Results: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/test-ultraoracle-evidence-safety.sh`
Expected: FAIL — "evidence-safety.sh missing at …", `Results: 0 passed, 1 failed`, non-zero exit.

- [ ] **Step 3: Create the lib by moving the functions verbatim**

Create `skills/ultraoracle/scripts/lib/evidence-safety.sh`. Move the EXISTING, already-audited function bodies out of `build-evidence-pack.sh` unchanged — do not rewrite the logic. Header + structure:

```bash
#!/usr/bin/env bash
# evidence-safety.sh — sourceable secret-scan + repo-containment gates for the
# ultraOracle evidence path (ADR 0007). Single source of truth shared by
# build-evidence-pack.sh (Phase 1/2) and retrieve-evidence.sh (Phase 5).
#
# REQUIRED: caller MUST set `GIT_ROOT` to a canonicalized repo root (cd … && pwd -P)
# BEFORE calling is_secret_like / contained_path. This lib is sourced — it does NOT
# set `set -e`; the calling script owns shell options. Bash 3.2 safe.
#
# Functions: is_secret_basename, is_secret_path, is_secret_like,
# contained_path, bytes_of, emit_nonsecret_z.

# secret-like? filename denylist (no content read). Case-INSENSITIVE.
is_secret_basename() {
  # [move the existing body from build-evidence-pack.sh lines ~100-123 verbatim,
  #  including the nocasematch save/restore and the case denylist]
  ...
}

is_secret_path() {
  # [move existing body ~128-137 verbatim — walks every path component]
  ...
}

is_secret_like() {
  # [move existing body ~139-... verbatim — strips GIT_ROOT, denylist + content scan]
  ...
}

contained_path() {
  # [move the existing canonicalization+containment body verbatim — the block that
  #  resolves parent via `cd … && pwd -P`, rejects symlinks ([[ -L "$canon" ]]),
  #  and gates on `case "$canon" in "$GIT_ROOT"/*)`. Rename to contained_path if the
  #  original was inlined without a name.]
  ...
}

bytes_of() { wc -c < "$1" 2>/dev/null | tr -d ' ' || echo 0; }

emit_nonsecret_z() {
  # [move existing body ~186-193 verbatim]
  ...
}
```

> **Implementer note:** copy the exact bytes of each function from the current `build-evidence-pack.sh`; this task is a pure extraction. The placeholder `...` above means "the unchanged original body" — reviewers will diff against the removed lines to confirm zero logic drift.

- [ ] **Step 4: Refactor `build-evidence-pack.sh` to source the lib**

In `build-evidence-pack.sh`, after `set -euo pipefail` and after `GIT_ROOT` is computed and canonicalized (line ~68), delete the now-extracted inline function definitions and add (near the top, after resolving the script dir):

```bash
_EVP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$_EVP_DIR/lib/evidence-safety.sh"
```

`GIT_ROOT` must be assigned BEFORE the first `is_secret_like`/`contained_path` call (it already is — line ~68). No other logic changes.

- [ ] **Step 5: Run both the new lib test and the regression test**

Run: `bash tests/test-ultraoracle-evidence-safety.sh && bash tests/test-ultraoracle-evidence.sh`
Expected: BOTH print `Results: N passed, 0 failed` and exit 0. (The regression test proves the extraction did not change pack behavior.)

- [ ] **Step 6: ShellCheck the changed files**

Run: `shellcheck skills/ultraoracle/scripts/lib/evidence-safety.sh skills/ultraoracle/scripts/build-evidence-pack.sh`
Expected: no errors (warnings already suppressed inline carry over).

- [ ] **Step 7: Commit**

```bash
git add skills/ultraoracle/scripts/lib/evidence-safety.sh \
        skills/ultraoracle/scripts/build-evidence-pack.sh \
        tests/test-ultraoracle-evidence-safety.sh
git commit -m "refactor(ultraoracle): extract evidence-safety lib for shared secret/containment gates"
```

---

### Task 2: Round-1 retrieval executor

**Files:**
- Create: `skills/ultraoracle/scripts/retrieve-evidence.sh`
- Test: `tests/test-ultraoracle-retrieve.sh`

**Interfaces:**
- Consumes: `evidence-safety.sh` functions (`contained_path`, `is_secret_like`, `is_secret_path`, `bytes_of`); a Round-1 request JSON file.
- Produces: CLI `retrieve-evidence.sh --request-file <round1.json> --out-dir <dir> [--byte-budget <n>]`.
  - Round-1 JSON shape (untrusted): `{ "needed_files": [{"path": "...", "reason": "..."}], "search_queries": [{"query": "...", "reason": "..."}], "cannot_assess_yet": [...] }`.
  - Writes `<out-dir>/manifest.txt`; copies accepted files AND bounded search artifacts to `<out-dir>/files/` (search hits as `<out-dir>/files/search-<n>.txt`, so the Round-2 `files/*` glob attaches both).
  - **`--out-dir` is a WRITE target, NOT required to be inside the repo** (the wrapper passes an ephemeral `/tmp` dir). It is created with a fresh-dir + symlink guard: a pre-existing dir or a `files/` symlink fails closed. Only the *requested source paths* must be repo-contained.
  - Exit non-zero (fail-closed) on: invalid JSON; **`needed_files`/`search_queries` present but not arrays-of-objects-with-non-empty-string `path`/`query` (typed exit 3)**; missing `--out-dir`; out-dir pre-existing / `files/` symlink; not-in-git-repo.
  - **Bounds (untrusted-input backpressure):** at most `MAX_FILES`=64 requested files and `MAX_QUERIES`=20 search queries processed; each query ≤256 bytes (over-limit items recorded + skipped).
  - Rejected requested paths are RECORDED in the manifest and SKIPPED (one bad request must not deny the rest): `rejected_outside_repo:` / `rejected_secret:` / `rejected_untracked:` (untracked/FIFO/special) / `skipped_unavailable:` (not a regular readable file) / `skipped_over_budget:`; searches: `rejected_secret_search:` / `skipped_over_budget_search:` / `search_empty:` / `skipped_query_too_long:`; plus `skipped_excess_files:` / `skipped_excess_queries:` when a cap is hit.

- [ ] **Step 1: Write the failing executor test**

Create `tests/test-ultraoracle-retrieve.sh`:

```bash
#!/usr/bin/env bash
# tests/test-ultraoracle-retrieve.sh
# ADR 0007 Phase 5 — retrieve-evidence.sh: the Oracle's Round-1 requested paths are
# UNTRUSTED. Verify out-of-repo, traversal, secret, and symlink paths are rejected
# (recorded, not copied), a legit tracked file is copied, and malformed JSON fails closed.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/skills/ultraoracle/scripts/retrieve-evidence.sh"

passed=0; failed=0
fail() { echo "FAIL: $1"; failed=$((failed + 1)); }
ok()   { echo "OK:   $1"; passed=$((passed + 1)); }
[[ -f "$SCRIPT" ]] || { fail "retrieve-evidence.sh missing"; echo "Results: 0 passed, 1 failed"; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
cd "$TMP"; git init -q
git config user.email t@t.t; git config user.name t
echo "real source" > app.sh
echo "SECRET=1" > .env
ln -s /etc/hosts outside-link
# Non-secret FILENAME whose CONTENT carries a known secret prefix — exercises the
# content-scan path (is_secret_like), which the path-name denylist alone would miss.
echo "token = sk-ant-api03-deadbeefdeadbeefdeadbeef" > config.txt
echo "untracked scratch note" > scratch.txt   # NOT git-added: must not be retrievable
git add app.sh config.txt 2>/dev/null || true
git commit -qm init 2>/dev/null || true
run() { ( cd "$TMP" && bash "$SCRIPT" "$@" ); }

# legit file requested => copied + manifested
cat > req1.json <<JSON
{ "needed_files": [ {"path": "app.sh", "reason": "r"} ], "search_queries": [] }
JSON
run --request-file "$TMP/req1.json" --out-dir "$TMP/o1" >/dev/null 2>&1 || true
if ls "$TMP/o1/files/"*app.sh >/dev/null 2>&1 && grep -q "^file:" "$TMP/o1/manifest.txt"; then
  ok "legit file copied + manifested"; else fail "legit file not retrieved"; fi

# out-of-repo absolute path => rejected, not copied
cat > req2.json <<JSON
{ "needed_files": [ {"path": "/etc/passwd", "reason": "r"} ], "search_queries": [] }
JSON
run --request-file "$TMP/req2.json" --out-dir "$TMP/o2" >/dev/null 2>&1 || true
if grep -q "rejected_outside_repo:" "$TMP/o2/manifest.txt" && ! ls "$TMP/o2/files/"* >/dev/null 2>&1; then
  ok "abs out-of-repo rejected"; else fail "abs out-of-repo not rejected"; fi

# traversal => rejected
cat > req3.json <<JSON
{ "needed_files": [ {"path": "../../etc/passwd", "reason": "r"} ], "search_queries": [] }
JSON
run --request-file "$TMP/req3.json" --out-dir "$TMP/o3" >/dev/null 2>&1 || true
grep -q "rejected_outside_repo:" "$TMP/o3/manifest.txt" && ok "traversal rejected" || fail "traversal not rejected"

# secret file => rejected_secret
cat > req4.json <<JSON
{ "needed_files": [ {"path": ".env", "reason": "r"} ], "search_queries": [] }
JSON
run --request-file "$TMP/req4.json" --out-dir "$TMP/o4" >/dev/null 2>&1 || true
if grep -q "rejected_secret:" "$TMP/o4/manifest.txt" && ! ls "$TMP/o4/files/"* >/dev/null 2>&1; then
  ok "secret file rejected"; else fail "secret file not rejected"; fi

# symlink leaving repo => rejected
cat > req5.json <<JSON
{ "needed_files": [ {"path": "outside-link", "reason": "r"} ], "search_queries": [] }
JSON
run --request-file "$TMP/req5.json" --out-dir "$TMP/o5" >/dev/null 2>&1 || true
! ls "$TMP/o5/files/"* >/dev/null 2>&1 && ok "symlink rejected" || fail "symlink slipped through"

# malformed JSON => fail closed (non-zero), no out-dir files
printf '{ not json' > req6.json
if run --request-file "$TMP/req6.json" --out-dir "$TMP/o6" >/dev/null 2>&1; then
  fail "malformed JSON did not fail closed"; else ok "malformed JSON fails closed"; fi

# out-dir whose files/ is a symlink escaping the repo => fail BEFORE any copy
cat > req7.json <<JSON
{ "needed_files": [ {"path": "app.sh", "reason": "r"} ], "search_queries": [] }
JSON
mkdir -p "$TMP/o7"; ln -s /tmp "$TMP/o7/files"
# A pre-existing out-dir must be REJECTED (no-`-p` mkdir) — the script exits non-zero, so
# the call MUST be in an if (a bare call under `set -e` would abort the whole test here).
if run --request-file "$TMP/req7.json" --out-dir "$TMP/o7" >/dev/null 2>&1; then
  fail "pre-existing out-dir / symlinked files accepted"
elif [ ! -e /tmp/1_app.sh ]; then ok "pre-existing out-dir rejected, no escape write"
else rm -f /tmp/1_app.sh; fail "wrote through escaping files/ symlink"; fi

# search query matching secret CONTENT in a non-secret-named file => not transmitted
cat > req8.json <<JSON
{ "needed_files": [], "search_queries": [ {"query": "sk-ant-api03", "reason": "r"} ] }
JSON
run --request-file "$TMP/req8.json" --out-dir "$TMP/o8" >/dev/null 2>&1 || true
if ! grep -rq "sk-ant-api03" "$TMP/o8/files" 2>/dev/null && grep -q "rejected_secret_search:" "$TMP/o8/manifest.txt"; then
  ok "secret-content search rejected"; else fail "secret content leaked via search"; fi

# wrong-typed collections / elements => schema gate fails closed (exit non-zero, no out-dir)
schema_ok=1; n=0
for bad in '{"needed_files":"hello"}' '{"search_queries":{}}' '{"needed_files":[{"path":["app.sh"]}]}' '{"search_queries":[{"query":123}]}'; do
  n=$((n+1)); printf '%s' "$bad" > "$TMP/bad$n.json"
  if run --request-file "$TMP/bad$n.json" --out-dir "$TMP/ob$n" >/dev/null 2>&1; then schema_ok=0; fi
done
[ "$schema_ok" -eq 1 ] && ok "wrong-typed schema fails closed (4 shapes)" || fail "a wrong-typed shape was accepted"

# untracked in-repo file requested => rejected_untracked, not copied
cat > req9.json <<JSON
{ "needed_files": [ {"path": "scratch.txt", "reason": "r"} ], "search_queries": [] }
JSON
run --request-file "$TMP/req9.json" --out-dir "$TMP/o9" >/dev/null 2>&1 || true
if grep -q "rejected_untracked:" "$TMP/o9/manifest.txt" && ! ls "$TMP/o9/files/"*scratch* >/dev/null 2>&1; then
  ok "untracked file rejected"; else fail "untracked file retrieved"; fi

# in-repo FIFO requested => MUST NOT hang the content scan (gate order rejects it as
# untracked before any read). Guard with timeout where available; rc 124 == hang == fail.
mkfifo "$TMP/pipe" 2>/dev/null || true
cat > req10.json <<JSON
{ "needed_files": [ {"path": "pipe", "reason": "r"} ], "search_queries": [] }
JSON
if command -v timeout >/dev/null 2>&1; then TO="timeout 10"; else TO=""; fi
fifo_rc=0; ( cd "$TMP" && $TO bash "$SCRIPT" --request-file "$TMP/req10.json" --out-dir "$TMP/o10" >/dev/null 2>&1 ) || fifo_rc=$?
if [ "$fifo_rc" != 124 ] && ! ls "$TMP/o10/files/"*pipe* >/dev/null 2>&1; then
  ok "FIFO rejected without hang"; else fail "FIFO hung (rc=$fifo_rc) or was retrieved"; fi

echo "Results: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/test-ultraoracle-retrieve.sh`
Expected: FAIL — "retrieve-evidence.sh missing", `Results: 0 passed, 1 failed`.

- [ ] **Step 3: Implement `retrieve-evidence.sh`**

Create `skills/ultraoracle/scripts/retrieve-evidence.sh`. Reuse `build-evidence-pack.sh`'s arg-parse + out-dir-containment pattern (lines ~40-92) verbatim in spirit; the new logic is the request-JSON consumption loop:

```bash
#!/usr/bin/env bash
# retrieve-evidence.sh — ADR 0007 Phase 5 Round-1 executor. Consumes the Oracle's
# UNTRUSTED request JSON and produces a read-only evidence manifest. Every requested
# path and search runs through the shared secret-scan + repo-containment gates; a
# rejected request is recorded and skipped, never copied. Fail-CLOSED on bad JSON.
set -euo pipefail
_RE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$_RE_DIR/lib/evidence-safety.sh"

REQUEST_FILE=""; OUT_DIR=""; BYTE_BUDGET="262144"  # 256 KiB default, matches consult cap intent
while [ $# -gt 0 ]; do
  case "$1" in
    --request-file) REQUEST_FILE="$2"; shift 2;;
    --out-dir)      OUT_DIR="$2"; shift 2;;
    --byte-budget)  BYTE_BUDGET="$2"; shift 2;;
    -h|--help)      echo "usage: retrieve-evidence.sh --request-file <json> --out-dir <dir> [--byte-budget <n>]" >&2; exit 0;;
    *) echo "error: unknown arg '$1'" >&2; exit 2;;
  esac
done
[[ -n "$REQUEST_FILE" ]] || { echo "error: --request-file required" >&2; exit 2; }
[[ -r "$REQUEST_FILE" ]] || { echo "error: --request-file unreadable" >&2; exit 2; }
[[ -n "$OUT_DIR" ]] || { echo "error: --out-dir required" >&2; exit 2; }
case "$BYTE_BUDGET" in ''|*[!0-9]*|0) echo "error: --byte-budget must be positive int" >&2; exit 2;; esac

# Fail CLOSED on malformed JSON — jq -e exits non-zero. Do this BEFORE any retrieval.
jq -e . "$REQUEST_FILE" >/dev/null 2>&1 || { echo "error: request JSON invalid — failing closed" >&2; exit 3; }

# SCHEMA gate (fail-closed on wrong TYPE — symmetric with the Task 3 validator). The
# streaming `.needed_files // [] | .[]?` below SILENTLY DROPS a wrong-typed value
# (`"needed_files":"x"` yields nothing, exit 0), violating the global type constraint.
# Reject up front: root must be an object; when present, needed_files/search_queries must
# be arrays whose every element is an object with a non-empty string path/query. A
# whole-array ABSENT is allowed (scope note in Global Constraints) — `// []` covers that.
jq -e '
  (type=="object")
  and ((.needed_files // [])   | type=="array" and all(.[]; (type=="object") and ((.path  // "")|type=="string") and ((.path  // "")|length>0)))
  and ((.search_queries // []) | type=="array" and all(.[]; (type=="object") and ((.query // "")|type=="string") and ((.query // "")|length>0)))
' "$REQUEST_FILE" >/dev/null 2>&1 || { echo "error: request JSON schema invalid (needed_files/search_queries must be arrays of {path|query:non-empty-string}) — failing closed" >&2; exit 3; }

GIT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$GIT_ROOT" ]] || { echo "error: not in git repo" >&2; exit 4; }
GIT_ROOT="$(cd "$GIT_ROOT" && pwd -P)"

# --- out-dir: fresh-dir + symlink guard (NOT in-repo-required) ---
# Design decision (resolves the arbiter's HIGH containment finding): the OUT_DIR is a
# WRITE target the wrapper supplies (e.g. a /tmp mktemp dir — see Task 4 Step 5), so we
# do NOT require it inside GIT_ROOT (that requirement is build-evidence-pack.sh's, and
# only the REQUESTED source paths below need repo-containment). What we DO keep from
# build-evidence-pack.sh is the fresh-dir + symlink guard: create both dirs with plain
# `mkdir` (NOT -p) so a pre-existing dir or a files/ symlink escaping elsewhere fails
# closed before any copy. Canonicalize the parent so a symlinked parent is resolved.
_od="$OUT_DIR"; while [ "$_od" != "/" ] && [ "${_od%/}" != "$_od" ]; do _od="${_od%/}"; done
_odp="${_od%/*}"; [ "$_odp" = "$_od" ] && _odp="."
_op="$(cd "$_odp" 2>/dev/null && pwd -P)" || { echo "error: --out-dir parent missing" >&2; exit 4; }
OUT_DIR="$_op/${_od##*/}"
# `mkdir` (no -p): fails if OUT_DIR already exists. Then files/ likewise — and if files/
# resolves to a symlink the second mkdir fails (mkdir refuses to create over a symlink),
# so a planted escaping files/ symlink cannot be written through.
mkdir "$OUT_DIR" 2>/dev/null || { echo "error: out-dir exists or cannot be created" >&2; exit 4; }
[ -L "$OUT_DIR/files" ] && { echo "error: files/ is a symlink — refusing" >&2; exit 4; }
mkdir "$OUT_DIR/files" 2>/dev/null || { echo "error: cannot create files/ (symlink or exists)" >&2; exit 4; }
MANIFEST="$OUT_DIR/manifest.txt"; : > "$MANIFEST"
{ echo "run_id: retrieve-$(git rev-parse HEAD 2>/dev/null || echo unknown)"
  echo "repo_root: $GIT_ROOT"
  echo "generated_utc: $(date -u +%Y-%m-%dT%H:%M:%SZ)"; } >> "$MANIFEST"

spent=0; idx=0; accepted=0; seen_files=0
MAX_FILES=64; MAX_QUERIES=20; MAX_QUERY_BYTES=256   # untrusted-input backpressure caps
# --- needed_files: each requested path runs the gates ---
while IFS= read -r reqpath; do
  [ -n "$reqpath" ] || continue
  seen_files=$((seen_files + 1))
  if [ "$seen_files" -gt "$MAX_FILES" ]; then echo "skipped_excess_files: $reqpath (cap $MAX_FILES)" >> "$MANIFEST"; continue; fi
  case "$reqpath" in /*) cand="$reqpath";; *) cand="$GIT_ROOT/$reqpath";; esac
  canon="$(contained_path "$cand")" || { echo "rejected_outside_repo: $reqpath" >> "$MANIFEST"; continue; }
  rel="${canon#"$GIT_ROOT"/}"
  # GATE ORDER MATTERS (fixes a FIFO/special-file hang). is_secret_like CONTENT-scans the
  # file (grep over its bytes) with NO regular-file guard, so running it on an in-repo
  # FIFO/named-pipe would BLOCK on read forever — a DoS on attacker-influenced input. So
  # gate cheaply first, content-scan last:
  #   1. is_secret_path — path-NAME denylist only, no file read (safe on any node type).
  #   2. ls-files tracked — special files are never tracked, so a FIFO is rejected here.
  #   3. [[ -f && -r ]] — confirm a regular, readable file before ANY content read.
  #   4. is_secret_like — content scan, now guaranteed to run only on a regular file.
  if is_secret_path "$rel"; then echo "rejected_secret: $reqpath" >> "$MANIFEST"; continue; fi
  # Only transmit TRACKED files — match the inventory the Oracle was shown and
  # build-evidence-pack.sh's tracked-only posture (also excludes FIFOs / untracked scratch
  # such as local notes, build artifacts, an un-gitignored .env.local).
  git -C "$GIT_ROOT" ls-files --error-unmatch -- "$rel" >/dev/null 2>&1 || { echo "rejected_untracked: $reqpath" >> "$MANIFEST"; continue; }
  [ -f "$canon" ] && [ -r "$canon" ] || { echo "skipped_unavailable: $reqpath" >> "$MANIFEST"; continue; }
  if is_secret_like "$canon"; then echo "rejected_secret: $reqpath" >> "$MANIFEST"; continue; fi
  sz="$(bytes_of "$canon")"
  if [ "$((spent + sz))" -gt "$BYTE_BUDGET" ]; then echo "skipped_over_budget: $reqpath" >> "$MANIFEST"; continue; fi
  idx=$((idx + 1)); flat="${idx}_$(printf '%s' "$rel" | tr '/' '_')"
  cp -- "$canon" "$OUT_DIR/files/$flat" || { echo "skipped_copy_failed: $reqpath" >> "$MANIFEST"; continue; }
  spent=$((spent + sz)); accepted=$((accepted + 1))
  echo "file: files/$flat <= $rel ($sz bytes)" >> "$MANIFEST"
done < <(jq -r '.needed_files // [] | .[]? | .path // empty' "$REQUEST_FILE")

# --- search_queries: bounded, read-only, secret-filtered (path AND content) ---
# Search artifacts land UNDER files/ so the Round-2 wrapper's single files/* glob
# attaches them too (resolves the arbiter's "Round-2 omits search context" finding).
MAX_HITS=200
qidx=0; seen_q=0
while IFS= read -r q; do
  [ -n "$q" ] || continue
  seen_q=$((seen_q + 1))
  if [ "$seen_q" -gt "$MAX_QUERIES" ]; then echo "skipped_excess_queries: query[$seen_q] (cap $MAX_QUERIES)" >> "$MANIFEST"; continue; fi
  # Reject an overlong query before spending a full-tree git grep on it.
  if [ "$(printf '%s' "$q" | wc -c | tr -d ' ')" -gt "$MAX_QUERY_BYTES" ]; then echo "skipped_query_too_long: query[$seen_q]" >> "$MANIFEST"; continue; fi
  qidx=$((qidx + 1)); hits="$OUT_DIR/files/search-$qidx.txt"
  # -F fixed-string (query is untrusted; no regex injection), -I skip binary.
  # Pass query as a single -e arg (never interpolated into a pattern string).
  # First get the MATCHING FILE PATHS as NUL-delimited records (`-l -z`) so a path that
  # itself contains a colon stays intact — the secret-path denylist must see the WHOLE
  # path (`${line%%:*}` on `dir:secrets/cfg:12:...` would truncate to `dir`, dropping the
  # secret-named component). Secret-filter on the intact path, THEN per-file grep for hits.
  : > "$hits"
  git -C "$GIT_ROOT" grep -lIF -z -e "$q" -- . 2>/dev/null \
    | while IFS= read -r -d '' f; do
        is_secret_path "$f" && continue
        git -C "$GIT_ROOT" grep -nIF -e "$q" -- "$f" 2>/dev/null
      done | head -n "$MAX_HITS" > "$hits" || true
  if [ ! -s "$hits" ]; then rm -f "$hits"; echo "search_empty: query[$qidx]" >> "$MANIFEST"; continue; fi
  # CONTENT scan: a query like `sk-` can match a secret value living in a NON-secret-named
  # file, which the path denylist above misses. is_secret_like scans the whole artifact;
  # if it trips, the hits file is dropped before it can be attached/transmitted.
  if is_secret_like "$hits"; then rm -f "$hits"; echo "rejected_secret_search: query[$qidx]" >> "$MANIFEST"; continue; fi
  hsz="$(bytes_of "$hits")"
  if [ "$((spent + hsz))" -gt "$BYTE_BUDGET" ]; then rm -f "$hits"; echo "skipped_over_budget_search: query[$qidx]" >> "$MANIFEST"; continue; fi
  spent=$((spent + hsz))   # search bytes count against the same shared budget as files
  echo "search: files/search-$qidx.txt <= query[$qidx] ($(wc -l < "$hits" | tr -d ' ') hits)" >> "$MANIFEST"
done < <(jq -r '.search_queries // [] | .[]? | .query // empty' "$REQUEST_FILE")

{ echo "accepted_files: $accepted"; echo "accepted_bytes: $spent"; } >> "$MANIFEST"
# Progress to STDERR only (mirrors build-evidence-pack.sh's stdout discipline) so a caller
# that captures this script's stdout gets nothing but the manifest path it writes — the
# wrapper does not capture it, keeping the wrapper's own stdout token-only.
echo "ORACLE_RETRIEVAL_MANIFEST $MANIFEST" >&2
```

> **Security note for reviewers:** the two `jq -r … | while read` loops are the only places untrusted Oracle JSON drives behavior. Each requested path is gated by `contained_path` (out-of-repo/symlink reject) THEN `is_secret_like` (secret reject) BEFORE any `cp`. Search queries reach `git grep` only as a single `-e "$q"` argument — never spliced into a pattern string or a shell command — binary/secret-pathed hits are filtered out, AND each completed search artifact is run through `is_secret_like` (content scan) before it can be attached, so a query matching a secret value inside a non-secret-named file is dropped, not transmitted. Search bytes debit the same shared `BYTE_BUDGET` as files.

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash tests/test-ultraoracle-retrieve.sh`
Expected: `Results: 11 passed, 0 failed`, exit 0.

- [ ] **Step 5: ShellCheck**

Run: `shellcheck skills/ultraoracle/scripts/retrieve-evidence.sh`
Expected: no errors.

- [ ] **Step 6: Commit**

```bash
git add skills/ultraoracle/scripts/retrieve-evidence.sh tests/test-ultraoracle-retrieve.sh
git commit -m "feat(ultraoracle): add Round-1 read-only retrieval executor (ADR 0007 Phase 5)"
```

---

### Task 3: Round-2 verdict validator

**Files:**
- Create: `skills/ultraoracle/scripts/validate-retrieval-review.sh`
- Test: `tests/test-ultraoracle-retrieval-review.sh`

**Interfaces:**
- Consumes: a Round-2 `ORACLE_RETRIEVAL_REVIEW` JSON file.
- Produces: CLI `validate-retrieval-review.sh --review-file <round2.json>`.
  - Round-2 shape: `{ "review_type": "ORACLE_RETRIEVAL_REVIEW", "files_examined": [...], "searches_examined": [...], "claims": [{"claim": "...", "evidence": ["path:line"]}], "limitations": [...], "verdict": "PASS|FAIL|UNCERTAIN" }`.
  - On success: prints `OK <verdict>` to stdout, exit 0.
  - Fail-closed (typed non-zero exit + stderr reason): exit 3 invalid JSON; exit 4 wrong/absent `review_type`; exit 5 verdict not in `PASS|FAIL|UNCERTAIN`; exit 6 empty/absent `claims`; exit 7 any claim with empty/absent `evidence` (uncited).

- [ ] **Step 1: Write the failing validator test**

Create `tests/test-ultraoracle-retrieval-review.sh`:

```bash
#!/usr/bin/env bash
# tests/test-ultraoracle-retrieval-review.sh
# ADR 0007 Phase 5 — validate-retrieval-review.sh must fail CLOSED on empty/uncited
# Round-2 verdicts (the ADR Phase 5 acceptance criterion) and on shape violations.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/skills/ultraoracle/scripts/validate-retrieval-review.sh"

passed=0; failed=0
fail() { echo "FAIL: $1"; failed=$((failed + 1)); }
ok()   { echo "OK:   $1"; passed=$((passed + 1)); }
[[ -f "$SCRIPT" ]] || { fail "validate-retrieval-review.sh missing"; echo "Results: 0 passed, 1 failed"; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
v() { bash "$SCRIPT" --review-file "$1"; }

# valid, cited review => pass (exit 0)
cat > "$TMP/good.json" <<JSON
{ "review_type": "ORACLE_RETRIEVAL_REVIEW", "claims": [ {"claim": "x", "evidence": ["app.sh:1"]} ], "verdict": "PASS" }
JSON
v "$TMP/good.json" >/dev/null 2>&1 && ok "valid cited review passes" || fail "valid review rejected"

# UNCERTAIN with a cited claim is still structurally valid => pass
cat > "$TMP/uncertain.json" <<JSON
{ "review_type": "ORACLE_RETRIEVAL_REVIEW", "claims": [ {"claim": "x", "evidence": ["a.sh:2"]} ], "verdict": "UNCERTAIN" }
JSON
v "$TMP/uncertain.json" >/dev/null 2>&1 && ok "UNCERTAIN cited passes" || fail "UNCERTAIN cited rejected"

# empty claims => fail closed (exit 6)
cat > "$TMP/empty.json" <<JSON
{ "review_type": "ORACLE_RETRIEVAL_REVIEW", "claims": [], "verdict": "PASS" }
JSON
v "$TMP/empty.json" >/dev/null 2>&1 && fail "empty claims accepted" || ok "empty claims rejected"

# uncited claim (empty evidence) => fail closed (exit 7)
cat > "$TMP/uncited.json" <<JSON
{ "review_type": "ORACLE_RETRIEVAL_REVIEW", "claims": [ {"claim": "x", "evidence": []} ], "verdict": "PASS" }
JSON
v "$TMP/uncited.json" >/dev/null 2>&1 && fail "uncited claim accepted" || ok "uncited claim rejected"

# wrong review_type => fail closed (exit 4)
cat > "$TMP/wrongtype.json" <<JSON
{ "review_type": "SOMETHING_ELSE", "claims": [ {"claim": "x", "evidence": ["a:1"]} ], "verdict": "PASS" }
JSON
v "$TMP/wrongtype.json" >/dev/null 2>&1 && fail "wrong review_type accepted" || ok "wrong review_type rejected"

# bad verdict => fail closed (exit 5)
cat > "$TMP/badverdict.json" <<JSON
{ "review_type": "ORACLE_RETRIEVAL_REVIEW", "claims": [ {"claim": "x", "evidence": ["a:1"]} ], "verdict": "LGTM" }
JSON
v "$TMP/badverdict.json" >/dev/null 2>&1 && fail "bad verdict accepted" || ok "bad verdict rejected"

# claims as a STRING (not array) => fail closed (jq length would return char count)
cat > "$TMP/claimstr.json" <<JSON
{ "review_type": "ORACLE_RETRIEVAL_REVIEW", "claims": "hello", "verdict": "PASS" }
JSON
v "$TMP/claimstr.json" >/dev/null 2>&1 && fail "string claims accepted" || ok "string claims rejected"

# evidence as a STRING (not array) => uncited, fail closed
cat > "$TMP/evstr.json" <<JSON
{ "review_type": "ORACLE_RETRIEVAL_REVIEW", "claims": [ {"claim": "x", "evidence": "a:1"} ], "verdict": "PASS" }
JSON
v "$TMP/evstr.json" >/dev/null 2>&1 && fail "string evidence accepted" || ok "string evidence rejected"

# Boundary: a fabricated-but-structurally-cited citation PASSES — existence verification
# is the downstream arbiter's responsibility, not this structural validator's (ADR P4).
cat > "$TMP/fab.json" <<JSON
{ "review_type": "ORACLE_RETRIEVAL_REVIEW", "claims": [ {"claim": "x", "evidence": ["nonexistent.sh:999"]} ], "verdict": "PASS" }
JSON
v "$TMP/fab.json" >/dev/null 2>&1 && ok "structurally-cited (fabricated) passes — arbiter checks existence" || fail "fabricated citation rejected (should defer to arbiter)"

# null claim text + object (non-string) evidence element => fail closed
cat > "$TMP/nullclaim.json" <<JSON
{ "review_type": "ORACLE_RETRIEVAL_REVIEW", "claims": [ {"claim": null, "evidence": [{}]} ], "verdict": "PASS" }
JSON
v "$TMP/nullclaim.json" >/dev/null 2>&1 && fail "null-claim/object-evidence accepted" || ok "null-claim/object-evidence rejected"

# bare-string claim element (claims:[\"x\"]) => typed fail closed, not a jq crash
cat > "$TMP/strclaim.json" <<JSON
{ "review_type": "ORACLE_RETRIEVAL_REVIEW", "claims": [ "iamastring" ], "verdict": "PASS" }
JSON
if v "$TMP/strclaim.json" >/dev/null 2>&1; then fail "string claim element accepted"; else
  rc=$?; [ "$rc" -eq 7 ] && ok "string claim element -> typed exit 7" || fail "string claim element exit $rc (want 7)"; fi

# malformed JSON => fail closed (exit 3)
printf '{ not json' > "$TMP/bad.json"
v "$TMP/bad.json" >/dev/null 2>&1 && fail "malformed JSON accepted" || ok "malformed JSON rejected"

echo "Results: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/test-ultraoracle-retrieval-review.sh`
Expected: FAIL — "validate-retrieval-review.sh missing", `Results: 0 passed, 1 failed`.

- [ ] **Step 3: Implement `validate-retrieval-review.sh`**

```bash
#!/usr/bin/env bash
# validate-retrieval-review.sh — ADR 0007 Phase 5 Round-2 validator. Fail-CLOSED on an
# Oracle ORACLE_RETRIEVAL_REVIEW that is malformed, mis-typed, has a non-enum verdict,
# carries no claims, or carries any uncited claim. An UNCERTAIN verdict is structurally
# valid (advisory-only downstream) — it is NOT rejected here.
set -euo pipefail
REVIEW_FILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --review-file) REVIEW_FILE="$2"; shift 2;;
    -h|--help) echo "usage: validate-retrieval-review.sh --review-file <json>" >&2; exit 0;;
    *) echo "error: unknown arg '$1'" >&2; exit 2;;
  esac
done
[[ -n "$REVIEW_FILE" && -r "$REVIEW_FILE" ]] || { echo "error: --review-file required/readable" >&2; exit 2; }

jq -e . "$REVIEW_FILE" >/dev/null 2>&1 || { echo "error: review JSON invalid — failing closed" >&2; exit 3; }

rtype="$(jq -r '.review_type // empty' "$REVIEW_FILE")"
[ "$rtype" = "ORACLE_RETRIEVAL_REVIEW" ] || { echo "error: review_type not ORACLE_RETRIEVAL_REVIEW ('$rtype')" >&2; exit 4; }

verdict="$(jq -r '.verdict // empty' "$REVIEW_FILE")"
case "$verdict" in PASS|FAIL|UNCERTAIN) : ;; *) echo "error: verdict not in PASS|FAIL|UNCERTAIN ('$verdict')" >&2; exit 5;; esac

# claims MUST be a non-empty ARRAY. `jq '.claims|length'` on a STRING returns its
# character count, so a string claims value (`"claims":"hello"`) would otherwise pass a
# bare length>=1 check — assert the type first and fail closed on anything but an array.
nclaims="$(jq 'if (.claims|type)=="array" then (.claims|length) else 0 end' "$REVIEW_FILE")"
case "$nclaims" in ''|*[!0-9]*) echo "error: claims count unreadable — failing closed" >&2; exit 6;; esac
[ "$nclaims" -ge 1 ] || { echo "error: claims missing/empty/not-an-array — failing closed" >&2; exit 6; }

# A claim is VALID only if it is an OBJECT with a non-empty string `.claim` AND a non-empty
# `.evidence` array whose every element is a non-empty string citation. Everything else —
# a non-object element, a null/empty claim text, string/empty/object-element evidence — is
# counted invalid => fail closed (exit 7). jq `and` short-circuits, so the leading
# type=="object" guard makes `.claim`/`.evidence` access safe even for a bare-string element
# (it returns false and is selected as invalid rather than throwing). The integer guard
# converts any jq read failure into the typed exit 7, not a raw `[ : integer expected` crash.
invalid="$(jq '[.claims[]? | select(
    ( (type=="object")
      and ((.claim|type)=="string") and ((.claim|length)>0)
      and ((.evidence|type)=="array") and ((.evidence|length)>0)
      and (all(.evidence[]; (type=="string") and (length>0)))
    ) | not)] | length' "$REVIEW_FILE")"
case "$invalid" in ''|*[!0-9]*) echo "error: claim validation unreadable — failing closed" >&2; exit 7;; esac
[ "$invalid" -eq 0 ] || { echo "error: $invalid malformed/uncited claim(s) — failing closed" >&2; exit 7; }

# NOTE — citation EXISTENCE is intentionally NOT verified here. This validator enforces
# the structural shape (cited array-of-claims). Whether a cited "path:line" actually
# exists in the retrieved evidence is the downstream design-review ARBITER's job — per
# ADR 0007 Phase 4 the arbiter validates Oracle claims against the codebase before any
# PASS/FAIL. Re-checking existence here would duplicate that and couple the validator to
# the manifest format. (Boundary is pinned by a test below.)
echo "OK $verdict"
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash tests/test-ultraoracle-retrieval-review.sh`
Expected: `Results: 12 passed, 0 failed`, exit 0.

- [ ] **Step 5: ShellCheck**

Run: `shellcheck skills/ultraoracle/scripts/validate-retrieval-review.sh`
Expected: no errors.

- [ ] **Step 6: Commit**

```bash
git add skills/ultraoracle/scripts/validate-retrieval-review.sh tests/test-ultraoracle-retrieval-review.sh
git commit -m "feat(ultraoracle): add Round-2 verdict validator, fail-closed on uncited claims (ADR 0007 Phase 5)"
```

---

### Task 4: Thin two-round loop wrapper + static contract test

**Files:**
- Create: `skills/ultraoracle/scripts/run-retrieval-loop.sh`
- Test: `tests/test-ultraoracle-retrieval-loop-contract.sh`

**Interfaces:**
- Consumes: `ultra_oracle_consult` (`scripts/lib/ultra-oracle.sh`), `ultra_oracle_surface_enabled` (`scripts/lib/ultra-oracle-config.sh`), `retrieve-evidence.sh`, `validate-retrieval-review.sh`.
- Produces: CLI `run-retrieval-loop.sh --question-file <q> --out-dir <dir>`. Prints a typed status token on the last line: `skipped:disabled` | `ORACLE_RETRIEVAL_REVIEW <verdict>` | `error` | `timeout` | `skipped:unavailable` | `skipped:user` (the operator's `.claude/skip-ultra-oracle.local` local opt-out, propagated verbatim from `ultra_oracle_consult`).
- Live `oracle` dispatch occurs ONLY when `ultra_oracle_surface_enabled blueprintReview` returns 0 (USER-config, default OFF). The deterministic pieces it orchestrates are independently tested in Tasks 2–3; this task's test is a static contract pin (no live dispatch), mirroring `tests/test-ultra-council.sh` and `tests/test-blueprint-review-oracle-arbiter-contract.sh`.

- [ ] **Step 1: Write the failing contract test**

Create `tests/test-ultraoracle-retrieval-loop-contract.sh`:

```bash
#!/usr/bin/env bash
# tests/test-ultraoracle-retrieval-loop-contract.sh
# ADR 0007 Phase 5 — the two-round loop hits live GPT-5.5 Pro, so it cannot be unit
# tested. Pin the load-bearing wiring with a static contract (same approach as
# test-ultra-council.sh): flag-gated dispatch, retrieve-before-validate ordering,
# exactly two consults, and fail-closed tokens.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
S="$REPO_ROOT/skills/ultraoracle/scripts/run-retrieval-loop.sh"

passed=0; failed=0
fail() { echo "FAIL: $1"; failed=$((failed + 1)); }
ok()   { echo "OK:   $1"; passed=$((passed + 1)); }
[[ -f "$S" ]] || { fail "run-retrieval-loop.sh missing"; echo "Results: 0 passed, 1 failed"; exit 1; }

# A1: dispatch is gated by the default-OFF blueprintReview flag.
grep -q 'ultra_oracle_surface_enabled blueprintReview' "$S" && ok "A1 flag-gated" || fail "A1 missing flag gate"
# A2: skips with a typed token when disabled (no silent run).
grep -q 'skipped:disabled' "$S" && ok "A2 disabled token" || fail "A2 missing disabled token"
# A3: retrieval runs BEFORE validation (ordering anchor).
rl=$(grep -n 'retrieve-evidence.sh' "$S" | head -1 | cut -d: -f1)
vl=$(grep -n 'validate-retrieval-review.sh' "$S" | head -1 | cut -d: -f1)
{ [ -n "$rl" ] && [ -n "$vl" ] && [ "$rl" -lt "$vl" ]; } && ok "A3 retrieve before validate" || fail "A3 ordering wrong"
# A4: exactly two oracle consults (Round 1 + Round 2).
c=$(grep -c 'ultra_oracle_consult' "$S" || true)
[ "$c" -ge 2 ] && ok "A4 two consults ($c)" || fail "A4 expected >=2 consults, got $c"
# A5: fail-closed token on a failed validation / consult.
grep -Eq 'printf .?error|echo .?error|"error"' "$S" && ok "A5 fail-closed token" || fail "A5 missing error token"
# A6: question-file validated (present+readable+non-empty) before any billed dispatch.
grep -q '\-s "\$QUESTION_FILE"' "$S" && ok "A6 question-file validated" || fail "A6 missing question-file -s guard"
# A7: errexit-safe consult capture (if st=...; then) so a non-zero typed token is not lost
# when the wrapper runs under set -e — guards the confirmed token-loss defect.
[ "$(grep -c 'if st[12]="\$(ultra_oracle_consult' "$S")" -eq 2 ] && ok "A7 errexit-safe capture x2" || fail "A7 consult capture not errexit-safe"
# A8: Round-2 prompt re-states the original question (grounding) — the question file is
# concatenated into round2-prompt.txt, not just round1.
awk '/round2-prompt.txt/{f=1} f&&/ORIGINAL QUESTION/{print; exit}' "$S" | grep -q . && ok "A8 round-2 re-grounds question" || fail "A8 round-2 omits question"
# A9: inventory is secret-filtered (emit_nonsecret_z), not raw git ls-files.
grep -q 'ls-files -z .*| emit_nonsecret_z' "$S" && ok "A9 inventory secret-filtered" || fail "A9 raw inventory"
# A10: question file is secret-scanned before the first consult.
qline=$(grep -n 'is_secret_like "\$q_canon"' "$S" | head -1 | cut -d: -f1)
c1line=$(grep -n 'ultra_oracle_consult' "$S" | head -1 | cut -d: -f1)
{ [ -n "$qline" ] && [ -n "$c1line" ] && [ "$qline" -lt "$c1line" ]; } && ok "A10 question secret-gated pre-consult" || fail "A10 question not gated before consult"

echo "Results: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/test-ultraoracle-retrieval-loop-contract.sh`
Expected: FAIL — "run-retrieval-loop.sh missing", `Results: 0 passed, 1 failed`.

- [ ] **Step 3: Implement `run-retrieval-loop.sh`**

```bash
#!/usr/bin/env bash
# run-retrieval-loop.sh — ADR 0007 Phase 5 thin two-round wrapper. Round 1: ask the
# Oracle (given a repo inventory) what files/searches it needs. Retrieve them read-only
# via retrieve-evidence.sh. Round 2: send the retrieved evidence back and validate the
# ORACLE_RETRIEVAL_REVIEW. Live dispatch is gated behind the USER-config, default-OFF
# ultraOracle.blueprintReview.enabled flag. Fail-CLOSED on every error.
set -euo pipefail
_RL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_LIB="$(cd "$_RL_DIR/../../.." && pwd)/scripts/lib"
# shellcheck source=/dev/null
source "$_LIB/ultra-oracle.sh"
# shellcheck source=/dev/null
source "$_LIB/ultra-oracle-config.sh"
# evidence-safety gates — so Round-1 INPUTS (inventory + question) route through the same
# single-sourced secret boundary as the retrieval step (not just the retrieved output).
# shellcheck source=/dev/null
source "$_RL_DIR/lib/evidence-safety.sh"

QUESTION_FILE=""; OUT_DIR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --question-file) QUESTION_FILE="$2"; shift 2;;
    --out-dir)       OUT_DIR="$2"; shift 2;;
    *) echo "error: unknown arg '$1'" >&2; printf 'error'; exit 2;;
  esac
done
[[ -n "$OUT_DIR" ]] || { echo "error: --out-dir required" >&2; printf 'error'; exit 2; }

# Gate: default-OFF. No live dispatch unless the operator opted in (USER config only).
# Checked FIRST so a disabled run with no --question-file still cleanly skips (Step 5).
if ! ultra_oracle_surface_enabled blueprintReview; then printf 'skipped:disabled'; exit 0; fi

# Fail CLOSED before the first BILLED consult: require a present, readable, NON-EMPTY
# question. ultra_oracle_consult's own guard only checks the prompt (which always carries
# the inventory header), so an empty question would otherwise reach a paid Round-1 call.
[[ -n "$QUESTION_FILE" && -r "$QUESTION_FILE" && -s "$QUESTION_FILE" ]] || { echo "error: --question-file required/readable/non-empty" >&2; printf 'error'; exit 2; }

mkdir -p "$OUT_DIR" || { printf 'error'; exit 1; }
GIT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$GIT_ROOT" ]] || { printf 'error'; exit 1; }
GIT_ROOT="$(cd "$GIT_ROOT" && pwd -P)"   # canonicalize for is_secret_like

# Gate the QUESTION before the first BILLED dispatch: a secret-like question file (by name
# or content) must never be transmitted to ChatGPT Pro. Mirrors build-evidence-pack.sh.
q_canon="$(contained_path "$QUESTION_FILE" 2>/dev/null || printf '%s' "$QUESTION_FILE")"
if is_secret_like "$q_canon"; then echo "error: --question-file looks secret-like — refusing" >&2; printf 'error'; exit 2; fi

# --- Round 1: inventory -> request ---
# Inventory routes through emit_nonsecret_z so a secret-like TRACKED path name (.env.local,
# secrets/…) is never shown to the Oracle — same posture as build-evidence-pack.sh.
inv="$OUT_DIR/inventory.txt"
git -C "$GIT_ROOT" ls-files -z 2>/dev/null | emit_nonsecret_z | head -n 2000 > "$inv" || true
r1prompt="$OUT_DIR/round1-prompt.txt"
{ echo "You are a repo-grounded expert witness. Given this file inventory and the"
  echo "question below, return ONLY JSON: {needed_files:[{path,reason}], search_queries:[{query,reason}], cannot_assess_yet:[...]}."
  echo "--- QUESTION ---"; cat "$QUESTION_FILE" 2>/dev/null || true
  echo "--- INVENTORY ---"; cat "$inv"; } > "$r1prompt"
r1out="$OUT_DIR/round1.json"
# errexit-safe capture: ultra_oracle_consult RETURNS NON-ZERO for the typed tokens
# error(1)/timeout(124)/skipped:unavailable(3). Under `set -e`, a bare st1=$(...) aborts
# the wrapper HERE — before the status-check line — so it would exit WITHOUT printing the
# typed token its own contract promises. Capture in if/else; default a lost token to error.
if st1="$(ultra_oracle_consult --prompt-file "$r1prompt" --out "$r1out" --slug "oracle retrieval round1")"; then :; else [ -n "$st1" ] || st1=error; fi
# Treat the operator opt-out tokens as intentional SKIPS (exit 0), not errors —
# ultra_oracle_consult returns skipped:user (return 0) for .claude/skip-ultra-oracle.local.
# timeout/error/skipped:unavailable stay fail-closed (non-zero).
case "$st1" in
  ok) : ;;
  skipped:user|skipped:disabled) printf '%s' "$st1"; exit 0 ;;
  *) printf '%s' "$st1"; exit 1 ;;
esac

# --- Retrieval (read-only, gated) ---
"$_RL_DIR/retrieve-evidence.sh" --request-file "$r1out" --out-dir "$OUT_DIR/evidence" || { printf 'error'; exit 1; }

# --- Round 2: send evidence -> review ---
r2prompt="$OUT_DIR/round2-prompt.txt"
# Each consult is a fresh stateless call — Round 2 MUST re-state the original question and
# the Round-1 request, or the Oracle reviews evidence with no objective and emits
# structurally-valid but ungrounded claims (defeats the two-round loop).
{ echo "Using ONLY the attached retrieved evidence, answer the ORIGINAL QUESTION below."
  echo "Return ONLY JSON with review_type \"ORACLE_RETRIEVAL_REVIEW\", claims[].evidence as"
  echo "[\"path:line\"] strings, and verdict PASS|FAIL|UNCERTAIN."
  echo "--- ORIGINAL QUESTION ---"; cat "$QUESTION_FILE" 2>/dev/null || true
  echo "--- YOUR ROUND-1 REQUEST ---"; cat "$r1out" 2>/dev/null || true
  echo "--- RETRIEVAL MANIFEST ---"; cat "$OUT_DIR/evidence/manifest.txt" 2>/dev/null || true; } > "$r2prompt"
r2out="$OUT_DIR/round2.json"
# Attach ALL retrieved evidence under files/ as context — copied source files AND the
# search-N.txt artifacts (the executor writes searches under files/ too), each already
# secret-gated (path + content) by the executor. One glob grounds both files and searches.
ctx=(); for f in "$OUT_DIR/evidence/files/"*; do [ -e "$f" ] && ctx+=(--context "$f"); done
# errexit-safe capture (same rationale as Round 1).
if st2="$(ultra_oracle_consult --prompt-file "$r2prompt" --out "$r2out" --slug "oracle retrieval round2" "${ctx[@]:-}")"; then :; else [ -n "$st2" ] || st2=error; fi
case "$st2" in
  ok) : ;;
  skipped:user|skipped:disabled) printf '%s' "$st2"; exit 0 ;;
  *) printf '%s' "$st2"; exit 1 ;;
esac

# --- Validate Round 2, fail-closed ---
if vres="$("$_RL_DIR/validate-retrieval-review.sh" --review-file "$r2out")"; then
  echo "ORACLE_RETRIEVAL_REVIEW ${vres#OK }"
else
  printf 'error'; exit 1
fi
```

> **Reviewer note:** the only outward/billed action is the two `ultra_oracle_consult` calls, both unreachable unless `ultra_oracle_surface_enabled blueprintReview` (USER config, default OFF). With the flag off the script prints `skipped:disabled` and exits 0 — which is exactly what CI and the contract test exercise. No test sets that flag. (Note: the quoted command path `"$_RL_DIR/retrieve-evidence.sh" ...` is an ordinary invocation — a double-quoted word at the start of a command is the command name; the quotes protect a spaced/expanded path and MUST stay. This was a refuted review finding.)

- [ ] **Step 4: Run the contract test to verify it passes**

Run: `bash tests/test-ultraoracle-retrieval-loop-contract.sh`
Expected: `Results: 10 passed, 0 failed`, exit 0.

- [ ] **Step 5: Verify default-OFF behavior end to end (no billing)**

Run: `bash skills/ultraoracle/scripts/run-retrieval-loop.sh --out-dir "$(mktemp -d)"; echo "exit=$?"`
Expected: prints `skipped:disabled`, `exit=0` (proves no live dispatch with the flag off).

- [ ] **Step 6: ShellCheck**

Run: `shellcheck skills/ultraoracle/scripts/run-retrieval-loop.sh`
Expected: no errors.

- [ ] **Step 7: Commit**

```bash
git add skills/ultraoracle/scripts/run-retrieval-loop.sh tests/test-ultraoracle-retrieval-loop-contract.sh
git commit -m "feat(ultraoracle): add two-round retrieval loop wrapper, default-OFF (ADR 0007 Phase 5)"
```

---

### Task 5: Mark Phase 5 Completed + document the scripts

**Files:**
- Modify: `docs/adr/0007-ultraoracle-expert-witness-and-ultra-council.md` (Phase 5 heading → Completed)
- Modify: `skills/ultraoracle/SKILL.md` (document retrieval-loop scripts + default-OFF live dispatch)

**Interfaces:** none (docs only).

- [ ] **Step 1: Update the ADR Phase 5 heading**

In `docs/adr/0007-…md`, change the Phase 5 heading (currently `### Phase 5: Two-round retrieval loop`) to:

```markdown
### Phase 5: Two-round retrieval loop (Completed 2026-06-30)
```

Append a one-line note under the acceptance list recording that the deterministic core (executor + validator + thin wrapper) is test-locked and the live two-round dispatch stays behind the default-OFF `ultraOracle.blueprintReview.enabled` flag (no billed dogfood this session).

- [ ] **Step 2: Document the scripts in SKILL.md**

Add a short "Phase 5 retrieval loop" subsection to `skills/ultraoracle/SKILL.md` listing `retrieve-evidence.sh`, `validate-retrieval-review.sh`, `run-retrieval-loop.sh`, their one-line jobs, and that the loop is default-OFF (operator opt-in via USER `busdriver.json`).

- [ ] **Step 3: Run the full Phase 5 test set + the regression test**

Run:
```bash
for t in evidence-safety retrieve retrieval-review retrieval-loop-contract; do
  bash "tests/test-ultraoracle-$t.sh" || exit 1
done
bash tests/test-ultraoracle-evidence.sh
```
Expected: every script prints `Results: N passed, 0 failed` and exits 0.

- [ ] **Step 4: Commit**

```bash
git add docs/adr/0007-ultraoracle-expert-witness-and-ultra-council.md skills/ultraoracle/SKILL.md
git commit -m "docs(ultraoracle): mark ADR 0007 Phase 5 Completed; document retrieval-loop scripts"
```

---

## Plan Sanity Check

**1. Spec coverage (ADR 189-238, 307-316):**
- Round 1 produces requested files/searches → consumed by `retrieve-evidence.sh` (Task 2). ✓
- Busdriver retrieves read-only evidence into a manifest, rejecting unsafe paths/secret files → Task 2 executor + Task 1 gates. ✓
- Round 2 produces `ORACLE_RETRIEVAL_REVIEW` → validated by `validate-retrieval-review.sh` (Task 3); two-round flow wired in `run-retrieval-loop.sh` (Task 4). ✓
- Acceptance: tests cover unsafe requested paths (Task 2 test: out-of-repo/traversal/secret/symlink) + empty/uncited verdicts (Task 3 test: empty claims exit 6, uncited exit 7). ✓
- UNCERTAIN advisory-only, never gate-blocks → validator treats UNCERTAIN as structurally valid (Task 3 test). ✓
- Live dispatch default-OFF, no billing this session → wrapper gated on `ultra_oracle_surface_enabled blueprintReview`; contract test never sets the flag (Task 4). ✓

**2. Placeholder scan:** the only `...` markers are in Task 1 Step 3, explicitly labeled "move the existing body verbatim" — a pure extraction, not a TODO. All new logic (executor loops, validator checks, wrapper) is shown in full. ✓

**3. Type/name consistency:** `contained_path`, `is_secret_like`, `is_secret_path`, `bytes_of` defined in Task 1 are the exact names called in Tasks 2/4. CLI flags consistent: `--request-file`/`--out-dir` (executor), `--review-file` (validator), `--question-file`/`--out-dir` (wrapper). Status token `ORACLE_RETRIEVAL_REVIEW` consistent across wrapper output and validator's expected `review_type`. ✓

**Revision note (after blueprint-review iteration 1):** the opus arbiter confirmed real fail-open defects, now fixed in this plan: (HIGH) errexit-safe `st1`/`st2` capture in the wrapper so a non-zero typed token is never lost under `set -e`; (HIGH) `validate-retrieval-review.sh` type-checks `claims`/`evidence` as arrays so a JSON *string* cannot bypass the empty/uncited guards; (HIGH) out-dir model resolved to fresh-dir + symlink guard (not in-repo-required), so the wrapper's `/tmp` mktemp out-dir is accepted while a planted `files/` escape symlink fails closed; (MED) search artifacts run through `is_secret_like` content-scan, debit the byte budget, and land under `files/` so Round-2 attaches them; (MED) question-file validated present/readable/non-empty before the first billed consult. The one refuted finding (Grok's "leading double-quote no-op") was empirically disproved by the arbiter — quotes retained. Tests added for each: symlinked-`files/`, secret-content search, string-`claims`, string-`evidence`, fabricated-citation boundary, plus contract anchors A6/A7.

**Revision note (after blueprint-review iteration 2):** further confirmed fixes: (HIGH) Round-2 prompt now re-states the original question + Round-1 request so the stateless second consult is grounded; (HIGH) the wrapper now sources `evidence-safety.sh` and routes the Round-1 inventory through `emit_nonsecret_z` and the question file through `is_secret_like` *before* the first billed dispatch, so a secret-like tracked path or secret question content cannot be transmitted; (HIGH) the executor gained an upfront jq schema gate rejecting wrong-typed `needed_files`/`search_queries` (no more silent-skip on `"needed_files":"x"`); (MED) the validator now requires each claim to be an object with a non-empty string `.claim` and a non-empty array of non-empty string evidence (closes the `{"claim":null,"evidence":[{}]}` fail-open) with integer-guarded jq so a malformed element yields typed exit 7, not a raw crash; (MED) requested files must be `git ls-files`-tracked (`rejected_untracked`), blocking untracked-scratch exfiltration; (MED) request bounded to ≤64 files / ≤20 queries / ≤256-byte queries; (MED) Task 2 Interfaces rewritten to match the fresh-dir/`files/`-search implementation; (MED) `skipped:user` documented in the Task 4 token list + propagation. New tests: wrong-typed schema (4 shapes), untracked-file, null-claim/object-evidence, bare-string claim element, plus contract anchors A8–A10. Two LOW findings (test reachability nuance, doc completeness) are non-blocking and left as-is.

**Revision note (after blueprint-review iteration 3 — gate auto-stopped `low_issues_only`, but two real HIGHs fixed before implementation):** (HIGH) **gate ordering** in the executor reordered so `is_secret_like` (a content grep with no regular-file guard) runs LAST — after `is_secret_path` (path-only) → `ls-files` tracked → `[[ -f && -r ]]` — so an in-repo FIFO/special file is rejected as untracked and never reaches a blocking read (closes a hang/DoS); (HIGH) the **req7 symlink test** was invoking the script bare under `set -e` (the correct non-zero exit aborted the whole test before its assertion) — now `if`-guarded, and a FIFO no-hang test (`req10`, `timeout`-guarded) added. (MED) search path-filter switched to NUL-delimited `git grep -l -z` so a colon-in-path can't truncate the secret-path check; (MED) `skipped:user`/`skipped:disabled` now exit 0 via a `case` (were exiting 1 like errors); (MED) the executor's manifest announcement moved to stderr so the wrapper's stdout stays token-only. Manifest tokens clarified: `rejected_untracked` (untracked/FIFO/special) and `skipped_unavailable` (not a regular readable file). Deferred (documented, non-blocking): the validator's structural-only boundary (existence-check is the Phase-4 arbiter's job, already documented) and extracting the duplicated fresh-dir guard into a shared helper (maintainability).

**Codex Handoff Eligibility:** Outcome 3 (default executor). Criteria 1, 2, 4, 5 hold, but criterion 3 fails — this is security-sensitive shell whose fail-closed semantics (symlink/traversal rejection, untrusted-JSON handling) warrant Claude's eyes between steps, not a purely verifier-led loop. Tasks are mildly dependent (2/3 depend on 1; 4 depends on 2/3) → `busdriver:executing-plans` (sequential with checkpoints) over subagent fan-out.

<!-- design-reviewed: PASS -->
<!-- design-review-coverage: FULL 3/3  -->
