#!/usr/bin/env bash
# Tests for #921 — the design-review detector arms on a Bash call's EFFECT, not its
# spelling. Each case drives check-design-document.sh the way the harness does: a
# PreToolUse payload (hook_event_name + tool_use_id), the command itself, then the post
# payload with the same id. The hook runs under the git config sanitized-gate.sh sets,
# with a temp HOME so the snapshot store lands in the fixture, from a hook cwd outside
# every fixture repository. Spec: docs/specs/2026-10-22-issue-921-design-gate-bash-effect-design.md
#
# All git and marker manipulation happens inside this script, so the PreToolUse gates see
# only the top-level `bash tests/...` invocation. Usage: bash tests/test-design-effect-921.sh
# shellcheck disable=SC2016,SC2312
set -uo pipefail
. "$(dirname "$0")/lib/git-env-isolation.sh" || exit 1
cd "$(dirname "$0")/.." || exit 1
ROOT="$(pwd)"
CHECKDOC="$ROOT/hooks/gate-scripts/check-design-document.sh"
LIB="$ROOT/hooks/gate-scripts/lib"
PY="$(command -v python3)"
NODE="$(command -v node || true)"
SYSPY=/usr/bin/python3

PASS=0; FAIL=0
ok(){ printf "  PASS  %s\n" "$1"; PASS=$((PASS + 1)); }
no(){ printf "  FAIL  %s :: %s\n" "$1" "${2:-}"; FAIL=$((FAIL + 1)); }
eq(){ if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "want=$3 got=$2"; fi; }
has(){ if printf '%s' "$2" | grep -qF -- "$3"; then ok "$1"; else no "$1" "missing [$3] in: $2"; fi; }
hasnt(){ if printf '%s' "$2" | grep -qF -- "$3"; then no "$1" "unexpected [$3] in: $2"; else ok "$1"; fi; }

TMP="$(mktemp -d)" && [ -d "$TMP" ] || { echo "mktemp failed" >&2; exit 1; }
ROWSNAP=""
cleanup(){ chmod -R u+rwx "$TMP" 2>/dev/null; rm -rf "$TMP"; [ -z "$ROWSNAP" ] || rm -f "$ROWSNAP"; }
trap cleanup EXIT
TH="$TMP/home"; HOOKCWD="$TMP/hookcwd"; TOOLS="$TMP/tools"
mkdir -p "$TH" "$HOOKCWD" "$TOOLS" "$TMP/src"
STORE="$TH/.claude/busdriver/design-effect.d"
ROOTUSER=0; [ "$(id -u)" = 0 ] && ROOTUSER=1

# rw.py <path> <old> <new>: in-place string replace, the #406 shape. `\n` in either
# string is a newline. A miss is recorded so no case can pass on a no-op rewrite.
cat >"$TOOLS/rw.py" <<'EOF'
import os, sys
p, a, b = (x.replace("\\n", "\n") for x in sys.argv[1:4])
s = open(p).read()
if a not in s:
    open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "misses"), "a").write(p + "\n")
    sys.exit(3)
open(p, "w").write(s.replace(a, b))
EOF
# put.py <path> <text>: create or overwrite a file (parents created).
cat >"$TOOLS/put.py" <<'EOF'
import os, sys
p, t = sys.argv[1], sys.argv[2]
os.makedirs(os.path.dirname(p) or ".", exist_ok=True)
open(p, "w").write(t.replace("\\n", "\n"))
EOF
# samestat.py <path> <old> <new>: a same-length replace that puts the mtime back.
cat >"$TOOLS/samestat.py" <<'EOF'
import os, sys
p, a, b = sys.argv[1], sys.argv[2].encode(), sys.argv[3].encode()
assert len(a) == len(b)
st = os.stat(p)
d = open(p, "rb").read()
if a not in d:
    open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "misses"), "a").write(p + "\n")
    sys.exit(3)
open(p, "wb").write(d.replace(a, b, 1))
os.utime(p, ns=(st.st_atime_ns, st.st_mtime_ns))
EOF
# rstrip.py <path>: drop trailing blank lines (the body hash ignores them).
cat >"$TOOLS/rstrip.py" <<'EOF'
import sys
p = sys.argv[1]
d = open(p, "rb").read()
open(p, "wb").write(d.rstrip(b"\n") + b"\n")
EOF
# stamp.sh <doc>: blueprint-review's own marker edits (in-place replace, /d, append).
cat >"$TOOLS/stamp.sh" <<'EOF'
d="$1"
sed -i.bak 's/<!-- design-reviewed: PENDING -->/<!-- design-reviewed: PASS -->/' "$d"
sed -i.bak '/<!-- design-review-coverage:/d' "$d"
rm -f "$d.bak"
grep -q '<!-- design-reviewed: PASS -->' "$d" || printf '\n<!-- design-reviewed: PASS -->\n' >>"$d"
printf '\n<!-- design-review-coverage: FULL 3/3 agy,codex,grok -->\n' >>"$d"
EOF

N=0
mkrepo(){   # mkrepo <dir> → initialised repo with an empty root commit
    mkdir -p "$1"; git -C "$1" init -q -b main
    git -C "$1" config user.email t@t; git -C "$1" config user.name t
    git -C "$1" config core.ignorecase false
    git -C "$1" commit -q --allow-empty -m init
}
commit_all(){ git -C "$1" add -A && git -C "$1" commit -q -m "${2:-c}" >/dev/null; }
mkdir_of(){ printf '%s/busdriver/design-review-needed.local.d' "$(git -C "$1" rev-parse --path-format=absolute --git-common-dir)"; }
tokens(){ local d; d="$(mkdir_of "$1")"; if [ -d "$d" ]; then find "$d" -type f | wc -l | tr -d ' '; else echo 0; fi; }
token_for(){   # 1 if a token whose body names <abs doc> exists in <repo>'s store
    local d; d="$(mkdir_of "$1")"; [ -d "$d" ] || { echo 0; return; }
    if grep -rqxF -- "$("$PY" -c 'import os,sys;print(os.path.realpath(os.path.dirname(sys.argv[1]))+"/"+os.path.basename(sys.argv[1]))' "$2")" "$d"; then echo 1; else echo 0; fi
}
clear_tokens(){ rm -rf "$(mkdir_of "$1")"; }
pass_line(){ grep -c '^<!-- design-reviewed: PASS -->$' "$1" 2>/dev/null | tr -d ' '; }
reviewed_doc(){ printf '# Design\n\nIntro line.\n\nSecond paragraph.\n\n<!-- design-reviewed: PASS -->\n'; }

payload(){   # payload <event|-> <command> <cwd> <id|-> → JSON (no event / id when "-")
    jq -cn --arg ev "$1" --arg c "$2" --arg cwd "$3" --arg id "$4" '
      {tool_name:"Bash", session_id:"sess-921", tool_input:{command:$c}, cwd:$cwd}
      + (if $ev == "-" then {} else {hook_event_name:$ev} end)
      + (if $id == "-" then {} else {tool_use_id:$id} end)'
}
hook(){   # hook <json> → OUT, ERR, RC
    local ef="$TMP/err.$N"
    OUT="$(printf '%s' "$1" | (cd "$HOOKCWD" && env -i PATH=/usr/bin:/bin HOME="$TH" \
        GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null /bin/bash "$CHECKDOC") 2>"$ef")"
    RC=$?; ERR="$(cat "$ef")"
}
# call <command> <cwd> [post-event] [post-cwd]: Pre, run the command in <cwd>, post.
call(){
    N=$((N + 1)); local id="tu-$N"
    hook "$(payload PreToolUse "$1" "$2" "$id")"; PRE_OUT="$OUT"; PRE_RC=$RC; PRE_ERR="$ERR"
    (cd "$2" && bash -c "$1") >/dev/null 2>&1
    hook "$(payload "${3:-PostToolUse}" "$1" "${4:-$2}" "$id")"
}

echo "── arms ────────────────────────────────────────────────────────"
R="$TMP/src/proj"; mkrepo "$R"   # an ancestor named src must not exclude its docs
reviewed_doc >"$R/DESIGN.md"; commit_all "$R"

call "\"$PY\" \"$TOOLS/rw.py\" DESIGN.md Intro Changed" "$R"
eq "python3 rewrite arms" "$(tokens "$R")" 1
eq "python3 rewrite downgrades PASS" "$(pass_line "$R/DESIGN.md")" 0
has "notice printed" "$OUT" "Design document written: DESIGN.md"
eq "Pre printed nothing" "$PRE_OUT" ""
eq "Pre exit 0" "$PRE_RC" 0
git -C "$R" checkout -q -- DESIGN.md; clear_tokens "$R"

if [ -n "$NODE" ]; then
    call "\"$NODE\" -e 'const f=require(\"fs\");f.writeFileSync(\"DESIGN.md\",f.readFileSync(\"DESIGN.md\",\"utf8\").replace(\"Intro\",\"Node\"))'" "$R"
    eq "node rewrite arms" "$(tokens "$R")" 1
    git -C "$R" checkout -q -- DESIGN.md; clear_tokens "$R"
else
    echo "  SKIP  node rewrite (node not installed)"
fi

call "sed -i.bak 's/Intro/Sed/' DESIGN.md && rm -f DESIGN.md.bak" "$R"
eq "sed -i arms" "$(tokens "$R")" 1
git -C "$R" checkout -q -- DESIGN.md; clear_tokens "$R"

printf '# Draft\n\nnew text\n' >"$TMP/draft.md"
call "W=\"$R\"; cp \"$TMP/draft.md\" \"\$W/DESIGN.md\"" "$R"
eq "cp through a variable destination arms" "$(tokens "$R")" 1
git -C "$R" checkout -q -- DESIGN.md; clear_tokens "$R"

git -C "$R" checkout -q -b other; "$PY" "$TOOLS/rw.py" "$R/DESIGN.md" Intro Other; commit_all "$R"
git -C "$R" checkout -q main
call "git checkout other -- DESIGN.md" "$R"
eq "git checkout <other> -- DESIGN.md arms" "$(tokens "$R")" 1
git -C "$R" reset -q --hard; clear_tokens "$R"

