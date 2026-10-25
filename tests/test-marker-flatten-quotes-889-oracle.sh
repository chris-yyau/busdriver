#!/usr/bin/env bash
# Property tests for #889 (classifier side), split from test-marker-flatten-quotes-889.sh
# for the CI budget (design: docs/plans/2026-10-24-issue-889-flatten-literal-quotes.md).
#
#   1. Span oracle: every span _literal_spans keeps is literal to bash. A probe planted in
#      each kept span must never run. Positive control: a lexer that opens a span inside
#      "..." must be caught.
#   2. Verdict oracle: wherever a marker slot actually executes under bash and the lexer
#      accepts the text, the change blocks whenever today's reading blocks. The reference
#      is the change with the lexer forced to bail, which is byte-for-byte today's flatten
#      (a checkout of main would be the change itself after merge). Three positive controls
#      each disable one rule and must find a regression.
#
# bash only ever runs harmless stand-ins (`echo PR\OBE`, `printf`); the classifier sees the
# slot filled with a helper invocation as JSON data. Seeds are fixed; raise N offline with
#   tests/test-marker-flatten-quotes-889-oracle.sh <span-N> <verdict-N>
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SPAN_N="${1:-5000}"
VERDICT_N="${2:-1000}"
FAIL=0

echo "== span oracle (seed 889, N=$SPAN_N)"
python3 -I - "$ROOT" "$SPAN_N" <<'PY' || FAIL=$((FAIL + 1))
import inspect, io, os, random, subprocess, sys, tempfile

ROOT, N, SEED = sys.argv[1], int(sys.argv[2]), 889
sys.path.insert(0, os.path.join(ROOT, 'hooks/gate-scripts/lib'))
sys.stdin = io.StringIO('')          # the module's gate run sees no payload and is ignored
_out, sys.stdout = sys.stdout, io.StringIO()
import marker_check                  # noqa: E402
sys.stdout = _out

lexer = marker_check._literal_spans
src = inspect.getsource(lexer)
broken_src = src.replace('def _literal_spans(', 'def _broken(').replace(
    'if ctx[0] == "dq":', 'if ctx[0] == "dq" and c != chr(39):', 1)
assert broken_src.count('def _broken(') == 1 and 'c != chr(39)' in broken_src
ns = dict(vars(marker_check))
# The word-boundary rule would reject the planted fake spans before the probe sees them.
ns['_span_stands_alone'] = lambda *_a: True
exec(broken_src, ns)
broken = ns['_broken']

# `PR\OBE` becomes `PROBE` only when echo RUNS: an error message quoting the literal text
# keeps the backslash, so it cannot fake a hit.
PROBE_SQ = ';echo PR\\OBE>&2;$(echo PR\\OBE>&2)'
PROBE_DQ = ';echo PR\\OBE>&2;'
ENV = {'PATH': '/usr/bin:/bin'}
SQ_CH = ['a', ' ', '"', '(', ')', '$(', ';', '|', '#', '${', '}', '\\', '`', '\t', '((', '$[', '<<']
DQ_CH = ['a', ' ', "'", '(', ')', ';', '|', '#', '}', '\t', ']']


def g_cmd(rng, d):
    parts = [g_simple(rng, d)]
    for _ in range(rng.randint(0, 2)):
        parts.append(rng.choice(['; ', ' | ', ' && ', '\n']) + g_simple(rng, d))
    return ''.join(parts)


def g_simple(rng, d):
    r = rng.random()
    if d < 3 and r < 0.12:
        return 'case ' + g_word(rng, d) + ' in ' + rng.choice(['a', '*', "''|*"]) + ') ' + g_cmd(rng, d + 1) + ';; esac'
    if d < 3 and r < 0.2:
        return '( ' + g_cmd(rng, d + 1) + ' )'
    # No `let`/`declare -i`: those re-evaluate a literal span (D4), the verdict oracle's job.
    return rng.choice(['echo', 'true', ':']) + ''.join(' ' + g_word(rng, d) for _ in range(rng.randint(0, 3)))


def g_word(rng, d):
    return ''.join(g_part(rng, d) for _ in range(rng.randint(1, 3)))


