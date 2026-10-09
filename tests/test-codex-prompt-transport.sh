#!/usr/bin/env bash
# tests/test-codex-prompt-transport.sh — #928/#931: _execute_codex delivers a review
# prompt of ANY size to the reviewer byte-for-byte, on both arms, or fails closed
# before any reviewer starts — and the direct arm never names its prompt.
#
# The bug (#928): the prompt went to ONE `/usr/bin/printf` argument, and Linux caps
# one argv string at MAX_ARG_STRLEN (131072 B). The companion arm then failed with
# "failed to write codex prompt"; the direct arm piped that dead printf into
# `codex exec -`, so codex reviewed an EMPTY prompt. Both arms now write through
# _bd_emit_chunked, so a failed write is caught before dispatch. The companion arm
# stages a named file for --prompt-file; the direct arm (#931) stages each attempt on
# an inode whose name is unlinked before anything is written, so an interrupted
# review leaves nothing behind under any caller.
#
# Cases (both arms unless noted; companion-arm cases SKIP without a trusted node):
#   1 200,000 B ASCII            4 format-hostile + trailing "\n\n" (>128 KiB)
#   2 1,000 B ASCII              5 real partial write (ulimit -f) fails closed
#   3 multibyte across the 30000-character chunk boundary, C.UTF-8 and C
#   6 direct: a retried attempt restages the whole prompt
#   7 a caller's `set -C` does not refuse the staged file
#   8 a runner-owned _BD_CODEX_PROMPT_FILE (companion: used; direct: left empty)
#   9 direct: TERM to the whole group mid-review leaves no prompt behind
#  10 direct: staging fails on a retry → rc 1, no retry, no fallback
#  11 direct: the group's open fails       12 direct: the unlink check fails
#  13 direct → companion between attempts  14 companion → direct between attempts
#  15 a companion call after a direct staging failure in the same shell
#  16 direct: empty output on every attempt still falls back (rc 3)
#  17 direct: per-attempt staging time is charged to the shared budget
# Layered on 1-8: the stub counts the private TMPDIR while it runs — 0 on the
# direct arm (1 in case 8: the empty owned file), 1 (its staged file) on the companion.
#
# Prompts are written by THIS shell to a file that is also the oracle (`cmp`), and
# only the file's path crosses into the env -i child — a 200 KB string cannot
# ride in the `bash -c` text, and `$(cat f)` would strip trailing newlines.
# Every run points TMPDIR at a private dir AFTER pre-staging the review lib, so
# the stub can count its entries while it runs and the test can see it empty
# afterwards (the GNU fallback names files tmp.*, so no name glob is used).
# Per-case stub behaviour is switched by marker files $W/m.* (cleared per run).
# SC2015: `cond && ok || bad` is safe, ok() always succeeds. SC2016: the child
# snippets are single-quoted on purpose (they expand inside the env -i child).
# shellcheck disable=SC2015,SC2016
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$ROOT/scripts/lib/resolve-cli.sh"
PASS=0
FAIL=0
ok() { echo "  PASS  $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL  $1"; FAIL=$((FAIL + 1)); }
skip() { echo "  SKIP  $1"; }

W="$(mktemp -d)"
W="$(cd "$W" && pwd -P)"
trap 'chmod 700 "$W/ptmp" 2>/dev/null; [ -f "$W/stubpid" ] && kill "$(cat "$W/stubpid")" 2>/dev/null; rm -rf "$W"' EXIT
mkdir -p "$W/bin" "$W/cc" "$W/ptmp" "$W/p"

# Stub reviewers. Paths are baked in: the --review launch runs them under an env
# allowlist, so they cannot be steered by environment variables.
cat > "$W/bin/codex" <<EOF
#!/bin/sh
n=\$((\$(cat "$W/calls" 2>/dev/null | wc -l) + 1))
echo x >> "$W/calls"
cat > "$W/cap.\$n"
ls -A "$W/ptmp" | wc -l | tr -d ' ' > "$W/seen.\$n"
ls -A "$W/ptmp" > "$W/names.\$n"
[ -f "$W/m.empty-all" ] && exit 0
if [ "\$n" -eq 1 ] && [ -f "$W/m.flake-first" ]; then
  [ -f "$W/m.unnode-first" ] && rm -f "$W/m.no-node"
  [ -f "$W/m.chmod-first" ] && chmod 000 "$W/ptmp"
  exit 0
