# shellcheck shell=bash disable=SC2034   # sourced library: UORA_HAPPY, ERR, HINT are read by the suites
# tests/lib/uora-test-env.sh — shared setup for the Chrome-transport adapter suites (spec 2026-11-01
# §11). Source it after setting DIR to the checkout root. In-process suites call uora_inproc after
# sourcing the adapter; out-of-process suites rely on the PATH shims alone, since the seams are never
# read from the environment (§2).
UORA_JQ=/usr/bin/jq
UORA_QUERY='file input element for attaching files to the message composer'   # = _UORA_QUERY (Task 6)
UORA_N=0

uora_env() {
  T="$(mktemp -d)" && [ -n "$T" ] || { echo "FAIL: mktemp" >&2; exit 1; }   # never let the trap see "/"
  export HOME="$T/home"
  mkdir -p "$HOME/.claude" "$T/bin" "$T/out"
  uora_fake_home
  uora_shims "$T/bin"
  printf 'Critique this design.\n' > "$T/prompt.txt"
  trap 'pkill -f "$T/" 2>/dev/null; rm -rf "$T"' EXIT INT TERM
}

# uora_fake_home: the fake's data dir under the current $HOME (the child sees only HOME, §3).
uora_fake_home() {
  F="$HOME/.uora-fake"
  mkdir -p "$HOME/Downloads" "$F"
  local fx="$DIR/tests/fixtures/ultra-oracle"
  cp "$fx/answer-ok.json" "$fx/answer-cjk.json" "$fx/std-results.json" "$F/"
  # §7: the classifier matches only the captured records. Replay just the record that carries the
  # signature, so the live run's own tool_use ids (which no log of ours holds) never reach the audit.
  local sig="$DIR/scripts/hooks/ultra-oracle-child/signatures.json"
  $UORA_JQ -c 'select(.type == "result")' "$fx/stream-signed-out.jsonl" > "$F/auth-result.jsonl"
  $UORA_JQ -c 'select(.type == "result")' "$fx/stream-disconnected.jsonl" > "$F/disc-result.jsonl"
  UORA_DISC_FORM="$($UORA_JQ -r .disconnect_record "$sig")"
  UORA_DISC_TEXT="$($UORA_JQ -r --arg d "$($UORA_JQ -r .disconnect "$sig")" '
    select(.type == "user") | .message.content[]? | select(.type == "tool_result")
    | (.content | if type == "string" then . else map(select(.type == "text") | .text) | join("") end)
    | select(contains($d))' "$fx/stream-disconnected.jsonl" | head -1)"
}

# uora_shims <bindir>: uname (Darwin), open and claude for out-of-process callers, which cannot
# reassign the seams (§2); put <bindir> first on PATH. The trusted resolver refuses a claude inside
# the caller's checkout and fails closed when the caller's directory is in no git repo
# (resolve-cli.sh dir_in_checkout, :634-644), so an out-of-process suite runs its wrappers from a git
# repo that does not contain <bindir>.
uora_shims() {
  printf '#!/bin/sh\ncase "$1" in -s) echo Darwin ;; *) exec /usr/bin/uname "$@" ;; esac\n' > "$1/uname"
  cat > "$1/open" <<'EOF'
#!/bin/sh
echo "$*" >> "$HOME/.uora-fake/opens"
case "$(cat "$HOME/.uora-fake/open-mode" 2>/dev/null)" in
  fail) exit 1 ;;
  hang) while :; do sleep 1; done ;;
esac
exit 0
EOF
  cp "$DIR/tests/lib/fake-claude-chrome.sh" "$1/claude"
  chmod +x "$1/uname" "$1/open" "$1/claude"
}

uora_inproc() {   # after `source scripts/lib/ultra-oracle.sh`
  _ULTRA_ORACLE_PLATFORM=Darwin
  _ULTRA_ORACLE_OPEN_CMD=("$T/bin/open")
  _ULTRA_ORACLE_CLAUDE_BIN="$T/bin/claude"
}

