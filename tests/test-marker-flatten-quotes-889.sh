#!/usr/bin/env bash
# Regression tests for #889 (classifier side) — the `$(...)` flatten keeps quoted text that
# bash reads as wholly literal whole, instead of dropping every quote.
#
# History: _helper_invoked flattened any command holding `$(` by deleting every quote, so a
# jq filter or `node -e` snippet in single quotes read as fake pipes and subshells and the
# pr-grind composers were refused with "Cannot call lease_slot.py directly". _literal_spans
# now finds the spans bash reads literally and the pairing loop keeps them opaque; on any
# text it does not model it returns None, which is exactly the old reading
# (design: docs/plans/2026-10-24-issue-889-flatten-literal-quotes.md).
#
# Pinned: the repros and their ordinary neighbours are allowed (A); every shape that RUNS
# the helper through quoted text keeps the producer probe's BLOCK (B, D4, D5, word
# boundary); a span that names a helper keeps today's reading; each lexer bail returns
# None. The D5 check and the name probe are proved live: disabled in a temp copy, their
# rows must stop blocking. The oracles live in test-marker-flatten-quotes-889-oracle.sh.
# Fixture text is inert classifier input: nothing here executes a helper.
set -u
. "$(dirname "$0")/lib/git-env-isolation.sh" || exit 1

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

python3 -I - "$ROOT" <<'PY'
import json, os, shutil, subprocess, sys, tempfile

ROOT = sys.argv[1]
LIB = 'hooks/gate-scripts/lib'
L = 'lease_' + 'slot'
H = 'python3 ' + LIB + '/' + L + '.py'
T = H + ' state(x) 20 0 99999'  # trailing arguments: a bare path is caught without D5 in places
M = 'python3 -m ' + L + ' state 20 0 99999'
Q, D, B = "'", '"', '\\'
counts = [0, 0]


def verdict(root, cmd):
    p = json.dumps({"tool_name": "Bash", "tool_input": {"command": cmd}})
    try:
        r = subprocess.run(['python3', '-I', os.path.join(root, LIB, 'marker_check.py')],
                           input=p, capture_output=True, text=True, timeout=60)
    except subprocess.TimeoutExpired:
        return 'ERROR(timeout)'
    return r.stdout.strip() if r.returncode == 0 else 'ERROR'


def check(cond, label, got):
    counts[0 if cond else 1] += 1
    label = label.replace('\n', '\\n').replace('\t', '\\t')
    print(('  ok    ' if cond else '  FAIL  ') + label + ('' if cond else ' :: got=' + repr(got)))


def ok(cmd, label, root=ROOT):
    got = verdict(root, cmd)
    check(got == 'OK|', label, got)


def block(cmd, label, root=ROOT):
    # The producer probe's own reason, not any BLOCK_*: another rule refusing the same text
    # would otherwise keep a regressed guard green.
    got = verdict(root, cmd)
    check(got.startswith('BLOCK_MARKER_SCRIPT|'), label, got)


def fence_after(path, anchor):
    s = open(os.path.join(ROOT, path)).read()
    i = s.index(anchor)
    j = s.rfind('```bash\n', 0, i)
    return s[j + len('```bash\n'):s.index('```', i)]


REPRO1 = (
    "  R=$(printf '%s' \"$CJ\" | jq -r '[.[] | select((.type // \"User\")==\"User\" and ((.login // \"\")|endswith(\"[bot]\")|not) and ((.permissions.push // false)==true)) | .login] | {count: length, first: (.[0] // \"\")} | \"\\(.count) \\(.first)\"' 2>/dev/null || echo \"0 \")\n"
    "  HUMAN_ADMIN_COUNT=\"${R%% *}\"; SOLE=\"${R#* }\"; case \"$HUMAN_ADMIN_COUNT\" in ''|*[!0-9]*) HUMAN_ADMIN_COUNT=0;; esac\n"
    "GAP_DECISION_JSON=$(bash \"${CLAUDE_PLUGIN_ROOT}/scripts/approver-gap-detect.sh\" 2>/dev/null || echo '{\"decision\":\"surface-decision\",\"trigger\":\"none\",\"reason\":\"detector failed\"}')\n")
