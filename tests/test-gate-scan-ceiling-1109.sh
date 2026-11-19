#!/usr/bin/env bash
# #1109: marker_check's helper scan walked commands up to 65,536 characters in full, and a
# 65,000-character command took 5.66s on an Apple-silicon Mac -- past the 5s hook deadline,
# which the harness reads as ALLOW (#553). The full walk now stops at 32,768 characters
# (cmdword's _LEX_READING_MAX); anything longer fails closed as UNSCANNABLE without the walk.
set -u
. "$(dirname "$0")/lib/git-env-isolation.sh" || exit 1
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT/hooks/gate-scripts/lib"
. "$ROOT/tests/lib/gate-cwd-isolation.sh" || exit 1   # #1064

# A repo with a design pending, so the gate's file-modifying branch runs too.
ARMED=""
trap 'rm -rf ${ARMED:+"$ARMED"}' EXIT
ARMED="$(mktemp -d)" || ARMED=""
[[ -n "$ARMED" && -d "$ARMED" ]] || { echo "  FAIL  mktemp -d"; exit 1; }
git -C "$ARMED" init -q || { echo "  FAIL  git init (armed)"; exit 1; }
mkdir -p "$ARMED/docs/plans" "$ARMED/.claude"
printf '# plan\n' >"$ARMED/docs/plans/thing.md"
bash "$LIB/resolve-repo-dir.sh" arm "$ARMED/docs/plans/thing.md" >/dev/null 2>&1 \
    || { echo "  FAIL  arming the design marker"; exit 1; }
# And one with nothing pending, where only the unconditional marker guard can block.
CLEAN=""
trap 'rm -rf ${ARMED:+"$ARMED"} ${CLEAN:+"$CLEAN"}' EXIT
CLEAN="$(mktemp -d)" || CLEAN=""
[[ -n "$CLEAN" && -d "$CLEAN" ]] || { echo "  FAIL  mktemp -d"; exit 1; }
git -C "$CLEAN" init -q || { echo "  FAIL  git init (clean)"; exit 1; }

python3 -I - "$LIB" "$ROOT" "$ARMED" "$CLEAN" <<'EOF'
import json, os, re, subprocess, sys, time
LIB, ROOT, ARMED, CLEAN = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
# The hook exactly as hooks.json registers it, so the timings include the launcher's cost:
# the 5s deadline is charged to the whole registered command, not to the gate script alone.
HOOK = [os.path.join(LIB, "contained-launch.sh"), "closed", "PATH=/usr/bin:/bin",
        "CLAUDE_PLUGIN_ROOT=" + ROOT, "/bin/bash", os.path.join(LIB, "sanitized-gate.sh"),
        "pre-implementation-gate.sh"]
DESIGN_REASON = "Design review must complete before modifying files via Bash"
PASS = FAIL = 0


def ok(m):
    global PASS
    PASS += 1
    print("  ok    " + m)


def no(m, why):
    global FAIL
    FAIL += 1
    print("  FAIL  %s :: %s" % (m, why))


def marker(cmd):
    payload = json.dumps({"tool_name": "Bash", "cwd": ARMED, "tool_input": {"command": cmd}})
    t = time.monotonic()
    r = subprocess.run([sys.executable, os.path.join(LIB, "marker_check.py")], input=payload,
                       capture_output=True, text=True, cwd=ARMED, timeout=60)
    if r.returncode != 0:
        return "crashed(rc=%d)" % r.returncode, time.monotonic() - t
    return r.stdout.strip().split("|", 1)[0], time.monotonic() - t


def gate(cmd, repo):
    # Returns the parsed decision: "block", "allow" (empty output, exit 0), "crashed" or "malformed".
    payload = json.dumps({"tool_name": "Bash", "cwd": repo, "tool_input": {"command": cmd}})
    t = time.monotonic()
    r = subprocess.run(HOOK, input=payload, capture_output=True, text=True, cwd=repo, timeout=60)
    dt = time.monotonic() - t
    out = r.stdout.strip()
    if r.returncode != 0:
        # A hook that dies before deciding is not an allow, even if the harness reads it as one.
        return "crashed", "rc=%d %s" % (r.returncode, r.stderr[-200:]), dt
    if not out:
        return "allow", "", dt
    try:
        d = json.loads(out)
    except ValueError:
        return "malformed", out[:200], dt
    # The gate's block_emit shape, exactly: both decision fields agree and carry the same
    # string reason. Anything else is malformed rather than a block.
    hso = d.get("hookSpecificOutput") if isinstance(d, dict) else None
    if (isinstance(hso, dict) and d.get("decision") == "block"
            and hso.get("hookEventName") == "PreToolUse" and hso.get("permissionDecision") == "deny"
            and isinstance(d.get("reason"), str) and d.get("reason") == hso.get("permissionDecisionReason")):
        return "block", d["reason"], dt
    return "malformed", out[:200], dt


def has(why, needle):
    return isinstance(why, str) and needle in why


# Controls: the armed repo really has a design pending, and the clean one does not.
for label, repo, want in (("blocked in the armed", ARMED, "block"), ("allowed in the clean", CLEAN, "allow")):
    d, why, _ = gate("echo hi > src/a.py", repo)
    # The armed control must see the design-review denial itself, not any block.
    if d == want and (want == "allow" or has(why, DESIGN_REASON)):
        ok("control: a write is %s repo" % label)
    else:
        no("control: a write is %s repo" % label, "decision=%s %s" % (d, why[:120]))

