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
# FAIL-CLOSED LAUNCH: node normally lives at ~/.local/bin/node or /opt/homebrew/bin
# — NOT on /usr/bin:/bin. A naive `env -i PATH=/usr/bin:/bin node …` would fail to
# find node; a blocking hook that never launches never exits 2 → the tool proceeds
# (fail-OPEN). So the trusted PATH re-adds the Homebrew/local dirs, and if node is
# STILL not found the wrapper emits {"decision":"block"} + exit 2 rather than exit 0.
#
# Re-imported vars (see ADR 0016): CLAUDE_PLUGIN_ROOT locates this wrapper + the
# runner (Claude-set, authoritative over the settings `env` block); HOME for tools
# that need it (re-derived from passwd below); CLAUDE_HOOK_EVENT_NAME because a
# contained hook may branch Pre- vs Post-event on it (Claude-set per event, not the
# settings-env injection channel).
set -euo pipefail

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

# Append the operator's own bin dirs + Linuxbrew so node resolves even when it lives
# outside a system prefix (~/.local/bin is the documented common case; the rest cover
# Volta, asdf, mise, Linuxbrew, and every nvm-installed version via the glob). These
# are derived from the trusted passwd HOME, never the PR-influenced env, and appended
# (system dirs still win). ponytail: this list is best-effort, not exhaustive — a node
# under a layout not covered here (an exotic version manager, a bespoke prefix) falls
# through to the loud fail-CLOSED block below, which is SAFE (it blocks, never bypasses)
# and names the searched PATH so the operator can symlink node into ~/.local/bin. Add a
# dir here only if a real operator hits it; don't pre-enumerate the world.
if [[ -n "${HOME:-}" ]]; then
    _uds=(
        "$HOME/.local/bin"
        "$HOME/.volta/bin"
        "$HOME/.asdf/shims"
        "$HOME/.local/share/mise/shims"
        /home/linuxbrew/.linuxbrew/bin
    )
    # nvm installs under ~/.nvm/versions/node/<version>/bin. PATH resolution takes the
    # FIRST match, so add ONLY the highest installed version that actually holds an
    # executable `node`. Version comparison is done in PURE BASH (numeric major.minor.patch),
    # NOT `sort -V` — that flag is GNU-only and absent from BSD/macOS `sort`, so relying on
    # it would make an nvm-only macOS host fail-CLOSED and block every operation.
    # Rank the highest CLEAN stable (vMAJOR.MINOR.PATCH) first so `command -v` prefers it,
    # then append EVERY other node-bearing nvm dir (prereleases, unparseable names) as a
    # fallback — so node ALWAYS resolves, even on a prerelease-only host, while a stable
    # release still wins when one exists. No `sort` (BSD `sort` lacks `-V`); component-wise
    # numeric compare (no packed-int overflow); a prerelease never outranks a stable but is
    # never excluded either.
    if [[ -d "$HOME/.nvm/versions/node" ]]; then
        _b_maj=-1; _b_min=-1; _b_pat=-1; _best_dir=""
        _other_nvm=()
        for _nv in "$HOME"/.nvm/versions/node/*/bin; do
            [[ -x "$_nv/node" ]] || continue
            _ver=${_nv%/bin}; _ver=${_ver##*/v}          # ".../v20.11.0/bin" → "20.11.0"
            # ONE strict anchored regex admits only clean MAJOR.MINOR.PATCH with each
            # component 1–6 digits. This single check rejects prereleases (`-rc.1`), build
            # metadata, trailing/leading dots, wrong arity, and over-long components in one
            # shot — the 6-digit cap also keeps 10#<n> (max 999999) inside 64-bit arithmetic
            # so nothing can overflow. BASH_REMATCH is read below before any other `[[ =~ ]]`.
            if [[ "$_ver" =~ ^([0-9]{1,6})\.([0-9]{1,6})\.([0-9]{1,6})$ ]] \
               && { (( 10#${BASH_REMATCH[1]} >  _b_maj )) \
                    || (( 10#${BASH_REMATCH[1]} == _b_maj && 10#${BASH_REMATCH[2]} >  _b_min )) \
                    || (( 10#${BASH_REMATCH[1]} == _b_maj && 10#${BASH_REMATCH[2]} == _b_min && 10#${BASH_REMATCH[3]} > _b_pat )); }; then
                [[ -n "$_best_dir" ]] && _other_nvm+=("$_best_dir")   # demote prior best to fallback
                _b_maj=$((10#${BASH_REMATCH[1]})); _b_min=$((10#${BASH_REMATCH[2]})); _b_pat=$((10#${BASH_REMATCH[3]})); _best_dir=$_nv
            else
                _other_nvm+=("$_nv")
            fi
        done
        [[ -n "$_best_dir" ]] && _uds+=("$_best_dir")
        [[ ${#_other_nvm[@]} -gt 0 ]] && _uds+=("${_other_nvm[@]}")
    fi
    for _ud in "${_uds[@]}"; do
        [[ -d "$_ud" ]] && PATH="$PATH:$_ud"
    done
    export PATH
fi

# ── Fail-CLOSED helper ─────────────────────────────────────────────────────
# A blocking hook that cannot launch its runtime MUST block, never pass through.
_block() {
    printf '%s\n' "$1" >&2
    printf '{"decision":"block","reason":"%s"}\n' "$2"
    exit 2
}

# ── Resolve node on the trusted PATH ───────────────────────────────────────
if ! _node=$(command -v node 2>/dev/null) || [[ -z "$_node" ]]; then
    _block "sanitized-node: node not found on trusted PATH ($PATH) — failing CLOSED" \
           "node runtime unavailable; blocking hook cannot launch"
fi

# ── Locate the runner + args ───────────────────────────────────────────────
# hooks.json passes the runner's OWN args after this wrapper: <hookId> <scriptRelPath> <profilesCsv>.
# The runner is hardcoded here (the dispatch layer), NOT taken from "$@".
root="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
runner="$root/scripts/hooks/run-with-flags.js"
if [[ ! -f "$runner" ]]; then
    _block "sanitized-node: runner not found: $runner — failing CLOSED" \
           "hook runner missing; blocking hook cannot launch"
fi

# The runner (run-with-flags.js) fail-OPENs — exit 0 — when the hook SCRIPT it is asked
# to dispatch is missing or path-rejected. For a blocking gate that is a fail-open hole,
# so verify the target hook script ($2 = <scriptRelPath>) exists HERE and fail CLOSED if
# not. (A deeper runner dispatch failure that still returns 0 — e.g. a require() throw on
# a corrupted plugin file — is a bounded plugin-integrity residual: these three scripts
# ship with the plugin and a PR cannot remove or rewrite them. See ADR 0016.)
# A blocking-gate registration MUST name a hookId ($1) and a hook script ($2). An empty
# arg means a malformed registration — and run-with-flags.js exits 0 (allow) on an empty
# hookId/scriptPath — so fail CLOSED here rather than dispatch into that fail-open path.
hook_id="${1:-}"
hook_rel="${2:-}"
if [[ -z "$hook_id" || -z "$hook_rel" ]]; then
    _block "sanitized-node: missing hookId/scriptPath arg (id='$hook_id' script='$hook_rel') — failing CLOSED" \
           "malformed blocking-gate registration; cannot confirm gate decision"
fi
case "$hook_rel" in
    /*|*..*) _block "sanitized-node: refusing hook path $hook_rel (absolute/traversal)" \
                    "bad hook script path; cannot confirm gate decision" ;;
esac
if [[ ! -f "$root/$hook_rel" ]]; then
    _block "sanitized-node: hook script missing: $root/$hook_rel — failing CLOSED" \
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
set +e
"$_node" "$runner" "$@" --fail-closed
_rc=$?
set -e
case "$_rc" in
    0|2) exit "$_rc" ;;
    *) _block "sanitized-node: runner exited $_rc (launch/crash, not a clean allow/block) — failing CLOSED" \
              "hook runner failed to execute (exit $_rc); blocking hook cannot confirm allow" ;;
esac
