#!/bin/bash
# tests/test-ultra-oracle-background-nonblocking.sh
#
# Guard for #501: `ultra_oracle_consult --mode background` must RETURN BEFORE its
# child exits.
#
# The disowned subshell used to close with a bare `) &`, so it inherited the
# caller's stdout. Every caller captures this function in `$( )`
# (run-design-review-loop.sh, ultra-oracle-run.sh), and command substitution reads
# until ALL writers close the pipe — so the "background" dispatch actually blocked
# for the consult's entire lifetime (measured: 4-31 min of serialization before the
# blueprint reviewers even launched).
#
# WHY THIS TEST IS NEW despite ~21 existing `--mode background` call sites in
# tests/test-ultra-oracle*.sh: every one of those polls `.rc` with a bounded wait
# and measures elapsed time TO THE `.rc` LANDING. That is satisfied whether the
# dispatch blocked or not, so none of them can observe this defect. A regression
# that drops the redirect leaves them all green.
#
# Layer 1 is behavioral (the property itself); layer 2 is a golden-grep so the
# specific mechanism cannot be silently reshaped.

set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAIL=0
SLOW=6   # stub oracle's runtime; the dispatch must return in a small fraction of it

tmp="$(mktemp -d)"; export HOME="$tmp"; mkdir -p "$tmp/.claude" "$tmp/bin"; cd "$tmp" || exit 1
trap 'rm -rf "$tmp"' EXIT INT TERM