REPRO2 = (
    "P=$(node -e 'console.log(require.resolve(\"posthog-js/package.json\"))' 2>/dev/null); D=$(dirname \"$P\"); grep -o '\"version\": \"[^\"]*\"' \"$P\"; grep -rln \"blockClass\" \"$D/lib\" \"$D/dist\" 2>/dev/null | grep \"\\.d\\.ts\" | head -3; grep -rn \"blockClass\" $(grep -rln \"blockClass\" \"$D/lib\" \"$D/dist\" 2>/dev/null | grep \"\\.d\\.ts\" | head -1) | head -3\n"
    "S=$(dirname $(node -e 'console.log(require.resolve(\"@sentry-internal/replay/package.json\"))' 2>/dev/null) 2>/dev/null); echo \"sentry replay dir: $S\"; grep -o '\"version\": \"[^\"]*\"' \"$S/package.json\" 2>/dev/null\n")
REPRO3 = (
    "RESULT_FIXES='add modifiedDate 2026-10-19 to labour-dept-esls-imported-worker-briefings-sep-oct-2026 in latest-data.ts (Kody thread PRRT_kwDORDyWW86ttOy4 and CodeRabbit merge-risk note)'\n"
    "  /*) printf 'RECOVERY_LIB_ROOT=%q\\n' \"$_bd890_root/scripts/lib\" >&2 ;;\n"
    "if [ \"$(git -C \"$WORKTREE_DIR\" symbolic-ref -q HEAD)\" != \"refs/heads/$_bd890_branch\" ]; then\n"
    "    | tee \"$_bd890_env_file\"\n"
    "  [ \"$_bd890_rc\" -ne 0 ] || _bd890_rc=1\n")

print('== A: the #889 repros and their ordinary spellings are allowed')
ok(REPRO1, 'repro 1: approver-gap composer (jq filter beside $(...))')
ok(REPRO2, 'repro 2: node -e / grep inspection')
ok(REPRO3, '2.10.1 minimal: parenthesized RESULT_FIXES + | tee')
ok("x=$(jq -r '[.[] | select((.a // \"b\")==\"c\")]' f)", 'a jq filter in isolation')
ok("P=$(node -e 'console.log(require.resolve(\"p/package.json\"))'); echo \"$P\"", 'node -e in isolation')
ok("x=$(true); grep -o '\"version\": \"[^\"]*\"' \"$P\"", "repro 2's grep pattern beside a $(...)")
ok("if [ \"$(true)\" = x ]; then RESULT_FIXES='fix a (b) in c'; fi", 'a parenthesized assignment beside $(...) in an if')
ok("RESULT_FIXES='fix (a) | b'; x=$(true)", "RESULT_FIXES='...(...)...' beside a $(...)")
ok("R=$(printf %s 3); case \"$R\" in ''|*[!0-9]*) R=0;; esac", "an empty '' span in a case pattern")
ok("R=$(jq -r '.a' f); grep --filter='a (b) | c' x", "--filter='a (b) | c' beside a $(...)")
ok("R=$(printf %s 3); jq -r '.a | (.b)' <<< 'x'", "jq ... <<< 'x' beside a $(...)")

