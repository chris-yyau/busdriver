#!/usr/bin/env bash
# Tests for issue #519 — pre-implementation gate composition fixes.
#
# Covers the three items shipped (1 was declined; see ADR 0031):
#   item 4  file-mod classification is token-level, so a verb inside a QUOTED
#           operand no longer reads as a file write, while wrapper-hidden real
#           writes stay blocked and an unparseable command falls back to the old
#           regexes (never to "allow").
#   item 3  the skip file is a LEASE (N uses / bounded window), it is spent only
#           by genuinely-gated operations, and it expires.
#   item 2  the block message points at the audited design-clear.sh release
#           rather than a bare `rm` of the gate's own audit trail.
#
# Each test drives the REAL gate against a REAL throwaway repo with a REAL armed
# marker — a guard whose failure branch has never been observed is not a guard.
#
# Usage: bash tests/test-impl-gate-scope-519.sh
# Exit: 0 if all pass, 1 if any fail.

# SC2312: decisions are read from captured stdout, not pipeline status.
# SC2016: the single-quoted cases pass LITERAL command text to the gate -- a `$(...)` in
# them is the input under test and must NOT be expanded by this script.
# shellcheck disable=SC2312,SC2016
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
REPO_ROOT="$PWD"
GATE="$REPO_ROOT/hooks/gate-scripts/pre-implementation-gate.sh"

PASS=0; FAIL=0

ok() { printf "  PASS  %s\n" "$1"; PASS=$((PASS + 1)); }
no() { printf "  FAIL  %s (%s)\n" "$1" "$2"; FAIL=$((FAIL + 1)); }

check() {   # <name> <expected: allow|block> <actual-output>
    local name="$1" expected="$2" out="$3" got="allow"
    case "$out" in *'"block"'*) got="block" ;; esac
    if [ "$got" = "$expected" ]; then ok "$name"; else no "$name" "expected=$expected got=$got"; fi
}

# ── A throwaway repo with ONE armed (pending) design-review marker ───────────
# Everything below needs a pending review, or the gate fast-allows and proves
# nothing. Built once and reused; each test resets the skip/lease state.
WORK="$(mktemp -d)" || WORK=""
if [ -z "$WORK" ] || [ ! -d "$WORK" ]; then
    echo "  FAIL  could not create a temp fixture dir — refusing to run" >&2
    exit 1
fi
trap 'rm -rf "$WORK"' EXIT
git -C "$WORK" init -q 2>/dev/null
git -C "$WORK" config user.email t@t.t
git -C "$WORK" config user.name t
mkdir -p "$WORK/docs/plans" "$WORK/.claude" "$WORK/src"
printf '# plan\n' >"$WORK/docs/plans/thing.md"
bash "$REPO_ROOT/hooks/gate-scripts/lib/resolve-repo-dir.sh" arm "$WORK/docs/plans/thing.md" >/dev/null 2>&1

# Confirm the fixture actually blocks — if arming silently failed, every "block"
# assertion below would pass vacuously and the suite would certify nothing.
BASE="$(printf '{"tool_name":"Write","cwd":"%s","tool_input":{"file_path":"%s/src/impl.py"}}' "$WORK" "$WORK" \
        | (cd "$WORK" && bash "$GATE") 2>/dev/null)"
case "$BASE" in
    *'"block"'*) ok "fixture: an armed marker blocks an implementation write" ;;
    *) no "fixture: an armed marker blocks an implementation write" "gate allowed — fixture is broken, remaining results are meaningless"
       printf "\n%d passed, %d failed\n" "$PASS" "$FAIL"; exit 1 ;;
esac

# The gate embeds its parsers as SINGLE-QUOTED python blocks, so one apostrophe in one
# comment inside them closes the block: the text after it is read as shell, a stray
# `<word>` becomes a redirect, and the parser silently stops running. `bash -n` passes
# on it (the result is valid syntax, just not the intended program), so the invariant is
# pinned HERE instead: a clean run writes nothing to stderr. This has regressed three
# times; it is a test rather than a comment for exactly that reason.
GATE_NOISE="$(printf '{"tool_name":"Bash","cwd":"%s","tool_input":{"command":"ls -la"}}' "$WORK" \
              | (cd "$WORK" && bash "$GATE") 2>&1 >/dev/null)"
if [[ -z "$GATE_NOISE" ]]; then
    ok "the gate runs with an empty stderr (embedded python blocks are intact)"
else
    no "gate stderr" "$GATE_NOISE"
fi

bash_decision() {   # <command>  -> gate stdout
    python3 -c '
import json,sys
print(json.dumps({"tool_name":"Bash","cwd":sys.argv[1],
                  "tool_input":{"command":sys.argv[2]}}))' "$WORK" "$1" \
    | (cd "$WORK" && bash "$GATE") 2>/dev/null
}

echo "── item 4: read-only commands that MENTION a verb must be ALLOWED ──"

check "grep whose PATTERN contains 'rm |mv '" allow \
    "$(bash_decision "grep -nE 'rm |mv |truncate' script.sh")"
check "echo whose LABEL contains 'mv '" allow \
    "$(bash_decision "bash -c 'echo \"T3 (mv FAILS): ...\"'")"
check "read-only sed -n" allow "$(bash_decision "sed -n '1,10p' file.txt")"
check "grep -i with 'sed' as the search string" allow \
    "$(bash_decision "grep -i sed notes.txt")"
check "plain listing" allow "$(bash_decision "ls -la")"
# A verb as plain DATA in a read-only command. This is why the classifier peels wrapper
# preambles instead of scanning every token: an all-token scan catches `sudo rm -rf src`
# but also misreads these.
check "grep with a verb as the search string" allow "$(bash_decision "grep dd notes.txt")"
check "echo naming a verb" allow "$(bash_decision "echo rmdir")"
check "piping into grep for a verb" allow "$(bash_decision "git log --oneline | grep rm")"
# Keywords that introduce a NAME (not a command), and wrapper names used as plain data.
check "for loop whose VARIABLE is named rm" allow \
    "$(bash_decision "for rm in a b; do echo hi; done")"
check "function definition via the function keyword" allow \
    "$(bash_decision "function mv { echo harmless; }")"
check "grep whose ARGS name a wrapper and a verb" allow "$(bash_decision "grep sudo rm")"
check "echo naming find -delete" allow "$(bash_decision "echo find -delete")"
# Test-expression operands are data. Skipping [[ resolved these to `rm`.
check "test expression comparing against rm" allow "$(bash_decision "[[ rm = value ]]")"
check "test expression checking a file named rm" allow "$(bash_decision "[[ -f rm ]]")"
check "test guarding a real rm still blocks" block \
    "$(bash_decision "if [[ -f x ]]; then rm y; fi")"
# #519 false positive 3: a probe DEFINING a function named mv. The paren split leaves
# a bare `mv` segment that reads as an invocation unless the header is stripped.
check "defining a shell function named mv" allow \
    "$(bash_decision "mv() { echo harmless; }")"
check "defining mv then calling rm still blocks" block \
    "$(bash_decision "mv() { echo hi; } ; rm x")"
# -c is a COUNT flag for grep, not "execute this string" — recursing on every -c
# operand would resurrect the quoted-operand false positive this change removes.
check "grep -c whose pattern contains 'rm '" allow "$(bash_decision "grep -c 'rm ' file.txt")"

echo "── item 4: real writes must still BLOCK ────────────────────────────"

check "bare rm" block "$(bash_decision "rm -rf src")"
check "wrapper-hidden rm (sudo)" block "$(bash_decision "sudo rm -rf src")"
check "wrapper-hidden mv (nohup)" block "$(bash_decision "nohup mv a b")"
check "leading assignment then rm" block "$(bash_decision "FOO=1 rm x")"
check "sed -i in place" block "$(bash_decision "sed -i 's/a/b/' f")"
check "sed -i.bak in place" block "$(bash_decision "sed -i.bak 's/a/b/' f")"
# GNU getopt_long accepts any unambiguous abbreviation of a long option, and
# no other GNU sed long option shares the "in-place" prefix -- so `--i` and
# `--in` are exactly as file-modifying as the full `--in-place` spelling.
check "sed --i in place (short abbreviation)" block "$(bash_decision "sed --i 's/a/b/' f")"
check "sed --in in place (short abbreviation)" block "$(bash_decision "sed --in 's/a/b/' f")"
check "sed --in-place=bak in place (long form)" block "$(bash_decision "sed --in-place=bak 's/a/b/' f")"
check "tee" block "$(bash_decision "cat x | tee out.txt")"
check "second segment writes" block "$(bash_decision "ls && rm x")"
check "timeout wrapper hiding rm" block "$(bash_decision "timeout 5 rm x")"
# ── generated: launcher x payload, over EVERY wrapper ────────────────
# flock and script were recorded as deliberately-omitted wrappers; both run the command
# that follows them, so the omission resolved the command word to the launcher and read
# a real write as read-only — the write the raw regex they replaced had caught. Hand-
# picking cases for the two that were missing is how the list got wrong in the first
# place, so the whole set is driven instead: every launcher, against a write payload, a
# read payload, and (where the launcher has one) the -c STRING form, which is a second
# spelling a wrapper entry alone does not cover.
_WR_FAIL=0 _WR_PASS=0
_wr() {  # <expected> <command>
    local got="allow"
    case "$(bash_decision "$2")" in *'"block"'*) got="block" ;; esac
    if [[ "$got" == "$1" ]]; then _WR_PASS=$((_WR_PASS + 1))
    else _WR_FAIL=$((_WR_FAIL + 1)); printf "  FAIL  wrapper: %s (want %s)\n" "$2" "$1"; fi
}
# Each entry is `<basename>:<launcher as invoked>` so the PARITY check below can prove
# the matrix covers every launcher the classifier knows, instead of trusting that
# whoever last edited _WRAPPERS remembered to add a case here.
_WR_CASES=(
    "sudo:sudo" "sudo:sudo -u root" "doas:doas" "su:su root" "runuser:runuser -u root"
    "nohup:nohup" "timeout:timeout 5" "nice:nice -n 5" "ionice:ionice -c3"
    "setsid:setsid" "stdbuf:stdbuf -o0" "unbuffer:unbuffer" "command:command"
    "builtin:builtin" "exec:exec" "xargs:xargs" "caffeinate:caffeinate"
    "chroot:chroot /jail" "arch:arch -arm64" "env:env" "env:env -u FOO" "torify:torify"
    "proxychains:proxychains" "proxychains4:proxychains4" "watch:watch -n1"
    "flock:flock /tmp/x.lock" "flock:flock -x .lock" "script:script -q /dev/null"
)
for _e in "${_WR_CASES[@]}"; do
    _w="${_e#*:}"
    for _p in "rm -rf src" "tee src/impl.py" "truncate -s 0 src/impl.py" "sed -i s/a/b/ f"; do
        _wr block "$_w $_p"
    done
    for _p in "npm test" "ls -la" "cat README.md" "grep -n TODO src/impl.py"; do
        _wr allow "$_w $_p"
    done
done
# The -c STRING form is a SECOND spelling: the whole program is one token that equals no
# verb, so a launcher can be a known wrapper and still pass its payload through unread.
# ATTACHED as well as separated -- `sh -c'rm -rf src'` dequotes to a single token, which
# is what let the attached spelling through after the separated one was closed.
_DC_CASES=("sh:sh" "bash:bash" "zsh:zsh" "dash:dash" "ksh:ksh" "mksh:mksh" "ash:ash"
           "su:su" "runuser:runuser" "flock:flock /tmp/x.lock" "script:script -q /dev/null")
for _e in "${_DC_CASES[@]}"; do
    _c="${_e#*:}"
    _wr block "$_c -c 'rm -rf src'"
    _wr block "$_c -c'rm -rf src'"
    _wr allow "$_c -c 'npm test'"
    _wr allow "$_c -c'npm test'"
done
_wr block "script -c 'rm -rf src' /dev/null"
_wr block "script -c'rm -rf src' /dev/null"
# getopt_long takes any UNAMBIGUOUS ABBREVIATION, so every prefix of --command runs what
# --command runs. Matching only the full spelling left the shorter ones unread.
for _a in "--c" "--co" "--com" "--comm" "--comman" "--command"; do
    _wr block "flock /tmp/x.lock $_a 'rm -rf src'"
    _wr block "flock /tmp/x.lock $_a='rm -rf src'"
    _wr allow "flock /tmp/x.lock $_a='npm test'"
done
# ...but --rcfile names a FILE to source, not inline source, and must stay unread.
_wr allow "bash --rcfile setup.sh -c 'npm test'"
# A LEADING REDIRECTION must not disable the conservative regime. `<` is not a wrapper
# name, so _starts_with_wrapper answered False and the launcher was then peeled by
# _effective_command_word -- which stops at the launcher's OWN operand. That resolved
# `</dev/null sudo -u root rm -rf src` to `root` and the script form to `null`, reading
# both as read-only while they executed rm. One leading character turned the regime off.
# Driven across every launcher that TAKES an operand (the ones where peeling lands on it)
# and every redirection spelling, because the defect was in the regime choice, not in any
# one launcher.
_LAUNCH_OPERAND=("sudo -u root" "chroot /jail" "env -u FOO" "script -q /dev/null"
                 "flock /tmp/x.lock" "nice -n 5" "timeout 5" "su root")
# NON-WRITING redirections: the verb behind them decides, both ways.
for _r in "</dev/null" "< in.txt" "2>&1" "2>/dev/null"; do
    for _l in "${_LAUNCH_OPERAND[@]}"; do
        _wr block "$_r $_l rm -rf src"
        _wr block "$_r $_l truncate -s 0 src/impl.py"
        # ...and the over-block side stays where it was: a read behind one of these is
        # still a read.
        _wr allow "$_r $_l npm test"
        _wr allow "$_r $_l grep -n TODO src/impl.py"
    done
done
# The operator has to be matched WHOLE, longest-first. A here-string `<<< data` read as a
# bare `<` left `data` unskipped and in command position, so the wrapper regime was never
# selected -- the same failure as the missing redirect skip, one spelling further along.
for _r in "<<< data" "<< EOF" "<> f" "<& 3" ">| out.txt" "&> log.txt"; do
    for _l in "sudo -u root" "chroot /jail" "script -q /dev/null"; do
        _wr block "$_r $_l rm -rf src"
    done
    _wr block "$_r rm -rf src"
done
_wr allow "<<< data npm test"
_wr allow "<<< data grep -n TODO src/impl.py"
# KNOWN RESIDUAL, pinned so it stays visible rather than being rediscovered: the
# tab-stripping heredoc opener written SEPARATED from its delimiter (`<<- EOF cmd`) still
# resolves to the delimiter and reads as a non-verb. It predates this branch -- HEAD
# behaves identically -- and the ATTACHED spelling (`<<-EOF cmd`) is caught. Asserted as
# the CURRENT behaviour so that closing it later trips this line deliberately.
_wr allow "<<- EOF rm -rf src"

# The same leading redirection, but in front of a RUNNER rather than a launcher. The
# matrix above drives launchers only, and every launcher in it IS a wrapper -- so the
# all-token regime fired and covered for the missing redirect skip. A runner is not a
# wrapper, so that regime was never selected and the payload walk stopped ON the operator
# instead, before the -c it exists to read. `</dev/null bash -c "rm -rf src"` therefore
# yielded no operands at all and ran; the READ redirection does not trip the write-
# redirect check either, so nothing downstream caught it. Two adjacent parser states,
# one covered and one not, which is why this is driven as its own cross-product rather
# than added as a single case. Found by the PR-mode deep review of this branch.
for _r in "</dev/null" "< in.txt" "2>/dev/null" "0< /dev/null" "3</dev/null" \
          "&>/dev/null" "<<< data" "<& 3"; do
    for _c in "bash -c" "sh -c" "su -c" "flock -c" "script -c"; do
        _wr block "$_r $_c 'rm -rf src'"
    done
    _wr block "$_r eval 'rm -rf src'"
    # coproc reaches this through _first_word rather than the payload walk: it is
    # deliberately NOT in _RESERVED, so an unskipped operator was reported as the first
    # word and the _OPAQUE_INTRO test missed.
    _wr block "$_r coproc rm -rf src"
    # The over-block side must not move: a read payload behind the same operator is
    # still a read, and an operator MENTIONED as data is not a redirection at all.
    _wr allow "$_r bash -c 'npm test'"
    _wr allow "$_r eval 'grep -n TODO src/impl.py'"
done
_wr allow "echo bash -c 'rm -rf src'"
_wr allow "printf 'coproc rm -rf src'"
_wr allow "grep -n '<' src/impl.py"

# A WRITING redirection is itself the modification, so the payload cannot rescue it --
# `>out.txt sudo -u root npm test` creates out.txt whatever npm does. Asserted separately
# rather than folded into the loop above, where an `allow` expectation for the read
# payloads was simply wrong and the suite caught it.
for _r in ">out.txt" ">>out.txt"; do
    for _l in "${_LAUNCH_OPERAND[@]}"; do
        _wr block "$_r $_l rm -rf src"
        _wr block "$_r $_l npm test"
    done
done
# GENERATED: the -c payload across option BUNDLES and both boundaries. The bundle is
# where the two shapes stop being distinguishable -- after dequoting, `-cl PROG` (the
# tail is more FLAGS, program in the next word) and `-cPROG` (program attached) are both
# a `c` plus a tail -- so the whole grid is driven rather than sampled. `c` is placed at
# the head, the middle and the tail of the bundle in turn.
for _b in "-c" "-lc" "-ic" "-ilc" "-cl" "-ci" "-cil" "-lci"; do
    for _sh in sh bash zsh dash; do
        _wr block "$_sh $_b 'rm -rf src'"
        _wr allow "$_sh $_b 'npm test'"
    done
done
# A -c-LOOKING token can belong to an EARLIER option that takes a filename, so the real
# payload sits further right. Knowing which option that was is the arity table this gate
# refuses to keep; the walk therefore never stops at the first `c`. Decoys are placed
# before, between, and after the genuine -c.
for _d in "-O -cfoo" "-O-cfoo" "-T -cbar -O -cbaz" "--log-out=-cfoo"; do
    _wr block "script $_d -c 'rm -rf src' /dev/null"
    _wr allow "script $_d -c 'npm test' /dev/null"
done
_wr block "flock -o -cx /tmp/l --com='rm -rf src'"
_wr allow "flock -o -cx /tmp/l --com='npm test'"
# su/runuser also execute --session-command, documented as equivalent to -c, so every
# prefix of THAT long option runs a program too.
for _a in "--s" "--sess" "--session-command"; do
    _wr block "su $_a='rm -rf src' root"
    _wr block "runuser $_a 'rm -rf src' root"
    _wr allow "su $_a='npm test' root"
done
# ...and the ATTACHED boundary, only meaningful when `c` ends the bundle.
for _b in "-c" "-lc" "-ilc"; do
    for _sh in sh bash zsh dash; do
        _wr block "$_sh $_b'rm -rf src'"
        _wr allow "$_sh $_b'npm test'"
    done
done
# REFUTED BY TEST, recorded so it is not "fixed" again on the next reading: a whole
# command quoted into ONE token after `--` does NOT execute. script execvp()s that token
# as a program NAME, so `script -q /dev/null -- 'rm -f canary'` exits 1 with the canary
# intact (checked against the real binary), and util-linux errors on the extra operand.
# The spelling that DOES run is the unquoted argv form, which the all-token scan blocks.
_wr block "script -q /dev/null -- rm -rf src"
# PARITY, mechanical rather than prose: a launcher added to either set without a case
# here is a lane this suite silently stops covering, which is exactly how `flock` and
# `script` stayed missing. Asserted against the module, so the test fails on the ADD.
_WR_UNCOVERED="$(python3 -c '
import sys
sys.path.insert(0, sys.argv[1] + "/hooks/gate-scripts/lib")
import cmdword
tested = set(sys.argv[2:])
gaps = []
for name, want in (("_WRAPPERS", cmdword._WRAPPERS),
                   ("_DASH_C_RUNNERS", cmdword._DASH_C_RUNNERS)):
    missing = sorted(set(want) - tested)
    if missing:
        gaps.append("%s: %s" % (name, " ".join(missing)))
print("; ".join(gaps))' "$REPO_ROOT" \
    "${_WR_CASES[@]%%:*}" "${_DC_CASES[@]%%:*}")"
if [[ -z "$_WR_UNCOVERED" ]]; then
    ok "every launcher the classifier knows has a case in this matrix"
else
    no "launcher matrix parity" "$_WR_UNCOVERED"
fi
# The PRICE of the wrapped regime, asserted so it stays deliberate rather than accidental:
# every token is scanned, so a verb NAME in a wrapped command's DATA reads as the verb.
# Uniform across launchers — it is not a flock/script quirk.
for _w in "sudo" "timeout 5" "nohup" "flock /tmp/x.lock" "script -q /dev/null"; do
    _wr block "$_w grep rm notes.txt"
done
if [[ "$_WR_FAIL" -eq 0 ]]; then
    ok "every launcher resolves its payload ($_WR_PASS spellings)"
else
    no "launcher payload spellings" "$_WR_FAIL of $((_WR_PASS + _WR_FAIL)) wrong"
fi
# ── watch: the payload must be found WITHOUT locating the command start ─────
# `watch CMD` joins its non-option arguments and runs them through `sh -c`, so the
# QUOTED spelling reaches the classifier as ONE token matching no verb name -- the
# all-token wrapper scan above cannot see it. The interesting half is the option
# spellings: the first draft skipped one token per flag except -n/--interval, and any
# OTHER value-taking option shifted the command start so the payload went unscanned.
# --shotsdir and --equexit are real procps options that broke it; --some-future-option
# is here to pin the actual invariant, which is that an option NOBODY has heard of
# must behave identically. A regression that reintroduces an arity table fails on that
# line specifically, which is the point of it.
_WATCH_FAIL=0 _WATCH_PASS=0
_wa() {   # <expected> <command>
    local got="allow"
    case "$(bash_decision "$2")" in *'"block"'*) got="block" ;; esac
    if [[ "$got" == "$1" ]]; then _WATCH_PASS=$((_WATCH_PASS + 1))
    else _WATCH_FAIL=$((_WATCH_FAIL + 1)); printf "  FAIL  watch: %s (want %s)\n" "$2" "$1"; fi
}
for _opt in "" "-d" "-n 1" "-n1" "-dn 1" "--interval=1" "--shotsdir logs" \
            "-s logs" "--equexit 5" "--some-future-option val"; do
    _wa block  "watch $_opt 'rm -f src/file'"
    _wa block  "watch $_opt 'git clean -fd'"
    _wa allow  "watch $_opt 'git status'"
done
_wa block "watch rm -f src/file"          # unquoted: the plain token scan covers it
# Space-padded verb: one word to a multi-word test, but a live command to the shell.
_wa block "watch -- ' rm' -rf src"
_wa block "watch -- ' sh' -c 'rm -rf src'"
# A LONE BARE WORD that is still shell source. These are why the rule recurses every
# argument rather than testing which ones "look like" a command: each spelling below is
# one token with no whitespace, and each one writes.
_wa block "watch '>src/file'"
_wa block "watch '>>src/file'"
_wa block "watch 'x;rm y'"
_wa block "watch 'a|rm x'"
_wa block "watch -x rm -f src/file"       # --exec skips the shell; over-read on purpose
_wa allow "watch -d ls -la"
_wa allow "echo watch rm -rf src"         # `watch` as plain DATA stays inert
if [[ "$_WATCH_FAIL" -eq 0 ]]; then
    ok "watch resolves its payload under every option spelling ($_WATCH_PASS cases)"
else
    no "watch payload spellings" "$_WATCH_FAIL of $((_WATCH_PASS + _WATCH_FAIL)) wrong"
fi
# THE INVARIANT ITSELF, rather than another list of spellings. `watch X` runs X, so its
# verdict must EQUAL the verdict on X alone -- no more, no less. Three separate drafts of
# the watch rule each passed the example list of their day and still let a new spelling
# through, because an example list only ever proves the examples. This compares the pair
# directly, so any payload whose wrapped verdict drifts from its bare one fails here
# whatever its spelling. The generator stays small and fixed rather than random: a seeded
# fuzz would make CI failures depend on the seed.
# Compared at the GATE decision, not at cmdword.is_file_mod. The classifier is only one
# rung: bare redirects are judged above it, so `>src/file` is False to is_file_mod while
# the gate still blocks it. Comparing the rung instead of the decision reports a mismatch
# that is not one -- measured, which is why this reads the real verdict.
_PROP="$(python3 - "$WORK" "$GATE" <<'PY'
import json, subprocess, sys
WORK, GATE = sys.argv[1], sys.argv[2]

def decision(cmd):
    p = subprocess.run(["bash", GATE], cwd=WORK, capture_output=True, text=True,
                       input=json.dumps({"tool_name": "Bash", "cwd": WORK,
                                         "tool_input": {"command": cmd}}))
    return '"block"' in p.stdout

