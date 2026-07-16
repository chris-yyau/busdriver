#!/usr/bin/env bash
# tests/test-github-server-now.sh — scripts/github-server-now.sh RFC-7231 ->
# ISO-8601 conversion (issue #302 server-time anchor). Exercises the offline arg
# path (a canned `Date:` header); the live `gh api` path is a thin wrapper the
# tests don't hit. Verifies valid conversion and fail-EMPTY on malformed input.
# shellcheck disable=SC2312  # assertions intentionally capture conv() stdout via
# $(...) and compare it; the masked command return is the point, not a bug.
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$DIR/scripts/github-server-now.sh"
FAIL=0
ok()  { echo "OK:   $1"; }
bad() { echo "FAIL: $1"; FAIL=1; }
eq()    { if [[ "$1" == "$2" ]]; then ok "$3"; else bad "$3 (got '$1', want '$2')"; fi; }
empty() { if [[ -z "$1" ]]; then ok "$2"; else bad "$2 (got '$1')"; fi; }

conv() { bash "$SCRIPT" "$1"; }

# 1. Canonical IMF-fixdate -> ISO-8601 UTC.
eq "$(conv 'Date: Wed, 08 Jul 2026 16:25:31 GMT')" "2026-07-08T16:25:31Z" "canonical Date header -> ISO"
# 2. Month-map boundaries: Jan -> 01, Dec -> 12.
eq "$(conv 'Date: Fri, 01 Jan 2027 00:00:00 GMT')" "2027-01-01T00:00:00Z" "January -> 01"
eq "$(conv 'Date: Thu, 31 Dec 2026 23:59:59 GMT')" "2026-12-31T23:59:59Z" "December -> 12"
# 3. Case-insensitive header name (gh may emit `date:` lowercased).
eq "$(conv 'date: Wed, 08 Jul 2026 16:25:31 GMT')" "2026-07-08T16:25:31Z" "lowercase header name accepted"
# 3b. CRLF-terminated header — the shape the LIVE `gh api -i` path actually emits.
# Every other case here is hand-typed and CR-free, which is exactly why the live
# path could return empty forever without a single test noticing: real headers are
# CRLF-terminated (RFC 7230), and the trailing CR made `$7 == "GMT"` compare
# against "GMT\r" and fail, so ADR 0012's downgrade could never fire.
eq "$(conv "$(printf 'Date: Wed, 08 Jul 2026 16:25:31 GMT\r')")" "2026-07-08T16:25:31Z" \
  "CRLF-terminated live header -> ISO"
eq "$(conv "$(printf 'date: Thu, 16 Jul 2026 19:32:24 GMT\r')")" "2026-07-16T19:32:24Z" \
  "CRLF + lowercase name (real gh output shape) -> ISO"

# 4. Malformed inputs fail-EMPTY (caller then fails CLOSED).
empty "$(conv 'not a date line at all')"                  "non-Date line -> empty"
empty "$(conv 'Date: Wed, 8 Jul 2026 16:25:31 GMT')"      "single-digit day -> empty (RFC needs 2-digit)"
empty "$(conv 'Date: Wed, 08 Jzz 2026 16:25:31 GMT')"     "unknown month -> empty"
empty "$(conv 'Date: Wed, 08 Jul 26 16:25:31 GMT')"       "2-digit year -> empty"
empty "$(conv 'Date:')"                                    "bare Date header -> empty"
empty "$(conv '')"                                         "empty input -> empty"
# Range + timezone validation: a wrong-zone or impossible instant must not slip
# through as a garbage/off-by-hours ref.
empty "$(conv 'Date: Wed, 08 Jul 2026 16:25:31 PST')"     "non-GMT zone -> empty"
empty "$(conv 'Date: Wed, 08 Jul 2026 24:00:00 GMT')"     "hour 24 out of range -> empty"
empty "$(conv 'Date: Wed, 08 Jul 2026 16:60:31 GMT')"     "minute 60 out of range -> empty"
empty "$(conv 'Date: Wed, 00 Jul 2026 16:25:31 GMT')"     "day 00 out of range -> empty"
empty "$(conv 'Date: Wed, 32 Jul 2026 16:25:31 GMT')"     "day 32 out of range -> empty"
empty "$(conv 'Date: Wed, 08 Jul 2026 99:99:99 GMT')"     "all-99 time -> empty"

[[ "$FAIL" == 0 ]] && echo "PASS test-github-server-now" || exit 1