call "\"$PY\" \"$TOOLS/put.py\" docs/plans/x.md '# x\\n'" "$R"
eq "script creating untracked docs/plans/x.md arms" "$(token_for "$R" "$R/docs/plans/x.md")" 1
rm -rf "$R/docs"; clear_tokens "$R"

call "\"$PY\" \"$TOOLS/put.py\" sub/ARCHITECTURE.md '# a\\n' && \"$PY\" \"$TOOLS/put.py\" docs/specs/sub/y.md '# y\\n'" "$R"
eq "nested and upper-case docs both arm" "$(tokens "$R")" 2
rm -rf "$R/sub" "$R/docs"; clear_tokens "$R"

reviewed_doc >"$R/PLAN.md"; commit_all "$R"
call "\"$PY\" \"$TOOLS/rw.py\" DESIGN.md Intro A && \"$PY\" \"$TOOLS/rw.py\" PLAN.md Intro B" "$R"
eq "script rewriting two docs arms both" "$(tokens "$R")" 2
clear_tokens "$R"
call "\"$PY\" \"$TOOLS/rw.py\" DESIGN.md Second Again" "$R"
eq "second rewrite of an already-dirty doc arms" "$(tokens "$R")" 1
git -C "$R" checkout -q -- DESIGN.md PLAN.md; clear_tokens "$R"

call "\"$PY\" \"$TOOLS/rw.py\" DESIGN.md 'Intro line.' 'Intro\\n\\nline.'" "$R"
eq "paragraph split arms" "$(tokens "$R")" 1
git -C "$R" checkout -q -- DESIGN.md; clear_tokens "$R"
call "\"$PY\" \"$TOOLS/rw.py\" DESIGN.md 'Intro line.' 'Intro line.  '" "$R"
eq "two-space hard break arms" "$(tokens "$R")" 1
git -C "$R" checkout -q -- DESIGN.md; clear_tokens "$R"

call "\"$PY\" \"$TOOLS/rw.py\" DESIGN.md Intro Fails && false" "$R" PostToolUseFailure
eq "rewrite then false, via PostToolUseFailure, arms" "$(tokens "$R")" 1
git -C "$R" checkout -q -- DESIGN.md; clear_tokens "$R"

# Two roots: payload cwd in A, a leading absolute cd into B, a reviewed doc changed in each.
A="$TMP/two/a"; B="$TMP/two/b"; NOREPO="$TMP/two/none"; mkrepo "$A"; mkrepo "$B"; mkdir -p "$NOREPO"
reviewed_doc >"$A/DESIGN-a.md"; commit_all "$A"; reviewed_doc >"$B/DESIGN-b.md"; commit_all "$B"
for pc in "$A" "$B" "$NOREPO"; do
    call "cd \"$B\" && \"$PY\" \"$TOOLS/rw.py\" DESIGN-b.md Intro X && \"$PY\" \"$TOOLS/rw.py\" \"$A/DESIGN-a.md\" Intro X" "$A" PostToolUse "$pc"
    eq "two roots, post cwd $(basename "$pc"): A armed" "$(tokens "$A")" 1
    eq "two roots, post cwd $(basename "$pc"): B armed" "$(tokens "$B")" 1
    eq "two roots, post cwd $(basename "$pc"): A downgraded" "$(pass_line "$A/DESIGN-a.md")" 0
    eq "two roots, post cwd $(basename "$pc"): B downgraded" "$(pass_line "$B/DESIGN-b.md")" 0
    git -C "$A" checkout -q -- .; git -C "$B" checkout -q -- .; clear_tokens "$A"; clear_tokens "$B"
done

# Truncated coverage line, then a loop-style repair + PASS stamp, then a real edit.
C="$TMP/cov"; mkrepo "$C"
printf '# D\n\nBody.\n\n<!-- design-reviewed: PENDING -->\n<!-- design-review-coverage: FULL 3/\n' >"$C/DESIGN.md"; commit_all "$C"
call "bash \"$TOOLS/stamp.sh\" DESIGN.md" "$C"
eq "loop-style repair + PASS stamp does not arm" "$(tokens "$C")" 0
eq "PASS survives the stamp" "$(pass_line "$C/DESIGN.md")" 1
call "\"$PY\" \"$TOOLS/rw.py\" DESIGN.md Body. Edited." "$C"
eq "a real body edit after the stamp arms" "$(tokens "$C")" 1

# Exclusions: only the real design doc arms.
E="$TMP/excl"; mkrepo "$E"
call "\"$PY\" \"$TOOLS/put.py\" docs/reviews/DESIGN-x.md x && \"$PY\" \"$TOOLS/put.py\" agents/plan-x.md x && \"$PY\" \"$TOOLS/put.py\" docs/plans/real.md x" "$E"
eq "excluded paths do not arm" "$(tokens "$E")" 1
eq "real.md is the armed doc" "$(token_for "$E" "$E/docs/plans/real.md")" 1
rm -rf "$E/docs" "$E/agents"; clear_tokens "$E"
call "mkdir -p docs/reviews && echo x > docs/reviews/DESIGN-log.md && \"$PY\" \"$TOOLS/put.py\" docs/plans/real.md y" "$E"
eq "excluded redirect target does not stop the effect step" "$(token_for "$E" "$E/docs/plans/real.md")" 1
rm -rf "$E/docs"; clear_tokens "$E"

# Root A cannot arm (marker dir path is a regular file); root B still arms.
reviewed_doc >"$A/DESIGN-a.md"; commit_all "$A"
mkdir -p "$(git -C "$A" rev-parse --path-format=absolute --git-common-dir)"
rm -rf "$(git -C "$A" rev-parse --path-format=absolute --git-common-dir)/busdriver"
: >"$(git -C "$A" rev-parse --path-format=absolute --git-common-dir)/busdriver"
call "cd \"$B\" && \"$PY\" \"$TOOLS/rw.py\" DESIGN-b.md Intro Y && \"$PY\" \"$TOOLS/rw.py\" \"$A/DESIGN-a.md\" Intro Y" "$A"
has "arm failure in A is named" "$ERR" "could not arm the design-review marker for DESIGN-a.md"
eq "B still arms" "$(tokens "$B")" 1
rm -f "$(git -C "$A" rev-parse --path-format=absolute --git-common-dir)/busdriver"
git -C "$A" checkout -q -- .; git -C "$B" checkout -q -- .; clear_tokens "$B"

# Merges.
M="$TMP/merge"; mkrepo "$M"
printf '# D\n\nPara one.\n\nPara two.\n\n<!-- design-reviewed: PASS -->\n' >"$M/DESIGN.md"
mkdir -p "$M/src"; printf 'base\n' >"$M/src/a.txt"; commit_all "$M" base
git -C "$M" checkout -q -b side
"$PY" "$TOOLS/rw.py" "$M/DESIGN.md" "Para one." "Para one side."; printf 'side\n' >"$M/src/a.txt"; commit_all "$M" side
git -C "$M" checkout -q main
"$PY" "$TOOLS/rw.py" "$M/DESIGN.md" "Para two." "Para two main."; printf 'main\n' >"$M/src/a.txt"; commit_all "$M" main
call "git merge side" "$M"
eq "doc auto-merged from both sides, merge stopped on src/ conflict: arms" "$(tokens "$M")" 1
git -C "$M" reset -q --hard; clear_tokens "$M"

git -C "$M" checkout -q -b c1 main~1; "$PY" "$TOOLS/rw.py" "$M/DESIGN.md" "Para one." "Para one c1."; commit_all "$M" c1
git -C "$M" checkout -q -b c2 main~1; "$PY" "$TOOLS/rw.py" "$M/DESIGN.md" "Para one." "Para one c2."; commit_all "$M" c2
call "git merge c1" "$M"
eq "merge stopped on a conflict in the doc: no token" "$(tokens "$M")" 0
has "conflict bytes untouched" "$(cat "$M/DESIGN.md")" "<<<<<<<"
call "\"$PY\" \"$TOOLS/put.py\" DESIGN.md '# D\\n\\nResolved new.\\n' && git add DESIGN.md" "$M"
eq "conflict resolved with new content and staged: arms" "$(tokens "$M")" 1
git -C "$M" reset -q --hard; clear_tokens "$M"

# Index holds staged content != HEAD.
git -C "$M" checkout -q main
"$PY" "$TOOLS/rw.py" "$M/DESIGN.md" "Para one." "Para one staged."; git -C "$M" add DESIGN.md
"$PY" "$TOOLS/rw.py" "$M/DESIGN.md" "Para one staged." "Para one worktree."
call "git checkout -- DESIGN.md" "$M"
eq "checkout -- with index != HEAD != worktree: arms" "$(tokens "$M")" 1
clear_tokens "$M"
call "git checkout -- DESIGN.md" "$M"
eq "checkout -- with worktree == staged != HEAD: no token" "$(tokens "$M")" 0
git -C "$M" reset -q --hard

U="$TMP/unborn"; mkdir -p "$U"; git -C "$U" init -q -b main
call "\"$PY\" \"$TOOLS/put.py\" DESIGN.md '# new\\n'" "$U"
eq "unborn HEAD, new design doc: arms" "$(tokens "$U")" 1

SPC="$TMP/trailing space "; mkrepo "$SPC"; reviewed_doc >"$SPC/DESIGN.md"; commit_all "$SPC"
call "\"$PY\" \"$TOOLS/rw.py\" DESIGN.md Intro Spaced" "$SPC"
eq "repository path ending in a space: arms" "$(tokens "$SPC")" 1

# A repository path ending in a newline (the helpers here are line-based, so check the
# resolver directly).
NLTOP="$(cd "$HOOKCWD" && env -i PATH=/usr/bin:/bin GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null "$SYSPY" -I -c '
import os, subprocess, sys
sys.path.insert(0, sys.argv[1])
import design_effect
d = os.path.join(os.path.realpath(sys.argv[2]), "nl\n")
os.mkdir(d)
subprocess.run(["git", "init", "-q", d], check=True)
print(design_effect.toplevel(d) == d)' "$LIB" "$TMP")"
eq "repository path ending in a newline resolves unchanged" "$NLTOP" True

