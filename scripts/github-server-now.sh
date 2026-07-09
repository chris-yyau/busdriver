#!/usr/bin/env bash
# scripts/github-server-now.sh — emit GitHub server "now" as an ISO-8601 UTC
# instant (YYYY-MM-DDThh:mm:ssZ), read from the HTTP `Date` response header.
#
# WHY: ADR 0012's stale-ack downgrade stamps an event timestamp that
# advisory-downgrade-revalidate.sh later compares LEXICALLY against GitHub
# activity timestamps (created_at/submitted_at/createdAt). Stamping that ref
# with the LOCAL clock fails OPEN under operator clock skew (issue #302): a
# machine clock ahead of GitHub makes a fresh re-engagement sort BEFORE the ref
# and be wrongly read as silence. Anchoring the ref to GitHub's own clock makes
# it directly comparable, so skew cannot occur.
#
# Source: the `Date` header of `gh api -i /rate_limit` — /rate_limit is exempt
# from the core rate limit, so this costs no quota. Conversion RFC 7231 ->
# ISO-8601 uses a portable awk month-map (no GNU `date -d` vs BSD `date -jf`
# divergence). Echoes EMPTY on any failure so callers fail-CLOSED (no server
# anchor => refuse to downgrade), never a skew-prone local fallback.
#
# Usage:
#   scripts/github-server-now.sh                 # live: reads gh's Date header
#   scripts/github-server-now.sh 'Date: Wed, 08 Jul 2026 16:25:31 GMT'  # offline/test
set -u

# With ANY arg (even an empty string) $1 is a raw RFC-7231 `Date:` header line —
# the offline/test path; branch on arg COUNT, not `${1:-…}`, so an explicitly
# empty arg stays offline (yields empty) instead of falling through to gh. With
# no arg, fetch it live from the quota-exempt /rate_limit endpoint.
if [[ "$#" -ge 1 ]]; then
  _line="$1"
else
  # shellcheck disable=SC2312  # masked pipe return is intentional: any gh/grep
  # failure leaves _line empty, which the awk below turns into empty output ->
  # caller fails CLOSED. There is no failure here we want to surface differently.
  _line="$(gh api -i /rate_limit 2>/dev/null | grep -i '^date:' | head -1)"
fi

printf '%s\n' "$_line" | awk '
  tolower($1) == "date:" && NF >= 7 {
    split("Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec", _m, " ")
    for (i = 1; i <= 12; i++) mm[_m[i]] = sprintf("%02d", i)
    # RFC 7231 IMF-fixdate: "Wed, 08 Jul 2026 16:25:31 GMT"
    #   $3=day(2-digit) $4=Mon $5=year(4-digit) $6=hh:mm:ss $7=GMT
    # Validate token SHAPE, numeric RANGE, and that the zone is literally GMT so an
    # impossible or wrong-zone header (e.g. "99 Jul 2026 99:99:99" or a "... PST")
    # is rejected, not emitted as a garbage/off-by-hours instant that would poison
    # the downgrade ref. RFC 7231 fixes the zone as GMT; anything else is not the
    # instant we would claim by stamping "Z". Range only, not per-month day counts;
    # GitHub sends valid dates, this just rejects gross garbage.
    d = $3 + 0; hh = substr($6, 1, 2) + 0; mi = substr($6, 4, 2) + 0; ss = substr($6, 7, 2) + 0
    if (($4 in mm) && ($3 ~ /^[0-9][0-9]$/) && ($5 ~ /^[0-9][0-9][0-9][0-9]$/) \
        && ($6 ~ /^[0-9][0-9]:[0-9][0-9]:[0-9][0-9]$/) && ($7 == "GMT") \
        && d >= 1 && d <= 31 && hh <= 23 && mi <= 59 && ss <= 60)
      printf "%s-%s-%sT%sZ\n", $5, mm[$4], $3, $6
  }'
