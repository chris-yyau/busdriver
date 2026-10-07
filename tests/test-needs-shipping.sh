#!/usr/bin/env bash
# Tests for scripts/needs-shipping.py (ADR 0054) and the pr-grind prose that wires it in.
#
# Part 1 drives the classifier through a stub `gh` on PATH. Stub responses are trimmed
# copies of real `gh pr view` / `git/trees` / `pulls/<n>/files --jq` output, so field
# names are not guessed. Every decision is observed on both sides (0 / 10 / 1).
# Part 2 asserts document order and the "exit 0 only" qualifiers in completion.md and
# SKILL.md, the same way tests/test-pr-grind-codex-wiring.sh pins prose contracts.
#
# Usage: bash tests/test-needs-shipping.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

SCRIPT="scripts/needs-shipping.py"
PY=/usr/bin/python3
PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"

HEAD=3df45264627e7ff8bf8cacc05a025723929b62d3
BASE=0e1270c5c81c44f7a62f796d7efde58f7eb2d358
OTHER=1111111111111111111111111111111111111111

# Stub gh. Fixture files under $FIX:
#   view1, view2           successive `gh pr view` responses (view2 reused afterwards)
#   tree-<sha>[.rc]        `gh api repos/o/r/git/trees/<sha>` body [and exit code]
#   files[.rc]             `gh api --paginate ... pulls/<n>/files --jq ...` stdout [and exit code]
# The stub logs every call to $FIX/calls and the GH_HOST it saw to $FIX/gh_host.
cat > "$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$FIX/calls"
printf '%s\n' "${GH_HOST:-}" > "$FIX/gh_host"
if [ "$1 $2" = "pr view" ]; then
  n=$(grep -c '^pr view' "$FIX/calls")
  if [ "$n" -le 1 ]; then cat "$FIX/view1"; else cat "$FIX/view2"; fi
  exit 0
fi
case "$*" in
  "api repos/o/r/git/trees/"*)
    sha=${2##*/}
    [ -f "$FIX/tree-$sha" ] && cat "$FIX/tree-$sha"
    exit "$(cat "$FIX/tree-$sha.rc" 2>/dev/null || { [ -f "$FIX/tree-$sha" ] && echo 0 || echo 1; })" ;;
  "api --paginate"*)
    cat "$FIX/files"
    exit "$(cat "$FIX/files.rc" 2>/dev/null || echo 0)" ;;
esac
echo "stub: unexpected gh $*" >&2
exit 99
STUB
chmod +x "$TMP/bin/gh"

view() { printf '{"baseRefOid":"%s","headRefOid":"%s","mergeStateStatus":%s}\n' "$1" "$2" "${3:-\"CLEAN\"}"; }
entry() { printf '{"mode":"%s","path":"%s","sha":"%s","type":"%s","url":"https://api.github.com/x"}' "$1" "$2" "$3" "$4"; }
tree() { local IFS=,; printf '{"sha":"x","tree":[%s],"truncated":false}\n' "$*"; }
DIR=040000
BLOB=100644
CUR=c000000000000000000000000000000000000000
SKL=5000000000000000000000000000000000000000

