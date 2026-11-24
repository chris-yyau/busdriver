#!/usr/bin/env bash
# Tests for #347 — design-review marker hardening (items 1 + 2 + 4).
#
#   item 1  — fail-closed PRE-ARM: pre-implementation-gate.sh arms a new/unreviewed
#             design doc BEFORE the write and BLOCKS when the arm fails while the
#             marker dir is resolvable (the PostToolUse detector cannot block).
#   item 2  — Bash-write EFFECTIVE-DIRECTORY resolution: gitcmd_detect.effective_cwd
#             honors a leading `cd`, so the read gate anchors (2b) and the detector
#             arms (2a) against the repo a Bash write actually lands in.
#   item 4  — STATE_DIR write-allowlist resolves against the PAYLOAD cwd (ADR 0023):
#             a relative `.claude/impl.py` sent with payload cwd = <repo>/src and gate
#             cwd = <repo> must NOT be exempted as a repo-root `.claude/` config write.
#
# All marker/git manipulation happens INSIDE this script, so the PreToolUse marker
# guard sees only the top-level `bash tests/...` invocation (same property that makes
# the review loop's inline prune legal). Usage: bash tests/test-design-marker-cd-prearm.sh
#
# SC2016: several test strings intentionally contain a literal $-expansion (e.g. cd "$D")
# to exercise the unresolvable-cd path — they must NOT expand.
# shellcheck disable=SC2312,SC2015,SC2016
set -uo pipefail
. "$(dirname "$0")/lib/git-env-isolation.sh" || exit 1
cd "$(dirname "$0")/.." || exit 1
ROOT="$(pwd)"
. "$ROOT/tests/lib/gate-cwd-isolation.sh" || exit 1   # #1064
R="$ROOT/hooks/gate-scripts/lib/resolve-repo-dir.sh"
G="$ROOT/hooks/gate-scripts/lib/gitcmd_detect.py"
PREIMPL="$ROOT/hooks/gate-scripts/pre-implementation-gate.sh"
CHECKDOC="$ROOT/hooks/gate-scripts/check-design-document.sh"

PASS=0; FAIL=0
ok(){ printf "  PASS  %s\n" "$1"; PASS=$((PASS + 1)); }
no(){ printf "  FAIL  %s :: %s\n" "$1" "${2:-}"; FAIL=$((FAIL + 1)); }
eq(){ [ "$2" = "$3" ] && ok "$1" || no "$1" "want=$3 got=$2"; }

TMPS=()
# Every repo lives under one parent made here, in the parent shell: mkrepo runs in a
# command substitution (`X="$(mkrepo)"`), where TMPS+= is lost and the repo leaked.
REPOS="$(mktemp -d)"; TMPS+=("$REPOS")
mkrepo(){
    local d; d="$(mktemp -d "$REPOS/r.XXXXXX")"
    git -C "$d" init -q
    git -C "$d" config user.email t@t; git -C "$d" config user.name t
    git -C "$d" commit -q --allow-empty -m init
    printf '%s' "$d"
}
cleanup(){ local d; for d in "${TMPS[@]:-}"; do [ -n "$d" ] && rm -rf "$d"; done; }
trap cleanup EXIT

arm(){ bash "$R" arm "$1" >/dev/null 2>&1; }
# gate_marker_pending exit: 0 none / 1 pending / 2 failure.
pending_code(){ local c=0; bash "$R" pending "$1" >/dev/null 2>&1 || c=$?; echo "$c"; }
# effective_cwd CLI: always exits 0 and prints the best-effort resolved cwd
# (exit 2 is reserved for bad CLI usage, e.g. a missing "effective-cwd" arg).
eff(){ local out c; out="$(printf '%s' "$2" | python3 -S "$G" effective-cwd "$1" 2>/dev/null)"; c=$?; printf '%s|%s' "$c" "$out"; }

# Run a gate with a JSON payload on stdin; sets OUT (stdout) and blocked? via grep.
run_gate(){ OUT="$(printf '%s' "$2" | bash "$1" 2>/dev/null)"; }
# block_emit pretty-prints via jq (spaces/newlines), so strip whitespace before matching.
is_block(){ printf '%s' "$OUT" | tr -d ' \n' | grep -q '"decision":"block"' && echo 1 || echo 0; }

bash_payload(){ jq -cn --arg c "$1" --arg cwd "$2" '{tool_name:"Bash",tool_input:{command:$c},cwd:$cwd}'; }
write_payload(){ jq -cn --arg fp "$1" --arg cwd "$2" '{tool_name:"Write",tool_input:{file_path:$fp},cwd:$cwd}'; }
edit_payload(){ jq -cn --arg fp "$1" --arg cwd "$2" '{tool_name:"Edit",tool_input:{file_path:$fp,old_string:"a",new_string:"b"},cwd:$cwd}'; }

echo "── effective_cwd (item 2 engine) ────────────────────────────────"
# effective_cwd STATS the cd target (a failed cd changes nothing), so use REAL dirs.
EB="$(mktemp -d)"; TMPS+=("$EB"); mkdir -p "$EB/other" "$EB/sub"
eq "no cd → payload cwd"            "$(eff "$EB" '> out.txt')"                        "0|$EB"
eq "abs cd (exists) → target"       "$(eff "$EB" "cd $EB/other && > out.txt")"        "0|$EB/other"
eq "; cd (exists) → target"         "$(eff "$EB" "cd $EB/other ; sed -i s/a/b/ f")"   "0|$EB/other"
eq "; cd MISSING → prior (cd failed)" "$(eff "$EB" "cd $EB/nope ; sed -i s/a/b/ f")"  "0|$EB"
: >"$EB/afile"   # a regular file: `cd /path/file` fails ("not a directory")
eq "; cd a FILE → prior (cd failed)" "$(eff "$EB" "cd $EB/afile ; sed -i s/a/b/ f")"  "0|$EB"
eq "leading assignment + cd"        "$(eff "$EB" "X=1 cd $EB/other && > f")"          "0|$EB/other"
# Relative cd is NOT resolved (CDPATH could redirect it) → payload anchor, same repo.
eq "relative cd → payload (CDPATH-unsafe)" "$(eff "$EB" 'cd sub && sed -i s/a/b/ f')"  "0|$EB"
eq "builtin cd → target"            "$(eff "$EB" "builtin cd $EB/other && > f")"      "0|$EB/other"
eq "command cd → target"            "$(eff "$EB" "command cd $EB/other && > f")"      "0|$EB/other"
# A path-qualified /x/cd is an EXTERNAL program (child process) — it cannot move the
# parent shell's cwd, so its operand must NOT anchor the gate.
eq "path-qualified /x/cd → payload"  "$(eff "$EB" "$EB/cd $EB/other && > f")"          "0|$EB"
# Ambiguous shapes fall back to the payload cwd (BEST-EFFORT, not fail-closed).
eq "\$var cd → payload"             "$(eff "$EB" 'cd "$D" && > f')"                   "0|$EB"
eq ".. cd → payload"                "$(eff "$EB" 'cd /a/../b && > f')"                "0|$EB"
eq "two cds → payload"              "$(eff "$EB" "cd $EB/other && cd $EB/sub && > f")" "0|$EB"
eq "cd after command → payload"     "$(eff "$EB" "ls && cd $EB/other && > f")"        "0|$EB"
eq "cd behind || → payload"         "$(eff "$EB" "cd $EB/other || > f")"              "0|$EB"
# A command ran in the cd target before the ||, so the write lands there → keep the cd.
eq "cd && cmd || write → keeps cd"  "$(eff "$EB" "cd $EB/other && false || sed -i x f")" "0|$EB/other"
# '&' backgrounds `cd && cmd` in a subshell → the FOREGROUND write lands in payload, NOT
# the cd target, even though a command ran (seen_cmd). Must give up unconditionally.
eq "cd && cmd & write → payload"    "$(eff "$EB" "cd $EB/other && true & > f")"        "0|$EB"
eq "if-conditional cd → payload"    "$(eff "$EB" "if cd $EB/other ; then > f ; fi")"  "0|$EB"
eq "subshell cd → payload"          "$(eff "$EB" "( cd $EB/other ) && > f")"          "0|$EB"

