#!/bin/bash
# guard.sh — PreToolUse guard and PostToolUse recorder for the UltraOracle Chrome child, plus the
# parent's pure replay mode. Spec docs/specs/2026-11-01-ultraoracle-chrome-transport-design.md §4;
# ADR 0061. Registered twice in the child's --settings, exec form, through
# hooks/gate-scripts/lib/contained-launch.sh closed (ADR 0049).
#   guard.sh pre     explicit allow (exit 0 + allow JSON) or deny (exit 2 + deny JSON)
#   guard.sh post    record one value from the tool's own result; never blocks
#   guard.sh replay  stdin = merged decision log; prints the JSON array of violations
# Expected values come ONLY from $UORA_RUN_DIR/guard.json, never from the tool input.
# bash 3.2 floor: no associative arrays, mapfile/readarray, [[ -v ]], namerefs, ${x,,}/${x^^},
# $BASHPID. jq only by absolute path — PATH is /usr/bin:/bin.
set -u
JQ=/usr/bin/jq
MODE="${1:-}"
RD="${UORA_RUN_DIR:-}"
_allowed=0
_held=0
_reason=forbidden

_deny_json() {
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"uora-guard: deny %s"}}\n' "$1"
  printf 'uora-guard: deny %s\n' "$1" >&2
}
# Every PreToolUse path that has not printed an explicit allow — a crash included — ends as a deny.
_on_exit() {
  local rc=$?
  if [ "$_held" = 1 ]; then rmdir -- "$RD/guard.lock" 2>/dev/null; fi
  if [ "$MODE" = pre ] && [ "$_allowed" != 1 ]; then _deny_json "$_reason"; exit 2; fi
  exit "$rc"
}
trap _on_exit EXIT

