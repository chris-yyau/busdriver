#!/usr/bin/env bash
# Regression tests for #573 — the mutating-helper guard must not name a helper that the
# command never spells, on the evidence of a wildcard that matches every filename.
#
# History: `gh pr create` with the PR body inline was refused with "Cannot call
# lease_slot.py directly". The command contained neither `lease_slot` nor `audit_append`.
# The quote-flattening that lets this file see inside `$(...)` turns a markdown bold
# marker into a bare `**` token, `_abandoned_scan_probe` asks each glob-looking word
# whether the shell could expand it onto a helper, and `fnmatch("**")` matches
# `lease_slot.py` — as it matches everything else. Reported twice by the operator; the
# first block cost a skip-litmus token on the retry.
#
# Two sides are pinned, and BOTH are needed. Only the first would let a future change
# drop glob detection wholesale (a real bypass); only the second is the bug.
#   A. a GENERIC pattern in structureless text is not evidence — no block
#   B. a TARGETED pattern still blocks, and so does every generic glob the structured
#      walk can still reach as a command operand
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLASSIFIER="$ROOT/hooks/gate-scripts/lib/marker_check.py"
LIB="hooks/gate-scripts/lib"
PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
no() { FAIL=$((FAIL + 1)); printf '  FAIL  %s :: %s\n' "$1" "${2:-}"; }

# The classifier's own verdict, not the gate's decision: this is a guard on the
# classifier's evidence, and going through the gate would let an unrelated pending-review
# state decide the outcome instead.
verdict() { # <command> -> the verdict line, or ERROR
    local payload
    payload=$(python3 -c 'import json,sys;print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]}}))' \
        "$1" 2>/dev/null) || { printf 'ERROR'; return; }
    python3 -I "$CLASSIFIER" <<<"$payload" 2>/dev/null || printf 'ERROR'
}

# Deliberately if/then/else rather than `cond && ok || no` (shellcheck SC2015).
assert_ok() { # <command> <label>
    local got
    got="$(verdict "$1")"
    if [[ "$got" == "OK|" ]]; then
        ok "$2"
    else
        no "$2" "got=${got:-<empty>} — a wildcard is not evidence that a helper was named"
    fi
}

assert_block() { # <command> <label>
    local got
    got="$(verdict "$1")"
    if [[ "$got" == BLOCK_* ]]; then
        ok "$2"
    else
        no "$2" "got=${got:-<empty>} — the helper guard regressed to allow"
    fi
}

# The delta-debugged minimum from #573, VERBATIM. Quoted heredoc, so these are the exact
# bytes the operator typed. All five lines are load-bearing — the issue reports that
# removing any one of them stops the block, and shortened paraphrases of this prose do
# NOT reproduce (measured). Do not "tidy" it: a trimmed body turns the assertion below
# vacuous, passing against the very classifier it exists to catch.
BODY573=$(cat <<'PROSE'
A `{` or `[` inside codex's own command log poisoned the whole extraction sweep. `raw_decode` anchored on the bracket, could not resolve the region, and `_resolve` then refused every verdict decoded after it.
The issue fingers `[codex] Running command:` at byte 1622, echoing `rg -n "import \{ en \}"`. **Measured against the artifact, that line is harmless** -- the `\}` closes the `{`, the region resolves, and the sweep steps over it. A fix aimed only at `Running command:` did not rescue the reported transcript.
Delta-debugging the 129-line artifact down to one line found the real culprit: its **`Command completed:` twin**, echoing the regex character class `[;}]`. The `[` pushes `]`, the `}` mismatches, `broken_pos` is set, and every later verdict is refused. The reported error message reproduces from that line alone.
| Per-region backward `rfind` was quadratic on one long line | `_seek_line` -- a monotonic forward cursor, equivalence to `rfind` asserted at every region of every fixture |
Also unchanged: the ~1.15s baseline on 64,000 same-line regions is pre-existing (the two sibling recognizers each do their own per-region backward scan). This PR only ensures it is not made worse.
PROSE
)

echo "── A. a generic wildcard in prose is not evidence ──"
assert_ok "gh pr create --body \"\$(cat <<'EOF'
$BODY573
EOF
)\"" "#573 verbatim: PR body inline -> allowed"

# The same word reached through the OTHER abandonment path: an apostrophe makes the
# heredoc unparseable, so the whole command is probed as text.
assert_ok "cat > /tmp/x.md <<'EOF'
It isn't ** a helper ** at all.
EOF" "bare ** in an unparseable heredoc -> allowed"

assert_ok "gh pr create --body \"\$(cat <<'EOF'
Emphasis ** around ** a phrase, and a bare * on its own.
EOF
)\"" "bare * and ** in a PR body -> allowed"

echo "── B. targeted patterns, and every glob the walk can still reach ──"
# The case the glob probe was BUILT for: `?` stands FOR the character, so no substring
# test finds the name, yet the shell expands it onto the helper.
assert_block "python3 $LIB/lease_slo?.py" "targeted glob (parseable) -> BLOCK"
assert_block "cat <<'EOF'
it isn't
EOF
python3 lease_slo?.py" "targeted glob in unparseable text -> BLOCK"
assert_block "eval \"python3 lease_slo?.py\"" "targeted glob behind eval -> BLOCK"
assert_block "python3 lease_slo[t].py" "bracket-globbed helper -> BLOCK"

