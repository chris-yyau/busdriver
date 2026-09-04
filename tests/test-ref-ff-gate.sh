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

# SC2310 warns that a function called in an `||` condition has `set -e`
# suppressed for it. This suite never enables `set -e` (see below - `-uo
# pipefail` only), so the warning's premise does not hold anywhere in the file,
# and the `|| { ...; exit 1; }` fixture idiom it fires on IS the explicit
# handling it asks for. Scoped to this file, and to that one check.
# shellcheck disable=SC2310

set -uo pipefail
cd "$(dirname "$0")/.."
REPO_ROOT="$(pwd)"
GATE_SCRIPT="$REPO_ROOT/hooks/gate-scripts/ref-ff-gate.sh"
_REAL_HOME="$HOME"

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
        # HERMETIC: the operator's global config may sign commits and tags
        # with an SSH key. Signing prompts for a passphrase, which fails in a
        # non-interactive run, and the fixture then builds an empty repo whose
        # every later assertion is meaningless. Nothing here is testing signing.
        git config commit.gpgsign false; git config tag.gpgsign false
        echo base > f; git add f; git commit -qm base
        # One more commit on origin/main — the "already landed through the gated
        # PR pipeline" content the pull arm must let through.
        echo landed >> f; git add f; git commit -qm landed

        git clone -q "$ORIGIN" "$REPO"
        cd "$REPO"
        git config user.email t@t; git config user.name t
        # HERMETIC: the operator's global config may sign commits and tags
        # with an SSH key. Signing prompts for a passphrase, which fails in a
        # non-interactive run, and the fixture then builds an empty repo whose
        # every later assertion is meaningless. Nothing here is testing signing.
        git config commit.gpgsign false; git config tag.gpgsign false
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
    # The gate is normally driven from the suite's own directory, which is where
    # it already runs. $GATE_CWD exists for the one case that is ABOUT the
    # process's working directory - in real use the hook runs inside the repo
    # being merged in, and that directory is content this merge controls.
    # $GATE_BASH exists for the one case that is ABOUT the interpreter: the hook
    # registration names /bin/bash, while everything else here uses whatever
    # `bash` PATH resolves to.
    output=$(cd "${GATE_CWD:-$REPO_ROOT}" && printf '%s' "$payload" | "${GATE_BASH:-bash}" "$GATE_SCRIPT" 2>/dev/null) && exit_code=0 || exit_code=$?
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
# Ask the remote for its published HEAD explicitly rather than relying on fetch
# to write it: `fetch` only began creating refs/remotes/<name>/HEAD in git 2.46,
# and this repository declares no git minimum, so an older git would fail this
# measurement rather than make it. `set-head --auto` queries the same published
# HEAD on every version, which is the thing being measured.
git -C "$REPO" remote set-head fork --auto >/dev/null 2>&1
_head=$(git -C "$REPO" symbolic-ref --short refs/remotes/fork/HEAD 2>/dev/null || true)
_rc=0; [[ "$_head" == "fork/main" ]] || _rc=1
assert_true "a fork publishes the same HEAD as origin (it declares main too)" "$_rc"
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
# A ref may be spelled like the fast-forward METADATA the emitter appends to the
# same operand list, and after `--` git accepts it. Sharing that namespace let the
# only operand be stripped as metadata and read as a bare merge of @{upstream}.
run_gate "a ref spelled like the ff-mode sentinel is unresolvable" \
    block "git merge -- -ff-mode=--ff-only" "cannot be resolved"
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
# An option this parser could not read may be the one that decides the shape, so
# the out-of-scope exit must not swallow it: `MODE=--ff-only` is applied LAST by
# git, turning a merge-commit shape back into a fast-forward.
# shellcheck disable=SC2016  # the literal $MODE IS the input under test
run_gate "an unreadable option beside --no-ff does not settle the shape" \
    block 'git merge --no-ff $MODE feature' "cannot be resolved"
# A skipped option VALUE that may expand is not one word: `MSG='note B'` makes
# git see two heads, reduce them, and fast-forward somewhere the marker never
# named.
# shellcheck disable=SC2016  # the literal $MSG IS the input under test
run_gate "a value that may expand poisons the operand list" \
    block 'git merge --ff-only --message $MSG feature' "cannot be resolved"
# ...in the ATTACHED spelling too, and through brace expansion, which carries no
# substitution character at all.
# shellcheck disable=SC2016  # the literal $MSG IS the input under test
run_gate "...and its attached spelling" \
    block 'git merge --ff-only --message=$MSG feature' "cannot be resolved"
run_gate "...and a brace expansion, which has no \$ to notice" \
    block 'git merge --ff-only --message {note,B} feature' "cannot be resolved"
run_gate "...and its SEQUENCE form, which the comma pattern missed" \
    block 'git merge --ff-only --message {A..B} feature' "cannot be resolved"
run_gate "...and pathname expansion, illegal in a ref name anyway" \
    block 'git merge --ff-only --message * feature' "cannot be resolved"
# An ORDINARY operand can brace-expand into OPTIONS, so the out-of-scope exit
# must not trust the shape it read either.
run_gate "an operand that may expand into options is unresolvable" \
    block 'git merge --no-ff {--ff-only,--no-edit} feature' "cannot be resolved"
# ...and a PARTIALLY quoted word is not a quoted one: bash still expands the bare
# braces in front of the empty quotes.
run_gate "a partially quoted brace word still expands" \
    block 'git merge --no-ff {--ff-only,--no-edit}"" feature' "cannot be resolved"
# With extglob on, @(...) expands to a matching pathname, so the word can BECOME
# an option the parser never saw.
run_gate "an extglob word is unresolvable too" \
    block 'git merge --no-ff @(--ff-only) feature' "cannot be resolved"
# ...while a value bash will NOT expand is one word, and an out-of-scope --no-ff
# merge stays out of scope. Quoting and escaping both count, and neither
# "raw == token" nor "wholly quoted" gets all three of these right.
# shellcheck disable=SC2016  # the literal $MSG IS the input under test
run_gate "a double-quoted substitution value does not split" \
    allow 'git merge --no-ff --message="$MSG" feature'
run_gate "...nor does a quoted glob" \
    allow 'git merge --no-ff --message "*" feature'
run_gate "...nor an escaped one" \
    allow 'git merge --no-ff --message \* feature'
# shellcheck disable=SC2016  # the literal $'note' IS the input under test
run_gate "...nor ANSI-C quoting, whose \$ opens a quote rather than a value" \
    allow "git merge --no-ff --message \$'note' feature"
# The exception to "quoted means one word": "\$@" and "\${arr[@]}" expand to as
# many words as there are elements, so a value that LOOKS safely quoted still
# adds merge heads.
# shellcheck disable=SC2016  # the literal "$@" IS the input under test
run_gate 'a "$@" value splits despite the quotes' \
    block 'git merge --no-ff --message "$@" feature' "cannot be resolved"
# shellcheck disable=SC2016  # the literal "${arr[@]}" IS the input under test
run_gate '...as does "${arr[@]}"' \
    block 'git merge --no-ff --message "${arr[@]}" feature' "cannot be resolved"
# shellcheck disable=SC2016  # the literal "${@}" IS the input under test
run_gate '...and the braced spellings "${@}" / "${@:2}"' \
    block 'git merge --no-ff --message "${@}" feature' "cannot be resolved"
# ...but [@] counts only as the parameter's own SUBSCRIPT. This is one word
# whatever MSG holds, and a pattern that looked for [@] anywhere refused it.
# shellcheck disable=SC2016  # the literal "${MSG:-note[@]}" IS the input under test
run_gate '...while "${MSG:-note[@]}" is one word, not an array' \
    allow 'git merge --no-ff --message "${MSG:-note[@]}" feature'
# EVERY indirection is plural, the plain-looking "${!name}" included — see the
# case below. These two are the explicit spellings.
# shellcheck disable=SC2016  # the literal "${!P@}" IS the input under test
run_gate '...and the indirections "${!P@}" / "${!arr[@]}"' \
    block 'git merge --no-ff --message "${!P@}" feature' "cannot be resolved"
# shellcheck disable=SC2016  # the literal "${!arr[@]}" IS the input under test
run_gate '...including its subscript spelling' \
    block 'git merge --no-ff --message "${!arr[@]}" feature' "cannot be resolved"
# ...and the plain-looking one is plural TOO, because indirection picks its
# target at run time: name='arr[@]' makes "${!name}" an array expansion, and the
# gate cannot see that value.
# shellcheck disable=SC2016  # the literal "${!name}" IS the input under test
run_gate '...and "${!name}", whose target is chosen at run time' \
    block 'git merge --no-ff --message "${!name}" feature' "cannot be resolved"
