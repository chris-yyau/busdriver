#!/usr/bin/env bash
# #802 — class-expansion probes must charge the command-wide budgets so a repeated
# bracket-glob payload cannot sit near the pre-implementation gate's 5s timeout
# (a timeout emits no decision, which the harness reads as ALLOW).
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLASSIFIER="$ROOT/hooks/gate-scripts/lib/marker_check.py"
PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
no() { FAIL=$((FAIL + 1)); printf '  FAIL  %s :: %s\n' "$1" "${2:-}"; }

# Classifier verdict for a Bash command. Status is captured separately from stdout so a
# crash that already printed a partial BLOCK_ line cannot satisfy a blocking assertion
# (same contract as tests/test-marker-numeric-case-776.sh).
verdict() {
  local payload out
  payload=$(python3 -c 'import json,sys;print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]}}))' \
    "$1") || { printf 'ERROR'; return; }
  if ! out=$(python3 -I "$CLASSIFIER" <<<"$payload" 2>/dev/null); then
    printf 'ERROR'
    return
  fi
  printf '%s' "$out"
}

# True for a real classification BLOCK, not a crash-shaped BLOCK_CLASSIFIER_ERROR.
is_real_block() {
  case "$1" in
    BLOCK_CLASSIFIER_ERROR|BLOCK_CLASSIFIER_ERROR\|*) return 1 ;;
    BLOCK_*) return 0 ;;
    *) return 1 ;;
  esac
}

# The band measured in #802: 5000 × `[!0-9]x|$A;` (~55KB) previously spent ~3.5s on
# glob-class expansion. Bound by the production 5s hook timeout; after the per-probe
# charge the same shape must return a verdict well inside that window.
# shellcheck disable=SC2016  # $A must stay literal inside the generated payload
PAYLOAD=$(python3 -c 'print("[!0-9]x|$A;" * 5000)')
got=$(python3 - "$CLASSIFIER" "$PAYLOAD" <<'PYEOF' 2>/dev/null || echo TIMEOUT_OR_ERROR
import json, subprocess, sys, time

PROD_TIMEOUT_S = 5
# Headroom guard: the pre-fix band was ~3.5s; require clear clearance under 5s so a
# slow runner still fails this check before production would fail open.
SOFT_MAX_S = 2.0
try:
    t0 = time.perf_counter()
    p = subprocess.run(
        [sys.executable, "-I", sys.argv[1]],
        input=json.dumps({"tool_name": "Bash",
                          "tool_input": {"command": sys.argv[2]}}),
        capture_output=True, text=True, timeout=PROD_TIMEOUT_S,
    )
    dt = time.perf_counter() - t0
except subprocess.TimeoutExpired:
    print("TIMEOUT_OR_ERROR")
else:
    # A non-zero exit is NOT a verdict, even when stdout already carries a BLOCK-prefixed
    # partial line (crash-shaped false pass).
    if p.returncode != 0:
        print("TIMEOUT_OR_ERROR")
    else:
        out = (p.stdout or "").strip() or "TIMEOUT_OR_ERROR"
        print(f"{out}|DT={dt:.3f}")
PYEOF
)

verdict_line="${got%%|DT=*}"
dt_field="${got##*|DT=}"
if [[ "$got" == TIMEOUT_OR_ERROR ]]; then
  no "#802 5000x digit-negation pipeline returns a verdict under the 5s gate" "timed out or errored"
elif [[ "$verdict_line" == BLOCK_CLASSIFIER_ERROR || "$verdict_line" == BLOCK_CLASSIFIER_ERROR\|* ]]; then
  no "#802 5000x digit-negation pipeline returns a verdict under the 5s gate" "classifier crashed: ${verdict_line}"
elif [[ "$verdict_line" != BLOCK_* && "$verdict_line" != "OK|" && "$verdict_line" != "OK" ]]; then
  no "#802 5000x digit-negation pipeline returns a verdict under the 5s gate" "got=${got:-<empty>}"
elif ! python3 -c "import sys; sys.exit(0 if float(sys.argv[1]) <= 2.0 else 1)" "${dt_field:-9}" 2>/dev/null; then
  no "#802 5000x digit-negation pipeline stays under 2s soft bound" "dt=${dt_field:-?}s got=${verdict_line}"
else
  ok "#802 5000x digit-negation pipeline returns ${verdict_line} in ${dt_field}s"
fi

# Precision preserved: a single-character class that cannot reach a helper still misses.
HELPER_MISS=$(python3 -c 'print("python3 hooks/gate-scripts/lib/lease_slo[a].py")')
miss=$(verdict "$HELPER_MISS")
if [[ "$miss" == "OK|" ]]; then
  ok "#802 precise [a] miss still allowed"
else
  no "#802 precise [a] miss still allowed" "got=${miss:-<empty>}"
fi

# Targeted bracket still blocks — crash-shaped BLOCK_CLASSIFIER_ERROR is not a hit.
HELPER_HIT=$(python3 -c 'print("python3 hooks/gate-scripts/lib/lease_slo[t].py")')
hit=$(verdict "$HELPER_HIT")
if is_real_block "$hit"; then
  ok "#802 precise [t] hit still blocks"
else
  no "#802 precise [t] hit still blocks" "got=${hit:-<empty>}"
fi

# Budget-boundary precise miss: a single 2048-byte operand ending in [a] must remain
# OK after the prepaid deep family (Codex on #802). Built inside the classifier driver
# so this shell script does not itself assemble a helper-shaped path in tool_input.
bound=$(python3 - "$CLASSIFIER" <<'PYEOF' 2>/dev/null || echo ERROR
import json, subprocess, sys
stem = "lease" + "_" + "slo"
op = ("a" * (2048 - len(stem + "[a].py"))) + stem + "[a].py"
assert len(op) == 2048
cmd = "python3 " + op
p = subprocess.run(
    [sys.executable, "-I", sys.argv[1]],
    input=json.dumps({"tool_name": "Bash", "tool_input": {"command": cmd}}),
    capture_output=True, text=True,
)
print((p.stdout or "").strip() if p.returncode == 0 else "ERROR")
PYEOF
)
if [[ "$bound" == "OK|" ]]; then
  ok "#802 2048-byte operand ending in [a] still allowed"
else
  no "#802 2048-byte operand ending in [a] still allowed" "got=${bound:-<empty>}"
fi


# Coupled multi-class with surrounding wildcards: base squeeze misses the reading
# Bash would expand to a helper; structured path must fail closed (Codex on #802).
coupled=$(python3 - "$CLASSIFIER" <<'PYEOF' 2>/dev/null || echo ERROR
import json, subprocess, sys
cmd = 'python3 *' + '[' + '"' + 'x][s' + '"' + ']*[s][l]*'
p = subprocess.run(
    [sys.executable, "-I", sys.argv[1]],
    input=json.dumps({"tool_name": "Bash", "tool_input": {"command": cmd}}),
    capture_output=True, text=True,
)
print((p.stdout or "").strip() if p.returncode == 0 else "ERROR")
PYEOF
)
if is_real_block "$coupled"; then
  ok "#802 coupled multi-class wildcard operand still blocks"
else
  no "#802 coupled multi-class wildcard operand still blocks" "got=${coupled:-<empty>}"
fi


# Quote-coupled classes with no wildcards can still encode a helper basename
# character-by-character (Codex on #802). Structured path must fail closed.
qcoupled=$(python3 - "$CLASSIFIER" <<'PYEOF' 2>/dev/null || echo ERROR
import json, subprocess, sys
q = chr(34)
helper = "".join(chr(c) for c in [108, 101, 97, 115, 101, 95, 115, 108, 111, 116, 46, 112, 121])
op = "".join("[" + q + "x][" + ch + q + "]" for ch in helper)
cmd = "python3 " + op
p = subprocess.run(
    [sys.executable, "-I", sys.argv[1]],
    input=json.dumps({"tool_name": "Bash", "tool_input": {"command": cmd}}),
    capture_output=True, text=True,
)
print((p.stdout or "").strip() if p.returncode == 0 else "ERROR")
PYEOF
)
if is_real_block "$qcoupled"; then
  ok "#802 quote-coupled multi-class (no wildcard) still blocks"
