#!/usr/bin/env bash
# Regression tests for the dispatch block documented in skills/imagegen/SKILL.md.
#
# The block is the deliverable, so the tests run the block ITSELF — extracted from the
# skill at test time, so the doc and the tested code cannot drift. No provider is
# called: every case here fails before dispatch, or exercises a pure helper.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKILL="$ROOT/skills/imagegen/SKILL.md"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()   { printf 'ok   %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf 'FAIL %s\n' "$1"; fail=$((fail+1)); }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want $3, got $2)"; fi; }

# Extract the Step 2 block verbatim.
BLOCK="$TMP/block.sh"
awk '/^\*\*Step 2 — one Bash call/,0' "$SKILL" \
  | awk '/^```bash/{f=1;next} /^```$/{if(f)exit} f' > "$BLOCK"
[ -s "$BLOCK" ] || { echo "FAIL could not extract the block from $SKILL"; exit 1; }

# A copy with the provider dispatch removed, so guard cases never spend real balance.
GUARDS="$TMP/guards.sh"
awk '/^case "\$PROVIDER" in$/{skip=1} skip&&/^esac$/{skip=0;next} !skip' "$BLOCK" > "$GUARDS"

run() {  # run() <script> <OUT> [env assignments...] -> prints exit code
  local script=$1 out=$2; shift 2
  ( env "$@" BRIEF="$TMP/brief.txt" bash -c "
      $(sed "s|^BRIEF=.*|BRIEF=$TMP/brief.txt|; s|^OUT=.*|OUT=$out|; s|^PROVIDER=.*|PROVIDER=agy|" "$script")
    " >/dev/null 2>&1 )
  echo $?
}

echo "a minimal flat vector logo of a circle" > "$TMP/brief.txt"

# 1. The documented block is valid shell. Cheapest guard against a broken paste.
if bash -n "$BLOCK" 2>/dev/null; then ok "block parses"; else bad "block has a syntax error"; fi

# 2. A relative $OUT is refused (the providers all need an absolute path).
check "relative OUT refused" "$(run "$GUARDS" 'relative/hero.png')" 1

# 3. A group/world-writable asset directory is refused — publication cannot be made
#    race-proof against another writer, so the directory must be yours.
mkdir -p "$TMP/open"; chmod 777 "$TMP/open"
check "world-writable dir refused" "$(run "$GUARDS" "$TMP/open/hero.png")" 1

# 4. A private directory is NOT refused — the guard must be able to pass, not just fail.
#    With the dispatch stripped there is no asset, so this run still exits 1; what
#    matters is that it got past the permission check to a LATER failure.
mkdir -p "$TMP/mine"; chmod 700 "$TMP/mine"
why=$( env BRIEF="$TMP/brief.txt" bash -c "
    $(sed "s|^BRIEF=.*|BRIEF=$TMP/brief.txt|; s|^OUT=.*|OUT=$TMP/mine/hero.png|; s|^PROVIDER=.*|PROVIDER=agy|" "$GUARDS")
  " 2>&1 >/dev/null )
case "$why" in
  *world-writable*) bad "private dir wrongly refused" ;;
  *"no regular asset produced"*) ok "private dir accepted (reached dispatch stage)" ;;
  *) bad "private dir: unexpected failure: $why" ;;
esac

# 5. An unreadable brief must fail BEFORE the output directory is created — the brief
#    read has to precede the mkdir, not merely the dispatch, or a typo'd path litters
#    the tree with empty directories. Asserting on a pre-created directory would miss
#    exactly that, so the directory here must not exist beforehand.
( env BRIEF=/nonexistent/brief.txt bash -c "
    $(sed "s|^BRIEF=.*|BRIEF=/nonexistent/brief.txt|; s|^OUT=.*|OUT=$TMP/nodir/hero.png|; s|^PROVIDER=.*|PROVIDER=agy|" "$GUARDS")
  " >/dev/null 2>&1 )
if [ -e "$TMP/nodir" ]; then bad "bad brief created $TMP/nodir"; else ok "bad brief creates nothing"; fi

# 6. An inherited WORK/TAKE/VERIFIED must never be swept: these are ordinary variable
#    names, and die() rm -rf's them.
mkdir -p "$TMP/precious"; touch "$TMP/precious/keep.txt"
( env BRIEF=/nonexistent WORK="$TMP/precious" TAKE="$TMP/precious" VERIFIED=1 bash -c "
    $(sed "s|^BRIEF=.*|BRIEF=/nonexistent|; s|^OUT=.*|OUT=$TMP/mine/x.png|; s|^PROVIDER=.*|PROVIDER=agy|" "$GUARDS")
  " >/dev/null 2>&1 )
if [ -f "$TMP/precious/keep.txt" ]; then ok "inherited WORK not swept"; else bad "inherited WORK was deleted"; fi

# 7. A find(1) that cannot answer must REFUSE, not pass. A discarded find failure
#    (absent binary, rejected -perm, unreadable directory) yields the same empty
#    output as a private directory, so silence must not be read as proof. The stub
#    below fails the way a missing or incompatible find would.
mkdir -p "$TMP/stub"
printf '#!/bin/sh\necho "find: broken" >&2\nexit 1\n' > "$TMP/stub/find"
chmod +x "$TMP/stub/find"
why=$( env BRIEF="$TMP/brief.txt" PATH="$TMP/stub:$PATH" bash -c "
    $(sed "s|^BRIEF=.*|BRIEF=$TMP/brief.txt|; s|^OUT=.*|OUT=$TMP/mine/probe.png|; s|^PROVIDER=.*|PROVIDER=agy|" "$GUARDS")
  " 2>&1 >/dev/null )
case "$why" in
  *"cannot inspect"*) ok "unanswerable find refuses (fail closed)" ;;
  *) bad "broken find did not refuse: $why" ;;
esac

# 8. Dimension parsing reads PIXELS, not JPEG's JFIF density. `head` would return
#    300x300 for the JPEG line below and pass a 1x1 image.
dims() { printf '%s' "$1" | grep -oE '[0-9]+ ?x ?[0-9]+' | tail -1; }
check "png dims" "$(dims 'PNG image data, 1024 x 1024, 8-bit/color RGB, non-interlaced')" "1024 x 1024"
check "jpeg dims not density" \
  "$(dims 'JPEG image data, JFIF standard 1.01, density 300x300, segment length 16, precision 8, 1024x1024, components 3')" \
  "1024x1024"
check "degenerate dims" "$(dims 'JPEG image data, JFIF standard 1.01, density 300x300, precision 8, 1x1, components 3')" "1x1"

# 9. The grok path guard rejects traversal out of the session root. Lexical prefix
#    matching alone is defeated by .../sessions/../../secret.png.
root=$(cd -P "$TMP" && pwd -P)
gen="$TMP/sessions/../escaped.png"
dir=$(cd -P "$(dirname "$gen")" 2>/dev/null && pwd -P || echo /nowhere)
case "$dir/$(basename "$gen")" in "$root"/sessions/*) bad "traversal accepted";; *) ok "traversal rejected";; esac

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
