#!/usr/bin/env bash
# #912: a PreToolUse payload with no absolute `cwd` must BLOCK, not fall back to the
# hook process's own working directory.
#
# cursor-agent sends imported Claude-plugin hooks `"cwd": ""`, and runs them from the
# plugin cache, which sits inside the ~/.claude repo. gate_resolve_repo_dir used to
# anchor on `${hook_cwd:-.}`, so the gate checked whatever repo the HOOK ran in, not
# the one the command runs in. From a directory outside every repo it resolved
# `outside-repo`, which pre-commit and pre-PR approve outright.
#
# Each gated caller is fed its own command with the cwd absent, empty and relative,
# from a hook cwd OUTSIDE every repo (the fail-open shape), and must block with the
# #912 reason. A positive control with an absolute cwd must not get that reason, which
# proves the payload reaches the resolver at all. The two codex nudges never block;
# they skip on anything but `proceed`, so the resolver cases below cover them.
#
# Usage: bash tests/test-gate-empty-cwd-912.sh   (exit 0 all pass, 1 any fail)
set -uo pipefail
. "$(dirname "$0")/lib/git-env-isolation.sh" || exit 1
cd "$(dirname "$0")/.." || exit 1
REPO_ROOT=$(pwd)
GATES="$REPO_ROOT/hooks/gate-scripts"
REASON="no absolute cwd"
PASS=0
FAIL=0

TMPROOT=$(mktemp -d) || exit 1
case "$TMPROOT" in /?*) ;; *) echo "unusable TMPROOT: '$TMPROOT'" >&2; exit 1 ;; esac
trap 'rm -rf "$TMPROOT"' EXIT
REPO="$TMPROOT/repo"
NOREPO="$TMPROOT/norepo"
mkdir -p "$NOREPO"
if ! { git init -q -b main "$REPO" \
    && git -C "$REPO" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init; }; then
    echo "  FAIL  fixture setup"; exit 1
fi
git -C "$NOREPO" rev-parse --git-dir >/dev/null 2>&1 && {
    echo "  FAIL  fixture: $NOREPO is inside a repo, so it cannot model the fail-open"; exit 1; }

ok()  { printf '  PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); }

# <gate> <command> <cwd-mode: absent|empty|relative|absolute>
gate_out() {
    local payload
    payload=$(python3 -c '
import json, sys
p = {"tool_name": "Bash", "tool_input": {"command": sys.argv[1]}}
mode = sys.argv[2]
if mode == "empty":
    p["cwd"] = ""
elif mode == "relative":
    p["cwd"] = "repo"
elif mode == "absolute":
    p["cwd"] = sys.argv[3]
print(json.dumps(p))' "$2" "$3" "$REPO")
    (cd "$NOREPO" && printf '%s' "$payload" | bash "$GATES/$1.sh" 2>/dev/null)
}

printf '\n=== gates: no absolute payload cwd blocks (#912) ===\n'
while IFS='|' read -r gate cmd; do
    for mode in absent empty relative; do
        out=$(gate_out "$gate" "$cmd" "$mode")
        if grep -q '"block"' <<<"$out" && grep -qF "$REASON" <<<"$out"; then
            ok "$gate, cwd $mode: blocks naming the missing cwd"
        else
            bad "$gate, cwd $mode: want a block naming the missing cwd, got: ${out:-<allow>}"
        fi
    done
    out=$(gate_out "$gate" "$cmd" absolute)
    if grep -qF "$REASON" <<<"$out"; then
        bad "$gate, absolute cwd: wrongly reported as missing"
    else
        ok "$gate, absolute cwd: not reported as missing (control)"
    fi
done <<'EOF'
pre-commit-gate|git commit -m x
pre-pr-gate|gh pr create --fill
pre-merge-gate|gh pr merge 1 --squash
ref-ff-gate|git merge --ff-only feature
EOF

printf '\n=== ...but a command the gate does not cover still runs ===\n'
# ref-ff-gate sees EVERY Bash call, so a missing cwd must not refuse `pwd` there.
while IFS='|' read -r gate cmd; do
    out=$(gate_out "$gate" "$cmd" empty)
    if grep -q '"block"' <<<"$out"; then
        bad "$gate, cwd empty, '$cmd': want allow, got: $out"
    else
        ok "$gate, cwd empty, '$cmd': allowed"
    fi
done <<'EOF'
pre-commit-gate|git status
pre-pr-gate|gh pr view 1
pre-merge-gate|gh pr view 1
ref-ff-gate|pwd
ref-ff-gate|git status && git log -1
EOF
# An unknown git word may be a `!`-alias that fast-forwards a protected ref.
out=$(gate_out ref-ff-gate "git zz912 feature" empty)
if grep -q '"block"' <<<"$out" && grep -qF "$REASON" <<<"$out"; then
    ok "ref-ff-gate, cwd empty, unknown git word: blocks naming the missing cwd"
else
    bad "ref-ff-gate, cwd empty, unknown git word: want a #912 block, got: ${out:-<allow>}"
fi

printf '\n=== resolver (covers codex-nudge-precreate / codex-nudge-premerge) ===\n'
# shellcheck source=hooks/gate-scripts/lib/resolve-repo-dir.sh
. "$GATES/lib/resolve-repo-dir.sh"
for c in "" "repo" "./repo"; do
    # An absolute target must not rescue a missing cwd either: the resolver refuses
    # before it looks at the target, so no command shape can opt out.
    for t in "" "$REPO"; do
        if (cd "$NOREPO" && gate_resolve_repo_dir "$t" "$c" \
            && [ "$GATE_RESOLVE_STATUS" = "block-unresolvable" ] \
            && [ -n "$GATE_RESOLVE_WHY" ]); then
            ok "cwd '$c', target '${t:+abs}': block-unresolvable with a reason"
        else
            bad "cwd '$c', target '${t:+abs}': want block-unresolvable with a reason"
        fi
    done
done
gate_resolve_repo_dir "" "$REPO"
if [ "$GATE_RESOLVE_STATUS" = "proceed" ] && [ -z "$GATE_RESOLVE_WHY" ]; then
    ok "absolute cwd: proceed, no reason"
else
    bad "absolute cwd: want proceed with no reason, got $GATE_RESOLVE_STATUS"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