PAYLOADS = [
    "rm -f src/file", "grep -n x src/file", "ls -la", "git status", "git clean -fd",
    ">src/file", "x;rm y", "a|rm x", "sed -i s/a/b/ f", "sed -n 1p f",
    "truncate -s 0 f", "echo rm",
]
OPTS = ["", "-n 1 ", "--shotsdir logs ", "--some-future-option v "]
# Quoting/padding shapes of the SAME payload. The bare split-argv spelling is deliberately
# excluded: it over-blocks by design (see the helper-guard cases below), so it is not
# verdict-transparent and asserting that it is would contradict a decision made on purpose.
WRAPS = [
    lambda p: "'" + p + "'",            # the spelling watch users actually write
    lambda p: "'  " + p + "'",          # leading padding the shell ignores
    lambda p: "'" + p + "  '",          # trailing padding
]
bad = []
for p in PAYLOADS:
    bare = decision(p)
    for o in OPTS:
        for w in WRAPS:
            if decision("watch " + o + w(p)) != bare:
                bad.append("watch %s%s disagrees with bare (bare=%s)" % (o, w(p), bare))
print(len(PAYLOADS) * len(OPTS) * len(WRAPS))
for b in bad[:6]:
    print("MISMATCH " + b)
PY
)"
_PROP_N="$(printf '%s\n' "$_PROP" | head -1)"
if ! printf '%s\n' "$_PROP" | grep -q MISMATCH; then
    ok "watch is verdict-transparent: wrapped == bare for all $_PROP_N payload x option pairs"
else
    no "watch verdict transparency" "$(printf '%s\n' "$_PROP" | grep MISMATCH | head -3 | tr '\n' ' ')"
fi
# `--` is NOT honoured as sed's option terminator: deciding whether it is an option
# OPERAND needs the same arity table, and here it is -f's script file, so the -i behind
# it writes in place. The price is the over-block on the next line, which is correct.
check "sed -f -- -i writes in place" block "$(bash_decision "sed -f -- -i file")"
check "read-only sed on a file named --in over-blocks (deliberate)" block \
    "$(bash_decision "sed -n -- --in")"
# ── #557: shell source arriving over a PIPE, not just via <<< ───────────────
# A shell given neither -c nor a script operand runs whatever stdin produced, so the
# payload is quoted DATA in the producer and the executing stage has no operand at all.
# The `<<<` spelling was closed by an operand branch a pipe never reaches, and the
# pre-#519 raw regex caught this one -- a REGRESSION, not an inherited gap.
check "printf piped into bash runs its payload" block \
    "$(bash_decision "printf 'rm -f src/impl.py' | bash")"
check "echo piped into sh runs its payload" block \
    "$(bash_decision "echo 'rm -rf src' | sh")"
check "explicit -s stdin form runs its payload" block \
    "$(bash_decision "printf 'rm -f src/impl.py' | sh -s")"
check "a payload piped through a middle stage still reaches the shell" block \
    "$(bash_decision "printf 'rm -rf src' | cat | bash")"
# Spellings that a "which flag means stdin" test would each miss individually. The stage
# test carries NO arity table: it asks only whether the fed stage might be a shell, so
# every one of these lands in the same branch.
check "a WRAPPED stdin shell runs its payload" block \
    "$(bash_decision "printf 'rm -rf src' | env sh")"
check "a shell hidden inside an env -S operand runs its payload" block \
    "$(bash_decision "printf 'rm -rf src' | env -S 'bash -s'")"
check "bash --norc still reads its payload from stdin" block \
    "$(bash_decision "printf 'rm -rf src' | bash --norc")"
check "bash --rcfile still reads its payload from stdin" block \
    "$(bash_decision "printf 'rm -rf src' | bash --rcfile /dev/null")"
check "a -c AFTER -- is an operand, not the option" block \
    "$(bash_decision "printf 'rm -rf src' | bash -s -- -c")"
check "an UNRESOLVABLE command word on the receiving end still blocks" block \
    "$(bash_decision 'printf "rm -rf src" | $SHELL')"
# GROUPING is transparent, in both directions. The segmenter splits on parens and on the
# `;` inside a brace group, so each of these three put the payload -- or the shell -- behind
# what LOOKS like a pipeline boundary, and each was measured executing the write while
# classifying as a read.
check "a parenthesised PRODUCER still reaches the shell" block \
    "$(bash_decision "(printf 'rm -rf src') | bash")"
check "a brace-grouped PRODUCER still reaches the shell" block \
    "$(bash_decision "{ printf 'rm -rf src'; } | bash")"
check "NESTED brace groups still reach the shell" block \
    "$(bash_decision "{ { printf 'rm -rf src'; }; } | bash")"
check "a parenthesised RECEIVER is still a shell" block \
    "$(bash_decision "printf 'rm -rf src' | (bash)")"
# A group with its OWN separator inside it. The `}`-segment rule closed the producer half
# and left this open: every `;` reset the pipe-fed state, so the shell behind one was never
# seen as fed. Depth tracking is what makes the two halves agree.
check "a brace RECEIVER containing a separator is still fed" block \
    "$(bash_decision "printf 'rm -rf src' | { :; bash; }")"
check "a paren RECEIVER containing a separator is still fed" block \
    "$(bash_decision "printf 'rm -rf src' | ( :; bash )")"
# ...and the brace counting must be by WORD, or a ${VAR} reference reads as an open group
# and swallows every separator after it.
check "a \${VAR} reference is not a brace group" allow \
    "$(bash_decision 'echo "${VAR}" | bash scripts/x.sh')"
# An option value ATTACHED to its flag. shlex hands back ONE token whose first word is
# `-Sbash`, which matches no shell -- the third attached-operand miss in this family, so the
# peel is general rather than env-specific.
check "an ATTACHED env -S operand still names a shell" block \
    "$(bash_decision "printf 'rm -rf src' | env -S'bash -s'")"
check "a long --split-string operand still names a shell" block \
    "$(bash_decision "printf 'rm -rf src' | env --split-string='bash -s'")"
# A REDIRECT-ONLY payload. The verb regexes cannot see a write with no verb in it, and the
# gate's own redirect check strips single-quoted text first -- which is exactly where a
# piped payload lives. Both halves of the verdict have to survive the transport.
check "a redirect-only payload piped into bash still writes" block \
    "$(bash_decision "printf 'echo x > src/impl.py' | bash")"
# The WHOLE pipeline inside one group. Depth must suppress the SEPARATOR only -- folding
# the pipe test into the in-a-group branch made these two ignore their own pipe, so the
# shell was never seen as fed at all.
check "a pipeline written wholly inside parens still feeds its shell" block \
    "$(bash_decision "(printf 'rm -rf src' | bash)")"
check "a pipeline written wholly inside braces still feeds its shell" block \
    "$(bash_decision "{ printf 'rm -rf src' | bash; }")"
check "a grouped harmless pipeline stays allowed" allow \
    "$(bash_decision "(printf 'hello' | bash)")"
# A LITERAL brace argument leaves a depth this reader never closes. Ordering is what makes
# that safe: a stale depth only stops a separator from resetting, which WIDENS the
# producer, and can never hide a pipe.
check "a literal brace argument cannot hide a later pipeline" block \
    "$(bash_decision "echo { ; printf 'rm -rf src' | bash")"
# Command substitution as the RECEIVER, in both spellings. Each resolves to a shell that
# this reader cannot see, so an unresolvable command word has to count.
check "a backtick-substituted receiver still blocks" block \
    "$(bash_decision 'printf "rm -rf src" | `printf bash`')"
check "a \$()-substituted receiver still blocks" block \
    "$(bash_decision 'printf "rm -rf src" | $(printf bash)')"
# A pipeline broken across LINES. The normalizer turns a newline into a separator, so this
# ordinary two-line pipeline -- which bash runs as one -- arrived as a pipe feeding an empty
# stage, then a separator before the shell. Same for a comment sitting after the pipe.
check "a pipeline broken across lines still feeds its shell" block \
    "$(bash_decision "$(printf 'printf %s | \nbash' "'rm -rf src'")")"
check "a comment after the pipe does not break the pipeline" block \
    "$(bash_decision "$(printf 'printf %s | # note\nbash' "'rm -rf src'")")"
check "a harmless two-line pipeline stays allowed" allow \
    "$(bash_decision "$(printf 'printf %s | \nbash' "'hello'")")"
# COMPOUND commands are one pipeline stage however many separators sit inside them. Braces
# were only the first spelling of this family; `if`, `for`, `while` and `case` are the rest,
# and each was verified running the piped program.
check "an if-receiver still runs the piped program" block \
    "$(bash_decision "printf 'rm -rf src' | if true; then bash; fi")"
check "a for-receiver still runs the piped program" block \
    "$(bash_decision "printf 'rm -rf src' | for x in 1; do bash; done")"
check "a while-receiver still runs the piped program" block \
    "$(bash_decision "printf 'rm -rf src' | while read l; do bash; done")"
check "a case-receiver still runs the piped program" block \
    "$(bash_decision "printf 'rm -rf src' | case x in x) bash;; esac")"
check "a compound PRODUCER is not truncated at its own separator" block \
    "$(bash_decision "if true; then printf 'rm -rf src'; fi | bash")"
check "a harmless if-receiver stays allowed" allow \
    "$(bash_decision "printf 'hello' | if true; then bash; fi")"
# ...and the keywords count only in COMMAND position, or every `done` in a grep argument
# would open a group that nothing closes.
check "a compound keyword as plain data opens no group" allow \
    "$(bash_decision "grep -n done log ; git status")"
# NESTED compounds. The leading-run walk has to step OVER `then`/`do`/`else`/`elif`, or the
# inner opener goes uncounted while its closer still closes -- driving the depth to zero a
# whole compound early, which discards the producer.
check "a nested compound PRODUCER is not truncated" block \
    "$(bash_decision "if true; then if true; then printf 'rm -rf src'; fi; fi | bash")"
check "a nested compound RECEIVER still runs the piped program" block \
    "$(bash_decision "printf 'rm -rf src' | if true; then if true; then bash; fi; fi")"
# A `case` PATTERN terminator is a bare `)` with no opener. Counting parens and keywords in
# ONE depth let that `)` cancel the `case`, and the `;;` behind it then discarded the
# producer -- so the two are counted separately, each clamped at zero.
check "a case PRODUCER survives its pattern terminator" block \
    "$(bash_decision "case x in x) printf 'rm -rf src';; esac | bash")"
check "a case RECEIVER with a leading command still gets fed" block \
    "$(bash_decision "printf 'rm -rf src' | case x in x) :; bash;; esac")"
check "an ordinary case beside a git read stays allowed" allow \
    "$(bash_decision "case x in x) echo hi;; esac ; git status")"
# PIPELINE PREFIXES. bash allows `time`, `time -p` and `!` in front of a compound command,
# and stopping the leading-run walk on one counted no opener while its closer still closed.
check "a time-prefixed compound PRODUCER is not truncated" block \
    "$(bash_decision "time if true; then printf 'rm -rf src'; fi | bash")"
check "a !-prefixed compound PRODUCER is not truncated" block \
    "$(bash_decision "! if false; then :; else printf 'rm -rf src'; fi | bash")"
# A BUNDLED option carrying the program. Peeling one option letter leaves `Sbash`, and
# peeling a fixed number never terminates -- the bundle length is the caller choice -- so the
# test asks whether a dash-word ENDS WITH a shell name instead.
check "a BUNDLED env option still names a shell" block \
    "$(bash_decision "printf 'rm -rf src' | env -iS'bash -s'")"
check "a longer option bundle still names a shell" block \
    "$(bash_decision "printf 'rm -rf src' | env -uXS'bash -s'")"
check "a bundled env option with a harmless payload stays allowed" allow \
    "$(bash_decision "printf 'hello' | env -iS'bash -s'")"
# INDIRECTION: a NAME can stand for either end of the transport, and the definition sits in a
# DIFFERENT pipeline from the use, so no producer slice contains it. A command that both
# introduces indirection and contains a pipe is therefore scanned whole.
check "an eval receiver resolving to a shell blocks" block \
    "$(bash_decision 'A=bash; printf "rm -rf src" | eval "$A"')"
check "a FUNCTION receiver hiding the shell blocks" block \
    "$(bash_decision 'f(){ bash; }; printf "rm -rf src" | f')"
check "a FUNCTION producer hiding the payload blocks" block \
    "$(bash_decision 'g(){ printf "rm -rf src"; }; g | bash')"
check "a function receiver with a harmless payload stays allowed" allow \
    "$(bash_decision 'f(){ bash; }; printf "hello" | f')"
# One more listed stdin shell. The list is an ENUMERATION with a stated residual -- adding a
# name is free, so it is added rather than argued about.
check "yash reads its program from stdin too" block \
    "$(bash_decision "printf 'rm -rf src' | yash")"
# The `function` KEYWORD form defines a function with no `()` at all, and the shell
# concatenates adjacent quoted runs -- so `ev"al"` runs eval while the raw text holds no
# contiguous `eval`. Both are matched, the second on the quote-squeezed copy.
check "the function KEYWORD form is indirection too" block \
    "$(bash_decision 'function f { bash; }; printf "rm -rf src" | f')"
check "a quote-split eval is still eval" block \
    "$(bash_decision 'ev"al" '"'"'g(){ printf "rm -rf src"; }'"'"'; g | bash')"
check "merely MENTIONING a function stays allowed" allow \
    "$(bash_decision "grep -n 'function foo' src.js ; git status")"
# A shell function NAME is any word free of the metacharacters that end it: bash runs
# `f-x`, `f.x` and `my:fn`, none of which an identifier charset matches. Both definition
# forms carried that charset, so both were bypassable by a hyphen.
check "a hyphenated function name is still indirection (keyword form)" block \
    "$(bash_decision 'function f-x { bash; }; printf "rm -rf src" | f-x')"
check "a hyphenated function name is still indirection (POSIX form)" block \
    "$(bash_decision 'f-x() { bash; }; printf "rm -rf src" | f-x')"
check "a dotted function name is still indirection" block \
    "$(bash_decision 'function f.x { bash; }; printf "rm -rf src" | f.x')"
# A function BODY is any compound command, so requiring a `{` after the name missed
# `function f while ...; do ...; done` and `function f [[ ... ]]`. Enumerating body shapes
# is the arity guess this file refuses; the branch keys on the KEYWORD IN COMMAND POSITION
# instead, which is what keeps `grep function file` (the line above) allowed.
check "a brace-less loop body still defines a function" block \
    "$(bash_decision 'function fz while false; do bash; done; printf "rm -rf src" | fz')"
check "a brace-less [[ ]] body still defines a function" block \
    "$(bash_decision 'function fz [[ 1 ]]; printf "rm -rf src" | fz')"
check "a function defined inside an if is still indirection" block \
    "$(bash_decision 'if true; then function f { bash; }; fi; printf "rm -rf src" | f')"
# `env -S` hands its OPERAND to execvp, and the operand can be an expansion -- so the
# stage runs a shell while its command word never names one, and peeling options returns
# nothing at all. The executed operands are asked the same questions the stage was.
check "an executed operand that expands to a shell is a receiver" block \
    "$(bash_decision 'A=bash; printf "python3 hooks/gate-scripts/lib/lease_slot.py x" | env -S"$A"')"
# `<&` duplicates a descriptor exactly as `>&` does, but only the OUTPUT spelling was joined
# to its redirect -- so the splitter cut mid-redirect and the producer became the bare `0`.
check "an input fd duplication does not split the producer" block \
    "$(bash_decision "printf 'rm -rf src' <&0 | bash")"
check "...and the same shape reaching the helper guard" block \
    "$(bash_decision "printf 'python3 hooks/gate-scripts/lib/lease_slot.py x' <&0 | bash")"
# COMMAND POSITION is the whole reserved-word set, not the three words that happened to be
# listed: `if`, `while`, `until`, `!` and `time` all put the next word in command position.
# The anchor is derived from _GROUP_OPEN | _GROUP_CONNECT so adding a keyword extends it.
check "a function defined as the if CONDITION is indirection" block \
    "$(bash_decision 'if function f { bash; }; then printf "rm -rf src" | f; fi')"
check "a function defined as the while CONDITION is indirection" block \
    "$(bash_decision 'while function f { bash; }; do printf "rm -rf src" | f; done')"
check "a function behind the time prefix is indirection" block \
    "$(bash_decision 'time -p function f { bash; }; printf "rm -rf src" | f')"
check "a function behind the ! prefix is indirection" block \
    "$(bash_decision '! function f { bash; }; printf "rm -rf src" | f')"
# The `name()` form needed the same treatment, and had only separators. It cannot sit behind
# a group CLOSER or a pipeline prefix (`} f(){` and `! f(){` are not definitions), so its
# anchor takes openers and reserved words only -- admitting the closers cost 698 further
# over-blocks and closed nothing.
check "an explicit fd input duplication does not split either" block \
    "$(bash_decision "printf 'rm -rf src' 3<&0 | bash")"
check "a closing input duplication does not split either" block \
    "$(bash_decision "printf 'rm -rf src' <&- | bash")"
check "a name() definition after then is indirection" block \
    "$(bash_decision 'if true; then f(){ bash; }; printf "rm -rf src" | f; fi')"
check "a name() definition inside a brace group is indirection" block \
    "$(bash_decision '{ f(){ bash; }; printf "rm -rf src" | f; }')"
check "a name() definition inside a subshell is indirection" block \
    "$(bash_decision '( f(){ bash; }; printf "rm -rf src" | f )')"
check "a name() definition inside a do body is indirection" block \
    "$(bash_decision 'while true; do f(){ bash; }; printf "rm -rf src" | f; break; done')"
# The PIPED-producer probe used the plain name test while its siblings used the glob-aware
# one, so a helper named through a glob in a piped payload walked through.
check "a globbed helper in a PIPED payload is caught" block \
    "$(bash_decision "printf 'python3 hooks/gate-scripts/lib/lease_slo?.py x' | bash")"
check "...and the bracket spelling of the same" block \
    "$(bash_decision "printf 'python3 hooks/gate-scripts/lib/lease_slo[t].py x' | bash")"
check "a glob in a piped payload matching NO helper stays allowed" allow \
    "$(bash_decision "printf 'python3 scripts/harmles?.py x' | bash")"
# A COMMENT runs to the end of its line and may contain `;`. `_normalize` rewrites newlines
# to `;` a moment later, so an intact comment split into a comment segment plus a bare word
# that read as a real command and ended the pipeline one stage early. The separators inside
# the comment are BLANKED rather than the comment deleted -- deleting also removed
# apostrophes, which moved 14 real commands from block to ALLOW by making them parseable.
check "a comment containing a separator does not end the pipeline" block \
    "$(bash_decision "printf 'rm -rf src' | # ; ignored
bash")"
check "...and the same shape reaching the helper guard" block \
    "$(bash_decision "printf 'python3 hooks/gate-scripts/lib/lease_slot.py x' | # ; ignored
bash")"
check "a comment before a harmless receiver stays allowed" allow \
    "$(bash_decision "printf 'hello' | # ; ignored
cat")"
check "a # that is not in word position is not a comment" allow \
    "$(bash_decision "sed 's#a#b#' f | head")"
# `)` is not word position either: it can close a substitution INSIDE the current word, so
# `echo $(true)#x` is one word and the `;` after it is a real separator. Treating it as a
# comment opener blanked that separator and hid everything after it.
check "a # after a closing substitution is not a comment" block \
    "$(bash_decision 'echo $(true)#x; rm -rf src')"
# Nor is a `#` after an ESCAPED space: the escape makes it an ordinary character, so the
# word continues. Both spellings turn on state the previous OUTPUT character cannot carry,
# which is why word position is tracked explicitly rather than inferred.
check "a # after an escaped space is not a comment" block \
    "$(bash_decision 'echo foo\ #notcomment; rm -rf src')"
# The same class in the splitter: an escaped `<` is an argument, not a redirect, so the `|`
# after it is a real pipe. Inferring from the buffered character lost the pipeline.
check "an escaped < does not swallow the pipe after it" block \
    "$(bash_decision "printf 'rm -rf src' \\<|bash")"
# The two paren spellings close differently and were fail-opens in SUCCESSIVE rounds --
# first `)` always delimited (so `echo $(true)#x` mis-read as a comment), then `)` never
# did (so `(true)# x` mis-read as a word). One bit per open paren distinguishes them.
check "a # after a closing SUBSHELL is a comment" block \
    "$(bash_decision "(true)# '
rm -rf src
(true)# '")"
check "...while a # after a closing SUBSTITUTION still is not" block \
    "$(bash_decision 'echo $(true)#x; rm -rf src')"
check "an ordinary substitution in a pipeline stays allowed" allow \
    "$(bash_decision 'echo "$(date)" | cat')"
# One more stdin-reading interpreter. The list is an enumeration with a stated residual --
# adding a name is free, so it is added rather than argued about.
check "tclsh reads its program from stdin too" block \
    "$(bash_decision "printf 'exec rm -rf src' | tclsh")"
check "awk reads its program from stdin with -f -" block \
    "$(bash_decision "printf 'BEGIN { system(\"rm -rf src\") }' | awk -f -")"
# sqlite3 reads DOT-COMMANDS from stdin and `.shell` runs one. Same for the editors and
# clients that take a command stream and can shell out. The list is an enumeration with a
# stated residual: adding a name is free, so it is added rather than argued about, and the
# residual is that a name nobody has listed still reads as a non-receiver.
check "sqlite3 executes a stdin command stream too" block \
    "$(bash_decision "printf '.shell rm -rf src' | sqlite3")"
check "source /dev/stdin runs the piped text" block \
    "$(bash_decision "printf 'rm -rf src' | source /dev/stdin")"
check "the POSIX . spelling does too" block \
    "$(bash_decision "printf 'rm -rf src' | . /dev/stdin")"
# `.` is tested in COMMAND POSITION only: a bare `.` is an ordinary argument, and matching
# it as a name anywhere in the stage cost 100 over-blocks for nothing.
check "a bare . as an argument is not a receiver" allow \
    "$(bash_decision 'find . -name x | head')"
# A WRAPPER hides the real program among its operands, and peeling it can land on the wrong
# word: `env -u X …` peels to `X`, the operand of `-u`, so the globbed receiver behind it
# was never tested. Scoped to wrapper-led stages -- asking every stage costs 8.63%, worse
# than the option the issue rejected, while this costs ZERO (1,440 either way at the round
# it was measured; 1,561 was the total at the last round that could be measured).
check "a globbed receiver behind a wrapper OPTION is caught" block \
    "$(bash_decision "printf 'rm -rf src' | env -u X /bin/[b]ash")"
check "a glob in an ordinary argument is still not a receiver" allow \
    "$(bash_decision 'git log --oneline | grep -- *.py')"
check "xargs executes what it reads from stdin" block \
    "$(bash_decision "printf 'rm -rf src' | xargs")"
check "make runs a stdin Makefile with -f -" block \
    "$(bash_decision "printf 'all:
	rm -rf src
' | make -f -")"
# EXTGLOB changes the GRAMMAR, not just a name: `+(s)` is a pathname pattern, so
# `/bin/ba+(s)h` expands to `/bin/bash`. The splitter kept the parens as a group and the
# receiver came apart; shlex then reads the command word as `ba+`, which names no shell.
check "an extglob receiver still resolves to a shell" block \
    "$(bash_decision "printf 'rm -rf src' | /bin/ba+(s)h")"
check "...for the @ spelling too" block \
    "$(bash_decision "printf 'rm -rf src' | /bin/ba@(s)h")"
# `!( )` matches everything EXCEPT its contents, so resolving it to the inner text gives
# `baxh` -- the one spelling that reads as harmless. A negation is unresolvable, and
# unresolvable is the fail-CLOSED case.
check "a NEGATED extglob receiver fails closed" block \
    "$(bash_decision "printf 'rm -rf src' | ba!(x)h")"
check "an ordinary subshell receiver is still not an extglob" allow \
    "$(bash_decision 'echo "$(date)" | cat')"
# An ALTERNATION names two things at once, so resolving it to its inner text picks one
# spelling -- and for `ba@(s|z)h` that is `bas|zh`, the harmless-looking one. Naming more
# than one thing is the unresolved case, which fails CLOSED, exactly as a negation does.
check "an ALTERNATING extglob receiver fails closed" block \
    "$(bash_decision "printf 'rm -rf src' | /bin/ba@(s|z)h")"
# `&>` and `&>>` redirect BOTH streams: the `&` belongs to the redirect, not the pipeline.
# Read as a control operator it cut the segment and threw the real producer away.
check "an &> redirect does not split the producer off" block \
    "$(bash_decision "printf 'rm -rf src' &>/dev/stdout | bash")"
check "...and the same shape reaching the helper guard" block \
    "$(bash_decision "printf 'python3 hooks/gate-scripts/lib/lease_slot.py x' &>/dev/stdout | bash")"
# THE AMBIGUITY IS NOT GUESSED AT. Whether a `)` delimited a command depends on what its
# `(` opened, and bash has four answers: a subshell and a case pattern delimit, a
# substitution and a FUNCTION HEADER do not. Three review rounds each closed one spelling
# and opened another, so `)#` is now flagged unresolved and answered by the raw
# whole-command scan -- the same fail-CLOSED reading an unparseable command gets. One
# command in a 34,758-command corpus contains the shape at all.
check "a function-header paren before # falls back, not through" block \
    "$(bash_decision "f()# '
{
rm -rf src
}
# '
f")"
check "a case-pattern paren before # falls back, not through" block \
    "$(bash_decision "case x in x)# '
rm -rf src
;; esac")"
check "the fallback does not fire on a harmless )# command" allow \
    "$(bash_decision 'echo $(date)#tag; ls')"
