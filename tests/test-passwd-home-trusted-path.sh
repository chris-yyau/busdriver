#!/usr/bin/env bash
# Test: passwd-HOME derivation must not be steerable by a user-writable PATH dir or
# by an imported shell function — issue #660.
#
# Both containment wrappers rebuild a fixed PATH allowlist whose first entries
# (/usr/local/bin, /opt/homebrew/bin) are OPERATOR-WRITABLE on a default Homebrew
# install, then shelled out to id/getent/dscl through it. macOS ships no `getent` at
# all, so a planted one is found with nothing to shadow and its stdout became HOME for
# every contained gate. A shell FUNCTION named `getent` outranks PATH the same way.
# Both are closed by deriving in a child under `/usr/bin/env -i`.
#
# The fixture cannot write /opt/homebrew/bin, so it SUBSTITUTES a writable plant dir
# into the copy's allowlist — a faithful stand-in for the writable entry already there.
# The function leg invokes the wrapper WITHOUT `env -i` on purpose: that makes it an
# assertion about the wrapper's own defense, not about its hooks.json launch line.
#
# Vacuous-pass guards: the decoy home EXISTS (the wrapper rejects a non-dir home and
# would fall through to the real one), the substitution is verified to have taken, and
# both plants are first shown to WORK against the pre-#660 derivation shape.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0
assert() {
    if [[ "$1" -eq 0 ]]; then PASS=$((PASS+1)); printf '  ok   %s\n' "$2"
    else FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$2"; fi
}

# No `set -e` here (assertions rely on non-zero rc), so bail explicitly: an empty TMP
# would make every path below resolve at the filesystem root.
_user="$(/usr/bin/id -un)" || { echo "cannot resolve user" >&2; exit 1; }
# REAL_HOME is the EXPECTED value of all four containment assertions below, so it must come
# from PASSWD and nowhere else. `$HOME` is specifically wrong here: it is the exact variable
# the code under test must ignore, so sourcing the oracle from it makes the assertion
# "the wrapper echoed $HOME back" -- which is equally true when the wrapper is correct and
# when it has regressed to reading $HOME, on any host where the two diverge. That is the
# guard-that-cannot-fail shape this whole suite exists to detect.
# getpwuid() rather than `eval echo ~$_user`: same passwd authority, no eval (CodeRabbit).
# Deliberately NOT the wrapper's own getent/dscl ladder -- an oracle that reimplements the
# implementation cannot catch the implementation being wrong.
REAL_HOME="$(/usr/bin/env python3 -c 'import pwd, os; print(pwd.getpwuid(os.getuid()).pw_dir)')" \
  || { echo "cannot resolve passwd home" >&2; exit 1; }
[[ -n "$REAL_HOME" && -d "$REAL_HOME" ]] || { echo "cannot resolve real home" >&2; exit 1; }
TMP="$(mktemp -d)"
[[ -n "$TMP" && -d "$TMP" ]] || { echo "mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT

PLANT="$TMP/writable_bin"
DECOY="$TMP/decoy_home"
mkdir -p "$PLANT" "$DECOY" "$TMP/root/hooks/gate-scripts/lib" "$TMP/root/scripts/hooks"

# A planted getent, as reachable from a writable PATH dir as a real one would be.
cat > "$PLANT/getent" <<PLANTED
#!/bin/sh
printf '%s:x:501:20::$DECOY:/bin/sh\n' "\$2"
PLANTED
chmod +x "$PLANT/getent"

# The pre-#660 derivation shape, used only to prove both plants actually work.
cat > "$TMP/vulnerable.sh" <<'VULN'
_u=$(id -un); _home=$(getent passwd "$_u" | cut -d: -f6)
echo "HOME=[$_home]"
VULN

# ── Controls: the plants steer the OLD shape ────────────────────────────────
ctl_path="$(PATH="$PLANT:$PATH" bash "$TMP/vulnerable.sh" 2>&1)"
grep -q "HOME=\[$DECOY\]" <<<"$ctl_path"
assert $? "control: a planted getent on a writable PATH dir DOES steer the pre-fix shape ($ctl_path)"

ctl_fn="$(
  # shellcheck disable=SC2329  # invoked indirectly via `export -f` in the bash child
  getent() { printf '%s:x:501:20::%s:/bin/sh\n' "$2" "$DECOY"; }
  export -f getent
  export DECOY            # the function body expands $DECOY in the CHILD
  bash "$TMP/vulnerable.sh" 2>&1
)"
grep -q "HOME=\[$DECOY\]" <<<"$ctl_fn"
assert $? "control: an exported getent() DOES steer the pre-fix shape ($ctl_fn)"