echo "── item 2b · read gate anchors on the write's real repo ─────────"
# Cross-repo fail-open: from a CLEAN repo, `cd /pending-repo && <file-mod>` used to
# anchor on the clean cwd and ALLOW. Now it anchors on /pending-repo → BLOCK.
P="$(mkrepo)"; C="$(mkrepo)"
printf 'x\n' >"$P/doc.md"; arm "$P/doc.md"
eq "P armed"  "$(pending_code "$P")" "1"
eq "C clean"  "$(pending_code "$C")" "0"
run_gate "$PREIMPL" "$(bash_payload "cd $P && sed -i s/x/y/ doc.md" "$C")"
eq "(2b) cd /pending && sed → BLOCK" "$(is_block)" "1"
# `builtin cd` / `command cd` really change dir → must anchor on the pending repo too.
run_gate "$PREIMPL" "$(bash_payload "builtin cd $P && sed -i s/x/y/ doc.md" "$C")"
eq "(2b) builtin cd /pending && sed → BLOCK" "$(is_block)" "1"
# Same shape into the CLEAN repo → allowed.
run_gate "$PREIMPL" "$(bash_payload "cd $C && sed -i s/a/b/ doc.md" "$P")"
eq "(2b) cd /clean && sed → allow"   "$(is_block)" "0"
# Descending relative cd file-mod in a CLEAN repo → NOT a false block.
run_gate "$PREIMPL" "$(bash_payload 'cd sub && sed -i s/a/b/ f' "$C")"
eq "(2b) cd sub && sed (clean) → allow" "$(is_block)" "0"
# Best-effort: an unresolvable cd anchors on the payload cwd (here clean) → allow,
# same as the pre-existing cd-blind gate (never worse). Not fail-closed by design.
run_gate "$PREIMPL" "$(bash_payload 'cd "$D" && sed -i s/a/b/ f' "$C")"
eq "(2b) cd \$var && sed (clean payload) → allow" "$(is_block)" "0"

echo "── item 2a · detector arms the repo the write lands in ──────────"
# From an unrelated cwd O, `cd /R && > docs/plans/DESIGN-x.md` must arm R, not O.
Rr="$(mkrepo)"; O="$(mkrepo)"
mkdir -p "$Rr/docs/plans"; printf 'plan\n' >"$Rr/docs/plans/DESIGN-x.md"
run_gate "$CHECKDOC" "$(bash_payload "cd $Rr && > docs/plans/DESIGN-x.md" "$O")"
eq "(2a) detector armed R (the cd target)"  "$(pending_code "$Rr")" "1"
eq "(2a) detector did NOT arm O (payload cwd)" "$(pending_code "$O")" "0"
# Cross-repo forged-PASS: the anti-self-stamp's `git show HEAD:<rel>` must read the
# repo the write LANDS in, not the hook's process cwd. HR has a legit reviewed
# DESIGN-forge.md at HEAD; a Bash write `cd TR && > docs/plans/DESIGN-forge.md`
# plants a FORGED PASS in TR (never reviewed there). A cwd-bound `git show` would
# borrow HR's review and PRESERVE the forgery (fail-open); the target-repo-bound
# lookup finds nothing in TR → strips PASS→PENDING (PR #444 review).
HR="$(mkrepo)"; TR="$(mkrepo)"
mkdir -p "$HR/docs/plans"; printf 'plan\n<!-- design-reviewed: PASS -->\n' >"$HR/docs/plans/DESIGN-forge.md"
git -C "$HR" add -A >/dev/null 2>&1; git -C "$HR" commit -q -m reviewed
mkdir -p "$TR/docs/plans"; printf 'plan\n<!-- design-reviewed: PASS -->\n' >"$TR/docs/plans/DESIGN-forge.md"
( cd "$HR" && printf '%s' "$(bash_payload "cd $TR && > docs/plans/DESIGN-forge.md" "$HR")" | bash "$CHECKDOC" >/dev/null 2>&1 )
grep -q '<!-- design-reviewed: PENDING -->' "$TR/docs/plans/DESIGN-forge.md" \
    && ok "(2a) cross-repo forged PASS stripped (no review borrow)" \
    || no "(2a) cross-repo forged PASS stripped" "target PASS survived — cross-repo git-show borrow"

echo "── item 1 · fail-closed pre-arm (Write/Edit design docs) ────────"
# New unreviewed design doc → pre-arm arms it and ALLOWS the write.
A="$(mkrepo)"; mkdir -p "$A/docs/plans"; printf 'plan\n' >"$A/docs/plans/DESIGN-new.md"
run_gate "$PREIMPL" "$(write_payload "$A/docs/plans/DESIGN-new.md" "$A")"
eq "(1) new design doc → allowed"  "$(is_block)" "0"
eq "(1) new design doc → pre-armed" "$(pending_code "$A")" "1"
# Arm FAILS (marker parent is a file, not a dir) while common-dir resolvable → BLOCK.
B="$(mkrepo)"; mkdir -p "$B/docs/plans"; printf 'plan\n' >"$B/docs/plans/DESIGN-b.md"
: >"$B/.git/busdriver"   # a FILE where the marker dir tree must go → makedirs fails
run_gate "$PREIMPL" "$(write_payload "$B/docs/plans/DESIGN-b.md" "$B")"
eq "(1) arm-failure → fail-closed BLOCK" "$(is_block)" "1"
printf '%s' "$OUT" | grep -qi 'could not arm the design-review marker' \
    && ok "(1) block names the arm failure" || no "(1) block names the arm failure" "$OUT"
# EDIT of an already-reviewed doc → allowed, NOT re-armed (small change preserves review).
Rev="$(mkrepo)"; mkdir -p "$Rev/docs/plans"
printf 'plan\n\n<!-- design-reviewed: PASS -->\n' >"$Rev/docs/plans/DESIGN-rev.md"
run_gate "$PREIMPL" "$(edit_payload "$Rev/docs/plans/DESIGN-rev.md" "$Rev")"
eq "(1) Edit of reviewed doc → allowed"      "$(is_block)" "0"
eq "(1) Edit of reviewed doc → NOT re-armed" "$(pending_code "$Rev")" "0"
# WRITE (rewrite) of a reviewed doc → re-opens review (re-armed), matching the detector —
# so a rewrite that removes/replaces PASS can never slip through unarmed (#347 round-3).
Rw="$(mkrepo)"; mkdir -p "$Rw/docs/plans"
printf 'plan\n\n<!-- design-reviewed: PASS -->\n' >"$Rw/docs/plans/DESIGN-rw.md"
run_gate "$PREIMPL" "$(write_payload "$Rw/docs/plans/DESIGN-rw.md" "$Rw")"
eq "(1) Write of reviewed doc → re-armed"    "$(pending_code "$Rw")" "1"

echo "── symlinked-parent exemption (physical grammar) ───────────────"
# A symlinked `docs/plans -> src` parent must not launder an impl write past the gate.
SL="$(mkrepo)"; mkdir -p "$SL/src" "$SL/docs"
ln -s ../src "$SL/docs/plans"                         # docs/plans -> src
printf 'x\n' >"$SL/realdoc.md"; arm "$SL/realdoc.md"  # a pending review exists in the repo
eq "(sym) repo has pending review" "$(pending_code "$SL")" "1"
# docs/plans/impl.md → physically src/impl.md (NOT a design doc) → NOT exempt → BLOCK.
run_gate "$PREIMPL" "$(write_payload 'docs/plans/impl.md' "$SL")"
eq "(sym) impl via symlinked docs/plans → BLOCK" "$(is_block)" "1"
# docs/plans/DESIGN.md → physically src/DESIGN.md, still a design doc by name → exempt.
run_gate "$PREIMPL" "$(write_payload 'docs/plans/DESIGN.md' "$SL")"
eq "(sym) DESIGN.md via symlinked docs/plans → allow" "$(is_block)" "0"
# A design-named LEAF symlink pointing at an impl file → physically an impl write → BLOCK.
mkdir -p "$SL/docs/specs"; ln -s ../../src/impl.sh "$SL/docs/specs/DESIGN.md"
run_gate "$PREIMPL" "$(write_payload 'docs/specs/DESIGN.md' "$SL")"
eq "(sym) leaf-symlink DESIGN.md -> impl.sh → BLOCK" "$(is_block)" "1"