# ANSI-C quoting PROCESSES backslash escapes, so an escaped quote does not close
# it. Read as ordinary single quoting, the scanner closed at the escaped quote and
# opened a fictitious one at the real close, hiding the unquoted $MODE behind
# what looked like a quoted tail.
# shellcheck disable=SC2016  # the literal escape IS the input under test
run_gate "an escaped quote inside ANSI-C quoting does not close it" \
    block "git merge --no-ff --message \$'a\\''\$MODE feature" "cannot be resolved"

# A brace group expands when its OWN depth holds the delimiter, so nesting does
# not hide it. Both of these expand; a flat pattern matched neither.
run_gate "a nested brace expansion still expands" \
    block 'git merge --ff-only --message {note,{B}} feature' "cannot be resolved"
run_gate "...whichever side the nesting is on" \
    block 'git merge --ff-only --message {{A},B} feature' "cannot be resolved"
# ...but a metacharacter is not an expansion. Bash leaves an unmatched bracket,
# a bare extglob paren and an endpoint-less sequence literal, and flagging every
# occurrence blocked ordinary one-word arguments.
# A `..` is a SEQUENCE only in bash's grammar for one: integer..integer or
# char..char, with an optional integer increment. The rest stay literal.
run_gate "a real sequence expands" \
    block 'git merge --ff-only --message {1..5} feature' "cannot be resolved"
run_gate "...and its character form" \
    block 'git merge --ff-only --message {a..z} feature' "cannot be resolved"
run_gate "...and one with an increment" \
    block 'git merge --ff-only --message {1..9..2} feature' "cannot be resolved"
# Removing quoted material must not make its NEIGHBOURS adjacent: bash leaves
# these one literal word, and deleting the quotes synthesised `{a..b}`.
run_gate "quoted material does not fuse the punctuation around it" \
    allow 'git merge --no-ff --message {a."".b} feature'
run_gate "...even when the quotes contain the dot" \
    allow 'git merge --no-ff --message {a.".".b} feature'
# Bash allows at most ONE sign in a sequence endpoint or increment.
run_gate "a double-signed endpoint is not a sequence" \
    allow 'git merge --no-ff --message {--1..2} feature'
run_gate "...nor a double-signed increment" \
    allow 'git merge --no-ff --message {1..3..--1} feature'
# `$((...))` is ARITHMETIC — one word, and it runs nothing.
# shellcheck disable=SC2016  # the literal $((1+2)) IS the input under test
run_gate 'arithmetic expansion is not a command substitution' \
    allow 'git merge --no-ff --message="$((1+2))" feature'

run_gate "...while a multi-character range is literal" \
    allow 'git merge --no-ff --message {ab..cd} feature'
run_gate "...as is a non-ASCII character range" \
    allow 'git merge --no-ff --message {é..ê} feature'
# `${!}` is the braced spelling of `$!`, a special parameter, not an indirection.
# shellcheck disable=SC2016  # the literal "${!}" IS the input under test
run_gate 'the braced last-background-PID is one word' \
    allow 'git merge --no-ff --message "${!}" feature'
run_gate "...as is a mixed range" \
    allow 'git merge --no-ff --message {1..x} feature'
run_gate "...and a non-numeric increment" \
    allow 'git merge --no-ff --message {1..3..x} feature'
# ANSI-C quoting is literal too, substitutions included.
run_gate "a substitution inside ANSI-C quoting is literal" \
    allow "git merge --no-ff --message \$'\`x\`' feature"
# The STAR indirections join on IFS — one word, like "\$*".
# shellcheck disable=SC2016  # the literal "${!P*}" IS the input under test
run_gate 'the star indirections are single words' \
    allow 'git merge --no-ff --message "${!P*}" feature'
# shellcheck disable=SC2016  # the literal "${!arr[*]}" IS the input under test
run_gate '...including the subscript spelling' \
    allow 'git merge --no-ff --message "${!arr[*]}" feature'

# Any `[` with a later `]` is a glob. MEASURED on bash 3.2 with nullglob: `[]`,
# `[!]` and `[z-a]` all expand to ZERO words, exactly like `*` — "matches
# nothing" is not "is not a glob", because an unmatched pattern REMOVES its word.
run_gate "an empty bracket class is still a glob" \
    block 'git merge --ff-only --message [] feature' "cannot be resolved"
run_gate "...as is a negated empty one" \
    block 'git merge --ff-only --message [!] feature' "cannot be resolved"
run_gate "...and a reversed range" \
    block 'git merge --ff-only --message [z-a] feature' "cannot be resolved"
# Arithmetic is one numeric word wherever it appears, quoted or not.
# QUOTED arithmetic is one word. UNQUOTED is not: its result is a field like any
# other and undergoes IFS splitting, so with IFS=1 the innocuous $((212)) becomes
# the two words `2` and `2` — a second merge head.
# shellcheck disable=SC2016  # the literal $((1+2)) IS the input under test
run_gate 'quoted arithmetic expansion does not split' \
    allow 'git merge --no-ff --message="$((1+2))" feature'
# shellcheck disable=SC2016  # the literal $((212)) IS the input under test
run_gate '...but the unquoted form is IFS-split' \
    block 'git merge --ff-only --message $((212)) feature' "cannot be resolved"
# ...but parentheses inside a nested parameter expansion are TEXT, not arithmetic
# syntax, so the balance never closes; skipping to it swallowed the trailing $MSG.
# shellcheck disable=SC2016  # the literal expansion IS the input under test
run_gate 'an unbalanced arithmetic run is unreadable, not one word' \
    block 'git merge --no-ff --message $((${X:-"("}))$MSG feature' "cannot be resolved"
# ...and a QUOTED closer later in the word must not satisfy that balance either:
# `${Y:+")"}` closes nothing, and counting it skipped past the real end.
# shellcheck disable=SC2016  # the literal expansions ARE the input under test
run_gate 'a quoted paren does not close an arithmetic run' \
    block 'git merge --no-ff --message $((${X:-"("}))$MSG${Y:+")"} feature' \
    "cannot be resolved"
# `${!#}` indirects through a COUNT, so it names exactly one positional parameter.
# shellcheck disable=SC2016  # the literal "${!#}" IS the input under test
run_gate 'the count indirection is one word' \
    allow 'git merge --no-ff --message "${!#}" feature'
run_gate "...while a real class expands" \
    block 'git merge --ff-only --message [ab] feature' "cannot be resolved"
run_gate "...negated too" \
    block 'git merge --ff-only --message [!a] feature' "cannot be resolved"
run_gate "...and a forward range" \
    block 'git merge --ff-only --message [a-z] feature' "cannot be resolved"

run_gate "an unmatched bracket is literal, not a glob" \
    allow 'git merge --no-ff --message [ feature'
run_gate "...as is a bare paren with no extglob prefix" \
    allow 'git merge --no-ff --message ( feature'
run_gate "...and a sequence missing an endpoint" \
    allow 'git merge --no-ff --message {a..} feature'

# An option can betray the parser without changing the word COUNT: `--"$MODE"`
# stays one word while becoming a DIFFERENT option, and with MODE=ff-only bash
# hands git a later --ff-only that fast-forwards the merge reported out of scope.
# shellcheck disable=SC2016  # the literal $MODE IS the input under test
run_gate "an expansion in the option NAME is unresolvable" \
    block 'git merge --no-ff --"$MODE" feature' "cannot be resolved"
# A COMMAND SUBSTITUTION ends the analysis wherever it sits: its body is a whole
# shell command, quotes included, so the inner quotes here close the outer one and
# a single-state scanner reads the trailing $MSG as quoted.
# shellcheck disable=SC2016  # the literal substitutions ARE the input under test
run_gate "a command substitution makes the whole word unreadable" \
    block 'git merge --no-ff --message="$(x='"'"'"'"'"')"$MSG"$(y='"'"'"'"'"')" feature' \
    "cannot be resolved"

# ...but only where bash would RUN it: single quotes make it a literal message.
run_gate "a single-quoted substitution is a literal, not a command" \
    allow "git merge --no-ff --message '\$(echo note)' feature"
run_gate "...and so is a single-quoted backtick" \
    allow "git merge --no-ff --message '\`date\`' feature"
# A pending option VALUE is not an option NAME, however it is spelled. Checking
# the name first read the literal value '-\$MSG' of --message as a dynamic option.
run_gate "a value beginning with a dash is still a value" \
    allow "git merge --no-ff --message '-\$MSG' feature"

run_gate "...including its ANSI-C spelling" \
    block "git merge --no-ff --\$'ff-only' feature" "cannot be resolved"