check "...and the same shape reaching the helper guard" block \
    "$(bash_decision 'echo $(true)#x; python3 hooks/gate-scripts/lib/lease_slot.py x')"
# `hash -p PATH NAME` binds NAME to PATH for the rest of the shell -- the same re-pointing
# `alias` does, and simply absent from the indirection set. Verified executing.
check "hash -p remapping is indirection" block \
    "$(bash_decision 'hash -p /bin/bash f; printf "rm -rf src" | f')"
check "...including behind the builtin prefix" block \
    "$(bash_decision 'builtin hash -p /bin/bash f; printf "rm -rf src" | f')"
check "hash without -p stays allowed" allow \
    "$(bash_decision 'hash f; printf "hello" | f')"
# `command` and `builtin` take their OWN options before the builtin they run, so matching the
# bare word left `command -- hash -p …` open.
check "hash -p behind command -- is indirection" block \
    "$(bash_decision 'command -- hash -p /bin/bash f; printf "rm -rf src" | f')"
check "hash -p behind command -p is indirection" block \
    "$(bash_decision 'command -p hash -p /bin/bash f; printf "rm -rf src" | f')"
# An ASSIGNMENT PREFIX is still command position, and bash allows any number of them.
check "hash -p behind an assignment prefix is indirection" block \
    "$(bash_decision 'FOO=x hash -p /bin/bash f; printf "rm -rf src" | f')"
# THE PREFIX GRAMMAR IS NOT MODELLED. Three rounds each closed one prefix and left the
# next -- `FOO=x`, then `A+=x`, then a leading redirection, then >20 assignments -- while
# dropping the anchor entirely measured ZERO further over-blocks. These pin that.
check "hash -p behind an append assignment is indirection" block \
    "$(bash_decision 'A+=x hash -p /bin/bash f; printf "rm -rf src" | f')"
check "hash -p behind a leading redirection is indirection" block \
    "$(bash_decision '</dev/null hash -p /bin/bash f; printf "rm -rf src" | f')"
# NOR IS THE OPTION SEARCH. Unbounded it backtracked at 7.2s against a 5s hook timeout;
# bounded to 120 characters it was defeated by 121 spaces, because bash ignores horizontal
# whitespace. Any CHARACTER bound is a guess at how far an option sits from its verb.
check "hash with 121 spaces before -p is still indirection" block \
    "$(bash_decision "hash$(python3 -c 'print(" " * 121, end="")')-p /bin/bash f; printf 'rm -rf src' | f")"
# Indirection is asked of the NORMALIZED text too, where a line continuation is rejoined
# and \${IFS} is restored to whitespace -- the raw text spells neither of these.
check "a hash split across a line continuation is indirection" block \
    "$(bash_decision 'ha\
sh -p /bin/bash f; printf "rm -rf src" | f')"
check "a hash spelled with \${IFS} is indirection" block \
    "$(bash_decision 'hash${IFS}-p${IFS}/bin/bash${IFS}f; printf "rm -rf src" | f')"
# The shell strips ESCAPES before it resolves a command word, so the indirection test asks
# the shell VARIANTS, not just the dequoted text.
check "an escape-split hash is still indirection" block \
    "$(bash_decision 'h\a\s\h -p /bin/bash f; printf "rm -rf src" | f')"
# Bash accepts a redirection straight after a command name, so requiring whitespace after
# `eval` missed it. The classifier had always used the word boundary; the gate had not.
check "eval followed immediately by a redirect is indirection" block \
    "$(bash_decision 'eval</dev/null "f(){ bash; }"; printf "rm -rf src" | f')"
# ...asserted against the HELPER guard too, with no write verb anywhere in the command, so
# the assertion depends on the gate's own indirection regex rather than on the classifier
# reaching the same verdict by a different route.
check "...and the helper guard sees it, with no verb to help" block \
    "$(bash_decision 'eval</dev/null "python3 hooks/gate-scripts/lib/lease_slot.py .claude fake 1"')"
# The suffix is the REDIRECT characters, not a bare word boundary: a match here enables the
# wholesale helper-name scan, so `\beval\b` would block an innocent read that merely names
# a file called eval.md beside a helper path.
check "a file named eval.md beside a helper path stays allowed" allow \
    "$(bash_decision 'cat docs/eval.md hooks/gate-scripts/lib/lease_slot.py')"
# The redirect family must be COMPLETE, because missing one is the unsafe direction.
check "eval followed immediately by &> is indirection" block \
    "$(bash_decision 'eval&>/dev/null "python3 hooks/gate-scripts/lib/lease_slot.py .claude fake 1"')"
check "...and the &>> spelling too" block \
    "$(bash_decision 'eval&>>/dev/null "python3 hooks/gate-scripts/lib/lease_slot.py .claude fake 1"')"
# KNOWN over-block, and a deliberate one. This layer sees TEXT, not a parsed command word,
# so an `eval` that is an ARGUMENT followed by a redirect matches too. Telling the two apart
# needs the command word, which is a different layer; an over-block is the safe direction
# and the shape is contrived. Pinned as CURRENT behaviour so changing it trips this line.
check "eval as an ARGUMENT before a redirect over-blocks (deliberate)" block \
    "$(bash_decision 'cat eval</dev/null hooks/gate-scripts/lib/lease_slot.py')"
# Inside a `case`, a `|` separates PATTERN ALTERNATIVES rather than pipeline stages. Closing
# that needs case-pattern state, and getting it wrong the other way turns a real pipe into
# an inert pattern -- a fail-OPEN. An over-block is the safe error, and this one needs a
# pattern that BOTH holds a write verb AND names a shell, so ordinary patterns are untouched.
check "a case pattern alternative reads as a pipe (deliberate over-block)" block \
    "$(bash_decision "case foo in 'rm -rf src'|bash) :;; esac")"
check "...while an ordinary case pattern is unaffected" allow \
    "$(bash_decision 'case foo in a|b) echo hi;; esac')"
check "...including a globbed one" allow \
    "$(bash_decision 'case $x in *.md|*.txt) ls;; esac')"
# `*.py` is deliberately NOT used above: that glob can expand to a protected helper, and the
# unconditional helper guard blocks it for that reason alone -- nothing to do with the pipe.
check "a case pattern globbing .py is blocked by the HELPER guard, not the pipe" block \
    "$(bash_decision 'case $x in *.py|*.sh) ls;; esac')"
# NESTED extglob needs more than one substitution pass, and passes are guesses at a
# grammar. Same exit as the negation and the alternation: unresolved, fail CLOSED.
check "a NESTED extglob receiver fails closed" block \
    "$(bash_decision "printf 'rm -rf src' | /bin/ba@(+(s))h")"
# ...and the search for the option is BOUNDED, because the unbounded form backtracked
# catastrophically: 7.2s on a valid 59KB command, against a 5s hook timeout that fails
# OPEN. The regex WAS the fail-open, which is not a shape review usually looks for.
HASH_CMD="$(python3 -c 'print("if hash x " * 5900 + "| cat; rm -rf src")')"
HASH_T0=$(python3 -c 'import time; print(time.time())')
HASH_OUT="$(bash_decision "$HASH_CMD")"
HASH_EL=$(python3 -c 'import sys, time; print(time.time() - float(sys.argv[1]))' "$HASH_T0")
check "a 59KB command padded with hash still blocks" block "$HASH_OUT"
if python3 -c 'import sys; sys.exit(0 if float(sys.argv[1]) < 3.0 else 1)' "$HASH_EL"; then
    ok "...and returns well inside the 5s hook timeout ($(printf '%.2f' "$HASH_EL")s)"
else
    no "...and returns well inside the 5s hook timeout" "took ${HASH_EL}s"
fi
# A NEWLINE is a command separator exactly as `;` is -- `_normalize` rewrites one to the
# other -- so a definition on its own line sits in command position. This one line is the
# most expensive in the change (465 of 872 over-blocks) and is kept because the shape is
# ordinary: a multi-line command defining a helper function. See ADR 0032.
check "a name() definition on its own LINE is indirection" block \
    "$(bash_decision "true
f(){ bash; }
printf 'rm -rf src' | f")"
# A bash ALIAS NAME is not an identifier: `alias 1x=bash` is valid and runs.
check "a numeric-leading alias receiver is caught" block \
    "$(bash_decision 'shopt -s expand_aliases; alias 1x=bash; printf "python3 hooks/gate-scripts/lib/lease_slot.py x" | 1x')"
# A case PATTERN ends with a bare `)`, which puts the next word in command position exactly
# as `;` does. Costs 233 of the 1,105 over-blocks; kept because it is a closable fail-open
# and declining a closable one inverts the fail-CLOSED principle. See ADR 0032.
check "a name() definition after a case pattern is indirection" block \
    "$(bash_decision 'case x in x) f(){ bash; };; esac; printf "rm -rf src" | f')"
# Bash ignores QUOTING inside a comment, so a quote left there changes the quote state of
# everything after it. Two balanced ones wrap a real write in apparent quotes; one
# unbalanced one made the whole command unparseable. Both are fail-opens, so the defuser
# blanks quotes as well as separators.
check "balanced quotes in comments cannot wrap a write" block \
    "$(bash_decision "# '
rm -rf src
# '")"
check "a comment holding an apostrophe does not hide the next command" block \
    "$(bash_decision "# the caller's copy
rm -rf src")"
# `hash` takes BUNDLED options with an ATTACHED operand, so a bare `-p` token was the wrong
# test: `hash -rp/bin/bash f` remaps just as `hash -p /bin/bash f` does.
check "a bundled hash -rp with an attached operand is indirection" block \
    "$(bash_decision 'hash -rp/bin/bash f; printf "rm -rf src" | f')"
# BASH_CMDS is the hash table itself, exposed as a writable array: assigning to it binds a
# name to a path exactly as `hash -p` does, without ever naming the builtin.
check "a BASH_CMDS assignment is indirection" block \
    "$(bash_decision 'BASH_CMDS[f]=/bin/bash; printf "rm -rf src" | f')"
# A COMMAND SUBSTITUTION inside an argument inherits the pipeline stdin, so the shell it
# resolves to runs the payload while the stage command word is something harmless.
check "a shell inside a command substitution is a receiver" block \
    "$(bash_decision 'printf "rm -rf src" | echo "$(bash)"')"
# ...and an UNRESOLVED word inside one, for the same reason: a substitution is executed by
# definition, so `$SHELL` there is an unresolved command word however the outer stage reads.
check "an unresolved word inside a substitution is a receiver" block \
    "$(bash_decision 'printf "rm -rf src" | echo "$($SHELL)"')"
check "...including the backtick spelling" block \
    "$(bash_decision 'printf "rm -rf src" | echo "`$X`"')"
# NESTED substitutions have inner parens the flat pattern cannot cross, so openers are
# counted against matches and a shortfall fails CLOSED -- the same exit nested extglob takes.
check "a NESTED substitution receiver fails closed" block \
    "$(bash_decision 'printf "rm -rf src" | echo "$( ($SHELL) )"')"
# ...and the two spellings are counted SEPARATELY, because only `$(` openers are counted.
# One shared counter let an unrelated backtick substitution pay for the `$(` opener, so the
# nested `$( ( . /dev/stdin ) )` beside it read as fully resolved and ran the piped payload.
check "a flat backtick cannot pay for a nested \$( opener" block \
    "$(bash_decision 'printf "rm -rf src" | echo "`true` $( ( . /dev/stdin ) )"')"
# A substitution BODY is a command, so it gets the same receiver questions the stage got --
# not a weaker unresolved-characters test. `. /dev/stdin` names no shell and holds no
# unresolved character, and it runs the piped payload.
check "a . receiver inside a substitution is caught" block \
    "$(bash_decision 'printf "rm -rf src" | echo "$(. /dev/stdin)"')"
check "...including the backtick spelling of that" block \
    "$(bash_decision 'printf "rm -rf src" | echo "`. /dev/stdin`"')"
# ...and the body is a COMPOUND command, so every segment is asked, not just the first. A
# harmless leading `true` is what the effective-command-word test would otherwise read.
# Verified running the piped payload in real bash.
check "a receiver BEHIND a first command in the body is caught" block \
    "$(bash_decision 'printf "rm -rf src" | echo "$(true; . /dev/stdin)"')"
check "...including the backtick spelling of that" block \
    "$(bash_decision 'printf "rm -rf src" | echo "`true; . /dev/stdin`"')"
check "...and a shell NAME behind a first command too" block \
    "$(bash_decision 'printf "rm -rf src" | echo "$(true; bash)"')"
# A `case` PATTERN closes the flat substitution pattern early without nesting anything, so
# the body reads as `case x in x` and the receiver behind it is never seen. Unbalanced parens
# in a substitution-bearing stage mean the extraction cannot be trusted -- fail CLOSED.
# Verified running the piped payload in real bash.
check "a case pattern cannot truncate the substitution body" block \
    "$(bash_decision 'printf "rm -rf src" | echo "$(case x in x) $SHELL;; esac)"')"
check "...with a . receiver behind the case pattern too" block \
    "$(bash_decision 'printf "rm -rf src" | echo "$(case x in x) . /dev/stdin;; esac)"')"
# ...and the PRECISION that keeps: an ordinary case statement holds no substitution, so it
# never relies on the extraction and pays nothing.
check "an ordinary case statement is untouched by that" allow \
    "$(bash_decision 'case $x in *.md) echo doc;; esac')"
# Not shells, but they run a PROGRAM READ FROM STDIN exactly as one does. Costs 95 further
# over-blocks; the list is an enumeration and adding a name is free.
check "python3 reads its program from stdin too" block \
    "$(bash_decision 'printf "rm -rf src" | python3')"
check "perl reads its program from stdin too" block \
    "$(bash_decision 'printf "rm -rf src" | perl')"
# PRECISION, not a fail-open: grouping punctuation joins the operator run when no segment
# text separates it, so `||(` read as a pipe and over-blocked where `|| (` did not.
check "|| followed immediately by a group is not a pipe" allow \
    "$(bash_decision 'printf "rm -rf src" ||(bash)')"
check "...matching the spaced spelling, which never was" allow \
    "$(bash_decision 'printf "rm -rf src" || (bash)')"
check "a real |& pipe still feeds its receiver" block \
    "$(bash_decision 'printf "rm -rf src" |& bash')"
# A guard that is correct but too SLOW is a fail-open with extra steps: the hook has a 5s
# timeout, and a timed-out hook writes no decision, which the harness reads as allow. The
# command-position prefix used to carry a repeated group that went quadratic on a valid
# command of stacked `!` prefixes -- 5.4s, measured -- and the repetition was redundant.
BANG_CMD="$(python3 -c 'print("! " * 4000 + "true | cat; rm -rf src")')"
BANG_T0=$(python3 -c 'import time; print(time.time())')
BANG_OUT="$(bash_decision "$BANG_CMD")"
BANG_EL=$(python3 -c 'import sys, time; print(time.time() - float(sys.argv[1]))' "$BANG_T0")
check "4000 stacked ! prefixes still block" block "$BANG_OUT"
if python3 -c 'import sys; sys.exit(0 if float(sys.argv[1]) < 3.0 else 1)' "$BANG_EL"; then
    ok "...and return well inside the 5s hook timeout ($(printf '%.2f' "$BANG_EL")s)"
else
    no "...and return well inside the 5s hook timeout" "took ${BANG_EL}s"
fi
# A hook that TIMES OUT writes no decision, and the harness reads no decision as ALLOW --
# so an unbounded walk is a fail-open with extra steps. The per-stage payload walk now
# charges the same token budget the rest of the guard does; exhausting it fails CLOSED.
PERF_CMD=": | $(python3 -c 'print("env " * 16000)')"
PERF_T0=$(python3 -c 'import time; print(time.time())')
PERF_OUT="$(bash_decision "$PERF_CMD")"
PERF_EL=$(python3 -c 'import sys, time; print(time.time() - float(sys.argv[1]))' "$PERF_T0")
check "a 64KB pipeline of receivers still fails CLOSED" block "$PERF_OUT"
if python3 -c 'import sys; sys.exit(0 if float(sys.argv[1]) < 3.0 else 1)' "$PERF_EL"; then
    ok "...and returns well inside the 5s hook timeout ($(printf '%.2f' "$PERF_EL")s)"
else
    no "...and returns well inside the 5s hook timeout" "took ${PERF_EL}s"
fi
# STATED RESIDUAL, asserted so it stays deliberate rather than being rediscovered as a bug.
# A producer that ASSEMBLES its payload instead of stating it is not recoverable by parsing
# -- issue #557 says so of the split-operand spelling, and the variable spelling is the same
# class. A rule for the variable form was written and measured at 386 over-blocks (1.1%)
# while still leaving the split-operand form open, so it was declined. See ADR 0032.
check "an ASSEMBLED payload is a documented residual, not a block" allow \
    "$(bash_decision 'P='"'"'rm -rf src'"'"'; printf "%s" "$P" | bash')"
check "the split-operand assembly is the same residual" allow \
    "$(bash_decision "printf '%s%s' r 'm -rf src' | bash")"
# Receiver spellings a literal seven-name list misses. csh/tcsh/fish were each verified
# EXECUTING a piped program, and the shell expands `/bin/[b]ash` onto bash before the
# command word exists, so a literal-name test reads a name no list contains.
check "csh reads its program from stdin too" block \
    "$(bash_decision "printf 'rm -rf src' | csh")"
check "fish reads its program from stdin too" block \
    "$(bash_decision "printf 'rm -rf src' | fish")"
check "a GLOBBED shell path on the receiving end still blocks" block \
    "$(bash_decision "printf 'rm -rf src' | /bin/[b]ash")"
# LAUNCHERS with no command operand exec a shell, so the pipe feeds that shell. Raised by
# Codex on #562 against util-linux `script`; the mechanism is the same for `su` and
# `chroot`. Not reproducible on macOS, where `script` wants a tty and hangs instead of
# running the payload -- so these are pinned here rather than resting on a local repro.
check "a script launcher on the receiving end blocks" block \
    "$(bash_decision "printf 'rm -rf src' | script -q /dev/null")"
check "...and su with no command too" block \
    "$(bash_decision "printf 'rm -rf src' | su")"
check "...and chroot with no command too" block \
    "$(bash_decision "printf 'rm -rf src' | chroot /jail")"
# ...including for the unconditional helper protection, which is the other thing the
# producer scan backs.
check "the helper piped into a script launcher is blocked" block \
    "$(bash_decision "printf 'python3 hooks/gate-scripts/lib/lease_slot.py x' | script -q /dev/null")"
# A launcher stays in COMMAND POSITION behind an assignment or a keyword prefix, and
# `unshare`/`nsenter` are not wrappers, so a leading-token test alone missed both. The
# prefix run is walked instead.
check "an assignment prefix does not hide a launcher" block \
    "$(bash_decision "printf 'rm -rf src' | FOO=1 unshare")"
check "...nor does a time prefix" block \
    "$(bash_decision "printf 'rm -rf src' | time script -q /dev/null")"
check "...nor exec, nor several assignments" block \
    "$(bash_decision "printf 'rm -rf src' | A=1 B=2 nsenter -t 1")"
check "...and a WRAPPER can still hide one among its operands" block \
    "$(bash_decision "printf 'rm -rf src' | env -i script -q /dev/null")"
# A REDIRECTION and a prefix word's own connector sit in the same run, and the first cut
# of the walk stopped on both. `2>/dev/null unshare` and `time -p unshare` each still put
# the launcher in command position.
check "a leading redirection does not hide a launcher" block \
    "$(bash_decision "printf 'rm -rf src' | 2>/dev/null unshare")"
check "...nor a redirection whose operand is a separate word" block \
    "$(bash_decision "printf 'rm -rf src' | > /dev/null nsenter -t 1")"
check "...nor an option belonging to the prefix word" block \
    "$(bash_decision "printf 'rm -rf src' | time -p unshare")"
check "...nor both at once" block \
    "$(bash_decision "printf 'rm -rf src' | 2>/dev/null time -p script -q /dev/null")"
check "the helper survives neither spelling" block \
    "$(bash_decision "printf 'python3 hooks/gate-scripts/lib/lease_slot.py x' | time -p script -q /dev/null")"
check "a redirected non-launcher receiver stays allowed" allow \
    "$(bash_decision "echo 'rm -rf src' | 2>/dev/null grep script")"
check "...and time -p in front of a real command is not unresolved" allow \
    "$(bash_decision "echo 'rm -rf src' | time -p grep -c su")"
# An UNKNOWN option in command position is the arity question again: `-o` takes a value,
# so skipping it reads `timing.out` as the command and the launcher behind it is missed.
# Unresolved marks the stage and the WHOLE stage is asked, which is fail-closed and costs
# the English-word precision the check below pins.
check "an option of unknown arity cannot hide a launcher" block \
    "$(bash_decision "printf 'rm -rf src' | /usr/bin/time -o timing.out unshare")"
check "the known cost of that: an unresolved stage over-blocks the word" block \
    "$(bash_decision "echo 'rm -rf src' | /usr/bin/time -o timing.out grep -c su")"
# A COMPOUND stage passes its stdin to the command inside it, so command position has to
# be restored after every separator and every reserved word -- in command position only,
# which is what keeps the `grep for script` shape below allowed.
check "a brace group does not hide a launcher" block \
    "$(bash_decision "printf 'rm -rf src' | { unshare; }")"
check "...nor does an if" block \
    "$(bash_decision "printf 'rm -rf src' | if unshare; then :; fi")"
check "...nor a while, nor the helper inside one" block \
    "$(bash_decision "printf 'python3 hooks/gate-scripts/lib/lease_slot.py x' | while unshare; do :; done")"
check "a brace group around a NON-launcher stays allowed" allow \
    "$(bash_decision "echo 'rm -rf src' | { grep script; }")"
check "a reserved word as an ARGUMENT does not restore command position" allow \
    "$(bash_decision "echo 'rm -rf src' | grep for script")"
# A SUBSTITUTION runs inside the pipeline, so it inherits the stdin the outer command
# never reads. The body scan asked about shell names and `.` but not about launchers.
check "a launcher inside a substitution body is caught" block \
    "$(bash_decision "printf 'rm -rf src' | echo \"\$(unshare)\"")"
