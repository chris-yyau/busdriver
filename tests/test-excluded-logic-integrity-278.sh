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

# Verbatim port of the guard's LEXICAL membership + status decision (STEP 1b),
# updated (PR #280) to match dispatcher-commit-block.sh's ".." collapse and
# committed-symlink rejection.
# Returns "BAIL" if the in-worktree logic file has divergence, else "CLEAN".
# worktree_dir is the trusted dispatcher input; logic_file is $LITMUS_SCRIPTS/lib/...
_lexical_collapse() { # pure string ".."/"."/duplicate-"/" collapse — no filesystem access
  local path="$1" out="" s parts
  # Split on "/" without glob expansion (mirrors dispatcher-commit-block.sh; an
  # unquoted `parts=($path)` under IFS=/ would also glob "*"/"?"/"[" segments).
  IFS=/ read -r -a parts <<< "$path"
  for s in "${parts[@]}"; do
    case "$s" in
      ""|".") continue ;;
      "..") out="${out%/*}" ;;
      *) out="$out/$s" ;;
    esac
  done
  [[ -z "$out" ]] && out="/"
  printf '%s' "$out"
}

decide() { # <worktree_dir> <logic_file(abs|relative-to-worktree)>
  local worktree_dir="$1" logic_file="$2" rel status
  while [[ "$worktree_dir" == */ && "$worktree_dir" != "/" ]]; do worktree_dir="${worktree_dir%/}"; done
  case "$logic_file" in /*) : ;; *) logic_file="$worktree_dir/$logic_file" ;; esac
  # PURELY LEXICAL ".." collapse (string manipulation only, no filesystem access —
  # cannot be fooled by a symlink swap the way realpath/pwd -P could). Apply the
  # IDENTICAL collapse to worktree_dir too, so an incidental double-slash (e.g.
  # from a TMPDIR with a trailing slash) can't desync the prefix match.
  worktree_dir=$(_lexical_collapse "$worktree_dir")
  logic_file=$(_lexical_collapse "$logic_file")
  # #280 regression: symlinked-plugin-root defense. If logic_file is lexically
  # OUTSIDE worktree_dir but PHYSICALLY resolves inside it (plugin root is a
  # symlink into the worktree), the lexical case below would wrongly classify
  # it as trusted-external and skip the guard entirely, while sourcing it
  # later would follow the symlink into mutable worktree content. Resolve
  # both to their physical paths ONCE (trusted roots, not attacker-controlled
  # components) purely to catch this classification mismatch.
  if [[ "$logic_file" != "$worktree_dir"/* ]]; then
    local real_wt real_dir
    real_wt=$(cd "$worktree_dir" 2>/dev/null && pwd -P) || { echo BAIL; return; }
    real_dir=$(cd "$(dirname "$logic_file")" 2>/dev/null && pwd -P) || real_dir=""
    if [[ -n "$real_dir" ]] && { [[ "$real_dir" == "$real_wt" ]] || [[ "$real_dir" == "$real_wt"/* ]]; }; then
      echo BAIL; return
    fi
  fi
  case "$logic_file" in
    "$worktree_dir"/*)
      rel="${logic_file#"$worktree_dir"/}"
      # Reject a committed symlink at ANY component of the logic path (leaf OR a
      # parent dir): git status only tracks a symlink's target-string blob, and a
      # committed-symlink PARENT (e.g. lib/) reports clean for a path underneath it
      # while the source follows it to unverified content (litmus, PR #280).
      local prefix="" seg segs
      IFS=/ read -r -a segs <<< "$rel"
      for seg in "${segs[@]}"; do
        [[ -z "$seg" || "$seg" == "." ]] && continue
        prefix="${prefix:+$prefix/}$seg"
        [[ -L "$worktree_dir/$prefix" ]] && { echo BAIL; return; }
      done
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

# #280 regression: a RELATIVE plugin root containing ".." (e.g.
# CLAUDE_PLUGIN_ROOT=../external-plugin) must not lexically string-prefix-match
# "$worktree_dir"/* — the ".." must be collapsed first, resolving OUTSIDE the
# worktree, correctly treated as trusted-external (no bail on a bogus
# out-of-repo git-status pathspec).
ext_plugin="$base/external-plugin/scripts/lib/exclude-generated.sh"
mkdir -p "$(dirname "$ext_plugin")"; printf '#defaults\n#external\n' > "$ext_plugin"
r=$(decide "$wt" "../external-plugin/scripts/lib/exclude-generated.sh")
check "relative '..'-escaping plugin root → no bail (trusted, not fail-closed)" CLEAN "$r"

# #280 regression: a COMMITTED symlink for the logic file itself. git status
# only tracks the symlink's target-string blob, so mutating the external
# target's content leaves git status clean — the guard must reject the
# symlink outright rather than trust git status here.
rm -f "$wt/skills/litmus/scripts/lib/exclude-generated.sh"
sym_target="$base/evil-logic.sh"; printf '#evil\n' > "$sym_target"
ln -s "$sym_target" "$wt/skills/litmus/scripts/lib/exclude-generated.sh"
git -C "$wt" add -A; git -C "$wt" commit -q -m "commit symlinked logic file"
r=$(decide "$wt" "$logic"); check "committed symlink logic file → BAIL" BAIL "$r"
# Restore a regular tracked file so cleanup below is unaffected.
rm -f "$wt/skills/litmus/scripts/lib/exclude-generated.sh"
printf '#defaults\n' > "$wt/skills/litmus/scripts/lib/exclude-generated.sh"
git -C "$wt" add -A; git -C "$wt" commit -q -m "restore regular logic file"

# #280 regression: a COMMITTED symlink at a PARENT component of the logic path
# (lib/ committed as a symlink to an external dir). git status on the path UNDER
# the symlink reports clean (nothing tracked there), so a leaf-only -L check
# passes while the source follows lib/ to unverified content. Only walking EVERY
# component catches the symlinked parent.
wt2="$base/repo-symparent"; mkdir -p "$wt2/skills/litmus/scripts"
git -C "$wt2" init -q; git -C "$wt2" config user.email t@t; git -C "$wt2" config user.name t
ext_parent="$base/evil-parent"; mkdir -p "$ext_parent"; printf '#evil\n' > "$ext_parent/exclude-generated.sh"
ln -s "$ext_parent" "$wt2/skills/litmus/scripts/lib"
printf 'x\n' > "$wt2/f.txt"
git -C "$wt2" add -A; git -C "$wt2" commit -q -m "commit symlinked lib parent"
r=$(decide "$wt2" "skills/litmus/scripts/lib/exclude-generated.sh")
check "committed symlink PARENT component → BAIL" BAIL "$r"

# #280 regression: symlinked PLUGIN ROOT into the worktree. logic_file's
# lexical path runs through a symlink dir OUTSIDE worktree_dir, so it never
# lexically matches "$worktree_dir"/* — but it physically resolves inside
# the worktree. Must BAIL rather than silently trust as external.
wt3="$base/repo-symroot"; mkdir -p "$wt3/skills/litmus/scripts/lib"
git -C "$wt3" init -q; git -C "$wt3" config user.email t@t; git -C "$wt3" config user.name t
printf '#tampered-via-symroot\n' > "$wt3/skills/litmus/scripts/lib/exclude-generated.sh"
printf 'x\n' > "$wt3/f.txt"
git -C "$wt3" add -A; git -C "$wt3" commit -q -m init
symroot="$base/plugin-symlink-root"
ln -s "$wt3" "$symroot"
r=$(decide "$wt3" "$symroot/skills/litmus/scripts/lib/exclude-generated.sh")
check "symlinked plugin root resolving into worktree → BAIL" BAIL "$r"
rm -f "$symroot"

rm -rf "$base"
echo "───────────────────────────────"
echo "Total: $((pass+fail))  Pass: $pass  Fail: $fail"
[[ "$fail" -eq 0 ]]
