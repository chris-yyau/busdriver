#!/bin/bash
# ultra-oracle-verdict.sh — the parent's post-exit pass for the Chrome transport (ADR 0061): the stream
# audit (replay + join, spec 2026-11-01 §4), phase classification (§2), reason precedence (§4),
# acceptance and publication (§6). Sourced by ultra-oracle.sh. bash 3.2; jq only as $_UORA_JQ.

# The join and the facts the phase table needs, from the stream (tolerant: a torn stream line is
# skipped, so a crash mid-record cannot hide the records before it) and the merged log (strict).
# `read -d ''` returns 1 at end of input, which would abort an errexit caller at source time
# (run-retrieval-loop.sh sources this under `set -euo pipefail`), hence `|| :` plus the non-empty
# checks after each program. Not `X=$(cat <<'JQ' ...)`: bash 3.2 misparses a heredoc whose body
# has unbalanced quotes or parens inside $( ).
_UORA_FACTS_JQ='' _UORA_PHASE_JQ=''
read -r -d '' _UORA_FACTS_JQ <<'JQ' || :
def C: "mcp__claude-in-chrome__";
def ops: ["j-home","j-attached","j-send","j-id","j-poll","j-get","j-archive"];
# The result's first text block only: the live child appends a "Tab Context" block (and sometimes
# a reminder) after the tool's own text, and the guard's recorder reads tool_response[0] (Task 11).
def txt: if type == "string" then . elif type == "array" then (map(select(.type == "text") | .text) | first // "") else "" end;
def strip1: if endswith("\n") then .[:-1] else . end;
def grammar: test("\\A(READY|ATTACHED|SENT|UORA_ID [0-9a-f-]{36}|NOID|PENDING|DONE|SAVED [0-9]+ [0-9a-f]{64}|ARCHIVED|ERR [a-z0-9_-]+( [0-9]{3})?)\\z");
$S[0] as $s | $L[0] as $l | $G[0] as $g | $SIG[0] as $sig
| ([$s[] | select(.type == "assistant") | .message.content[]? | select(.type == "tool_use") | {id, name, input}]) as $tu
| ([$s[] | select(.type == "user") | .message.content[]? | select(.type == "tool_result")
    | {id: .tool_use_id, err: (.is_error // false), text: (.content | txt | strip1)}]) as $tr
| ([$s[] | select(.type == "result")] | last) as $final
| ([$l[] | select(.half == "pre")]) as $pre
| def opof($t): [ops[] | select(. == $t or $g.snippets[.] == $t)] | first;
  def cls($r): if $r == null then "none"
    elif ($r.text | contains($sig.deny_marker)) then "deny"
    elif ($sig.permission_refusal != null and ($r.text | contains($sig.permission_refusal))) then "refused"
    else "executed" end;
  [ $tu[] as $u
    | ([$pre[] | select(.id == $u.id)] | first) as $x
    | ([$tr[] | select(.id == $u.id)] | first) as $r
    | {id: $u.id, tool: ($u.name | ltrimstr(C)),
       op: (if $u.name == C + "javascript_tool" then ($x.input.text // opof($u.input.text // "")) else null end),
       log: ($x.d // null), cls: cls($r), err: ($r.err // false), text: ($r.text // null),
       bad: (if $x == null then "unlogged"
             elif $x.tool != $u.name then "tool"   # same id and input under another tool name
             elif $u.name == C + "javascript_tool" then
               (if ($x.input | del(.text)) != ($u.input | del(.text)) then "input"
                elif (ops | index($x.input.text)) == null then "input"
                elif $u.input.text != (if $sig.stream_js_text == "snippet" then $g.snippets[$x.input.text] else $x.input.text end)
                  then "input"
                else null end)
             elif $x.input != $u.input then "input"
             else null end)}
    | .bad = (.bad // (if .cls == "executed" and .log != "allow" then "executed-without-allow" else null end))
    # §5: a snippet result outside the closed grammar is a parse failure that ends the run as an
    # error, wherever it sits (before J-get or in the archive/close suffix), so it is a violation.
    # A tool-level error (is_error: the tab is gone, the extension disconnected) is not a snippet
    # result; the phase table and the disconnect signature classify those.
    | .bad = (.bad // (if .op != null and .cls == "executed" and (.err | not) and ((.text // "") | grammar | not)
                       then "nongrammar" else null end)) ] as $calls
# A tool-level error (is_error) is never evidence of success: no SAVED, UORA_ID, ARCHIVED or upload.
| def done($op): [$calls[] | select(.op == $op and .cls == "executed" and (.err | not)) | .text];
  ([done("j-get")[] | select(test("\\ASAVED [0-9]+ [0-9a-f]{64}\\z"))] | first) as $saved
| ([done("j-id")[] | select(test("\\AUORA_ID [0-9a-f-]{36}\\z"))] | first) as $uid
# A retryable deny can precede the upload that ran, so the successful one wins, else the last attempt.
| ([$calls[] | select(.tool == "file_upload")]) as $ups
| (([$ups[] | select(.cls == "executed" and (.err | not) and ((.text // "") | startswith("Uploaded")))] | first)
   // ($ups | last)) as $up
| ([$calls[] | select(.op == "j-send" and (.cls == "executed" or .cls == "none"))] | first) as $js
| ([$calls[] | select(.op != null and .cls == "executed" and (.text | test("\\AERR [a-z0-9_-]+( [0-9]{3})?\\z")))] | last) as $e
| {
    violations: [$calls[] | select(.bad != null) | {id, why: .bad}],
    forbidden: any($pre[]; .r == "forbidden"),
    noref: any($pre[]; .r == "no-ref"),
    saved: (if $saved == null then null else ($saved | split(" ") | {bytes: (.[1] | tonumber), sha: .[2]}) end),
    uora_id: (if $uid == null then null else ($uid | ltrimstr("UORA_ID ")) end),
    upload: (if $up == null then null
             else {cls: $up.cls, log: $up.log, uploaded: ($up.cls == "executed" and ($up.err | not) and ($up.text | startswith("Uploaded")))} end),
    jsend: (if $js == null then null else {cls: $js.cls, text: $js.text} end),
    err: (if $e == null then null else ($e.text | capture("\\AERR (?<code>[a-z0-9_-]+)( (?<http>[0-9]{3}))?\\z")) + {op: $e.op} end),
    archive: (done("j-archive") | last),
    tab: ([$l[] | select(.half == "post") | .rec.tab? // empty] | first // null),
    closed: any($calls[]; .tool == "tabs_close_mcp" and .cls == "executed" and (.err | not)),
    disconnect: (if $sig.disconnect_record == "result" then (($final // {}) | tojson | contains($sig.disconnect))
                 else any($tr[]; .text | contains($sig.disconnect)) end),
    auth: (($final // {}) | tojson | contains($sig.auth))
  }
JQ

# §2 phase table, applied to the facts. Only reached with a clean audit, no SAVED, no cutoff and no
# no-ref deny (§4 precedence 1-4).
read -r -d '' _UORA_PHASE_JQ <<'JQ' || :
def phase($pf):
  if .uora_id != null then "submitted"
  elif $pf == "submitting" then "submitting"
  elif .upload != null and (.upload.uploaded
       or (.upload.cls == "none" and (.upload.log == "allow" or .upload.log == null))) then "submitting"
  else "setup" end;
def presult($ph):
  if $ph == "setup" then
    if .disconnect then "unavailable extension-not-connected"
    elif .auth then "unavailable claude-unavailable"
    elif .err != null and .err.op == "j-home" and .err.code == "pro" then "error pro-unavailable"
    elif .err != null and .err.op == "j-home" and (.err.code == "not-home" or .err.code == "origin") then "error " + .err.code
    else "error child-died" end
  elif $ph == "submitting" then
    if .jsend == null then "error upload"
    elif .jsend.cls == "executed" and ((.jsend.text // "") | test("\\AERR (origin|not-home|focus|send|draft|schema)\\z")) then "error send"
    else "error submit-uncertain" end
  else
    if .err != null and (.err.code as $c | ["auth","rate","server","gone","binding","schema","origin","timeout","network"] | index($c)) != null
    then "error " + (if .err.code == "timeout" then "fetch-timeout" else .err.code end)
    else "error child-died" end
  end;
phase($pf) as $ph
| . + {phase: $ph, presult: presult($ph), cutoff: $cut,
       audit: (if ((.violations + $V) | map(select(.why != "forbidden")) | length) > 0 then "audit"
               elif .forbidden then "guard-denied" else "clean" end),
       violations: (.violations + $V), http: (.err.http // null), uploaded: (.upload.uploaded // false)}
JQ

# _uora_classify <rd>: merge the log, replay it through guard.sh's pure mode, join it to the stream.
_uora_classify() {
  local rd="$1" s="$1/scratch" f viol pf cut=false
  [ -n "$_UORA_FACTS_JQ" ] && [ -n "$_UORA_PHASE_JQ" ] || return 1   # a failed load fails closed
  { [ -f "$rd/decisions.jsonl" ] && cat "$rd/decisions.jsonl"
    for f in "$rd"/oob/l.*; do [ -f "$f" ] && cat "$f"; done; } > "$rd/log.merged" 2>/dev/null
  rm -rf "$s"; mkdir -m 700 "$s" "$s/oob" || return 1
  if ! $_UORA_JQ -s -c . "$rd/log.merged" > "$s/log.json" 2>/dev/null; then
    viol='[{"why":"log-parse"}]'; printf '[]\n' > "$s/log.json"   # a torn or absent line fails closed (§4)
  elif [ ! -f "$rd/guard.json.done" ]; then
    viol='[{"why":"no-guard-json"}]'
  else
    cp "$rd/guard.json.done" "$s/guard.json" && chmod 600 "$s/guard.json" \
      && printf '{}\n' > "$s/guard-state.json" && printf 'setup\n' > "$s/phase" || return 1
    viol="$(/usr/bin/env -i PATH=/usr/bin:/bin UORA_RUN_DIR="$s" /bin/bash "$_UORA_CHILD_DIR/guard.sh" replay < "$rd/log.merged" 2>/dev/null)" \
      || viol='[{"why":"replay"}]'
    $_UORA_JQ -e 'type == "array"' >/dev/null 2>&1 <<<"$viol" || viol='[{"why":"replay"}]'
  fi
  $_UORA_JQ -n -R -c '[inputs | fromjson? | select(type == "object")]' "$rd/stream.jsonl" > "$s/stream.json" 2>/dev/null \
    || printf '[]\n' > "$s/stream.json"
  [ -f "$rd/guard.json.done" ] && cp "$rd/guard.json.done" "$s/g.json" || printf '{"snippets":{}}\n' > "$s/g.json"
  pf="$(cat "$rd/phase" 2>/dev/null)"
  [ -f "$rd/cutoff" ] && cut=true
  $_UORA_JQ -n -c --slurpfile S "$s/stream.json" --slurpfile L "$s/log.json" --slurpfile G "$s/g.json" \
      --slurpfile SIG "$_UORA_CHILD_DIR/signatures.json" "$_UORA_FACTS_JQ" \
    | $_UORA_JQ -c --arg pf "$pf" --argjson cut "$cut" --argjson V "$viol" "$_UORA_PHASE_JQ"
}

# _uora_precedence: §4 "Reason precedence". A clean audit, SAVED and a verified answer is ok.
_uora_precedence() { # <audit> <saved> <accept> <cutoff> <noref> <presult>
  if [ "$1" != clean ]; then printf 'error %s' "$1"; return 0; fi
  if [ "$2" = 1 ]; then
    if [ "$3" = ok ]; then printf 'ok -'; else printf 'error %s' "$3"; fi
    return 0
  fi
  if [ "$4" = 1 ]; then printf 'timeout timeout'; return 0; fi
  if [ "$5" = 1 ]; then printf 'error upload'; return 0; fi
  printf '%s' "$6"
}

# ---- the §6 hint table ------------------------------------------------------------------------
_uora_hint() { # <reason> [<detail>]
  case "$1" in
    input) printf 'The consult input was rejected: %s.' "${2:-see the error above}" ;;
    internal) printf 'The adapter could not run the consult (%s); re-run it.' "${2:-unknown cause}" ;;
    claude-unavailable)
      if [ "${2:-}" = jq ]; then printf 'The browser guard needs /usr/bin/jq, which is missing (macOS 15 or later ships it).'
      else printf 'Claude Code is missing, too old, or not signed in.'; fi ;;
    extension-not-connected) printf 'Open a Chrome window, reconnect Claude in Chrome, and re-run the consult.' ;;
    not-macos) printf "The Chrome transport runs only on the operator's Mac." ;;
    pro-unavailable) printf 'ChatGPT is not set to Pro; select Pro once in Chrome.' ;;
    upload) printf 'The prompt attachment could not be uploaded.' ;;
    send) printf 'The composer could not send the prompt; a draft with the attachment may remain in the consult tab.' ;;
    tab-cleanup) printf 'A consult tab could not be closed: tab %s.' "${2:-?}" ;;
    gone) printf 'The consult conversation no longer exists.' ;;
    submit-uncertain) printf 'A send may have happened; check ChatGPT for an unarchived consult chat before retrying.' ;;
    child-died) printf 'The browser child exited before an answer was captured; re-run the consult.' ;;
    binding|schema|origin) printf "ChatGPT's page or answer did not match this consult (wrong model, attachment or page)." ;;
    not-home) printf "ChatGPT's page or answer did not match this consult (wrong model, attachment or page). The consult needs ChatGPT's UI in English (Attach files, Send, Remove <name>)." ;;
    fetch-timeout|network) printf 'ChatGPT could not be reached from the page.' ;;
    auth|rate|server) printf 'ChatGPT returned HTTP %s.' "${2:-?}" ;;
    guard-denied|audit) printf 'The browser child attempted an action outside its fixed steps.' ;;
    download-missing|hash-mismatch) printf 'The answer download was not found or did not match (searched: %s).' "${2:-the Chrome download dirs}" ;;
    verdict-floor) printf 'The answer was empty or below the verdict floor.' ;;
    timeout) printf "No answer within the cap; generation on ChatGPT's server is not cancelled." ;;
    archive) printf 'The consult chat could not be archived.' ;;
    *) printf 'The consult failed (%s).' "$1" ;;
  esac
}

# ---- acceptance (§6 "Finding the file", "Checks") ------------------------------------------------
# _uora_find_answer <tag> <bytes> <sha>: rc 0 prints the matching file; rc 1 a size match with the
# wrong hash; rc 2 nothing. A " (1)" copy is a candidate like any other.
_uora_find_answer() {
  local d f rc=2
  while IFS= read -r d; do
    [[ -d "$d" && ! -L "$d" ]] || continue
    for f in "$d/uora-$1.json" "$d/uora-$1 ("*").json"; do
      [[ -f "$f" && ! -L "$f" && ! -e "$f.crdownload" ]] || continue
      [ "$(wc -c < "$f" | tr -dc '0-9')" = "$2" ] || continue
      rc=1
      if [ "$(_uora_sha256 "$f")" = "$3" ]; then printf '%s' "$f"; return 0; fi
    done
  done < <(_uora_dl_dirs)
  return "$rc"
}

_uora_accept() { # <rd> <tag> <bytes> <sha> <uora_id> <deadline> <out>
  local rd="$1" tag="$2" bytes="$3" sha="$4" uid="$5" deadline="$6" out="$7" end f frc why
  end=$(( $(_uora_now) + _UORA_SETTLE_MAX )); [ "$end" -gt "$deadline" ] && end="$deadline"
  while :; do
    frc=0; f="$(_uora_find_answer "$tag" "$bytes" "$sha")" || frc=$?
    [ "$frc" = 0 ] && break
    [ "$(_uora_now)" -lt "$end" ] || break
    sleep 1
  done
  if [ "$frc" != 0 ]; then
    if [ "$frc" = 1 ]; then printf 'hash-mismatch'; else printf 'download-missing'; fi
    return 0
  fi
  mv -f -- "$f" "$rd/answer.json" 2>/dev/null || { printf 'download-missing'; return 0; }
  [ "$(_uora_sha256 "$rd/answer.json")" = "$sha" ] || { printf 'hash-mismatch'; return 0; }
  # shellcheck disable=SC2016  # single-quoted jq program: $names are jq variables, not shell ones.
  why="$($_UORA_JQ -r --arg tag "$tag" --arg id "$uid" '
    def str: type == "string";
    if type != "object"
       or (keys != ["assistant_message_id","attachment","content_type","end_turn","id","model","role","status","tag","text","user_message_id"])
       or ([.tag, .id, .user_message_id, .assistant_message_id, .role, .content_type, .status, .model, .attachment, .text] | all(str) | not)
       or ((.end_turn | type) != "boolean")
    then "schema"
    elif .tag != $tag or .id != $id or .role != "assistant" or .content_type != "text"
       or .status != "finished_successfully" or .end_turn != true
       or (.model | test("\\Agpt-[0-9]+(\\.[0-9]+)*-pro\\z") | not)
       or .attachment != ("uora-" + $tag + ".txt")
    then "binding" else "ok" end' "$rd/answer.json" 2>/dev/null)" || why=schema
  [ "$why" = ok ] || { printf '%s' "${why:-schema}"; return 0; }
  # ChatGPT's entity markup (U+E200 name U+E202 payload U+E201, e.g. a web-search citation) is
  # cut from the published text only; answer.json, which the hash binds, stays as downloaded.
  ( umask 077; $_UORA_JQ -j '.text | gsub("\ue200[^\ue201]*\ue201"; "")' "$rd/answer.json" > "$out.tmp" ) || { rm -f -- "$out.tmp"; printf 'schema'; return 0; }
  _ultra_oracle_verdict_ok "$out.tmp" || { rm -f -- "$out.tmp"; printf 'verdict-floor'; return 0; }
  printf 'ok'
}

# ---- publication (§6 "Publication", "Reasons") ---------------------------------------------------
_uora_finish() { # <mode> <out> <rd> <status> <reason> <facts> [<detail>]
  local mode="$1" out="$2" rd="$3" st="$4" why="$5" fx="${6:-}" det="${7:-}" uid tab closed arch errs="" hints="" h shown
  $_UORA_JQ -e 'type == "object"' >/dev/null 2>&1 <<<"$fx" || fx='{}'
  uid="$($_UORA_JQ -r '.uora_id // empty' <<<"$fx")"
  tab="$($_UORA_JQ -r '.tab // empty' <<<"$fx")"
  closed="$($_UORA_JQ -r '.closed // false' <<<"$fx")"
  arch="$($_UORA_JQ -r '.archive // empty' <<<"$fx")"
  if [ "$st" = ok ] && ! mv -f -- "$out.tmp" "$out"; then st=error why=internal det="the answer could not be published"; fi
  if [ "$st" != ok ]; then
    rm -f -- "$out.tmp"
    case "$why" in
      auth|rate|server) h="$(_uora_hint "$why" "$($_UORA_JQ -r '.http // "?"' <<<"$fx")")" ;;
      download-missing|hash-mismatch) h="$(_uora_hint "$why" "$(_uora_dl_dirs | paste -sd ',' -)")" ;;
      *) h="$(_uora_hint "$why" "$det")" ;;
    esac
    if [ "$why" = upload ]; then
      [ "$($_UORA_JQ -r '.uploaded // false' <<<"$fx")" = true ] && h="$h A draft with the attachment may remain in the consult tab."
      [ "$($_UORA_JQ -r '.noref // false' <<<"$fx")" = true ] && h="$h ChatGPT's UI must be in English (Attach files, Send, Remove <name>)."
    fi
    [ -n "$uid" ] && h="$h The consult chat $uid is left unarchived in ChatGPT and may still finish there; re-run the consult."
    errs="$why" hints="$h"
  elif [ "$arch" != ARCHIVED ]; then
    errs=archive hints="$(_uora_hint archive)"
  fi
  if [ -n "$tab" ] && [ "$closed" != true ]; then
    errs="${errs:+$errs$'\n'}tab-cleanup" hints="${hints:+$hints }$(_uora_hint tab-cleanup "$tab")"
  fi
  shown="$hints"   # the legacy-keys notice is already on stderr from the consult's start (§8: once)
  [ -n "${_UORA_NOTE_HINT:-}" ] && hints="${hints:+$hints }$_UORA_NOTE_HINT"   # the legacy-keys notice (Task 17)
  # Notices are published before the completion marker (record.json's status). A notice that cannot
  # be written must not vanish behind an `ok`: the run becomes `error internal`, and the notices go
  # to stderr in both modes so the operator still sees them.
  local pub=1
  if [ -n "$errs" ]; then
    # rm, then a noclobber write: a symlink planted at the .partial path is never written through.
    { rm -f -- "$out.err.partial" && ( set -C; printf '%s\n' "$errs" > "$out.err.partial" ) \
        && mv -f -- "$out.err.partial" "$out.err"; } 2>/dev/null || pub=0
  fi
  if [ -n "$hints" ]; then
    { rm -f -- "$out.hint.partial" && ( set -C; printf '%s\n' "$hints" > "$out.hint.partial" ) \
        && mv -f -- "$out.hint.partial" "$out.hint"; } 2>/dev/null || pub=0
  fi
  if [ "$pub" = 0 ]; then
    rm -f -- "$out.err.partial" "$out.hint.partial"
    echo "ultra-oracle: the consult's notices could not be written next to $out: ${hints:-$errs}" >&2
    [ "$st" = ok ] && st=error why=internal
  elif [ "$mode" = blocking ] && [ -n "$shown" ]; then
    echo "ultra-oracle: $shown" >&2
  fi
  # shellcheck disable=SC2016  # single-quoted jq program: $names are jq variables, not shell ones.
  _uora_record "$rd" --arg s "$st" --arg r "$why" --argjson f "$fx" --argjson e "$(_uora_now)" '
    . + {status: $s, reason: $r, phase: (if $s == "ok" then "captured" else ($f.phase // .phase) end),
         uora_id: ($f.uora_id // null), cutoff: ($f.cutoff // false),
         tab: ($f.tab // null), tab_closed: ($f.closed // false), finished: $e}' \
    || { echo "ultra-oracle: record.json could not be written; the consult reports error" >&2; return 1; }
}

# A missing or unreadable record.json, or one with no status, reads as `error`, so a failed
# completion write can never surface as `ok` (.rc 0).
_uora_status_of() { $_UORA_JQ -r '.status // "error"' "$1/record.json" 2>/dev/null || printf 'error'; }
