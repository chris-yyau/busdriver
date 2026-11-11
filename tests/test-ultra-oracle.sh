#!/bin/bash
# tests/test-ultra-oracle.sh
set -u
. "$(dirname "$0")/lib/git-env-isolation.sh" || exit 1
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAIL=0
tmp="$(mktemp -d)"; export HOME="$tmp"; mkdir -p "$tmp/.claude" "$tmp/bin"; cd "$tmp" || exit 1
trap 'rm -rf "$tmp"' EXIT INT TERM   # clean up temp dir even if killed mid-run
# shellcheck source=/dev/null
. "$DIR/tests/lib/uora-test-env.sh"
T="$tmp"; export HOME="$tmp"; uora_fake_home; uora_shims "$tmp/bin"
export PATH="$tmp/bin:$PATH"   # the wrapper rows run out of process: the shims stand in for the seams (§2)
# shellcheck source=/dev/null
source "$DIR/scripts/lib/ultra-oracle.sh"
uora_inproc

uora_scenario $UORA_HAPPY
st="$(ultra_oracle_consult --prompt hi --out "$tmp/v.md" --mode blocking)"
[ "$st" = "ok" ] || { echo "FAIL ok got '$st'"; FAIL=1; }
grep -q "QUALIFY-ONE" "$tmp/v.md" || { echo "FAIL verdict not captured"; FAIL=1; }

# exit 0 + a degenerate answer ("I") -> error (fail-closed verdict floor)
uora_scenario ctx nav home find upload attached send id poll '{"download":{"mutate":".text = \"I\""}}' get archive close exit0
st="$(ultra_oracle_consult --prompt hi --out "$tmp/vd.md" --mode blocking)"
[ "$st" = "error" ] || { echo "FAIL degen->error got '$st'"; FAIL=1; }
# ...and the floor must NOT reject an answer at exactly the default threshold (8 non-ws bytes).
uora_scenario ctx nav home find upload attached send id poll '{"download":{"mutate":".text = \"abcdefgh\""}}' get archive close exit0
st="$(ultra_oracle_consult --prompt hi --out "$tmp/vok.md" --mode blocking)"
[ "$st" = "ok" ] || { echo "FAIL floor false-rejects 8-byte verdict got '$st'"; FAIL=1; }

# a child that exits 0 with no answer downloaded -> error
uora_scenario ctx nav home find upload attached send id poll exit0
st="$(ultra_oracle_consult --prompt hi --out "$tmp/v_e.md" --mode blocking)"
[ "$st" = "error" ] || { echo "FAIL empty->error got '$st'"; FAIL=1; }

# operator skip file -> skipped:user (checked before availability)
uora_scenario $UORA_HAPPY
touch "$tmp/.claude/skip-ultra-oracle.local"
st="$(ultra_oracle_consult --prompt hi --out "$tmp/v_s.md" --mode blocking)"
[ "$st" = "skipped:user" ] || { echo "FAIL skip got '$st'"; FAIL=1; }
rm -f "$tmp/.claude/skip-ultra-oracle.local"

# unavailable -> skipped:unavailable: no claude seam, and PATH hides the shim and any real claude
OLDPATH="$PATH"; _ULTRA_ORACLE_CLAUDE_BIN=""; PATH="/usr/bin:/bin"
st="$(ultra_oracle_consult --prompt hi --out "$tmp/v2.md" --mode blocking)"
[ "$st" = "skipped:unavailable" ] || { echo "FAIL unavail got '$st'"; FAIL=1; }
PATH="$OLDPATH"; _ULTRA_ORACLE_CLAUDE_BIN="$T/bin/claude"

# timeout: the fake clock crosses the 120 s cap in seconds
_uora_now() { echo $(( $(date +%s) + $(cat "$HOME/.uora-fake/skew" 2>/dev/null || echo 0) )); }
uora_scenario ctx nav home find upload attached send id poll=PENDING '{"skew":100}' '{"hang":true}'
st="$(ultra_oracle_consult --prompt hi --out "$tmp/v3.md" --mode blocking --timeout-cap-seconds 120)"
[ "$st" = "timeout" ] || { echo "FAIL timeout got '$st'"; FAIL=1; }
rm -f "$HOME/.uora-fake/skew"; _uora_now() { date +%s; }

# a cap under the 120 s floor -> error (§6)
uora_scenario $UORA_HAPPY
st="$(ultra_oracle_consult --prompt hi --out "$tmp/v60.md" --mode blocking --timeout-cap-seconds 60)"
[ "$st" = "error" ] || { echo "FAIL cap-floor got '$st'"; FAIL=1; }

