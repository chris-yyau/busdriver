#!/bin/bash
# ultra-oracle-chrome.sh — the Claude-in-Chrome transport behind ultra_oracle_consult
# (docs/specs/2026-11-01-ultraoracle-chrome-transport-design.md; ADR 0061). Sourced by
# ultra-oracle.sh after ultra-oracle-config.sh. bash 3.2 floor; jq only as /usr/bin/jq.
_UORA_JQ=/usr/bin/jq
_UORA_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
_UORA_CHILD_DIR="$_UORA_ROOT/scripts/hooks/ultra-oracle-child"
_UORA_QUERY='file input element for attaching files to the message composer'
_UORA_URL='https://chatgpt.com/'
_UORA_OPS='j-home j-attached j-send j-id j-poll j-get j-archive'

# _uora_sig <key> -> the live-measured value from signatures.json (Task 1): rc 0 and "" for an
# explicit null, rc 1 when the file cannot be read or the key is absent. A failed read must never
# look like "no r3 protection" (that would fail open).
_uora_sig() {
  local f="$_UORA_CHILD_DIR/signatures.json"
  [ -f "$f" ] && [ ! -L "$f" ] || return 1
  # shellcheck disable=SC2016  # single-quoted jq program: $names are jq variables, not shell ones.
  $_UORA_JQ -er --arg k "$1" 'if has($k) then (.[$k] // "" | tostring) else error("missing") end' "$f" 2>/dev/null
}

# _uora_sig_ok: signatures.json is a regular file holding every Task 1 key with its type; only the
# two r3 keys may be null. Checked once per consult before the lock; failure is `error internal`.
_uora_sig_ok() {
  local f="$_UORA_CHILD_DIR/signatures.json"
  [ -f "$f" ] && [ ! -L "$f" ] || return 1
  $_UORA_JQ -e '
    type == "object"
    and (.disconnect | type == "string" and length > 0)
    and (.disconnect_record | IN("result", "tool_result"))
    and (.auth | type == "string" and length > 0)
    and .deny_marker == "uora-guard: deny"
    and (.permission_refusal | type == "string" and length > 0)
    and (.stream_js_text | IN("opcode", "snippet"))
    and (.reopen_settle_seconds | type == "number" and . >= 0 and . == floor)
    and has("pretool_on_failure") and has("claude_min_version")   # nullable, but never absent
    and (.pretool_on_failure == null or .pretool_on_failure == "block")
    and (.claude_min_version == null or (.claude_min_version | type == "string" and test("\\A[0-9]+\\.[0-9]+\\.[0-9]+\\z")))
    and ((.pretool_on_failure == null) == (.claude_min_version == null))' "$f" >/dev/null 2>&1
}

# _uora_phase_set <rd> <word>: the phase file is only ever written by an atomic rename (§2).
_uora_phase_set() {
  local t
  t="$(mktemp "$1/phase.XXXXXXXX")" || return 1
  printf '%s\n' "$2" > "$t" && mv -f -- "$t" "$1/phase"
}

# _uora_render_guard <rd> <tag>: guard.json holds the tag, the staged path, and each snippet's
# rendered text. The guard reads its expected values only from here (§4 "Guard state").
# Each snippet is delivered as `await (<snippet>)`: javascript_tool evaluates with REPL semantics
# and returns a bare async IIFE's Promise unawaited, serialized as "{}" (measured live in r1).
_uora_render_guard() {
  local rd="$1" tag="$2" op
  local -a args=()
  for op in $_UORA_OPS; do
    [ -f "$_UORA_CHILD_DIR/$op.js" ] && [ ! -L "$_UORA_CHILD_DIR/$op.js" ] || return 1
    args+=(--rawfile "${op//-/_}" "$_UORA_CHILD_DIR/$op.js")
  done
  ( umask 077
    # shellcheck disable=SC2016  # single-quoted jq program: $names are jq variables, not shell ones.
    $_UORA_JQ -n --arg tag "$tag" --arg staged "$rd/uora-$tag.txt" --arg url "$_UORA_URL" --arg q "$_UORA_QUERY" "${args[@]}" '
      def r: "await (\n" + gsub("__UORA_TAG__"; $tag) + "\n)";
      {tag: $tag, staged: $staged, url: $url, query: $q,
       snippets: {"j-home": ($j_home | r), "j-attached": ($j_attached | r), "j-send": ($j_send | r),
                  "j-id": ($j_id | r), "j-poll": ($j_poll | r), "j-get": ($j_get | r), "j-archive": ($j_archive | r)}}' \
      > "$rd/guard.json" ) || return 1
  chmod 600 "$rd/guard.json" || return 1
  ( umask 077; printf '{}\n' > "$rd/guard-state.json" ) || return 1
  mkdir -m 700 "$rd/oob" || return 1
  _uora_phase_set "$rd" setup
}

# _uora_render_settings <rd>: both halves in exec form through contained-launch.sh closed, the
# match-all matcher so Read and ToolSearch pass the guard too, timeout 30 (§4 "Hook registration").
_uora_render_settings() {
  local rd="$1" block
  block="$(_uora_sig pretool_on_failure)" || return 1   # a failed read never renders "no onFailure"
  case "$block" in ''|block) ;; *) return 1 ;; esac   # the only legal values (Task 1 Step 1)
  ( umask 077
    # shellcheck disable=SC2016  # single-quoted jq program: $names are jq variables, not shell ones.
    $_UORA_JQ -n --arg l "$_UORA_ROOT/hooks/gate-scripts/lib/contained-launch.sh" \
      --arg g "$_UORA_CHILD_DIR/guard.sh" --arg rd "$rd" --arg b "$block" '
      def h($m; $extra): [{matcher: "*", hooks: [{type: "command", command: $l,
        args: ["closed", "PATH=/usr/bin:/bin", ("UORA_RUN_DIR=" + $rd), "/bin/bash", $g, $m], timeout: 30} + $extra]}];
      # r3: onFailure is a per-handler field, and only PreToolUse may block (a recorder failure
      # must never block a call that already ran).
      {hooks: {PreToolUse: h("pre"; (if $b == "" then {} else {onFailure: $b} end)),
               PostToolUse: h("post"; {})}}' > "$rd/child-settings.json" )
}

