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
