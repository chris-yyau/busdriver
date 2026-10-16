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
# Blank the dynamic-loader variables BEFORE anything below runs a binary. The
# `-u` list built further down only cleans the FINAL re-exec's child, but the
# enumerator (`env -0` / `perl`) and `printf` are themselves dynamically linked:
# on Linux a hostile LD_PRELOAD/LD_AUDIT executes inside THOSE processes first,
# and a preloaded enumerator can simply lie about the environment it reports.
# Assignment, not `unset`: `unset` is a shadowable builtin (see the note above),
# while assignment is grammar no exported function can intercept — and an EMPTY
# LD_PRELOAD/LD_AUDIT is inert to the loader, so blanking is as good as removing.
# Scope, stated honestly: this protects the binaries this block runs and every
# descendant. It CANNOT protect the interpreter already executing these lines --
# the loader acted before bash ran its first instruction, which no in-script step
# can undo. DYLD_* is not blanked here (it is a family, not a fixed name); it is
# still carried into the `-u` list below, and macOS ignores DYLD_* for the
# SIP-protected /usr/bin binaries this block invokes.
# Not locals: these arrive EXPORTED from the caller's environment, so assigning
# empty keeps them exported and inert for every child -- hence SC2034 per line.
# shellcheck disable=SC2034
LD_PRELOAD=
# shellcheck disable=SC2034
LD_AUDIT=
# shellcheck disable=SC2034
LD_LIBRARY_PATH=
# Same treatment for the Python loader variables, and for the same reason the LD_*
# trio needs the ASSIGNMENT form rather than the `-u` list below: the re-exec is
# conditional on that list being non-empty, so an environment carrying only
# PYTHONPATH would skip it entirely and hand every `python3 -c` here an attacker
# import path. That is not a theoretical descendant -- the backstop VERDICT
# VALIDATOR is one of those calls, so a forged `sitecustomize.py` runs before the
# code that decides whether a review passed. Measured: a hostile PYTHONPATH
# executed sitecustomize.py ahead of the `-c` body, and a hostile PYTHONUSERBASE
# got its usercustomize.py found, read and executed. Blanking is inert to Python
# for all three (measured), exactly as an empty LD_PRELOAD is inert to the loader.
# PYTHONSTARTUP is deliberately NOT here: measured, it applies only to interactive
# sessions and never to `-c`, so adding it would be hardening with no vector.
# Blanking PYTHONUSERBASE is NOT sufficient on its own: with it empty, site.py
# falls back to deriving the user site directory from $HOME, which this block does
# not strip -- so a hostile HOME still reaches usercustomize.py by a second route
# (measured: it executed). PYTHONNOUSERSITE closes that, because it disables user
# site-packages outright rather than relocating them, so no $HOME value can point
# at anything. It is the one entry here that must be EXPORTED and NON-EMPTY: the
# other three arrive exported already and are being emptied, while this one is
# usually absent and is a flag Python tests for presence, not value. It is
# deliberately absent from the `-u` strip list below -- this is the one Python
# variable that must SURVIVE into every descendant. Measured: ENABLE_USER_SITE
# becomes False, and ordinary stdlib use (json, sys -- all these call sites import)
# is unaffected.
# shellcheck disable=SC2034
PYTHONPATH=
# shellcheck disable=SC2034
PYTHONHOME=
# shellcheck disable=SC2034
PYTHONUSERBASE=
export PYTHONNOUSERSITE=1
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
  # Dynamic-loader variables are stripped alongside the forged functions. Be exact
  # about what this does and does not buy: on Linux the loader honours LD_PRELOAD /
  # LD_AUDIT before bash executes a single instruction, so `-p` cannot protect THIS
  # process — that residual is unreachable from here, and a parent able to set them
  # is the parent, which could as easily have exec'd a different binary outright
  # (the same boundary the shadowable-`exec` note draws). What the strip does buy is
  # that the re-exec'd shell and EVERY descendant start loader-clean, which is the
  # same treatment resolve-cli.sh already gives each of its `env -i` children.
  case "$_bd803_e" in
    BASH_FUNC_*|LD_PRELOAD=*|LD_AUDIT=*|LD_LIBRARY_PATH=*|DYLD_*|PYTHONPATH=*|PYTHONHOME=*|PYTHONUSERBASE=*)
      _bd803_envclean+=(-u "${_bd803_e%%=*}") ;;
  esac
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
# Initialize design review state, or continue a stopped one (#948)
# Usage: init-design-review.sh <design_file> [max_iterations]
#        init-design-review.sh --continue <design_file> [--max-iterations N]

set -euo pipefail

STATE_DIR="${BUSDRIVER_STATE_DIR:-.claude}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/validation.sh"
source "$SCRIPT_DIR/lib/state_management.sh"