check "...in the backtick spelling too" block \
    "$(bash_decision "printf 'rm -rf src' | echo \`unshare\`")"
check "...and for the helper, which is the guard that has no escape hatch" block \
    "$(bash_decision "printf 'python3 hooks/gate-scripts/lib/lease_slot.py x' | echo \"\$(unshare)\"")"
# A PREFIX ahead of a WRAPPER: the fallback was asked of the whole token list, and this
# copy of _starts_with_wrapper does not model `time`, so it answered no and the launcher
# among the wrapper operands went unseen. Asked from the command word instead. These are
# the gate-side spot checks for the composition the property below drives exhaustively.
check "a prefix in front of a wrapper does not hide a launcher" block \
    "$(bash_decision "printf 'rm -rf src' | time env -i script -q /dev/null")"
check "...including for the helper" block \
    "$(bash_decision "printf 'python3 hooks/gate-scripts/lib/lease_slot.py x' | time env -i script -q /dev/null")"
check "...and with the connector between them" block \
    "$(bash_decision "printf 'rm -rf src' | time -p env -i unshare")"
check "...and for sudo, which is the other wrapper regime" block \
    "$(bash_decision "printf 'rm -rf src' | time sudo unshare")"
# find hands -exec its own command, and find never reads the pipe itself, so the payload
# is still unread when that command execs a shell.
check "a launcher in a find -exec payload is caught" block \
    "$(bash_decision "printf 'rm -rf src' | find . -maxdepth 0 -exec unshare ;")"
check "...including for the helper" block \
    "$(bash_decision "printf 'python3 hooks/gate-scripts/lib/lease_slot.py x' | find . -maxdepth 0 -exec unshare ;")"
check "a find that merely NAMES one stays allowed" allow \
    "$(bash_decision "echo 'rm -rf src' | find . -name script")"
# `+` ends an -exec only in the `{} +` form. Breaking on a BARE `+` truncated the payload
# at an ordinary operand -- here the output file of `time -o` -- and the launcher behind
# it was never read. The same truncation was in the write-verb extractor and the gate copy.
check "a bare + does not truncate the -exec payload" block \
    "$(bash_decision "printf 'rm -rf src' | find . -maxdepth 0 -exec /usr/bin/time -o + unshare ;")"
check "...and the {} + form still terminates properly" block \
    "$(bash_decision "find . -name '*.tmp' -exec rm -rf {} +")"
# A "-exec"-shaped TOKEN is answered by PRESENCE, deliberately. `-name` takes an
# arbitrary word, so in `-name -exec` the `-exec` is a filename PATTERN and find runs
# nothing -- but every attempt to be precise about that became a fail-OPEN, because an
# operand-taking primary the table does not know (`-printf`) puts a primary NAME into
# data position and lets it eat a REAL `-exec`. Presence alone costs nothing here: at
# ordinary depth the payload is EXTRACTED, and a trailing `-exec` has none, so the
# pattern spelling is allowed on the payload's merits rather than by parsing find. The
# over-block is confined to the depth cap, where no payload is examined at all.
check "a -exec-shaped filename pattern is allowed on an empty payload" allow \
    "$(bash_decision "printf 'rm -rf src' | find . -maxdepth 0 -name -exec")"
check "...and a primary eaten as data cannot hide a REAL -exec" block \
    "$(bash_decision "printf 'rm -rf src' | find . -maxdepth 0 -name -name -exec unshare ;")"
check "...nor can one hidden behind an unlisted primary" block \
    "$(bash_decision "printf 'rm -rf src' | find . -maxdepth 0 -printf -name -exec unshare ;")"
# VERSION-QUALIFIED interpreters are real packaged executables (`python3.12`, `perl5.38.2`,
# `tclsh8.6`, `wish8.5`), and the exact-name receiver set does not match them. Each of
# these read the piped text as a program while the classifier called it a plain read.
check "a versioned python receiver is still a receiver" block \
    "$(bash_decision "printf 'rm -rf src' | python3.12")"
check "...and a versioned perl" block \
    "$(bash_decision "printf 'rm -rf src' | perl5.38.2")"
check "...and both halves of the Tcl/Tk pair" block \
    "$(bash_decision "printf 'rm -rf src' | wish8.5")"
check "...including wearing an attached option bundle" block \
    "$(bash_decision "printf 'rm -rf src' | env -iStclsh8.6")"
# `source` is the bash spelling of `.`, and like `.` it means something only in COMMAND
# position: as any-word it flipped `grep source`, where the word is a PATTERN.
check "source names a command only in command position" allow \
    "$(bash_decision "printf 'rm -rf src' | grep source")"
check "...and there it is a receiver" block \
    "$(bash_decision "printf 'rm -rf src' | source /dev/stdin")"
# The simple-command split is done on the RAW TEXT, not on tokens: shlex erases the
# difference between a separator `;` and an operand that merely spells one, so a
# token-level split read `unshare` as a command word here and over-blocked.
check "an ESCAPED separator is an operand, not a command boundary" allow \
    "$(bash_decision "echo 'rm -rf src' | grep \\; unshare")"
check "...and a quoted paren likewise" allow \
    "$(bash_decision "echo 'rm -rf src' | grep '(' script")"
# A MULTI-CALL dispatcher puts the applet name one word to the right, and busybox ships
# its own unshare applet, which execs $SHELL when handed no program.
check "busybox dispatching to a launcher applet is caught" block \
    "$(bash_decision "printf 'rm -rf src' | busybox unshare")"
check "...including for the helper" block \
    "$(bash_decision "printf 'python3 hooks/gate-scripts/lib/lease_slot.py x' | busybox unshare")"
check "busybox dispatching to an ordinary applet stays allowed" allow \
    "$(bash_decision "echo 'rm -rf src' | busybox grep -c script")"
# The set is an ENUMERATION and does not close -- these two arrived a round after the
# first six, named by a reviewer rather than derived. Pinned so a future trim is deliberate.
check "newgrp with no command execs a shell" block \
    "$(bash_decision "printf 'rm -rf src' | newgrp")"
check "...and sg does too" block \
    "$(bash_decision "printf 'rm -rf src' | sg users")"
check "...while the same names as data stay allowed" allow \
    "$(bash_decision "echo 'rm -rf src' | grep -c newgrp")"
# A dispatcher with a DYNAMIC applet: peeling lands on `busybox`, which is resolved and
# harmless, while the word that decides what runs is the expansion behind it. Unresolved
# in command position fails CLOSED, and the walk is the only place that word is visible.
check "a dynamic busybox applet fails closed" block \
    "$(bash_decision "printf 'rm -rf src' | busybox \"\$APPLET\"")"
check "...including for the helper" block \
    "$(bash_decision "printf 'python3 hooks/gate-scripts/lib/lease_slot.py x' | busybox \"\$APPLET\"")"
# The -exec scan is anchored on find being the COMMAND: naming find, -exec and a launcher
# as grep PATTERNS executes none of them.
check "find named only as grep data does not trigger the -exec scan" allow \
    "$(bash_decision "echo 'rm -rf src' | grep -e find -e -exec -e unshare")"
# ...and through the dispatcher, whose find applet is the same find.
check "busybox find -exec is scanned like a bare find" block \
    "$(bash_decision "printf 'rm -rf src' | busybox find . -exec unshare ;")"
# A find -exec payload carries REAL argv boundaries, so it is requoted before it is
# re-read. Space-joining turned one grep pattern into a second command.
check "punctuation inside an -exec operand is not shell syntax" allow \
    "$(bash_decision "printf 'rm -rf src' | find . -exec grep \"foo; unshare\" ;")"
check "...and the helper guard agrees" allow \
    "$(bash_decision "printf 'python3 hooks/gate-scripts/lib/lease_slot.py x' | find . -exec grep \"foo; unshare\" ;")"
# sudo and doas are wrappers EXCEPT in their shell modes, where a flag and no command
# operand start a shell. The flag is what is matched: proving the absence of a command
# operand needs the option-arity table this module refuses. Lowercase only -- an uppercase
# -S reads the PASSWORD from stdin, so the pipe is data there, not a program.
check "sudo in shell mode is a launcher" block \
    "$(bash_decision "printf 'rm -rf src' | sudo -n -s")"
check "...and its login mode too" block \
    "$(bash_decision "printf 'rm -rf src' | sudo -i")"
check "...and doas likewise" block \
    "$(bash_decision "printf 'rm -rf src' | doas -n -s")"
check "...including for the helper" block \
    "$(bash_decision "printf 'python3 hooks/gate-scripts/lib/lease_slot.py x' | sudo -n -s")"
check "...and the LONG spellings" block \
    "$(bash_decision "printf 'rm -rf src' | sudo --shell")"
check "...and the long login form" block \
    "$(bash_decision "printf 'rm -rf src' | sudo --login")"
check "...and a bundle of no-argument flags" block \
    "$(bash_decision "printf 'rm -rf src' | sudo -ns")"
# The flag is looked for in the WHOLE stage, not in an option run. Scoping it to the run
# needed to know which options take a VALUE: `sudo -u root -s` hid the flag behind an
# operand, `sudo --user root --shell` behind a long one, and `sudo -B -s` behind a flag
# missing from the list -- three rounds, three rows of the arity table this module refuses.
# The whole-stage scan is the regime a WRAPPER already selects everywhere else here, and
# it carries the same documented PRICE, pinned below so it stays deliberate: a word in the
# wrapped command DATA reads as the flag, exactly as `sudo grep rm notes.txt` already
# blocks on a verb in grep data.
check "a shell flag behind a value-taking option is still found" block \
    "$(bash_decision "printf 'rm -rf src' | sudo -u root -s")"
check "...and behind a LONG one" block \
    "$(bash_decision "printf 'rm -rf src' | sudo --user root --shell")"
check "...and nested behind another wrapper" block \
    "$(bash_decision "printf 'rm -rf src' | env -i sudo -s")"
check "the price of that regime: an option of the wrapped command (deliberate)" block \
    "$(bash_decision "echo 'rm -rf src' | sudo grep -i needle")"
check "...uniform under doas (deliberate)" block \
    "$(bash_decision "echo 'rm -rf src' | doas grep -i needle")"
# A bundle still counts only when every letter is a no-argument flag, so `-ualice` reads
# as `-u` with its value attached rather than as five flags.
check "a value attached to a short option is not a flag bundle" allow \
    "$(bash_decision "echo 'rm -rf src' | sudo -ualice grep needle")"
# ...and an unwrapped command is untouched by any of it.
check "an ordinary -i outside a wrapper is not a shell mode" allow \
    "$(bash_decision "echo 'rm -rf src' | grep -i needle")"
# getopt_long takes any unambiguous ABBREVIATION, so the long forms are matched by prefix.
check "an abbreviated long shell flag is still a shell mode" block \
    "$(bash_decision "printf 'rm -rf src' | sudo --shel")"
check "...and the abbreviated login form" block \
    "$(bash_decision "printf 'rm -rf src' | sudo --logi")"
# A bundle is read LEFT TO RIGHT and stops at the first flag that takes a value, because
# the rest of the token is that value: `-su root` is `-s -u root`, `-ualice` is not.
check "a shell flag before a value-taking one in a bundle counts" block \
    "$(bash_decision "printf 'rm -rf src' | sudo -su root")"
check "...and after other no-argument flags" block \
    "$(bash_decision "printf 'rm -rf src' | sudo -nsu root")"
# When an option of unknown arity has already made command position unresolvable, an
# EXPANSION among the remaining words is what runs, and there is no literal name to test.
check "an expansion behind an unknown option fails closed" block \
    "$(bash_decision "printf 'rm -rf src' | /usr/bin/time -o /dev/null \"\$APPLET\"")"
# A for/select/case HEADER names a variable or a subject, never a command. Reading the
# word after the opener as a command word blocked ordinary loops over these names.
check "a for header naming a launcher is not a command" allow \
    "$(bash_decision "printf 'rm -rf src' | for script in a; do grep x; done")"
check "...nor is a select header" allow \
    "$(bash_decision "printf 'rm -rf src' | select unshare in a; do :; done")"
check "...nor a case subject" allow \
    "$(bash_decision "printf 'rm -rf src' | case script in x) :;; esac")"
check "...while the loop BODY is still a command" block \
    "$(bash_decision "printf 'rm -rf src' | for x in a; do unshare; done")"
# An executed OPERAND is lexed before the name tests, not split on whitespace: the shell
# resolves the quoting, and a raw split leaves `'unshare'` carrying its quotes, which no
# name set holds. Both the shell-name test and the launcher test read the same words.
check "a quoted launcher inside an executed operand is caught" block \
    "$(bash_decision "printf 'rm -rf src' | env -S \"env -i 'unshare'\"")"
check "...and a quoted shell name likewise" block \
    "$(bash_decision "printf 'rm -rf src' | env -S \"env -i 'bash'\"")"
check "...and the same nested in a substitution" block \
    "$(bash_decision "printf 'rm -rf src' | echo \"\$(env -S 'env -i unshare')\"")"
# DELIBERATE over-block, pinned so that changing it is a decision rather than a drift: a
# launcher given an explicit program (`unshare -- grep rm`) runs that program and the pipe
# is data, but proving there IS one needs per-launcher operand arity -- `unshare --  CMD`
# and `chroot -- NEWROOT CMD` put the command in different places, and `script -c` in a
# third. That table is the thing this module refuses, because it fails OPEN wherever it is
# wrong. Blocking a launcher that would have been harmless costs precision on one command.
check "a launcher with an explicit program over-blocks (deliberate)" block \
    "$(bash_decision "printf 'rm -rf src' | unshare -- grep rm")"
# The helper guard reads the SAME words, so its copy has to lex them too -- it was still
# splitting on whitespace after the classifier stopped.
check "a quoted shell in an executed operand blocks for the helper too" block \
    "$(bash_decision "printf 'python3 hooks/gate-scripts/lib/lease_slot.py x' | env -S \"env -i 'bash'\"")"
# PERFORMANCE is a security property here: the hook has a 5s timeout and a timed-out hook
# writes NO decision, which the harness reads as ALLOW. Restarting the -exec search after
# each hit re-read every operand of the payload already collected, so operands that merely
# SPELL `-exec` cost O(N^2) -- 1,400 of them measured 6.04s. The scan is index-controlled
# now; this pins the shape at a size that took seconds before and milliseconds after.
_XP="$(python3 -c 'print("-exec foo " * 1400)')"
check "operands that spell -exec do not make the find scan quadratic" block \
    "$(bash_decision "printf 'rm -rf src' | find . -exec grep $_XP unshare ;")"
# The HELPER guard walks the same payloads through its own extractor, which emitted an
# overlapping suffix per `-exec` operand -- 1,900 of them measured 11.0s, more than twice
# the hook timeout. Timed against the same 5s ceiling the padded-command budget uses.
_XP2="$(python3 -c 'print("-exec foo " * 1900)')"
_T0="$(python3 -c 'import time; print(time.time())')"
check "...and neither does the helper guard payload walk" block \
    "$(bash_decision "printf 'python3 hooks/gate-scripts/lib/lease_slot.py x' | find . -exec grep $_XP2 unshare ;")"
_EL="$(python3 -c 'import sys,time; print("%.2f" % (time.time() - float(sys.argv[1])))' "$_T0")"
if python3 -c 'import sys; sys.exit(0 if float(sys.argv[1]) < 3.5 else 1)' "$_EL"; then
    ok "the helper payload walk stays inside the hook timeout (${_EL}s < 3.5s)"
else
    no "helper payload walk timing" "${_EL}s >= 3.5s budget"
fi
# ...and the precision that buys: these are ordinary words, so they must only count in
# command position. Matching them anywhere would flip every one of these to block.
check "a launcher NAME as a grep pattern stays allowed" allow \
    "$(bash_decision "echo 'rm -rf src' | grep script")"
check "...including behind an assignment prefix" allow \
    "$(bash_decision "echo 'rm -rf src' | FOO=1 grep script")"
check "...and behind a time prefix" allow \
    "$(bash_decision "echo 'rm -rf src' | time grep -c su")"
check "the pipe is found inside an executed string too" block \
    "$(bash_decision "bash -c \"printf 'rm -rf src' | bash\"")"
# The helper guard has to agree: the same invocation one transport apart was blocked as
# `bash -c` and allowed through a pipe.
check "the helper piped into a stdin shell is blocked" block \
    "$(bash_decision "printf 'python3 hooks/gate-scripts/lib/lease_slot.py .claude 20 30 3600' | bash")"
# ...and the gate's own substitution counter has to agree with cmdword's: a flat backtick
# must not pay for a nested `$(` opener, or the nested receiver beside it reads as resolved
# and sources the helper payload off the pipe. Verified executing in real bash.
check "a flat backtick cannot pay for a nested opener at the gate" block \
    "$(bash_decision 'printf "python3 hooks/gate-scripts/lib/lease_slot.py x" | echo "`true` $( ( . /dev/stdin ) )"')"
# ...and the gate splits a COMPOUND body too, so a leading `true` cannot hide the receiver
# that sources the helper payload off the pipe. Both substitution spellings.
check "a receiver behind a first command in the body blocks at the gate" block \
    "$(bash_decision 'printf "python3 hooks/gate-scripts/lib/lease_slot.py x" | echo "$(true; . /dev/stdin)"')"
check "...including the backtick spelling of that at the gate" block \
    "$(bash_decision 'printf "python3 hooks/gate-scripts/lib/lease_slot.py x" | echo "`true; . /dev/stdin`"')"
# ...and the gate refuses the truncated-by-a-case-pattern body too, so the helper payload
# cannot be sourced off the pipe behind one.
check "a case pattern cannot truncate the body at the gate" block \
    "$(bash_decision 'printf "python3 hooks/gate-scripts/lib/lease_slot.py x" | echo "$(case x in x) . /dev/stdin;; esac)"')"
# ...and the precision this keeps. Scanning the WHOLE command on any shell name was
# measured against 34,758 real commands and over-blocked 2,693 of them (7.7%); scoping the
# scan to the PRODUCER cost 1,561 (4.49%) at the last round that could be measured -- two
# rules landed after it with the corpus gone, so ADR 0032 carries the breakdown and
# supersedes every earlier figure. These four are the shapes that difference is made
# of -- a shell with a script operand on the receiving end of a pipe, a genuine -c, a
# non-shell consumer, and `||`, which feeds the next segment nothing.
check "a script-operand shell fed by a pipe stays allowed" allow \
    "$(bash_decision 'gh pr checks 1 | bash scripts/x.sh "$(git rev-parse HEAD)"')"
check "a genuine bash -c with a harmless payload stays allowed" allow \
    "$(bash_decision "bash -c 'git status'")"
check "the same quoted verb piped into grep stays allowed" allow \
    "$(bash_decision "echo 'rm -rf src' | grep rm")"
check "a harmless payload piped into bash stays allowed" allow \
    "$(bash_decision "printf 'hello' | bash")"
check "|| is not a pipe, so it feeds the shell nothing" allow \
    "$(bash_decision "git status || bash")"
check "running a test script beside an unrelated git read stays allowed" allow \
    "$(bash_decision "bash tests/foo.sh && git status")"
# A GENERATED matrix over the composition the hand-picked cases above sample. The grouped
# and expanded spellings were found by review, not by these tests, precisely because
# examples do not compose -- so the invariant is asserted over the product instead:
# grouping and receiver spelling must not change the verdict. Run against the classifier
# directly (not the gate) so the product stays affordable; the gate-level cases above pin
# that the two agree on the same shapes.
_STDIN_PROP="$(python3 - "$REPO_ROOT" <<'PY'
import sys
sys.path.insert(0, sys.argv[1] + "/hooks/gate-scripts/lib")
import cmdword

# Producer spellings, each of which really emits the verb.
PRODUCERS = ["printf 'rm -rf src'", "echo 'rm -rf src'", "printf '%s' 'rm -rf src'",
             "printf 'echo x > src/impl.py'",
             "if true; then printf 'rm -rf src'; fi",
             "case x in x) printf 'rm -rf src';; esac",
             "time if true; then printf 'rm -rf src'; fi",
             "! if false; then :; else printf 'rm -rf src'; fi"]
# Grouping applied to the producer. Every one of these runs the same program.
GROUPS = [lambda p: p, lambda p: "(" + p + ")", lambda p: "{ " + p + "; }"]
# Receiver spellings. Everything from `csh` on was missed by some earlier cut of the
# candidate test -- literal names, grouping, a separator inside the group, an attached
# option value, a glob, an expansion.
RECEIVERS = ["bash", "sh", "sh -s", "bash --norc", "env sh", "(bash)", "csh", "fish",
             "{ :; bash; }", "( :; bash )", "env -S'bash -s'",
             "env --split-string='bash -s'", "/bin/[b]ash", "$SHELL",
             chr(96) + "printf bash" + chr(96), "$(printf bash)",
             "\nbash", "# note\nbash", "if true; then bash; fi",
             "for x in 1; do bash; done", "while read l; do bash; done",
             "case x in x) :; bash;; esac", "if true; then if true; then bash; fi; fi",
             "env -iS'bash -s'", "env -uXS'bash -s'", "yash", "posh"]
# ...and grouping applied to the WHOLE pipeline rather than to either end. Grouping only
# the producer is what let `(producer | bash)` through: its pipe sat inside a group.
WHOLE = [lambda c: c, lambda c: "(" + c + ")", lambda c: "{ " + c + "; }"]
bad = []
for p in PRODUCERS:
    for g in GROUPS:
        for r in RECEIVERS:
            for w in WHOLE:
                cmd = w(g(p) + " | " + r)
                if not cmdword.is_file_mod(cmd):
                    bad.append(cmd)
# The other half of the invariant: the same shapes around a HARMLESS producer must stay
# allowed -- otherwise "block everything" would pass the above.
for g in GROUPS:
    for r in RECEIVERS:
        for w in WHOLE:
            cmd = w(g("printf 'hello'") + " | " + r)
            if cmdword.is_file_mod(cmd):
                bad.append("OVERBLOCK " + cmd)
print((len(PRODUCERS) + 1) * len(GROUPS) * len(RECEIVERS) * len(WHOLE))
for b in bad[:6]:
    print("MISMATCH " + b)
PY
)"
_STDIN_RC=$?
# The python must have SUCCEEDED and reported a positive combination count. Searching stdout
# for MISMATCH alone passes when the process dies -- an import error or an exception produces
# no MISMATCH either, and a matrix that never ran certifies nothing.
_STDIN_N="$(printf '%s\n' "$_STDIN_PROP" | head -1)"
case "$_STDIN_N" in ''|*[!0-9]*) _STDIN_N=0 ;; esac
if [[ "$_STDIN_RC" -eq 0 ]] && [[ "$_STDIN_N" -gt 0 ]] \
   && ! printf '%s\n' "$_STDIN_PROP" | grep -q MISMATCH; then
    ok "stdin-shell verdict survives grouping x receiver spelling ($_STDIN_N combinations)"
else
    no "stdin-shell composition matrix" \
       "rc=$_STDIN_RC n=$_STDIN_N $(printf '%s\n' "$_STDIN_PROP" | grep MISMATCH | head -3 | tr '\n' ' ')"
fi
check "xargs running rm" block "$(bash_decision "echo hi | xargs rm")"
check "find -exec rm" block "$(bash_decision "find . -exec rm {} ;")"
check "find -delete" block "$(bash_decision "find . -delete")"
# Launchers/keywords that RUN a following command. Each was a fail-open while this
# module's wrapper list was narrower than the forge detector's.
check "coproc running rm" block "$(bash_decision "coproc rm src/x")"
check "caffeinate running rm" block "$(bash_decision "caffeinate rm src/x")"
check "su -c running rm" block "$(bash_decision "su -c 'rm src/x'")"
check "function body containing rm" block "$(bash_decision "function f { rm src/x; }; f")"
check "find -exec with a WRAPPED verb" block "$(bash_decision "find . -exec sudo rm {} ;")"
check "echo naming coproc stays allowed" allow "$(bash_decision "echo coproc rm x")"
# Wrapper flag OPERANDS and shell reserved words. Peeling to the first plausible token
# returned `root`, `{` and `then` respectively, allowing the write behind them.
check "sudo with a flag operand before rm" block \
    "$(bash_decision "sudo -u root rm -rf src")"
check "brace group around rm" block "$(bash_decision "{ rm -rf src; }")"
check "if/then around rm" block "$(bash_decision "if true; then rm -rf src; fi")"
check "wrapped sed -i" block "$(bash_decision "sudo sed -i 's/a/b/' f")"
# Executed-string operands. Tokenizing alone reduces these to inert single tokens, so
# each was a live fail-open in the first cut of this change — caught by codex review.
# Note the shape is IDENTICAL to the allowed `bash -c 'echo "(mv FAILS)"'` above; only
# the inner program differs, which is why the operand must be re-classified as shell
# source rather than pattern-matched.
check "bash -c with an rm payload" block "$(bash_decision "bash -c 'rm -rf src'")"
check "eval with an rm payload" block "$(bash_decision "eval 'rm -rf src'")"
check "command substitution running rm" block "$(bash_decision "echo \"\$(rm -rf src)\"")"
check "wrapper + shell -c payload" block "$(bash_decision "sudo bash -c 'rm x'")"
# The unparseable path must fall back to the REGEXES (block), never to "allow" —
# this is the one branch where a tokenizer bug could become a fail-open.
check "unparseable (apostrophe in prose) + rm falls back to blocking" block \
    "$(bash_decision "git commit -m \"the operator's skip file\" && rm x")"

echo "── item 3: the skip file is a lease ────────────────────────────────"

arm_skip() {   # <age-seconds>
    rm -rf "$WORK/.claude/.skip-design-review-lease.d"
    : >"$WORK/.claude/skip-design-review.local"
    # Backdate so the >=30s anti-self-bypass floor is satisfied without sleeping.
    local when
    when="$(python3 -c 'import sys,time;print(time.time()-float(sys.argv[1]))' "$1")"
    python3 -c 'import os,sys;t=float(sys.argv[2]);os.utime(sys.argv[1],(t,t))' \
        "$WORK/.claude/skip-design-review.local" "$when"
}

write_decision() {   # -> gate stdout for a gated implementation Write
    printf '{"tool_name":"Write","cwd":"%s","tool_input":{"file_path":"%s/src/impl.py"}}' "$WORK" "$WORK" \
    | (cd "$WORK" && bash "$GATE") 2>/dev/null
}

# The old gate consumed the skip on the FIRST gated write. The whole point of the
# lease is that the second, third, ... still pass on ONE operator touch.
arm_skip 120
r1="$(write_decision)"; r2="$(write_decision)"; r3="$(write_decision)"
check "lease use 1 allows" allow "$r1"
check "lease use 2 allows (old gate consumed after 1)" allow "$r2"
check "lease use 3 allows" allow "$r3"

# ...and the count is real, not unbounded. Uses are immutable <mtime>.<n> slot dirs:
# a mutable counter would let two concurrent gates both read k and both write k+1,
# silently overshooting the ceiling.
lease_uses() { find "$WORK/.claude/.skip-design-review-lease.d" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' '; }
if [ "$(lease_uses)" = "3" ]; then ok "lease records 3 uses as atomic slots"
else no "lease records 3 uses as atomic slots" "got $(lease_uses)"; fi

# A read-only Bash must NOT spend a use — this is the "any intervening tool call
# burns it" sharp edge the late invocation fixes.
before="$(lease_uses)"
bash_decision "ls -la" >/dev/null
after="$(lease_uses)"
if [ "$before" = "$after" ]; then ok "a read-only command does not spend a lease use"
else no "a read-only command does not spend a lease use" "$before -> $after"; fi

# An EXEMPT write (the design doc itself) must not spend one either.
printf '{"tool_name":"Write","cwd":"%s","tool_input":{"file_path":"%s/docs/plans/thing.md"}}' "$WORK" "$WORK" \
    | (cd "$WORK" && bash "$GATE") >/dev/null 2>&1
after2="$(lease_uses)"
if [ "$before" = "$after2" ]; then ok "an exempt design-doc write does not spend a lease use"
else no "an exempt design-doc write does not spend a lease use" "$before -> $after2"; fi

# Exhaustion: burn the budget, then confirm the next write blocks AND the file is gone.
arm_skip 120
i=0; while [ "$i" -lt 20 ]; do write_decision >/dev/null; i=$((i + 1)); done
check "write 21 blocks (lease exhausted)" block "$(write_decision)"
if [ -f "$WORK/.claude/skip-design-review.local" ]; then no "exhausted lease removes the skip file" "file still present"
else ok "exhausted lease removes the skip file"; fi
# ...but the SLOTS must survive. Deleting them here is a TOCTOU: a concurrent gate that
# already passed the skip-file/mtime checks would mkdir -p a fresh directory, claim slot
# 1 under the same mtime, and be granted a 21st use.
if [ "$(lease_uses)" = "20" ]; then ok "exhausted lease KEEPS its slots (anti-TOCTOU)"
else no "exhausted lease KEEPS its slots (anti-TOCTOU)" "got $(lease_uses)"; fi

# FAIL-CLOSED: if a use cannot be RECORDED it cannot be BOUNDED, so an unwritable
# lease dir must refuse the bypass rather than grant an unlimited one until expiry.
arm_skip 120
rm -rf "$WORK/.claude/.skip-design-review-lease.d"
: >"$WORK/.claude/.skip-design-review-lease.d"          # a plain file: mkdir -p will fail
check "an unrecordable lease refuses the bypass (fail-closed)" block "$(write_decision)"
rm -f "$WORK/.claude/.skip-design-review-lease.d"

# FAIL-CLOSED on an unwritable audit log. The docs promise every lease use is
# recorded; a silent `|| true` would turn an audited hatch into an unaudited one, so
# the promise is enforced rather than merely stated (same rule design-clear.sh applies).
arm_skip 120
mv "$WORK/.claude/bypass-log.jsonl" "$WORK/.claude/bypass-log.bak" 2>/dev/null || true
mkdir -p "$WORK/.claude/bypass-log.jsonl"    # a directory: the append cannot succeed
check "an unloggable lease use refuses the bypass (fail-closed)" block "$(write_decision)"
rmdir "$WORK/.claude/bypass-log.jsonl" 2>/dev/null || true
# NOT asserted here: that the refused use also RETURNS its slot. ADR 0031 promises it
# ("a use whose audit append fails is refused and its slot returned") and the code does
# not do it -- a real prose/behaviour divergence, found by codex during PR #548 and
# deliberately left open rather than fixed here. Three successive attempts at the fix
# each uncovered the next failure rung (an unsynced rmdir, a failed rmdir, a failed
# disarm), and the last review round showed the remaining one is not a durability
# question at all: `append_at` can return false AFTER writing a complete
# `skip-review-consumed` record, so returning the slot then would leave the audit log
# claiming a use that no slot backs -- and post-commit-consume-marker.sh treats a recent
# such event as proof a bypass was sanctioned. Getting that right needs append_at to
# distinguish "definitely did not write" from "may have written", which is a contract
# change to the audit appender, not a patch here. The gate stays fail-CLOSED either way
# (the use is refused); what is wrong is only the budget accounting. Tracked as a
# follow-up.

# A SYMLINKED log must refuse too. A plain `>>` follows symlinks, so pointing the log
# at /dev/null would make the append "succeed" while retaining nothing — the check
# would then read that as proof of a durable record and grant an unlogged lease.
arm_skip 120
ln -sfn /dev/null "$WORK/.claude/bypass-log.jsonl"
check "a symlinked audit log refuses the bypass (fail-closed)" block "$(write_decision)"
rm -f "$WORK/.claude/bypass-log.jsonl"
mv "$WORK/.claude/bypass-log.bak" "$WORK/.claude/bypass-log.jsonl" 2>/dev/null || true

# Expiry: an old file is refused however few uses it has left.
arm_skip 7200
check "an over-age skip file blocks (lease expired)" block "$(write_decision)"
if [ -f "$WORK/.claude/skip-design-review.local" ]; then no "expired lease removes the skip file" "file still present"
else ok "expired lease removes the skip file"; fi

# The >=30s anti-self-bypass floor must survive the change to a lease.
arm_skip 2
check "a just-created skip file is refused (self-bypass floor intact)" block "$(write_decision)"

# ...and the refusal must be reachable ONLY from a genuinely gated operation. The
# rejection-and-poison lives inside _skip_lease_consume, which is invoked once, after
# tool classification and every allowlist -- so a read-only command issued during the
# window never reaches it and cannot destroy the operator's file. That is the recovery
# protocol's load-bearing claim ("wait 35s, do not verify"), and it was documented in
# prose on both sides of the change while only the pre-lease half was ever pinned.
arm_skip 2
check "a read-only command during the window is not gated" allow "$(bash_decision "ls -la")"
if [ -f "$WORK/.claude/skip-design-review.local" ]; then
    ok "a read-only command does not destroy a young skip file"
else
    no "a read-only command does not destroy a young skip file" "the gate consumed it"
fi
# The floor still bites the moment a gated operation arrives, young file and all.
check "the floor still refuses the young file on a real write" block "$(write_decision)"

# The ledger is what BOUNDS the lease, so it is gate state like the skip file itself.
# Unprotected, the agent could spend one use on `rm -rf <ledger>` and reset the ceiling
# to zero — an unbounded lease that merely looks bounded.
check "deleting the lease ledger is blocked" block \
    "$(bash_decision "rm -rf .claude/.skip-design-review-lease.d")"
check "redirecting into the lease ledger is blocked" block \
    "$(bash_decision "echo x > .claude/.skip-design-review-lease.d/1")"
# Hardening the APPEND is worth nothing if the FILE can be erased for free — writes
# under $STATE_DIR are otherwise SAFE and a bare rm of one hits the F9 exemption.
check "deleting the bypass audit log is blocked" block \
    "$(bash_decision "rm -f .claude/bypass-log.jsonl")"
check "truncating the bypass audit log is blocked" block \
    "$(bash_decision "echo x > .claude/bypass-log.jsonl")"
check "READING the bypass audit log is still allowed" allow \
    "$(bash_decision "cat .claude/bypass-log.jsonl")"
# truncate/unlink erase content with an ordinary bare command and were in neither the
# old regexes nor the forge detector, so they could wipe the trail for free.
check "truncate on the audit log is blocked" block \
    "$(bash_decision "truncate -s 0 .claude/bypass-log.jsonl")"
check "unlink on the audit log is blocked" block \
    "$(bash_decision "unlink .claude/bypass-log.jsonl")"
# Wrapper-hidden destruction. The forge detector matched only the RAW first word, so
# these slipped past it while the classifier still called them modifications — and the
# F9 state-directory exemption then allowed them through.
check "command-wrapped rmdir of a lease slot is blocked" block \
    "$(bash_decision "command rmdir .claude/.skip-design-review-lease.d/1.1")"
check "env-wrapped truncate of the audit log is blocked" block \
    "$(bash_decision "env truncate -s 0 .claude/bypass-log.jsonl")"
check "sudo-wrapped unlink of the audit log is blocked" block \
    "$(bash_decision "sudo unlink .claude/bypass-log.jsonl")"
# A QUOTED verb inside an executed string — the inner shell strips those quotes, so the
# detector must too. Needs a json.dumps-built payload, hence this suite rather than the
# printf-based harness in test-pre-implementation-gate.sh.
check "env -S with a quoted verb is blocked" block \
    "$(bash_decision 'env -S "\"truncate\" -s 0 .claude/bypass-log.jsonl"')"
check "dd blanking the audit log is blocked" block \
    "$(bash_decision "dd if=/dev/null of=.claude/bypass-log.jsonl")"
# The EMBEDDED-verb pattern must cover every name treated as an indirect verb.
# time/script/flock were listed as verbs but left out of the embedded pattern, so the
# one shape it exists for — the whole program inside a single token — let them past.
check "env -S with an embedded script is blocked" block \
    "$(bash_decision "env -S 'script .claude/bypass-log.jsonl'")"
check "env -S with an embedded flock is blocked" block \
    "$(bash_decision "env -S 'flock .claude/bypass-log.jsonl true'")"
check "env -S with an embedded time -o is blocked" block \
    "$(bash_decision "env -S 'time -o .claude/bypass-log.jsonl true'")"
# rmdir on a spent slot would let it be reclaimed, extending the ceiling indefinitely.
check "rmdir on a spent lease slot is blocked" block \
    "$(bash_decision "rmdir .claude/.skip-design-review-lease.d/1.1")"

echo "── item 2: block message points at the audited release path ────────"

rm -f "$WORK/.claude/skip-design-review.local"; rm -rf "$WORK/.claude/.skip-design-review-lease.d"
MSG="$(write_decision)"
case "$MSG" in
    *design-clear.sh*) ok "block message names design-clear.sh" ;;
    *) no "block message names design-clear.sh" "hint missing" ;;
esac
case "$MSG" in
    *"drain if abandoned: rm "*) no "block message no longer invites a bare rm" "rm hint still present" ;;
    *) ok "block message no longer invites a bare rm" ;;
esac

echo "── item 2: the release RECORDS what residual was accepted ─────────"

# The point of routing operators to design-clear.sh instead of `rm` is that the
# trail survives the release. A doc approved under DEGRADED coverage keeps its PASS
# withheld (#355), so a release is the only way forward — and the event must name
# the coverage that was accepted, or the record does not answer the question #519
# asked ("which lenses were absent, and who accepted the residual").
CLEARWORK="$(mktemp -d)" || CLEARWORK=""
if [ -z "$CLEARWORK" ] || [ ! -d "$CLEARWORK" ]; then
    no "clear event records the DEGRADED coverage it released" "no temp dir"
    printf "\n%d passed, %d failed\n" "$PASS" "$FAIL"; exit 1
fi
git -C "$CLEARWORK" init -q 2>/dev/null
git -C "$CLEARWORK" config user.email t@t.t
git -C "$CLEARWORK" config user.name t
mkdir -p "$CLEARWORK/docs/plans"
printf '# plan\n<!-- design-review-coverage: DEGRADED 1/3 (reviewer_2=runtime-failed) -->\n' \
    >"$CLEARWORK/docs/plans/p.md"
bash "$REPO_ROOT/hooks/gate-scripts/lib/resolve-repo-dir.sh" arm "$CLEARWORK/docs/plans/p.md" >/dev/null 2>&1
(cd "$CLEARWORK" && bash "$REPO_ROOT/scripts/design-clear.sh" "$CLEARWORK/docs/plans/p.md" --yes) >/dev/null 2>&1
EVT="$(tail -1 "$CLEARWORK/.claude/bypass-log.jsonl" 2>/dev/null || true)"
case "$EVT" in
    *'"coverage"'*DEGRADED*) ok "clear event records the DEGRADED coverage it released" ;;
    *) no "clear event records the DEGRADED coverage it released" "got: ${EVT:-<no event>}" ;;
esac
# ...and still records HOW it was authorized, which the coverage field must not displace.
case "$EVT" in
    *'"confirmed"'*) ok "clear event still records how the release was authorized" ;;
    *) no "clear event still records how the release was authorized" "field missing" ;;
esac
rm -rf "$CLEARWORK"

echo "── the mutating helpers are not callable from Bash ───────────────"

# lease_slot.py and audit_append.py MUTATE gate state, and neither needs to name a
# protected path or a modification verb to do it — so nothing else in the detector
# would notice. Unguarded they are bypass primitives: a fabricated mtime prunes the
# genuine slots (resetting the ceiling), and an arbitrary record forges audit events.
check "direct lease_slot.py invocation is blocked" block \
    "$(bash_decision "python3 -I hooks/gate-scripts/lib/lease_slot.py .claude fake 1")"
check "direct audit_append.py invocation is blocked" block \
    "$(bash_decision "python3 -I hooks/gate-scripts/lib/audit_append.py .claude '{\"forged\":1}'")"
# ...but --self-check stays callable: temp dir only, mutates no real state, and the
# test suite below invokes it through Bash.
check "helper --self-check stays allowed" allow \
    "$(bash_decision "python3 -I hooks/gate-scripts/lib/lease_slot.py --self-check")"
# `-m` runs the helper without ever naming the FILE, and `-m` was on the list of flags
# whose operand is skipped as an option value.
check "python3 -m running the helper is blocked" block \
    "$(bash_decision 'PYTHONPATH=hooks/gate-scripts/lib python3 -m lease_slot .claude 999 0 3600')"
check "the attached -m spelling is blocked" block \
    "$(bash_decision 'python3 -mlease_slot .claude 999 0 3600')"
check "a dotted module path to the helper is blocked" block \
    "$(bash_decision 'python3 -m gate.lib.audit_append')"
check "-m on an unrelated module stays allowed" allow \
    "$(bash_decision 'python3 -m json.tool file.json')"
# CPython accepts -m inside a short-flag CLUSTER, both spaced and attached.
check "a clustered -Bm running the helper is blocked" block \
    "$(bash_decision 'python3 -Bm lease_slot .claude 999 0 3600')"
check "a clustered attached -Bmlease_slot is blocked" block \
    "$(bash_decision 'python3 -Bmlease_slot .claude 999')"
check "the long --module spelling is blocked" block \
    "$(bash_decision 'python3 --module audit_append .claude')"
check "a clustered -B before an unrelated -m stays allowed" allow \
    "$(bash_decision 'python3 -B -m pytest tests/')"
# A short-option CLUSTER stops at the first option that takes an operand: `-Wm` is
# `-W m`, NOT a module switch. Reading the `m` as one skipped the script behind it.
check "-Wm does not shadow the script it precedes" block \
    "$(bash_decision 'python3 -Wm hooks/gate-scripts/lib/lease_slot.py .claude 999 0 3600')"
check "-Xm does not shadow the script it precedes" block \
    "$(bash_decision 'python3 -Xm hooks/gate-scripts/lib/audit_append.py .claude')"
check "-Wm before an unrelated script stays allowed" allow \
    "$(bash_decision 'python3 -Wm tools/report.py --out /dev/null')"
# A GLOB in script position is resolved by the shell, so the question is whether the
# PATTERN can name a helper — searching the text for a helper stem cannot answer it.
check "a glob that can expand to the helper is blocked" block \
    "$(bash_decision 'python3 hooks/gate-scripts/lib/lease_slo?.py .claude 999 0 3600')"
check "a star glob over the helper directory is blocked" block \
    "$(bash_decision 'python3 hooks/gate-scripts/lib/audit_*.py .claude')"
check "a glob that cannot name a helper stays allowed" allow \
    "$(bash_decision 'python3 tools/repor?.py --out /dev/null')"
# Bash accepts SHORT \u escapes (1-4 digits); Python unicode_escape demands four, so
# the old decoder passed `$'\u73'` through untouched and the name never resolved.
_SQ_="'"
check "a short \\u escape in the module name is blocked" block \
    "$(bash_decision "python3 -m lease_\$$_SQ_\\u73${_SQ_}lot .claude 999 0 3600")"
check "a short \\u escape in a git verb is blocked" block \
    "$(bash_decision "g\$$_SQ_\\u69${_SQ_}t clean -fd")"
check "an octal escape in a git verb is blocked" block \
    "$(bash_decision "g\$$_SQ_\\151${_SQ_}t clean -fd")"
# The SWITCH and the INTERPRETER are tokens too, so both can arrive still encoded.
check "an escaped -m switch is blocked" block \
    "$(bash_decision "python3 -\$$_SQ_\\x6d${_SQ_} lease_slot .claude 999 0 3600")"
check "an escaped interpreter name is blocked" block \
    "$(bash_decision "p\$$_SQ_\\x79${_SQ_}thon3 -m lease_slot .claude 999")"
# CPython stops parsing options at -c and -m: what follows is argv, not a second
# module and not a script. Walking past them blocked ordinary READS of the helper.
check "argv after -c that names the helper stays allowed" allow \
    "$(bash_decision "python3 -c 'pass' -m lease_slot")"
# TIGHTENED. This previously asserted `allow`, on the reasoning that json.tool only reads
# its operand. The module NAME is not evidence of that: for -m, CPython puts the current
# directory on sys.path, and this gate runs with its CWD inside the repo it is gating, so
# a repo-root `json/` package makes json.tool whatever the repo says it is -- no
# PYTHONPATH required. Consent authenticated by content the gated party controls is the
# shape ADR 0016 / #325 rejects. The read-only allowlist now counts only under isolated
# mode, which is what actually drops the CWD from the search path.
check "a bare -m json.tool naming the helper is blocked (name is not evidence)" block \
    "$(bash_decision 'python3 -m json.tool hooks/gate-scripts/lib/lease_slot.py')"
check "the same read under isolated mode is allowed" allow \
    "$(bash_decision 'python3 -I -m json.tool hooks/gate-scripts/lib/lease_slot.py')"
check "-P alone is enough, since it is the flag that drops CWD" allow \
    "$(bash_decision 'python3 -P -m json.tool hooks/gate-scripts/lib/lease_slot.py')"
check "a PYTHONPATH-shadowed read-only module is blocked" block \
    "$(bash_decision 'PYTHONPATH=/tmp/evil python3 -m json.tool hooks/gate-scripts/lib/lease_slot.py')"
check "a script after -- is still resolved" block \
    "$(bash_decision 'python3 -- hooks/gate-scripts/lib/lease_slot.py .claude 999 0 3600')"
# ── generated: the -m module shape across cluster x binding x operand ─
_MM_FAIL=0 _MM_PASS=0
_mm() {  # <expected> <command>
    local got="allow"
    case "$(bash_decision "$2")" in *'"block"'*) got="block" ;; esac
    if [[ "$got" == "$1" ]]; then _MM_PASS=$((_MM_PASS + 1))
    else _MM_FAIL=$((_MM_FAIL + 1)); printf "  FAIL  -m: %s (want %s)\n" "$2" "$1"; fi
}
for flag in -m -Bm -BSm --module; do
    for mod in lease_slot audit_append gate.lib.lease_slot; do
        _mm block "python3 $flag $mod .claude 999 0 3600"          # spaced operand
        _mm block "M=$mod; python3 $flag \"\$M\" .claude 999"      # expanded at run time
        # ANSI-C escapes are DECODED by the shell, so the name is assembled from hex.
        _mm block "python3 $flag ${mod%?}\$'$(printf '%s' "\\x$(printf '%x' "'${mod: -1}")")' .claude" 
        [[ "$flag" == "--module" ]] && continue                    # long form takes no tail
        _mm block "python3 $flag$mod .claude 999"                  # attached to the cluster
    done
    # ...and an unrelated module keeps the same spellings allowed.
    _mm allow "python3 $flag pytest tests/"
done
# Every token bash resolves can arrive ENCODED, not just the operand: the interpreter
# name, the switch, and the module. Encoding only the operand is what let an escaped
# `-m` through, so each position is exercised in turn, in each escape width bash takes.
for _esc in '\x6d' '\u6d' '\155'; do
    _mm block "python3 -\$$_SQ_$_esc${_SQ_} lease_slot .claude 999 0 3600"
done
for _esc in '\x79' '\u79' '\171'; do
    _mm block "p\$$_SQ_$_esc${_SQ_}thon3 -m lease_slot .claude 999 0 3600"
    _mm allow "p\$$_SQ_$_esc${_SQ_}thon3 -m pytest tests/"
done
for _esc in '\x73' '\u73' '\163'; do
    _mm block "python3 -m lease_\$$_SQ_$_esc${_SQ_}lot .claude 999 0 3600"
done
if [[ "$_MM_FAIL" -eq 0 ]]; then
    ok "no -m spelling reaches a mutating helper ($_MM_PASS spellings)"
else
    no "-m module spellings" "$_MM_FAIL of $((_MM_PASS + _MM_FAIL)) wrong"
fi
# ── generated: word-concatenation on an UNPARSEABLE command ──────────
# The fallback exists for commands that will not tokenize, so the quote structure it is
# handed is broken by definition. Quotes AND backslashes are the characters bash removes
# before it resolves the command word, so the fallback runs on a squeezed copy too.
_WC_FAIL=0 _WC_PASS=0
for verb in 'g"it" clean -fd' "g'it' clean -fd" 'g\it clean -fd' \
            'r"m" -rf src' "r'm' -rf src" 'r\m -rf src' \
            '"git" clean -fd' '\git clean -fd' \
            "g''it clean -fd" '$'"'"'g'"'"'it clean -fd' \
            "$(printf 'g\\\nit clean -fd')"; do
    # An apostrophe in the heredoc body is the #365 shape that forces the fallback.
    _cmd="$(printf '%s <<EOF\nthe operator%ss note\nEOF' "$verb" "'")"
    got="allow"
    case "$(bash_decision "$_cmd")" in *'"block"'*) got="block" ;; esac
    if [[ "$got" == "block" ]]; then _WC_PASS=$((_WC_PASS + 1))
    else _WC_FAIL=$((_WC_FAIL + 1)); printf "  FAIL  concat: %s\n" "$verb"; fi
done
if [[ "$_WC_FAIL" -eq 0 ]]; then
    ok "word-concatenated verbs block on the fallback path ($_WC_PASS spellings)"
else
    no "word-concatenated verbs" "$_WC_FAIL of $((_WC_PASS + _WC_FAIL)) allowed"
fi
# THE FALLBACK MUST BE WIDER than the classifier it stands in for, asserted in the
# module self-check rather than claimed in prose -- and proven to FAIL without the git
# pattern, since a guard whose failure branch is never observed is not a guard.
_FB="$(python3 - <<'PY' 2>&1
import sys
sys.path.insert(0, "hooks/gate-scripts/lib")
import cmdword as c
c.FILE_MOD_PATTERNS = [p for p in c.FILE_MOD_PATTERNS if p != r"\bgit\s"]
try:
    c._demo()
except AssertionError:
    print("FIRES")
PY
)"
case "$_FB" in
    *FIRES*) ok "the fallback-superset invariant fails without the git pattern" ;;
    *) no "the fallback-superset invariant" "did not fire with the git pattern removed" ;;
esac
# The guard is TOKEN-level: a raw substring test was defeated by quote concatenation,
# and a whole-string --self-check exemption was satisfied by a trailing no-op segment
# while the FIRST segment mutated the real ledger.
check "quote-concatenated helper name is blocked" block \
    "$(bash_decision 'python3 -I hooks/gate-scripts/lib/lease_"slot.py" .claude fake 1')"
check "trailing --self-check in another segment does not exempt" block \
    "$(bash_decision "python3 -I hooks/gate-scripts/lib/lease_slot.py .claude fake 1; : --self-check")"
# bash treats this as a COMMENT; the parser (commenters disabled) tokenizes it, so an
# any-token exemption let the real, mutating invocation through.
check "commented --self-check does not exempt" block \
    "$(bash_decision "python3 -I hooks/gate-scripts/lib/lease_slot.py .claude fake 1 # --self-check")"
# ...and merely NAMING a helper is an ordinary read.
check "cat of a helper is allowed" allow \
    "$(bash_decision "cat hooks/gate-scripts/lib/lease_slot.py")"
check "git diff naming a helper is allowed" allow \
    "$(bash_decision "git diff -- hooks/gate-scripts/lib/audit_append.py")"
check "echo naming a helper is allowed" allow "$(bash_decision "echo lease_slot.py")"
# A wrapper flag OPERAND hid the interpreter from a command-word anchor.
check "env -u wrapper before the helper is blocked" block \
    "$(bash_decision "env -u FOO python3 -I hooks/gate-scripts/lib/lease_slot.py .claude fake 1")"
check "sudo -u wrapper before the helper is blocked" block \
    "$(bash_decision "sudo -u root python3 -I hooks/gate-scripts/lib/lease_slot.py .claude fake 1")"
# ...and the helper as an ARGUMENT to another script is not the executed one.
check "helper passed as an arg to another script is allowed" allow \
    "$(bash_decision "python3 safe.py lease_slot.py")"
check "helper in a comment after python -c is allowed" allow \
    "$(bash_decision "python3 -c 'print(1)' # lease_slot.py")"
check "echo naming python and a helper is allowed" allow \
    "$(bash_decision "echo python3 lease_slot.py")"
# A payload handed to find -exec / env -S / sh -c is executed just as surely as the top
# level, so the guard follows those too.
check "find -exec running the helper is blocked" block \
    "$(bash_decision "find . -maxdepth 0 -exec python3 -I hooks/gate-scripts/lib/lease_slot.py .claude fake 1 ;")"
check "env -S running the helper is blocked" block \
    "$(bash_decision "env -S 'python3 -I hooks/gate-scripts/lib/lease_slot.py .claude fake 1'")"
check "sh -c running the helper is blocked" block \
    "$(bash_decision "sh -c 'python3 -I hooks/gate-scripts/lib/audit_append.py .claude {}'")"
# `watch` with a QUOTED payload. This one SHIPPED as a hole: watch was taught to the
# file-mod classifier without a matching payload extraction in the helper guard, so the
# quoted spelling reached the helper unseen while sh -c, env -S, find -exec and even
# UNQUOTED watch were all caught. The unquoted control is here deliberately -- it passed
# throughout, so testing only that spelling would have certified a guard with a hole in it.
check "watch running the helper is blocked (unquoted control)" block \
    "$(bash_decision "watch python3 -I hooks/gate-scripts/lib/lease_slot.py .claude 20 30 3600")"
check "watch with a QUOTED helper payload is blocked" block \
    "$(bash_decision "watch 'python3 -I hooks/gate-scripts/lib/lease_slot.py .claude 20 30 3600'")"
check "watch -n with a quoted helper payload is blocked" block \
    "$(bash_decision "watch -n 1 'python3 -I hooks/gate-scripts/lib/lease_slot.py .claude 20 30 3600'")"
# An option this list has never heard of must not shift where the payload is found --
# the whole reason neither watch rule keeps an option-arity table.
check "watch with an unknown value-taking option still finds the helper" block \
    "$(bash_decision "watch --some-future-option val 'python3 -I hooks/gate-scripts/lib/lease_slot.py .claude 20 30 3600'")"
# WHITESPACE PADDING. This defeated the FIRST fix here, which scanned tokens individually
# and skipped any that was not multi-word: ` python3` is one word plus a leading space, so
# it was skipped, while the shell ignores the space and runs it. The padding is
# attacker-chosen, so both spellings are pinned rather than trusting a whitespace list.
check "watch hiding the runner in a space-padded token is blocked" block \
    "$(bash_decision "watch -- ' python3' -I hooks/gate-scripts/lib/lease_slot.py .claude 20 30 3600")"
check "watch hiding a space-padded shell before the helper is blocked" block \
    "$(bash_decision "watch -- ' sh' -c 'python3 -I hooks/gate-scripts/lib/lease_slot.py .claude 20 30 3600'")"
# ...and the recursion must not turn NAMING a helper into invoking it. The payload is
# re-classified as its own command, so a read that merely mentions the path stays a read.
check "watch of a read that merely NAMES the helper is allowed" allow \
    "$(bash_decision "watch 'grep -n x hooks/gate-scripts/lib/lease_slot.py'")"
# The SEPARATE-ARGV spelling over-blocks, DELIBERATELY. Resolving the command word inside
# a watch invocation without an option-arity table means treating each argument position as
# a possible start, which necessarily promotes operands too -- so a bare helper pathname
# reads as an invocation. Five narrower rules were measured and each was fail-OPEN instead;
# the trade is the same one already made two blocks down for `echo -exec sh -c <helper>`.
# Pinned so the over-block stays a decision rather than becoming a surprise.
check "watch NAMING the helper as separate argv over-blocks (deliberate)" block \
    "$(bash_decision "watch grep -n x hooks/gate-scripts/lib/lease_slot.py")"
check "watch cat NAMING the helper as separate argv over-blocks (deliberate)" block \
    "$(bash_decision "watch cat hooks/gate-scripts/lib/lease_slot.py")"
# (The QUOTED spelling of that same read stays allowed -- asserted just above. There the
# payload is one token and needs no position guessing, so the over-block is the price of
# the argv spelling only, not of watching a read in general.)
# The spelling that motivated the whole trade: a value-taking option whose value displaces
# the command word, with a space-padded runner behind it. Fail-open in every narrower rule.
check "watch with an option VALUE before a padded runner is blocked" block \
    "$(bash_decision "watch --shotsdir logs ' python3' -I hooks/gate-scripts/lib/lease_slot.py .claude 20 30 3600")"
# Enough repeated value-taking options to push the payload past any FIXED candidate cap.
# An earlier draft capped candidates at twelve positions and stopped there SILENTLY, which
# is a fail-open wearing a limit: the search simply never reached the command. The bound is
# now the shared token budget, and draining it makes every emitted payload fail CLOSED.
check "watch payload beyond a fixed candidate cap is still blocked" block \
    "$(bash_decision "watch --shotsdir log0 --shotsdir log1 --shotsdir log2 --shotsdir log3 --shotsdir log4 --shotsdir log5 'python3 -I hooks/gate-scripts/lib/lease_slot.py .claude 20 30 3600'")"
# A command SPLIT ACROSS arguments. watch concatenates before handing to sh -c, so neither
# `>` nor `src/file` classifies alone while the pair truncates the file. This is why the
# classifier scans the join as well as each argument.
check "watch with a redirect split across arguments is blocked" block \
    "$(bash_decision "watch '>' src/file")"
# NESTED payloads: a runner inside a find -exec. The payload tokens are requoted before
# the recursive scan, because a bare space-join loses the boundary the quoted `-c` string
# carried -- `sh -c "python3 -I .../lease_slot.py ..."` re-lexed as `sh -c python3 -I
# .../lease_slot.py ...`, whose -c handler reads only `python3` as the program and never
# scans the helper demoted to $0/$1.
check "find -exec sh -c running the helper is blocked" block \
    "$(bash_decision "find . -maxdepth 0 -exec sh -c 'python3 -I hooks/gate-scripts/lib/lease_slot.py .claude 20 30 3600' {} ;")"
check "find -exec env -S sh -c running the helper is blocked" block \
    "$(bash_decision "find . -maxdepth 0 -exec env -S sh -c 'python3 hooks/gate-scripts/lib/lease_slot.py .claude 20 30 3600' ;")"
check "a helper after a ; INSIDE a find -exec payload is blocked" block \
    "$(bash_decision "find . -maxdepth 0 -exec bash -c 'cd /tmp && python3 hooks/gate-scripts/lib/lease_slot.py .claude 20 30 3600' ;")"
# ...and requoting must not over-block a payload that merely NAMES one.
check "find -exec sh -c echoing a helper name is allowed" allow \
    "$(bash_decision "find . -maxdepth 0 -exec sh -c 'echo lease_slot.py' ;")"
# A RUNNER NAMED IN AN ARGUMENT LIST IS DATA. Both payload scans used to fire at any
# index, so printing a command that would invoke a helper counted as invoking it.
# `-exec` now needs the segment to actually run find (it is a find predicate, not a
# general convention), and a shell/env runner needs to still be in the wrapper preamble.
check "echo of a find -exec helper payload over-blocks (documented)" block \
    "$(bash_decision "echo -exec sh -c 'python3 -I hooks/gate-scripts/lib/lease_slot.py .claude 20 30 3600' ';'")"
check "echo of an sh -c helper payload over-blocks (documented)" block \
    "$(bash_decision "echo sh -c 'python3 hooks/gate-scripts/lib/lease_slot.py .claude 20 30 3600'")"
# The mention contract still holds for a plain read -- these are the cases that matter.
check "cat of a helper stays allowed" allow \
    "$(bash_decision "cat hooks/gate-scripts/lib/lease_slot.py")"
# ...while every genuine preamble spelling still executes, and still blocks.
check "nohup wrapper before sh -c is blocked" block \
    "$(bash_decision "nohup sh -c 'python3 hooks/gate-scripts/lib/lease_slot.py .claude 20 30 3600'")"
check "a leading assignment before bash -c is blocked" block \
    "$(bash_decision "X=1 bash -c 'python3 hooks/gate-scripts/lib/lease_slot.py .claude 20 30 3600'")"
check "sudo env -S running the helper is blocked" block \
    "$(bash_decision "sudo env -S 'python3 hooks/gate-scripts/lib/lease_slot.py .claude 20 30 3600'")"
# ash and mksh were in cmdword._SHELLS but missing from the gate's own list, so their
# -c payload walked straight past the helper guard. `watch` was missing from BOTH wrapper
# lists, so `watch --exec rm -rf src` resolved to `watch` and read as an observation.
check "ash -c running the helper is blocked" block \
    "$(bash_decision "ash -c 'python3 -I hooks/gate-scripts/lib/lease_slot.py .claude 20 0 3600'")"
check "mksh -c running the helper is blocked" block \
    "$(bash_decision "mksh -c 'python3 hooks/gate-scripts/lib/lease_slot.py .claude 20 0 3600'")"
check "watch --exec hiding rm is blocked" block \
    "$(bash_decision "watch --exec rm -rf src")"
check "watch of a read stays allowed" allow "$(bash_decision "watch ls -la")"
# SUBCOMMAND DISPATCHERS: `git rm` / `git mv` really do delete and rename working-tree
# files, but the verb sits one token in, so a command-word test read it as data. The raw
# regexes this replaced matched the literal `rm `, so missing it was a fail-open.
check "git rm is a write" block "$(bash_decision "git rm src/x")"
check "git mv is a write" block "$(bash_decision "git mv a b")"
check "git clean is a write" block "$(bash_decision "git clean -fd")"
check "git restore is a write" block "$(bash_decision "git restore .")"
check "git checkout -- is a write" block "$(bash_decision "git checkout -- .")"
# ...looked up at its POSITION, so the read subcommands stay reads.
check "git status stays a read" allow "$(bash_decision "git status")"
check "git log stays a read" allow "$(bash_decision "git log --oneline")"
check "git log --grep rm stays a read" allow "$(bash_decision "git log --grep rm")"
check "git diff naming rm.py stays a read" allow "$(bash_decision "git diff -- rm.py")"
check "echo of git rm stays a read" allow "$(bash_decision "echo git rm x")"
check "git rm inside bash -c is a write" block "$(bash_decision "bash -c 'git rm x'")"
# A dispatcher BEHIND A WRAPPER never reached the positional lookup, because the wrapped
# branch returns first. In that regime the subcommand is matched by scan, like every
# other token.
check "sudo git clean is a write" block "$(bash_decision "sudo git clean -fd")"
check "env git stash is a write" block "$(bash_decision "env git stash")"
# The dispatcher is matched on BASENAME, and its global flag OPERANDS are skipped so they
# are not mistaken for the subcommand.
check "an absolute git path is still a dispatcher" block \
    "$(bash_decision "/usr/bin/git rm x")"
check "git -C repo rm is a write" block "$(bash_decision "git -C repo rm x")"
check "git --git-dir <dir> clean is a write" block \
    "$(bash_decision "git --git-dir repo/.git clean -fd")"
check "git -C repo status stays a read" allow "$(bash_decision "git -C repo status")"
# ...and the set covers the other working-tree writers, not just rm/mv.
check "git reset --hard is a write" block "$(bash_decision "git reset --hard")"
check "git switch is a write" block "$(bash_decision "git switch main")"
check "git apply is a write" block "$(bash_decision "git apply patch.diff")"
check "git merge is a write" block "$(bash_decision "git merge topic")"
check "git clone is a write" block "$(bash_decision "git clone https://x /tmp/y")"
check "git worktree add is a write" block "$(bash_decision "git worktree add ../w")"
check "git submodule update is a write" block \
    "$(bash_decision "git submodule update --init")"
# A leading ASSIGNMENT whose value basenames to the dispatcher must not be matched as the
# dispatcher itself, or the subcommand is read from the wrong position.
check "an assignment shadowing the dispatcher name is not the dispatcher" block \
    "$(bash_decision "GIT_DIR=/tmp/git git rm x")"
# BOTH regimes live in _runs_mod_verb, so a find -exec payload is judged like a top-level
# command. The wrapped-dispatcher rule used to exist only on the segment path.
check "find -exec sudo git clean is a write" block \
    "$(bash_decision "find . -exec sudo git clean -fd ;")"
check "find -exec env git stash is a write" block \
    "$(bash_decision "find . -exec env git stash ;")"
# THE SUBCOMMAND LIST IS OF READS, NOT WRITES. Listing the writers is an allowlist in a
# fail-CLOSED gate: anything unrecognised reads as safe, so an alias, an external
# git-<helper>, and a redirection token landing where the subcommand was expected all
# sailed through. Inverted, the unknown case blocks.
check "a git alias running a shell is a write" block \
    "$(bash_decision "git -c alias.nuke='!rm -rf src' nuke")"
check "a redirection before the subcommand does not hide it" block \
    "$(bash_decision "git </dev/null clean -fd")"
check "an unknown git subcommand is a write" block \
    "$(bash_decision "git some-unknown-subcmd")"
# ...and a listed READ that is told to produce a file is still a write.
check "git diff --output= is a write" block \
    "$(bash_decision "git diff --output=src/x")"
check "git diff -o is a write" block "$(bash_decision "git diff -o src/x")"
# NO `--no-index` SPELLING IS A READ, in any combination. Treating it as one was tried
# in PR #548 and abandoned after three rungs: bare `--no-index` lets a configured
# `diff.external` driver run; gating it behind `--no-ext-diff` closes only EXTERNAL
# DRIVERS, while git separately enables TEXTCONV by default for no-index diffs, so
# repository attributes plus `diff.<driver>.textconv` still execute a configured
# command. Pinned as a BLOCK in both spellings so a future attempt has to defeat this
# line deliberately, and has to enumerate every git mechanism that can run a configured
# program from a diff rather than only the one the last report happened to name.
check "git diff --no-index is a write (diff.external can fire)" block \
    "$(bash_decision "git diff --no-index a b")"
check "...and --no-ext-diff does not redeem it (textconv still runs)" block \
    "$(bash_decision "git diff --no-index --no-ext-diff a b")"
# The reads that matter day to day must stay reads.
check "git add stays a read" allow "$(bash_decision "git add -A")"
check "git push stays a read" allow "$(bash_decision "git push")"
check "git show stays a read" allow "$(bash_decision "git show HEAD")"
check "git diff --stat stays a read" allow "$(bash_decision "git diff --stat")"
check "bare git stays a read" allow "$(bash_decision "git")"
check "sudo git status stays a read" allow "$(bash_decision "sudo git status")"
# The subcommand is located POSITIONALLY in BOTH regimes. Scanning for a read name
# anywhere let a PATHSPEC vouch for the command, and skipped the writeflag check.
check "a pathspec named like a read subcommand does not vouch" block \
    "$(bash_decision "sudo git clean -fd status")"
check "wrapped git diff --output= is a write" block \
    "$(bash_decision "sudo git diff --output=src/x")"
# A LEADING REDIRECTION is legal shell; resolving the command word to `<` allowed the
# write behind it.
check "a leading redirection does not hide the command word" block \
    "$(bash_decision "</dev/null git clean -fd")"
check "a leading fd redirection does not hide it either" block \
    "$(bash_decision "2>/dev/null git rm x")"
# A read subcommand has to be read-only in EVERY mode, not just its common one.
check "git config --file is a write" block \
    "$(bash_decision "git config --file src/x k v")"
check "git bundle create is a write" block \
    "$(bash_decision "git bundle create src/x HEAD")"
# ...and a read that is handed an external PROGRAM to run is a write of whatever that
# program touches. THE OPTION LIST IS OF INERT OPTIONS: listing the dangerous ones was
# tried and never finished (`--output`, `-c`, `--paginate`, `--textconv`, `--filters`,
# and the joined `-ccore.x=y` that no exact match catches), because git's exec surface is
# config-driven and unbounded. Unrecognised is not cleared.
check "git -c setting an external diff command is a write" block \
    "$(bash_decision "git -c diff.x.command='rm -rf src' diff --ext-diff")"
check "git -c is a write on its own" block \
    "$(bash_decision "git -c core.pager='rm -rf src' log")"
check "difftool is not a read" block "$(bash_decision "git difftool")"
check "difftool --extcmd is a write" block \
    "$(bash_decision "git difftool --extcmd='rm -rf src'")"
check "wrapped git -c is a write" block \
    "$(bash_decision "sudo git -c core.pager='rm -rf src' log")"
check "git grep -O is a write" block "$(bash_decision "git grep -O rm pattern")"
check "git log --ext-diff is a write" block \
    "$(bash_decision "git log --ext-diff")"
# An ASSIGNMENT PREFIX is the same config channel by another route.
check "GIT_EXTERNAL_DIFF= before git is a write" block \
    "$(bash_decision "GIT_EXTERNAL_DIFF='rm -rf src' git diff --ext-diff")"
check "any assignment before git is a write" block \
    "$(bash_decision "GIT_PAGER=cat git log")"
# An OPTION token carrying an expansion has no fixed spelling to match, so it cannot be
# cleared. A token that is WHOLLY an expansion is read as an operand -- documented
# residual: it is indistinguishable from `git diff "\$FILE"`, which must stay a read.
check "an expansion inside an option token is a write" block \
    "$(bash_decision 'git diff --ext${EMPTY}-diff')"
check "an expansion inside a global option NAME is a write" block \
    "$(bash_decision 'git --pag${E}inate log')"
# An expansion in an option VALUE is cleared when the NAME is inert: `--git-dir` selects
# a directory, not a program, whatever the path turns out to be.
check "an expansion in an inert option value stays a read" allow \
    "$(bash_decision 'git --git-dir=${D} log')"
check "an expansion as a plain operand stays a read" allow \
    "$(bash_decision 'git diff "$FILE"')"
check "an expansion as a -C operand stays a read" allow \
    "$(bash_decision 'git -C "$repo" status')"
# OPTIONS ARE SCANNED IN THEIR OWN REGION. One list scanned over every token conflated
# the global `-c key=val` with the subcommand `git grep -c`, and read the pathspec in
# `git diff -- --tool` as an option.
check "git grep -c is a count, not config injection" allow \
    "$(bash_decision "git grep -c pattern")"
check "a pathspec after -- is not an option" allow \
    "$(bash_decision "git diff -- --tool")"
check "a pathspec after -- is not a writeflag either" allow \
    "$(bash_decision "git diff -- --output=x")"
check "git init writes the tree it is given" block \
    "$(bash_decision "git init src/generated")"
# A REDIRECT inside an executed string is a write. The caller's own redirect check
# strips single-quoted text first, which is exactly where a payload lives.
check "a redirect inside bash -c is a write" block \
    "$(bash_decision "bash -c 'printf hi > src/impl.py'")"
check "a redirect inside eval is a write" block \
    "$(bash_decision "eval 'echo hi > src/impl.py'")"
check "an append inside sh -c is a write" block \
    "$(bash_decision "sh -c 'cat a >> src/b'")"
check "a redirect inside a wrapped payload is a write" block \
    "$(bash_decision "sudo -u root bash -c 'printf hi > src/impl.py'")"
check "a payload redirect to /dev/null stays a read" allow \
    "$(bash_decision "bash -c 'grep x file 2>/dev/null'")"
check "a payload fd duplication stays a read" allow \
    "$(bash_decision "bash -c 'diff a b 2>&1'")"
# `<>` opens for reading AND writing, and creates the file. The write then happens
# through a descriptor, where `>&3` is indistinguishable from an ordinary fd dup.
check "a read-write redirect inside a payload is a write" block \
    "$(bash_decision "bash -c 'exec 3<>src/impl.py; printf PWN >&3'")"
# A DEFINITION behind a reserved word: the first word is `then`, so the conservative
# regime has to be decided on the peeled word or the body is never scanned.
check "a function definition after a reserved word is scanned" block \
    "$(bash_decision 'if true; then function f { touch .claude/skip-design-review.local; }; f; fi')"
# `python3 -` reads the PROGRAM from stdin, so the executed script is not an argument
# and the operand walk picked the first plain operand as the script.
check "python3 - with the helper on stdin is blocked" block \
    "$(bash_decision 'PYTHONPATH=hooks/gate-scripts/lib python3 - .claude 20 0 3600 < hooks/gate-scripts/lib/lease_slot.py')"
# ── generated: the stdin-program shape across alias x transport ───
# What stdin carries is not statically visible, so the WHOLE command is searched --
# a per-segment scan missed the pipe transport entirely.
_SI_FAIL=0 _SI_PASS=0
# Descriptors are matched as a FAMILY. A list of spellings covered descriptor 0 only,
# and `exec 3<helper.py; python3 /dev/fd/3` reads the same program through another one.
# The name is resolved by TOKENIZING, so quote concatenation cannot split it.
for alias in - /dev/stdin /dev/fd/0 /dev/fd/3 /proc/self/fd/0 /proc/self/fd/7 /proc/1/fd/2 \
             /dev/fd/./0 /dev//fd/0 /dev/fd/../fd/0 //dev/fd/0 '"$FD"' \
             /proc/thread-self/fd/0 /proc/self/task/12/fd/0 '/dev/f?/0'; do
    for form in "python3 $alias .claude 20 0 3600 < hooks/gate-scripts/lib/lease_slot.py" \
                "cat hooks/gate-scripts/lib/lease_slot.py | python3 $alias .claude 20" \
                "sudo python3 $alias .claude < hooks/gate-scripts/lib/audit_append.py" \
                "env -S 'python3 $alias .claude' < hooks/gate-scripts/lib/lease_slot.py" \
                "exec 3<hooks/gate-scripts/lib/lease_slot.py; python3 $alias .claude 20" \
                "python3 $alias .claude 20 < hooks/gate-scripts/lib/lease_\"slot.py\"" \
                "python3 $alias .claude 20 < 'hooks/gate-scripts/lib/lease_slot.py'" \
                "python3 $alias .claude 20 < hooks/gate-scripts/lib/lease_\$'slot.py'" \
                "python3 $alias .claude 20 < hooks/gate-scripts/lib/lease_slo[t].py"; do
        got="allow"
        case "$(bash_decision "$form")" in *'"block"'*) got="block" ;; esac
        if [[ "$got" == "block" ]]; then _SI_PASS=$((_SI_PASS + 1))
        else _SI_FAIL=$((_SI_FAIL + 1)); printf "  FAIL  stdin: %s\n" "$form"; fi
    done
done
if [[ "$_SI_FAIL" -eq 0 ]]; then
    ok "the helper reaches no interpreter through stdin ($_SI_PASS spellings)"
else
    no "stdin-program spellings" "$_SI_FAIL of $((_SI_PASS + _SI_FAIL)) allowed"
fi
# PROCESS SUBSTITUTION hands its reader a generated descriptor, and the segment splitter
# dismantles `<(...)` before the operand walk sees it.
check "an interpreter reading a process substitution is blocked" block \
    "$(bash_decision 'python3 <(cat hooks/gate-scripts/lib/lease_slot.py) .claude 20')"
check "a shell reading a process substitution is blocked" block \
    "$(bash_decision 'bash <(cat hooks/gate-scripts/lib/lease_slot.py)')"
check "diffing the helper through a substitution stays a read" allow \
    "$(bash_decision 'diff <(cat hooks/gate-scripts/lib/lease_slot.py) old.py')"
# ...and naming the helper without an interpreter stays a read.
check "reading the helper next to a python mention stays allowed" allow \
    "$(bash_decision 'echo python3 hooks/gate-scripts/lib/lease_slot.py')"
# A JOINED SHORT is not decomposed: `-Orm` is not `-O rm` without per-letter arity git
# does not expose, so it is simply not cleared.
check "a joined -c is a write" block \
    "$(bash_decision "git -ccore.fsmonitor='touch src/x' status")"
check "a joined -O is a write" block "$(bash_decision "git grep -Orm pattern")"
check "--paginate runs the configured pager" block \
    "$(bash_decision "git --paginate log")"
check "--textconv runs a configured program" block \
    "$(bash_decision "git cat-file --textconv HEAD:x")"
check "--filters runs a configured program" block \
    "$(bash_decision "git cat-file --filters HEAD:x")"
# The joined NUMERIC shapes are cleared, because each names a count, not a program.
check "git log -5 stays a read" allow "$(bash_decision "git log -5")"
check "git log -n5 stays a read" allow "$(bash_decision "git log -n5")"
check "git diff -U3 stays a read" allow "$(bash_decision "git diff -U3")"
# ── generated: exec-capable options by REGION ────────────────────
_RG_FAIL=0 _RG_PASS=0
_rg() {  # <expected> <command>
    local got="allow"
    case "$(bash_decision "$2")" in *'"block"'*) got="block" ;; esac
    if [[ "$got" == "$1" ]]; then _RG_PASS=$((_RG_PASS + 1))
    else _RG_FAIL=$((_RG_FAIL + 1)); printf "  FAIL  region: %s (want %s)\n" "$2" "$1"; fi
}
for f in --ext-diff --extcmd --tool --exec --upload-pack --receive-pack \
         -O --open-files-in-pager --textconv --filters --output=x -o; do
    _rg block "git log $f"       # not cleared in the subcommand region
    _rg allow "git log -- $f"    # behind `--` the same spelling is a pathspec
