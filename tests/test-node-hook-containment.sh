#!/usr/bin/env bash
# Test: node-hook environment containment manifest guard (Task 3, ADR 0016).
#
# ADR 0016 contained the shell gates under `env -i` + sanitized-gate.sh but left
# the PURE-BLOCK node hooks inheriting the session env, so a committed
# settings.json `env` block (ECC_HOOK_PROFILE / ECC_DISABLED_HOOKS) could DISABLE
# them. Task 3 wraps those hooks in sanitized-node.sh. This test is the
# UPGRADE-TRIGGER guard: it fails if a new exit-2-capable node hook appears that
# is neither CONTAINED (wrapped) nor explicitly recorded as ACCEPTED RESIDUAL —
# so containment can't silently rot as hooks are added.
#
# Why not "just grep": the discovery grep is a HEURISTIC, not the authority.
# mcp-health-check blocks via `exitCode: shouldFailOpen() ? 0 : 2`, which a naive
# `grep 'exitCode: 2'` misses entirely. The AUTHORITY is the explicit KNOWN_EXIT2
# list below; the grep only forces NEW naive/ternary exit-2 hooks into it.
#
# #629: the source grep alone is not enough of a net. A hook can block without ever
# exiting 2 — `permissionDecision: "deny"` with exitCode 0 is the canonical PreToolUse
# block shape — and then the ONLY place its blocking-ness is declared is its hooks.json
# registration (`--fail-closed` / `|| exit 2`). Discovery is therefore the UNION of the
# source grep and the registration; KNOWN_EXIT2 stays the human authority over both.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOKS_JSON="$REPO_ROOT/hooks/hooks.json"
HOOKS_DIR="$REPO_ROOT/scripts/hooks"
WRAPPER_REF='lib/sanitized-node.sh'
PASS=0
FAIL=0
assert() {  # assert <rc:0/1> <message>
    if [[ "$1" -eq 0 ]]; then PASS=$((PASS+1)); printf '  ok   %s\n' "$2"
    else FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$2"; fi
}

# ── The authoritative classification (maintained by humans, verified below) ──
# CONTAINED: exit-2 is a gate decision that must be wrapped in sanitized-node.sh.
# mcp-health-check.js joined this set in #351: it reads MCP config from the hook
# PAYLOAD cwd (not process.cwd()), so it no longer needs its env re-imported, and
# `env -i` also wipes its ECC_MCP_RECONNECT_COMMAND shell-exec + ECC_MCP_HEALTH_FAIL_OPEN
# injection channels. See docs/adr/0016-gate-env-containment.md.
CONTAINED=(block-no-verify.js config-protection.js pre-bash-dev-server-block.js mcp-health-check.js)
# ACCEPTED RESIDUAL: exit-2 hooks left uncontained because `env -i` would change
# behavior, not just strip the injection flag. Empty since #351.
RESIDUAL=()
# The full known exit-2 universe = CONTAINED ∪ RESIDUAL. The `${RESIDUAL[@]+…}`
# guard keeps an empty RESIDUAL from tripping `set -u` on bash 3.2 (macOS default).
KNOWN_EXIT2=("${CONTAINED[@]}" ${RESIDUAL[@]+"${RESIDUAL[@]}"})
# DENY-CAPABLE: hooks that block via `permissionDecision: "deny"` rather than exit 2.
# Human authority, exactly like KNOWN_EXIT2 and for the same reason — the guard-3c grep
# cannot see a deny moved into a constant, a helper, or onto its own line, so this list is
# what actually pins those hooks. Membership demands CONTAINMENT (env -i + wrapper), NOT
# fail-closedness: gateguard-fact-force.js is `--fail-open … || exit 0` per #616.
KNOWN_DENY=(gateguard-fact-force.js)

in_list() {  # in_list <needle> <list...>
    local n="$1"; shift
    local x; for x in "$@"; do [[ "$x" == "$n" ]] && return 0; done; return 1
}

