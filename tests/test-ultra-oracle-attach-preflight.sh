#!/usr/bin/env bash
# tests/test-ultra-oracle-attach-preflight.sh
# Command-mocked test harness for scripts/ultra-oracle-attach-preflight.sh — the
# ~210-line destructive Chrome-attach state machine (ADR 0020, issue #410).
#
# WHY: PR #409 shipped only adapter-level parsing stubs; they never touch the
# risky half — profile containment, PID/listener ownership, stale-file cleanup,
# process termination, launch recovery, and concurrent convergence (CodeRabbit
# r3608480522). Those paths run `find … -delete`, `kill -9`, and launch a browser,
# so "it parses" is worlds away from "it is safe". This harness drives the WHOLE
# script end-to-end against fully mocked externals, so each destructive branch is
# actually exercised, not just described.
#
# HOW IT MOCKS: every external the script consults is intercepted so no real
# process, port, or browser is touched:
#   - ps/lsof/curl/sleep      → PATH stubs reading a shared registry file ($REG)
#   - fake Chrome             → a stub the script launches via the _UORA_CHROME_BIN
#                               test seam; it "registers" a running browser
#   - kill / kill -9          → an EXPORTED shell function (kill is a builtin, so a
#                               PATH stub would be ignored) that removes a pid from
#                               the registry, so termination is observable
# The registry ($REG) is the single source of truth all mocks agree on: one line
# per live browser, "<pid>\t<port>\t<profile>". A process is "running" iff its line
# exists; a port "answers" iff some line owns it; killing deletes the line.
#
# Hermetic + portable: no real ps/lsof/curl/Chrome, HOME is a temp dir, sleep is a
# no-op. Runs identically on Linux CI and macOS.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/ultra-oracle-attach-preflight.sh"

passed=0; failed=0
fail() { echo "FAIL: $1"; failed=$((failed + 1)); }
ok()   { echo "OK:   $1"; passed=$((passed + 1)); }

[[ -f "$SCRIPT" ]] || { echo "Results: 0 passed, 1 failed (script missing at $SCRIPT)"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "Results: 0 passed, 1 failed (python3 required by the script under test)"; exit 1; }

# pwd -P: resolve to the PHYSICAL path. On macOS mktemp returns /var/… (a symlink
# to /private/var), but the script canonicalizes profiles with realpath, so a
# hand-seeded registry path must already be physical to match the script's $PROFILE.
# GUARD the creation: this suite does not use errexit, so an empty TMP would make
# HOME_DIR=/home and STUB=/bin and the setup redirects could clobber system files.
_mk="$(mktemp -d)" || { echo "Results: 0 passed, 1 failed (mktemp failed)"; exit 1; }
TMP="$(cd "$_mk" && pwd -P)" || { echo "Results: 0 passed, 1 failed (cannot resolve temp dir)"; exit 1; }
[[ -n "$TMP" && -d "$TMP" ]] || { echo "Results: 0 passed, 1 failed (temp dir unusable)"; exit 1; }
trap 'rm -rf "$TMP"' EXIT

# ── Mock environment ──────────────────────────────────────────────────────
# errexit for SETUP ONLY: a failed mkdir / heredoc redirect / chmod / export must
# abort before any test runs — a half-built harness could otherwise fall through to
# the REAL ps/lsof/curl/kill. Disabled again before the assertions (they rely on
# non-zero exits not aborting the script). Restored to the -uo pipefail baseline there.
set -e
HOME_DIR="$TMP/home"
APPSUP="$HOME_DIR/Library/Application Support"   # oracle's discovery root
mkdir -p "$APPSUP"
STUB="$TMP/bin"; mkdir -p "$STUB"

REG="$TMP/registry"          # live browsers: "<pid>\t<port>\t<profile>" per line
: > "$REG"
PIDCTR="$TMP/pidctr"; echo 1000 > "$PIDCTR"
PORTCTR="$TMP/portctr"; echo 40000 > "$PORTCTR"
LAUNCHCTR="$TMP/launchctr"; echo 0 > "$LAUNCHCTR"   # times fake Chrome was started
KILLLOG="$TMP/killlog"; : > "$KILLLOG"              # "<sig>\t<pid>" per kill() call