done
for f in -c --config-env --exec-path --paginate -p; do
    _rg block "git $f x=y log"   # not cleared in the global region
    _rg allow "git log -- $f"
done
if [[ "$_RG_FAIL" -eq 0 ]]; then
    ok "exec-capable options fire only in their own region ($_RG_PASS spellings)"
else
    no "exec-capable options by region" "$_RG_FAIL of $((_RG_PASS + _RG_FAIL)) wrong"
fi
check "wrapped find -exec running the helper is blocked" block \
    "$(bash_decision "sudo find . -maxdepth 0 -exec python3 hooks/gate-scripts/lib/lease_slot.py .claude 20 30 3600 ;")"
# RUNNERS ARE MATCHED AT ANY INDEX, on purpose. Requiring command position means knowing
# where the wrapper preamble ends, which means knowing which wrapper flags take an
# operand -- and every approximation of that is a fail-open. A rule that consumed one
# operand per flag ate the `find` in `sudo -E find . -exec ...`, because -E is boolean,
# and the payload behind it went unscanned. Same for `env -i` and `sudo -n`. These four
# are the shapes that rule got wrong.
check "sudo -u root sh -c running the helper is blocked" block \
    "$(bash_decision "sudo -u root sh -c 'python3 hooks/gate-scripts/lib/lease_slot.py .claude 20 30 3600'")"