print('== B: every shape that runs the helper through quoted text keeps blocking')
for c in [
    f'echo "it{Q}s $({H})"',
    f'echo "$(echo {Q}x){Q}; {H})"',
    f'echo "$(echo {Q}a{Q}"b"; {H})"',
    f'x=$(python3 {Q}{LIB}/lease_{Q}slot.py)',
    f'x=$(python3 {LIB}/{Q}{L}.py{Q})',
    f'x=$(sh -c {Q}{H}{Q})',
    f'echo "$(sh -c {Q}x; {H}{Q})"',
    f'x=$(bash -c {Q}python3 hooks/*/lib/lease_*.py{Q})',
    f'x=$(eval {Q}{H}{Q})',
    f'x=$(printf %s {Q}{H}{Q} | sh)',
    f'printf %s {Q}{H}{Q} | sh',
    f'echo "$(printf {Q}%s{Q} "{H}" | bash)"',
    f'R=$(jq -r {Q}.a | (.b){Q} f); {H}',
    f'R=$(jq -r {Q}.a | (.b){Q} f); x=$({H})',
    f'echo {Q}a{Q}; $({H})',
    f'case x in a) y=$({H});; esac',
    f'f() {{ echo "$1"; }}; x=$(f {Q}(z){Q}; {H})',
    f'echo "$( (echo {Q})({Q}); {H} )"',
    f'x=$(echo {Q}"{Q}; {H}; echo {Q}"{Q})',
    f'x="$(echo "{Q}"; {H}; echo "{Q}")"',
    f'x=$(echo {B}{Q}; {H}; echo {B}{Q})',
    f'x=$(echo {Q}${{{Q}; {H})',
    f'x=$({Q}python3{Q} {LIB}/{L}.py)',
    f'x=$(p{Q}ython3{Q} {Q}{LIB}/{L}.py{Q})',
    f'x=$(xargs sh -c {Q}{H}{Q} <<< y)',
    f'x=$(bash <<< {Q}{H}{Q})',
]:
    block(c, c.replace(H, '<H>'))

print('== D4: builtins that re-evaluate a literal span keep blocking')
for c in [
    f"x=$(let 'a[$({H})]=1')",
    f"x=$([[ 1 -eq 'a[$({H})]' ]] && echo y)",
    f"x=$(declare -i 'b=a[$({H})]')",
    f"x=$(printf -v 'a[$({H})]' %s 1)",
    f"echo \"$(let 'a[$({H})]=1')\"",
    f"R=$(jq -r '.a' f); let 'a[$({H})]=1'",
]:
    block(c, c.replace(H, '<H>'))

print('== D3 word boundary: glued spans, $( assembled across quotes, escaped delimiters')
for c in [
    f"sh -c 'for x in x; do echo '$(true)'; {H}; done'",
    f'bash -c "echo "$(true)"; {H}"',
    f"sh -c 'case x in x) echo '$(true)'; {H};; esac'",
    "$(true); let " + D + "a[$" + D + Q + "(" + H + ")]=1" + Q,
    "$(true); declare -i " + D + "b=a[$" + D + Q + "(" + H + ")]" + Q,
    "$(true); printf -v " + D + "a[$" + D + Q + "(" + H + ")]" + Q + " %s 1",
    f"sh -c 'echo '$(true)' {H}'",
    "x=$(true); let " + D + "a[$" + D + B + "(" + Q + ":; " + H + ")]" + Q,
    "x=$(true); let a[$" + B + "(" + Q + ":;" + H + ")]" + Q,
    "x=$(true); let a[$" + B + "(" + B + " " + Q + ":;" + H + ")]" + Q,
    "x=$(true); let a[$" + B + "(x=" + Q + ":;" + H + ")]" + Q,
    "x=$(true); declare -i b=a[$" + B + "(" + Q + ":;" + H + ")]" + Q,
    "x=$(true); printf -v a[$" + B + "(" + Q + ":;" + H + ")]" + Q + " %s 1",
    "x=$(true); [[ 1 -eq a[$" + B + "(" + Q + ":;" + H + ")]" + Q + " ]]",
]:
    block(c, c.replace(H, '<H>'))

