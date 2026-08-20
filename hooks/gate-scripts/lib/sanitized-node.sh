#!/usr/bin/env bash
# Node-hook environment-containment wrapper — Task 3, docs/adr/0016-gate-env-containment.md
#
# WHY: ADR 0016 contained the 10 shell gates under `env -i`, but the PURE-BLOCK
# node hooks (block-no-verify, config-protection, pre-bash-dev-server-block) still
# inherited the session env. A committed .claude/settings.json `env` block sets
# ECC_HOOK_PROFILE / ECC_DISABLED_HOOKS, which hook-flags.js reads to DISABLE a
# hook — so a PR could switch off the very gates that block `git commit --no-verify`,
# config tampering, and unattended dev-server launches. Containment must happen
# ABOVE the runner: once node has started under a poisoned PATH/env it is too late.
#
# HOW: hooks.json invokes this wrapper under `/usr/bin/env -i` (absolute path so
# `env` itself can't be shimmed; `-i` wipes the ENTIRE environment, including the
# ECC_HOOK_PROFILE / ECC_DISABLED_HOOKS injection flags and any exported functions).
# This wrapper rebuilds a TRUSTED PATH from a fixed allowlist — the SAME one
# sanitized-gate.sh uses (sanitized-gate.sh:51) — neutralizes global git config and
# a poisoned HOME, resolves node on the trusted PATH, then RUNS (as a child, not exec —
# so it can inspect the exit status) the hook DISPATCH layer (run-with-flags.js), NOT a
# hook directly. With the profile flags wiped, the runner falls back to each hook's
# default-enabled state → the gate fires.
#
# LAUNCH DISPOSITION — this wrapper has TWO, selected by the caller (#616):
#
#   default (no flag)  A blocking gate that cannot launch its runtime MUST block.
#                      node normally lives at ~/.local/bin/node or /opt/homebrew/bin —
#                      NOT on /usr/bin:/bin. A naive `env -i PATH=/usr/bin:/bin node …`
#                      would fail to find node; a blocking hook that never launches
#                      never exits 2 → the tool proceeds. So the trusted PATH re-adds
#                      the Homebrew/local dirs, and if node is STILL not found the
#                      wrapper emits {"decision":"block"} + exit 2 rather than exit 0.
#
#   --fail-open        A launch/infrastructure failure resolves to ALLOW: no stdout
#                      decision at all ("no opinion"), exit 0. ONLY for a consumer that
#                      guards no boundary. GateGuard (a quality prompt, off by default,
#                      opt-in per repo) is the sole such consumer; adopting the closed
#                      disposition for it would hard-block every Edit/Write/Bash of
#                      operators who never opted in, on a missing node or one oversized
#                      payload. Do NOT add a second consumer without the same argument.
#                      See docs/adr/0016-gate-env-containment.md.
#
# A MALFORMED ARGUMENT LIST is not a launch failure and is never fail-open: it is a bug
# in code that ships with the plugin, so it is forced to the closed disposition below.
#
# Re-imported vars (see ADR 0016): CLAUDE_PLUGIN_ROOT locates this wrapper + the
# runner (Claude-set, authoritative over the settings `env` block); HOME for tools
# that need it (re-derived from passwd below); CLAUDE_HOOK_EVENT_NAME because a
# contained hook may branch Pre- vs Post-event on it (Claude-set per event, not the
# settings-env injection channel).
set -euo pipefail

# ── Disposition ────────────────────────────────────────────────────────────
# Assignment and shift ONLY — no _block call here: _block is not defined yet, and
# calling it would be a command-not-found (127) that `|| exit 0` silently swallows.
# Validation of the remaining argument list happens right after _block's definition.
_disposition="closed"; _disp_word="CLOSED"
if [[ "${1:-}" == "--fail-open" ]]; then _disposition="open"; _disp_word="OPEN"; shift; fi

# ── Trusted PATH ───────────────────────────────────────────────────────────
# Same SYSTEM allowlist as sanitized-gate.sh:51 — known-good absolute dirs, never
# inherited. Unlike the shell gates' tools (git/gh/jq/python3, always in a system
# prefix), node frequently lives in the OPERATOR's own bin dir (Homebrew symlink,
# ~/.local/bin, a version manager). The operator-owned dirs are appended AFTER HOME
# is re-derived from passwd below (a PR cannot write to the real operator's $HOME),
# so they are safe to trust for node resolution without reopening the env channel.
_p=""
for _d in /usr/local/bin /opt/homebrew/bin /opt/homebrew/sbin /usr/bin /bin /usr/sbin /sbin; do
    if [[ -d "$_d" ]]; then
        _p="${_p:+$_p:}$_d"
    fi