_uora_std() { # <step> [<result override>] -> one scenario line
  local r js='{"action":"javascript_exec","text":"%s","tabId":101}'
  case "$1" in
    ctx|nav|find|upload|close)
      local tool input
      case "$1" in
        ctx) tool=tabs_context_mcp input='{"createIfEmpty":true}' ;;
        nav) tool=navigate input='{"url":"https://chatgpt.com/","tabId":101}' ;;
        find) tool=find input="$($UORA_JQ -cn --arg q "$UORA_QUERY" '{query: $q, tabId: 101}')" ;;
        upload) tool=file_upload input='{"paths":["@STAGED@"],"ref":"ref_7","tabId":101}' ;;
        close) tool=tabs_close_mcp input='{"tabId":101}' ;;
      esac
      r="${2-$($UORA_JQ -r --arg t "$tool" '.[$t]' "$F/std-results.json")}"
      $UORA_JQ -cn --arg t "$tool" --argjson i "$input" --arg r "$r" '{tool: $t, input: $i, result: $r}' ;;
    home|attached|send|id|poll|get|archive)
      local op="j-$1" dflt
      case "$1" in home) dflt=READY ;; attached) dflt=ATTACHED ;; send) dflt=SENT ;; id) dflt='UORA_ID @ID@' ;;
                   poll) dflt=DONE ;; get) dflt=@SAVED@ ;; archive) dflt=ARCHIVED ;; esac
      # shellcheck disable=SC2059
      $UORA_JQ -cn --argjson i "$(printf "$js" "$op")" --arg r "${2-$dflt}" '{tool: "javascript_tool", input: $i, result: $r}' ;;
    dl) printf '{"download":{}}\n' ;;
    exit0) printf '{"exit":0}\n' ;;
    *) echo "uora_scenario: unknown step $1" >&2; return 1 ;;
  esac
}

# uora_scenario <step…>: a step is a standard name, name=RESULT, name! (the call dies after its
# PreToolUse hook), @disc or @auth (the captured disconnect or signed-out record, §7), or a raw JSON
# scenario line.
uora_scenario() {
  local s
  : > "$F/scenario.jsonl"
  for s in "$@"; do
    case "$s" in
      '{'*) printf '%s\n' "$s" ;;
      @disc) if [ "$UORA_DISC_FORM" = tool_result ]; then _uora_std ctx "$UORA_DISC_TEXT"; printf '{"exit":1}\n'
             else printf '{"record":"disc-result.jsonl"}\n'; fi ;;
      @auth) printf '{"record":"auth-result.jsonl"}\n' ;;
      *'!') _uora_std "${s%!}" | $UORA_JQ -c '. + {die: true}' ;;
      *=*) _uora_std "${s%%=*}" "${s#*=}" ;;
      *) _uora_std "$s" ;;
    esac
  done >> "$F/scenario.jsonl"
}
UORA_HAPPY="ctx nav home find upload attached send id poll dl get archive close exit0"

uora_launches() { if [ -f "$F/launches" ]; then wc -l < "$F/launches" | tr -dc 0-9; else echo 0; fi; }
uora_opens() { if [ -f "$F/opens" ]; then wc -l < "$F/opens" | tr -dc 0-9; else echo 0; fi; }
# uora_only_record: every run dir holds only record.json (§2 "Cleanup").
uora_only_record() {
  local d
  for d in "$HOME/.cache/busdriver/ultra-oracle"/run-*; do
    [ -d "$d" ] || continue
    [ "$(ls -A "$d")" = record.json ] || return 1
  done
}

# uora_run <blocking|background> <step…>: one consult through _uora_chrome_consult. Sets OUT, ST (the
# blocking token, or the background .rc), ERR (first .err line) and HINT.
uora_run() {
  local mode="$1" i=0
  shift
  uora_scenario "$@" || return 1
  UORA_N=$((UORA_N + 1)); OUT="$T/out/c$UORA_N.md"
  rm -f "$F/launches" "$F/opens" "$F/linger" "$F/overlap" "$F/skew"; rmdir "$F/active.d" 2>/dev/null
  if [ "$mode" = blocking ]; then
    ST="$(_uora_chrome_consult --prompt-file "$T/prompt.txt" --out "$OUT" --mode blocking ${UORA_CAP:+--timeout-cap-seconds "$UORA_CAP"})"
  else
    ST="$(_uora_chrome_consult --prompt-file "$T/prompt.txt" --out "$OUT" --mode background ${UORA_CAP:+--timeout-cap-seconds "$UORA_CAP"})"
    if [ "$ST" = dispatched ]; then
      while [ ! -f "$OUT.rc" ] && [ "$i" -lt 600 ]; do sleep 0.2; i=$((i + 1)); done
      ST="rc=$(cat "$OUT.rc" 2>/dev/null)"
    fi
  fi
  ERR="$(head -1 "$OUT.err" 2>/dev/null)"
  HINT="$(cat "$OUT.hint" 2>/dev/null)"
}