# ── 1. Every CONTAINED hook's hooks.json registration routes through the wrapper ─
# EVERY registration line that names the hook must (a) begin its command with
# `/usr/bin/env -i` (anchored at the "command": prefix, so env -i is the actual launch
# token — not a stray arg/comment) AND (b) name the wrapper. Per-line, so a duplicate
# registration that splits wrapper and env -i across lines, or one wrapped + one bare
# line, is caught. `env -i` is what wipes ECC_HOOK_PROFILE / ECC_DISABLED_HOOKS (the
# wrapper rebuilds PATH but does NOT itself clear those flags), so dropping it silently
# restores the bypass this task closes.
for h in "${CONTAINED[@]}"; do
    _regs="$(grep "scripts/hooks/$h" "$HOOKS_JSON")"
    _lines=0; _bad=0
    while IFS= read -r _line; do
        [[ -z "$_line" ]] && continue
        _lines=$((_lines+1))
        grep -qE '"command":[[:space:]]*"/usr/bin/env -i ' <<<"$_line" || _bad=1
        grep -q "$WRAPPER_REF" <<<"$_line" || _bad=1
        # Registration-level fail-CLOSED: if bash can't launch the wrapper (bad
        # CLAUDE_PLUGIN_ROOT, missing wrapper, ENOEXEC) the outer command exits
        # 1/126/127 BEFORE the wrapper's internal fail-closed runs — a non-2 exit the
        # harness treats as non-blocking (fail-OPEN). The trailing `|| exit 2` converts
        # any such launch failure to a block.
        grep -q '|| exit 2' <<<"$_line" || _bad=1
    done <<< "$_regs"
    if [[ "$_lines" -ge 1 && "$_bad" -eq 0 ]]; then
        assert 0 "$h: every registration launches via /usr/bin/env -i + sanitized-node.sh, fail-closed with || exit 2"
    else
        assert 1 "$h: every registration launches via /usr/bin/env -i + sanitized-node.sh, fail-closed with || exit 2"
    fi
done

# ── 2. No CONTAINED hook has a bare (un-wrapped) `node run-with-flags.js` line ──
for h in "${CONTAINED[@]}"; do
    if grep "scripts/hooks/$h" "$HOOKS_JSON" | grep -qE '"command":[[:space:]]*"node '; then
        assert 1 "$h has NO bare 'node run-with-flags.js' registration"
    else
        assert 0 "$h has NO bare 'node run-with-flags.js' registration"
    fi
done