def g_part(rng, d):
    r = rng.random()
    if r < 0.3:
        return "'" + ''.join(rng.choice(SQ_CH) for _ in range(rng.randint(0, 5))) + "'"
    if r < 0.55:
        inner = []
        for _ in range(rng.randint(0, 4)):
            q = rng.random()
            if d < 3 and q < 0.25:
                inner.append('$(' + g_cmd(rng, d + 1) + ')')
            elif q < 0.35:
                inner.append('${a:-' + rng.choice(['b', '${c}', '${d:-e}']) + '}')
            elif q < 0.42:
                inner.append(rng.choice(['\\"', '\\$', '\\\\']))
            else:
                inner.append(rng.choice(DQ_CH))
        return '"' + ''.join(inner) + '"'
    if d < 3 and r < 0.68:
        return '$(' + g_cmd(rng, d + 1) + ')'
    if r < 0.76:
        return rng.choice(['${a}', '${a:-b}', '${#a}', '${a%% *}', '${a/x/y}', '${a:-${b}}'])
    if r < 0.82:
        return '\\' + rng.choice(['a', "'", '"', ';', '(', ')', '$', ' '])
    return rng.choice(['a', 'x', '*', '=', '-eq'])


def mutate(toks):
    return ''.join((t[:-1] + (PROBE_SQ if t[0] == "'" else PROBE_DQ) + t[-1]) if len(t) > 1 else t
                   for t in toks)


def run(fn, label, cwd):
    rng = random.Random(SEED)
    accepted = spans = hits = 0
    for _ in range(N):
        c = g_cmd(rng, 0)
        if subprocess.run(['bash', '-n', '-c', c], capture_output=True).returncode:
            continue
        toks = fn(c)
        if toks is None:
            continue
        assert ''.join(toks) == c, (c, toks)
        k = sum(1 for t in toks if len(t) > 1)
        accepted += 1
        if not k:
            continue
        spans += k
        try:
            r = subprocess.run(['bash', '-c', mutate(toks)], cwd=cwd, env=ENV, stdin=subprocess.DEVNULL,
                               capture_output=True, text=True, timeout=5)
        except subprocess.TimeoutExpired:
            continue  # skipped, not counted
        if 'PROBE' in r.stderr:
            hits += 1
            if hits == 1:
                print(f'  {label} first hit: {c!r}')
    print(f'  {label:8} accepted={accepted} probed-spans={spans} probe-fired={hits}')
    return hits


with tempfile.TemporaryDirectory() as d:
    real = run(lexer, 'lexer', d)
    ctrl = run(broken, 'control', d)
ok = real == 0 and ctrl > 0
print('  ' + ('ok    ' if ok else 'FAIL  ') + f'span oracle (lexer hits={real}, control hits={ctrl})')
sys.exit(0 if ok else 1)
PY

echo "== verdict non-regression oracle (seed 889, N=$VERDICT_N)"
python3 -I - "$ROOT" "$VERDICT_N" <<'PY' || FAIL=$((FAIL + 1))
import importlib.util, io, json, os, random, shutil, subprocess, sys, tempfile

ROOT, N, SEED = sys.argv[1], int(sys.argv[2]), 889
LIB = 'hooks/gate-scripts/lib'
H = 'python3 ' + LIB + '/lease_' + 'slot.py'
# `PR\OBE` becomes PROBE only when echo RUNS; >&2 because a substitution captures stdout.
RUN = 'echo PR\\OBE >&2'
# Through a parameter expansion `>&2` and `\` are plain text, so that family uses printf
# (whose literal text reads `PR OBE`) and the check reads stdout as well.
RUN_EXP = 'printf %s%s\\n PR OBE'
MK = '\x00'
CONTROL_BUDGET = 5
# Every generated slot names the helper, so the name probe alone would mask what the
# word-boundary rules protect: those controls disable it too.
NAME_PROBE_OFF = ('_span_names_helper(t[1:-1])', 'False')
CONTROLS = [  # (label, [(unique text in marker_check.py, replacement)]) disabling one rule
    ('word-boundary rule off', [('    left = cmd[i - 1] if i else ""\n',
                                 '    return True\n    left = cmd[i - 1] if i else ""\n'), NAME_PROBE_OFF]),
    ('escaped-delimiter check off', [('if i >= 2 and cmd[i - 2] == "\\\\":', 'if False:'), NAME_PROBE_OFF]),
    ('bound-span check off', [('_helper_invoked(t[1:-1], _depth + 1, _full=_whole)', 'False')]),
]