fi
if [ -f "$W/m.sleep" ]; then echo \$\$ > "$W/stubpid"; exec sleep 30; fi
echo '{"status":"PASS","issues":[]}'
EOF
chmod +x "$W/bin/codex"
cat > "$W/cc/codex-companion.mjs" <<EOF
import fs from "node:fs";
const a = process.argv.slice(2);
const calls = fs.existsSync("$W/calls") ? fs.readFileSync("$W/calls", "utf8").split("\n").length : 1;
fs.appendFileSync("$W/calls", "x\n");
fs.copyFileSync(a[a.indexOf("--prompt-file") + 1], "$W/cap." + calls);
fs.writeFileSync("$W/seen." + calls, String(fs.readdirSync("$W/ptmp").length) + "\n");
fs.writeFileSync("$W/names." + calls, fs.readdirSync("$W/ptmp").join("\n") + "\n");
if (calls === 1 && fs.existsSync("$W/m.flake-first")) {
  if (fs.existsSync("$W/m.node-off-first")) fs.writeFileSync("$W/m.no-node", "");
  process.exit(0);
}
process.stdout.write('{"status":"PASS","issues":[]}');
EOF

# Arm pins: only --print-trusted-companion is shimmed (_bd803_bash_pt_lib delegates
# to it, so the --review re-check sees the same answer); everything else is real.
cat > "$W/pin-direct.sh" <<'PIN'
eval "_bd803_orig_staged_lib() $(declare -f _bd803_bash_staged_lib | tail -n +2)"
_bd803_bash_staged_lib() {
  if [ "${1-}" = "--print-trusted-companion" ]; then return 1; fi
  _bd803_orig_staged_lib "$@"
}
PIN
cat > "$W/pin-companion.sh" <<PIN
eval "_bd803_orig_staged_lib() \$(declare -f _bd803_bash_staged_lib | tail -n +2)"
_bd803_bash_staged_lib() {
  if [ "\${1-}" = "--print-trusted-companion" ]; then /usr/bin/printf '%s\n' "$W/cc/codex-companion.mjs"; return 0; fi
  _bd803_orig_staged_lib "\$@"
}
_bd_codex_broker() { /usr/bin/printf absent; }
PIN
# Arm switches (13-15): the per-attempt arm gate is `_bd803_cc_a && node`, and
# _bd803_cc_a is cached before the loop, so these keep the companion pin and toggle
# NODE instead — unresolvable while $W/m.no-node exists, read on every call.
cat > "$W/pin-switch.sh" <<'PIN'
eval "_orig_rtcb() $(declare -f _resolve_trusted_cli_bin | tail -n +2)"
_resolve_trusted_cli_bin() {
  if [ "${1-}" = node ] && [ -e "${PTMP%/*}/m.no-node" ]; then return 1; fi
  _orig_rtcb "$@"
}
PIN
cat "$W/pin-companion.sh" "$W/pin-switch.sh" > "$W/pin-companion-switch.sh"

# shellcheck source=/dev/null
source "$LIB" >/dev/null 2>&1
ARMS=(direct)
if _resolve_trusted_cli_bin node >/dev/null 2>&1; then
  ARMS+=(companion)
else
  echo "  NOTE  no trusted node — companion-arm cases skipped"
fi
UTF8=C.UTF-8
locale -a 2>/dev/null | grep -qiE '^c\.utf-?8$' || echo "  NOTE  no C.UTF-8 locale — case 3 runs byte-sliced only"
ROOTUSER=0
[[ "$(id -u)" -eq 0 ]] && ROOTUSER=1

reset() {
  rm -f "$W"/calls "$W"/cap.* "$W"/seen.* "$W"/names.* "$W"/m.* "$W"/stubpid
  chmod 700 "$W/ptmp"
  find "$W/ptmp" -mindepth 1 -delete
  RC=0
}
# The env -i child: source, pin the arm, pre-stage the review lib, then point TMPDIR
# at the private dir and run <pre-snippet> before the call under test.
CHILD='cd "$1" && source "$2" >/dev/null 2>&1 && source "$3" || exit 99
      _bd803_ensure_staged_lib || exit 98
      export TMPDIR="$PTMP"
      eval "$PRE"
      p=$(cat "$PF"; printf x); p=${p%x}
      _execute_codex "$p" 60'

