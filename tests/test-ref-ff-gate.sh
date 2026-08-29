#!/usr/bin/env bash
# Tests for the ref fast-forward gate (issue #779).
#
# THE BYPASS UNDER TEST. A fast-forward moves a protected branch to commits
# litmus never reviewed WITHOUT creating a commit object, so no commit-oriented
# gate observes it. hooks/gate-scripts/ref-ff-gate.sh is the observation point;
# these cases pin both halves of its contract — that it BLOCKS the bypass, and
# that it does NOT block the ordinary operations it shares a command word with —
# feature-branch merges, everything off the protected branch, and every shape that
# belongs to another issue. On the protected branch itself the contract is
# deliberately narrow: ONE route, an operator marker naming an exact oid on a
# `git merge --ff-only <oid>`. `git pull` has no route at all, and the cases below
# pin that, because it is the command #779 opens with.
#
# Every case runs against a REAL temp repo with a REAL local "remote", so the
# fast-forward predicate, the ref-name resolution and the ancestry answers are
# exercised as git actually computes them, not as a fixture asserts them.
#
# Usage: bash tests/test-ref-ff-gate.sh
# Exit: 0 if all pass, 1 if any fail.

set -uo pipefail
cd "$(dirname "$0")/.."
REPO_ROOT="$(pwd)"
GATE_SCRIPT="$REPO_ROOT/hooks/gate-scripts/ref-ff-gate.sh"

PASS=0
FAIL=0

# Isolated state dir for the whole suite: the gate writes a real
# bypass-log.jsonl entry on every marker authorization, and consumes a real
# marker file. Pointing $BUSDRIVER_STATE_DIR at a scratch name keeps all of that
# inside the per-test temp repo and off the operator's own .claude/.
ISO_STATE=".claude-test-779-$$"
export BUSDRIVER_STATE_DIR="$ISO_STATE"

TMPROOT=$(mktemp -d) || { printf 'could not create temp dir\n' >&2; exit 1; }
trap 'rm -rf "$TMPROOT"' EXIT

# ── Fixture: a repo on `main`, an origin whose main is 1 commit ahead, and an
#    unreviewed local branch `feature` that also fast-forwards main. ────────
#    Exported for the assertions: REPO, FEATURE_OID, ORIGIN_MAIN_OID.
setup_repo() {
    REPO="$TMPROOT/repo-$1"
    rm -rf "$REPO" "$TMPROOT/origin-$1"
    ORIGIN="$TMPROOT/origin-$1"
    (
        set -e
        git init -q -b main "$ORIGIN"
        cd "$ORIGIN"
        git config user.email t@t; git config user.name t
        echo base > f; git add f; git commit -qm base
        # One more commit on origin/main — the "already landed through the gated
        # PR pipeline" content the pull arm must let through.
        echo landed >> f; git add f; git commit -qm landed

        git clone -q "$ORIGIN" "$REPO"
        cd "$REPO"
        git config user.email t@t; git config user.name t
        # Put local main one commit BEHIND origin/main so a pull/merge from it is
        # a genuine fast-forward rather than a no-op.
        git reset -q --hard HEAD~1
        # An unreviewed local branch that also fast-forwards main.
        git checkout -q -b feature
        echo unreviewed >> g; git add g; git commit -qm unreviewed
        git checkout -q main
    ) >/dev/null 2>&1 || return 1
    FEATURE_OID=$(git -C "$REPO" rev-parse 'feature^{commit}')
    ORIGIN_MAIN_OID=$(git -C "$REPO" rev-parse refs/remotes/origin/main)
    mkdir -p "$REPO/$ISO_STATE"
}