check "sudo -E find -exec running the helper is blocked" block \
    "$(bash_decision "sudo -E find . -maxdepth 0 -exec sh -c 'python3 hooks/gate-scripts/lib/lease_slot.py .claude 20 30 3600' ;")"
check "env -i sh -c running the helper is blocked" block \
    "$(bash_decision "env -i sh -c 'python3 hooks/gate-scripts/lib/lease_slot.py .claude 20 30 3600'")"
check "sudo -n sh -c running the helper is blocked" block \
    "$(bash_decision "sudo -n sh -c 'python3 hooks/gate-scripts/lib/lease_slot.py .claude 20 30 3600'")"
check "timeout 5 env -S running the helper is blocked" block \
    "$(bash_decision "timeout 5 env -S 'python3 hooks/gate-scripts/lib/lease_slot.py .claude 20 30 3600'")"
# There is NO reader-exemption list. One was tried -- commands that "only print their
# arguments" skipped payload extraction -- and every entry turned out to be another way to
# execute: `less "+!<cmd>"` runs a shell, `alias echo=eval` re-points the name, a function
# definition shadows it outright. The list is gone and the scan is unconditional; the
# price is one documented over-block, pinned here so it stays deliberate.
check "echo of an sh -c helper payload over-blocks (documented, fail-CLOSED)" block \
    "$(bash_decision "echo -n sh -c 'python3 hooks/gate-scripts/lib/lease_slot.py .claude 20 30 3600'")"
