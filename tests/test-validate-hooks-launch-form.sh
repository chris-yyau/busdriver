#!/usr/bin/env bash
# Test: the #713 launch-form pins in scripts/ci/validate-hooks.js actually REJECT the
# mutations they claim to (issue #713, ADR 0049).
#
# WHY THIS FILE EXISTS. The pins were originally proven by hand-run mutations. A guard that
# has only ever been *observed* failing is not enforced — the observation is not in the
# repository and does not survive the next edit. This drives every mutation as a permanent
# check, against COPIES of hooks.json (the validator takes an optional path argument), so
# the real document is never edited.
#
# Each mutation must make the validator EXIT NON-ZERO. The green control must exit 0 — a
# suite where every case is expected to fail can pass while validating nothing.
#
# Two layers: a named list of the mutations the pins were designed against, then an
# EXHAUSTIVE sweep deleting and duplicating every argv element of one registration in turn,
# so the coverage is not limited to holes someone thought of in advance.
# shellcheck disable=SC2016  # the python mutation bodies are single-quoted ON PURPOSE:
# every `$` inside them belongs to Python, except the few explicitly interpolated below.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VALIDATOR="$REPO_ROOT/scripts/ci/validate-hooks.js"
HOOKS_JSON="$REPO_ROOT/hooks/hooks.json"
PASS=0
FAIL=0
assert() { if [[ "$1" -eq 0 ]]; then PASS=$((PASS+1)); printf '  ok   %s\n' "$2"
           else FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$2"; fi; }

TMP="$(mktemp -d)" || TMP=""
if [[ -z "$TMP" || ! -d "$TMP" ]]; then
    printf '  FAIL could not create a temporary directory\n' >&2
    printf 'PASS=0 FAIL=1\n'; exit 1
fi
LAUNCHER="$REPO_ROOT/hooks/gate-scripts/lib/contained-launch.sh"
# The launcher rows below mutate the FIRST HOP OF EVERY LIVE GATE. An earlier revision did it
# in place, with a backup and a restoring trap. That was wrong at the design level, not just
# the edge cases: no trap survives SIGKILL, and every hook in this repo fires constantly, so
# any tool call landing inside the mutation window would have executed a deliberately
# weakened launcher — one of these variants has its no-argument path stubbed to `exit 0`.
# A test must not put a fail-open gate on disk, however briefly.
#
# So the mutations run against a SANDBOX TREE instead, laid out so the validator's own
# `__dirname/../../…` resolution lands inside it. It sits under node_modules (gitignored, and
# still on node's resolution path for ajv) so no tracked file is touched and `git status`
# stays clean throughout.
# Unique per run: a fixed path would let two concurrent invocations delete and overwrite each
# other's sandbox between mutation and validation, so one run could validate the OTHER run's
# mutation — flaky failures, or worse, a row scored as rejected on someone else's evidence.
SANDBOX="$REPO_ROOT/node_modules/.cache/bd713-launcher-mutations.$$.${RANDOM}"
trap 'rm -rf "$TMP" "$SANDBOX"' EXIT
trap 'rm -rf "$TMP" "$SANDBOX"; exit 130' INT
trap 'rm -rf "$TMP" "$SANDBOX"; exit 143' TERM

# mutate <name> <python-body> — <python-body> edits `doc` in place; `rows()` yields
# (block, index, hook) for every registration in the document.
mutate() {
    local name="$1" body="$2" out="$TMP/mutated.json"
    if ! python3 - "$HOOKS_JSON" "$out" "$body" <<'PY'
import collections, json, sys
src, dst, body = sys.argv[1], sys.argv[2], sys.argv[3]
doc = json.load(open(src), object_pairs_hook=collections.OrderedDict)
def rows():
    for blocks in doc.get("hooks", doc).values():
        for blk in blocks:
            for i, hk in enumerate(list(blk.get("hooks", []))):
                yield blk, i, hk
def is_gate(hk):
    argv = [hk.get("command", "")] + list(hk.get("args") or [])
    return any(isinstance(a, str) and "sanitized-gate.sh" in a for a in argv) \
        and "codex-nudge" not in " ".join(str(a) for a in argv)
def is_nudge(hk):
    return "codex-nudge-premerge.sh" in hk.get("command", "")
exec(body)
json.dump(doc, open(dst, "w"), indent=2)
open(dst, "a").write("\n")
PY
    then assert 1 "$name (mutation script itself failed)"; return; fi
    if node "$VALIDATOR" "$out" >/dev/null 2>&1; then assert 1 "$name — ESCAPED the validator"
    else assert 0 "$name — rejected"; fi
}

# ── Green control ───────────────────────────────────────────────────────────────────
node "$VALIDATOR" "$HOOKS_JSON" >/dev/null 2>&1
assert $? "control: the unmutated document PASSES (so a rejection below means something)"

# ── Launch form ─────────────────────────────────────────────────────────────────────
mutate "shell-form revert of a gate" '
for blk, i, hk in rows():
    if is_gate(hk):
        argv = [hk["command"]] + hk["args"]
        blk["hooks"][i] = {"type": "command", "command": " ".join(argv), "timeout": hk.get("timeout", 20)}
        break
'
# ── R7: the first hop must never be bare /usr/bin/env again ─────────────────────────
mutate "command reverted to bare /usr/bin/env (args-ignoring client would exit 0 + dump env)" '
for blk, i, hk in rows():
    if is_gate(hk):
        hk["command"] = "/usr/bin/env"
        hk["args"] = ["-i"] + hk["args"][1:]
        break
'
mutate "command repointed at another executable" '
for blk, i, hk in rows():
    if is_gate(hk):
        hk["command"] = "/bin/bash"
        break
'
# ── R8: the launch-failure disposition ──────────────────────────────────────────────
mutate "disposition dropped (nothing left to turn a 127 into a block)" '
for blk, i, hk in rows():
    if is_gate(hk):
        hk["args"] = hk["args"][1:]
        break
'
mutate "unknown disposition" '
for blk, i, hk in rows():
    if is_gate(hk):
        hk["args"][0] = "maybe"
        break
'
mutate "a fail-CLOSED gate flipped to the open disposition" '
for blk, i, hk in rows():
    a = list(hk.get("args") or [])
    if any("block-no-verify.js" in str(x) for x in a):
        hk["args"][0] = "open"
        break
'
mutate "a fail-OPEN GateGuard row flipped to closed" '
for blk, i, hk in rows():
    a = list(hk.get("args") or [])
    if "--fail-open" in a:
        hk["args"][0] = "closed"
        break
'
mutate "disposition and wrapper flag swapped in tandem (both populations preserved)" '
op = cl = None
for blk, i, hk in rows():
    a = list(hk.get("args") or [])
    if "--fail-open" in a and op is None:
        op = hk
    elif any("block-no-verify.js" in str(x) for x in a) and cl is None:
        cl = hk
op["args"][0] = "closed"
op["args"] = [x for x in op["args"] if x != "--fail-open"]
bi = cl["args"].index("/bin/bash")
cl["args"][0] = "open"
cl["args"] = cl["args"][:bi+2] + ["--fail-open"] + cl["args"][bi+2:]
'
mutate "empty args array" '
for blk, i, hk in rows():
    if is_gate(hk):
        hk["args"] = []
        break
'
mutate "args replaced by a single joined string element" '
for blk, i, hk in rows():
    if is_gate(hk):
        hk["args"] = [" ".join(hk["args"])]
        break
'
mutate "PATH widened to include a writable dir" '
for blk, i, hk in rows():
    if is_gate(hk):
        hk["args"] = ["PATH=/usr/bin:/bin:/tmp" if x == "PATH=/usr/bin:/bin" else x for x in hk["args"]]
        break
'
mutate "async: true (a backgrounded hook returns status 0 = allow)" '
for blk, i, hk in rows():
    if is_gate(hk):
        hk["async"] = True
        break
'
mutate "|| exit 2 tail smuggled in as an args element" '
for blk, i, hk in rows():
    if is_gate(hk):
        hk["args"] = hk["args"] + ["||", "exit", "2"]
        break
'

# ── Assignments ─────────────────────────────────────────────────────────────────────
mutate "SHELLOPTS=noexec injected between the disposition and /bin/bash" '
for blk, i, hk in rows():
    if is_gate(hk):
        a = hk["args"]; a.insert(a.index("/bin/bash"), "SHELLOPTS=noexec")
        break
'
mutate "CLAUDE_PLUGIN_ROOT repointed at an attacker-chosen tree" '
for blk, i, hk in rows():
    if is_gate(hk):
        hk["args"] = ["CLAUDE_PLUGIN_ROOT=/tmp/evil" if x.startswith("CLAUDE_PLUGIN_ROOT=") else x
                      for x in hk["args"]]
        break
'
mutate "duplicated assignment with a divergent second value" '
for blk, i, hk in rows():
    if is_gate(hk):
        a = hk["args"]; a.insert(a.index("/bin/bash"), "CLAUDE_PLUGIN_ROOT=/tmp/evil")
        break
'
mutate "CODEX_WARN_OUTER_BUDGET dropped from pre-merge-gate" '
for blk, i, hk in rows():
    if "pre-merge-gate.sh" in list(hk.get("args") or []):
        hk["args"] = [x for x in hk["args"] if not x.startswith("CODEX_WARN_OUTER_BUDGET=")]
        break
'
mutate "pre-merge-gate timeout drifts away from its advisory budget" '
for blk, i, hk in rows():
    if "pre-merge-gate.sh" in list(hk.get("args") or []):
        hk["timeout"] = 5
        break
'

# ── Wrapper operand ─────────────────────────────────────────────────────────────────
mutate "wrapper operand suffixed .disabled (counted, but exits 127 = fail-open)" '
for blk, i, hk in rows():
    if is_gate(hk):
        hk["args"] = [x + ".disabled" if x.endswith("sanitized-gate.sh") else x for x in hk["args"]]
        break
'
mutate "wrapper operand unrooted (absolute path outside the plugin)" '
for blk, i, hk in rows():
    if is_gate(hk):
        hk["args"] = ["/tmp/sanitized-gate.sh" if x.endswith("/sanitized-gate.sh") else x
                      for x in hk["args"]]
        break
'
mutate "/bin/bash replaced by a bare bash (reintroduces the PATH lookup)" '
for blk, i, hk in rows():
    if is_gate(hk):
        hk["args"] = ["bash" if x == "/bin/bash" else x for x in hk["args"]]
        break
'

# ── Population counts ───────────────────────────────────────────────────────────────
# Detection is a substring match, so any mutation that removes the wrapper reference also
# removes the row from the guarded population. The counts are what make that fail-closed.
mutate "a contained registration deleted outright" '
for blk, i, hk in rows():
    if is_gate(hk):
        del blk["hooks"][i]
        break
'
mutate "a gate given the nudge exemption command verbatim" '
tgt = None
for blk, i, hk in rows():
    if is_nudge(hk):
        tgt = hk["command"]
for blk, i, hk in rows():
    if is_gate(hk):
        blk["hooks"][i] = {"type": "command", "command": tgt, "timeout": 20}
        break
'
mutate "a nudge migrated to exec form (drops its PR_GRIND kill switch)" '
for blk, i, hk in rows():
    if is_nudge(hk):
        blk["hooks"][i] = {"type": "command", "command": "/usr/bin/env", "args": [
            "-i", "PATH=/usr/bin:/bin", "CLAUDE_PLUGIN_ROOT=${CLAUDE_PLUGIN_ROOT}", "/bin/bash",
            "${CLAUDE_PLUGIN_ROOT}/hooks/gate-scripts/lib/sanitized-gate.sh",
            "codex-nudge-premerge.sh"], "timeout": 20}
        break
'
mutate "a nudge command drifted by one element" '
for blk, i, hk in rows():
    if is_nudge(hk):
        hk["command"] = hk["command"].replace("PATH=/usr/bin:/bin", "PATH=/usr/bin:/bin:/tmp")
        break
'
mutate "a nudge registration deleted outright" '
for blk, i, hk in rows():
    if is_nudge(hk):
        del blk["hooks"][i]
        break
'

# ── Roster: identity and event, not just counts ─────────────────────────────────────
mutate "one gate swapped for a duplicate of another (counts unchanged)" '
tgt = None
for blk, i, hk in rows():
    if is_gate(hk) and "careful-guard.sh" in hk["args"]:
        tgt = list(hk["args"])
for blk, i, hk in rows():
    if is_gate(hk) and "pre-pr-gate.sh" in hk["args"]:
        hk["args"] = tgt
        break
'
mutate "a gate moved to an event that never fires for it" '
src = None
for blk, i, hk in rows():
    if is_gate(hk) and "pre-pr-gate.sh" in list(hk.get("args") or []):
        src = (blk, i, hk)
        break
evs = doc.get("hooks", doc)
evs["PostToolUse"][0].setdefault("hooks", []).append(src[2])
del src[0]["hooks"][src[1]]
'
mutate "a gate re-pointed at a matcher it never sees" '
for blk, i, hk in rows():
    if is_gate(hk) and "pre-pr-gate.sh" in list(hk.get("args") or []):
        blk["matcher"] = "NoSuchToolEver"
        break
'
mutate "a node gate narrowed to fewer profiles (drops standard-profile users)" '
for blk, i, hk in rows():
    a = list(hk.get("args") or [])
    if "scripts/hooks/config-protection.js" in a:
        hk["args"] = ["strict" if x == "standard,strict" else x for x in a]
        break
'
mutate "a node gate re-pointed at a different runner script" '
for blk, i, hk in rows():
    a = list(hk.get("args") or [])
    if "scripts/hooks/config-protection.js" in a:
        hk["args"] = ["scripts/hooks/block-no-verify.js" if x.endswith("config-protection.js") else x
                      for x in a]
        break
'
mutate "a fail-CLOSED node gate flipped to --fail-open" '
for blk, i, hk in rows():
    a = list(hk.get("args") or [])
    if "scripts/hooks/block-no-verify.js" in a:
        bi = a.index("/bin/bash")
        hk["args"] = a[:bi+2] + ["--fail-open"] + a[bi+2:]
        break
'
mutate "a gate given timeout 0 (killed before it can decide)" '
for blk, i, hk in rows():
    if is_gate(hk) and "careful-guard.sh" in list(hk.get("args") or []):
        hk["timeout"] = 0
        break
'
mutate "pre-merge timeout AND its budget lowered together (stays self-consistent)" '
for blk, i, hk in rows():
    if "pre-merge-gate.sh" in list(hk.get("args") or []):
        hk["timeout"] = 2
        hk["args"] = ["CODEX_WARN_OUTER_BUDGET=2" if x.startswith("CODEX_WARN_OUTER_BUDGET=") else x
                      for x in hk["args"]]
        break
'

# ── Property sweep: EVERY single-element deletion and duplication ───────────────────
# The cases above are hand-picked, so they can only catch holes someone already imagined.
# This sweep is exhaustive over one registration's argv: for each index, delete that element
# and separately duplicate it, and require the validator to reject BOTH. It is what found
# that a dropped `CLAUDE_PLUGIN_ROOT=` assignment used to pass every grammar rule while
# leaving the wrapper unable to resolve its gate (exit 1 — non-blocking).
_len=$(python3 - "$HOOKS_JSON" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
for blocks in doc.get("hooks", doc).values():
    for blk in blocks:
        for hk in blk.get("hooks", []):
            a = hk.get("args")
            if isinstance(a, list) and any("sanitized-gate.sh" in str(x) for x in a):
                print(len(a)); raise SystemExit
print(0)
PY
) || _len=0
_rc=1; [[ "$_len" -ge 6 ]] && _rc=0
assert "$_rc" "sweep target found: a contained gate with $_len argv elements"

_swept=0
for ((_k = 0; _k < _len; _k++)); do
    for _op in delete duplicate; do
        mutate "sweep: $_op argv[$_k]" "
_k = $_k
for blk, i, hk in rows():
    if is_gate(hk):
        a = list(hk['args'])
        hk['args'] = a[:_k] + a[_k+1:] if '$_op' == 'delete' else a[:_k] + [a[_k]] + a[_k:]
        break
"
        _swept=$((_swept + 1))
    done
done
_rc=1; [[ "$_swept" -eq $((_len * 2)) ]] && _rc=0
assert "$_rc" "sweep ran every index in both directions ($_swept mutations)"

# ── The first hop itself: CI runs it, so weakening it must fail CI ──────────────────
# R7 lives in this file, not in hooks.json, so a hooks.json-only mutation matrix would leave
# the actual defence unproven. The validator probes the real script on every run; these rows
# are what show that probe can fail.
rm -rf "$SANDBOX"
mkdir -p "$SANDBOX/scripts/ci" "$SANDBOX/hooks/gate-scripts/lib" "$SANDBOX/schemas"
cp "$VALIDATOR" "$SANDBOX/scripts/ci/validate-hooks.js" \
    && cp "$HOOKS_JSON" "$SANDBOX/hooks/hooks.json"
_sandbox_ok=$?
# The schema is optional in this repo (the validator guards its read with existsSync), so
# copy it only when it exists rather than failing setup over a file that may not be there.
if [[ "$_sandbox_ok" -eq 0 && -f "$REPO_ROOT/schemas/hooks.schema.json" ]]; then
    cp "$REPO_ROOT/schemas/hooks.schema.json" "$SANDBOX/schemas/hooks.schema.json"
    _sandbox_ok=$?
fi
_rc=1; [[ "$_sandbox_ok" -eq 0 ]] && _rc=0
assert "$_rc" "sandbox tree built (no tracked file is mutated by the rows below)"

SANDBOX_VALIDATOR="$SANDBOX/scripts/ci/validate-hooks.js"
SANDBOX_LAUNCHER="$SANDBOX/hooks/gate-scripts/lib/contained-launch.sh"

launcher_mutation() {  # launcher_mutation <name> <sed-expression>
    if ! sed "$2" "$LAUNCHER" > "$SANDBOX_LAUNCHER" || ! chmod +x "$SANDBOX_LAUNCHER"; then
        # A setup failure would ALSO be rejected by the validator, so scoring it as a
        # rejection would count broken plumbing as coverage. Report it as its own failure.
        assert 1 "$1 — SKIPPED: could not build the mutated launcher in the sandbox"
        return
    fi
    if node "$SANDBOX_VALIDATOR" "$SANDBOX/hooks/hooks.json" >/dev/null 2>&1; then
        assert 1 "$1 — ESCAPED the validator"
    else
        assert 0 "$1 — rejected"
    fi
}

# The sandbox must pass BEFORE anything is mutated in it, or every rejection below could be
# an artefact of a bad copy rather than of the mutation.
cp "$LAUNCHER" "$SANDBOX_LAUNCHER" && chmod +x "$SANDBOX_LAUNCHER"
node "$SANDBOX_VALIDATOR" "$SANDBOX/hooks/hooks.json" >/dev/null 2>&1
assert $? "control: the UNMUTATED sandbox passes (so the rejections below are the mutations)"

launcher_mutation "launcher no-arg path weakened to exit 0 (R7 reopened)" 's/^    exit 2$/    exit 0/'
launcher_mutation "launcher no-arg path made to print the environment" 's|^    exit 2$|    /usr/bin/env; exit 2|'
launcher_mutation "launcher privileged mode dropped from the shebang" '1s|^#!/bin/bash -p$|#!/bin/bash|'

# ── PARTIAL argument loss, the side door into R7 ────────────────────────────────────
# `env -i NAME=value` with no utility does not fail: it applies the assignments, PRINTS the
# environment and exits 0. So dropping the tail only partway — keeping the disposition and
# some assignments — used to yield an allow plus an environment dump from the very hop added
# to stop exactly that. Asserted directly against the launcher, because no hooks.json shape
# can express "the client kept three of my six args".
for _tail in "closed" "closed PATH=/usr/bin:/bin" "closed PATH=/usr/bin:/bin A=1" "open PATH=/usr/bin:/bin"; do
    # shellcheck disable=SC2086  # $_tail is a deliberate argv split, not a path
    _out="$("$LAUNCHER" $_tail </dev/null 2>/dev/null)"; _prc=$?
    _rc=1; [[ "$_prc" -eq 2 ]] && _rc=0
    assert "$_rc" "partial argv [$_tail] fails CLOSED (exit 2, got $_prc)"
    _rc=1; [[ -z "$_out" ]] && _rc=0
    assert "$_rc" "partial argv [$_tail] prints no environment on stdout"
done
# A relative program would be resolved by a PATH lookup inside the sterile child.
"$LAUNCHER" closed PATH=/usr/bin:/bin bash -c true </dev/null >/dev/null 2>&1
_prc=$?
_rc=1; [[ "$_prc" -eq 2 ]] && _rc=0
assert "$_rc" "a non-absolute program is refused, failing CLOSED (got $_prc)"
# ── STDIN-READING OPERANDS, the arity check's blind spot ───────────────────────────
# The "at least one operand" rule above is satisfied by `/bin/bash --`, `-s` and `-i` — each
# is exactly one operand, and each leaves bash reading its source from STDIN, i.e. from the
# hook payload. `/bin/bash /dev/stdin` does the same while being absolute, so a path-shape
# rule alone does not catch it either. Assert exit 2, an empty stdout, AND that the payload's
# command substitution never ran: a rejection that still executed the payload is not a fix.
#
# The second half of the list is the SPELLING sweep, and it is the half that found a real
# hole. A rule written as `case … in /dev/stdin|/dev/fd/*)` compares strings, so it refused
# the canonical name and let `/dev/./stdin`, `/dev//stdin`, `/dev/../dev/stdin` and
# `/dev/fd/../fd/0` through to bash — each of them measured executing the payload and exiting
# 0. Enumerating spellings is not the fix (there are infinitely many), but enumerating a few
# here is what keeps the shape rule that replaced it honest: every entry below must be refused
# by a rule about path SHAPE, never by having been listed.
#
# `-c` is in the list for completeness, not because it reads stdin: bash exits 2 with
# "option requires an argument" and never opens fd 0 (measured). It is refused here by the
# absolute-path rule, one door earlier, and would fail closed even without these rules.
_STDIN_SENTINEL="$TMP/stdin-operand-executed"
_STDIN_PAYLOAD="$(printf '{"tool_input":{"command":"x"}}\n$(touch %s)\n' "$_STDIN_SENTINEL")"
for _op in -- -s -i -c /dev/stdin /dev/fd/0 \
           /dev/./stdin /dev//stdin /dev/../dev/stdin /dev/fd/../fd/0 /proc/self/fd/0; do
    rm -f "$_STDIN_SENTINEL"
    printf '%s' "$_STDIN_PAYLOAD" > "$TMP/stdin-operand-payload"
    _out="$("$LAUNCHER" closed PATH=/usr/bin:/bin /bin/bash "$_op" \
        <"$TMP/stdin-operand-payload" 2>/dev/null)"
    _prc=$?
    _rc=1; [[ "$_prc" -eq 2 ]] && _rc=0
    assert "$_rc" "stdin-reading operand [/bin/bash $_op] fails CLOSED (exit 2, got $_prc)"
    _rc=1; [[ -z "$_out" ]] && _rc=0
    assert "$_rc" "stdin-reading operand [/bin/bash $_op] writes nothing to stdout"
    _rc=1; [[ ! -e "$_STDIN_SENTINEL" ]] && _rc=0
    assert "$_rc" "stdin-reading operand [/bin/bash $_op] never executes the payload"
done
rm -f "$_STDIN_SENTINEL"
# ── NESTED INTERPRETERS, where operand rules cannot reach ──────────────────────────
# Every rule above constrains the first OPERAND, which only helps while the program being
# launched is the interpreter that would read it. `/usr/bin/env /bin/bash -s` breaks that
# assumption from the outside: the program is absolute, the first operand is `/bin/bash` (as
# unimpeachable as an operand gets), and the inner `env` then runs `bash -s` on the payload.
# Measured before the interpreter pin: the payload ran and the launcher exited 0. Chaining is
# unbounded, so these rows assert the refusal comes from the PIN — the only rule that does not
# have to imagine the shape in advance.
for _chain in "/usr/bin/env /bin/bash -s" "/usr/bin/env /bin/bash" "/bin/sh /bin/bash -s"; do
    rm -f "$_STDIN_SENTINEL"
    printf '%s' "$_STDIN_PAYLOAD" > "$TMP/stdin-operand-payload"
    # shellcheck disable=SC2086  # deliberate word split: $_chain is a fixed argv, not user input
    _err="$("$LAUNCHER" closed PATH=/usr/bin:/bin $_chain \
        <"$TMP/stdin-operand-payload" 2>&1 >"$TMP/stdin-operand-stdout")"
    _prc=$?
    _out="$(cat "$TMP/stdin-operand-stdout")"
    _rc=1; [[ "$_prc" -eq 2 && -z "$_out" && ! -e "$_STDIN_SENTINEL" ]] && _rc=0
    assert "$_rc" "nested interpreter [$_chain] fails CLOSED, silent, payload unfired (got $_prc)"
    _rc=1; [[ "$_err" == *'names'*'/bin/bash as the interpreter'* ]] && _rc=0
    assert "$_rc" "nested interpreter [$_chain] is refused BY THE INTERPRETER PIN"
done
rm -f "$_STDIN_SENTINEL"

# ── GENERATED spellings, because a hand-written list is what failed here twice ──────
# The list above is a list, and both holes in this rule were found by someone thinking of a
# spelling nobody had listed. So generate the space instead of enumerating it: every
# combination of a slash run, a dot-segment prefix and a descriptor name is a different string
# naming the same file, and all of them must be refused by a rule about SHAPE. A future edit
# that reverts to matching names will fail dozens of these at once rather than passing because
# it happened to cover the six that were written down.
#
# Each row also asserts WHICH RULE refused it, and that is not decoration. Most of these
# spellings name nothing that exists — `/dev/anydir/../stdin` fails pathname resolution at
# `anydir` long before `..` is reached — and a nonexistent operand under the `closed`
# disposition produces exit 2, no output and no sentinel all by itself, because bash's 127 is
# converted. That is the success condition, so a status-only row would stay green with the
# path-shape guard deleted entirely. Naming the expected refusal is what makes the row test
# the guard rather than the disposition.
for _name in stdin fd/0; do
    for _sep in / // ///; do
        for _prefix in '' . ./. anydir/..; do
            _spelling="/dev${_sep}${_prefix:+$_prefix/}${_name}"
            # A dot segment is refused for BEING a dot segment, before anything looks at the
            # filesystem; everything else survives to the tree test.
            case "$_prefix" in
                '') _want='it is under /dev or /proc' ;;
                *)  _want="carries a '.' or '..' segment" ;;
            esac
            rm -f "$_STDIN_SENTINEL"
            printf '%s' "$_STDIN_PAYLOAD" > "$TMP/stdin-operand-payload"
            _err="$("$LAUNCHER" closed PATH=/usr/bin:/bin /bin/bash "$_spelling" \
                <"$TMP/stdin-operand-payload" 2>&1 >"$TMP/stdin-operand-stdout")"
            _prc=$?
            _out="$(cat "$TMP/stdin-operand-stdout")"
            _rc=1; [[ "$_prc" -eq 2 && -z "$_out" && ! -e "$_STDIN_SENTINEL" ]] && _rc=0
            assert "$_rc" \
                "generated spelling [$_spelling] fails CLOSED, silent, payload unfired (got $_prc)"
            _rc=1; [[ "$_err" == *"$_want"* ]] && _rc=0
            assert "$_rc" "generated spelling [$_spelling] is refused for the right reason"
        done
    done
