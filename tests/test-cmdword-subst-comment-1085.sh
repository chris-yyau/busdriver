#!/usr/bin/env bash
# #1085: cmdword read substitution bodies and comments differently from bash, so writes behind
# `${v%)}`, a comment, a heredoc, or an ANSI-C-quoted program were allowed while a design was
# pending. The checks live in tests/fixtures/cmdword_1085.py; this suite builds the repos.
set -u
# shellcheck source=/dev/null
. "$(dirname "$0")/lib/git-env-isolation.sh" || exit 1

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATE="$ROOT/hooks/gate-scripts/pre-implementation-gate.sh"
FIX="$ROOT/tests/fixtures/cmdword_1085.py"
PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
no() { FAIL=$((FAIL + 1)); printf '  FAIL  %s :: %s\n' "$1" "${2:-}"; }

ARMED=""
trap 'rm -rf ${ARMED:+"$ARMED"}' EXIT
ARMED="$(mktemp -d)" || ARMED=""
[[ -n "$ARMED" && -d "$ARMED" ]] || { echo "  FAIL  mktemp -d"; exit 1; }
git -C "$ARMED" init -q
mkdir -p "$ARMED/docs/plans" "$ARMED/.claude" "$ARMED/src"
printf '# plan\n' >"$ARMED/docs/plans/thing.md"
bash "$ROOT/hooks/gate-scripts/lib/resolve-repo-dir.sh" arm "$ARMED/docs/plans/thing.md" >/dev/null 2>&1

# The fixture is only meaningful with a design pending: prove it, or every allow is vacuous.
case "$(printf '{"tool_name":"Bash","cwd":"%s","tool_input":{"command":"rm -rf src"}}' "$ARMED" \
        | (cd "$ARMED" && bash "$GATE") 2>/dev/null)" in
    *'"block"'*) ok "fixture: a design is pending in the armed repo" ;;
    *) no "fixture: a design is pending in the armed repo" "rm -rf src was allowed"
       printf '\n════ cmdword-subst-comment-1085: %d passed, %d failed ════\n' "$PASS" "$FAIL"; exit 1 ;;
esac

for mode in rows fuzz timing; do
    echo "=== $mode ==="
    out="$(python3 -I "$FIX" "$mode" "$ARMED" 2>&1)"
    rc=$?
    printf '%s\n' "$out" | grep -v '^SUMMARY '
    sum="$(printf '%s\n' "$out" | grep '^SUMMARY ' | tail -1 || true)"   # none: handled below
    p=0 f=0
    if [[ -n "$sum" ]]; then
        read -r _ p f <<<"$sum"     # counted whatever rc is: N failed rows show as N
    fi
    PASS=$((PASS + p)); FAIL=$((FAIL + f))
    if [[ -z "$sum" ]] || [[ $rc -ne 0 && $f -eq 0 ]]; then
        no "$mode" "fixture exited $rc${sum:+ ($sum)}"   # setup failure, or rc and SUMMARY disagree
    fi
done

printf '\n════ cmdword-subst-comment-1085: %d passed, %d failed ════\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
