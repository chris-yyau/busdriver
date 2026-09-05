#!/bin/bash
# State-transition coverage for clear_stale_abort_state (#622).
#
# Every bug this cleanup shipped with was a state COLLAPSE — two situations that
# want opposite handling reaching the same branch. It refused an orphan spent
# record and bricked the repository; it consumed a marker no claim bound; it
# treated a structurally invalid file and a later /litmus mint as the same
# thing. Single end-to-end merges in test-merge-commit-gate.sh cover the paths
# a real merge takes; this file walks the state MATRIX instead, because that is
# where the collapses live. The claim states it covers: absent (2 cases), present
# and ARMED (4, one per marker state), and present but NOT armed (2 — the
# anti-forgery branch and its recovery, the latter twice — once with a
# consumable token and once with a structurally invalid one, which is the only
# way the recovery's marker-disposition flag becomes observable).
#
# Two invariants hold across every state that returns success, and they are the
# whole point:
#   (1) it never leaves the claim armed — an armed claim with no way to retire
#       it refuses every later refs/heads update in the repository;
#   (2) it never destroys a well-formed token belonging to a LATER review.
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

# Inherited repository-selecting git environment cannot be allowed to reach the
# fixtures below. `git -C <dir>` does NOT override it: GIT_INDEX_FILE makes a
# fixture's `git add` write ANOTHER repository's index, GIT_DIR and GIT_WORK_TREE
# redirect the operation outright, and the object-directory pair can leave a fixture
# referencing objects its own cleanup then deletes. A fixture core.hooksPath does not
# override them either. Same guard as tests/test-merge-commit-gate.sh -- kept as a
# local function in each suite so every suite stays runnable on its own, which is how
# they are invoked. A FUNCTION, not a bare `unset`, so the containment case below can
# plant hostile values and re-apply it.
_neutralize_git_env() {
    unset GIT_INDEX_FILE GIT_DIR GIT_WORK_TREE GIT_OBJECT_DIRECTORY \
          GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR
    # ...and the COMMAND-LEVEL config injectors, which the six above do not cover.
    # `GIT_CONFIG_COUNT` + `GIT_CONFIG_KEY_n`/`GIT_CONFIG_VALUE_n` (and the older
    # `GIT_CONFIG_PARAMETERS`) inject settings into EVERY git invocation at a
    # precedence above the repository file, so an inherited core.hooksPath sends a
    # fixture install into an external hooks directory that the fixture never names
    # -- measured, not assumed. Unsetting COUNT is what disables the indexed pairs:
    # git reads KEY_n/VALUE_n only up to COUNT, so the pairs need no enumeration.
    unset GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS GIT_CONFIG
}
_neutralize_git_env
REPO_ROOT="$PWD"
LIB="$REPO_ROOT/hooks/gate-scripts/lib"
PASS=0
FAIL=0

assert() {
    local name="$1" want="$2" got="$3"
    if [[ "$want" == "$got" ]]; then
        printf '  PASS  %s\n' "$name"
        PASS=$((PASS + 1))
    else
        printf '  FAIL  %s (expected=%s got=%s)\n' "$name" "$want" "$got"
        FAIL=$((FAIL + 1))
    fi
}