# Drive the gate with a PreToolUse payload whose `cwd` is $REPO.
#
# The optional 4th argument is a substring the block reason must contain. It is
# what separates a DELIBERATE block from the ERR trap's catch-all: the trap emits
# the same {"decision":"block"} shape, so a suite that only greps for "block"
# would score a gate that crashed on every input as fully passing.
run_gate() {  # <name> <expected: allow|block> <command> [reason substring]
    local name="$1" expected="$2" cmd="$3" want_reason="${4:-}"
    local payload output exit_code got
    payload=$(python3 -c '
import json, sys
print(json.dumps({"tool_name": "Bash", "cwd": sys.argv[1],
                  "tool_input": {"command": sys.argv[2]}}))' "$REPO" "$cmd")
    output=$(printf '%s' "$payload" | bash "$GATE_SCRIPT" 2>/dev/null) && exit_code=0 || exit_code=$?
    got="allow"
    if [[ "$exit_code" -ne 0 ]] && [[ -z "$output" ]]; then
        got="crash"
    elif echo "$output" | grep -q '"block"' 2>/dev/null; then
        got="block"
    fi
    if [[ "$got" != "$expected" ]]; then
        printf "  FAIL  %s (expected=%s got=%s)\n" "$name" "$expected" "$got"; FAIL=$((FAIL + 1))
        return
    fi
    if [[ -n "$want_reason" ]] && ! grep -qF "$want_reason" <<<"$output"; then
        printf "  FAIL  %s (blocked, but not for the stated reason: want %q)\n" "$name" "$want_reason"
        FAIL=$((FAIL + 1)); return
    fi
    printf "  PASS  %s\n" "$name"; PASS=$((PASS + 1))
}

assert_true() {  # <name> <status>
    if [[ "$2" -eq 0 ]]; then
        printf "  PASS  %s\n" "$1"; PASS=$((PASS + 1))
    else
        printf "  FAIL  %s\n" "$1"; FAIL=$((FAIL + 1))
    fi
}

# Write the marker with a backdated mtime so the 30s anti-self-bypass window
# (which exists to stop the agent minting its own authorization) does not
# swallow the cases that are about CONTENT matching.
write_marker() {  # <content>
    printf '%s\n' "$1" > "$REPO/$ISO_STATE/ref-ff-authorized.local"
    touch -t 200001010000 "$REPO/$ISO_STATE/ref-ff-authorized.local"
}

printf '\n=== ref fast-forward gate (#779) ===\n'

setup_repo main || { printf '  FAIL  fixture setup\n'; exit 1; }

# ── The bypass itself ────────────────────────────────────────────────
run_gate "merge of an unreviewed branch fast-forwards main → block" \
    block "git merge feature" "would FAST-FORWARD the protected branch"
run_gate "...and --ff-only is the same move, not an exemption" \
    block "git merge --ff-only feature"
run_gate "...and --no-commit still fast-forwards the ref (#779's named form)" \
    block "git merge --no-commit feature"
# "Resolves to itself" is an equality, not a length: object-id length depends on
# the repository's hash algorithm, so a 40- or 64-hex test accepted a REF whose
# name happens to be hex and bound the marker to something git looks up again.
git -C "$REPO" branch "$(printf '%064d' 0)" feature >/dev/null 2>&1
write_marker "PASS-FF refs/heads/main $FEATURE_OID"
run_gate "a 64-hex BRANCH NAME is not mistaken for a self-resolving oid" \
    block "git merge --ff-only $(printf '%064d' 0)" "a symbolic ref that git resolves again"
rm -f "$REPO/$ISO_STATE/ref-ff-authorized.local"
git -C "$REPO" branch -D "$(printf '%064d' 0)" >/dev/null 2>&1

run_gate "merge by raw oid → block (the ref name is not what binds)" \
    block "git merge $FEATURE_OID"
# ── A pull on the protected branch is refused OUTRIGHT. It cannot have a marker
#    route (the commit it lands does not exist locally yet), and every attempt to
#    authorize it by SOURCE read an input the gated party controls. These pin the
#    refusal — `git pull --ff-only` on main is the bypass #779 opens with, so an
#    allow here would be the whole issue reopened. ──────────────────────
run_gate "pull of a foreign refspec onto main → block" \
    block "git pull origin feature" "does not exist locally yet"
run_gate "pull from a non-upstream remote → block" \
    block "git pull /tmp/elsewhere main" "does not exist locally yet"
run_gate "pull --no-ff of reviewed content → block" \
    block "git pull --no-ff origin main" "does not exist locally yet"
run_gate "#779's own headline command is refused: pull --ff-only on main" \
    block "git pull --ff-only origin main" "does not exist locally yet"
run_gate "...and a bare pull, whatever the upstream is" \
    block "git pull" "does not exist locally yet"
# Config cannot buy a route, however it is spelled: git reads the
# GIT_CONFIG_COUNT family as if it were `-c`, that family is stripped from the
# gate's environment and not from the command's, so no config value the gate can
# read is a fact about the command.
git -C "$REPO" config pull.ff only
run_gate "...and pull.ff=only buys nothing" \
    block "git pull --ff-only origin main" "does not exist locally yet"
git -C "$REPO" config --unset pull.ff

# A remote's published HEAD does NOT separate a canonical remote from a fork, and
# neither does its URL once `url.<x>.insteadOf` can be set in an environment the
# gate never sees. Both checks were written, run, and removed rather than shipped
# as assurance they cannot give; this pins the measurement behind the first.
git -C "$REPO" remote add fork "$ORIGIN" >/dev/null 2>&1
git -C "$REPO" fetch -q fork >/dev/null 2>&1
_rc=0; git -C "$REPO" symbolic-ref --short refs/remotes/fork/HEAD >/dev/null 2>&1 || _rc=1
assert_true "a plain fetch gives a new remote its own HEAD (so it declares main)" "$_rc"
git -C "$REPO" remote remove fork >/dev/null 2>&1

# Two operations in one command: the opener is a NO-OP the gate would rightly
# allow on its own, and stopping there let the second one fast-forward main
# unseen. The whole command is refused instead.
run_gate "a no-op merge cannot escort a second merge past the gate" \
    block "git merge HEAD && git merge feature" "separate git merge/pull operations"
run_gate "...nor can an allowed merge escort a pull" \
    block "git merge origin/main; git pull origin feature" "separate git merge/pull operations"

# Last-wins option families: reading only the FIRST occurrence reported "not a
# fast-forward" for both of these and waved them past the gate entirely.
run_gate "--no-ff followed by --ff-only still fast-forwards → block" \
    block "git merge --no-ff --ff-only feature" "would FAST-FORWARD the protected branch"
run_gate "--squash cancelled by --no-squash is an ordinary merge again → block" \
    block "git merge --squash --no-squash feature" "would FAST-FORWARD the protected branch"

# A global that redirects the repo or rewrites the config the gate reads makes
# every answer it computes describe a different repository.
run_gate "--git-dir/--work-tree redirect the repo → block" \
    block "git --git-dir=/other/.git --work-tree=/other merge feature" "cannot be resolved statically"
run_gate "-c rewrites the very config the pull path reads → block" \
    block "git -c branch.main.merge=refs/heads/feature pull origin" "cannot be resolved statically"

# Time-of-check: the gate resolves the target before the command runs, so a
# ref write in the SAME command replaces what was checked.
run_gate "a ref write in the same command defeats the oid check → block" \
    block "git branch -f topic $FEATURE_OID && git merge topic" "SEPARATE call"
run_gate "...and a fetch counts, because it moves FETCH_HEAD" \
    block "git fetch origin main && git merge FETCH_HEAD" "SEPARATE call"
run_gate "...and a config rewrite counts too" \
    block "git config branch.main.merge refs/heads/feature && git pull origin" "SEPARATE call"

# A command-line alias spells a merge under a name the parser cannot know.
run_gate "an alias defined on the command line is unresolvable, not absent" \
    block "git -c alias.m=merge m feature" "cannot be resolved"
# ...and the alias can be defined INDIRECTLY, so the test is any config override,
# not an `alias.` key match.
run_gate "-c include.path can supply the alias from a file → block" \
    block "git -c include.path=/tmp/aliases m feature" "cannot be resolved"
run_gate "the attached short form -c<key>=<value> counts too" \
    block "git -cbranch.main.merge=refs/heads/feature pull origin" "cannot be resolved"

# An alias in a config FILE is nowhere in the command string — but the gate has
# the repo, so it resolves the names the parser did not recognize.
git -C "$REPO" config alias.m merge
# A configured alias that resolves to something harmless is refused anyway, in a
# repo that HAS a protected branch, on any branch. Two narrower placements were
# tried and both are unsound: trusting the resolution loses to an ambient
# GIT_CONFIG_KEY_n that overrides the file value, and scoping it to the protected
# branch loses to a shell alias whose own body switches branch. What the gate sees
# is a first word in the config IT can read — never the body, never the env.
git -C "$REPO" config alias.lg log
run_gate "a configured alias is refused on the protected branch" \
    block "git lg -1" "resolves to neither a git command nor a git alias"
git -C "$REPO" checkout -q feature
run_gate "...and off it too, because the alias body could switch back" \
    block "git lg -1" "resolves to neither a git command nor a git alias"
git -C "$REPO" checkout -q main
git -C "$REPO" config --unset alias.lg

run_gate "a config-file alias for merge is resolved and refused" \
    block "git m feature" "is a git alias reaching"
# Git splits an alias expansion on any whitespace, so the first WORD is what runs.
git -C "$REPO" config alias.t "$(printf 'merge\t--ff-only')"
run_gate "...and a tab-separated expansion is the same merge" \
    block "git t feature" "is a git alias reaching"
git -C "$REPO" config --unset alias.t
# Git expands an alias whose value names another alias, so the chain is followed.
# An expansion may carry git GLOBAL options before the subcommand.
git -C "$REPO" config alias.g "-c color.ui=false merge --ff-only"
run_gate "an expansion opening with a global option is unresolvable" \
    block "git g feature" "is a git alias reaching"
git -C "$REPO" config --unset alias.g
git -C "$REPO" config alias.a1 a2
git -C "$REPO" config alias.a2 "merge --ff-only"
run_gate "a chained alias still reaches merge" \
    block "git a1 feature" "is a git alias reaching"
git -C "$REPO" config --unset alias.a1
git -C "$REPO" config --unset alias.a2
# Git applies its own quote/backslash processing to an expansion, so these all
# run `merge` even though the raw first word is spelled otherwise.
git -C "$REPO" config alias.q "'merge' --ff-only"
run_gate "a quoted expansion still reaches merge" \
    block "git q feature" "is a git alias reaching"
git -C "$REPO" config alias.q 'm\e\r\g\e --ff-only'
run_gate "...and a backslash-spelled one" \
    block "git q feature" "is a git alias reaching"
git -C "$REPO" config alias.q "$(printf '\nmerge --ff-only')"
run_gate "...and one whose first word is on the next line" \
    block "git q feature" "is a git alias reaching"
git -C "$REPO" config --unset alias.q

# runuser/setpriv are not wrappers the shared parser walks, so a git command
# behind one produced NO operation at all — a fail-open, not an over-block.
run_gate "setpriv is not walked as a wrapper, so it is unresolvable" \
    block "setpriv --no-new-privs git merge feature" "cannot be resolved statically"
run_gate "...and runuser the same" \
    block "runuser -u alice -- git merge feature" "cannot be resolved statically"
# shellcheck disable=SC2016  # the literal $1 IS the alias body under test
git -C "$REPO" config alias.sh '!sh -c "git merge $1"'
run_gate "a !shell alias can never be cleared" \
    block "git sh feature" "is a git alias reaching"
git -C "$REPO" config --unset alias.m
git -C "$REPO" config --unset alias.sh
# With the alias gone the word resolves to nothing — and that is now a BLOCK, not
# an allow. The gate's environment is sanitized, so an alias set through
# GIT_CONFIG_KEY_n is stripped here and still live for the command; a word git
# itself would reject is the cheapest thing to refuse.
run_gate "...and with the alias gone the word resolves to nothing → block" \
    block "git m feature" "resolves to neither a git command nor a git alias"
# The alias-only companion refusal must not catch ordinary work: `commit` is a
# real git command, so nothing here can turn it into a merge.
run_gate "an ordinary git command beside another is not an alias risk" \
    allow "git status && git commit --allow-empty -m x"

# A long option may be abbreviated, so its value must still be recognized as a
# value rather than read as a second merge head.
run_gate "an abbreviated value option does not fake an octopus merge" \
    block "git merge --into reviewed-name feature" "would FAST-FORWARD the protected branch"
# HOME and XDG_CONFIG_HOME select which config files git reads.
run_gate "HOME selects the config that decides what a pull merges → block" \
    block "HOME=/tmp/attacker git pull origin" "cannot be resolved statically"
# git accepts the negated control forms, so they are last-wins, not one-way exits
# (verified against git 2.55.0).
run_gate "--abort cancelled by --no-abort is a real merge again → block" \
    block "git merge --abort --no-abort --ff-only feature" "would FAST-FORWARD the protected branch"

# Adjacent quotes are free to insert and the shell joins them back into `git`, so
# a raw-substring pre-filter never sees the command the shell runs.
run_gate "a quote-split command word does not slip past the pre-filter" \
    block "g''it merge feature" "would FAST-FORWARD the protected branch"

# _command_argv strips assignment prefixes to reach the command word, so a GIT_*
# env var redirecting the repo or the config was invisible to the whole gate.
run_gate "GIT_DIR/GIT_WORK_TREE redirect the repo → block" \
    block "GIT_DIR=/other/.git GIT_WORK_TREE=/other git merge feature" "cannot be resolved statically"
run_gate "GIT_CONFIG_* rewrites the config the pull path reads → block" \
    block "env GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=branch.main.merge git pull origin" "cannot be resolved statically"
run_gate "...set in an EARLIER segment, which still reaches the merge" \
    block "export GIT_DIR=/other/.git && git merge feature" "cannot be resolved statically"
run_gate "an alias defined through GIT_CONFIG_* hides the subcommand entirely" \
    block "GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=alias.m GIT_CONFIG_VALUE_0=merge git m feature" "cannot be resolved statically"
run_gate "a chdir-ing wrapper (env -C) moves the repo out from under the check" \
    block "env -C /other git merge feature" "cannot be resolved statically"
run_gate "...and its ATTACHED spelling, which env and sudo both accept" \
    block "env -C/other git merge feature" "cannot be resolved statically"
# difftool exists to run a configured external command, so it is a ref writer.
run_gate "difftool can run anything, so it counts" \
    block "git difftool --no-prompt && git merge feature" "SEPARATE call"
# The rule is the CLASS, not a list: even an obviously harmless companion counts,
# because telling them apart is what could never be completed.
run_gate "...and so does a harmless git status, deliberately" \
    block "git status && git merge feature" "SEPARATE call"
run_gate "...and a shell builtin that changes git's environment" \
    block "unset HOME && git pull origin main" "SEPARATE call"
run_gate "env -u strips config from the child inside ONE segment" \
    block "env -u HOME git pull origin main" "cannot be resolved statically"
run_gate "env -i wipes the environment git would read → block" \
    block "env -i git merge feature" "cannot be resolved statically"
# Running git as another user changes HOME, so the config, aliases and
# credentials it reads are not the ones the gate consulted. No option needed.
run_gate "sudo runs git with a different HOME → block" \
    block "sudo git merge feature" "cannot be resolved statically"
# The transport helper decides which objects a pull actually brings back.
run_gate "GIT_SSH_COMMAND redirects where the objects come from → block" \
    block "GIT_SSH_COMMAND=/tmp/fake-ssh git pull origin main" "cannot be resolved statically"
run_gate "...as does the transport's trust boundary" \
    block "GIT_SSL_NO_VERIFY=1 git pull origin main" "cannot be resolved statically"
# -r/--rebase takes an OPTIONAL attached value, so `-rfalse` is not a cluster
# ending in -s; reading it as one swallowed the remote operand.
run_gate "an optional-arg short option is not read as a cluster" \
    block "git pull -rfalse evil" "cannot be resolved statically"
# A git global that changes reachability semantics, not just the repo location.
run_gate "--no-replace-objects changes what the ancestry check means → block" \
    block "git --no-replace-objects merge feature" "cannot be resolved statically"
run_gate "...and its environment twin does the same" \
    block "GIT_NO_REPLACE_OBJECTS=1 git merge feature" "cannot be resolved statically"

# Git abbreviates the STATE options too, so an exact-match test left the earlier
# flag latched and reported these ordinary merges out of scope entirely.
run_gate "--squash cancelled by the abbreviated --no-sq → block" \
    block "git merge --squash --no-sq feature" "would FAST-FORWARD the protected branch"
run_gate "--no-ff overridden by the abbreviated --ff-o → block" \
    block "git merge --no-ff --ff-o feature" "would FAST-FORWARD the protected branch"
run_gate "--abort cancelled by the abbreviated --no-ab → block" \
    block "git merge --abort --no-ab feature" "would FAST-FORWARD the protected branch"

# No literal merge/pull at gate time: the command creates the alias and then uses
# it, so the alias lookup finds nothing. The companion is what gives it away.
run_gate "a command that DEFINES the alias it then merges through → block" \
    block "git config alias.m merge && git m feature" "neither a git command nor a git alias"
# ...and REWRITING a harmless existing alias is the same move: its current value
# proves nothing when the companion can change it first.
git -C "$REPO" config alias.m status
run_gate "a command that REWRITES an existing alias → block" \
    block "git config alias.m merge && git m feature" "neither a git command nor a git alias"
git -C "$REPO" config --unset alias.m

# A ref writer the allowlist never named. The test is the INVERSION — anything
# outside the read-only set counts — not this one subcommand.
run_gate "a ref writer outside any allowlist (fast-import) still counts" \
    block "git fast-import </dev/null && git merge feature" "SEPARATE call"

# A pull with --squash/--no-ff still FETCHES, so it must stay an operation:
# dropping it let the pull replace the value the following merge was cleared for.
run_gate "a --squash pull still counts as an operation" \
    block "git pull --squash origin feature && git merge origin/feature" "separate git merge/pull operations"

# An unrecognized separate-value option leaves its VALUE among the operands and
# fakes an octopus merge — which the gate used to exit on.
run_gate "an option value masquerading as a second head → block, not allow" \
    block "git merge --cleanup=strip --unknown-opt strip feature" "do not both resolve to commits"
run_gate "...and three-plus operands are refused rather than guessed at" \
    block "git merge a b c" "reads at most two"

# Past `--`, a ref may legitimately be spelled like an option.
# ...so it reaches the gate as a TARGET. It still blocks — a ref spelled like an
# option is one the gate cannot resolve — but as an unresolvable target rather
# than by being read as --no-ff and dismissed as out of scope.
run_gate "a ref named --no-ff after -- is a target, not an option" \
    block "git merge -- --no-ff" "merge target cannot be resolved statically"

# refs/remotes/origin/HEAD is an ordinary local ref. Re-pointing it must not be
# able to REMOVE main from what the gate protects.
git -C "$REPO" remote set-head origin feature >/dev/null 2>&1
run_gate "re-pointing origin/HEAD cannot un-protect main" \
    block "git merge feature" "would FAST-FORWARD the protected branch"
git -C "$REPO" remote set-head origin main >/dev/null 2>&1

# A diverged protected branch is refused like every other pull — but the fixture
# stays, because the shape checks BEFORE the refusal must survive it.
setup_repo diverged || { printf '  FAIL  fixture setup (diverged)\n'; exit 1; }
git -C "$REPO" commit -q --allow-empty -m "local-only commit on main"
run_gate "a diverged protected branch is refused like any other pull" \
    block "git pull --ff-only origin main" "does not exist locally yet"

# `git pull <remote>` takes its branch from branch.<protected>.merge — one of the
# repo-controlled inputs that made source-based authorization unworkable.
git -C "$REPO" config branch.main.merge refs/heads/feature
run_gate "pull <remote> with branch.main.merge pointing elsewhere → block" \
    block "git pull origin" "does not exist locally yet"
run_gate "...and the refspec-less pull is refused on the same grounds" \
    block "git pull" "does not exist locally yet"
git -C "$REPO" config branch.main.merge refs/heads/main
setup_repo main || { printf '  FAIL  fixture re-setup (diverged)\n'; exit 1; }

# ── The ordinary operations that must keep working ───────────────────
# A pull still has to PARSE correctly even though every pull is refused: the
# operand reading is what tells a pull from a merge, and from an unresolvable
# command. These assert the refusal is the deliberate one, not a parse failure.
run_gate "pull --ff-only <remote> is refused, and for the pull reason" \
    block "git pull --ff-only origin" "does not exist locally yet"
run_gate "pull --ff-only <remote> <branch> likewise" \
    block "git pull --ff-only origin main" "does not exist locally yet"
# --filter takes a separate value; unrecognized, it displaced the real operands.
run_gate "a separate-value pull option does not displace the operands" \
    block "git pull --ff-only --filter blob:none origin main" "does not exist locally yet"
run_gate "...nor does the long form of -m, which the first list omitted" \
    block "git merge --message hello feature" "would FAST-FORWARD the protected branch"
run_gate "bare pull --ff-only, upstream is origin/main" \
    block "git pull --ff-only" "does not exist locally yet"
# A merge from the remote-tracking ref is no longer a route: that voucher is a
# local ref any colon-refspec fetch can plant. The ordinary update is the pull.
run_gate "merge origin/main is NOT a route — the pull arm is" \
    block "git merge origin/main" "would FAST-FORWARD the protected branch"
# Ancestry says a fast-forward is possible; config decides whether git takes it.
git -C "$REPO" config merge.ff false
run_gate "merge.ff=false does not need a config read to be refused" \
    block "git merge origin/main" "would FAST-FORWARD the protected branch"
git -C "$REPO" config --unset merge.ff
# Git's boolean parser is case-insensitive; --type=bool is what makes the gate
# see the same value git does.
git -C "$REPO" config merge.ff FALSE
run_gate "...in any case git accepts" \
    block "git merge origin/main" "would FAST-FORWARD the protected branch"
git -C "$REPO" config --unset merge.ff
git -C "$REPO" config branch.main.mergeOptions --no-ff
run_gate "...as does branch.<protected>.mergeOptions" \
    block "git merge origin/main" "would FAST-FORWARD the protected branch"
git -C "$REPO" config --unset branch.main.mergeOptions
run_gate "...and naming its oid instead does not change that" \
    block "git merge $ORIGIN_MAIN_OID" "would FAST-FORWARD the protected branch"
# Git builds a merge COMMIT for an annotated tag even when the ancestry would
# allow a fast-forward, so the ancestry answer does not describe what git does.
git -C "$REPO" tag -a -m reviewed reviewed-tag "$ORIGIN_MAIN_OID"
run_gate "an annotated tag is not the fast-forward shape the gate evaluates" \
    block "git merge reviewed-tag" "is an ANNOTATED TAG"
git -C "$REPO" tag -d reviewed-tag >/dev/null 2>&1
# Bare `git merge` takes merge.defaultToUpstream, i.e. @{upstream} = origin/main
# here — its own code path, and the one an operand-shaped test would never reach.
run_gate "a bare merge resolves @{upstream}, and that is still a block" \
    block "git merge" "would FAST-FORWARD the protected branch"
run_gate "git commit is another gate's business" \
    allow "git commit -m x"
# Read-only git commands are not ref writers — the inverted test must not turn
# every inspect-then-merge command into a refusal.
# The scope-env refusal is paired with a merge/pull CANDIDATE on purpose, so
# inspecting another repo is untouched.
run_gate "GIT_DIR on a read-only command is not this gate's business" \
    allow "GIT_DIR=/other/.git git log"
# An OPERAND that merely looks like an assignment is a ref, not an environment
# change — matching it as one blocked a legitimately-named branch outright.
run_gate "a ref named like an assignment is a ref" \
    block "git merge PATH=reviewed" "cannot resolve the merge target"
# A PREFIX assignment binds one command; only the persisting forms reach a later
# merge. Reading both whole-command made HOME (which git merge never sees) the
# stated reason for the block.
run_gate "a prefix assignment on another command is not the merge's scope" \
    block "HOME=/tmp git status && git merge origin/main" "SEPARATE call"
run_gate "...while an exported one does reach it" \
    block "export GIT_DIR=/other/.git && git merge feature" "cannot be resolved statically"
run_gate "a nested wrapper does not hide the assignment prefix" \
    block "command env GIT_DIR=/other/.git git merge feature" "cannot be resolved statically"
run_gate "command -p resolves git through a different PATH → block" \
    block "command -p git merge feature" "cannot be resolved statically"
# GNU env abbreviates its long options, so an exact-token test never finished.
run_gate "an abbreviated wrapper option is unaccounted for, not absent" \
    block "env --chd=/other git merge feature" "cannot be resolved statically"
run_gate "...in its flag form too" \
    block "env --igno git merge feature" "cannot be resolved statically"
# A wrapper with no options changes nothing and must stay resolvable.
run_gate "a bare wrapper is not by itself a scope change" \
    block "command git merge origin/main" "would FAST-FORWARD the protected branch"
# ...but env's operands AFTER the utility belong to the utility, so a ref named
# like an assignment survives being wrapped.
run_gate "a ref named like an assignment survives an env wrapper" \
    block "env git merge PATH=reviewed" "cannot resolve the merge target"
# Alias candidates carry no scope, so a scoped command cannot be resolved against
# one repository — a repo-local alias.m would be invisible.
run_gate "an alias candidate in a cd-scoped command is unresolvable" \
    block "cd /other && git m feature" "cannot be resolved"
# CDPATH changes where a RELATIVE cd lands, and the cd is what scopes the gate.
run_gate "CDPATH on the scoping cd is not an exempt cd" \
    block "CDPATH=/other cd repo && git merge topic" "cd target cannot be resolved statically"
# Git ignores an alias that shadows a built-in, so one must not block the built-in.
git -C "$REPO" config alias.commit merge
run_gate "an alias shadowing a built-in is inert, and must not block it" \
    allow "git commit --allow-empty -m x"
git -C "$REPO" config --unset alias.commit
run_gate "prose mentioning git merge, piped to another tool" \
    allow "echo 'git merge feature' > /dev/null"
# Shell syntax is not a merge head. Reading it as one made the operand-count and
# ref-resolution checks reject ordinary, valid merges.
run_gate "a redirected merge is still a one-head merge" \
    block "git merge feature >/dev/null" "would FAST-FORWARD the protected branch"
run_gate "...and 2>&1, whose split debris is not a companion command" \
    block "git merge feature 2>&1" "would FAST-FORWARD the protected branch"
run_gate "...and a trailing comment is not an operand" \
    block "git merge feature # take the feature branch" "would FAST-FORWARD the protected branch"
run_gate "a redirected merge is read as a merge, not as unparseable" \
    block "git merge origin/main >/dev/null" "would FAST-FORWARD the protected branch"
# ...but a QUOTED ref that merely looks like shell syntax is a real ref. Dropping
# it left no operand at all, which sent the gate to resolve @{upstream} instead
# of the ref git would actually merge.
run_gate "a quoted ref named like a comment is still a ref" \
    block "git merge '#topic'" "cannot resolve the merge target"
run_gate "...and one named like a redirection" \
    block "git merge '>topic'" "cannot resolve the merge target"

# -j/--jobs takes an ATTACHED value, so it consumes nothing: reading `4` as its
# value made the gate validate origin while git pulled from a remote named 4.
run_gate "--jobs does not swallow the remote operand" \
    block "git pull --jobs 4 origin" "does not exist locally yet"
# Git reads a short-option cluster as its letters, so `-vm reviewed` is
# `-v -m reviewed` — a message, not a head — and git merges @{upstream}. Reading
# `reviewed` as the head made the gate validate a ref git was not going to merge;
# now it resolves the upstream, which here is origin/main — still not a route.
# The assertion is that the two AGREE, not that it blocks.
run_gate "a clustered -vm is a message, so the gate resolves @{upstream}" \
    block "git merge -vm reviewed" "would FAST-FORWARD the protected branch"
# Two readings of the same string that disagree about the merge target. Neither
# is assumed: `-Sm reviewed` is `-S` keyed `m` leaving `reviewed` as the head, or
# `-S -m reviewed` leaving none — and the shell strips a redirection before git
# sees it, so `-m >/dev/null x` gives git `-m x`, not `-m >/dev/null`.
run_gate "an optional-attached-arg cluster is unresolvable, not guessed" \
    block "git merge -Sm reviewed" "cannot be resolved statically"
run_gate "a redirection between an option and its value is unresolvable" \
    block "git merge -m >/dev/null reviewed" "cannot be resolved statically"

# ── Out of scope by decision: forms that are not a fast-forward ──────
run_gate "merge --abort starts no merge" allow "git merge --abort"
run_gate "merge --continue resumes one rather than starting a new one" \
    allow "git merge --continue"
run_gate "HOME on a read-only command is not this gate's business" \
    allow "HOME=/tmp/x git log"
run_gate "merge --squash moves no ref (pre-commit-gate owns the commit)" \
    allow "git merge --squash feature"
run_gate "merge --no-ff makes a COMMIT — #622/#782's class, not this gate's" \
    allow "git merge --no-ff feature"
# Unrecognized long options must not cancel correctly-read state: these are still
# a squash and a forced merge commit, neither of which is a fast-forward.
run_gate "an unrelated long option does not cancel --squash" \
    allow "git merge --squash --no-commit feature"
run_gate "...nor does an attached-value option cancel --no-ff" \
    allow "git merge --no-ff --strategy=ours feature"
run_gate "a genuine octopus merge is always a merge commit, never an FF" \
    allow "git merge feature origin/main"
# ...but git REDUCES the head list first, so a pair that collapses to one head
# can still fast-forward and must not take the octopus exit.
run_gate "two heads that reduce to one can still fast-forward → block" \
    block "git merge HEAD feature" "git reduces the list"
run_gate "...as does a repeated head" \
    block "git merge feature feature" "git reduces the list"

# ── Direction: the gate keys on HEAD's branch, not on the operand ────
git -C "$REPO" checkout -q feature
run_gate "merge main FROM a feature branch — no protected ref moves" \
    allow "git merge main"
run_gate "merge of unreviewed content onto a feature branch is ordinary work" \
    allow "git merge origin/main"
# The ref-writer refusal is scoped to the protected branch on purpose — this is
# the everyday shape it must not break.
# A companion is refused on EVERY branch, not just the protected one: the branch
# the gate reads is a pre-command value, and a companion can change it.
run_gate "a companion is refused off the protected branch too" \
    block "git fetch origin main && git merge origin/main" \
    "runs something else ALONGSIDE a merge/pull"
run_gate "...because the companion can switch ONTO the protected branch" \
    block "git switch main && git merge feature" \
    "runs something else ALONGSIDE a merge/pull"
# The same shape with NO literal merge/pull. There is nothing for the companion
# refusal to match, the alias does not exist when the gate looks, and the
# branch-scoped word check sees the FEATURE branch — so this reached the no-op
# exit and then created the alias, switched, and fast-forwarded main.
run_gate "...and with no literal merge at all, via an alias defined en route" \
    block "git config alias.m merge && git switch main && git m feature" \
    "resolves to neither a git command nor a git alias"
git -C "$REPO" checkout -q --detach
run_gate "detached HEAD moves no branch ref" allow "git merge feature"
git -C "$REPO" checkout -q main

# ── Discovery cannot outrun the hook budget ──────────────────────────
# One `git symbolic-ref` per remote, inside a 10s budget whose expiry emits no
# decision — so an unbounded walk is a way THROUGH the gate. Remotes are
# repo-controlled and free to add.
setup_repo manyremotes || { printf '  FAIL  fixture setup (manyremotes)\n'; exit 1; }
for _i in $(seq 1 70); do
    git -C "$REPO" remote add "r$_i" "$ORIGIN" >/dev/null 2>&1
done
run_gate "a repo with more remotes than the budget allows is refused" \
    block "git merge feature" "past the 64 this gate can examine"
setup_repo main || { printf '  FAIL  fixture re-setup (manyremotes)\n'; exit 1; }

# A repo with no state dir at all has no declaration and no marker — absent, not
# unsafe. Folding the two together refused every merge in an ordinary checkout.
mv "$REPO/$ISO_STATE" "$TMPROOT/state-aside"
run_gate "a repo with no state dir is not treated as unsafe" \
    block "git merge feature" "would FAST-FORWARD the protected branch"
mv "$TMPROOT/state-aside" "$REPO/$ISO_STATE"

# ── A word from the command is never expanded against the working tree ──
# The parser hands back space-separated names, which the gate iterates unquoted.
# With globbing on, `git m*` in a directory containing a file called `merge`
# became the candidate `m*` and then expanded to `merge` — a name the command
# never used, compared against the list of real git commands, and passed.
: > "$REPO/merge"
run_gate "an alias candidate is not glob-expanded against the repo" \
    block "git m* --ff-only feature" "resolves to neither a git command nor a git alias"
rm -f "$REPO/merge"

# ── An oversized payload is refused, not parsed ──────────────────────
# The hook budget is 10s and its expiry emits no decision, so a payload that
# outruns the parser goes THROUGH the gate. The bound has to fire before python.
_big=$(python3 -c '
import json, sys
print(json.dumps({"tool_name": "Bash", "cwd": sys.argv[1],
                  "tool_input": {"command": "git merge feature #" + "x" * 70000}}))' "$REPO")
_out=$(printf '%s' "$_big" | bash "$GATE_SCRIPT" 2>/dev/null || true)
_rc=0; grep -q 'past the 64 KiB' <<<"$_out" || _rc=1
assert_true "an oversized payload is refused before it can outrun the budget" "$_rc"

# ── A parser that never answered is not an answer ────────────────────
# The gate reads a 12-line frame from the shared detector. Nothing the Python
# handler can catch is the problem — it emits its own `error` frame. The problem
# is what it CANNOT catch (no interpreter, an import failure, the process killed),
# which used to leave the frame empty, and empty read exactly like a genuine "no
# merge in this command". Stub python3 to fail silently and require a BLOCK.
mkdir -p "$TMPROOT/stubbin"
printf '#!/bin/sh\nexit 1\n' > "$TMPROOT/stubbin/python3"
chmod +x "$TMPROOT/stubbin/python3"
_payload=$(python3 -c '
import json, sys
print(json.dumps({"tool_name": "Bash", "cwd": sys.argv[1],
                  "tool_input": {"command": "git merge feature"}}))' "$REPO")
_out=$(printf '%s' "$_payload" | PATH="$TMPROOT/stubbin:$PATH" bash "$GATE_SCRIPT" 2>/dev/null || true)
_rc=0; grep -q '"block"' <<<"$_out" || _rc=1
assert_true "a parser that dies without a frame blocks, it does not pass" "$_rc"
rm -rf "$TMPROOT/stubbin"

# ── Fail-CLOSED on anything the gate cannot resolve ──────────────────
# shellcheck disable=SC2016  # the literal $(...) IS the input under test
run_gate "substitution operand → cannot resolve the target → block" \
    block 'git merge $(cat /tmp/ref)' "an operand of this git merge/pull cannot be resolved"
run_gate "unknown ref → cannot resolve the target → block" \
    block "git merge no-such-branch-anywhere" "cannot resolve the merge target"
# shellcheck disable=SC2016  # the literal $(...) IS the input under test
run_gate "torn assignment hides the scope → block" \
    block 'X=$(printf git x) git merge feature'
run_gate "unproven cd to another repo → cannot tell which repo → block" \
    block "cd /some/other/repo; git merge feature" "cd target cannot be resolved statically"

# ── The oid-bound marker: the authorization form #779 asks for ───────
# The marker path requires an operand git resolves to ITSELF, so the merge names
# the oid. A symbolic ref would be re-resolved when the command runs, leaving the
# authorization bound to the gate's observation rather than the ref move.
write_marker "PASS-FF refs/heads/main $FEATURE_OID"
run_gate "a marker without --ff-only does not authorize the merge" \
    block "git merge $FEATURE_OID" "does not carry --ff-only"
run_gate "exact PASS-FF <ref> <oid> marker authorizes the fast-forward" \
    allow "git merge --ff-only $FEATURE_OID"
_rc=0; [ ! -f "$REPO/$ISO_STATE/ref-ff-authorized.local" ] || _rc=1
assert_true "...and the marker is CONSUMED (single use)" "$_rc"
_rc=0; grep -q '"event":"ref-ff-authorized"' "$REPO/$ISO_STATE/bypass-log.jsonl" 2>/dev/null || _rc=1
assert_true "...and the authorization is recorded in the gate audit log" "$_rc"
# The record must be PARSEABLE, not merely present: a ref name may legally contain
# a double quote, and building the line by string interpolation produced JSON the
# appender stored verbatim (it checks durable bytes, not syntax).
_rc=0; python3 -c '
import json, sys
for line in open(sys.argv[1]):
    line = line.strip()
    if line:
        json.loads(line)' "$REPO/$ISO_STATE/bypass-log.jsonl" 2>/dev/null || _rc=1
assert_true "...as a well-formed JSONL record" "$_rc"

# The block message is text an operator PASTES, and git accepts a branch name
# containing single quotes, semicolons and dollar signs. Interpolated raw, such a
# name closed the quoted string in the suggested command and appended its own.
# NO SPACES in the name — git rejects those, and an earlier version of this test
# used one, so the branch was never created and the assertion passed vacuously.
# Hence the explicit creation check below: a fixture that failed to build must
# fail the test, not silently satisfy it.
# shellcheck disable=SC2016  # the literal ${IFS} IS the payload under test
_HOSTILE='x'"'"';touch${IFS}/tmp/ref-ff-pwn;#'
_rc=0; git -C "$REPO" checkout -q -b "$_HOSTILE" 2>/dev/null || _rc=1
assert_true "the hostile-name fixture is a real branch (not a vacuous test)" "$_rc"
printf '%s\n' "$_HOSTILE" > "$REPO/$ISO_STATE/ref-ff-protected.local"
_payload=$(python3 -c '
import json, sys
print(json.dumps({"tool_name": "Bash", "cwd": sys.argv[1],
                  "tool_input": {"command": "git merge --ff-only " + sys.argv[2]}}))' \
    "$REPO" "$FEATURE_OID")
_out=$(printf '%s' "$_payload" | bash "$GATE_SCRIPT" 2>/dev/null || true)
# Raw interpolation produced exactly this byte sequence; printf %q cannot.
_rc=0; grep -qF "PASS-FF refs/heads/$_HOSTILE" <<<"$_out" && _rc=1
assert_true "a hostile branch name is shell-quoted in the block message" "$_rc"
rm -f "$REPO/$ISO_STATE/ref-ff-protected.local" /tmp/ref-ff-pwn
git -C "$REPO" checkout -q main
git -C "$REPO" branch -D "$_HOSTILE" >/dev/null 2>&1

write_marker "PASS-FF refs/heads/main $ORIGIN_MAIN_OID"
run_gate "a marker for a DIFFERENT oid does not authorize this one" \
    block "git merge --ff-only $FEATURE_OID" "would FAST-FORWARD the protected branch"
run_gate "...and a marker cannot authorize a SYMBOLIC operand at all" \
    block "git merge feature" "a symbolic ref that git resolves again"

write_marker "PASS-FF refs/heads/release $FEATURE_OID"
run_gate "a marker naming a different REF does not authorize this branch" \
    block "git merge --ff-only $FEATURE_OID"

write_marker "$(printf 'PASS-FF refs/heads/main %s\nrm -rf /' "$FEATURE_OID")"
run_gate "a well-formed first line with trailing garbage is NOT honoured" \
    block "git merge --ff-only $FEATURE_OID"

write_marker "PASS-MERGE-1754400000"
run_gate "the old PASS-MERGE token cannot authorize a fast-forward" \
    block "git merge --ff-only $FEATURE_OID"

printf '%s\n' "PASS-FF refs/heads/main $FEATURE_OID" > "$REPO/$ISO_STATE/ref-ff-authorized.local"
run_gate "a marker created moments ago is refused (anti-self-bypass)" \
    block "git merge --ff-only $FEATURE_OID" "was created moments ago"
rm -f "$REPO/$ISO_STATE/ref-ff-authorized.local"

# ── No remote-tracking ref: the pull arm CANNOT hold, so the marker is the
#    only way through. Keying an allow on the repo's shape would be a
#    fail-OPEN reachable by deleting a remote. ─────────────────────────
setup_repo noremote || { printf '  FAIL  fixture setup (noremote)\n'; exit 1; }
git -C "$REPO" remote remove origin >/dev/null 2>&1
git -C "$REPO" update-ref -d refs/remotes/origin/main >/dev/null 2>&1
git -C "$REPO" update-ref -d refs/remotes/origin/HEAD >/dev/null 2>&1
run_gate "with no remote-tracking ref, a fast-forward onto main still blocks" \
    block "git merge feature" "would FAST-FORWARD the protected branch"

# ── A default branch that is not main/master, on a remote that is not
#    origin. An empty protected set disabled the gate outright — a fail-OPEN
#    on exactly the branch it exists to guard. ─────────────────────────
setup_repo trunkish || { printf '  FAIL  fixture setup (trunkish)\n'; exit 1; }
git -C "$REPO" branch -m main trunk
# A remote may legally contain a slash, so the HEAD short name must have the
# REMOTE'S name stripped, not just its first path component.
git -C "$REPO" remote rename origin team/upstream >/dev/null 2>&1
run_gate "a 'trunk' default on a slash-named remote is still protected" \
    block "git merge feature" "would FAST-FORWARD the protected branch"
# A name the gate cannot infer at all is named by the operator instead.
git -C "$REPO" branch -m trunk release
printf 'release\n' > "$REPO/$ISO_STATE/ref-ff-protected.local"
run_gate "an operator-declared protected branch is guarded too" \
    block "git merge feature" "would FAST-FORWARD the protected branch"
# A CRLF file must declare `release`, not `release<CR>`.
printf 'release\r\n' > "$REPO/$ISO_STATE/ref-ff-protected.local"
run_gate "...and a CRLF declaration still names the branch" \
    block "git merge feature" "would FAST-FORWARD the protected branch"
# A last line with NO trailing newline: `read` returns non-zero on it, so the
# loop used to drop it. When it is the only declaration the set came out empty
# and the gate exited 0 on the branch the file exists to protect.
printf 'release' > "$REPO/$ISO_STATE/ref-ff-protected.local"
run_gate "...and a declaration with no trailing newline still counts" \
    block "git merge feature" "would FAST-FORWARD the protected branch"
# With no declaration AND nothing discoverable, the gate cannot tell what is
# protected — which is the failure case, not the happy path. This used to exit 0,
# and it was the lever every mutable-discovery finding pulled: delete the remote
# HEAD the default was found through and the set empties.
rm -f "$REPO/$ISO_STATE/ref-ff-protected.local"
run_gate "...and with the declaration gone, an unidentifiable repo BLOCKS" \
    block "git merge feature" "cannot identify a protected branch"
# An EMPTY declaration is the operator saying there is none — a statement the
# absence of the file does not make.
: > "$REPO/$ISO_STATE/ref-ff-protected.local"
run_gate "...while an empty declaration says so deliberately, and allows" \
    allow "git merge feature"
# ...and with nothing to protect, the shape refusals have nothing to refuse FOR.
# They existed only because a companion could reach a protected branch.
git -C "$REPO" config alias.m status
run_gate "...and the companion/alias refusals do not fire with none declared" \
    allow "git status && git m"
git -C "$REPO" config --unset alias.m
# `#` starts a valid git branch name, so it cannot mean "comment" — a declaration
# of `#release` names a branch and must be honoured as one.
git -C "$REPO" branch '#release' >/dev/null 2>&1
printf '#release\n' > "$REPO/$ISO_STATE/ref-ff-protected.local"
git -C "$REPO" checkout -q '#release'
run_gate "a branch whose name starts with # is declarable, not a comment" \
    block "git merge feature" "would FAST-FORWARD the protected branch"
git -C "$REPO" checkout -q main
git -C "$REPO" branch -D '#release' >/dev/null 2>&1

# An oversized declaration is REFUSED, not truncated. A single fixed-size read
# turned 64 KiB of blank lines followed by a real declaration into a file naming
# no branch — which is how an operator says the repo has none, so the file
# disabled the gate instead of being rejected by it.
{ head -c 65536 /dev/zero | tr '\0' '\n'; printf 'release\n'; } \
    > "$REPO/$ISO_STATE/ref-ff-protected.local"
run_gate "an oversized declaration is refused, never silently truncated" \
    block "git merge feature" "could not be read safely"
rm -f "$REPO/$ISO_STATE/ref-ff-protected.local"

# A symlink ANYWHERE in the path, not only at the leaf: a plain file test resolves
# every component, so a symlinked state dir made the test describe one file while
# the read took another.
mkdir -p "$TMPROOT/elsewhere"
: > "$TMPROOT/elsewhere/ref-ff-protected.local"
mv "$REPO/$ISO_STATE" "$REPO/$ISO_STATE.real"
ln -s "$TMPROOT/elsewhere" "$REPO/$ISO_STATE"
run_gate "a symlinked state dir is not followed to find the declaration" \
    block "git merge feature" "could not be read safely"
rm -f "$REPO/$ISO_STATE"
mv "$REPO/$ISO_STATE.real" "$REPO/$ISO_STATE"

# The declaration decides what the gate guards, and a file naming NO branch turns
# it off — so a repository that could commit one could disable its own gate.
# Consent is authenticated by LOCATION here, exactly as the marker is.
: > "$REPO/$ISO_STATE/ref-ff-protected.local"
git -C "$REPO" add -f "$ISO_STATE/ref-ff-protected.local" >/dev/null 2>&1
run_gate "a repo-controlled declaration cannot switch the gate off" \
    block "git merge feature" "is repo-controlled"
git -C "$REPO" rm -q --cached "$ISO_STATE/ref-ff-protected.local" >/dev/null 2>&1

# A file that NAMES a branch which does not exist is a typo, not that statement.
# Unvalidated, it made the set non-empty and guarded nothing.
printf 'releaze\n' > "$REPO/$ISO_STATE/ref-ff-protected.local"
run_gate "...but a declaration naming no existing branch is a typo → block" \
    block "git merge feature" "no such branch exists"
rm -f "$REPO/$ISO_STATE/ref-ff-protected.local"
setup_repo main || { printf '  FAIL  fixture re-setup\n'; exit 1; }

# ── Repo scoping: the marker is bound to a repo by its LOCATION ──────
setup_repo other || { printf '  FAIL  fixture setup (other)\n'; exit 1; }
OTHER_REPO="$REPO"
setup_repo main2 || { printf '  FAIL  fixture setup (main2)\n'; exit 1; }
write_marker "PASS-FF refs/heads/main $FEATURE_OID"
MARKER_HOLDER="$REPO"
REPO="$OTHER_REPO"
run_gate "a marker in ANOTHER repo does not authorize this one" \
    block "git merge --ff-only $FEATURE_OID"
rm -f "$MARKER_HOLDER/$ISO_STATE/ref-ff-authorized.local"

printf '\nRESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
