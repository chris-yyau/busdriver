#!/bin/bash
# ultra-oracle-attach-preflight.sh — make oracle's `--browser-attach-running` path usable.
#
# WHY THIS EXISTS (ADR 0020): oracle's own Chrome launches carry automation flags that
# Cloudflare fingerprints, so every `oracle serve` / cookiePath consult walked into a
# "Just a moment" challenge that no amount of re-login clears. Attaching to an ordinary
# Chrome sidesteps the challenge entirely — but oracle only DISCOVERS an attachable
# browser by walking `~/Library/Application Support` for a `DevToolsActivePort` file
# (oracle 0.15.2 dist/src/browser/detect.js:105, filtered to the requested port in
# attachRunning.js). That imposes two hard constraints this script satisfies:
#   1. the profile MUST live under ~/Library/Application Support, and
#   2. a CURRENT DevToolsActivePort file must exist in it.
#
# NO `--remote-debugging-port` LAUNCH FLAG (2026-10, Chrome 155 / oracle 0.21). Cloudflare
# now challenges a Chrome started with that flag even with no client attached, and a human
# cannot pass the check there — verified on one profile and network: flag-free launch loads
# chatgpt.com, the same profile relaunched with the flag is challenged every time. The debug
# server is instead turned on AT RUNTIME by the operator, via Chrome's own
# chrome://inspect/#remote-debugging toggle; Chrome then writes DevToolsActivePort itself
# (dynamic port, root of the user-data-dir). Toggle mode serves no HTTP discovery
# (/json/version answers 404) and Chrome asks the operator to Allow each CDP connection —
# oracle waits for that via --browser-approval-wait. Never automate that Allow: it is
# Chrome's consent gate for full control of the browser.
#
# Prints `ok <host>:<port>` on success. Every other outcome is a typed, non-zero,
# human-actionable line on stderr — fail CLOSED, consistent with ultra-oracle.sh.
# Idempotent: safe to call before every consult. A cold call launches a plain Chrome and
# names the toggle step if no debug server appears; it never kills a running browser.
set -uo pipefail

HOST="127.0.0.1"
LAUNCH_WAIT_SECONDS=15   # budget for a cold Chrome to expose its DevTools endpoint
PROFILE="${1:-$HOME/Library/Application Support/oracle-attach}"

die() { echo "ultra-oracle-attach: $1" >&2; exit 1; }

# oracle's discovery root on macOS is exactly ~/Library/Application Support. A profile
# anywhere else is INVISIBLE to attach mode no matter how healthy its CDP endpoint is —
# fail loudly here rather than let the consult burn its full timeout cap discovering that.
#
# CANONICALIZE FIRST. A purely lexical prefix test passes for `.../Application Support/../../evil`
# or a symlink pointing outside the root, and this script then runs a destructive
# `find ... -delete` and launches Chrome against that directory — while oracle still
# cannot discover it. Resolve both sides and compare the real paths. The profile need not
# exist yet (first run creates it), so resolve its nearest existing ancestor.
_canon() {
  python3 - "$1" <<'PY' 2>/dev/null
import os, sys
p = os.path.abspath(sys.argv[1])
probe = p
while probe != os.path.dirname(probe) and not os.path.exists(probe):
    probe = os.path.dirname(probe)
rel = os.path.relpath(p, probe)
# normpath (NOT rstrip) collapses the "." that relpath returns when p already exists:
# rstrip("/.") would also eat legitimate trailing dots, mangling a profile literally
# named e.g. "oracle-attach." into "oracle-attach".
print(os.path.realpath(probe) if rel == "." else os.path.normpath(os.path.join(os.path.realpath(probe), rel)))
PY
}
_ROOT="$(_canon "$HOME/Library/Application Support")"
PROFILE="$(_canon "$PROFILE")"
[[ -n "$PROFILE" && -n "$_ROOT" ]] || die "could not resolve profile path (python3 required)"
case "$PROFILE" in
  "$_ROOT"/?*) : ;;
  *) die "profile '$PROFILE' resolves outside ~/Library/Application Support — oracle's attach discovery only walks that root, so it would never be found" ;;
esac