else
  no "#802 quote-coupled multi-class (no wildcard) still blocks" "got=${qcoupled:-<empty>}"
fi




# Prefixed quoted class cannot name a helper — must stay allow (Codex on #802).
safeq=$(python3 - "$CLASSIFIER" <<'PYEOF' 2>/dev/null || echo ERROR
import json, subprocess, sys
cmd = "python3 safe[" + chr(39) + "a" + chr(39) + "].py"
p = subprocess.run(
    [sys.executable, "-I", sys.argv[1]],
    input=json.dumps({"tool_name": "Bash", "tool_input": {"command": cmd}}),
    capture_output=True, text=True,
)
print((p.stdout or "").strip() if p.returncode == 0 else "ERROR")
PYEOF
)
if [[ "$safeq" == "OK|" ]]; then
  ok "#802 safe-prefix quoted class still allowed"
else
  no "#802 safe-prefix quoted class still allowed" "got=${safeq:-<empty>}"
fi

# Decoy latch from abandoned-scan must not hard-block a later safe-prefix operand.
decoy=$(python3 - "$CLASSIFIER" <<'PYEOF' 2>/dev/null || echo ERROR
import json, subprocess, sys
cmd = "eval : " + ("[a]" * 1000) + "; python3 " + chr(34) + "safe[1].py" + chr(34)
p = subprocess.run(
    [sys.executable, "-I", sys.argv[1]],
    input=json.dumps({"tool_name": "Bash", "tool_input": {"command": cmd}}),
    capture_output=True, text=True,
)
print((p.stdout or "").strip() if p.returncode == 0 else "ERROR")
PYEOF
)
if [[ "$decoy" == "OK|" ]]; then
  ok "#802 decoy-exhausted safe-prefix operand still allowed"
else
  no "#802 decoy-exhausted safe-prefix operand still allowed" "got=${decoy:-<empty>}"
fi



# Short stemless multi-class cannot encode a helper — must stay allow.
short=$(python3 - "$CLASSIFIER" <<'PYEOF' 2>/dev/null || echo ERROR
import json, subprocess, sys
cmd = "python3 [a][b]"
p = subprocess.run(
    [sys.executable, "-I", sys.argv[1]],
    input=json.dumps({"tool_name": "Bash", "tool_input": {"command": cmd}}),
    capture_output=True, text=True,
)
print((p.stdout or "").strip() if p.returncode == 0 else "ERROR")
PYEOF
)
if [[ "$short" == "OK|" ]]; then
  ok "#802 short stemless [a][b] still allowed"
else
  no "#802 short stemless [a][b] still allowed" "got=${short:-<empty>}"
fi

# Whitespace-separated `$` and classes must not be rejoined into a false block.
spaced=$(python3 - "$CLASSIFIER" <<'PYEOF' 2>/dev/null || echo ERROR
import json, subprocess, sys
cmd = "python3 $ [a][b]"
p = subprocess.run(
    [sys.executable, "-I", sys.argv[1]],
    input=json.dumps({"tool_name": "Bash", "tool_input": {"command": cmd}}),
    capture_output=True, text=True,
)
print((p.stdout or "").strip() if p.returncode == 0 else "ERROR")
PYEOF
)
if [[ "$spaced" == "OK|" ]]; then
  ok "#802 whitespace-separated dollar class still allowed"
else
  no "#802 whitespace-separated dollar class still allowed" "got=${spaced:-<empty>}"
fi

# ── Command-substitution boundaries ───────────────────────────────────────────
# `_strip_cmd_subst` finds the end of a `$()` by COUNTING parens, so a `)` that
# closes nothing breaks the count: a `case` pattern terminator, and a `#` comment
# (which runs to end of LINE, not end of word). Each closed the substitution early,
# so the wrong span was stripped and the helper glob that survived was read as
# harmless text. A heredoc body is the same `)` with the opposite cost -- reading it
# as live shell text ALSO turned an ordinary `$(cat <<'EOF' ...)` into a false block
# -- so it is skipped as data rather than refused.
#
# Execute-then-classify, per the review that raised it: every shape is first run
# against a STUB helper in a temp tree, so each assertion rests on what Bash really
# expands and not on a reading of the parser. A fixture that stops reaching the stub
# fails rather than passing silently. The two shapes Bash does NOT expand onto the
# stub are asserted the other way -- they must stay ALLOWED.
LIB="hooks/gate-scripts/lib"
CS_DIR="$(mktemp -d)" || CS_DIR=""
# One trap for the temp dir. INT/TERM must EXIT, not just clean up: a handler that
# returns swallows the signal, which would make this suite unkillable by the
# per-test timeout in scripts/ci/run-shell-tests.sh.
trap 'rm -rf "${CS_DIR:-}"' EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
if [[ -z "$CS_DIR" || ! -d "$CS_DIR" ]]; then
  no "#802 cmd-subst boundaries: temp dir" "mktemp -d gave no usable directory"