# run <pin> <prompt-file> <LC_ALL> <pre-snippet> [VAR=val ...]
# Leaves stdout/stderr in $W/out / $W/err and the exit status in $RC.
run() {
  local pin="$1" pf="$2" loc="$3" pre="$4"; shift 4
  reset
  env -i HOME="$HOME" PATH="$W/bin:$PATH" LC_ALL="$loc" PF="$pf" PTMP="$W/ptmp" PRE="$pre" "$@" \
    bash -c "$CHILD" _ "$ROOT" "$LIB" "$W/pin-$pin.sh" >"$W/out" 2>"$W/err" || RC=$?
}
calls() { if [[ -f "$W/calls" ]]; then grep -c . "$W/calls"; else echo 0; fi; }
empty_tmp() { [[ -z "$(ls -A "$W/ptmp")" ]]; }
no_verdict() { ! grep -qE 'PASS|BUILTIN_FALLBACK' "$W/out"; }

# Assert one clean review that received exactly the bytes of <prompt-file>, saw
# <in-flight> entries in the private TMPDIR while it ran, and left <residue> after.
delivered() {
  local label="$1" pf="$2" want="$3" residue="${4-}"
  if [[ "$RC" -eq 0 && "$(calls)" -eq 1 ]] && cmp -s "$pf" "$W/cap.1"; then
    ok "$label: reviewer got all $(wc -c < "$pf" | tr -d ' ') bytes, once"
  else
    bad "$label: rc=$RC calls=$(calls) captured=$(wc -c < "$W/cap.1" 2>/dev/null || echo none) want=$(wc -c < "$pf")"
    sed 's/^/        /' "$W/err" | tail -5
  fi
  [[ "$(cat "$W/seen.1" 2>/dev/null)" == "$want" ]] && ok "$label: $want private TMPDIR entr(ies) during review" \
    || bad "$label: private TMPDIR held $(cat "$W/seen.1" 2>/dev/null || echo '?') entries during review, want $want"
  [[ "$(ls -A "$W/ptmp")" == "$residue" ]] && ok "$label: TMPDIR afterwards is '${residue}'" \
    || bad "$label: left behind: $(ls -A "$W/ptmp"), want '${residue}'"
}
# Assert a staging refusal: rc 1, <n> reviewer calls, no verdict, the canonical message.
refused() {
  local label="$1" n="$2"
  if [[ "$RC" -eq 1 && "$(calls)" -eq "$n" ]]; then ok "$label: rc 1, $n reviewer call(s)"; else bad "$label: rc=$RC calls=$(calls), want rc 1 and $n"; fi
  no_verdict && ok "$label: no verdict on stdout" || bad "$label: verdict on stdout: $(head -c 200 "$W/out")"
  grep -q 'failed to write codex prompt' "$W/err" && ok "$label: error names the failed write" || bad "$label: stderr: $(tail -3 "$W/err")"
}

head -c 200000 /dev/zero | tr '\0' a > "$W/p/big"
head -c 1000 /dev/zero | tr '\0' b > "$W/p/small"
{ head -c 29999 /dev/zero | tr '\0' c; for _ in $(seq 1 15000); do builtin printf '%s' 'é漢😀'; done; } > "$W/p/multi"
{ builtin printf '%s' '-n -- %s %d %% \n \\ \x41 '; head -c 140000 /dev/zero | tr '\0' '%'; builtin printf '\\%s\n\n' x; } > "$W/p/hostile"

