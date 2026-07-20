#!/usr/bin/env bash
# Tests for #347 — design-review marker hardening (items 1 + 2).
#
#   item 1  — fail-closed PRE-ARM: pre-implementation-gate.sh arms a new/unreviewed
#             design doc BEFORE the write and BLOCKS when the arm fails while the
#             marker dir is resolvable (the PostToolUse detector cannot block).
#   item 2  — Bash-write EFFECTIVE-DIRECTORY resolution: gitcmd_detect.effective_cwd
#             honors a leading `cd`, so the read gate anchors (2b) and the detector
#             arms (2a) against the repo a Bash write actually lands in.
#
# All marker/git manipulation happens INSIDE this script, so the PreToolUse marker
# guard sees only the top-level `bash tests/...` invocation (same property that makes
# the review loop's inline prune legal). Usage: bash tests/test-design-marker-cd-prearm.sh
#
# SC2016: several test strings intentionally contain a literal $-expansion (e.g. cd "$D")
# to exercise the unresolvable-cd path — they must NOT expand.
# shellcheck disable=SC2312,SC2015,SC2016
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
ROOT="$(pwd)"
R="$ROOT/hooks/gate-scripts/lib/resolve-repo-dir.sh"
G="$ROOT/hooks/gate-scripts/lib/gitcmd_detect.py"
PREIMPL="$ROOT/hooks/gate-scripts/pre-implementation-gate.sh"
CHECKDOC="$ROOT/hooks/gate-scripts/check-design-document.sh"

PASS=0; FAIL=0
ok(){ printf "  PASS  %s\n" "$1"; PASS=$((PASS + 1)); }
no(){ printf "  FAIL  %s :: %s\n" "$1" "${2:-}"; FAIL=$((FAIL + 1)); }
eq(){ [ "$2" = "$3" ] && ok "$1" || no "$1" "want=$3 got=$2"; }

TMPS=()
mkrepo(){
    local d; d="$(mktemp -d)"; TMPS+=("$d")
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
# effective_cwd CLI: prints cwd + exit 0, or exit 4 (unresolvable).
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

echo ""
echo "──────────────────────────────────────────────"
printf "  %d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