# ...while QUOTING the WHOLE word disables both expansions, so it is a ref name.
run_gate "a quoted brace word is a ref, not an expansion" \
    block "git merge --ff-only '{note,B}'" "cannot resolve the merge target"

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
# MANY and LONG, both deliberately. The gate bounds its read with `head`, and a
# listing of 70 short names fits the pipe buffer whole - the reader closes early
# but git has already finished writing, so nothing is signalled. Only a listing
# far larger than head will ever consume leaves git blocked mid-write when the
# pipe closes, which is what raises SIGPIPE and, under `pipefail`, fails the
# whole pipeline on exactly the oversized list this guard exists for. Written
# straight into the config: 500 `git remote add` calls would dominate the run.
_LONGNAME=$(printf 'x%.0s' $(seq 1 1000))
for _i in $(seq 1 500); do
    printf '[remote "r%s%s"]\n\turl = %s\n\tfetch = +refs/heads/*:refs/remotes/r%s%s/*\n' \
        "$_i" "$_LONGNAME" "$ORIGIN" "$_i" "$_LONGNAME"
done >> "$REPO/.git/config"
_rc=0
_remote_bytes=$(git -C "$REPO" remote | wc -c | tr -d ' ')
[[ "$_remote_bytes" -gt 262144 ]] || _rc=1
assert_true "the many-remotes listing outruns the pipe buffer ($_remote_bytes bytes)" "$_rc"
run_gate "a repo with more remotes than the budget allows is refused" \
    block "git merge feature" "past the 64 this gate can examine"
setup_repo hugeremotes || { printf '  FAIL  fixture setup (hugeremotes)\n'; exit 1; }
# FEW remotes, ENORMOUS names. A line bound says nothing about how much there is
# to read: ten names of 100 KiB each are ten lines and a megabyte, so counting
# lines alone would walk them all and spend the budget the count exists to save.
_HUGENAME=$(printf 'y%.0s' $(seq 1 100000))
for _i in $(seq 1 10); do
    printf '[remote "h%s%s"]\n\turl = %s\n\tfetch = +refs/heads/*:refs/remotes/h%s%s/*\n' \
        "$_i" "$_HUGENAME" "$ORIGIN" "$_i" "$_HUGENAME"
done >> "$REPO/.git/config"
_rc=0
_huge_n=$(git -C "$REPO" remote | wc -l | tr -d ' ')
_huge_b=$(git -C "$REPO" remote | wc -c | tr -d ' ')
{ [[ "$_huge_n" -le 64 ]] && [[ "$_huge_b" -gt 65536 ]]; } || _rc=1
assert_true "the huge-names fixture is under the NAME bound ($_huge_n) and over the BYTE one ($_huge_b)" "$_rc"
run_gate "...and so is a listing that is few names but far too many bytes" \
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
# Arithmetic in a merge option value reads as a COMPANION and is refused, even on
# the authorized route. Deliberate, not an oversight: `$( (cmd) )` is a command
# substitution wrapping a subshell and is spelled `$((cmd))` without the space, so
# skipping every `$((` would stop scanning a real command body. An over-count
# blocks; an under-count is a bypass. `--message` has no effect on a fast-forward
# anyway, so the refusal costs nothing real.
run_gate "arithmetic in a merge option value is refused as a companion" \
    block "git merge --ff-only --message=\"\$((1+2))\" $FEATURE_OID" \
    "runs something else ALONGSIDE a merge/pull"

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
# The payload writes inside the suite's OWN temp tree, never a fixed /tmp name.
# The cleanup below removes whatever sits at that path, and a suite must not
# delete a file it did not create.
_PWN="$TMPROOT/ref-ff-pwn"
# shellcheck disable=SC2016  # the literal ${IFS} IS the payload under test
_HOSTILE='x'"'"';touch${IFS}'"$_PWN"';#'
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
# The message is printed, never run - so this is a backstop, not the main
# assertion. It costs one stat and would catch any future path that did execute.
_rc=0; [[ -e "$_PWN" ]] && _rc=1
assert_true "...and nothing executed the payload the name carries" "$_rc"
rm -f "$REPO/$ISO_STATE/ref-ff-protected.local" "$_PWN"
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

# ...and trailing BLANK lines are trailing garbage too - the shape a whole-file
# compare misses, because command substitution strips every trailing newline and
# the two strings then compare equal. Written directly rather than through
# write_marker: passing it through `$(...)` would strip the very newlines under
# test and leave this asserting nothing.
printf 'PASS-FF refs/heads/main %s\n\n\n' "$FEATURE_OID" \
    > "$REPO/$ISO_STATE/ref-ff-authorized.local"
touch -t 200001010000 "$REPO/$ISO_STATE/ref-ff-authorized.local"
_rc=0; [[ "$(grep -c '^' "$REPO/$ISO_STATE/ref-ff-authorized.local")" == "3" ]] || _rc=1
assert_true "the trailing-blank-line marker fixture really has 3 lines" "$_rc"
run_gate "...as are trailing BLANK lines, which a stripped compare reads as equal" \
    block "git merge --ff-only $FEATURE_OID"

write_marker "PASS-MERGE-1754400000"
run_gate "the old PASS-MERGE token cannot authorize a fast-forward" \
    block "git merge --ff-only $FEATURE_OID"

printf '%s\n' "PASS-FF refs/heads/main $FEATURE_OID" > "$REPO/$ISO_STATE/ref-ff-authorized.local"
run_gate "a marker created moments ago is refused (anti-self-bypass)" \
    block "git merge --ff-only $FEATURE_OID" "was created moments ago"
rm -f "$REPO/$ISO_STATE/ref-ff-authorized.local"

# A fast-forward that lands a POST-MERGE HOOK is not one ref move: git runs
# post-merge immediately, so with core.hooksPath in the working tree the content
# being checked out executes. This needs NO shell access, only control of the
# incoming content — exactly what the gate distrusts.
git -C "$REPO" config core.hooksPath .githooks
git -C "$REPO" checkout -q feature
mkdir -p "$REPO/.githooks"
printf '#!/bin/sh\necho pwned\n' > "$REPO/.githooks/post-merge"
chmod +x "$REPO/.githooks/post-merge"
git -C "$REPO" add .githooks/post-merge >/dev/null 2>&1
git -C "$REPO" commit -qm "add post-merge hook" >/dev/null 2>&1
HOOK_OID=$(git -C "$REPO" rev-parse 'feature^{commit}')
git -C "$REPO" checkout -q main
write_marker "PASS-FF refs/heads/main $HOOK_OID"
run_gate "a fast-forward that lands a post-merge hook is refused" \
    block "git merge --ff-only $HOOK_OID" "core.hooksPath"
rm -f "$REPO/$ISO_STATE/ref-ff-authorized.local"
# ...and the refusal does NOT depend on this merge touching that directory. The
# narrow "only if it changes" check was tried and abandoned: deciding what git
# will execute means resolving repo-root paths, relative paths, symlinks,
# DANGLING symlinks, symlinks nested inside the hooks dir, and pathspec magic
# like `:(exclude)` — and each fix revealed the next hole.
write_marker "PASS-FF refs/heads/main $FEATURE_OID"
run_gate "...and an in-tree hooksPath refuses the route regardless" \
    block "git merge --ff-only $FEATURE_OID" "core.hooksPath"
git -C "$REPO" config --unset core.hooksPath
setup_repo main || { printf '  FAIL  fixture re-setup (hookspath)\n'; exit 1; }

# ...and the configured spelling is not the directory git reaches. With
# `.githooks -> hooks`, a change to `hooks/post-merge` produces no diff under
# `.githooks`, yet git follows the link and runs the changed hook. Containment is
# therefore resolved physically, and both spellings are passed as pathspecs.
git -C "$REPO" checkout -q feature
mkdir -p "$REPO/hooks"
printf '#!/bin/sh\necho pwned\n' > "$REPO/hooks/post-merge"
chmod +x "$REPO/hooks/post-merge"
git -C "$REPO" add hooks/post-merge >/dev/null 2>&1
git -C "$REPO" commit -qm "add hook via symlinked dir" >/dev/null 2>&1
SYM_OID=$(git -C "$REPO" rev-parse 'feature^{commit}')
git -C "$REPO" checkout -q main
ln -s hooks "$REPO/.githooks"
git -C "$REPO" config core.hooksPath .githooks
write_marker "PASS-FF refs/heads/main $SYM_OID"
run_gate "a symlinked hooksPath is resolved, not taken literally" \
    block "git merge --ff-only $SYM_OID" "core.hooksPath"
rm -f "$REPO/$ISO_STATE/ref-ff-authorized.local" "$REPO/.githooks"
git -C "$REPO" config --unset core.hooksPath
setup_repo main || { printf '  FAIL  fixture re-setup (symlink hookspath)\n'; exit 1; }

# An ABSOLUTE hooksPath outside the tree is not safe just because it is spelled
# that way: a dangling `/tmp/... -> <repo>/future-hooks` resolves INTO the tree
# the moment this merge creates the target. A link that cannot be followed is not
# provably outside, so it refuses.
ln -s "$REPO/future-hooks" "$TMPROOT/dangling-hooks"
git -C "$REPO" config core.hooksPath "$TMPROOT/dangling-hooks"
write_marker "PASS-FF refs/heads/main $FEATURE_OID"
run_gate "a dangling absolute hooksPath symlink is not provably outside" \
    block "git merge --ff-only $FEATURE_OID" "core.hooksPath"