# non-zero exit -> error
uora_scenario ctx nav home '{"exit":7}'
st="$(ultra_oracle_consult --prompt hi --out "$tmp/v4.md" --mode blocking)"
[ "$st" = "error" ] || { echo "FAIL fail->error got '$st'"; FAIL=1; }

# malformed call: a value-flag missing its argument -> typed 'error', not a set -u crash
st="$(ultra_oracle_consult --prompt hi --out)"
[ "$st" = "error" ] || { echo "FAIL missing-value got '$st'"; FAIL=1; }
# no prompt source (neither --prompt nor --prompt-file) -> typed 'error'
st="$(ultra_oracle_consult --out "$tmp/np.md")"
[ "$st" = "error" ] || { echo "FAIL missing-prompt got '$st'"; FAIL=1; }

# --- scripts/ultra-oracle-run.sh wrapper (shell-agnostic entry) ---
mkdir -p "$tmp/repo" && git -C "$tmp/repo" init -q && { cd "$tmp/repo" || exit 1; }   # the trusted resolver needs a git cwd without the shim
# The wrapper exists so the council/etc. SKILL blocks can invoke the bash-only
# oracle lib from ANY caller shell (they are pasted into a zsh Bash tool on
# macOS). HOME=$tmp has no busdriver.json -> council surface disabled by default.
WRAP="$DIR/scripts/ultra-oracle-run.sh"
rm -f "$tmp/.claude/busdriver.json"
wp="$(mktemp)"; printf 'council question' > "$wp"

# bad args -> fail closed
out="$(bash "$WRAP" council 1 "" "")"
[[ "$out" == "FAILED [bad-args]" ]] || { echo "FAIL wrapper bad-args got '$out'"; FAIL=1; }

# surface disabled + not forced -> NOT_ATTEMPTED (caller omits the section)
out="$(bash "$WRAP" council 0 "$wp" "$tmp/wrap_na.md")"
[[ "$out" == "NOT_ATTEMPTED" ]] || { echo "FAIL wrapper NOT_ATTEMPTED got '$out'"; FAIL=1; }

# forced + ok stub -> VERDICT on line 1, verdict text after
uora_scenario $UORA_HAPPY
out="$(bash "$WRAP" council 1 "$wp" "$tmp/wrap_ok.md")"
first_line="${out%%$'\n'*}"
[[ "$first_line" == "VERDICT" ]] || { echo "FAIL wrapper VERDICT token got '$first_line'"; FAIL=1; }
printf '%s\n' "$out" | grep -q "QUALIFY-ONE" || { echo "FAIL wrapper verdict body missing"; FAIL=1; }

# forced + failing stub -> FAILED [<status>] token (drives the ORACLE_FAILED banner)
uora_scenario ctx nav home '{"exit":7}'
out="$(bash "$WRAP" council 1 "$wp" "$tmp/wrap_fail.md")"
first_line="${out%%$'\n'*}"
[[ "$first_line" == FAILED\ \[*\]* ]] ||   # an optional " — <hint>" suffix follows (ultra-oracle-run.sh _sfx)
   { echo "FAIL wrapper FAILED token got '$first_line'"; FAIL=1; }

# REGRESSION (the actual bug): invoked from a NON-bash caller shell it must still
# work — an in-shell `source ultra-oracle.sh` aborted under zsh, but `bash $WRAP`
# runs the wrapper under bash regardless. Skip cleanly if zsh is absent.
if command -v zsh >/dev/null 2>&1; then
  out="$(zsh -c 'bash "$1" council 0 "$2" "$3"' _ "$WRAP" "$wp" "$tmp/wrap_zsh.md" 2>&1)"
  [[ "$out" == "NOT_ATTEMPTED" ]] || { echo "FAIL wrapper under zsh caller got '$out'"; FAIL=1; }