BIG="$TMP/big"; mkrepo "$BIG"
"$PY" -c "import sys; open(sys.argv[1],'w').write('# Big\n\n' + ('prose line\n' * 190000) + '\n<!-- design-reviewed: PASS -->\n')" "$BIG/DESIGN.md"
commit_all "$BIG"
call "\"$PY\" \"$TOOLS/rw.py\" DESIGN.md '# Big' '# Bigger'" "$BIG"
eq "2 MiB doc with edited prose: arms" "$(tokens "$BIG")" 1
git -C "$BIG" checkout -q -- DESIGN.md; clear_tokens "$BIG"

# Past MAX_BODY_BYTES a doc is hashed raw, not normalized: a change still arms (without a
# PASS downgrade, since nothing was compared to a revision), and an untouched dirty one
# does not.
HUGE="$TMP/huge"; mkrepo "$HUGE"
"$PY" -c "import sys; open(sys.argv[1],'w').write('# Huge\n\n' + ('prose line\n' * 400000) + '\n<!-- design-reviewed: PASS -->\n')" "$HUGE/DESIGN.md"
commit_all "$HUGE"
call "\"$PY\" \"$TOOLS/rw.py\" DESIGN.md '# Huge' '# Huger'" "$HUGE"
eq "oversize doc with edited prose: arms" "$(tokens "$HUGE")" 1
eq "oversize doc: PASS line untouched" "$(pass_line "$HUGE/DESIGN.md")" 1
clear_tokens "$HUGE"
call "ls" "$HUGE"; eq "oversize dirty doc, untouched: no token" "$(tokens "$HUGE")" 0
call "\"$PY\" \"$TOOLS/samestat.py\" DESIGN.md '# Huger' '# Hugee'" "$HUGE"
eq "oversize dirty doc, same size and mtime, new bytes: arms" "$(tokens "$HUGE")" 1

