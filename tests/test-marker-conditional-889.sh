#!/usr/bin/env bash
# Regression for a false BLOCK_MARKER_SCRIPT (#947; referenced from #889, which it does
# NOT fix): `&&` inside a `[[ ... ]]` conditional is a CONDITIONAL operator, not a list
# separator. The segmenter cut the conditional there, so an operand after it
# (`"$g" == *`) looked like a command whose unresolved command word `$g` runs a glob
# operand, and the #802 probe refused it. The same text with the conditional written as
# two `[[ ]]` was already allowed.
#
# Both directions are pinned: the conditional shapes must be OK, and every real
# unresolved-command / glob / substitution / helper shape around a conditional must
# still BLOCK. Commands are classified as JSON DATA only -- never executed.
# Design: docs/plans/2026-10-11-issue-947-conditional-operands.md
set -u
. "$(dirname "$0")/lib/git-env-isolation.sh" || exit 1

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLASSIFIER="$ROOT/hooks/gate-scripts/lib/marker_check.py"
PASS=0
FAIL=0
# A scanner regression must fail (as ERROR), not hang the suite. macOS ships no
# `timeout`, so perl's alarm stands in there.
TO=(perl -e 'alarm shift; exec @ARGV or exit 127' 60)
command -v timeout >/dev/null 2>&1 && TO=(timeout 60)
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
no() { FAIL=$((FAIL + 1)); printf '  FAIL  %s :: %s\n' "$1" "${2:-}"; }

verdict() { # <command> -> the verdict line, or ERROR (contract of test-herestring-receiver-643.sh)
    local payload out
    payload=$(python3 -c 'import json,sys;print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]}}))' \
        "$1" 2>/dev/null) || { printf 'ERROR'; return; }
    # Captured, not streamed: on a nonzero exit the partial output is discarded.
    if out=$(${TO[@]+"${TO[@]}"} python3 -I "$CLASSIFIER" <<<"$payload" 2>/dev/null); then
        printf '%s' "$out"
    else
        printf 'ERROR'
    fi
}

assert_ok() { # <command> <label>
    local got
    got="$(verdict "$1")"
    if [[ "$got" == "OK|" ]]; then ok "$2"; else no "$2" "got=${got:-<empty>} — a conditional operand was read as a command"; fi
}

assert_block() { # <command> <label>
    local got
    got="$(verdict "$1")"
    # BLOCK_CLASSIFIER_ERROR is a fail-closed VERDICT but not a passing TEST: the rule never ran.
    if [[ "$got" == BLOCK_CLASSIFIER_ERROR* ]]; then
        no "$2" "got=$got — the classifier raised"
    elif [[ "$got" == BLOCK_* ]]; then
        ok "$2"
    else
        no "$2" "got=${got:-<empty>} — a real invocation was allowed"
    fi
}

# Fixtures whose text `_split_conditionals` must return unchanged, so the reason they
# BLOCK is not some later rule happening to catch a rewritten text.
IDENT=()
assert_block_id() { assert_block "$1" "$2"; IDENT+=("$2" "$1"); }

# Assembled from fragments so this file does not itself read as an invocation of the
# protected helper to the very gate it is testing.
STEM="python3 hooks/gate-scripts/lib/lease_"
TAIL="slot.py"
HELPER="$STEM$TAIL"
HGLOB="${STEM}slo?.py"
NL=$'\n'