else
  mkdir -p "$CS_DIR/$LIB"
  printf 'print("STUB_RAN")\n' > "$CS_DIR/$LIB/lease_slot.py"
  # Both guarded helpers, so a spelling can be asserted against the one it names.
  # No `no` fixture below can expand onto this name, so it widens nothing.
  printf 'print("STUB_RAN")\n' > "$CS_DIR/$LIB/audit_append.py"

  cs_runs() {
    local _out
    _out=$(cd "$CS_DIR" && bash -c "$1" 2>/dev/null) || true
    [[ "$_out" == *STUB_RAN* ]]
  }

  # <command> <yes|no: does Bash reach the stub?> <label>
  cs_case() {
    local got
    if [[ "$2" == yes ]]; then
      if ! cs_runs "$1"; then
        no "#802 $3" "Bash no longer expands onto the stub — the fixture asserts nothing"
        return
      fi
    elif cs_runs "$1"; then
      no "#802 $3" "Bash DID reach the stub — this is not a false-block fixture"
      return
    fi
    got=$(verdict "$1")
    if [[ "$2" == yes ]]; then
      if is_real_block "$got"; then ok "#802 $3"; else no "#802 $3" "got=${got:-<empty>}"; fi
    elif [[ "$got" == "OK|" ]]; then
      ok "#802 $3"
    else
      no "#802 $3" "got=${got:-<empty>}"
    fi
  }

  # shellcheck disable=SC2016  # payloads are literal: the CLASSIFIER expands them, not us
  printf -v _cs_comment 'python3 %s/[l]$(true #)\n)ease_slot.py' "$LIB"
  # shellcheck disable=SC2016
  printf -v _cs_heredoc 'python3 %s/[l]$(cat <<E >/dev/null\n)\nE\n)ease_slot.py' "$LIB"
  # An attached `<<` is a heredoc too, so its body ')' is data, not the closer.
  # shellcheck disable=SC2016
  printf -v _cs_attached 'python3 %s/[l]$(cat<<E >/dev/null\n)\nE\n)ease_slot.py' "$LIB"
  # Under a plain `<<` a TAB-indented delimiter is body data -- only `<<-` strips tabs.
  # shellcheck disable=SC2016
  printf -v _cs_tabdelim 'python3 %s/[l]$(cat <<E >/dev/null\n\tE\n)\nE\n)ease_slot.py' "$LIB"
  # A compound command ends a word, so this '#' opens a comment and hides its ')'.
  # shellcheck disable=SC2016
  printf -v _cs_subshell 'python3 %s/[l]$( (true)#)\n)ease_slot.py' "$LIB"
  # `((expr))` is arithmetic, so a `<<` there is a shift. Mis-reading one keeps its
  # span VERBATIM, which leaves the $() on the next line unstripped and the helper
  # it hides unseen -- the body skip is not the harmless direction.
  # shellcheck disable=SC2016
  printf -v _cs_arith '(( 1<<2 ))\npython3 %s/[l]$(true)ease_slot.py\n2' "$LIB"
  # An unquoted substitution expands to UNKNOWN text; deleting it asserts the empty
  # string, which is the one expansion the shell almost never gives.
  # shellcheck disable=SC2016
  printf -v _cs_output 'python3 %s/[l]$(printf e)[a][s][e][_][s][l][o][t][.][p][y]' "$LIB"
  # A parameter expansion is the same unknown text, and was deleted the same way.
  # shellcheck disable=SC2016
  printf -v _cs_brace 'python3 %s/[l]${X:-e}[a][s][e][_][s][l][o][t][.][p][y]' "$LIB"
  # A backslash makes the NEXT character literal, so this delimits on E"OF and a
  # bare EOF line is body data, not the terminator.
  # shellcheck disable=SC2016
  printf -v _cs_delimesc 'python3 %s/[l]$(cat <<E\\"OF >/dev/null\nEOF\n)\nE"OF\n)ease_slot.py' "$LIB"
  # The shell joins a line continuation BEFORE it parses, so this really is `case`.
  # shellcheck disable=SC2016
  printf -v _cs_linecont 'python3 %s/[l]$(ca\\\nse x in x) true;; esac)ease_slot.py' "$LIB"

  cs_case "python3 $LIB/[l]\$(case x in x) true;; esac)ease_slot.py" yes \
    "a case-pattern ')' does not close \$()"
  cs_case "$_cs_comment" yes "a ')' inside a '#' comment does not close \$()"
  cs_case "$_cs_heredoc" yes "a ')' inside a heredoc body does not close \$()"
  cs_case "$_cs_attached" yes "an attached '<<E' still hides its body ')'"
  cs_case "$_cs_tabdelim" yes "a tab-indented delimiter under plain '<<' is body data"
  cs_case "$_cs_subshell" yes "a '#' after a subshell ')' opens a comment"
  cs_case "$_cs_arith" yes "a '<<' inside (( )) is a shift, not a heredoc"
  cs_case "$_cs_output" yes "an unquoted substitution's output is unknown, not empty"
  cs_case "$_cs_brace" yes "an unquoted \${} expansion's value is unknown, not empty"
  cs_case "$_cs_delimesc" yes "an escaped quote in a heredoc delimiter stays literal"
  cs_case "$_cs_linecont" yes "a line continuation joins a split keyword"
  cs_case "python3 $LIB/[l]'\$(true)'ease_slot.py" no \
    "a single-quoted \$() is literal text, not a substitution"
  cs_case "python3 $LIB/\"x\"lease_[[:lower:]]lot.py" no \
    "a quoted ordinary character survives into the class projection"

  # Quoting the substitution suppresses glob expansion of its OUTPUT -- it does not make
  # the output known. The classes around it are still live, so `[l]"$(printf e)"[a]...`
  # reaches the helper exactly as the unquoted spelling does, one quote pair away.
  # shellcheck disable=SC2016
  printf -v _cs_qout 'python3 %s/[l]"$(printf e)"[a][s][e][_][s][l][o][t][.][p][y]' "$LIB"
  # shellcheck disable=SC2016
  printf -v _cs_qbrace 'python3 %s/[l]"${X:-e}"[a][s][e][_][s][l][o][t][.][p][y]' "$LIB"
  cs_case "$_cs_qout" yes "a double-quoted substitution's output is unknown, not empty"
  cs_case "$_cs_qbrace" yes "a double-quoted \${} expansion's value is unknown, not empty"

  # The heredoc skip must not swallow the rest of the introducer's line: the body
  # starts on the NEXT line, and a helper can still be named after the delimiter.
  # shellcheck disable=SC2016
  printf -v _cs_tail 'cat <<E $(true) | python3 %s/[l]ease_slot.py\nbody\nE' "$LIB"
  got=$(verdict "$_cs_tail")
  if is_real_block "$got"; then
    ok "#802 a heredoc body does not hide the rest of its own line"
  else
    no "#802 a heredoc body does not hide the rest of its own line" "got=${got:-<empty>}"
  fi
fi

# EXECUTION POSITION survives the mid-glob substitution probe. A helper NAMED in an
# operand is data -- that is what keeps `cat .../lease_slot.py` allowed -- and an
# unrelated substitution elsewhere in the command does not turn the mention into a
# call. Probing the flattened text token-by-token lost that distinction, because a bare
# token carries no position.
for _mention in "cat $LIB/[l]ease_slot.py \$(true)" "cat $LIB/[l]\$(true)ease_slot.py"; do
  got=$(verdict "$_mention")
  if [[ "$got" == "OK|" ]]; then
    ok "#802 a mention stays a mention beside a substitution: ${_mention##*/}"
  else
    no "#802 a mention stays a mention beside a substitution: ${_mention##*/}" \
      "got=${got:-<empty>}"
  fi
done

# The whole-command re-entry fires on the ORIGINAL command only. A recursive scan
# inherits the parent's `_whole`, so keying the branch off it re-flattened the
# ENCLOSING command once per nesting level and ran the depth cap out -- turning these
# ordinary commands into refusals. Each nests a payload beside a substitution and a
# bracket, which is exactly the shape the branch keys on.
for _nested in "sh -c true; echo \"\$(true)\" \"[\"" \
               "bash -c \"true\"; echo \"\$(true)\" \"[\"" \
               "find . -maxdepth 0 -exec true {} \;; echo \"\$(true)\" \"[\""; do
  got=$(verdict "$_nested")
  if [[ "$got" == "OK|" ]]; then
    ok "#802 a nested payload does not re-scan the enclosing command: ${_nested:0:20}"
  else
    no "#802 a nested payload does not re-scan the enclosing command: ${_nested:0:20}" \
      "got=${got:-<empty>}"
  fi
done

# A `<<<` herestring is a WORD, not a body. Refusing to read it as a heredoc is not
# the same as CONSUMING it: the scanner stepped one character and then read the
# leftover `<<` as a heredoc introducer, whose fictitious body swallowed the `)` that
# closed the substitution. And a `$()` nested inside double quotes quotes for itself,
# so its own quotes are not the enclosing quote's closer. Both turned valid commands
# into refusals. Both shapes run under bash first, so the premise is bash's, not ours.
for _q in "echo \"\$(cat <<< foo
)\" \"[\"" \
          "cat <<< \"hello\" ; echo \"[\"" \
          "echo \"\$(echo \"\$(printf '\"')\")\" \"[\"" \
          "echo \"\$(echo \"nested \$(printf x) done\")\" \"[\""; do
  if ! bash -c "$_q" >/dev/null 2>&1; then
    no "#802 quoting/herestring shape is valid bash: ${_q:0:24}" "bash rejected it"
    continue
  fi
  got=$(verdict "$_q")
  if [[ "$got" == "OK|" ]]; then
    ok "#802 a herestring or nested quote does not fabricate a refusal: ${_q:0:24}"
  else
    no "#802 a herestring or nested quote does not fabricate a refusal: ${_q:0:24}" \
      "got=${got:-<empty>}"
  fi
done