def load_lexer(root, name):
    sys.path.insert(0, os.path.join(root, LIB))
    spec = importlib.util.spec_from_file_location(name, os.path.join(root, LIB, 'marker_check.py'))
    mod = importlib.util.module_from_spec(spec)
    old_in, old_out, sys.stdin, sys.stdout = sys.stdin, sys.stdout, io.StringIO(''), io.StringIO()
    try:
        spec.loader.exec_module(mod)
    finally:
        sys.stdin, sys.stdout = old_in, old_out
        sys.path.pop(0)
    return mod._literal_spans


def piece(rng, d):
    r = rng.random()
    if r < 0.25:
        return "'" + rng.choice(['a', ' ', '; ', 'echo ', '(x)', '|', '"']) + "'"
    if r < 0.45 and d < 2:
        return '$(' + rng.choice(['true', 'echo a', 'printf %s 3']) + ')'
    if r < 0.55:
        return '"' + rng.choice(['a', '$x', "'", '$', '(', ' ']) + '"'
    if r < 0.65:
        return rng.choice(['${a}', '${a:-b}', '$x', 'x', 'a'])
    return rng.choice([' ', '', 'echo ', '; '])


def payload(rng, d):
    # a string that bash concatenates and a nested shell then runs
    parts = [rng.choice(['echo ', 'for x in x; do echo ', 'case x in x) echo '])]
    parts += [piece(rng, d) for _ in range(rng.randint(0, 3))]
    parts += ['; ', MK]
    tail = {'for': '; done', 'case': ';; esac'}
    p = ''.join(parts) + (tail['for'] if parts[0].startswith('for') else tail['case'] if parts[0].startswith('case') else '')
    out, k = [], 0
    while k < len(p):
        step = rng.randint(1, 8)
        chunk = p[k:k + step]
        style = rng.random()
        if MK in chunk or "'" in chunk or style < 0.4:
            out.append(chunk if "'" in chunk or MK in chunk else "'" + chunk + "'")
        elif style < 0.5:
            # an escaped delimiter glued to a quoted chunk: literal to bash, so the words join
            out.append(rng.choice(['\\(', '\\ ', '\\;', '\\)', '\\|']) + "'" + chunk + "'")
        elif style < 0.75 and d < 2:
            out.append("'" + chunk + "'" + '$(true)')
        else:
            out.append('"' + chunk.replace('"', '') + '"')
        k += step
    return ''.join(out)


def bound(rng):
    # a span bound to a name (or array), expanded in command position later
    q = rng.choice(["'", '"'])
    bind = rng.choice(['P=', 'P+=', 'P=x Q=', 'a=(', 'a+=( ', 'a=(\n', 'n=P; P='])
    val = q + MK + q + (' )' if bind.startswith('a') else '')
    var = {'P=': 'P', 'P+=': 'P', 'P=x Q=': 'Q', 'a=(': 'a', 'a+=( ': 'a', 'a=(\n': 'a',
           'n=P; P=': '!n'}[bind]
    use = rng.choice(['$V', '${V}', '( $V )', '$V | cat', 'echo $V | sh', 'eval \\$V', '{ $V; }'])
    if var == '!n':
        use = '${!n}'
    return bind + val + '; ' + use.replace('V', var)


