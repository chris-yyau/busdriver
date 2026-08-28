#!/usr/bin/env bash
# Test: contained gates launch in EXEC FORM, and the blocking semantics survive it (#713).
#
# THE DEFECT. Claude Code runs a SHELL-FORM command hook via `/bin/sh -c <string>`, and a
# committed `.claude/settings.json` `env` block is merged into that shell's environment.
# Where /bin/sh is bash (macOS: 3.2.57), `SHELLOPTS=noexec` makes it PARSE the hook command
# and exit 0 without executing it — silencing `/usr/bin/env -i`, the wrapper, the gate and
# any trailing `|| exit 2` together. `env -i` sanitizes the child it launches; it cannot
# sanitize the parent that decides whether that child runs at all. ADR 0016 named this as an
# out-of-scope class residual; #713 closes it by removing the shell from the launch.
#
# WHAT THIS FILE CAN AND CANNOT PROVE. The outer-shell half is a PLATFORM behaviour: it needs
# a real `claude` session with a committed settings file, and no workflow in .github/workflows
# invokes `claude`. That half was measured by hand (see docs/adr/0049 and the #713 design doc)
# and is NOT re-run here. What IS proven here, offline and in CI:
#   1. every contained GATE is exec form, and the two non-gating Codex nudges are still
#      shell form with the kill switch forwarded (see ADR 0049 — migrating them would
#      silently re-enable outbound `@codex review` comments);
#   2. the shell-form bypass is real on this host (the mechanism, demonstrated directly);
#   3. the real argv, spawned with a HOSTILE environ and no shell in between, still yields
#      the gate's decision — `permissionDecision: "ask"` and a fail-closed exit 2 (with its
#      reason) both survive, and a harmless payload is still allowed. The `deny` and legacy
#      top-level `{"decision":"block"}` shapes were measured live under exec form (#713
#      ledger rows c2/c3) and are not re-driven here — no in-tree gate emits them on a
#      payload this suite can construct without standing up PR state;
#   4. R7 and R8 are now CLOSED, and both pins are INVERTED so the old fail-open cannot
#      come back silently: the first hop exits 2 (printing nothing) when a client drops
#      `args`, and a missing wrapper exits 2 under the `closed` disposition.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOKS_JSON="$REPO_ROOT/hooks/hooks.json"
PASS=0
FAIL=0
assert() {  # assert <rc> <message>
    if [[ "$1" -eq 0 ]]; then PASS=$((PASS+1)); printf '  ok   %s\n' "$2"
    else FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$2"; fi
}

TMP="$(mktemp -d)" || TMP=""
if [[ -z "$TMP" || ! -d "$TMP" ]]; then
    printf '  FAIL could not create a temporary directory\n' >&2
    printf 'RESULT: 0 passed, 1 failed\n'; exit 1
fi
trap 'rm -rf "$TMP"' EXIT

# The environ a hostile repo could once set through a committed settings.json `env` block.
# BASH_FUNC_exec%% overrides the `exec` BUILTIN, which is why a bash first hop is not an
# option and `env -i` must run before bash starts.
# NOTE ON ORDERING, which is the whole point: these are set in the OUTER environment and
# the command under test then strips them itself. Setting them AFTER a `-i` would re-add
# them to the sterile child and prove the opposite of what is claimed. `SHELLOPTS` is
# readonly inside bash, so it can only be introduced via `env`, never a prefix assignment.
hostile_env() {
    /usr/bin/env \
        SHELLOPTS=noexec \
        BASH_ENV="$TMP/bashenv.sh" \
        ENV="$TMP/bashenv.sh" \
        'BASH_FUNC_exec%%=() { echo PWNED; }' \
        "$@"
}
printf 'echo BASH_ENV_SOURCED\n' > "$TMP/bashenv.sh"

