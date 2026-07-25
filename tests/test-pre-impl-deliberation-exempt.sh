#!/usr/bin/env bash
# Tests for the pre-implementation gate's F10 deliberation-dispatcher exemption
# (issue #484). When a design review is PENDING, the classification path at
# pre-implementation-gate.sh:764 must let the council / ultra-council /
# ultimate-council, ultraoracle, and dispatch-cli dispatch blocks run — they
# create and clean up their OWN temp/state files (mktemp prompt files, a
# captured result, $STATE_DIR/ultra-oracle output).
#
# The exemption recognizes a dispatcher by its literal plugin script path and
# does NOT validate the rest of the command (delib_gate.py explains why static
# operand validation is unsound: $(mktemp) and $(rm -rf src) are the same shell
# construct). This is a COOPERATIVE gate — any session bypasses via `python -c` —
# so a dispatcher command is exempt wholesale (accepted #484 residual), while a
# command with NO dispatcher path (a bare rm/redirect to a product file) still
# BLOCKS, which is what the gate exists to catch.
#
# Unlike test-pre-implementation-gate.sh (which exercises the UNCONDITIONAL
# marker-forge path), this suite arms a real pending marker in a throwaway git
# repo so the classification path actually runs. Isolated temp repo → the real
# repo's markers are never touched.
#
# Usage: bash tests/test-pre-impl-deliberation-exempt.sh
# Exit: 0 if all pass, 1 if any fail.

# shellcheck disable=SC2312  # run_test captures the gate's JSON decision, not pipe status
# shellcheck disable=SC2016  # JSON command payloads are literal on purpose — no shell expansion
set -euo pipefail
cd "$(dirname "$0")/.."

GATE="$PWD/hooks/gate-scripts/pre-implementation-gate.sh"
LIB="$PWD/hooks/gate-scripts/lib/marker_ops.py"

PASS=0
FAIL=0
TOTAL=0

# Arm a pending design-review marker in an isolated temp git repo, then cd into
# it so the gate's anchor (cwd) resolves the marker dir to THIS repo's .git.
TD="$(mktemp -d)"
trap 'rm -rf "$TD"' EXIT
git -C "$TD" init -q
git -C "$TD" config user.email t@t.co
git -C "$TD" config user.name t
python3 "$LIB" arm "$TD/.git/busdriver/design-review-needed.local.d" "docs/plans/pending.md" >/dev/null

run_test() {
    local name="$1" expected="$2" cmd="$3" output got
    TOTAL=$((TOTAL + 1))
    output=$(cd "$TD" && printf '{"tool_name":"Bash","tool_input":{"command":%s}}' "$cmd" | bash "$GATE" 2>/dev/null || true)
    if echo "$output" | grep -q '"block"'; then got="block"; else got="allow"; fi
    if [[ "$got" == "$expected" ]]; then
        printf "  PASS  %s\n" "$name"; PASS=$((PASS + 1))
    else
        printf "  FAIL  %s (expected=%s got=%s)\n" "$name" "$expected" "$got"; FAIL=$((FAIL + 1))
    fi
}

echo "── delib_gate.py unit self-check ────────────────────────────────"
# The classifier's own vectors (heredoc/comment/quote/cmd-sub laundering) run as
# a fast unit check before the slower through-the-gate integration cases.
TOTAL=$((TOTAL + 1))
if python3 hooks/gate-scripts/lib/delib_gate.py --selftest >/dev/null 2>&1; then
    printf "  PASS  delib_gate --selftest\n"; PASS=$((PASS + 1))
else
    printf "  FAIL  delib_gate --selftest\n"; FAIL=$((FAIL + 1))
fi

echo ""
echo "── sanity: pending marker is active ─────────────────────────────"
# If these allow, the marker isn't pending and every result below is vacuous.
run_test "non-dispatcher redirect to impl blocks" "block" '"echo x > foo.py"'
run_test "non-dispatcher rm blocks"                "block" '"rm -rf src"'

