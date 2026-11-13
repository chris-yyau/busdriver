#!/usr/bin/env bash
# #1095: scans in the pre-implementation gate that were QUADRATIC on whitespace or newline runs.
# The hook has a 5 s deadline and a killed hook is read as ALLOW, so a superlinear scan is a
# fail-open. Each check times one scan on a run long enough that the old form took seconds
# (minutes for some) and the linear form takes milliseconds, so the thresholds sit far from both.
set -u
. "$(dirname "$0")/lib/git-env-isolation.sh" || exit 1
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT/hooks/gate-scripts/lib"
GATE="$ROOT/hooks/gate-scripts/pre-implementation-gate.sh"

# A repo with a design pending, so the gate's file-modifying branch runs.
ARMED=""
trap 'rm -rf ${ARMED:+"$ARMED"}' EXIT
ARMED="$(mktemp -d)" || ARMED=""
[[ -n "$ARMED" && -d "$ARMED" ]] || { echo "  FAIL  mktemp -d"; exit 1; }
git -C "$ARMED" init -q
mkdir -p "$ARMED/docs/plans" "$ARMED/.claude" "$ARMED/src"
printf '# plan\n' >"$ARMED/docs/plans/thing.md"
bash "$LIB/resolve-repo-dir.sh" arm "$ARMED/docs/plans/thing.md" >/dev/null 2>&1

python3 -I - "$LIB" "$GATE" "$ARMED" <<'EOF'
import importlib.util, io, json, os, re, subprocess, sys, time
LIB, GATE, ARMED = sys.argv[1], sys.argv[2], sys.argv[3]
PASS = FAIL = 0


def ok(m):
    global PASS
    PASS += 1
    print("  ok    " + m)


def no(m, why):
    global FAIL
    FAIL += 1
    print("  FAIL  %s :: %s" % (m, why))


def load_marker_check():
    # marker_check runs its classifier at import; give it a harmless payload to read.
    real_in, real_out = sys.stdin, sys.stdout
    sys.stdin = io.StringIO(json.dumps({"tool_name": "Bash", "cwd": "/nonexistent",
                                        "tool_input": {"command": "true"}}))
    sys.stdout = io.StringIO()
    try:
        spec = importlib.util.spec_from_file_location("marker_check_1095", os.path.join(LIB, "marker_check.py"))
        mod = importlib.util.module_from_spec(spec)
        try:
            spec.loader.exec_module(mod)
        except SystemExit:
            pass
    finally:
        sys.stdin, sys.stdout = real_in, real_out
    return mod


mc = load_marker_check()
sys.path.insert(0, LIB)
import cmdword  # noqa: E402

# The gate's trailing `|| true` strip, read out of the gate -- not copied.
m = re.search(r'clean = re\.sub\(r"([^"]*)", "", cmd\)', open(GATE).read())
if not m:
    no("gate strip pattern", "not found in pre-implementation-gate.sh -- update this test")
    print("SUMMARY %d %d" % (PASS, FAIL))
    sys.exit(1)
strip = re.compile(m.group(1))