case "$MODE" in pre|post|replay) ;; *) exit 2 ;; esac
case "$RD" in /*) ;; *) exit 2 ;; esac
if [ ! -d "$RD" ] || [ -L "$RD" ]; then exit 2; fi
# guard.json must be a regular, non-symlink, mode-0600 file. Re-checked under the lock as the
# post-exit fence: the parent renames it to guard.json.done before it audits (§4).
_g_ok() {
  [ -f "$RD/guard.json" ] && [ ! -L "$RD/guard.json" ] \
    && [ -n "$(find "$RD/guard.json" -prune -type f -perm 600 2>/dev/null)" ]
}
_g_ok || exit 2

read -r -d '' LIB <<'JQ'
def C: "mcp__claude-in-chrome__";
def six: ["tabs_context_mcp","tabs_close_mcp","navigate","find","file_upload","javascript_tool"] | map(C + .);
def ops: ["j-home","j-attached","j-send","j-id","j-poll","j-get","j-archive"];
def init: {tab: null, find_count: null, ref: null, navigated: false, ready: false, attached: false,
           sent: false, saved: false, n: {ctx: 0, nav: 0, find: 0, upload: 0, send: 0, get: 0, archive: 0}};
def only($k): type == "object" and ((keys - $k) | length) == 0;
def deny($r): {d: "deny", r: $r, k: null, u: null, ph: null};
def allow($k): {d: "allow", r: null, k: $k, u: null, ph: null};
def bump($k): if $k == null then . else .n[$k] += 1 end;
def strip1: if endswith("\n") then .[:-1] else . end;

# decide: {s, g, t, i} -> {d, r, k, u, ph}. One row of the spec §4 allow table per branch.
def decide:
  .s as $s | .g as $g | .t as $t | (.i // {}) as $i
  | (if $s.n.upload == 0 then "pre" elif $s.sent then "sent" else "up" end) as $c
  | def gate($shape; $dep; $k):
      if ($shape | not) then deny("forbidden")
      elif ($dep | not) then deny("not-yet")
      elif $s.tab == null then deny("not-yet")
      elif $i.tabId != $s.tab then deny("forbidden")
      else allow($k) end;
    if $t == "ToolSearch" then
      if ($i | only(["query","max_results"])) and (($i.query | type) == "string")
         and ($i.query | startswith("select:"))
         and (($i.query | ltrimstr("select:") | split(",") | sort) == (six | sort))
      then allow(null) else deny("forbidden") end
    elif $t == C + "tabs_context_mcp" then
      if $c == "pre" and $i == {createIfEmpty: true} and $s.n.ctx == 0 then allow("ctx") else deny("forbidden") end
    elif $t == C + "navigate" then
      gate($c == "pre" and ($i | only(["url","tabId"])) and $i.url == $g.url and $s.n.nav == 0; true; "nav")
    elif $t == C + "find" then
      gate($c == "pre" and ($i | only(["query","tabId"])) and $i.query == $g.query and $s.n.find == 0; $s.ready; "find")
    elif $t == C + "file_upload" then
      if ($c == "pre" and ($i | only(["paths","ref","tabId"])) and $i.paths == [$g.staged] and $s.n.upload == 0 | not)
        then deny("forbidden")
      elif ($s.ready | not) or $s.find_count == null then deny("not-yet")
      elif $s.find_count != "1" then deny("no-ref")
      elif $s.tab == null then deny("not-yet")
      elif $i.tabId != $s.tab or $i.ref != $s.ref then deny("forbidden")
      else allow("upload") + {ph: "submitting"} end
    elif $t == C + "javascript_tool" then
      ($i.text // null) as $op
      | if (($i | only(["action","text","tabId"])) and $i.action == "javascript_exec" and (ops | any(. == $op)) | not)
          then deny("forbidden")
        else (if $op == "j-home" then gate($c == "pre"; $s.navigated; null)
              elif $op == "j-attached" then gate($c == "up"; true; null)
              elif $op == "j-send" then gate($c == "up" and $s.n.send == 0; $s.attached; "send")
              elif $op == "j-id" or $op == "j-poll" then gate($c == "sent"; true; null)
              elif $op == "j-get" then gate($c == "sent" and $s.n.get == 0; true; "get")
              else gate($c == "sent" and $s.n.archive == 0 and $s.saved; true; "archive") end)
             | if .d == "allow" then .u = ($i + {text: $g.snippets[$op]}) else . end
        end
    elif $t == C + "tabs_close_mcp" then gate($i | only(["tabId"]); true; null)
    else deny("forbidden") end;

# ctxtab: the own tab id from the tabs_context_mcp result text (fixture tabs-context-result.txt).
def ctxtab: (try fromjson catch null)
  | if type == "object" and ((.availableTabs // []) | length) == 1 and (.availableTabs[0].tabId | type) == "number"
    then .availableTabs[0].tabId else null end;
def opof($g): . as $x | [ops[] | select(. == $x or $g.snippets[.] == $x)] | (first // null);

# record: {s, g, t, i, p} -> {rec, s}. The six values of spec §4, read from tool_response[0].text.
def record:
  .s as $s | .g as $g | .t as $t | (.i // {}) as $i
  | ((.p.tool_response // null)
     | if type == "array" and length > 0 and ((.[0].text // null) | type) == "string" then .[0].text else "" end
     | strip1) as $x
  | (if $t == C + "tabs_context_mcp" then
       ($x | ctxtab) as $id | (if $id != null and $s.tab == null then {tab: $id} else null end)
     elif $t == C + "navigate" then {navigated: true}
     elif $t == C + "find" then
       [ $x | split("\n")[] | capture("^- (?<ref>ref_[0-9]+): button \"+Attach files\"+ \\(file\\)( - |$)") ] as $m
       | {find_count: (if ($m | length) == 0 then "0" elif ($m | length) == 1 then "1" else "many" end),
          ref: (if ($m | length) == 1 then $m[0].ref else null end)}
     elif $t == C + "javascript_tool" then
       (($i.text // "") | opof($g)) as $op
       | if $op == "j-home" and $x == "READY" then {ready: true}
         elif $op == "j-attached" and $x == "ATTACHED" then {attached: true}
         elif $op == "j-send" and $x == "SENT" then {sent: true}
         elif $op == "j-get" and ($x | test("\\ASAVED [0-9]+ [0-9a-f]{64}\\z")) then {saved: true}
         else null end
     else null end) as $rec
  | {rec: $rec, s: ($s + ($rec // {}))};

def checked: if (.tool_use_id | type) != "string" or (.tool_name | type) != "string" then error("bad payload") else . end;

# replay($g): re-decide every logged PreToolUse line from fresh state and apply every logged record.
def replay($g):
  reduce .[] as $l ({s: init, bad: []};
    if ($l | type) != "object" then .bad += [{why: "parse"}]
    elif $l.d == "post-lost" then .bad += [{id: $l.id, why: "post-lost"}]
    elif $l.half == "pre" and $l.r == "busy" then .
    elif $l.half == "pre" then
      ({s: .s, g: $g, t: $l.tool, i: $l.input} | decide) as $x
      | if $x.d != $l.d or $x.r != $l.r then .bad += [{id: $l.id, why: "mismatch"}]
        elif $x.d == "allow" then .s |= bump($x.k)
        else . end
    elif $l.half == "post" and $l.d == "rec" then .s += ($l.rec // {})
    else .bad += [{id: $l.id, why: "unknown"}] end)
  | .bad;
JQ

# shellcheck disable=SC2016  # single-quoted jq program: $names are jq variables, not shell ones.
PRE='checked | . as $p
| {s: (init * ($S[0] // {})), g: $G[0], t: $p.tool_name, i: ($p.tool_input // {})} as $in
| ($in | decide) as $x
| ($in.s | if $x.d == "allow" then bump($x.k) else . end) as $ns
| "\($x.d) \($x.r // "-") \($x.ph // "-")",
  ($ns | tojson),
  ({id: $p.tool_use_id, half: "pre", tool: $p.tool_name, input: ($p.tool_input // {}), d: $x.d, r: $x.r, rec: null} | tojson),
  ($x.u | tojson)'
# shellcheck disable=SC2016  # single-quoted jq program: $names are jq variables, not shell ones.
POST='checked | . as $p
| {s: (init * ($S[0] // {})), g: $G[0], t: $p.tool_name, i: ($p.tool_input // {}), p: $p} | record
| (.s | tojson),
  ({id: $p.tool_use_id, half: "post", tool: $p.tool_name, input: ($p.tool_input // {}), d: "rec", r: null, rec: .rec} | tojson)'

# _oob <line>: busy and post-lost lines are the only ones written outside the lock — each to its own
# new file whose name is not derived from the payload (§4 "Decision log").
_oob() {
  local f
  f="$(mktemp "$RD/oob/l.XXXXXXXX")" || return 1
  printf '%s\n' "$1" > "$f"
}
_phase_write() {
  local t
  t="$(mktemp "$RD/phase.XXXXXXXX")" || return 1
  printf '%s\n' "$1" > "$t" && mv -f -- "$t" "$RD/phase"
}
_state_write() {
  printf '%s\n' "$1" > "$RD/guard-state.json.tmp" && mv -f -- "$RD/guard-state.json.tmp" "$RD/guard-state.json"
}

pre_main() {
  local payload res d r ph ns log upd line
  payload="$(cat)" || exit 2
  # PreToolUse tries the lock ONCE: nothing has run yet, so the child can reissue the call (§4).
  if ! mkdir -- "$RD/guard.lock" 2>/dev/null; then
    _reason=busy
    line="$(printf '%s' "$payload" | $JQ -c '{id: .tool_use_id, half: "pre", tool: .tool_name, input: (.tool_input // {}), d: "deny", r: "busy", rec: null}' 2>/dev/null)" \
      && _oob "$line"
    exit 2
  fi
  _held=1
  _g_ok || exit 2      # guard.json renamed away after the child exited: deny and write nothing
  res="$(printf '%s' "$payload" | $JQ -r --slurpfile S "$RD/guard-state.json" --slurpfile G "$RD/guard.json" "$LIB
$PRE" 2>/dev/null)" || exit 2
  { IFS=' ' read -r d r ph; IFS= read -r ns; IFS= read -r log; IFS= read -r upd; } <<EOF
$res
EOF
  case "$d" in allow|deny) ;; *) exit 2 ;; esac
  [ -n "$ns" ] && [ -n "$log" ] && [ -n "$upd" ] || exit 2
  [ "$r" = - ] || _reason="$r"
  # Order under the lock: phase (upload only) -> log line -> state rename -> unlock -> answer.
  # A failed step is a failed transition, so the call is denied (§4).
  if [ "$ph" = submitting ]; then _phase_write submitting || { _reason=forbidden; exit 2; }; fi
  printf '%s\n' "$log" >> "$RD/decisions.jsonl" || { _reason=forbidden; exit 2; }
  _state_write "$ns" || { _reason=forbidden; exit 2; }
  rmdir -- "$RD/guard.lock" && _held=0
  [ "$d" = allow ] || exit 2
  if [ "$upd" = null ]; then
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":"uora-guard: allow"}}\n' || exit 2
  else
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":"uora-guard: allow","updatedInput":%s}}\n' "$upd" || exit 2
  fi
  _allowed=1
  exit 0
}

post_main() {
  local payload res ns log line s0
  payload="$(cat)" || exit 1
  # PostToolUse waits for the lock (10 ms steps, at most 5 s): its tool already ran, so its
  # record must not be dropped. Giving up writes a post-lost line, which the audit fails on.
  s0=$SECONDS
  until mkdir -- "$RD/guard.lock" 2>/dev/null; do
    if [ $(( SECONDS - s0 )) -ge 5 ]; then
      line="$(printf '%s' "$payload" | $JQ -c '{id: .tool_use_id, half: "post", tool: .tool_name, input: (.tool_input // {}), d: "post-lost", r: null, rec: null}' 2>/dev/null)" \
        && _oob "$line"
      exit 1
    fi
    sleep 0.01
  done
  _held=1
  _g_ok || exit 1
  res="$(printf '%s' "$payload" | $JQ -r --slurpfile S "$RD/guard-state.json" --slurpfile G "$RD/guard.json" "$LIB
$POST" 2>/dev/null)" || exit 1
  { IFS= read -r ns; IFS= read -r log; } <<EOF
$res
EOF
  [ -n "$ns" ] && [ -n "$log" ] || exit 1
  printf '%s\n' "$log" >> "$RD/decisions.jsonl" || exit 1
  _state_write "$ns" || exit 1
  rmdir -- "$RD/guard.lock" && _held=0
  exit 0
}

replay_main() {
  # Pure: reads the merged log on stdin and the scratch copy of guard.json; writes no file.
  $JQ -s -c --slurpfile G "$RD/guard.json" "$LIB
replay(\$G[0])" || exit 3
  exit 0
}

case "$MODE" in
  pre) pre_main ;;
  post) post_main ;;
  replay) replay_main ;;
esac