# `-exec` is anchored to a preceding `find`, so a bare -exec operand is not a payload.
check "grep with an -exec operand is allowed" allow \
    "$(bash_decision "grep -exec notes.txt")"
check "a non-find command with an -exec operand is allowed" allow \
    "$(bash_decision "printf '%s\\n' -exec notes.txt")"
# INDIRECTION withdraws the mention contract: a command that defines a function, defines
# an alias, or calls eval can re-point a name so an operand becomes what runs.
check "a pager startup command (+!) is an executed payload" block \
    "$(bash_decision "less '+!python3 -I hooks/gate-scripts/lib/lease_slot.py .claude 20 0 3600' /dev/null")"
check "an alias re-pointing a name is caught" block \
    "$(bash_decision 'shopt -s expand_aliases; alias echo=eval; echo "python3 -I hooks/gate-scripts/lib/lease_slot.py .claude 20 0 3600"')"
check "a bare eval of the helper is caught" block \
    "$(bash_decision 'eval "python3 -I hooks/gate-scripts/lib/lease_slot.py .claude 20 0 3600"')"
# ...matched on a DEQUOTED copy, because the shell concatenates adjacent quoted runs.
check "quote-split eval is caught" block \
    "$(bash_decision 'ev"al" "python3 -I hooks/gate-scripts/lib/lease_slot.py .claude 20 0 3600"')"
check "quote-split alias is caught" block \
    "$(bash_decision "al''ias echo=eval; echo 'python3 -I hooks/gate-scripts/lib/lease_slot.py .claude 20 0 3600'")"
# A COMMAND SUBSTITUTION runs before the command consuming its output, so a harmless
# consumer proves nothing: this claims a slot and logs a sanctioned-bypass event, then
# prints the slot number.
check "helper inside a command substitution is blocked" block \
    "$(bash_decision 'echo "$(python3 -I hooks/gate-scripts/lib/lease_slot.py .claude 20 0 3600)"')"
check "helper inside a backtick substitution is blocked" block \
    "$(bash_decision 'echo `python3 -I hooks/gate-scripts/lib/lease_slot.py .claude 20 0 3600`')"
check "helper in a substitution assigned to a variable is blocked" block \
    "$(bash_decision 'X=$(python3 hooks/gate-scripts/lib/lease_slot.py .claude 20 0 3600); echo $X')"
check "an ordinary substitution stays allowed" allow \
    "$(bash_decision 'echo "today is $(date)"')"
check "grepping for a helper under a substituted path is allowed" allow \
    "$(bash_decision 'grep -rn lease_slot.py $(git rev-parse --show-toplevel)')"
# QUOTES ARE REMOVED, NOT SPACED OUT, when flattening a substitution: the shell
# concatenates adjacent quoted runs, so lease_"slot.py" is one word.
check "quote-split helper inside a substitution is blocked" block \
    "$(bash_decision 'echo "$(python3 -I hooks/gate-scripts/lib/lease_"slot.py" .claude 999 0 3600)"')"
# git READS like a reader but an alias runs a shell, so it is deliberately NOT exempt.
check "git alias forwarding to sh -c is blocked" block \
    "$(bash_decision 'git -c "alias.x=!f(){ \"\$@\"; }; f" x sh -c "python3 -I hooks/gate-scripts/lib/lease_slot.py .claude 999 0 3600"')"
check "git diff naming a helper stays allowed" allow \
    "$(bash_decision "git diff -- hooks/gate-scripts/lib/audit_append.py")"
# A FUNCTION DEFINITION CAN SHADOW A NAME, so the mention contract is withdrawn
# wholesale whenever the command defines one -- withdrawing it only ever blocks more.
check "a function shadowing echo cannot launder a payload" block \
    "$(bash_decision 'echo() { "\$@"; }; echo sh -c "python3 -I hooks/gate-scripts/lib/lease_slot.py .claude 20 0 3600"')"
check "the function keyword form is caught too" block \
    "$(bash_decision 'function echo { "\$@"; }; echo sh -c "python3 -I hooks/gate-scripts/lib/lease_slot.py .claude 20 0 3600"')"

echo "── fallback parity ────────────────────────────────────────────────"

# The gate carries an INLINE copy of FILE_MOD_PATTERNS as the cmdword-import-failure
# fallback. A verb present in one list and not the other fails OPEN on exactly the
# damaged-installation path the fallback exists to cover. Asserted, not documented:
# a comment saying "keep these in sync" survives until the next edit; this does not.
if python3 - "$REPO_ROOT" <<'PYEOF'
import re, sys, pathlib
root = pathlib.Path(sys.argv[1])
sys.path.insert(0, str(root / "hooks/gate-scripts/lib"))
from cmdword import FILE_MOD_PATTERNS
gate = (root / "hooks/gate-scripts/pre-implementation-gate.sh").read_text()
block = re.search(r"FILE_MOD_PATTERNS = \[(.*?)\]", gate, re.S)
if not block:
    sys.exit(1)
inline = set(re.findall(r'r"([^"]+)"', block.group(1)))
sys.exit(0 if inline == set(FILE_MOD_PATTERNS) else 1)
PYEOF
then
    ok "gate inline FILE_MOD_PATTERNS matches cmdword.FILE_MOD_PATTERNS"
else
    no "gate inline FILE_MOD_PATTERNS matches cmdword.FILE_MOD_PATTERNS" "the two lists have drifted"
fi

echo "── the hardened audit appender ────────────────────────────────────"
if python3 -I "$REPO_ROOT/hooks/gate-scripts/lib/audit_append.py" --self-check >/dev/null 2>&1; then
    ok "audit_append self-check (symlinked log / symlinked prefix / torn line all refuse)"
else
    no "audit_append self-check" "see: python3 hooks/gate-scripts/lib/audit_append.py --self-check"
fi
if python3 -I "$REPO_ROOT/hooks/gate-scripts/lib/lease_slot.py" --self-check >/dev/null 2>&1; then
    ok "lease_slot self-check (slots increment/exhaust/reset; age boundaries; every use logged)"
else
    no "lease_slot self-check" "see: python3 hooks/gate-scripts/lib/lease_slot.py --self-check"
fi

# THE AUDIT EVENT HAS NO STANDALONE ENTRY POINT. A CLI that writes a record -- even one
# built from fixed fields, taking only integers -- mints `skip-review-consumed` with no
# lease behind it, and post-commit-consume-marker.sh reads a recent one of those as proof
# that a bypass was sanctioned, suppressing a genuine unreviewed-commit entry. Such a
# command names no protected path and no modification verb, so the Bash detector above
# would be the ONLY thing in the way. Pin that the entry point stays absent: the gate's
# detector is defence in depth here, never the sole defence.
_forge_dir="$(mktemp -d)" || _forge_dir=""
if [ -z "$_forge_dir" ] || [ ! -d "$_forge_dir" ]; then
    no "audit_append has no record-writing CLI" "could not create a temp dir"
else
    if (cd "$_forge_dir" && mkdir -p .claude &&
        ! python3 -I "$REPO_ROOT/hooks/gate-scripts/lib/audit_append.py" .claude 1 20 2>/dev/null &&
        [ ! -e .claude/bypass-log.jsonl ]); then
        ok "audit_append has no record-writing CLI (a forged event exits non-zero, writes nothing)"
    else
        no "audit_append has no record-writing CLI" "a standalone invocation minted an event"
    fi
    rm -rf "$_forge_dir"
fi

echo "── generated: the helper guard across combined spellings ──────────"
# PROPERTY-STYLE COVERAGE, not one more hand-picked example. The guard has to hold across
# the CROSS PRODUCT of the things that independently defeated it during review: how the
# helper name is spelled (plain / split across quoted runs), what hands it to a runner
# (direct / a shell -c / env -S / a find -exec / eval), and what sits in front (nothing /
# a wrapper / a wrapper with a flag operand / a leading assignment). Fixed examples kept
# passing while a neighbouring spelling did not.
_SPELL=(
  "python3 -I hooks/gate-scripts/lib/lease_slot.py .claude 20 0 3600"
  "python3 -I hooks/gate-scripts/lib/lease_\"slot.py\" .claude 20 0 3600"
  "python3 -I hooks/gate-scripts/lib/audit_append.py .claude 1 20"
)
_PREFIX=("" "sudo " "sudo -u root " "sudo -E " "nohup " "timeout 5 " "X=1 ")
_GEN_PASS=0; _GEN_FAIL=0
for pre in "${_PREFIX[@]}"; do
  for sp in "${_SPELL[@]}"; do
    for form in direct sh env find eval; do
      case "$form" in
        direct) cmd="${pre}${sp}" ;;
        sh)     cmd="${pre}sh -c '${sp}'" ;;
        env)    cmd="${pre}env -S '${sp}'" ;;
        find)   cmd="${pre}find . -maxdepth 0 -exec sh -c '${sp}' ;" ;;
        eval)   cmd="${pre}eval '${sp}'" ;;
      esac
      out="$(bash_decision "$cmd")"
      case "$out" in
        *'"block"'*) _GEN_PASS=$((_GEN_PASS + 1)) ;;
        *) _GEN_FAIL=$((_GEN_FAIL + 1)); printf "  FAIL  generated: %s\n" "$cmd" ;;
      esac
    done
  done
done
if [ "$_GEN_FAIL" -eq 0 ]; then
    ok "every generated helper invocation blocks ($_GEN_PASS spellings)"
else
    no "generated helper invocations" "$_GEN_FAIL of $((_GEN_PASS + _GEN_FAIL)) allowed"
fi

# ...and the mention contract holds across the same axes for a plain READ of the file.
_READ=("cat" "head -5" "wc -l" "grep -n import" "git diff --")
_RD_FAIL=0
for r in "${_READ[@]}"; do
    out="$(bash_decision "$r hooks/gate-scripts/lib/lease_slot.py")"
    case "$out" in *'"block"'*) _RD_FAIL=$((_RD_FAIL + 1)); printf "  FAIL  generated read: %s\n" "$r" ;; esac
done
if [ "$_RD_FAIL" -eq 0 ]; then
    ok "every generated READ of a helper stays allowed (${#_READ[@]} forms)"
else
    no "generated helper reads" "$_RD_FAIL blocked"
fi

# ── An ABANDONED helper scan is not a clean scan ────────────────────────────
# The helper guard runs on EVERY command, not only while a design review is pending. The
# token budget that stops it burning the hook timeout therefore cannot degrade to "no
# helper found": with nothing pending, nothing else covers the gap. It degraded twice.
#
#   * The fallback probe searched for `lease_slot.py` / `audit_append.py` only, and
#     `python3 -m lease_slot` never writes either string -- so a real invocation read as
#     absent. The probe now searches the module stems, which subsume the file names.
#   * Exhaustion then returned that probe alone, so a command that named no helper at all
#     was ALLOWED even though the scan never finished. It now fails CLOSED.
#
# The reasoning that justified the old behaviour -- that the cmdword budget blocks the
# same shape anyway -- is exactly what did not hold, so the padded cases below are run
# with NOTHING pending, which is the state in which the two guards do not overlap.
_PAD="$(python3 -c 'print(" ".join(["-x"] * 4100))')"
_BUD_FAIL=0
_bud() {   # <expected> <command> <label>
    local got="allow"
    case "$(bash_decision "$2")" in *'"block"'*) got="block" ;; esac
    [[ "$got" == "$1" ]] || { _BUD_FAIL=$((_BUD_FAIL + 1))
                              printf "  FAIL  budget: %s (want %s, got %s)\n" "$3" "$1" "$got"; }
}
_bud block "python3 $_PAD -m lease_slot .claude fake 1"   "padded + module lease_slot"
_bud block "python3 $_PAD -m audit_append .claude x"      "padded + module audit_append"
_bud block "python3 -m lease_slot .claude fake 1"         "module, unpadded (control)"
_bud block "python3 -m gate.lib.lease_slot .claude f 1"   "dotted module path"
# A scan cut short by an unbalanced quote lands on the same probe, so the module spelling
# has to be covered there too -- this is the shape that isolates the probe from the
# fail-closed branch, since the budget is never reached.
_bud block 'python3 -m lease_slot .claude f 1 "unbalanced' "unparseable + module"
# Exhaustion with NO helper named anywhere still blocks: not-knowing is not not-found.
_bud block "echo $(python3 -c 'print("y " * 4100)')"      "budget exhausted, no helper named"
# ...and the price is bounded to genuinely absurd shapes. A long SINGLE token is not
# thousands of words, so it never reaches the budget.
_bud allow "echo $(python3 -c 'print("y" * 60000)')"      "one long token stays allowed"
_bud allow "npm test"                                     "ordinary command stays allowed"
if [ "$_BUD_FAIL" -eq 0 ]; then
    ok "an abandoned helper scan fails closed, and the module spelling is covered"
else
    no "helper scan budget" "$_BUD_FAIL wrong"
fi

# ── The helper guard, behind a leading redirection and behind nesting ───────
# Two escapes from the UNCONDITIONAL helper guard, both found after the wrapper regime
# was believed fixed in cmdword.py. They are asserted HERE, against the gate, because the
# gate keeps its OWN copy of the scan and the two tokenize differently: cmdword uses a
# plain shlex, so `</dev/null` stays one token; this file uses punctuation_chars, which
# splits it into `<` plus `/dev/null`. Filtering only the OPERATOR left the target in
# command position, `basename /dev/null` is `null`, no wrapper was seen, and the launcher
# was peeled to its own operand. Fixing the library copy alone left this one open.
_BUD_FAIL=0          # own accumulator: the block above already reported on its own
_HLP="python3 hooks/gate-scripts/lib/lease_slot.py .claude fake 1"
for _r in "</dev/null" "< in.txt" "2>&1" "2>/dev/null" "> out.txt"; do
    for _l in "sudo -u root" "script -q /dev/null" "flock /tmp/x.lock" "chroot /jail" \
              "env -u FOO" ""; do
        _bud block "$_r $_l $_HLP" "redirect [$_r] + launcher [$_l] + helper"
    done
done
# ...and the read/mention contract survives the same stripping: naming the file is not
# running it, redirection or no redirection.
_bud allow "</dev/null cat hooks/gate-scripts/lib/lease_slot.py"  "redirect + READ of helper"
_bud allow "2>&1 grep -n import hooks/gate-scripts/lib/lease_slot.py" "redirect + grep helper"
_bud allow "</dev/null echo lease_slot.py"                        "redirect + mention"
# Nesting past the depth cap must block rather than fall through to a substring probe
# that a GLOBBED name defeats -- the shell expands `lease_slo[t].py`, the probe does not.
_NEST="$_HLP"
for _i in 1 2 3 4; do _NEST="sh -c $(printf '%q' "$_NEST")"; done
_bud block "$_NEST" "4x nested sh -c + helper"
_GNEST="python3 hooks/gate-scripts/lib/lease_slo[t].py .claude fake 1"
for _i in 1 2 3 4; do _GNEST="sh -c $(printf '%q' "$_GNEST")"; done
_bud block "$_GNEST" "4x nested sh -c + GLOBBED helper name"
# A QUOTED redirect character handed to a wrapper as an OPERAND is not syntax. shlex
# dequotes before this scan sees it, so `>` as a value is byte-identical to `>` as an
# operator -- and the redirect stripper that fixed the case above then consumed it AND the
# interpreter behind it. Both directions are wrong in opposite ways, so both are pinned:
# strip in command position (a leftover target hides the verb), never strip under a
# wrapper (the wrapper regime reads every token, and stripping eats real ones).
for _q in ">" "<" ">>" "2>&1" "<<" ">|"; do
    _bud block "env -u '$_q' $_HLP"      "wrapper operand is a literal [$_q]"
    _bud block "sudo -u '$_q' $_HLP"     "sudo operand is a literal [$_q]"
done
# When the SEGMENTER gives up, the probe has to squeeze quoting and GLOB characters, not
# just look for the literal filename. A Bash-VALID heredoc whose body contains an
# apostrophe defeats this parser (a documented limitation -- the body is data to bash and
# source to this gate), and `lease_slo[t].py` names no helper literally while the shell
# expands it to one. Those two together were a bypass.
#
# The matching over-block is asserted in the same breath, because the obvious fix -- block
# whenever the parse fails -- costs far more than it buys: heredocs carrying prose are
# ordinary, and blocking every one containing an apostrophe is a constant benign failure.
_GLOB_HLP="python3 hooks/gate-scripts/lib/lease_slo[t].py .claude fake 1"
_bud block "$(printf '%s <<%sEOF%s\nit%ss a body\nEOF' "$_GLOB_HLP" "'" "'" "'")" \
           "heredoc + apostrophe + globbed helper"
_bud block "$_HLP \"unbalanced"                      "unbalanced quote + helper"
_bud block "$_GLOB_HLP"                              "globbed helper, parseable"
_bud allow "$(printf 'echo hi <<%sEOF%s\nit%ss fine\nEOF' "'" "'" "'")" \
           "benign heredoc carrying an apostrophe"
_bud allow "git commit -m \"it's a message\""        "apostrophe in a quoted -m"
if [ "$_BUD_FAIL" -eq 0 ]; then
    ok "the helper guard holds behind leading redirections and past the depth cap"
else
    no "helper guard redirect/nesting" "$_BUD_FAIL wrong"
fi

# ── The gate must DECIDE within its own hook timeout ────────────────────────
# Cost is a correctness property for this hook, not a latency one: hooks.json registers
# it at timeout 5, and a timeout kills it with NO decision on stdout, which the harness
# reads as ALLOW. So a command that merely takes long enough to classify IS a bypass, and
# it is reachable from the command string alone.
#
# The -c scan is O(tokens^2) by construction (it refuses the per-flag arity table, which
# fails OPEN when wrong), so padding a command with repeated runner/option pairs used to
# buy that time: 12.8KB cost 4.9s in is_file_mod alone, and 128KB cost 34s end to end.
# Bounded now by cmdword._MAX_SCAN_TOKENS/_MAX_CMD_CHARS, _HELPER_MAX_TOKENS, and the
# split pre-parse ceiling. Each case must still come back BLOCK -- fast-and-allowed would
# be the same bypass with extra steps.
#
# Asserted at 3.5s against the hook's real 5s timeout. Asserting AT the timeout accepts
# any margin down to zero: a variant measured at 3.92s here passes a 5s assertion while
# being one slow box away from the fail-open it is meant to prevent. So the test demands
# room -- but the room has to be a number a real machine can meet.
#
# It was 2.5s (half the timeout), calibrated on a developer machine, and that is what
# failed CI: this payload costs 0.65s here and 2.71s on a GitHub runner. A baseline-SCALED
# budget was tried next and was worse than useless -- the 16KB case it scaled from is
# dominated by process startup, which CI does at roughly local speed (0.19s), while the
# 2048KB case is dominated by parse throughput, which CI does far slower. The two ratios
# are 5.4x locally and 14.3x on CI, so scaling from the small case mis-models the workload
# and the floor simply won on both machines. A flat number honest about the slow case is
# the simpler and correct instrument.
#
# 3.5s keeps the guard whole. What it exists to catch is superlinear blowup, and all three
# regressions it was written for -- 7.2s, 5.4s, 4.9s -- are above 3.5s. It also still fails
# BEFORE production does: a machine 30% slower than that CI runner trips this at 3.5s while
# the hook itself is still inside its 5s timeout, which is the direction a warning points.
#
# The payload is built and piped INSIDE python, never passed as an argv word: the gate
# reads its command from stdin JSON and is not bound by ARG_MAX, but bash_decision passes
# argv, so routing the megabyte case through it fails with E2BIG and tests the harness
# rather than the gate.
_padded_decision() {   # <kb> -> gate stdout
    python3 -c '
import json, sys
n = int(sys.argv[2]) * 1024 // 7
cmd = "script " + "sh -cx " * n + "-- env -S " + chr(39) + "rm -rf src" + chr(39)
sys.stdout.write(json.dumps({"tool_name": "Bash", "cwd": sys.argv[1],
                             "tool_input": {"command": cmd}}))' "$WORK" "$1" \
    | (cd "$WORK" && bash "$GATE") 2>/dev/null
}
_TIMED_FAIL=0
for _kb in 16 128 2048; do
    _T0="$(python3 -c 'import time; print(time.time())')"
    _OUT="$(_padded_decision "$_kb")"
    _EL="$(python3 -c "import time; print('%.2f' % (time.time() - $_T0))")"
    case "$_OUT" in
        *'"block"'*) ;;
        *) _TIMED_FAIL=$((_TIMED_FAIL + 1))
           printf "  FAIL  %sKB padded command was ALLOWED\n" "$_kb" ;;
    esac
    _BUDGET=3.5
    if [[ "$(python3 -c "print(1 if $_EL >= $_BUDGET else 0)")" == "1" ]]; then
        _TIMED_FAIL=$((_TIMED_FAIL + 1))
        printf "  FAIL  %sKB padded command took %ss (budget %ss; the hook timeout is 5s)\n" \
               "$_kb" "$_EL" "$_BUDGET"
    fi
done
if [[ "$_TIMED_FAIL" -eq 0 ]]; then
    ok "padded commands still block, inside the 5s hook timeout (16KB/128KB/2MB)"
else
    no "padded-command timing" "$_TIMED_FAIL assertion(s) failed"
fi

# The same bound must not be escapable by how the payload SPELLS itself. The first cut of
# the pre-parse guard scoped itself to two literal `"tool_name":"Bash"` spellings and
# measured ${#INPUT}, which counts characters; the parsers accept `toolName` as well, and
# four-byte characters make characters and bytes differ by 4x. Both are caller-chosen, so
# both are pinned here: a guard scoped by a spelling the caller picks is not a guard.
#
# Three things this has to get right, each of which a previous cut got wrong:
#
#  1. The payload must be big enough to REACH the guard. A first cut used ~1MB of many
#     small tokens and passed even with the guard defeated, because the TOKEN budget
#     disposes of that shape on its own -- a test certifying a guard it never reached.
#     The padding here is ONE long token, so the token budget cannot be what stops it.
#  2. ensure_ascii must be FALSE. json.dumps defaults to True, which ships a 4-byte
#     character as a 12-byte ASCII surrogate escape -- so the "4-byte padding" case was
#     never actually putting multibyte bytes on the wire, and the shape that genuinely
#     cost 7.8s went untested. Written as bytes for the same reason.
#  3. Sizes must straddle the ceiling. Below it the deep path runs and the per-command
#     budgets must hold; above it the pre-parse guard must short-circuit. Testing only
#     one side leaves the other free to regress.
_SPELL_FAIL=0
_spelled_decision() {   # <key> <pad-char-codepoint> <chars> -> gate stdout
    python3 -c '
import json, sys
key, cp, n = sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
cmd = chr(cp) * n + "; rm -rf src"
sys.stdout.buffer.write(json.dumps(
    {key: "Bash", "cwd": sys.argv[1], "tool_input": {"command": cmd}},
    ensure_ascii=False).encode("utf-8"))' "$WORK" "$1" "$2" "$3" \
    | (cd "$WORK" && bash "$GATE") 2>/dev/null
}
for _key in "tool_name" "toolName"; do
    for _cp in 120 65536; do          # 1-byte and 4-byte padding characters
        # 60000 chars sits under both ceilings (the deep path RUNS); 262130 is the exact
        # width from the review that cost 7.8s end to end before the ceiling was split.
        for _n in 60000 262130; do
            _T0="$(python3 -c 'import time; print(time.time())')"
            _OUT="$(_spelled_decision "$_key" "$_cp" "$_n")"
            _EL="$(python3 -c "import time; print('%.2f' % (time.time() - $_T0))")"
            case "$_OUT" in
                *'"block"'*) ;;
                *) _SPELL_FAIL=$((_SPELL_FAIL + 1))
                   printf "  FAIL  key=%s cp%s n=%s was ALLOWED\n" "$_key" "$_cp" "$_n" ;;
            esac
            # Same 3.5s budget as the padded loop above, for the same reason: a flat 2.5s
            # was this laptop's speed masquerading as a universal constant.
            _SBUDGET=3.5
            if [[ "$(python3 -c "print(1 if $_EL >= $_SBUDGET else 0)")" == "1" ]]; then
                _SPELL_FAIL=$((_SPELL_FAIL + 1))
                printf "  FAIL  key=%s cp%s n=%s took %ss (budget %ss; hook timeout is 5s)\n" \
                       "$_key" "$_cp" "$_n" "$_EL" "$_SBUDGET"
            fi
        done
    done