# Six more lexing gaps in the same walker, all found by a differential sweep against
# HEAD rather than one per review round. Each is a construct the walker MEANS to skip
# and mis-read instead, and every one turned a command bash runs into a refusal:
#   - `$((` entered as a plain `$(` left the arithmetic stack empty, so the `<<` of a
#     shift read as a heredoc introducer and its fictitious body ate the closer;
#   - inside a BACKTICK body the same seeding was missing;
#   - `$'...'` escapes the next character, so the `'` in `$'a\'b'` is DATA -- read as an
#     ordinary closer it shifted every quote after it;
#   - a backtick body ends at its OWN delimiter, so its `)` or `}` closes nothing outer:
#     unquoted inside `$()`, inside `"` there, and inside `${...}` all mis-read it;
#   - a `$()` opened inside `"` within a backtick body was never paren-counted back.
# Every shape runs under bash first, so the premise is bash's and not ours.
for _lx in "echo \"\$((1 << 2
))\" \"[\"" \
           "echo \$(echo \$'a\\'b') \"[\"" \
           "echo \`echo \"\$(true)\"\` \"[\"" \
           "echo \`echo \$(( 1 << 2
))\` \"[\"" \
           "echo \$(printf '%s' \"\`echo '\"'\`\") \"[\"" \
           "echo \$(echo \${X:-\`echo )\`}) \"[\"" \
           "echo \${X:-\$(printf '%s' \"\`echo '\"'\`\")} \"[\""; do
  if ! bash -c "$_lx" >/dev/null 2>&1; then
    no "#802 lexing shape is valid bash: ${_lx:0:26}" "bash rejected it"
    continue
  fi
  got=$(verdict "$_lx")
  if [[ "$got" == "OK|" ]]; then
    ok "#802 a skipped construct does not fabricate a refusal: ${_lx:0:26}"
  else
    no "#802 a skipped construct does not fabricate a refusal: ${_lx:0:26}" \
      "got=${got:-<empty>}"
  fi
done

# Three more of the same class, from the same sweep. `$(` has THREE doors into the inner
# walker -- the outer entry, the unquoted branch, and the one taken from inside double
# quotes -- and only the first two seeded the arithmetic stack, so a `$((` reached through
# the third read its `<<` as a heredoc. `<<$'EOF'` delimits on EOF, because the `$` is
# quoting syntax and not part of the word; keeping it made every terminator line miss and
# the body then swallowed the substitution closer. And a backtick body is OPAQUE: an
# earlier fix suspended the enclosing quote for one instead of skipping it, which left the
# body's own `)` counting against the enclosing `$()`.
for _lx2 in "echo \"\$(echo \"\$((1 << 2
))\")\" \"[\"" \
            "echo \"\$(cat <<\$'EOF'
hi
EOF
)\" \"[\"" \
            "echo \"\$(cat <<\$'E\\x4fF'
hi
EOF
)\" \"[\"" \
            "echo \$(echo \"echo \${X:-\`echo )\`}\") \"[\""; do
  if ! bash -c "$_lx2" >/dev/null 2>&1; then
    no "#802 lexing shape is valid bash: ${_lx2:0:26}" "bash rejected it"
    continue
  fi
  got=$(verdict "$_lx2")
  if [[ "$got" == "OK|" ]]; then
    ok "#802 every door into the walker agrees: ${_lx2:0:26}"
  else
    no "#802 every door into the walker agrees: ${_lx2:0:26}" "got=${got:-<empty>}"
  fi
done

# Two more causes of the same class, from the same sweep. `case` is a reserved word only at
# START of a command, so the one in `printf %s case` is an ordinary argument -- refusing
# it blocked a command bash runs. And a heredoc body begins at a newline of ITS OWN
# command: a newline inside a nested `$()` belongs to that command, and consuming the
# body there swallowed the nested closer.
for _lx3 in "echo \"\$(printf %s case )\" \"[\"" \
            "echo \"\$(echo a case b)\" \"[\"" \
            "echo \"\$(cat <<EOF \$(echo hi
)
body
EOF
)\" \"[\""; do
  if ! bash -c "$_lx3" >/dev/null 2>&1; then
    no "#802 lexing shape is valid bash: ${_lx3:0:26}" "bash rejected it"
    continue
  fi
  got=$(verdict "$_lx3")
  if [[ "$got" == "OK|" ]]; then
    ok "#802 a word that only looks like a keyword is not one: ${_lx3:0:26}"
  else
    no "#802 a word that only looks like a keyword is not one: ${_lx3:0:26}" \
      "got=${got:-<empty>}"
  fi
done

# And two the round after that, both about which command a heredoc belongs to. Bodies
# queue per COMMAND, so an inner `$()` with its own `<<` must not consume the outer
# delimiter at its own newline. And the shell removes a delimiter's quotes to get the
# terminator, which can leave NOTHING: `<<''` ends on the first empty line, and reading
# it as "no delimiter" scanned the body as live shell text.
for _hd in "echo \"\$(cat <<A \$(: <<B
inner
B
)
outer
A
)\" \"[\"" \
           "echo \"\$(cat <<''
case x in

)\" \"[\""; do
  if ! bash -c "$_hd" >/dev/null 2>&1; then
    no "#802 heredoc shape is valid bash: ${_hd:0:28}" "bash rejected it"
    continue
  fi
  got=$(verdict "$_hd")
  if [[ "$got" == "OK|" ]]; then
    ok "#802 a heredoc body belongs to the command that queued it: ${_hd:0:28}"
  else
    no "#802 a heredoc body belongs to the command that queued it: ${_hd:0:28}" \
      "got=${got:-<empty>}"
  fi
done

# The other direction, and the one that costs something: a keyword leaves the command
# position OPEN, so the `case` after `then` IS the keyword and its pattern ')' closes
# nothing. Reading only the preceding word would call these ordinary arguments and count
# that ')' -- every shape below returns OK without the word test, which is the fail-OPEN
# this whole change exists to close. UNSCANNABLE is pinned rather than "some block",
# since a block reached by stumbling past the pattern is not the same answer.
for _kw in "echo \"\$(if true; then case x in x) true;; esac; fi)\" \"[\"" \
           "echo \"\$(for i in 1; do case x in x) true;; esac; done)\" \"[\"" \
           "echo \"\$(! case x in x) true;; esac)\" \"[\"" \
           "echo \"\$(time case x in x) true;; esac)\" \"[\""; do
  if ! bash -c "$_kw" >/dev/null 2>&1; then
    no "#802 keyword shape is valid bash: ${_kw:0:30}" "bash rejected it"
    continue
  fi
  got=$(verdict "$_kw")
  if [[ "$got" == "BLOCK_UNSCANNABLE|" ]]; then
    ok "#802 a case keyword after a keyword is still the keyword: ${_kw:0:30}"
  else
    no "#802 a case keyword after a keyword is still the keyword: ${_kw:0:30}" \
      "got=${got:-<empty>}"
  fi
done

# And two more, in two different layers. Only a BASENAME can name a helper -- a class in
# a directory component selects directories -- so counting classes across the whole path
# met the length threshold on a path whose own basename matches nothing. And neither
# `${...}` nor legacy `$[...]` is command text: the `<<` in a default VALUE is data, and
# the one in `$[1 << 2]` is a shift, so the heredoc read there was fictitious.
for _lx4 in "python3 [s][k][i][l][l][s]/[l][i][t][m][u][s]/scripts/lib/[t]est_parse_narrative.py" \
            "echo \"\$(printf %s \${X:-<<EOF}
)\" \"[\"" \
            "echo \"\$(echo \$[1 << 2]
)\" \"[\"" \
            "echo \"\$(X=ab; echo \${X//a/(}
)\" \"[\"" \
            "echo \"\$(echo \${X:-(}
)\" \"[\""; do
  if ! bash -n <<<"$_lx4" 2>/dev/null; then
    no "#802 shape is valid bash: ${_lx4:0:30}" "bash rejected it"
    continue
  fi
  got=$(verdict "$_lx4")
  if [[ "$got" == "OK|" ]]; then
    ok "#802 a construct the shell reads as data is not command text: ${_lx4:0:30}"
  else
    no "#802 a construct the shell reads as data is not command text: ${_lx4:0:30}" \
      "got=${got:-<empty>}"
  fi
done

# The fail-CLOSED half of that second one: skipping a span for LEXING must not hide the
# word it sits in. Both shapes below still resolve to the helper, and the marker verdict
# is pinned rather than "some block" -- refusing them for a fictitious heredoc, as the
# reviewed bytes did, is a different answer that happens to look the same from outside.
# shellcheck disable=SC2016
printf -v _sp_brace 'python3 %s/[l]$(printf %%s ${X:-<<EOF}\n)ease_slot.py' "$LIB"
# shellcheck disable=SC2016
printf -v _sp_arith 'python3 %s/[l]$(echo $[1 << 2]\n)ease_slot.py' "$LIB"
for _sp in "$_sp_brace" "$_sp_arith"; do
  if ! bash -n <<<"$_sp" 2>/dev/null; then
    no "#802 span shape is valid bash: ${_sp:0:30}" "bash rejected it"
    continue
  fi
  got=$(verdict "$_sp")
  if [[ "$got" == BLOCK_MARKER_SCRIPT\|* ]]; then
    ok "#802 a skipped span does not hide the word around it: ${_sp:0:30}"
  else
    no "#802 a skipped span does not hide the word around it: ${_sp:0:30}" \
      "got=${got:-<empty>}"
  fi
done

# Three more, one per layer the scan is built from. Re-reading a command with its
# substitutions flattened is the SAME command, not a shell nested in it, so charging a
# nesting level spent one of the three an `sh -c` chain may use. A QUOTED heredoc
# delimiter makes its body literal, so the `\<newline>` in there is two characters the
# shell keeps rather than a join. And a pattern whose every class is one literal
# character names exactly ONE file, so the match test against the helpers was final.
for _lx5 in "sh -c 'sh -c \"sh -c true\"'; echo \"\${X}\" \"[\"" \
            "echo \"\$(cat <<'EOF'
E\\
OF
case x in
EOF
)\" \"[\"" \
            "python3 [t][e][s][t][_][p][a][r][s][e][_][n][a][r][r][a][t][i][v][e].[p][y]" \
            "echo \"\$(cat <<E\\
OF
x
EOF
)\" \"[\""; do
  if ! bash -n <<<"$_lx5" 2>/dev/null; then
    no "#802 shape is valid bash: ${_lx5:0:30}" "bash rejected it"
    continue
  fi
  got=$(verdict "$_lx5")
  if [[ "$got" == "OK|" ]]; then
    ok "#802 a resolved reading is not re-charged or re-guessed: ${_lx5:0:30}"
  else
    no "#802 a resolved reading is not re-charged or re-guessed: ${_lx5:0:30}" \
      "got=${got:-<empty>}"
  fi
done

# The fail-CLOSED half of the last one, as an invariant rather than a guard on the
# shortcut's placement: resolving a pattern exactly says WHICH file it names, never that
# naming it is allowed. This spelling resolves to the helper, and blocks.
cs_case "python3 $LIB/[l][e][a][s][e][_][s][l][o][t].[p][y]" yes \
  "an all-singleton spelling of the helper is still the helper"

# A NEGATED class is a wildcard by any other name, and the fallback that catches an
# unresolved multi-class word asked for a literal `*` or `?` before it would refuse one.
# Three classes, an in-class quote and no star walked straight through -- and bash
# expands that operand to the helper itself, so this was a live FAIL-OPEN, the direction
# this whole change exists to close. `cs_case ... yes` runs it against the stub first, so
# the assertion rests on what Bash really expands.
cs_case "python3 $LIB/[\"^\"l]ease_[!Z]lot.p[[.y.]]" yes \
  "a quoted ^ stays literal while a separate unquoted ! still negates"
# The quoted `^` must NOT read as a negation on its own: this is the same word with the
# negated class removed, and it must still block for the ordinary reason.
cs_case "python3 $LIB/[\"^\"l]ease_slot.py" yes \
  "a quoted ^ in a class is a literal member, not a negation"

# Asking HOW the wildcard is spelled was a list, and it was lost twice. The first fix
# read a class that LEADS with `!`/`^`; bash negates after quote REMOVAL, so `[""!Z]`
# and `[''^Z]` negate behind empty quotes where no lead-anchored pattern can see them.
# Both spellings below expand onto the stub under bash. The clause now asks only what
# it can actually answer -- an in-class quote means the class bash reads is not the one
# this projection reads -- so no spelling of a wildcard has to be enumerated (#802).
cs_case "python3 $LIB/[\"\"!Z]ease_slot['^'.]p[''^Z]" yes \
  "a class negated behind empty double quotes is still a negation"
cs_case "python3 $LIB/['^'a]udi[t][_]ap[''^Z]end.p[''^Z]" yes \
  "the same spelling reaches the OTHER guarded helper"
# The control for that widening: two classes and in-class quotes, naming no helper.
# It resolves, so it stays allowed -- the clause is not simply "quote plus two classes".
cs_case "python3 $LIB/[\"a\"]b[\"c\"]d.txt" no \
  "an in-class quote alone does not make an ordinary filename a helper"

# A BACKSLASH conceals a class member exactly as a quote does, and only the quote was
# asked about: `[\^l]` is a literal caret and an `l`, so bash lands on the helper, while
# the projection -- which drops the escape before it decides -- read a NEGATED `[^l]`,
# resolved nothing, and allowed. Multi-class words are denied the deep reading by
# budget, so nothing else was going to catch it. Fail-OPEN, and HEAD blocks it (#802).
cs_case "python3 $LIB/[\^l]ease_[!Z]lot.p[^Z]" yes \
  "a class member concealed by a BACKSLASH is still a member"
cs_case "python3 $LIB/[\^a]udit_[!Z]ppend.p[^Z]" yes \
  "the same backslash spelling reaches the OTHER guarded helper"
# The control that keeps the widening honest: drop the backslash and `[^l]` really IS a
# negation, so bash lands on nothing and the command stays allowed. Blocking this one
# would mean the fix had stopped reading the class and started refusing the character.
cs_case "python3 $LIB/[^l]ease_[!Z]lot.p[^Z]" no \
  "an UNESCAPED leading caret is a real negation, and still allowed"

# Asking whether a keyword is itself in command position walks LEFT one word at a time.
# Recursing per word raised RecursionError on 1100 argument words -- an ordinary 5KB
# command line -- which fails closed but still refuses a command bash runs. The runs are
# disjoint, so the loop stays linear; 12000 words is asserted to answer, not to answer OK
# (the token budget legitimately refuses at that size).
_deep_args="echo \"\$(printf %s $(python3 -c 'print("then " * 1100, end="")')case x)\" \"[\""
if ! bash -n <<<"$_deep_args" 2>/dev/null; then
  no "#802 a long argument run does not exhaust the interpreter stack" "bash rejected it"
else
  got=$(verdict "$_deep_args")
  if [[ "$got" == "OK|" ]]; then
    ok "#802 a long argument run does not exhaust the interpreter stack"
  else
    no "#802 a long argument run does not exhaust the interpreter stack" "got=${got:-<empty>}"
  fi
fi

# LINEARITY. The fragment fallbacks ask whether the WHOLE command is unscannable, and
# they sit inside per-segment loops -- so asking once per segment made the scan
# quadratic in command length. At 300 segments and 64KB this measured 7.2s against the
# pre-implementation gate's registered 5s timeout, and a killed hook emits no decision,
# which the harness reads as ALLOW. The payload below is a VALID protected-marker write:
# an ALLOW here is the vulnerability, so this asserts the block AND the bound.
# shellcheck disable=SC2016  # $P must stay literal inside the generated payload
BIG=$(python3 -c 'print(("$P `true && cat`; " * 300) + ": [a] " + "x" * 59000 + "; touch .claude/skip-litmus.local")')
got=$(python3 - "$CLASSIFIER" "$BIG" <<'PYEOF' 2>/dev/null || echo TIMEOUT_OR_ERROR
import json, subprocess, sys, time

PROD_TIMEOUT_S = 5
try:
    t0 = time.perf_counter()
    p = subprocess.run(
        [sys.executable, "-I", sys.argv[1]],
        input=json.dumps({"tool_name": "Bash",
                          "tool_input": {"command": sys.argv[2]}}),
        capture_output=True, text=True, timeout=PROD_TIMEOUT_S,
    )
    dt = time.perf_counter() - t0
except subprocess.TimeoutExpired:
    print("TIMEOUT_OR_ERROR")
else:
    if p.returncode != 0:
        print("TIMEOUT_OR_ERROR")
    else:
        out = (p.stdout or "").strip() or "TIMEOUT_OR_ERROR"
        print(f"{out}|DT={dt:.3f}")
PYEOF
)
verdict_line="${got%%|DT=*}"
dt_field="${got##*|DT=}"
if [[ "$got" == TIMEOUT_OR_ERROR ]]; then
  no "#802 64KB segmented marker write blocks inside the 5s gate" "timed out or errored"
elif ! is_real_block "$verdict_line"; then
  no "#802 64KB segmented marker write blocks inside the 5s gate" "got=${verdict_line:-<empty>}"
elif ! python3 -c "import sys; sys.exit(0 if float(sys.argv[1]) <= 2.0 else 1)" "${dt_field:-9}" 2>/dev/null; then
  no "#802 64KB segmented marker write stays under the 2s soft bound" \
    "dt=${dt_field:-?}s -- the whole-command strip is being re-asked per segment"
else
  ok "#802 64KB segmented marker write returns ${verdict_line} in ${dt_field}s"
fi

# A `-exec` payload is RESERIALIZED from an already-split token list, and the quotes that
# serialization adds are OURS -- they keep one token one token. Spending them as if the
# author had written them made the glob they wrap literal, and the word then matched
# nothing: `find ... -exec python3 .../lease_slo?.py ... ;` went from BLOCK at HEAD to
# allow, while bash expands that operand to the helper before find ever runs.
# The terminator is `\;` and not a bare `;`: the shell eats an unescaped one, so find
# fails with `no terminating ";"` and the helper never runs. Executed against a stub
# in a temp tree, this spelling DOES run it -- the bare one did not.
_fx="find . -maxdepth 0 -exec python3 $LIB/lease_slo?.py .claude 20 0 3600 \;"
got=$(verdict "$_fx")
if is_real_block "$got"; then
  ok "#802 a glob in a find -exec payload survives reserialization"
else
  no "#802 a glob in a find -exec payload survives reserialization" "got=${got:-<empty>}"
fi

# The author's own quotes cannot be recovered here -- the token list was split before this
# point -- so the quoted spelling blocks too. That is HEAD's answer as well, and it is the
# fail-CLOSED direction. Pinned so a future attempt to thread raw quoting through the
# payload has to change this line deliberately rather than by accident.
got=$(verdict "find . -maxdepth 0 -exec python3 '$LIB/lease_slo?.py' .claude 20 0 3600 \;")
if is_real_block "$got"; then
  ok "#802 a quoted glob in a payload stays fail-closed (quoting is lost at the split)"
else
  no "#802 a quoted glob in a payload stays fail-closed (quoting is lost at the split)" \
    "got=${got:-<empty>}"
fi

# ...but OUTSIDE a payload the distinction survives: a quoted meta is literal text, and a
# helper name carries no metas, so the word cannot name one.
got=$(verdict "python3 '$LIB/lease_slo?.py'")
if [[ "$got" == "OK|" ]]; then
  ok "#802 a quoted glob outside a payload is literal, not a pattern"
else
  no "#802 a quoted glob outside a payload is literal, not a pattern" "got=${got:-<empty>}"
fi

# Three spellings that put a NEWLINE inside a bracket class, and one POSIX class. A review
# round read the newline cases as a reserialization bypass: `_requote` cannot escape a
# newline, so such a token falls back to `shlex.quote`, and the raw-aware `_glob_helper`
# then sees quotes it reads as the AUTHOR's and returns None. The function-level mechanism
# is real -- `_glob_helper(w, raw=<requoted>)` IS None where `raw=<bare>` names the helper.
# What makes it unreachable is bash: executed against a stub in a temp tree, the two LIVE
# spellings below both expand to the helper and both BLOCK here and at pre-branch HEAD,
# including behind `sh -c` where the outer lexer sees only one quoted blob and so cannot
# be what shadows them. The third does not expand at all -- a fully single-quoted word is
# a literal filename, not a pattern -- so allowing it is the CORRECT reading and the only
# place this branch differs from HEAD, which over-blocked it. Pinned in all three
# directions so the mechanism cannot become reachable without changing these lines.
_nl=$'\n'
_dq='"'
_nlcls="python3 -I $LIB/[l${_dq}${_nl}${_dq}]ease_slo?.py .claude 20 0 3600"
if ! bash -n <<<"$_nlcls" 2>/dev/null; then
  no "#802 a double-quoted newline in a live bracket class blocks" "bash rejected it"
else
  got=$(verdict "$_nlcls")
  if is_real_block "$got"; then
    ok "#802 a double-quoted newline in a live bracket class blocks"
  else
    no "#802 a double-quoted newline in a live bracket class blocks" "got=${got:-<empty>}"
  fi
fi

_ansicls="python3 -I $LIB/[l\$'\\n']ease_slo?.py .claude 20 0 3600"
if ! bash -n <<<"$_ansicls" 2>/dev/null; then
  no "#802 an ANSI-C newline in a live bracket class blocks" "bash rejected it"
else
  got=$(verdict "$_ansicls")
  if is_real_block "$got"; then
    ok "#802 an ANSI-C newline in a live bracket class blocks"
  else
    no "#802 an ANSI-C newline in a live bracket class blocks" "got=${got:-<empty>}"
  fi
fi

got=$(verdict "python3 -I '$LIB/[l${_nl}]ease_slo?.py' .claude 20 0 3600")
if [[ "$got" == "OK|" ]]; then
  ok "#802 a wholly single-quoted newline class is a filename, not a pattern"
else
  no "#802 a wholly single-quoted newline class is a filename, not a pattern" \
    "got=${got:-<empty>}"
fi

# The same round read a STEMLESS POSIX class as clearing the helper once preceding decoys
# exhaust the class-expansion probes: with no members returned and no literal helper
# prefix, the reading was said to fall through. It does not -- `_bracket_prefix_hit` names
# the helper with `_class_expand_exhausted` forced True exactly as it does with it False,
# so the exhausted path keeps the block. bash expands this operand to the helper.
got=$(verdict "python3 -I $LIB/[[:lower:]]ease_slo?.py .claude 20 0 3600")
if is_real_block "$got"; then
  ok "#802 a stemless POSIX class blocks, exhausted probes or not"
else
  no "#802 a stemless POSIX class blocks, exhausted probes or not" "got=${got:-<empty>}"
fi

# The substitution walker keeps its own arithmetic-depth stack. It used to reuse the outer
# loop's name, rebinding that INT to a list, so the next `((` in the command ran `list += 1`
# and the classifier died. A crash is not a verdict: it reaches the gate as
# BLOCK_CLASSIFIER_ERROR, which is a fail-closed stall on an ordinary command.
# shellcheck disable=SC2016
got=$(verdict 'echo "$(true)"; ((1)); echo "["')
if [[ "$got" == "OK|" ]]; then
  ok "#802 an arithmetic group after a substitution does not crash the scanner"
else
  no "#802 an arithmetic group after a substitution does not crash the scanner" \
    "got=${got:-<empty>}"
fi

# An unquoted `#` at a word start opens a comment, and the shell reads none of it. Parsing
# it as live text made an unmatched `$(` or backtick in a comment an unscannable command.
# shellcheck disable=SC2016
for _cmt in 'git status # [docs] example $(foo' 'git status # [docs] example `foo'; do
  got=$(verdict "$_cmt")
  if [[ "$got" == "OK|" ]]; then
    ok "#802 an unmatched opener inside a comment is not a refusal: ${_cmt##*# }"
  else
    no "#802 an unmatched opener inside a comment is not a refusal: ${_cmt##*# }" \
      "got=${got:-<empty>}"
  fi
done

# A `${}` or `$[]` span is not command text, but a `$()` opened INSIDE one is: its
# heredoc is a real heredoc, and suppressing it scanned the body as shell text where an
# apostrophe in prose opened a quote. And a keyword only opens a command where IT is in
# command position -- in `printf then case x` both words are printf arguments. Both ran
# at HEAD and were refused by the staged bytes.
for _lx6 in "echo \"\$(printf %s \${X:-\$(cat <<EOF
it's data
EOF
)})\" \"[\"" \
            "echo \"\$(printf then case x)\" \"[\"" \
            "echo \"\$(printf do case x)\" \"[\"" \
            "cat <<<'x'
python3 $LIB/[l]ease_slo?.py"; do
  if ! bash -n <<<"$_lx6" 2>/dev/null; then
    no "#802 shape is valid bash: ${_lx6:0:30}" "bash rejected it"
    continue
  fi
  got=$(verdict "$_lx6")
  case "$_lx6" in
    *ease_slo*)
      if is_real_block "$got"; then
        ok "#802 a helper behind a quoted herestring still blocks"
      else
        no "#802 a helper behind a quoted herestring still blocks" "got=${got:-<empty>}"
      fi ;;
    *)
      if [[ "$got" == "OK|" ]]; then
        ok "#802 a real construct inside a span, and a keyword-shaped argument: ${_lx6:0:26}"
      else
        no "#802 a real construct inside a span, and a keyword-shaped argument: ${_lx6:0:26}" \
          "got=${got:-<empty>}"
      fi ;;
  esac
