#!/usr/bin/env bash
# scripts/shipping-merge-watch.sh — wait for Cursor Shipping to land a kicked PR, and print
# the cleanup commands for the operator once it has.
#
# Usage:
#   shipping-merge-watch.sh <owner>/<repo> <PR_NUMBER> [INTERVAL_SECS] [CAP_SECS]
#   shipping-merge-watch.sh --cleanup <owner>/<repo> <PR_NUMBER>   (run in the repo's checkout)
#
# After pr-grind posts a Shipping kick (ADR 0055) the cloud agent merges the PR, and
# nothing in the session learns about it, so the operator's branch and worktree go
# stale. pr-grind runs the watch in the background right after the kick.
#
# Watch mode prints exactly ONE line, then exits:
#   merged <PR> <merge-commit-oid>        exit 0
#   closed <PR>                           exit 3  (closed without merging)
#   timeout <PR> <CAP>s <last-state>      exit 5  (still open, or never readable)
#   error: <reason>                       exit 2  (bad arguments)
# A head move is NOT terminal: Shipping updates a BEHIND branch itself before it merges.
# A failed or hung `gh` read (each is cut off at 60s or the time left) is retried on
# the next poll, never treated as an outcome.
#
# Defaults: poll every 60s for up to 5400s. Measured 2026-10-12 over the three opted-in
# repos: 15 auto-kicked PRs merged 6.9-12.5 min after the kick, one hand kick took
# 53.6 min, and no kicked PR went unmerged. 90 min leaves wide headroom over all of it.
#
# Cleanup mode prints the commands that apply, one per line, each prefixed `! ` and
# shell-quoted with %q so a branch or path is inert data. It never runs them: deleting
# a worktree or branch is the operator's call.
set -u

check_repo_pr() {   # validates $repo and $pr, or exits 2
  case $repo in */*) ;; *) echo "error: repo must be <owner>/<repo>"; exit 2 ;; esac
  case $repo in *[!A-Za-z0-9._/-]* | */*/* | /* | */) echo "error: bad repo '$repo'"; exit 2 ;; esac
  case $pr in '' | *[!0-9]* | ???????* | 0*) echo "error: bad PR number '$pr'"; exit 2 ;; esac
}
# bounded <secs> <cmd...>: run cmd, SIGKILL it after <secs>. gh is a Go program, which
# catches SIGALRM and keeps running, so a bare alarm cannot stop it; this forks the
# command into its own process group and kills the whole group from outside, so an ssh
# or credential-helper child dies with it. A run killed by a signal reports failure.
bounded() {
  perl -e '$t = shift; $p = fork // exit 125;
           if (!$p) { setpgrp(0, 0); exec @ARGV; exit 127 }
           $SIG{ALRM} = sub { kill "KILL", -$p; kill "KILL", $p; waitpid $p, 0; exit 124 };
           # Session shutdown signals this group, not the read group: kill that too.
           for my $s ([HUP => 1], [INT => 2], [TERM => 15]) {
             my $c = 128 + $s->[1]; $SIG{$s->[0]} = sub { kill "KILL", -$p; kill "KILL", $p; waitpid $p, 0; exit $c } }
           alarm $t; waitpid $p, 0; $rc = $?;
           kill "KILL", -$p;   # a straggler left in the group would hold stdout open
           exit($rc & 127 ? 128 + ($rc & 127) : $rc >> 8)' "$@"
}
export GIT_TERMINAL_PROMPT=0   # a credential prompt must fail, not wait
# Same routing containment as the Codex nudge: a repo-controlled settings env must not
# steer these credentialed reads to another host or repository.
export GH_HOST=github.com
unset GH_REPO

