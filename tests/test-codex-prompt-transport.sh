#!/usr/bin/env bash
# tests/test-codex-prompt-transport.sh — #928: _execute_codex delivers a review
# prompt of ANY size to the reviewer byte-for-byte, on both arms, or fails closed
# before any reviewer starts.
#
# The bug: the prompt went to ONE `/usr/bin/printf` argument, and Linux caps one
# argv string at MAX_ARG_STRLEN (131072 B). The companion arm then failed with
# "failed to write codex prompt"; the direct arm piped that dead printf into
# `codex exec -`, so codex reviewed an EMPTY prompt. The fix stages the prompt to
# a file through _bd_emit_chunked for both arms (companion: --prompt-file;
# direct: fd 0 from the file), so a failed write is caught before dispatch.
#
# Cases (both arms unless noted; the companion arm SKIPs without a trusted node):
#   1 200,000 B ASCII            4 format-hostile + trailing "\n\n" (>128 KiB)
#   2 1,000 B ASCII              5 real partial write (ulimit -f) fails closed
#   3 multibyte across the 30000-character chunk boundary, C.UTF-8 and C
#   6 direct arm: a retried attempt re-reads the whole file
#   7 a caller's `set -C` does not refuse the staged file
#
# Prompts are written by THIS shell to a file that is also the oracle (`cmp`), and
# only the file's path crosses into the env -i child — a 200 KB string cannot
# ride in the `bash -c` text, and `$(cat f)` would strip trailing newlines.
# Every run points TMPDIR at a private dir AFTER pre-staging the review lib, so
# the stub can see the prompt file exist while it runs and the test can see it
# gone afterwards (the GNU fallback names it tmp.*, so no name glob is used).
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

W="$(mktemp -d)"
W="$(cd "$W" && pwd -P)"
trap 'rm -rf "$W"' EXIT
mkdir -p "$W/bin" "$W/cc" "$W/ptmp" "$W/p"

# Stub reviewers. Paths are baked in: the --review launch runs them under an env
# allowlist, so they cannot be steered by environment variables.
cat > "$W/bin/codex" <<EOF
#!/bin/sh
n=\$((\$(cat "$W/calls" 2>/dev/null | wc -l) + 1))
echo x >> "$W/calls"
cat > "$W/cap.\$n"
ls -A "$W/ptmp" | wc -l | tr -d ' ' > "$W/seen.\$n"
[ -f "$W/flake-first" ] && [ "\$n" -eq 1 ] && exit 0
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

# run <arm> <prompt-file> <LC_ALL> <pre-snippet> [VAR=val ...]
# Leaves stdout/stderr in $W/out / $W/err and the exit status in $RC.
run() {
  local arm="$1" pf="$2" loc="$3" pre="$4"; shift 4
  rm -f "$W"/calls "$W"/cap.* "$W"/seen.* "$W"/flake-first
  find "$W/ptmp" -mindepth 1 -delete
  RC=0
  env -i HOME="$HOME" PATH="$W/bin:$PATH" LC_ALL="$loc" PF="$pf" PTMP="$W/ptmp" "$@" \
    bash -c 'cd "$1" && source "$2" >/dev/null 2>&1 && source "$3" || exit 99
      _bd803_ensure_staged_lib || exit 98
      export TMPDIR="$PTMP"
      '"$pre"'
      p=$(cat "$PF"; printf x); p=${p%x}
      _execute_codex "$p" 60' _ "$ROOT" "$LIB" "$W/pin-$arm.sh" >"$W/out" 2>"$W/err" || RC=$?
}
calls() { if [[ -f "$W/calls" ]]; then grep -c . "$W/calls"; else echo 0; fi; }