next() { local f="$1" n; n=$(cat "$f"); echo $((n + 1)) > "$f"; echo $((n + 1)); }
export -f next
export PIDCTR PORTCTR

# ps stub: emit "<pid> --user-data-dir=<profile> …" for every registered browser,
# mirroring the `ps -Awwo pid=,command=` the script parses (case match on a literal
# `--user-data-dir=$PROFILE ` substring with a trailing space).
cat > "$STUB/ps" <<'STUB'
#!/usr/bin/env bash
while IFS=$'\t' read -r pid port profile; do
  [[ -n "$pid" ]] || continue
  printf '%s --type=main --user-data-dir=%s --remote-debugging-port=0\n' "$pid" "$profile"
done < "$REG"
STUB

# lsof stub: `lsof -nP -iTCP:<port> -sTCP:LISTEN -t` → pids owning that port.
cat > "$STUB/lsof" <<'STUB'
#!/usr/bin/env bash
want=""
for a in "$@"; do case "$a" in -iTCP:*) want="${a#-iTCP:}";; esac; done
[[ -n "$want" ]] || exit 1
found=1
while IFS=$'\t' read -r pid port profile; do
  [[ "$port" = "$want" ]] && { printf '%s\n' "$pid"; found=0; }
done < "$REG"
exit "$found"
STUB

# curl stub: `curl -sf … http://127.0.0.1:<port>/json/version` → exit 0 iff some
# registered browser owns that port (mirrors `curl -sf` failing on no-connect).
cat > "$STUB/curl" <<'STUB'
#!/usr/bin/env bash
url=""
for a in "$@"; do case "$a" in http://*) url="$a";; esac; done
port="$(printf '%s' "$url" | sed -n 's|.*127\.0\.0\.1:\([0-9]*\)/.*|\1|p')"
[[ -n "$port" ]] || exit 22
while IFS=$'\t' read -r pid p profile; do
  [[ "$p" = "$port" ]] && exit 0
done < "$REG"
exit 22
STUB

# sleep stub: no-op so the probe/kill loops spin fast (the deadlines are wall-clock).
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB/sleep"

# fake Chrome: launched by the script through _UORA_CHROME_BIN. Registers a NEW
# browser unless one already owns this profile — that hand-off models Chrome's own
# SingletonLock, the exclusion the script deliberately relies on instead of a lock
# (concurrent-convergence path). Writes the DevToolsActivePort file Chrome would.
#
# _TEST_INJECT_WINNER: model the true race deterministically — a CONCURRENT caller's
# Chrome grabbed the SingletonLock first. When set, this launch first materializes
# that incumbent, then its own "already owned?" check finds it and hands off, adding
# no second owner. That is exactly the launch_chrome() convergence the script relies
# on, made observable without real thread interleaving.
cat > "$STUB/fake-chrome" <<'STUB'
#!/usr/bin/env bash
profile=""
for a in "$@"; do case "$a" in --user-data-dir=*) profile="${a#--user-data-dir=}";; esac; done
[[ -n "$profile" ]] || exit 0
next "$LAUNCHCTR" >/dev/null
owned() { awk -F'\t' -v p="$1" '$3==p{f=1} END{exit f?0:1}' "$REG"; }
if [[ -n "${_TEST_INJECT_WINNER:-}" ]] && ! owned "$profile"; then
  wpid="$(next "$PIDCTR")"; wport="$(next "$PORTCTR")"
  mkdir -p "$profile"
  printf '%s\n/devtools/browser/win\n' "$wport" > "$profile/DevToolsActivePort"
  printf '%s\t%s\t%s\n' "$wpid" "$wport" "$profile" >> "$REG"