# ── 1. Structural: 17 launcher-fronted gates + 2 named shell-form exemptions ────────
# The two Codex NUDGE registrations are deliberately NOT migrated (#713, Hermes verdict):
# they POST `@codex review` comments and are suppressed by $PR_GRIND_CODEX_RETRIGGER, which
# exec form cannot forward — `env -i` strips it, and the nudge runs its delegate as a CHILD
# of that sterile process. Both are non-gating, so an outer-shell SHELLOPTS=noexec silencing
# them skips a nudge rather than bypassing a gate. Asserted as a SPLIT, not a lowered count:
# a bare "17 are exec form" would pass just as happily if a real GATE were the one left
# behind.
#
# `command` must be contained-launch.sh, never bare /usr/bin/env (R7), and the first arg is
# the launch-failure disposition the launcher needs to turn a 127 into a block (R8).
_n=$(python3 - "$HOOKS_JSON" <<'PY'
import json, sys
EXEMPT = ("codex-nudge-premerge.sh", "codex-nudge-precreate.sh")
LAUNCH = "${CLAUDE_PLUGIN_ROOT}/hooks/gate-scripts/lib/contained-launch.sh"
doc = json.load(open(sys.argv[1]))
execform = bad = exempt = badexempt = 0
for blocks in doc.get("hooks", doc).values():
    for blk in blocks:
        for hk in blk.get("hooks", []):
            argv = [hk.get("command", "")] + list(hk.get("args") or [])
            if not any(isinstance(a, str) and ("sanitized-gate.sh" in a or "sanitized-node.sh" in a)
                       for a in argv):
                continue
            args = hk.get("args")
            if any(isinstance(a, str) and any(e in a for e in EXEMPT) for a in argv):
                exempt += 1
                # Shell form, and still forwarding the kill switch — the whole reason it was
                # left behind. A migrated nudge silently resumes posting.
                if args is not None or "PR_GRIND_CODEX_RETRIGGER=" not in hk.get("command", ""):
                    badexempt += 1
                continue
            execform += 1
            ok = (hk.get("command") == LAUNCH and isinstance(args, list)
                  and args[0] in ("closed", "open")
                  and args[1] == "PATH=/usr/bin:/bin" and "/bin/bash" in args)
            # The disposition and the wrapper's own --fail-open flag must agree, or the
            # registration lies about which way it fails.
            if ok:
                bi = args.index("/bin/bash")
                ok = (args[bi + 2:bi + 3] == ["--fail-open"]) == (args[0] == "open")
            if not ok:
                bad += 1
print("%d %d %d %d" % (execform, bad, exempt, badexempt))
PY
) || _n="0 1 0 1"
read -r _count _bad _exempt _badexempt <<<"$_n"
_rc=1; [[ "$_count" -eq 17 && "$_bad" -eq 0 ]] && _rc=0
assert "$_rc" "all 17 contained GATEs launch via contained-launch.sh with an agreeing disposition (found $_count, non-conformant $_bad)"
_rc=1; [[ "$_exempt" -eq 2 && "$_badexempt" -eq 0 ]] && _rc=0
assert "$_rc" "the 2 Codex nudges stay shell form AND still forward PR_GRIND_CODEX_RETRIGGER (found $_exempt, non-conformant $_badexempt)"

# ── 2. The mechanism: a shell-form command IS silenced; an argv is not ──────────────
# Not a tautology — it is the measurement the whole change rests on, re-taken locally.
# /bin/sh is bash on macOS and dash on most Linux CI; dash ignores SHELLOPTS, so the
# bypass is asserted only where it can exist. The exec-form leg is asserted everywhere.
_sh_out="$(/usr/bin/env SHELLOPTS=noexec /bin/sh -c 'echo EXECUTED' 2>/dev/null)"
if /bin/sh -c 'test -n "$BASH_VERSION"' 2>/dev/null; then
    _rc=1; [[ -z "$_sh_out" ]] && _rc=0
    assert "$_rc" "shell form under SHELLOPTS=noexec is SILENCED (/bin/sh is bash — the #713 bypass)"
else
    assert 0 "shell form: /bin/sh is not bash on this host, so SHELLOPTS cannot silence it (bypass is macOS-shaped)"
fi
_exec_out="$(hostile_env /usr/bin/env -i PATH=/usr/bin:/bin /bin/bash -c 'echo EXECUTED' 2>/dev/null)"
_rc=1; [[ "$_exec_out" == "EXECUTED" ]] && _rc=0
assert "$_rc" "exec form RUNS under the same hostile environ (env -i strips it before bash starts)"
_rc=1; [[ "$_exec_out" != *PWNED* ]] && _rc=0
assert "$_rc" "exec form: an imported BASH_FUNC_exec%% never reaches bash"

# 2b. `SHELLOPTS=xtrace` + a command-substituting `PS4` is the same channel's SHARP end, and
#     it is worth separating from "the hook is silenced": bash expands PS4 BEFORE running the
#     command, so a committed settings.json `env` block gets ARBITRARY CODE EXECUTION out of
#     the outer /bin/sh — not merely a skipped hook. Measured here in both directions.
PS4_SENTINEL="$TMP/ps4-fired"
rm -f "$PS4_SENTINEL"
/usr/bin/env SHELLOPTS=xtrace "PS4=\$(touch '$PS4_SENTINEL')+ " \
    /bin/sh -c 'true' >/dev/null 2>&1