# _uora_render_instructions <rd> <tag>: fills in only the tag and the staged path (§3).
_uora_render_instructions() {
  local rd="$1" tag="$2"
  ( umask 077
    # shellcheck disable=SC2016  # single-quoted jq program: $names are jq variables, not shell ones.
    $_UORA_JQ -Rrs --arg t "$tag" --arg p "$rd/uora-$tag.txt" 'gsub("__UORA_TAG__"; $t) | gsub("__UORA_STAGED__"; $p)' \
      < "$_UORA_CHILD_DIR/instructions.txt" > "$rd/instructions.txt" )
}

# ---- run dir, staging, record (spec §2) ----------------------------------------------------
_UORA_STAGE_MAX=10485760   # 10 MB, headers included

# Outside every repository on purpose: a consumer repo does not gitignore .claude/ultra-oracle/ (§2).
_uora_base() { printf '%s/.cache/busdriver/ultra-oracle' "$HOME"; }

_uora_new_run() {
  local base tag rd re='^[0-9a-f]{16}$'
  base="$(_uora_base)"
  ( umask 077; mkdir -p "$base" ) || return 1
  tag="$(od -An -N8 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')"
  [[ "$tag" =~ $re ]] || return 1
  mkdir -m 700 "$base/run-$tag" || return 1
  rd="$(cd "$base/run-$tag" && pwd -P)" || return 1
  printf '%s\t%s' "$tag" "$rd"
}

_uora_input_ok() { [[ ! -L "$1" && -f "$1" && -r "$1" ]]; }

# Stage one text file: the prompt, then each context under "=== [<n>] <basename> ===" (basename
# only, by design, §2), as one cumulative bounded copy. A FIFO or /dev/zero never gets this far:
# _uora_input_ok accepts regular files only. The `head -c` cap is what bounds a regular file that
# grows while it is read.
_uora_stage() {
  local dst="$1" ptext="$2" pfile="$3" g sz nul ctx=()
  shift 3
  if [[ -n "$pfile" ]]; then
    _uora_input_ok "$pfile" && [[ -s "$pfile" ]] \
      || { echo "ultra-oracle: prompt file '$pfile' is a symlink, not a regular non-empty file, or unreadable" >&2; return 1; }
    [[ "$pfile" == /* ]] || pfile="./$pfile"   # cat reads an operand '-' as stdin, even after --
  fi
  for g in "$@"; do
    _uora_input_ok "$g" || { echo "ultra-oracle: context '$g' is a symlink, not a regular file, or unreadable" >&2; return 1; }
    [[ "$g" == /* ]] && ctx+=("$g") || ctx+=("./$g")
  done
  set -- ${ctx[@]+"${ctx[@]}"}
  # Every read's status is recorded in $dst.rerr, because only head's status survives the pipe.
  # A read that dies of SIGPIPE (141) means head already holds cap+1 bytes, which the size check
  # below rejects anyway, so any recorded failure fails staging: a partial prompt never uploads.
  rm -f -- "$dst.rerr"
  ( umask 077; set +o pipefail
    { if [[ -n "$pfile" ]]; then cat -- "$pfile" || echo "$?" >> "$dst.rerr"; else printf '%s' "$ptext"; fi
      n=0
      for g in "$@"; do n=$((n + 1)); printf '\n=== [%d] %s ===\n' "$n" "${g##*/}"; cat -- "$g" || echo "$?" >> "$dst.rerr"; done
    } 2>/dev/null | head -c $((_UORA_STAGE_MAX + 1)) > "$dst" ) \
    || { rm -f -- "$dst.rerr"; echo "ultra-oracle: staging failed" >&2; return 1; }
  sz="$(wc -c < "$dst" | tr -dc '0-9')"
  [[ -n "$sz" ]] || { rm -f -- "$dst.rerr"; echo "ultra-oracle: cannot measure the staged prompt" >&2; return 1; }
  [ "$sz" -le "$_UORA_STAGE_MAX" ] || { rm -f -- "$dst.rerr"; echo "ultra-oracle: the staged prompt exceeds 10 MB" >&2; return 1; }
  if [ -e "$dst.rerr" ]; then
    rm -f -- "$dst.rerr"; echo "ultra-oracle: an input could not be read in full" >&2; return 1
  fi
  [ "$sz" -gt 0 ] || { echo "ultra-oracle: the staged prompt is empty" >&2; return 1; }
  nul="$(set -o pipefail; LC_ALL=C tr -cd '\000' < "$dst" | wc -c | tr -dc '0-9')" \
    || { echo "ultra-oracle: cannot check the staged prompt for NUL bytes" >&2; return 1; }
  [ "${nul:-1}" -eq 0 ] || { echo "ultra-oracle: an input holds a NUL byte (the upload is a text file)" >&2; return 1; }
}

