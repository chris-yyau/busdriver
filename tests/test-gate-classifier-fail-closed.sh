#!/usr/bin/env bash
# Regression tests for #557 — the pre-implementation gate must fail CLOSED when its
# command classifier cannot produce a verdict, and must never carry that classifier
# as a single argv element again.
#
# History: the gate passed ~2250 lines of python inline as ONE `python3 -I -c`
# argument. At 4d00d13 that argument reached 133043 bytes and crossed the Linux
# MAX_ARG_STRLEN cap of 131072 bytes per argv element (macOS has no per-argument cap,
# so the same bytes worked there). execve returned E2BIG, python never ran, and BOTH
# recovery paths printed `OK|` — which means ALLOW. Every gated command was permitted
# on Linux with no diagnostic on stdout or stderr: ~30 assertions across three suites
# flipped to `expected=block got=allow`, and the cause was invisible because the
# classifier's stderr was discarded.
#
# Two invariants are pinned here:
#   A. the classifier is invoked as a FILE, so no argv limit applies
#   B. a classifier that cannot run BLOCKS rather than allowing
#
# (A) is what actually broke; (B) is what made it a silent bypass instead of a loud
# failure. Both are needed: (A) alone leaves the next crash a bypass, and (B) alone
# turns the overflow into a hard lockout of every command on Linux.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATE="$ROOT/hooks/gate-scripts/pre-implementation-gate.sh"
CLASSIFIER="$ROOT/hooks/gate-scripts/lib/marker_check.py"
PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
no() { FAIL=$((FAIL + 1)); printf '  FAIL  %s :: %s\n' "$1" "${2:-}"; }

# Abort if mktemp fails. With only `set -u` an empty WORK is not an error, and the
# setup below would then run `git init` against the current repo and create paths at
# the filesystem root — mutating the working tree instead of failing the test.
WORK="$(mktemp -d)" || { echo "mktemp -d failed"; exit 1; }
if [[ -z "$WORK" || ! -d "$WORK" ]]; then
    echo "mktemp -d produced no usable directory"
    exit 1
fi
trap 'rm -rf "$WORK"' EXIT
git -C "$WORK" init -q
mkdir -p "$WORK/.claude"

verdict() { # <command> <gate-path> -> BLOCK | allow
    local out
    out=$(python3 -c 'import json,sys;print(json.dumps({"tool_name":"Bash","cwd":sys.argv[1],"tool_input":{"command":sys.argv[2]}}))' \
        "$WORK" "$1" 2>/dev/null | (cd "$WORK" && bash "$2") 2>/dev/null)
    if printf '%s' "$out" | grep -q '"block"'; then printf 'BLOCK'; else printf 'allow'; fi
}

# Deliberately if/then/else rather than `cond && ok || no`: with the && || form a
# failure inside ok() would also run no(), reporting both a pass and a fail for one
# assertion (shellcheck SC2015).
assert_verdict() { # <want> <command> <gate-path> <label> <failure-note>
    local got
    got="$(verdict "$2" "$3")"
    if [[ "$got" == "$1" ]]; then ok "$4"; else no "$4" "$5 (want=$1 got=$got)"; fi
}

echo "── A. the classifier is a file, not an argv element ──"
if [[ -f "$CLASSIFIER" ]]; then
    ok "lib/marker_check.py exists"
else
    no "lib/marker_check.py exists" "classifier file missing"
fi

# The durable invariant. An inline `python3 -c` classifier is what created the E2BIG
# ceiling; a file has no argv limit, so the size can never silently reintroduce it.
if grep -q 'python3 -I "\$_GATE_LIBDIR/marker_check.py"' "$GATE"; then
    ok "gate invokes the classifier by file path"
else
    no "gate invokes the classifier by file path" \
        "launcher changed — if it went back inline, the MAX_ARG_STRLEN ceiling is back"
fi

