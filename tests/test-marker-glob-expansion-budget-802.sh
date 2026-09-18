#!/usr/bin/env bash
# #802 — class-expansion probes must charge the command-wide budgets so a repeated
# bracket-glob payload cannot sit near the pre-implementation gate's 5s timeout
# (a timeout emits no decision, which the harness reads as ALLOW).
# Fixtures are literal shell text for the CLASSIFIER; `$` must not expand in this shell.
# shellcheck disable=SC2016
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
elif ! is_real_block "$verdict_line"; then
  # OK here would mean the budget never latched: the payload scanned to a clean miss,
  # which is the same cost profile that used to sit at ~3.5s. Only a real BLOCK proves
  # the exhaustion path fired (cubic on #869).
  no "#802 5000x digit-negation pipeline latches fail-closed" "got=${got:-<empty>}"
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
# The padding is a DIRECTORY, not the basename: padding the basename made the stem
# unrecognisable to `_bracket_prefix_hit`, so a wrongful abandon into it still answered
# OK and this check could not fail (greptile on #869). The `[t]` twin proves it can.
bound=$(python3 - "$CLASSIFIER" <<'PYEOF' 2>/dev/null || echo ERROR
import json, subprocess, sys
stem = "lease" + "_" + "slo"
def v(cls):
    base = stem + "[" + cls + "].py"
    op = ("a" * (2048 - len(base) - 1)) + "/" + base
    assert len(op) == 2048
    p = subprocess.run(
        [sys.executable, "-I", sys.argv[1]],
        input=json.dumps({"tool_name": "Bash", "tool_input": {"command": "python3 " + op}}),
        capture_output=True, text=True,
    )
    return (p.stdout or "").strip() if p.returncode == 0 else "ERROR"
print(v("a") + "#" + v("t"))
PYEOF
)
if [[ "${bound%%#*}" == "OK|" ]]; then
  ok "#802 2048-byte operand ending in [a] still allowed"
else
  no "#802 2048-byte operand ending in [a] still allowed" "got=${bound:-<empty>}"
fi
if is_real_block "${bound#*#}"; then
  ok "#802 2048-byte operand ending in [t] still blocks (fixture can see a fallback)"
else
  no "#802 2048-byte operand ending in [t] still blocks" "got=${bound:-<empty>}"
fi

# Precise misses across ONE command (Codex P1 on #869): the deep family is prepaid per
# word, so repeating a miss must not drain the budget into `_bracket_prefix_hit`. A real
# hit after several misses must still block.
seq=$(python3 - "$CLASSIFIER" <<'PYEOF' 2>/dev/null || echo ERROR
import json, subprocess, sys
w = "python3 lease" + "_" + "slo"
def v(cmd):
    p = subprocess.run([sys.executable, "-I", sys.argv[1]],
                       input=json.dumps({"tool_name": "Bash", "tool_input": {"command": cmd}}),
                       capture_output=True, text=True)
    return (p.stdout or "").strip() if p.returncode == 0 else "ERROR"
miss = w + "[a].py"
print(v("; ".join([miss] * 3)) + "#" + v("; ".join([miss] * 10))
      + "#" + v("; ".join([miss, miss, w + "[t].py"])))
PYEOF
)
IFS='#' read -r seq3 seq10 seqhit <<<"$seq"
if [[ "$seq3" == "OK|" && "$seq10" == "OK|" ]]; then
  ok "#802 3x and 10x precise [a] misses in one command still allowed"
else
  no "#802 3x and 10x precise [a] misses in one command still allowed" "got=${seq:-<empty>}"
fi
if is_real_block "$seqhit"; then
  ok "#802 real [t] hit after two misses still blocks"
else
  no "#802 real [t] hit after two misses still blocks" "got=${seq:-<empty>}"
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
  printf -v _cs_heredoc 'python3 %s/[l]$(cat <<E >/dev/null\n)\nE\n)ease_slot.py' "$LIB"
  # An attached `<<` is a heredoc too, so its body ')' is data, not the closer.
  # shellcheck disable=SC2016
  printf -v _cs_attached 'python3 %s/[l]$(cat<<E >/dev/null\n)\nE\n)ease_slot.py' "$LIB"
  # Under a plain `<<` a TAB-indented delimiter is body data -- only `<<-` strips tabs.
  # shellcheck disable=SC2016
  printf -v _cs_tabdelim 'python3 %s/[l]$(cat <<E >/dev/null\n\tE\n)\nE\n)ease_slot.py' "$LIB"
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

  cs_case "$_cs_heredoc" yes "a ')' inside a heredoc body does not close \$()"
  cs_case "$_cs_attached" yes "an attached '<<E' still hides its body ')'"
  cs_case "$_cs_tabdelim" yes "a tab-indented delimiter under plain '<<' is body data"
  cs_case "$_cs_arith" yes "a '<<' inside (( )) is a shift, not a heredoc"
  cs_case "$_cs_output" yes "an unquoted substitution's output is unknown, not empty"
  cs_case "$_cs_brace" yes "an unquoted \${} expansion's value is unknown, not empty"
  cs_case "$_cs_delimesc" yes "an escaped quote in a heredoc delimiter stays literal"
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

