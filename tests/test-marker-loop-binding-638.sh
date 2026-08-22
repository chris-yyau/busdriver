#!/usr/bin/env bash
# Regression tests for #638 — a `for` loop BINDING must not hide a gate marker from the
# marker-forge guard, and the sanctioned drain (#516) must exist for the markers whose
# removal is safe.
#
# History: `rm -f <marker>` blocked, but the same removal written as
# `for f in <marker>; do rm -f "$f"; done` was ALLOWED and deleted four review artifacts.
# `simple_vars` was populated only from NAME=VALUE assignment tokens, so a loop variable
# resolved to "" and `_match_marker` gave up. The delete is the shape that was observed;
# the REDIRECT twin of it forges a review pass, which is the threat the gate exists for.
#
# Three sides are pinned, and all three are needed:
#   A. the loop binding BLOCKS, for the delete and for the write through the same binding
#   B. a loop that only READS a marker, and an ordinary loop over non-markers, still
#      ALLOW — over-blocking every loop would be a different bug
#   C. the #516 drain works and refuses the markers whose removal LOOSENS a gate
#      (without it, closing A leaves no way at all to disarm a spent skip file)
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLASSIFIER="$ROOT/hooks/gate-scripts/lib/marker_check.py"
DRAIN="$ROOT/scripts/design-clear.sh"
PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
no() { FAIL=$((FAIL + 1)); printf '  FAIL  %s :: %s\n' "$1" "${2:-}"; }

# The classifier's own verdict, not the gate's decision: this pins the EVIDENCE the
# classifier produces, so an unrelated pending-review state cannot decide the outcome.
verdict() { # <command> -> the verdict line, or ERROR
    local payload
    payload=$(python3 -c 'import json,sys;print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]}}))' \
        "$1" 2>/dev/null) || { printf 'ERROR'; return; }
    python3 -I "$CLASSIFIER" <<<"$payload" 2>/dev/null || printf 'ERROR'
}

assert_block() { # <command> <label>
    local got
    got="$(verdict "$1")"
    if [[ "$got" == BLOCK_* ]]; then
        ok "$2"
    else
        no "$2" "got=${got:-<empty>} — a loop binding walked past the marker guard"
    fi
}

assert_ok() { # <command> <label>
    local got
    got="$(verdict "$1")"
    if [[ "$got" == "OK|" ]]; then
        ok "$2"
    else
        no "$2" "got=${got:-<empty>} — a marker READ must stay allowed"
    fi
}

M=".claude/pr-review-passed.local"

echo "── A. the loop binding resolves to the marker ──"

# The observed command, verbatim.
assert_block 'for f in .claude/pr-review-passed.local; do rm -f "$f"; done' \
    '#638 observed: for-loop rm through "$f"'

# The four files of the original report, one loop.
assert_block 'for f in .claude/pr-backstop-verdict.local.json .claude/pr-codex-lead.local.json .claude/pr-review-passed.local .claude/reviewed-commits.local; do
  rm -f "$f"
done' \
    '#638 report: four artifacts in one loop list'

# The WRITE twin of the same binding — this is the threat the gate names.
assert_block "for f in $M; do echo forged > \"\$f\"; done"   'for + redirect (the forge twin)'
assert_block "for f in $M; do echo x | tee \"\$f\"; done"    'for + tee'
assert_block "for f in $M; do touch \"\$f\"; done"           'for + touch (indirect verb)'
assert_block "select f in $M; do rm -f \"\$f\"; done"        'select binds the same way'
assert_block "for f in $M
do
rm -f \"\$f\"
done"                                                        'the same loop spelled across newlines'
assert_block "for f in a.txt $M b.txt; do rm -f \"\$f\"; done" \
                                                             'a marker among ordinary words in the list'

# The same literal loop behind a reserved-word prefix is the same loop.
assert_block "! for f in $M; do rm -f \"\$f\"; done"        'the loop behind a ! prefix'
assert_block "{ for f in $M; do rm -f \"\$f\"; done; }"     'the loop inside a { } group'
assert_block "if for f in $M; do rm -f \"\$f\"; done; then :; fi" \
                                                             'the loop behind an if prefix'
# `function NAME {` vs `NAME() {`: the second already blocked (`)` and `{` are reserved),
# so only the ksh spelling of the same wrapper was a bypass.
assert_block "function x { for f in $M; do rm -f \"\$f\"; done; }; x" \
                                                             'the loop inside a function NAME body'