echo "── ancestor named docs/plans must not launder impl .md ─────────"
M="$ROOT/hooks/gate-scripts/lib/marker_ops.py"
ddx(){ python3 -S "$M" dd-exempt "$1" ".claude" >/dev/null 2>&1; echo $?; }
AN="$(mktemp -d)"; TMPS+=("$AN")
RP="$AN/docs/plans/repo"; mkdir -p "$RP/src" "$RP/docs/plans"   # repo checked out UNDER docs/plans/
git -C "$RP" init -q; git -C "$RP" config user.email t@t; git -C "$RP" config user.name t
git -C "$RP" commit -q --allow-empty -m init
eq "(anc) repo's own src/impl.md NOT exempt" "$(ddx "$RP/src/impl.md")" "1"
eq "(anc) repo's own docs/plans/DESIGN.md exempt" "$(ddx "$RP/docs/plans/DESIGN.md")" "0"
# NOT-yet-created nested parent must still resolve repo-relative (walk up to existing dir).
eq "(anc) new nested src/new/impl.md NOT exempt" "$(ddx "$RP/src/new/impl.md")" "1"
eq "(anc) new nested docs/plans/n/DESIGN.md exempt" "$(ddx "$RP/docs/plans/n/DESIGN.md")" "0"
# gate_design_doc_exempt rc contract: 0 exempt / 1 not-a-doc / 2 error.
eq "(err) dd-exempt on non-design → 1" "$(ddx "$RP/src/util.go")" "1"

echo "── item 4 · STATE_DIR allowlist keys on the PAYLOAD cwd ────────"
# gate_marker_relpath resolves a RELATIVE path against the GATE PROCESS cwd. Pre-fix,
# a relative `.claude/impl.py` sent with payload cwd = <repo>/src and gate cwd = <repo>
# resolved gate-cwd-relative to `.claude/impl.py` → matched the STATE_DIR allowlist →
# EXEMPT, while the write actually lands at <repo>/src/.claude/impl.py — an impl file
# wrongly exempted (a design-review fail-OPEN, Codex litmus HIGH). The fix keys the arm
# on the payload-cwd-joined $_NORM_FP, matching the sibling design-doc arm. Both
# <repo>/.claude AND <repo>/src/.claude exist so gate_marker_relpath resolves either
# spelling physically — isolating the fix from a dir-missing confound (which would
# block for the wrong reason and hide a regression).
F="$(mkrepo)"; mkdir -p "$F/.claude" "$F/src/.claude"
printf 'x\n' >"$F/doc.md"; arm "$F/doc.md"
eq "(4) repo has pending review" "$(pending_code "$F")" "1"
# Run the gate FROM $F (gate process cwd = $F) with payload cwd = $F/src — the
# divergence the bug needs. Pass-after: BLOCK. Fail-before (raw $FILE_PATH): would
# resolve `.claude/impl.py` against $F → exempt → allow (the bypass).
OUT="$(cd "$F" && printf '%s' "$(write_payload '.claude/impl.py' "$F/src")" | bash "$PREIMPL" 2>/dev/null)"
eq "(4) relative .claude/impl.py from src cwd → BLOCK (no bypass)" "$(is_block)" "1"
# No false positive: a genuine repo-root `.claude/` config write (payload cwd = repo
# root) stays EXEMPT despite the pending review — the fix must not over-block.
OUT="$(cd "$F" && printf '%s' "$(write_payload '.claude/settings.json' "$F")" | bash "$PREIMPL" 2>/dev/null)"
eq "(4) genuine .claude/settings.json at repo root → allow (still exempt)" "$(is_block)" "0"
# Absolute impl path is unaffected (common case): resolves physically to src/… → BLOCK.
OUT="$(cd "$F" && printf '%s' "$(write_payload "$F/src/impl.py" "$F")" | bash "$PREIMPL" 2>/dev/null)"
eq "(4) absolute src/impl.py → BLOCK (unchanged)" "$(is_block)" "1"

echo "── item 4 (Greptile P1, #451) · missing/relative payload cwd fails CLOSED ──"
# A relative file_path with NO payload cwd field (or an empty one) must NOT fall back
# to a bare "." — that lexical no-op would leave $_NORM_FP relative, which both the
# design-doc arm and the STATE_DIR arm then resolve against the GATE PROCESS's own cwd
# (gate_marker_relpath's `git -C`/`cd`) instead of the payload's real effective
# directory — reopening the exact bypass item 4 closes, just triggered by an absent
# cwd instead of a present-but-different one. Gate process cwd = $F (repo root), so a
# pre-fix gate would resolve `.claude/impl.py` root-relative → EXEMPT → allow.
NO_CWD_PAYLOAD='{"tool_name":"Write","tool_input":{"file_path":".claude/impl.py"}}'
OUT="$(cd "$F" && printf '%s' "$NO_CWD_PAYLOAD" | bash "$PREIMPL" 2>/dev/null)"
eq "(4b) relative .claude/impl.py, cwd OMITTED → BLOCK (no bypass)" "$(is_block)" "1"
# An explicit empty-string cwd is the same falsy shape as omission — same fail-closed
# outcome.
OUT="$(cd "$F" && printf '%s' "$(write_payload '.claude/impl.py' '')" | bash "$PREIMPL" 2>/dev/null)"
eq "(4c) relative .claude/impl.py, cwd='' → BLOCK (no bypass)" "$(is_block)" "1"
# A literal "." payload cwd is not an anchor by itself either — same fail-closed
# outcome as omission (Greptile's report named this shape explicitly).
OUT="$(cd "$F" && printf '%s' "$(write_payload '.claude/impl.py' '.')" | bash "$PREIMPL" 2>/dev/null)"
eq "(4d) relative .claude/impl.py, cwd='.' → BLOCK (no bypass)" "$(is_block)" "1"
# No regression on the already-covered absolute-cwd divergence case (4) above, and no
# new false positive: an absolute-cwd genuine root config write still stays exempt —
# re-asserted here for clarity that the missing-cwd fix didn't touch that arm.
OUT="$(cd "$F" && printf '%s' "$(write_payload '.claude/settings.json' "$F")" | bash "$PREIMPL" 2>/dev/null)"
eq "(4e) genuine .claude/settings.json, absolute cwd=root → allow (still exempt)" "$(is_block)" "0"