fi
# Already owned? Hand off to the incumbent (Chrome SingletonLock) — add nothing.
owned "$profile" && exit 0
pid="$(next "$PIDCTR")"; port="$(next "$PORTCTR")"
mkdir -p "$profile"
printf '%s\n/devtools/browser/abc\n' "$port" > "$profile/DevToolsActivePort"
printf '%s\t%s\t%s\n' "$pid" "$port" "$profile" >> "$REG"
STUB

chmod +x "$STUB/ps" "$STUB/lsof" "$STUB/curl" "$STUB/sleep" "$STUB/fake-chrome"

# kill / kill -9 must mutate the registry so termination is observable. kill is a
# bash BUILTIN — a PATH stub would never be consulted — so override it with an
# exported function that the child `bash script.sh` imports. Signal-aware: it logs
# every call to $KILLLOG and, when _TEST_TERM_IGNORED is set, models a wedged Chrome
# that ignores TERM so only the -9 branch removes it (exercising kill_chrome's
# force-kill escalation, not just the happy TERM path).
kill() {
  local sig="TERM" a
  for a in "$@"; do
    case "$a" in
      -9|-KILL|-SIGKILL) sig="KILL" ;;
      -*) : ;;   # other signal flags: treat as a non-force signal
      *)
        printf '%s\t%s\n' "$sig" "$a" >> "$KILLLOG"
        if [[ "$sig" = "KILL" || -z "${_TEST_TERM_IGNORED:-}" ]]; then
          grep -v "^${a}$(printf '\t')" "$REG" > "$REG.tmp" 2>/dev/null || :
          mv "$REG.tmp" "$REG"
        fi
        ;;
    esac
  done
  return 0
}
export -f kill
export REG LAUNCHCTR KILLLOG

# Refuse to run if the kill override does not reach the child shell. Without it the
# script's kill_chrome would signal our mock PID NUMBERS against REAL processes — a
# CI runner may actually own pid 8888/7777. Fail closed rather than risk that.
_killtype="$(PATH="$STUB:$PATH" bash -c 'type -t kill' 2>/dev/null || true)"
[[ "$_killtype" = "function" ]] || {
  echo "Results: 0 passed, 1 failed (kill override not imported by child bash — refusing to risk real kills)"; exit 1; }

# Seed a running browser directly (bypassing launch) for the "already healthy" cases.
seed() { # profile
  local pid port; pid="$(next "$PIDCTR")"; port="$(next "$PORTCTR")"
  mkdir -p "$1"
  printf '%s\n/devtools/browser/abc\n' "$port" > "$1/DevToolsActivePort"
  printf '%s\t%s\t%s\n' "$pid" "$port" "$1" >> "$REG"
  echo "$port"
}

reset_state() { : > "$REG"; echo 0 > "$LAUNCHCTR"; : > "$KILLLOG"; }

# Run the script under the full mock env. Captures stdout, stderr, exit into globals.
run() { # profile-arg…
  RUN_OUT="$(PATH="$STUB:$PATH" HOME="$HOME_DIR" \
    _UORA_CHROME_BIN="$STUB/fake-chrome" \
    REG="$REG" LAUNCHCTR="$LAUNCHCTR" PIDCTR="$PIDCTR" PORTCTR="$PORTCTR" \
    bash "$SCRIPT" "$@" 2>"$TMP/err")"
  RUN_RC=$?
  RUN_ERR="$(cat "$TMP/err")"
}
# Number of times the fake Chrome was launched this run. Read into a local before a
# test so the command substitution's exit status is never masked (shellcheck SC2312).
launches() { cat "$LAUNCHCTR"; }

set +e   # end of setup — assertions below must survive their own non-zero exits

# ── 1. Profile containment (destructive-before-safe guard) ────────────────
reset_state
run "$TMP/outside-appsupport/evil"
if [[ "$RUN_RC" -ne 0 && "$RUN_ERR" == *"outside"* ]]; then
  ok "containment: profile outside Application Support is rejected"