assert_block "coproc x { for f in $M; do rm -f \"\$f\"; done; }" \
                                                             'the loop inside a coproc NAME body'
# The binding must not ERASE what the variable already held: the rebinding here never
# reaches the parent shell, so "$f" is still the marker at the delete.
assert_block "f=$M; (for f in safe; do :; done); rm -f \"\$f\"" \
                                                             'a loop must not shadow an existing marker binding'

echo "── B. reads and ordinary loops stay allowed ──"

assert_ok 'for f in a.txt b.txt; do rm -f "$f"; done'        'an ordinary loop delete stays allowed'
assert_ok "for f in $M; do cat \"\$f\"; done"                'for + cat (a read)'
assert_ok "for f in $M; do echo \"\$f\"; done"               'for + echo (a mention)'
assert_ok "grep -c . $M"                                     'a plain read of a marker'
# A reserved word is never path-qualified: `/tmp/if` is an ordinary command and
# establishes no loop binding, so matching on the basename over-blocked it.
assert_ok "/tmp/if for f in $M; rm -f \"\$f\""             'a path-named command is not shell syntax'

echo "── C. the #516 drain ──"

# Armed from SCRIPT code, never from a tool call: the guard blocks a Bash tool call that
# names a marker in a write position, which is the whole point of A.
TMP="$(mktemp -d)" || { echo "mktemp failed" >&2; exit 2; }
trap 'rm -rf "$TMP"' EXIT
git -C "$TMP" init -q
git -C "$TMP" -c user.email=t@example.invalid -c user.name=t commit -q --allow-empty -m init
mkdir -p "$TMP/.claude"

drain() { # <args...> -> exit code, output on stdout
    ( cd "$TMP" && bash "$DRAIN" "$@" 2>&1 )
}

: >"$TMP/.claude/skip-litmus.local"
OUT="$(drain --skip skip-litmus.local --yes)"; CODE=$?
if [ "$CODE" -eq 0 ] && [ ! -e "$TMP/.claude/skip-litmus.local" ]; then
    ok 'drains an armed skip file'
else
    no 'drains an armed skip file' "exit=$CODE out=$OUT"
fi
if grep -q '"event": *"skip-marker-cleared"' "$TMP/.claude/bypass-log.jsonl" 2>/dev/null; then
    ok 'writes a skip-marker-cleared audit event'
else
    no 'writes a skip-marker-cleared audit event' "log=$(cat "$TMP/.claude/bypass-log.jsonl" 2>&1)"
fi

: >"$TMP/.claude/pr-codex-lead.local.json"
OUT="$(drain --skip pr-codex-lead.local.json --yes)"; CODE=$?
if [ "$CODE" -eq 0 ] && [ ! -e "$TMP/.claude/pr-codex-lead.local.json" ]; then
    ok 'drains a spent PR review artifact'
else
    no 'drains a spent PR review artifact' "exit=$CODE out=$OUT"
fi

# The refusals are the load-bearing half: a drain that unlinks these is not a drain, it
# is the bypass the gate exists to stop. reviewed-commits.local is refused for the OTHER
# reason — no gate reads it, so removing it tightens nothing and destroys the records.
for never in bypass-log.jsonl design-review-needed.local .skip-design-review-lease.d reviewed-commits.local; do
    # Created only if absent — bypass-log.jsonl is the real audit log written above, and
    # truncating it here would be the test faking its own evidence.
    [ -e "$TMP/.claude/$never" ] || : >"$TMP/.claude/$never"
    LOG_BEFORE="$(wc -c <"$TMP/.claude/bypass-log.jsonl")"
    OUT="$(drain --skip "$never" --yes)"; CODE=$?
    if [ "$CODE" -ne 0 ] && [ -e "$TMP/.claude/$never" ]; then
        ok "refuses $never"
    else
        no "refuses $never" "exit=$CODE out=$OUT"
    fi
    if [ "$(wc -c <"$TMP/.claude/bypass-log.jsonl")" = "$LOG_BEFORE" ]; then
        ok "refusing $never writes no audit event"
    else
        no "refusing $never writes no audit event" 'the log changed size'
    fi
done

OUT="$(drain --skip ../../etc/hosts --yes)"; CODE=$?
if [ "$CODE" -ne 0 ]; then
    ok 'refuses a path selector (the drain is not an arbitrary unlink)'
