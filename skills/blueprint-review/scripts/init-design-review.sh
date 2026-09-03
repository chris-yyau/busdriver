#!/bin/bash -p
# #803: same clean-child scrub as run-review-loop.sh -- privileged mode stops THIS
# shell from honouring BASH_ENV/ENV and importing BASH_FUNC_*, but leaves those
# entries in the environment for any unprivileged child to re-process.
# #803: last-resort -p re-exec, matching the run-* sibling. The shebang above covers
# direct execution, but a caller that runs this as `bash <script>` bypasses it, and the
# clean-env rebuild below only fires when a BASH_FUNC_* entry is present -- so a
# BASH_ENV-only poisoning would already have executed its startup code in THIS shell
# (DEBUG trap, readonly pins, function definitions) before the `unset` below runs.
# `exec` is itself shadowable, so this closes the ordinary case, not a hostile parent
# -- the same accepted residual the run-* siblings document.
if [[ "$-" != *p* ]]; then
    exec "${BASH:-/bin/bash}" -p "$0" "$@"
fi
# BD803-CLEAN-ENV-BEGIN
# #803: privileged mode protects THIS shell only. It makes bash ignore BASH_ENV/ENV
# and refuse BASH_FUNC_* imports, but it leaves every one of those entries sitting in
# the ENVIRONMENT, so any unprivileged descendant re-imports them -- including a
# plain `#!/bin/bash` helper reached through a sourced library, which no amount of
# care in THIS file would cover. Measured: BASH_ENV pointing at a file containing
# `exit 0` made a child exit 0 without running its body, and a forged
# BASH_FUNC_python3%% was imported by an unprivileged grandchild.
# BASH_FUNC_* entries cannot be removed with `unset` -- their names are not valid
# identifiers and the environ entry survives (measured) -- so strip them by rebuilding
# the environment once, here. SHELLOPTS/BASHOPTS are readonly and cannot be unset;
# -p already ignores them.
unset BASH_ENV ENV
# Enumerate NUL-delimited (`env -0`), never newline-delimited. `env` output is NOT one
# line per variable: a value holding an embedded newline followed by text shaped like
# `BASH_FUNC_x%%=...` renders as its own line, and the name parsed out of that PHANTOM
# names no real variable -- so `env -u` strips nothing, the carrier survives the exec,
# the child re-detects the same phantom, and the block re-execs forever. Measured: an
# unbounded exec loop, armed by one ordinary variable, by the very poisoned environment
# this block exists to strip. A NUL can appear in neither an environment name nor a
# value, so NUL-delimited entries are exact and that phantom cannot be constructed.
# The trailing sentinel is the exit-status channel `env -0` otherwise loses through the
# process substitution: `&&` emits it only when env succeeded, and it can only arrive
# LAST. A final entry that is not the sentinel therefore covers BOTH a failed
# enumeration AND a substitution that never opened (no /dev/fd, unwritable TMPDIR).
# Neither may be read as "nothing to strip" -- that skips the clean re-exec and hands
# every descendant the inherited entries -- so both refuse. The count bound stays as a
# backstop against a pathological environment; NUL parsing is already O(n).
_bd803_envclean=()
_bd803_last=
_bd803_count=0
# shellcheck disable=SC2312  # `env -0`'s status is deliberately not read here: the
# sentinel below IS the status channel, and splitting the substitution would
# reintroduce a capture that cannot carry NUL bytes.
while IFS= read -r -d '' _bd803_e; do
  _bd803_last=$_bd803_e
  _bd803_count=$((_bd803_count + 1))
  if [[ ${_bd803_count} -gt 4096 ]]; then
    printf '%s\n' "$0: environment listing too large — refusing to run unprivileged descendants (#803)" >&2
    exit 1
  fi
  case "$_bd803_e" in BASH_FUNC_*) _bd803_envclean+=(-u "${_bd803_e%%=*}") ;; esac
