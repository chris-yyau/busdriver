#!/usr/bin/env bash
# Gate environment-containment wrapper — issue #325, docs/adr/0016-gate-env-containment.md
#
# WHY: Claude Code merges a committed .claude/settings.json `env` block into the
# session environment, and every bash gate inherits it. That makes `env` a
# PR-controllable injection channel into the review gates:
#   - BASH_ENV / ENV / exported functions (BASH_FUNC_*) → arbitrary code runs
#     BEFORE a gate's own first line (RCE);
#   - PATH → prepend a repo-local dir to shim git / gh / jq / python3;
#   - GIT_* (GIT_DIR, GIT_WORK_TREE, GIT_CONFIG*, …) → redirect git resolution;
#   - SKIP_LITMUS / SKIP_PR_GRIND / SKIP_DESIGN_REVIEW → direct gate bypass;
#   - BUSDRIVER_PLUGIN_ROOT / BUSDRIVER_STATE_DIR → redirect which scripts get
#     sourced and which marker dir is read;
#   - LITMUS_PR_BASE / LITMUS_PR_BACKSTOP_MAX_AGE → move the diff base or inflate
#     the backstop-age window to manufacture a bypass.
# A per-script scrub cannot close this: BASH_ENV/PATH/functions compromise the
# script before it can defend itself. Containment must happen ABOVE the script.
#
# HOW: hooks.json invokes this wrapper under `/usr/bin/env -i` (absolute path so
# `env` itself can't be shimmed; `-i` wipes the ENTIRE environment, including
# exported shell functions), re-adding only a minimal PATH (enough to exec bash),
# HOME, and CLAUDE_PLUGIN_ROOT. This wrapper then rebuilds a TRUSTED PATH from a
# fixed allowlist of absolute dirs — never the caller's PATH — neutralizes global
# git config (so a re-imported HOME can't smuggle a ~/.gitconfig with executable
# git helpers), and execs the named gate with stdin (the PreToolUse JSON) passed
# through untouched.
#
# Re-imported vars (see ADR):
#   - CLAUDE_PLUGIN_ROOT locates THIS wrapper (hooks.json expands it before
#     `env -i`). This is NOT the settings.json-env injection channel: Claude Code
#     sets CLAUDE_PLUGIN_ROOT authoritatively per-plugin AFTER merging settings, so
#     a committed `env` block cannot override it (verified — Claude-provided vars
#     take precedence over the settings `env` block, docs v2.1.195+). It is the
#     plugin trust root every busdriver hook already relies on.
#   - HOME is re-imported for tools that need it (e.g. gh auth under ~/.config).
#     The concrete git-helper vector a poisoned HOME enabled is closed below; a
#     spoofed ~/.config/gh remains a bounded residual (read-only PR-state queries).
#     pre-commit-gate.sh's docs-only carve-out (#685/ADR 0044) additionally
#     re-imports the SAME pre-substitution value as BUSDRIVER_ORIG_HOME (this
#     wrapper never touches that name, so it survives the HOME override below
#     untouched) — commit_scope.py's unsanitized config pass reads it to check
#     the effective global git config under the HOME the authorized `git commit`
#     will actually run with, not this wrapper's defensively-substituted one.
#     Reported by Codex on PR #697, reproduced.
#   - Outer-shell BASH_ENV is VERIFIED not a live vector: Claude Code runs hook commands
#     via `sh -c` (documented, code.claude.com/docs/en/hooks.md), and a non-interactive
#     POSIX `sh` sources NO startup files, so BASH_ENV is not read before this command
#     (confirmed empirically: `/bin/sh -c` ignores a BASH_ENV that `bash -c` sources).
#     `env -i` then strips it for the gate. Only an upstream switch to `bash -c` reopens
#     it — an ADR 0016 revisit trigger, not closeable from inside the plugin.
set -euo pipefail

# ── Trusted PATH ───────────────────────────────────────────────────────────
# Rebuilt from fixed absolute dirs that EXIST on this host, never inherited, so a
# committed settings.json cannot prepend a shim ahead of the real tools the gates call
# (git, gh, jq, python3, date, stat, shellcheck). NOT all root-owned: /usr/local/bin and
# /opt/homebrew/bin are operator-writable on a default Homebrew install — trusted against
# REPO injection, not against local code already running as the operator (#660), which is
# why the passwd lookup below runs on a root-only PATH instead.
_p=""
for _d in /usr/local/bin /opt/homebrew/bin /opt/homebrew/sbin /usr/bin /bin /usr/sbin /sbin; do
    if [[ -d "$_d" ]]; then
        _p="${_p:+$_p:}$_d"
    fi