# Generic globs the STRUCTURED walk still reaches, because the interpreter is in command
# position and the wildcard is its operand. These are why the change is scoped to
# _abandoned_scan_probe and _glob_helper itself stays strict — if these ever flip to
# allow, the fix was applied at the wrong layer.
assert_block "cd $LIB && python3 *" "python3 * (operand) -> BLOCK"
assert_block "cd $LIB && python3 *.py" "python3 *.py (operand) -> BLOCK"
assert_block "cd $LIB && python3 **" "python3 ** (operand) -> BLOCK"
assert_block "python3 -m cProfile $LIB/*" "runner module + glob operand -> BLOCK"

# A pattern of pure `?` matches the helper by LENGTH and matches no ordinary short
# filename, so it stays blocked. Pinned deliberately: it is the safe direction, and it is
# the case a future "just drop all-wildcard patterns" simplification would open.
assert_block "cd $LIB && python3 ?????????????" "13 wildcards == len(lease_slot.py) -> BLOCK"

# The plain spellings, so a regression in the fix cannot pass this file by disabling the
# guard outright.
assert_block "python3 -I $LIB/lease_slot.py .claude 20 0 3600" "direct invocation -> BLOCK"
assert_block "python3 -m lease_slot" "module invocation -> BLOCK"
assert_block "echo \"see $LIB/audit_append.py\" > /dev/null && python3 $LIB/audit_append.py" \
    "audit_append invocation -> BLOCK"

echo "── C. crafted patterns must not buy a release ──"
# The release rule is "a run of `*` and nothing else". Anything that AIMS at the helper
# needs some character other than `*` to aim with, and any such character disqualifies it.
# These are the evasions that broke the first draft, which asked whether the pattern also
# matched an ordinary decoy filename: unioning alternatives satisfied both the decoy and
# the helper.
for evasion in \
    '[lm][ea][ai]*.py' \
    '[la]*.py' \
    'l*t.py' \
    '*slot.py' \
    'lease*' \
    '[a-z]*_*.py' \
    '?ease_slot.py'
do
    assert_block "cat <<'EOF'
it isn't
EOF
cd $LIB && python3 $evasion" "crafted: $evasion -> BLOCK"
done

# GENERATED, not hand-picked. A hand-written evasion list is exactly how the second draft
# of this fix shipped a hole: every case someone thinks of tends to contain a letter, and
# the evasion that broke it (`?????_????.??*`) contained none — it aimed with `_` and `.`
# at the offsets of the helper's own name. So derive the family mechanically from the
# helper names instead: replace every alphanumeric RUN with that many `?`, then decorate
# with `*`. Each result matches its helper and carries no letter, and every one must block.
for helper in lease_slot.py audit_append.py; do
    # python3, not sed: a `\n` in a sed REPLACEMENT is a GNU extension, so the same script
    # emits a literal `n` under BSD sed and silently generates a weaker pattern set. This
    # suite runs on both macOS (developer) and ubuntu (CI), and a test that quietly covers
    # less on one of them is worse than no test. python3 is already a hard dependency here.
    skeleton=$(python3 -c \
        'import re,sys;print(re.sub(r"[A-Za-z0-9]+", lambda m: "?"*len(m.group()), sys.argv[1]))' \
        "$helper")
    # Every decoration must still MATCH the helper, or the assertion is vacuous: a
    # trailing `*?` demands one more character than the name has, so it matches nothing
    # and `OK|` would be the correct answer rather than a bypass.
    for shaped in "$skeleton" "$skeleton*" "*$skeleton" "${skeleton%??}*"; do
        assert_block "cat <<'EOF'
it isn't
EOF
cd $LIB && python3 $shaped" "generated skeleton: $shaped -> BLOCK"
    done
done

# The ONLY pattern class that is released: a run of `*` and nothing else, which matches
# every string that exists and so distinguishes the helper from nothing. Asserted so the
# residual is visible rather than folklore. Each `?` above imposes a minimum length and is
# therefore a narrowing, which is why the `*?`-family sits in the BLOCK list rather than
# here — four successive drafts of a wider rule each shipped a bypass. If this last case
# ever needs to block, the fix is command-position gating, not a wider release rule.
for lenfloor in '?????????????*' '*?????????????' '?*' '*?*' '??*'; do
    assert_block "cat <<'EOF'
it isn't
EOF
cd $LIB && python3 $lenfloor" "length-floor wildcard: $lenfloor -> BLOCK"
done

for residual in '*' '**' '***'; do
    assert_ok "cat <<'EOF'
it isn't
EOF
cd $LIB && python3 $residual" "documented residual: $residual behind an unparseable command -> allowed"
done

# ...and the boundary of that residual, which a third draft got wrong: taking the
# BASENAME before the purity test released `<libdir>/*`, whose discarded directory is a
# literal naming the folder both helpers live in. That is the "pruned directory" the
# residual note assumes must come from outside the token — supplied inside it. A `/` is a
# literal like any other, so a qualified glob is never released.
for qualified in "$LIB/*" "$LIB/**" "./$LIB/*" "/usr/../$LIB/*"; do
    assert_block "cat <<'EOF'
it isn't
EOF
python3 $qualified" "path-qualified wildcard: $qualified -> BLOCK"
done

echo
echo "════ marker-glob-specificity: $PASS passed, $FAIL failed ════"
[[ "$FAIL" -eq 0 ]]