done
rm -f "$_STDIN_SENTINEL"
# ── FILESYSTEM ALIASES, where the lexical rule alone is not enough ──────────────────
# Every check above reads the path as text; the regular-file check that follows them FOLLOWS
# SYMLINKS. So an alias reaches the descriptor without spelling it, and both shapes were
# measured executing the payload and exiting 0 before this was closed: a symlinked FINAL
# component, and a symlinked DIRECTORY component. They are refused by two different rules —
# the final component because a symlink is refused outright, the directory because it is
# resolved with `cd -P`/`pwd -P` before the tree test — so both need their own row.
#
# Two things about these rows are load-bearing and were both got wrong first time.
#
# The setup MUST be asserted. Every success condition below — exit 2, empty stdout, no
# sentinel — is ALSO what a missing wrapper produces under the `closed` disposition, which
# converts bash's 127. So an `ln` that silently failed would leave these rows green while
# testing nothing at all: a security test that passes because its fixture is absent.
#
# And the directory row cannot be isolated by choosing a clever target, which is where two
# attempts at it went wrong. Naming `stdin` under the aliased directory is refused by `-L` one
# rule early, because `/dev/stdin` is itself a symlink on both platforms. Naming `fd/0` is
# worse than it looks: on Linux `/dev/fd` resolves through `/proc/self/fd` and the entries
# there are symlinks too, so the row passes for the wrong reason on macOS and fails outright
# on CI. And every remaining entry under `/dev` is a device node, which the regular-file rule
# would refuse on its own even with the directory defence deleted.
#
# So isolate on the REFUSAL, not on the fixture: assert which rule spoke. `/dev/null` exists
# and is not a symlink everywhere this runs, and the physical-directory rule is the only one
# that says "its directory resolves to". Delete that rule and the row goes red on the message
# even though the status would still be 2 — which is exactly the discrimination the fixture
# could not give us portably. (Verified in both directions against a sandbox copy of the
# launcher with only the `physical_dir=` block neutered: the alias then executed the payload
# and exited 0.)
ln -sf /dev/stdin "$TMP/alias-to-stdin"
_rc=1; [[ -L "$TMP/alias-to-stdin" ]] && _rc=0
assert "$_rc" "fixture: the final-component alias was actually created as a symlink"
rm -rf "$TMP/alias-to-dev" && ln -sf /dev "$TMP/alias-to-dev"
_rc=1; [[ -L "$TMP/alias-to-dev" && -e "$TMP/alias-to-dev/null" ]] && _rc=0
assert "$_rc" "fixture: the directory alias was created and resolves into /dev"
_err="$("$LAUNCHER" closed PATH=/usr/bin:/bin /bin/bash "$TMP/alias-to-dev/null" </dev/null 2>&1 >/dev/null)"
_rc=1; [[ "$_err" == *"its directory resolves to"* ]] && _rc=0
assert "$_rc" "the directory alias is refused BY THE PHYSICAL-DIRECTORY RULE, not by a later one"
for _alias in "$TMP/alias-to-stdin" "$TMP/alias-to-dev/null"; do
    rm -f "$_STDIN_SENTINEL"
    printf '%s' "$_STDIN_PAYLOAD" > "$TMP/stdin-operand-payload"
    _out="$("$LAUNCHER" closed PATH=/usr/bin:/bin /bin/bash "$_alias" \
        <"$TMP/stdin-operand-payload" 2>/dev/null)"
    _prc=$?
    _rc=1; [[ "$_prc" -eq 2 ]] && _rc=0
    assert "$_rc" "symlink alias [${_alias##*/tmp.}] fails CLOSED (exit 2, got $_prc)"
    _rc=1; [[ -z "$_out" ]] && _rc=0
    assert "$_rc" "symlink alias [${_alias##*/tmp.}] writes nothing to stdout"
    _rc=1; [[ ! -e "$_STDIN_SENTINEL" ]] && _rc=0
    assert "$_rc" "symlink alias [${_alias##*/tmp.}] never executes the payload"