if [ "${1-}" = --cleanup ]; then
  # Run in the PR's repository checkout. Nothing caller-typed reaches a command but the
  # validated repo and PR: the branch names come from GitHub, the worktree from git.
  repo=${2-} pr=${3-}
  check_repo_pr
  refs=$(bounded 60 gh pr view "$pr" -R "$repo" --json headRefName,baseRefName,headRefOid,isCrossRepository,state \
           -q '"\(.headRefName) \(.baseRefName) \(.headRefOid) \(.isCrossRepository) \(.state)"' 2>/dev/null) \
    || { echo "error: cannot read PR $pr"; exit 1; }
  read -r br base head cross state <<<"$refs"
  [ "$state" = MERGED ] || { echo "note: PR $pr is not merged; no cleanup offered"; exit 0; }
  # A fork's head branch is not a branch of this repository, even when it shares a name.
  [ "$cross" = false ] || { echo "note: PR $pr is from a fork; no cleanup offered"; exit 0; }
  [ "$br" != "$base" ] || { echo "note: PR $pr head and base are both $(printf %q "$br"); no cleanup offered"; exit 0; }
  for b in "$br" "$base"; do
    git check-ref-format --branch "$b" >/dev/null 2>&1 || { echo "error: bad branch name from GitHub"; exit 1; }
  done
  case $head in *[!0-9a-f]* | '') echo "error: bad head commit from GitHub"; exit 1 ;; esac
  # Every command runs from this checkout, which any worktree of the repository can do.
  root=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "error: not in a git work tree"; exit 1; }
  # NUL-delimited, so a path holding a newline is read whole. The first entry is the main
  # worktree, which can be switched but not removed. A process substitution drops git's
  # exit status, so a trailing OK field (never a porcelain field) proves it succeeded.
  wts=()
  while IFS= read -r -d '' f; do wts+=("$f"); done < <(git -C "$root" worktree list --porcelain -z && printf 'OK\0')
  if ! { [ "${#wts[@]}" -gt 1 ] && [ "${wts[${#wts[@]}-1]}" = OK ]; }; then
    echo "error: cannot list worktrees"; exit 1
  fi
  unset 'wts[${#wts[@]}-1]'
  # This checkout must be the PR's repository, not a fork or another clone of it.
  remote=$(git -C "$root" remote -v 2>/dev/null | awk -v r="$repo" '
       $3 == "(fetch)" { u = tolower($2); sub(/\.git$/, "", u)
         if (u == "https://github.com/" tolower(r) || u == "git@github.com:" tolower(r) \
             || u == "ssh://git@github.com/" tolower(r)) { print $1; exit } }')
  if [ -z "$remote" ]; then
    echo "note: no remote of this checkout is github.com/$repo; no cleanup offered"
    exit 0
  fi
  # Shipping may have updated a BEHIND branch in the cloud: fetch that head from the
  # matching remote so the ancestry check below can see it. Fetching a commit writes no ref.
  bounded 60 git -C "$root" cat-file -e "$head^{commit}" 2>/dev/null \
    || bounded 60 git -C "$root" fetch -q --no-tags "$remote" "$head" 2>/dev/null || true
  tip=$(git -C "$root" rev-parse -q --verify "refs/heads/$br^{commit}") || exit 0   # no local branch
  # Offer cleanup only for the branch this PR merged: the local tip must be the PR head
  # or behind it. That proves the repository too (an unrelated checkout cannot hold the
  # PR's commits) and that nothing was committed locally after the push.
  if [ "$tip" != "$head" ] && ! git -C "$root" merge-base --is-ancestor "$tip" "$head" 2>/dev/null; then
    echo "note: local $(printf %q "$br") is not the PR head or behind it; no cleanup offered"
    exit 0
  fi
  wt="" w="" base_held="" first=""
  for f in "${wts[@]}"; do
    case $f in
      "worktree "*) w=${f#worktree } ;;
      "branch refs/heads/$br") wt=$w ;;
      "branch refs/heads/$base") base_held=$w ;;
    esac
  done
  if [ -n "$wt" ] && [ "worktree $wt" = "${wts[0]}" ]; then
    # With a separate git dir, git lists the git dir here; that cannot be switched.
    [ "$(git -C "$wt" rev-parse --is-inside-work-tree 2>/dev/null)" = true ] \
      || { echo "note: $(printf %q "$br") is checked out in an unrecognised main worktree; no cleanup offered"; exit 0; }
    # Switch to the base only if it exists locally and no other worktree holds it.
    if [ -n "$base_held" ] || ! git -C "$wt" show-ref --verify --quiet "refs/heads/$base"; then
      first=$(printf 'git -C %q switch --detach' "$wt")
    else
      first=$(printf 'git -C %q switch %q' "$wt" "$base")
    fi
  elif [ -n "$wt" ]; then
    if [ "$wt" = "$root" ]; then
      # Run from the main worktree, so the branch -D below does not start in the
      # directory this command removes.
      main=${wts[0]#worktree }
      [ "$(git -C "$main" rev-parse --is-inside-work-tree 2>/dev/null)" = true ] \
        || { echo "note: run cleanup from the main worktree; no cleanup offered"; exit 0; }
      root=$main
    fi
    # worktree remove refuses tracked changes and untracked files but deletes ignored ones.
    if st=$(bounded 60 git -C "$wt" -c status.showUntrackedFiles=normal status --porcelain \
              --untracked-files=normal --ignored=matching 2>/dev/null); then
      ign=$(printf '%s\n' "$st" | grep -c '^!! ')
      [ "$ign" -eq 0 ] \
        || echo "warning: $(printf %q "$wt") holds $ign ignored file(s) or dir(s) (e.g. .env, .claude/*.local); worktree remove deletes them"
    else
      echo "warning: could not check $(printf %q "$wt") for ignored files; worktree remove deletes any it holds"
    fi
    first=$(printf 'git -C %q worktree remove %q' "$root" "$wt")
  fi
  # -D: a squash merge leaves the branch unmerged by ancestry. It is the same unguarded
  # delete `gh pr merge --delete-branch` runs; git still refuses a checked-out branch.
  # Joined by &&, so the branch is not deleted if the worktree step fails.
  del=$(printf 'git -C %q branch -D %q' "$root" "$br")
  printf '! %s\n' "${first:+$first && }$del"
  exit 0
fi

repo=${1-} pr=${2-} interval=${3-60} cap=${4-5400}
check_repo_pr
for v in "$interval" "$cap"; do
  # Six digits at most, so the arithmetic below cannot overflow.
  case $v in '' | *[!0-9]* | ???????*) echo "error: interval and cap must be integers of at most 6 digits"; exit 2 ;; esac
done
interval=$((10#$interval)) cap=$((10#$cap))

deadline=$(( $(date +%s) + cap ))
last=unread
while :; do
  left=$(( deadline - $(date +%s) ))
  t=$(( left < 1 ? 1 : (left < 60 ? left : 60) ))   # one read always runs, even at cap 0
  if out=$(bounded "$t" \
             gh pr view "$pr" -R "$repo" --json state,mergeCommit \
             -q '"\(.state) \(.mergeCommit.oid // "")"' 2>/dev/null); then
    state=${out%% *} oid=${out#* }
    last=$state
    case $state in
      MERGED) echo "merged $pr $oid"; exit 0 ;;
      CLOSED) echo "closed $pr"; exit 3 ;;
    esac
  fi
  left=$(( deadline - $(date +%s) ))
  [ "$left" -gt 0 ] || { echo "timeout $pr ${cap}s $last"; exit 5; }
  sleep $(( interval < 1 ? 1 : (interval < left ? interval : left) ))   # interval 0 must not spin
done