echo "── #1081 · absolute redirect / tee / git -C targets are anchors too ──"
# A scanner that fails prints ERR, so it cannot pass a row that expects no anchors.
wa(){
    local o
    o="$(printf '%s' "$1" | python3 -S "$G" write-anchors 2>/dev/null)" || { printf 'ERR'; return; }
    [ -z "$o" ] || printf '%s\n' "$o" | tr '\n' ' '
}
eq "(wa) > /abs"             "$(wa 'printf x > /B/f')"                 "/B/f "
eq "(wa) attached >/abs"     "$(wa 'printf x>/B/f')"                   "/B/f "
eq "(wa) 2>> and &>"         "$(wa 'a 2>>/B/f; b &>/C/g')"             "/B/f /C/g "
eq "(wa) tee operands"       "$(wa 'a | tee -a /B/f -- -x/y /C/g')"   "/B/f /C/g "
# git runs in the LAST -C: an absolute one replaces, a relative one descends.
eq "(wa) git -C chain, abs"  "$(wa 'git -c a=b -C /B -C /D status')"   "/D "
eq "(wa) git -C chain, rel"  "$(wa 'git -C /B -C sub status')"         "/B/sub "
eq "(wa) adjacent redirects" "$(wa 'x>/B/f>>/C/g')"                    "/B/f /C/g "
eq "(wa) op then attached"   "$(wa 'x > /B/f>/C/g')"                   "/B/f /C/g "
eq "(wa) quoted > is data"   "$(wa "echo \"see >/B/f\" 'a>/C/g' > /D/r")" "/D/r "
eq "(wa) >&file opens a file" "$(wa 'a >&/B/f 2>&1 >&2')"               "/B/f "
eq "(wa) quoted space kept"  "$(wa 'a > "/B c/f"')"                    "/B c/f "
eq "(wa) glob unresolved"    "$(wa 'a > /B/f*')"                       ""
eq "(wa) brace expansion unresolved" "$(wa 'a | tee /B/{x,y}/f')"        ""
eq "(wa) quoted lone > is data" "$(wa "echo '>' /B/f \">\" /C/g > /D/r")" "/D/r "
eq "(wa) escaped space, quoted >" "$(wa 'echo a\ b ">" /B/f > /D/r')"  "/D/r "
eq "(wa) escaped quote, quoted >" "$(wa 'echo \"x ">" /B/f > /D/r')"  "/D/r "
eq "(wa) escaped space in path" "$(wa 'printf x > /B/a\ b')"           "/B/a b "
eq "(wa) quoted prefix, quoted >" "$(wa "echo 'a'b \">\" /B/f > /D/r")" "/D/r "
eq "(wa) op then quoted path" "$(wa 'x>"/B/f" 2>'"'"'/C/g'"'")"        "/B/f /C/g "
eq "(wa) digits stay in path" "$(wa 'x > /B/f2>/C/g')"                 "/B/f2 /C/g "
eq "(wa) command tee"        "$(wa 'a | command tee /B/f')"            "/B/f "
eq "(wa) sudo -u u tee -a"   "$(wa 'a | sudo -u root tee -a /B/f')"    "/B/f "
eq "(wa) env git -C"         "$(wa 'env A=1 git -C /B add .')"         "/B "
eq "(wa) substitution body"  "$(wa 'echo "$(printf x > /B/s)"')"       "/B/s "
eq "(wa) newline ends a command" "$(wa 'printf x
tee /B/f
echo "a
b" > /C/g')" "/B/f /C/g "
eq "(wa) >| and >& on a later line" "$(wa 'a
b >|/B/f
c >&/C/g')" "/B/f /C/g "
eq "(wa) a comment is not a redirect" "$(wa 'printf x > out # was: > /B/log')" ""
eq "(wa) apostrophe in a comment" "$(wa "printf x # don't
printf y > /F/f")" "/F/f "
eq "(wa) escaped space, then #" "$(wa 'echo a\ #b > /G/g')"  "/G/g "
eq "(wa) reserved word before tee"  "$(wa 'if tee /B/f; then :; fi')"      "/B/f "
eq "(wa) ! and while before tee"   "$(wa 'while ! tee -a /B/f; do :; done')" "/B/f "
eq "(wa) \$' inside double quotes is literal" "$(wa 'echo "it$'"'"'s" > /B/f')" "/B/f "
eq "(wa) && inside [[ ]] keeps the test" "$(wa '[[ a && b > /B/f ]] && printf x > /D/d')" "/D/d "
eq "(wa) [[ after if, tokenizer reads a comparison" "$(printf '%s' 'if [[ a > /B/f ]]; then :; fi' | python3 -S -c 'import sys; sys.path.insert(0, sys.argv[1]); from gitcmd_detect import _shell_commands, _cmd_write_anchors; print(" ".join(a for t in _shell_commands(sys.stdin.read()) for a in _cmd_write_anchors(t)))' "$(dirname "$G")" || printf ERR)" ""
eq "(wa) newline inside [[ ]] keeps the test" "$(wa '[[ a &&
b > /B/f ]] && printf x > /D/d')" "/D/d "
eq "(wa) comment continuation hiding a nested write still names it" "$(wa "printf x # c \\
bash -c 'printf x > /B/f'")" "/B/f "
# ACCEPTED OVER-BLOCK: the other reading cannot tell a quoted `#` from a comment, so
# a real continuation after one yields the next line's words as a destination too
# (bash passes them to printf). An extra anchor only adds a block; the root cause is
# the shared extractor joining a comment's trailing backslash.
eq "(wa) ACCEPTED OVER-BLOCK: quoted # before a real continuation" "$(wa "bash -c 'printf \"%s\" \"#\" \\
tee /B/f'")" "/B/f "
eq "(wa) backslash ending a comment does not continue it" "$(wa '# note \
printf x > /B/f')" "/B/f "
eq "(wa) plain \$'...' word is its literal" "$(wa "printf x > \$'/B/f'")" "/B/f "
eq "(wa) &> after a word"      "$(wa 'a&>/B/f tee /C/g')"          "/B/f "
# Fuzz: a fixed path spelled many ways (plain with escapes, single, double, double with
# a backslash-newline, plain and escaped $'...', unquoted continuations). Bash says
# what each spelling is; the scanner must name exactly that path, or say incomplete.
# It may never name a different one.
# shellcheck disable=SC2016  # python3 -c program; $ and quotes are literal code
WA_FUZZ="$(python3 -S -c '
import os, random, subprocess, sys
sys.path.insert(0, sys.argv[1])
from gitcmd_detect import write_anchors
rnd = random.Random(1081)
def esc(seg, chars):
    return "".join("\\" + c if c in chars else c for c in seg)
def enc(seg):
    k = rnd.randrange(7)
    if k == 0:
        return esc(seg, " \x27\"\\$`{}*?[#;&|<>()")
    if k == 1:
        return "\x27" + seg.replace("\x27", "\x27\\\x27\x27") + "\x27"
    if k == 2:
        return "\"" + esc(seg, "\"\\$`") + "\""
    if k == 3:
        body = esc(seg, "\"\\$`")
        cut = rnd.randrange(len(body) + 1)
        while cut and body[cut - 1] == "\\":
            cut -= 1
        return "\"" + body[:cut] + "\\\n" + body[cut:] + "\""
    if k == 4:
        return "$\x27" + seg.replace("\\", "\\\\").replace("\x27", "\\\x27") + "\x27"
    if k == 5:
        return "$\x27" + "".join("\\x%02x" % ord(c) for c in seg) + "\x27"
    return esc(seg, " \x27\"\\$`{}*?[#;&|<>()") + "\\\n"
bad = []
for n in range(300):
    path = "/B/" + "".join(rnd.choice("ab /\x27\"{,}#") for _ in range(rnd.randrange(1, 9))) + "f"
    path = os.path.normpath(path)
    pieces, i = [], 0
    while i < len(path):
        j = i + rnd.randrange(1, 4)
        pieces.append(path[i:j])
        i = j
    spelling = "".join(enc(p) for p in pieces)
    real = subprocess.run(["bash", "-c", "printf %s " + spelling], capture_output=True, text=True).stdout
    if real != path:
        continue                            # a spelling bash itself reads otherwise
    st = {}
    got = list(write_anchors("printf x > " + spelling, None, st))
    if got != [path] and not (got == [] and st.get("incomplete")):
        bad.append((spelling, got, st))
print(len(bad))
for b in bad[:3]:
    print(repr(b), file=sys.stderr)
' "$(dirname "$G")")"
eq "(wa) fuzz: every target spelling is bash's path or incomplete" "$WA_FUZZ" "0"
# The comment-continuation check stays linear on a long line of `#` words (a regex
# spanning `#` to the line end went quadratic), and still sees one that ends in `\`.
# shellcheck disable=SC2016  # python3 -c program; $ and quotes are literal code
WA_HASHES="$(python3 -S -c '
import sys, time
sys.path.insert(0, sys.argv[1])
from gitcmd_detect import _wa_comment_cont
long = "bash -c x; " + "# " * 200000
t0 = time.time()
r1 = _wa_comment_cont(long + "\nnext")
dt = time.time() - t0
r2 = _wa_comment_cont("bash -c x # note \\\nprintf x > /tmp/f")
r3 = _wa_comment_cont("printf a\\\nb")
print("fast" if dt < 0.5 else "slow %.2fs" % dt, r1, r2, r3)
' "$(dirname "$G")")"
eq "(wa) comment-continuation check: linear, and exact on both sides" "$WA_HASHES" "fast False True False"
# A long run of line continuations is walked once, not once per continuation: 40k of
# them take milliseconds walked once and ~15s, far past the 5s bound, walked per
# continuation, so a loaded machine cannot blur the two.
# shellcheck disable=SC2016  # python3 -c program; $ and quotes are literal code
WA_CONTS="$(python3 -S -c '
import sys, time
sys.path.insert(0, sys.argv[1])
from gitcmd_detect import write_anchors
c = "printf x >" + "\\\n" * 40000 + "| /B/f"
t0 = time.time()
st = {}
list(write_anchors(c, None, st))
print("fast" if time.time() - t0 < 5 else "slow", bool(st.get("incomplete")))
' "$(dirname "$G")" || printf ERR)"
eq "(wa) a long run of continuations: linear, and the split still seen" "$WA_CONTS" "fast True"
# Shapes the scan must call incomplete (it cannot place their target), and the
# read-only git it must not: `>\<newline>|` is bash's `>|`; a top-level comment
# ending in `\` hides the only nested script from the extractor; a `..` git -C path
# matters only when that git writes.
# shellcheck disable=SC2016  # python3 -c program; $ and quotes are literal code
WA_INC="$(python3 -S -c '
import sys
sys.path.insert(0, sys.argv[1])
import shlex
from gitcmd_detect import write_anchors
deep = "printf x > /B/f"
for _ in range(8):
    deep = "bash -c " + shlex.quote(deep)