usage() {
  echo "Usage: $0 <design_file> [max_iterations]" >&2
  echo "       $0 --continue <design_file> [--max-iterations N]" >&2
  echo "" >&2
  echo "Arguments:" >&2
  echo "  design_file        Path to the design document to review" >&2
  echo "  max_iterations     Maximum review iterations (default: 5)" >&2
  echo "  --continue         Continue a parked, ceiling-stopped or unfinished continued" >&2
  echo "                     review, keeping its attempt count and history" >&2
  echo "  --max-iterations N Raise the ceiling while continuing (must be higher than now)" >&2
}

_valid_n() { [[ "$1" =~ ^[1-9][0-9]{0,2}$ ]]; }

# Parse arguments: exactly the four shapes of #948 D1.
CONTINUE=false
NEW_MAX=""
if [[ $# -ge 1 && "$1" == "--continue" ]]; then
  CONTINUE=true
  shift
  if [[ $# -ne 1 && $# -ne 3 ]]; then
    usage
    exit 1
  fi
  DESIGN_FILE="$1"
  if [[ $# -eq 3 ]]; then
    if [[ "$2" != "--max-iterations" ]] || ! _valid_n "$3"; then
      log_error "--continue accepts only: --continue <design_file> [--max-iterations N] (N: 1-999)"
      exit 1
    fi
    NEW_MAX="$3"
  fi
else
  if [[ $# -lt 1 || $# -gt 2 ]]; then
    usage
    exit 1
  fi
  DESIGN_FILE="$1"
  MAX_ITERATIONS="${2:-5}"
  if ! _valid_n "$MAX_ITERATIONS"; then
    log_error "max_iterations must be a whole number 1-999 (got: $MAX_ITERATIONS); --continue must come first"
    exit 1
  fi
fi
case "$DESIGN_FILE" in
  -*)
    log_error "Unknown option or misplaced flag: $DESIGN_FILE (--continue must come first)"
    usage
    exit 1
    ;;
esac

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

SLUG=$(get_review_slug "$DESIGN_FILE")
if [[ -z "$SLUG" ]]; then
  log_error "Cannot derive a review slug from $DESIGN_FILE: nothing is left after its date prefix."
  exit 1
fi
# docs/reviews/.continue.lock is the global lock; `.` and `..` are not review directories.
case "$SLUG" in
  .|..|.continue.lock)
    log_error "Cannot review $DESIGN_FILE: its slug '$SLUG' is reserved. Rename the design file."
    exit 1
    ;;
esac
REVIEW_DIR="docs/reviews/$SLUG"
TARGET_STATE="$REVIEW_DIR/state.md"
POINTER_FILE="$STATE_DIR/current-design-review.local"
# A parking or ceiling-stopped loop writes its stop signal before its last few state
# writes; a state changed more recently than this may still have a loop finishing on it.
QUIET_SECS=10

_canon() {
  local d
  d=$(cd "$(dirname "$1")" 2>/dev/null && pwd -P) || return 1
  printf '%s/%s\n' "$d" "$(basename "$1")"
}

# 0 when the supplied file is the document state.md reviews (#948 D3 check 2).
_same_document() {
  local stored="$1" a b
  [[ -n "$stored" ]] || return 1
  a=$(_canon "$DESIGN_FILE") || return 1
  b=$(_canon "$stored") || return 1
  [[ "$a" == "$b" ]]
}

# ── Init refusal (#948 D2): never reset a stopped or continued review ──
# Placed before check_existing_review, cleanup_stale_review and the coverage
# advisory, so a refusal writes nothing.
# Run again under the cross-review lock, after check_existing_review (see there).
_init_refusal() {
if [[ "$CONTINUE" == false && -f "$TARGET_STATE" ]]; then
  _t_progress=$(_sf_get "$TARGET_STATE" "progress_status" || true)
  _t_status=$(_sf_get "$TARGET_STATE" "status" || true)
  _t_cc=$(_sf_get "$TARGET_STATE" "continuation_count" || true)
  _t_reason=""
  if [[ "$_t_progress" == "parked_no_progress" ]]; then
    _t_reason="it is parked (no progress)"
  elif [[ "$_t_status" == "max_iterations_exceeded" ]]; then
    _t_reason="it stopped at its iteration ceiling"
  elif [[ -n "$_t_cc" && "$_t_cc" != "0" && "$_t_status" != "passed" ]]; then
    _t_reason="it was continued (continuation_count $_t_cc) and has not passed"
  fi
  if [[ -n "$_t_reason" ]]; then
    _t_design=$(_sf_get "$TARGET_STATE" "design_file" || true)
    log_error "Refusing a fresh init: $TARGET_STATE holds a stopped review, because $_t_reason."
    log_error "  A fresh init would reset its attempt count and history."
    if _same_document "$_t_design"; then
      if [[ "$_t_status" == "max_iterations_exceeded" ]]; then
        log_error "  Continue it with: init-design-review.sh --continue $DESIGN_FILE --max-iterations N"
      else
        log_error "  Continue it with: init-design-review.sh --continue $DESIGN_FILE"
      fi
    else
      log_error "  Slug '$SLUG' is held by a stopped review of $_t_design."
      log_error "  Continue that file with --continue, or give this document a different name."
    fi
    exit 1
  fi
fi
}
_init_refusal

# A park is finished once its loop has exited: the loop holds .loop.pid for its whole
# run, so a paused loop is never mistaken for a finished one.
_loop_finished() {  # <state file>
  ! loop_alive "$(dirname "$1")"
}

# ── Continuation (#948 D3-D6) ───────────────────────────────────────
_refuse() {
  log_error "Refusing --continue: $1"
  shift
  local line
  for line in "$@"; do
    log_error "  $line"
  done
  exit 1
}

_filter_blocker() {
  case "$1" in
    blocked_by_high_issues|medium_issues_remaining) printf '%s' "$1" ;;
    *) printf '' ;;
  esac
}

# The loop's hash chain (compute_spec_hash): shasum, then sha256sum, then python3.
_hash() {
  local file="$1"
  if command -v shasum &>/dev/null; then
    shasum -a 256 "$file" | cut -d' ' -f1
  elif command -v sha256sum &>/dev/null; then
    sha256sum "$file" | cut -d' ' -f1
  elif command -v python3 &>/dev/null; then
    _CH_FILE="$file" python3 -c 'import hashlib, os; print(hashlib.sha256(open(os.environ["_CH_FILE"], "rb").read()).hexdigest())'
  else
    return 1
  fi
}

# Read-only checks, in the order of #948 D3. Sets the C_* values the build uses.
# Run once before the lock and again under it (checks 3, 7, 8 and 10 see a fresh read).
_continue_checks() {
  local under_lock="$1"
  local progress status active cc early iter max ptr="" f

  # 1. The target state exists at the explicit path.
  [[ -f "$TARGET_STATE" ]] || _refuse "no review state at $TARGET_STATE"

  # 2. Same document.
  local stored
  stored=$(_sf_get "$TARGET_STATE" "design_file" || true)
  _same_document "$stored" \
    || _refuse "$TARGET_STATE reviews '$stored', not '$DESIGN_FILE'" \
         "The slug matches, but --continue only continues the document state.md names."

  # 3. The state is continuable.
  progress=$(_sf_get "$TARGET_STATE" "progress_status" || true)
  status=$(_sf_get "$TARGET_STATE" "status" || true)
  active=$(_sf_get "$TARGET_STATE" "active" || true)
  cc=$(_sf_get "$TARGET_STATE" "continuation_count" || true)
  early=$(_sf_get "$TARGET_STATE" "early_stopped" || true)
  iter=$(_sf_get "$TARGET_STATE" "iteration" || true)
  max=$(_sf_get "$TARGET_STATE" "max_iterations" || true)
  if [[ -f "$POINTER_FILE" ]]; then
    ptr=$(cat "$POINTER_FILE" 2>/dev/null || true)
  fi
  [[ -n "$cc" ]] || cc=0
  [[ "$cc" =~ ^[0-9]+$ ]] || _refuse "continuation_count is not a number ('$cc') in $TARGET_STATE"
  [[ "$iter" =~ ^[0-9]+$ && "$max" =~ ^[0-9]+$ ]] \
    || _refuse "iteration or max_iterations is unreadable in $TARGET_STATE"

  # However it stopped, a review whose loop is still running is never continued.
  _loop_finished "$TARGET_STATE" \
    || _refuse "the review's loop has not finished (status '${status:-<none>}')" \
         "Wait for it to exit, then run --continue again."

  C_STOP_REASON="$early"
  if [[ "$progress" == "parked_no_progress" ]]; then
    C_SIGNAL=park
  elif [[ "$status" == "max_iterations_exceeded" ]]; then
    [[ -n "$NEW_MAX" ]] \
      || _refuse "this review stopped at its iteration ceiling ($iter of $max)" \
           "Continue it with: --continue $DESIGN_FILE --max-iterations N (N higher than $max)"
    C_SIGNAL=ceiling
    [[ -n "$C_STOP_REASON" ]] || C_STOP_REASON="max_iterations_exceeded"
  elif [[ "$cc" -gt 0 && "$status" != "passed" ]]; then
    if [[ "$ptr" == "$SLUG" ]]; then
      _refuse "the loop resumes this review; run it" \
        "The pointer names '$SLUG' (status ${status:-<none>}), so run-design-review-loop.sh continues it." \
        "Continuing it here could race that loop and lower its iteration count."
    fi
    if [[ "$active" == "true" ]]; then
      state_file_is_stale "$TARGET_STATE" \
        || _refuse "it was active within DESIGN_REVIEW_STALE_HOURS and the pointer no longer names it" \
             "The loop cannot resume it (it resolves its state through the pointer)." \
             "Wait until it is stale, then run --continue."
      [[ -n "$C_STOP_REASON" ]] || C_STOP_REASON="stale"
    fi
    C_SIGNAL=continued
    [[ -n "$C_STOP_REASON" ]] || C_STOP_REASON="$status"
  else
    _refuse "the review is not stopped (status '${status:-<none>}', progress '${progress:-<none>}', continuation_count $cc)" \
      "Only a parked review, a ceiling stop (with --max-iterations) or a continued review that has not passed can be continued." \
      "Use the loop, or a fresh init."
  fi
  state_file_quiet_for "$TARGET_STATE" "$QUIET_SECS" \
    || _refuse "$TARGET_STATE changed less than ${QUIET_SECS}s ago" \
         "A loop may still be finishing on it. Wait, then run --continue again."

  # 4. No leftovers of a killed continuation (our own lock excepted, under it).
  local left=()
  if [[ "$under_lock" != true && -e "$REVIEW_DIR/.continue.lock" ]]; then
    left+=("$REVIEW_DIR/.continue.lock")
  fi
  for f in "$REVIEW_DIR"/state.md.continue.* "$REVIEW_DIR"/attempts/.staging.*; do
    if [[ -e "$f" || -L "$f" ]]; then
      left+=("$f")
    fi
  done
  [[ ${#left[@]} -eq 0 ]] \
    || _refuse "a killed continuation left these behind; inspect and remove them first:" "${left[@]}"

  # 5. No symlinked top-level entry, and the directory itself is no symlink.
  local links
  [[ ! -L "$REVIEW_DIR" && ! -L docs/reviews && ! -L docs ]] \
    || _refuse "$REVIEW_DIR, docs/reviews or docs is a symlink; refusing to follow it"
  [[ ! -L "${STATE_DIR%/}" && ! -L "$POINTER_FILE" && ( -f "$POINTER_FILE" || ! -e "$POINTER_FILE" ) ]] \
    || _refuse "$STATE_DIR or $POINTER_FILE is a symlink, or the pointer is not a regular file; refusing to write through it"
  # The pointer is rewritten in place, so a hard link would carry the write to its other names.
  [[ -z "$(find "$POINTER_FILE" -prune -links +1 2>/dev/null)" ]] \
    || _refuse "$POINTER_FILE has another hard link; refusing to write through it"
  # The ledger is appended in place after the commit, so the same holds for it.
  [[ -z "$(find "$REVIEW_DIR/continuations.jsonl" -prune -links +1 2>/dev/null)" ]] \
    || _refuse "$REVIEW_DIR/continuations.jsonl has another hard link; refusing to write through it"
  links=$(find "$REVIEW_DIR" -mindepth 1 -maxdepth 1 ! -type f ! -type d -print)  # a FIFO would block a write
  [[ -z "$links" ]] || _refuse "the review directory holds a symlink or special file; refusing to follow it:" "$links"

  # 6. A raised ceiling must be higher.
  C_ITER_BEFORE="$iter"
  C_MAX_BEFORE="$max"
  C_MAX_AFTER="$max"
  if [[ -n "$NEW_MAX" ]]; then
    [[ "$NEW_MAX" -gt "$max" ]] \
      || _refuse "--max-iterations $NEW_MAX is not higher than the current max_iterations $max"
    C_MAX_AFTER="$NEW_MAX"
  fi

  # 7. Room under the ceiling. Only a park is counted here: every park exit leaves
  # before increment_iteration, so this is the one place it is counted.
  C_ITER_AFTER="$iter"
  if [[ "$C_SIGNAL" == park ]]; then
    C_ITER_AFTER=$((iter + 1))
  fi
  [[ "$C_ITER_AFTER" -lt "$C_MAX_AFTER" ]] \
    || _refuse "the continued review would start at iteration $C_ITER_AFTER with max_iterations $C_MAX_AFTER" \
         "Raise the ceiling with --max-iterations N."

  # 8. The pointer names no other review the loop could still run. The loop re-reads
  # the pointer on every state write, and `active` cannot tell a finished review from
  # a running loop (only init writes active: true), so only a review the loop refuses
  # at start (park or ceiling signal) may be named.
  if [[ -n "$ptr" && "$ptr" != "$SLUG" ]]; then
    local other="docs/reviews/$ptr/state.md" o_progress o_status
    [[ -f "$other" ]] \
      || _refuse "the pointer names '$ptr', which has no state.md" \
           "Once nothing uses it, remove $POINTER_FILE and run --continue again."
    o_progress=$(_sf_get "$other" "progress_status" || true)
    o_status=$(_sf_get "$other" "status" || true)
    if [[ "$o_progress" != "parked_no_progress" && "$o_status" != "max_iterations_exceeded" ]]; then
      _refuse "the pointer names another review, '$ptr' (status ${o_status:-<none>})" \
        "A loop still running on it re-reads the pointer on every state write, so moving the pointer would send its writes into this review." \
        "Let it finish; once no loop runs on it, remove $POINTER_FILE and run --continue again."
    fi
    _loop_finished "$other" \
      || _refuse "'$ptr' is parked but its loop has not finished (status ${o_status:-<none>})" \
           "Wait for it to exit, then run --continue again."
    state_file_quiet_for "$other" "$QUIET_SECS" \
      || _refuse "'$ptr' stopped less than ${QUIET_SECS}s ago; its loop may still be finishing" \
           "Wait, then run --continue again."
  fi

  # 9. Recover run_id from the explicit target directory (never through the pointer).
  for f in "$REVIEW_DIR"/* "$REVIEW_DIR"/.[!.]*; do
    if [[ -f "$f" && ! -r "$f" ]]; then
      _refuse "artifact $f is not readable"
    fi
  done
  local a v
  C_RUN_ID=""
  for a in codex.json agy.json grok.json claude.json; do
    f="$REVIEW_DIR/$a"
    [[ -f "$f" ]] || continue
    v=$(jq -r '.metadata.run_id // ""' "$f" 2>/dev/null || echo "")
    if [[ -n "$v" ]]; then
      C_RUN_ID="$v"
      break
    fi
  done
  if [[ -n "$C_RUN_ID" ]]; then
    [[ "$C_RUN_ID" =~ ^[A-Za-z0-9_-]+$ ]] \
      || _refuse "recovered run_id '$C_RUN_ID' is unsafe as a path component"
    C_RUN_DIRNAME="$C_RUN_ID"
  else
    C_RUN_DIRNAME="unknown"
  fi

  # 10. Archive number: one more than the highest existing NNN.
  local e n max_n=0
  for e in "$REVIEW_DIR"/attempts/[0-9][0-9][0-9]-*; do
    [[ -e "$e" ]] || continue
    n=$(basename "$e")
    n=$((10#${n%%-*}))
    if [[ "$n" -gt "$max_n" ]]; then
      max_n="$n"
    fi
  done
  C_NNN=$(printf '%03d' $((max_n + 1)))
  C_DEST="$REVIEW_DIR/attempts/${C_NNN}-${C_RUN_DIRNAME}"
  [[ ! -e "$C_DEST" ]] \
    || _refuse "the archive destination $C_DEST already exists (anomaly); inspect it"

  # Derivations (D5), still read-only, so their refusals change nothing.
  local hh mh ch ppr pps pbh pbm tail write_site=false
  hh=$(_sf_get "$TARGET_STATE" "high_issues_history" || true)
  mh=$(_sf_get "$TARGET_STATE" "medium_issues_history" || true)
  ch=$(_sf_get "$TARGET_STATE" "coverage_history" || true)
  [[ -n "$hh" ]] || hh="[]"
  [[ -n "$mh" ]] || mh="[]"
  [[ -n "$ch" ]] || ch="[]"
  for v in "$hh" "$mh" "$ch"; do
    jq -e 'type == "array"' <<<"$v" >/dev/null 2>&1 \
      || _refuse "inconsistent state: a history in $TARGET_STATE is not a JSON array ($v)"
  done
  C_HIGH="$hh"
  C_MEDIUM="$mh"
  C_COVERAGE="$ch"
  C_DROPPED=null
  if [[ "$C_SIGNAL" == park && "$early" == "arbiter_verdict_uncountable" && "$status" != "uncountable_claude_output" ]]; then
    # Write-site uncountable park: its trailing entry is the loop's placeholder 0.
    write_site=true
    tail=$(jq -r 'if length == 0 then "none" else (.[-1] | tostring) end' <<<"$hh")
    [[ "$tail" == "0" ]] \
      || _refuse "inconsistent state: a write-site uncountable park must end high_issues_history with its placeholder 0 (got $hh)"
    C_HIGH=$(jq -c '.[:-1]' <<<"$hh")
    C_DROPPED=0
  fi

  ppr=$(_sf_get "$TARGET_STATE" "pre_park_recorded" || true)
  pps=$(_sf_get "$TARGET_STATE" "pre_park_progress_status" || true)
  if [[ "$ppr" == "true" ]]; then
    case "$pps" in
      ""|blocked_by_high_issues|medium_issues_remaining) ;;
      *) _refuse "inconsistent state: pre_park_progress_status '$pps' is not a blocker value" ;;
    esac
    C_DERIVED="$pps"
    C_SOURCE=persisted
  elif [[ "$C_SIGNAL" == continued ]]; then
    C_DERIVED=$(_filter_blocker "$progress")
    C_SOURCE=carried
  elif [[ "$write_site" == true ]]; then
    C_SOURCE=legacy_high_history
    if [[ "$C_HIGH" == "[]" ]]; then
      C_DERIVED=""
    else
      tail=$(jq -r '.[-1] | tostring' <<<"$C_HIGH")
      if [[ "$tail" =~ ^[0-9]+$ && "$tail" -gt 0 ]]; then
        C_DERIVED=blocked_by_high_issues
      else
        _refuse "ambiguous_legacy_history: $TARGET_STATE ends high_issues_history with 0 after the placeholder drop ($C_HIGH)" \
          "That 0 may be a passed or degraded round, or a second placeholder; no field tells them apart." \
          "Nothing was changed. Resolve it by hand and record why."
      fi
    fi
  else
    pbh=$(_sf_get "$TARGET_STATE" "plan_blocking_high" || true)
    pbm=$(_sf_get "$TARGET_STATE" "plan_blocking_medium" || true)
    [[ "$pbh" =~ ^[0-9]+$ ]] || pbh=0
    [[ "$pbm" =~ ^[0-9]+$ ]] || pbm=0
    C_SOURCE=legacy_plan_blocking
    if [[ "$pbh" -gt 0 ]]; then
      C_DERIVED=blocked_by_high_issues
    elif [[ "$pbm" -gt 0 ]]; then
      C_DERIVED=medium_issues_remaining
    else
      C_DERIVED=""
    fi
  fi

  C_STATUS_BEFORE="$status"
  C_EARLY_BEFORE="$early"
  C_CC_AFTER=$((cc + 1))
}

LOCK="$REVIEW_DIR/.continue.lock"
# Serializes every --continue, whatever its slug: each one moves the shared pointer, so
# check 8 under this lock must see the pointer an earlier continuation wrote.
ALL_LOCK="docs/reviews/.continue.lock"  # the one path the loop and every init take
HELD_ALL_LOCK=false
HELD_LOCK=false
CREATED_ATTEMPTS=false
STAGING=""
TEMP_STATE=""
CLAIMED_DEST=""
PTR_TOUCHED=false
HAD_PTR=false
SAVED_PTR=""
CREATED_STATE_DIR=false
LEDGER_DONE=false
# INT, TERM and HUP are deferred while --continue runs and acted on only here, where
# every path this run created is already recorded for the rollback.
_CONT_SIG=""
_checkpoint() { [[ -z "$_CONT_SIG" ]] || exit 1; }
# _claim <dir>: mkdir with INT/TERM/HUP ignored in mkdir only (inherited across exec), so
# a process-group signal cannot kill it after it created <dir> and before it said so.
_claim() { (trap '' INT TERM HUP; exec mkdir "$1") 2>/dev/null; }

# Single rollback (D6): undoes only what this run recorded creating, in reverse order.
_continue_rollback() {
  set +e
  if [[ "$PTR_TOUCHED" == true ]]; then
    if [[ "$HAD_PTR" == true ]]; then
      printf '%s' "$SAVED_PTR" > "$POINTER_FILE"
    else
      rm -f "$POINTER_FILE"
    fi
    [[ "$CREATED_STATE_DIR" == true ]] && rmdir "$STATE_DIR" 2>/dev/null
  fi
  [[ -n "$CLAIMED_DEST" ]] && rm -rf -- "$CLAIMED_DEST"
  [[ -n "$STAGING" ]] && rm -rf -- "$STAGING"
  [[ "$CREATED_ATTEMPTS" == true ]] && rmdir "$REVIEW_DIR/attempts" 2>/dev/null
  [[ -n "$TEMP_STATE" ]] && rm -f -- "$TEMP_STATE" "$TEMP_STATE.tmp"
  [[ "$HELD_LOCK" == true ]] && rmdir "$LOCK" 2>/dev/null
  [[ "$HELD_ALL_LOCK" == true ]] && rmdir "$ALL_LOCK" 2>/dev/null
  log_error "--continue did not complete; what this run created was removed (state.md and the pointer are unchanged)."
  exit 1
}

# After the commit nothing is rolled back. A failed ledger append leaves the lock on
# purpose: the loop and --continue refuse it until the operator has looked (D6).
_continue_after_commit() {
  set +e
  # The pointer is written, so the cross-slug lock has done its job.
  [[ "$HELD_ALL_LOCK" == true ]] && rmdir "$ALL_LOCK" 2>/dev/null
  if [[ "$LEDGER_DONE" == true ]]; then
    log_error "Continuation committed and recorded, but $LOCK could not be removed; remove it after checking."
  else
    log_error "Continuation COMMITTED to $TARGET_STATE, but its ledger line was not written."
    log_error "  The archive $C_DEST has no line in $REVIEW_DIR/continuations.jsonl."
    log_error "  $LOCK is left in place on purpose: the loop and --continue refuse until you inspect."
  fi
  exit 1
}

continue_review() {
  command -v jq &>/dev/null || _refuse "jq is required"
  log_info "Continuing review: $TARGET_STATE"
  _continue_checks false

  trap '_CONT_SIG=1' INT TERM HUP
  _claim "$ALL_LOCK" \
    || _refuse "another --continue holds $ALL_LOCK" "If none is running, a killed one left it: inspect, then remove it."
  HELD_ALL_LOCK=true
  trap _continue_rollback EXIT
  _claim "$LOCK" || _refuse "another --continue holds $LOCK"
  HELD_LOCK=true
  _checkpoint
  _continue_checks true

  # D4: stage, manifest, verify. Nothing is published yet.
  if [[ ! -d "$REVIEW_DIR/attempts" ]]; then
    _claim "$REVIEW_DIR/attempts"
    CREATED_ATTEMPTS=true
  fi
  local staging_path="$REVIEW_DIR/attempts/.staging.$$"
  _claim "$staging_path"
  STAGING="$staging_path"
  _checkpoint
  local names name manifest="" h
  names=$(cd "$REVIEW_DIR" && find . -mindepth 1 -maxdepth 1 -type f \
            ! -name continuations.jsonl ! -name '*.tmp' ! -name 'state.md.continue.*' -print \
          | sed 's|^\./||' | LC_ALL=C sort)
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    cp -p "$REVIEW_DIR/$name" "$STAGING/$name"
  done <<<"$names"
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    h=$(_hash "$STAGING/$name")
    [[ "$h" =~ ^[0-9a-f]{64}$ ]] || _refuse "could not hash $name"
    manifest+="$h  $name"$'\n'
  done <<<"$names"
  printf '%s' "$manifest" > "$STAGING/MANIFEST.sha256"
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    [[ "$(_hash "$REVIEW_DIR/$name")" == "$(_hash "$STAGING/$name")" ]] \
      || _refuse "the staged copy of $name does not match its source"
  done <<<"$names"
  _checkpoint

  # D5: build the new state on a temporary copy, through path-explicit writes only.
  TEMP_STATE="$REVIEW_DIR/state.md.continue.$$"
  cp -p "$TARGET_STATE" "$TEMP_STATE"
  local t="$TEMP_STATE" now
  now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  _sf_set "$t" "iteration" "$C_ITER_AFTER"
  _sf_set "$t" "max_iterations" "$C_MAX_AFTER"
  _sf_set "$t" "high_issues_history" "\"$C_HIGH\""
  _sf_set "$t" "progress_status" "\"$C_DERIVED\""
  _sf_set "$t" "fresh_round_required" "true"
  _sf_set "$t" "early_stopped" '""'
  _sf_set "$t" "last_stop_reason" "\"$C_STOP_REASON\""
  if [[ -n "$C_RUN_ID" ]]; then
    _sf_set "$t" "last_stop_run_id" "\"$C_RUN_ID\""
  else
    _sf_set "$t" "last_stop_run_id" "null"
  fi
  _sf_set "$t" "continuation_count" "$C_CC_AFTER"
  _sf_set "$t" "pre_park_progress_status" '""'
  _sf_set "$t" "pre_park_recorded" "false"
  _sf_set "$t" "status" '"IN_PROGRESS"'
  _sf_set "$t" "active" "true"
  _sf_set "$t" "last_review_timestamp" "\"$now\""
  _checkpoint

  # D6 step 1: publish, claiming the destination first so a move can never nest.
  _claim "$C_DEST" \
    || _refuse "the archive destination $C_DEST appeared after numbering (anomaly); inspect it"
  CLAIMED_DEST="$C_DEST"
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    mv "$STAGING/$name" "$C_DEST/$name"
  done <<<"$names"
  mv "$STAGING/MANIFEST.sha256" "$C_DEST/MANIFEST.sha256"
  rmdir "$STAGING"
  STAGING=""
  _checkpoint

  # D6 step 2: save the pointer byte for byte, then point it at the target.
  if [[ -f "$POINTER_FILE" ]]; then
    SAVED_PTR=$(cat "$POINTER_FILE" && printf x) \
      || { log_error "Cannot read $POINTER_FILE to back it up; rolled back."; exit 1; }
    SAVED_PTR="${SAVED_PTR%x}"
    HAD_PTR=true
  fi
  if [[ ! -d "$STATE_DIR" ]]; then
    mkdir -p "$STATE_DIR"
    CREATED_STATE_DIR=true
  fi
  PTR_TOUCHED=true
  echo "$SLUG" > "$POINTER_FILE"
  _checkpoint

  # D6 step 3: commit. mv can be killed after its rename (a process-group signal): a
  # temp state that is gone was committed, so only a temp state still there rolls back.
  if ! mv "$TEMP_STATE" "$TARGET_STATE" && [[ -e "$TEMP_STATE" ]]; then
    exit 1
  fi
  trap _continue_after_commit EXIT
  TEMP_STATE=""

  # D6 step 4: one ledger line, built before the file is opened.
  local ledger="$REVIEW_DIR/continuations.jsonl" seq=1 line msha
  if [[ -f "$ledger" ]]; then
    seq=$(( $(wc -l < "$ledger") + 1 ))
  fi
  msha=$(_hash "$C_DEST/MANIFEST.sha256")
  line=$(jq -nc \
    --argjson seq "$seq" --arg ts "$now" --arg signal "$C_SIGNAL" \
    --arg status_before "$C_STATUS_BEFORE" --arg early "$C_EARLY_BEFORE" --arg rid "$C_RUN_ID" \
    --argjson ib "$C_ITER_BEFORE" --argjson ia "$C_ITER_AFTER" \
    --argjson mb "$C_MAX_BEFORE" --argjson ma "$C_MAX_AFTER" \
    --argjson hh "$C_HIGH" --argjson mh "$C_MEDIUM" --argjson ch "$C_COVERAGE" \
    --argjson dropped "$C_DROPPED" --arg derived "$C_DERIVED" --arg source "$C_SOURCE" \
    --arg archive "$C_DEST" --arg msha "$msha" \
    '{seq: $seq, timestamp: $ts, stop_signal: $signal, status_before: $status_before,
      early_stopped: $early, stop_run_id: (if $rid == "" then null else $rid end),
      iteration_before: $ib, iteration_after: $ia, max_before: $mb, max_after: $ma,
      high_issues_history: $hh, medium_issues_history: $mh, coverage_history: $ch,
      dropped_high_placeholder: $dropped, derived_progress_status: $derived,
      derivation_source: $source, archive_dir: $archive, manifest_sha256: $msha}')
  printf '%s\n' "$line" >> "$ledger"
  LEDGER_DONE=true
  rmdir "$LOCK"
  rmdir "$ALL_LOCK"
  trap - EXIT INT TERM HUP

  log_info "Review continued: $TARGET_STATE"
  log_info "  Stop: $C_SIGNAL ($C_STOP_REASON), run ${C_RUN_ID:-unknown}"
  log_info "  Iteration $C_ITER_BEFORE -> $C_ITER_AFTER of $C_MAX_AFTER; blocker carried: ${C_DERIVED:-none} ($C_SOURCE)"
  log_info "  Archive: $C_DEST"
  log_info "  The next round must be a full one (--claude-only is refused until then)."
  log_info "Run: /bin/bash -p scripts/run-design-review-loop.sh"
}

if [[ "$CONTINUE" == true ]]; then
  continue_review
  exit 0
fi

# The pointer is shared with --continue: hold its lock from the existing-review check
# through the pointer write, so no continuation commits in between (its check 8, under
# the same lock, then sees this review).
# A fresh init keeps the same no-alias contract: nothing is created or written through a
# symlinked review path, and a special state.md (a FIFO would block) is never opened.
if [[ -L docs || -L docs/reviews || -L "$REVIEW_DIR" || -L "$REVIEW_DIR/state.md" ]] \
   || [[ -e "$REVIEW_DIR/state.md" && ! -f "$REVIEW_DIR/state.md" ]]; then
  log_error "$REVIEW_DIR, docs/reviews or docs is a symlink, or its state.md is not a regular file; refusing to follow it."
  exit 1
fi
trap '_CONT_SIG=1' INT TERM HUP
mkdir -p "$(dirname "$REVIEW_DIR")"
if ! _claim "$ALL_LOCK"; then
  log_error "A --continue holds $ALL_LOCK; run init again when it has finished."
  log_error "  If none is running, a killed one left it: inspect, then remove it."
  exit 1
fi
trap 'rmdir "$ALL_LOCK" 2>/dev/null' EXIT
trap 'exit 1' INT TERM HUP
_checkpoint

# Check for existing active review
# check_existing_review return codes: 0=stale (clean up), 1=active (block), 2=no review (skip)
EXISTING=0
check_existing_review || EXISTING=$?
# Again, under the lock and before any cleanup: a loop on this slug that was running at
# the first check has either been refused by check_existing_review or has parked since.
_init_refusal
if [[ -L "$POINTER_FILE" || ( -e "$POINTER_FILE" && ! -f "$POINTER_FILE" ) ]]; then
  log_error "$POINTER_FILE is a symlink or not a regular file; refusing to write through it."
  exit 1
fi
if loop_alive "$REVIEW_DIR"; then
  log_error "A loop is running on $REVIEW_DIR (pid $({ [[ -f "$REVIEW_DIR/.loop.pid" ]] && head -n 1 "$REVIEW_DIR/.loop.pid"; } 2>/dev/null || echo '?')); refusing to reset it."
  exit 1
fi
if [[ $EXISTING -eq 2 ]]; then
  # No active review — nothing to clean up, proceed to init
  :
elif [[ $EXISTING -eq 0 ]]; then
  STALE_SLUG=$(cat "$STATE_DIR/current-design-review.local" 2>/dev/null)
  if loop_alive "docs/reviews/$STALE_SLUG"; then
    log_error "A loop is running on docs/reviews/$STALE_SLUG; it is not stale. Refusing to clean it up."
    exit 1
  fi
  log_info "Cleaning up stale review: $STALE_SLUG (never completed an iteration)"
  cleanup_stale_review
elif [[ $EXISTING -eq 1 ]]; then
  ACTIVE_SLUG=$(cat "$STATE_DIR/current-design-review.local" 2>/dev/null)
  log_error "Active review loop already exists: $ACTIVE_SLUG"
  log_error "  State: docs/reviews/$ACTIVE_SLUG/state.md"
  log_error "  To force: rm $STATE_DIR/current-design-review.local"
  log_error "  (A continued review is not reset that way: init refuses its slug, and it resumes"
  log_error "   through --continue once it is stale.)"
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
rmdir "$ALL_LOCK"
trap - EXIT INT TERM HUP

log_info "Design review initialized"
log_info "  Design file: $DESIGN_FILE"
log_info "  Max iterations: $MAX_ITERATIONS"
log_info "  State file: $STATE_FILE"
log_info ""
log_info "Ready to start review. Run: /bin/bash -p scripts/run-design-review-loop.sh"
