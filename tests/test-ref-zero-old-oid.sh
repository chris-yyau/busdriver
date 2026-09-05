#!/usr/bin/env bash
# Focused regression for issue #780 — ZERO-old-oid create vs force-update.
#
# At reference-transaction prepared, force-update and create both report
# old-oid=ZERO. The shared discriminator is prepared-time / pre-command
# `git rev-parse --verify` (githooks(5)): absent ⇒ genuine create (allow);
# present ⇒ force-update (abort). Deletes of protected refs abort so
# delete-then-recreate cannot re-mint the name.
#
# Covers: branch -f, checkout -B, update-ref without oldvalue, delete/recreate,
# and both files + reftable backends where supported.
#
# Usage: bash tests/test-ref-zero-old-oid.sh

# shellcheck disable=SC2310
set -uo pipefail
cd "$(dirname "$0")/.."
REPO_ROOT="$(pwd)"
GATE_SCRIPT="$REPO_ROOT/hooks/gate-scripts/ref-ff-gate.sh"

PASS=0
FAIL=0

ISO_STATE=".claude-test-780-$$"
export BUSDRIVER_STATE_DIR="$ISO_STATE"

TMPROOT=$(mktemp -d) || { printf 'could not create temp dir\n' >&2; exit 1; }
trap 'rm -rf "$TMPROOT"' EXIT

supports_reftable() {
    local d="$TMPROOT/reftable-probe"
    rm -rf "$d"
    git init -q -b main --ref-format=reftable "$d" 2>/dev/null || return 1
    rm -rf "$d"
    return 0
}

setup_repo() {  # <tag> <ref-format>
    local tag="$1" fmt="$2"
    REPO="$TMPROOT/repo-$tag"
    rm -rf "$REPO"
    (
        set -e
        if [ "$fmt" = reftable ]; then
            git init -q -b main --ref-format=reftable "$REPO"
        else
            # Default backend is files; avoid --ref-format=files (Git >= 2.45 only).
            git init -q -b main "$REPO"
        fi
        cd "$REPO"
        git config user.email t@t; git config user.name t
        git config commit.gpgsign false; git config tag.gpgsign false
        # Isolate from ambient core.hooksPath (e.g. ~/.codex/git-hooks).
        git config core.hooksPath "$(pwd)/.git/hooks"
        echo base > f; git add f; git commit -qm base
        echo next >> f; git add f; git commit -qm next
        UNREVIEWED=$(git rev-parse HEAD)
        git reset -q --hard HEAD~1
        git branch unreviewed "$UNREVIEWED"
        mkdir -p "$ISO_STATE"
    ) >/dev/null 2>&1 || return 1
    UNREVIEWED=$(git -C "$REPO" rev-parse unreviewed)
    REVIEWED=$(git -C "$REPO" rev-parse main)
}

