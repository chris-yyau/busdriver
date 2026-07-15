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
# CONTAINED: exit-2 is a PURE gate decision from stdin/filePath — must be wrapped.
CONTAINED=(block-no-verify.js config-protection.js pre-bash-dev-server-block.js)
# ACCEPTED RESIDUAL: exit-2 is env-DRIVEN (reads behavior-affecting vars), so
# `env -i` would change behavior, not just strip the injection flag; defaults
# fail-closed. Documented in docs/adr/0016-gate-env-containment.md.
RESIDUAL=(mcp-health-check.js)
# The full known exit-2 universe = CONTAINED ∪ RESIDUAL.
KNOWN_EXIT2=("${CONTAINED[@]}" "${RESIDUAL[@]}")

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

unclassified=""
# Capture first (SC2312): a process-substitution feed would mask discover_exit2's rc.
_discovered="$(discover_exit2)"
while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    b=$(basename "$f")
    # Only care about hooks actually wired into hooks.json.
    grep -q "scripts/hooks/$b" "$HOOKS_JSON" || continue
    if ! in_list "$b" "${KNOWN_EXIT2[@]}"; then
        unclassified+="$b "
    fi
done <<< "$_discovered"

if [[ -z "$unclassified" ]]; then
    assert 0 "no unclassified exit-2 node hooks (all are CONTAINED or ACCEPTED RESIDUAL)"
else
    printf '  ↳ unclassified: %s\n' "$unclassified"
    printf '  ↳ ADD each to CONTAINED (and wrap in hooks.json) or to RESIDUAL (and document in ADR 0016)\n'
    assert 1 "no unclassified exit-2 node hooks (all are CONTAINED or ACCEPTED RESIDUAL)"
fi

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
