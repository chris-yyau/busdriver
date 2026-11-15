#!/usr/bin/env bash
# Tests for scripts/kody-waiver.py (ADR 0064 D10): it decides docs_only() and, only on
# `docs-only`, appends ONE fixed-shape record to the MAIN checkout's .claude/bypass-log.jsonl.
# A stub `gh` on PATH serves the classifier's calls; every repo is a fresh temp repo.
#
# Usage: bash tests/test-kody-waiver.sh
set -uo pipefail
. "$(dirname "$0")/lib/git-env-isolation.sh" || exit 1
cd "$(dirname "$0")/.." || exit 1
ROOT=$PWD
WAIVER="$ROOT/scripts/kody-waiver.py"
LIB="$ROOT/hooks/gate-scripts/lib"
PY=/usr/bin/python3
PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
export KW_HEAD=3df45264627e7ff8bf8cacc05a025723929b62d3
export KW_BASE=0e1270c5c81c44f7a62f796d7efde58f7eb2d358
# Stub gh: one docs/a.md tree. KW_CHANGED picks the changed path; KW_TRUNC=true truncates the tree.
cat > "$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
x=1111111111111111111111111111111111111111
case "$*" in
  "pr view"*) printf '{"baseRefName":"main","headRefOid":"%s","mergeStateStatus":"CLEAN","author":{"login":"cursor"},"isCrossRepository":false}\n' "$KW_HEAD" ;;
  "api repos/o/r/git/ref/heads/main") printf '{"ref":"refs/heads/main","object":{"sha":"%s","type":"commit"}}\n' "$KW_BASE" ;;
  "api repos/o/r/git/trees/"*"?recursive=1")
    printf '{"truncated":%s,"tree":[{"path":"docs","mode":"040000","type":"tree","sha":"%s"},{"path":"docs/a.md","mode":"100644","type":"blob","sha":"%s","size":1}]}\n' \
      "${KW_TRUNC:-false}" "$x" "$x" ;;
  "api --paginate"*) printf '{"filename":"%s","previous_filename":null,"status":"modified"}\n' "${KW_CHANGED:-docs/a.md}" ;;
  *) echo "stub: unexpected gh $*" >&2; exit 99 ;;
esac
STUB
chmod +x "$TMP/bin/gh"

