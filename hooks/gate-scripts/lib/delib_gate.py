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
    (P="$(mktemp)", "$(...)") and heredocs whose unquoted bodies run parameter
    and command substitution. `$(mktemp)` and `$(rm -rf src)` are the SAME shell
    construct, so no static scan of the un-run command can separate them. Every
    "prove the operands are safe" scanner is defeated by some shell-grammar
    corner — heredoc-body `$()`, per-cmdsub quoting context, backslash-newline
    continuation, quote-removed traversal, arithmetic `<<`. Chasing them is an
    arms race a design-gate exemption should not be running; the #484 litmus
    review walked six such bypasses before this was simplified.

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
_DISPATCHER = re.compile(
    r"skills/(?:dispatch-cli|ultraoracle|council)/scripts/"
    r"|/scripts/ultra-oracle-run\.sh"
    r"|/scripts/lib/resolve-cli\.sh")


def is_exempt(command):
    """True iff the command invokes a recognized deliberation dispatcher.

    Recognition is by dispatcher path only — see the module docstring for why
    operand validation is deliberately absent (unsound to attempt statically,
    and the residual equals the gate's pre-existing `python -c` residual).
    """
    return bool(_DISPATCHER.search(command))


def _demo():
    # Runnable self-check: `python3 delib_gate.py --selftest`.
    allow = [
        # Every recognized dispatcher path is exempt.
        "bash skills/dispatch-cli/scripts/dispatch.sh --cli codex",
        'D="$R/skills/dispatch-cli/scripts/dispatch.sh"; bash "$D" <<EOF\nhi\nEOF',
        'bash "$R/scripts/ultra-oracle-run.sh" council 0 "$P" out.md > "$RES"; rm -f "$P"',
        "source skills/council/scripts/convene.sh",
        'LABEL="$(bash skills/ultraoracle/scripts/build-evidence-pack.sh --mode repo)"',
        'bash "$R/scripts/lib/resolve-cli.sh" agy',
        # ACCEPTED RESIDUAL (#484): a dispatcher command is exempt even with a
        # destructive tail — the SAME residual as `python -c os.remove`. Pinned
        # here so re-adding a static "operand safety" scanner is a deliberate,
        # visible change, not an accident. Do NOT "fix" these to block.
        "bash skills/dispatch-cli/scripts/dispatch.sh && rm -rf src",
        "source skills/council/scripts/x.sh; echo x > app/main.py",
    ]
    block = [
        # No dispatcher path → not our concern → the gate's normal block stands.
        "rm -rf src",
        "git commit -m x",
        "echo hi > app/main.py",
        "bash scripts/other.sh; rm -rf src",
        "sed -i s/a/b/ lib/core.py",
        "bash skills/litmus/scripts/run-review-loop.sh",  # litmus = F8, not this
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