done
rm -f "$_STDIN_SENTINEL"
# The alias rules must not swallow R8 either, and this is the case that distinguishes
# "refuse what cannot be resolved" from "refuse what resolves somewhere dangerous": a wrapper
# under a directory that does not exist has no physical path at all. It still has to reach
# bash, become a 127, and let the disposition decide — otherwise the containment rule has
# quietly retired R8 for every registration whose plugin root is temporarily absent.
"$LAUNCHER" open PATH=/usr/bin:/bin /bin/bash "$TMP/absent-dir/wrapper.sh" x </dev/null >/dev/null 2>&1
_prc=$?
_rc=1; [[ "$_prc" -eq 0 ]] && _rc=0
assert "$_rc" "a wrapper under a MISSING directory still reaches bash; open allows (got $_prc)"
# The same rule must not swallow R8: a MISSING wrapper is absolute and non-existent, so it
# still reaches bash, still becomes a 127, and the disposition still decides it. Asserting
# both halves here keeps the containment rule from quietly becoming a policy change on the
# two `open` rows.
"$LAUNCHER" open PATH=/usr/bin:/bin /bin/bash "$TMP/absent-wrapper.sh" x </dev/null >/dev/null 2>&1
_prc=$?
_rc=1; [[ "$_prc" -eq 0 ]] && _rc=0
assert "$_rc" "a missing wrapper still reaches bash and the open disposition allows (got $_prc)"
# Positive control: the full argv still runs, so the rows above are not just "everything blocks".
printf '#!/bin/bash\nexit 0\n' > "$TMP/control-wrapper.sh" && chmod +x "$TMP/control-wrapper.sh"
"$LAUNCHER" closed PATH=/usr/bin:/bin /bin/bash "$TMP/control-wrapper.sh" </dev/null >/dev/null 2>&1
_prc=$?
_rc=1; [[ "$_prc" -eq 0 ]] && _rc=0
assert "$_rc" "control: the complete argv still runs and allows (got $_prc)"