done
export PATH="$_p"
export LANG="${LANG:-C}"
export TMPDIR="${TMPDIR:-/tmp}"
# Neutralize global + system git config so a re-imported HOME can't supply an
# executable git helper/alias/pager (same rationale as sanitized-gate.sh).
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null
export PYTHONNOUSERSITE=1
_u=$(id -un 2>/dev/null || true)
_home=""
if [[ -n "$_u" ]]; then
    if command -v getent >/dev/null 2>&1; then
        _home=$(getent passwd "$_u" 2>/dev/null | cut -d: -f6 || true)
    fi
    if [[ -z "$_home" || ! -d "$_home" ]] && command -v dscl >/dev/null 2>&1; then
        _home=$(dscl . -read "/Users/$_u" NFSHomeDirectory 2>/dev/null | awk '{print $2}' || true)
    fi
fi
if [[ -n "$_home" && -d "$_home" ]]; then
    export HOME="$_home"
else
    unset HOME
fi

# NOTE on node location: node is resolved from the trusted system allowlist FIRST, then
# from the operator's own passwd-HOME direct-binary dirs (~/.local/bin and nvm's per-version
# bins) as a fallback — so a host whose only node is under nvm still resolves. Two surfaces
# are DELIBERATELY excluded: (a) Volta/asdf/mise SHIM dirs and (b) shared prefixes like
# /home/linuxbrew/.linuxbrew/bin. (a) because a shim is extra indirection best avoided even
# though the `cd /` below already neutralizes the repo-config vector; (b) because a
# group-writable shared prefix is an LCE surface `cd /` does NOT fix (it is about who owns
# the binary, not the cwd). The `cd /` neutral-cwd step below is what makes the operator
# fallback safe: even if ~/.local/bin/node is a symlink to a version manager, running it
# from `/` means no repo-local .tool-versions/.nvmrc/package.json can steer it.

# ── Disposition-aware failure helper ───────────────────────────────────────
# Every failure path in this file routes through here, so the disposition is honoured
# by construction rather than remembered at each of the eight call sites.
#
# The disposition word is appended HERE, not by the caller. In the OPEN disposition
# nothing may reach stdout: the harness consumes a stdout decision regardless of exit
# status, so printing block JSON and then exiting 0 would still block the tool call.
# "No opinion" means no stdout at all.
# An `if` rather than `[[ … ]] && exit 0`. To be accurate about why, because the obvious
# reason is WRONG and was believed here at one point: the AND-list form is NOT a `set -e`
# hazard. A failing `[[ ]]` as a non-final member of an AND-list is exempt from `set -e`,
# so the AND-list form prints the block JSON and exits 2 correctly from every call shape
# in this file — verified by execution on bash 3.2.57 (the macOS system bash this wrapper
# actually runs under) and bash 5.3, in the `if … then`, `… || _block`, and bare-call
# shapes. The `if` is kept only because it states the branch without relying on that
# exemption being remembered by the next reader.
_block() {
    printf '%s — failing %s\n' "$1" "$_disp_word" >&2
    if [[ "$_disposition" == "open" ]]; then
        exit 0
    fi
    printf '{"decision":"block","reason":"%s"}\n' "$2"
    exit 2
}