chrome_bin() {
  local c
  # Test seam: an explicit override wins over the fixed search paths so the
  # command-mocked harness (tests/test-ultra-oracle-attach-preflight.sh) can point
  # the launch at a fake Chrome and never risk starting a real browser — the real
  # /Applications binary exists on the maintainer's Mac and would otherwise be
  # picked first. Underscore-prefixed, test-only, like the other _UORA_* internals.
  # If it is SET but not usable, FAIL (return 1) rather than fall through to the real
  # browser search — a botched harness setup must not silently launch real Chrome.
  # `+x` tests SET-ness (not emptiness), so an empty `_UORA_CHROME_BIN=` also fails
  # closed instead of falling through.
  if [[ -n "${_UORA_CHROME_BIN+x}" ]]; then
    # -f as well as -x: a directory is executable/searchable, so `-x` alone would
    # accept a directory here and only fail later at launch. Require a regular file.
    [[ -n "$_UORA_CHROME_BIN" && -f "$_UORA_CHROME_BIN" && -x "$_UORA_CHROME_BIN" ]] && { printf '%s' "$_UORA_CHROME_BIN"; return 0; }
    return 1
  fi
  for c in "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
           "$HOME/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"; do
    [[ -x "$c" ]] && { printf '%s' "$c"; return 0; }
  done
  return 1
}

# PIDs of Chrome processes running on exactly this profile. Two approaches were tried and
# rejected, both worth recording because each fails silently:
#   - `pgrep -f "user-data-dir=$PROFILE"` treats the pattern as an extended REGEX, so a
#     profile name containing `.`, `[`, `*` matches unrelated processes — and `pkill` would
#     then terminate someone else's Chrome.
#   - an awk whitespace-field comparison never matches at all, because the DEFAULT profile
#     path contains a space ("Application Support"), so no single field equals the flag.
# Match the flag as a LITERAL substring instead, requiring a space (or end of line) right
# after the path so a sibling profile sharing a prefix (`oracle-attach` vs `oracle-attach2`)
# cannot match. `case` patterns treat the quoted expansion literally, so regex/glob
# metacharacters in the path are inert.
chrome_pids() {
  # -ww: never let ps truncate to display width. Output here is piped (not a tty) so
  # macOS ps already emits full lines, but -ww makes that independent of call context.
  ps -Awwo pid=,command= | while read -r pid rest; do
    case "$rest " in *"--user-data-dir=$PROFILE "*) printf '%s\n' "$pid" ;; esac
  done
}
chrome_running() { [[ -n "$(chrome_pids)" ]]; }

# A Chrome on this profile started WITH the debug-port flag (e.g. by the pre-toggle version
# of this script) is exactly the browser Cloudflare challenges. Same literal-substring match
# as chrome_pids.
chrome_has_port_flag() {
  local cmd
  while read -r cmd; do
    case "$cmd " in *"--user-data-dir=$PROFILE "*) [[ "$cmd" == *--remote-debugging-port* ]] && return 0 ;; esac
  done < <(ps -Awwo command=)
  return 1
}

# Is the listener on <port> actually OUR Chrome? A port file alone proves nothing — it can
# be stale and name a port another Chrome now owns, and the consult would then attach to
# the wrong (possibly signed-out) session. Intersect the listening PIDs with this profile's
# PIDs to tie the two halves together.
port_owned_by_profile() {
  local lpid cpid pids; pids="$(chrome_pids)"
  [[ -n "$pids" ]] || return 1
  for lpid in $(lsof -nP -iTCP:"$1" -sTCP:LISTEN -t 2>/dev/null); do
    for cpid in $pids; do [[ "$lpid" = "$cpid" ]] && return 0; done
  done
  return 1
}

# Read the port Chrome recorded. ROOT FILE ONLY — verified against Chrome 150: with a
# dynamic debug port Chrome writes `<user-data-dir>/DevToolsActivePort` and nothing under
# Default/. A nested Default/DevToolsActivePort therefore only ever arrives by COPYING
# another user-data-dir, so it is stale by construction; honoring it (even "if newer",
# since a copy carries a fresh mtime) risks attaching to a DIFFERENT browser that happens
# to own that port. launch_chrome() deletes such copies rather than reading them.
read_port() {
  local f="$PROFILE/DevToolsActivePort"
  [[ -f "$f" ]] || return 1
  head -1 "$f" | tr -dc '0-9'
}

TOGGLE_HINT="remote debugging is off in the oracle-attach Chrome (profile: $PROFILE): in that window open chrome://inspect/#remote-debugging, tick 'Allow remote debugging for this browser instance', then re-run — and click Allow when Chrome asks for each oracle connection"