rm -f "$REPO/$ISO_STATE/ref-ff-authorized.local" "$TMPROOT/dangling-hooks"
# The path'''s OWN LOCATION counts, not only where it resolves today: a tracked
# in-tree entry spelled ABSOLUTELY, pointing safely outside right now, can be
# replaced by this very merge with a directory holding post-merge.
ln -s /tmp "$REPO/.githooks-abs"
git -C "$REPO" config core.hooksPath "$REPO/.githooks-abs"
write_marker "PASS-FF refs/heads/main $FEATURE_OID"
run_gate "an absolute in-tree hooksPath spelling refuses too" \
    block "git merge --ff-only $FEATURE_OID" "post-merge hook"
rm -f "$REPO/$ISO_STATE/ref-ff-authorized.local" "$REPO/.githooks-abs"
# An INTERMEDIATE in-tree component counts as much as the final one. `.links` is
# tracked content pointing safely outside today, so the fully-resolved path looks
# external - and this very merge can replace `.links` with a directory holding
# post-merge. Each component must be judged where it LIVES, before it is followed.
ln -s /tmp "$REPO/.links"
git -C "$REPO" config core.hooksPath "$REPO/.links/current/hooks"
_rc=0; [[ -L "$REPO/.links" ]] || _rc=1
assert_true "the nested-symlink hooksPath fixture was created" "$_rc"
write_marker "PASS-FF refs/heads/main $FEATURE_OID"
run_gate "an in-tree symlink COMPONENT refuses, though the path resolves outside" \
    block "git merge --ff-only $FEATURE_OID" "post-merge hook"
rm -f "$REPO/$ISO_STATE/ref-ff-authorized.local" "$REPO/.links"
git -C "$REPO" config --unset core.hooksPath
# SET-to-empty is not unset, and git does not fall back to the default for it.
git -C "$REPO" config core.hooksPath ""
write_marker "PASS-FF refs/heads/main $FEATURE_OID"
run_gate "an empty core.hooksPath value is not treated as the default" \
    block "git merge --ff-only $FEATURE_OID" "EMPTY value"
rm -f "$REPO/$ISO_STATE/ref-ff-authorized.local"
git -C "$REPO" config --unset core.hooksPath

# A symlink LOOP leaves realpath non-strict and returns a spelling that can look
# safely outside, so an entry that cannot be stat'''ed for any reason other than
# absence is not provably outside.
ln -s "$TMPROOT/loop-b" "$TMPROOT/loop-a"
ln -s "$TMPROOT/loop-a" "$TMPROOT/loop-b"
git -C "$REPO" config core.hooksPath "$TMPROOT/loop-a"
write_marker "PASS-FF refs/heads/main $FEATURE_OID"
run_gate "a symlink loop in hooksPath is not provably outside" \
    block "git merge --ff-only $FEATURE_OID" "post-merge hook"
rm -f "$REPO/$ISO_STATE/ref-ff-authorized.local" "$TMPROOT/loop-a" "$TMPROOT/loop-b"
git -C "$REPO" config --unset core.hooksPath

# A RELATIVE hooksPath never passes: it is rooted in the working tree, so this
# merge can replace any component of it - including a tracked `.githooks` symlink
# that resolves OUTSIDE today and becomes an in-tree directory once the merge
# lands. Resolving the pre-merge filesystem cannot see that coming.
ln -s /tmp "$REPO/.githooks-out"
git -C "$REPO" config core.hooksPath .githooks-out
write_marker "PASS-FF refs/heads/main $FEATURE_OID"
run_gate "a relative hooksPath resolving outside today still refuses" \
    block "git merge --ff-only $FEATURE_OID" "post-merge hook"
rm -f "$REPO/$ISO_STATE/ref-ff-authorized.local" "$REPO/.githooks-out"
git -C "$REPO" config --unset core.hooksPath
# ...while a plainly ABSENT absolute path is harmless: it is not a link, so it
# points nowhere git can execute from. This is the ordinary global-hooks case.
git -C "$REPO" config core.hooksPath "$TMPROOT/no-such-hooks-dir"
write_marker "PASS-FF refs/heads/main $FEATURE_OID"
run_gate "...while an absent non-symlink absolute hooksPath is fine" \
    allow "git merge --ff-only $FEATURE_OID"
git -C "$REPO" config --unset core.hooksPath
setup_repo main || { printf '  FAIL  fixture re-setup (dangling hookspath)\n'; exit 1; }

# The DEFAULT hooks directory counts too, and this is the case a hooksPath-only
# check missed entirely: no core.hooksPath is set, but .git/hooks/post-merge is a
# SYMLINK to a tracked file, so the merge replaces the very file git then runs.
# A plain regular file there is fine - it lives in the git dir, which the merge
# cannot touch - so this pins both directions.
_gd=$(git -C "$REPO" rev-parse --absolute-git-dir)
mkdir -p "$_gd/hooks"
# The operator may have a GLOBAL core.hooksPath, which would mask the default and
# make this test exercise nothing. Name the git dir's own hooks explicitly.
git -C "$REPO" config core.hooksPath "$_gd/hooks"
# An actual regular file, not an absent one: the exemption being asserted is that
# a REAL hook living in the git dir is fine, and an empty directory would assert
# nothing.
printf '#!/bin/sh\nexit 0\n' > "$_gd/hooks/post-merge"
chmod +x "$_gd/hooks/post-merge"
_rc=0; { [[ -f "$_gd/hooks/post-merge" ]] && [[ ! -L "$_gd/hooks/post-merge" ]]; } || _rc=1
assert_true "the default post-merge hook fixture is a regular file" "$_rc"
write_marker "PASS-FF refs/heads/main $FEATURE_OID"
run_gate "a plain default post-merge hook file does not block" \
    allow "git merge --ff-only $FEATURE_OID"
rm -f "$_gd/hooks/post-merge"
rm -f "$REPO/$ISO_STATE/ref-ff-authorized.local"
ln -sf ../../tracked-hook "$_gd/hooks/post-merge"
write_marker "PASS-FF refs/heads/main $FEATURE_OID"
run_gate "...but a default post-merge SYMLINK into the tree refuses" \
    block "git merge --ff-only $FEATURE_OID" "post-merge hook"
rm -f "$REPO/$ISO_STATE/ref-ff-authorized.local" "$_gd/hooks/post-merge"
git -C "$REPO" config --unset core.hooksPath
setup_repo main || { printf '  FAIL  fixture re-setup (default hooks)\n'; exit 1; }

# ...and with core.hooksPath UNSET - the ordinary case, and the one with no
# coverage until now. `git config --get` exits nonzero for an unset key, so a
# gate under `set -euf` can die here before deciding anything; run_gate scores
# that as a crash rather than an allow, which is what makes this test bite.
# The operator may have a GLOBAL core.hooksPath, which would mask the unset case
# and leave this testing nothing. GIT_CONFIG_GLOBAL cannot neutralize it: the
# gate runs every git through `env -u GIT_CONFIG_GLOBAL -u GIT_CONFIG_SYSTEM`
# deliberately, so it re-reads the operator's real config. HOME is the lever that
# does reach it, and the precondition below is asserted through the SAME env the
# gate uses, so it cannot claim coverage the gate does not actually see.
git -C "$REPO" config --unset-all core.hooksPath >/dev/null 2>&1 || true
_EMPTY_HOME="$TMPROOT/empty-home"; mkdir -p "$_EMPTY_HOME"
export HOME="$_EMPTY_HOME"
_rc=0
env -u GIT_CONFIG_GLOBAL -u GIT_CONFIG_SYSTEM git -C "$REPO" config --get core.hooksPath >/dev/null 2>&1 && _rc=1
assert_true "no core.hooksPath is visible to the gate for the unset fixture" "$_rc"
write_marker "PASS-FF refs/heads/main $FEATURE_OID"
run_gate "an unset core.hooksPath decides normally, it does not abort the gate" \
    allow "git merge --ff-only $FEATURE_OID"
rm -f "$REPO/$ISO_STATE/ref-ff-authorized.local"
export HOME="$_REAL_HOME"
setup_repo main || { printf '  FAIL  fixture re-setup (unset hooks)\n'; exit 1; }