def gen(rng):
    r = rng.random()
    pre = rng.choice(['', '$(true); ', 'R=$(jq -r ' + "'.a'" + ' f); ', 'x="$(echo a)"; '])
    if r < 0.35:
        return pre + rng.choice(['sh -c ', 'bash -c ', 'eval ']) + payload(rng, 0), RUN
    if r < 0.55:
        esc = rng.choice(['\\(', '\\ ', '\\;', '\\|', '\\<', '\\&'])
        q = rng.choice(['"a[$"' + "'(" + MK + ")]=1'", "'a['" + '"$("' + MK + "')]=1'",
                        "'a[$('" + MK + "')]=1'", '"a[$("' + MK + '")]=1"',
                        '"a[$"' + esc + "':; " + MK + ")]'", "a[$" + esc + "'; " + MK + ")]'",
                        '"a[$"\\(' + "'" + MK + ")]'"])
        op = rng.choice(['let ', 'declare -i b=', '(( '])
        return pre + op + q + (' ))' if op == '(( ' else ''), RUN
    if r < 0.75:
        return (pre or '$(true); ') + bound(rng), RUN_EXP
    if r < 0.88:
        return pre + "x=$(echo " + piece(rng, 0) + '; ' + MK + ')', RUN
    return pre + 'echo "$(' + piece(rng, 0) + '; ' + MK + ')"', RUN


def verdict(root, c):
    p = json.dumps({"tool_name": "Bash", "tool_input": {"command": c}, "cwd": "/repo"})
    return subprocess.run(['python3', '-I', os.path.join(root, LIB, 'marker_check.py')],
                          input=p, capture_output=True, text=True).stdout.strip()


def run(root, lex, stop_at_first, ref):
    rng = random.Random(SEED)
    tested = runs = regress = 0
    first = None
    # A control stops at its first regression, so a larger budget costs time only when it
    # would otherwise miss: the escaped-delimiter shape is rare (about 9 in 3000).
    for _ in range(N * CONTROL_BUDGET if stop_at_first else N):
        t, stand_in = gen(rng)
        real = t.replace(MK, H)
        if lex(real) is None:
            continue  # the lexer bails: byte-for-byte today's reading
        try:
            r = subprocess.run(['bash', '-c', t.replace(MK, stand_in)], capture_output=True, text=True,
                               timeout=5, stdin=subprocess.DEVNULL, env={'PATH': '/usr/bin:/bin'},
                               cwd=tempfile.gettempdir())
        except subprocess.TimeoutExpired:
            continue
        tested += 1
        if 'PROBE' not in r.stderr + (r.stdout if stand_in == RUN_EXP else ''):
            continue
        runs += 1
        if verdict(ref, real).startswith('BLOCK') and not verdict(root, real).startswith('BLOCK'):
            regress += 1
            first = first or t.replace(MK, '<H>')
            if stop_at_first:
                break
    return tested, runs, regress, first


src = open(os.path.join(ROOT, LIB, 'marker_check.py')).read()
ok = True
with tempfile.TemporaryDirectory() as tmp:
    def patched(name, edits):
        text = src
        for old, new in edits:
            assert text.count(old) == 1, (name, old)
            text = text.replace(old, new)
        root = os.path.join(tmp, name)
        shutil.copytree(os.path.join(ROOT, LIB), os.path.join(root, LIB),
                        ignore=shutil.ignore_patterns('__pycache__'))
        with open(os.path.join(root, LIB, 'marker_check.py'), 'w') as fh:
            fh.write(text)
        return root
    # By D2, the change with the lexer always bailing is byte-for-byte today's flatten.
    ref = patched('ref', [('def _literal_spans(cmd):\n', 'def _literal_spans(cmd):\n    return None\n')])
    tested, runs, regress, first = run(ROOT, load_lexer(ROOT, 'mc_change'), False, ref)
    good = regress == 0 and runs > 0
    ok &= good
    print('  ' + ('ok    ' if good else 'FAIL  ')
          + f'change: lexer-accepted={tested} slot-ran={runs} regressions={regress} first={first!r}')
    for i, (label, edits) in enumerate(CONTROLS):
        root = patched(str(i), edits)
        _, cruns, creg, cfirst = run(root, load_lexer(root, f'mc_ctl{i}'), True, ref)
        ok &= creg > 0
        print('  ' + ('ok    ' if creg else 'FAIL  ')
              + f'control {label}: slot-ran={cruns} first-regression={cfirst!r}')
sys.exit(0 if ok else 1)
PY

echo
echo "════ marker-flatten-quotes-889-oracle: $((2 - FAIL)) passed, $FAIL failed ════"
[[ "$FAIL" -eq 0 ]]
