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
    elif .jsend.cls == "executed" and ((.jsend.text // "") | test("\\AERR (origin|not-home|focus|send)\\z")) then "error send"
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