def inc(c, w=None):
    st = {}
    list(write_anchors(c, w, st))
    return str(bool(st.get("incomplete")))
print(inc("printf x >\\\n| /B/f"),
      inc("printf x # note \\\nbash -c \x27printf x > /B/f\x27"),
      inc("git -C /B/../C status", lambda c: False),
      inc("git -C /B/../C commit", lambda c: True),
      inc("printf x > /B/f && \\\n  printf y > /C/g"),
      inc("printf x \\\n| tee src/f"),
      inc("cat > src/f <<\x27EOF\x27\nexample >\\\n|\n# c \\\nEOF"),
      inc("true &&\\\n> src/f"),
      inc("printf x &\\\n> /B/f"),
      inc("bash <<\x27EOF\x27\n# c \\\nprintf x > /B/f\nEOF"),
      inc("bash -c true; cat > src/f <<\x27EOF\x27\n# example \\\nEOF"),
      inc("printf %s \x27>\\\n|\x27 > src/f"),
      inc("printf x >\\\n> /B/f"),
      inc("printf x \\>>\\\n| /B/f"),
      inc("printf x \\\\>\\\n| /B/f"),
      inc("printf x # c \\\n" + deep))
' "$(dirname "$G")" || printf ERR)"
# Then: `&&` then `>` is unchanged by the join, `&` `>` becomes `&>`, a comment
# continuation in a heredoc body bash RUNS hides that body's next line; one in a body
# that is only data changes nothing, nor do quoted operator characters; `>` `>`
# joined is `>>`; after an escaped `\>` (a word character) `>` `|` is `>|`, and so
# it is after `\\>` (an escaped backslash, then the operator); and a comment
# continuation hiding a payload nested past the depth bound.
eq "(wa) split operator, hidden nested script, read-only vs writing git -C .., continuations that change nothing" \
    "$WA_INC" "True True False True False False False False True True False False True True True True"
eq "(wa) (( > )) compares"      "$(wa '(( a > 3 )) && printf x > /D/d')" "/D/d "
# ACCEPTED OVER-BLOCK: the shared payload reader (_shell_payloads, fail-closed for
# the commit detectors) reads the inside of `[[ ... ]]` as a possible eval payload,
# so a `>` comparison against an absolute path also anchors that path's repo.
eq "(wa) ACCEPTED OVER-BLOCK: [[ a > /abs ]]"   "$(wa '[[ a > /B/f ]] && printf x > /D/d')" "/D/d /B/f "
eq "(wa) ACCEPTED OVER-BLOCK: [[ \$v > /abs ]]" "$(wa '[[ $v > /B/f ]] && printf x > /D/d')" "/D/d /B/f "
eq "(wa) unreadable tail keeps what came before" "$(wa 'printf x > /B/f; echo "open')" "/B/f "
eq "(wa) a comment is not a pipeline" "$(wa 'printf x > out # old | tee /B/log')" ""
eq "(wa) heredoc body is input"   "$(wa 'cat <<X > /N/n
tee /B/log
X')" "/N/n "
eq "(wa) a quoted # is data"   "$(wa 'echo "#" > /D/r')"              "/D/r "
eq "(wa) top level before nested" "$(wa 'echo "$(printf x > /B/s)" > /T/top')" "/T/top /B/s "
eq "(wa) bash -c payload"    "$(wa 'bash -c "printf x > /B/c"')"       "/B/c "
# Device paths are not filtered here (a worktree under /dev/shm is a repository): the
# gate drops them because no repository contains them. Gate rows below pin that.
eq "(wa) /dev/shm path kept"  "$(wa 'printf x > /dev/shm/wt/f')"       "/dev/shm/wt/f "
eq "(wa) \$VAR unresolved"   "$(wa 'printf x > $HOME/f')"              ""
eq "(wa) relative ignored"   "$(wa 'git -C rel status > out')"         ""
eq "(wa) .. ignored"         "$(wa 'printf x > /a/../b/f')"            ""
eq "(wa) quoted and >|"      "$(wa 'a > "/B/f"; b >|/C/g')"            "/B/f /C/g "
# Gate: payload cwd is the CLEAN repo X, the write lands in the PENDING repo Y by
# absolute path. Before #1081 every row anchored on X and was allowed.
Y="$(mkrepo)"; X="$(mkrepo)"
printf 'x\n' >"$Y/doc.md"; arm "$Y/doc.md"
eq "(1081) Y armed" "$(pending_code "$Y")" "1"
eq "(1081) X clean" "$(pending_code "$X")" "0"
for c in "printf x > $Y/zz-probe.txt" \
         "printf x>$Y/zz-probe.txt" \
         "printf x | tee $Y/zz-probe.txt" \
         "printf x 2>&1 >>$Y/new/dir/zz-probe.txt" \
         "git -C $Y worktree add $X/zz-wt -b zz HEAD" \
         "echo \"\$(printf x > $Y/zz-probe.txt)\"" \
         "bash -c 'printf x > $Y/zz-probe.txt'" \
         "printf x > \"$Y/zz-probe.txt\"" \
         "printf x >|$Y/zz-probe.txt" \
         "printf x | command tee $Y/zz-probe.txt" \
         "printf x>\"$Y/zz-probe.txt\"" \
         "printf x | t'ee' $Y/zz-probe.txt"; do
    run_gate "$PREIMPL" "$(bash_payload "$c" "$X")"
    eq "(1081) $c → BLOCK" "$(is_block)" "1"
done
# A nested write that only the reading without a comment's trailing backslash sees
# (the shared extractor joins that backslash with the next line) is an anchor too:
# with a clean primary repository, a lease-free incomplete flag alone would allow it.
run_gate "$PREIMPL" "$(bash_payload "printf x # note \\
bash -c 'printf x > $Y/zz-probe.txt'" "$X")"
eq "(1081) comment continuation hides a nested write into pending Y → BLOCK" "$(is_block)" "1"
# A dangling link is followed, as a write follows it: its target is in pending Y.
ln -s "$Y/zz-dangling-target" "$X/zz-dl"
run_gate "$PREIMPL" "$(bash_payload "printf x > $X/zz-dl" "$X")"
eq "(1081) write through a dangling link into pending Y → BLOCK" "$(is_block)" "1"
rm -f "$X/zz-dl"
# A link to an EXISTING file is that file: its repository is the target's.
printf 'x\n' >"$Y/zz-existing"; ln -s "$Y/zz-existing" "$X/zz-fl"
run_gate "$PREIMPL" "$(bash_payload "printf x > $X/zz-fl" "$X")"
eq "(1081) write through a link to an existing file in pending Y → BLOCK" "$(is_block)" "1"
rm -f "$X/zz-fl" "$Y/zz-existing"
# A destination under a directory the hook may not search, inside pending Y: the
# directory cannot be placed exactly, but the repository around it still is.
if [ "$(id -u)" != "0" ]; then
    mkdir -p "$Y/zz-locked"; chmod 000 "$Y/zz-locked"
    run_gate "$PREIMPL" "$(bash_payload "printf x > $Y/zz-locked/f" "$X")"
    eq "(1081) write under an unsearchable dir in pending Y → BLOCK" "$(is_block)" "1"
    # A readable link in clean X whose target is inside that directory.
    ln -s "$Y/zz-locked/f" "$X/zz-to-locked"
    run_gate "$PREIMPL" "$(bash_payload "printf x > $X/zz-to-locked" "$X")"
    eq "(1081) write through a link into an unsearchable dir in pending Y → BLOCK" "$(is_block)" "1"
    rm -f "$X/zz-to-locked"
    chmod 700 "$Y/zz-locked"; rmdir "$Y/zz-locked"
else
    ok "(1081) write under an unsearchable dir in pending Y: skipped (running as root)"
    ok "(1081) write through a link into an unsearchable dir in pending Y: skipped (running as root)"
fi
# A path inside the clean repo that is a symlink into the pending one anchors on the
# repository it reaches: a file link, and a directory link.
ln -s "$Y/zz-probe.txt" "$X/flink"; ln -s "$Y" "$X/dlink"
for c in "printf x > $X/flink" "printf x | tee $X/dlink/zz-probe.txt"; do
    run_gate "$PREIMPL" "$(bash_payload "$c" "$X")"
    eq "(1081) symlink: $c → BLOCK" "$(is_block)" "1"