# ── A value git stores faithfully but `$(...)` cannot carry: command
#    substitution strips every trailing newline, so `/tmp/hooks\n` reaches the
#    gate as `/tmp/hooks`. That trimmed name is outside the tree (and need not
#    exist at all), while git runs the hook under the real newline-suffixed
#    path. Measured: git writes the value escaped and hands it back intact.
#    The gate refuses rather than guessing which name it is judging. ──────────
git -C "$REPO" config core.hooksPath '/tmp/hooks
'
_nl_count=$(git -C "$REPO" config -z --get core.hooksPath | tr -d '\000' | wc -l | tr -d ' ')
_rc=0; [[ "$_nl_count" == "1" ]] || _rc=1
assert_true "the newline-valued hooksPath fixture really holds a newline" "$_rc"
write_marker "PASS-FF refs/heads/main $FEATURE_OID"
run_gate "a core.hooksPath containing a NEWLINE is refused, not silently trimmed" \
    block "git merge --ff-only $FEATURE_OID" "contains a NEWLINE"
rm -f "$REPO/$ISO_STATE/ref-ff-authorized.local"
git -C "$REPO" config --unset core.hooksPath

# ── The containment check is a `python3 -c` payload, and `-c` puts the
#    process's CURRENT DIRECTORY first on sys.path. In real use that directory
#    is the repository being merged in, so a unicodedata.py sitting there is
#    imported instead of the stdlib one - measured: it then returns whatever it
#    likes from normalize(), which folds every path to one value and turns this
#    refusal into an allow. The control case first, so the second assertion is
#    known to be about the module and not about the fixture. ─────────────────
mkdir -p "$REPO/.githooks-in-tree"
git -C "$REPO" config core.hooksPath "$REPO/.githooks-in-tree"
write_marker "PASS-FF refs/heads/main $FEATURE_OID"
run_gate "an in-tree hooksPath refuses (control for the hostile-module case)" \
    block "git merge --ff-only $FEATURE_OID" "post-merge hook"
rm -f "$REPO/$ISO_STATE/ref-ff-authorized.local"
# Not a constant: folding EVERY path together also makes the worktree look like
# it sits inside the git dir, and the gate refuses that outright - a block for
# the wrong reason, which would leave this test asserting nothing. This one
# leaves git-dir paths alone and collapses the rest, so the worktree-root
# exemption swallows the hooks path while the ancestor guard stays quiet.
printf 'def normalize(form, s):\n    if s.endswith(".git") or "/.git/" in s:\n        return s\n    return "X"\n' > "$REPO/unicodedata.py"
_rc=0; [[ -f "$REPO/unicodedata.py" ]] || _rc=1
assert_true "the repo-controlled unicodedata.py fixture is in place" "$_rc"
write_marker "PASS-FF refs/heads/main $FEATURE_OID"
GATE_CWD="$REPO"
run_gate "...and a repo-controlled unicodedata.py cannot make it allow" \
    block "git merge --ff-only $FEATURE_OID" "post-merge hook"
unset GATE_CWD
rm -f "$REPO/$ISO_STATE/ref-ff-authorized.local" "$REPO/unicodedata.py"
rmdir "$REPO/.githooks-in-tree"
git -C "$REPO" config --unset core.hooksPath