for arm in "${ARMS[@]}"; do
  echo "── $arm arm"
  seen=0; [[ "$arm" == companion ]] && seen=1
  run "$arm" "$W/p/big" C ''
  delivered "$arm (1) 200,000 B" "$W/p/big" "$seen"
  run "$arm" "$W/p/small" C ''
  delivered "$arm (2) 1,000 B" "$W/p/small" "$seen"
  run "$arm" "$W/p/multi" "$UTF8" ''
  delivered "$arm (3) multibyte at the chunk boundary, $UTF8" "$W/p/multi" "$seen"
  run "$arm" "$W/p/multi" C ''
  delivered "$arm (3) multibyte at the chunk boundary, C" "$W/p/multi" "$seen"
  run "$arm" "$W/p/hostile" C ''
  delivered "$arm (4) format-hostile, trailing newlines" "$W/p/hostile" "$seen"
  run "$arm" "$W/p/big" C 'set -C'
  delivered "$arm (7) under set -C" "$W/p/big" "$seen"
  # (8) #930: a runner-owned _BD_CODEX_PROMPT_FILE. The companion stages into it (the
  # one file the stub sees is "owned", removed afterwards); the direct arm leaves it
  # alone — same inode, still 0 bytes — and the prompt still arrives whole.
  run "$arm" "$W/p/big" C '_BD_CODEX_PROMPT_FILE="$PTMP/owned"; : > "$_BD_CODEX_PROMPT_FILE"; ls -i "$_BD_CODEX_PROMPT_FILE" > "$PTMP/../m.ino"'
  [[ "$(cat "$W/names.1" 2>/dev/null)" == owned ]] && ok "$arm (8) the one entry during review was the supplied path" \
    || bad "$arm (8) TMPDIR during review: $(cat "$W/names.1" 2>/dev/null || echo '?'), want owned"
  if [[ "$arm" == companion ]]; then
    delivered "$arm (8) runner-owned prompt file" "$W/p/big" 1
  else
    delivered "$arm (8) runner-owned prompt file" "$W/p/big" 1 owned
    read -r ino_before _ < "$W/m.ino" || ino_before=x
    read -r ino_after _ < <(ls -i "$W/ptmp/owned" 2>/dev/null) || ino_after=y
    [[ "$ino_before" == "$ino_after" && "$(wc -c < "$W/ptmp/owned" | tr -d ' ')" -eq 0 ]] \
      && ok "$arm (8) owned file untouched: same inode, 0 bytes" || bad "$arm (8) owned file: inode $ino_before → $ino_after, $(wc -c < "$W/ptmp/owned" 2>/dev/null) bytes"
  fi

  # (5) 64 KiB file-size limit: the third 30000-character chunk is cut short and its
  # writer killed by SIGXFSZ — a real partial file. Nothing may reach a reviewer.
  run "$arm" "$W/p/big" C 'ulimit -c 0; ulimit -f 64'
  if [[ "$RC" -ne 0 && "$(calls)" -eq 0 ]]; then ok "$arm (5) partial write: refused, no reviewer started (rc=$RC)"; else bad "$arm (5) partial write: rc=$RC calls=$(calls)"; fi
  no_verdict && ok "$arm (5) no verdict on stdout" || bad "$arm (5) partial write produced a verdict: $(head -c 200 "$W/out")"
  grep -q 'failed to write codex prompt' "$W/err" && ok "$arm (5) error names the failed write" || bad "$arm (5) stderr: $(tail -3 "$W/err")"
  empty_tmp && ok "$arm (5) partial prompt file removed" || bad "$arm (5) left behind: $(ls -A "$W/ptmp")"
done

echo "── direct arm only"
# (6) A clean-but-empty first attempt is a flake and is retried; the retry must get
# the whole prompt again, staged afresh, and neither attempt may see it named.
run direct "$W/p/big" C 'touch "$PTMP/../m.flake-first"' LITMUS_CODEX_RETRY_DELAY=0
if [[ "$RC" -eq 0 && "$(calls)" -eq 2 ]] && cmp -s "$W/p/big" "$W/cap.1" && cmp -s "$W/p/big" "$W/cap.2"; then
  ok "direct (6) both attempts received all 200,000 bytes"
else
  bad "direct (6) rc=$RC calls=$(calls) cap1=$(wc -c < "$W/cap.1" 2>/dev/null || echo none) cap2=$(wc -c < "$W/cap.2" 2>/dev/null || echo none)"
fi
[[ "$(cat "$W/seen.1" "$W/seen.2" 2>/dev/null | tr '\n' ' ')" == "0 0 " ]] && ok "direct (6) no named prompt during either attempt" \
  || bad "direct (6) TMPDIR entries during the attempts: $(cat "$W/seen.1" "$W/seen.2" 2>/dev/null | tr '\n' ' ')"
empty_tmp && ok "direct (6) nothing left behind" || bad "direct (6) left behind: $(ls -A "$W/ptmp")"

# (9) A non-litmus caller has no watchdog: TERM the whole group while the reviewer
# runs. The stub's line in $W/calls is the barrier — staging is complete before the
# reviewer starts — so the TERM cannot land between mktemp and the unlink.
if command -v setsid >/dev/null 2>&1; then
  reset; touch "$W/m.sleep"
  env -i HOME="$HOME" PATH="$W/bin:$PATH" LC_ALL=C PF="$W/p/big" PTMP="$W/ptmp" PRE='' \
    setsid bash -c "$CHILD" _ "$ROOT" "$LIB" "$W/pin-direct.sh" >"$W/out" 2>"$W/err" &
  pgid=$!
  for _ in $(seq 100); do [[ -s "$W/stubpid" ]] && break; sleep 0.1; done
  if [[ -s "$W/stubpid" ]]; then
    kill -TERM -- "-$pgid" 2>/dev/null || true
    wait "$pgid" 2>/dev/null || true
    kill "$(cat "$W/stubpid")" 2>/dev/null || true
    empty_tmp && ok "direct (9) TERM mid-review leaves no prompt behind" || bad "direct (9) left behind: $(ls -A "$W/ptmp")"
  else
    kill -KILL -- "-$pgid" 2>/dev/null || true; wait "$pgid" 2>/dev/null || true
    bad "direct (9) the reviewer never started: $(tail -3 "$W/err")"
  fi
