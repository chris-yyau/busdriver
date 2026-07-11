#!/usr/bin/env bash
# Test: gate_skip_file_repo_controlled (issue #325, ADR 0016).
#
# A gitignored `.claude/*.local` skip file is only real operator consent when it
# is UNtracked. `.gitignore` blocks an accidental `git add`, not `git add -f`, so
# a malicious PR could commit a skip file and bypass the gate after checkout. The
# helper must REJECT (return 0) any skip file tracked in the index or HEAD, and
# HONOR (return 1) only a genuinely untracked one. FAIL-CLOSED on git errors.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../hooks/gate-scripts/lib/resolve-repo-dir.sh disable=SC1091
source "$REPO_ROOT/hooks/gate-scripts/lib/resolve-repo-dir.sh"

PASS=0; FAIL=0
assert() { if [[ "$1" -eq 0 ]]; then PASS=$((PASS+1)); printf '  ok   %s\n' "$2"; else FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$2"; fi; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
G="git -C $TMP -c user.email=t@t -c user.name=t -c commit.gpgsign=false -c init.defaultBranch=main"
$G init -q .
mkdir -p "$TMP/.claude"
printf 'skip\n' > "$TMP/.claude/skip-litmus.local"
printf '.claude/*.local\n' > "$TMP/.gitignore"
$G add .gitignore && $G commit -qm init

REL=".claude/skip-litmus.local"

# 1. Untracked (real operator consent) → honor (return 1).
! gate_skip_file_repo_controlled "$TMP" "$REL"; assert $? "untracked skip file is honored (not repo-controlled)"

# 2. Force-added to the index → repo-controlled → reject (return 0).
$G add -f "$REL"
gate_skip_file_repo_controlled "$TMP" "$REL"; assert $? "index-staged (git add -f) skip file is rejected"

# 3. Committed into HEAD → repo-controlled → reject (return 0).
$G commit -qm "sneak skip file"
gate_skip_file_repo_controlled "$TMP" "$REL"; assert $? "committed (in HEAD) skip file is rejected"

# 4. Empty repo root → fail-closed → reject (return 0).
gate_skip_file_repo_controlled "" "$REL"; assert $? "empty root fails closed (rejected)"

# 5. Non-repo dir → git errors → fail-closed → reject (return 0).
gate_skip_file_repo_controlled "$TMP/nope" "$REL"; assert $? "unqueryable root fails closed (rejected)"

# 6. Parent `.claude` committed as a SYMLINK (mode 120000) → git resolves the skip
#    file behind it, leaf-path checks miss it → must reject (return 0).
TMP2="$(mktemp -d)"
G2="git -C $TMP2 -c user.email=t@t -c user.name=t -c commit.gpgsign=false -c init.defaultBranch=main"
$G2 init -q .
mkdir -p "$TMP2/real"
printf 'skip\n' > "$TMP2/real/skip-litmus.local"
$G2 add -f real/skip-litmus.local
ln -s real "$TMP2/.claude"          # .claude -> real (tracked as a symlink)
$G2 add "$TMP2/.claude"
$G2 commit -qm "sneak via .claude symlink"
gate_skip_file_repo_controlled "$TMP2" "$REL"; assert $? "committed .claude symlink is rejected"
rm -rf "$TMP2"

# 7. root="." from the repo root (the shape pre-implementation-gate uses): a committed
#    skip file must still be detected. ($TMP still has $REL committed from case 3.)
( cd "$TMP" && gate_skip_file_repo_controlled "." "$REL" ); assert $? "root=. detects committed skip file (pre-impl call shape)"

# 8. In HEAD but removed from the index (git rm --cached): the index check misses it,
#    so the HEAD:./<rel> check must catch it — this is exactly the root=. vs repo-root
#    anchoring bug the `HEAD:./` form fixes.
$G rm --cached -q "$REL"
( cd "$TMP" && gate_skip_file_repo_controlled "." "$REL" ); assert $? "root=. detects HEAD-only skip file via HEAD:./ check"

# 9. UNBORN repo (git init, no commits): an untracked skip file is genuine operator
#    consent — HEAD does not resolve, but this is legitimate, so HONOR (return 1).
TMP3="$(mktemp -d)"
G3="git -C $TMP3 -c user.email=t@t -c user.name=t -c init.defaultBranch=main"
$G3 init -q .
mkdir -p "$TMP3/.claude"; printf 'skip\n' > "$TMP3/.claude/skip-litmus.local"
! gate_skip_file_repo_controlled "$TMP3" "$REL"; assert $? "unborn repo honors untracked skip file (HEAD unresolved is not an error)"

# 10. CORRUPT HEAD (ref points at a missing, non-null object): git resolves the sha
#     syntactically (rev-parse --verify HEAD == 0) but HEAD's tree is unreadable — a git
#     error that must FAIL CLOSED (return 0), NOT be mistaken for the unborn case.
printf 'ref: refs/heads/main\n' > "$TMP3/.git/HEAD"
printf 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeef\n' > "$TMP3/.git/refs/heads/main"
gate_skip_file_repo_controlled "$TMP3" "$REL"; assert $? "corrupt HEAD (missing object) fails closed (rejected)"
rm -rf "$TMP3"

# 11. CORRUPT NESTED SUBTREE: HEAD and its ROOT tree are intact, but the `.claude/`
#     subtree object needed to resolve the skip-file path is missing. `cat-file -e` /
#     `HEAD^{tree}` would pass the root-tree check and fail open; ls-tree errors → reject.
TMP4="$(mktemp -d)"
G4="git -C $TMP4 -c user.email=t@t -c user.name=t -c init.defaultBranch=main -c commit.gpgsign=false"
$G4 init -q .
mkdir -p "$TMP4/.claude"; printf 'skip\n' > "$TMP4/.claude/skip-litmus.local"
$G4 add -A; $G4 commit -qm c
SUBTREE=$($G4 rev-parse 'HEAD:.claude')
rm -f "$TMP4/.git/objects/${SUBTREE:0:2}/${SUBTREE:2}"    # delete the .claude subtree object
gate_skip_file_repo_controlled "$TMP4" "$REL"; assert $? "corrupt nested .claude subtree fails closed (root tree intact)"
rm -rf "$TMP4"

echo ""
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
echo "ALL SKIP-FILE-GUARD ASSERTIONS PASSED"