done

# A herestring is not a heredoc one character later. Stepping over only the first `<`
# left `<<'X'` starting at the next character, read as a QUOTED delimiter whose
# terminator never comes -- so the body swallowed the command and none of its
# continuations were joined. No verdict shape was found that this changes, which is why
# the joiner's OUTPUT is what gets pinned: the parse is wrong whether or not a verdict
# happens to survive it, and the next lexing rule laid on top of it would inherit that.
got=$(python3 - "$CLASSIFIER" <<'PYEOF' 2>/dev/null || echo ERROR
import importlib.util, io, sys

sys.stdin = io.StringIO("{}")          # the module reads stdin at import
spec = importlib.util.spec_from_file_location("mc", sys.argv[1])
mc = importlib.util.module_from_spec(spec)
_real, sys.stdout = sys.stdout, io.StringIO()   # it PRINTS a verdict at import too
try:
    spec.loader.exec_module(mc)
except SystemExit:
    pass
finally:
    sys.stdout = _real
BS = chr(92)
bad = []
for src in ("cat <<<'x'" + chr(10) + "a " + BS + chr(10) + "b",
            'jq . <<<"$X"' + chr(10) + "a " + BS + chr(10) + "b",
            "cat <<< foo" + chr(10) + "a " + BS + chr(10) + "b"):
    want = src.split(chr(10))[0] + chr(10) + "a b"
    got = mc._join_continuations(src)
    if got != want:
        bad.append(repr(got))
print("OK" if not bad else "UNJOINED:" + ",".join(bad))
PYEOF
)
if [[ "$got" == OK ]]; then
  ok "#802 a continuation after a herestring is still joined"