# Stub oracle: writes the verdict only AFTER sleeping, so "child still running"
# is observable as "verdict not yet on disk".
cat > "$tmp/bin/oracle" <<EOF
#!/bin/bash
out=""
while [ \$# -gt 0 ]; do case "\$1" in --write-output) out="\$2"; shift 2;; *) shift;; esac; done
sleep $SLOW
[ -n "\$out" ] && printf 'ADVISORY: slow but sound\n' > "\$out"
exit 0
EOF
chmod +x "$tmp/bin/oracle"; export PATH="$tmp/bin:$PATH"
export ULTRA_ORACLE_TEST_NO_LOCK=1   # no shared-browser mutex in unit context

# shellcheck source=/dev/null
source "$DIR/scripts/lib/ultra-oracle.sh"

# ── Layer 1: behavioral — the capture must return while the child still runs ──
t0=$(date +%s)
st="$(ultra_oracle_consult --mode background --prompt "review the plan" \
        --slug "ultra oracle plan review" --out "$tmp/nb.md")"
t1=$(date +%s)
elapsed=$(( t1 - t0 ))

[ "$st" = "dispatched" ] || { echo "FAIL: status got '$st', want 'dispatched'"; FAIL=1; }

# The whole point. Allow generous slack for a loaded CI box but stay well under
# the child's own runtime, so a blocking regression cannot slip through.
if [ "$elapsed" -ge $(( SLOW - 2 )) ]; then
  echo "FAIL: dispatch blocked ${elapsed}s against a ${SLOW}s child — \`\$( )\` held by the child's inherited stdout (#501)"
  FAIL=1
else
  echo "OK:   dispatch returned in ${elapsed}s while the ${SLOW}s child ran"
fi

# Corroborate that the child really was still working when we were handed control,
# rather than the stub having finished early.
if [ -f "$tmp/nb.md.rc" ]; then
  echo "FAIL: .rc already present at return — child finished, so the timing above proves nothing"
  FAIL=1
else
  echo "OK:   child still in flight at return (.rc absent)"
fi

# ...and that it does complete afterwards: non-blocking must not mean lost.
n=0
while [ ! -f "$tmp/nb.md.rc" ] && [ "$n" -lt 100 ]; do sleep 0.2; n=$((n + 1)); done
if [ "$(cat "$tmp/nb.md.rc" 2>/dev/null)" = "0" ]; then
  echo "OK:   child completed after the dispatch returned (.rc=0)"
else
  echo "FAIL: child never completed (.rc missing or non-zero)"; FAIL=1
fi
grep -q 'ADVISORY' "$tmp/nb.md" 2>/dev/null \
  || { echo "FAIL: verdict body not written"; FAIL=1; }

# ── Layer 1b: the child must not hold the CALLER's stderr either ──
# The `$( )` capture above only proves stdout was released. The enclosing Bash
# TOOL call captures stdout AND stderr, so a child that inherits stderr keeps that
# capture open after the loop exits — the same stall, one level up. Model it
# exactly: run a whole dispatching shell and capture both streams, then exit while
# the child is still working.
_both="$( bash -c '
  export ULTRA_ORACLE_TEST_NO_LOCK=1
  # shellcheck source=/dev/null
  source "'"$DIR"'/scripts/lib/ultra-oracle.sh"
  ultra_oracle_consult --mode background --prompt p --slug "ultra oracle plan review" \
    --out "'"$tmp"'/fd.md" >/dev/null
' 2>&1 )"
n=0; while [ ! -f "$tmp/fd.md.rc" ] && [ "$n" -lt 100 ]; do sleep 0.2; n=$((n + 1)); done

# The child's stderr must be PRESERVED on disk, not discarded: it is the only
# carrier of the stale-browser-lock recovery pointer, and "$out.err" is truncated
# by the watched/blocking paths for oracle's own output.
if [ -f "$tmp/fd.md.dispatch.err" ]; then
  echo "OK:   child stderr routed to \$out.dispatch.err (recovery pointer survives)"
else
  echo "FAIL: no \$out.dispatch.err — child stderr inherited or discarded"
  FAIL=1
fi
[ -z "$_both" ] || echo "note: outer capture carried: $_both"

# NOT asserted, deliberately: that the ENCLOSING tool capture (stdout+stderr of
# the whole invoking shell) is released. Measured with this same 6s stub, the hold
# is identical for stderr->file, stderr->/dev/null, and no redirect at all — so
# the holder is another descriptor on the attach/watched path, not the subshell's
# own std fds, and no redirect here can fix it. Asserting it would be a guard that
# fails for a reason the code under test cannot control. Residual in ADR 0030.

# ── Layer 1c: the child must be in its OWN process group ──
# `disown` only drops the job-table entry — the child otherwise keeps the parent's
# pgid, so a harness group SIGTERM kills it mid-consult and strands the shared
# browser mutex, which has NO auto-reclaim. `set -m` at the launch makes it a
# process-group leader.
_pg_out="$( bash -c '
  export ULTRA_ORACLE_TEST_NO_LOCK=1
  # shellcheck source=/dev/null
  source "'"$DIR"'/scripts/lib/ultra-oracle.sh"
  ppg=$(ps -o pgid= -p $$ | tr -d " ")
  st=$(ultra_oracle_consult --mode background --prompt p --slug "ultra oracle plan review" --out "'"$tmp"'/pg.md")
  cpid=""
  for _i in 1 2 3 4 5 6 7 8 9 10; do
    cpid=$(pgrep -f "^sleep '"$SLOW"'$" | head -1)
    [ -n "$cpid" ] && break
    sleep 0.1
  done
  cpg=$(ps -o pgid= -p "$cpid" 2>/dev/null | tr -d " ")
  printf "%s %s %s" "$st" "$ppg" "$cpg"
' 2>/dev/null )"
set -- $_pg_out
if [ "${1:-}" != "dispatched" ]; then
  echo "FAIL: status token corrupted to '${1:-}' — job-control notices leaked onto stdout"
  FAIL=1
elif [ -n "${3:-}" ] && [ "${2:-}" != "${3:-}" ]; then
  echo "OK:   child runs in its own process group (${2} vs ${3}) — group SIGTERM cannot strand the mutex"
else
  echo "FAIL: child shares the parent process group (${2:-?} vs ${3:-?}) — a group SIGTERM strands the browser lock"
  FAIL=1
fi

# ── Layer 2: golden-grep — the subshell redirect itself ──
ADAPTER="$DIR/scripts/lib/ultra-oracle.sh"
# The `)` closes on the same line as the final statement, so anchor on the
# redirect + `&` tail rather than the line start.
_PAT='\) </dev/null >/dev/null 2>>"\$out\.dispatch\.err" &[[:space:]]*$'
if grep -qE "$_PAT" "$ADAPTER"; then
  echo "OK:   background subshell closes with all three fds redirected"
else
  echo "FAIL: subshell no longer closes with \`) </dev/null >/dev/null 2>>\"\$out.err\" &\` (#501 regression)"
  FAIL=1
fi

# stderr must go to a FILE — never inherited (holds the tool capture open) and
# never /dev/null (loses the stale-lock recovery pointer).
if grep -qE '\) </dev/null >/dev/null &[[:space:]]*$' "$ADAPTER"; then
  echo "FAIL: stderr left inherited — a live child holds the enclosing tool capture open"
  FAIL=1
fi
if grep -qE '\) </dev/null >/dev/null 2>(&1|/dev/null) &' "$ADAPTER"; then
  echo "FAIL: stderr merged or discarded — the stale-lock 'rm -f' recovery pointer is lost"
  FAIL=1
fi

# Prove the guard can FAIL, not just pass: the same pattern against a copy with
# the redirect stripped must not match. A grep assertion that has never been seen
# to fail is not a guard.
_probe="$tmp/adapter-noredir.sh"
sed 's|) </dev/null >/dev/null 2>>"$out.dispatch.err" &|) \&|' "$ADAPTER" > "$_probe"
if grep -qE "$_PAT" "$_probe"; then
  echo "FAIL: golden-grep still matches after the redirect was stripped — it cannot detect a regression"
  FAIL=1
else
  echo "OK:   golden-grep rejects a stripped-redirect copy (guard fires)"
fi

[ "$FAIL" -eq 0 ] && echo "PASS: ultra-oracle background dispatch is non-blocking" || echo "FAILED"
exit "$FAIL"