else
  skip "direct (9) no setsid"
fi

# (10) The flake's first call makes the private TMPDIR unwritable, so the retry's
# mktemp fails: a staging failure is final — no second reviewer call, no fallback.
if [[ "$ROOTUSER" -eq 0 ]]; then
  run direct "$W/p/big" C 'touch "$PTMP/../m.flake-first" "$PTMP/../m.chmod-first"' LITMUS_CODEX_RETRY_DELAY=0
  chmod 700 "$W/ptmp"
  refused "direct (10) staging fails on a retry" 1
else
  skip "direct (10) uid 0: chmod 000 does not stop mktemp"
fi

# (11)/(12) _execute_codex calls /usr/bin/mktemp and /bin/rm by absolute path; bash
# outside POSIX mode takes slashed function names, so the child shims them directly.
# Each logs to $W and passes anything it does not handle on via `command`.
if [[ "$ROOTUSER" -eq 0 ]]; then
  # (11) mktemp hands back a mode-000 file: the check passes, the group's open fails.
  run direct "$W/p/big" C ': > "$PTMP/locked"; chmod 000 "$PTMP/locked"
    /usr/bin/mktemp() { echo x >> "$PTMP/../m.mk"
      if [ "${1-}" = -t ] && [ "${2-}" = codex-prompt ]; then /usr/bin/printf "%s\n" "$PTMP/locked"; else command /usr/bin/mktemp "$@"; fi; }'
  refused "direct (11) group open fails" 0
  [[ "$(grep -c . "$W/m.mk" 2>/dev/null)" == 1 ]] && ok "direct (11) staged exactly once: no retry" \
    || bad "direct (11) mktemp calls: $(grep -c . "$W/m.mk" 2>/dev/null || echo 0), want 1"
  empty_tmp && ok "direct (11) the unopenable file was removed" || bad "direct (11) left behind: $(ls -A "$W/ptmp")"
else
  skip "direct (11) uid 0: mode 000 does not refuse the open"