# Slice-2 reconciliation with main (#813 and litmus on the #802 split). Each case is
# (label, want, command); commands are built in Python so this shell never assembles a
# helper-shaped path in its own tool_input.
recon=$(python3 - "$CLASSIFIER" <<'PYEOF' 2>/dev/null || echo ERROR
import json, subprocess, sys
stem = "lease" + "_" + "slo"
hlp = "[l]ease" + "_" + "slot.py"
lib = "hooks/gate-scripts/lib/"
cases = [
    # A BARE glob command word, or a case pattern the `|` splitter leaves in command
    # position, is not evidence a helper was named (main's section A / #813).
    ("bare glob command word", "OK", "*.py"),
    ("case pattern with a negated class", "OK", "case \"$x\" in ''|*[!0-9]*) x=900 ;; esac"),
    ("empty array literal + glob line", "OK", "A_1=( )\n*.py"),
    # A substitution MENTION re-arms nothing: only a real one the flatten rewrites.
    ("single-quoted $() mention + case alternative", "OK",
     "echo '$(true)'; case x.py in a|*.py) echo ok;; esac"),
    ("single-quoted $() mention + case arm glob", "OK",
     "echo '$(true)'; case x in x) *.py;; esac"),
    ("escaped $() mention + case arm glob", "OK",
     "echo \\$(true); case x in x) *.py;; esac"),
    # A REAL substitution elsewhere does not make a case arm's `)` a closer.
    ("real $() elsewhere + case arm glob", "OK",
     "echo \"$(true)\"; case x in x) *.py;; esac"),
    ("real $() elsewhere + glued $() command word", "BLOCK",
     "case x in x) *.py;; esac; $(true)" + hlp),
    # The stripper cannot parse a case arm or a comment inside $(...): no flatten, and
    # the ordinary walk (main's reading) decides. A helper name next to the
    # substitution is its own word there, so it still blocks.
    ("unglued case inside $()", "OK", 'echo "$(case x in x) echo ok;; esac)" "["'),
    ("unglued comment inside $()", "OK", 'echo "$(echo hi # comment\n)" "["'),
    ("case arm glued to its body inside $()", "OK", 'echo "$(case x in x)echo ok;; esac)" "["'),
    ("quoted glued mention + unparseable $()", "OK",
     "echo 'x$(true)'; echo \"$(case x in x) echo ok;; esac)\" \"[\""),
    ("backtick closer glued to a helper", "BLOCK", "`case x in x) :;; esac`" + hlp),
    ("glued suffix after unparseable $()", "BLOCK", "$(case x in x) :;; esac)" + hlp),
    ("unparseable $() then a helper word", "BLOCK", "$(case x in x) :;; esac) " + hlp),
    ("glued comment $() before helper", "BLOCK", "$(echo hi # c\n)" + hlp),
    # What the flatten exists for still blocks.
    ("glued $() command word", "BLOCK", "$(true)" + hlp),
    ("glued backtick command word", "BLOCK", "`true`" + hlp),
    ("glued $() after a separator", "BLOCK", "echo hi; $(true)" + hlp),
    ("echo $() then a helper glob", "BLOCK", "echo $(true) " + lib + stem + "?.py"),
]
for label, want, cmd in cases:
    p = subprocess.run([sys.executable, "-I", sys.argv[1]],
                       input=json.dumps({"tool_name": "Bash", "tool_input": {"command": cmd}}),
                       capture_output=True, text=True)
    out = (p.stdout or "").strip() if p.returncode == 0 else "ERROR"
    got = "OK" if out == "OK|" else ("BLOCK" if out.startswith("BLOCK_") and not out.startswith("BLOCK_CLASSIFIER_ERROR") else out)
    print(("PASS" if got == want else "FAIL") + "\t" + label + "\t" + out)
PYEOF
)
while IFS=$'\t' read -r st label out; do
  [[ -z "$st" ]] && continue
  if [[ "$st" == PASS ]]; then ok "#802 slice-2: $label"; else no "#802 slice-2: $label" "got=$out"; fi
done <<<"$recon"
[[ "$recon" == ERROR ]] && no "#802 slice-2 reconciliation driver" "driver failed"

# Timing: a 64KB `$(true)` flood used to re-join the flatten output at every `$(`.
flood=$(python3 - "$CLASSIFIER" <<'PYEOF' 2>/dev/null || echo ERROR
import json, subprocess, sys, time
cmd = "echo " + "$(true) " * 8190
t = time.perf_counter()
p = subprocess.run([sys.executable, "-I", sys.argv[1]],
                   input=json.dumps({"tool_name": "Bash", "tool_input": {"command": cmd}}),
                   capture_output=True, text=True, timeout=5)
print(f"{time.perf_counter() - t:.3f}" if p.returncode == 0 else "ERROR")
PYEOF
)
if [[ "$flood" != ERROR ]] && python3 -c "import sys; sys.exit(0 if float(sys.argv[1]) <= 2.0 else 1)" "$flood"; then
  ok "#802 slice-2: 64KB \$(true) flood classifies in ${flood}s"
else
  no "#802 slice-2: 64KB \$(true) flood under 2s" "got=${flood:-<empty>}"
fi

echo
echo "════ marker-glob-expansion-budget-802: $PASS passed, $FAIL failed ════"
[[ "$FAIL" -eq 0 ]]