else
  fail "containment: outside profile not rejected (rc=$RUN_RC err=$RUN_ERR)"
fi
n="$(launches)"
if [[ "$n" = "0" ]]; then ok "containment: no Chrome launched for rejected profile"
else fail "containment: launched Chrome despite rejecting profile"; fi

reset_state
# Traversal that lexically sits under the root but resolves outside it.
run "$APPSUP/../../../etc/oracle-evil"
if [[ "$RUN_RC" -ne 0 && "$RUN_ERR" == *"outside"* ]]; then
  ok "containment: '..' traversal out of the root is rejected"
else
  fail "containment: traversal not rejected (rc=$RUN_RC err=$RUN_ERR)"
fi

# ── 2. Healthy fast path + listener ownership ─────────────────────────────
reset_state
P1="$APPSUP/prof-healthy"
PORT1="$(seed "$P1")"
run "$P1"
if [[ "$RUN_RC" -eq 0 && "$RUN_OUT" = "ok 127.0.0.1:$PORT1" ]]; then
  ok "healthy: live+owned browser returns fast without relaunch"
else
  fail "healthy: expected 'ok 127.0.0.1:$PORT1', got rc=$RUN_RC out='$RUN_OUT'"
fi
n="$(launches)"
if [[ "$n" = "0" ]]; then ok "healthy: fast path launches nothing"
else fail "healthy: fast path relaunched Chrome ($n)"; fi

# Wrong-owner: the port file names a port owned by a DIFFERENT browser (not on this
# profile). Fast path MUST reject it and heal, or the consult attaches to a stranger.
reset_state
P2="$APPSUP/prof-wrongowner"
mkdir -p "$P2"
# stale file claims port 40000; that port is owned by an UNRELATED profile's browser.
printf '40000\n/devtools/browser/x\n' > "$P2/DevToolsActivePort"
printf '%s\t%s\t%s\n' 5555 40000 "$APPSUP/some-other-profile" >> "$REG"
run "$P2"
if [[ "$RUN_RC" -eq 0 && "$RUN_OUT" = ok\ 127.0.0.1:* && "$RUN_OUT" != "ok 127.0.0.1:40000" ]]; then
  ok "ownership: port owned by another browser is not trusted; heals to own port"
else
  fail "ownership: wrong-owner port trusted or heal failed (rc=$RUN_RC out='$RUN_OUT')"
fi
n="$(launches)"
if [[ "$n" -ge 1 ]]; then ok "ownership: wrong-owner triggers a clean relaunch"
else fail "ownership: wrong-owner did not relaunch"; fi
# The unrelated browser owning the foreign port MUST be left alone — healing this
# profile must never terminate a stranger's Chrome.
if grep -q "^5555$(printf '\t')" "$REG"; then
  ok "ownership: the unrelated foreign-port browser (pid 5555) is left untouched"
else
  fail "ownership: preflight terminated the unrelated browser owning the foreign port"
fi

# ── 3. Stale-file cleanup + launch recovery ───────────────────────────────
reset_state
P3="$APPSUP/prof-stale"
mkdir -p "$P3/Default"
printf '39999\n' > "$P3/DevToolsActivePort"          # root stale port, nobody listens
printf '38888\n' > "$P3/Default/DevToolsActivePort"  # copied nested one — must be purged
run "$P3"
if [[ "$RUN_RC" -eq 0 && "$RUN_OUT" = ok\ 127.0.0.1:* ]]; then
  ok "stale: dead port file → relaunch yields a fresh usable endpoint"
else
  fail "stale: recovery failed (rc=$RUN_RC out='$RUN_OUT' err=$RUN_ERR)"
fi
if [[ ! -f "$P3/Default/DevToolsActivePort" ]]; then
  ok "stale: nested Default/DevToolsActivePort copy is deleted"
else
  fail "stale: nested stale port file survived cleanup"
fi