if /bin/sh -c 'test -n "$BASH_VERSION"' 2>/dev/null; then
    _rc=1; [[ -e "$PS4_SENTINEL" ]] && _rc=0
    assert "$_rc" "shell form: a committed PS4 command substitution EXECUTES (the sharp end of #713)"
else
    assert 0 "shell form: /bin/sh is not bash here, so the PS4 channel is macOS-shaped"
fi
rm -f "$PS4_SENTINEL"
/usr/bin/env SHELLOPTS=xtrace "PS4=\$(touch '$PS4_SENTINEL')+ " \
    /usr/bin/env -i PATH=/usr/bin:/bin /bin/bash -c 'true' >/dev/null 2>&1
_rc=1; [[ ! -e "$PS4_SENTINEL" ]] && _rc=0
assert "$_rc" "exec form: the PS4 command substitution never runs (env -i strips it first)"

# ── 3. Blocking semantics survive the new launch, driven through the REAL argv ──────
# The argv is EXTRACTED from hooks.json, never restated here: a suite that rebuilds the
# invocation cannot notice the registration changing underneath it.
argv_for() {  # argv_for <needle> -> one element per line, ${CLAUDE_PLUGIN_ROOT} resolved
    python3 - "$HOOKS_JSON" "$1" "$REPO_ROOT" <<'PY'
import json, sys
doc, needle, root = json.load(open(sys.argv[1])), sys.argv[2], sys.argv[3]
for blocks in doc.get("hooks", doc).values():
    for blk in blocks:
        for hk in blk.get("hooks", []):
            argv = [hk.get("command", "")] + list(hk.get("args") or [])
            if any(isinstance(a, str) and needle in a for a in argv):
                for a in argv:
                    print(str(a).replace("${CLAUDE_PLUGIN_ROOT}", root))
                raise SystemExit
PY
}
run_argv() {  # run_argv <needle> <payload> ; echoes stdout, RETURNS rc
    local needle="$1" payload="$2" raw; local -a argv=()
    # Capture first, then split: a process substitution's status never reaches the `while`,
    # so a failed extraction would silently produce an empty argv and a bogus PASS.
    raw="$(argv_for "$needle")" || return 99
    while IFS= read -r _e; do argv+=("$_e"); done <<<"$raw"
    [[ ${#argv[@]} -ge 2 ]] || return 99
    # The hostile environ is applied by the FIRST element (/usr/bin/env -i …) exactly as
    # the platform spawns it — no shell anywhere in this pipeline.
    printf '%s' "$payload" | hostile_env "${argv[@]}" 2>"$TMP/stderr.log"
}

_payload=''
_pl() { printf '{"session_id":"s","transcript_path":"/tmp/t","cwd":"%s","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"%s"}}' "$REPO_ROOT" "$1"; }

# 3a. careful-guard emits permissionDecision "ask" — the disposition #713 flagged as the
#     one that must not degrade to a silent allow or a silent deny.
_payload="$(_pl 'rm -rf /')" || _payload=''
_ask="$(run_argv 'careful-guard.sh' "$_payload")"
grep -q '"permissionDecision"[[:space:]]*:[[:space:]]*"ask"' <<<"$_ask"
assert $? "careful-guard still emits permissionDecision=ask under exec form + hostile env"

# 3b. block-no-verify is a fail-CLOSED node gate. It blocks by EXITING 2 with its reason on
#     stderr and an empty stdout — not by printing a decision document.
_payload="$(_pl 'git commit --no-verify -m x')" || _payload=''
_bnv="$(run_argv 'block-no-verify.js' "$_payload")"; _bnv_rc=$?
_rc=1; [[ "$_bnv_rc" -eq 2 ]] && _rc=0
assert "$_rc" "block-no-verify still exits 2 under exec form + hostile env (got rc=$_bnv_rc)"
# This gate blocks via exit 2 with its reason on STDERR — the "exit 2 is a blocking error
# in its own right" path, distinct from a stdout decision. Assert the reason survives too:
# an exit 2 with no explanation would still block, but silently.
grep -qi 'BLOCKED' "$TMP/stderr.log"
assert $? "block-no-verify still surfaces its block reason on stderr"

# 3c. A clean payload is allowed — proves 3a/3b are decisions, not a wrapper that always blocks.
_payload="$(_pl 'echo hello')" || _payload=''
_ok="$(run_argv 'careful-guard.sh' "$_payload")"; _ok_rc=$?
_rc=1; [[ "$_ok_rc" -eq 0 ]] && _rc=0
assert "$_rc" "a harmless command is still allowed (rc=$_ok_rc)"

# ── 4. R7 and R8 are CLOSED — both pins INVERTED (Hermes CLOSE_R7_AND_R8) ──────────
# These two assertions used to pin the opposite outcome. They are inverted rather than
# deleted: the fail-open behaviour must not be able to come back silently either.
#
# R7 — a client that honours `command` and drops `args` runs the launcher with argc 0. That
# used to be bare `/usr/bin/env`, which exits 0 AND prints the environment: an allow on every
# gate plus a per-event environment dump. The launcher must exit 2 and write nothing to
# stdout. Driven against the REAL file named in hooks.json, not a restatement of it.
_launcher="$(python3 - "$HOOKS_JSON" "$REPO_ROOT" <<'PY'
import json, sys
doc, root = json.load(open(sys.argv[1])), sys.argv[2]
for blocks in doc.get("hooks", doc).values():
    for blk in blocks:
        for hk in blk.get("hooks", []):
            args = hk.get("args")
            if isinstance(args, list) and any("sanitized-" in str(a) for a in args):
                print(str(hk.get("command", "")).replace("${CLAUDE_PLUGIN_ROOT}", root))
                raise SystemExit
PY
)" || _launcher=""
_rc=1; [[ -n "$_launcher" && -x "$_launcher" ]] && _rc=0
assert "$_rc" "R7: the registered first hop exists and is executable ($_launcher)"

# The hostile environ is applied here too: the launcher runs BEFORE `env -i`, so its own
# immunity (`#!/bin/bash -p` — no imported functions, SHELLOPTS/BASH_ENV/ENV ignored) is
# what makes a bash first hop admissible at all. If that ever regresses, this row goes red.
_r7_out="$(hostile_env "$_launcher" </dev/null 2>/dev/null)"; _r7_rc=$?
_rc=1; [[ "$_r7_rc" -eq 2 ]] && _rc=0
assert "$_rc" "R7 CLOSED: the first hop with no args exits 2, not 0 (got rc=$_r7_rc)"
_rc=1; [[ -z "$_r7_out" ]] && _rc=0
assert "$_rc" "R7 CLOSED: the first hop with no args prints nothing on stdout (no environment dump)"
_rc=1; [[ "$_r7_out" != *PATH=* ]] && _rc=0
assert "$_rc" "R7 CLOSED: no environment assignment appears in its stdout"

# R8 — a missing or unreadable wrapper makes bash exit 127, which does NOT block. The
# launcher converts any non-{0,2} rc into the registration's declared disposition, which is
# what the shell-form `|| exit 2` tail used to do.
"$_launcher" closed PATH=/usr/bin:/bin /bin/bash "$TMP/no-such-wrapper.sh" a b c \
    </dev/null >/dev/null 2>&1
_r8_rc=$?
_rc=1; [[ "$_r8_rc" -eq 2 ]] && _rc=0
assert "$_rc" "R8 CLOSED: a missing wrapper under the closed disposition exits 2 (got rc=$_r8_rc)"
"$_launcher" open PATH=/usr/bin:/bin /bin/bash "$TMP/no-such-wrapper.sh" a b c \
    </dev/null >/dev/null 2>&1
_r8_open_rc=$?
_rc=1; [[ "$_r8_open_rc" -eq 0 ]] && _rc=0
assert "$_rc" "R8: the open disposition still allows on launch failure — the 2 GateGuard rows (got rc=$_r8_open_rc)"

# The conversion must not swallow a real decision: 0 and 2 pass straight through, or the
# launcher would turn every allow into a block (or worse, every block into an allow).
"$_launcher" closed PATH=/usr/bin:/bin /bin/bash -c 'exit 0' </dev/null >/dev/null 2>&1
_pass_rc=$?
_rc=1; [[ "$_pass_rc" -eq 0 ]] && _rc=0
assert "$_rc" "launcher passes an ALLOW (0) through untouched (got rc=$_pass_rc)"
"$_launcher" closed PATH=/usr/bin:/bin /bin/bash -c 'exit 2' </dev/null >/dev/null 2>&1
_blk_rc=$?
_rc=1; [[ "$_blk_rc" -eq 2 ]] && _rc=0
assert "$_rc" "launcher passes a BLOCK (2) through untouched (got rc=$_blk_rc)"
"$_launcher" bogus PATH=/usr/bin:/bin /bin/bash -c 'exit 0' </dev/null >/dev/null 2>&1
_bogus_rc=$?
_rc=1; [[ "$_bogus_rc" -eq 2 ]] && _rc=0
assert "$_rc" "launcher refuses an unknown disposition, failing CLOSED (got rc=$_bogus_rc)"

printf '\nPASS=%d FAIL=%d\n' "$PASS" "$FAIL"
if [[ "$FAIL" -eq 0 ]]; then
    printf 'ALL #713 EXEC-FORM ASSERTIONS PASSED\n'; exit 0
fi
exit 1