else
  no "#802 a continuation after a herestring is still joined" "got=${got:-<empty>}"
fi

# The continuation joiner reads the delimiter from the JOINED line, so it needs that
# line built. Building it per `<<` is quadratic: 16K operators in a 64KB command took
# 21.5s in isolation, four times the gate's whole registered 5s budget, and a hook
# killed on the budget emits nothing -- which the runner reads as ALLOW. The token
# budget happens to bound what reaches this today (no end-to-end payload measured
# above 0.35s), but a fix for a timeout fail-open does not get to leave a quadratic
# behind trusting an unrelated budget to hide it. Asserted on the function, because
# end-to-end the budget makes both spellings equally fast and the check vacuous.
got=$(python3 - "$CLASSIFIER" <<'PYEOF' 2>/dev/null || echo ERROR
import importlib.util, io, sys, time

sys.stdin = io.StringIO("{}")          # the module reads stdin at import
spec = importlib.util.spec_from_file_location("mc", sys.argv[1])
mc = importlib.util.module_from_spec(spec)
_real, sys.stdout = sys.stdout, io.StringIO()   # it PRINTS a verdict at import too
try:
    spec.loader.exec_module(mc)
except SystemExit:
    pass
finally:
    sys.stdout = _real
line = ("<<A " * 16000) + chr(92) + "\n" + "y"
t0 = time.perf_counter()
mc._join_continuations(line)
print("%.3f" % (time.perf_counter() - t0))
PYEOF
)
if [[ "$got" == ERROR ]]; then
  no "#802 the continuation joiner scans each line once, not once per heredoc" "harness error"