elif [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
  # CI installs zsh (tests.yml, #821); absence there is a coverage regression, not a skip.
  echo "FAIL zsh not installed in CI — wrapper zsh-caller row would silently skip (#821)"; FAIL=1
fi
rm -f "$wp"

# --- scripts/ultra-oracle-consult-run.sh wrapper (blocking, raw-token passthrough) ---
# The BLOCKING sibling of ultra-oracle-run.sh: brainstorming + ultraoracle SKILL
# blocks call it instead of sourcing the bash-only lib in a zsh Bash tool (#296).
# It passes ultra_oracle_consult's raw token through (ok|skipped:*|timeout|error),
# with an optional --surface gate.
CWRAP="$DIR/scripts/ultra-oracle-consult-run.sh"
rm -f "$tmp/.claude/busdriver.json"
cwp="$(mktemp)"; printf 'design to critique' > "$cwp"

# no forwarded args (no --out) -> fail closed to `error`
out="$(bash "$CWRAP")"
[[ "$out" == "error" ]] || { echo "FAIL consult-run no-args got '$out'"; FAIL=1; }

# dangling --surface with no value -> fail closed to `error`
out="$(bash "$CWRAP" --surface)"
[[ "$out" == "error" ]] || { echo "FAIL consult-run dangling --surface got '$out'"; FAIL=1; }

# --surface followed by a flag (no real value) -> fail closed to `error`
# (must NOT consume `--mode` as the surface name and silently skip)
out="$(bash "$CWRAP" --surface --mode blocking --prompt-file "$cwp" --out "$tmp/cr_flagval.md")"
[[ "$out" == "error" ]] || { echo "FAIL consult-run --surface-eats-flag got '$out'"; FAIL=1; }

# --surface-check gate query (used by brainstorming to gate BEFORE writing the design)
out="$(bash "$CWRAP" --surface-check)"                       # no name -> error
[[ "$out" == "error" ]] || { echo "FAIL surface-check no-name got '$out'"; FAIL=1; }
out="$(bash "$CWRAP" --surface-check brainstorming)"         # config disabled -> disabled
[[ "$out" == "disabled" ]] || { echo "FAIL surface-check disabled got '$out'"; FAIL=1; }

# --surface brainstorming, config disabled (no busdriver.json) -> skipped:disabled
out="$(bash "$CWRAP" --surface brainstorming --mode blocking --prompt-file "$cwp" --out "$tmp/cr_dis.md")"
[[ "$out" == "skipped:disabled" ]] || { echo "FAIL consult-run disabled surface got '$out'"; FAIL=1; }

# enable the brainstorming surface via USER config for the remaining surface-gated cases
printf '{"ultraOracle":{"brainstorming":{"enabled":true}}}' > "$tmp/.claude/busdriver.json"

# --surface-check now reports enabled
out="$(bash "$CWRAP" --surface-check brainstorming)"
[[ "$out" == "enabled" ]] || { echo "FAIL surface-check enabled got '$out'"; FAIL=1; }

# --surface brainstorming, enabled + ok stub -> raw `ok` + verdict body at --out
uora_scenario $UORA_HAPPY
out="$(bash "$CWRAP" --surface brainstorming --mode blocking --prompt-file "$cwp" --out "$tmp/cr_ok.md")"
[[ "$out" == "ok" ]] || { echo "FAIL consult-run enabled ok got '$out'"; FAIL=1; }
grep -q "QUALIFY-ONE" "$tmp/cr_ok.md" || { echo "FAIL consult-run verdict not captured"; FAIL=1; }

# no --surface (ultraoracle shape) + ok stub -> `ok` even with no config gate
out="$(bash "$CWRAP" --mode blocking --prompt-file "$cwp" --out "$tmp/cr_noguard.md")"
[[ "$out" == "ok" ]] || { echo "FAIL consult-run no-surface ok got '$out'"; FAIL=1; }


# failing oracle -> raw `error` token (drives caller's ORACLE_FAILED / block-and-ask)
uora_scenario ctx nav home '{"exit":7}'
out="$(bash "$CWRAP" --mode blocking --prompt-file "$cwp" --out "$tmp/cr_fail.md")"
[[ "$out" == "error" ]] || { echo "FAIL consult-run fail stub got '$out'"; FAIL=1; }

# REGRESSION (#296): invoked from a NON-bash (zsh) caller it must still work — an
# in-shell `source ultra-oracle.sh` aborted under zsh, but `bash $CWRAP` runs under
# bash regardless. Surface is enabled + ok stub, so a working wrapper returns `ok`;
# the pre-fix in-shell source would have half-loaded and produced no verdict.
uora_scenario $UORA_HAPPY
if command -v zsh >/dev/null 2>&1; then
  out="$(zsh -c 'bash "$1" --surface brainstorming --mode blocking --prompt-file "$2" --out "$3"' \
        _ "$CWRAP" "$cwp" "$tmp/cr_zsh.md" 2>&1)"
  [[ "$out" == "ok" ]] || { echo "FAIL consult-run under zsh caller got '$out'"; FAIL=1; }
elif [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
  # CI installs zsh (tests.yml, #821); absence there is a coverage regression, not a skip.
  echo "FAIL zsh not installed in CI — consult-run zsh-caller row would silently skip (#821)"; FAIL=1
fi
rm -f "$cwp" "$tmp/.claude/busdriver.json"

[[ "$FAIL" = 0 ]] && echo "PASS test-ultra-oracle" || exit 1