# The two limits name the same bound; a drift reopens the window one of them closed.
src_mc = open(os.path.join(LIB, "marker_check.py")).read()
src_cw = open(os.path.join(LIB, "cmdword.py")).read()
m1 = re.search(r"^_HELPER_SCAN_MAX = (\d+)$", src_mc, re.M)
m2 = re.search(r"^_LEX_READING_MAX = (\d+)$", src_cw, re.M)
if m1 and m2 and m1.group(1) == m2.group(1) == "32768":
    ok("marker_check._HELPER_SCAN_MAX == cmdword._LEX_READING_MAX == 32768")
else:
    no("scan ceilings in step", "marker_check=%s cmdword=%s" % (m1 and m1.group(1), m2 and m2.group(1)))
if "65536" in src_mc:
    no("no literal 65536 left in marker_check", "found one")
else:
    ok("no literal 65536 left in marker_check")


# The boundary: a plain long word is scanned at the ceiling and refused one past it.
def word(n):
    return "echo " + "y" * (n - len("echo "))


v, _ = marker(word(32768))
if v == "OK":
    ok("32,768 characters is still scanned (OK)")
else:
    no("32,768 characters is still scanned", "verdict=%r" % v)
v, dt = marker(word(32769))
if v == "BLOCK_UNSCANNABLE" and dt < 2.0:
    ok("32,769 characters fails closed as unscannable (%.2fs)" % dt)
else:
    no("32,769 characters fails closed as unscannable", "verdict=%s %.2fs" % (v, dt))


# The issue's shapes. At the ceiling the full walk still runs, and must decide inside the 5s
# hook deadline; past it the walk is skipped and the guard refuses at once.
def shaped(unit, n):
    head = ': "$(# x\\\n$\'\necho '
    tail = '; ls)"'
    body = (unit * n)[: n - len(head) - len(tail)]
    return head + body + tail


# The gate's own reason for BLOCK_UNSCANNABLE: a block for any other cause (a precautionary
# error block, the pending design) must not satisfy the rows past the ceiling.
UNSCANNABLE_REASON = "too large or too deeply nested for the gate to determine"
SHAPES = (("\\n", "\n"), (";\\n", ";\n"), ("&\\n", "&\n"), ("`", "`"))
for name, unit in SHAPES:
    cmd = shaped(unit, 32768)
    v, dt = marker(cmd)
    if v == "OK" and dt < 4.5:
        ok("32,768-char %s shape is walked and found clean in %.2fs" % (name, dt))
    else:
        no("32,768-char %s shape is walked and found clean" % name, "verdict=%r %.2fs" % (v, dt))
    # The whole hook, not just the marker scan, has to finish inside the 5s deadline.
    for label, repo in (("nothing pending", CLEAN), ("a design pending", ARMED)):
        d, why, dt = gate(cmd, repo)
        # Clean repo: nothing can block this read-only shape. Armed repo: either outcome is a
        # decision, but a block must be the design-review one, not a precautionary error block.
        decided = d == "allow" if repo == CLEAN else (
            d == "allow" or (d == "block" and has(why, DESIGN_REASON)))
        if decided and dt < 4.0:
            ok("32,768-char %s shape: full gate decides (%s) with %s in %.2fs" % (name, d, label, dt))
        else:
            no("32,768-char %s shape: full gate decides with %s" % (name, label), "decision=%s %.2fs %s" % (d, dt, why[:120]))
# A heredoc at the ceiling: cmdword reads it in full alongside marker_check's two walks,
# so it is the joint worst case and must still decide inside the deadline.
HD = ': "$(# x\\\n$\'\ncat <<E\n'
HD = HD + "\n" * (32768 - len(HD) - len('\nE\n; ls)"')) + '\nE\n; ls)"'
for label, repo in (("nothing pending", CLEAN), ("a design pending", ARMED)):
    d, why, dt = gate(HD, repo)
    decided = d == "allow" if repo == CLEAN else (
        d == "allow" or (d == "block" and has(why, DESIGN_REASON)))
    if len(HD) == 32768 and decided and dt < 4.0:
        ok("32,768-char heredoc shape: full gate decides (%s) with %s in %.2fs" % (d, label, dt))
    else:
        no("32,768-char heredoc shape: full gate decides with %s" % label, "len=%d decision=%s %.2fs %s" % (len(HD), d, dt, why[:120]))
for name, unit in SHAPES:
    cmd = shaped(unit, 65000)
    v, dt = marker(cmd)
    if v == "BLOCK_UNSCANNABLE" and dt < 2.0:
        ok("65,000-char %s shape fails closed as unscannable in %.2fs" % (name, dt))
    else:
        no("65,000-char %s shape fails closed as unscannable" % name, "verdict=%r %.2fs" % (v, dt))
    # Through the whole gate, in a repo with NOTHING pending: only the marker guard can block.
    d, why, dt = gate(cmd, CLEAN)
    if d == "block" and has(why, UNSCANNABLE_REASON) and dt < 2.5:
        ok("65,000-char %s shape: full gate blocks with nothing pending in %.2fs" % (name, dt))
    else:
        no("65,000-char %s shape: full gate blocks with nothing pending" % name, "decision=%s %.2fs %s" % (d, dt, why[:120]))
    d, why, dt = gate(cmd, ARMED)
    if d == "block" and has(why, UNSCANNABLE_REASON) and dt < 2.5:
        ok("65,000-char %s shape: full gate blocks with a design pending in %.2fs" % (name, dt))
    else:
        no("65,000-char %s shape: full gate blocks with a design pending" % name, "decision=%s %.2fs %s" % (d, dt, why[:120]))

print("test-gate-scan-ceiling-1109.sh: %d passed, %d failed" % (PASS, FAIL))
sys.exit(1 if FAIL else 0)
EOF