# ── 3. Discovery: any registered node hook that exits 2 must be classified ──────
# HEURISTIC net, not the authority (the KNOWN_EXIT2 list is). Tolerant of whitespace
# so `process.exit( 2 )`, `exitCode: 2`, and `exitCode = 2` all match, plus the
# fail-closed ternary `? 0 : 2` (mcp-health-check). A hook that hides its exit-2
# behind a constant or a helper call is genuinely undetectable by grep — that gap is
# WHY the explicit KNOWN_EXIT2 list is the real guard and guard #4 pins the trio.
discover_exit2() {
    { grep -lE 'process\.exit\([[:space:]]*2|exitCode[[:space:]]*[:=][[:space:]]*2' "$HOOKS_DIR"/*.js 2>/dev/null
      grep -lE '\?[[:space:]]*0[[:space:]]*:[[:space:]]*2' "$HOOKS_DIR"/*.js 2>/dev/null
    } | sort -u
}

# The SECOND net (#629): hooks.json declares blocking-ness directly. Any registration
# carrying `|| exit 2` (or `--fail-closed`, should a registration ever pass it — today the
# wrapper appends that token itself) names a blocking gate whatever its script returns,
# including one that blocks purely through `permissionDecision: "deny"` and is invisible to
# the source grep above. Extraction is deliberately UNFILTERED: non-node registrations drop
# out on their own (no scripts/hooks/*.js token), and a future fail-closed registration
# routed through run-with-flags.js should surface loudly rather than be silently excused.
#
# This net covers the FAIL-CLOSED-registration half of #629. A deny-capable hook whose
# registration is NOT fail-closed still blocks (`--fail-open` governs a LAUNCH failure,
# never a successful deny) — guard 3c below is the half that covers it.
discover_registered_blocking() {
    grep -E '"command":.*(--fail-closed|\|\| exit 2)' "$HOOKS_JSON" 2>/dev/null \
      | grep -oE 'scripts/hooks/[A-Za-z0-9._-]+\.js' | sed 's|.*/||' | sort -u
}

# Union of both nets, as basenames.
discover_blocking() {
    # Capture first (SC2312): a pipeline feed would mask each discoverer's rc.
    local _src _reg
    _src="$(discover_exit2)"; _reg="$(discover_registered_blocking)"
    { sed 's|.*/||' <<< "$_src"; printf '%s\n' "$_reg"; } | sed '/^$/d' | sort -u
}

# Blocking hooks wired into hooks.json but absent from KNOWN_EXIT2.
unclassified_blocking() {
    local out="" b _discovered
    # Capture first (SC2312): a process-substitution feed would mask discover_blocking's rc.
    _discovered="$(discover_blocking)"
    while IFS= read -r b; do
        [[ -z "$b" ]] && continue
        # Only care about hooks actually wired into hooks.json.
        grep -q "scripts/hooks/$b" "$HOOKS_JSON" || continue
        in_list "$b" "${KNOWN_EXIT2[@]}" || out+="$b "
    done <<< "$_discovered"
    printf '%s' "$out"
}

unclassified="$(unclassified_blocking)"
if [[ -z "$unclassified" ]]; then
    assert 0 "no unclassified blocking node hooks (all are CONTAINED or ACCEPTED RESIDUAL)"
else
    printf '  ↳ unclassified: %s\n' "$unclassified"
    printf '  ↳ ADD each to CONTAINED (and wrap in hooks.json) or to RESIDUAL (and document in ADR 0016)\n'
    assert 1 "no unclassified blocking node hooks (all are CONTAINED or ACCEPTED RESIDUAL)"
fi

# ── 3b. Regression (#629): the registration net actually fires ──────────────────
# Guard #3 can only prove itself on a tree that HAS an unclassified blocking hook, and the
# real tree does not (#616 landed). So mutate a throwaway tree into exactly the shape that
# used to slip through: a hook that blocks via permissionDecision with exitCode 0, wired in
# with a fail-closed `|| exit 2` registration and absent from KNOWN_EXIT2. The second assert
# is the negative control — it pins that the SOURCE grep misses it, so a pass on the first
# can only come from the registration net.
_fix="$(mktemp -d)"
# Fail CLOSED on a mktemp failure: an empty $_fix would write the fixture to /hooks and
# /scripts/hooks and leave the EXIT trap unable to clean up.
[[ -n "$_fix" && -d "$_fix" ]] || { printf '  FAIL %s\n' "regression fixture tempdir created"; exit 1; }
trap 'rm -rf "$_fix"' EXIT
mkdir -p "$_fix/hooks" "$_fix/scripts/hooks"
cat > "$_fix/scripts/hooks/synthetic-deny-gate.js" <<'JS'
// Blocks via permissionDecision with exitCode 0 — never exits 2, so the source grep
// cannot see it. Only the registration below declares it blocking.
module.exports = () => ({
  stdout: JSON.stringify({ hookSpecificOutput: { permissionDecision: 'deny' } }),
  exitCode: 0,
});
JS
cat > "$_fix/hooks/hooks.json" <<'JSON'
{ "hooks": { "PreToolUse": [ { "matcher": "Edit|Write", "hooks": [ {
  "type": "command",
  "command": "node \"${CLAUDE_PLUGIN_ROOT}/scripts/hooks/synthetic-deny-gate.js\" || exit 2"
} ] } ] } }
JSON
# Subshells so the fixture paths can never leak into the guards below.
_fixture_unclassified="$( HOOKS_JSON="$_fix/hooks/hooks.json"; HOOKS_DIR="$_fix/scripts/hooks"; unclassified_blocking )"
_fixture_src_only="$( HOOKS_DIR="$_fix/scripts/hooks"; discover_exit2 )"
_m1="registration-only permissionDecision gate is discovered and flagged unclassified"
_m2="↳ control: the source grep alone does NOT see it (the registration net is what fired)"
if [[ "$_fixture_unclassified" == *"synthetic-deny-gate.js"* ]]; then assert 0 "$_m1"; else assert 1 "$_m1"; fi
if [[ -z "$_fixture_src_only" ]]; then assert 0 "$_m2"; else assert 1 "$_m2"; fi

# ── 3c. Deny-capable node hooks must be CONTAINED (#629) ───────────────────────
# The third discovery class. `permissionDecision: "deny"` blocks the tool call from a hook
# that ran SUCCESSFULLY, so the registration tail says nothing about it: `--fail-open …
# || exit 0` only resolves a LAUNCH failure to ALLOW. Such a hook is therefore invisible to
# both nets above, and what it must satisfy is CONTAINMENT — `env -i` + the wrapper, so a
# committed settings.json `env` block can't disable it — NOT fail-closedness. Guard #1 is
# left alone deliberately: gateguard-fact-force.js is `--fail-open … || exit 0` by the
# settled #616 decision, and demanding `|| exit 2` of it would reopen that. Same heuristic
# caveat as the exit-2 grep: a deny hidden behind a constant is not greppable, which is why
# the explicit lists stay the human authority.
discover_deny_capable() {
    grep -lE "permissionDecision['\"]?[[:space:]]*:[[:space:]]*['\"]deny" "$HOOKS_DIR"/*.js 2>/dev/null \
      | sed 's|.*/||' | sort -u
}
# Capture first (SC2312): a process-substitution feed would mask discover_deny_capable's rc.
_deny_grep="$(discover_deny_capable)"
# UNION with the human list, so a deny that stops being greppable stays guarded.
_deny="$( { printf '%s\n' "$_deny_grep"; printf '%s\n' "${KNOWN_DENY[@]}"; } | sed '/^$/d' | sort -u )"
while IFS= read -r _dh; do
    [[ -z "$_dh" ]] && continue
    # Only care about hooks actually wired into hooks.json.
    grep -q "scripts/hooks/$_dh" "$HOOKS_JSON" || continue
    _regs="$(grep "scripts/hooks/$_dh" "$HOOKS_JSON")"
    _lines=0; _bad=0
    while IFS= read -r _line; do
        [[ -z "$_line" ]] && continue
        _lines=$((_lines+1))
        grep -qE '"command":[[:space:]]*"/usr/bin/env -i ' <<<"$_line" || _bad=1
        grep -q "$WRAPPER_REF" <<<"$_line" || _bad=1
    done <<< "$_regs"
    _dm="$_dh (deny-capable): every registration launches via /usr/bin/env -i + sanitized-node.sh"
    if [[ "$_lines" -ge 1 && "$_bad" -eq 0 ]]; then assert 0 "$_dm"; else assert 1 "$_dm"; fi
done <<< "$_deny"

# Sanity, mirroring guard #4: the deny grep must still see every listed hook, so a refactor
# that hides the literal is caught here instead of silently shrinking the net.
for _dh in "${KNOWN_DENY[@]}"; do
    _dm="deny grep still detects $_dh"
    if grep -q "^$_dh\$" <<<"$_deny_grep"; then assert 0 "$_dm"; else assert 1 "$_dm"; fi
done

# ── 4. Sanity: the discovery grep actually still finds the CONTAINED trio ───────
# (guards against a future refactor that hides their exit-2 from discovery,
# which would silently weaken guard #3.)
found="$(discover_exit2)"
for h in "${CONTAINED[@]}"; do
    if grep -q "/$h\$" <<<"$found"; then
        assert 0 "discovery grep still detects $h"
    else
        assert 1 "discovery grep still detects $h"
    fi
done

# ── 5. The wrapper exists and is fail-closed (blocks when node/runner absent) ───
[[ -f "$REPO_ROOT/hooks/gate-scripts/lib/sanitized-node.sh" ]]; assert $? "sanitized-node.sh launcher exists"
grep -q '"decision":"block"' "$REPO_ROOT/hooks/gate-scripts/lib/sanitized-node.sh"; assert $? "launcher has a fail-closed block path"

echo ""
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
echo "ALL NODE-HOOK CONTAINMENT ASSERTIONS PASSED"