# ── EXHAUSTIVE truncation sweep over a REAL registration argv ───────────────────────
# Hand-picked partial shapes are guesses. This takes an actual registration out of
# hooks.json and feeds the launcher every proper prefix of it, requiring each to fail CLOSED
# with an empty stdout AND no side effect from the payload. It is what catches the prefix a
# human list misses — the one ending exactly at `/bin/bash`, where bash has no script operand
# and reads its source from STDIN, i.e. from the hook payload. Before that guard existed the
# payload below created the sentinel and the launcher returned 0: code execution and an
# allow from the same truncation.
_argv_raw="$(python3 - "$HOOKS_JSON" "$REPO_ROOT" <<'PY'
import json, sys
doc, root = json.load(open(sys.argv[1])), sys.argv[2]
for blocks in doc.get("hooks", doc).values():
    for blk in blocks:
        for hk in blk.get("hooks", []):
            args = hk.get("args")
            if isinstance(args, list) and any("sanitized-gate.sh" in str(a) for a in args):
                for a in args:
                    print(str(a).replace("${CLAUDE_PLUGIN_ROOT}", root))
                raise SystemExit
PY
)" || _argv_raw=""
_full=()
while IFS= read -r _el; do _full+=("$_el"); done <<<"$_argv_raw"
_rc=1; [[ ${#_full[@]} -ge 5 ]] && _rc=0
assert "$_rc" "sweep target: a real registration argv with ${#_full[@]} elements"

SENTINEL="$TMP/payload-executed"
# A payload whose command substitution runs only if something interprets it as shell source.
PAYLOAD="$(printf '{"tool_input":{"command":"x"}}\n$(touch %s)\n' "$SENTINEL")"

_trunc_bad=0
for ((_k = 1; _k < ${#_full[@]}; _k++)); do
    rm -f "$SENTINEL"
    # printf's status is masked by the pipeline; capture the payload once instead of
    # re-deriving it inside the substitution on every iteration.
    printf '%s' "$PAYLOAD" > "$TMP/payload.json"
    _out="$("$LAUNCHER" "${_full[@]:0:$_k}" <"$TMP/payload.json" 2>/dev/null)"
    _trc=$?
    if [[ "$_trc" -ne 2 || -n "$_out" || -e "$SENTINEL" ]]; then
        _trunc_bad=$((_trunc_bad + 1))
        printf '       prefix len %d: rc=%d stdout=%d sentinel=%s\n' \
            "$_k" "$_trc" "${#_out}" "$([[ -e "$SENTINEL" ]] && echo YES || echo no)"
    fi
done
rm -f "$SENTINEL"
_rc=1; [[ "$_trunc_bad" -eq 0 ]] && _rc=0
assert "$_rc" "every proper prefix of a real argv fails CLOSED, silent, with no payload execution ($_trunc_bad bad)"

# Positive control for the sweep: the COMPLETE argv must still run, or the loop above proves
# only that the launcher rejects everything.
rm -f "$SENTINEL"
printf '%s' "$PAYLOAD" | "$LAUNCHER" "${_full[@]}" >/dev/null 2>&1
_full_rc=$?
_rc=1; [[ "$_full_rc" -eq 0 || "$_full_rc" -eq 2 ]] && _rc=0
assert "$_rc" "control: the complete argv reaches the gate and yields a decision (rc=$_full_rc)"
_rc=1; [[ ! -e "$SENTINEL" ]] && _rc=0
assert "$_rc" "control: the complete argv does not execute the payload either"
rm -f "$SENTINEL"

# The real tree was never touched — assert that, rather than assuming it.
node "$VALIDATOR" "$HOOKS_JSON" >/dev/null 2>&1
assert $? "control: the REAL launcher still passes (the rows above never wrote to it)"

printf '\nPASS=%d FAIL=%d\n' "$PASS" "$FAIL"
if [[ "$FAIL" -eq 0 ]]; then
    printf 'ALL #713 VALIDATOR MUTATIONS REJECTED\n'; exit 0
fi
exit 1