launch_chrome() {
  local bin; bin="$(chrome_bin)" || die "Google Chrome not found in /Applications or ~/Applications"
  mkdir -p "$PROFILE" || die "cannot create profile dir '$PROFILE'"
  # Clear stale DevToolsActivePort files (including a copied Default/ one) so a truthful
  # port is what we read back. `find` (not a glob) because an unmatched glob aborts the
  # whole statement under zsh.
  #
  # Singleton* is deliberately NOT deleted. Those files ARE Chrome's profile-exclusion
  # mechanism — the one this script now relies on instead of its own lock. Removing them
  # would let two Chromes co-own a user-data-dir, re-creating by hand exactly the corruption
  # the lock was meant to prevent. Chrome reclaims its own stale Singleton locks on startup.
  find "$PROFILE" -maxdepth 2 -name DevToolsActivePort -delete 2>/dev/null
  # No flags at all — see the header. The debug server only appears if the operator's
  # runtime toggle is on in this profile.
  "$bin" --user-data-dir="$PROFILE" https://chatgpt.com/ >/dev/null 2>&1 &
  # WALL-CLOCK deadline, not an iteration count, so the budget is the real elapsed time.
  local _deadline; _deadline=$(( $(date +%s) + LAUNCH_WAIT_SECONDS ))
  while [ "$(date +%s)" -lt "$_deadline" ]; do
    sleep 0.5
    local p; p="$(read_port 2>/dev/null || true)"
    [[ -n "$p" ]] && port_owned_by_profile "$p" && return 0
  done
  return 1
}

# NO PREFLIGHT-LEVEL LOCK — deliberately. An earlier revision serialized concurrent runs
# with a mkdir lock, and safely breaking a STALE one needs atomic compare-and-delete, which
# mkdir cannot express: four successive review rounds each closed one race and left a
# narrower one (two waiters both judging an owner dead, the delayed one then deleting the
# NEW owner's lock; PID recycling; the publish gap before the pid file lands).
#
# Chrome already provides the atomicity we were re-implementing. Its own SingletonLock makes
# profile ownership exclusive: a second Chrome launched against the same user-data-dir hands
# off to the first and exits. So concurrent preflights converge instead of corrupting each
# other — the loser's launch simply exits, and its probe loop then observes the winner's
# healthy browser and returns that port. Both callers get the same, correct target.
#
# The residual race is narrow and self-correcting: two cold runs can interleave launches
# such that one probe loop times out. It fails CLOSED (non-zero + a diagnostic), the adapter turns
# that into a typed 'error', and the next consult heals — the same contract as every other
# failure here. That is a strictly better trade than a lock whose stale-breaking is subtly
# wrong, because a wrong lock fails SILENTLY (two owners) rather than loudly.
mkdir -p "$PROFILE" 2>/dev/null || die "cannot create profile dir '$PROFILE'"

PORT="$(read_port 2>/dev/null || true)"

# A flag-launched Chrome is Cloudflare-challenged however healthy its port looks.
if chrome_has_port_flag; then
  die "the Chrome on profile '$PROFILE' was started with --remote-debugging-port, which Cloudflare challenges: quit that Chrome and re-run"
fi

# Healthy already? Cheapest path — sub-second, and the common case. Both are required
# TOGETHER: a recorded port and that port's listener being one of OUR pids. (Toggle mode
# serves no HTTP discovery, so there is no /json/version probe to add.)
if [[ -n "$PORT" ]] && port_owned_by_profile "$PORT"; then
  echo "ok $HOST:$PORT"; exit 0
fi

# Running without a live debug server: the toggle is off. Relaunching cannot turn it on,
# so never kill the operator's window — say what to click.
chrome_running && die "$TOGGLE_HINT"

# Cold: open a plain Chrome; it exposes a port only if the toggle survived the restart.
launch_chrome || die "$TOGGLE_HINT"
PORT="$(read_port 2>/dev/null || true)"

# ponytail: no ChatGPT sign-in probe here — reading page state needs a CDP WebSocket
# session, and oracle already emits a typed 'session not detected' hint that
# _ultra_oracle_diagnose_hint surfaces. Add one (open a tab, evaluate on
# document.querySelector) if a stale login turns out to cost real time in practice.
echo "ok $HOST:$PORT"