done
export PATH="$_p"
# LANG=C is safe: modern python3 auto-enables UTF-8 mode under a C locale (PEP 540)
# and the gates' grep work is ASCII marker matching. TMPDIR default for mktemp users.
export LANG="${LANG:-C}"
export TMPDIR="${TMPDIR:-/tmp}"
# Neutralize global + system git config so a re-imported (possibly poisoned) HOME
# cannot supply a ~/.gitconfig with an executable helper/alias/pager that runs when
# a gate calls git. Repo-local .git/config still applies (it is not part of the
# committed tree, so a PR cannot inject it) — gates need it for remote resolution.
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null
# HOME is re-derived from the password database (getpwnam), NOT the PR-influenced
# session env. A poisoned HOME is a general tool-config RCE channel: git helpers
# (~/.gitconfig — also neutralized above), a Python user-site
# ~/.local/lib/pythonX/site-packages/sitecustomize.py that runs on every `python3`,
# or a spoofed ~/.config/gh that feeds a gate fake PR state. The passwd home is the
# real operator's, independent of $HOME, so git/python3/gh all read trusted config.
# PYTHONNOUSERSITE also disables Python user-site outright (belt-and-suspenders; the
# gates use only stdlib).
export PYTHONNOUSERSITE=1
# ── HOME from passwd, derived in a STERILE child ───────────────────────────
# #660: the allowlist above contains /opt/homebrew/bin and /usr/local/bin, BOTH
# operator-writable on a default Homebrew install — and macOS ships no `getent` at
# all, so a planted one shadows nothing and its stdout became HOME for every
# contained gate. An imported shell FUNCTION outranks PATH the same way, and a purge
# is not the answer (a function named `unset` or `compgen` defeats the purge itself).
# So derive in a child under `/usr/bin/env -i` — invoked by absolute path, which no
# function name can match, and `-i` strips BASH_FUNC_*. The child therefore has no
# imported function at all, calls id/getent/dscl by absolute path, and parses with
# parameter expansion, so neither PATH nor any command NAME is consulted.
# SCOPE of that guarantee: it closes the #660 vector (PATH/command-name lookup) even
# for a hand invocation. It does NOT make the wrapper safe against a parent that has
# already imported hostile FUNCTIONS — one named `export`, `cd` or `exec` intercepts
# this script wherever it runs, and no in-script purge helps (a function named `unset`
# or `compgen` defeats the purge). That class is closed one level up: every hooks.json
# registration launches this wrapper under `/usr/bin/env -i`, which strips BASH_FUNC_*
# before bash starts. That launch invariant is enforced by a test, not by prose —
# tests/test-passwd-home-trusted-path.sh (gates) and tests/test-node-hook-containment.sh
# (node hooks) fail if any registration drops `env -i`.
# shellcheck disable=SC2016  # the child script is deliberately literal
_home=$(/usr/bin/env -i /bin/bash -c '
    u=$(/usr/bin/id -un 2>/dev/null) || exit 0
    [[ -n "$u" ]] || exit 0
    h=""
    if [[ -x /usr/bin/getent ]]; then
        line=$(/usr/bin/getent passwd "$u" 2>/dev/null) || line=""
        if [[ "$line" == *:*:*:*:*:*:* ]]; then rest=${line#*:*:*:*:*:}; h=${rest%%:*}; fi
    fi
    if [[ ( -z "$h" || ! -d "$h" ) && -x /usr/bin/dscl ]]; then
        out=$(/usr/bin/dscl . -read "/Users/$u" NFSHomeDirectory 2>/dev/null) || out=""
        [[ "$out" == *" "* ]] && h=${out##* }
    fi
    [[ -n "$h" && -d "$h" ]] && printf %s "$h"
' 2>/dev/null || true)
if [[ -n "$_home" && -d "$_home" ]]; then
    export HOME="$_home"
else
    # Could not derive a trusted home → FAIL CLOSED: drop the env-supplied (possibly
    # poisoned) HOME rather than trusting it. Tools that getpwuid-fall-back still find the
    # real home; a gh-using gate without HOME fails closed (blocks), never bypasses.
    unset HOME
fi

# ── Resolve the gate to run ────────────────────────────────────────────────
# A bare basename supplied by hooks.json (trusted), but reject path/traversal
# defensively. Fail with a visible error rather than silently approving — a bad
# arg means a broken hook config, not "no gate to run".
gate="${1:-}"
case "$gate" in
    ""|*/*|*..*)
        printf 'sanitized-gate: refusing gate arg %q (empty, path, or traversal)\n' "$gate" >&2
        exit 1
        ;;
esac

# CLAUDE_PLUGIN_ROOT is normally passed in; fall back to this wrapper's own
# location (lib/ → gate-scripts/ → hooks/ → plugin root, i.e. three levels up).
root="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
script="$root/hooks/gate-scripts/$gate"
if [[ ! -f "$script" ]]; then
    printf 'sanitized-gate: gate script not found: %s\n' "$script" >&2
    exit 1
fi

# stdin (the PreToolUse JSON) is inherited across exec untouched.
exec bash "$script"
