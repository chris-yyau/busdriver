#!/usr/bin/env bash
# tests/test-ultraoracle-evidence-safety.sh
# Unit test for the extracted evidence-safety.sh lib (ADR 0007 Phase 5 Task 1).
# Verifies the secret-scan + containment gates in isolation so that both
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
is_secret_basename ".env" && ok "secret: .env" || fail ".env not flagged"
is_secret_basename "API_TOKEN" && ok "secret: API_TOKEN" || fail "API_TOKEN not flagged"
is_secret_basename "deploy.pem" && ok "secret: *.pem" || fail "*.pem not flagged"
is_secret_basename "app.sh" && fail "app.sh wrongly flagged" || ok "non-secret: app.sh"

# secret in an ancestor directory component
is_secret_path "secrets/config.yml" && ok "secret ancestor dir" || fail "secrets/ dir not flagged"

# containment: in-repo file resolves; out-of-repo / traversal rejected
echo hi > "$GIT_ROOT/real.txt"
contained_path "$GIT_ROOT/real.txt" >/dev/null && ok "in-repo contained" || fail "in-repo rejected"
contained_path "/etc/passwd" >/dev/null && fail "abs out-of-repo accepted" || ok "abs out-of-repo rejected"
contained_path "$GIT_ROOT/../../etc/passwd" >/dev/null && fail "traversal accepted" || ok "traversal rejected"

# symlink rejection (a symlink whose target is outside must not slip through)
ln -s /etc/hosts "$GIT_ROOT/link"
contained_path "$GIT_ROOT/link" >/dev/null && fail "symlink accepted" || ok "symlink rejected"

echo "Results: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