# Assert one clean review that received exactly the bytes of <prompt-file>.
delivered() {
  local label="$1" pf="$2"
  if [[ "$RC" -eq 0 && "$(calls)" -eq 1 ]] && cmp -s "$pf" "$W/cap.1"; then
    ok "$label: reviewer got all $(wc -c < "$pf" | tr -d ' ') bytes, once"
  else
    bad "$label: rc=$RC calls=$(calls) captured=$(wc -c < "$W/cap.1" 2>/dev/null || echo none) want=$(wc -c < "$pf")"
    sed 's/^/        /' "$W/err" | tail -5
  fi
  # Positive control for the cleanup assertions: the staged file WAS in the
  # private TMPDIR while the reviewer ran, and is gone now.
  [[ "$(cat "$W/seen.1" 2>/dev/null)" == 1 ]] && ok "$label: staged prompt file present during review" \
    || bad "$label: private TMPDIR held $(cat "$W/seen.1" 2>/dev/null || echo '?') entries during review, want 1"
  [[ -z "$(ls -A "$W/ptmp")" ]] && ok "$label: staged prompt file removed" || bad "$label: left behind: $(ls -A "$W/ptmp")"
}

head -c 200000 /dev/zero | tr '\0' a > "$W/p/big"
head -c 1000 /dev/zero | tr '\0' b > "$W/p/small"
{ head -c 29999 /dev/zero | tr '\0' c; for _ in $(seq 1 15000); do builtin printf '%s' 'é漢😀'; done; } > "$W/p/multi"
{ builtin printf '%s' '-n -- %s %d %% \n \\ \x41 '; head -c 140000 /dev/zero | tr '\0' '%'; builtin printf '\\%s\n\n' x; } > "$W/p/hostile"

for arm in "${ARMS[@]}"; do
  echo "── $arm arm"
  run "$arm" "$W/p/big" C ''
  delivered "$arm (1) 200,000 B" "$W/p/big"
  run "$arm" "$W/p/small" C ''
  delivered "$arm (2) 1,000 B" "$W/p/small"
  run "$arm" "$W/p/multi" "$UTF8" ''
  delivered "$arm (3) multibyte at the chunk boundary, $UTF8" "$W/p/multi"
  run "$arm" "$W/p/multi" C ''
  delivered "$arm (3) multibyte at the chunk boundary, C" "$W/p/multi"
  run "$arm" "$W/p/hostile" C ''
  delivered "$arm (4) format-hostile, trailing newlines" "$W/p/hostile"
  run "$arm" "$W/p/big" C 'set -C'
  delivered "$arm (7) under set -C" "$W/p/big"

  # (5) 64 KiB file-size limit: the third 30000-character chunk is cut short and its
  # writer killed by SIGXFSZ — a real partial file. Nothing may reach a reviewer.
  run "$arm" "$W/p/big" C 'ulimit -c 0; ulimit -f 64'
  if [[ "$RC" -ne 0 && "$(calls)" -eq 0 ]]; then ok "$arm (5) partial write: refused, no reviewer started (rc=$RC)"; else bad "$arm (5) partial write: rc=$RC calls=$(calls)"; fi
  if grep -qE 'PASS|BUILTIN_FALLBACK' "$W/out"; then bad "$arm (5) partial write produced a verdict: $(head -c 200 "$W/out")"; else ok "$arm (5) no verdict on stdout"; fi
  grep -q 'failed to write codex prompt' "$W/err" && ok "$arm (5) error names the failed write" || bad "$arm (5) stderr: $(tail -3 "$W/err")"
  [[ -z "$(ls -A "$W/ptmp")" ]] && ok "$arm (5) partial prompt file removed" || bad "$arm (5) left behind: $(ls -A "$W/ptmp")"
done

# (6) A clean-but-empty first attempt is a flake and is retried; the retry must read
# the whole prompt again, not whatever was left of a consumed stream.
echo "── direct arm, retry"
run direct "$W/p/big" C 'touch "$PTMP/../flake-first"' LITMUS_CODEX_RETRY_DELAY=0
if [[ "$RC" -eq 0 && "$(calls)" -eq 2 ]] && cmp -s "$W/p/big" "$W/cap.1" && cmp -s "$W/p/big" "$W/cap.2"; then
  ok "direct (6) both attempts received all 200,000 bytes"
else
  bad "direct (6) rc=$RC calls=$(calls) cap1=$(wc -c < "$W/cap.1" 2>/dev/null || echo none) cap2=$(wc -c < "$W/cap.2" 2>/dev/null || echo none)"
fi
[[ -z "$(ls -A "$W/ptmp")" ]] && ok "direct (6) staged prompt file removed" || bad "direct (6) left behind: $(ls -A "$W/ptmp")"

echo
echo "$PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