# ── Argument-list validation (forced CLOSED) ───────────────────────────────
# Placed AFTER _block's definition — see the disposition block above for why.
# Checked on ARITY, not by re-testing the leading token: `--fail-open A B C --fail-open`
# has already been shifted once, so a leading-token re-check would pass it and the extra
# operand would reach the runner through the verbatim "$@" below.
# EMPTINESS too: `--fail-open "" "" "..."` satisfies arity with three args, and the
# hookId/scriptPath emptiness would otherwise be caught further down — by then in the
# OPEN disposition, i.e. a malformed registration silently allowing.
# Forced closed: a malformed registration is a plugin bug, not an operator-environment
# condition, and must be loud whatever the registration asked for.
if [[ $# -ne 3 ]] || [[ -z "$1" || -z "$2" || -z "$3" ]] \
   || [[ "$1" == --* || "$2" == --* || "$3" == --* ]]; then
    _disposition="closed"; _disp_word="CLOSED"
    _block "sanitized-node: malformed argument list" \
           "malformed blocking-gate registration; cannot confirm gate decision"
fi

# ── Locate the runner ──────────────────────────────────────────────────────
# Resolved BEFORE node so node candidates can be validated against the actual runner.
# hooks.json passes the runner's OWN args after this wrapper: <hookId> <scriptRelPath> <profilesCsv>.
# The runner is hardcoded here (the dispatch layer), NOT taken from "$@".
root="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
# Normalize root to ABSOLUTE before the `cd /` below. A relative CLAUDE_PLUGIN_ROOT
# (e.g. a manual/local `CLAUDE_PLUGIN_ROOT=.`) would make $runner and the hook-script
# path relative, and after `cd /` they would resolve against `/` and vanish — every gate
# would then fail CLOSED (safe, but a usability break). Resolving here keeps them valid.
if [[ "$root" != /* ]]; then
    root=$(cd "$root" 2>/dev/null && pwd) || _block \
        "sanitized-node: CLAUDE_PLUGIN_ROOT '$CLAUDE_PLUGIN_ROOT' does not resolve" \
        "plugin root unresolvable; blocking hook cannot launch"
fi
runner="$root/scripts/hooks/run-with-flags.js"
if [[ ! -f "$runner" ]]; then
    _block "sanitized-node: runner not found: $runner" \
           "hook runner missing; blocking hook cannot launch"
fi

# Neutralize the CWD before running ANY node — belt-and-suspenders against a system-dir
# `node` that is actually a SYMLINK/wrapper to a version-manager shim (Volta/asdf/mise can
# install into /usr/local/bin): such a shim selects its runtime + can run manager plugin
# code from config found RELATIVE TO THE CWD (.tool-versions/.nvmrc/package.json/mise). The
# hook CWD is the repo, so a PR could drop such a file to steer node before the gate. Running
# from `/` (no such files) closes that for both `--check` AND the runner exec below. The
# three contained hooks stay correct: block-no-verify / dev-server-block act on the command
# string; config-protection now resolves a relative file_path against the PAYLOAD cwd (not
# process.cwd()), so a neutral process CWD does not weaken it (see config-protection.js).
cd / 2>/dev/null || _block "sanitized-node: cannot cd to a neutral dir" \
                           "cannot neutralize CWD; blocking hook cannot launch safely"

# ── Resolve node: system dirs first, passwd-HOME direct-binary dirs as fallback ──────
# Candidate order per the node-location note above: system allowlist FIRST (real binaries),
# then ~/.local/bin and each nvm version bin (so an nvm-only host still resolves). For EACH
# candidate, VALIDATE with `node --check "$runner"` — a real syntax parse of THE runner,
# stronger than `--version` (which an outdated node that can't parse the runner's `??`/`?.`
# would still pass). This is the fix for Codex P2 ("an incompatible node the wrapper picks
# fails EVERY gated action closed"): an unparseable node is SKIPPED so resolution falls
# through to a compatible one. --check picks the first working node (any node that parses the
# trivial runner works — no version ranking needed). `cd /` above already ran, so a shim
# candidate cannot read repo config. Excluded: Volta/asdf/mise shims + Linuxbrew (see note).
_node=""
_cands=(/opt/homebrew/bin /usr/local/bin /usr/bin /bin)
if [[ -n "${HOME:-}" ]]; then
    _cands+=("$HOME/.local/bin")
    for _nv in "$HOME"/.nvm/versions/node/*/bin; do
        [[ -d "$_nv" ]] && _cands+=("$_nv")
    done
fi
for _cand in "${_cands[@]}"; do
    [[ -x "$_cand/node" ]] || continue
    "$_cand/node" --check "$runner" >/dev/null 2>&1 || continue
    _node="$_cand/node"; break
done
if [[ -z "$_node" ]]; then
    _block "sanitized-node: no node able to parse the runner on trusted candidates (PATH=$PATH, +~/.local/bin, +nvm)" \
           "no compatible node runtime; blocking hook cannot launch"
fi

# The runner (run-with-flags.js) fail-OPENs — exit 0 — when the hook SCRIPT it is asked
# to dispatch is missing or path-rejected. For a blocking gate that is a fail-open hole,
# so verify the target hook script ($2 = <scriptRelPath>) exists HERE and fail CLOSED if
# not. (A deeper runner dispatch failure that still returns 0 — e.g. a require() throw on
# a corrupted plugin file — is a bounded plugin-integrity residual: these three scripts
# ship with the plugin and a PR cannot remove or rewrite them. See ADR 0016.)
# hookId ($1) and hook script ($2) are already guaranteed present and non-empty by the
# forced-CLOSED argument-list validation near the top of this file — which is where that
# check has to live, so a malformed registration cannot be adjudicated in the OPEN
# disposition and silently allow.
hook_rel="$2"
case "$hook_rel" in
    /*|*..*) _block "sanitized-node: refusing hook path $hook_rel (absolute/traversal)" \
                    "bad hook script path; cannot confirm gate decision" ;;
esac
if [[ ! -f "$root/$hook_rel" ]]; then
    _block "sanitized-node: hook script missing: $root/$hook_rel" \
           "target hook script absent; cannot confirm gate decision"
fi

# Run the runner (NOT `exec`) so we can inspect its exit status and fail CLOSED on a
# launch/crash failure. stdin (the PreToolUse JSON) and stdout are inherited untouched.
# The runner's meaningful codes are 0 (allow / no opinion) and 2 (a hook blocked).
# Any OTHER non-zero — node found but not executable (126), node vanished mid-launch
# (127), a runner syntax/startup crash (1) — is an INFRA failure: a blocking gate that
# could not reach a decision MUST block, not let the tool through on a non-2 exit that
# the harness treats as a non-blocking error (the fail-OPEN hole `exec` would leave).
#
# The trailing `--fail-closed` tells run-with-flags.js to convert ITS OWN fail-open exit
# points (a caught run() exception, missing/rejected script, legacy-spawn failure,
# unhandled error) to exit 2 — otherwise a hook crash the runner swallows to exit 0 would
# be indistinguishable from a genuine allow, and `|| exit 2` can't help because the runner
# returns 0. It is a positional ARG, deliberately NOT an env var: the bare non-gate hook
# registrations invoke the runner directly (no `env -i`), so a committed settings.json
# `env` block could set a fail-closed ENV var and turn advisory hooks into spurious
# blocks (a DoS). An argv is only settable via hooks.json (review-visible code), not the
# silent settings-env channel this containment is built to defeat.
#
# Appended ONLY in the closed disposition. `--fail-open` is never forwarded: the runner has
# no reader for it, and the runner's fail-open behaviour is exactly the ABSENCE of
# `--fail-closed` (failOpenExitCode(), run-with-flags.js:116-118). The token still appears in
# the hooks.json command string, which is what #629's registration-derived detection keys on.
# STDOUT IS BUFFERED IN THE OPEN DISPOSITION, and streamed in the closed one.
#
# Streaming is wrong for fail-open specifically: the runner inherits stdout, so a runner that
# prints a deny decision and THEN dies with a status outside 0/2 has already put that decision
# on the harness's stdout. `_block` in the open disposition emits nothing and exits 0 -- but it
# cannot RETRACT what already left the process, so the harness blocks the tool call on an
# infrastructure failure the registration explicitly declared fail-OPEN. Buffering makes the
# decision conditional on a clean exit, which is what the disposition promises.
#
# The closed disposition keeps streaming: there, a decision surviving a crash biases toward
# blocking, which is the direction that disposition already fails in.
#
# stderr is inherited in BOTH branches, so diagnostics are never withheld or reordered.
_out=""
set +e
if [[ "$_disposition" == "open" ]]; then
    _out=$("$_node" "$runner" "$@")
else
    "$_node" "$runner" "$@" --fail-closed
fi
_rc=$?
set -e
case "$_rc" in
    0|2) if [[ "$_disposition" == "open" ]]; then printf '%s' "$_out"; fi; exit "$_rc" ;;
    *) _block "sanitized-node: runner exited $_rc (launch/crash, not a clean allow/block)" \
              "hook runner failed to execute (exit $_rc); blocking hook cannot confirm allow" ;;
esac
