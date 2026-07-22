#!/usr/bin/env bash
# Hermetic regression tests for freeze-guard.sh repo-relative anchoring (#375).
#
# The pre-existing tests/test-gate-adversarial.sh runs against the live repo cwd,
# which can't create a real git worktree or a docs/specs symlink without polluting
# it. These three cases each need that setup, so they get a throwaway temp repo:
#
#   A. An absolute path INTO a real linked worktree homed under .claude/worktrees/
#      is NOT blanket-exempt by the `*.claude/*` arm (the CodeRabbit #170 fail-open).
#   B. A pre-existing `docs/specs -> src` symlink cannot launder an impl write past
#      the docs arm (CodeRabbit #170 symlink half).
#   C. A relative `../docs/specs/x-design.md` from a subdir payload cwd stays
#      writable — it is joined to the cwd, not tripped by the traversal arm
#      (CodeRabbit #126, relative-cwd join).
#
# Usage: bash tests/test-freeze-guard-anchoring.sh   (exit 0 all pass, 1 on any fail)

set -uo pipefail

FREEZE_SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/hooks/gate-scripts/freeze-guard.sh"

PASS=0
FAIL=0

# Setup guard — a false setup must FAIL the suite, not silently let a case pass for
# the wrong reason (e.g. a repo that never got created makes a path "outside every
# repo", which also blocks — masking the common-dir mismatch the test claims). set -e
# is avoided (it fights run_case's `|| rc=$?`); assert the critical invariants instead.
require() {   # <human-msg> <cmd...>
    if "${@:2}" >/dev/null 2>&1; then return 0; fi
    printf "  FAIL  setup: %s\n" "$1"; FAIL=$((FAIL + 1)); return 1
}

# Run the guard with the gate process cwd set to $1 (so it finds that repo's
# .claude/freeze-scope.local) and the JSON payload $2. Classify block vs allow vs
# crash — a non-zero exit with NO output is a broken guard, NOT an allow, so an
# expected-allow case can't pass by silently crashing (litmus PR finding).
run_case() {
    local name="$1" expected="$2" runcwd="$3" input="$4" output rc got
    output=$( cd "$runcwd" && printf '%s' "$input" | bash "$FREEZE_SCRIPT" 2>/dev/null ) && rc=0 || rc=$?
    # A `"block"` decision on stdout is authoritative. Otherwise a NON-ZERO exit is a
    # crash (never "allow") — even with a nonempty diagnostic on stdout, so a broken
    # guard cannot green an expected-allow case. Only exit 0 without a block is allow.
    if printf '%s' "$output" | grep -q '"block"'; then
        got="block"
    elif [[ "$rc" -ne 0 ]]; then
        got="crash"
    else
        got="allow"
    fi
    if [[ "$got" == "$expected" ]]; then
        printf "  PASS  %s\n" "$name"; PASS=$((PASS + 1))
    else
        printf "  FAIL  %s (expected=%s got=%s)\n    output: %s\n" "$name" "$expected" "$got" "$output"
        FAIL=$((FAIL + 1))
    fi
}

# ── Hermetic temp repo ────────────────────────────────────────────────
T="$(mktemp -d)"
# HARD guard: an empty/failed mktemp would turn `rm -rf "$T/docs/specs"` into
# `rm -rf "/docs/specs"` (data loss). Since the suite deliberately runs without
# `set -e`, assert T is a real directory before anything derives paths from it.
[[ -n "$T" && -d "$T" ]] || { echo "FATAL: mktemp -d failed"; exit 1; }
# macOS /tmp is a symlink to /private/tmp; resolve so the payload cwd we pass and
# the guard's realpath-based resolution agree on the same physical root.
T="$(cd "$T" && pwd -P)"
[[ -n "$T" && -d "$T" ]] || { echo "FATAL: could not resolve temp dir"; exit 1; }
trap 'git -C "$T" worktree remove --force "$T/.claude/worktrees/wt" 2>/dev/null || true; git -C "$T" worktree remove --force "$T-siblingB" 2>/dev/null || true; rm -rf "$T" "$T-siblingB"' EXIT

git -C "$T" init -q
git -C "$T" config user.email t@t.t
git -C "$T" config user.name t
git -C "$T" config commit.gpgsign false   # override a signing-on global; keep hermetic
mkdir -p "$T/.claude" "$T/src/auth" "$T/src/payments" "$T/docs/specs"
echo "src/auth" > "$T/.claude/freeze-scope.local"
: > "$T/docs/specs/.keep"
git -C "$T" add -A >/dev/null 2>&1
git -C "$T" commit -qm init
require "temp repo T is a work tree" git -C "$T" rev-parse --is-inside-work-tree
require "freeze scope file present" test -f "$T/.claude/freeze-scope.local"

echo "── freeze-guard repo-relative anchoring (#375) ───────────────"

# Sanity: an in-scope write (absolute path) is allowed; an out-of-scope one blocks.
run_case "in-scope absolute write allowed" "allow" "$T" \
    "{\"tool_name\":\"Write\",\"cwd\":\"$T\",\"tool_input\":{\"file_path\":\"$T/src/auth/login.js\"}}"
run_case "out-of-scope absolute write blocked" "block" "$T" \
    "{\"tool_name\":\"Write\",\"cwd\":\"$T\",\"tool_input\":{\"file_path\":\"$T/src/payments/x.js\"}}"