# Containment: prove the guard, do not assume the caller's environment was clean.
# Asserting the six variables are empty passes vacuously on exactly the runs where
# this defect is invisible, so plant hostile values and re-apply the guard on top.
_TMP_CONTAIN=$(mktemp -d)
(
  cd "$_TMP_CONTAIN" && git init -q r && cd r \
    && git config user.email t@t && git config user.name t \
    && git config commit.gpgsign false \
    && echo x > x && git add x && git commit -q -m contained
) >/dev/null 2>&1
_CONTAIN_REAL=$(cd "$_TMP_CONTAIN" && pwd -P)
_CONTAIN_GD=$(
    export GIT_DIR="$_TMP_CONTAIN/hostile-gitdir" \
           GIT_INDEX_FILE="$_TMP_CONTAIN/hostile-index" \
           GIT_WORK_TREE="$_TMP_CONTAIN/hostile-worktree" \
           GIT_OBJECT_DIRECTORY="$_TMP_CONTAIN/hostile-objects" \
           GIT_ALTERNATE_OBJECT_DIRECTORIES="$_TMP_CONTAIN/hostile-alt" \
           GIT_COMMON_DIR="$_TMP_CONTAIN/hostile-common"
    _neutralize_git_env
    cd "$_TMP_CONTAIN/r" && { git rev-parse --absolute-git-dir 2>/dev/null || true; }
)
case "$_CONTAIN_GD" in
    "$_CONTAIN_REAL"/r/.git) assert "a fixture resolves its own git dir despite a hostile inherited env" "contained" "contained" ;;
    *) assert "a fixture resolves its own git dir despite a hostile inherited env" "contained" "${_CONTAIN_GD:-<unresolvable>}" ;;
esac
_CONTAIN_STAGED=$(
    export GIT_INDEX_FILE="$_TMP_CONTAIN/hostile-index"
    _neutralize_git_env
    git -C "$_TMP_CONTAIN/r" diff --cached --name-only 2>/dev/null | tr '\n' ' '
)
assert "a staged write goes to the fixture index, not an inherited one" "" "$_CONTAIN_STAGED"

# ...and a command-level injector cannot override the fixture's OWN config. The
# fixture sets a local core.hooksPath first: reading an unset key would fall
# through to the machine's global config and prove nothing about the injector.
git -C "$_TMP_CONTAIN/r" config core.hooksPath "$_TMP_CONTAIN/fixture-hooks"
_CONTAIN_HOOKS=$(
    export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath \
           GIT_CONFIG_VALUE_0="$_TMP_CONTAIN/EXTERNAL-hooks"
    _neutralize_git_env
    git -C "$_TMP_CONTAIN/r" config --get core.hooksPath 2>/dev/null || echo "<unreadable>"
)
assert "an inherited GIT_CONFIG_COUNT cannot redirect core.hooksPath" \
    "$_TMP_CONTAIN/fixture-hooks" "$_CONTAIN_HOOKS"
rm -rf "$_TMP_CONTAIN"

WORK=$(mktemp -d) || exit 1
trap 'rm -rf "$WORK"' EXIT

echo "── clear_stale_abort_state state matrix ─"

# Every case the harness must report. A harness that dies before printing —
# ImportError, a git that is not installed, a typo at module scope — writes
# nothing to stdout, and a read loop over nothing runs ZERO assertions and exits
# 0. That is the failure this file exists to catch, so it is checked below
# rather than assumed.
EXPECTED_CASES=9

