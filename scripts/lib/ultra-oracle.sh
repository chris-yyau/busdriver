#!/bin/bash
# ultra-oracle.sh — the ONLY surface that consults ChatGPT Pro (Layer-2). One guarded
# `claude -p --chrome` child per consult drives the operator's signed-in Chrome (ADR 0061).
# Fails CLOSED: prints ONE typed status token; callers MUST surface it, never
# silently skip. Reuses resolve-cli.sh _portable_timeout + is_cli_available.
# Harness-neutral; no bash-4-isms (no associative arrays / mapfile).
# Conditional style: [[ ]] for string/file tests; POSIX [ ] for integer -gt/-ge
# comparisons. `[ ]` does base-10 strtol with NO arithmetic evaluation, which
# avoids [[ ]]'s octal-parse of leading-zero values (e.g. "09999") AND its
# command-substitution-in-arithmetic injection surface (e.g. RHS "a[$(cmd)]").
# Portable dir resolution. BASH_SOURCE is unset under zsh (and other non-bash shells), where
# `dirname "${BASH_SOURCE[0]}"` silently collapses to "." and mis-sources the sibling libs from
# the CWD — functions end up undefined with no error. Guard loudly: this lib is bash-only, so
# fail closed rather than half-load.
if [ -z "${BASH_SOURCE:-}" ]; then
  echo "ultra-oracle.sh: ERROR — must be sourced under bash (BASH_SOURCE unset; zsh/other shells mis-resolve the script dir and half-load)" >&2
  # shellcheck disable=SC2317  # reached when sourced under a non-bash shell
  return 1 2>/dev/null || exit 1
fi
_ULTRA_ORACLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${_ULTRA_ORACLE_DIR}/ultra-oracle-config.sh"   # also transitively sources resolve-cli.sh
# shellcheck source=/dev/null
source "${_ULTRA_ORACLE_DIR}/ultra-oracle-chrome.sh"   # Chrome transport (ADR 0061); inert until the flip
source "${_ULTRA_ORACLE_DIR}/ultra-oracle-verdict.sh"   # post-exit audit and publication (ADR 0061)

# _ultra_oracle_verdict_ok <file> -> 0 if the file holds a usable verdict.
# A usable verdict must be more than a degenerate token. The oracle browser engine can
# exit 0 yet write a near-empty body (observed live: a 2-byte "I\n" when extraction
# races the response stream or the ChatGPT session is stale). A bare `-s` (non-empty)
# check accepts that and renders junk as a successful verdict (false-ok). Require a
# minimum count of NON-WHITESPACE bytes so single-token captures ("I", "ok", "n/a")
# fail closed while any real one-sentence advisory passes. Tunable via
# ULTRA_ORACLE_MIN_VERDICT_BYTES (default 8; invalid/empty/zero falls back to 8).
# Note: wc -c counts bytes, not Unicode characters — multibyte chars count more than
# one toward the floor. ASCII verdicts dominate in practice; the byte floor is the
# correct primitive here (we're guarding against near-empty captures, not charset issues).
_ultra_oracle_verdict_ok() {
  local f="$1" min nonws
  min="${ULTRA_ORACLE_MIN_VERDICT_BYTES:-8}"
  case "$min" in ''|*[!0-9]*|0) min=8;; esac
  [[ -s "$f" ]] || return 1
  nonws="$(tr -d '[:space:]' < "$f" 2>/dev/null | wc -c | tr -dc '0-9')"
  [[ -n "$nonws" ]] || return 1
  [ "$nonws" -ge "$min" ]
}

# _ultra_oracle_diagnose_hint <err-file> -> the §6 operator sentence for the first reason in a
# consult's .err (ADR 0061). Prints nothing for an unreadable or empty file.
_ultra_oracle_diagnose_hint() {
  local r
  [[ -r "$1" ]] || return 0
  r="$(head -1 "$1" 2>/dev/null)"
  [[ -n "$r" ]] && _uora_hint "$r"
  return 0
}