_uora_sha256() {
  local h re='^[0-9a-f]{64}$'
  if command -v sha256sum >/dev/null 2>&1; then h="$(sha256sum < "$1")"; else h="$(shasum -a 256 < "$1")"; fi || return 1
  h="${h%% *}"
  [[ "$h" =~ $re ]] || return 1
  printf '%s' "$h"
}

# record.json holds no content: hashes, phase, id, status, reason, the tab ledger (§2 "Cleanup").
_uora_record() {
  local rd="$1"
  shift
  [ -f "$rd/record.json" ] || ( umask 077; printf '{}\n' > "$rd/record.json" ) || return 1
  $_UORA_JQ -c "$@" "$rd/record.json" > "$rd/record.json.tmp" && mv -f -- "$rd/record.json.tmp" "$rd/record.json"
}

# ---- seams, clock, probe, reopen (spec §2 "Platform and process seams", §3) -------------------
# Assigned unconditionally at source time, never read from the environment. In-process tests
# reassign them AFTER sourcing; that is the only override path.
_ULTRA_ORACLE_PLATFORM="$(uname -s 2>/dev/null)"
_ULTRA_ORACLE_OPEN_CMD=(open -a "Google Chrome")
_ULTRA_ORACLE_CLAUDE_BIN=""   # empty: resolve through the trusted resolver
# The one clock. A failed or non-numeric read is rc 1, never an empty "now" that compares false.
_uora_now() { local n; n="$(date +%s 2>/dev/null)" || return 1; case "$n" in ''|*[!0-9]*) return 1 ;; esac; echo "$n"; }

# The child's whole environment (§3): HOME USER LOGNAME TMPDIR LANG, plus PATH at launch.
_uora_env_init() {
  _UORA_ENV=(HOME="$HOME" USER="${USER-}" LOGNAME="${LOGNAME-}" TMPDIR="${TMPDIR:-/tmp}" LANG="${LANG:-en_US.UTF-8}")
}