done
# The cwd itself is a link inside the pending repo that points into the clean one:
# the primary probe resolves physically (the clean repo), so the pending repo the
# command writes into by absolute path must still be checked as an extra.
ln -s "$X" "$Y/xlink"
run_gate "$PREIMPL" "$(bash_payload "printf x > $Y/zz-probe.txt" "$Y/xlink")"
eq "(1081) symlinked cwd into the clean repo, abs write into the pending one → BLOCK" "$(is_block)" "1"
rm -f "$Y/xlink"
# BEST-EFFORT (ADR 0021): a target the scan cannot carry or finish adds no anchor, the
# pre-#1081 verdict, and never a block of its own. A link that resolves to a
# repository whose path holds a newline cannot travel on the anchor list.
NLP="$(mktemp -d)"; TMPS+=("$NLP"); NLR="$NLP/a
b"; mkdir -p "$NLR"; git -C "$NLR" init -q; ln -s "$NLR" "$X/nlink"
run_gate "$PREIMPL" "$(bash_payload "printf x > $X/nlink/f" "$X")"
eq "(1081) ACCEPTED RESIDUAL: link to a newline-named repo → allow" "$(is_block)" "0"
rm -f "$X/nlink"
# The anchor scan skips a command over 64 KiB, but nothing that long reaches it: the
# marker_check scan above refuses any command past its own 32 KiB cap (#1109), on
# every command and before any anchor is read. Pinned so a change to either cap shows.
PAD="$(printf '%*s' 66000 '' | tr ' ' x)"
run_gate "$PREIMPL" "$(bash_payload "printf $PAD > $X/zz.txt" "$X")"
printf '%s' "$OUT" | grep -q 'too large or too deeply nested' \
    && ok "(1081) write over 64 KiB → BLOCK by the marker_check size cap" \
    || no "(1081) write over 64 KiB → BLOCK by the marker_check size cap" "$OUT"
# The serial probes check the first 16 other repositories, inside the hook timeout.
# Seventeen clean ones are allowed; the pending repo among the first 16 blocks, and
# past them it is not checked.
MANYR=""; for n in $(seq 1 17); do MANYR="${MANYR}printf x > $(mkrepo)/f; "; done
run_gate "$PREIMPL" "$(bash_payload "$MANYR" "$X")"
eq "(1081) writes into 17 clean repos → allow" "$(is_block)" "0"
run_gate "$PREIMPL" "$(bash_payload "printf x > $Y/zz-probe.txt; $MANYR" "$X")"
eq "(1081) pending repo first, then 17 clean → BLOCK" "$(is_block)" "1"
run_gate "$PREIMPL" "$(bash_payload "${MANYR}printf x > $Y/zz-probe.txt" "$X")"
eq "(1081) ACCEPTED RESIDUAL: pending repo after 17 others → allow" "$(is_block)" "0"
# A write nested past the chunk walk's depth bound is not read: no anchor, no error.
DEEP="printf x > $Y/zz-probe.txt"; for n in $(seq 1 8); do DEEP="bash -c $(printf '%q' "$DEEP")"; done
eq "(wa) truncated walk adds nothing" "$(wa "$DEEP")|$(printf '%s' "$DEEP" | python3 -S "$G" write-anchors >/dev/null 2>&1; echo $?)" "|0"
# Forty writes into other directories first: no cap hides the pending repo's anchor.
MANY=""; for n in $(seq 1 40); do MANY="${MANY}printf x > /tmp/zz-1081-$n/f; "; done
run_gate "$PREIMPL" "$(bash_payload "${MANY}printf x > $Y/zz-probe.txt" "$X")"
eq "(1081) 40 other targets, then the pending repo → BLOCK" "$(is_block)" "1"
[ ! -e "$Y/zz-probe.txt" ] && ok "(1081) gate only classified (no probe file)" \
    || no "(1081) gate only classified" "probe file exists"
# No over-block: a READ of the pending repo, a write into another CLEAN repo, and a
# write outside any repo are all still allowed from the clean cwd.
X2="$(mkrepo)"
for c in "git -C $Y status" \
         "git -C $Y status > $X/report.txt" \
         "git -C $Y log --oneline | tee $X/report.txt" \
         "echo \"copied >$Y/doc.md\" > $X/report.txt" \
         "cat $Y/doc.md > $X/out.txt" \
         "printf x > $X2/zz.txt" \
         "printf x | tee $X2/zz.txt" \
         "printf x > /tmp/zz-1081-\$\$.txt" \
         "ls 2>/dev/null >/dev/stderr; printf x > $X/out.txt"; do
    run_gate "$PREIMPL" "$(bash_payload "$c" "$X")"
    eq "(1081) $c → allow" "$(is_block)" "0"
done
# A skip lease is armed for ONE repository's pending review: it carries a write into
# that repository (relatively, by absolute path, or into a linked worktree that shares
# its markers), and never a write into ANOTHER repository with its own pending review.
# The lease lives in the hook's working directory ($STATE_DIR is relative), so these
# rows run the gate from the session repository L.
L="$(mkrepo)"; mkdir -p "$L/.claude" "$L/src"; printf 'x\n' >"$L/doc.md"; arm "$L/doc.md"
git -C "$L" worktree add -q "$REPOS/l-wt" -b l-wt >/dev/null 2>&1
lease_arm(){
    rm -rf "$L/.claude/.skip-design-review-lease.d"; : >"$L/.claude/skip-design-review.local"
    python3 -c 'import os,sys,time;t=time.time()-120;os.utime(sys.argv[1],(t,t))' \
        "$L/.claude/skip-design-review.local"
}
lease_drop(){ rm -rf "$L/.claude/.skip-design-review-lease.d" "$L/.claude/skip-design-review.local"; }
gate_in_L(){ OUT="$(printf '%s' "$(bash_payload "$1" "$L")" | (cd "$L" && bash "$PREIMPL") 2>/dev/null)"; }
for c in "printf x > src/f" "printf x > $L/src/f" "printf x > $REPOS/l-wt/f"; do
    lease_arm; gate_in_L "$c"
    eq "(1081) lease, same repo: $c → allow" "$(is_block)" "0"
done
lease_arm; gate_in_L "printf x > $Y/zz-probe.txt"
eq "(1081) lease for L, write into pending Y → BLOCK" "$(is_block)" "1"
# The block names Y's pending document, even when the primary repository is clean and
# made no records of its own (the scan subshell writes into the parent's records file).
run_gate "$PREIMPL" "$(bash_payload "printf x > $Y/zz-probe.txt" "$X")"
printf '%s' "$OUT" | grep -q 'doc.md' \
    && ! printf '%s' "$OUT" | grep -q 'to see the specific documents' \
    && ok "(1081) cross-repo block names Y's pending document" \
    || no "(1081) cross-repo block names Y's pending document" "$OUT"
printf '%s' "$OUT" | grep -q 'covers only that repository' \
    && ok "(1081) cross-repo block says the lease does not cover it" \
    || no "(1081) cross-repo block says the lease does not cover it" "$OUT"
lease_arm; gate_in_L "printf x > src/f; printf x | tee $Y/zz-probe.txt"
eq "(1081) lease for L, writes into L and pending Y → BLOCK" "$(is_block)" "1"
# The same with L clean: the extra still blocks, and no lease of L's is spent on it.
rm -rf "$(bash "$R" dir "$L")"
eq "(1081) L clean again" "$(pending_code "$L")" "0"
lease_arm; gate_in_L "printf x > $Y/zz-probe.txt"
eq "(1081) clean L with a lease, write into pending Y → BLOCK" "$(is_block)" "1"
[ -z "$(ls -A "$L/.claude/.skip-design-review-lease.d" 2>/dev/null)" ] \
    && ok "(1081) no lease use spent on the cross-repo write" \
    || no "(1081) no lease use spent on the cross-repo write" "$(ls -A "$L/.claude/.skip-design-review-lease.d")"
[ ! -e "$Y/zz-probe.txt" ] && ok "(1081) gate only classified (no probe file in Y)" \
    || no "(1081) gate only classified (no probe file in Y)" "probe file exists"