# ── The git-dir exemption ("a hook that lives inside the git dir is out of the
#    merge's reach") holds only while the git dir is NOT an ancestor of the
#    worktree. `git init --separate-git-dir` builds exactly that layout, and it
#    is constructible - measured, not assumed. In it EVERY tracked path is
#    inside the git dir too, so an exemption keyed on "inside the git dir"
#    would swallow the whole post-merge check and wave the merge through. The
#    layout cannot be proven safe here, so it refuses. ────────────────────────
_SAVED_REPO="$REPO"
_ANC="$TMPROOT/anc"
rm -rf "$_ANC"
(
    set -e
    git init -q -b main --separate-git-dir="$_ANC/gd" "$_ANC/gd/wt"
    cd "$_ANC/gd/wt"
    git config user.email t@t; git config user.name t
    git config commit.gpgsign false; git config tag.gpgsign false
    echo base > f; git add f; git commit -qm base
    git checkout -q -b feature
    echo more > f; git add f; git commit -qm more
    git checkout -q main
) || { printf '  FAIL  fixture setup (gitdir-ancestor)\n'; FAIL=$((FAIL + 1)); }
REPO="$_ANC/gd/wt"
mkdir -p "$REPO/$ISO_STATE"
# This fixture has no remote, so protected-branch discovery would fall through
# to init.defaultBranch - operator config the suite does not control. Declare it
# instead, so the test turns on the git-dir layout and nothing else.
printf 'main\n' > "$REPO/$ISO_STATE/ref-ff-protected.local"
_ANC_OID=$(git -C "$REPO" rev-parse feature 2>/dev/null) || _ANC_OID=""
# pwd -P on both sides: the gate compares realpath'd roots, and $TMPROOT is under
# /var, a symlink to /private/var on macOS.
_anc_tl_raw=$(git -C "$REPO" rev-parse --show-toplevel)
_anc_gd_raw=$(git -C "$REPO" rev-parse --absolute-git-dir)
_anc_tl=$(cd "$_anc_tl_raw" && pwd -P)
_anc_gd=$(cd "$_anc_gd_raw" && pwd -P)
_rc=1; case "$_anc_tl" in "$_anc_gd"/*) _rc=0 ;; esac
assert_true "the fixture's git dir really is an ANCESTOR of its worktree" "$_rc"
write_marker "PASS-FF refs/heads/main $_ANC_OID"
run_gate "a git dir that is an ANCESTOR of the worktree refuses the merge" \
    block "git merge --ff-only $_ANC_OID" "post-merge hook"
rm -f "$REPO/$ISO_STATE/ref-ff-authorized.local" "$REPO/$ISO_STATE/ref-ff-protected.local"
REPO="$_SAVED_REPO"
rm -rf "$_ANC"

# ...and the SAME layout spelled in a different case. realpath resolves symlinks
# but keeps the spelling it is handed, so on a case-insensitive volume a git dir
# recorded as .../GD and a worktree at .../gd/wt are ONE directory that no plain
# string comparison relates - and a core.hooksPath spelled with the git dir's
# casing would then take the exemption and wave a tracked in-tree post-merge
# hook through.
#
# Two spellings, because they discriminate different things. gd/GD is plain
# ASCII and any lowercasing catches it. The Greek pair does not: `lower()` maps
# the medial sigma but leaves the FINAL sigma alone, while the filesystem folds
# them together (measured on this volume) - so only real case FOLDING sees that
# ancestry. Each pair is built only where the alias actually exists; on a
# case-sensitive volume the two names are different directories and there is
# nothing to alias.
for _pair in "gd:GD" "σ:ς"; do
    _low="${_pair%%:*}"; _alias="${_pair##*:}"
    rm -rf "$TMPROOT/case-probe"; mkdir -p "$TMPROOT/case-probe/$_alias"
    [[ -d "$TMPROOT/case-probe/$_low" ]] || continue
    _SAVED_REPO="$REPO"
    _ANC2="$TMPROOT/anc2"
    rm -rf "$_ANC2"; mkdir -p "$_ANC2"
    # Physical from the start: $TMPROOT sits under /var, a symlink to /private/var
    # on macOS, and a prefix test that missed for THAT reason would prove nothing
    # about casing.
    _ANC2_P=$(cd "$_ANC2" && pwd -P)
    (
        set -e
        git init -q -b main --separate-git-dir="$_ANC2_P/$_low" "$_ANC2_P/$_low/wt"
        cd "$_ANC2_P/$_low/wt"
        git config user.email t@t; git config user.name t
        git config commit.gpgsign false; git config tag.gpgsign false
        echo base > f; git add f; git commit -qm base
        git checkout -q -b feature
        echo more > f; git add f; git commit -qm more
        git checkout -q main
        # Re-point the worktree at the ALIASED spelling of that very directory.
        # Written by hand deliberately - git normalizes its own spelling.
        printf 'gitdir: %s\n' "$_ANC2_P/$_alias" > "$_ANC2_P/$_low/wt/.git"
    ) || { printf '  FAIL  fixture setup (case-aliased gitdir-ancestor %s)\n' "$_pair"; FAIL=$((FAIL + 1)); }
    REPO="$_ANC2_P/$_low/wt"
    mkdir -p "$REPO/$ISO_STATE"
    printf 'main\n' > "$REPO/$ISO_STATE/ref-ff-protected.local"
    _ANC2_OID=$(git -C "$REPO" rev-parse feature 2>/dev/null) || _ANC2_OID=""
    _anc2_tl=$(git -C "$REPO" rev-parse --show-toplevel 2>/dev/null) || _anc2_tl=""
    _anc2_gd=$(git -C "$REPO" rev-parse --absolute-git-dir 2>/dev/null) || _anc2_gd=""
    # The alias only bites if a PLAIN prefix test misses the ancestry while the
    # directory is genuinely there. That is the pre-fix behaviour being pinned.
    _rc=0
    case "$_anc2_tl" in "$_anc2_gd"/*) _rc=1 ;; esac
    { [[ -n "$_anc2_gd" ]] && [[ -d "$_anc2_gd" ]]; } || _rc=1
    assert_true "the $_pair fixture hides its ancestry from a plain prefix test" "$_rc"
    write_marker "PASS-FF refs/heads/main $_ANC2_OID"
    run_gate "...and a CASE-ALIASED ($_pair) ancestor git dir refuses too" \
        block "git merge --ff-only $_ANC2_OID" "post-merge hook"
    rm -f "$REPO/$ISO_STATE/ref-ff-authorized.local" "$REPO/$ISO_STATE/ref-ff-protected.local"
    REPO="$_SAVED_REPO"
    rm -rf "$_ANC2"
done
rm -rf "$TMPROOT/case-probe"

# ── A second spelling that realpath does NOT collapse: macOS firmlinks give
#    /x and /System/Volumes/Data/x the same dev+inode under different names, so
#    a hooksPath written the other way reads as safely outside the very tree it
#    is inside. Built only where the alias actually resolves to the same
#    directory - it is a macOS data-volume layout, not a portable one. ────────
_ALIAS_PREFIX=/System/Volumes/Data
_repo_phys=$(cd "$REPO" && pwd -P)
_alias_repo="$_ALIAS_PREFIX$_repo_phys"
_id_a=$(stat -f '%d:%i' "$_repo_phys" 2>/dev/null) || _id_a=""
_id_b=$(stat -f '%d:%i' "$_alias_repo" 2>/dev/null) || _id_b=""
if [[ -n "$_id_a" ]] && [[ "$_id_a" == "$_id_b" ]]; then
    mkdir -p "$REPO/.githooks-alias"
    # The ALIAS spelling, which shares no prefix with the repo path git reports.
    git -C "$REPO" config core.hooksPath "$_alias_repo/.githooks-alias"
    _rc=0
    case "$_alias_repo" in "$_repo_phys"/*|"$_repo_phys") _rc=1 ;; esac
    assert_true "the firmlink alias spelling shares no prefix with the repo path" "$_rc"
    write_marker "PASS-FF refs/heads/main $FEATURE_OID"
    run_gate "an in-tree hooksPath spelled through a firmlink alias refuses too" \
        block "git merge --ff-only $FEATURE_OID" "post-merge hook"
    rm -f "$REPO/$ISO_STATE/ref-ff-authorized.local"
    rmdir "$REPO/.githooks-alias"
    # ...and DEEP, through the same alias, where the plain-prefix test is blind
    # and every verdict rests on the identity climb. This does NOT discriminate
    # the climb's bound: measured, a 300-component path still refuses with the
    # bound at 256 and its exhausted answer inverted, because the walk reaches
    # the worktree root - a climb of zero - long before depth matters. It is
    # kept as coverage of the deep-alias shape itself, not as a bound test.
    _deep=""
    for _i in $(seq 1 300); do _deep="$_deep/d"; done
    mkdir -p "$REPO$_deep"
    git -C "$REPO" config core.hooksPath "$_alias_repo$_deep"
    _rc=0; [[ -d "$REPO$_deep" ]] || _rc=1
    assert_true "the 300-component in-tree hooks directory was created" "$_rc"
    write_marker "PASS-FF refs/heads/main $FEATURE_OID"
    run_gate "a DEEP in-tree hooksPath through the alias refuses too" \
        block "git merge --ff-only $FEATURE_OID" "post-merge hook"
    rm -f "$REPO/$ISO_STATE/ref-ff-authorized.local"
    rm -rf "$REPO/d"
    git -C "$REPO" config --unset core.hooksPath
fi

# ── The interpreter the REGISTRATION names. hooks.json launches this gate with
#    /bin/bash, which on macOS is 3.2; the rest of this suite runs it with
#    whatever `bash` PATH resolves to, which on a developer machine is 5.x. So a
#    bash-4-only construct passes every test here and aborts in production —
#    where an aborting gate emits no decision, and the launcher turns that into
#    a refusal of every command it guards. Measured: process substitution
#    containing a parenthesised comment does exactly that under 3.2.
#    Both directions, so this proves the gate DECIDES there rather than merely
#    failing in the direction that happens to look like a pass. ───────────────
_rc=0; [[ -x /bin/bash ]] || _rc=1
assert_true "the interpreter named by the registration exists" "$_rc"
GATE_BASH=/bin/bash
write_marker "PASS-FF refs/heads/main $FEATURE_OID"
run_gate "under /bin/bash the gate still ALLOWS an authorized fast-forward" \
    allow "git merge --ff-only $FEATURE_OID"
rm -f "$REPO/$ISO_STATE/ref-ff-authorized.local"
run_gate "...and still BLOCKS an unauthorized one, so it is deciding, not aborting" \
    block "git merge $FEATURE_OID" "would FAST-FORWARD the protected branch"
unset GATE_BASH

# ── The containment payload lives inside a shell "..." string, so a `$`, a
#    backtick or a double quote anywhere in it - a COMMENT included - is
#    expanded rather than read as text. Every time that has happened the gate
#    silently blocked everything, which is a fail-closed direction but still a
#    dead gate. Pin it structurally; prose has not held. ──────────────────────
_pay_start=$(grep -n 'python3 -I -S -c "' "$GATE_SCRIPT" | cut -d: -f1)
_pay_end=$(grep -n '^" "\$REPO_DIR" "\$_hookdir" "\$_gitdir"' "$GATE_SCRIPT" | cut -d: -f1)
_rc=0
{ [[ -n "$_pay_start" ]] && [[ -n "$_pay_end" ]] && [[ "$_pay_end" -gt "$_pay_start" ]]; } || _rc=1
assert_true "the embedded containment payload was located in the gate" "$_rc"
if [[ "$_rc" -eq 0 ]]; then
    _bad=$(awk -v a="$_pay_start" -v b="$_pay_end" 'NR>a && NR<b' "$GATE_SCRIPT" | grep -c '[$`"\\]')
    _rc=0; [[ "${_bad//[[:space:]]/}" == "0" ]] || _rc=1
    assert_true "the embedded payload carries no shell-active character" "$_rc"
fi

# ── An in-tree component that RESOLVES to the worktree root. The root itself is
#    exempt because git cannot replace it - but a tracked `.jump -> $REPO` is
#    not the root, it is ordinary space this merge can turn into a directory of
#    its own. Spelled with a `..` after it the path resolves OUTSIDE the tree
#    today, so only judging the component where it lives catches it. ──────────
ln -s "$REPO" "$REPO/.jump"
git -C "$REPO" config core.hooksPath "$REPO/.jump/../hooks"
_rc=0; [[ -L "$REPO/.jump" ]] || _rc=1
assert_true "the self-referencing .jump symlink fixture was created" "$_rc"
write_marker "PASS-FF refs/heads/main $FEATURE_OID"
run_gate "an in-tree component resolving to the worktree ROOT is not exempt either" \
    block "git merge --ff-only $FEATURE_OID" "post-merge hook"
rm -f "$REPO/$ISO_STATE/ref-ff-authorized.local" "$REPO/.jump"
git -C "$REPO" config --unset core.hooksPath

# ── A git dir INSIDE the worktree under an ordinary name. `.git` is reserved -
#    git will never check content into it - but a separate common dir at
#    <worktree>/control is plain tracked space, so an incoming commit can add
#    control/hooks/post-merge and the exemption would wave it through. The
#    layout cannot be proven safe, so the marker route refuses it. ────────────
_SAVED_REPO="$REPO"
_CTL="$TMPROOT/ctl"
rm -rf "$_CTL"; mkdir -p "$_CTL"
_CTL_P=$(cd "$_CTL" && pwd -P)
(
    set -e
    git init -q -b main --separate-git-dir="$_CTL_P/wt/control" "$_CTL_P/wt"
    cd "$_CTL_P/wt"
    git config user.email t@t; git config user.name t
    git config commit.gpgsign false; git config tag.gpgsign false
    echo base > f; git add f; git commit -qm base
    git checkout -q -b feature
    echo more > f; git add f; git commit -qm more
    git checkout -q main
) || { printf '  FAIL  fixture setup (in-tree git dir)\n'; FAIL=$((FAIL + 1)); }
REPO="$_CTL_P/wt"
mkdir -p "$REPO/$ISO_STATE"
printf 'main\n' > "$REPO/$ISO_STATE/ref-ff-protected.local"
_ctl_oid=$(git -C "$REPO" rev-parse feature 2>/dev/null) || _ctl_oid=""
_ctl_common=$(git -C "$REPO" rev-parse --git-common-dir 2>/dev/null) || _ctl_common=""
_ctl_tl=$(git -C "$REPO" rev-parse --show-toplevel 2>/dev/null) || _ctl_tl=""
# It has to be genuinely INSIDE the worktree and genuinely not named .git,
# or the case under test is not the case being built.
_rc=0
case "$_ctl_common" in "$_ctl_tl"/*) : ;; *) _rc=1 ;; esac
case "$_ctl_common" in */.git) _rc=1 ;; esac
assert_true "the in-tree git dir fixture sits in the worktree under a plain name" "$_rc"
write_marker "PASS-FF refs/heads/main $_ctl_oid"
run_gate "a git dir inside the worktree under a plain name is not exempt space" \
    block "git merge --ff-only $_ctl_oid" "post-merge hook"