# A post-call status failure re-hashes an oversize snapshotted doc to the same `bighash:`
# the snapshot stored: untouched it does not arm, rewritten it does.
hugefb(){   # hugefb <command>: Pre, run the command, then diff with the status failing
    N=$((N + 1)); local id="tu-$N"
    hook "$(payload PreToolUse "$1" "$HUGE" "$id")"
    (cd "$HUGE" && bash -c "$1") >/dev/null 2>&1
    payload PostToolUse "$1" "$HUGE" "$id" | (cd "$HOOKCWD" && env -i PATH=/usr/bin:/bin HOME="$TH" \
        GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null "$SYSPY" -I -c '
import sys
lib = sys.argv[1]
sys.path.insert(0, lib)
import design_effect
def failed(*a):
    raise design_effect.GitError("status failed")
design_effect.candidates_for = failed
sys.exit(design_effect.main(["diff", lib]))' "$LIB") >/dev/null 2>&1
}
clear_tokens "$HUGE"
hugefb "ls"; eq "status fails, oversize dirty doc untouched: no token" "$(tokens "$HUGE")" 0
clear_tokens "$HUGE"; hugefb "\"$PY\" \"$TOOLS/rw.py\" DESIGN.md '# Hugee' '# Hugex'"
eq "status fails, oversize dirty doc rewritten: arms" "$(tokens "$HUGE")" 1

# A payload without a cwd: the hook process cwd is compared instead, with a warning.
NC="$TMP/nocwd"; mkrepo "$NC"; reviewed_doc >"$NC/DESIGN.md"; commit_all "$NC"
N=$((N + 1)); ncid="tu-$N"; nccmd="\"$PY\" \"$TOOLS/rw.py\" DESIGN.md Intro NoCwd"
SAVED_HOOKCWD="$HOOKCWD"; HOOKCWD="$NC"
hook "$(payload PreToolUse "$nccmd" "$NC" "$ncid" | jq -c 'del(.cwd)')"; NCERR="$ERR"
(cd "$NC" && bash -c "$nccmd") >/dev/null 2>&1
hook "$(payload PostToolUse "$nccmd" "$NC" "$ncid" | jq -c 'del(.cwd)')"
HOOKCWD="$SAVED_HOOKCWD"
eq "payload without cwd: the hook cwd is compared, arms" "$(tokens "$NC")" 1
has "payload without cwd: warns" "$NCERR" "payload cwd is missing or not absolute"

# ...and when the hook cwd is unresolvable too (deleted), the snapshot is still written:
# a command that `cd`s to an absolute repository is compared there and arms.
NG="$TMP/nogetcwd"; mkrepo "$NG"; reviewed_doc >"$NG/DESIGN.md"; commit_all "$NG"
N=$((N + 1)); ngid="tu-$N"; ngcmd="cd \"$NG\" && \"$PY\" \"$TOOLS/rw.py\" DESIGN.md Intro NoGetcwd"
NGERR="$(payload PreToolUse "$ngcmd" "$NG" "$ngid" | jq -c 'del(.cwd)' | (cd "$HOOKCWD" && env -i \
    PATH=/usr/bin:/bin HOME="$TH" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null "$SYSPY" -I -c '
import sys
lib = sys.argv[1]
sys.path.insert(0, lib)
import design_effect
def gone():
    raise FileNotFoundError(2, "No such file or directory")
design_effect.os.getcwd = gone
sys.exit(design_effect.main(["snap", lib]))' "$LIB") 2>&1 >/dev/null)"
bash -c "$ngcmd" >/dev/null 2>&1
hook "$(payload PostToolUse "$ngcmd" "$NG" "$ngid" | jq -c 'del(.cwd)')"
eq "payload without cwd, hook cwd unresolvable: the cd target is compared, arms" "$(tokens "$NG")" 1
has "payload without cwd, hook cwd unresolvable: warns" "$NGERR" "hook cwd is unresolvable"

# A post-call marker-dir lookup that eats the deadline (slow `rev-parse`) must not cost
# the comparison: the snapshot carries the marker dir, so a newly created doc still arms.
MD="$TMP/mdirsnap"; mkrepo "$MD"; commit_all "$MD"
N=$((N + 1)); mdid="tu-$N"; mdcmd="\"$PY\" \"$TOOLS/put.py\" docs/plans/fresh.md '# f\\n'"
hook "$(payload PreToolUse "$mdcmd" "$MD" "$mdid")"
(cd "$MD" && bash -c "$mdcmd") >/dev/null 2>&1
payload PostToolUse "$mdcmd" "$MD" "$mdid" | (cd "$HOOKCWD" && env -i PATH=/usr/bin:/bin \
    HOME="$TH" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null "$SYSPY" -I -c '
import sys
lib = sys.argv[1]
sys.path.insert(0, lib)
import design_effect
orig = design_effect.git
def git(root, args, *a, **k):
    if "--git-common-dir" in args:
        design_effect._START -= design_effect.DEADLINE_S + 1
    return orig(root, args, *a, **k)
design_effect.git = git
sys.exit(design_effect.main(["diff", lib]))' "$LIB") >/dev/null 2>&1
eq "post-call marker-dir lookup exhausting the deadline: a new doc still arms" "$(tokens "$MD")" 1

# A snap-time marker-dir lookup that eats the deadline must not cost a later root's dirty
# set: lookups run after every root is captured, so the cd target is still compared.
MA="$TMP/mdslow/a"; MB="$TMP/mdslow/b"; mkrepo "$MA"; mkrepo "$MB"; commit_all "$MA"
reviewed_doc >"$MB/DESIGN.md"; commit_all "$MB"
N=$((N + 1)); msid="tu-$N"; mscmd="cd \"$MB\" && \"$PY\" \"$TOOLS/rw.py\" DESIGN.md Intro SlowSnap"
payload PreToolUse "$mscmd" "$MA" "$msid" | (cd "$HOOKCWD" && env -i PATH=/usr/bin:/bin \
    HOME="$TH" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null "$SYSPY" -I -c '
import sys
lib = sys.argv[1]
sys.path.insert(0, lib)
import design_effect
orig = design_effect.git
def git(root, args, *a, **k):
    if "--git-common-dir" in args:
        design_effect._START -= design_effect.DEADLINE_S + 1
    return orig(root, args, *a, **k)
design_effect.git = git
sys.exit(design_effect.main(["snap", lib]))' "$LIB") >/dev/null 2>&1
(cd "$MA" && bash -c "$mscmd") >/dev/null 2>&1
hook "$(payload PostToolUse "$mscmd" "$MA" "$msid")"
eq "snap-time marker-dir lookup exhausting the deadline: the cd target still arms" "$(tokens "$MB")" 1

# A call that moves the git dir leaves the recorded marker dir under a gitfile; the
# post-call half looks it up again, so the token reaches the repository's new store.
SG="$TMP/sepgit"; mkrepo "$SG"; reviewed_doc >"$SG/DESIGN.md"; commit_all "$SG"
call "git init -q --separate-git-dir=\"$TMP/sepgit-dir\" && \"$PY\" \"$TOOLS/rw.py\" DESIGN.md Intro Moved" "$SG"
eq "git dir moved by the call: arms in the new store" "$(tokens "$SG")" 1

# A call that retargets a linked worktree's gitfile at another repository's worktree
# leaves the old common dir in place; the recorded marker dir no longer matches the
# filesystem, so the lookup reruns and the token reaches the new repository's store.
RP="$TMP/retarget/p"; RQ="$TMP/retarget/q"; mkrepo "$RP"; mkrepo "$RQ"
reviewed_doc >"$RP/DESIGN.md"; commit_all "$RP"; reviewed_doc >"$RQ/DESIGN.md"; commit_all "$RQ"
git -C "$RP" worktree add -q -b wp "$TMP/retarget/wp" 2>/dev/null
git -C "$RQ" worktree add -q -b wq "$TMP/retarget/wq" 2>/dev/null
RQGD="$(git -C "$TMP/retarget/wq" rev-parse --path-format=absolute --git-dir)"
call "printf 'gitdir: %s\\n' \"$RQGD\" >.git && \"$PY\" \"$TOOLS/rw.py\" DESIGN.md Intro Retarget" "$TMP/retarget/wp"
eq "gitfile retargeted by the call: arms in the new repository's store" "$(tokens "$TMP/retarget/wp")" 1

# The filesystem reading refuses what it cannot parse exactly as git does (a gitfile or
# commondir with an embedded newline, a CR, padding), so the lookup reruns instead.
FSC="$(cd "$HOOKCWD" && env -i PATH=/usr/bin:/bin "$SYSPY" -I -c '
import os, sys, tempfile
sys.path.insert(0, sys.argv[1])
import design_effect
out = []
for body in (b"gitdir: /x/old.git\nnew\n", b"gitdir: /x/a\r\n", b" gitdir: /x/a\n", b"gitdir: /x/a \n"):
    r = tempfile.mkdtemp()
    open(os.path.join(r, ".git"), "wb").write(body)
    out.append(str(design_effect._fs_common_dir(r)))
g = tempfile.mkdtemp(); r = tempfile.mkdtemp()
open(os.path.join(r, ".git"), "w").write("gitdir: " + g + "\n")
open(os.path.join(g, "commondir"), "wb").write(b"../old\nnew\n")
out.append(str(design_effect._fs_common_dir(r)))
print(" ".join(out))' "$LIB" 2>&1)"
eq "unparseable gitfile or commondir: no filesystem common dir" "$FSC" "None None None None None"

# A call can leave a FIFO where a gitfile, commondir or snapshotted doc was; opening it
# must not block (the alarm turns a hang into a failure): no filesystem common dir, and
# the fallback arms the doc as unreadable.
FIFO="$(cd "$HOOKCWD" && env -i PATH=/usr/bin:/bin "$SYSPY" -I -c '
import os, signal, sys, tempfile
signal.alarm(5)
sys.path.insert(0, sys.argv[1])
import design_effect
out = []
r = tempfile.mkdtemp(); os.mkfifo(os.path.join(r, ".git"))
out.append(str(design_effect._fs_common_dir(r)))
g = tempfile.mkdtemp(); r = tempfile.mkdtemp()
open(os.path.join(r, ".git"), "w").write("gitdir: " + g + "\n")
os.mkfifo(os.path.join(g, "commondir"))
out.append(str(design_effect._fs_common_dir(r)))
r = tempfile.mkdtemp(); os.makedirs(os.path.join(r, "docs", "plans"))
os.mkfifo(os.path.join(r, "docs", "plans", "f.md"))
out.append(repr(design_effect.fallback_candidates(r, {"docs/plans/f.md": "deadbeef"})))
import marker_ops
md = os.path.join(tempfile.mkdtemp(), "busdriver", "design-review-needed.local.d")
design_effect.process_doc(marker_ops, r, "docs/plans/f.md", False, md, ".claude", classify=False)
out.append(str(len(os.listdir(md))))
print(" ".join(out))' "$LIB" 2>/dev/null)"
eq "FIFO gitfile, commondir or doc: no hang, no common dir, doc arms" "$(printf '%s\n' "$FIFO" | tail -1)" "None None [('docs/plans/f.md', False)] 1"

# A committed doc past MAX_BODY_BYTES that the call shrinks below it: the pre-call blob
# is never fetched, so the doc arms without a PASS downgrade.
SHR="$TMP/shrink"; mkrepo "$SHR"
"$PY" -c "import sys; open(sys.argv[1],'w').write('# Shrink\n\n<!-- design-reviewed: PASS -->\n' + '\n' * 4500000)" "$SHR/DESIGN.md"
commit_all "$SHR"
call "\"$PY\" \"$TOOLS/rstrip.py\" DESIGN.md" "$SHR"
eq "oversize committed doc shrunk under the cap: arms" "$(tokens "$SHR")" 1
eq "oversize committed doc shrunk under the cap: PASS line untouched" "$(pass_line "$SHR/DESIGN.md")" 1

# A failed revision read: the command commits an unrelated file, then corrupts the
# pre-call HEAD's tree, so `ls-tree <pre-call HEAD>` fails while `git status` (which reads
# the new HEAD) still works; corrupting the tree, not a blob, makes the read itself fail.
H="$TMP/blobfail"; mkrepo "$H"; reviewed_doc >"$H/DESIGN.md"; commit_all "$H"
tree="$(git -C "$H" rev-parse 'HEAD^{tree}')"; obj="$H/.git/objects/${tree:0:2}/${tree:2}"
call "\"$PY\" \"$TOOLS/rw.py\" DESIGN.md Intro Blob && echo o > other.txt && git add other.txt && git commit -qm o -- other.txt && chmod 644 \"$obj\" && printf garbage > \"$obj\"" "$H"
eq "pre-call HEAD read fails: arms" "$(tokens "$H")" 1
eq "pre-call HEAD read fails: PASS line untouched" "$(pass_line "$H/DESIGN.md")" 1
has "pre-call HEAD read fails: warns" "$ERR" "revision read failed"

# Only a line holding nothing but the marker is dropped from the hash.
ML="$TMP/markerline"; mkrepo "$ML"; reviewed_doc >"$ML/DESIGN.md"
printf '<!-- design-review-coverage: FULL 3/3 agy,codex,grok -->\n' >>"$ML/DESIGN.md"; commit_all "$ML"
call "\"$PY\" \"$TOOLS/rw.py\" DESIGN.md 'PASS -->' 'PASS --> added text'" "$ML"
eq "text added after the PASS marker arms" "$(tokens "$ML")" 1
git -C "$ML" checkout -q -- DESIGN.md; clear_tokens "$ML"
call "\"$PY\" \"$TOOLS/rw.py\" DESIGN.md 'agy,codex,grok -->' 'agy,codex,grok --> added text'" "$ML"
eq "text added after the coverage marker arms" "$(tokens "$ML")" 1
git -C "$ML" checkout -q -- DESIGN.md; clear_tokens "$ML"
call "\"$PY\" \"$TOOLS/rw.py\" DESIGN.md '<!-- design-reviewed: PASS -->' '<!-- design-reviewed: PASS --> <!-- x -->'" "$ML"
eq "a second comment on the PASS line arms" "$(tokens "$ML")" 1
git -C "$ML" checkout -q -- DESIGN.md; clear_tokens "$ML"

# A repository the command only cd's into must not run its own configured programs
# before the call is approved. Each probe program leaves a marker file when it runs.
FM="$TMP/fsmon"; mkrepo "$FM"; reviewed_doc >"$FM/DESIGN.md"; commit_all "$FM"
printf '#!/bin/sh\ntouch "%s/fsmon-ran"\nexit 1\n' "$TMP" >"$TOOLS/fsmon.sh"; chmod +x "$TOOLS/fsmon.sh"
git -C "$FM" config core.fsmonitor "$TOOLS/fsmon.sh"
git -C "$FM" status >/dev/null 2>&1
eq "probe: plain git status runs the fsmonitor program" "$([ -e "$TMP/fsmon-ran" ] && echo ran || echo no)" ran
rm -f "$TMP/fsmon-ran"
call "cd \"$FM\" && \"$PY\" \"$TOOLS/rw.py\" DESIGN.md Intro F" "$A"
eq "cd into a repo with core.fsmonitor: its program never runs" "$([ -e "$TMP/fsmon-ran" ] && echo ran || echo no)" no
eq "cd into a repo with core.fsmonitor: still compared and armed" "$(tokens "$FM")" 1
git -C "$FM" config --unset core.fsmonitor

FL="$TMP/filter"; mkrepo "$FL"; reviewed_doc >"$FL/DESIGN.md"; printf 'a\n' >"$FL/a.txt"
printf '*.txt filter=probe\n' >"$FL/.gitattributes"
git -C "$FL" config filter.probe.clean "sh -c 'touch \"$TMP/filter-ran\"; cat'"
commit_all "$FL"; rm -f "$TMP/filter-ran"
"$PY" -c 'import os,sys,time; t=time.time()+5; os.utime(sys.argv[1], (t, t))' "$FL/a.txt"
git -C "$FL" status >/dev/null 2>&1
eq "probe: plain git status runs the clean filter" "$([ -e "$TMP/filter-ran" ] && echo ran || echo no)" ran
rm -f "$TMP/filter-ran"
"$PY" -c 'import os,sys,time; t=time.time()+9; os.utime(sys.argv[1], (t, t))' "$FL/a.txt"
call "cd \"$FL\" && \"$PY\" \"$TOOLS/rw.py\" DESIGN.md Intro F" "$A"
eq "cd into a repo with a filter program: it never runs" "$([ -e "$TMP/filter-ran" ] && echo ran || echo no)" no
has "cd into a repo with a filter program: named as not compared" "$PRE_ERR" "configures a clean/process filter"
git -C "$A" checkout -q -- .; clear_tokens "$A"

# A partial clone missing the doc's blob: reading it would lazily fetch through the repo's
# own core.sshCommand. The hook reads it with fetching disabled, so the probe never runs.
PC="$TMP/partial"; mkrepo "$PC"; reviewed_doc >"$PC/DESIGN.md"; commit_all "$PC"
printf '#!/bin/sh\ntouch "%s/ssh-ran"\nexit 1\n' "$TMP" >"$TOOLS/ssh.sh"; chmod +x "$TOOLS/ssh.sh"
git -C "$PC" config core.repositoryformatversion 1
git -C "$PC" config extensions.partialclone origin
git -C "$PC" config remote.origin.url ssh://probe.invalid/repo
git -C "$PC" config remote.origin.promisor true
git -C "$PC" config core.sshCommand "$TOOLS/ssh.sh"
blob="$(git -C "$PC" rev-parse HEAD:DESIGN.md)"; rm -f "$PC/.git/objects/${blob:0:2}/${blob:2}"
git -C "$PC" cat-file -p "$blob" >/dev/null 2>&1
eq "probe: a plain blob read lazily fetches through core.sshCommand" "$([ -e "$TMP/ssh-ran" ] && echo ran || echo no)" ran
rm -f "$TMP/ssh-ran"
call "\"$PY\" \"$TOOLS/rw.py\" DESIGN.md Intro P" "$PC"
eq "partial clone with a missing blob: no lazy fetch" "$([ -e "$TMP/ssh-ran" ] && echo ran || echo no)" no
eq "partial clone with a missing blob: still arms" "$(tokens "$PC")" 1
# `ls-tree -l` cannot size the missing blob, so it reads as oversize: no PASS downgrade.
eq "partial clone with a missing blob: PASS line untouched" "$(pass_line "$PC/DESIGN.md")" 1
# A blob ls-tree did size but cat-file then reports `missing` (pruned in between) is an
# unreadable object, not an absent path: the read fails, so nothing is downgraded.
MISS="$(cd "$HOOKCWD" && env -i PATH=/usr/bin:/bin GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null "$SYSPY" -I -c '
import sys
sys.path.insert(0, sys.argv[1])
import design_effect
orig = design_effect.git
def gone(root, args, *a, **k):
    if args[:1] == ["cat-file"]:
        return b"".join(o.split()[0] + b" missing\n" for o in k["stdin"].splitlines())
    return orig(root, args, *a, **k)
design_effect.git = gone
try:
    print(design_effect.revision_hashes(sys.argv[2], "HEAD", ["DESIGN.md"]))
except design_effect.GitError as e:
    print("GitError")' "$LIB" "$R" 2>&1)"
eq "revision blob listed by ls-tree but missing from cat-file: a failed read" "$MISS" GitError
# Cd'd into from another repo, with the promisor named only by partialclonefilter and a
# repo-level `protocol.ssh.allow=always` that beats a -c default: still no fetch, and the
# doc still arms. (No checkout here: restoring the doc would itself fetch the blob.)
clear_tokens "$PC"; git -C "$PC" config --unset remote.origin.promisor
git -C "$PC" config --unset extensions.partialclone; git -C "$PC" config remote.origin.partialclonefilter blob:none
git -C "$PC" config protocol.ssh.allow always
git -C "$PC" -c protocol.allow=never cat-file -p "$blob" >/dev/null 2>&1
eq "probe: the repo's protocol override beats -c protocol.allow=never" "$([ -e "$TMP/ssh-ran" ] && echo ran || echo no)" ran
rm -f "$TMP/ssh-ran"
call "cd \"$PC\" && \"$PY\" \"$TOOLS/rw.py\" DESIGN.md 'P line.' 'R line.'" "$A"
eq "cd into a partial clone with a protocol override: no lazy fetch" "$([ -e "$TMP/ssh-ran" ] && echo ran || echo no)" no
eq "cd into a partial clone: still arms" "$(tokens "$PC")" 1

echo "── does not arm ────────────────────────────────────────────────"
Q="$TMP/quiet"; mkrepo "$Q"; reviewed_doc >"$Q/DESIGN.md"; mkdir -p "$Q/src"; printf 'a\n' >"$Q/src/a.txt"; commit_all "$Q"
call "echo b > src/a.txt" "$Q"; eq "Bash write to src/a.txt" "$(tokens "$Q")" 0
call "\"$PY\" \"$TOOLS/rw.py\" DESIGN.md Intro Intro" "$Q"; eq "identical-content rewrite" "$(tokens "$Q")" 0
printf '# D\n\nBody.\n\n<!-- design-reviewed: PENDING -->\n' >"$Q/PLAN.md"; commit_all "$Q"
call "bash \"$TOOLS/stamp.sh\" PLAN.md" "$Q"; eq "loop-style stamp on a clean doc" "$(tokens "$Q")" 0
"$PY" "$TOOLS/rw.py" "$Q/PLAN.md" "Body." "Dirty body."; clear_tokens "$Q"
"$PY" "$TOOLS/rw.py" "$Q/PLAN.md" "PASS" "PENDING"
call "bash \"$TOOLS/stamp.sh\" PLAN.md" "$Q"; eq "loop-style stamp on a dirty doc" "$(tokens "$Q")" 0
git -C "$Q" checkout -q -- PLAN.md
"$PY" "$TOOLS/rw.py" "$Q/DESIGN.md" Intro Dirty
call "git checkout -- DESIGN.md" "$Q"; eq "checkout -- restoring HEAD" "$(tokens "$Q")" 0
"$PY" "$TOOLS/rw.py" "$Q/DESIGN.md" Intro Dirty
call "git commit -qam dirty" "$Q"; eq "git commit of an already-dirty doc" "$(tokens "$Q")" 0
"$PY" "$TOOLS/rw.py" "$Q/DESIGN.md" Dirty Edited
call "ls" "$Q"; eq "ls with a doc left dirty earlier" "$(tokens "$Q")" 0
git -C "$Q" checkout -q -- DESIGN.md

git -C "$Q" checkout -q -b feat; "$PY" "$TOOLS/put.py" "$Q/docs/specs/new.md" '# n\n\n<!-- design-reviewed: PASS -->\n'; commit_all "$Q"
git -C "$Q" checkout -q main
call "git merge -q feat" "$Q"; eq "fast-forward merge bringing in a reviewed spec" "$(tokens "$Q")" 0
call "git reset -q --soft HEAD~1" "$Q"; eq "reset --soft undoing a reviewed doc's commit" "$(tokens "$Q")" 0
git -C "$Q" commit -qm again
call "git reset -q HEAD~1" "$Q"; eq "reset (mixed) undoing a reviewed doc's commit" "$(tokens "$Q")" 0
git -C "$Q" add -A; git -C "$Q" commit -qm again2

# Merge and rebase stopped on src/ conflicts while bringing in a reviewed spec unchanged.
S="$TMP/stop"; mkrepo "$S"; mkdir -p "$S/src"; printf 'base\n' >"$S/src/a.txt"; commit_all "$S"
git -C "$S" checkout -q -b topic
"$PY" "$TOOLS/put.py" "$S/docs/specs/x.md" '# x\n\n<!-- design-reviewed: PASS -->\n'; printf 'topic\n' >"$S/src/a.txt"; commit_all "$S" topic
git -C "$S" checkout -q main; printf 'main\n' >"$S/src/a.txt"; commit_all "$S" main
call "git merge topic" "$S"
eq "merge stopped on src/ conflict bringing a reviewed spec: no token" "$(tokens "$S")" 0
eq "merge stop: PASS kept" "$(pass_line "$S/docs/specs/x.md")" 1
git -C "$S" merge --abort
git -C "$S" checkout -q topic
call "git rebase main" "$S"
eq "rebase stopped on src/ conflict bringing a reviewed spec: no token" "$(tokens "$S")" 0
eq "rebase stop: PASS kept" "$(pass_line "$S/docs/specs/x.md")" 1
git -C "$S" rebase --abort

# pull --rebase --autostash over a marker-only local edit; upstream changed the prose.
UP="$TMP/up"; mkrepo "$UP"; reviewed_doc >"$UP/DESIGN.md"; commit_all "$UP"
CL="$TMP/clone"; git clone -q "$UP" "$CL"; git -C "$CL" config user.email t@t; git -C "$CL" config user.name t
"$PY" "$TOOLS/rw.py" "$UP/DESIGN.md" "Intro line." "Upstream intro."; commit_all "$UP" upstream
printf '<!-- design-review-coverage: FULL 3/3 agy,codex,grok -->\n' >>"$CL/DESIGN.md"
call "git pull -q --rebase --autostash" "$CL"
has "pull brought upstream prose" "$(cat "$CL/DESIGN.md")" "Upstream intro."
eq "pull --rebase --autostash over a marker-only edit: no token" "$(tokens "$CL")" 0
eq "pull --rebase --autostash: PASS kept" "$(pass_line "$CL/DESIGN.md")" 1

"$PY" "$TOOLS/rw.py" "$BIG/DESIGN.md" "# Big" "# Dirty big"
call "ls" "$BIG"; eq "dirty 2 MiB doc, unrelated ls" "$(tokens "$BIG")" 0
"$PY" "$TOOLS/rw.py" "$BIG/DESIGN.md" "PASS" "PENDING"
call "bash \"$TOOLS/stamp.sh\" DESIGN.md" "$BIG"
eq "dirty 2 MiB doc, loop-style stamp" "$(tokens "$BIG")" 0
eq "dirty 2 MiB doc: PASS kept" "$(pass_line "$BIG/DESIGN.md")" 1

if [ "$ROOTUSER" = 0 ]; then
    "$PY" "$TOOLS/rw.py" "$Q/DESIGN.md" Second Unreadable
    eq "setup: the unreadable case starts from a dirty doc" "$(git -C "$Q" status --porcelain -- DESIGN.md | cut -c2)" M
    chmod 000 "$Q/DESIGN.md"
    call "ls" "$Q"; eq "unreadable dirty doc, first ls" "$(tokens "$Q")" 0
    call "ls" "$Q"; eq "unreadable dirty doc, second ls" "$(tokens "$Q")" 0
    chmod 644 "$Q/DESIGN.md"; git -C "$Q" checkout -q -- DESIGN.md
else
    echo "  SKIP  unreadable doc (running as root)"
fi

# Ignored docs count only inside a plans/ or specs/ directory: blueprint-review's own run
# rewrites the ignored .claude/ultra-oracle/plan-consult-verdict.md, which must never arm.
printf '.claude/ultra-oracle/\n.claude/plans/\ndocs/specs/private/\n' >"$Q/.gitignore"; commit_all "$Q"
call "\"$PY\" \"$TOOLS/put.py\" .claude/ultra-oracle/plan-consult-verdict.md verdict" "$Q"
eq "ignored plan*.md outside plans/specs written by a script: no token" "$(tokens "$Q")" 0
call "\"$PY\" \"$TOOLS/put.py\" .claude/plans/p.md '# p\\n' && \"$PY\" \"$TOOLS/put.py\" docs/specs/private/s.md '# s\\n'" "$Q"
eq "ignored docs in plans/ and specs/ written by a script: both arm" "$(tokens "$Q")" 2
clear_tokens "$Q"
call "ls" "$Q"
eq "ignored docs left unchanged: no token" "$(tokens "$Q")" 0
call "\"$PY\" \"$TOOLS/rw.py\" .claude/plans/p.md p q" "$Q"
eq "ignored doc rewritten: arms" "$(tokens "$Q")" 1
clear_tokens "$Q"
printf 'pkg/docs/plans/\n' >>"$Q/.gitignore"; commit_all "$Q"
call "\"$PY\" \"$TOOLS/put.py\" pkg/docs/plans/n.md '# n\\n'" "$Q"
eq "ignored doc in a nested docs/plans/ written by a script: arms" "$(tokens "$Q")" 1
# The `**/` pass failing (a timeout walking node_modules) keeps the top-anchored listing.
IGN="$(cd "$HOOKCWD" && env -i PATH=/usr/bin:/bin GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null "$SYSPY" -I -c '
import sys
sys.path.insert(0, sys.argv[1])
import design_effect
orig = design_effect.git
def git(root, args, *a, **k):
    if "ls-files" in args and any(x.endswith("**/docs/**/plans/**/*.md") for x in args):
        raise design_effect.GitError("simulated timeout", 124)
    return orig(root, args, *a, **k)
design_effect.git = git
print(" ".join(sorted(design_effect.dirty_set(sys.argv[2], ".claude"))))' "$LIB" "$Q" 2>/dev/null)"
eq "nested ignored pass fails: top-anchored ignored doc still listed" "$IGN" ".claude/plans/p.md docs/specs/private/s.md"
rm -rf "$Q/.claude" "$Q/docs/specs/private" "$Q/pkg"; clear_tokens "$Q"

call "\"$PY\" \"$TOOLS/rw.py\" DESIGN.md Second Committed && git commit -qam both" "$Q"
eq "setup: the write-and-commit call committed" "$(git -C "$Q" log -1 --format=%s)" both
eq "write and commit in one call (stated residual): no token" "$(tokens "$Q")" 0

echo "── parity with the Write path ──────────────────────────────────"
P="$TMP/parity"; mkrepo "$P"; mkdir -p "$P/src" "$P/docs"; ln -s ../src "$P/docs/plans"; commit_all "$P"
PATHS="DESIGN.md docs/reviews/DESIGN-r.md memory/DESIGN-m.md agents/plan-a.md docs/plans/sym.md"
groups(){ local d; d="$(mkdir_of "$P")"; [ -d "$d" ] && find "$d" -type f -exec basename {} \; | cut -d. -f1 | sort -u | tr '\n' ' '; }
for p in $PATHS; do
    "$PY" "$TOOLS/put.py" "$P/$p" x
    hook "$(jq -cn --arg fp "$P/$p" --arg cwd "$P" '{tool_name:"Write",hook_event_name:"PostToolUse",tool_input:{file_path:$fp},cwd:$cwd}')"
done
W_GROUPS="$(groups)"
for p in $PATHS; do rm -f "$P/$p"; done; clear_tokens "$P"
cmd=""; for p in $PATHS; do cmd="$cmd\"$PY\" \"$TOOLS/put.py\" $p x && "; done
call "${cmd}true" "$P"
eq "Write and Bash effect arm the same token groups" "$(groups)" "$W_GROUPS"
eq "exactly one group (DESIGN.md)" "$(printf '%s' "$W_GROUPS" | wc -w | tr -d ' ')" 1

echo "── unchanged Write path ────────────────────────────────────────"
OLDDIR="$TMP/old/gs"; mkdir -p "$OLDDIR"; ln -s "$LIB" "$OLDDIR/lib"
sed '/^# #921 — a Bash call is judged by its EFFECT/,/^fi$/d' "$CHECKDOC" >"$OLDDIR/check-design-document.sh"
hasnt "pre-change copy has no effect block" "$(cat "$OLDDIR/check-design-document.sh")" "design_effect.py"
WR="$TMP/wr"; mkrepo "$WR"; reviewed_doc >"$WR/DESIGN.md"
wp="$(jq -cn --arg fp "$WR/DESIGN.md" --arg cwd "$WR" '{tool_name:"Write",hook_event_name:"PostToolUse",tool_input:{file_path:$fp},cwd:$cwd}')"
rm -rf "$STORE"; hook "$wp"; NEW_OUT="$OUT"; NEW_ERR="$ERR"
reviewed_doc >"$WR/DESIGN.md"; clear_tokens "$WR"
OUT="$(printf '%s' "$wp" | (cd "$HOOKCWD" && env -i PATH=/usr/bin:/bin HOME="$TH" GIT_CONFIG_GLOBAL=/dev/null \
    GIT_CONFIG_SYSTEM=/dev/null /bin/bash "$OLDDIR/check-design-document.sh") 2>"$TMP/olderr")"
eq "Write stdout identical to the pre-change script" "$NEW_OUT" "$OUT"
eq "Write stderr identical to the pre-change script" "$NEW_ERR" "$(cat "$TMP/olderr")"
eq "Write creates no snapshot" "$(find "$STORE" -type f 2>/dev/null | wc -l | tr -d ' ')" 0

echo "── error paths ─────────────────────────────────────────────────"
X="$TMP/err"; mkrepo "$X"; reviewed_doc >"$X/DESIGN.md"; commit_all "$X"
(cd "$X" && "$PY" "$TOOLS/rw.py" DESIGN.md Intro NoSnap && echo '# r' > docs-r.md && mkdir -p docs/plans && echo '# r' > docs/plans/r.md)
hook "$(payload PostToolUse "\"$PY\" w.py && echo '# r' > docs/plans/r.md" "$X" "never-pre")"
has "no snapshot warns" "$ERR" "no pre-call snapshot"
eq "no snapshot: DESIGN.md not armed by effect" "$(token_for "$X" "$X/DESIGN.md")" 0
eq "no snapshot: the redirect target still arms" "$(token_for "$X" "$X/docs/plans/r.md")" 1
git -C "$X" checkout -q -- DESIGN.md; rm -rf "$X/docs" "$X/docs-r.md"; clear_tokens "$X"

nid(){ payload "$1" "\"$PY\" \"$TOOLS/rw.py\" DESIGN.md Intro NoIds" "$X" - | jq -c 'del(.session_id)'; }
hook "$(nid PreToolUse)"
has "degraded key warns" "$ERR" "no tool_use_id"
(cd "$X" && "$PY" "$TOOLS/rw.py" DESIGN.md Intro NoIds); hook "$(nid PostToolUse)"
eq "no session_id and no tool_use_id: halves still pair" "$(tokens "$X")" 1
eq "snapshot deleted after the comparison" "$(find "$STORE" -type f | wc -l | tr -d ' ')" 0
git -C "$X" checkout -q -- DESIGN.md; clear_tokens "$X"

mkdir -p "$STORE"; : >"$STORE/stale.json"; touch -t 202001010000 "$STORE/stale.json"
call "ls" "$X"
eq "snapshot older than 24 h pruned" "$([ -e "$STORE/stale.json" ] && echo kept || echo pruned)" pruned

reviewed_doc >"$A/DESIGN-a.md"; commit_all "$A"
call "cd \"$B\" && \"$PY\" \"$TOOLS/rw.py\" DESIGN-b.md Intro Z && \"$PY\" \"$TOOLS/rw.py\" \"$A/DESIGN-a.md\" Intro Z && printf garbage > \"$B/.git/index\"" "$A"
has "corrupted index: that root is uncompared" "$ERR" "uncompared"
eq "corrupted index in B: A still arms" "$(tokens "$A")" 1
rm -f "$B/.git/index"; git -C "$B" reset -q --hard; git -C "$A" checkout -q -- .; clear_tokens "$A"
# Same failure, but B's doc was already dirty (so snapshotted): it is re-checked and arms.
"$PY" "$TOOLS/rw.py" "$B/DESIGN-b.md" Second DirtyB
call "\"$PY\" \"$TOOLS/rw.py\" \"$B/DESIGN-b.md\" Intro Z2 && printf garbage > \"$B/.git/index\"" "$B"
eq "corrupted index: a snapshotted doc that changed still arms" "$(tokens "$B")" 1
eq "corrupted index: armed without a downgrade" "$(pass_line "$B/DESIGN-b.md")" 1
rm -f "$B/.git/index"; git -C "$B" reset -q --hard; clear_tokens "$B"
# Unreadable before the call, readable after (a permissions-only change): the pre-call
# content was never compared, so the doc arms without a PASS downgrade.
if [ "$ROOTUSER" = 0 ]; then
    UR="$TMP/unread-pre"; mkrepo "$UR"; reviewed_doc >"$UR/DESIGN.md"; commit_all "$UR"
    "$PY" "$TOOLS/rw.py" "$UR/DESIGN.md" Second DirtyU; chmod 000 "$UR/DESIGN.md"
    call "chmod 644 DESIGN.md" "$UR"
    eq "unreadable before, readable after: arms" "$(tokens "$UR")" 1
    eq "unreadable before, readable after: PASS line untouched" "$(pass_line "$UR/DESIGN.md")" 1
fi

# Same failure, and the call also leaves the snapshotted doc unreadable: it is not "gone".
if [ "$ROOTUSER" = 0 ]; then
    "$PY" "$TOOLS/rw.py" "$B/DESIGN-b.md" Second DirtyB
    call "\"$PY\" \"$TOOLS/rw.py\" \"$B/DESIGN-b.md\" Intro Z3 && chmod 000 \"$B/DESIGN-b.md\" && printf garbage > \"$B/.git/index\"" "$B"
    eq "corrupted index: a snapshotted doc made unreadable still arms" "$(tokens "$B")" 1
    chmod 644 "$B/DESIGN-b.md"; rm -f "$B/.git/index"; git -C "$B" reset -q --hard; clear_tokens "$B"
fi

if [ "$ROOTUSER" = 0 ]; then
    RO="$TMP/ro"; mkrepo "$RO"; mkdir -p "$RO/docs/plans"; reviewed_doc >"$RO/docs/plans/ro.md"; commit_all "$RO"
    chmod 555 "$RO/docs/plans"
    call "\"$PY\" \"$TOOLS/rw.py\" docs/plans/ro.md Intro ReadOnly" "$RO"
    eq "downgrade fails: still arms" "$(tokens "$RO")" 1
    eq "downgrade fails: PASS line untouched" "$(pass_line "$RO/docs/plans/ro.md")" 1
    has "downgrade fails: still-PASS warning" "$ERR" "ro.md still reads PASS"
    chmod 755 "$RO/docs/plans"
else
    echo "  SKIP  read-only downgrade (running as root)"
fi

# cmd_dd_exempt raising for one candidate: that doc arms with a warning, the next one too.
K="$TMP/raise"; mkrepo "$K"; reviewed_doc >"$K/DESIGN-first.md"; reviewed_doc >"$K/DESIGN-second.md"; commit_all "$K"
N=$((N + 1)); kid="tu-$N"; kcmd="\"$PY\" \"$TOOLS/rw.py\" DESIGN-first.md Intro R && \"$PY\" \"$TOOLS/rw.py\" DESIGN-second.md Intro R"
hook "$(payload PreToolUse "$kcmd" "$K" "$kid")"
(cd "$K" && bash -c "$kcmd")
KERR="$(payload PostToolUse "$kcmd" "$K" "$kid" | (cd "$HOOKCWD" && env -i PATH=/usr/bin:/bin HOME="$TH" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null "$SYSPY" -I -c '
import sys
lib = sys.argv[1]
sys.path.insert(0, lib)
import marker_ops, design_effect
orig = marker_ops.cmd_dd_exempt
def boom(argv):
    if argv[0].endswith("DESIGN-first.md"):
        raise RuntimeError("boom")
    return orig(argv)
marker_ops.cmd_dd_exempt = boom
sys.exit(design_effect.main(["diff", lib]))' "$LIB") 2>&1 >/dev/null)"
has "classifier raise warns" "$KERR" "could not classify"
eq "classifier raise: both docs armed" "$(tokens "$K")" 2

# The pre-call HEAD lookup failing does not skip the root: a doc the call newly dirtied
# still arms, without a PASS downgrade.
HU="$TMP/headfail"; mkrepo "$HU"; reviewed_doc >"$HU/DESIGN.md"; commit_all "$HU"
N=$((N + 1)); uid="tu-$N"; ucmd="\"$PY\" \"$TOOLS/rw.py\" DESIGN.md Intro U"
UERR="$(payload PreToolUse "$ucmd" "$HU" "$uid" | (cd "$HOOKCWD" && env -i PATH=/usr/bin:/bin HOME="$TH" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null "$SYSPY" -I -c '
import sys
lib = sys.argv[1]
sys.path.insert(0, lib)
import design_effect
orig = design_effect.git
def flaky(root, args, *a, **k):
    if args[:1] == ["rev-parse"] and args[-1].startswith("HEAD"):
        raise design_effect.GitError("timed out: git rev-parse")
    return orig(root, args, *a, **k)
design_effect.git = flaky
sys.exit(design_effect.main(["snap", lib]))' "$LIB") 2>&1 >/dev/null)"
has "HEAD lookup fails: warns" "$UERR" "could not resolve HEAD"
(cd "$HU" && bash -c "$ucmd")
hook "$(payload PostToolUse "$ucmd" "$HU" "$uid")"
eq "HEAD lookup fails: arms" "$(tokens "$HU")" 1
eq "HEAD lookup fails: PASS line untouched" "$(pass_line "$HU/DESIGN.md")" 1

# A revision read past MAX_BATCH_BYTES is not fetched: it counts as a failed read, so the
# doc arms without a PASS downgrade.
RB="$TMP/batchcap"; mkrepo "$RB"; reviewed_doc >"$RB/DESIGN.md"; commit_all "$RB"
N=$((N + 1)); bid="tu-$N"; bcmd="\"$PY\" \"$TOOLS/rw.py\" DESIGN.md Intro B"
hook "$(payload PreToolUse "$bcmd" "$RB" "$bid")"
(cd "$RB" && bash -c "$bcmd")
BERR="$(payload PostToolUse "$bcmd" "$RB" "$bid" | (cd "$HOOKCWD" && env -i PATH=/usr/bin:/bin HOME="$TH" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null "$SYSPY" -I -c '
import sys
lib = sys.argv[1]
sys.path.insert(0, lib)
import design_effect
design_effect.MAX_BATCH_BYTES = 10
sys.exit(design_effect.main(["diff", lib]))' "$LIB") 2>&1 >/dev/null)"
eq "revision batch over the cap: arms" "$(tokens "$RB")" 1
eq "revision batch over the cap: PASS line untouched" "$(pass_line "$RB/DESIGN.md")" 1
has "revision batch over the cap: warns" "$BERR" "revision blobs exceed"

# Arming comes first: a downgrade or PASS probe that raises (MemoryError on a huge doc)
# still leaves the token, and the probe never reads a doc past MAX_BODY_BYTES.
PD="$TMP/probeorder"; mkdir -p "$PD"; reviewed_doc >"$PD/DESIGN.md"
"$PY" -c "import sys; open(sys.argv[1],'w').write('# Huge\n' + 'x' * (4 * 1024 * 1024 + 10))" "$PD/HUGE.md"
PORD="$(cd "$HOOKCWD" && env -i PATH=/usr/bin:/bin "$SYSPY" -I -c '
import contextlib, sys
sys.path.insert(0, sys.argv[1])
import design_effect
calls = []
class Mo:
    def cmd_dd_exempt(self, a): return 0
    def cmd_downgrade_pass(self, a): calls.append("down"); raise MemoryError()
    def cmd_reviewed(self, a): calls.append("probe:" + a[0].rsplit("/", 1)[1]); raise MemoryError()
    def cmd_arm(self, a): calls.append("arm"); return 0
for doc in ("DESIGN.md", "HUGE.md"):
    try:
        with contextlib.redirect_stdout(sys.stderr):
            design_effect.process_doc(Mo(), sys.argv[2], doc, True, "/nonexistent", ".claude")
    except Exception as e:
        calls.append("raised")
print(" ".join(calls))' "$LIB" "$PD" 2>/dev/null)"
eq "downgrade and probe raising: still arms, nothing escapes" "$PORD" "arm down probe:DESIGN.md arm down"

# such revision": the doc arms without a PASS downgrade.
RF="$TMP/revfail"; mkrepo "$RF"; reviewed_doc >"$RF/DESIGN.md"; commit_all "$RF"
N=$((N + 1)); rid="tu-$N"; rcmd="\"$PY\" \"$TOOLS/rw.py\" DESIGN.md Intro R"
hook "$(payload PreToolUse "$rcmd" "$RF" "$rid")"
(cd "$RF" && bash -c "$rcmd")
RERR="$(payload PostToolUse "$rcmd" "$RF" "$rid" | (cd "$HOOKCWD" && env -i PATH=/usr/bin:/bin HOME="$TH" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null "$SYSPY" -I -c '
import sys
lib = sys.argv[1]
sys.path.insert(0, lib)
import design_effect
orig = design_effect.git
def flaky(root, args, *a, **k):
    if args[:1] == ["rev-parse"] and args[-1].startswith("MERGE_HEAD"):
        raise design_effect.GitError("timed out: git rev-parse")
    return orig(root, args, *a, **k)
design_effect.git = flaky
sys.exit(design_effect.main(["diff", lib]))' "$LIB") 2>&1 >/dev/null)"
eq "revision lookup fails: arms" "$(tokens "$RF")" 1
eq "revision lookup fails: PASS line untouched" "$(pass_line "$RF/DESIGN.md")" 1
has "revision lookup fails: warns" "$RERR" "revision read failed"

# The deadline passing during the post-call status: the status fails, and the
# fallback re-hashes nothing, arming every snapshotted doc still present (unread).
FD="$TMP/fallback-late"; mkrepo "$FD"; reviewed_doc >"$FD/DESIGN-1.md"; reviewed_doc >"$FD/DESIGN-2.md"; commit_all "$FD"
"$PY" "$TOOLS/rw.py" "$FD/DESIGN-1.md" Second Dirty1; "$PY" "$TOOLS/rw.py" "$FD/DESIGN-2.md" Second Dirty2
N=$((N + 1)); fid="tu-$N"; fcmd="\"$PY\" \"$TOOLS/rw.py\" DESIGN-1.md Intro F"
hook "$(payload PreToolUse "$fcmd" "$FD" "$fid")"
(cd "$FD" && bash -c "$fcmd")
FERR="$(payload PostToolUse "$fcmd" "$FD" "$fid" | (cd "$HOOKCWD" && env -i PATH=/usr/bin:/bin HOME="$TH" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null "$SYSPY" -I -c '
import sys
lib = sys.argv[1]
sys.path.insert(0, lib)
import design_effect
def late(*a):
    design_effect.DEADLINE_S = -1.0
    raise design_effect.Deadline()
design_effect.candidates_for = late
design_effect.fallback_entry = lambda p: (_ for _ in ()).throw(AssertionError("re-hashed " + p))
sys.exit(design_effect.main(["diff", lib]))' "$LIB") 2>&1 >/dev/null)"
hasnt "fallback past the deadline: nothing re-hashed" "$FERR" "re-hashed"
eq "fallback past the deadline: both snapshotted docs arm" "$(tokens "$FD")" 2
eq "fallback past the deadline: no PASS downgrade" "$(( $(pass_line "$FD/DESIGN-1.md") + $(pass_line "$FD/DESIGN-2.md") ))" 2

# The deadline passing after comparison: remaining candidates still arm, unclassified and
# without a PASS downgrade.
DL="$TMP/late"; mkrepo "$DL"; reviewed_doc >"$DL/DESIGN-1.md"; reviewed_doc >"$DL/DESIGN-2.md"; commit_all "$DL"
N=$((N + 1)); did="tu-$N"; dcmd="\"$PY\" \"$TOOLS/rw.py\" DESIGN-1.md Intro L && \"$PY\" \"$TOOLS/rw.py\" DESIGN-2.md Intro L"
hook "$(payload PreToolUse "$dcmd" "$DL" "$did")"
(cd "$DL" && bash -c "$dcmd")
DERR="$(payload PostToolUse "$dcmd" "$DL" "$did" | (cd "$HOOKCWD" && env -i PATH=/usr/bin:/bin HOME="$TH" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null "$SYSPY" -I -c '
import sys
lib = sys.argv[1]
sys.path.insert(0, lib)
import design_effect
orig = design_effect.candidates_for
def late(*a):
    r = orig(*a)
    design_effect.DEADLINE_S = -1.0
    return r
design_effect.candidates_for = late
sys.exit(design_effect.main(["diff", lib]))' "$LIB") 2>&1 >/dev/null)"
has "late candidates are named" "$DERR" "armed without classification"
eq "late candidates both arm" "$(tokens "$DL")" 2
eq "late candidates keep their PASS line" "$(( $(pass_line "$DL/DESIGN-1.md") + $(pass_line "$DL/DESIGN-2.md") ))" 2

# The deadline passing after the first root's comparison: the second root's doc (dirty
# before the call) still arms, and no git child starts once the deadline has passed.
L1="$TMP/late-a"; L2="$TMP/late-b"; mkrepo "$L1"; mkrepo "$L2"
reviewed_doc >"$L1/DESIGN.md"; reviewed_doc >"$L2/DESIGN.md"; commit_all "$L1"; commit_all "$L2"
"$PY" "$TOOLS/rw.py" "$L2/DESIGN.md" Second DirtyL2
N=$((N + 1)); lid="tu-$N"; lcmd="cd \"$L2\" && \"$PY\" \"$TOOLS/rw.py\" DESIGN.md Intro L && \"$PY\" \"$TOOLS/rw.py\" \"$L1/DESIGN.md\" Intro L"
hook "$(payload PreToolUse "$lcmd" "$L1" "$lid")"
(cd "$L1" && bash -c "$lcmd")
LERR="$(payload PostToolUse "$lcmd" "$L1" "$lid" | (cd "$HOOKCWD" && env -i PATH=/usr/bin:/bin HOME="$TH" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null "$SYSPY" -I -c '
import sys
lib = sys.argv[1]
sys.path.insert(0, lib)
import design_effect
import subprocess
orig_c, orig_run = design_effect.candidates_for, subprocess.run
def late(*a):
    r = orig_c(*a)
    design_effect.DEADLINE_S = -1.0
    return r
def watch(cmd, *a, **k):
    if design_effect.remaining() <= 0:
        sys.stderr.write("late git child: " + " ".join(cmd[:6]) + "\n")
    return orig_run(cmd, *a, **k)
design_effect.candidates_for, subprocess.run = late, watch
sys.exit(design_effect.main(["diff", lib]))' "$LIB") 2>&1 >/dev/null)"
hasnt "past the deadline: no git child starts" "$LERR" "late git child"
eq "past the deadline: first root arms" "$(tokens "$L1")" 1
eq "past the deadline: second root's snapshotted doc arms" "$(tokens "$L2")" 1

# The deadline cutting off the post-call hashing: the doc already hashed and the one cut
# off both arm; the cut-off one is armed without a PASS downgrade.
HC="$TMP/hashcut"; mkrepo "$HC"; reviewed_doc >"$HC/DESIGN-1.md"; reviewed_doc >"$HC/DESIGN-2.md"; commit_all "$HC"
N=$((N + 1)); hid="tu-$N"; hcmd="\"$PY\" \"$TOOLS/rw.py\" DESIGN-1.md Intro H && \"$PY\" \"$TOOLS/rw.py\" DESIGN-2.md Intro H"
hook "$(payload PreToolUse "$hcmd" "$HC" "$hid")"
(cd "$HC" && bash -c "$hcmd")
HERR="$(payload PostToolUse "$hcmd" "$HC" "$hid" | (cd "$HOOKCWD" && env -i PATH=/usr/bin:/bin HOME="$TH" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null "$SYSPY" -I -c '
import sys
lib = sys.argv[1]
sys.path.insert(0, lib)
import design_effect
orig, calls = design_effect.file_entry, []
def cut(path):
    calls.append(path)
    if len(calls) == 2:
        raise design_effect.Deadline()
    return orig(path)
design_effect.file_entry = cut
sys.exit(design_effect.main(["diff", lib]))' "$LIB") 2>&1 >/dev/null)"
eq "hashing cut off by the deadline: both docs arm" "$(tokens "$HC")" 2
eq "hashing cut off: one doc downgraded, the cut-off one keeps PASS" "$(( $(pass_line "$HC/DESIGN-1.md") + $(pass_line "$HC/DESIGN-2.md") ))" 1
has "hashing cut off: warns" "$HERR" "armed without a PASS downgrade"

# The deadline cutting off the PRE-call hashing: the snapshot keeps what it hashed, and a
# dirty doc it never hashed is armed after the call without a PASS downgrade.
SC="$TMP/snapcut"; mkrepo "$SC"; reviewed_doc >"$SC/DESIGN-1.md"; reviewed_doc >"$SC/DESIGN-2.md"; commit_all "$SC"
"$PY" "$TOOLS/rw.py" "$SC/DESIGN-1.md" Second Dirty1; "$PY" "$TOOLS/rw.py" "$SC/DESIGN-2.md" Second Dirty2
N=$((N + 1)); sid="tu-$N"; scmd="\"$PY\" \"$TOOLS/rw.py\" DESIGN-1.md Intro S"
SERR="$(payload PreToolUse "$scmd" "$SC" "$sid" | (cd "$HOOKCWD" && env -i PATH=/usr/bin:/bin HOME="$TH" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null "$SYSPY" -I -c '
import sys
lib = sys.argv[1]
sys.path.insert(0, lib)
import design_effect
orig, calls = design_effect.file_entry, []
def cut(path):
    calls.append(path)
    if len(calls) == 2:
        raise design_effect.Deadline()
    return orig(path)
design_effect.file_entry = cut
sys.exit(design_effect.main(["snap", lib]))' "$LIB") 2>&1 >/dev/null)"
has "pre-call hashing cut off: warns" "$SERR" "unhashed dirty docs will be armed"
(cd "$SC" && bash -c "$scmd")
hook "$(payload PostToolUse "$scmd" "$SC" "$sid")"
eq "pre-call hashing cut off: both dirty docs arm" "$(tokens "$SC")" 2

echo "── launcher row ────────────────────────────────────────────────"
LR="$TMP/launch"; mkrepo "$LR"
row(){ jq -r --arg ev "$1" '.hooks[$ev][] | select(.matcher | split("|") | index("Bash")) | .hooks[] | select((.args // []) | index("check-design-document.sh")) | ([.command] + .args) | @json' "$ROOT/hooks/hooks.json" | head -1; }
launch(){   # launch <event> <payload>: run the registration exactly as hooks.json declares it
    local argv; argv="$(row "$1" | sed "s#\${CLAUDE_PLUGIN_ROOT}#$ROOT#g")"
    [ -n "$argv" ] || { LRC="no $1 row"; LOUT=""; return; }
    local -a a; while IFS= read -r x; do a+=("$x"); done < <(printf '%s' "$argv" | jq -r '.[]')
    LOUT="$(printf '%s' "$2" | (cd "$HOOKCWD" && "${a[@]}"))"; LRC=$?
}
# The row runs under the passwd HOME (sanitized-gate.sh), not the fixture's, so its
# snapshot lands in the operator's real store: a per-run session id keeps concurrent
# runs apart, and cleanup() removes the file if the run stops before the post half.
LSID="sess-921-launch-$$-$RANDOM"
lpayload(){ payload "$1" "ls" "$LR" "launch-1" | jq -c --arg s "$LSID" '.session_id = $s'; }
ROWSNAP="$("$PY" -c '
import hashlib, os, pwd, sys
d = hashlib.sha256(sys.argv[1].encode() + b"\0launch-1").hexdigest()
print(os.path.join(pwd.getpwuid(os.getuid()).pw_dir, ".claude/busdriver/design-effect.d", d + ".json"))' "$LSID")"
launch PreToolUse "$(lpayload PreToolUse)"
eq "PreToolUse|Bash row exits 0" "$LRC" 0
eq "PreToolUse|Bash row prints nothing" "$LOUT" ""
eq "PreToolUse|Bash row wrote its snapshot" "$([ -f "$ROWSNAP" ] && echo yes || echo no)" yes
# Consume the snapshot the row wrote under the passwd HOME, so no file is left behind.
launch PostToolUse "$(lpayload PostToolUse)"
eq "PostToolUse row exits 0" "$LRC" 0
eq "row snapshot consumed (none left in the passwd HOME)" "$([ -e "$ROWSNAP" ] && echo left || echo gone)" gone

echo "── timing ──────────────────────────────────────────────────────"
TA="$TMP/time/a"; TB="$TMP/time/b"; mkrepo "$TA"; mkrepo "$TB"
for i in $(seq 1 25); do reviewed_doc >"$TA/docs-plans-$i.md"; done
mkdir -p "$TA/docs/plans" "$TB/docs/plans"
for i in $(seq 1 25); do mv "$TA/docs-plans-$i.md" "$TA/docs/plans/p$i.md"; reviewed_doc >"$TB/docs/plans/p$i.md"; done
commit_all "$TA"; commit_all "$TB"
tcmd="cd \"$TB\" && sed -i.bak 's/Intro/Timed/' docs/plans/*.md \"$TA\"/docs/plans/*.md && rm -f docs/plans/*.bak \"$TA\"/docs/plans/*.bak"
N=$((N + 1)); tid="tu-$N"
t0=$("$PY" -c 'import time;print(time.time())')
hook "$(payload PreToolUse "$tcmd" "$TA" "$tid")"
t1=$("$PY" -c 'import time;print(time.time())')
(cd "$TA" && bash -c "$tcmd")
t2=$("$PY" -c 'import time;print(time.time())')
hook "$(payload PostToolUse "$tcmd" "$TA" "$tid")"
t3=$("$PY" -c 'import time;print(time.time())')
pre_s=$("$PY" -c "print('%.2f' % ($t1-$t0))"); post_s=$("$PY" -c "print('%.2f' % ($t3-$t2))")
echo "  INFO  two roots, 50 changed docs: Pre ${pre_s}s, Post ${post_s}s"
eq "Pre half under 4 s" "$("$PY" -c "print($t1-$t0 < 4)")" True
eq "Post half under 4 s" "$("$PY" -c "print($t3-$t2 < 4)")" True
eq "all 50 docs armed" "$(( $(tokens "$TA") + $(tokens "$TB") ))" 50
hasnt "no uncompared warning" "$ERR" "uncompared"
hasnt "no deadline warning" "$ERR" "deadline passed"

eq "every rewrite found its target (no case passed on a no-op)" "$(cat "$TOOLS/misses" 2>/dev/null)" ""

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