elif ! python3 -c "import sys; sys.exit(0 if float(sys.argv[1]) <= 1.0 else 1)" "${got:-9}" 2>/dev/null; then
  no "#802 the continuation joiner scans each line once, not once per heredoc" \
    "64KB of heredoc operators took ${got}s -- the line is being rebuilt per operator"
else
  ok "#802 the continuation joiner scans each line once (64KB in ${got}s)"
fi

# The SAME rule one loop over: the flattening pass that puts a substitution's trailing
# argument back in argument position asked "what is the last non-whitespace character so
# far?" by joining and stripping its whole accumulated output, once per `$(` -- quadratic
# in the number of substitutions. Measured on this loop before the fix: 8000 took 0.903s
# and 16000 took 3.044s, four times the work for twice the input; after, 0.198s and
# 0.336s. The token budget bounds what reaches it end-to-end (16000 short-circuits to
# BLOCK_UNSCANNABLE either way), which is exactly why this is asserted on the function --
# end-to-end the check would be vacuous, and a fix for a timeout fail-open does not get
# to leave a quadratic behind trusting an unrelated budget to hide it (#802).
got=$(python3 - "$CLASSIFIER" <<'PYEOF' 2>/dev/null || echo ERROR
import importlib.util, io, sys, time

sys.stdin = io.StringIO("{}")          # the module reads stdin at import
spec = importlib.util.spec_from_file_location("mc", sys.argv[1])
mc = importlib.util.module_from_spec(spec)
_real, sys.stdout = sys.stdout, io.StringIO()   # it PRINTS a verdict at import too
try:
    spec.loader.exec_module(mc)
except SystemExit:
    pass
finally:
    sys.stdout = _real
_lb, _rb = chr(91), chr(93)
_helper = "hooks/gate-scripts/lib/" + _lb + "l" + _rb + "ease_" + "sl" + "o?.py"
cmd = "$(true) " * 16000 + "python3 -I " + _helper + " .claude x 1 3600"
t0 = time.perf_counter()
mc._helper_invoked(cmd)
print("%.3f" % (time.perf_counter() - t0))
PYEOF
)
if [[ "$got" == ERROR ]]; then
  no "#802 the flattening pass tracks command position incrementally" "harness error"
elif ! python3 -c "import sys; sys.exit(0 if float(sys.argv[1]) <= 1.5 else 1)" "${got:-9}" 2>/dev/null; then
  no "#802 the flattening pass tracks command position incrementally" \
    "16000 substitutions took ${got}s -- the accumulated output is being rejoined per opener"
else
  ok "#802 the flattening pass tracks command position incrementally (16000 in ${got}s)"
fi

# `$$` is the PID, so `$${foo` is a PID and a LITERAL brace. Testing `${` one character
# in opened an expansion with no closer and refused the whole command; bash runs it.
# The parity question already had an answer in this file -- the raw-word scan and the
# segment splitter both ask it -- so the walker asks it the same way (#802 / #553).
_pid_brace='echo $${foo "["'
if ! bash -n <<<"$_pid_brace" 2>/dev/null; then
  no "#802 a PID beside a literal brace is not a parameter expansion" "bash rejected it"
else
  got=$(verdict "$_pid_brace")
  if [[ "$got" == "OK|" ]]; then
    ok "#802 a PID beside a literal brace is not a parameter expansion"
  else
    no "#802 a PID beside a literal brace is not a parameter expansion" "got=${got:-<empty>}"
  fi
fi

# The same parity, in the walkers the first fix did not touch: `$${` is a PID beside a
# literal brace INSIDE a substitution too, and the fictitious span swallowed the real
# closing paren. Not the `$(`/`$((` branches -- bash REJECTS `$$(` and `$$((`, so
# refusing those is already right.
_pid_inner='echo "$(printf %s $${foo)" "["'
# Only an UNESCAPED separator starts a command: `\;` is an argument, so the `case`
# after it is one too, and reading the escape as a separator refused a command bash
# runs (#802).
_esc_sep='echo "$(printf %s \; case x)" "["'
# The whole separator set, not just the one the review named.
_esc_amp='echo "$(printf %s \& case x)" "["'
_esc_par='echo "$(printf %s \( case x)" "["'
for _c in "$_pid_inner" "$_esc_sep" "$_esc_amp" "$_esc_par"; do
  if ! bash -n <<<"$_c" 2>/dev/null; then
    no "#802 an escaped or PID-adjacent construct is read as bash reads it" "bash rejected: $_c"
  else
    got=$(verdict "$_c")
    if [[ "$got" == "OK|" ]]; then
      ok "#802 bash-faithful reading of: $_c"
    else
      no "#802 bash-faithful reading of: $_c" "got=${got:-<empty>}"
    fi
  fi