# claude and its PATH come from the trusted resolver run under env -i with loader variables
# cleared, exactly as the litmus backstop runs it (skills/litmus/scripts/run-review-loop.sh:1169-1177).
_uora_resolve_claude() {
  local bin p r="$_UORA_ROOT/scripts/lib/resolve-cli.sh"
  if [[ -n "$_ULTRA_ORACLE_CLAUDE_BIN" ]]; then
    [[ "$_ULTRA_ORACLE_CLAUDE_BIN" == /* ]] || return 1
    printf '%s\t%s' "$_ULTRA_ORACLE_CLAUDE_BIN" "/usr/bin:/bin"; return 0
  fi
  bin=$(LD_PRELOAD='' LD_AUDIT='' LD_LIBRARY_PATH='' DYLD_INSERT_LIBRARIES='' DYLD_LIBRARY_PATH='' DYLD_FRAMEWORK_PATH='' DYLD_FALLBACK_LIBRARY_PATH='' DYLD_FALLBACK_FRAMEWORK_PATH='' DYLD_VERSIONED_LIBRARY_PATH='' DYLD_VERSIONED_FRAMEWORK_PATH='' /usr/bin/env -i PATH="${PATH-}" PWD="${PWD-}" /bin/bash --noprofile --norc "$r" --print-trusted-cli claude 2>/dev/null) || bin=""
  [[ "$bin" == /* ]] || return 1
  p=$(LD_PRELOAD='' LD_AUDIT='' LD_LIBRARY_PATH='' DYLD_INSERT_LIBRARIES='' DYLD_LIBRARY_PATH='' DYLD_FRAMEWORK_PATH='' DYLD_FALLBACK_LIBRARY_PATH='' DYLD_FALLBACK_FRAMEWORK_PATH='' DYLD_VERSIONED_LIBRARY_PATH='' DYLD_VERSIONED_FRAMEWORK_PATH='' /usr/bin/env -i PATH="${PATH-}" PWD="${PWD-}" /bin/bash --noprofile --norc "$r" --print-review-dispatch-path "$bin" claude 2>/dev/null) || p=""
  [[ "$p" == /* ]] || return 1
  printf '%s\t%s' "$bin" "$p"
}

# Every loader variable is UNSET (not blanked) in the subshell that runs timeout and env: env -i
# clears the child, but timeout and env themselves would still load with the caller's settings.
_uora_noloader() {
  unset LD_PRELOAD LD_AUDIT LD_LIBRARY_PATH DYLD_INSERT_LIBRARIES DYLD_LIBRARY_PATH DYLD_FRAMEWORK_PATH \
    DYLD_FALLBACK_LIBRARY_PATH DYLD_FALLBACK_FRAMEWORK_PATH DYLD_VERSIONED_LIBRARY_PATH DYLD_VERSIONED_FRAMEWORK_PATH
}

# Capability probe under the dispatch environment, bounded at 15 s. The help text is captured
# once and then matched, so pipefail cannot SIGPIPE it (§3).
_uora_probe() { # <bin> <path>
  local help rc=0 min ver
  help="$(_uora_noloader; _portable_timeout 15 /usr/bin/env -i "${_UORA_ENV[@]}" PATH="$2" "$1" --help 2>&1)" || rc=$?
  [ "$rc" = 0 ] || return 1
  [[ "$help" == *--chrome* && "$help" == *--setting-sources* ]] || return 1
  # r3 (Task 1 Step 1): per-handler onFailure needs a minimum claude version. An unparseable
  # version, or one below the minimum, fails closed.
  min="$(_uora_sig claude_min_version)" || return 1   # a failed read never skips the gate
  [ -n "$min" ] || return 0
  rc=0
  ver="$(_uora_noloader; _portable_timeout 15 /usr/bin/env -i "${_UORA_ENV[@]}" PATH="$2" "$1" --version 2>/dev/null)" || rc=$?
  [ "$rc" = 0 ] || return 1
  [[ "$ver" =~ ([0-9]+)\.([0-9]+)\.([0-9]+) ]] || return 1
  _uora_ver_ge "${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.${BASH_REMATCH[3]}" "$min"
}

# _uora_ver_ge <a> <b>: a >= b for dotted x.y.z, numeric per field (bash 3.2: no sort -V needed).
_uora_ver_ge() {
  local IFS=. a b i
  read -r -a a <<< "$1"; read -r -a b <<< "$2"
  for i in 0 1 2; do
    case "${a[$i]:-}${b[$i]:-}" in ''|*[!0-9]*) return 1 ;; esac
    [ "${a[$i]}" -gt "${b[$i]}" ] && return 0
    [ "${a[$i]}" -lt "${b[$i]}" ] && return 1
  done
  return 0
}

# Run once, unconditionally, after the mutex and before the launch. It starts Chrome or opens a
# window (E10), bounded by the time left before the browser cutoff (§2 "Chrome reopen").
_uora_reopen() { # <cutoff-epoch>
  local left rc=0 settle now
  now="$(_uora_now)" || return 1
  left=$(( $1 - now ))
  [ "$left" -gt 0 ] || return 124
  ( _uora_noloader; _portable_timeout "$left" "${_ULTRA_ORACLE_OPEN_CMD[@]}" >/dev/null 2>&1 ) || rc=$?
  # 137: timeout -k needed KILL after TERM; the budget still ran out, so it is a timeout too.
  case "$rc" in 124|137) return 124 ;; esac
  [ "$rc" = 0 ] || return 1
  settle="$(_uora_sig reopen_settle_seconds)" || return 1
  case "$settle" in ''|*[!0-9]*) return 1 ;; esac   # signatures.json is validated; a bad value fails closed
  # The settle sleep is browser time too: never past the cutoff (§2 "browser work stops at the cutoff").
  now="$(_uora_now)" || return 1
  left=$(( $1 - now ))
  [ "$settle" -gt "$left" ] && settle="$left"
  [ "$settle" -gt 0 ] && sleep "$settle"
  now="$(_uora_now)" || return 1
  [ "$now" -lt "$1" ] || return 124
  return 0
}

# ---- launch, cleanup, sweep (spec §2, §3, §4) ------------------------------------------------
# The child runs as its own process group: a dedicated subshell turns on monitor mode, starts
# claude as a background job (pgid == pid, measured under /bin/bash 3.2), and the publisher —
# never a member of that group — waits on it. Every signal goes to -$pid only.
_uora_launch() { # <rd> <bin> <cpath> <cutoff>
  local rd="$1" bin="$2" cpath="$3" cutoff="$4" tag instr
  tag="${rd##*/run-}"
  instr="$(cat "$rd/instructions.txt")" || return 1
  # set +e: a caller's errexit must not end this subshell at `wait` or at the final group KILL.
  ( set -m; set +e
    cd "$rd" || exit 1
    _uora_noloader
    /usr/bin/env -i "${_UORA_ENV[@]}" PATH="$cpath" "$bin" -p --chrome --model sonnet --permission-mode default \
      --setting-sources '' --tools "Read,ToolSearch" --strict-mcp-config --no-session-persistence \
      --output-format stream-json --verbose \
      --allowedTools "ToolSearch,Read(/$rd/uora-$tag.txt)" \
      --disallowedTools "Bash,Write,Edit,NotebookEdit,WebFetch,WebSearch,Glob,Grep,Agent,Task" \
      --settings "$rd/child-settings.json" \
      "$instr" </dev/null >"$rd/stream.jsonl" 2>"$rd/child.err" &
    pid=$!
    # The child's pid (= its pgid under set -m) for the core's cancel path (_uora_abort). A trap here
    # would not do: `_uora_launch … &` forks twice (the async shell, then this subshell), so a TERM
    # sent to $! never reaches this subshell (measured under /bin/bash 3.2.57: the child survived).
    ( umask 077; printf '%s\n' "$pid" > "$rd/child.pid" )
    # The core's abort writes <rd>/cancel BEFORE it reads child.pid, and this check runs AFTER the
    # pid is written, so whichever way they interleave, one side kills the group.
    [ -e "$rd/cancel" ] && kill -KILL -- "-$pid" 2>/dev/null
    while kill -0 "$pid" 2>/dev/null; do
      now="$(_uora_now)" || now="$cutoff"   # an unreadable clock is the cutoff, never "no deadline"
      if [ "$now" -ge "$cutoff" ]; then
        printf 'cutoff\n' > "$rd/cutoff"
        kill -TERM -- "-$pid" 2>/dev/null
        i=0; while [ "$i" -lt 5 ] && kill -0 "$pid" 2>/dev/null; do sleep 1; i=$((i + 1)); done
        kill -KILL -- "-$pid" 2>/dev/null
        break
      fi
      sleep 1
    done
    wait "$pid"; rc=$?
    kill -KILL -- "-$pid" 2>/dev/null   # whatever exit: no hook of the child is left running (§4)
    exit "$rc"
  ) >/dev/null 2>>"$rd/launch.err"
}

# Candidate download dirs (§6): every Chrome profile's download.default_directory, then ~/Downloads.
_uora_dl_dirs() {
  local p d
  for p in "$HOME/Library/Application Support/Google/Chrome/"*/Preferences; do
    [ -f "$p" ] || continue
    d="$($_UORA_JQ -r '.download.default_directory // empty' "$p" 2>/dev/null)" || continue   # a bad profile never truncates the list
    [ -n "$d" ] && printf '%s\n' "$d"
  done
  printf '%s\n' "$HOME/Downloads"
}

# Cleanup, both modes, every exit path (§2): the run dir keeps only record.json; this tag's
# download copies go too, .crdownload included — regular files only, never through a symlink.
_uora_cleanup() { # <rd> <tag>
  local rd="$1" tag="$2" d f e
  while IFS= read -r d; do
    [[ -d "$d" && ! -L "$d" ]] || continue
    for f in "$d/uora-$tag.json" "$d/uora-$tag.json.crdownload" "$d/uora-$tag ("*").json" "$d/uora-$tag ("*").json.crdownload"; do
      [[ -f "$f" && ! -L "$f" ]] && rm -f -- "$f"
    done
  done < <(_uora_dl_dirs)
  [[ -d "$rd" && ! -L "$rd" ]] || return 0
  for e in "$rd"/* "$rd"/.[!.]*; do
    [[ -e "$e" || -L "$e" ]] || continue
    [ "$e" = "$rd/record.json" ] || rm -rf -- "$e"
  done
}

# After acquiring the mutex: run dirs older than twice the cap ceiling, and stray answer files
# older than the ceiling (§2), such as a late download that landed after its child was killed.
_uora_sweep() { # <ceiling-secs>
  local base ceil="$1" mins d f name re='^uora-[0-9a-f]{16}( \([0-9]+\))?\.json(\.crdownload)?$'
  base="$(_uora_base)"
  case "$ceil" in ''|*[!0-9]*|0) ceil=3600 ;; esac
  mins=$(( (2 * ceil + 59) / 60 ))
  find "$base" -mindepth 1 -maxdepth 1 -type d -name 'run-*' -mmin +"$mins" -exec rm -rf -- {} + 2>/dev/null || :   # no base yet must not skip the download sweep
  mins=$(( (ceil + 59) / 60 ))
  while IFS= read -r d; do
    [[ -d "$d" && ! -L "$d" ]] || continue
    while IFS= read -r f; do
      name="${f##*/}"
      [[ "$name" =~ $re ]] && [[ -f "$f" && ! -L "$f" ]] && rm -f -- "$f"
    done < <(find "$d" -mindepth 1 -maxdepth 1 -type f -name 'uora-*' -mmin +"$mins" 2>/dev/null)
  done < <(_uora_dl_dirs)
}