# `env -0` is GNU; BSD/older macOS `env` rejects it and exits non-zero having
# written nothing, which would refuse to start every hardened entry point on a
# platform this repo explicitly supports (bash 3.2 is the macOS default). perl is
# the fallback because it is already the portable stand-in `_portable_timeout`
# relies on, and %ENV is read straight from environ, so a BASH_FUNC_x%% key —
# not a valid shell identifier — is still visible to it. If BOTH are unavailable
# the sentinel never arrives and the entry point refuses, which is the correct
# direction: unknowable environment, no unprivileged descendants.
#
# The perl arm is itself environment-steerable, and it is reached with the hostile
# environment still in place: PERL5OPT/PERL5LIB load attacker code BEFORE the
# script runs, and a module that merely exits 0 produces an EMPTY enumeration that
# the outer `&&` still stamps with the sentinel — "nothing to strip", every
# BASH_FUNC_* inherited (measured: 0 bytes, rc 0). Closed twice over: `-T` makes
# perl ignore PERL5LIB/PERLLIB/PERL5OPT outright, the assignment prefixes blank
# them for belt and braces, and the count check after the loop refuses an
# enumeration that returned nothing at all — no real environment is empty, so a
# silent zero is a failure however it was produced.
done < <( { /usr/bin/env -0 2>/dev/null \
            || PERL5OPT='' PERL5LIB='' PERLLIB='' /usr/bin/perl -T -e 'print map { "$_=$ENV{$_}\0" } keys %ENV'; } \
          && /usr/bin/printf 'BD803-ENV-OK\0' )
# -lt 2, not -lt 1: the SENTINEL is itself one of the entries the loop counted, so
# an enumeration that returned nothing at all still arrives here with a count of 1.
# Any real environment carries at least PATH alongside it.
if [[ "$_bd803_last" != "BD803-ENV-OK" || "$_bd803_count" -lt 2 ]]; then
  printf '%s\n' "$0: cannot enumerate the environment — refusing to run unprivileged descendants (#803)" >&2
  exit 1