# ── A. Absolute path into a real linked worktree under .claude/worktrees/ ──
# Without repo-relative anchoring the `*.claude/*` arm exempts EVERY such path
# (the worktree home is <main>/.claude/worktrees/). With it, the path resolves to
# the worktree's own `src/payments/impl.sh`, outside the frozen `src/auth` scope.
git -C "$T" worktree add -q -b wt "$T/.claude/worktrees/wt" >/dev/null 2>&1
require "linked worktree created" git -C "$T/.claude/worktrees/wt" rev-parse --is-inside-work-tree
mkdir -p "$T/.claude/worktrees/wt/src/payments"
run_case "absolute worktree path NOT blanket-exempt by .claude/*" "block" "$T" \
    "{\"tool_name\":\"Write\",\"cwd\":\"$T\",\"tool_input\":{\"file_path\":\"$T/.claude/worktrees/wt/src/payments/impl.sh\"}}"
# A genuine .claude/ infra write inside the worktree still resolves to `.claude/…`
# and stays exempt (control — proves we didn't just block everything).
run_case "genuine .claude/ infra write inside worktree still exempt" "allow" "$T" \
    "{\"tool_name\":\"Write\",\"cwd\":\"$T\",\"tool_input\":{\"file_path\":\"$T/.claude/worktrees/wt/.claude/notes/x.md\"}}"

# ── B. Pre-existing docs/specs -> src symlink cannot launder an impl write ──
rm -rf "$T/docs/specs"
ln -s ../src "$T/docs/specs"          # docs/specs now physically points at src/
run_case "symlinked docs/specs -> src cannot launder impl write" "block" "$T" \
    "{\"tool_name\":\"Write\",\"cwd\":\"$T\",\"tool_input\":{\"file_path\":\"$T/docs/specs/payments/impl.sh\"}}"
# Restore a real docs/specs for case C.
rm -f "$T/docs/specs"
mkdir -p "$T/docs/specs"

# ── C. Relative ../docs/specs/x-design.md from a subdir PAYLOAD cwd ──
# The gate runs from $T (so it FINDS .claude/freeze-scope.local — the freeze must be
# active for this to test anything), while the PAYLOAD cwd is the subdir $T/src. The
# guard must join the payload cwd before normalizing, so the write lands in the real
# docs/specs/ (exempt) instead of tripping the traversal fail-closed arm.
run_case "relative ../docs/specs from subdir payload cwd stays writable" "allow" "$T" \
    "{\"tool_name\":\"Write\",\"cwd\":\"$T/src\",\"tool_input\":{\"file_path\":\"../docs/specs/x-design.md\"}}"

# ── D. Cross-repo alias cannot satisfy this repo's freeze scope ──
# A DIFFERENT repo whose path shares the frozen relative scope (src/auth/) must NOT
# resolve to `src/auth/…` in this repo's frame — that would alias past the freeze
# (litmus PR HIGH). Binding to the anchor repo's git-common-dir keeps it absolute.
O="$(mktemp -d)"
[[ -n "$O" && -d "$O" ]] || { echo "FATAL: mktemp -d (O) failed"; exit 1; }
O="$(cd "$O" && pwd -P)"
[[ -n "$O" && -d "$O" ]] || { echo "FATAL: could not resolve temp dir O"; exit 1; }
git -C "$O" init -q
git -C "$O" config commit.gpgsign false
mkdir -p "$O/src/auth"
# Must be a REAL, distinct repo (its own git-common-dir), else the target is merely
# "outside every repo" and the block would not exercise the common-dir mismatch.
require "cross-repo O is a distinct work tree" git -C "$O" rev-parse --is-inside-work-tree
run_case "cross-repo same-relative-path write NOT aliased into scope" "block" "$T" \
    "{\"tool_name\":\"Write\",\"cwd\":\"$T\",\"tool_input\":{\"file_path\":\"$O/src/auth/x.js\"}}"
rm -rf "$O"

# ── E. A genuinely SIBLING (non-nested) linked worktree's own docs/specs/.claude
#      files must NOT gain the always-allow infra exemption just because they
#      resolve relative to THAT worktree's own root (Greptile P1, PR #457). Unlike
#      case A's worktree (physically nested under $T/.claude/worktrees/), $S here
#      is a separate top-level directory linked to the same repo — same
#      git-common-dir, but NOT nested under $T's own tree.
S="$T-siblingB"
git -C "$T" worktree add -q -b wtSibling "$S" >/dev/null 2>&1
require "sibling linked worktree created" git -C "$S" rev-parse --is-inside-work-tree
mkdir -p "$S/docs/specs"
echo "plan" > "$S/docs/specs/plan.md"
run_case "sibling (non-nested) worktree's own docs/specs NOT blanket-exempt" "block" "$T" \
    "{\"tool_name\":\"Write\",\"cwd\":\"$T\",\"tool_input\":{\"file_path\":\"$S/docs/specs/plan.md\"}}"
git -C "$T" worktree remove --force "$S" 2>/dev/null || true
rm -rf "$S"

echo ""
echo "═══════════════════════════════════════════════════════════════"
printf "Results: %d/%d passed" "$PASS" "$((PASS + FAIL))"
if [[ "$FAIL" -gt 0 ]]; then printf " (%d FAILED)\n" "$FAIL"; exit 1; else printf " (all passed)\n"; exit 0; fi