N = 20000
RUNS = {"spaces": " " * N + "x", "newlines": "\n" * N + "x", "mixed": " \n" * (N // 2) + "x"}
CHECKS = [
    ("marker_check._INDIRECTION_OTHER_RE", mc._INDIRECTION_OTHER_RE.search),
    ("marker_check._HEADER_RE", mc._HEADER_RE.search),
    ("marker_check._INDIRECTION_RE", mc._INDIRECTION_RE.search),
    ("cmdword._INDIRECTION_RE", cmdword._INDIRECTION_RE.search),
    ("cmdword._FUNC_DEF_RE sub", lambda s: cmdword._FUNC_DEF_RE.sub(r"\1", s)),
    ("cmdword._FUNC_DEF_LEX_RE sub", lambda s: cmdword._FUNC_DEF_LEX_RE.sub(r"\1", s)),
    ("gate trailing-strip sub", lambda s: strip.sub("", "rm x" + s)),
]
for name, fn in CHECKS:
    for kind, text in RUNS.items():
        t = time.perf_counter()
        fn(text)
        dt = time.perf_counter() - t
        label = "%s on %d %s: %.3fs" % (name, N, kind, dt)
        ok(label) if dt < 0.25 else no(label, "superlinear -- the old form took seconds here")

# A repeated blank segment is walked once: 32 KiB of bare newlines in a substitution used to
# cost a full pass per segment and ran the classifier past 30 s. The limit is the #1085
# fixture's: 4 s locally, 10 s on a GitHub runner (the 2.5x calibration #553 measured).
LIMIT = 10.0 if os.environ.get("GITHUB_ACTIONS", "").strip().lower() == "true" else 4.0
cmd = ': "$(' + "\n" * 32000 + '; ls)"'
payload = json.dumps({"tool_name": "Bash", "cwd": "/nonexistent", "tool_input": {"command": cmd}})
t = time.perf_counter()
try:
    r = subprocess.run([sys.executable, "-I", os.path.join(LIB, "marker_check.py")], input=payload,
                       capture_output=True, text=True, timeout=30)
    out = r.stdout.strip()
except subprocess.TimeoutExpired:
    out = "TIMEOUT"
dt = time.perf_counter() - t
label = "marker_check on 32000 empty segments: %s in %.2fs" % (out[:40], dt)
ok(label) if out == "OK|" and dt < LIMIT else no(label, "not OK|, or too slow for the 5 s hook deadline")

# The same run, counted rather than timed, so removing the blank-segment dedupe fails here even
# where the machine is fast enough to hide it: each classifier walks a repeated blank segment once.
blank = ': "$(' + "\n" * 4000 + '; ls)"'
calls = [0]
real_seg = cmdword._segment_is_mod


def counting_seg(*a, **k):
    calls[0] += 1
    return real_seg(*a, **k)


cmdword._segment_is_mod = counting_seg
try:
    cmdword.is_file_mod(blank)
finally:
    cmdword._segment_is_mod = real_seg
label = "cmdword walks 4000 blank segments %d times" % calls[0]
ok(label) if calls[0] < 200 else no(label, "each repeated blank segment is walked again")
calls[0] = 0
real_raw = mc._raw_words


def counting_raw(*a, **k):
    calls[0] += 1
    return real_raw(*a, **k)


mc._raw_words = counting_raw
try:
    mc._helper_invoked(blank)
finally:
    mc._raw_words = real_raw
label = "marker_check walks 4000 blank segments %d times" % calls[0]
ok(label) if calls[0] < 200 else no(label, "each repeated blank segment is walked again")

# The gate's own state-file allowlist, through the real gate with a design pending. `\S+` could
# end at any later `.claude/` inside a word, so a failing match tried every split: 30 glued
# prefixes took minutes, and a killed hook lets `rm -rf src` through.
cmd = "rm -rf " + ".claude/a" * 30 + " src"
payload = json.dumps({"tool_name": "Bash", "cwd": ARMED, "tool_input": {"command": cmd}})
t = time.perf_counter()
try:
    r = subprocess.run(["bash", GATE], input=payload, cwd=ARMED, capture_output=True, text=True, timeout=30)
    got = "block" if '"block"' in r.stdout else "allow rc=%d" % r.returncode
except subprocess.TimeoutExpired:
    got = "TIMEOUT"
dt = time.perf_counter() - t
label = "gate: rm -rf of 30 glued state prefixes then src: %s in %.2fs" % (got, dt)
ok(label) if got == "block" and dt < LIMIT else no(label, "must block inside the hook deadline")

print("SUMMARY %d %d" % (PASS, FAIL))
sys.exit(1 if FAIL else 0)
EOF
rc=$?
echo
echo "════ gate-linear-scans-1095: rc=$rc ════"
exit "$rc"
