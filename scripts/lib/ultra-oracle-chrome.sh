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
_uora_render_guard() {
  local rd="$1" tag="$2" op
  local -a args=()
  for op in $_UORA_OPS; do
    [ -f "$_UORA_CHILD_DIR/$op.js" ] && [ ! -L "$_UORA_CHILD_DIR/$op.js" ] || return 1
    args+=(--rawfile "${op//-/_}" "$_UORA_CHILD_DIR/$op.js")
  done
  ( umask 077
    $_UORA_JQ -n --arg tag "$tag" --arg staged "$rd/uora-$tag.txt" --arg url "$_UORA_URL" --arg q "$_UORA_QUERY" "${args[@]}" '
      def r: gsub("__UORA_TAG__"; $tag);
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
