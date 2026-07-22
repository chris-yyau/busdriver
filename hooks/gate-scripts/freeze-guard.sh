#!/usr/bin/env bash
# PreToolUse hook: restrict Write/Edit to a single directory during debugging
#
# When .claude/freeze-scope.local exists, blocks Write/Edit operations
# targeting files outside the allowed directory. This prevents agents from
# accidentally modifying unrelated files during focused debugging sessions.
#
# State file format (.claude/freeze-scope.local):
#   Line 1: absolute or relative path to allowed directory
#
# Activate: echo "src/auth" > .claude/freeze-scope.local
# Deactivate: rm .claude/freeze-scope.local
#
# The systematic-debugging skill auto-activates this when entering Phase 1.

set -euo pipefail

FREEZE_FILE=".claude/freeze-scope.local"

# No freeze active → approve immediately
[ ! -f "$FREEZE_FILE" ] && exit 0

# Read allowed scope
ALLOWED_SCOPE=$(head -1 "$FREEZE_FILE" 2>/dev/null || true)
[ -z "$ALLOWED_SCOPE" ] && exit 0

# ── Block emission helper ────────────────────────────────────────────
block_emit() {
    if command -v jq &>/dev/null; then
        jq -n --arg r "$1" '{decision:"block", reason:$r}'
    elif command -v python3 &>/dev/null; then
        # python3 is a hard dependency of these gates; json.dumps escapes
        # backslashes, quotes, newlines and control chars that sed alone cannot.
        printf '%s' "$1" | python3 -I -c 'import json,sys; sys.stdout.write(json.dumps({"decision":"block","reason":sys.stdin.read()}))'
        printf '\n'
    else
        # Last resort (no jq, no python3 — must still emit a block or the gate
        # fails OPEN). Delete the two JSON-special bytes (" = \042, \\ = \134) and
        # every control char, so the surviving text needs no escaping at all.
        # Lossy but always valid JSON; this tier only serializes fixed gate
        # messages, which contain neither a quote nor a backslash.
        local escaped
        escaped=$(printf '%s' "$1" | tr -d '\042\134' | tr '\n\r\t' '   ' | tr -d '\000-\037')
        printf '{"decision":"block","reason":"%s"}\n' "$escaped"
    fi
}

# Consume stdin
INPUT=$(cat 2>/dev/null || true)
[[ -z "$INPUT" ]] && exit 0

# ── Fail CLOSED when python3 is unavailable ──────────────────────────
# A freeze is active (checked above) but without python3 we cannot parse the
# tool input to learn the target path. Every sibling gate blocks in this state;
# freeze-guard must too, or it silently fails OPEN and lets out-of-scope edits
# through. The matcher is Write|Edit|MultiEdit only, so blocking here never
# touches Bash — `rm .claude/freeze-scope.local` still unfreezes.
if ! command -v python3 &>/dev/null; then
    block_emit "FREEZE/GUARD: python3 not found — cannot verify the edit target while a freeze is active, so this write is blocked (fail-closed).

Allowed scope: $ALLOWED_SCOPE

Install python3 to restore scope checking, or unfreeze via Bash: rm .claude/freeze-scope.local"
    exit 0
fi

# ── Shared repo-relative resolver (#375) ─────────────────────────────
# gate_repo_rel_phys anchors the infra-exemption arms AND the scope check to the
# write's OWNING worktree: realpath resolves every symlink and repo-relativity
# strips the worktree/ancestor prefix. This closes two fail-opens the LEXICAL
# match had — an absolute worktree path was blanket-exempt by `*.claude/*` (busdriver
# homes worktrees under <main>/.claude/worktrees/), and a symlinked `docs/specs -> src`
# laundered impl writes past the docs arm.
_GATE_LIBDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
# shellcheck source=lib/resolve-repo-dir.sh disable=SC1091
source "$_GATE_LIBDIR/resolve-repo-dir.sh"

# ── Parse tool name and file path, join a relative path to the payload cwd ──
# shellcheck disable=SC2016  # python3 -c program; $/quotes are literal code
PARSED=$(printf '%s' "$INPUT" | python3 -I -c '
import sys
sys.path[:] = [p for p in sys.path if p not in ("", ".")]
import json, os
try:
    d = json.load(sys.stdin)
    tool = d.get("tool_name", d.get("toolName", ""))
    inp = d.get("tool_input", d.get("toolInput", {}))
    if isinstance(inp, str):
        inp = json.loads(inp)
    fp = inp.get("file_path", inp.get("filePath", ""))
    if not fp and tool == "MultiEdit":
        # MultiEdit carries file_path at the top level in the common case;
        # fall back to the first edits[] entry, mirroring the sibling hooks
        # (post-edit-accumulator.js, gateguard-fact-force.js).
        edits = inp.get("edits", [])
        if isinstance(edits, list) and edits and isinstance(edits[0], dict):
            fp = edits[0].get("file_path", edits[0].get("filePath", ""))
    # Coerce non-string fp/cwd to their empty forms BEFORE any os.path call. A truthy
    # non-string cwd (malformed payload) would make os.path.isabs(cwd) raise, and the
    # broad except would print "|" — erasing TOOL_NAME so the tool switch fast-ALLOWS
    # a Write without a scope check (fail-open). Coercing keeps the tool gated.
    if not isinstance(fp, str):
        fp = ""
    if not fp:
        print(tool + "|")
    else:
        # #375 residual 2 — join a RELATIVE file_path to the PAYLOAD cwd (where the
        # write lands) so `../docs/specs/x.md` from a subdir cwd resolves into the repo
        # instead of tripping the traversal fail-closed arm. Absolute fp is used as-is.
        # Fall back to the gate process cwd (== repo root while a freeze is active — the
        # FREEZE_FILE is found relative to it) only when the payload gives no absolute
        # cwd; that matches the pre-fix behavior, never worse. LEFT UN-normalized so
        # realpath (in gate_repo_rel_phys) resolves symlinks BEFORE any `..` collapse.
        cwd = d.get("cwd")
        if not isinstance(cwd, str):
            cwd = None
        if os.path.isabs(fp):
            target = fp
        elif cwd and os.path.isabs(cwd):
            target = os.path.join(cwd, fp)
        else:
            target = os.path.join(os.getcwd(), fp)
        print(tool + "|" + target)
except Exception:
    print("|")
' 2>/dev/null || echo "|")
TOOL_NAME="${PARSED%%|*}"
TARGET="${PARSED#*|}"

# Only gate Write, Edit, and MultiEdit tools
case "$TOOL_NAME" in
    Write|Edit|MultiEdit) ;;
    *) exit 0 ;;
