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
# Chrome writes that file itself ONLY when the debug port is dynamic (`--remote-debugging-port=0`);
# with an explicit port it writes nothing, which is why we never pin one. Dynamic ports
# also dodge the port-squatting we hit on 9222.
#
# Prints `ok <host>:<port>` on success. Every other outcome is a typed, non-zero,
# human-actionable line on stderr — fail CLOSED, consistent with ultra-oracle.sh.
# Idempotent and self-healing: safe to call before every consult, and the first call
# after a reboot simply relaunches Chrome (no launchd agent needed).
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

# TERM, then WAIT for the processes to actually go. Returning while the old Chrome still
# runs lets launch_chrome delete the DevToolsActivePort/Singleton files out from under a
# live process, which then races the replacement browser for the same profile. Escalate to
# KILL if TERM is ignored, so a wedged Chrome cannot stall the consult indefinitely.
kill_chrome() {
  local pid _w
  for pid in $(chrome_pids); do kill "$pid" 2>/dev/null; done
  for ((_w = 0; _w < 40; _w++)); do
    chrome_running || return 0
    sleep 0.25
  done
  for pid in $(chrome_pids); do kill -9 "$pid" 2>/dev/null; done
  for ((_w = 0; _w < 20; _w++)); do
    chrome_running || return 0
    sleep 0.25
  done
  return 1
}

# Is the listener on <port> actually OUR Chrome? `chrome_running` only proves some process
# references PROFILE and `cdp_alive` only proves something answers on that port — they can
# be two DIFFERENT browsers when a stale port file names a port another Chrome now owns,
# and the consult would then attach to the wrong (possibly signed-out) session. Intersect
# the listening PIDs with this profile's PIDs to tie the two halves together.
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

cdp_alive() { curl -sf -m 3 -o /dev/null "http://$HOST:$1/json/version" 2>/dev/null; }

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
  # Port 0 = let Chrome choose AND record it. No automation flags: that is the entire
  # point — a vanilla browser is what keeps Cloudflare quiet.
  "$bin" --user-data-dir="$PROFILE" --remote-debugging-port=0 https://chatgpt.com/ >/dev/null 2>&1 &
  # WALL-CLOCK deadline, not an iteration count: each iteration sleeps 0.5s AND can spend
  # up to 3s inside cdp_alive's curl timeout, so "30 iterations" was really up to ~105s —
  # nothing like the 15s this advertises. Bound the real elapsed time instead.
  local _deadline; _deadline=$(( $(date +%s) + LAUNCH_WAIT_SECONDS ))
  while [ "$(date +%s)" -lt "$_deadline" ]; do
    sleep 0.5
    local p; p="$(read_port 2>/dev/null || true)"
    [[ -n "$p" ]] && cdp_alive "$p" && port_owned_by_profile "$p" && return 0
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
# The residual race is narrow and self-correcting: two runs can interleave kill/launch such
# that one probe loop times out. It fails CLOSED (non-zero + a diagnostic), the adapter turns
# that into a typed 'error', and the next consult heals — the same contract as every other
# failure here. That is a strictly better trade than a lock whose stale-breaking is subtly
# wrong, because a wrong lock fails SILENTLY (two owners) rather than loudly.
mkdir -p "$PROFILE" 2>/dev/null || die "cannot create profile dir '$PROFILE'"

PORT="$(read_port 2>/dev/null || true)"

# Healthy already? Cheapest path — sub-second, and the common case. All three conditions
# are required TOGETHER: a live process on this profile, a port that answers, and that
# listener being one of OUR pids. The first two alone can describe two different browsers.
if [[ -n "$PORT" ]] && cdp_alive "$PORT" && port_owned_by_profile "$PORT"; then
  echo "ok $HOST:$PORT"; exit 0
fi

# Otherwise heal. A dead Chrome, a missing or stale port file, and a port owned by some
# OTHER browser all land here and are fixed the same way — relaunch clean. kill_chrome
# blocks until the processes are actually gone, so launch_chrome cannot delete state out
# from under a live one.
if chrome_running; then
  kill_chrome || die "could not terminate existing Chrome on profile '$PROFILE'"
fi

launch_chrome || die "Chrome did not expose a DevTools endpoint within ${LAUNCH_WAIT_SECONDS}s (profile: $PROFILE)"

PORT="$(read_port 2>/dev/null || true)"
if [[ -z "$PORT" ]] || ! cdp_alive "$PORT" || ! port_owned_by_profile "$PORT"; then
  die "launched Chrome but no usable DevTools port owned by this profile (profile: $PROFILE)"
fi

# ponytail: no ChatGPT sign-in probe here — reading page state needs a CDP WebSocket
# session, and oracle already emits a typed 'session not detected' hint that
# _ultra_oracle_diagnose_hint surfaces. Add one (open a tab, evaluate on
# document.querySelector) if a stale login turns out to cost real time in practice.
echo "ok $HOST:$PORT"
