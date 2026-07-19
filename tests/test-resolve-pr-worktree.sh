#!/usr/bin/env bash
# tests/test-resolve-pr-worktree.sh — behavioral test for the Step 0 worktree
# resolution fail-CLOSED fix (#421).
#
# Unlike the golden-grep SKILL.md guards, this drives the real script against
# real git worktrees and asserts on exit codes + the stdout wire format. It
# exercises the three-way split the issue names: branch nowhere / branch here /
# branch in ANOTHER worktree — plus the unconditional branch assertion.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RESOLVER="$SCRIPT_DIR/scripts/resolve-pr-worktree.sh"

passed=0; failed=0
ok()   { echo "OK:   $1"; passed=$((passed + 1)); }
fail() { echo "FAIL: $1"; failed=$((failed + 1)); }

[ -x "$RESOLVER" ] || { fail "resolver missing or not executable: $RESOLVER"; echo "Results: $passed passed, $failed failed"; exit 1; }

# Guard the mktemp: this script does not use `set -e`, so an unchecked failure
# would leave TMP empty, make REPO="/work/repo", and let the fixture below
# git-init and write to that unrelated absolute path on a writable runner.
TMP=$(mktemp -d) || { echo "FAIL: mktemp -d failed"; exit 1; }
case "$TMP" in
  /*) ;;
  *) echo "FAIL: mktemp -d returned a non-absolute path: '$TMP'"; exit 1 ;;
esac
trap 'cd /; rm -rf "$TMP"' EXIT

# --- fixture: a repo on `main` with a `feature` branch ------------------------
# Nested one level down so the resolver's sibling `pr-grind-<N>` dir lands
# inside $TMP and gets cleaned up with it.
REPO="$TMP/work/repo"
mkdir -p "$REPO"
cd "$REPO" || exit 1
git init -q -b main .
git config user.email test@example.com
git config user.name  Test
echo seed > seed.txt
git add seed.txt
git commit -qm seed
git branch feature
REPO_CANON=$(cd "$REPO" && pwd -P)

run() { OUT=$("$RESOLVER" "$@" 2>&1); RC=$?; return 0; }

# --- case A: branch checked out NOWHERE → creates the ephemeral worktree ------
cd "$REPO" || exit 1
run 421 feature "$(git -C "$REPO" rev-parse feature)"
if [ "$RC" -eq 0 ]; then ok "A: exits 0 when branch is free"; else fail "A: expected 0, got $RC — $OUT"; fi
WTLINE=$(printf '%s' "$OUT" | grep '^WORKTREE_DIR=' || true)
if [ -n "$WTLINE" ]; then ok "A: emits WORKTREE_DIR"; else fail "A: no WORKTREE_DIR line — $OUT"; fi
A_DIR="${WTLINE#WORKTREE_DIR=}"
if [ "$A_DIR" != "$REPO_CANON" ] && [ -d "$A_DIR" ]; then
  ok "A: resolved to a NEW worktree, not the repo root"
else
  fail "A: expected a fresh worktree dir, got '$A_DIR'"
fi
if [ "$(git -C "$A_DIR" rev-parse --abbrev-ref HEAD)" = "feature" ]; then
  ok "A: resolved dir is on the PR branch"
else
  fail "A: resolved dir is not on 'feature'"
fi
if printf '%s' "$OUT" | grep -q 'pr-grind-mode: no-worktree'; then
  fail "A: emitted the no-worktree marker despite creating a worktree"
else
  ok "A: no no-worktree marker (worktree mode)"
fi
git -C "$REPO" worktree remove "$A_DIR" --force

# --- case B: branch checked out HERE → in-place fallback ----------------------
cd "$REPO" || exit 1
git checkout -q feature
run 421 feature "$(git -C "$REPO" rev-parse feature)"
if [ "$RC" -eq 0 ]; then ok "B: exits 0 when branch is checked out here"; else fail "B: expected 0, got $RC — $OUT"; fi
if printf '%s' "$OUT" | grep -q '^pr-grind-mode: no-worktree$'; then
  ok "B: emits the exact no-worktree marker the dispatcher scans for"
else
  fail "B: missing 'pr-grind-mode: no-worktree' — $OUT"
fi
B_DIR=$(printf '%s' "$OUT" | grep '^WORKTREE_DIR=' | sed 's/^WORKTREE_DIR=//')
if [ "$B_DIR" = "$REPO_CANON" ]; then ok "B: WORKTREE_DIR is the repo root"; else fail "B: expected '$REPO_CANON', got '$B_DIR'"; fi
git checkout -q main

# --- case C: branch held by ANOTHER worktree → BAIL, never the repo root ------
# This is the #421 regression. Repo root sits on `main`; `feature` is elsewhere.
OTHER="$TMP/work/other"
git -C "$REPO" worktree add -q "$OTHER" feature
cd "$REPO" || exit 1
run 421 feature "$(git -C "$REPO" rev-parse feature)"
if [ "$RC" -ne 0 ]; then ok "C: BAILs when the branch is held by another worktree"; else fail "C: expected non-zero, got 0 — the #421 fail-open is back"; fi
if printf '%s' "$OUT" | grep -q "^WORKTREE_DIR=$REPO_CANON$"; then
  fail "C: pointed WORKTREE_DIR at the repo root (on 'main') — the #421 bug"
else
  ok "C: did NOT emit the repo root as WORKTREE_DIR"
fi
if printf '%s' "$OUT" | grep -qF "$OTHER"; then
  ok "C: names the holding worktree in the bail message"
else
  fail "C: bail message does not name the holder — $OUT"
fi
git -C "$REPO" worktree remove "$OTHER" --force

# --- case D: the unconditional assertion fails closed -------------------------
# Exercised by handing the resolver a non-branch ref (a raw SHA). `git worktree
# add` happily succeeds with a DETACHED HEAD, so the three-way split above is
# satisfied and only the assertion can catch it — which is the point: this is
# the backstop firing, not the split.
cd "$REPO" || exit 1
SHA=$(git rev-parse HEAD)
run 421 "$SHA" "$SHA"
if [ "$RC" -ne 0 ]; then ok "D: assertion BAILs on a detached (non-branch) resolution"; else fail "D: detached worktree accepted — the assertion did not fire"; fi
if [ ! -d "$TMP/work/pr-grind-421" ]; then
  ok "D: cleaned up the worktree it created before bailing"
else
  fail "D: stranded a worktree at $TMP/work/pr-grind-421"
fi

# --- case E: SHA mismatch — stale/unrelated same-named local branch -----------
# The name assertion alone would pass here: the local branch really is called
# `feature`. Only the SHA check catches that it is not the revision the PR is at
# (the fork-PR / never-fetched case).
cd "$REPO" || exit 1
run 421 feature "0000000000000000000000000000000000000000"
if [ "$RC" -ne 0 ]; then ok "E: BAILs when local branch is not at the PR head SHA"; else fail "E: accepted a branch at the wrong revision — name-only assertion is back"; fi
if printf '%s' "$OUT" | grep -q 'fetch or push'; then
  ok "E: bail message tells the operator how to reconcile"
else
  fail "E: SHA-mismatch message is not actionable — $OUT"
fi

# --- case F: both git diagnostic phrasings are classified ---------------------
# git ≥2.x says "already used by worktree at"; older git says "already checked
# out at". Matching only the newer form sent an ordinary in-place case down the
# unclassified-fatal branch.
#
# Drive the REAL resolver against both phrasings via a `git` shim earlier on
# PATH that fakes only `worktree add` and delegates everything else to the real
# binary. Re-running the production regex inside the test would prove nothing:
# both copies could drift together, or share a defect (an earlier revision of
# this test did exactly that and passed while the resolver was broken on BSD).
SHIM_DIR="$TMP/shim"
mkdir -p "$SHIM_DIR"
REAL_GIT=$(command -v git)
# Holder paths are not always tidy — exercise one containing spaces so the
# extractor's quoting is covered, not just the two diagnostic wordings.
SPACED="$TMP/holder with spaces"
mkdir -p "$SPACED"
for phrasing in "is already used by worktree at" "is already checked out at"; do
  cat > "$SHIM_DIR/git" <<SHIM
#!/usr/bin/env bash
if [ "\$1" = "worktree" ] && [ "\$2" = "add" ]; then
  echo "fatal: 'feature' $phrasing '$REPO_CANON'" >&2
  exit 128
fi
exec "$REAL_GIT" "\$@"
SHIM
  chmod +x "$SHIM_DIR/git"
  cd "$REPO" || exit 1
  git checkout -q feature
  # The shim reports the holder as the repo root, so the resolver must take the
  # in-place branch — the same classification a real old git would produce.
  OUT=$(PATH="$SHIM_DIR:$PATH" "$RESOLVER" 421 feature "$(git rev-parse feature)" 2>&1); RC=$?
  if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q '^pr-grind-mode: no-worktree$'; then
    ok "F: resolver classifies '$phrasing' as the in-place case"
  else
    fail "F: resolver mishandled '$phrasing' (rc=$RC) — $OUT"
  fi
  git checkout -q main

  # Same phrasing, but the holder is a DIFFERENT worktree whose path contains
  # spaces: the resolver must extract it intact and name it in the bail.
  cat > "$SHIM_DIR/git" <<SHIM
#!/usr/bin/env bash
if [ "\$1" = "worktree" ] && [ "\$2" = "add" ]; then
  echo "fatal: 'feature' $phrasing '$SPACED'" >&2
  exit 128
fi
exec "$REAL_GIT" "\$@"
SHIM
  chmod +x "$SHIM_DIR/git"
  OUT=$(PATH="$SHIM_DIR:$PATH" "$RESOLVER" 421 feature "$(git rev-parse feature)" 2>&1); RC=$?
  if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -qF "$SPACED"; then
    ok "F: extracts a space-containing holder path ('$phrasing')"
  else
    fail "F: lost the space-containing holder path (rc=$RC) — $OUT"
  fi
done
rm -rf "$SHIM_DIR"

# --- case G: argument validation ---------------------------------------------
run
if [ "$RC" -ne 0 ]; then ok "G: BAILs on missing args"; else fail "G: accepted empty args"; fi
run 421 feature
if [ "$RC" -ne 0 ]; then ok "G: BAILs when head SHA arg is absent"; else fail "G: accepted a missing head SHA"; fi

# PR_NUMBER lands in WORKTREE_DIR, which the assertion's cleanup passes to
# `git worktree remove --force`. A traversing value must never reach it.
cd "$REPO" || exit 1
FEATURE_SHA=$(git rev-parse feature)
for bad in "../escape" "4/2/1" ".." "42; rm -rf /" "4 2"; do
  run "$bad" feature "$FEATURE_SHA"
  if [ "$RC" -ne 0 ]; then
    ok "G: rejects non-numeric pr-number '$bad'"
  else
    fail "G: ACCEPTED traversing/injecting pr-number '$bad'"
  fi
done
if [ ! -e "$TMP/work/pr-grind-../escape" ] && [ ! -e "$TMP/escape" ]; then
  ok "G: no directory created outside the intended location"
else
  fail "G: a traversing pr-number created a directory outside the sibling path"
fi
run 421 feature "not-hex-at-all"
if [ "$RC" -ne 0 ]; then ok "G: rejects a non-hex head SHA"; else fail "G: accepted a non-hex head SHA"; fi

echo "Results: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