# shellcheck disable=SC2016  # every `$` below must reach the classifier unexpanded
{
# -- A. operands of one conditional are not commands ------------------------------
assert_ok '[[ -n x && "$g" == * ]]'      "A1 && inside [[ ]] before an unresolved operand and a glob"
assert_ok '[[ -n x ]] && [[ "$g" == * ]]' "A5 baseline: the same test as two conditionals"
IDENT+=("A5" '[[ -n x ]] && [[ "$g" == * ]]')
assert_ok '[[ -n x&&"$g" == * ]]'        "A6 an unspaced operator still ends the word"
assert_ok 'if [[ -n x && "$g" == * ]]; then :; fi' "A8 under a reserved word"
assert_ok '[[ -n x && -n y && "$g" == * ]]' "A10 several interior &&"
assert_ok '[[ -n x && "$g" == * ]]'"$NL"'echo ok' "A11 a first-line conditional ended by a newline"
assert_ok 'echo !; [[ -n x && "$g" == * ]]' "A14 a ! argument is not pipeline negation"
assert_ok '[[ ! -n x && "$g" == * ]]'      "A16 ! inside the conditional"
assert_ok '[[ -n x && "$g" == * ]] && [ -f "$f" ]' "A17 a plain [ ] test on the same line"

# -- Residual over-blocks: pinned so a change to them is deliberate -----------------
# A3 / A9 / A12: any `$(` STOPs the rewrite. The classifier misses payloads inside some
# substitution bodies (`echo "$(sh -c '<helper>')"` is allowed on its own) and caught
# B40/B41/B51 only because the `&&` split happened to expose them.
assert_block_id '[[ -n x && -z $(printf %s y | wc -c) && "$g" == * ]]' "A12 an unquoted substitution body"
assert_block_id '[[ "$(true)" -eq 1 && "$g" == *'"'"') || y'"'"' ]]' \
    "A3 a quoted substitution in the conditional (flattened reading)"
assert_block_id '[[ "$(printf '"'"'%s\n'"'"' "$g" | wc -l)" -eq 1 && "$g" == * ]] || { z=0; }' \
    "A9 a quoted body with a pipe and a nested quote"
assert_block_id '[[ -n x || "$g" == *.py ]]' "A2 || is never rewritten (dash runs its right side)"
# The reported shape: a quoted heredoc body. Its receiver is unknown, and dash runs a
# `[[` in it, so a heredoc body is never rewritten.
assert_block_id "python3 -I - <<'EOF'"$'\n''# `x` $'"'"'\n'"'"$'\n''[[ "$(printf '"'"'%s\\n'"'"' "$g" | wc -l)" -eq 1 && "$g" == *'"'"') || y'"'"' ]] || { z=0; }'$'\n''EOF' \
    "A4 the reported heredoc + backtick + ANSI-C shape"

# -- B. what a conditional must NOT hide ------------------------------------------
assert_block_id '"$g" *'                  "B1 unresolved command word + glob operand (#802)"
assert_block_id '$P *.py'                 "B2 ...unquoted"
assert_block_id '[[ -n x ]] && $P *'      "B3 after the conditional closes, && is a list operator"
assert_block_id '[[ -n x ]] || "$g" *'    "B4 ...and so is ||"
assert_block_id '[ -n x ] && "$g" *'      "B5 [ ] is a command, not a conditional"
assert_block_id '[[ -n x ]]; $P *'        "B6 a separator after the conditional"
assert_block_id 'echo [[ && $P *'         "B7 [[ as an ARGUMENT opens nothing"
assert_block_id 'x=1 [[ -n x || $P * ]]'  "B8 [[ after an assignment is not the keyword"
assert_block_id '"[[" -n x || $P * ]]'    "B9 a quoted [[ is not the keyword"
assert_block_id '\[[ -n x || $P * ]]'     "B10 an escaped [[ is not the keyword"
assert_block_id '[[ x == "]]" ]] && $P *' "B11 a quoted ]] does not close; the real one does"
assert_block_id '[[ -n x && $P *'         "B12 an unclosed conditional relaxes nothing"
assert_block_id '[[ -n x && "$(a && $P '"$HGLOB"')" ]]' \
    "B13 a substitution inside the conditional still runs its own commands"
assert_block_id "[[ \"\$($HELPER)\" && -n x ]]"  "B14 a literal helper inside a conditional substitution"
assert_block_id "[[ -n x ]] && $HGLOB"        "B15 a globbed helper after the conditional"
assert_block_id "[[ -n x && -n y ]] && $HELPER"  "B16 a literal helper after a compound conditional"
assert_block_id '[[ -n x && `$P *` ]]'        "B17 a backtick is a STOP"
assert_block_id '[[ -n x && "$(case y in y) $P *;; esac)" ]]' "B18 case in a body is a STOP"
assert_block_id '[[ a < b && $P * ]]'         "B19 < is a STOP"
assert_block_id "sh <<< '[[ -n x && $HELPER ]]'" "B20 a herestring payload is never rewritten"
assert_block_id '[[ -n x &&'"$NL"'$P * ]]'    "B21 a newline before ]] is a STOP"
assert_block_id '$(true) [[ -n x && "$g" == * ]]' "B22 a top-level \$( is a STOP"
assert_block_id "\$(true) [[ -n x && $HGLOB ]]"   "B23 helper-glob twin of B22"
assert_block_id '[[ -n x && "$(echo "a" && $P *)" ]]' "B24 & in a body is a STOP"
assert_block_id "[[ -n x && \"\$(echo \"a\" && $HGLOB)\" ]]" "B25 helper-glob twin of B24"
assert_block_id "case '[[' in${NL}"'[[) ( true && $P * && echo ]] );; esac' "B26 case is a STOP"
assert_block_id "sh <<'EOF'${NL}[[ -n x || $HELPER ]]${NL}EOF" \
    "B29 the dash counterexample: a heredoc is never rewritten"
assert_block_id 'bash <<EOF'"$NL"'[[ -z \\" ]] && echo \\" || \$P '"$HGLOB"' ]]'"$NL"'EOF' \
    "B30 an unquoted heredoc body is never rewritten"
assert_block_id "[[ -n x || y && $HELPER ]]"  "B31 mixed || / && is never rewritten"
assert_block_id '[[ -n "$(printf %s \) && $P *.py)" ]]' "B32 a backslash in a body is a STOP"
assert_block_id '[[ -n "$(printf %s $'"'"')'"'"' && $P *.py)" ]]' "B33 \$' in a body is a STOP"
assert_block_id 'echo `printf '"'"'"'"'"'`; [[ -n x && $P * ]]' "B34 a backtick before a conditional"
assert_block_id 'x="$(case y in y) echo "a";; esac)"; [[ -n x && $P * ]]' \
    "B35 \$( outside a conditional is a STOP"
assert_block_id '! [[ -n x && $P * ]]'        "B36 ! does not keep command position"
assert_block_id '! true | [[ -n x && "$P" * ]]' "B57 ! negates the whole pipeline, past the |"
assert_block_id 'if ! true | [[ -n x && "$P" * ]]; then :; fi' "B58 ! after a keeper word"
assert_block_id 'time ! true | [[ -n x && "$P" * ]]' "B59 ! after a time prefix"
assert_block_id 'time -p ! true | [[ -n x && "$P" * ]]' "B60 ! after time -p"
assert_block_id 'time -p -- ! true | [[ -n x && "$P" * ]]' "B61 ! after time -p --"
assert_block_id '! true | { true; } | [[ -n x && "$P" * ]]' "B62 a nested ; does not end the negated pipeline"
assert_block_id '! true; true | [[ -n x && "$P" * ]]' "B63 no | restores command position after a ! on the line"
assert_block_id '! false; [[ -n x && "$P" * ]]' "B64 a command-position ! stops the rest of the line"
assert_block_id 'true || [[ -n x && "$P" * ]]' "B65 || before the conditional (dash skips [[ and runs the operand)"
assert_block_id '! false || [[ -n x && "$P" * ]]' "B66 ! and || together"
assert_block_id 'true || { true; } | [[ -n x && "$P" * ]]' "B67 || then a pipeline after a group"
assert_block_id 'true && false || [[ -n x && "$P" * ]]' "B68 || after an && chain"
assert_block_id "alias '[['=true${NL}[[ -n x && $HELPER ]]" \
    "B37 first line only: a text-defined alias reaches only later lines"
assert_block_id 'time [[ -n x && "$g" == * ]]' "B38 time ends command position (accepted over-block)"
assert_block_id 'x=1 [[ -n x && "$g" == * ]]'  "B39 an assignment prefix ends command position"
assert_block_id "[[ -n x && \"\$(sh -c '$HELPER')\" ]]" "B40 a payload in a quoted substitution is a STOP"
assert_block_id "[[ -n x && \"\$(bash -c \"$HELPER\")\" == y ]]" "B41 ...with a double-quoted payload"
assert_block_id "[[ -n x && \$($HELPER) ]]"       "B42 a literal helper in an unquoted body is never rewritten"
assert_block_id "[[ -n x && $HELPER ]]"       "B44 a spelled helper operand is never rewritten (inherited-alias residual)"
assert_block_id "[[ -n x && $HGLOB ]]"        "B45 ...nor a glob that targets one"
assert_block_id "[[ -n x && python3 -m lease_${TAIL%.py} ]]" "B46 ...nor its module spelling"
assert_block_id "[[ -n x && python3 -m lease_\"${TAIL%.py}\" ]]" "B49 ...nor one assembled by quote removal"
assert_block_id "[[ -n x && ${STEM%lease_}l[\";\"e]ase_$TAIL ]]" "B53 ...nor one assembled by a bracket class"
assert_block_id "[[ -n x && ${STEM%lease_}[\"|\"l]ease_$TAIL ]]" "B69 ...nor a class whose split leaves a bare ["
# Identity only: brace expansion is the ADR 0006 residual, unseen by the base classifier.
IDENT+=("B54 ...nor by brace expansion" "[[ -n x && ${STEM}slo{t,x}.py ]]")
assert_block_id "ARGS=' state 1 0 0'; [[ -n x && -n \$(python3 -- ${HGLOB#python3 }\$ARGS) && \"\$g\" == * ]]" \
    "B51 a globbed helper with a parameter suffix inside a body"
# Identity only: the verdict is the base classifier's, unchanged by this rewrite.
IDENT+=("B52 a targeted glob with a parameter suffix is never rewritten" "[[ -n x && ${HGLOB}\$ARGS ]]")
# Helper-free twins of B31 / B37, so the || and newline guards are pinned on their own
# and not only behind the helper-name refusal.
assert_block_id '[[ -n x || y && "$g" == * ]]' "B47 mixed || / && without a spelled helper"
assert_block_id "alias '[['=true${NL}"'[[ -n x && "$g" == * ]]' "B48 a second-line conditional without a spelled helper"
assert_block_id 'echo ok'"$NL"'[[ -n x && "$g" == * ]]' "B55 a second-line conditional is never rewritten (newline guard on its own)"
assert_block_id '[[ -n x && $(case y in y) && $P * ]]' \
    "B43 case in an unquoted body is a STOP (its pattern ) would end the body early)"
}