rm -f "$REPO/$ISO_STATE/ref-ff-authorized.local" "$REPO/$ISO_STATE/ref-ff-protected.local"
printf 'main\n' > "$REPO/$ISO_STATE/ref-ff-protected.local"
# ...and the same layout reached through a .git SYMLINK. What makes .git safe is
# that git will not track a path spelled that way - nothing about the directory
# behind it. A test that asked whether .git and the git dir are the same
# DIRECTORY would follow the link and call the tracked `control` reserved.
rm -f "$REPO/.git"
ln -s control "$REPO/.git"
_rc=0
{ [[ -L "$REPO/.git" ]] && git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1; } || _rc=1
assert_true "the .git-symlink fixture is a symlink git still resolves" "$_rc"
write_marker "PASS-FF refs/heads/main $_ctl_oid"
run_gate "...and a .git SYMLINK onto it does not make it reserved either" \
    block "git merge --ff-only $_ctl_oid" "post-merge hook"
rm -f "$REPO/$ISO_STATE/ref-ff-authorized.local" "$REPO/$ISO_STATE/ref-ff-protected.local"
REPO="$_SAVED_REPO"
rm -rf "$_CTL"
# The reservation is granted to the EXACT name `.git` and to no other spelling,
# because that is the name git refuses to track. The `.GIT` variant of this case
# is only constructible on a case-SENSITIVE volume - here the two names are one
# file, so a fixture cannot hold both - and a test that could only ever skip is
# not coverage. The two cases above pin the same rule with names that do exist.

# ── An in-tree component that currently POINTS INTO the git dir. Its target is
#    exempt, but the component itself lives in the worktree, and this merge can
#    replace it with a directory of its own holding post-merge. The exemption
#    therefore has to be decided on where a path LIVES, never on where it
#    resolves - the mirror image of the nested-symlink case above. ────────────
ln -s .git/hooks "$REPO/.githooks-into-gitdir"
git -C "$REPO" config core.hooksPath "$REPO/.githooks-into-gitdir"
_rc=0; [[ -L "$REPO/.githooks-into-gitdir" ]] || _rc=1
assert_true "the into-the-git-dir symlink fixture was created" "$_rc"
write_marker "PASS-FF refs/heads/main $FEATURE_OID"
run_gate "an in-tree symlink INTO the git dir does not inherit its exemption" \
    block "git merge --ff-only $FEATURE_OID" "post-merge hook"
rm -f "$REPO/$ISO_STATE/ref-ff-authorized.local" "$REPO/.githooks-into-gitdir"
git -C "$REPO" config --unset core.hooksPath

# ── A LINKED worktree. --absolute-git-dir there is <common>/worktrees/<name>,
#    but git runs hooks from <common>/hooks - so composing the default by hand
#    names a directory that does not exist, reads as safely outside, and never
#    inspects the shared hook that actually fires. Ask git instead. The default
#    only matters with core.hooksPath unset, and the operator may have a GLOBAL
#    one that would mask it, so HOME is emptied exactly as in the unset case
#    above. ──────────────────────────────────────────────────────────────────
setup_repo lworktree || { printf '  FAIL  fixture setup (linked worktree)\n'; exit 1; }
_SAVED_REPO="$REPO"
_LW="$TMPROOT/lw"
rm -rf "$_LW"
git -C "$REPO" checkout -q feature
git -C "$REPO" worktree add -q "$_LW" main >/dev/null 2>&1
mkdir -p "$REPO/.git/hooks"
# A symlink from the SHARED hooks dir into the linked worktree: content this
# merge lands, executed the moment it completes.
ln -sf "$_LW/tracked-hook" "$REPO/.git/hooks/post-merge"
_lw_abs=$(git -C "$_LW" rev-parse --absolute-git-dir 2>/dev/null) || _lw_abs=""
_lw_common=$(git -C "$_LW" rev-parse --git-common-dir 2>/dev/null) || _lw_common=""
_rc=0
{ [[ -n "$_lw_abs" ]] && [[ "$_lw_abs" != "$_lw_common" ]]; } || _rc=1
assert_true "the linked-worktree fixture really has a per-worktree git dir" "$_rc"
REPO="$_LW"
mkdir -p "$REPO/$ISO_STATE"
export HOME="$_EMPTY_HOME"
write_marker "PASS-FF refs/heads/main $FEATURE_OID"
GATE_CWD="$REPO"
run_gate "the SHARED post-merge hook of a linked worktree is the one inspected" \
    block "git merge --ff-only $FEATURE_OID" "post-merge hook"
unset GATE_CWD
export HOME="$_REAL_HOME"
rm -f "$REPO/$ISO_STATE/ref-ff-authorized.local"
REPO="$_SAVED_REPO"
git -C "$REPO" worktree remove --force "$_LW" >/dev/null 2>&1
rm -rf "$_LW"
setup_repo main || { printf '  FAIL  fixture re-setup (linked worktree)\n'; exit 1; }

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

# A FIFO at the declaration path must not be OPENED and waited on: the 10s hook
# budget would kill the gate with no decision, which is a way through it.
rm -f "$REPO/$ISO_STATE/ref-ff-protected.local"
_rc=0; mkfifo "$REPO/$ISO_STATE/ref-ff-protected.local" 2>/dev/null || _rc=1
assert_true "the FIFO fixture was created (not a vacuous test)" "$_rc"
# BOUNDED deliberately, and not through run_gate: the whole point is that the
# gate must not WAIT on the FIFO. Without O_NONBLOCK it blocks in open() forever,
# and an unbounded assertion would hang the suite instead of failing it.
_rc=0
python3 - "$GATE_SCRIPT" "$REPO" <<'PYEOF' || _rc=$?
import json, os, signal, subprocess, sys
payload = json.dumps({"tool_name": "Bash", "cwd": sys.argv[2],
                      "tool_input": {"command": "git merge feature"}})
# Its own session, and the whole GROUP is killed on timeout. subprocess.run()
# would kill only the bash it started, then block again waiting for the captured
# pipes — which the descendant stuck on the FIFO still holds open — so the guard
# meant to bound this test could hang in its own cleanup, and leave the blocked
# child orphaned after the FIFO is gone.
proc = subprocess.Popen(["bash", sys.argv[1]], stdin=subprocess.PIPE,
                        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                        text=True, start_new_session=True)
try:
    out, _ = proc.communicate(payload, timeout=10)
except subprocess.TimeoutExpired:
    os.killpg(proc.pid, signal.SIGKILL)
    proc.wait()
    sys.exit(2)                       # waited on the FIFO — the bug this pins
sys.exit(0 if "could not be read safely" in out else 1)
PYEOF
assert_true "a FIFO declaration is refused, not blocked on" "$_rc"
rm -f "$REPO/$ISO_STATE/ref-ff-protected.local"

# Bash DISCARDS NUL across a command substitution, so a declaration of nothing
# but NULs arrived as an empty string — indistinguishable from the empty file
# that deliberately says this repo has no protected branch.
printf '\0\0\0' > "$REPO/$ISO_STATE/ref-ff-protected.local"
run_gate "a NUL-only declaration is refused, not read as empty" \
    block "git merge feature" "could not be read safely"
rm -f "$REPO/$ISO_STATE/ref-ff-protected.local"

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

# ── A LITERAL `git -C` is a scope the gate can follow (#812) ─────────
# The alias arm used to refuse ANY scope change beside an unrecognized
# subcommand, so ordinary read-only commands were blocked with a message about
# merge operands. But `_has_unaccounted_global` already exempts a bare `-C` on
# the merge path — a literal target IS the repository git will use — so the gate
# resolves the aliases THERE instead of refusing. Everything it cannot resolve
# statically still fails closed.
setup_repo scoped || { printf '  FAIL  fixture setup (scoped)\n'; exit 1; }
SCOPED_REPO="$REPO"
setup_repo main || { printf '  FAIL  fixture re-setup (scoped)\n'; exit 1; }

run_gate "git -C <literal> worktree list is not a merge" \
    allow "git -C $SCOPED_REPO worktree list"
run_gate "...nor is git -C <literal> branch -a" \
    allow "git -C $SCOPED_REPO branch -a"

# THE proof that the scope is actually used: `zz` is an alias for merge in the
# `-C` repo and does not exist in the session repo. Resolving it against the
# session repo would give the "resolves to neither a git command nor a git alias"
# refusal instead, so the reason string is what distinguishes the two.
git -C "$SCOPED_REPO" config alias.zz merge
run_gate "an alias is resolved in the -C repo, not the session repo" \
    block "git -C $SCOPED_REPO zz feature" "is a git alias reaching"