# ── Install each wrapper with the plant dir inside its PATH allowlist ───────
install_wrapper() {  # install_wrapper <src> <dest>
    sed "s|^for _d in /usr/local/bin|for _d in $PLANT /usr/local/bin|" "$1" > "$2"
    grep -q "for _d in $PLANT " "$2"   # fixture is live only if the substitution took
}

# ── Leg 0: the launch invariant the wrappers rely on ───────────────────────
# The sterile child closes PATH/command-name lookup, but an imported FUNCTION named
# `export`/`cd`/`exec` intercepts the wrapper wherever it runs and no in-script purge
# can help. That class is closed by `/usr/bin/env -i` at the launch, so every
# sanitized-gate.sh registration must actually use it. (test-node-hook-containment.sh
# already pins the same invariant for the node-hook registrations.)
# #713: read the document STRUCTURALLY, never line-wise. The registrations are exec form
# (`command` + `args`), so `sanitized-gate.sh` and `/usr/bin/env` land on different lines
# and the old single-line grep matched neither — it would have gone quietly vacuous rather
# than red, which is the failure mode this repo's own review rules call out.
# The membership test is also deliberately a SUBSTRING, not `endswith`: under exec form the
# wrapper path is followed by the gate basename, so an `endswith("/sanitized-gate.sh")`
# population silently EXCLUDES every shell-form row — which is precisely the two Codex
# nudges deliberately left behind (see ADR 0049), i.e. the check would pass by not looking.
# Those two are non-gating and stay shell form so they can still forward
# $PR_GRIND_CODEX_RETRIGGER, but the invariant THIS test pins — the sterile `env -i` child
# that closes the imported-function class — holds for them too, so they are asserted, not
# skipped. Both populations are pinned so a gate cannot be quietly moved between them.
_probe_out="$(python3 - "$REPO_ROOT/hooks/hooks.json" <<'PY'
import json, sys
EXEMPT = ("codex-nudge-premerge.sh", "codex-nudge-precreate.sh")
PREFIX = "/usr/bin/env -i PATH=/usr/bin:/bin "
LAUNCH = "${CLAUDE_PLUGIN_ROOT}/hooks/gate-scripts/lib/contained-launch.sh"
doc = json.load(open(sys.argv[1]))
n = bad = exempt = badexempt = 0
for blocks in doc.get("hooks", doc).values():
    for blk in blocks:
        for hk in blk.get("hooks", []):
            if hk.get("type") != "command":
                continue
            cmd, args = hk.get("command"), hk.get("args")
            argv = [cmd] + list(args) if isinstance(args, list) else [cmd]
            if not any(isinstance(a, str) and "/sanitized-gate.sh" in a for a in argv):
                continue
            if any(isinstance(a, str) and any(e in a for e in EXEMPT) for a in argv):
                exempt += 1
                # Shell form, but still the same sterile launch: `env -i` is the first thing
                # the outer shell runs, so bash still starts with no imported functions.
                if args is not None or not str(cmd).startswith(PREFIX):
                    badexempt += 1
                continue
            n += 1
            # #713: the first hop is contained-launch.sh, which supplies `env -i` itself.
            # `command` must NOT be bare /usr/bin/env — a client that drops `args` would then
            # run env with no operands, which exits 0 and prints the environment (R7).
            if not (cmd == LAUNCH and isinstance(args, list)
                    and args[0] in ("closed", "open") and args[1] == "PATH=/usr/bin:/bin"):
                bad += 1
print("%d %d %d %d" % (n, bad, exempt, badexempt))
PY
)" || _probe_out="0 1 0 1"
read -r _n _bad _exempt _badexempt <<<"$_probe_out"
_rc=0
[[ "$_n" -eq 10 && "$_bad" -eq 0 ]] || _rc=1
assert "$_rc" "all $_n sanitized-gate.sh GATE registrations launch via contained-launch.sh, which applies env -i (strips BASH_FUNC_*)"
_rc=0
[[ "$_exempt" -eq 2 && "$_badexempt" -eq 0 ]] || _rc=1
assert "$_rc" "the $_exempt shell-form Codex nudges still launch under /usr/bin/env -i too (#713 / ADR 0049)"