esac

# No file path → approve
[[ -z "$TARGET" ]] && exit 0

# Repo-relative, symlink-resolved write target, BOUND to this freeze's own repo
# (anchor "." = the gate cwd, where .claude/freeze-scope.local was found). A target
# in a DIFFERENT repo that happens to share the frozen relative path (e.g.
# /other/repo/src/auth/x) resolves to an ABSOLUTE path here, not `src/auth/x`, so it
# cannot alias into this repo's scope. Empty/absolute/traversing → fail-CLOSED below.
REPO_REL="$(gate_repo_rel_phys "$TARGET" "." 2>/dev/null || true)"

# ── Always allow writes to infrastructure paths ──────────────────────
# Matched against the REPO-RELATIVE, symlink-resolved target (#375), so:
#   - an absolute worktree path resolves to `src/…` (its worktree root strips the
#     <main>/.claude/worktrees/<name>/ prefix) and is NO LONGER blanket-exempt by
#     `*.claude/*` — the pre-existing fail-open;
#   - a symlinked `docs/specs -> src` resolves to `src/…` and cannot launder an
#     impl write past the docs arm.
# The docs/ arms keep `docs` at a segment start so nested monorepo docs
# (packages/foo/docs/specs/) still resolve, matching the design-doc detector.
# FAIL-CLOSED: an unresolved (empty), out-of-repo (absolute, leading-/), or still-
# traversing REPO_REL grants NO exemption — fall through to the scope check.
FILE_LOWER=$(printf '%s' "$REPO_REL" | tr '[:upper:]' '[:lower:]')
case "$REPO_REL" in
    ""|/*|../*|*/../*|*/..) ;;
    *)
        case "$FILE_LOWER" in
            *.claude/*) exit 0 ;;
            *claude.md|*notes.md) exit 0 ;;
        esac
        case "$FILE_LOWER" in
            docs/plans/*|*/docs/plans/*) exit 0 ;;
            docs/specs/*|*/docs/specs/*) exit 0 ;;
            docs/reviews/*|*/docs/reviews/*) exit 0 ;;
        esac
        ;;
esac

# ── Check if file is within allowed scope — ABSOLUTE physical containment ──
# Both the target and the scope are realpath-resolved and compared as absolute
# paths (exact, or a `/`-bounded prefix). This is robust where a repo-relative
# compare is brittle: a symlinked scope (`src-link -> src/auth`), an absolute scope,
# or a scope equal to a worktree root all resolve to the same physical frame as the
# target, and a target in a DIFFERENT repo has a different absolute prefix so it can
# never satisfy this repo's scope (cross-repo aliasing). A relative scope resolves
# against the gate cwd (== repo root while a freeze is active). FAIL-CLOSED: any
# resolution error prints "out" → block.
# shellcheck disable=SC2016  # python3 -c program; $/quotes are literal code
IN_SCOPE=$(TARGET="$TARGET" SCOPE="$ALLOWED_SCOPE" python3 -I -c '
import sys
sys.path[:] = [p for p in sys.path if p not in ("", ".")]
import os
try:
    t = os.path.realpath(os.environ["TARGET"])
    s = os.path.realpath(os.environ["SCOPE"])
    # realpath returns a trailing "/" only for root; use it as-is so a root scope
    # ("/") does not become "//" and reject every descendant. Any other scope gets
    # one boundary "/" appended so a sibling prefix (src/authx vs src/auth) cannot match.
    sep = s if s.endswith("/") else s + "/"
    print("in" if (t == s or t.startswith(sep)) else "out")
except Exception:
    print("out")
' 2>/dev/null || echo "out")
[[ "$IN_SCOPE" == "in" ]] && exit 0

# ── Block: file is outside frozen scope ──────────────────────────────
REASON="FREEZE/GUARD: Edit blocked — file is outside the investigation scope.

Allowed scope: $ALLOWED_SCOPE
Blocked file:  ${REPO_REL:-$TARGET}

During debugging, edits are restricted to the investigation directory to prevent
accidental changes to unrelated code. This is enforced by .claude/freeze-scope.local.

To expand scope: echo \"new/path\" > .claude/freeze-scope.local
To unfreeze:     rm .claude/freeze-scope.local"

block_emit "$REASON"