# ── 4. Process termination (a running-but-unhealthy browser is killed) ────
reset_state
P4="$APPSUP/prof-term"
mkdir -p "$P4"
# A browser is "running" on the profile but its port file names a DEAD port (nobody
# answers). Fast path fails → chrome_running is true → kill_chrome must terminate the
# stale pid before a clean relaunch.
DEADPID=7777
printf '%s\t%s\t%s\n' "$DEADPID" 40001 "$P4" >> "$REG"   # "running" on profile…
printf '39990\n' > "$P4/DevToolsActivePort"              # …but recorded port is dead
run "$P4"
if [[ "$RUN_RC" -eq 0 && "$RUN_OUT" = ok\ 127.0.0.1:* ]]; then
  ok "termination: unhealthy running browser is healed to a working endpoint"
else
  fail "termination: heal failed (rc=$RUN_RC out='$RUN_OUT' err=$RUN_ERR)"
fi
if grep -q "^${DEADPID}$(printf '\t')" "$REG"; then
  fail "termination: stale pid $DEADPID was never killed (still in registry)"
else
  ok "termination: stale browser pid $DEADPID was terminated before relaunch"
fi

# ── 5. Launch recovery from cold (nothing running, no port file) ──────────
reset_state
P5="$APPSUP/prof-cold"
run "$P5"
if [[ "$RUN_RC" -eq 0 && "$RUN_OUT" = ok\ 127.0.0.1:* ]]; then
  ok "cold: empty state launches a browser and returns its endpoint"
else
  fail "cold: cold launch failed (rc=$RUN_RC out='$RUN_OUT' err=$RUN_ERR)"
fi
n="$(launches)"
if [[ "$n" = "1" ]]; then ok "cold: exactly one launch on a cold start"
else fail "cold: expected 1 launch, got $n"; fi

# ── 6. Concurrent convergence (SingletonLock hand-off) ────────────────────
# The documented race: this preflight reaches launch_chrome cold, but a CONCURRENT
# caller's Chrome grabbed the SingletonLock first. Our launch must hand off to that
# incumbent (not spawn a second owner) and our probe loop must read back and return
# the incumbent's port. _TEST_INJECT_WINNER makes that hand-off deterministic.
reset_state
P6="$APPSUP/prof-concurrent"
RUN_OUT="$(PATH="$STUB:$PATH" HOME="$HOME_DIR" \
  _UORA_CHROME_BIN="$STUB/fake-chrome" _TEST_INJECT_WINNER=1 \
  REG="$REG" LAUNCHCTR="$LAUNCHCTR" PIDCTR="$PIDCTR" PORTCTR="$PORTCTR" \
  bash "$SCRIPT" "$P6" 2>"$TMP/err")"; RUN_RC=$?; RUN_ERR="$(cat "$TMP/err")"
owners="$(awk -F'\t' -v p="$P6" '$3==p{c++} END{print c+0}' "$REG")"
winport="$(awk -F'\t' -v p="$P6" '$3==p{print $2; exit}' "$REG")"
if [[ "$RUN_RC" -eq 0 && "$RUN_OUT" = "ok 127.0.0.1:$winport" ]]; then
  ok "convergence: launch hands off and returns the concurrent winner's endpoint"
else
  fail "convergence: did not converge on winner (rc=$RUN_RC out='$RUN_OUT' err=$RUN_ERR)"
fi
if [[ "$owners" = "1" ]]; then
  ok "convergence: profile is owned by exactly one browser (no double-owner)"
else
  fail "convergence: profile has $owners owners (expected 1)"
fi