run_gate "...and the same name in the SESSION repo resolves to nothing" \
    block "git zz feature" "resolves to neither a git command nor a git alias"

# Everything the parser cannot pin to one directory still fails closed.
run_gate "a substituted -C target is still unresolvable" \
    block 'git -C "$(pwd)" worktree list' "cannot be resolved"
run_gate "...and a variable one" \
    block 'git -C $SOMEDIR worktree list' "cannot be resolved"
run_gate "...and a relative one (CDPATH can send it elsewhere)" \
    block "git -C sub worktree list" "cannot be resolved"
run_gate "...and a chained -C, whose later operand may be relative" \
    block "git -C $SCOPED_REPO -C sub worktree list" "cannot be resolved"
run_gate "...and a cd, which the exemption never covered" \
    block "cd $SCOPED_REPO && git worktree list" "cannot be resolved"
run_gate "...and a -C inside a nested payload" \
    block "bash -c 'git -C $SCOPED_REPO zz feature'" "cannot be resolved"
# Two invocations DISAGREEING about the directory is as unresolvable as an opaque
# target: `zz` here runs in the session repo, so anchoring on the -C repo would
# hide the session repo's own alias.
run_gate "...and invocations that disagree about the directory" \
    block "git -C $SCOPED_REPO worktree list && git zz feature" "cannot be resolved"

# The anchor is now a directory the COMMAND names, which makes the "not in a git
# repo → git fails on its own" shortcut reachable on an agent-picked target. It
# does not hold for an unresolved word: a `!`-shell alias is not a git operation,
# git runs it from outside a repository just as happily, and its body can name any
# repo (`alias.zz = !git -C /session merge feature`). Verified: the shell alias
# really does run, and before this guard the plain-directory shape ALLOWED.
mkdir -p "$TMPROOT/not-a-repo"
run_gate "a -C target outside every repo cannot silence the alias arm" \
    block "git -C $TMPROOT/not-a-repo zz feature" "not a work tree"
# ...but a REAL subcommand there is exactly what the shortcut is for: `--list-cmds`
# needs no repository, so the builtin filter still rules it out and git's own
# failure is the honest answer.
run_gate "...while a real subcommand there is still git's own problem" \
    allow "git -C $TMPROOT/not-a-repo worktree list"
# The refusal is scoped to a COMMAND-CHOSEN anchor. When the gate derived the
# anchor itself — the session simply runs outside every repo — the original
# unconditional exit stands, or an ordinary global alias (`git lg`, not a builtin,
# so an unknown candidate) would block with no escape hatch: a skip file inside a
# non-repo directory is not something the tooling describes. #812 never touched
# this shape, and the guard above must not either.
NOREPO_HOLDER="$REPO"
REPO="$TMPROOT/not-a-repo"
run_gate "an unknown word from a non-repo cwd is untouched (no -C chose it)" \
    allow "git lg -1"
REPO="$NOREPO_HOLDER"
# A BARE repo answers exit-0 `false` to --is-inside-work-tree, so it resolves
# `proceed` rather than `outside-repo` and is refused by the ordinary alias path.
# CLONED, not `init --bare`: a freshly-initialised bare repo has no branches, so
# it would block at the "cannot identify a protected branch" exit instead and the
# case would pass without ever reaching the path it documents.
git clone -q --bare "$SCOPED_REPO" "$TMPROOT/bare-scoped"
git -C "$TMPROOT/bare-scoped" config alias.zz merge
run_gate "...and a bare repo is refused by the ordinary alias path" \
    block "git -C $TMPROOT/bare-scoped zz feature" "is a git alias reaching"

git -C "$SCOPED_REPO" config --unset alias.zz

# Consent is per-repo. A command-chosen anchor must not spend the consent
# artifacts of the repository it points at, because a `!`-shell alias resolved
# there acts on whichever repository its body names — the same consent/effect
# divergence as the outside-repo case, reached through a real work tree.
#
# The empty declaration is the leg that can be exercised here (the skip file is
# the other, and is the operator's to create). Reaching it needs a repo whose
# PROTECTED_SET really is empty, so the fixture has NO conventional branch and no
# remote: discovery finds nothing, and the empty file is then the whole answer.
NOCONV="$TMPROOT/noconv"
rm -rf "$NOCONV"
(
    set -e
    git init -q -b wip "$NOCONV"
    cd "$NOCONV"
    git config user.email t@t; git config user.name t
    git config commit.gpgsign false
    echo base > f; git add f; git commit -qm base
) >/dev/null 2>&1 || { printf '  FAIL  fixture setup (noconv)\n'; FAIL=$((FAIL + 1)); }
mkdir -p "$NOCONV/$ISO_STATE"
: > "$NOCONV/$ISO_STATE/ref-ff-protected.local"
run_gate "a command-chosen anchor cannot spend that repo's empty declaration" \
    block "git -C $NOCONV zz feature" "chose its own anchor"
# A literal no-op merge does not launder the unresolved word riding behind it.
# Keying the guard on an empty KIND left exactly this hole: KIND is `merge`, so
# the anchor looked gate-derived and the declaration was spent as before.
run_gate "...and a literal no-op merge alongside it does not launder the word" \
    block "git -C $NOCONV merge HEAD && git -C $NOCONV zz feature" "chose its own anchor"
# The same divergence one step away: when the LITERAL merge carries no `-C`, the
# scan matches it first and target_dir is empty, so the gate would anchor on the
# cwd — spending the cwd repo's consent while `zz` resolves in $NOCONV. The alias
# scope is therefore decided for the whole command, not only when no literal
# merge/pull was found.
run_gate "...and a cwd-scoped merge does not launder a -C-scoped word either" \
    block "git merge HEAD && git -C $NOCONV zz feature" "cannot be resolved"
# ...but a plain `cd` must not poison the LITERAL-merge path. There the scan
# already folds a trusted '&&'-joined cd into the match's own target_dir, so
# re-refusing it here only flipped this to a block and explained it with the
# merge-operand message rather than the companion one — which is the
# wrong-explanation class #812 was filed about. (`fetch` is an alias candidate,
# so this command reaches the scope check at all.)
run_gate "a leading cd still only scopes a literal merge, as its message says" \
    block "cd $REPO && git fetch origin && git merge feature" "SEPARATE call"
# ...and the exemption buys the LEADING cd only. A cd AFTER the merge is folded
# into neither target_dir nor untrusted_cd (the scan matched before reaching it),
# so nothing but the companion refusal would see it — and that sits after the
# consent exits, so an armed skip file would have waved it through while `zz`
# resolved elsewhere.
run_gate "...but a cd AFTER the merge still poisons the alias scope" \
    block "git merge HEAD && cd $NOCONV && git zz feature" "cannot be resolved"
# The exempted cd is also the SCOPE of every invocation that carries no `-C`, so
# an equivalent absolute `-C` agrees with it rather than reading as a second,
# conflicting directory. Blocked here by the companion refusal — the accurate
# reason — not by an unresolvable-operand message.
run_gate "an equivalent -C agrees with the exempted leading cd" \
    block "cd $REPO && git merge HEAD && git -C $REPO zz feature" "ALONGSIDE"
# The inferred scope is the MAIN chunk's only. A nested chunk's ordering against
# the cd is not decidable here, and a redirection attached to the cd runs BEFORE
# the directory changes, so attributing the nested git to the cd target would be
# a guess in the fail-OPEN direction.
run_gate "...but the inferred scope never reaches a nested chunk" \
    block "cd $REPO && git merge HEAD && bash -c 'git zz feature'" "cannot be resolved"
# The scope tests carry the upstream arm's QUALIFIER as well as its tests. Without
# it a global on a read-safe subcommand poisoned the whole command whenever any
# alias candidate appeared elsewhere — and bought nothing, since all three tests
# are per-invocation.
run_gate "a global on a read-safe subcommand does not poison the command" \
    allow "git --no-pager diff && git add -A"
run_gate "...nor does a -c on one" \
    allow "git -c color.ui=false log && git add -A"
# The anchor a command names can BE the session's own repo, and then consent and
# effect do not diverge — the escape hatch must not depend on whether the
# operator typed a redundant `-C`.
NOCONV_HOLDER="$REPO"
REPO="$NOCONV"
run_gate "...and a -C naming the session's own repo is not command-chosen" \
    allow "git -C $NOCONV zz feature"
REPO="$NOCONV_HOLDER"
# ...while the same file still speaks for the repo the session is actually IN,
# which is where the operator wrote it. This is the pre-#812 behaviour and the
# guard above must not disturb it.
NOCONV_HOLDER="$REPO"
REPO="$NOCONV"
run_gate "...but the same declaration is honoured for the session's own repo" \
    allow "git zz feature"
REPO="$NOCONV_HOLDER"
rm -f "$NOCONV/$ISO_STATE/ref-ff-protected.local"

printf '\nRESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
