#!/usr/bin/env bash
# test-excluded-logic-integrity-278.sh
# Regression for the #278 excluded-only "exclusion-logic integrity" guard in
# scripts/dispatcher-commit-block.sh. The guard must detect a tampered/removed
# exclude-generated.sh that lives INSIDE the reviewed worktree BEFORE sourcing
# it — and crucially must NOT be defeated by `git rm --cached` (which untracks
# the file while leaving a tamperable worktree copy).
#
# Membership is decided LEXICALLY against the trusted WORKTREE_DIR input (trailing
# slashes stripped, relative logic path normalized to absolute against it), then a
# `git status --porcelain` on the tracked path bails on any divergence — git
# reports on the tracked path regardless of symlink/index games, so `rm --cached`
# and a symlink-swapped lib/ are both caught.
#
# This test replicates the guard's exact decision logic against scratch repos —
# the dispatcher fixture keeps exclude-generated.sh outside its sandbox, so the
# in-worktree branch can't be exercised there.
set -uo pipefail

pass=0 fail=0
check() { # name expected(BAIL|CLEAN) actual
  if [[ "$3" == "$2" ]]; then echo "PASS: $1"; pass=$((pass+1))
  else echo "FAIL: $1 — expected $2 got $3"; fail=$((fail+1)); fi
}

# Verbatim port of the guard's LEXICAL membership + status decision (STEP 1b).
# Returns "BAIL" if the in-worktree logic file has divergence, else "CLEAN".
# worktree_dir is the trusted dispatcher input; logic_file is $LITMUS_SCRIPTS/lib/...
decide() { # <worktree_dir> <logic_file(abs|relative-to-worktree)>
  local worktree_dir="$1" logic_file="$2" rel status
  while [[ "$worktree_dir" == */ && "$worktree_dir" != "/" ]]; do worktree_dir="${worktree_dir%/}"; done
  case "$logic_file" in /*) : ;; *) logic_file="$worktree_dir/$logic_file" ;; esac
  case "$logic_file" in
    "$worktree_dir"/*)
      rel="${logic_file#"$worktree_dir"/}"
      # Fail-CLOSED: a git status error bails, only a successful empty run is clean.
      if status=$(git -C "$worktree_dir" status --porcelain --untracked-files=all --ignored -- "$rel" 2>/dev/null); then
        [[ -n "$status" ]] && { echo BAIL; return; }
      else
        echo BAIL; return
      fi
      ;;
  esac
  echo CLEAN
}

base=$(mktemp -d "${TMPDIR:-/tmp}/logic-integrity-278.XXXXXX") || { echo "mktemp failed" >&2; exit 1; }

# --- Repo A: logic file tracked & committed inside worktree ---
wt="$base/repo"; mkdir -p "$wt/skills/litmus/scripts/lib"
git -C "$wt" init -q; git -C "$wt" config user.email t@t; git -C "$wt" config user.name t
printf '#defaults\n' > "$wt/skills/litmus/scripts/lib/exclude-generated.sh"
printf 'x\n' > "$wt/f.txt"
git -C "$wt" add -A; git -C "$wt" commit -q -m init
logic="$wt/skills/litmus/scripts/lib/exclude-generated.sh"

r=$(decide "$wt" "$logic"); check "committed-clean logic → no bail" CLEAN "$r"

# Vuln vector 1: git rm --cached untracks the file, worktree copy remains.
git -C "$wt" rm -q --cached skills/litmus/scripts/lib/exclude-generated.sh
r=$(decide "$wt" "$logic"); check "rm --cached (untracked worktree copy) → BAIL" BAIL "$r"
git -C "$wt" reset -q --hard; git -C "$wt" clean -qfd

# Vuln vector 2: replace the in-worktree lib/ dir with a symlink to an external
# attacker dir. git status reports the tracked lib/ files as deleted → BAIL.
ext="$base/evil"; mkdir -p "$ext"; printf '#evil\n' > "$ext/exclude-generated.sh"
rm -rf "$wt/skills/litmus/scripts/lib"
ln -s "$ext" "$wt/skills/litmus/scripts/lib"
r=$(decide "$wt" "$logic"); check "symlink-swap of lib/ → BAIL" BAIL "$r"
rm -f "$wt/skills/litmus/scripts/lib"; git -C "$wt" reset -q --hard; git -C "$wt" clean -qfd

# Unstaged modification of the tracked logic file.
printf '#tampered **/*.sh\n' >> "$wt/skills/litmus/scripts/lib/exclude-generated.sh"
r=$(decide "$wt" "$logic"); check "unstaged modification → BAIL" BAIL "$r"
git -C "$wt" checkout -q -- skills/litmus/scripts/lib/exclude-generated.sh

# Staged modification.
printf '#staged tamper\n' >> "$wt/skills/litmus/scripts/lib/exclude-generated.sh"
git -C "$wt" add skills/litmus/scripts/lib/exclude-generated.sh
r=$(decide "$wt" "$logic"); check "staged modification → BAIL" BAIL "$r"
git -C "$wt" reset -q --hard

# Relative logic path (e.g. CLAUDE_PLUGIN_ROOT=.) must normalize to in-worktree
# and still catch tampering — not silently skip the guard.
printf '#tampered\n' >> "$wt/skills/litmus/scripts/lib/exclude-generated.sh"
r=$(decide "$wt" "skills/litmus/scripts/lib/exclude-generated.sh"); check "relative in-worktree path → BAIL" BAIL "$r"
git -C "$wt" checkout -q -- skills/litmus/scripts/lib/exclude-generated.sh

# Trailing slash on WORKTREE_DIR must NOT skip the guard (the "$wt"/* pattern
# would otherwise become /repo//* and miss a normal /repo/skills/... path).
printf '#tampered\n' >> "$wt/skills/litmus/scripts/lib/exclude-generated.sh"
r=$(decide "$wt/" "$logic"); check "trailing-slash WORKTREE_DIR → BAIL" BAIL "$r"
git -C "$wt" checkout -q -- skills/litmus/scripts/lib/exclude-generated.sh

# A gitignored in-worktree logic file is untracked-and-unreviewed → must BAIL.
# (--untracked-files=all alone would NOT report it; --ignored does, as !!.)
git -C "$wt" rm -q --cached skills/litmus/scripts/lib/exclude-generated.sh
printf 'skills/litmus/scripts/lib/exclude-generated.sh\n' > "$wt/.gitignore"
git -C "$wt" add .gitignore; git -C "$wt" commit -q -m "ignore logic file"
# worktree copy remains, now ignored + untracked
r=$(decide "$wt" "$logic"); check "gitignored in-worktree logic → BAIL" BAIL "$r"
git -C "$wt" rm -q .gitignore; git -C "$wt" commit -q -m "unignore"
git -C "$wt" add skills/litmus/scripts/lib/exclude-generated.sh; git -C "$wt" commit -q -m "retrack"

# --- Repo B: logic file OUTSIDE the worktree (trusted plugin-cache case) ---
outside="$base/plugin/skills/litmus/scripts/lib/exclude-generated.sh"
mkdir -p "$(dirname "$outside")"; printf '#defaults\n#dirty\n' > "$outside"
r=$(decide "$wt" "$outside"); check "logic file outside worktree → no bail (trusted)" CLEAN "$r"

rm -rf "$base"
echo "───────────────────────────────"
echo "Total: $((pass+fail))  Pass: $pass  Fail: $fail"
[[ "$fail" -eq 0 ]]