# new_case: fresh fixture dir, both views = (BASE, HEAD), base tree WITHOUT .cursor.
new_case() {
  FIX="$TMP/case$((PASS + FAIL))"; mkdir -p "$FIX"; export FIX; : > "$FIX/calls"
  view "$BASE" "$HEAD" > "$FIX/view1"; cp "$FIX/view1" "$FIX/view2"
  tree "$(entry $BLOB README.md aaa blob)" "$(entry $DIR src bbb tree)" > "$FIX/tree-$BASE"
}
# opt_in [skills-entries...]: base tree carries .cursor/skills/ with the given entries
# (default: one verify-site directory).
opt_in() {
  tree "$(entry $BLOB README.md aaa blob)" "$(entry $DIR .cursor $CUR tree)" > "$FIX/tree-$BASE"
  tree "$(entry $DIR skills $SKL tree)" > "$FIX/tree-$CUR"
  if [ $# -eq 0 ]; then set -- "$(entry $DIR verify-site 7777 tree)"; fi
  tree "$@" > "$FIX/tree-$SKL"
}
files() { : > "$FIX/files"; for f in "$@"; do printf '%s\n' "$f" >> "$FIX/files"; done; }
plain() { printf '{"filename":"%s","previous_filename":null}' "$1"; }

# run_case <label> <expected-exit> <expected-stdout>: stdout must equal the expected
# line exactly, except `error`, which matches any `error: <reason>` line.
run_case() {
  local out rc ok=0
  out=$(PATH="$TMP/bin:$PATH" "$PY" -I "$SCRIPT" o/r 42 "$HEAD" 2>/dev/null); rc=$?
  if [ "$3" = error ]; then [ "${out#error: }" != "$out" ] && ok=1; else [ "$out" = "$3" ] && ok=1; fi
  if [ "$rc" = "$2" ] && [ "$ok" = 1 ]; then pass "$1"
  else fail "$1 (rc=$rc out=$out, want rc=$2 out=$3)"; fi
}

echo "── classifier ───────────────────────────────────────────────"

new_case
run_case "not opted in (no .cursor) → merge" 0 merge
if grep -q -- '--paginate' "$FIX/calls"; then fail "not opted in never calls the files API"; else pass "not opted in never calls the files API"; fi
if [ "$(cat "$FIX/gh_host")" = github.com ]; then pass "gh runs with GH_HOST=github.com"; else fail "gh runs with GH_HOST=github.com"; fi

new_case; opt_in "$(entry $DIR helper 8888 tree)"
run_case "not opted in (.cursor/skills has no verify-* dir) → merge" 0 merge

new_case; opt_in "$(entry $BLOB verify-site.md 9999 blob)"
run_case "not opted in (verify-site.md is a blob) → merge" 0 merge

new_case; rm "$FIX/tree-$BASE"; echo 1 > "$FIX/tree-$BASE.rc"
run_case "trees API failure → error" 1 error

new_case; echo '{"message":"Not Found"}' > "$FIX/tree-$BASE"; echo 1 > "$FIX/tree-$BASE.rc"
run_case "trees API 404 → error, not 'absent'" 1 error

new_case; tree "$(entry $DIR src bbb tree)" | sed 's/"truncated":false/"truncated":true/' > "$FIX/tree-$BASE"
run_case "truncated tree → error" 1 error

new_case; tree '{"path":"src","sha":"bbb"}' > "$FIX/tree-$BASE"
run_case "malformed tree entry (no type) → error" 1 error

new_case; view "$BASE" "$OTHER" > "$FIX/view2"
run_case "not opted in, head moved before the final view → error" 1 error

new_case; opt_in; files "$(plain docs/a.md)" "$(plain README.md)"
run_case "opted in, docs-only → merge" 0 merge

new_case; opt_in; files "$(plain docs/a.md)" "$(plain src/app/page.tsx)"
run_case "opted in, src change → shipping" 10 "shipping mergeStateStatus=CLEAN"

new_case; opt_in; files '{"filename":"docs/a.ts","previous_filename":"src/a.ts"}'
run_case "opted in, rename src→docs → shipping" 10 "shipping mergeStateStatus=CLEAN"

new_case; opt_in; files "$(plain .cursor/skills/verify-site/SKILL.md)"
run_case "opted in, PR deletes the verify skill → shipping" 10 "shipping mergeStateStatus=CLEAN"

new_case; opt_in; files "$(plain docs/a.md)"; echo 1 > "$FIX/files.rc"
run_case "opted in, a later page fails → error" 1 error

new_case; opt_in; for _ in $(seq 3000); do plain docs/a.md; echo; done > "$FIX/files"
run_case "opted in, 3000 file objects → shipping" 10 "shipping mergeStateStatus=CLEAN"

new_case; opt_in; for i in $(seq 1500); do printf '{"filename":"docs/n%s.md","previous_filename":"docs/o%s.md"}\n' "$i" "$i"; done > "$FIX/files"
run_case "opted in, 1500 docs-only renames (3000 paths, 1500 records) → merge" 0 merge

new_case; opt_in; files '{"filename":"src/app/a.test.ts\ndocs/x","previous_filename":null}'
run_case "opted in, filename with embedded newline → shipping" 10 "shipping mergeStateStatus=CLEAN"

new_case; opt_in; files 'not json'
run_case "opted in, unparseable files line → error" 1 error

new_case; opt_in; files '{"filename":"docs/a.md","previous_filename":7}'
run_case "opted in, malformed previous_filename → error" 1 error

new_case; opt_in; files "$(plain src/x.ts)"; view "$BASE" "$HEAD" null > "$FIX/view2"
run_case "mergeStateStatus null → UNKNOWN" 10 "shipping mergeStateStatus=UNKNOWN"

new_case; opt_in; files "$(plain src/x.ts)"; view "$OTHER" "$HEAD" > "$FIX/view2"
run_case "opted in, base moved while classifying → error" 1 error

new_case; view "$BASE" "$OTHER" > "$FIX/view1"
run_case "head differs from REVIEWED_HEAD → error" 1 error

out=$("$PY" -I "$SCRIPT" o/r 42 abc 2>/dev/null); rc=$?
if [ "$rc" = 1 ] && [ "${out#error}" != "$out" ]; then pass "bad arguments → error, exit 1"; else fail "bad arguments → error (rc=$rc)"; fi

out=$("$PY" -I "$SCRIPT" --selftest 2>&1); rc=$?
if [ "$rc" = 0 ] && [ "$out" = needs_shipping_selftest_ok ]; then pass "--selftest under $PY"; else fail "--selftest under $PY ($out)"; fi

echo "── prose wiring ─────────────────────────────────────────────"
COMP=skills/pr-grind/references/completion.md
SKILL=skills/pr-grind/SKILL.md
QUAL='only when Shipping routing exited 0'
line_of() { grep -nF -- "$2" "$1" | head -1 | cut -d: -f1; }
# t <label> <command...>: pass when the command succeeds.
t() { local label=$1; shift; if "$@"; then pass "$label"; else fail "$label"; fi; }
has() { grep -qF -- "$2" <<<"$1"; }           # has <text> <literal>
lacks() { ! grep -qF -- "$2" <<<"$1"; }       # lacks <text> <literal>

L_VERIFY=$(line_of "$COMP" '**Verify checks are green')
L_ROUTE=$(line_of "$COMP" '**Shipping routing (REQUIRED')
L_BLOCK=$(line_of "$COMP" '**Shipping block:')
L_MARKER=$(line_of "$COMP" '**Write the pr-grind-clean marker')
in_order() { [ -n "$1" ] && [ -n "$2" ] && [ "$1" -lt "$2" ]; }
if in_order "$L_VERIFY" "$L_ROUTE" && in_order "$L_ROUTE" "$L_MARKER"; then
  pass "routing sits between 'Verify checks are green' and the marker write"
else
  fail "routing sits between 'Verify checks are green' and the marker write"
fi

ROUTE_TEXT=$(sed -n "${L_ROUTE},$((L_MARKER - 1))p" "$COMP")
BLOCK_BASH=$(sed -n "${L_BLOCK},\$p" "$COMP" | awk '/^```bash/{f=1;next} f&&/^```/{exit} f')
# shellcheck disable=SC2016  # literal shell text being searched for
t "Shipping block removes both markers" \
  has "$BLOCK_BASH" 'rm -f "$R/.claude/pr-grind-clean.local" "$R/.claude/pr-pending-grind.local"'
writes_marker() { grep -E '(printf|cp|>).*pr-grind-clean\.local' <<<"$1" | grep -qvE '^[[:space:]]*(rm|\[)'; }
if writes_marker "$BLOCK_BASH"; then fail "Shipping block never writes or copies the clean marker"
else pass "Shipping block never writes or copies the clean marker"; fi
# shellcheck disable=SC2016
t "Shipping block iterates roots as a quoted array" has "$BLOCK_BASH" 'for R in "${ROOTS[@]}"'
t "routing names the catch-all" has "$ROUTE_TEXT" '**anything else**'
t "routing BAILs env" has "$ROUTE_TEXT" 'RESULT_BAIL_CATEGORY=env'
# shellcheck disable=SC2016  # literal backticks being searched for
t "routing says --no-merge does not override it" has "$ROUTE_TEXT" '`--no-merge` does not override this'
t "routing section does not prune Codex retrigger markers" lacks "$ROUTE_TEXT" 'codex-retrigger-gc'
if grep -qE '^REVIEWED_HEAD=' <<<"$ROUTE_TEXT"; then fail "routing passes the head inline (no REVIEWED_HEAD= assignment)"
else pass "routing passes the head inline (no REVIEWED_HEAD= assignment)"; fi

# Execute the Shipping block itself (placeholders substituted) in repos whose paths
# contain a space, with markers pre-seeded in both roots.
run_block() { # <session-repo> <orig-path> <no_worktree>
  local blk
  blk=$(printf '%s\n' "$BLOCK_BASH" | sed -e "s|<0\|1 — see \"Resolve flag-to-state translations\" in START>|$3|" \
    -e "s|<original-worktree-path>|\"$2\"|g" -e 's|<PR_NUMBER>|42|g')
  (cd "$1" && bash -c "$blk") >/dev/null 2>&1
}
seed() { for r in "$@"; do mkdir -p "$r/.claude"; echo "42 $HEAD" > "$r/.claude/pr-grind-clean.local"; : > "$r/.claude/pr-pending-grind.local"; done; }
gone() { for f in "$@"; do [ ! -e "$f" ] || return 1; done; }
SP="$TMP/with space"; mkdir -p "$SP"
git init -q "$SP/session repo"; git init -q "$SP/orig repo"
seed "$SP/session repo" "$SP/orig repo"
run_block "$SP/session repo" "$SP/orig repo" 0; rc=$?
if [ "$rc" = 0 ] && gone "$SP/session repo/.claude/pr-grind-clean.local" "$SP/orig repo/.claude/pr-grind-clean.local" "$SP/orig repo/.claude/pr-pending-grind.local"; then
  pass "Shipping block (paths with spaces) exits 0 and removes markers in both roots"
else
  fail "Shipping block (paths with spaces) exits 0 and removes markers in both roots (rc=$rc)"
fi
seed "$SP/session repo"
run_block "$SP/session repo" "$SP/missing repo" 0; rc=$?
if [ "$rc" != 0 ] && gone "$SP/session repo/.claude/pr-grind-clean.local"; then
  pass "Shipping block: unresolvable original root still clears the session marker, then exits non-zero"
else
  fail "Shipping block: unresolvable original root still clears the session marker, then exits non-zero (rc=$rc)"
fi

L_EI=$(awk -v r="$L_ROUTE" 'NR>r && /^<EXTREMELY-IMPORTANT>/{print NR; exit}' "$COMP")
qualified() { sed -n "${1}p" "$COMP" | grep -qiF -- "$QUAL"; }
t "CRITICAL two-call block carries the exit-0 qualifier" qualified "$((L_EI + 1))"
t "marker-write heading carries the exit-0 qualifier" qualified "$L_MARKER"
# shellcheck disable=SC2016  # literal backticks being searched for
t "--no-merge heading carries the exit-0 qualifier" qualified "$(line_of "$COMP" '**If `--no-merge`')"
# shellcheck disable=SC2016  # literal backticks being searched for
for w in 'Ready for Shipping (mergeStateStatus=<S>)' 'Shipping rebases the bottom PR itself' \
         'When `<S>` is `BLOCKED`, `DIRTY` or `DRAFT`' 'When `<S>` is `UNKNOWN`'; do
  t "output carries: $w" grep -qF -- "$w" "$COMP"
done

L_SROUTE=$(line_of "$SKILL" 'Shipping routing (scripts/needs-shipping.py')
L_SMARK=$(line_of "$SKILL" 'Write .claude/pr-grind-clean.local at repo root')
t "SKILL.md diagram: routing node above the marker-write node" in_order "$L_SROUTE" "$L_SMARK"
t "SKILL.md diagram: --no-merge node marked exit-0 only" grep -qF '├── --no-merge (exit 0 only)' "$SKILL"

echo
echo "needs-shipping: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