# -- Bounded work: must reach a real verdict, not ERROR or a classifier raise ---------
assert_bounded() { # <command> <label>
    local got
    got="$(verdict "$1")"
    if [[ "$got" == ERROR || "$got" == BLOCK_CLASSIFIER_ERROR* || -z "$got" ]]; then
        no "$2" "got=${got:-<empty>}"
    else
        ok "$2 (verdict ${got%%|*})"
    fi
}
B27=""
for ((i = 0; i < 3000; i++)); do B27+="cat <<'E$i'$NL"; done
# shellcheck disable=SC2016
B27+='[[ -n x && "$g" == * ]]'
for ((i = 2999; i >= 0; i--)); do B27+="${NL}E$i"; done
B28="[[ -n x"
for ((i = 0; i < 2000; i++)); do B28+=" && -n x"; done
B28+=" ]]"
assert_bounded "$B27" "B27 3000 nested heredocs: the first < STOPs cheaply"
B56="echo $(printf 'x%.0s' {1..60000})"
assert_bounded "$B56" "B56 one 60000-character word scans in linear time"
assert_bounded "$B28" "B28 2000 interior && in one conditional"
B28OK="[[ -n x"
for ((i = 0; i < 1000; i++)); do B28OK+=" && -n x"; done
B28OK+=" ]]"
assert_ok "$B28OK" "B28b past the rewrite cap the text is left as today (OK, not UNSCANNABLE)"
B28CAP="[[ -n x"
for ((i = 0; i < 63; i++)); do B28CAP+=" && -n x"; done
# shellcheck disable=SC2016
B28CAP+=' && "$g" == * ]]'
assert_ok "$B28CAP" "B28c a chain at the cap is rewritten and still OK"
# Near the budget, the rewrite's own words must not be what exhausts it: OK before #947.
B28NEAR="echo"
for ((i = 0; i < 3950; i++)); do B28NEAR+=" x"; done
B28NEAR+=" ; [[ -n x"
for ((i = 0; i < 20; i++)); do B28NEAR+=" && -n x"; done
B28NEAR+=" ]]"
assert_ok "$B28NEAR" "B28d near-budget text: the rewrite falls back instead of going UNSCANNABLE"
B28OVER="echo"
for ((i = 0; i < 4100; i++)); do B28OVER+=" x"; done
B28OVER+=" ; [[ -n x && -n x ]]"
got="$(verdict "$B28OVER")"
if [[ "$got" == "BLOCK_UNSCANNABLE|" ]]; then ok "B28e over-budget text stays UNSCANNABLE"; else no "B28e over-budget text stays UNSCANNABLE" "got=${got:-<empty>}"; fi

