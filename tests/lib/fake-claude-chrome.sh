#!/bin/bash
# tests/lib/fake-claude-chrome.sh — a stand-in `claude -p --chrome` for the adapter suites (spec
# 2026-11-01 §11 "Adapter cases"). It replays $HOME/.uora-fake/scenario.jsonl through the REAL hook
# commands named in --settings (so the guard, its log and its state are the production ones), writes
# stream-json the way the live child does (fixture stream-ok.jsonl), and drops the answer download.
# The adapter launches it under env -i, so everything it reads lives under $HOME. bash 3.2.
set -u
JQ=/usr/bin/jq
F="$HOME/.uora-fake"
C=mcp__claude-in-chrome__

for a in "$@"; do
  if [ "$a" = --version ]; then
    # r3 version gate (Task 9 probe): `oldver` in $F/help reports a claude below any minimum.
    case "$(cat "$F/help" 2>/dev/null)" in oldver) echo '0.0.1 (Claude Code)' ;; *) echo '9.9.9 (Claude Code)' ;; esac
    exit 0
  fi
  if [ "$a" = --help ]; then
    case "$(cat "$F/help" 2>/dev/null)" in
      hang) while :; do sleep 1; done ;;
      old) printf 'Usage: claude [options] [prompt]\n  -p, --print\n'; exit 0 ;;
    esac
    printf 'Usage: claude [options] [prompt]\n  --chrome  Enable Claude in Chrome\n  --setting-sources <sources>\n'
    exit 0
  fi
done

printf '%s\n' "$*" >> "$F/launches"
N="$(wc -l < "$F/launches" | tr -dc 0-9)"
env | LC_ALL=C sort > "$F/env.$N"

settings="" prev=""
for a in "$@"; do [ "$prev" = --settings ] && settings="$a"; prev="$a"; done
[ -f "$settings" ] || exit 1
RD="${settings%/child-settings.json}"
TAG="${RD##*/run-}"
ID="$(cat "$F/id" 2>/dev/null || echo 0f0e0d0c-0b0a-4908-8706-050403020100)"
GUARD="$($JQ -r '.hooks.PreToolUse[0].hooks[0].args[-2]' "$settings")"
SIG="${GUARD%/guard.sh}/signatures.json"
FORM="$($JQ -r '.stream_js_text' "$SIG")"
REFUSAL="$($JQ -r '.permission_refusal' "$SIG")"
ONFAIL="$($JQ -r '.hooks.PreToolUse[0].hooks[0].onFailure // empty' "$settings")"
SAVED="" n=0

sub() { # <json> -> the same JSON with every placeholder filled in
  printf '%s' "$1" | $JQ -c --arg t "$TAG" --arg id "$ID" --arg p "$RD/uora-$TAG.txt" --arg s "$SAVED" \
    'walk(if type == "string" then gsub("@TAG@"; $t) | gsub("@ID@"; $id) | gsub("@STAGED@"; $p) | gsub("@SAVED@"; $s) else . end)'
}
hook() { # <PreToolUse|PostToolUse> <payload> -> the hook's stdout; returns its exit status
  local x
  local -a argv=()
  while IFS= read -r x; do argv+=("$x"); done < <($JQ -r --arg e "$1" '.hooks[$e][0].hooks[0] | .command, .args[]' "$settings")
  printf '%s' "$2" | "${argv[@]}" 2>/dev/null
}
full() { case "$1" in ToolSearch|Read) printf '%s' "$1" ;; *) printf '%s%s' "$C" "$1" ;; esac; }
stream_input() { # <name> <input> -> the input as the stream shows it (the r1 form, signatures.json)
  local op
  if [ "$1" = "${C}javascript_tool" ] && [ "$FORM" = snippet ]; then
    op="$(printf '%s' "$2" | $JQ -r '.text')"
    $JQ -c --arg op "$op" --argjson i "$2" '$i + {text: (.snippets[$op] // $op)}' "$RD/guard.json" 2>/dev/null \
      || $JQ -c --arg op "$op" --argjson i "$2" -n '$i'
  else printf '%s' "$2"; fi
}
tool_use() { # <id> <name> <input>
  $JQ -cn --arg id "$1" --arg n "$2" --argjson i "$(stream_input "$2" "$3")" \
    '{type: "assistant", message: {role: "assistant", content: [{type: "tool_use", id: $id, name: $n, input: $i}]}}'
}
tool_result() { # <id> <text> <is_error>
  $JQ -cn --arg id "$1" --arg t "$2" --argjson e "$3" \
    '{type: "user", message: {role: "user", content: [{type: "tool_result", tool_use_id: $id, content: [{type: "text", text: $t}], is_error: $e}]}}'
}
finish() { # <rc>
  $JQ -cn --argjson rc "$1" '{type: "result", subtype: (if $rc == 0 then "success" else "error_during_execution" end), is_error: ($rc != 0), result: "done"}'
  exit "$1"
}

