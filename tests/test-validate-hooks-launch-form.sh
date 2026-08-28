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
# The launcher-mutation rows below overwrite a TRACKED file in place — the validator
# resolves contained-launch.sh relative to its own location and takes no override for it, by
# design (an overridable first-hop path would be a hole, not a feature). A byte-exact backup
# is taken before any of that and restored here, on every exit path including a signal.
LAUNCHER="$REPO_ROOT/hooks/gate-scripts/lib/contained-launch.sh"
LAUNCHER_BAK="$TMP/contained-launch.sh.bak"
restore_launcher() {
    if [[ -f "$LAUNCHER_BAK" ]]; then
        cp "$LAUNCHER_BAK" "$LAUNCHER" && chmod +x "$LAUNCHER"
    fi
}
# The signal handler must EXIT, not fall through. A bare `trap '<cleanup>' INT TERM` runs the
# cleanup and then resumes the script — which here would mean the backup has just been
# deleted with `rm -rf "$TMP"` while the mutation loop below is still going, and the very
# next `sed … > "$LAUNCHER"` truncates the tracked launcher before sed fails to read the
# vanished backup. Restore, clean, and leave.
trap 'restore_launcher; rm -rf "$TMP"' EXIT
trap 'restore_launcher; rm -rf "$TMP"; exit 130' INT
trap 'restore_launcher; rm -rf "$TMP"; exit 143' TERM

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
cp "$LAUNCHER" "$LAUNCHER_BAK"
_rc=1; [[ -s "$LAUNCHER_BAK" ]] && _rc=0
assert "$_rc" "launcher backed up before the in-place mutations below"

launcher_mutation() {  # launcher_mutation <name> <sed-expression>
    # Re-check the backup on EVERY call, not once up front. The redirection below truncates
    # a tracked file, so it must never run when the only copy of the original is gone — a
    # failed `cp`, a signal that already cleaned $TMP, anything. Refuse instead.
    if [[ ! -s "$LAUNCHER_BAK" ]]; then
        assert 1 "$1 — SKIPPED: no launcher backup, refusing to truncate the tracked file"
        return
    fi
    # Build the mutation elsewhere and move it into place, so a failing `sed` cannot leave a
    # truncated launcher behind: `> "$LAUNCHER"` empties the file before sed writes anything.
    if ! sed "$2" "$LAUNCHER_BAK" > "$TMP/mutated-launcher.sh"; then
        assert 1 "$1 — SKIPPED: could not build the mutated launcher"
        return
    fi
    if ! cp "$TMP/mutated-launcher.sh" "$LAUNCHER" || ! chmod +x "$LAUNCHER"; then
        # A partial copy leaves a damaged launcher the validator would also reject — the row
        # would then be scored as a successful rejection while proving nothing. Restore and
        # report the setup failure instead of counting it as coverage.
        assert 1 "$1 — SKIPPED: could not install the mutated launcher"
        restore_launcher
        return
    fi
    if node "$VALIDATOR" "$HOOKS_JSON" >/dev/null 2>&1; then assert 1 "$1 — ESCAPED the validator"
    else assert 0 "$1 — rejected"; fi
    restore_launcher
}

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
# Positive control: the full argv still runs, so the rows above are not just "everything blocks".
"$LAUNCHER" closed PATH=/usr/bin:/bin /bin/bash -c 'exit 0' </dev/null >/dev/null 2>&1
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
    _out="$(printf '%s' "$PAYLOAD" | "$LAUNCHER" "${_full[@]:0:$_k}" 2>/dev/null)"
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

# Positive control: the restored launcher must pass, or every row above is meaningless.
node "$VALIDATOR" "$HOOKS_JSON" >/dev/null 2>&1
assert $? "control: the restored launcher PASSES again (the mutations above were the cause)"

printf '\nPASS=%d FAIL=%d\n' "$PASS" "$FAIL"
if [[ "$FAIL" -eq 0 ]]; then
    printf 'ALL #713 VALIDATOR MUTATIONS REJECTED\n'; exit 0
fi
exit 1
