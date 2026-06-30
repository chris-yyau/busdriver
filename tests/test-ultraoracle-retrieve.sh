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
# Security property (token-agnostic): the secret is whole-file-excluded, so config.txt's hits
# never stage and NO search artifact is written — the secret string must be absent from files/.
if ! grep -rq "sk-ant-api03" "$TMP/o8/files" 2>/dev/null && ! ls "$TMP/o8/files/"*search* >/dev/null 2>&1; then
  ok "secret-content search excluded"; else fail "secret content leaked via search"; fi

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

# embedded-newline path => rejected at the schema gate (control-char rule), never split into
# a second retrieval. Without the guard, jq -r + newline `read` would split "app.sh\nconfig.txt"
# and retrieve the tracked app.sh from the smuggled second line. Either way: no app.sh copied.
printf '{ "needed_files": [ {"path": "app.sh\\nconfig.txt", "reason": "r"} ], "search_queries": [] }' > req11.json
run --request-file "$TMP/req11.json" --out-dir "$TMP/o11" >/dev/null 2>&1 || true
if ! ls "$TMP/o11/files/"*app.sh >/dev/null 2>&1; then
  ok "embedded-newline path not split (no app.sh retrieved)"; else fail "embedded-newline path split into extra retrieval"; fi

# a search hit whose bytes exceed the budget => REJECTED (not truncated-and-sent). The "real"
# match in app.sh (~20-byte hit line) overflows a 5-byte budget, so no artifact reaches files/.
cat > req12.json <<JSON
{ "needed_files": [], "search_queries": [ {"query": "real", "reason": "r"} ] }
JSON
run --request-file "$TMP/req12.json" --out-dir "$TMP/o12" --byte-budget 5 >/dev/null 2>&1 || true
if ! ls "$TMP/o12/files/"*search* >/dev/null 2>&1 && grep -q "skipped_over_budget_search:" "$TMP/o12/manifest.txt"; then
  ok "over-budget search rejected, not truncated"; else fail "over-budget search not rejected"; fi

echo "Results: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
