"""Deliberation-dispatcher exemption for the pre-implementation design-review gate.

Recognizes busdriver's deliberation dispatchers (council / ultra-council /
ultimate-council, ultraoracle, dispatch-cli) by their literal plugin script
paths and EXEMPTS such a command from the design-review file-mod block. Without
this, a council convened to help fix a design that is mid-review is blocked BY
the design gate — every CLI voice and the UltraOracle dispatch via Bash and get
killed, silently degrading the council to its Agent-tool voices only (#484).

Scope (deliberate, #484): recognition is by dispatcher path ALONE. This module
makes NO attempt to validate the rest of the command's file-mods. That is not an
oversight — it is both unachievable and unnecessary here:

  - Unachievable. The dispatch blocks legitimately use command substitution
    (P="$(mktemp)", "$(...)"), indirect quoted-string data flow
    (D="...dispatch.sh"; bash "$D"), heredocs, and printf/echo — so a dispatcher
    path that is genuinely INVOKED is statically indistinguishable from one that
    only appears as inert data (a heredoc body, a printf argument, an assigned-
    but-unused variable). `$(mktemp)` and `$(rm -rf src)` are the SAME shell
    construct; a path assigned to a variable and one merely printf'd as a log
    line are the SAME "quoted string containing the path" shape without
    per-variable data-flow tracking. Chasing precise invoke-vs-mention is an
    arms race a design-gate exemption should not run — across #484/#488 the
    litmus review bypassed every partial parser tried (six operand-side, then
    heredoc/printf/token-boundary strippers), each defeated by a shell-grammar
    corner (word concatenation, process substitution, non-word heredoc
    delimiters). So the only inert context stripped is the LINE COMMENT (below —
    cheaply and soundly). Every other over-recognition — a path in a heredoc
    body, a printf arg, a `.sh.disabled` variant, or alongside a destructive
    tail — is the documented, accepted residual.

  - Unnecessary. This gate is a COOPERATIVE forcing function, not an adversarial
    sandbox. Any Bash-holding session already bypasses it trivially
    (`python -c 'os.remove(...)'`, perl, env). The residual here — a destructive
    op pasted alongside a genuine dispatcher command slips past the DESIGN gate —
    is that SAME already-accepted residual, not a new hole. What the gate exists
    to catch is untouched: an ACCIDENTAL Write/Edit or a bare `rm -rf src` while
    a design is unreviewed has no dispatcher path and is not exempted at all.

Interface: `is_exempt(command) -> bool`, imported by pre-implementation-gate.sh.
Import failure there leaves is_exempt=None → the command falls through to the
normal block (fail-CLOSED: a missing lib blocks, never allows).
"""
import re
import sys

# Literal plugin script paths that only the deliberation dispatchers invoke.
# Any one present marks the command as a deliberation dispatch. (litmus /
# blueprint-review are intentionally absent — they have their own F8 exemption.)
#
# `/scripts/lib/resolve-cli.sh` is deliberately EXCLUDED (#484 review): it is
# a plugin-wide shared library sourced by litmus, blueprint-review, CI tests
# (e.g. tests/test-agy-argv-limit.sh), and council/ultraoracle alike — so
# matching on it alone over-exempts any command that merely sources the
# helper for unrelated reasons (`source .../resolve-cli.sh; rm -rf src` would
# read as a "deliberation dispatch"). It adds no real detection power: every
# actual dispatcher command already reaches a CLI voice via
# `skills/dispatch-cli/scripts/dispatch.sh` (matched below) or
# `scripts/ultra-oracle-run.sh` (matched below) — council's own inline
# dispatch block sources resolve-cli.sh only to resolve role→CLI names, then
# invokes the voice through `$DISPATCH`, which is dispatch.sh.
#
# ultraoracle is matched by SPECIFIC entry-point filenames, not the whole
# `skills/ultraoracle/scripts/` directory (#488 review, Codex P1). Per
# `skills/ultraoracle/SKILL.md`, `build-evidence-pack.sh` and
# `run-retrieval-loop.sh` are the two scripts actually pasted directly into an
# operator/agent's live dispatch Bash block; `retrieve-evidence.sh`,
# `validate-retrieval-review.sh`, and `lib/*` are internal helpers invoked BY
# `run-retrieval-loop.sh`, never dispatched standalone — matching the whole
# directory let an unrelated helper invocation (e.g. `validate-retrieval-review.sh
# --review-file x; rm -rf src`) ride through as a false "deliberation dispatch".
# dispatch-cli and council are left directory-wide: dispatch-cli/scripts/ has
# exactly one file today (no over-broadness possible), and council/scripts/
# doesn't exist yet (forward-looking placeholder, not evidenced as over-broad
# by any reviewer) — narrowing either would be an unforced, unevidenced change.
# A shell token boundary after a matched `.sh` filename: end-of-string or a
# char that cannot continue a path token. Stops a DIFFERENT, non-dispatcher
# file whose name merely has an approved entry point as a prefix — e.g.
# `run-retrieval-loop.sh.disabled` or `ultra-oracle-run.sh.bak` — from matching
# (#488 review, Codex P1). The directory-form alternatives intentionally match
# any file under the dir (dispatch-cli/scripts/ has one file; council/scripts/
# is a forward-looking placeholder), so they take no boundary.
_TOK_END = r"(?=$|[\s\"'&;|<>()])"
_DISPATCHER = re.compile(
    r"skills/(?:dispatch-cli|council)/scripts/"
    + r"|skills/ultraoracle/scripts/(?:build-evidence-pack|run-retrieval-loop)\.sh" + _TOK_END
    + r"|/scripts/ultra-oracle-run\.sh" + _TOK_END)