mkrepo() { # <dir> [git-init args...]: a repo with one commit
  local d=$1; shift
  git init -q "$@" "$d" && git -C "$d" -c user.email=t@e -c user.name=t commit -q --allow-empty -m i
}
# waive <cwd> [args...]: run the waiver; sets OUT and RC.
waive() {
  local cwd=$1; shift
  [ $# -gt 0 ] || set -- o/r 42 "$KW_HEAD"
  OUT=$(cd "$cwd" && PATH="$TMP/bin:$PATH" "$PY" -I "$WAIVER" "$@" 2>/dev/null); RC=$?
}
lines() { if [ -f "$1" ]; then wc -l < "$1" | tr -d ' '; else echo 0; fi; }
record_ok() { # <log>: exactly one well-formed record
  [ "$(lines "$1")" = 1 ] && jq -e --arg h "$KW_HEAD" '
    .event == "kody-unlicensed-skip-waived" and .gate == "pr-grind-completion" and .pr == 42
    and (.pr | type) == "number" and .head_sha == $h and (.head_sha | test("\\A[0-9a-f]{40}\\z"))
    and .scope == "docs-only" and .verified == "documentation-only diff at head_sha"
    and .basis == "completion ledger read kody-ai=skipped-unlicensed" and .adr == "0064"
    and (.ts | test("\\A20[0-9]{2}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\\z"))
    and (keys | length) == 9' "$1" >/dev/null 2>&1
}
PYC_BEFORE=$(find "$LIB" -name '*.pyc' 2>/dev/null | sort)

echo "── kody-waiver.py ───────────────────────────────────────────"
M="$TMP/m1"; mkrepo "$M"
waive "$M"
if [ "$RC" = 0 ] && [ "$OUT" = waived ] && record_ok "$M/.claude/bypass-log.jsonl"; then pass "main worktree: waived, one record"
else fail "main worktree: waived, one record (rc=$RC out=$OUT log=$(cat "$M/.claude/bypass-log.jsonl" 2>/dev/null))"; fi

M="$TMP/m2"; mkrepo "$M"; git -C "$M" worktree add -q "$TMP/w2" 2>/dev/null
waive "$TMP/w2"
if [ "$RC" = 0 ] && [ "$OUT" = waived ] && record_ok "$M/.claude/bypass-log.jsonl" && [ ! -e "$TMP/w2/.claude" ]; then
  pass "linked worktree: the record lands in the main checkout only"
else fail "linked worktree: the record lands in the main checkout only (rc=$RC out=$OUT)"; fi

M="$TMP/m 2b"$'\t''"q'$'\r'; mkrepo "$M"; git -C "$M" worktree add -q "$TMP/w2b" 2>/dev/null
waive "$TMP/w2b"
if [ "$RC" = 0 ] && [ "$OUT" = waived ] && record_ok "$M/.claude/bypass-log.jsonl"; then
  pass "linked worktree whose main checkout path holds a space, tab, quote and CR"
else fail "linked worktree whose main checkout path holds a space, tab, quote and CR (rc=$RC out=$OUT)"; fi

S="$TMP/s3"; mkrepo "$S" --separate-git-dir "$TMP/g3"
waive "$S"
if [ "$RC" = 0 ] && [ "$OUT" = waived ] && record_ok "$S/.claude/bypass-log.jsonl"; then pass "--separate-git-dir main worktree: waived"
else fail "--separate-git-dir main worktree: waived (rc=$RC out=$OUT)"; fi

S="$TMP/s4"; mkrepo "$S" --separate-git-dir "$TMP/g4"; git -C "$S" worktree add -q "$TMP/w4" 2>/dev/null
waive "$TMP/w4"
if [ "$RC" = 1 ] && [ "${OUT#error: }" != "$OUT" ] && [ ! -e "$S/.claude" ] && [ ! -e "$TMP/w4/.claude" ] && [ ! -e "$TMP/g4/.claude" ]; then
  pass "linked worktree of a --separate-git-dir repo: exit 1, nothing written"
else fail "linked worktree of a --separate-git-dir repo: exit 1, nothing written (rc=$RC out=$OUT)"; fi

M="$TMP/m5"; mkrepo "$M"
KW_CHANGED=src/x.ts waive "$M"
if [ "$RC" = 10 ] && [ "$OUT" = not-docs-only ] && [ ! -e "$M/.claude" ]; then pass "not-docs-only: exit 10, nothing written"
else fail "not-docs-only: exit 10, nothing written (rc=$RC out=$OUT)"; fi
KW_TRUNC=true waive "$M"
if [ "$RC" = 10 ] && [ "$OUT" = incomplete ] && [ ! -e "$M/.claude" ]; then pass "incomplete: exit 10, nothing written"
else fail "incomplete: exit 10, nothing written (rc=$RC out=$OUT)"; fi

for args in "o/r 042 $KW_HEAD" "o/r 0 $KW_HEAD" "o/r 42 ${KW_HEAD:0:8}" "o/r 42" "o/r 42 $KW_HEAD x" "../r 42 $KW_HEAD"; do
  # shellcheck disable=SC2086 # word-split on purpose: each row is an argv
  waive "$M" $args
  if [ "$RC" = 1 ] && [ "${OUT#error: }" != "$OUT" ] && [ ! -e "$M/.claude" ]; then pass "bad arguments [$args]: exit 1, nothing written"
  else fail "bad arguments [$args]: exit 1, nothing written (rc=$RC out=$OUT)"; fi
done

M="$TMP/m6"; mkrepo "$M"; mkdir -p "$M/.claude"; ln -s /dev/null "$M/.claude/bypass-log.jsonl"
waive "$M"
if [ "$RC" = 1 ] && [ "$OUT" != waived ]; then pass "state file is a symlink to /dev/null: exit 1"
else fail "state file is a symlink to /dev/null: exit 1 (rc=$RC out=$OUT)"; fi
M="$TMP/m7"; mkrepo "$M"; mkdir -p "$TMP/elsewhere"; ln -s "$TMP/elsewhere" "$M/.claude"
waive "$M"
if [ "$RC" = 1 ] && [ "$OUT" != waived ] && [ -z "$(ls -A "$TMP/elsewhere")" ]; then pass "state dir is a symlink: exit 1, nothing written through it"
else fail "state dir is a symlink: exit 1, nothing written through it (rc=$RC out=$OUT)"; fi

M="$TMP/m8"; mkrepo "$M"
BUSDRIVER_STATE_DIR=alt waive "$M"
if [ "$RC" = 0 ] && record_ok "$M/.claude/bypass-log.jsonl" && [ ! -e "$M/alt" ]; then pass "BUSDRIVER_STATE_DIR=alt is not read"
else fail "BUSDRIVER_STATE_DIR=alt is not read (rc=$RC out=$OUT)"; fi

M="$TMP/m9"; mkrepo "$M"; R="$TMP/r9"; mkrepo "$R"
GIT_DIR="$R/.git" GIT_WORK_TREE="$R" waive "$M"
if [ "$RC" = 0 ] && record_ok "$M/.claude/bypass-log.jsonl" && [ ! -e "$R/.claude" ]; then pass "exported GIT_DIR/GIT_WORK_TREE do not move the record"
else fail "exported GIT_DIR/GIT_WORK_TREE do not move the record (rc=$RC out=$OUT)"; fi

if [ "$(find "$LIB" -name '*.pyc' 2>/dev/null | sort)" = "$PYC_BEFORE" ]; then pass "no bytecode written under hooks/gate-scripts/lib"
else fail "no bytecode written under hooks/gate-scripts/lib"; fi

echo
echo "kody-waiver: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