# ---- the consult (spec §1, §2, §6, §7) ------------------------------------------------------------
_UORA_FLOOR=120      # §6: a cap under 120 s would leave the 60 s reserve no browser time
_UORA_RESERVE=60     # §2: the final 60 s settle the download, audit, verify and publish
_UORA_SETTLE_MAX=30  # §6: the download settle bound

# _uora_early <out> <reason> [<detail>]: .err and .hint for a consult that never launches a child.
_uora_early() {
  local h
  h="$(_uora_hint "$2" "${3:-}")${_UORA_NOTE_HINT:+ $_UORA_NOTE_HINT}"
  printf '%s\n' "$2" > "$1.err" 2>/dev/null
  printf '%s\n' "$h" > "$1.hint" 2>/dev/null
  echo "ultra-oracle: $h" >&2
}

# _uora_core <mode> <out> <rd> <tag> <cap> <deadline> <bin> <cpath>: everything after dispatch. A
# subshell function in BOTH modes, so its EXIT trap (unlock, then cleanup) never lands in the caller's
# shell and a caller's errexit cannot abort it before publication (§2 "Process model"). It publishes
# and records the status; the caller reads it back and, in background mode, writes .rc after it.
_uora_core() (
  set +e
  _UORA_C_OUT="$2" _UORA_C_RD="$3" _UORA_C_TAG="$4" _UORA_LOCK_HANDLE="" _UORA_LAUNCH_PID=""
  trap '_ultra_oracle_browser_unlock "$_UORA_LOCK_HANDLE"; rm -f -- "$_UORA_C_OUT.tmp"; _uora_cleanup "$_UORA_C_RD" "$_UORA_C_TAG"' EXIT
  # A cancelled consult (Ctrl-C, kill) must not orphan the child, which could still upload the prompt
  # the operator just cancelled, and must release the mutex. bash 3.2 does not run the EXIT trap on
  # death by an untrapped signal, so each signal is trapped and turned into an exit (which runs the
  # EXIT trap), after this shell has killed the child's group itself, by the pgid the launcher wrote
  # to <rd>/child.pid. The launcher runs in the background and is waited on, because a trap is
  # deferred until a FOREGROUND command returns, while `wait` is interrupted at once. (An async
  # subshell starts with INT ignored, so in background mode only TERM and HUP can reach it; INT is
  # trapped for blocking mode.) A signal to an outer wrapper rather than to this shell leaves the
  # core running to its normal end, which unlocks and cleans up as usual.
  # shellcheck disable=SC2329  # invoked by the signal traps set below.
  _uora_abort() {
    local c
    trap - INT TERM HUP
    # The marker goes first: a launcher that has not yet written child.pid sees it after it does
    # and kills its own group (_uora_launch).
    : > "$_UORA_C_RD/cancel" 2>/dev/null
    c="$(cat "$_UORA_C_RD/child.pid" 2>/dev/null)"
    case "$c" in ''|*[!0-9]*) ;; *)
      kill -TERM -- "-$c" 2>/dev/null; sleep 1; kill -KILL -- "-$c" 2>/dev/null ;; esac
    # Wait for the launcher (the core's only job) instead of killing it: a TERM reaches only the
    # outer async shell, never the nested subshell that owns the child, so unlock must follow its exit.
    wait 2>/dev/null
    exit "$1"
  }
  trap '_uora_abort 130' INT; trap '_uora_abort 143' TERM; trap '_uora_abort 129' HUP
  # This subshell's own pid (bash 3.2 has no $BASHPID; a direct child's $PPID is this shell), so an
  # operator, or the cancel test, can signal the core itself.
  /bin/sh -c 'echo "$PPID"' > "$3/core.pid"
  mode="$1" out="$2" rd="$3" tag="$4" cap="$5" deadline="$6" bin="$7" cpath="$8"
  cutoff=$(( deadline - _UORA_RESERVE ))
  # The mutex wait is inside the deadline and gives up at the browser cutoff (§2 "Deadline").
  lrc=0
  _UORA_LOCK_HANDLE="$(_ultra_oracle_browser_lock chrome-extension "$cap" "$cap" "$cutoff")" || lrc=$?
  if [ "$lrc" = 2 ]; then _UORA_LOCK_HANDLE=""; _uora_finish "$mode" "$out" "$rd" error internal '{}' "the lock dir cannot support atomic locking"; exit 0; fi
  if [ "$lrc" != 0 ]; then _UORA_LOCK_HANDLE=""; _uora_finish "$mode" "$out" "$rd" timeout timeout '{}'; exit 0; fi
  _uora_sweep "$(_ultra_oracle_sanitize_ceiling "${ULTRA_ORACLE_CAP_CEILING:-3600}")"
  rrc=0; _uora_reopen "$cutoff" || rrc=$?
  if [ "$rrc" = 124 ]; then _uora_finish "$mode" "$out" "$rd" timeout timeout '{}'; exit 0; fi
  if [ "$rrc" != 0 ]; then _uora_finish "$mode" "$out" "$rd" unavailable extension-not-connected '{}'; exit 0; fi
  if ! { _uora_render_guard "$rd" "$tag" && _uora_render_settings "$rd" && _uora_render_instructions "$rd" "$tag"; }; then
    _uora_finish "$mode" "$out" "$rd" error internal '{}' "the guard files could not be rendered"; exit 0
  fi
  # No child is spawned at or past the cutoff (rendering takes time too).
  now="$(_uora_now)" || now="$cutoff"   # an unreadable clock is the cutoff, never "no deadline"
  if [ "$now" -ge "$cutoff" ]; then _uora_finish "$mode" "$out" "$rd" timeout timeout '{}'; exit 0; fi
  _uora_launch "$rd" "$bin" "$cpath" "$cutoff" &   # exactly one child; its group is dead on return (§4)
  _UORA_LAUNCH_PID=$!
  wait "$_UORA_LAUNCH_PID"; _UORA_LAUNCH_PID=""
  mv -f -- "$rd/guard.json" "$rd/guard.json.done" 2>/dev/null   # the second fence (§4)
  fx="$(_uora_classify "$rd")"
  $_UORA_JQ -e 'type == "object"' >/dev/null 2>&1 <<<"$fx" || fx='{"audit":"audit","violations":[{"why":"classify"}]}'
  audit="$($_UORA_JQ -r '.audit // "audit"' <<<"$fx")"
  saved=0 acc=-
  if [ "$($_UORA_JQ -r '.saved != null' <<<"$fx")" = true ]; then
    saved=1
    [ "$audit" = clean ] && acc="$(_uora_accept "$rd" "$tag" "$($_UORA_JQ -r .saved.bytes <<<"$fx")" \
      "$($_UORA_JQ -r .saved.sha <<<"$fx")" "$($_UORA_JQ -r '.uora_id // ""' <<<"$fx")" "$deadline" "$out")"
  fi
  cut=0; [ -f "$rd/cutoff" ] && cut=1
  noref=0; [ "$($_UORA_JQ -r '.noref // false' <<<"$fx")" = true ] && noref=1
  res="$(_uora_precedence "$audit" "$saved" "$acc" "$cut" "$noref" "$($_UORA_JQ -r '.presult // "error child-died"' <<<"$fx")")"
  _uora_finish "$mode" "$out" "$rd" "${res%% *}" "${res#* }" "$fx"
)