# ── 7. Force-kill escalation (a browser that IGNORES TERM is killed with -9) ─
# kill_chrome sends TERM, waits, then escalates to KILL. Model a wedged Chrome that
# ignores TERM (_TEST_TERM_IGNORED) so only the -9 branch can remove it — proving the
# force-kill escalation actually fires, not just the happy TERM path.
reset_state
P7k="$APPSUP/prof-wedged"
mkdir -p "$P7k"
WEDGED=8888
printf '%s\t%s\t%s\n' "$WEDGED" 40050 "$P7k" >> "$REG"   # "running" on profile…
printf '39980\n' > "$P7k/DevToolsActivePort"             # …recorded port is dead → heal
RUN_OUT="$(PATH="$STUB:$PATH" HOME="$HOME_DIR" \
  _UORA_CHROME_BIN="$STUB/fake-chrome" _TEST_TERM_IGNORED=1 \
  REG="$REG" LAUNCHCTR="$LAUNCHCTR" KILLLOG="$KILLLOG" PIDCTR="$PIDCTR" PORTCTR="$PORTCTR" \
  bash "$SCRIPT" "$P7k" 2>"$TMP/err")"; RUN_RC=$?; RUN_ERR="$(cat "$TMP/err")"
if [[ "$RUN_RC" -eq 0 && "$RUN_OUT" = ok\ 127.0.0.1:* ]]; then
  ok "force-kill: a TERM-ignoring browser is escalated to kill -9 and healed"
else
  fail "force-kill: heal failed (rc=$RUN_RC out='$RUN_OUT' err=$RUN_ERR)"
fi
if grep -q "^KILL$(printf '\t')${WEDGED}$" "$KILLLOG"; then
  ok "force-kill: kill -9 escalation fired for the wedged pid"
else
  klog="$(cat "$KILLLOG")"
  fail "force-kill: escalation to kill -9 never happened (killlog: $klog)"
fi
# Graceful-first: TERM must be attempted BEFORE the KILL. A regression that jumps
# straight to SIGKILL (destroying browser state) would still log a KILL, so assert
# the FIRST signal was TERM.
first="$(head -1 "$KILLLOG")"
if [[ "$first" = "TERM$(printf '\t')${WEDGED}" ]]; then
  ok "force-kill: TERM was attempted before KILL (graceful-first, not an instant SIGKILL)"
else
  fail "force-kill: expected a TERM attempt before KILL, first killlog entry='$first'"
fi

# ── 8. Seam contract: an unusable _UORA_CHROME_BIN must be rejected by chrome_bin ─
# Tested at the FUNCTION level, not by running the whole script: chrome_bin only PRINTS
# a path (it never launches), so even if the seam regressed and fell through to the real
# /Applications search, no browser is ever spawned by this case — it just returns that
# path and the assertion fails. Extract the function verbatim and exercise its contract.
chrome_bin_src="$(sed -n '/^chrome_bin()/,/^}/p' "$SCRIPT")"
eval "$chrome_bin_src"
# rejected: chrome_bin refuses this override (non-zero AND prints nothing). Status is
# captured into a variable (not tested in an `if`) to keep the check errexit-neutral.
rejected() { local out rc; out="$(_UORA_CHROME_BIN="$1" chrome_bin 2>/dev/null)"; rc=$?; [[ "$rc" -ne 0 && -z "$out" ]]; }
notexec="$TMP/not-executable-chrome"; : > "$notexec"; chmod 0644 "$notexec"
rejected "$notexec"; r=$?
if [[ "$r" -eq 0 ]]; then ok "seam: set-but-non-executable override is rejected"
else fail "seam: non-executable override was not rejected"; fi
rejected "$TMP"; r=$?
if [[ "$r" -eq 0 ]]; then ok "seam: a directory override is rejected (not just -x)"
else fail "seam: directory override was accepted"; fi
rejected ""; r=$?
if [[ "$r" -eq 0 ]]; then ok "seam: an empty override (set but blank) is rejected"
else fail "seam: empty override fell through"; fi
# And a usable override IS honored — chrome_bin returns exactly it.
got="$(_UORA_CHROME_BIN="$STUB/fake-chrome" chrome_bin)"
if [[ "$got" = "$STUB/fake-chrome" ]]; then ok "seam: a valid executable override is returned verbatim"
else fail "seam: valid override not returned (got '$got')"; fi

echo "Results: $passed passed, $failed failed"
[[ "$failed" -eq 0 ]]