# -- Exact output of the pure function ------------------------------------------------
# Imported the way test-marker-glob-expansion-budget-802.sh does: the module reads stdin
# and prints a verdict at import.
out=$(python3 -I - "$CLASSIFIER" "$HELPER" "$B28" "${IDENT[@]}" <<'PYEOF' 2>&1 || echo "ERROR rc=$?"
import importlib.util, io, sys

sys.stdin = io.StringIO("{}")
spec = importlib.util.spec_from_file_location("mc", sys.argv[1])
mc = importlib.util.module_from_spec(spec)
_real, sys.stdout = sys.stdout, io.StringIO()
try:
    spec.loader.exec_module(mc)
except SystemExit:
    pass
finally:
    sys.stdout = _real
H, B28, pairs = sys.argv[2], sys.argv[3], sys.argv[4:]
NL = chr(10)

def check(label, ok, detail=""):
    print(("ok    " if ok else "FAIL  ") + label + ("" if ok else " :: " + detail))

for label, text in zip(pairs[0::2], pairs[1::2]):
    got = mc._split_conditionals(text)
    check("identity " + label.split()[0], got == text, repr(got))

exact = [
    ("A1", '[[ -n x && "$g" == * ]]', '[[ -n x  ]] && [[  "$g" == * ]]'),
    ("A6", '[[ -n x&&"$g" == * ]]', '[[ -n x ]] && [[ "$g" == * ]]'),
    ("A10", '[[ -n x && -n y && "$g" == * ]]', '[[ -n x  ]] && [[  -n y  ]] && [[  "$g" == * ]]'),
    ("A11", '[[ -n x && "$g" == * ]]' + NL + 'echo ok', '[[ -n x  ]] && [[  "$g" == * ]]' + NL + 'echo ok'),
    ("A17", '[[ -n x && "$g" == * ]] && [ -f "$f" ]', '[[ -n x  ]] && [[  "$g" == * ]] && [ -f "$f" ]'),
]
for label, src, want in exact:
    got = mc._split_conditionals(src)
    check("exact rewrite " + label, got == want, repr(got))

def chain(k):
    return "[[ -n x" + " && -n x" * k + " ]]"
def delta(t):
    return len(mc._split_conditionals(t).split()) - len(t.split())
cap = mc._COND_MAX_REWRITES
check("B28 at the cap: exactly two words per interior &&", delta(chain(cap)) == 2 * cap, "delta=%d" % delta(chain(cap)))
check("B28 past the cap: the text is unchanged", mc._split_conditionals(chain(cap + 1)) == chain(cap + 1))
check("B28 2000 interior &&: unchanged", mc._split_conditionals(B28) == B28)
def globbed(k):
    return "[[ -n x && -n x ]]; ls " + " ".join("g%d?" % i for i in range(k))
gcap = mc._COND_MAX_GLOB_PROBES
check("glob probes at the cap: rewritten", mc._split_conditionals(globbed(gcap)) != globbed(gcap))
check("glob probes past the cap: unchanged", mc._split_conditionals(globbed(gcap + 1)) == globbed(gcap + 1))

# Only the operator's own text is ever rewritten: derived readings re-enter with
# `_full` set, including the same-depth `_strip_cmd_subst` re-entry.
real, calls = mc._split_conditionals, []
def recorder(t):
    calls.append(t)
    return real(t)
mc._split_conditionals = recorder
for label, src in (("B22", '$(true) [[ -n x && "$g" == * ]]'),
                   ("A3", '[[ "$(true)" -eq 1 && "$g" == *' + "') || y'" + ' ]]'),
                   ("A9", '[[ "$(printf ' + "'%s\\n'" + ' "$g" | wc -l)" -eq 1 && "$g" == * ]] || { z=0; }'),
                   # OK texts with a substitution, so `_strip_cmd_subst` re-enters
                   ("OK1", 'echo "$(true)"'),
                   ("OK2", '[[ -n x ]] && [[ "$(true)" == y ]]')):
    del calls[:]
    mc._helper_invoked(src)
    check("original text only " + label, calls == [src], repr(calls))
mc._split_conditionals = real

# Generated shapes, with dash as the oracle (`[[` is not a keyword there): a text the
# scanner rewrites must never be one whose conditional operand dash runs. `*` expands to
# the file RAN, so `"$P" *` with P=echo prints RAN exactly when the operand ran.
import itertools, os, shutil, subprocess, tempfile
DASH = shutil.which("dash")
if DASH is None:
    check("dash oracle skipped: no dash on PATH", True)
else:
    C = '[[ -n x && "$P" * ]]'
    SEG = ["true", "false", "! true", "! false", "time ! true", "time -p ! false",
           "{ true; }", "{ false; }", "! { true; }", "if true; then true; fi", "echo !",
           "[ -n x ]"]
    OPS = [";", "&&", "||", "|"]
    texts = [C] + ["%s %s %s" % (a, o, C) for a, o in itertools.product(SEG, OPS)]
    texts += ["%s %s %s %s %s" % (a, o, b, q, C)
              for a, o, b, q in itertools.product(SEG, OPS, SEG, OPS)]
    bad, rewritten = [], 0
    with tempfile.TemporaryDirectory() as d:
        open(os.path.join(d, "RAN"), "w").close()
        for t in texts:
            if mc._split_conditionals(t) == t:
                continue
            rewritten += 1
            r = subprocess.run([DASH, "-c", t], cwd=d, env={"P": "echo", "PATH": os.environ["PATH"]},
                               capture_output=True, text=True, timeout=10)
            if "RAN" in r.stdout:
                bad.append(t)
    check("dash oracle: no rewritten text runs its operand (%d rewritten of %d)"
          % (rewritten, len(texts)), not bad, repr(bad[:5]))
    check("dash oracle is not vacuous", rewritten > 100, str(rewritten))
PYEOF
)
while IFS= read -r line; do
    case "$line" in
        "ok    "*) ok "${line#ok    }" ;;
        "FAIL  "*) no "${line#FAIL  }" ;;
        *) no "pure-function harness" "$line" ;;
    esac
done <<<"$out"

printf '\n%s: %d passed, %d failed\n' "$(basename "${BASH_SOURCE[0]}")" "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