done

# `$"EOF"` is a locale TRANSLATION, so bash's delimiter is `EOF` and the body ends at it.
# Keeping the `$` hunted for `$EOF`, ran off the end of the body, and ate the enclosing
# substitution's `)` -- refusing a command bash runs. Both directions are asserted,
# because a walker that simply stopped reading heredocs would satisfy the first alone.
_dq_hd='echo "$(cat <<$"EOF"
data
EOF
)" "["'
_dq_hd_block='cat <<$"EOF"
data
EOF
echo x > .claude/skip-litmus.local'
if ! bash -n <<<"$_dq_hd" 2>/dev/null || ! bash -n <<<"$_dq_hd_block" 2>/dev/null; then
  no "#802 a \$\"..\" heredoc delimiter is read as bash reads it" "bash rejected a fixture"
else
  got=$(verdict "$_dq_hd")
  if [[ "$got" == "OK|" ]]; then
    ok "#802 a \$\"..\" heredoc body ends at its delimiter"
  else
    no "#802 a \$\"..\" heredoc body ends at its delimiter" "got=${got:-<empty>}"
  fi
  got=$(verdict "$_dq_hd_block")
  if [[ "$got" == "BLOCK_MARKER|skip-litmus.local" ]]; then
    ok "#802 ...and the command AFTER that body is still read, and still blocks"
  else
    no "#802 ...and the command AFTER that body is still read, and still blocks" \
      "got=${got:-<empty>}"
  fi
fi

# A heredoc body inside a `${...}` default value is DATA. Reading it as shell text let an
# apostrophe in prose open a quote that swallowed the closing brace, refusing a command
# bash runs. The walker does not need to walk the nested `$()` to get this right -- it
# needs to stop reading the one span that is not shell text.
_pe_hd='echo "${X:-$(cat <<EOF
it'"'"'s data
EOF
)}" "["'
_pe_hd_block='echo "${X:-$(cat <<EOF
python3 '"$LIB"'/lease_slot.py
EOF
)}"'
# `$(..)` in ARGUMENT position does not start a new command: what follows it belongs to
# the command the substitution sits in. `echo "$(true)" <helper>` prints a filename.
# Both spellings, because a glob spelling must never be more permissive than the literal.
_f1_lit='echo "$(true)" '"$LIB"'/lease_slot.py'
_f1_glob='echo "$(true)" '"$LIB"'/[l]ease_slo?.py'
# ...and the paired fail-CLOSED half: in COMMAND position the next word really is the
# command, so `$(true) python3 <helper>` RUNS the helper and must still block.
_f1_cmdpos='$(true) python3 '"$LIB"'/lease_slot.py'
# `<<` is a heredoc introducer only in COMMAND text. In a default VALUE it is ordinary
# characters, inside arithmetic it is a shift, and `<<<` is a herestring -- none of the
# three is a body to skip. Asking about a heredoc anywhere in the brace body refused all
# three; the walker now asks only inside the nested `$()` a command actually lives in.
_pe_lit='echo "${X:-<<EOF}" "["'
_pe_shift='echo "${X:-$(echo $((1 << 2)))}" "["'
_pe_herestr='echo "${X:-$(cat <<< foo)}" "["'
# Several bodies queue on ONE line -- `cat <<A <<B` reads A's then B's -- so jumping at
# the first introducer left the second body read as shell text.
_pe_two_hd='echo "${X:-$(cat <<A <<B
first
A
it'"'"'s data
B
)}" "["'
# A bare `(` is a SUBSHELL and its `)` is not the substitution'"'"'s. Unpushed, that closer
# consumed the substitution'"'"'s own entry, and the separator it left put the trailing
# argument back into command position. Both spellings, again.
# A nested `$()` is its OWN command, so the delimiter queued OUTSIDE it is not pending
# at the inner command's newline. One flat queue took the outer `A` there, and its body
# then ate the closing `)}` -- bash prints `hello [docs]` for this, HEAD allowed it.
_pe_nest_hd='echo "${X:-$(cat <<A $(printf "" <<B
B
)
it'"'"'s data
A
)}" "["'
_sub_shell_lit='echo "$( (true) )" '"$LIB"'/lease_slot.py'
_sub_shell_glob='echo "$( (true) )" '"$LIB"'/[l]ease_slo?.py'
for _c in "$_pe_hd" "$_f1_lit" "$_f1_glob" "$_pe_lit" "$_pe_shift" "$_pe_herestr" \
          "$_pe_two_hd" "$_pe_nest_hd" "$_sub_shell_lit" "$_sub_shell_glob"; do
  if ! bash -n <<<"$_c" 2>/dev/null; then
    no "#802 a span that is not shell text is read as bash reads it" "bash rejected: $_c"
  else
    got=$(verdict "$_c")
    if [[ "$got" == "OK|" ]]; then
      ok "#802 bash-faithful reading of: ${_c//$'"'"'\n'"'"'/ }"
    else
      no "#802 bash-faithful reading of: ${_c//$'"'"'\n'"'"'/ }" "got=${got:-<empty>}"
    fi
  fi
done
# ...and the paired fail-CLOSED half for each: a helper in the SECOND heredoc body, and
# a helper the subshell actually runs.
#
# Bash never RUNS the ones inside a body -- `cat <<A ... A` prints them -- so these are
# deliberate over-blocks, and they are NOT this branch's: HEAD returns the same
# BLOCK_MARKER_SCRIPT for all three, because the helper-NAME search reads the whole
# command text and a body is still part of it. What the branch changed is the LEXING
# (a body is data, so its quotes and parens are not the walker's), and that is exactly
# why the block half is here: a walker that simply stopped reading heredocs would
# satisfy the allow half above on its own. Pinning the unchanged direction is what
# makes the changed one mean something.
_pe_two_hd_block='echo "${X:-$(cat <<A <<B
first
A
python3 '"$LIB"'/lease_slot.py
B
)}"'
_sub_shell_block='echo "$( (python3 '"$LIB"'/lease_slot.py) )"'
# ...and the OUTER body of the nested-heredoc shape above, which is still data.
_pe_nest_hd_block='echo "${X:-$(cat <<A $(printf "" <<B
B
)
python3 '"$LIB"'/lease_slot.py
A
)}"'
for _c in "$_pe_hd_block" "$_f1_cmdpos" "$_pe_two_hd_block" "$_pe_nest_hd_block" \
          "$_sub_shell_block"; do
  got=$(verdict "$_c")
  if is_real_block "$got"; then
    ok "#802 ...and the invocation it hides still blocks: ${_c//$'"'"'\n'"'"'/ }"
  else
    no "#802 ...and the invocation it hides still blocks: ${_c//$'"'"'\n'"'"'/ }" \
      "got=${got:-<empty>}"
  fi
done

# A flattened substitution loses ARGUMENT position, so both spellings of a helper named
# after an unquoted `$(...)` block. That is deliberate parity, not an over-block found
# late: HEAD already blocks the LITERAL one by the same reasoning, and only the glob
# spelling changed. Pinned in BOTH spellings so a later "fix" for one has to face the
# other (#802).
for _c in 'echo $(true) '"$LIB"'/lease_slot.py' 'echo $(true) '"$LIB"'/lease_slo?.py'; do
  got=$(verdict "$_c")
  if is_real_block "$got"; then
    ok "#802 flattened substitution blocks both spellings: ${_c}"
  else
    no "#802 flattened substitution blocks both spellings: ${_c}" "got=${got:-<empty>}"
  fi
done

echo
echo "════ marker-glob-expansion-budget-802: $PASS passed, $FAIL failed ════"
[[ "$FAIL" -eq 0 ]]