# Shell comments (`#` to end of line). Stripped before matching so a dispatcher
# path mentioned only in inert commentary — not as a command/source operand —
# doesn't trigger the exemption (#484 review: `rm -rf src #
# skills/dispatch-cli/scripts/dispatch.sh` must not read as SAFE). A line
# comment is the ONE inert context that is cheaply AND soundly strippable: `#`
# to end-of-line, no grammar to track. (The only imprecision — a `#` inside a
# quoted string — over-strips, which only makes recognition MORE conservative,
# never less; fail-CLOSED.) Other inert positions (heredoc bodies, quoted
# printf args) are NOT stripped — soundly excluding those needs a full shell
# parser, the same "unachievable" problem the docstring declines for command
# substitution, and #488's litmus review confirmed every partial parser has a
# bypass. A dispatcher path mentioned there is part of the accepted residual.
_COMMENT = re.compile(r"#[^\n]*")


def is_exempt(command):
    """True iff a recognized deliberation-dispatcher path appears in the command.

    Recognition is by dispatcher path only — see the module docstring for why
    validating HOW the path is used (invoked vs. merely mentioned in a heredoc
    body / printf arg / alongside a destructive tail) is deliberately not
    attempted: it is unsound statically, and the residual equals the gate's
    pre-existing `python -c` residual. Line comments are the one exception —
    cheaply and soundly stripped first so a path in a trailing `#` comment does
    not itself trigger the exemption.
    """
    return bool(_DISPATCHER.search(_COMMENT.sub("", command)))


def _demo():
    # Runnable self-check: `python3 delib_gate.py --selftest`.
    allow = [
        # Every recognized dispatcher path is exempt.
        "bash skills/dispatch-cli/scripts/dispatch.sh --cli codex",
        'D="$R/skills/dispatch-cli/scripts/dispatch.sh"; bash "$D" <<EOF\nhi\nEOF',
        'bash "$R/scripts/ultra-oracle-run.sh" council 0 "$P" out.md > "$RES"; rm -f "$P"',
        "source skills/council/scripts/convene.sh",
        'LABEL="$(bash skills/ultraoracle/scripts/build-evidence-pack.sh --mode repo)"',
        # run-retrieval-loop.sh is the other real ultraoracle dispatch entry
        # point (#488) — its own mktemp/rm cleanup must stay exempt too.
        'bash skills/ultraoracle/scripts/run-retrieval-loop.sh --question-file q.txt --out-dir out; rm -f q.txt',
        # ACCEPTED RESIDUAL (#484 / #488): a command containing a dispatcher path
        # token is exempt regardless of HOW the path is used — a destructive
        # tail, or the path appearing only as inert data inside a heredoc body
        # or a printf/echo argument. Soundly distinguishing "invoked" from
        # "merely mentioned there" needs a full shell parser (#488's litmus
        # review found a bypass in every partial one), so it is not attempted;
        # this is the SAME residual as `python -c os.remove`. Pinned here so
        # re-adding a static invoke-vs-mention scanner is a deliberate, visible
        # change, not an accident. Do NOT "fix" these to block. (Line comments
        # ARE stripped — that one inert context is soundly cheap; see block.)
        "bash skills/dispatch-cli/scripts/dispatch.sh && rm -rf src",
        "source skills/council/scripts/x.sh; echo x > app/main.py",
        'cat <<EOF\nskills/dispatch-cli/scripts/dispatch.sh\nEOF\nrm -rf src',
        "printf '%s\\n' 'skills/dispatch-cli/scripts/dispatch.sh'; rm -rf src",
    ]
    block = [
        # No dispatcher path → not our concern → the gate's normal block stands.
        "rm -rf src",
        "git commit -m x",
        "echo hi > app/main.py",
        "bash scripts/other.sh; rm -rf src",
        "sed -i s/a/b/ lib/core.py",
        "bash skills/litmus/scripts/run-review-loop.sh",  # litmus = F8, not this
        # resolve-cli.sh alone is NOT a dispatcher signal (#484 review,
        # Greptile/Codex P1) — it's a shared library sourced by litmus,
        # blueprint-review, and unrelated tests; matching on it over-exempts.
        'source "$R/scripts/lib/resolve-cli.sh"; rm -rf src',
        'bash "$R/scripts/lib/resolve-cli.sh" agy',
        # tests/test-agy-argv-limit.sh's real invocation shape — must not
        # read as a deliberation dispatch.
        '. "$REPO_ROOT/scripts/lib/resolve-cli.sh"; _agy_wants_argv_prompt',
        # A dispatcher path in a trailing comment is stripped before matching
        # (#484 review, Codex P1) — line comments are the one inert context we
        # soundly remove; the command actually run is a bare rm.
        "rm -rf src  # skills/dispatch-cli/scripts/dispatch.sh",
        # A directory-wide ultraoracle match over-exempted a non-dispatcher
        # helper (#488 review, Codex P1) — validate-retrieval-review.sh is a
        # local JSON validator, not a dispatch entry point; the narrowed regex
        # only matches the two real entry points.
        'bash skills/ultraoracle/scripts/validate-retrieval-review.sh --review-file review.json; rm -rf src',
        # A DIFFERENT file whose name has an entry point as a prefix is not the
        # entry point (#488 review, Codex P1) — the token boundary rejects it.
        'bash skills/ultraoracle/scripts/run-retrieval-loop.sh.disabled; rm -rf src',
    ]
    for c in allow:
        assert is_exempt(c), "should ALLOW:\n" + c
    for c in block:
        assert not is_exempt(c), "should BLOCK:\n" + c
    print("delib_gate self-check: OK ({} allow, {} block)".format(len(allow), len(block)))


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--selftest":
        _demo()
    else:
        # Read a command on stdin; print SAFE (exempt) or UNSAFE.
        print("SAFE" if is_exempt(sys.stdin.read()) else "UNSAFE")
