#!/usr/bin/env bash
# Test: passwd-HOME derivation must not resolve its tools through a user-writable
# PATH dir — issue #660.
#
# Both containment wrappers rebuild a fixed PATH allowlist whose first entries
# (/usr/local/bin, /opt/homebrew/bin) are OPERATOR-WRITABLE on a default Homebrew
# install, and THEN shell out to id/getent/dscl to derive the trusted HOME. macOS
# ships no `getent` at all, so a planted one is found with no binary to shadow and
# its stdout becomes HOME for every contained gate. The fix derives HOME on a
# root-only PATH and restores the wide PATH afterwards.
#
# The fixture can't write /opt/homebrew/bin, so it SUBSTITUTES a writable plant dir
# into the copy's allowlist — a faithful stand-in for the writable entry that is
# already there. Guards against vacuous passes: the decoy home must EXIST (the
# wrapper rejects a non-dir home and would fall through to the real one), the
# substitution must be verified to have taken, and a deliberately un-fixed copy is
# run as a positive control so the fixture is proven able to fail.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATE_WRAPPER="$REPO_ROOT/hooks/gate-scripts/lib/sanitized-gate.sh"
NODE_WRAPPER="$REPO_ROOT/hooks/gate-scripts/lib/sanitized-node.sh"
PASS=0
FAIL=0
assert() {
    if [[ "$1" -eq 0 ]]; then PASS=$((PASS+1)); printf '  ok   %s\n' "$2"
    else FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$2"; fi
}

# No `set -e` here (assertions rely on non-zero rc), so bail explicitly: an empty TMP
# would make every path below resolve at the filesystem root.
_user="$(/usr/bin/id -un)" || { echo "cannot resolve user" >&2; exit 1; }
REAL_HOME="$(eval echo "~$_user")"
[[ -n "$REAL_HOME" && -d "$REAL_HOME" ]] || { echo "cannot resolve real home" >&2; exit 1; }
TMP="$(mktemp -d)"
[[ -n "$TMP" && -d "$TMP" ]] || { echo "mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT

PLANT="$TMP/writable_bin"
DECOY="$TMP/decoy_home"
mkdir -p "$PLANT" "$DECOY" "$TMP/root/hooks/gate-scripts/lib" "$TMP/root/scripts/hooks"

# Planted lookups, as reachable from a writable PATH dir as the real ones.
cat > "$PLANT/getent" <<PLANTED
#!/bin/sh
printf '%s:x:501:20::$DECOY:/bin/sh\n' "\$2"
PLANTED
cat > "$PLANT/id" <<'PLANTED'
#!/bin/sh
echo decoyuser
PLANTED
chmod +x "$PLANT/getent" "$PLANT/id"

# ── Copy each wrapper with the plant dir substituted into the PATH allowlist ──
install_wrapper() {  # install_wrapper <src> <dest> [--unfixed]
    sed "s|^for _d in /usr/local/bin|for _d in $PLANT /usr/local/bin|" "$1" > "$2"
    if [[ "${3:-}" == "--unfixed" ]]; then
        # Positive control: drop the root-only derivation PATH, restoring the #660 bug.
        sed -i.bak '/^export PATH=\/usr\/bin:\/bin:\/usr\/sbin:\/sbin$/d' "$2" && rm -f "$2.bak"
    fi
    grep -q "for _d in $PLANT " "$2"
}

# ── Leg 1: sanitized-gate.sh ────────────────────────────────────────────────
cat > "$TMP/root/hooks/gate-scripts/_probe.sh" <<'PROBE'
echo "HOME=[${HOME:-}]"
PROBE
install_wrapper "$GATE_WRAPPER" "$TMP/root/hooks/gate-scripts/lib/sanitized-gate.sh"
assert $? "fixture is live: plant dir substituted into sanitized-gate.sh's PATH allowlist"

gate_out="$(/usr/bin/env -i PATH=/usr/bin:/bin HOME="$DECOY" CLAUDE_PLUGIN_ROOT="$TMP/root" \
    bash "$TMP/root/hooks/gate-scripts/lib/sanitized-gate.sh" _probe.sh 2>&1)"
grep -q "HOME=\[$REAL_HOME\]" <<<"$gate_out"
assert $? "sanitized-gate.sh: HOME comes from the real passwd entry, not the planted getent ($gate_out)"

# Positive control — same fixture, wrapper without the root-only derivation PATH.
install_wrapper "$GATE_WRAPPER" "$TMP/root/hooks/gate-scripts/lib/unfixed.sh" --unfixed
unfixed_out="$(/usr/bin/env -i PATH=/usr/bin:/bin HOME="$DECOY" CLAUDE_PLUGIN_ROOT="$TMP/root" \
    bash "$TMP/root/hooks/gate-scripts/lib/unfixed.sh" _probe.sh 2>&1)"
grep -q "HOME=\[$DECOY\]" <<<"$unfixed_out"
assert $? "positive control: without the root-only PATH the plant DOES win ($unfixed_out) — fixture can fail"

# ── Leg 2: sanitized-node.sh ────────────────────────────────────────────────
# The wrapper hardcodes scripts/hooks/run-with-flags.js as the runner and verifies
# the named hook script exists, so the skeleton supplies both. The runner must parse
# under `node --check` (the wrapper's node-validation step).
cat > "$TMP/root/scripts/hooks/run-with-flags.js" <<'RUNNER'
console.log("HOME=[" + (process.env.HOME || "") + "]");
RUNNER
: > "$TMP/root/scripts/hooks/probe.js"
install_wrapper "$NODE_WRAPPER" "$TMP/root/hooks/gate-scripts/lib/sanitized-node.sh"
assert $? "fixture is live: plant dir substituted into sanitized-node.sh's PATH allowlist"

node_out="$(/usr/bin/env -i PATH=/usr/bin:/bin HOME="$DECOY" CLAUDE_PLUGIN_ROOT="$TMP/root" \
    CLAUDE_HOOK_EVENT_NAME=PreToolUse \
    bash "$TMP/root/hooks/gate-scripts/lib/sanitized-node.sh" "pre:probe" "scripts/hooks/probe.js" 2>&1)"
grep -q "HOME=\[$REAL_HOME\]" <<<"$node_out"
assert $? "sanitized-node.sh: contained hook inherits the real passwd HOME, not the planted one ($node_out)"

echo ""
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
echo "ALL #660 PASSWD-HOME ASSERTIONS PASSED"