fi
if [[ ${#_bd803_envclean[@]} -gt 0 ]]; then
  # A FAILED exec must not fall through. Non-interactive bash normally exits when
  # exec cannot run the command, but that behaviour is switchable (`execfail`), and
  # relying on an implicit exit for a security boundary means relying on a shell
  # option to stay off. The realistic failure is E2BIG: every stripped name adds a
  # `-u NAME` argument to an environment that is already large, and past ARG_MAX
  # the exec fails — at which point falling through would run the whole script with
  # exactly the BASH_FUNC_* entries this block exists to remove.
  exec /usr/bin/env "${_bd803_envclean[@]}" "${BASH:-/bin/bash}" -p "$0" "$@"
  printf '%s\n' "$0: cannot re-exec with a rebuilt environment — refusing to run unprivileged descendants (#803)" >&2
  exit 1
fi
unset _bd803_envclean _bd803_e _bd803_last _bd803_count
# BD803-CLEAN-ENV-END
# Initialize design review state
# Usage: init-design-review.sh <design_file> [max_iterations]

set -euo pipefail

STATE_DIR="${BUSDRIVER_STATE_DIR:-.claude}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/validation.sh"
source "$SCRIPT_DIR/lib/state_management.sh"

# Parse arguments
if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <design_file> [max_iterations]" >&2
  echo "" >&2
  echo "Arguments:" >&2
  echo "  design_file      Path to the design document to review" >&2
  echo "  max_iterations   Maximum review iterations (default: 5)" >&2
  exit 1
fi

DESIGN_FILE="$1"
MAX_ITERATIONS="${2:-5}"

# Validate design file exists
log_info "Validating design file: $DESIGN_FILE"
if ! validate_file_exists "$DESIGN_FILE"; then
  log_error "Design file not found or not readable"
  exit 1
fi

if ! validate_file_not_empty "$DESIGN_FILE"; then
  log_error "Design file is empty"
  exit 1
fi

# Check for existing active review
# check_existing_review return codes: 0=stale (clean up), 1=active (block), 2=no review (skip)
EXISTING=0
check_existing_review || EXISTING=$?
if [[ $EXISTING -eq 2 ]]; then
  # No active review — nothing to clean up, proceed to init
  :
elif [[ $EXISTING -eq 0 ]]; then
  STALE_SLUG=$(cat "$STATE_DIR/current-design-review.local" 2>/dev/null)
  log_info "Cleaning up stale review: $STALE_SLUG (never completed an iteration)"
  cleanup_stale_review
elif [[ $EXISTING -eq 1 ]]; then
  ACTIVE_SLUG=$(cat "$STATE_DIR/current-design-review.local" 2>/dev/null)
  log_error "Active review loop already exists: $ACTIVE_SLUG"
  log_error "  State: docs/reviews/$ACTIVE_SLUG/state.md"
  log_error "  To force: rm $STATE_DIR/current-design-review.local"
  exit 1
fi

# ── Chronic coverage degradation advisory ───────────────────────────
# Reads the cross-review trend (.claude/blueprint-coverage-trend.local, JSONL).
# If the last BLUEPRINT_COVERAGE_MIN_STREAK (default 3) completed reviews were ALL
# degraded (fulfilled_lens_count < 3), surface a loud advisory. NON-blocking
# (state still initializes, exit 0). Informational only — no script gates on it.
# Auto-clears when a later run records FULL coverage, or via BLUEPRINT_ACK_DEGRADED=1.
_chronic_coverage_check() {
  case "${BLUEPRINT_COVERAGE_PROVENANCE:-1}" in 0|false|no|off) return 0 ;; esac
  local trend="$STATE_DIR/blueprint-coverage-trend.local"
  local advisory="$STATE_DIR/blueprint-coverage-degraded.local"
  local streak="${BLUEPRINT_COVERAGE_MIN_STREAK:-3}"
  case "$streak" in ''|*[!0-9]*) streak=3 ;; esac
  [[ -f "$trend" ]] || return 0

  if [[ "${BLUEPRINT_ACK_DEGRADED:-0}" == "1" ]]; then
    rm -f "$advisory"
    return 0
  fi

  # Most recent run FULL → auto-clear any standing advisory.
  local last_count
  last_count=$(tail -n 1 "$trend" | sed -n 's/.*"fulfilled_lens_count":\([0-9]*\).*/\1/p')
  if [[ "$last_count" == "3" ]]; then
    rm -f "$advisory"
    return 0
  fi

  local total
  total=$(grep -c . "$trend" 2>/dev/null || echo 0)
  [[ "$total" -ge "$streak" ]] || return 0

  local degraded=0 c
  while IFS= read -r c; do
    [[ -n "$c" && "$c" -lt 3 ]] && degraded=$((degraded + 1))
  done < <(tail -n "$streak" "$trend" | sed -n 's/.*"fulfilled_lens_count":\([0-9]*\).*/\1/p')

  if [[ "$degraded" -ge "$streak" ]]; then
    log_warning ""
    log_warning "⚠️  CHRONIC COVERAGE DEGRADATION: the last $streak design reviews ran with <3 reviewers."
    log_warning "    A degraded or fallen-back backend has been silently reducing review coverage."
    log_warning "    Fix your reviewer CLIs (check: which agy codex grok), or set BLUEPRINT_ACK_DEGRADED=1 to dismiss."
    log_warning ""
    printf 'chronic coverage degradation: last %s reviews <3 reviewers (init %s)\n' \
      "$streak" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$advisory"
  fi
}
_chronic_coverage_check

# Initialize state file
log_info "Initializing design review state"
STATE_FILE=$(init_state_file "$DESIGN_FILE" "$MAX_ITERATIONS")

log_info "Design review initialized"
log_info "  Design file: $DESIGN_FILE"
log_info "  Max iterations: $MAX_ITERATIONS"
log_info "  State file: $STATE_FILE"
log_info ""
log_info "Ready to start review. Run: /bin/bash -p scripts/run-design-review-loop.sh"