# The gate legitimately keeps several SMALL inline `-c` helpers (tool-name
# extraction, design fingerprint). Banning them outright would be wrong; what must
# never recur is an inline block anywhere near the per-argv ceiling. Measure the
# largest one and require real headroom, so growth trips this long before execve does.
BIGGEST=$(python3 - "$GATE" <<'PY'
import sys
lines = open(sys.argv[1]).read().split("\n")
biggest = 0
for i, line in enumerate(lines):
    if line.rstrip().endswith("python3 -I -c '"):
        for j in range(i + 1, len(lines)):
            if lines[j].startswith("'"):
                biggest = max(biggest, len("\n".join(lines[i + 1:j]).encode()))
                break
print(biggest)
PY
)
LIMIT=131072
BUDGET=$((LIMIT / 2))
if [[ "$BIGGEST" -lt "$BUDGET" ]]; then
    ok "largest inline -c block is ${BIGGEST}B, well under the ${LIMIT}B argv cap"
else
    no "an inline -c block is approaching the argv cap" \
        "${BIGGEST}B >= ${BUDGET}B (half of MAX_ARG_STRLEN) — move it to a file before execve starts failing with E2BIG"
fi

if python3 -m py_compile "$CLASSIFIER" 2>/dev/null; then
    ok "classifier compiles"
else
    no "classifier compiles" "syntax error in lib/marker_check.py"
fi

echo "── B. a classifier that cannot run must BLOCK ──"
# Both injections need a self-contained gate-scripts tree: the gate resolves its lib
# via BASH_SOURCE, so a copy without real siblings dies during startup and every case
# would read "allow" — a vacuous pass hiding the regression this file exists to catch.
cp -R "$ROOT/hooks/gate-scripts" "$WORK/gs"

# B1: python never starts (the measured E2BIG shape).
sed 's|python3 -I "$_GATE_LIBDIR/marker_check.py"|python3-absent -I "$_GATE_LIBDIR/marker_check.py"|' \
    "$GATE" > "$WORK/gs/g-noexec.sh"
assert_verdict BLOCK "ls -la" "$WORK/gs/g-noexec.sh" \
    "python absent -> BLOCK" "allowed — a classifier that cannot start is a silent bypass"

# B2: the classifier raises, exercising its catch-all handler.
cp -R "$ROOT/hooks/gate-scripts" "$WORK/gs2"
python3 - "$WORK/gs2/lib/marker_check.py" <<'PY'
import sys
p = sys.argv[1]
src = open(p).read()
marker = "\ntry:\n"
i = src.index(marker)
open(p, "w").write(src[:i] + "\ntry:\n    raise RuntimeError(chr(88))\n" + src[i + len(marker):])
PY
assert_verdict BLOCK "ls -la" "$WORK/gs2/pre-implementation-gate.sh" \
    "classifier raises -> BLOCK" "allowed — the catch-all handler is a silent bypass"

# B3: the classifier exits 0 but prints NOTHING (truncated or damaged install).
# `${MARKER_CHECK%%|*}` is then empty, which matches no branch and used to fall
# through to ALLOW — the same bypass wearing a different shape.
cp -R "$ROOT/hooks/gate-scripts" "$WORK/gs3"
printf 'import sys\nsys.exit(0)\n' > "$WORK/gs3/lib/marker_check.py"
assert_verdict BLOCK "ls -la" "$WORK/gs3/pre-implementation-gate.sh" \
    "classifier prints nothing -> BLOCK" "allowed — an empty verdict is not a pass"

# B4: the classifier prints something UNRECOGNIZED. Normalizing only the empty case
# left this falling through to ALLOW — the branches match specific action names, so
# any other value matches nothing.
cp -R "$ROOT/hooks/gate-scripts" "$WORK/gs4"
printf 'print("garbage")\n' > "$WORK/gs4/lib/marker_check.py"
assert_verdict BLOCK "ls -la" "$WORK/gs4/pre-implementation-gate.sh" \
    "unrecognized verdict -> BLOCK" "allowed — only allowlisted verdicts may pass"