echo ""
echo "── F10: deliberation dispatchers with OWN temp/state mods ───────"
run_test "council: mktemp+rm \$VAR+redirect \$VAR (ultra-oracle-run.sh)" "allow" \
    '"source \"$R/scripts/lib/resolve-cli.sh\"; D=\"$R/skills/dispatch-cli/scripts/dispatch.sh\"; P=\"$(mktemp)\"; bash \"$R/scripts/ultra-oracle-run.sh\" council 0 \"$P\" \"${BUSDRIVER_STATE_DIR:-.claude}/ultra-oracle/c.md\" > \"$RES\" 2>/dev/null; rm -f \"$P\""'
run_test "ultraoracle: build-evidence-pack.sh cmdsub" "allow" \
    '"LABEL=\"$(bash skills/ultraoracle/scripts/build-evidence-pack.sh --mode repo)\""'
run_test "dispatch-cli: heredoc (no file mod at all)" "allow" \
    '"bash skills/dispatch-cli/scripts/dispatch.sh --cli codex <<EOF\nhi\nEOF"'
# The FULL ultra-council block: its own comment mentions `rm -f` and its heredoc
# prompt bodies contain rm/mv/cp/tee/install in prose. Non-executable text must
# be neutralized (heredocs + comments), or the block re-blocks itself (#484 rev).
run_test "REAL ultra-council block (comment + heredoc rm/mv/cp in prose)" "allow" \
    '"\"$D\" --cli agy --timeout 300 <<'\''PRAGMATIST_PROMPT'\'' &\nPlease rm the old design, mv it aside, cp a backup.\nPRAGMATIST_PROMPT\nP=\"$(mktemp)\"\ncat > \"$P\" <<'\''ORACLE'\''\nconsider rm -rf and tee and install in prose\nORACLE\n# The { ...; rm -f ...; } group deletes the prompt file\nbash \"$R/scripts/ultra-oracle-run.sh\" council 0 \"$P\" \"${BUSDRIVER_STATE_DIR:-.claude}/ultra-oracle/c.md\" > \"$RES\" 2>/dev/null; rm -f \"$P\""'

echo ""
echo "── F10 accepted residual: dispatcher path ⇒ exempt wholesale ─────"
# A recognized dispatcher command is exempt even with a destructive tail — the
# SAME residual the gate already carries for `python -c os.remove` (#484). These
# assert ALLOW deliberately: re-adding a static operand scanner to flip them back
# to BLOCK reopens the unsound arms race (six grammar bypasses in #484 review).
run_test "residual: dispatcher && rm -rf src"          "allow" \
    '"bash skills/dispatch-cli/scripts/dispatch.sh --cli codex && rm -rf src"'
run_test "residual: dispatcher ; redirect to impl file" "allow" \
    '"bash skills/ultraoracle/scripts/build-evidence-pack.sh; echo x > app/main.py"'
run_test "residual: dispatcher ; cp to literal impl path" "allow" \
    '"source skills/council/scripts/x.sh; cp /etc/hosts app/config.py"'

echo ""
echo "── the gate's real job: NO dispatcher path ⇒ still BLOCKS ────────"
# What the design gate exists to catch — an accidental product-file mod while a
# design is unreviewed — is untouched: no dispatcher path, no exemption.
run_test "bare rm blocks"                              "block" '"rm -rf src"'
run_test "non-dispatcher script + rm blocks"          "block" \
    '"bash scripts/other.sh; rm -rf src"'
run_test "non-dispatcher sed -i to impl blocks"       "block" \
    '"sed -i s/a/b/ lib/core.py"'

echo ""
echo "═══════════════════════════════════════════════════════════════"
printf "Results: %d/%d passed" "$PASS" "$TOTAL"
if [[ "$FAIL" -gt 0 ]]; then printf " (%d FAILED)\n" "$FAIL"; exit 1; else printf " (all passed)\n"; exit 0; fi
