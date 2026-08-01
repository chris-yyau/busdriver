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
check "the helper as a -m json.tool operand stays allowed" allow \
    "$(bash_decision 'python3 -m json.tool hooks/gate-scripts/lib/lease_slot.py')"
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
_forge_dir="$(mktemp -d)"
if (cd "$_forge_dir" && mkdir -p .claude &&
    ! python3 -I "$REPO_ROOT/hooks/gate-scripts/lib/audit_append.py" .claude 1 20 2>/dev/null &&
    [ ! -e .claude/bypass-log.jsonl ]); then
    ok "audit_append has no record-writing CLI (a forged event exits non-zero, writes nothing)"
else
    no "audit_append has no record-writing CLI" "a standalone invocation minted an event"
fi
rm -rf "$_forge_dir"

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
# Asserted at 2.5s, HALF the 5s hook timeout, deliberately. Asserting at the timeout
# itself accepts any margin down to zero: a variant measured at 3.92s here passes a 5s
# assertion while being one slow CI box away from the fail-open it is supposed to
# prevent. The budget is a property of the slowest machine that will ever run this hook,
# not of this one, so the test demands room rather than a bare pass.
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
    if [ "$(python3 -c "print(1 if $_EL >= 2.5 else 0)")" = "1" ]; then
        _TIMED_FAIL=$((_TIMED_FAIL + 1))
        printf "  FAIL  %sKB padded command took %ss (budget is 2.5s = half the 5s hook timeout)\n" "$_kb" "$_EL"
    fi
done
if [ "$_TIMED_FAIL" -eq 0 ]; then
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
            if [ "$(python3 -c "print(1 if $_EL >= 2.5 else 0)")" = "1" ]; then
                _SPELL_FAIL=$((_SPELL_FAIL + 1))
                printf "  FAIL  key=%s cp%s n=%s took %ss (budget is 2.5s = half the 5s hook timeout)\n" \
                       "$_key" "$_cp" "$_n" "$_EL"
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

printf "\n%d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