# D5: a span bound to a name can run later. Scalar rows use the trailing-argument witness;
# array rows the module witness, because a bare path is caught there without D5.
D5_MUT = [r.replace('{W}', T) for r in [
    "x=$(true); P='{W}'; $P", "x=$(true); P='{W}'; ${P}", "x=$(true); P='{W}'; ( $P )",
    "x=$(true); P='{W}'; { $P; }", "x=$(true); P='{W}'; $P | cat", "x=$(true); P='{W}'; echo $P | sh",
    "x=$(true); n=P; P='{W}'; ${!n}", "x=$(true); P=x Q='{W}'; $Q", "x=$(true); --x='{W}'",
    'x=$(true); P="{W}"; $P', "y=\"$(P='{W}'; $P)\"",
]] + [r.replace('{W}', M) for r in [
    "x=$(true); a=('{W}'); $a", "x=$(true); a=( '{W}' ); $a", "x=$(true); a=(\t'{W}'); $a",
    "x=$(true); a=(\n'{W}'\n); $a", 'x=$(true); a=( "{W}" ); $a', "x=$(true); a+=( '{W}' ); $a",
    "x=$(true); a=( $(true) '{W}' ); $a",
]]
print('== D5: bound spans whose text runs the helper keep blocking')
for c in D5_MUT:
    block(c, c.replace(T, '<T>').replace(M, '<M>'))
for c in ["x=$(true); P='{W}'; eval \\$P", "x=$(true); f() { P='{W}'; $P; }; f", "x=$(true); P+='{W}'; $P"]:
    c = c.replace('{W}', T)
    block(c, c.replace(T, '<T>') + ' (blocked without D5)')

print('== D5 is live: with its check disabled, every mutation row stops blocking')
with tempfile.TemporaryDirectory() as tmp:
    shutil.copytree(os.path.join(ROOT, LIB), os.path.join(tmp, LIB), ignore=shutil.ignore_patterns('__pycache__'))
    p = os.path.join(tmp, LIB, 'marker_check.py')
    s = open(p).read()
    old = '_helper_invoked(t[1:-1], _depth + 1, _full=_whole)'
    check(s.count(old) == 1, 'the D5 call is present exactly once', s.count(old))
    open(p, 'w').write(s.replace(old, 'False'))
    for c in D5_MUT:
        got = verdict(tmp, c)
        check(not got.startswith('BLOCK'), 'D5 off: ' + c.replace(T, '<T>').replace(M, '<M>'), got)

print('== R7 (accepted residual): execute-a-string transports keep their current verdict')
S = 'state(' + LIB + '/' + L + '.py)'
ok(f"read -r P <<< '{S}'; $P", "read -r P <<< 'state(<P>)'; $P")
ok(f"set -- '{S}'; $1", "set -- 'state(<P>)'; $1")

# A span that names a helper keeps today's reading wherever it sits, because the program
# it is handed may execute it. Main blocks these through the #889 misreading (each plain
# form, without `x=$(true); `, is OK on main); the change keeps main's verdict.
NAMED = [
    f"x=$(true); read -r P <<< '{S}'; $P",
    f"x=$(true); set -- '{S}'; $1",
    f"x=$(true); python3 -c 'import os; os.system(\"{H}\")'",
    f"x=$(true); node -e 'require(\"child_process\").execSync(\"{H}\")'",
    f"x=$(true); awk 'BEGIN{{system(\"{H}\")}}'",
    "x=$(true); python3 -c 'import os; os.system(\"python3 hooks/*/lib/lease_*.py\")'",
]
print('== a span naming a helper keeps today\'s reading (R7 flips, R8 interpreters, globs)')
for c in NAMED:
    block(c, c.replace(S, 'state(<P>)').replace(H, '<H>'))

print('== the name probe is live: with it disabled, every named-span row stops blocking')
with tempfile.TemporaryDirectory() as tmp:
    shutil.copytree(os.path.join(ROOT, LIB), os.path.join(tmp, LIB), ignore=shutil.ignore_patterns('__pycache__'))
    p = os.path.join(tmp, LIB, 'marker_check.py')
    s = open(p).read()
    old = '_span_names_helper(t[1:-1])'
    check(s.count(old) == 1, 'the name probe call is present exactly once', s.count(old))
    open(p, 'w').write(s.replace(old, 'False'))
    for c in NAMED:
        got = verdict(tmp, c)
        check(not got.startswith('BLOCK'), 'probe off: ' + c.replace(S, 'state(<P>)').replace(H, '<H>'), got)