# A leading cd reaches another repository as surely as an absolute path does: L's
# lease does not carry it either (before #1081 it did).
lease_arm; gate_in_L "cd $Y && printf x > zz-probe.txt"
eq "(1081) lease for L, cd into pending Y and write → BLOCK" "$(is_block)" "1"
# Commands on separate lines are separate commands, as with `;`.
run_gate "$PREIMPL" "$(bash_payload "printf x
tee $Y/zz-probe.txt </dev/null" "$X")"
eq "(1081) tee into pending Y on a second line → BLOCK" "$(is_block)" "1"
# Every pending repository the command reaches is weighed: a pending L among them
# cannot vouch for another one, whichever of them is the primary anchor.
arm "$L/doc.md"
eq "(1081) L pending again" "$(pending_code "$L")" "1"
for c in "cd $Y && printf x > zz-probe.txt; printf x > $L/src/f" \
         "printf x > $L/src/f; printf x > $Y/zz-probe.txt" \
         "printf x > src/f; printf x > $L/src/g; printf x > $Y/zz-probe.txt"; do
    lease_arm; gate_in_L "$c"
    eq "(1081) lease for pending L, also reaches pending Y: $c → BLOCK" "$(is_block)" "1"
done
# The primary is clean (cd into X), L is reached by absolute path first, and Y after
# it: the scan must go on past L, or L's lease would carry the write into Y.
lease_arm; gate_in_L "cd $X && printf x > f; printf x > $L/src/f; printf x > $Y/zz-probe.txt"
eq "(1081) lease for L, cd clean X, then L and pending Y → BLOCK" "$(is_block)" "1"
lease_arm; gate_in_L "cd $X && printf x > f; printf x > $L/src/f"
eq "(1081) lease for L, cd clean X, then L only → allow (lease)" "$(is_block)" "0"
# No lease: the block for that shape names L's pending document (the records the
# scan made for L are the ones reported, not emptied as stale).
lease_drop
gate_in_L "cd $X && printf x > f; printf x > $L/src/f"
eq "(1081) cd clean X, then pending L by abs path → BLOCK" "$(is_block)" "1"
printf '%s' "$OUT" | grep -q 'doc.md' \
    && ok "(1081) that block names L's pending document" \
    || no "(1081) that block names L's pending document" "$OUT"
# The time budget (bash SECONDS counts from hook start; the contained launcher's env -i
# keeps a caller from presetting it, so a test may). Past 2s no repository probe
# starts: the extras go unchecked, the pre-#1081 verdict, and a lease is not used
# for a write the shortened scan could not place.
gate_slow(){ OUT="$(printf '%s' "$(bash_payload "$1" "$2")" | (cd "$2" && env SECONDS=3 bash "$PREIMPL") 2>/dev/null)"; }
gate_slow "printf x > $Y/zz-probe.txt" "$X"
eq "(1081) ACCEPTED RESIDUAL: no time left, abs write into pending Y → allow" "$(is_block)" "0"
lease_arm; gate_slow "printf x > src/f" "$L"
eq "(1081) no time left, lease for pending L → BLOCK (lease not used)" "$(is_block)" "1"
# The same when the python scan is cut short by a bound (16 repositories here; a
# deadline or parser failure reads the same): a destination may have gone unchecked,
# so the lease does not vouch for the command. A complete scan of the same shape does.
lease_arm; gate_in_L "printf x > src/f; $MANYR"
eq "(1081) lease for pending L, scan capped at 16 repos → BLOCK (lease not used)" "$(is_block)" "1"
printf '%s' "$OUT" | grep -q 'could be checked in time' \
    && ! printf '%s' "$OUT" | grep -q 'belongs to' \
    && ok "(1081) capped scan: the note says unchecked, not another repository's" \
    || no "(1081) capped scan: the note says unchecked, not another repository's" "$OUT"
lease_arm; gate_in_L "printf x > src/f; printf x > $X2/zz.txt"
eq "(1081) lease for pending L, complete scan, clean X2 → allow (lease)" "$(is_block)" "0"
# A directory the hook may not search (a privileged writer such as sudo tee can):
# the destination's repository cannot be placed, so the lease does not vouch for it.
if [ "$(id -u)" != "0" ]; then
    LOCKD="$(mkrepo)"; mkdir -p "$LOCKD/in"; chmod 000 "$LOCKD/in"
    lease_arm; gate_in_L "printf x > src/f; printf x > $LOCKD/in/f"
    eq "(1081) lease for pending L, unsearchable destination dir → BLOCK (lease not used)" "$(is_block)" "1"
    # A link whose target runs through that directory and back out (`in/sub/../..`):
    # resolved lexically it lands in LOCKD, which the hook can read; a writer that can
    # search `in` follows `sub` wherever it points.
    ln -s "$LOCKD/in/sub/../.." "$X2/zz-via-locked"
    lease_arm; gate_in_L "printf x > src/f; printf x > $X2/zz-via-locked/f"
    eq "(1081) lease for pending L, link through an unsearchable dir and .. → BLOCK (lease not used)" "$(is_block)" "1"
    rm -f "$X2/zz-via-locked"
    chmod 700 "$LOCKD/in"
    lease_arm; gate_in_L "printf x > src/f; printf x > $LOCKD/in/f"
    eq "(1081) lease for pending L, same destination searchable → allow (lease)" "$(is_block)" "0"
else
    ok "(1081) unsearchable destination dir: skipped (running as root)"
    ok "(1081) link through an unsearchable dir and ..: skipped (running as root)"
    ok "(1081) same destination searchable: skipped (running as root)"
fi
lease_arm; gate_in_L "$DEEP; printf x > src/f"
eq "(1081) lease for pending L, payload nested past the depth bound → BLOCK" "$(is_block)" "1"
# A write target spelled in a shape the scanner does not model (braces here), and a
# nested script whose comment ends in a backslash (the shared extractor joins it
# with the next line): either could hide a repository, so the lease is not used.
lease_arm; gate_in_L "printf x > src/f; printf x > /tmp/zz-1081-{a,b}"
eq "(1081) lease for pending L, brace-spelled target → BLOCK (lease not used)" "$(is_block)" "1"
lease_arm; gate_in_L "printf x > src/f; bash -c '# note \\
printf x > /tmp/zz-1081-c'"
eq "(1081) lease for pending L, nested comment continuation → BLOCK (lease not used)" "$(is_block)" "1"
lease_arm; gate_in_L "printf x > src/f # note \\
bash -c 'printf x > /tmp/zz-1081-c'"
eq "(1081) lease for pending L, top-level comment continuation → BLOCK (lease not used)" "$(is_block)" "1"
lease_arm; gate_in_L "git -C $X/../$(basename "$X") status; printf x > src/f"
eq "(1081) lease for pending L, read-only git -C with .. → allow (lease)" "$(is_block)" "0"
lease_arm; gate_in_L "printf x > src/f; bash -c 'printf x > /tmp/zz-1081-c'"
eq "(1081) lease for pending L, plain nested write outside repos → allow (lease)" "$(is_block)" "0"
# Exactly 16 other repositories is a COMPLETE scan: the lease still applies.
M16=""; for n in $(seq 1 16); do M16="${M16}printf x > $(mkrepo)/f; "; done
lease_arm; gate_in_L "printf x > src/f; $M16"
eq "(1081) lease for pending L, exactly 16 clean repos → allow (lease)" "$(is_block)" "0"
# A probe that STALLS. The scan runs under a hard deadline in a background subshell,
# so the hook still decides well inside its 5s timeout (an expired hook reads as
# ALLOW): the stalled repository goes unchecked, the primary verdict stands, and no
# lease is used. A git on PATH that hangs on one repository stands in for a slow disk.
SLOW="$(mkrepo)"; CRASH="$(mkrepo)"; RSLOW="$(mkrepo)"; SBIN="$REPOS/slowbin"; mkdir -p "$SBIN"
# The stalled probes sleep for a length unique to this run (8.<pid>), so a concurrent
# copy of this suite neither reports nor kills them.
NAP="8.$$"; NAP_RE="^sleep 8[.]$$\$"
# The test runner's own process group: CRASH must never take it down (that would hide
# the very regression it tests for, a scan left in this group).
RUNPG="$(ps -o pgid= -p $$ | tr -d ' ')"; SAMEPG="$REPOS/crash-same-group"
REALGIT="$(command -v git)"
# CRASH stands in for a scan that dies before its final word: it kills its own
# process group, which is the scan's (only the scan subshell probes extras).
# RSLOW stalls only the block-message renderer: its top-level lookup comes from shell,
# while the marker classifier asks the same question from python.
cat >"$SBIN/git" <<EOS
#!/bin/sh
case "\$*" in *"$SLOW"*) sleep $NAP ;; esac
case "\$*" in *"$RSLOW"*show-toplevel*)
    case "\$(ps -o comm= -p \$PPID)" in *[Pp]ython*) ;; *) sleep $NAP ;; esac ;;