# pre <id> <name> <input> -> sets V (allow|deny|refused), U (the input the tool runs with), W (deny text)
pre() {
  local out rc
  out="$(hook PreToolUse "$($JQ -cn --arg id "$1" --arg n "$2" --argjson i "$3" \
    '{hook_event_name: "PreToolUse", tool_name: $n, tool_input: $i, tool_use_id: $id, session_id: "fake", cwd: "/"}')")"
  rc=$?
  U="$3" W=""
  if [ "$rc" = 2 ]; then
    V=deny
    W="PreToolUse:$2 hook error: $(printf '%s' "$out" | $JQ -r '.hookSpecificOutput.permissionDecisionReason // "blocked"' 2>/dev/null)"
  elif [ "$rc" = 0 ] && [ "$(printf '%s' "$out" | $JQ -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)" = allow ]; then
    V=allow
    U="$(printf '%s' "$out" | $JQ -c --argjson i "$3" '.hookSpecificOutput.updatedInput // $i')"
  elif [ "$rc" != 0 ] && [ "$ONFAIL" = block ]; then
    V=deny W="PreToolUse:$2 hook error: hook failed (exit $rc)"   # the rendered onFailure blocks a crashed hook
  elif [ "$2" = ToolSearch ] || [ "$2" = Read ]; then
    V=allow   # pre-approved in --allowedTools: a hook that decides nothing lets them run (E16)
  else
    V=refused W="$REFUSAL"   # nothing is pre-approved for chrome tools: the permission layer refuses (E16)
  fi
}
post() { # <id> <name> <input> <result>
  hook PostToolUse "$($JQ -cn --arg id "$1" --arg n "$2" --argjson i "$3" --arg r "$4" \
    '{hook_event_name: "PostToolUse", tool_name: $n, tool_input: $i, tool_use_id: $id, session_id: "fake", cwd: "/",
      tool_response: [{type: "text", text: $r}]}')" >/dev/null
}
settle() { # <id> <name> <result> after pre(): emit the result and run PostToolUse for an allowed call
  if [ "$V" = allow ]; then post "$1" "$2" "$U" "$3"; tool_result "$1" "$3" false
  else tool_result "$1" "$W" true; fi
}

download() { # <spec-json>
  local spec="$1" fx mut dir name late never body bytes sha
  fx="$(printf '%s' "$spec" | $JQ -r '.fixture // "answer-ok.json"')"
  mut="$(printf '%s' "$spec" | $JQ -r '.mutate // "."')"
  dir="$(printf '%s' "$spec" | $JQ -r --arg h "$HOME" '.dir // ($h + "/Downloads")')"
  name="$(sub "$(printf '%s' "$spec" | $JQ -c '.name // "uora-@TAG@.json"')" | $JQ -r .)"
  late="$(printf '%s' "$spec" | $JQ -r '.late // 0')"
  never="$(printf '%s' "$spec" | $JQ -r '.never // false')"
  mkdir -p "$dir"
  body="$F/body.$$"
  $JQ -cj --arg t "$TAG" --arg id "$ID" \
    "walk(if type == \"string\" then gsub(\"@TAG@\"; \$t) | gsub(\"@ID@\"; \$id) else . end) | $mut" "$F/$fx" > "$body"
  bytes="$(wc -c < "$body" | tr -dc 0-9)"
  if command -v sha256sum >/dev/null 2>&1; then sha="$(sha256sum < "$body")"; else sha="$(shasum -a 256 < "$body")"; fi
  SAVED="SAVED $bytes ${sha%% *}"
  [ "$(printf '%s' "$spec" | $JQ -r '.badhash // false')" = true ] && SAVED="SAVED $bytes $(printf '0%.0s' $(seq 64))"
  SAVED="$(printf '%s' "$spec" | $JQ -r --arg s "$SAVED" '.saved // $s')"
  if [ "$never" = true ]; then mv -f "$body" "$dir/$name.crdownload"
  elif [ "$late" -gt 0 ]; then
    mv -f "$body" "$dir/$name.crdownload"
    # Real Chrome finishes a download outside the child's process group, so the parent's group
    # KILL never reaches it. Model that: the mover leaves the group (setpgrp) before it signals
    # ready, and the fake does not go on until it has, so the KILL cannot race the move.
    rm -f "$F/late-ready"
    /usr/bin/perl -e 'setpgrp(0, 0) or exit 1; open(my $r, ">", $ARGV[3]) and close($r);
      sleep $ARGV[0]; rename($ARGV[1], $ARGV[2]) or exit 1' \
      "$late" "$dir/$name.crdownload" "$dir/$name" "$F/late-ready" </dev/null >/dev/null 2>&1 &
    for _ in $(seq 50); do [ -e "$F/late-ready" ] && break; sleep 0.1; done
    [ -e "$F/late-ready" ] || { echo "fake: late mover never left the process group" >&2; exit 97; }
  else mv -f "$body" "$dir/$name"; fi
}

