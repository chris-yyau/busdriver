#!/usr/bin/env bash
# tests/test-trusted-review-cli.sh — #789: planted in-checkout review CLIs are unavailable.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$ROOT/scripts/lib/resolve-cli.sh"
PASS=0
FAIL=0
ok() { echo "  PASS  $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL  $1"; FAIL=$((FAIL + 1)); }

# Portable temp root: BD789_TEST_TMP_ROOT -> RUNNER_TEMP -> TMPDIR -> /tmp.
# The previous chain hardcoded one operator's /Volumes path and then hard-failed,
# so this suite could not run anywhere else (measured: it aborted with "no usable
# temp root" on a runner that had neither that path nor RUNNER_TEMP). Each
# candidate must be an ABSOLUTE, non-symlink, writable directory — the fixtures
# plant executables and symlinks under this root, so a relative root or a
# symlinked one could redirect the whole fixture tree out from under the asserts.
# Every guard is written `|| continue` (never `&& continue`) so a false test does
# not trip `set -e`.
_BD789_TMP_ROOT=""
for _bd789_cand in "${BD789_TEST_TMP_ROOT:-}" "${RUNNER_TEMP:-}" "${TMPDIR:-}" /tmp; do
  [[ -n "$_bd789_cand" ]] || continue
  _bd789_cand="${_bd789_cand%/}"
  [[ -n "$_bd789_cand" ]] || _bd789_cand=/
  [[ "$_bd789_cand" == /* ]] || continue
  [[ ! -L "$_bd789_cand" ]] || continue
  [[ -d "$_bd789_cand" && -w "$_bd789_cand" ]] || continue
  _BD789_TMP_ROOT="$_bd789_cand"
  break
done
if [[ -z "$_BD789_TMP_ROOT" ]]; then
  echo "bd-789 focused test: no usable temp root (set BD789_TEST_TMP_ROOT to an absolute, non-symlink, writable directory)" >&2
  exit 1
fi
WORK=$(mktemp -d "$_BD789_TMP_ROOT/bd-789-ftest.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

# #803: review lib pin latches at trusted source load.
set +e
pin_check=$(
  cd "$ROOT" && /bin/bash --norc -c ". \"$LIB\" >/dev/null 2>&1; canon=\$(_bd803_canonical_file_path \"$LIB\"); _bd803_ensure_staged_lib >/dev/null 2>&1; printf 'PIN=%s\nCANON=%s\nSHA=%s\n' \"\${_BD803_REVIEW_LIB_PIN:-}\" \"\$canon\" \"\${_BD803_REVIEW_LIB_SHA:-}\""
)
set -e
pin_val=$(/usr/bin/printf '%s\n' "$pin_check" | /usr/bin/grep '^PIN=' | /usr/bin/head -1 | /usr/bin/cut -d= -f2-)
canon_val=$(/usr/bin/printf '%s\n' "$pin_check" | /usr/bin/grep '^CANON=' | /usr/bin/head -1 | /usr/bin/cut -d= -f2-)
sha_val=$(/usr/bin/printf '%s\n' "$pin_check" | /usr/bin/grep '^SHA=' | /usr/bin/head -1 | /usr/bin/cut -d= -f2-)
if [[ "$pin_val" == /* && -n "$pin_val" && ( "$pin_val" == "$canon_val" || "$pin_val" -ef "$canon_val" ) ]]; then
  ok "#803: _BD803_REVIEW_LIB_PIN latched at source load"
else
  bad "#803: _BD803_REVIEW_LIB_PIN latch failed: pin='$pin_val' canon='$canon_val'"
fi
if [[ "$sha_val" =~ ^[0-9a-f]{64}$ ]]; then
  ok "#803: _BD803_REVIEW_LIB_SHA latched after ensure_staged_lib (64-char hex)"
else
  bad "#803: _BD803_REVIEW_LIB_SHA latch failed: sha='$sha_val'"
fi

# #803: `builtin exec N< file` redirects the `builtin` COMMAND, so the descriptor
# is closed again before the next line (bash 3.2 / macOS). Every descriptor-bound
# staging site must use a group redirect instead; reintroducing the idiom silently
# breaks review-lib staging and makes every review dispatch refuse.
set +e
bexec_hits=$(/usr/bin/grep -cE '^[^#]*builtin[[:space:]]+exec[[:space:]]+[0-9]+[<>]' "$LIB")
set -e
if [[ "$bexec_hits" -eq 0 ]]; then
  ok "#803: no 'builtin exec N<' descriptor staging in resolve-cli.sh"
else
  bad "#803: 'builtin exec N<' reintroduced in resolve-cli.sh ($bexec_hits site(s)) — use a group redirect"
fi

# Behavioural half of the same invariant: the descriptor chain must actually run.
# _bd803_bash_staged_lib reads the staged copy once, hashes those exact bytes, and
# executes them via process substitution. A broken read, a mismatched digest, or a
# failed handoff all surface here as empty output.
set +e
staged_home=$(/bin/bash --noprofile --norc -c 'source "$1" >/dev/null 2>&1; _bd803_bash_staged_lib --print-trusted-home' bash "$LIB" 2>/dev/null)
set -e
if [[ -n "$staged_home" && "$staged_home" == /* ]]; then
  ok "#803: staged-lib descriptor chain executes (read-once verified bytes, --print-trusted-home='$staged_home')"
else
  bad "#803: staged-lib descriptor chain broken: --print-trusted-home returned '$staged_home'"
fi

# #803: `builtin` is ITSELF shadowable — an imported BASH_FUNC_builtin%% makes
# `builtin unset` a silent no-op. The source-load reset must therefore clear the
# staged-lib state with plain assignments, so attacker-supplied _STAGED/_SHA
# cannot survive into a dispatch. Attack shape: export a matching pair pointing at
# planted bytes, shadow `builtin`, source the lib, and see whether the pin re-latches.
PLANT="$WORK/planted-lib.sh"
printf 'printf "PLANTED_EXEC\\n"\n' > "$PLANT"
PLANT_SHA=$(/usr/bin/shasum -a 256 "$PLANT" | /usr/bin/cut -d' ' -f1)
set +e
# shellcheck disable=SC2016  # the single-quoted script is expanded by the child, not here
shadow_out=$(
  env "BASH_FUNC_builtin%%=() { :; }" \
      _BD803_REVIEW_LIB_STAGED="$PLANT" \
      _BD803_REVIEW_LIB_SHA="$PLANT_SHA" \
    /bin/bash --noprofile --norc -c \
      '. "$1" >/dev/null 2>&1; printf "STAGED=%s\n" "${_BD803_REVIEW_LIB_STAGED:-}"' bash "$LIB" 2>/dev/null
)
set -e
shadow_staged=$(/usr/bin/printf '%s\n' "$shadow_out" | /usr/bin/grep '^STAGED=' | /usr/bin/head -1 | /usr/bin/cut -d= -f2-)
if [[ "$shadow_staged" != "$PLANT" ]]; then
  ok "#803: BASH_FUNC_builtin%% shadow cannot preserve attacker staged-lib state"
else
  bad "#803: BASH_FUNC_builtin%% shadow preserved attacker _BD803_REVIEW_LIB_STAGED='$shadow_staged'"
fi

# #803: the same state, poisoned the OTHER way — READONLY. BASH_ENV is honoured for
# `bash script.sh`, so an env-injected prelude can declare the staged-lib state
# readonly before this library is ever sourced, and neither a plain assignment nor
# `builtin unset` can clear a readonly. Point it at a real planted file whose digest
# matches the attacker's own _SHA and the staging fast path would hand those bytes to
# the clean child. Measured end-to-end before the fix: the planted script executed.
# This asserts the dispatch REFUSES rather than executing planted bytes.
RO_PLANT="$WORK/readonly-planted.sh"
printf 'printf "PWNED_EXEC\\n"\n' > "$RO_PLANT"
chmod 500 "$RO_PLANT"
RO_SHA=$(/usr/bin/shasum -a 256 "$RO_PLANT" | /usr/bin/cut -d' ' -f1)
RO_ENV="$WORK/readonly-prelude.sh"
# %q, not %s: WORK comes from BD789_TEST_TMP_ROOT/RUNNER_TEMP/TMPDIR, so the planted
# path can carry spaces or shell metacharacters. Unquoted it would emit a malformed
# declaration, the poison would never load, and the assertion below would pass for
# the wrong reason — the exploit would look closed because it never ran.
printf 'readonly _BD803_REVIEW_LIB_STAGED=%q\nreadonly _BD803_REVIEW_LIB_SHA=%q\n' "$RO_PLANT" "$RO_SHA" > "$RO_ENV"
set +e
# shellcheck disable=SC2016  # the single-quoted script is expanded by the child, not here
ro_out=$(
  BASH_ENV="$RO_ENV" /bin/bash --noprofile -c \
    '. "$1" >/dev/null 2>&1; _bd803_bash_staged_lib --print-trusted-home' bash "$LIB" 2>/dev/null
)
set -e
if [[ "$ro_out" != *PWNED_EXEC* ]]; then
  ok "#803: readonly-poisoned staged-lib state cannot execute planted bytes"
else
  bad "#803: readonly-poisoned staged-lib state EXECUTED planted bytes (got '$ro_out')"
fi

# #803: the authoritative boundary. Every EXECUTABLE entry point that sources
# resolve-cli.sh must start privileged, because privileged bash ignores BASH_ENV —
# the only environment-reachable way to install the DEBUG trap or the readonly
# declarations the two assertions above model. Measured: the same preludes that
# execute planted bytes without -p are inert with it. Sourced libraries are excluded
# (they cannot re-exec; they inherit their entry point's mode). Generated over the
# real set rather than a fixed list, so a new entry point is covered on arrival.
# An entry point here means: it SOURCES the library (not merely mentions it), it is
# executable, and it is not itself a library under a lib/ directory — a sourced
# library cannot re-exec and inherits the mode of whatever entry point ran it.
entry_seen=0
# BEHAVIOURAL, not substring: an in-script `exec "$BASH" -p "$0"` guard looks right
# and is defeated, because the first bash has ALREADY imported BASH_FUNC_* and run
# BASH_ENV before reaching it — a shadowed `exec` returns and the script continues
# unprivileged (measured: $- went from "hpB" to "hB" and the prelude ran). Only the
# shebang is applied by the kernel, ahead of any import. So take each entry point's
# REAL shebang, build a probe carrying that exact interpreter line, execute it under
# a hostile prelude plus a shadowed `exec`, and require it to come up privileged and
# blind to BASH_ENV. A guard that merely appears in a comment cannot satisfy this.
HOSTILE_ENV="$WORK/hostile-prelude.sh"
printf 'BD803_PRELUDE_RAN=yes\n' > "$HOSTILE_ENV"
# Enumerate separately (not inside the process substitution) so the grep's own exit
# status is visible rather than masked by the pipeline — SC2312. grep exits 1 for
# "no match" and 2 for a real error; only the latter is a broken enumeration, and
# the vacuity assertion below catches an empty-but-successful listing.
set +e
entry_list=$(cd "$ROOT" && /usr/bin/grep -rlE '^[[:space:]]*(\.|source)[[:space:]]+.*resolve-cli\.sh' --include='*.sh' skills scripts 2>/dev/null)
entry_rc=$?
set -e
if [[ "$entry_rc" -gt 1 ]]; then
  bad "#803: entry-point enumeration failed (grep rc=$entry_rc)"
fi
entry_list=$(/usr/bin/printf '%s\n' "$entry_list" | /usr/bin/sort)
while IFS= read -r entry; do
  [[ -n "$entry" ]] || continue
  case "$entry" in
    */lib/*) continue ;;
    *) ;;
  esac
  [[ -x "$ROOT/$entry" ]] || continue
  entry_seen=$((entry_seen + 1))
  shebang=$(/usr/bin/head -1 "$ROOT/$entry")
  probe="$WORK/probe-$entry_seen.sh"
  {
    printf '%s\n' "$shebang"
    # shellcheck disable=SC2016  # probe text: expanded by the probe, not here
    printf 'printf "FLAGS=%%s ENVSEEN=%%s\\n" "$-" "${BD803_PRELUDE_RAN:-no}"\n'
  } > "$probe"
  chmod 755 "$probe"
  set +e
  probe_out=$(BASH_ENV="$HOSTILE_ENV" env "BASH_FUNC_exec%%=() { :; }" "$probe" 2>/dev/null)
  set -e
  if [[ "$probe_out" == *FLAGS=*p* && "$probe_out" == *ENVSEEN=no* ]]; then
    ok "#803: entry point starts privileged at interpreter creation: $entry"
  else
    bad "#803: entry point NOT privileged before sourcing resolve-cli.sh: $entry (probe: ${probe_out:-<no output>})"
  fi
  # Privileged mode protects only the shell that has it: BASH_ENV/ENV stay in the
  # ENVIRONMENT and any unprivileged child re-processes them (measured: a child of a
  # privileged parent ran a BASH_ENV file containing `exit 0` and never executed its
  # own body). So each entry point must also scrub them. Probe carries the entry
  # point's real shebang plus its own scrub line lifted from the file — a missing or
  # renamed scrub produces no scrub line and the child then sees the prelude.
  scrub_line=$(/usr/bin/grep -m1 '^unset BASH_ENV' "$ROOT/$entry" || true)
  childprobe="$WORK/childprobe-$entry_seen.sh"
  {
    printf '%s\n' "$shebang"
    printf '%s\n' "$scrub_line"
    # shellcheck disable=SC2016  # probe text: expanded by the probe, not here
    printf 'bash -c '\''printf "CHILDSEEN=%%s\\n" "${BD803_PRELUDE_RAN:-no}"'\''\n'
  } > "$childprobe"
  chmod 755 "$childprobe"
  set +e
  child_out=$(BASH_ENV="$HOSTILE_ENV" "$childprobe" 2>/dev/null)
  set -e
  if [[ "$child_out" == *CHILDSEEN=no* ]]; then
    ok "#803: entry point scrubs BASH_ENV so children start clean: $entry"
  else
    bad "#803: entry point leaks BASH_ENV to children: $entry (probe: ${child_out:-<no output>})"
  fi
done <<< "$entry_list"
# The hardened entry points are PINNED here, deliberately, not discovered.
# Discovering them by searching for the hardening marker is circular: removing the
# block from a script also removes it from the list, so the assertions below would
# still pass on a smaller set. A pinned list makes that removal a FAILURE, which is
# the whole point. It does mean a newly hardened entry point must be added here — the
# cross-check below fails loudly when one carries the marker but is missing from the
# list, so the omission surfaces rather than silently narrowing coverage.
BD803_ENTRY_POINTS="skills/blueprint-review/scripts/run-design-review-loop.sh
skills/blueprint-review/scripts/init-design-review.sh
skills/litmus/scripts/run-review-loop.sh
skills/litmus/scripts/init-review-loop.sh
scripts/ci/run-shell-tests.sh"
hardened_list="$BD803_ENTRY_POINTS"
# `grep | sort` would report SORT's status, so run grep on its own first.
set +e
marked_raw=$(cd "$ROOT" && /usr/bin/grep -rl 'BD803-CLEAN-ENV-BEGIN' --include='*.sh' skills scripts 2>/dev/null)
marked_rc=$?
set -e
if [[ "$marked_rc" -gt 1 ]]; then
  bad "#803: hardened-entry-point cross-check failed (grep rc=$marked_rc)"
fi
marked_list=$(/usr/bin/printf '%s\n' "$marked_raw" | /usr/bin/sort)
expected_list=$(/usr/bin/printf '%s\n' "$BD803_ENTRY_POINTS" | /usr/bin/sort)
if [[ "$marked_list" == "$expected_list" ]]; then
  ok "#803: hardened entry points match the pinned list exactly"
else
  bad "#803: hardened-entry-point drift — a script gained or lost the rebuild block:"$'\n'"pinned:"$'\n'"$expected_list"$'\n'"on disk:"$'\n'"$marked_list"
fi

# #803: BASH_FUNC_* entries cannot be removed with `unset` -- their names are not
# valid identifiers and the environ entry survives (measured) -- so a privileged entry
# point that merely ignores them still hands them to every descendant, including a
# plain `#!/bin/bash` helper reached through a sourced library (load_changelog.sh,
# ultra_oracle_attach_preflight.sh). Each entry point therefore rebuilds its
# environment once via `env -u`. Behavioural and TRANSITIVE: lift the real
# BD803-CLEAN-ENV block out of each entry point, run a plain-shebang helper behind it,
# and require that helper not to import a forged BASH_FUNC_python3. A deleted or
# renamed block yields no block and the helper imports the forgery.
DOWNSTREAM="$WORK/downstream-helper.sh"
# shellcheck disable=SC2016  # probe text: expanded by the probe, not here
printf '#!/bin/bash\n[ "$(type -t python3 2>/dev/null)" = function ] && echo IMPORTED_FORGERY || echo downstream_clean\n' > "$DOWNSTREAM"
chmod 755 "$DOWNSTREAM"
transitive_bad=""
while IFS= read -r _ep; do
  [[ -n "$_ep" ]] || continue
  # dispatch.sh is deliberately absent: it already re-execs behind a nonce+sentinel
  # proof that ABORTS on an inherited forged sentinel, and every child it launches is
  # `env -i`, so it has no plain-shebang descendant to protect. Adding the rebuild
  # there also broke that proof — the strip removed the sentinel the proof consumes,
  # and re-execing without the nonce marker re-armed it forever (measured: a hang).
  [[ -f "$ROOT/$_ep" ]] || continue
  _blk=$(/usr/bin/sed -n '/BD803-CLEAN-ENV-BEGIN/,/BD803-CLEAN-ENV-END/p' "$ROOT/$_ep")
  _probe="$WORK/transitive-$(/usr/bin/basename "$_ep")"
  {
    /usr/bin/head -1 "$ROOT/$_ep"
    printf '%s\n' "$_blk"
    # shellcheck disable=SC2016  # probe text: expanded by the probe, not here
    printf '"$1"\n'
  } > "$_probe"
  chmod 755 "$_probe"
  set +e
  _out=$(env "BASH_FUNC_python3%%=() { printf FORGED\n; }" "$_probe" "$DOWNSTREAM" 2>/dev/null)
  set -e
  [[ "$_out" == *downstream_clean* ]] || transitive_bad="${transitive_bad}${_ep} -> ${_out:-<no output>}"$'\n'
done <<< "$hardened_list"
if [[ -z "$transitive_bad" ]]; then
  ok "#803: entry points rebuild the environment so plain-shebang descendants stay clean"
else
  bad "#803: descendant imported a forged BASH_FUNC_python3:"$'\n'"$transitive_bad"
fi

# #803: env-list parsing must not depend on a writable TMPDIR here-string temporary.
# An unwritable TMPDIR that broke `<<<` used to leave `_bd803_envclean` empty — the
# same shape as "nothing to strip" — and skip the scrub (fail-open). In-process
# split closes that class; this asserts the scrub still reaches the descendant.
tmpdir_bad=""
BADTMP=$(mktemp -d "$WORK/badtmp.XXXXXX")
chmod 000 "$BADTMP"
while IFS= read -r _ep; do
  [[ -n "$_ep" ]] || continue
  [[ -f "$ROOT/$_ep" ]] || continue
  _blk=$(/usr/bin/sed -n '/BD803-CLEAN-ENV-BEGIN/,/BD803-CLEAN-ENV-END/p' "$ROOT/$_ep")
  _probe="$WORK/tmpdir-$(/usr/bin/basename "$_ep")"
  {
    /usr/bin/head -1 "$ROOT/$_ep"
    printf '%s\n' "$_blk"
    # shellcheck disable=SC2016  # probe text: expanded by the probe, not here
    printf '"$1"\n'
  } > "$_probe"
  chmod 755 "$_probe"
  set +e
  _out=$(env TMPDIR="$BADTMP" "BASH_FUNC_python3%%=() { printf FORGED\n; }" "$_probe" "$DOWNSTREAM" 2>/dev/null)
  set -e
  [[ "$_out" == *downstream_clean* ]] || tmpdir_bad="${tmpdir_bad}${_ep} -> ${_out:-<no output>}"$'\n'
done <<< "$hardened_list"
chmod 755 "$BADTMP"
if [[ -z "$tmpdir_bad" ]]; then
  ok "#803: clean-env scrub survives an unwritable TMPDIR (no here-string fail-open)"
else
  bad "#803: unwritable TMPDIR let a forged BASH_FUNC reach a descendant:"$'\n'"$tmpdir_bad"
fi

# #803: the library refuses to install its own EXIT trap when the sourcing script
# already owns one (replacing it would drop the caller's cleanup), so a caller that
# owns EXIT must COMPOSE _bd803_cleanup_review_lib_exec into its handler or the
# ~250KB staged copy is left in TMPDIR on every run and accumulates without bound.
# Behavioural: stage under a composing caller and require the copy to be gone.
# PRODUCTION ORDER matters here: dispatch.sh and run-shell-tests.sh source the library
# BEFORE installing their own EXIT trap, so the library registers its cleanup and the
# caller then overwrites it — the composing-caller case below would pass while those
# two still leaked. Model that order explicitly.
ORDER_T="$WORK/order-caller.sh"
{
  printf '#!/bin/bash -p\n'
  # shellcheck disable=SC2016  # expanded by the probe, not here
  printf '. "$1" >/dev/null 2>&1\n_bd803_ensure_staged_lib >/dev/null 2>&1\n'
  printf 'trap %s _bd803_cleanup_review_lib_exec >/dev/null && _bd803_cleanup_review_lib_exec || true%s EXIT\n' "'declare -F" "'"
  # shellcheck disable=SC2016  # expanded by the probe, not here
  printf 'printf "STAGED_DURING=%%s\\n" "${_BD803_REVIEW_LIB_STAGED:-none}"\n'
} > "$ORDER_T"
chmod 755 "$ORDER_T"
set +e
order_out=$("$ORDER_T" "$LIB" 2>/dev/null)
set -e
order_path=${order_out#STAGED_DURING=}
if [[ -n "$order_path" && "$order_path" != none && ! -e "$order_path" ]]; then
  ok "#803: source-then-trap caller (dispatch.sh / run-shell-tests.sh order) leaves no staged lib"
else
  bad "#803: source-then-trap caller leaked the staged lib: '${order_path:-<none staged>}'"
fi

COMPOSE_T="$WORK/compose-caller.sh"
{
  printf '#!/bin/bash -p\n'
  printf 'trap %s _bd803_cleanup_review_lib_exec >/dev/null && _bd803_cleanup_review_lib_exec || true%s EXIT\n' "'declare -F" "'"
  # shellcheck disable=SC2016  # expanded by the probe, not here
  printf '. "$1" >/dev/null 2>&1\n_bd803_ensure_staged_lib >/dev/null 2>&1\n'
  # shellcheck disable=SC2016  # expanded by the probe, not here
  printf 'printf "STAGED_DURING=%%s\\n" "${_BD803_REVIEW_LIB_STAGED:-none}"\n'
} > "$COMPOSE_T"
chmod 755 "$COMPOSE_T"
set +e
compose_out=$("$COMPOSE_T" "$LIB" 2>/dev/null)
set -e
compose_path=${compose_out#STAGED_DURING=}
if [[ -n "$compose_path" && "$compose_path" != none && ! -e "$compose_path" ]]; then
  ok "#803: composing caller cleans the staged lib on exit (no TMPDIR accumulation)"
else
  bad "#803: staged lib survived a composing caller's exit: '${compose_path:-<none staged>}'"
fi

# #803: the blueprint-review entry points install NO EXIT trap of their own, so the
# library's own trap is the one that fires. That is the third caller shape (the two
# above cover source-then-trap and compose); assert it directly rather than reasoning
# about it, because "no trap anywhere" and "trap replaced" look identical from outside.
BARE_T="$WORK/bare-caller.sh"
{
  printf '#!/bin/bash -p\n'
  # shellcheck disable=SC2016  # expanded by the probe, not here
  printf '. "$1" >/dev/null 2>&1\n_bd803_ensure_staged_lib >/dev/null 2>&1\n'
  # shellcheck disable=SC2016  # expanded by the probe, not here
  printf 'printf "STAGED_DURING=%%s\\n" "${_BD803_REVIEW_LIB_STAGED:-none}"\n'
} > "$BARE_T"
chmod 755 "$BARE_T"
set +e
bare_out=$("$BARE_T" "$LIB" 2>/dev/null)
set -e
bare_path=${bare_out#STAGED_DURING=}
if [[ -n "$bare_path" && "$bare_path" != none && ! -e "$bare_path" ]]; then
  ok "#803: trapless caller (blueprint-review shape) leaves no staged lib"
else
  bad "#803: trapless caller leaked the staged lib: '${bare_path:-<none staged>}'"
fi

# #803: the clean-env rebuild is duplicated verbatim across every hardened entry
# point, and the marker-drift check above only proves each one HAS a block — not that
# they are the same block. A fix applied to four of five is the likely failure, and it
# is invisible from any per-file assertion, so compare the extracted bodies byte for
# byte against the first.
block_ref=""
block_ref_file=""
block_bad=""
block_seen=0
while IFS= read -r entry; do
  [[ -n "$entry" ]] || continue
  [[ -f "$ROOT/$entry" ]] || continue
  _blk=$(/usr/bin/sed -n '/# BD803-CLEAN-ENV-BEGIN/,/# BD803-CLEAN-ENV-END/p' "$ROOT/$entry")
  [[ -n "$_blk" ]] || { block_bad="${block_bad}${entry}: no block extracted"$'\n'; continue; }
  block_seen=$((block_seen + 1))
  if [[ -z "$block_ref" ]]; then
    block_ref="$_blk"; block_ref_file="$entry"
  elif [[ "$_blk" != "$block_ref" ]]; then
    block_bad="${block_bad}${entry}: differs from ${block_ref_file}"$'\n'
  fi
done <<< "$hardened_list"
if [[ -n "$block_bad" ]]; then
  bad "#803: clean-env rebuild block drifted between entry points:"$'\n'"$block_bad"
elif [[ "$block_seen" -lt 5 ]]; then
  bad "#803: clean-env block comparison is vacuous — extracted only $block_seen block(s)"
else
  ok "#803: clean-env rebuild block is byte-identical across $block_seen entry points"
fi

# #803: `env` output is NOT one line per variable. A value carrying an embedded
# newline followed by `BASH_FUNC_x%%=...` renders as its own line, so a newline parse
# derives a name that no variable owns; `env -u` then strips nothing, the carrier
# survives the exec, and the child re-detects the same phantom — an unbounded exec
# loop, armed by one ordinary variable, by exactly the attacker this block distrusts
# (measured: hung indefinitely before the NUL parse landed).
# Probed against the block extracted from a real entry point, so the assertion tracks
# the shipped code. The positive controls are load-bearing: a block that refused
# EVERYTHING would satisfy the hang check alone.
ENVP="$WORK/cleanenv-probe.sh"
{
  printf '#!/bin/bash -p\n'
  /usr/bin/sed -n '/# BD803-CLEAN-ENV-BEGIN/,/# BD803-CLEAN-ENV-END/p' "$ROOT/scripts/ci/run-shell-tests.sh"
  # shellcheck disable=SC2016  # expanded by the probe, not here
  # Count entries, not lines: map real newlines out of the way FIRST, then turn the
  # NUL delimiters into newlines. `tr "\0" "\n"` alone reproduces the very phantom
  # this probe exists to disprove — a carrier value's embedded newline would be
  # counted as a BASH_FUNC_ entry that no variable owns.
  # shellcheck disable=SC2016  # expanded by the probe, not here
  printf 'printf "BODY funcs=%%s\\n" "$(/usr/bin/env -0 | /usr/bin/tr "\\n" "\\001" | /usr/bin/tr "\\0" "\\n" | /usr/bin/grep -c "^BASH_FUNC_")"\n'
} > "$ENVP"
chmod 755 "$ENVP"
# No portable `timeout` on macOS, so bound the wall clock by hand: background it,
# poll, and kill. A surviving process IS the finding.
_envprobe() {
  _ep_out="$WORK/envprobe.out"
  : > "$_ep_out"
  ( "$@" > "$_ep_out" 2>/dev/null ) &
  _ep_pid=$!
  _ep_i=0
  while [[ "$_ep_i" -lt 40 ]] && kill -0 "$_ep_pid" 2>/dev/null; do
    /bin/sleep 0.2
    _ep_i=$((_ep_i + 1))
  done
  if kill -0 "$_ep_pid" 2>/dev/null; then
    kill -9 "$_ep_pid" 2>/dev/null || true
    wait "$_ep_pid" 2>/dev/null || true
    /usr/bin/printf 'HUNG\n'
  else
    wait "$_ep_pid" 2>/dev/null || true
    /bin/cat "$_ep_out"
  fi
}
env_bad=""
_r=$(_envprobe /usr/bin/env -i PATH=/usr/bin:/bin "$ENVP")
[[ "$_r" == "BODY funcs=0" ]] || env_bad="${env_bad}clean env -> '$_r'"$'\n'
_r=$(_envprobe /usr/bin/env -i PATH=/usr/bin:/bin 'BASH_FUNC_bd803probe%%=() { :; }' "$ENVP")
[[ "$_r" == "BODY funcs=0" ]] || env_bad="${env_bad}real BASH_FUNC shadow -> '$_r'"$'\n'
_r=$(_envprobe /usr/bin/env -i PATH=/usr/bin:/bin 'BD803EVIL=x
BASH_FUNC_bd803phantom%%=() { :; }' "$ENVP")
[[ "$_r" == "BODY funcs=0" ]] || env_bad="${env_bad}phantom newline -> '$_r'"$'\n'
_r=$(_envprobe /usr/bin/env -i PATH=/usr/bin:/bin 'BD803EVIL=x
BASH_FUNC_bd803phantom%%=() { :; }' 'BASH_FUNC_bd803probe%%=() { :; }' "$ENVP")
[[ "$_r" == "BODY funcs=0" ]] || env_bad="${env_bad}phantom + real shadow -> '$_r'"$'\n'
if [[ -z "$env_bad" ]]; then
  ok "#803: clean-env rebuild strips real shadows and cannot be looped by a phantom entry"
else
  bad "#803: clean-env rebuild misbehaved (expected 'BODY funcs=0' each time):"$'\n'"$env_bad"
fi

# #803: the shebang must pin an ABSOLUTE interpreter. `#!/usr/bin/env -S bash -p`
# still resolves bash through the ambient PATH, so a hostile PATH picks the
# interpreter before privileged mode or the environment rebuild can start — the entry
# boundary would be decided by the thing it exists to distrust.
# Generated from the SAME enumeration as the assertions above, so a newly added entry
# point is covered on arrival rather than needing this list edited. dispatch.sh is the
# one documented exception: its pi lane requires bash 4+, which on macOS only PATH
# resolution supplies (/bin/bash is 3.2), and its own nonce+sentinel proof plus
# `env -i` children bound the residual.
# The `/env` match tolerates any whitespace run (a tab after `#!/usr/bin/env` is the
# same defect as a space), so a reformat cannot slip an env-resolved shebang through.
shebang_bad=""
shebang_seen=0
while IFS= read -r entry; do
  [[ -n "$entry" ]] || continue
  case "$entry" in
    */lib/*) continue ;;
    skills/dispatch-cli/scripts/dispatch.sh) continue ;;
    *) ;;
  esac
  [[ -x "$ROOT/$entry" ]] || continue
  shebang_seen=$((shebang_seen + 1))
  _sb=$(/usr/bin/head -1 "$ROOT/$entry")
  if [[ "$_sb" == '#!/'* ]] && ! /usr/bin/printf '%s' "$_sb" | /usr/bin/grep -qE '/env[[:space:]]'; then
    :
  else
    shebang_bad="${shebang_bad}${entry}: ${_sb}"$'\n'
  fi
done <<< "$hardened_list"
if [[ -z "$shebang_bad" && "$shebang_seen" -ge 4 ]]; then
  ok "#803: entry-point shebangs pin an absolute interpreter ($shebang_seen checked)"
elif [[ "$shebang_seen" -lt 2 ]]; then
  bad "#803: shebang enumeration collapsed (found $shebang_seen) — the assertion is vacuous"
else
  bad "#803: entry point resolves its interpreter through PATH:"$'\n'"$shebang_bad"
fi

# #803: the shebang is not the only place an interpreter gets chosen. `bash -p foo.sh`
# runs the FIRST `bash` on PATH — a script's own `#!/bin/bash -p` is never consulted
# when bash is invoked explicitly — so a bare `bash -p` inside a hardened script hands
# the entry boundary back to the very PATH it exists to distrust, and a block message
# printing that form propagates the defect to whoever pastes it. Every invocation and
# every printed hint must name the interpreter absolutely. Comment lines are skipped:
# they describe the shape, they do not execute it.
set +e
pathbash_raw=$(cd "$ROOT" && /usr/bin/grep -rnE '(^|[^/[:alnum:]_-])bash[[:space:]]+-p[[:space:]]' \
  --include='*.sh' --include='*.yml' skills scripts hooks .github 2>/dev/null)
pathbash_rc=$?
pathbash_pinned=$(cd "$ROOT" && /usr/bin/grep -rnE '/bin/bash[[:space:]]+-p[[:space:]]' \
  --include='*.sh' --include='*.yml' skills scripts hooks .github 2>/dev/null | /usr/bin/grep -cvE ':[[:space:]]*#')
set -e
if [[ "$pathbash_rc" -gt 1 ]]; then
  bad "#803: PATH-bash scan failed (grep rc=$pathbash_rc)"
fi
pathbash_bad=""
while IFS= read -r hit; do
  [[ -n "$hit" ]] || continue
  _pb_body=${hit#*:}
  _pb_body=${_pb_body#*:}
  case "${_pb_body#"${_pb_body%%[![:space:]]*}"}" in
    '#'*) continue ;;
  esac
  pathbash_bad="${pathbash_bad}${hit}"$'\n'
done <<< "$pathbash_raw"
if [[ -n "$pathbash_bad" ]]; then
  bad "#803: PATH-resolved bash invocation — a hostile PATH picks the interpreter:"$'\n'"$pathbash_bad"
elif [[ "$pathbash_pinned" -lt 20 ]]; then
  bad "#803: PATH-bash scan is vacuous — only $pathbash_pinned pinned '/bin/bash -p' forms found"
else
  ok "#803: every bash -p form names an absolute interpreter ($pathbash_pinned pinned)"
fi

# A silently empty enumeration would make the loop above vacuously green.
if [[ "$entry_seen" -ge 2 ]]; then
  ok "#803: entry-point enumeration found $entry_seen executables to check"
else
  bad "#803: entry-point enumeration collapsed (found $entry_seen) — the privilege assertions are vacuous"
fi


REPO="$WORK/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q -b main
git -C "$REPO" config user.email t@example.com
git -C "$REPO" config user.name Test
echo base > "$REPO/f.txt"
git -C "$REPO" add f.txt
git -C "$REPO" commit -qm base

mkdir -p "$REPO/bin"
printf '#!/bin/sh\necho FORGED_PASS\n' > "$REPO/bin/codex"
chmod +x "$REPO/bin/codex"

EXT=$(mktemp -d "$WORK/ext.XXXXXX")
printf '#!/bin/sh\necho REAL\n' > "$EXT/codex"
chmod +x "$EXT/codex"

DROID_EXT=$(mktemp -d "$WORK/droid-ext.XXXXXX")
printf '#!/bin/sh\necho REAL_DROID\n' > "$DROID_EXT/droid"
chmod +x "$DROID_EXT/droid"



LINKDIR=$(mktemp -d "$WORK/link.XXXXXX")
ln -s "$REPO/bin/codex" "$LINKDIR/codex"

run_avail() {
  local path="$1"
  ( cd "$REPO" && PATH="$path" bash -c ". \"$LIB\" >/dev/null 2>&1; is_trusted_review_cli_available codex" )
}

set +e
run_avail "$REPO/bin:/usr/bin:/bin"
rc=$?
set -e
if [[ "$rc" -ne 0 ]]; then ok "in-checkout planted codex is not available"; else bad "in-checkout planted codex was treated as available"; fi

set +e
run_avail "$EXT:/usr/bin:/bin"
rc=$?
set -e
if [[ "$rc" -eq 0 ]]; then ok "external mktemp stub remains available"; else bad "external mktemp stub was refused"; fi

set +e
run_avail "$LINKDIR:/usr/bin:/bin"
rc=$?
set -e
if [[ "$rc" -ne 0 ]]; then ok "outside symlink into the checkout is not available"; else bad "outside symlink into the checkout was treated as available"; fi

resolved=$(
  cd "$REPO" && PATH="$REPO/bin:/usr/bin:/bin" BUSDRIVER_REVIEW_CLI=codex \
    bash -c ". \"$LIB\" >/dev/null 2>&1; resolve_review_cli"
)
if [[ "$resolved" == "missing:codex" ]]; then ok "BUSDRIVER_REVIEW_CLI=codex with planted binary yields missing:codex"; else bad "expected missing:codex, got '$resolved'"; fi

pinned=$(
  cd "$REPO" && PATH="$EXT:$REPO/bin:/usr/bin:/bin" \
    bash -c ". \"$LIB\" >/dev/null 2>&1; _resolve_trusted_cli_bin codex"
)
ext_phys=""
ext_phys="$(CDPATH='' cd -P -- "$EXT" 2>/dev/null && pwd -P)" || ext_phys=""
want="${ext_phys}/codex"
if [[ "$pinned" == "$want" ]]; then ok "trusted resolver returns the external absolute path, not the planted one"; else bad "expected pinned=$want, got '$pinned'"; fi

# #803: opencode availability must use the SAME fixed trusted PATH as dispatch
# (<trusted-home>/.opencode/bin + .local/bin + system dirs), not ambient PATH.
# Checkout-planted and arbitrary-external installs are refused; only a stub under
# a mocked trusted home is accepted. Symlink-into-checkout remains refused.
# Negatives mock an EMPTY trusted home so a real operator install cannot make them
# vacuously green; the positive case plants under a separate mocked home.
printf '#!/bin/sh\necho FORGED_OPENCODE\n' > "$REPO/bin/opencode"
chmod +x "$REPO/bin/opencode"
OC_EXT=$(mktemp -d "$WORK/oc-ext.XXXXXX")
printf '#!/bin/sh\necho ARBITRARY_EXTERNAL\n' > "$OC_EXT/opencode"
chmod +x "$OC_EXT/opencode"
OC_LINK=$(mktemp -d "$WORK/oc-link.XXXXXX")
ln -s "$REPO/bin/opencode" "$OC_LINK/opencode"
OC_HOME=$(mktemp -d "$WORK/oc-home.XXXXXX")
OC_EMPTY=$(mktemp -d "$WORK/oc-empty.XXXXXX")
mkdir -p "$OC_HOME/.opencode/bin"
printf '#!/bin/sh\necho TRUSTED_HOME_OPENCODE\n' > "$OC_HOME/.opencode/bin/opencode"
chmod +x "$OC_HOME/.opencode/bin/opencode"
run_avail_oc() {
  # $1=PATH $2=mocked trusted home
  # shellcheck disable=SC2016
  ( cd "$REPO" && PATH="$1" OC_HOME="$2" LIB="$LIB" bash -c '
    . "$LIB" >/dev/null 2>&1
    _trusted_operator_home() { printf "%s\n" "$OC_HOME"; }
    is_trusted_review_cli_available opencode
  ' )
}
set +e
run_avail_oc "$REPO/bin:/usr/bin:/bin" "$OC_EMPTY"; oc_planted=$?
run_avail_oc "$OC_EXT:/usr/bin:/bin" "$OC_EMPTY"; oc_ext=$?
run_avail_oc "$OC_LINK:/usr/bin:/bin" "$OC_EMPTY"; oc_link=$?
run_avail_oc "/usr/bin:/bin" "$OC_HOME"; oc_home=$?
set -e
if [[ "$oc_planted" -ne 0 && "$oc_ext" -ne 0 && "$oc_link" -ne 0 && "$oc_home" -eq 0 ]]; then
  ok "#803: opencode availability matches dispatch PATH (planted/arbitrary/symlink refused, trusted-home accepted)"
else
  bad "#803: opencode trusted-home PATH wrong: planted=$oc_planted ext=$oc_ext link=$oc_link home=$oc_home (want !=0,!=0,!=0,0)"
fi

printf '#!/bin/sh\necho PLANTED_TIMEOUT\n' > "$REPO/bin/timeout"
chmod +x "$REPO/bin/timeout"
to_out=$(
  cd "$REPO" && PATH="$REPO/bin:/usr/bin:/bin" \
    bash -c ". \"$LIB\" >/dev/null 2>&1; _portable_timeout 1 /bin/echo SAFE"
)
if [[ "$to_out" == *PLANTED_TIMEOUT* ]]; then
  bad "checkout-planted timeout wrapped the review command"
elif [[ "$to_out" == *SAFE* ]]; then
  ok "portable timeout ignores checkout-planted timeout wrapper"
else
  bad "portable timeout produced neither SAFE nor PLANTED_TIMEOUT: '$to_out'"
fi


# Empty PATH component is CWD for shell lookup — plant ./codex at checkout root.
cp "$REPO/bin/codex" "$REPO/codex"
set +e
run_avail ":$EXT:/usr/bin:/bin"
rc=$?
set -e
if [[ "$rc" -ne 0 ]]; then
  ok "empty PATH component (CWD) with planted ./codex is not available"
else
  bad "empty PATH component skipped planted CWD codex and blessed an external binary"
fi

# Shim dir on PATH resolves to a different physical bindir — dispatch PATH must
# still include the outside-checkout shim dir so bare `codex` remains findable
# (companion lookup), without using $HOME.
PHYS=$(mktemp -d "$WORK/phys.XXXXXX")
SHIM=$(mktemp -d "$WORK/shim.XXXXXX")
printf '#!/bin/sh\necho REAL_PHYS\n' > "$PHYS/codex.js"
chmod +x "$PHYS/codex.js"
ln -s "$PHYS/codex.js" "$SHIM/codex"
disp=$(
  cd "$REPO" && PATH="$SHIM:$REPO/bin:/usr/bin:/bin" \
    bash -c ". \"$LIB\" >/dev/null 2>&1; b=\$(_resolve_trusted_cli_bin codex) || exit 2; _review_dispatch_path \"\$b\" codex"
)
shim_phys="$(CDPATH='' cd -P -- "$SHIM" 2>/dev/null && pwd -P)"
phys_dir="$(CDPATH='' cd -P -- "$PHYS" 2>/dev/null && pwd -P)"
want_phys="${phys_dir}/codex.js"
pinned_shim=$(
  cd "$REPO" && PATH="$SHIM:$REPO/bin:/usr/bin:/bin" \
    bash -c ". \"$LIB\" >/dev/null 2>&1; _resolve_trusted_cli_bin codex"
)
if [[ "$pinned_shim" == "$want_phys" ]] \
  && [[ ":$disp:" == *":$shim_phys:"* ]] \
  && [[ ":$disp:" != *":$HOME:"* ]] \
  && [[ "$disp" != *"\$HOME"* ]]; then
  ok "dispatch PATH keeps outside-checkout shim dir for bare-name lookup"
else
  bad "shim launchdir missing or HOME leaked: pinned='$pinned_shim' want='$want_phys' disp='$disp' shim='$shim_phys'"
fi

# Checkout-planted shim to the same physical target must not put the checkout on DISP.
ln -sf "$PHYS/codex.js" "$REPO/bin/codex"
disp_plant=$(
  cd "$REPO" && PATH="$REPO/bin:$SHIM:/usr/bin:/bin" \
    bash -c ". \"$LIB\" >/dev/null 2>&1; b=\$(_resolve_trusted_cli_bin codex) || { echo REFUSED; exit 0; }; _review_dispatch_path \"\$b\" codex"
)
repo_phys="$(CDPATH='' cd -P -- "$REPO" 2>/dev/null && pwd -P)"
if [[ "$disp_plant" == "REFUSED" ]]; then
  ok "checkout-planted shim to external physical target is refused"
elif [[ ":$disp_plant:" == *":${repo_phys}/"* ]] || [[ ":$disp_plant:" == *":${repo_phys}:"* ]]; then
  bad "dispatch PATH included checkout after planted shim: '$disp_plant'"
else
  # Resolver may skip planted first hit if launchdir-in-checkout refuses — then
  # fall through to SHIM. Either refuse or external-only DISP is acceptable;
  # checkout must never appear.
  ok "checkout-planted shim does not place checkout on dispatch PATH"
fi

# Earlier PATH dir with a non-codex alias to the same physical target must not
# steal launchdir — only "$d/codex" counts.
ALIAS=$(mktemp -d "$WORK/alias.XXXXXX")
ln -s "$PHYS/codex.js" "$ALIAS/notcodex"
disp_alias=$(
  cd "$REPO" && PATH="$ALIAS:$SHIM:/usr/bin:/bin" \
    bash -c ". \"$LIB\" >/dev/null 2>&1; b=\$(_resolve_trusted_cli_bin codex) || exit 2; _review_dispatch_path \"\$b\" codex"
)
alias_phys="$(CDPATH='' cd -P -- "$ALIAS" 2>/dev/null && pwd -P)"
if [[ ":$disp_alias:" == *":$shim_phys:"* ]] && [[ ":$disp_alias:" != *":$alias_phys:"* ]]; then
  ok "launchdir ignores non-codex alias to the same physical target"
else
  bad "alias stole or omitted shim launchdir: disp='$disp_alias' shim='$shim_phys' alias='$alias_phys'"
fi


# Physical bindir decoy named `codex` must lose to the shim launchdir on DISP.
printf '#!/bin/sh\necho DECOY\n' > "$PHYS/codex"
chmod +x "$PHYS/codex"
found=$(
  cd "$REPO" && PATH="$SHIM:$REPO/bin:/usr/bin:/bin" \
    bash -c ". \"$LIB\" >/dev/null 2>&1; b=\$(_resolve_trusted_cli_bin codex) || exit 2; PATH=\$(_review_dispatch_path \"\$b\" codex) command -v codex"
)
shim_dir=""
shim_dir="$(CDPATH='' cd -P -- "$SHIM" 2>/dev/null && pwd -P)" || shim_dir=""
shim_codex="${shim_dir}/codex"
if [[ "$found" == "$shim_codex" ]]; then
  ok "dispatch PATH prefers shim launchdir over physical-bindir decoy codex"
else
  bad "decoy won bare-name lookup: found='$found' want='$shim_codex'"
fi

# --- (a) BASH_FUNC_local%% / BASH_FUNC_return%% must not bless in-checkout planted CLI ---
printf '#!/bin/sh\necho FORGED_PASS\n' > "$REPO/bin/codex"
chmod +x "$REPO/bin/codex"
rm -f "$REPO/bin/node"
set +e
shadow_out=$(
  cd "$REPO" && PATH="$REPO/bin:/usr/bin:/bin" \
    env 'BASH_FUNC_local%%=() { :; }' 'BASH_FUNC_return%%=() { :; }' \
    /bin/bash --norc -c ". \"$LIB\" >/dev/null 2>&1; out=\$(_resolve_trusted_cli_bin codex); rc=\$?; printf 'OUT=%s\nRC=%s\n' \"\$out\" \"\$rc\""
)
set -e
if [[ "$shadow_out" == OUT=/* ]] || [[ "$shadow_out" == *$'\nRC=0'* ]] || [[ "$shadow_out" == RC=0* ]]; then
  bad "BASH_FUNC shadow allowed planted codex: '$shadow_out'"
else
  ok "BASH_FUNC_local/return shadowing cannot make planted in-checkout codex available"
fi

# Litmus HIGH: BASH_FUNC must not collapse dispatch PATH into checkout CWD
set +e
poison_disp=$(
  cd "$REPO" && PATH="$SHIM:$REPO/bin:/usr/bin:/bin" \
    /usr/bin/env 'BASH_FUNC_local%%=() { :; }' 'BASH_FUNC_return%%=() { :; }' \
    /bin/bash --norc -c ". \"$LIB\" >/dev/null 2>&1; b=\$(_resolve_trusted_cli_bin codex) || exit 2; out=\$(_review_dispatch_path \"\$b\" codex); rc=\$?; printf 'OUT=%s\nRC=%s\n' \"\$out\" \"\$rc\""
)
set -e
repo_phys="$(CDPATH='' cd -P -- "$REPO" 2>/dev/null && pwd -P)"
if [[ "$poison_disp" == *"OUT=$repo_phys"* ]] || [[ "$poison_disp" == *"OUT=$REPO"* ]]; then
  bad "BASH_FUNC shadow made dispatch PATH include checkout: '$poison_disp'"
else
  ok "BASH_FUNC_local/return cannot collapse dispatch PATH into checkout"
fi

# --- (b) approved env-node shim with decoy node beside it ---
NODEDIR=$(mktemp -d "$WORK/node.XXXXXX")
printf '#!/bin/sh\necho TRUSTED_NODE\n' > "$NODEDIR/node"
chmod +x "$NODEDIR/node"
node_phys="$(CDPATH='' cd -P -- "$NODEDIR" 2>/dev/null && pwd -P)"

ENVPHYS=$(mktemp -d "$WORK/envphys.XXXXXX")
ENVSHIM=$(mktemp -d "$WORK/envshim.XXXXXX")
printf '%s\n' '#!/usr/bin/env node' 'console.log("ENVNODE")' > "$ENVPHYS/codex.js"
chmod +x "$ENVPHYS/codex.js"
ln -sf "$ENVPHYS/codex.js" "$ENVSHIM/codex"
printf '#!/bin/sh\necho PLANTED_NODE\n' > "$REPO/bin/node"
chmod +x "$REPO/bin/node"
ln -sf "$REPO/bin/node" "$ENVSHIM/node"

found_node=$(
  cd "$REPO" && PATH="$NODEDIR:$ENVSHIM:$REPO/bin:/usr/bin:/bin" \
    /bin/bash -c ". \"$LIB\" >/dev/null 2>&1; b=\$(_resolve_trusted_cli_bin codex) || exit 2; PATH=\$(_review_dispatch_path \"\$b\" codex) || exit 3; command -v node"
)
want_node="${node_phys}/node"
if [[ "$found_node" == "$want_node" ]]; then
  ok "env-node shim: validated nodedir beats decoy node beside approved shim"
else
  bad "env-node decoy node won: found='$found_node' want='$want_node'"
fi

# require-node / env-node fail-closed: absolute bash; inner PATH excludes system node dirs
set +e
disp_req=$(
  cd "$REPO" && \
    /bin/bash -c ". \"$LIB\" >/dev/null 2>&1; PATH=\"$ENVSHIM:$REPO/bin\"; b=\$(_resolve_trusted_cli_bin codex) || exit 2; _review_dispatch_path \"\$b\" codex require-node; echo DISP_RC=\$?"
)
set -e
if [[ "$disp_req" == *DISP_RC=1* ]]; then
  ok "require-node mode fails closed when validated node is absent"
else
  bad "require-node did not fail closed: '$disp_req'"
fi

set +e
disp_env=$(
  cd "$REPO" && \
    /bin/bash -c ". \"$LIB\" >/dev/null 2>&1; PATH=\"$ENVSHIM:$REPO/bin\"; b=\$(_resolve_trusted_cli_bin codex) || exit 2; _review_dispatch_path \"\$b\" codex; echo DISP_RC=\$?"
)
set -e
if [[ "$disp_env" == *DISP_RC=1* ]]; then
  ok "env-node shebang fails closed when validated node is absent"
else
  bad "env-node shebang did not fail closed: '$disp_env'"
fi

set +e
disp_shell=$(
  cd "$REPO" && \
    /bin/bash -c ". \"$LIB\" >/dev/null 2>&1; PATH=\"$SHIM:$REPO/bin\"; b=\$(_resolve_trusted_cli_bin codex) || exit 2; out=\$(_review_dispatch_path \"\$b\" codex); echo DISP_RC=\$?; printf 'DISP_OUT=%s\n' \"\$out\""
)
set -e
if [[ "$disp_shell" == *DISP_RC=0* ]] && [[ "$disp_shell" == *"$shim_phys"* ]]; then
  ok "shell/native shim dispatch succeeds without trusted node"
else
  bad "shell/native dispatch unexpectedly failed closed: '$disp_shell'"
fi

# Bare timed dispatch pins but must NOT scrub CODEX_HOME; --review must.
# shellcheck disable=SC2016
/usr/bin/printf '%s\n' '#!/bin/sh' 'printf "CHILD_CODEX_HOME=%s\n" "$CODEX_HOME"' > "$EXT/codex"
chmod +x "$EXT/codex"
# #803: inside a checkout, bare timed codex/agy/droid pin argv0 but keep
# ambient env (no env -i) so write-capable dispatch retains API keys / CODEX_HOME.
# Outside a checkout, ambient env is preserved as well.
bare_ck_out=$(
  cd "$REPO" && PATH="$EXT:/usr/bin:/bin" CODEX_HOME=/sentinel-codex-home \
    /bin/bash --norc -c ". \"$LIB\" >/dev/null 2>&1; _portable_timeout 2 codex"
)
if [[ "$bare_ck_out" == *CHILD_CODEX_HOME=/sentinel-codex-home* ]]; then
  ok "bare timeout inside checkout preserves CODEX_HOME"
else
  bad "bare timeout inside checkout scrubbed CODEX_HOME: '$bare_ck_out'"
fi
BARE_NONGIT="$WORK/bare-nongit"
mkdir -p "$BARE_NONGIT"
bare_out=$(
  cd "$BARE_NONGIT" && PATH="$EXT:/usr/bin:/bin" CODEX_HOME=/sentinel-codex-home \
    /bin/bash --norc -c ". \"$LIB\" >/dev/null 2>&1; _portable_timeout 2 codex"
)
if [[ "$bare_out" == *CHILD_CODEX_HOME=/sentinel-codex-home* ]]; then
  ok "bare timeout outside checkout preserves CODEX_HOME"
else
  bad "bare timeout outside checkout scrubbed CODEX_HOME: '$bare_out'"
fi
rev_out=$(
  cd "$REPO" && PATH="$EXT:/usr/bin:/bin" CODEX_HOME=/sentinel-codex-home \
    /bin/bash --norc -c ". \"$LIB\" >/dev/null 2>&1; _portable_timeout --review codex 2 codex"
)
if [[ "$rev_out" == *CHILD_CODEX_HOME=/sentinel-codex-home* ]]; then
  bad "--review did not scrub CODEX_HOME: '$rev_out'"
else
  ok "--review scrubs CODEX_HOME"
fi


# --- Litmus HIGH regressions (#789 out12) ---
# 1) --review must clear DYLD fallback/versioned loader vars
# shellcheck disable=SC2016
/usr/bin/printf '%s\n' '#!/bin/sh' \
  'printf "FB=%s\n" "${DYLD_FALLBACK_LIBRARY_PATH-<unset>}"' \
  'printf "VER=%s\n" "${DYLD_VERSIONED_LIBRARY_PATH-<unset>}"' > "$EXT/codex"
chmod +x "$EXT/codex"
loader_out=$(
  cd "$REPO" && PATH="$EXT:/usr/bin:/bin" \
    DYLD_FALLBACK_LIBRARY_PATH=/evil-fb DYLD_VERSIONED_LIBRARY_PATH=/evil-ver \
    /bin/bash --norc -c ". \"$LIB\" >/dev/null 2>&1; _portable_timeout --review codex 2 codex"
)
if [[ "$loader_out" == *'FB=<unset>'* || "$loader_out" == *'FB='*$'\n'* ]] && [[ "$loader_out" != *FB=/evil-fb* ]] \
   && [[ "$loader_out" != *VER=/evil-ver* ]]; then
  ok "--review scrubs DYLD fallback/versioned loader vars"
else
  # Empty string after scrub is also acceptable (exported empty)
  if [[ "$loader_out" == *FB=* && "$loader_out" != *FB=/evil-fb* && "$loader_out" != *VER=/evil-ver* ]]; then
    ok "--review scrubs DYLD fallback/versioned loader vars"
  else
    bad "--review leaked DYLD fallback/versioned vars: '$loader_out'"
  fi
fi

# 2) is_cli_available from non-Git directory uses ordinary PATH lookup
NONGIT="$WORK/nongit"
mkdir -p "$NONGIT"
printf '#!/bin/sh\necho ok\n' > "$NONGIT/codex"
chmod +x "$NONGIT/codex"
set +e
( cd "$NONGIT" && PATH="$NONGIT:/usr/bin:/bin" \
    /bin/bash --norc -c ". \"$LIB\" >/dev/null 2>&1; is_cli_available codex" )
nongit_rc=$?
set -e
if [[ "$nongit_rc" -eq 0 ]]; then
  ok "is_cli_available works from non-Git directory"
else
  bad "is_cli_available failed from non-Git directory (rc=$nongit_rc)"
fi

# 3) _resolve_trusted_cli_bin must not clear caller LD_PRELOAD
set +e
preload_out=$(
  cd "$REPO" && PATH="$EXT:/usr/bin:/bin" LD_PRELOAD=/sentinel-preload \
    /bin/bash --norc -c ". \"$LIB\" >/dev/null 2>&1; _resolve_trusted_cli_bin codex >/dev/null; printf 'LP=%s\n' \"\${LD_PRELOAD-<unset>}\""
)
preload_rc=$?
set -e
if [[ "$preload_rc" -eq 0 && "$preload_out" == *LP=/sentinel-preload* ]]; then
  ok "_resolve_trusted_cli_bin preserves caller LD_PRELOAD"
else
  bad "_resolve_trusted_cli_bin mutated LD_PRELOAD: rc=$preload_rc out='$preload_out'"
fi


# 4) --review scrubs GIT_EXTERNAL_DIFF / GIT_DIR
# shellcheck disable=SC2016
/usr/bin/printf '%s\n' '#!/bin/sh' \
  'printf "GD=%s\n" "${GIT_DIR-<unset>}"' \
  'printf "GE=%s\n" "${GIT_EXTERNAL_DIFF-<unset>}"' \
  'printf "NR=%s\n" "${GIT_NO_REPLACE_OBJECTS-<unset>}"' > "$EXT/codex"
chmod +x "$EXT/codex"
git_out=$(
  cd "$REPO" && PATH="$EXT:/usr/bin:/bin" \
    GIT_DIR=/evil-gitdir GIT_EXTERNAL_DIFF=/evil-diff \
    /bin/bash --norc -c ". \"$LIB\" >/dev/null 2>&1; _portable_timeout --review codex 2 codex"
)
if [[ "$git_out" != *GD=/evil-gitdir* && "$git_out" != *GE=/evil-diff* && "$git_out" == *NR=1* ]]; then
  ok "--review scrubs GIT_* and sets GIT_NO_REPLACE_OBJECTS=1"
else
  bad "--review leaked GIT_* or missed NO_REPLACE: '$git_out'"
fi

# 4b) --review must not inherit HTTPS_PROXY / SSL_CERT_FILE
# shellcheck disable=SC2016
/usr/bin/printf '%s\n' '#!/bin/sh' \
  'printf "PX=%s\n" "${HTTPS_PROXY-<unset>}"' \
  'printf "SC=%s\n" "${SSL_CERT_FILE-<unset>}"' > "$EXT/codex"
chmod +x "$EXT/codex"
proxy_out=$(
  cd "$REPO" && PATH="$EXT:/usr/bin:/bin" \
    HTTPS_PROXY=http://evil-proxy SSL_CERT_FILE=/evil-ca.pem \
    /bin/bash --norc -c ". \"$LIB\" >/dev/null 2>&1; _portable_timeout --review codex 2 codex"
)
if [[ "$proxy_out" != *PX=http://evil-proxy* && "$proxy_out" != *SC=/evil-ca.pem* ]]; then
  ok "--review drops HTTPS_PROXY and SSL_CERT_FILE"
else
  bad "--review leaked proxy/CA overrides: '$proxy_out'"
fi


# 5) ordinary is_cli_available still sees planted PATH entry (dispatch-cli mode)
set +e
( cd "$REPO" && PATH="$REPO/bin:/usr/bin:/bin" \
    /bin/bash --norc -c ". \"$LIB\" >/dev/null 2>&1; is_cli_available codex" )
ord_rc=$?
set -e
if [[ "$ord_rc" -eq 0 ]]; then
  ok "ordinary is_cli_available accepts PATH hit inside Git checkout"
else
  bad "ordinary is_cli_available unexpectedly refused PATH hit (rc=$ord_rc)"
fi


# 7) --review node keeps sanitized ambient PATH (companion dispatch)
# shellcheck disable=SC2016
/usr/bin/printf '%s\n' '#!/bin/sh' 'printf "PATH_HAS=%s\n" "$PATH"' > "$EXT/node"
chmod +x "$EXT/node"
node_out=$(
  cd "$REPO" && PATH="$EXT:/usr/bin:/bin" \
    /bin/bash --norc -c ". \"$LIB\" >/dev/null 2>&1; _portable_timeout --review node 2 \"$EXT/node\""
)
ext_phys="$(CDPATH='' cd -P -- "$EXT" 2>/dev/null && pwd -P)"
if [[ "$node_out" == *PATH_HAS="$ext_phys"* || "$node_out" == *"PATH_HAS=$ext_phys:"* ]]; then
  ok "--review node preserves sanitized ambient dispatch PATH"
else
  bad "--review node dropped ambient dispatch PATH: '$node_out'"
fi


# 8) PATH directory with metacharacters must not inject into phys_dir
EVIL="$WORK/evil;injected;dir"
mkdir -p "$EVIL"
printf '#!/bin/sh\necho EVIL\n' > "$EVIL/codex"
chmod +x "$EVIL/codex"
set +e
inj=$(
  cd "$REPO" && PATH="$EVIL:$EXT:/usr/bin:/bin" \
    /bin/bash --norc -c ". \"$LIB\" >/dev/null 2>&1; _resolve_trusted_cli_bin codex; echo RC=\$?"
)
set -e
if [[ "$inj" != *EVIL* ]] && { [[ "$inj" == *RC=0* ]] || [[ "$inj" == *RC=1* ]]; }; then
  ok "PATH dir with metacharacters cannot inject into review dispatch"
else
  bad "PATH metachar injection result: '$inj'"
fi


# 9) BASH_FUNC_local/return must not make --review node accept checkout PATH
printf '#!/bin/sh\necho FORGED_NODE\n' > "$REPO/bin/node"
chmod +x "$REPO/bin/node"
printf '#!/bin/sh\necho FORGED_CODEX\n' > "$REPO/bin/codex"
chmod +x "$REPO/bin/codex"
set +e
sarp_node=$(
  cd "$REPO" && PATH="$REPO/bin:$EXT:/usr/bin:/bin" \
    /usr/bin/env 'BASH_FUNC_local%%=() { raw=/; target=/; dir=/; phys=/; out=/; }' \
                 'BASH_FUNC_return%%=() { :; }' \
    /bin/bash --norc -c ". \"$LIB\" >/dev/null 2>&1; _portable_timeout --review node 2 \"$EXT/node\"; echo RC=\$?"
)
set -e
repo_phys="$(CDPATH='' cd -P -- "$REPO" 2>/dev/null && pwd -P)"
if [[ "$sarp_node" == *"$repo_phys"* ]] || [[ "$sarp_node" == *"$REPO/bin"* && "$sarp_node" == *FORGED* ]]; then
  bad "--review node accepted checkout PATH under BASH_FUNC poison: '$sarp_node'"
else
  ok "BASH_FUNC poison cannot force --review node onto checkout PATH"
fi

# 10) The SURGICAL BASH_FUNC_local shape that actually bypassed containment.
# Test 9's poison blanks every name at once, which fails CLOSED: the upstream
# phys_dir helper breaks first and the predicate refuses. The shape that bypassed
# performs every assignment EXCEPT the one naming `dir`, so upstream still works
# and only the containment input is emptied — the walk never runs and the trailing
# `return 1` reports "outside the checkout". RC=0 means IN-CHECKOUT (refused).
set +e
# shellcheck disable=SC2016 # the BASH_FUNC body is a literal passed to env, never expanded here
tcdic=$(
  cd "$REPO" && /usr/bin/env \
    'BASH_FUNC_local%%=() { for _a in "$@"; do case "$_a" in dir=*) dir= ;; *=*) eval "$_a" ;; esac; done; }' \
    /bin/bash --norc -c ". \"$LIB\" >/dev/null 2>&1; _trusted_cli_dir_in_checkout \"$REPO/bin\"; echo RC=\$?"
)
set -e
if [[ "$tcdic" == *RC=0* ]]; then
  ok "surgical BASH_FUNC_local cannot make the checkout look external"
else
  bad "containment predicate bypassed by surgical BASH_FUNC_local: '$tcdic'"
fi


# 11) The predicate physicalizes a FILE argument, which is what lets the
# trusted-directory `timeout` lookup reject a wrapper symlinked into the reviewed
# tree without searching ambient PATH. The symlink itself lives OUTSIDE the
# checkout, so only symlink resolution can catch it.
printf '#!/bin/sh\necho FORGED_TIMEOUT\n' > "$REPO/bin/timeout"
chmod +x "$REPO/bin/timeout"
ln -s "$REPO/bin/timeout" "$EXT/timeout"
set +e
tphys=$(
  cd "$REPO" && /bin/bash --norc -c ". \"$LIB\" >/dev/null 2>&1; _trusted_cli_dir_in_checkout \"$EXT/timeout\"; echo RC=\$?"
)
set -e
if [[ "$tphys" == *RC=0* ]]; then
  ok "outside symlink to an in-checkout file is refused by physicalization"
else
  bad "in-checkout symlink target accepted via an outside path: '$tphys'"
fi


# 12) ORDINARY agy dispatch must not inherit the review-only resolver's
# outside-a-checkout refusal. A 1.0.x agy on ambient PATH, probed from a non-Git
# directory, must be read as LEGACY (RC=1, stdin transport) with a CONCLUSIVE
# probe — not defaulted to argv because the trusted resolver declined to answer.
AGYDIR=$(mktemp -d "$WORK/agy.XXXXXX")
NONGIT=$(mktemp -d "$WORK/nongit.XXXXXX")
# shellcheck disable=SC2016 # $1 belongs to the generated stub script, not this shell
printf '#!/bin/sh\nif [ "$1" = "--version" ]; then echo 1.0.7; exit 0; fi\necho AGY\n' > "$AGYDIR/agy"
chmod +x "$AGYDIR/agy"
set +e
agy_ord=$(
  cd "$NONGIT" && PATH="$AGYDIR:/usr/bin:/bin" \
    /bin/bash --norc -c ". \"$LIB\" >/dev/null 2>&1; _agy_wants_argv_prompt; echo RC=\$? CONCLUSIVE=\$_AGY_PROBE_CONCLUSIVE"
)
set -e
if [[ "$agy_ord" == *"RC=1"* && "$agy_ord" == *"CONCLUSIVE=1"* ]]; then
  ok "ordinary agy probe outside a checkout reads the real version (stdin transport)"
else
  bad "ordinary agy probe outside a checkout: '$agy_ord'"
fi

# 13) A shadowed `return` must not turn a --review refusal into a launch. The
# refusal block calls `return 1`; with BASH_FUNC_return%% exported that call runs
# the ATTACKER's function — which can assign _pt_bin — and then falls THROUGH to
# the dispatch. Measured before the _pt_refuse latch: the refusal printed, the
# planted in-checkout codex executed, and the call returned 0.
set +e
ret_out=$(
  cd "$REPO" && PATH="$REPO/bin:/usr/bin:/bin" /usr/bin/env \
    "BASH_FUNC_return%%=() { _pt_bin=$REPO/bin/codex; }" \
    /bin/bash --norc -c ". \"$LIB\" >/dev/null 2>&1; _portable_timeout --review codex 2 codex --version; echo RC=\$?"
)
set -e
if [[ "$ret_out" != *FORGED_CODEX* && "$ret_out" == *"RC=1"* ]]; then
  ok "shadowed return cannot turn a --review refusal into a launch"
else
  bad "shadowed return produced a launch or a zero status: '$ret_out'"
fi

# 14) The shape that defeated the round-3 latch: the shadow `return` resets the
# GUARD variable as well as _pt_bin. Any parent-shell latch is writable by the very
# shadow it guards against — measured: refusal printed, planted codex executed,
# status 0. The refusal now has no latch to reset; it records a message and falls
# to an absolute /usr/bin/false, and _portable_timeout calls no shadowable builtin
# at all, so the shadow never runs inside it.
set +e
ret2=$(
  cd "$REPO" && PATH="$REPO/bin:/usr/bin:/bin" /usr/bin/env \
    "BASH_FUNC_return%%=() { _pt_refuse=0; _pt_err=; _pt_bin=$REPO/bin/codex; }" \
    /bin/bash --norc -c ". \"$LIB\" >/dev/null 2>&1; _portable_timeout --review codex 2 codex --version; echo RC=\$?"
)
set -e
if [[ "$ret2" != *FORGED_CODEX* && "$ret2" == *"RC=1"* ]]; then
  ok "shadowed return cannot reset refusal state and launch"
else
  bad "shadowed return defeated the refusal: '$ret2'"
fi


# 15) FORCE-ASSIGNMENT `local` poison. The shadow does not merely drop the
# assignment — it substitutes an attacker value (`target=/`, `home=/`), which is
# the shape that actually reddens: measured against the pre-fix bytes this printed
# "/" and exited 0, so `/` became $HOME for every --review launch and redirected
# companion-cache resolution with it. Assert the real password-DB home comes back:
# absolute, an existing directory, and NOT "/".
set +e
# shellcheck disable=SC2016 # the BASH_FUNC body is a literal passed to env
toh=$(
  cd "$REPO" && /usr/bin/env \
    'BASH_FUNC_local%%=() { for _a in "$@"; do case "$_a" in target=*) target=/ ;; home=*) home=/ ;; *=*) eval "$_a" ;; esac; done; }' \
    /bin/bash --norc -c ". \"$LIB\" >/dev/null 2>&1; _trusted_operator_home"
)
set -e
toh_first=$(/usr/bin/printf '%s\n' "$toh" | /usr/bin/head -1)
if [[ "$toh_first" == /* && "$toh_first" != "/" && -d "$toh_first" ]]; then
  ok "force-assignment local poison cannot redirect the trusted operator home"
else
  bad "operator home under force-assignment local poison: '$toh_first'"
fi

# 16) Exhausting the 32-hop symlink budget is UNRESOLVABLE, not "resolved to
# something outside". A chain longer than 32 that LIVES outside the checkout but
# TERMINATES inside it used to leave the path still symlinked, so the containment
# check examined the link chain's own (external) directory and accepted a planted
# in-checkout binary. Measured RC=1 (accepted) before the guard, RC=0 after.
CHAIN="$WORK/chain"
mkdir -p "$CHAIN"
ln -s "$REPO/bin/codex" "$CHAIN/l0"
i=1
while [[ "$i" -le 40 ]]; do ln -s "$CHAIN/l$((i-1))" "$CHAIN/l$i"; i=$((i+1)); done
set +e
sym=$(
  cd "$REPO" && /bin/bash --norc -c ". \"$LIB\" >/dev/null 2>&1; _trusted_cli_dir_in_checkout \"$CHAIN/l40\"; echo RC=\$?"
)
set -e
if [[ "$sym" == *"RC=0"* ]]; then
  ok "symlink chain past the hop budget fails closed (unresolvable is not outside)"
else
  bad "long symlink chain terminating in the checkout was accepted: '$sym'"
fi

# 17) A BASH_FUNC_local%% shadow can mark a variable READONLY, not merely assign
# it — a shape the earlier probes missed. Pinning _CODEX_COMPANION readonly to a
# checkout path made every later assignment in the resolver fail; _execute_codex
# calls that resolver BARE (its status is ignored) and hands the pinned path to
# trusted node as an ARGUMENT, which _portable_timeout's argv0 containment check
# does not cover. The resolver no longer calls `local`, so the shadow never fires.
printf 'console.log("FORGED_COMPANION");\n' > "$REPO/evil.mjs"
set +e
comp=$(
  cd "$REPO" && /usr/bin/env \
    "BASH_FUNC_local%%=() { readonly _CODEX_COMPANION=$REPO/evil.mjs 2>/dev/null; }" \
    /bin/bash --norc -c ". \"$LIB\" >/dev/null 2>&1; _resolve_codex_companion; echo GOT=\$_CODEX_COMPANION"
)
set -e
if [[ "$comp" != *"evil.mjs"* ]]; then
  ok "readonly-pinned local cannot force a checkout-controlled codex companion"
else
  bad "companion was pinned to a checkout-controlled script: '$comp'"
fi

# 18) #803: shadowed return must not turn _execute_codex refusal into a launch.
set +e
codex803=$(
  cd "$REPO" && PATH="$REPO/bin:/usr/bin:/bin" /usr/bin/env \
    "BASH_FUNC_return%%=() { :; }" \
    /bin/bash --norc -c ". \"$LIB\" >/dev/null 2>&1; _execute_codex 'probe prompt' 5 2>&1; echo RC=\$?"
)
set -e
if [[ "$codex803" != *FORGED_PASS* && "$codex803" == *"RC=1"* ]]; then
  ok "#803: _execute_codex refusal survives shadowed return"
else
  bad "#803: _execute_codex launched under shadowed return: '$codex803'"
fi

# 19) #803: execute_review agy arm must refuse in-checkout agy under shadowed return.
printf '#!/bin/sh\necho FORGED_AGY\n' > "$REPO/bin/agy"
chmod +x "$REPO/bin/agy"
set +e
agy803=$(
  cd "$REPO" && PATH="$REPO/bin:/usr/bin:/bin" /usr/bin/env \
    "BASH_FUNC_return%%=() { :; }" "BASH_FUNC_local%%=() { :; }" \
    /bin/bash --norc -c ". \"$LIB\" >/dev/null 2>&1; execute_review agy 'probe' 2 2>&1; echo RC=\$?"
)
set -e
if [[ "$agy803" != *FORGED_AGY* && "$agy803" == *"RC=1"* ]]; then
  ok "#803: execute_review agy refusal survives BASH_FUNC shadow"
else
  bad "#803: execute_review agy launched under shadow: '$agy803'"
fi

# 20) #803: execute_review droid arm must refuse in-checkout droid under shadowed return.
printf '#!/bin/sh\necho FORGED_DROID\n' > "$REPO/bin/droid"
chmod +x "$REPO/bin/droid"
set +e
droid803=$(
  cd "$REPO" && PATH="$REPO/bin:/usr/bin:/bin" /usr/bin/env \
    "BASH_FUNC_return%%=() { :; }" \
    /bin/bash --norc -c ". \"$LIB\" >/dev/null 2>&1; execute_review droid 'probe' 2 2>&1; echo RC=\$?"
)
set -e
if [[ "$droid803" != *FORGED_DROID* && "$droid803" == *"RC=1"* ]]; then
  ok "#803: execute_review droid refusal survives shadowed return"
else
  bad "#803: execute_review droid launched under shadow: '$droid803'"
fi

# 21) #803: should_escalate_to_droid must stay false for grok under shadowed return.
set +e
setd803=$(
  cd "$REPO" && /usr/bin/env "BASH_FUNC_return%%=() { :; }" \
    /bin/bash --norc -c ". \"$LIB\" >/dev/null 2>&1; should_escalate_to_droid grok 1 /dev/null; echo RC=\$?"
)
set -e
if [[ "$setd803" == *"RC=1"* ]]; then
  ok "#803: should_escalate_to_droid grok stays false under shadowed return"
else
  bad "#803: should_escalate_to_droid grok escalated under shadow: '$setd803'"
fi

# 22) #803: clean should_escalate_to_droid behavior intact (codex timeout still escalates).
set +e
setd_clean=$(
  cd "$REPO" && PATH="$DROID_EXT:/usr/bin:/bin:/usr/sbin:/sbin" /bin/bash --norc -c ". \"$LIB\" >/dev/null 2>&1; should_escalate_to_droid codex 124 /dev/null; echo RC=\$?"
)
set -e
if [[ "$setd_clean" == *"RC=0"* ]]; then
  ok "#803: should_escalate_to_droid codex timeout still escalates when clean"
else
  bad "#803: clean should_escalate_to_droid codex timeout broken: '$setd_clean'"
fi




# 23) #803: BD803_REVIEW_LIB must resolve to resolve-cli.sh (not arbitrary script).
printf '#!/bin/sh\necho EVIL_PIN\n' > "$WORK/evil.sh"
chmod +x "$WORK/evil.sh"
set +e
pt803=$(
  cd "$REPO" && PATH="$EXT:/usr/bin:/bin" BD803_REVIEW_LIB="$WORK/evil.sh" \
    /bin/bash --norc -c ". \"$LIB\" >/dev/null 2>&1; _portable_timeout --review codex 1 codex 2>&1; echo RC=\$?"
)
set -e
if [[ "$pt803" != *EVIL_PIN* && "$pt803" == *RC=[1-9]* && ( "$pt803" == *BD803_REVIEW_LIB* || "$pt803" == *refusing* ) ]]; then
  ok "#803: BD803_REVIEW_LIB evil.sh refused for --review"
else
  bad "#803: BD803_REVIEW_LIB evil.sh not refused: '$pt803'"
fi

# 24) #803: _bd803_canonical_file_path sanity; poisoned /bin/sh pin refused.
set +e
canon=$(
  cd "$REPO" && /bin/bash --norc -c ". \"$LIB\" >/dev/null 2>&1; _bd803_canonical_file_path \"$LIB\""
)
canon_rc=$?
set -e
if [[ "$canon_rc" -eq 0 && ( "$canon" == "$LIB" || "$canon" -ef "$LIB" ) ]]; then
  ok "#803: _bd803_canonical_file_path sanity on LIB"
else
  bad "#803: _bd803_canonical_file_path sanity failed: rc=$canon_rc out='$canon'"
fi
set +e
shpin=$(
  cd "$REPO" && PATH="$EXT:/usr/bin:/bin" BD803_REVIEW_LIB=/bin/sh \
    /bin/bash --norc -c ". \"$LIB\" >/dev/null 2>&1; _portable_timeout --review codex 1 codex 2>&1; echo RC=\$?"
)
set -e
if [[ "$shpin" == *RC=[1-9]* && ( "$shpin" == *BD803_REVIEW_LIB* || "$shpin" == *refusing* ) ]]; then
  ok "#803: BD803_REVIEW_LIB=/bin/sh refused"
else
  bad "#803: BD803_REVIEW_LIB=/bin/sh not refused: '$shpin'"
fi

# 25) #803: latched pin survives post-source canonical stub (no live BASH_SOURCE re-resolve).
/usr/bin/printf '%s\n' '#!/bin/sh' 'echo REAL' > "$EXT/codex"
chmod +x "$EXT/codex"
set +e
canon_miss=$(
  cd "$REPO" && PATH="$EXT:/usr/bin:/bin" /bin/bash --norc -c \
    ". \"$LIB\" >/dev/null 2>&1; _bd803_canonical_file_path() { :; }; _portable_timeout --review codex 1 codex --version 2>&1; echo RC=\$?"
)
set -e
if [[ "$canon_miss" == *REAL* && "$canon_miss" == *RC=0* ]]; then
  ok "#803: latched pin survives post-source canonical stub for --review"
else
  bad "#803: latched pin did not survive post-source canonical stub: '$canon_miss'"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