# _uora_chrome_consult: ultra_oracle_consult's contract over the Chrome transport. Prints exactly one of
# ok | skipped:unavailable | skipped:user | timeout | error | dispatched. Everything before `dispatched`
# runs synchronously and returns its token directly (§7).
_uora_chrome_consult() {
  local prompt="" prompt_file="" mode="blocking" out="" cap="" t0 deadline ceil run tag rd rb bin cpath st
  local state_dir git_root skip
  local -a ctx_arr=()
  t0="$(_uora_now)"   # the deadline's one anchor, before any wait (§2)
  _UORA_NOTE_HINT="$(_ultra_oracle_legacy_keys_notice)"   # appended to every .hint (§8)
  [ -n "$_UORA_NOTE_HINT" ] && echo "ultra-oracle: $_UORA_NOTE_HINT" >&2
  while [ $# -gt 0 ]; do
    case "$1" in
      --prompt|--prompt-file|--context|--mode|--out|--slug|--timeout-cap-seconds)
        [ $# -ge 2 ] || { printf 'error'; return 1; } ;;
    esac
    case "$1" in
      --prompt) prompt="$2"; shift 2 ;;
      --prompt-file) prompt_file="$2"; shift 2 ;;
      --context) ctx_arr+=("$2"); shift 2 ;;
      --mode) mode="$2"; shift 2 ;;
      --out) out="$2"; shift 2 ;;
      --slug) shift 2 ;;   # oracle's session name; accepted so callers need no change (§1)
      --timeout-cap-seconds) cap="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  [[ -n "$out" ]] || { printf 'error'; return 1; }
  [[ -n "$prompt" || -n "$prompt_file" ]] || { printf 'error'; return 1; }
  [[ -n "$prompt_file" ]] && prompt=""
  [[ -n "$cap" ]] || cap="$(ultra_oracle_timeout_cap)"
  case "$cap" in *[!0-9]*) : ;; *) cap="${cap#"${cap%%[!0]*}"}" ;; esac
  case "$cap" in ''|*[!0-9]*|0)
    echo "ultra-oracle: invalid timeout cap '$cap' — using config/default" >&2
    cap="$(ultra_oracle_timeout_cap)" ;;
  esac
  ceil="$(_ultra_oracle_sanitize_ceiling "${ULTRA_ORACLE_CAP_CEILING:-3600}")"
  if [ "${#cap}" -ge 19 ] || [ "$cap" -gt "$ceil" ]; then
    echo "ultra-oracle: timeout cap $cap exceeds ceiling $ceil — clamping" >&2
    cap="$ceil"
  fi
  mkdir -p "$(dirname "$out")" 2>/dev/null || { printf 'error'; return 1; }
  rm -f -- "$out" "$out.tmp" "$out.rc" "$out.rc.partial" "$out.err" "$out.hint" || {
    echo "ultra-oracle: cannot clear stale output '$out' — failing closed" >&2
    printf 'error'; return 1
  }
  if [ "$cap" -lt "$_UORA_FLOOR" ]; then
    _uora_early "$out" input "the timeout cap ${cap}s is under the Chrome transport's ${_UORA_FLOOR}s floor"
    printf 'error'; return 1
  fi
  state_dir="${BUSDRIVER_STATE_DIR:-.claude}"
  git_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  skip="${git_root:+$git_root/}$state_dir/skip-ultra-oracle.local"
  if [[ -f "$skip" ]]; then printf 'skipped:user'; return 0; fi
  if [ "$_ULTRA_ORACLE_PLATFORM" != Darwin ]; then _uora_early "$out" not-macos; printf 'skipped:unavailable'; return 3; fi
  if [ ! -x "$_UORA_JQ" ]; then _uora_early "$out" claude-unavailable jq; printf 'skipped:unavailable'; return 3; fi
  rb="$(_uora_resolve_claude)" || { _uora_early "$out" claude-unavailable; printf 'skipped:unavailable'; return 3; }
  bin="${rb%%$'\t'*}" cpath="${rb#*$'\t'}"
  _uora_env_init
  # signatures.json carries the r3 protections; an unreadable or malformed one is an internal
  # error, never "no protection" (Task 6 _uora_sig_ok).
  _uora_sig_ok || { _uora_early "$out" internal "scripts/hooks/ultra-oracle-child/signatures.json is missing or malformed"; printf 'error'; return 1; }
  _uora_probe "$bin" "$cpath" || { _uora_early "$out" claude-unavailable; printf 'skipped:unavailable'; return 3; }
  run="$(_uora_new_run)" || { _uora_early "$out" internal "the run dir could not be created"; printf 'error'; return 1; }
  tag="${run%%$'\t'*}" rd="${run#*$'\t'}"
  if ! _uora_stage "$rd/uora-$tag.txt" "$prompt" "$prompt_file" ${ctx_arr[@]+"${ctx_arr[@]}"} 2>"$rd/stage.err"; then
    _uora_early "$out" input "$(sed -n '1s/^ultra-oracle: //p' "$rd/stage.err")"
    _uora_cleanup "$rd" "$tag"; printf 'error'; return 1
  fi
  deadline=$(( t0 + cap ))
  # shellcheck disable=SC2016  # single-quoted jq program: $names are jq variables, not shell ones.
  _uora_record "$rd" --arg h "$(_uora_sha256 "$rd/uora-$tag.txt")" --argjson d "$deadline" --argjson c "$cap" \
    '. + {staged_sha256: $h, deadline: $d, cap: $c, phase: "setup"}' \
    || { _uora_early "$out" internal "record.json could not be written"; _uora_cleanup "$rd" "$tag"; printf 'error'; return 1; }

  if [[ "$mode" == background ]]; then
    # The existing disowned launcher (ultra-oracle.sh's background branch), unchanged in shape: fd 9 is
    # $out.dispatch.err, `set -m` gives the consult its own process group, and the inner subshell is
    # the publisher that writes .rc last.
    if ! ( exec 9>|"$out.dispatch.err" || exit 1
      set -m 2>/dev/null || true
      ( set +e
        _uora_core background "$out" "$rd" "$tag" "$cap" "$deadline" "$bin" "$cpath"
        case "$(_uora_status_of "$rd")" in ok) st=0 ;; timeout) st=124 ;; unavailable) st=3 ;; *) st=1 ;; esac
        printf '%s' "$st" > "$out.rc.partial" && mv -f "$out.rc.partial" "$out.rc" ) </dev/null >/dev/null 2>&9 &
      disown 2>/dev/null || true
      exit 0
    ) >/dev/null; then
      _uora_cleanup "$rd" "$tag"; printf 'error'; return 1
    fi
    printf 'dispatched'; return 0
  fi
  _uora_core blocking "$out" "$rd" "$tag" "$cap" "$deadline" "$bin" "$cpath" </dev/null || :
  case "$(_uora_status_of "$rd")" in
    ok) printf 'ok'; return 0 ;;
    timeout) printf 'timeout'; return 124 ;;
    unavailable) printf 'skipped:unavailable'; return 3 ;;
    *) printf 'error'; return 1 ;;
  esac
}