done
# A Write/Edit gets the generous ceiling by design -- its payload is file CONTENT and the
# gate reads only file_path. Pinned so that raising the strict limit to "fix" a large
# write, or dropping the Write exemption, both show up here rather than in production.
_BIG_WRITE="$(python3 -c '
import json, sys
sys.stdout.buffer.write(json.dumps(
    {"tool_name": "Write", "cwd": sys.argv[1],
     "tool_input": {"file_path": sys.argv[1] + "/src/impl.py", "content": "x" * 3000000}}
).encode())' "$WORK" | (cd "$WORK" && bash "$GATE") 2>/dev/null)"
case "$_BIG_WRITE" in
    *'"block"'*) ;;
    *) _SPELL_FAIL=$((_SPELL_FAIL + 1))
       printf "  FAIL  a 3MB Write to an impl path was ALLOWED (design gate bypassed)\n" ;;
esac
# The generous ceiling must key off the TOP-LEVEL tool discriminator, never off the string
# appearing somewhere in the payload. A Bash request that puts "Write" in a sibling field
# (description is a real, supported field) raised its own ceiling 256KB -> 8MB and reached
# the marker and effective-CWD parsers with a megabyte of command: measured at 5.5s
# against a 5s timeout, i.e. a fail-open bought with one word of attacker-chosen text.
for _decoy in Write Edit MultiEdit; do
    for _key in tool_name toolName; do
        _T0="$(python3 -c 'import time; print(time.time())')"
        _OUT="$(python3 -c '
import json, sys
key, decoy = sys.argv[2], sys.argv[3]
cmd = chr(0x10000) * 262130 + "; rm -rf src"
sys.stdout.buffer.write(json.dumps(
    {key: "Bash", "cwd": sys.argv[1],
     "tool_input": {"command": cmd, "description": decoy}},
    ensure_ascii=False).encode("utf-8"))' "$WORK" "$_key" "$_decoy" \
        | (cd "$WORK" && bash "$GATE") 2>/dev/null)"
        _EL="$(python3 -c "import time; print('%.2f' % (time.time() - $_T0))")"
        case "$_OUT" in
            *'"block"'*) ;;
            *) _SPELL_FAIL=$((_SPELL_FAIL + 1))
               printf "  FAIL  %s=Bash with description=%s was ALLOWED\n" "$_key" "$_decoy" ;;
        esac
        if [ "$(python3 -c "print(1 if $_EL >= 2.5 else 0)")" = "1" ]; then
            _SPELL_FAIL=$((_SPELL_FAIL + 1))
            printf "  FAIL  %s=Bash description=%s took %ss (budget 2.5s)\n" \
                   "$_key" "$_decoy" "$_EL"
        fi
    done
done
if [ "$_SPELL_FAIL" -eq 0 ]; then
    ok "the size bound holds across tool_name/toolName and 1-byte/4-byte padding"
else
    no "size-bound spelling independence" "$_SPELL_FAIL assertion(s) failed"
fi

# The discriminator must not import from the repo it is gating ─────────────
# The ceiling above is chosen from the parsed tool_name, so whatever parses that name
# is part of the boundary. A bare `python3 -c` puts the process CWD on sys.path, and the
# gate runs with CWD inside the repo -- so a repo-root json.py both executes arbitrary
# code inside the gate and can return {"tool_name": "Write"}, lifting a Bash payload from
# the 256KB ceiling to 8MB and restoring the timeout fail-open the ceiling exists to close.
# Every other stdin parser in the gate already spells this `python3 -I -c`; this one did
# not, which is exactly the kind of drift a convention cannot enforce on its own.
#
# Asserted by SENTINEL, not by the decision. The first cut of this test sent a 300KB
# benign command and asserted "block" -- and passed against the KNOWN-BROKEN gate, because
# 300KB also exceeds cmdword._MAX_CMD_CHARS, which fails closed on its own. The verdict was
# identical with and without the hijack, so the assertion certified nothing. What the
# hijack actually buys is the SLOW path (a timeout yields no decision, which reads as
# allow) and arbitrary execution inside the gate. Importing is the boundary, so importing
# is what gets asserted -- directly, with no timing flake.
#
# The gate's other stdin parsers already pass -I, so a tripped sentinel implicates this
# discriminator specifically.
printf 'import pathlib\npathlib.Path("%s/PWNED").write_text("x")\ndef load(f):\n    return {"tool_name": "Write"}\n' \
       "$WORK" > "$WORK/json.py"
rm -f "$WORK/PWNED"
printf '{"tool_name":"Bash","cwd":"%s","tool_input":{"command":"ls -la"}}' "$WORK" \
    | (cd "$WORK" && bash "$GATE") >/dev/null 2>&1
rm -f "$WORK/json.py"
if [ -e "$WORK/PWNED" ]; then
    rm -f "$WORK/PWNED"
    no "discriminator import isolation" "the gate imported a repo-root json.py — needs python3 -I"
else
    ok "the gate does not import a repo-root json.py (isolated mode)"
fi

# ── Three fail-opens found by the PR-mode deep review of this branch ────────

# 1. A redirect-only write, nested past the recursion cap. The cap degrades to
# _regex_fallback, which is VERB patterns only -- so it cannot see a redirect, and the
# tokenized pass that WOULD have run _writes_via_redirect never happens. The caller
# strips single-quoted text before its own redirect check (so a literal `jq .x > 0` is
# not a write), which is exactly where a payload lives. Both halves of the verdict have
# to survive the cap, not just the verb half.
#
# Quoted with shlex.quote, and each level is syntax-checked with `bash -n`: a repr-style
# nesting is NOT valid shell (`\'` inside single quotes), and an invalid command proves
# nothing because it takes the unparseable path instead of the one under test.
# Driven over every WRITE spelling, not just the spaced one. A redirection needs no
# whitespace in front of it (`printf x>f`), `<>` opens for reading AND writing despite
# starting with `<`, and `>|` overrides noclobber -- the first regex here required a
# leading delimiter and omitted `<>`, so three valid writes walked through it.
# Asserted against cmdword DIRECTLY, not through the gate, and that is load-bearing. The
# gate carries its own fail-closed depth cap ABOVE this one: at four nested `sh -c` layers
# it blocks every command, including `grep -n TODO src/impl.py`, which contains no
# redirection at all. Verified identical before and after this change, so it is not a
# behaviour this branch introduced -- but it means a GATE-level assertion at the depths
# this fix targets passes no matter what the regex does. Testing the blunter layer would
# have certified nothing, in both directions at once.
#
# Same reason the suite already reaches into cmdword for the FILE_MOD_PATTERNS parity
# check: the property under test lives there.
_NEST_OUT="$(python3 - <<'PYEOF' 2>&1
import shlex, subprocess, sys
sys.path.insert(0, "hooks/gate-scripts/lib")
import cmdword

# A redirection needs no whitespace in front of it, `<>` opens for reading AND writing
# despite starting with `<`, and `>|` overrides noclobber. The first regex here required
# a leading delimiter and omitted `<>`, so three valid writes walked through it.
WRITES = ['printf x > src/impl.py', 'printf x>src/impl.py', 'printf x>>src/impl.py',
          'printf x 1<>src/impl.py', 'printf x >|src/impl.py', 'printf x 2>src/impl.py',
          # `>&word` creates a FILE whenever the target is not a number or `-`. Both the
          # raw depth-cap pattern and the token-level _writes_via_redirect decide this by
          # the TARGET, because punctuation_chars tokenization gives `>&2` and `>& out`
          # the same two-token shape.
          'printf x >&src/impl.py', 'printf x >& src/impl.py', 'printf x &>src/impl.py']
# A descriptor DUPLICATION is not a write. Without these the rule above is satisfiable by
# a regex that blocks every `>`, turning the depth path into a blanket block wearing a
# redirect test.
#
# NOT listed: a `/dev/null` target. The token path exempts it, the raw depth-cap path
# deliberately does not (past the cap there are no exemptions to honor), so the two
# disagree there BY DESIGN. It is unobservable through the gate, which blocks every
# command at four nested layers regardless -- but asserting it here would be asserting a
# disagreement rather than a property.
NOT_WRITES = ['npm test 2>&1', 'echo hi >&2', 'cat < in.txt', 'grep -n TODO src/impl.py',
              'printf x 2>&-', 'printf x >&2', 'printf x 1>&2', 'ls -la']

bad = []
for depth in range(1, 7):
    for inner, want in [(c, True) for c in WRITES] + [(c, False) for c in NOT_WRITES]:
        cmd = inner
        for _ in range(depth):
            cmd = "sh -c " + shlex.quote(cmd)
        # A repr-style nesting is NOT valid shell, and an invalid command takes the
        # unparseable path instead of the one under test -- so each fixture is checked.
        if subprocess.run(["bash", "-n", "-c", cmd], capture_output=True).returncode:
            bad.append("depth %d fixture is not valid shell: %s" % (depth, inner))
            continue
        if cmdword.is_file_mod(cmd) != want:
            bad.append("depth %d %s: %s" % (depth, "allowed" if want else "blocked", inner))
print("\n".join(bad) if bad else "CLEAN")
PYEOF
)"
if [ "$_NEST_OUT" = "CLEAN" ]; then
    ok "every write spelling blocks past the cap, and no descriptor dup is read as one"
else
    no "nested redirect classification" "$(printf '%s' "$_NEST_OUT" | tr '\n' ';')"
fi

# The depth-cap redirect pattern is checked against BASH ITSELF rather than against a list
# someone maintained by hand. Each spelling runs in a throwaway directory and the question
# asked is the only one that matters -- did a file appear? -- then compared with the
# pattern's verdict. Three successive rounds of review found a missing spelling in this
# one regex (attached `x>f`, then `<>`, then the legacy `>&f`, which bash treats as a
# WRITE whenever the target is not a number or `-`), which is exactly the signal that a
# hand-maintained list is the wrong instrument. An oracle cannot be short a case that bash
# supports, and it fails the moment the two disagree in EITHER direction.
_ORACLE_OUT="$(python3 - <<'PYEOF' 2>&1
import os, subprocess, sys, tempfile
sys.path.insert(0, "hooks/gate-scripts/lib")
import cmdword

SPELLINGS = [
    "printf x > T", "printf x >T", "printf x >> T", "printf x >>T",
    "printf x >| T", "printf x >|T", "printf x 2> T", "printf x 2>T",
    "printf x 1>> T", "printf x &> T", "printf x &>T", "printf x &>> T",
    "printf x >& T", "printf x >&T", "printf x 1>& T",
    "printf x <> T", "printf x 1<> T", "printf x 1<>T",
    "printf x >&2", "printf x >& 2", "printf x 2>&1", "printf x 1>&2",
    "printf x 2>&-", "printf x >&-", "printf x < T", "printf x <T",
    "printf x", "npm test 2>&1", "grep -n TODO T",
]
bad = []
for s in SPELLINGS:
    d = tempfile.mkdtemp()
    cmd = s.replace("T", "target.txt")
    subprocess.run(["bash", "-c", cmd], cwd=d, capture_output=True)
    creates = os.path.exists(os.path.join(d, "target.txt"))
    if bool(cmdword._RAW_WRITE_REDIR_RE.search(cmd)) != creates:
        bad.append("%s: bash_creates=%s regex=%s" % (s, creates, not creates))
print("\n".join(bad) if bad else "CLEAN")
PYEOF
)"
if [ "$_ORACLE_OUT" = "CLEAN" ]; then
    ok "the depth-cap redirect pattern agrees with bash on every spelling (29 forms)"
else
    no "redirect pattern vs bash" "$(printf '%s' "$_ORACLE_OUT" | tr '\n' ';')"
fi

# 2. The pre-parse size ceiling measured INPUT AFTER `$(cat)` had read the whole stream
# and command substitution had stripped every trailing newline -- so a small valid object
# followed by a large newline run was read in full and measured as only the object. Every
# ceiling sat downstream of that read, guarding work already paid for.
#
# The COMMAND here is deliberately innocuous. A payload carrying `rm -rf src` blocks
# either way -- on the classifier rather than the size -- so it cannot tell the versions
# apart and would certify nothing. With `ls -la`, the old gate measures 63 bytes and
# ALLOWS, while an honest measurement puts the stream past the Bash ceiling and refuses
# it. Verified against the pre-fix gate, which allows both sizes below.
#
# Asserted on the VERDICT, not on elapsed time: the wall clock here is dominated by the
# producer generating the suffix, so a timing threshold separated the two versions by
# only 0.3s on this machine and would invert on another.
for _mb in 1 16; do
    _SUFFIX_OUT="$(python3 -c '
import sys
sys.stdout.write("{\"tool_name\":\"Bash\",\"cwd\":\"" + sys.argv[1] +
                 "\",\"tool_input\":{\"command\":\"ls -la\"}}")
try:
    sys.stdout.write("\n" * (int(sys.argv[2]) * 1024 * 1024))
    sys.stdout.flush()
except BrokenPipeError:
    pass          # the gate stopped reading early, which is the point
' "$WORK" "$_mb" 2>/dev/null | (cd "$WORK" && bash "$GATE") 2>/dev/null)"
    case "$_SUFFIX_OUT" in
        *'too large'*) ok "a ${_mb}MB trailing suffix is measured and refused, not read past" ;;
        *) no "trailing-suffix measurement (${_mb}MB)" \
              "the stream was measured as just its leading object" ;;
    esac
done

# 3. `python3 -m <mod> <helper>` -- the walk stopped at the module and never looked at the
# operand, so any stdlib module that RUNS a script path executed the protected helper
# while the gate classified only the module name. The list of such modules is exactly the
# kind that fails OPEN on the one nobody enumerated, so the test drives the fail-closed
# direction: an UNKNOWN module must block.
for _m in cProfile profile pdb trace timeit runpy coverage totally_unknown_module; do
    check "python3 -m $_m running the helper is blocked" block \
        "$(bash_decision "python3 -m $_m hooks/gate-scripts/lib/lease_slot.py .claude 20 0 3600")"
done
# ...and the read-only modules the allowlist exists to protect stay allowed UNDER
# ISOLATED MODE, or the fix above is just a blanket block wearing a list. Both halves are
# asserted: bare blocks (the module name can be shadowed from the CWD), isolated allows.
for _m in json.tool tokenize ast dis py_compile; do
    check "python3 -I -m $_m only READING the helper stays allowed" allow \
        "$(bash_decision "python3 -I -m $_m hooks/gate-scripts/lib/lease_slot.py")"
    check "the same module WITHOUT isolation is not trusted" block \
        "$(bash_decision "python3 -m $_m hooks/gate-scripts/lib/lease_slot.py")"
done
# The operand is matched as a GLOB, because the shell expands it before python sees it.
# An exact-basename test never matches these spellings while the command still runs the
# helper -- the direct-script path already resolved operands this way, so an equality
# test here would have been a second, weaker matcher for the same question.
for _g in 'lease_slo[t].py' 'lease_slot*.py' 'lease_slo?.py' 'audit_appen[d].py'; do
    check "a glob-spelled helper behind -m is blocked ($_g)" block \
        "$(bash_decision "python3 -m cProfile hooks/gate-scripts/lib/$_g .claude 20 0 3600")"
done
check "a glob matching no helper stays allowed" allow \
    "$(bash_decision "python3 -m cProfile scripts/other*.py")"
check "a glob under an ISOLATED read-only module stays allowed" allow \
    "$(bash_decision "python3 -I -m json.tool hooks/gate-scripts/lib/lease_slo[t].py")"
# A runner module accepts its OWN -m, so the helper can be named as a MODULE and never
# carry a `.py` for the filename matcher to find.
check "a runner module re-dispatching -m to the helper is blocked" block \
    "$(bash_decision "PYTHONPATH=hooks/gate-scripts/lib python3 -m cProfile -m lease_slot .claude 20 0 3600")"
check "the same shape via pdb and audit_append is blocked" block \
    "$(bash_decision "PYTHONPATH=hooks/gate-scripts/lib python3 -m pdb -m audit_append")"
check "a runner module re-dispatching -m elsewhere stays allowed" allow \
    "$(bash_decision "python3 -m cProfile -m json.tool foo.json")"
# A runner takes ONE target and passes the rest through as argv, so the scan stops at the
# first script it would execute. Without that stop the helper was blocked while being mere
# data. The stop must not be reachable by an option OPERAND, or `-o out.prof <helper>`
# walks free -- which is why it keys on the `.py` suffix rather than on "first word after
# the module", and why both shapes are pinned here.
# The helper merely passed as ARGV to another profiled script is a KNOWN false block, and
# a deliberate one. Stopping the scan at the first `.py` operand would spare it, and was
# tried -- but an option operand can itself end in `.py`, so `-o out.py <helper>` then
# broke at out.py while cProfile still executed the helper. That trades a false block for
# a fail-OPEN. Any narrowing needs per-option arity, the table this file refuses because
# it fails open wherever it is wrong. Pinned as CURRENT behaviour so that changing it
# trips this line deliberately.
check "the helper as ARGV to another script over-blocks (deliberate)" block \
    "$(bash_decision "python3 -m cProfile safe.py hooks/gate-scripts/lib/lease_slot.py")"
check "the helper BEHIND an option operand is still blocked" block \
    "$(bash_decision "python3 -m cProfile -o out.prof hooks/gate-scripts/lib/lease_slot.py")"
check "...including when that operand itself ends in .py" block \
    "$(bash_decision "python3 -m cProfile -o out.py hooks/gate-scripts/lib/lease_slot.py")"
check "the helper as the profiled script itself is still blocked" block \
    "$(bash_decision "python3 -m pdb hooks/gate-scripts/lib/lease_slot.py")"

echo "── property checks over the splitter and the producer scan ──"
# Everything above is a FIXED case, generated or hand-written, so it only ever probes the
# shapes someone thought of. These two properties quantify over a grammar instead, which
# is what the parser rewrite -- operator runs, quote state, grouping depth -- actually
# needs: the failures it produced were all compositions nobody had listed.
#
# The generator is SEEDED, so a failure reproduces exactly and a green run means the same
# thing twice. Randomness without a fixed seed would make this suite flaky, which is worse
# than the gap it closes.
PROP_OUT="$(python3 - "$REPO_ROOT" <<'PY' 2>&1
import random, sys, os
sys.path.insert(0, os.path.join(sys.argv[1], "hooks", "gate-scripts", "lib"))
import cmdword

rnd = random.Random(20260803)
ATOM = ["ls", "git status", "echo hi", "printf 'a;b'", 'grep "x|y" f', "cat f",
        "rm -rf src", "sed -i s/a/b/ f", "true", "# note", "", "f() { :; }",
        "function g { :; }", 'A="1;2"', "eval ls"]
OPS = [" | ", " || ", " && ", " ; ", " & ", "\n", " |& "]
WRAP = [("", ""), ("( ", " )"), ("{ ", " ; }"), ("if true; then ", "; fi"),
        ("for i in 1; do ", "; done"), ("while false; do ", "; done")]

# P1 -- the splitter is LOSSLESS. Operator runs and segments must concatenate back to the
# normalized input: a dropped byte is a segment boundary the scan will read wrongly, and
# the quote-state and operator-run bugs this rewrite fixed all showed up as lost text.
p1 = 0
for _ in range(3000):
    pre, post = rnd.choice(WRAP)
    body = rnd.choice(OPS).join(rnd.choice(ATOM) for _ in range(rnd.randint(1, 5)))
    src = cmdword._normalize(pre + body + post)
    pairs, _ok = cmdword._split_with_ops(src)
    if "".join(o + g for o, g in pairs) != src:
        print("P1-FAIL", repr(src)); break
    p1 += 1
print("P1", "ok" if p1 == 3000 else "FAIL", p1)

# P2 -- a stated write handed to a shell always blocks, however the pipeline is dressed.
# This is the fail-OPEN direction: every regression in this file was a composition that
# made a real write read as inert, so it is quantified over rather than enumerated.
SHELL = ["bash", "sh", "zsh", "/bin/bash", "$SHELL", "env -S bash", "env -Sbash",
         "bash -s", "xargs -0 bash", "yash", "bash -",
         # EXTGLOB spellings: the parens are a PATTERN, not a group, and the last two are
         # unresolvable (a negation names all but its contents; an alternation names two
         # things) so they must reach the same verdict by the fail-CLOSED path instead.
         "/bin/ba+(s)h", "/bin/ba@(s)h", "ba!(x)h", "/bin/ba@(s|z)h",
         # ...and the SUBSTITUTION spellings, flat and nested, which the flat pattern
         # resolves or fails closed on respectively
         'echo "$(bash)"', 'echo "$($SHELL)"', 'echo "$( ($SHELL) )"',
         # ...and the receivers that are not shells but run what they read
         "python3", "perl", "tclsh", "awk -f -", "source /dev/stdin", ". /dev/stdin",
         "xargs", "make -f -", "sqlite3"]
LEAD = ["", "time ", "! ", "nohup ", "command "]
p2 = 0
for _ in range(3000):
    pre, post = rnd.choice(WRAP)
    # A COMMENT atom must be closed by a NEWLINE. Joined with `;` it swallows the rest of
    # the line -- including the payload -- and bash then executes nothing, so asserting a
    # block there would assert a false positive. This property found that itself once the
    # comment handling landed, which is the argument for having it.
    parts = []
    for _ in range(rnd.randint(0, 2)):
        atom = rnd.choice(ATOM)
        sep = "\n" if atom.lstrip().startswith("#") else rnd.choice([" ; ", " && ", "\n"])
        parts.append(atom + sep)
    noise = "".join(parts)
    cmd = pre + noise + "printf 'rm -rf src' | " + rnd.choice(LEAD) + rnd.choice(SHELL) + post
    if not cmdword.is_file_mod(cmd):
        print("P2-FAIL", repr(cmd)); break
    p2 += 1
print("P2", "ok" if p2 == 3000 else "FAIL", p2)

# P3 -- the command-position walk, COMPOSED rather than sampled. Four review rounds each
# found a prefix spelling the hand-written cases had missed (an assignment, `time`, a
# leading redirection, a compound container, an option of unknown arity), which is the
# signature of coverage by enumeration. The composition is mechanical, so generate it:
# every launcher against every prefix shape inside every container. Driven IN-PROCESS
# rather than through the gate because 312 gate invocations cost ~200s of wall clock;
# the gate-side spot checks above pin the twin.
LAUNCH = ["script -q /dev/null", "su", "runuser", "chroot /jail", "unshare",
          "nsenter -t 1", "newgrp", "sg users"]
PREFIX = ["", "FOO=1 ", "A=1 B=2 ", "time ", "time -p ", "exec ", "nohup ",
          "2>/dev/null ", "> /dev/null ", "env -i ", "sudo ", "time env -i ",
          "/usr/bin/time -o t.out ", "busybox ", "toybox "]
BOX = [("", ""), ("{ ", "; }"), ("if ", "; then :; fi"), ("while ", "; do :; done")]
p3 = p3bad = 0
for launcher in LAUNCH:
    for pre in PREFIX:
        for _open, _close in BOX:
            cmd = "printf 'rm -rf src' | " + _open + pre + launcher + _close
            if cmdword.is_file_mod(cmd):
                p3 += 1
            else:
                p3bad += 1
                print("P3-FAIL", repr(cmd))
print("P3", "ok" if p3bad == 0 else "FAIL", p3)

# P4 -- and the precision that has to survive it. These are ordinary English words, so
# the same names as ARGUMENTS must stay allowed behind every prefix that is not itself a
# wrapper. (`sudo`/`env -i` are excluded deliberately: a wrapper hides the real program
# among its operands, so the whole stage is scanned there and the word cost is the
# documented price of that regime, not a launcher regression.)
NAMES = ["script", "su", "runuser", "chroot", "unshare", "nsenter", "newgrp", "sg"]
SAFE = ["", "FOO=1 ", "A=1 B=2 ", "time ", "time -p ", "2>/dev/null ",
        "> /dev/null ", "busybox "]
p4 = p4bad = 0
for nm in NAMES:
    for pre in SAFE:
        cmd = "echo 'rm -rf src' | " + pre + "grep -c " + nm
        if cmdword.is_file_mod(cmd):
            p4bad += 1
            print("P4-FAIL", repr(cmd))
        else:
            p4 += 1
print("P4", "ok" if p4bad == 0 else "FAIL", p4)
PY
)"
case "$PROP_OUT" in
    *"P1 ok 3000"*) ok "property: the splitter is lossless over 3000 seeded compositions" ;;
    *) no "property: the splitter is lossless" "$PROP_OUT" ;;
esac
case "$PROP_OUT" in
    *"P3 ok 480"*) ok "property: every launcher x prefix x container composition blocks (480)" ;;
    *) no "property: launcher composition" "$PROP_OUT" ;;
esac
case "$PROP_OUT" in
    *"P4 ok 64"*) ok "property: the same names as ARGUMENTS stay allowed (64)" ;;
    *) no "property: launcher-name precision" "$PROP_OUT" ;;
esac
case "$PROP_OUT" in
    *"P2 ok 3000"*) ok "property: a written payload piped to a shell always blocks (3000 seeded)" ;;
    *) no "property: a written payload piped to a shell always blocks" "$PROP_OUT" ;;
esac

printf "\n%d passed, %d failed\n" "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