print('== the span checks are speculative: they leave the scan budget to the reading after')
# 33 bound spans of 100 words each: the checks once spent the token budget main gives the
# reading that follows, which then reported BLOCK_UNSCANNABLE where main is OK.
LONG = 'x=$(true); ' + ("P='echo" + ' x' * 100 + "'; ") * 33 + 'printf done'
ok(LONG, '33 long bound spans beside a $(...)')

print('== pinned residual: the shipped pr-grind blocks carry # comments, so the lexer bails')
block(fence_after('skills/pr-grind/SKILL.md', 'SOLO_OPTIN_SNAPSHOT='), 'Step 0 solo-admin snapshot block')
block(fence_after('skills/pr-grind/references/completion.md', 'HUMAN_ADMIN_COUNT='), 'completion.md approver-gap block')

print('== bound: 60KB floods finish inside the per-call budget')
for unit in ["P='x'; ", "P='a (b) | c'; ", "--o='x' ", "a=('x'); ", "P='echo x'; ", "'a' $(true) ", '"a" $(true) ']:
    got = verdict(ROOT, unit * (60000 // len(unit)))
    check(not got.startswith('ERROR'), 'flood ' + repr(unit), got)

print('== _literal_spans: every unmodelled shape bails to None')
sys.path.insert(0, os.path.join(ROOT, LIB))
sys.stdin = open(os.devnull)
_out, sys.stdout = sys.stdout, open(os.devnull, 'w')
import marker_check as mc  # noqa: E402  (its top-level gate run sees an empty stdin)
sys.stdout = _out
for c, why in [
    ('echo `date` $(true)', 'backtick'),
    ('cat <<E\nx\nE\n$(true)', 'heredoc'),
    ("echo $'a' $(true)", 'ANSI-C quoting'),
    ('((1)); $(true)', '(( arithmetic'),
    ('echo $((1)) $(true)', '$(( arithmetic'),
    ('echo $[1] $(true)', '$[ arithmetic'),
    ('echo x # c $(true)', 'a comment'),
    ('#x $', '# at index 0'),
    ('echo $(true) \\', 'trailing backslash'),
    ('echo x \\\n$(true)', 'line continuation'),
    ("echo \\'hi\\' $(true)", 'an escaped quote'),
    ('echo ${a[0]} $(true)', '${ outside the allowlist'),
    ("echo 'a $(true)", 'an unterminated single quote'),
    ("echo a'b' $(true)", 'a span glued to a word'),
    ('echo a"b" $(true)', 'a literal "..." glued to a word'),
    ('( case x in a) y;; esac ); $(true)', 'a case arm closer inside a frame'),
    ('echo $(true', 'an unclosed frame'),
]:
    got = mc._literal_spans(c)
    check(got is None, 'None on ' + why, got)
got = mc._literal_spans("case x in ''|*) :;; esac")
check(got is not None and "''" in got, "an empty '' span is kept", got)
got = mc._literal_spans("x=$(true); jq '.a | (.b)' f")
check(got is not None and "'.a | (.b)'" in got, 'a jq filter is one kept span', got)
W = mc._SPAN_WORD_MAX
check(not mc._span_names_helper(' '.join(['word'] * W)), 'a span at the word cap is probed', W)
check(mc._span_names_helper(' '.join(['word'] * (W + 1))), 'a span past the word cap keeps today\'s reading', W)
Y = mc._SPAN_PROBE_BYTES
check(not mc._span_names_helper('a' * Y), 'a span at the byte cap is probed', Y)
check(mc._span_names_helper('a' * (Y + 1)), 'a span past the byte cap keeps today\'s reading', Y)

print()
print(f'════ marker-flatten-quotes-889: {counts[0]} passed, {counts[1]} failed ════')
sys.exit(1 if counts[1] else 0)
PY