# ---- concurrent-consult browser mutex (issue #477 Cause 2) --------------------------------
# The Chrome transport drives ONE shared browser instance: the operator's Chrome, through the
# Claude-in-Chrome extension (ADR 0061). Two consults at once — e.g. a
# council in one session and a plan-review in another, on the SAME machine — drive that same browser
# concurrently; one hangs or harvests the other's tab. Serialize them with a portable, $HOME-anchored
# file mutex (macOS ships no flock(1)). This serializes SAME-MACHINE consults, which is #477's scope
# (a solo operator's overlapping council/plan-review); a serve shared across machines/accounts is a
# KNOWN limitation the local lock can't cover — cross-client serialization is the serve's job (see the
# remoteHost branch). cookiePath/copy-profile each launch their OWN Chrome, so there is nothing to
# serialize. The lock is published ATOMICALLY WITH its
# metadata via ln(1) — a hardlink from a fully-written temp file, which fails if the target exists
# (O_EXCL) — so a visible lock ALWAYS carries valid holder metadata; there is no create-then-write
# window that could wedge it. Acquire is a plain atomic `ln`; a dir that cannot support it is an
# ERROR (the Chrome consult never runs unlocked, ADR 0061). ONLY the
# owner ever removes its lock, and it does so nonce-checked — there is DELIBERATELY no auto-reclaim.
# Why: no portable, suspension-safe liveness signal exists here. bash 3.2 exposes no $BASHPID, so a
# disowned consult's real pid is unknowable ($$ is the parent wrapper's); and "the deadline passed" is
# equally true of a merely SUSPENDED holder, so any age/deadline-based reclaim (even one behind an
# exclusive reclaim-right) can remove a lock a stopped holder still owns and later have it resume and
# delete a successor — concurrent drive (#477 review, rounds 3-8). With no reclaimer, no party can
# mutate a held lock, so both acquire and release are race-free under arbitrary suspension. The one
# cost is a CRASHED holder's lock persists: contenders wait, surface a manual `rm -f`
# pointer when they give up, then fail closed — a stuck advisory consult (non-gating), never a silent double-drive. The
# recorded deadline is used only to label that diagnostic. Best-effort serialization, not a security
# gate — the shared browser is a soft resource; this hardens the unlocked status quo without ever
# trading safety for automatic crash recovery that portable shell cannot provide correctly.
_ultra_oracle_lock_file() {
  # Deterministic PER-USER lock path for <key>, anchored at $HOME — NOT $TMPDIR, which varies per
  # process (two sessions sharing one browser could get $TMPDIR vs /tmp and never meet, bypassing
  # serialization). Consults sharing an attached browser share $HOME. cksum is POSIX; hashing keeps
  # odd characters (profile paths, hostnames) out of the filename.
  local root h
  root="${HOME:-/tmp}/.cache/busdriver"; mkdir -p "$root" 2>/dev/null
  h="$(printf '%s' "$1" | cksum 2>/dev/null | tr -dc '0-9')"; [[ -n "$h" ]] || h=0
  printf '%s/ultra-oracle.%s.lock' "$root" "$h"
}
_ultra_oracle_lock_recovery_line() { # <lockfile>
  echo "ultra-oracle: gave up waiting for the Chrome consult lock $1. ONLY if no consult is still running — check that \`pgrep -fl 'claude -p --chrome'\` prints nothing — remove it to unblock: rm -f '$1'" >&2
}
_ultra_oracle_browser_lock() {
  # <key> <wait-secs> <holder-cap> [<give-up-epoch>] -> rc 0 + "<lockfile>\t<nonce>"; rc 1 when not
  # acquired in time (a waiter that gives up on a HELD lock prints the recovery line, spec §1);
  # rc 2 when the lock dir cannot support atomic locking. <holder-cap> sizes the recorded deadline.
  local key="$1" wait="$2" hcap="$3" giveup="${4:-}" lf now waited=0 tmp nonce deadline
  case "$wait" in ''|*[!0-9]*) wait=600 ;; esac
  case "$hcap" in ''|*[!0-9]*|0) hcap=600 ;; esac
  case "$giveup" in *[!0-9]*) giveup="" ;; esac
  lf="$(_ultra_oracle_lock_file "$key")"
  printf -v nonce '%04x%04x%04x' "$RANDOM" "$RANDOM" "$RANDOM"
  tmp="$(mktemp "${lf}.XXXXXX" 2>/dev/null)" || tmp=""
  if [[ -z "$tmp" ]] || ! ln "$tmp" "${tmp}.lnk" 2>/dev/null; then
    [[ -n "$tmp" ]] && rm -f "$tmp" "${tmp}.lnk" 2>/dev/null
    echo "ultra-oracle: the lock dir cannot support atomic locking — failing closed (a Chrome consult never runs unlocked)" >&2
    return 2
  fi
  rm -f "$tmp" "${tmp}.lnk" 2>/dev/null
  while :; do
    now="$(_uora_now)" || { echo "ultra-oracle: cannot read the clock — failing closed" >&2; return 2; }
    # The give-up time bounds the acquire itself, not only the wait: a waiter that wakes past it,
    # or a caller already past it, never takes the lock.
    if [ -n "$giveup" ] && [ "$now" -ge "$giveup" ]; then
      [[ -e "$lf" ]] && _ultra_oracle_lock_recovery_line "$lf"
      return 1
    fi
    deadline=$(( now + hcap + 120 ))
    tmp="$(mktemp "${lf}.XXXXXX" 2>/dev/null)" \
      || { echo "ultra-oracle: the lock dir became unwritable — failing closed" >&2; return 2; }
    if printf '%s %s' "$nonce" "$deadline" > "$tmp" 2>/dev/null && [[ -s "$tmp" ]] \
       && ln "$tmp" "$lf" 2>/dev/null; then
      rm -f "$tmp" 2>/dev/null
      printf '%s\t%s' "$lf" "$nonce"; return 0
    fi
    rm -f "$tmp" 2>/dev/null
    if [ "$waited" -ge "$wait" ]; then
      [[ -e "$lf" ]] && _ultra_oracle_lock_recovery_line "$lf"
      return 1
    fi
    sleep 1; waited=$(( waited + 1 ))
  done
}
_ultra_oracle_browser_unlock() {
  # "<lockfile>\t<nonce>" -> release the lock IF it still records OUR nonce. Race-free with NO
  # coordination primitive precisely because there is NO reclaimer: only the owner ever removes its
  # lock, so no other party can mutate $lf between our read and our rm, and a holder suspended for any
  # length of time simply removes its own still-present lock on resume (nothing could have replaced
  # it). No-op on an empty/degraded handle.
  local h="${1:-}" lf nonce cur
  lf="${h%%$'\t'*}"; nonce="${h#*$'\t'}"
  [[ -n "$lf" && "$nonce" != "$h" ]] || return 0     # no TAB -> empty/degraded handle -> nothing to do
  cur="$(cat "$lf" 2>/dev/null)"; cur="${cur%% *}"
  [[ "$cur" == "$nonce" ]] && rm -f "$lf" 2>/dev/null
  return 0
}

# ultra_oracle_consult --prompt <t> | --prompt-file <p>  [--context <file>]... \
#   --out <path> [--mode blocking|background] [--timeout-cap-seconds <n>] [--slug <words>]
# Prints exactly one of: ok | skipped:unavailable | skipped:user | timeout | error | dispatched
#
# Every --context file is staged with the prompt into one private text file, under a basename-only
# header, and uploaded as one attachment (spec 2026-11-01 §2). --slug is accepted and ignored.
ultra_oracle_consult() { _uora_chrome_consult "$@"; }