fi
# (12) The first rm aimed into the private TMPDIR — the in-group unlink — is a no-op
# that drops the sentinel $W/m.rm-sentinel, so the name survives; later calls log the
# target's size, then remove it for real.
run direct "$W/p/big" C '/bin/rm() { local t="${!#}"
    case "$t" in "$PTMP"/*)
      if [ ! -e "$PTMP/../m.rm-sentinel" ]; then : > "$PTMP/../m.rm-sentinel"; return 0; fi
      wc -c < "$t" | tr -d " " >> "$PTMP/../m.rm" ;; esac
    command /bin/rm "$@"; }'
refused "direct (12) unlink check fails" 0
[[ -e "$W/m.rm-sentinel" ]] && ok "direct (12) the shim intercepted the unlink" || bad "direct (12) the unlink was never intercepted"
[[ "$(cat "$W/m.rm" 2>/dev/null)" == 0 ]] && ok "direct (12) the surviving name was still empty: no write" \
  || bad "direct (12) sizes at removal: $(cat "$W/m.rm" 2>/dev/null || echo none), want 0"
empty_tmp && ok "direct (12) the surviving name was removed" || bad "direct (12) left behind: $(ls -A "$W/ptmp")"

# (16) A clean exit with empty output on every attempt is not a review: it still
# falls back (rc 3), never a blank rc 0 — the empty-output promotion stays in force.
run direct "$W/p/small" C 'touch "$PTMP/../m.empty-all"' LITMUS_CODEX_RETRIES=1 LITMUS_CODEX_RETRY_DELAY=0
if [[ "$RC" -eq 3 ]] && grep -q BUILTIN_FALLBACK "$W/out"; then ok "direct (16) empty output on every attempt falls back (rc 3)"; else bad "direct (16) rc=$RC out=$(head -c 200 "$W/out")"; fi

# (17) Per-attempt staging is charged to the shared budget, as the broker snapshot is:
# a 2s write leaves the reviewer at most 58s of a 60s budget, never the full 60.
run direct "$W/p/small" C 'M=${PTMP%/*}
  eval "_orig_ec() $(declare -f _bd_emit_chunked | tail -n +2)"; _bd_emit_chunked() { /bin/sleep 2; _orig_ec "$@"; }
  eval "_orig_pt() $(declare -f _portable_timeout | tail -n +2)"; _portable_timeout() { echo "$3" >> "$M/m.allow"; _orig_pt "$@"; }'
allow="$(tail -1 "$W/m.allow" 2>/dev/null || echo none)"
[[ "$RC" -eq 0 && "$allow" =~ ^[0-9]+$ && "$allow" -le 58 ]] && ok "direct (17) staging time is charged to the budget (allowance ${allow}s of 60s)" \
  || bad "direct (17) rc=$RC reviewer allowance=$allow, want <= 58"

echo "── arm switches"
if [[ " ${ARMS[*]} " != *" companion "* ]]; then
  skip "(13)-(15) no trusted node"
else
  # (13) Direct first (no node), then node appears: nothing was staged for the
  # companion, so attempt 2 refuses as a staging failure and never starts it.
  run companion-switch "$W/p/big" C 'touch "$PTMP/../m.no-node" "$PTMP/../m.flake-first" "$PTMP/../m.unnode-first"' LITMUS_CODEX_RETRY_DELAY=0
  refused "(13) direct → companion" 1
  grep -q 'arm switched mid-review' "$W/err" && ! grep -q 'unresolved after dual re-check' "$W/err" \
    && ok "(13) refused by the arm-switch guard" || bad "(13) stderr: $(tail -3 "$W/err")"
  empty_tmp && ok "(13) nothing left behind" || bad "(13) left behind: $(ls -A "$W/ptmp")"

  # (14) Companion first (its named file staged), then node vanishes: the direct
  # attempt removes that file before staging its own, so the reviewer sees none.
  run companion-switch "$W/p/big" C 'touch "$PTMP/../m.flake-first" "$PTMP/../m.node-off-first"' LITMUS_CODEX_RETRY_DELAY=0
  if [[ "$RC" -eq 0 && "$(calls)" -eq 2 ]] && grep -q '"PASS"' "$W/out" && cmp -s "$W/p/big" "$W/cap.2"; then
    ok "(14) companion → direct: the direct attempt got all 200,000 bytes"
  else
    bad "(14) rc=$RC calls=$(calls) cap2=$(wc -c < "$W/cap.2" 2>/dev/null || echo none) err: $(tail -2 "$W/err")"
  fi
  [[ "$(cat "$W/seen.1" "$W/seen.2" 2>/dev/null | tr '\n' ' ')" == "1 0 " ]] && ok "(14) companion file gone before the direct review" \
    || bad "(14) TMPDIR entries during the attempts: $(cat "$W/seen.1" "$W/seen.2" 2>/dev/null | tr '\n' ' '), want 1 0"
  empty_tmp && ok "(14) nothing left behind" || bad "(14) left behind: $(ls -A "$W/ptmp")"

  # (15) Same shell: a direct call whose staging fails, then a companion call. The
  # companion never stages per attempt, so only the entry-time reset keeps the first
  # call's flag from turning the second call's PASS into a write failure.
  if [[ "$ROOTUSER" -eq 0 ]]; then
    # ${PTMP%/*}, not $PTMP/..: the latter cannot be resolved while PTMP is mode 000.
    run companion-switch "$W/p/big" C 'M=${PTMP%/*}; touch "$M/m.no-node"; chmod 000 "$PTMP"
      p=$(cat "$PF"; printf x); p=${p%x}
      _execute_codex "$p" 60 > "$M/m.out1" 2> "$M/m.err1"; echo $? > "$M/m.rc1"
      chmod 700 "$PTMP"; rm -f "$M/m.no-node"'
    [[ "$(cat "$W/m.rc1" 2>/dev/null)" == 1 ]] && grep -q 'failed to write codex prompt' "$W/m.err1" \
      && ok "(15) first call: direct staging failure (rc 1)" || bad "(15) first call rc=$(cat "$W/m.rc1" 2>/dev/null) err: $(tail -2 "$W/m.err1" 2>/dev/null)"
    delivered "(15) second call: companion PASS" "$W/p/big" 1
    grep -q 'failed to write codex prompt' "$W/err" && bad "(15) second call reported a write failure" || ok "(15) second call reported no write failure"
  else
    skip "(15) uid 0: chmod 000 does not stop mktemp"
  fi
fi

echo
echo "$PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