run_gate() {  # <name> <expected: allow|block> <command> [reason substring]
    local name="$1" expected="$2" cmd="$3" want_reason="${4:-}"
    local payload output exit_code got
    payload=$(python3 -c '
import json, sys
print(json.dumps({"tool_name": "Bash", "cwd": sys.argv[1],
                  "tool_input": {"command": sys.argv[2]}}))' "$REPO" "$cmd")
    output=$(cd "$REPO_ROOT" && printf '%s' "$payload" | bash "$GATE_SCRIPT" 2>/dev/null) && exit_code=0 || exit_code=$?
    got="allow"
    if [[ "$exit_code" -ne 0 ]] && [[ -z "$output" ]]; then
        got="crash"
    elif echo "$output" | grep -q '"block"' 2>/dev/null; then
        got="block"
    fi
    if [[ "$got" != "$expected" ]]; then
        printf "  FAIL  %s (expected=%s got=%s)\n" "$name" "$expected" "$got"
        printf "         output=%s\n" "$output"
        FAIL=$((FAIL + 1))
        return
    fi
    if [[ -n "$want_reason" ]] && ! grep -qF "$want_reason" <<<"$output"; then
        printf "  FAIL  %s (blocked, but reason missing %q)\n" "$name" "$want_reason"
        FAIL=$((FAIL + 1)); return
    fi
    printf "  PASS  %s\n" "$name"; PASS=$((PASS + 1))
}

# Install a reference-transaction hook that uses the SAME discriminator the
# gate does, so files/reftable backends are exercised at the documented layer.
install_rt_hook() {
    local hookdir
    # MUST NOT use `git rev-parse --git-path hooks`: ambient core.hooksPath
    # (this machine points it at the primary checkout) would install into the
    # SHARED hooks dir and poison every other suite. Pin the repo-local path.
    hookdir="$REPO/.git/hooks"
    if [ -f "$REPO/.git" ]; then
        # linked worktree — read gitdir file; tests use plain inits only
        hookdir=$(git -C "$REPO" rev-parse --absolute-git-dir)/hooks
    fi
    # Neutralize hooksPath for THIS fixture so git runs the local hook.
    git -C "$REPO" config --local core.hooksPath "$hookdir"
    mkdir -p "$hookdir"
    cat > "$hookdir/reference-transaction" <<'HOOK'
#!/bin/bash
phase=$1
[ "$phase" = prepared ] || exit 0
while read -r old new ref; do
    case "$ref" in
        refs/heads/*) ;;
        *) continue ;;
    esac
    zero=0000000000000000000000000000000000000000
    zero64=0000000000000000000000000000000000000000000000000000000000000000
    # Delete of any heads ref (new=ZERO): abort — same as the gate for protected
    # names; here we exercise the discriminator for all heads.
    if [ "$new" = "$zero" ] || [ "$new" = "$zero64" ]; then
        echo "ref-zero-old-oid: refuse delete of $ref" >&2
        exit 1
    fi
    if [ "$old" = "$zero" ] || [ "$old" = "$zero64" ]; then
        if git rev-parse --verify --quiet "$ref" >/dev/null 2>&1; then
            echo "ref-zero-old-oid: refuse force-update of $ref (pre-image exists)" >&2
            exit 1
        fi
        # absent ⇒ genuine create — allow
    fi
done
exit 0
HOOK
    chmod +x "$hookdir/reference-transaction"
}

assert_git_fails() {  # <name> <git args...>
    local name="$1"; shift
    if git -C "$REPO" "$@" >/dev/null 2>&1; then
        printf "  FAIL  %s (git succeeded, expected abort)\n" "$name"
        FAIL=$((FAIL + 1))
    else
        printf "  PASS  %s\n" "$name"
        PASS=$((PASS + 1))
    fi
}

assert_git_ok() {  # <name> <git args...>
    local name="$1"; shift
    if git -C "$REPO" "$@" >/dev/null 2>&1; then
        printf "  PASS  %s\n" "$name"
        PASS=$((PASS + 1))
    else
        printf "  FAIL  %s (git failed, expected success)\n" "$name"
        FAIL=$((FAIL + 1))
    fi
}

run_format_suite() {  # <format>
    local fmt="$1"
    printf '\n=== #780 ZERO-old-oid (%s) ===\n' "$fmt"
    setup_repo "$fmt" "$fmt" || { printf "  FAIL  fixture setup (%s)\n" "$fmt"; FAIL=$((FAIL + 1)); return; }

    # PreToolUse gate — the shipped observation point (same machinery as #779).
    run_gate "branch -f main → block" \
        block "git branch -f main $UNREVIEWED" "force-updates a branch ref with no old-oid precondition"
    run_gate "checkout -B main → block" \
        block "git checkout -B main $UNREVIEWED" "force-updates a branch ref with no old-oid precondition"
    run_gate "update-ref without oldvalue → block" \
        block "git update-ref refs/heads/main $UNREVIEWED" "force-updates a branch ref with no old-oid precondition"
    run_gate "branch -D main → block (closes delete-recreate)" \
        block "git branch -D main" "DELETE the protected branch"
    run_gate "delete then recreate in one call → block on delete" \
        block "git branch -D main && git branch main $UNREVIEWED" "issue #780"
    run_gate "genuine create of newbranch → allow" \
        allow "git branch newbranch $UNREVIEWED"
    # A three-operand update-ref is only exempt when its oldvalue pins CONTENT.
    # git resolves that operand as a rev, so naming the ref itself reads main's
    # CURRENT value as its own precondition -- the CAS is vacuous and the
    # force-update lands (measured against real git, not inferred).
    run_gate "self-referential CAS is not a precondition" \
        block "git update-ref refs/heads/main $UNREVIEWED refs/heads/main" \
        "no old-oid precondition"
    run_gate "...nor is a bare branch name" \
        block "git update-ref refs/heads/main $UNREVIEWED main" \
        "no old-oid precondition"
    run_gate "...nor HEAD" \
        block "git update-ref refs/heads/main $UNREVIEWED HEAD" \
        "no old-oid precondition"
    # ...and a hex operand of the WRONG length for this repo's object format is
    # not an object name either: git sends it through ref DWIM, so a 64-hex
    # BRANCH NAME in a sha1 repo resolves to that branch and the CAS goes vacuous
    # (measured). A fixed (40, 64) predicate would have accepted it.
    HEX64=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    [ "${#HEX64}" -eq 64 ] || { printf '  FAIL  HEX64 literal is not 64 chars\n'; FAIL=$((FAIL + 1)); }
    git -C "$REPO" branch "$HEX64" main
    run_gate "...nor a wrong-length hex operand that is really a branch" \
        block "git update-ref refs/heads/main $UNREVIEWED $HEX64" \
        "no old-oid precondition"
    git -C "$REPO" branch -D "$HEX64" >/dev/null 2>&1
    # ...and the null-oid create CAS is the same rule, not an exception: zeros
    # are hex, so a 64-zero operand in a sha1 repo is a ref DWIM lookup for a
    # branch that can be named exactly that -- not "the ref must be absent".
    ZERO64=0000000000000000000000000000000000000000000000000000000000000000
    [ "${#ZERO64}" -eq 64 ] || { printf '  FAIL  ZERO64 literal is not 64 chars\n'; FAIL=$((FAIL + 1)); }
    git -C "$REPO" branch "$ZERO64" main
    run_gate "...nor a wrong-length ALL-ZERO operand" \
        block "git update-ref refs/heads/main $UNREVIEWED $ZERO64" \
        "no old-oid precondition"
    git -C "$REPO" branch -D "$ZERO64" >/dev/null 2>&1
    run_gate "...while the right-length create CAS is still allowed" \
        allow "git update-ref refs/heads/main $UNREVIEWED 0000000000000000000000000000000000000000"
    # The dashed spelling is not a laundering route: `git-branch -f main
    # <rev>` is still a porcelain force, and a trailing operand that merely
    # LOOKS like another dashed command (`git-status` is a legal rev name) does
    # not re-read the invocation as that safe subcommand.
    run_gate "the dashed form is not laundered by a git-* looking operand" \
        block "git-branch -f main git-status" "no old-oid precondition"
    # A companion is the only thing that could swap the repository under the
    # object-format read, and it forfeits the CAS exemption before it gets the
    # chance -- so the format read has no TOCTOU window to exploit.
    run_gate "a companion forfeits the CAS exemption too" \
        block "ln -sfn /other $REPO && git update-ref refs/heads/main $UNREVIEWED $REVIEWED" \
        "issue #780"
    # A lowercase copy is not a force: it refuses an existing destination and
    # leaves the source alone, so no ref this gate guards can move. `-C` can
    # overwrite one, and `-m` DELETES the source even unforced -- both stay in.
    run_gate "a plain branch copy is not a force" \
        allow "git branch -c topic topic-copy"
    run_gate "...but the forcing copy is" \
        block "git branch -C topic main" "no old-oid precondition"
    run_gate "...and an unforced rename is, because it deletes the source" \
        block "git branch -m main renamed" "no old-oid precondition"
    # ── Not this gate's business ────────────────────────────────────────
    # The wrapper-fallback arm exists for ONE shape (a git invocation hidden
    # behind a wrapper). Its heuristics are English words and common flags, so
    # without the "segment names git" qualifier it refused ordinary commands —
    # including the PR workflow's own `gh pr checkout`.
    run_gate "gh pr checkout is not a protected-ref force" \
        allow "gh pr checkout 828"
    run_gate "...nor is an npm script called switch" allow "npm run switch"
    run_gate "...nor is the word checkout in an echo" allow "echo checkout"
    run_gate "...nor a variable-bearing rm" allow "rm -rf \$TMPDIR/x"
    run_gate "...nor a pipeline that greps for branch" \
        allow "git status | grep branch"
    # A force-ish flag on a subcommand that cannot write refs/heads/* is not a
    # ZERO-old op either; only `worktree add` can, of the ones outside the
    # modelled set (measured: `git worktree add -B main <path> <oid>` moves main).
    run_gate "git add -f is not a branch force" allow "git add -f path"
    run_gate "...nor git clean -fd" allow "git clean -fd"
    run_gate "...nor git tag -f" allow "git tag -f v1"
    run_gate "...nor removing a worktree" allow "git worktree remove -f /tmp/wt"
    # On `worktree add`, `-f` only permits checking out a branch already checked
    # out elsewhere -- it writes no ref. Only `-B` resets one, so the generic
    # force-flag net does not apply to this subcommand.
    run_gate "...nor worktree add -f, which resets no ref" \
        allow "git worktree add -f /tmp/wt-780f main"
    run_gate "...nor worktree add -b, which refuses an existing branch" \
        allow "git worktree add -b fresh-780 /tmp/wt-780b main"
    run_gate "...but worktree add -B is" \
        block "git worktree add -B main /tmp/wt-780 $UNREVIEWED" \
        "no old-oid precondition"
    run_gate "...including inside a short cluster" \
        block "git worktree add -fB main /tmp/wt-780c $UNREVIEWED" \
        "no old-oid precondition"
    # An operand the gate cannot READ is not a safe one — either of these
    # executes `worktree add -B`. Same rule the modelled subcommands already
    # apply (`git branch "$X" main` blocks), and it stays keyed to the verb.
    run_gate "...and an unreadable flag operand is not a missing -B" \
        block "git worktree add \"\${FLAG:--B}\" main /tmp/wt-780d HEAD" \
        "no old-oid precondition"
    run_gate "...nor is an unreadable verb a missing add" \
        block "git worktree \"\$VERB\" -B main /tmp/wt-780e HEAD" \
        "no old-oid precondition"
    run_gate "...but a literal verb that resets no ref still reads as itself" \
        allow "git worktree remove \"\$WTDIR\""
    # Everything after `--` is positional, so an unreadable token there cannot
    # be the -B this fails closed on.
    run_gate "...and an unreadable operand after -- is a path, not a flag" \
        allow "git worktree add -- \"\$WTPATH\" main"
    run_gate "...at either position" \
        allow "git worktree add -- /tmp/wt-780i \"\$REV\""
    run_gate "...while a -B before it still counts" \
        block "git worktree add -B main -- /tmp/wt-780j" \
        "no old-oid precondition"
    # A command word that is a substitution runs SOMETHING; nothing in argv says
    # it is not git. It keeps the wrapper-fallback arm alive -- but only through
    # the subcommand-word disjunct, so an ordinary dynamic invocation stays out.
    run_gate "a dynamically named git is still git" \
        block "GIT=git; \"\$GIT\" branch -f main $UNREVIEWED" \
        "no old-oid precondition"
    run_gate "...unquoted too" \
        block "GIT=git; \$GIT update-ref -d refs/heads/main" \
        "no old-oid precondition"
    # ...and behind a wrapper, which is the shape this whole arm exists for:
    # the dynamic name may sit at any index BEFORE the subcommand word.
    run_gate "...and behind a wrapper" \
        block "xargs -I{} \"\$GIT\" branch -f main $UNREVIEWED" \
        "no old-oid precondition"
    run_gate "...and after env" \
        block "env \"\$GIT\" update-ref -d refs/heads/main" \
        "no old-oid precondition"
    run_gate "...but a dynamic command word alone is not a ref write" \
        allow "\"\$PYTHON\" -m pytest -x tests/"
    # A substitution AFTER the word is an operand, not an executable.
    run_gate "...nor is a grep whose path is a variable" \
        allow "grep -rn branch \$DIR"
    # A literal `git` only counts where an EXECUTABLE can stand. Matching it at
    # any index read these two as protected-ref force-updates (measured).
    run_gate "...nor is the word git inside an echo" allow "echo git branch"
    run_gate "...nor git as a grep operand" allow "grep branch git"
    # Same question asked of a DYNAMIC token: an argument is not an executable
    # just because it cannot be read.
    run_gate "...nor a variable echoed in front of the word branch" \
        allow "echo \"\$X\" branch -f main HEAD"
    run_gate "...nor the same through printf" \
        allow "printf %s \"\$X\" branch -f main HEAD"
    run_gate "...but a wrapper prefix still reaches it" \
        block "timeout 5 git branch -f main $UNREVIEWED" \
        "no old-oid precondition"
    # The wrapper arm models `worktree` by FLAG, exactly as the argv path does:
    # the word alone writes no ref, `add -B` resets one.
    run_gate "...and a wrapped worktree add -B is still a force" \
        block "xargs -I{} git worktree add -B main /tmp/wt-780g $UNREVIEWED" \
        "no old-oid precondition"
    run_gate "...including behind a dynamically named git" \
        block "GIT=git; \"\$GIT\" worktree add -B main /tmp/wt-780h $UNREVIEWED" \
        "no old-oid precondition"
    run_gate "...but a wrapped worktree list is not" \
        allow "xargs -I{} git worktree list"
    # The arm asks for an invocation SHAPE, not a position, because the set of
    # wrappers is open-ended — every review round named another one a
    # position rule did not know. None of these needs to be in a list.
    run_gate "...and an unmodelled wrapper does not hide a force" \
        block "arch -x86_64 git branch -f main $UNREVIEWED" \
        "no old-oid precondition"
    run_gate "...whatever the wrapper is called" \
        block "chronic git branch -f main $UNREVIEWED" \
        "no old-oid precondition"
    run_gate "...nor does one in front of a dynamically named git" \
        block "arch -x86_64 \"\$GIT\" branch -f main $UNREVIEWED" \
        "no old-oid precondition"
    # An unforced rename still DELETES the source ref, so it is a ref write —
    # the same reading the argv path gives it.
    run_gate "...and a wrapped rename is a ref write too" \
        block "\"\$GIT\" branch -m main renamed" \
        "no old-oid precondition"
    # The subcommand can be spelled into the executable's own NAME, leaving no
    # unreadable operand at all — there the candidate itself is the unreadable
    # part, and it must be where an executable goes.
    run_gate "...and a dashed git in a variable is a ref write" \
        block "G=git-branch; \"\$G\" -f main $UNREVIEWED" \
        "no old-oid precondition"
    run_gate "...including behind a wrapper" \
        block "xargs -I{} \"\$G\" -f main $UNREVIEWED" \
        "no old-oid precondition"
    # ...but an operand is not an executable, however forceful the flag.
    run_gate "...while a copy naming two variables is not" \
        allow "cp -f \$SRC \$DST"
    run_gate "...nor an interpreter with a -m of its own" \
        allow "\"\$PYTHON\" -m pytest -x tests/"
    # A print-only word that is an OPTION VALUE is not the command: in
    # `xargs -I echo …` the echo is the replacement string and git is what runs.
    run_gate "...and echo as a replacement string does not exempt git" \
        block "printf x | xargs -I echo git branch -f main $UNREVIEWED" \
        "no old-oid precondition"
    # `fast-import` is OUT OF SCOPE for #780 (operator decision): its force can
    # arrive as `feature force` inside the import STREAM, which this gate never
    # sees, so a `--force`-only rule would read as coverage it does not have.
    run_gate "fast-import is not this issue's business" \
        allow "git fast-import --force"
    run_gate "...in either spelling" allow "git fast-import"
    # `--` is end-of-options only when it IS the marker: parse-options hands the
    # next argv element to a value-taking option whatever it spells, so here the
    # `--` is the reason STRING and `-B` is still an option.
    run_gate "...and a -- consumed as an option value ends nothing" \
        block "git worktree add --lock --reason -- -B main /tmp/wt-780k $UNREVIEWED" \
        "no old-oid precondition"
    # The write has to be the CANDIDATE's own — a flag belongs to the command it
    # follows. This is what lets an unknown leading word stay unknown.
    run_gate "...and an unknown wrapper cannot hide a dashed git either" \
        block "arch -x86_64 \"\$G\" -f main $UNREVIEWED" \
        "no old-oid precondition"
    run_gate "...while an f spent BEFORE the variable is that command's own" \
        allow "cp -f \$SRC \$DST"
    run_gate "...as in a tar" allow "tar -cf \$ARCHIVE \$DIR"
    # A ref writer needs no FLAG, so an unreadable subcommand cannot be
    # qualified on one — the refs/ operand is the write.
    run_gate "...and a flagless dynamic ref writer is still a write" \
        block "G=git; S=update-ref; \"\$G\" \"\$S\" refs/heads/main $UNREVIEWED" \
        "no old-oid precondition"
    run_gate "...including one spelled into the executable name" \
        block "G=git-update-ref; \"\$G\" refs/heads/main $UNREVIEWED" \
        "no old-oid precondition"
    # A print-only builtin consumes the words. Its POSITION is the test, not
    # the segment's first word: a wrapper option value can be the substitution.
    run_gate "...but a wrapper option value in front of echo is not a force" \
        allow "sudo -u \"\$USER\" echo branch -f main HEAD"
    run_gate "...nor the same through env" \
        allow "env -u \"\$NAME\" echo branch -f main HEAD"
    # The UNFORCED delete removes the ref too — it only refuses an unmerged
    # branch, and from a branch that CONTAINS main it succeeds. `-D` was
    # covered; `-d` was not, so this was a recognised subcommand with no write.
    run_gate "...and an unforced delete is still a delete" \
        block "printf x | xargs -I{} git branch -d main" \
        "no old-oid precondition"
    run_gate "...including inside a real cluster" \
        block "printf x | xargs -I{} git branch -dq main" \
        "no old-oid precondition"
    # ...but a single-dash LONG option is not a cluster, in either letter.
    run_gate "...while find's -depth is not a delete flag" \
        allow "find \$DIR -depth -name branch"
    run_gate "...nor is find's own -delete" allow "find \$DIR -delete"
    # A print-only NAME is only an exemption where a COMMAND can stand: here
    # `echo` is a FILE and git is what find executes.
    run_gate "...and a file named echo does not exempt what find runs" \
        block "G=git; find echo -exec \"\${G}\" update-ref refs/heads/main $UNREVIEWED ;" \
        "no old-oid precondition"
    # ...but a single-dash long option is not a cluster: -name is not -m.
    run_gate "...while a find naming a path variable is not" \
        allow "find \$DIR -name branch"
    # A wrapper's OPTION VALUE is not the command word either.
    run_gate "...and an option value does not hide the executable" \
        block "GIT=git; env -u FOO \"\$GIT\" branch -f main $UNREVIEWED" \
        "no old-oid precondition"
    run_gate "...the same through sudo" \
        block "sudo -u nobody \"\$GIT\" branch -f main $UNREVIEWED" \
        "no old-oid precondition"
    # With a LITERAL git behind it the earlier arm gets there first: `env -u`
    # is an env manipulation the gate cannot resolve, so it fails closed on the
    # operand. Pinned so a later reader does not credit this arm for it.
    run_gate "...though a literal git behind env is caught before this arm" \
        block "env -u FOO git update-ref -d refs/heads/main" \
        "cannot be resolved"
    # An ordinary topic branch is ordinary feature work — the same reading the
    # merge arm gives it — and needs no declaration file to say so.
    run_gate "deleting a topic branch is not deleting a protected one" \
        allow "git branch -D old-topic-780"
    # A ref name may legally contain glob metacharacters; the pair must not be
    # pathname-expanded against the gate's cwd on its way to PROTECTED_SET.
    run_gate "a glob-metachar ref name is unreadable, not rewritten" \
        block "git branch -D bad[a-z]name" "no old-oid precondition"
    # A bounded sweep, not enumeration: every prefix this file knows and every
    # one it does not, against both spellings of the executable. The oracle is
    # trivial — each of these runs `branch -f main <oid>` — and it is exactly
    # the axis where four review rounds each found one more missing entry.
    for _zo_pre in "" "xargs -I{} " "env " "sudo " "timeout 5 " "nice " \
                   "arch -x86_64 " "chronic " "caffeinate -i "; do
        for _zo_exe in "git branch" "\"\$G\""; do
            # Refused is the whole oracle here — WHICH arm refuses is not this
            # sweep's business (a `sudo` prefix is an unresolvable scope and is
            # caught earlier). The named cases above pin the reasons.
            run_gate "sweep: [${_zo_pre}]${_zo_exe} force → block" \
                block "${_zo_pre}${_zo_exe} -f main $UNREVIEWED"
        done
    done
    # ...and the documented escape the refusal advertises still works.
    run_gate "an honest full-oid CAS is still allowed" \
        allow "git update-ref refs/heads/main $UNREVIEWED $REVIEWED"
    git -C "$REPO" branch topic HEAD
    git -C "$REPO" branch old-topic-780 HEAD
    # Porcelain force has no old-oid CAS; pre-command probe is TOCTOU, so
    # fail closed for every current-ref state (direct / absent / symref),
    # including non-protected topic names (files + reftable). Measured: `git
    # branch -f <symref> <oid>` DEREFERENCES, so `-f topic` where topic is a
    # symref to refs/heads/main moves main -- the name alone cannot clear it.
    run_gate "branch -f of non-protected topic → block" \
        block "git branch -f topic $UNREVIEWED" "force-updates a branch ref with no old-oid precondition"

    # The refusal names skip-litmus.local as the override, so that has to be
    # REACHABLE: the ZERO-old arm must run after the skip check, not before it.
    # (Aged mtime because the shared anti-self-bypass rule refuses a marker the
    # session could have just created itself.)
    touch -t 202001010000 "$REPO/$ISO_STATE/skip-litmus.local"
    run_gate "the advertised skip-litmus.local override is reachable" \
        allow "git branch -f main $UNREVIEWED"
    rm -f "$REPO/$ISO_STATE/skip-litmus.local"

    # ...and it authorizes THIS repo only. The ZERO-old arm sits after the skip
    # check, so the standing question is whether repo A's consent can reach a
    # protected ref in repo B. It cannot: a scope the command chose is either
    # refused as an unresolvable operand (an env redirect) or forfeits the skip
    # outright (a command-chosen `-C` anchor, #812) -- both BEFORE consent is
    # read. Pinned with the marker still armed, which is the only state in which
    # the question has teeth.
    OTHER_REPO="$TMPROOT/other-$fmt"
    rm -rf "$OTHER_REPO"
    (
        set -e
        git init -q -b main "$OTHER_REPO"
        cd "$OTHER_REPO"
        git config user.email t@t; git config user.name t
        git config commit.gpgsign false
        git config core.hooksPath "$(pwd)/.git/hooks"
        echo base > f; git add f; git commit -qm base
    ) >/dev/null 2>&1 || { printf "  FAIL  fixture setup (other repo)\n"; FAIL=$((FAIL + 1)); return; }
    touch -t 202001010000 "$REPO/$ISO_STATE/skip-litmus.local"
    run_gate "an armed skip does not reach a -C-scoped delete in another repo" \
        block "git -C $OTHER_REPO branch -D main" "DELETE the protected branch 'main'"
    run_gate "...nor a -C-scoped default-deref update-ref there" \
        block "git -C $OTHER_REPO update-ref refs/heads/main $UNREVIEWED" \
        "no old-oid precondition"
    run_gate "...nor one an env scope redirect points elsewhere" \
        block "export GIT_DIR=$OTHER_REPO/.git && git update-ref -d refs/heads/main" \
        "cannot be resolved statically"
    # ...and a COMPANION forfeits it too, for the same reason: the ZERO-old
    # refusal sits after consent, so a sourced script or any other segment could
    # export GIT_DIR / cd between the gate's read and git's own chdir, and repo
    # A's marker would have authorized the write wherever it landed.
    run_gate "an armed skip does not survive a companion command" \
        block "source /tmp/redirect.sh && git update-ref -d refs/heads/main" \
        "issue #780"
    run_gate "...and the lone force it IS armed for still passes" \
        allow "git branch -f main $UNREVIEWED"
    # An INHERITED git scope is the third relocating shape. The gate's own env is
    # sanitized, so it learns of one only through the launcher's sentinel -- and
    # without marking the scope it would anchor on the session cwd, read THIS
    # repo's marker, and redeem a force whose effect landed in the repo GIT_DIR
    # actually names.
    BUSDRIVER_GIT_SCOPE_PRESENT=1 \
    run_gate "an armed skip does not survive an inherited git scope" \
        block "git branch -f main $UNREVIEWED" "cannot be resolved"
    # ...including when a wrapper hides the git word from the parser: that path
    # yields the same unresolved force, so it needs the same scope marker.
    BUSDRIVER_GIT_SCOPE_PRESENT=1 \
    run_gate "...nor when a wrapper hides the force" \
        block "xargs -I{} git branch -f main $UNREVIEWED" "cannot be resolved"
    # ...while an inherited scope must not make every `branch`/`checkout` WORD a
    # refusal. The parser has already looked and fails closed on its own for the
    # shapes that write a ref, so read-only forms stay read-only.
    # ...and the same for a write the parser models by FLAG rather than by word.
    # The scope marker used to be armed only when the parser produced a `raw`
    # operation, so `worktree add -B` appended its force WITHOUT marking the
    # scope — and this repo's armed marker then redeemed a reset landing in the
    # repo GIT_DIR names.
    BUSDRIVER_GIT_SCOPE_PRESENT=1 \
    run_gate "...nor a worktree add -B, which the parser models by flag" \
        block "git worktree add -B main /tmp/wt-780z $UNREVIEWED" "cannot be resolved"
    BUSDRIVER_GIT_SCOPE_PRESENT=1 \
    run_gate "...nor a subcommand it cannot read at all" \
        block "git \$SUB -f main $UNREVIEWED" "cannot be resolved"
    # ...while an inherited scope must not make a read-only worktree form a
    # refusal either.
    BUSDRIVER_GIT_SCOPE_PRESENT=1 \
    run_gate "...but a worktree listing under one is still read-only" \
        allow "git worktree list"
    BUSDRIVER_GIT_SCOPE_PRESENT=1 \
    run_gate "...and a read-only branch listing is still not a force" \
        allow "git branch --list"
    BUSDRIVER_GIT_SCOPE_PRESENT=1 \
    run_gate "...nor is a plain copy under one" \
        allow "git branch -c topic topic-copy2"
    rm -f "$REPO/$ISO_STATE/skip-litmus.local"
    rm -rf "$OTHER_REPO"

    # Off protected HEAD still blocks force of main.
    git -C "$REPO" checkout -q -b feature
    run_gate "branch -f main from feature branch → block" \
        block "git branch -f main $UNREVIEWED" "force-updates a branch ref with no old-oid precondition"

    # reference-transaction layer — stay off main so Git itself does not reject
    # branch -f/-D of the checked-out branch (that would mask a missing hook).
    install_rt_hook
    assert_git_fails "rt: branch -f main aborts" branch -f main "$UNREVIEWED"
    assert_git_fails "rt: checkout -B main aborts" checkout -B main "$UNREVIEWED"
    assert_git_fails "rt: update-ref without oldvalue aborts" update-ref refs/heads/main "$UNREVIEWED"
    assert_git_fails "rt: delete main aborts" branch -D main
    assert_git_ok "rt: genuine create newbranch2 allowed" branch newbranch2 "$UNREVIEWED"
    git -C "$REPO" update-ref -d refs/heads/scratch 2>/dev/null || true
    assert_git_ok "rt: create of absent non-protected name allowed" branch scratch "$UNREVIEWED"
}

run_format_suite files
if supports_reftable; then
    run_format_suite reftable
else
    printf '\n=== #780 reftable skipped (git lacks --ref-format=reftable) ===\n'
    printf "  PASS  reftable unsupported on this git — files coverage stands\n"
    PASS=$((PASS + 1))
fi

# Detector unit smoke (shared root).
printf '\n=== #780 detector smoke ===\n'
DET=$(PYTHONPATH="$REPO_ROOT/hooks/gate-scripts/lib" python3 -S - "$REPO" <<'PY'
import sys
from gitcmd_detect import git_zero_old_ref_op
hook_cwd = sys.argv[1]
OID_A = '3cc2f0d6f1a399738b4873e4873e88b2e47356be'
OID_B = '39f33bdc516ac395d10ff9b84f6da7145084245c'
ops = git_zero_old_ref_op('git branch -f main abc', hook_cwd=hook_cwd)
assert ops == [('force', '')], ops
ops = git_zero_old_ref_op('git checkout -B main abc', hook_cwd=hook_cwd)
assert ops == [('force', '')], ops
ops = git_zero_old_ref_op('git branch -f topic abc', hook_cwd=hook_cwd)
assert ops == [('force', '')], ops
ops = git_zero_old_ref_op(
    'git update-ref refs/heads/main abc', hook_cwd=hook_cwd)
assert ops == [('force', '')], ops
ops = git_zero_old_ref_op(
    'git update-ref refs/heads/main abc def', hook_cwd=hook_cwd)
assert ops == [('force', '')], ops            # 'def' is not an object name
ops = git_zero_old_ref_op(
    'git update-ref refs/heads/main ' + OID_A + ' ' + OID_B, hook_cwd=hook_cwd)
assert ops == [], ops                          # a full-oid CAS is a real one
ops = git_zero_old_ref_op(
    'git update-ref refs/heads/main ' + OID_A + ' refs/heads/main',
    hook_cwd=hook_cwd)
assert ops == [('force', '')], ops             # self-referential CAS is vacuous
ops = git_zero_old_ref_op(
    'git update-ref refs/heads/main ' + OID_A + ' ' + 'a' * 64, hook_cwd=hook_cwd)
assert ops == [('force', '')], ops             # wrong length for a sha1 repo
ops = git_zero_old_ref_op('git branch -D main', hook_cwd=hook_cwd)
assert ops == [('delete', 'main')], ops
print('ok')
PY
) || DET=fail
if [ "$DET" = ok ]; then
    printf "  PASS  detector shapes\n"; PASS=$((PASS + 1))
else
    printf "  FAIL  detector shapes (%s)\n" "$DET"; FAIL=$((FAIL + 1))
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