else
    no 'refuses a path selector' "exit=$CODE out=$OUT"
fi

OUT="$(drain --skip not-a-marker.local --yes)"; CODE=$?
if [ "$CODE" -ne 0 ]; then
    ok 'refuses a name that is not a gate marker'
else
    no 'refuses a name that is not a gate marker' "exit=$CODE out=$OUT"
fi

# A symlink where a marker should be is anomalous state, not something to follow.
ln -s /etc/hosts "$TMP/.claude/litmus-passed.local"
OUT="$(drain --skip litmus-passed.local --yes)"; CODE=$?
if [ "$CODE" -ne 0 ] && [ -L "$TMP/.claude/litmus-passed.local" ]; then
    ok 'refuses a symlinked marker'
else
    no 'refuses a symlinked marker' "exit=$CODE out=$OUT"
fi
rm -f "$TMP/.claude/litmus-passed.local"

# A `-L` test on the marker checks only the FINAL component. `.claude/` is
# repo-controlled — in a linked worktree it is plausibly a symlink to the main worktree's
# state dir — so the drain must refuse to traverse it rather than unlink an allowlisted
# basename in another tree while stamping an audit event that names this one.
LINKED="$(mktemp -d)" || exit 2
git -C "$LINKED" init -q
git -C "$LINKED" -c user.email=t@example.invalid -c user.name=t commit -q --allow-empty -m init
mkdir -p "$LINKED/elsewhere"
: >"$LINKED/elsewhere/skip-litmus.local"
ln -s elsewhere "$LINKED/.claude"
OUT="$( cd "$LINKED" && bash "$DRAIN" --skip skip-litmus.local --yes 2>&1 )"; CODE=$?
if [ "$CODE" -ne 0 ] && [ -e "$LINKED/elsewhere/skip-litmus.local" ]; then
    ok 'refuses a state dir reached through a symlink'
else
    no 'refuses a state dir reached through a symlink' "exit=$CODE out=$OUT"
fi
rm -rf "$LINKED"

OUT="$(drain --skip)"; CODE=$?
if [ "$CODE" -ne 0 ] && printf '%s' "$OUT" | grep -q 'Never drainable'; then
    ok 'bare --skip lists both sets and changes nothing'
else
    no 'bare --skip lists both sets' "exit=$CODE out=$OUT"
fi

# The design-token modes must be untouched by the new one.
OUT="$(drain)"; CODE=$?
if [ "$CODE" -eq 1 ] && printf '%s' "$OUT" | grep -q 'No pending design-review tokens'; then
    ok 'design-token listing still works with no selector'
else
    no 'design-token listing still works' "exit=$CODE out=$OUT"
fi

OUT="$(drain --skip skip-litmus.local --all-for-doc)"; CODE=$?
if [ "$CODE" -eq 2 ]; then
    ok 'refuses --skip together with --all-for-doc'
else
    no 'refuses --skip together with --all-for-doc' "exit=$CODE out=$OUT"
fi

# The block message is the only thing an agent sees when the guard fires. Answering a
# REMOVAL with instructions for ARMING a bypass is how the loop workaround got invented,
# so pin that the drain is named for the drainable markers — and only for those.
GATE="$ROOT/hooks/gate-scripts/pre-implementation-gate.sh"
gate_reason() { # <command> -> the block reason text
    python3 -c 'import json,sys;print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]},"cwd":sys.argv[2]}))' \
        "$1" "$TMP" 2>/dev/null \
        | bash "$GATE" 2>/dev/null \
        | python3 -c 'import json,sys
try:
    print(json.load(sys.stdin).get("reason", ""))
except Exception:
    print("")' 2>/dev/null
}

if gate_reason 'rm -f .claude/skip-litmus.local' | grep -q -- '--skip skip-litmus.local'; then
    ok 'the block message names the drain for a drainable marker'
else
    no 'the block message names the drain' "reason=$(gate_reason 'rm -f .claude/skip-litmus.local')"
fi

if gate_reason 'rm -f .claude/bypass-log.jsonl' | grep -q -- '--skip'; then
    no 'no drain hint for the audit log' 'the message offered a drain that would be refused'
else
    ok 'no drain hint for a marker whose removal erases the trail'
fi

printf '\n════ marker-loop-binding-638: %d passed, %d failed ════\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