# B5: a valid verdict printed BEFORE a crash. `$(cmd || echo fallback)` concatenates
# partial stdout with the fallback, so `OK|` + failure would win the `%%|*` split.
cp -R "$ROOT/hooks/gate-scripts" "$WORK/gs5"
printf 'import sys\nprint("OK|")\nsys.stdout.flush()\nsys.exit(3)\n' > "$WORK/gs5/lib/marker_check.py"
assert_verdict BLOCK "ls -la" "$WORK/gs5/pre-implementation-gate.sh" \
    "partial verdict then crash -> BLOCK" "allowed — a valid prefix must not win over the failure"

# B6: Bash is NOT covered by the python3-absent carve-out. The classifier enforces
# unconditional protections for Bash, so a missing interpreter must block there even
# though a non-Bash tool with nothing pending is allowed through.
# A PATH holding ONLY bash is not a valid probe: the gate needs dirname, git, sed and
# friends during startup, so it dies in the ERR trap and "blocks" for the wrong
# reason — passing vacuously while missing the real defect (an unset _TOOL aborting
# the shell under set -u before any decision is emitted). Mirror the real PATH minus
# python3 so the gate reaches the branch under test.
mkdir -p "$WORK/nopy"
for d in /bin /usr/bin /usr/local/bin /opt/homebrew/bin; do
    [[ -d "$d" ]] || continue
    for f in "$d"/*; do
        b="$(basename "$f")"
        case "$b" in python | python3*) continue ;; esac
        [[ -e "$WORK/nopy/$b" ]] || ln -s "$f" "$WORK/nopy/$b" 2>/dev/null
    done
done
if PATH="$WORK/nopy" command -v python3 >/dev/null 2>&1; then
    no "python3 absent + Bash -> BLOCK" "probe setup failed: python3 still on PATH"
else
    OUT=$(printf '{"tool_name":"Bash","cwd":"%s","tool_input":{"command":"ls -la"}}' "$WORK" \
        | PATH="$WORK/nopy" bash "$GATE" 2>/dev/null || true)
    if printf '%s' "$OUT" | grep -q '"block"'; then
        ok "python3 absent + Bash -> BLOCK"
    else
        no "python3 absent + Bash -> BLOCK" \
            "got=${OUT:-<no decision>} — marker forgery via Bash is unguarded"
    fi
fi

# B7: the same Bash call spelled with JSON whitespace. A fixed-string match on the
# compact form alone would read this as "not Bash" and take the carve-out.
if PATH="$WORK/nopy" command -v python3 >/dev/null 2>&1; then
    no "python3 absent + spaced Bash JSON -> BLOCK" "probe setup failed: python3 still on PATH"
else
    OUT=$(printf '{"tool_name" : "Bash", "cwd":"%s","tool_input":{"command":"ls -la"}}' "$WORK" \
        | PATH="$WORK/nopy" bash "$GATE" 2>/dev/null || true)
    if printf '%s' "$OUT" | grep -q '"block"'; then
        ok "python3 absent + spaced Bash JSON -> BLOCK"
    else
        no "python3 absent + spaced Bash JSON -> BLOCK" \
            "got=${OUT:-<no decision>} — whitespace spelling evades the carve-out guard"
    fi
fi

echo "── C. normal operation is unchanged ──"
assert_verdict allow "ls -la" "$GATE" \
    "benign command still allowed" "blocked — the fail-closed path is over-firing"
assert_verdict allow "echo hello" "$GATE" \
    "echo still allowed" "blocked — the fail-closed path is over-firing"
assert_verdict BLOCK "python3 -I hooks/gate-scripts/lib/lease_slot.py .claude 20 0 3600" "$GATE" \
    "helper invocation still blocked" "allowed — the unconditional guard regressed"

echo
echo "════ classifier-fail-closed: $PASS passed, $FAIL failed ════"
[[ "$FAIL" -eq 0 ]]
