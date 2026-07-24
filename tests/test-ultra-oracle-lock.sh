#!/bin/bash
# tests/test-ultra-oracle-lock.sh
# Exercises the concurrent-consult browser mutex (issue #477 Cause 2): the portable
# ln(1)-atomic file lock that serializes consults sharing ONE attached browser.
# Covers acquire/release, the busy-timeout path, stale reclaim by the holder's OWN
# deadline (no pid check — see the helper header), per-key isolation, and nonce-fenced
# unlock (a reclaimed holder must not delete its successor's lock).
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAIL=0
tmp="$(mktemp -d)"; export HOME="$tmp"; export TMPDIR="$tmp"; mkdir -p "$tmp/.claude"
trap 'rm -rf "$tmp"' EXIT INT TERM
# shellcheck source=/dev/null
source "$DIR/scripts/lib/ultra-oracle.sh"

nonce_of() { printf '%s' "${1#*$'\t'}"; }   # extract nonce from a "<lf>\t<nonce>" handle

# (a) acquire returns a "<lf>\t<nonce>" handle; the lock FILE now exists with content
h="$(_ultra_oracle_browser_lock "attach:/p" 5 60)" || { echo "FAIL (a) acquire returned nonzero"; FAIL=1; }
lf="${h%%$'\t'*}"
[ -n "$lf" ] && [ -f "$lf" ] && [ -s "$lf" ] || { echo "FAIL (a) lock file '$lf' missing/empty"; FAIL=1; }
[ "$(nonce_of "$h")" != "$h" ] || { echo "FAIL (a) handle carried no nonce"; FAIL=1; }

# (b) busy: a second acquire of the SAME key (live holder, future deadline) times out
if _ultra_oracle_browser_lock "attach:/p" 1 60 >/dev/null 2>&1; then
  echo "FAIL (b) second acquire on held key should have failed"; FAIL=1
fi

# (c) distinct key does NOT contend
h2="$(_ultra_oracle_browser_lock "remote:host" 1 60)" || { echo "FAIL (c) distinct key blocked"; FAIL=1; }
[ -n "$h2" ] && [ "${h2%%$'\t'*}" != "$lf" ] || { echo "FAIL (c) distinct key reused same lock"; FAIL=1; }
_ultra_oracle_browser_unlock "$h2"

# (d) release removes the lock, and the key can be re-acquired
_ultra_oracle_browser_unlock "$h"
[ -e "$lf" ] && { echo "FAIL (d) unlock left the lock behind"; FAIL=1; }
h3="$(_ultra_oracle_browser_lock "attach:/p" 2 60)" || { echo "FAIL (d) re-acquire after release failed"; FAIL=1; }
_ultra_oracle_browser_unlock "$h3"

# (e) an existing lock blocks a contender — there is DELIBERATELY no auto-reclaim (suspension-safe)
lf_e="$(_ultra_oracle_lock_file "attach:/held")"; printf '%s %s' "deadbeef" "$(( $(date +%s) + 9999 ))" > "$lf_e"
if _ultra_oracle_browser_lock "attach:/held" 1 60 >/dev/null 2>&1; then
  echo "FAIL (e) acquired an already-held lock"; FAIL=1
fi
rm -f "$lf_e"

# (f) even a PAST-deadline (crashed-holder) lock is NOT auto-removed; only a manual rm unblocks
lf_f="$(_ultra_oracle_lock_file "attach:/crashed")"; printf '%s %s' "cafef00d" "$(( $(date +%s) - 5 ))" > "$lf_f"
if _ultra_oracle_browser_lock "attach:/crashed" 1 60 >/dev/null 2>&1; then
  echo "FAIL (f) auto-reclaimed a stale lock (must require manual cleanup)"; FAIL=1
fi
[ -e "$lf_f" ] || { echo "FAIL (f) stale lock was removed (should be left for manual rm)"; FAIL=1; }
rm -f "$lf_f"   # manual cleanup unblocks
hf="$(_ultra_oracle_browser_lock "attach:/crashed" 2 60)" || { echo "FAIL (f) acquire after manual cleanup failed"; FAIL=1; }
_ultra_oracle_browser_unlock "$hf"

# (g) nonce fence: unlocking a live lock with the WRONG nonce must NOT delete it
hg="$(_ultra_oracle_browser_lock "attach:/fence" 2 60)"; lf_g="${hg%%$'\t'*}"
_ultra_oracle_browser_unlock "$lf_g"$'\t'"deadbeef"      # wrong nonce -> must not delete
[ -e "$lf_g" ] || { echo "FAIL (g) wrong-nonce unlock deleted the lock"; FAIL=1; }
_ultra_oracle_browser_unlock "$hg"                        # correct nonce releases it
[ -e "$lf_g" ] && { echo "FAIL (g) owner unlock did not release"; FAIL=1; }

# (h) degraded (empty) handle -> unlock is a harmless no-op
_ultra_oracle_browser_unlock ""
_ultra_oracle_browser_unlock "notahandle"   # no TAB -> ignored, must not error

if [ "$FAIL" -eq 0 ]; then echo "PASS test-ultra-oracle-lock"; else echo "FAILURES in test-ultra-oracle-lock"; fi
exit "$FAIL"