esac
case "\$*" in *"$CRASH"*)
    pg="\$(ps -o pgid= -p \$\$ | tr -d ' ')"
    if [ "\$pg" = "$RUNPG" ]; then : >"$SAMEPG"; exit 1; fi
    kill -9 -"\$pg" ;;
esac
exec "$REALGIT" "\$@"
EOS
chmod +x "$SBIN/git"
gate_stall(){
    local t0 t1
    t0="$(python3 -c 'import time;print(time.time())')"
    OUT="$(printf '%s' "$(bash_payload "$1" "$2")" | (cd "$2" && PATH="$SBIN:$PATH" bash "$PREIMPL") 2>/dev/null)"
    t1="$(python3 -c 'import time;print(time.time())')"
    STALL_S="$(python3 -c 'import sys;print(round(float(sys.argv[2])-float(sys.argv[1]),1))' "$t0" "$t1")"
}
fast(){ python3 -c 'import sys;sys.exit(0 if float(sys.argv[1]) < 4.5 else 1)' "$STALL_S"; }
gate_stall "printf x > $SLOW/f; printf x > out.txt" "$X"
eq "(1081) stalled extra, clean primary → allow (extra unchecked)" "$(is_block)" "0"
fast && ok "(1081) stalled extra: hook decided in ${STALL_S}s (< 4.5s)" \
    || no "(1081) stalled extra: hook decided in time" "${STALL_S}s"
lease_arm; gate_stall "printf x > src/f; printf x > $SLOW/f" "$L"
eq "(1081) stalled extra, lease for pending L → BLOCK (lease not used)" "$(is_block)" "1"
fast && ok "(1081) stalled extra with a pending primary: decided in ${STALL_S}s (< 4.5s)" \
    || no "(1081) stalled extra with a pending primary: decided in time" "${STALL_S}s"
# A pending repository found BEFORE the stall still counts: here L (no lease armed),
# reached by absolute path after a cd into clean X, then the stalled repository.
rm -f "$L/.claude/skip-design-review.local"
gate_stall "cd $X && printf x > f; printf x > $L/src/f; printf x > $SLOW/f" "$L"
eq "(1081) pending L found, then a stall → BLOCK (finding kept)" "$(is_block)" "1"
# The kill takes the whole scan with it: no stalled probe is left running.
sleep 0.3
[ -z "$(pgrep -f "$NAP_RE" 2>/dev/null)" ] && ok "(1081) no stalled probe left running" \
    || no "(1081) no stalled probe left running" "$(pgrep -fl "$NAP_RE")"
# A scan that dies after publishing a finding, without its final word, is incomplete:
# L's lease does not vouch for the destinations it never reached.
lease_arm; gate_stall "cd $X && printf x > f; printf x > $L/src/f; printf x > $CRASH/f" "$L"
eq "(1081) scan dies after finding L, lease for L → BLOCK (lease not used)" "$(is_block)" "1"
[ ! -e "$SAMEPG" ] && ok "(1081) the scan's probes run outside the hook's process group" \
    || no "(1081) the scan's probes run outside the hook's process group" "probe shared the runner's group"
# A repository whose marker probe answers but whose block-message rendering stalls
# (the renderer asks git for its top level): the block still arrives in time, with
# the generic pending line in place of the document names.
printf 'x\n' >"$RSLOW/doc.md"; arm "$RSLOW/doc.md"
gate_stall "printf x > $RSLOW/zz-probe.txt" "$X"
eq "(1081) rendering stalls in a pending extra → BLOCK" "$(is_block)" "1"
fast && ok "(1081) rendering stall: hook decided in ${STALL_S}s (< 4.5s)" \
    || no "(1081) rendering stall: hook decided in time" "${STALL_S}s"
# L's list was rendered first (reached after a cd into clean X); the stalled render
# for RSLOW must not leave L's list standing in for RSLOW's.
lease_drop
gate_stall "cd $X && printf x > f; printf x > $L/src/f; printf x > $RSLOW/zz-probe.txt" "$L"
eq "(1081) L rendered, then RSLOW's render stalls → BLOCK" "$(is_block)" "1"
printf '%s' "$OUT" | grep -q 'to see the specific documents' \
    && ok "(1081) a stalled render shows the generic line, not L's list" \
    || no "(1081) a stalled render shows the generic line, not L's list" "$OUT"
# The scan finds a decisive repository and exits while the root resolver it started
# is still blocked on a later path (a python3 that hangs after answering stands in
# for a stalled lookup): the resolver goes with it, not left running.
PBIN="$REPOS/slowpy"; mkdir -p "$PBIN"
REALPY="$(command -v python3)"
cat >"$PBIN/python3" <<EOS
#!/bin/sh
case "\$*" in *"def root"*) : >"$REPOS/resolver-ran"; "$REALPY" "\$@"; sleep $NAP; exit 0 ;; esac
exec "$REALPY" "\$@"
EOS
chmod +x "$PBIN/python3"
lease_drop
SBIN="$PBIN" gate_stall "cd $X && printf x > f; printf x > $L/src/f" "$X"
eq "(1081) decisive hit while the resolver hangs → BLOCK" "$(is_block)" "1"
[ -e "$REPOS/resolver-ran" ] && ok "(1081) the hanging resolver stand-in actually ran" \
    || no "(1081) the hanging resolver stand-in actually ran" "stub not reached"
fast && ok "(1081) hanging resolver: hook decided in ${STALL_S}s (< 4.5s)" \
    || no "(1081) hanging resolver: hook decided in time" "${STALL_S}s"
sleep 0.3
[ -z "$(pgrep -f "$NAP_RE" 2>/dev/null)" ] \
    && ok "(1081) a resolver left hanging after a decisive hit is killed" \
    || no "(1081) a resolver left hanging after a decisive hit is killed" "$(pgrep -fl "$NAP_RE")"
pkill -f "$NAP_RE" 2>/dev/null || true
# A clean extra repository leaves the primary repository's document names intact.
rm -f "$L/.claude/skip-design-review.local"
gate_in_L "printf x > src/f; printf x > $X2/zz.txt"
printf '%s' "$OUT" | grep -q 'doc.md' \
    && ! printf '%s' "$OUT" | grep -q 'to see the specific documents' \
    && ok "(1081) clean extra keeps the primary's document names" \
    || no "(1081) clean extra keeps the primary's document names" "$OUT"
# A heredoc body is input, not commands, quoted delimiter or not; only the
# substitutions an UNQUOTED body expands run, and those are read.
run_gate "$PREIMPL" "$(bash_payload "cat > $X/notes.md <<E
printf x > $Y/zz-probe.txt
E" "$X")"
eq "(1081) unquoted heredoc body naming the pending repo → allow" "$(is_block)" "0"
run_gate "$PREIMPL" "$(bash_payload "cat > $X/notes.md <<E
\$(printf x > $Y/zz-probe.txt)
E" "$X")"
eq "(1081) unquoted heredoc body substitution writing into Y → BLOCK" "$(is_block)" "1"
run_gate "$PREIMPL" "$(bash_payload "cat > $X/notes.md <<'E'
printf x > $Y/zz-probe.txt
E" "$X")"
eq "(1081) quoted heredoc body is data → allow" "$(is_block)" "0"
# ACCEPTED RESIDUAL (write_anchors docstring): shapes whose target is not a literal
# redirect/tee/git -C operand still anchor on the payload cwd alone, as before #1081.
# The python row is how the #1081 incident itself wrote; ADR 0006 / #862.
for c in "cp $X/doc.md $Y/zz-probe.txt" \
         "python3 -c \"open('$Y/zz-probe.txt','w')\"" \
         "git --work-tree=$Y --git-dir=$Y/.git add ." \
         "D=$Y; printf x > \$D/zz-probe.txt"; do
    run_gate "$PREIMPL" "$(bash_payload "$c" "$X")"
    eq "(1081) ACCEPTED RESIDUAL: $c → allow" "$(is_block)" "0"
done

echo ""
echo "──────────────────────────────────────────────"
printf "  %d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
