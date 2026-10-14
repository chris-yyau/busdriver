#!/bin/bash
# grok-auth-ready.sh — will grok's login outlive this dispatch? (#882)
#
# INVOKED ONLY BY resolve-cli.sh's grok_auth_ready, after grok_sandbox_preflight
# passed, as `/usr/bin/env -i /bin/bash -p <this file> <home> <pinned-path>
# <budget-seconds>`. <home> and <pinned-path> are the values that preflight
# derived and verified; nothing else is inherited.
#
# WHY. The busdriver-review profile denies **/.grok, so grok inside the sandbox
# cannot take ~/.grok/auth.json.lock and cannot renew its access token. grok
# renews only once the token has EXPIRED (6h lifetime), so a review that starts
# with an expired token, or outlives it, gets 401s until the dispatch timeout
# and leaves no review JSON. Widening the sandbox to write ~/.grok would let the
# grok that reads untrusted content rewrite the operator's credentials, so the
# sandbox stays as it is and this check runs OUTSIDE it instead:
#   * expired  -> run `grok models` once, unsandboxed, to let grok's own login
#                 code renew the token, then check again;
#   * expires before now + budget -> refuse now, not after the budget is spent.
#
# Contract: prints `OK` and exits 0 when the earliest expires_at in auth.json
# is later than now + budget + 60s (measured after any renewal); otherwise prints `WHY=auth` (no usable
# login, or renewal failed) or `WHY=auth-expiring` (valid now, expires mid-run)
# and exits 1. Never prints anything read from auth.json.

set -u
PATH=/usr/bin:/bin
home="${1:-}"
pinned="${2:-}"
budget="${3:-}"

[[ "${home#/}" != "$home" && -n "$pinned" ]] || { printf 'WHY=auth\n'; exit 1; }
# At most 9 digits, and base 10 forced: a leading zero would otherwise be read
# as octal (01200 -> 640s, and 08 an arithmetic error).
[[ "$budget" =~ ^[0-9]{1,9}$ ]] || { printf 'WHY=auth\n'; exit 1; }
budget=$((10#$budget))
auth="$home/.grok/auth.json"

# Fixed-format UTC ISO-8601 compares correctly as a string, so the deadline is
# formatted the same way instead of parsing expires_at per platform (BSD vs GNU
# date). The fractional tail of expires_at costs at most 1s.
iso_at() {
  /usr/bin/perl -MPOSIX -e 'print strftime("%Y-%m-%dT%H:%M:%S", gmtime($ARGV[0]))' "$1" 2>/dev/null
}

# Earliest expires_at across scope entries (conservative when there are
# several). Empty when the file is missing or no value has the expected shape.
earliest() {
  [[ -f "$auth" && ! -L "$auth" ]] || return 0
  /usr/bin/grep -oE '"expires_at"[[:space:]]*:[[:space:]]*"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?Z"' "$auth" 2>/dev/null |
    /usr/bin/sed -E 's/.*"([0-9T:-]{19})[^"]*"$/\1/' | /usr/bin/sort | /usr/bin/head -n 1
}

# Sets now_iso and deadline (now + budget + 60s) from the clock.
clock() {
  now="$(/bin/date +%s)" || return 1
  [[ "$now" =~ ^[0-9]+$ ]] || return 1
  now_iso="$(iso_at "$now")"
  deadline="$(iso_at $((now + budget + 60)))"
  [[ ${#now_iso} -eq 19 && ${#deadline} -eq 19 ]]
}
clock || { printf 'WHY=auth\n'; exit 1; }

exp="$(earliest)"
if [[ -n "$exp" && ! "$exp" > "$now_iso" ]]; then
  # Expired. No prompt, no repo content, an empty cwd and the operator's own
  # verified grok: only grok's login code touches the operator's own file.
  # Bounded so a hook waiting for approval (#560) cannot hang the dispatch.
  # The callers do not count this against their budget, so it is kept short:
  # min(15s, budget), against ~1.3s measured for a plain `grok models`.
  cap=15
  [[ "$budget" -lt "$cap" ]] && cap="$budget"
  [[ "$cap" -ge 1 ]] || cap=1
  tmp="$(/usr/bin/mktemp -d)" || { printf 'WHY=auth\n'; exit 1; }
  if [[ -x /usr/bin/timeout ]]; then
    lim=(/usr/bin/timeout "$cap")
  else
    lim=(/usr/bin/perl -e 'alarm shift; exec @ARGV or exit 127' "$cap")
  fi
  (cd "$tmp" && "${lim[@]}" /usr/bin/env -i PATH="$pinned" HOME="$home" \
    GROK_HOME="$home/.grok" GROK_CLAUDE_HOOKS_ENABLED=0 \
    GROK_CURSOR_HOOKS_ENABLED=0 HINDSIGHT_DISABLED=1 \
    grok models) </dev/null >/dev/null 2>&1 || :
  /bin/rm -rf -- "$tmp" 2>/dev/null || :
  exp="$(earliest)"
  # The review starts after the renewal, so its deadline does too.
  clock || { printf 'WHY=auth\n'; exit 1; }
fi

[[ -n "$exp" && "$exp" > "$now_iso" ]] || { printf 'WHY=auth\n'; exit 1; }
[[ "$exp" > "$deadline" ]] || { printf 'WHY=auth-expiring\n'; exit 1; }
printf 'OK\n'
exit 0