# ── Leg 1: sanitized-gate.sh ────────────────────────────────────────────────
cat > "$TMP/root/hooks/gate-scripts/_probe.sh" <<'PROBE'
echo "HOME=[${HOME:-}]"
PROBE
GATE_COPY="$TMP/root/hooks/gate-scripts/lib/sanitized-gate.sh"
install_wrapper "$REPO_ROOT/hooks/gate-scripts/lib/sanitized-gate.sh" "$GATE_COPY"
assert $? "fixture is live: plant dir substituted into sanitized-gate.sh's PATH allowlist"

gate_path_out="$(/usr/bin/env -i PATH=/usr/bin:/bin HOME="$DECOY" CLAUDE_PLUGIN_ROOT="$TMP/root" \
    bash "$GATE_COPY" _probe.sh 2>&1)"
grep -q "HOME=\[$REAL_HOME\]" <<<"$gate_path_out"
assert $? "sanitized-gate.sh: planted getent on the trusted PATH cannot supply HOME ($gate_path_out)"

gate_fn_out="$(
  # shellcheck disable=SC2329  # invoked indirectly via `export -f` in the bash child
  getent() { printf '%s:x:501:20::%s:/bin/sh\n' "$2" "$DECOY"; }
  export -f getent
  export DECOY            # the function body expands $DECOY in the CHILD
  HOME="$DECOY" CLAUDE_PLUGIN_ROOT="$TMP/root" bash "$GATE_COPY" _probe.sh 2>&1
)"
grep -q "HOME=\[$REAL_HOME\]" <<<"$gate_fn_out"
assert $? "sanitized-gate.sh: an exported getent() cannot supply HOME either ($gate_fn_out)"

# ── Leg 2: sanitized-node.sh ────────────────────────────────────────────────
# The wrapper hardcodes scripts/hooks/run-with-flags.js as the runner and verifies the
# named hook script exists, so the skeleton supplies both. The runner must parse under
# `node --check` (the wrapper's node-validation step).
#
# THREE positional args are required -- <hookId> <scriptRelPath> <profilesCsv> -- and the
# third is NOT optional padding: #616 made the wrapper reject any argument list that is not
# exactly three non-empty, non-`--`-prefixed operands, failing CLOSED, because a registration
# missing its profiles operand would otherwise reach the runner malformed. Every real
# hooks.json registration passes all three, so a two-arg call here would test a shape the
# plugin never emits. "standard,strict" mirrors the non-gateguard node registrations; the
# stub runner below ignores the value, so only its presence and shape matter to this test.
cat > "$TMP/root/scripts/hooks/run-with-flags.js" <<'RUNNER'
console.log("HOME=[" + (process.env.HOME || "") + "]");
RUNNER
: > "$TMP/root/scripts/hooks/probe.js"
NODE_COPY="$TMP/root/hooks/gate-scripts/lib/sanitized-node.sh"
install_wrapper "$REPO_ROOT/hooks/gate-scripts/lib/sanitized-node.sh" "$NODE_COPY"
assert $? "fixture is live: plant dir substituted into sanitized-node.sh's PATH allowlist"

node_path_out="$(/usr/bin/env -i PATH=/usr/bin:/bin HOME="$DECOY" CLAUDE_PLUGIN_ROOT="$TMP/root" \
    CLAUDE_HOOK_EVENT_NAME=PreToolUse \
    bash "$NODE_COPY" "pre:probe" "scripts/hooks/probe.js" "standard,strict" 2>&1)"
grep -q "HOME=\[$REAL_HOME\]" <<<"$node_path_out"
assert $? "sanitized-node.sh: contained hook inherits the real passwd HOME, not the planted one ($node_path_out)"

node_fn_out="$(
  # shellcheck disable=SC2329  # invoked indirectly via `export -f` in the bash child
  getent() { printf '%s:x:501:20::%s:/bin/sh\n' "$2" "$DECOY"; }
  export -f getent
  export DECOY            # the function body expands $DECOY in the CHILD
  HOME="$DECOY" CLAUDE_PLUGIN_ROOT="$TMP/root" CLAUDE_HOOK_EVENT_NAME=PreToolUse \
    bash "$NODE_COPY" "pre:probe" "scripts/hooks/probe.js" "standard,strict" 2>&1
)"
grep -q "HOME=\[$REAL_HOME\]" <<<"$node_fn_out"
assert $? "sanitized-node.sh: an exported getent() cannot supply HOME either ($node_fn_out)"

echo ""
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
echo "ALL #660 PASSWD-HOME ASSERTIONS PASSED"