RESULTS=$(python3 -I - "$LIB" "$WORK" <<'PYEOF'
import os
import subprocess
import sys

LIB, WORK = sys.argv[1], sys.argv[2]
sys.path.insert(0, LIB)
import merge_pending as mp  # noqa: E402

EXACT = "BUILTIN-" + "b" * 64
OTHER = "BUILTIN-" + "c" * 64


def git(repo, *args):
    """check=True on purpose: nothing here runs a git command that may fail, so a
    failure is a broken harness, not a case outcome. Swallowing it would hand an
    empty OID or git-dir to the callers below, and os.path.join with an empty
    first component resolves against the PROCESS cwd — writing gate state
    outside WORK, where the cleanup trap will not find it."""
    return subprocess.run(
        ["git", "-C", repo] + list(args),
        capture_output=True, text=True, check=True,
    )


def new_repo(name):
    repo = os.path.join(WORK, name)
    os.makedirs(os.path.join(repo, ".claude"))
    git(repo, "init", "-q", "-b", "main")
    git(repo, "config", "user.email", "t@example.com")
    git(repo, "config", "user.name", "t")
    # Match setup_repo() in test-merge-commit-gate.sh: a host that signs commits
    # by default, or points core.hooksPath at its own hooks, would otherwise
    # change or break fixture creation before any case runs — and git() is
    # check=True, so that surfaces as a harness crash rather than a case result.
    git(repo, "config", "commit.gpgsign", "false")
    git(repo, "config", "tag.gpgsign", "false")
    # This suite drives clear_stale_abort_state directly and wants NO gate hooks
    # firing during setup; an empty dir is the portable way to say that.
    empty_hooks = os.path.join(repo, ".empty-hooks")
    os.makedirs(empty_hooks, exist_ok=True)
    git(repo, "config", "core.hooksPath", empty_hooks)
    with open(os.path.join(repo, "f.txt"), "w") as fh:
        fh.write("one\n")
    git(repo, "add", "f.txt")
    git(repo, "commit", "-q", "-m", "base")
    return repo


def marker_path(repo):
    return os.path.join(repo, ".claude", "litmus-passed.local")


def write_marker(repo, content):
    with open(marker_path(repo), "w") as fh:
        fh.write(content + "\n")


def arm(repo):
    """Mint a real claim + arm through the module's own writer."""
    write_marker(repo, EXACT)
    head = git(repo, "rev-parse", "HEAD").stdout.strip()
    return mp.write_claim(repo, ".claude", head, EXACT)


def state(repo):
    gd = git(repo, "rev-parse", "--absolute-git-dir").stdout.strip()
    return {
        "claim": os.path.exists(os.path.join(repo, ".claude", mp.PENDING)),
        "armed": os.path.exists(os.path.join(gd, mp.ARMED_GIT)),
        # SPENT is the one file whose SURVIVAL re-creates #622's permanent block:
        # it outlives the retirement, HEAD moves, _spent_names_tip goes false, and
        # every later refs/heads update is refused. Leaving it out of this dict
        # made the retirement cases pass against a _finish_published_cleanup that
        # never unlinked it.
        "spent": os.path.exists(os.path.join(gd, mp.SPENT_GIT)),
        "marker": (
            open(marker_path(repo)).read().strip()
            if os.path.exists(marker_path(repo)) else None
        ),
    }


def case(name, build, want_rc, want):
    repo = new_repo(name)
    if not build(repo):
        print("%s|setup-failed" % name)
        return
    try:
        rc = mp.clear_stale_abort_state(repo, ".claude")
    except Exception as exc:  # a raise is itself a finding
        print("%s|raised:%s" % (name, type(exc).__name__))
        return
    got = state(repo)
    if rc is not want_rc:
        print("%s|rc=%s" % (name, rc))
        return
    for key, expected in want.items():
        if got[key] != expected:
            print("%s|%s=%r" % (name, key, got[key]))
            return
    print("%s|ok" % name)


def armed_with(mutate):
    def build(repo):
        if not arm(repo):
            return False
        mutate(repo)
        return True
    return build


def noop(repo):
    pass


def make_foreign(repo):
    write_marker(repo, OTHER)


def make_multilink(repo):
    os.link(marker_path(repo), marker_path(repo) + ".copy")


def remove_marker(repo):
    os.unlink(marker_path(repo))


def forge_claim(repo):
    """Rewrite the claim's marker line so it no longer matches the live ARM.

    The arm was minted over the ORIGINAL payload, so a claim naming different
    marker content cannot reproduce it: _is_armed goes false and the anti-forgery
    branch is reached. The matching token is put on disk too, so the case cannot
    pass merely because no marker was there — it has to be the ARM check that
    refuses, not the marker lookup.
    """
    claim = os.path.join(repo, ".claude", mp.PENDING)
    with open(claim) as fh:
        lines = fh.read().split("\n")
    lines[1] = OTHER
    with open(claim, "w") as fh:
        fh.write("\n".join(lines))
    write_marker(repo, OTHER)


def forge_claim_with_spent(repo):
    forge_claim(repo)
    gd = git(repo, "rev-parse", "--absolute-git-dir").stdout.strip()
    head = git(repo, "rev-parse", "HEAD").stdout.strip()
    with open(os.path.join(gd, mp.SPENT_GIT), "w") as fh:
        fh.write(head + "\n")


def forge_claim_with_spent_multilink(repo):
    """Recovery, but the token is structurally invalid rather than consumable.

    Without this the recovery branch's drop_invalid is decided by nothing: its
    only other case has a marker whose content MATCHES the forged claim, so the
    token is removed by _finish_marker_consume and drop_invalid is False either
    way. A multi-linked marker is the one shape that makes the flag observable.
    """
    forge_claim_with_spent(repo)
    os.link(marker_path(repo), marker_path(repo) + ".copy")


def orphan_spent(at_tip):
    def build(repo):
        gd = git(repo, "rev-parse", "--absolute-git-dir").stdout.strip()
        # A marker IS on disk for both, and no claim binds it. That is the whole
        # point: the branch under test decides on the protected spent record
        # ALONE, so an unrelated token must neither swing the decision nor be
        # destroyed by it. Without a marker here the at-tip branch's
        # unlink_marker=False is asserted by nothing.
        write_marker(repo, OTHER)
        if at_tip:
            oid = git(repo, "rev-parse", "HEAD").stdout.strip()
        else:
            tree = git(repo, "rev-parse", "HEAD^{tree}").stdout.strip()
            oid = git(repo, "commit-tree", tree, "-m", "elsewhere").stdout.strip()
        with open(os.path.join(gd, mp.SPENT_GIT), "w") as fh:
            fh.write(oid + "\n")
        return bool(oid)
    return build


# An armed claim retires in every marker state, and what happens to the FILE is
# the part that differs: this claim's own token is spent, a later mint survives
# untouched, and a file that is not a valid one-use token is removed so the
# pathname-reading consumption path cannot spend it afterwards.
case("armed-exact", armed_with(noop), True,
     {"claim": False, "armed": False, "spent": False, "marker": None})
case("armed-foreign", armed_with(make_foreign), True,
     {"claim": False, "armed": False, "spent": False, "marker": OTHER})
case("armed-multilink", armed_with(make_multilink), True,
     {"claim": False, "armed": False, "spent": False, "marker": None})
case("armed-absent", armed_with(remove_marker), True,
     {"claim": False, "armed": False, "spent": False, "marker": None})

# Claim present but NOT armed. A claim whose payload the protected arm does not
# reproduce is a FORGERY, and refusing it is the whole point of the arm — but
# refusing must also leave the forger's chosen token alone, or a forged claim
# becomes a way to destroy someone else's review. The recovery half is narrow and
# has to stay narrow: only spent naming the live tip reopens it.
case("unarmed-claim-forged", armed_with(forge_claim), False,
     {"claim": True, "marker": OTHER})
case("unarmed-claim-forged-spent-at-tip", armed_with(forge_claim_with_spent), True,
     {"claim": False, "armed": False, "spent": False, "marker": None})
case("unarmed-claim-forged-spent-at-tip-multilink",
     armed_with(forge_claim_with_spent_multilink), True,
     {"claim": False, "armed": False, "spent": False, "marker": None})

# No claim at all. The protected spent record decides alone — never the marker,
# which the gated party can create.
case("orphan-spent-at-tip", orphan_spent(True), True,
     {"claim": False, "armed": False, "spent": False, "marker": OTHER})
case("orphan-spent-non-tip", orphan_spent(False), False,
     {"spent": True, "marker": OTHER})
PYEOF
)

PY_RC=$?

REPORTED=$(grep -c '|' <<< "$RESULTS")
if [[ "$PY_RC" -ne 0 || "$REPORTED" -ne "$EXPECTED_CASES" ]]; then
    assert "the harness reported every case" \
        "rc=0 cases=$EXPECTED_CASES" "rc=$PY_RC cases=$REPORTED"
    printf '%s\n' "$RESULTS" | sed 's/^/    /'
fi

while IFS='|' read -r name outcome; do
    [[ -z "$name" ]] && continue
    assert "$name" "ok" "$outcome"
done <<< "$RESULTS"

printf '\nResults: %d/%d passed\n' "$PASS" "$((PASS + FAIL))"
[[ "$FAIL" -eq 0 ]] || exit 1