call() { # <step-json>
  local s="$1" t name input res id
  t="$(printf '%s' "$s" | $JQ -r .tool)"; name="$(full "$t")"
  input="$(sub "$(printf '%s' "$s" | $JQ -c '.input // {}')")"
  res="$(sub "$(printf '%s' "$s" | $JQ -c '.result // ""')" | $JQ -r .)"
  n=$((n + 1)); id="toolu_fake$n"
  tool_use "$id" "$name" "$input"
  pre "$id" "$name" "$input"
  [ "$(printf '%s' "$s" | $JQ -r '.die // false')" = true ] && exit 1
  settle "$id" "$name" "$res"
}

batch() { # <step-json> with .batch = [call…]
  local k cnt t name input
  local -a ids=() names=() res=() vs=() us=() ws=() uses=()
  cnt="$(printf '%s' "$1" | $JQ '.batch | length')"
  k=0
  while [ "$k" -lt "$cnt" ]; do
    t="$(printf '%s' "$1" | $JQ -r --argjson k "$k" '.batch[$k].tool')"
    n=$((n + 1)); ids+=("toolu_fake$n"); names+=("$(full "$t")")
    input="$(sub "$(printf '%s' "$1" | $JQ -c --argjson k "$k" '.batch[$k].input // {}')")"; us+=("$input")
    res+=("$(sub "$(printf '%s' "$1" | $JQ -c --argjson k "$k" '.batch[$k].result // ""')" | $JQ -r .)")
    uses+=("$($JQ -cn --arg id "toolu_fake$n" --arg nm "$(full "$t")" --argjson i "$(stream_input "$(full "$t")" "$input")" \
      '{type: "tool_use", id: $id, name: $nm, input: $i}')")
    k=$((k + 1))
  done
  printf '%s\n' "${uses[@]}" | $JQ -sc '{type: "assistant", message: {role: "assistant", content: .}}'
  k=0
  while [ "$k" -lt "$cnt" ]; do pre "${ids[$k]}" "${names[$k]}" "${us[$k]}"; vs+=("$V"); ws+=("$W"); us[$k]="$U"; k=$((k + 1)); done
  k=0
  while [ "$k" -lt "$cnt" ]; do V="${vs[$k]}" W="${ws[$k]}" U="${us[$k]}"; settle "${ids[$k]}" "${names[$k]}" "${res[$k]}"; k=$((k + 1)); done
}

$JQ -cn --arg rd "$RD" '{type: "system", subtype: "init", cwd: $rd, tools: [], model: "sonnet"}'
while IFS= read -r line; do
  [ -n "$line" ] || continue
  case "$(printf '%s' "$line" | $JQ -r 'keys[0]')" in
    batch) batch "$line" ;;
    download) download "$(printf '%s' "$line" | $JQ -c .download)" ;;
    record) cat "$F/$(printf '%s' "$line" | $JQ -r .record)"; exit 1 ;;   # the recorded result record is the last one
    sleep) sleep "$(printf '%s' "$line" | $JQ -r .sleep)" ;;
    hang) while :; do sleep 1; done ;;
    linger) ( sleep "$(printf '%s' "$line" | $JQ -r .linger)"; echo late > "$F/linger" ) >/dev/null 2>&1 &
            finish 0 ;;
    exit) finish "$(printf '%s' "$line" | $JQ -r .exit)" ;;
    *) call "$line" ;;
  esac
done < "$F/scenario.jsonl"
finish 0
