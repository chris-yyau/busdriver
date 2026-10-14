#!/usr/bin/env bash
# Tests for scripts/needs-shipping.py (ADR 0054) and the pr-grind prose that wires it in.
#
# Part 1 drives the classifier through a stub `gh` on PATH. Stub responses are trimmed
# copies of real `gh pr view` / `git/trees` / `pulls/<n>/files --jq` output, so field
# names are not guessed. Every decision is observed on both sides (0 / 10 / 1).
# Part 2 asserts document order and the "exit 0 only" qualifiers in completion.md and
# SKILL.md, the same way tests/test-pr-grind-codex-wiring.sh pins prose contracts.
#
# Usage: bash tests/test-needs-shipping.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

SCRIPT="scripts/needs-shipping.py"
PY=/usr/bin/python3
PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"

HEAD=3df45264627e7ff8bf8cacc05a025723929b62d3
BASE=0e1270c5c81c44f7a62f796d7efde58f7eb2d358
OTHER=1111111111111111111111111111111111111111

# Stub gh. Fixture files under $FIX:
#   view1, view2           successive `gh pr view` responses (view2 reused afterwards)
#   tree-<sha>[.rc]        `gh api repos/o/r/git/trees/<sha>` body [and exit code]
#   files[.rc]             `gh api --paginate ... pulls/<n>/files --jq ...` stdout [and exit code]
#   ref1, ref2[, ref.rc]   successive git/ref/heads/<b> bodies (ref2 optional) [and exit code]; names logged to ref_names
#   rtree-<sha>[.rc]       `gh api .../git/trees/<sha>?recursive=1` body [and exit code];
#                          rtree-default when absent. rhang delays only these calls.
#   blob-<sha>             GraphQL Blob node served for variable o<N>=<sha>; gql-body overrides the whole reply
# The stub logs every call to $FIX/calls and the GH_HOST it saw to $FIX/gh_host.
cat > "$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$FIX/calls"
printf '%s\n' "${GH_HOST:-}" > "$FIX/gh_host"
printf '%s|%s|%s|%s|%s|%s\n' "${GH_REPO:-}" "${GH_DEBUG:-}" "${GITHUB_API_URL:-}" "${GH_TOKEN:-}" "${GITHUB_TOKEN:-}" "${GH_CONFIG_DIR:-}" > "$FIX/gh_env"
[ -f "$FIX/hang" ] && sleep 3
if [ "$1 $2" = "pr view" ]; then
  n=$(grep -c '^pr view' "$FIX/calls")
  if [ "$n" -le 1 ]; then cat "$FIX/view1"; else cat "$FIX/view2"; fi
  exit 0
fi
case "$*" in
  "api repos/o/r/git/ref/heads/"*)
    echo "${2#repos/o/r/git/ref/heads/}" >> "$FIX/ref_names"
    n=$(grep -c '^api repos/o/r/git/ref/heads/' "$FIX/calls")
    if [ "$n" -gt 1 ] && [ -f "$FIX/ref2" ]; then cat "$FIX/ref2"; else cat "$FIX/ref1"; fi
    exit "$(cat "$FIX/ref.rc" 2>/dev/null || echo 0)" ;;
  "api repos/o/r/git/trees/"*"?recursive=1")
    [ -f "$FIX/rhang" ] && sleep 3
    sha=${2##*/}; sha=${sha%%\?*}
    f="$FIX/rtree-$sha"; [ -f "$f" ] || f="$FIX/rtree-default"
    cat "$f"
    exit "$(cat "$f.rc" 2>/dev/null || echo 0)" ;;
  "api graphql"*)
    case " $* " in *" -f owner=o -f name=r "*) ;; *) echo "stub: owner/name must be raw -f strings" >&2; exit 1 ;; esac
    if [ -f "$FIX/gql-body" ]; then cat "$FIX/gql-body"; exit 0; fi
    out='{"data":{"repository":{' sep=''
    for a in "$@"; do
      case "$a" in o[0-9]*=*) k=${a%%=*}; s=${a#*=}; out="$out$sep\"f${k#o}\":$(cat "$FIX/blob-$s" 2>/dev/null || echo null)"; sep=, ;; esac
    done
    printf '%s}}}\n' "$out"; exit 0 ;;
  "api repos/o/r/git/trees/"*)
    sha=${2##*/}
    [ -f "$FIX/tree-$sha" ] && cat "$FIX/tree-$sha"
    exit "$(cat "$FIX/tree-$sha.rc" 2>/dev/null || { [ -f "$FIX/tree-$sha" ] && echo 0 || echo 1; })" ;;
  "api --paginate"*)
    cat "$FIX/files"
    exit "$(cat "$FIX/files.rc" 2>/dev/null || echo 0)" ;;
esac
echo "stub: unexpected gh $*" >&2
exit 99
STUB
chmod +x "$TMP/bin/gh"

DEF_AUTHOR='{"login":"op-user"}'
# view <head> [mergeStateStatus-json]; BREF, AUTHOR (JSON) and XREPO (JSON) override the rest.
view() { printf '{"baseRefName":"%s","headRefOid":"%s","mergeStateStatus":%s,"author":%s,"isCrossRepository":%s}\n' \
  "${BREF:-main}" "$1" "${2:-\"CLEAN\"}" "${AUTHOR:-$DEF_AUTHOR}" "${XREPO:-false}"; }
# ref <sha>: a git/ref/heads/<BREF> body.
ref() { printf '{"ref":"refs/heads/%s","node_id":"x","url":"https://api.github.com/x","object":{"sha":"%s","type":"commit","url":"https://api.github.com/x"}}\n' "${BREF:-main}" "$1"; }
# ship [status] [skills] [agent_config_edited] [files_incomplete] [author] [cross_repo] [base_ref] [base_tip]
ship() { printf 'shipping mergeStateStatus=%s base_ref=%s base_tip=%s skills=%s agent_config_edited=%s files_incomplete=%s author=%s cross_repo=%s' \
  "${1:-CLEAN}" "${7:-main}" "${8:-$BASE}" "${2:-verify-site}" "${3:-0}" "${4:-0}" "${5:-op-user}" "${6:-0}"; }
AC=$(ship CLEAN verify-site 1)
# review <head>: rewrite both views with the current BREF/AUTHOR/XREPO.
review() { view "$1" > "$FIX/view1"; cp "$FIX/view1" "$FIX/view2"; }
entry() { printf '{"mode":"%s","path":"%s","sha":"%s","type":"%s","url":"https://api.github.com/x"}' "$1" "$2" "$3" "$4"; }
tree() { local IFS=,; printf '{"sha":"x","tree":[%s],"truncated":false}\n' "$*"; }
DIR=040000
BLOB=100644
CUR=c000000000000000000000000000000000000000
SKL=5000000000000000000000000000000000000000

# new_case: fresh fixture dir, both views at HEAD, base tip = BASE, BASE's tree WITHOUT .cursor.
new_case() {
  FIX="$TMP/case$((PASS + FAIL))"; mkdir -p "$FIX"; export FIX; : > "$FIX/calls"
  view "$HEAD" > "$FIX/view1"; cp "$FIX/view1" "$FIX/view2"
  ref "$BASE" > "$FIX/ref1"
  tree "$(entry $BLOB README.md aaa blob)" "$(entry $DIR src bbb tree)" > "$FIX/tree-$BASE"
  printf '{"sha":"x","url":"x","tree":[],"truncated":false}\n' > "$FIX/rtree-default"
}
# opt_in [skills-entries...]: base tree carries .cursor/skills/ with the given entries
# (default: one verify-site directory).
opt_in() {
  tree "$(entry $BLOB README.md aaa blob)" "$(entry $DIR .cursor $CUR tree)" > "$FIX/tree-$BASE"
  tree "$(entry $DIR skills $SKL tree)" > "$FIX/tree-$CUR"
  if [ $# -eq 0 ]; then set -- "$(entry $DIR verify-site 7777 tree)"; fi
  tree "$@" > "$FIX/tree-$SKL"
}
files() { : > "$FIX/files"; for f in "$@"; do printf '%s\n' "$f" >> "$FIX/files"; done; }
plain() { printf '{"filename":"%s","previous_filename":null}' "$1"; }
# mkrev <rev> <spec>...: the recursive tree fixture rtree-<rev> plus a blob-<sha> GraphQL node per blob.
#   path=TEXT   text blob           path%N        blob claiming tree size N (text "x")
#   path@link   symlink             path@gitlink  submodule        path@dir   empty tree
#   path@bin / path@nullbin / path@trunc          isBinary true / null / isTruncated
#   path@big    600 KiB blob        @truncated    the tree itself is truncated
cat > "$TMP/mkrev.py" <<'MKREV'
import hashlib, json, os, sys
fix, rev = os.environ["FIX"], sys.argv[1]
entries, truncated = {}, False
def sha(s):
    return hashlib.sha1(s.encode()).hexdigest()
for spec in sys.argv[2:]:
    if spec == "@truncated":
        truncated = True
        continue
    node, n = {"byteSize": 1, "isBinary": False, "isTruncated": False, "text": "x"}, None
    if "=" in spec:
        path, text = spec.split("=", 1)
        kind, digest = "text", sha("text:" + text)
        node.update(byteSize=len(text.encode()), text=text)
    elif "%" in spec:
        path, n = spec.split("%", 1)
        kind, digest = "claim", sha("claim:" + path)
    else:
        path, kind = spec.rsplit("@", 1)
        digest = sha(kind + ":" + path)
    parts = path.split("/")
    for i in range(1, len(parts)):
        d = "/".join(parts[:i])
        entries.setdefault(d, {"path": d, "mode": "040000", "type": "tree", "sha": sha("dir:" + d)})
    e = {"path": path, "mode": "100644", "type": "blob", "sha": digest, "size": node["byteSize"]}
    if kind == "claim":
        e["size"] = int(n)
    elif kind == "link":
        e["mode"] = "120000"
    elif kind in ("gitlink", "dir"):
        e.update(mode="160000" if kind == "gitlink" else "040000", type="commit" if kind == "gitlink" else "tree")
        del e["size"]
    elif kind == "bin":
        node["isBinary"] = True
    elif kind == "nullbin":
        node["isBinary"] = None
    elif kind == "trunc":
        node["isTruncated"] = True
    elif kind == "big":
        e["size"] = node["byteSize"] = 600 * 1024
    entries[path] = e
    with open(os.path.join(fix, "blob-" + digest), "w") as f:
        json.dump(node, f)
with open(os.path.join(fix, "rtree-" + rev), "w") as f:
    json.dump({"sha": rev, "url": "x", "truncated": truncated,
               "tree": sorted(entries.values(), key=lambda x: x["path"])}, f)
MKREV
at() { "$PY" -I "$TMP/mkrev.py" "$@"; }                    # at <rev> <spec>...
both() { at "$HEAD" "$@" && at "$BASE" "$@"; }            # the same tree at head and base_tip
walk_case() { new_case; opt_in; both "$@"; }              # opted in; both revisions carry the specs
only() { files "$(plain "$1")"; }                         # the PR changes exactly one path
gql_count() { grep -c '^api graphql' "$FIX/calls"; }

# run_case <label> <expected-exit> <expected-stdout>: stdout must equal the expected
# line exactly, except `error`, which matches any `error: <reason>` line.
run_case() {
  local out rc ok=0
  out=$(PATH="$TMP/bin:$PATH" "$PY" -I "${SCRIPT_RUN:-$SCRIPT}" o/r 42 "$HEAD" 2>/dev/null); rc=$?
  if [ "$3" = error ]; then [ "${out#error: }" != "$out" ] && ok=1; else [ "$out" = "$3" ] && ok=1; fi
  if [ "$rc" = "$2" ] && [ "$ok" = 1 ]; then pass "$1"
  else fail "$1 (rc=$rc out=$out, want rc=$2 out=$3)"; fi
}

echo "── classifier ───────────────────────────────────────────────"

new_case
run_case "not opted in (no .cursor) → merge" 0 merge
if grep -q -- '--paginate' "$FIX/calls"; then fail "not opted in never calls the files API"; else pass "not opted in never calls the files API"; fi
if [ "$(cat "$FIX/gh_host")" = github.com ]; then pass "gh runs with GH_HOST=github.com"; else fail "gh runs with GH_HOST=github.com"; fi

new_case
PATH="$TMP/bin:$PATH" GH_REPO=x/y GH_DEBUG=api GITHUB_API_URL=https://evil.example GH_TOKEN=tok GITHUB_TOKEN=gtok GH_CONFIG_DIR=/cfg \
  "$PY" -I "$SCRIPT" o/r 42 "$HEAD" >/dev/null 2>&1
if [ "$(cat "$FIX/gh_env")" = "|||tok|gtok|/cfg" ]; then pass "gh drops GH_REPO, GH_DEBUG and GITHUB_API_URL, keeps GH_TOKEN, GITHUB_TOKEN and GH_CONFIG_DIR"
else fail "gh drops GH_REPO, GH_DEBUG and GITHUB_API_URL, keeps GH_TOKEN, GITHUB_TOKEN and GH_CONFIG_DIR (saw $(cat "$FIX/gh_env"))"; fi

# A hung gh call fails closed: run a copy whose per-call timeout is 1s.
sed 's/^GH_TIMEOUT = 120 /GH_TIMEOUT = 1 /' "$SCRIPT" > "$TMP/needs-shipping-fast.py"
if grep -q '^GH_TIMEOUT = 1 ' "$TMP/needs-shipping-fast.py"; then
  new_case; : > "$FIX/hang"
  out=$(PATH="$TMP/bin:$PATH" "$PY" -I "$TMP/needs-shipping-fast.py" o/r 42 "$HEAD" 2>/dev/null); rc=$?
  case "$rc $out" in "1 error: gh "*"timed out after 1s") pass "hung gh call → error, exit 1" ;; *) fail "hung gh call → error, exit 1 (rc=$rc out=$out)" ;; esac
else
  fail "could not shrink GH_TIMEOUT in the test copy"
fi

new_case; opt_in "$(entry $DIR helper 8888 tree)"
run_case "not opted in (.cursor/skills has no verify-* dir) → merge" 0 merge

new_case; opt_in "$(entry $BLOB verify-site.md 9999 blob)"
run_case "not opted in (verify-site.md is a blob) → merge" 0 merge

new_case; rm "$FIX/tree-$BASE"; echo 1 > "$FIX/tree-$BASE.rc"
run_case "trees API failure → error" 1 error

new_case; echo '{"message":"Not Found"}' > "$FIX/tree-$BASE"; echo 1 > "$FIX/tree-$BASE.rc"
run_case "trees API 404 → error, not 'absent'" 1 error

new_case; tree "$(entry $DIR src bbb tree)" | sed 's/"truncated":false/"truncated":true/' > "$FIX/tree-$BASE"
run_case "truncated tree → error" 1 error

new_case; tree '{"path":"src","sha":"bbb"}' > "$FIX/tree-$BASE"
run_case "malformed tree entry (no type) → error" 1 error

new_case; view "$OTHER" > "$FIX/view2"
run_case "not opted in, head moved before the final view → error" 1 error

new_case; opt_in; files "$(plain docs/a.md)" "$(plain README.md)"
run_case "opted in, docs-only → merge" 0 merge

new_case; opt_in; files "$(plain docs/a.md)" "$(plain src/app/page.tsx)"
run_case "opted in, src change → shipping" 10 "$(ship)"

new_case; opt_in; files '{"filename":"docs/a.ts","previous_filename":"src/a.ts"}'
run_case "opted in, rename src→docs → shipping" 10 "$(ship)"

new_case; opt_in; files "$(plain .cursor/skills/verify-site/SKILL.md)"
run_case "opted in, PR deletes the verify skill → shipping, agent config" 10 "$(ship CLEAN verify-site 1)"

new_case; opt_in; files "$(plain docs/a.md)"; echo 1 > "$FIX/files.rc"
run_case "opted in, a later page fails → error" 1 error

new_case; opt_in; for _ in $(seq 3000); do plain docs/a.md; echo; done > "$FIX/files"
run_case "opted in, 3000 file objects → shipping" 10 "$(ship CLEAN verify-site 0 1)"

new_case; opt_in; for i in $(seq 1500); do printf '{"filename":"docs/n%s.md","previous_filename":"docs/o%s.md"}\n' "$i" "$i"; done > "$FIX/files"
run_case "opted in, 1500 docs-only renames (3000 paths, 1500 records) → merge" 0 merge

new_case; opt_in; files '{"filename":"src/app/a.test.ts\ndocs/x","previous_filename":null}'
run_case "opted in, filename with embedded newline → shipping" 10 "$(ship)"

new_case; opt_in; files 'not json'
run_case "opted in, unparseable files line → error" 1 error

new_case; opt_in; files '{"filename":"docs/a.md","previous_filename":7}'
run_case "opted in, malformed previous_filename → error" 1 error

new_case; opt_in; files "$(plain src/x.ts)"; view "$HEAD" null > "$FIX/view2"
run_case "mergeStateStatus null → UNKNOWN" 10 "$(ship UNKNOWN)"

new_case; opt_in; files "$(plain src/x.ts)"; ref "$OTHER" > "$FIX/ref2"
run_case "opted in, base tip moved while classifying → error" 1 error

new_case; view "$OTHER" > "$FIX/view1"
run_case "head differs from REVIEWED_HEAD → error" 1 error

TIP2=2222222222222222222222222222222222222222

new_case; BREF='bad name' review "$HEAD"
run_case "invalid base name → error" 1 error
new_case; BREF='a/../b' review "$HEAD"
run_case "base name with .. → error" 1 error

new_case; echo 1 > "$FIX/ref.rc"
run_case "base ref read fails → error, even when not opted in" 1 error
new_case; ref "$BASE" | sed 's/"type":"commit"/"type":"tag"/' > "$FIX/ref1"
run_case "base ref pointing at a tag object → error" 1 error
new_case; opt_in; files "$(plain src/x.ts)"
run_case "base tip read from heads/<base_ref>" 10 "$(ship)"
if grep -q 'git/ref/heads/main' "$FIX/calls" && ! grep -q 'tags' "$FIX/calls"; then pass "tip read is heads/main, never tags"; else fail "tip read is heads/main, never tags"; fi
if grep -q 'baseRefOid' "$FIX/calls"; then fail "baseRefOid is never requested"; else pass "baseRefOid is never requested"; fi

# Opt-in follows base_tip: BASE's tree is opted in, the tip's (TIP2) is not, and the reverse.
new_case; opt_in; ref "$TIP2" > "$FIX/ref1"; tree "$(entry $DIR src bbb tree)" > "$FIX/tree-$TIP2"; files "$(plain src/x.ts)"
run_case "opted in only at an older commit, not at base_tip → merge" 0 merge
new_case; ref "$TIP2" > "$FIX/ref1"
tree "$(entry $DIR .cursor $CUR tree)" > "$FIX/tree-$TIP2"; tree "$(entry $DIR skills $SKL tree)" > "$FIX/tree-$CUR"
tree "$(entry $DIR verify-new 7 tree)" > "$FIX/tree-$SKL"; files "$(plain src/x.ts)"
run_case "opted in at base_tip only → shipping, skills from base_tip" 10 "$(ship CLEAN verify-new 0 0 op-user 0 main "$TIP2")"

new_case; BREF=release/1.2 review "$HEAD"; BREF=release/1.2 ref "$BASE" > "$FIX/ref1"; opt_in; files "$(plain src/x.ts)"
run_case "slash base name → base_ref=release/1.2" 10 "$(ship CLEAN verify-site 0 0 op-user 0 release/1.2)"
if grep -qx 'release/1.2' "$FIX/ref_names"; then pass "ref path keeps the slash unencoded"; else fail "ref path keeps the slash unencoded"; fi
new_case; BREF=_release review "$HEAD"; BREF=_release ref "$BASE" > "$FIX/ref1"; opt_in; files "$(plain src/x.ts)"
run_case "leading-underscore base name → base_ref=_release" 10 "$(ship CLEAN verify-site 0 0 op-user 0 _release)"
new_case; BREF=rc+1=a@b review "$HEAD"; BREF=rc+1=a@b ref "$BASE" > "$FIX/ref1"; opt_in; files "$(plain src/x.ts)"
run_case "+ = @ base name → base_ref=rc+1=a@b" 10 "$(ship CLEAN verify-site 0 0 op-user 0 rc+1=a@b)"
new_case; BREF='release/@someone' review "$HEAD"
run_case "@ after / (mention surface) → error" 1 error

for p in AGENTS.md CLAUDE.md docs/AGENTS.md .claude/AGENTS.md .claude/CLAUDE.md .claude/skills/x/SKILL.md \
         tests/.cursorrules .cursor/rules/x.mdc .agents/skills/x/SKILL.md .codex/skills/x/SKILL.md \
         .claude/agents/verifier.md .codex/agents/x.md .claude/settings.json .cursorignore \
         web/.cursorindexingignore apps/web/.cursor/skills/x/SKILL.md docs/.agents/skills/x/SKILL.md \
         CLAUDE.local.md docs/CLAUDE.local.md .mcp.json; do
  new_case; opt_in; files "$(plain "$p")"
  run_case "agent config $p (edit or delete) → shipping, agent_config_edited=1" 10 "$(ship CLEAN verify-site 1)"
done
new_case; opt_in; files '{"filename":"src/old.ts","previous_filename":".cursor/skills/verify-site/SKILL.md"}'
run_case "rename out of .cursor/skills → agent_config_edited=1" 10 "$(ship CLEAN verify-site 1)"
new_case; opt_in; files "$(plain .claude/CLAUDE.md)" "$(plain src/x.ts)"
run_case "agent config alongside a src edit → agent_config_edited=1" 10 "$(ship CLEAN verify-site 1)"
for p in src/skills/x.ts src/my.claude.ts docs/claude/skills.md; do
  new_case; opt_in; files "$(plain "$p")" "$(plain src/y.ts)"
  run_case "$p is not agent config → agent_config_edited=0" 10 "$(ship)"
done

new_case; opt_in; : > "$FIX/files"
run_case "empty listing → files_incomplete=1" 10 "$(ship CLEAN verify-site 0 1)"

for a in '{"login":".dot"}' '{"login":"a b"}' '{"login":""}' 'null' '{"login":"x;y"}'; do
  new_case; AUTHOR=$a review "$HEAD"; opt_in; files "$(plain src/x.ts)"
  run_case "author $a → author=-" 10 "$(ship CLEAN verify-site 0 0 -)"
done
for l in app/dependabot 'renovate[bot]' Op-User; do
  new_case; AUTHOR="{\"login\":\"$l\"}" review "$HEAD"; opt_in; files "$(plain src/x.ts)"
  run_case "author $l passes through" 10 "$(ship CLEAN verify-site 0 0 "$l")"
done

new_case; XREPO=true review "$HEAD"; opt_in; files "$(plain src/x.ts)"
run_case "cross-repo PR → cross_repo=1" 10 "$(ship CLEAN verify-site 0 0 op-user 1)"
for x in null '"false"' 0; do
  new_case; XREPO=$x review "$HEAD"; opt_in; files "$(plain src/x.ts)"
  run_case "isCrossRepository $x → error" 1 error
done
new_case; printf '{"baseRefName":"main","headRefOid":"%s","mergeStateStatus":"CLEAN","author":%s}\n' "$HEAD" "$DEF_AUTHOR" > "$FIX/view1"
cp "$FIX/view1" "$FIX/view2"
run_case "isCrossRepository omitted → error" 1 error

new_case; opt_in "$(entry $DIR verify-b 1 tree)" "$(entry $DIR helper 2 tree)" "$(entry $DIR verify-a 3 tree)" "$(entry $BLOB verify-c.md 4 blob)"
files "$(plain src/x.ts)"
run_case "skills filtered and sorted" 10 "$(ship CLEAN verify-a,verify-b)"
# shellcheck disable=SC2016  # 'verify-a$b' is a deliberately invalid literal skill name
new_case; opt_in "$(entry $DIR verify-a 1 tree)" "$(entry $DIR 'verify-a$b' 2 tree)"; files "$(plain src/x.ts)"
run_case "one invalid skill name → skills=-" 10 "$(ship CLEAN -)"
# #940: a bare `verify-` still opts in and is invalid, so it blocks the kick instead of vanishing
new_case; opt_in "$(entry $DIR verify- 1 tree)"; files "$(plain src/x.ts)"
run_case "bare verify- dir alone → shipping, skills=-" 10 "$(ship CLEAN -)"
new_case; opt_in "$(entry $DIR verify- 1 tree)" "$(entry $DIR verify-site 2 tree)"; files "$(plain src/x.ts)"
run_case "bare verify- next to verify-site → skills=-" 10 "$(ship CLEAN -)"
new_case; opt_in '{"mode":"040000","path":"verify-site","type":"tree"}'; files "$(plain docs/a.md)"
run_case "verify-* entry without a sha → error" 1 error
new_case; opt_in; files '{"filename":"src/x.ts","previous_filename":"CLAUDE.local.md"}'
run_case "rename out of CLAUDE.local.md → agent_config_edited=1" 10 "$(ship CLEAN verify-site 1)"

echo "── import walk (#936) ───────────────────────────────────────"
new_case; run_case "not opted in → merge (walk)" 0 merge
if grep -qE 'recursive=1|^api graphql' "$FIX/calls"; then fail "not opted in makes no walk calls"; else pass "not opted in makes no walk calls"; fi

walk_case '.claude/CLAUDE.md=See @../docs/agent-notes.md' 'docs/agent-notes.md=notes'; only docs/agent-notes.md
run_case "docs-only edit of an imported file → agent config" 10 "$AC"
walk_case '.claude/CLAUDE.md=See @../docs/agent-notes.md' 'docs/agent-notes.md=notes'; files "$(plain docs/agent-notes.md)" "$(plain src/x.ts)"
run_case "code+docs edit of an imported file → agent_config_edited=1" 10 "$AC"
walk_case '.claude/CLAUDE.md=See @../docs/agent-notes.md' 'docs/agent-notes.md=notes'; only docs/other.md
run_case "docs-only edit of a file nothing imports → merge" 0 merge

walk_case '.claude/CLAUDE.md=@../docs/a.md' 'docs/a.md=@b.md' 'docs/b.md=x'; only docs/b.md
run_case "two-hop import → agent config" 10 "$AC"
walk_case '.claude/CLAUDE.md=@../docs/a.md' 'docs/a.md=@b.md' 'docs/b.md=@a.md'; only docs/other.md
run_case "import cycle terminates → merge" 0 merge
CHAIN=('.claude/CLAUDE.md=@../docs/d1.md' 'docs/d1.md=@d2.md' 'docs/d2.md=@d3.md' 'docs/d3.md=@d4.md' 'docs/d4.md=@d5.md')
walk_case "${CHAIN[@]}" 'docs/d5.md=end'; only docs/other.md
run_case "five-hop chain, depth 5 with no candidate → complete" 0 merge
walk_case "${CHAIN[@]}" 'docs/d5.md=end'; only docs/d5.md
run_case "five-hop chain: the depth-5 file is agent config" 10 "$AC"
walk_case "${CHAIN[@]}" 'docs/d5.md=@d6.md' 'docs/d6.md=x'; only docs/other.md
run_case "sixth import of an instruction file → incomplete" 10 "$AC"
walk_case "${CHAIN[@]}" 'docs/d5.md=@../package.json' 'package.json=x'; only docs/other.md
run_case "depth-5 live @package.json → incomplete" 10 "$AC"
walk_case "${CHAIN[@]}" 'docs/d5.md=@new.md'; files "$(plain docs/new.md)" "$(plain docs/other.md)"
run_case "depth-5 live @new.md, no entry: the added file is agent config" 10 "$AC"
walk_case "${CHAIN[@]}" 'docs/d5.md=@new.md'; only docs/other.md
run_case "depth-5 live @new.md, no entry: the walk stays complete" 0 merge
walk_case "${CHAIN[@]}" 'docs/d5.md=`@../README`' 'README=x'; only docs/other.md
run_case "backticked @README in a depth-5 Claude-only file → merge" 0 merge

walk_case '.claude/CLAUDE.md=@../docs/policy.md#rules' 'docs/policy.md=x'; only docs/policy.md
run_case "@path#fragment imports the path" 10 "$AC"
walk_case '.claude/CLAUDE.md=[see](x)@../docs/a.md' 'docs/a.md=x'; only docs/a.md
run_case "@ right after a link's ) starts a token" 10 "$AC"
walk_case '.claude/CLAUDE.md=\"@../docs/a.md' 'docs/a.md=@b.md' 'docs/b.md=x'; only docs/b.md
run_case "escaped quote before @ is live, so the import is walked" 10 "$AC"
walk_case '.claude/CLAUDE.md=[@../docs/x.md](../docs/x.md)' 'docs/x.md=x'; only docs/x.md
run_case "link import [@path](path)" 10 "$AC"
walk_case '.claude/CLAUDE.md=[**@../docs/x.md**](../docs/x.md)' 'docs/x.md=x'; only docs/x.md
run_case "[**@path**](path) imports the path" 10 "$AC"
walk_case '.claude/CLAUDE.md=`@../docs/a.md`' 'docs/a.md=x'; only docs/a.md
run_case "an import inside a code span still counts" 10 "$AC"
walk_case '.claude/CLAUDE.md=`@../docs/notes.md`' 'docs/notes.md=@/abs'; only docs/other.md
run_case "a backticked import is not walked, so its @/abs does not count" 0 merge
walk_case '.claude/CLAUDE.md=@../docs/new.md'; only docs/new.md
run_case "a missing target the PR adds → agent config" 10 "$AC"
walk_case '.claude/CLAUDE.md=@../package.json' 'package.json={"devDependencies": {"@types/node": "1"}}'; only package.json
run_case "@package.json: package.json is agent config" 10 "$AC"
walk_case 'CLAUDE.md=@package.json' 'package.json={"devDependencies": {"@types/node": "1"}}'; only docs/other.md
run_case "root CLAUDE.md → package.json: Cursor-live @types/node only adds a cover" 0 merge
walk_case '.claude/CLAUDE.md=@../README' 'README=@docs/policy.md' 'docs/policy.md=x'; only docs/policy.md
run_case "chain through an extensionless README" 10 "$AC"

new_case; opt_in
at "$HEAD" '.claude/CLAUDE.md=@../docs/h.md' 'docs/h.md=x' 'docs/b.md=x'
at "$BASE" '.claude/CLAUDE.md=@../docs/b.md' 'docs/h.md=x' 'docs/b.md=x'; only docs/b.md
run_case "import present only at base_tip" 10 "$AC"
only docs/h.md
run_case "import present only at head" 10 "$AC"
new_case; opt_in
at "$BASE" '.claude/CLAUDE.md=@../docs/new-rules/' 'docs/r.md=x'
at "$HEAD" '.claude/CLAUDE.md=x' 'docs/r.md=x' 'docs/new-rules/a.md=x'; only docs/new-rules/a.md
run_case "base-only live @docs/new-rules/ with no tree; the PR adds a file under it → agent config" 10 "$AC"
new_case; opt_in
at "$BASE" '.claude/CLAUDE.md=@../docs/link/x.md' 'docs/r.md=x'
at "$HEAD" '.claude/CLAUDE.md=x' 'docs/r.md=x' 'docs/link@link'; only docs/link
run_case "base imports a missing docs/link/x.md; the PR adds docs/link as a symlink → agent config" 10 "$AC"

walk_case '.claude/CLAUDE.md=@../docs' 'docs/guide.md=@../src/conventions.md' 'src/conventions.md=x'; only src/conventions.md
run_case "live directory import → incomplete" 10 "$AC"
walk_case '.claude/CLAUDE.md=`@../docs/guides`' 'docs/guides/a.md=x'; only docs/guides/a.md
run_case "backticked directory in a Claude-only file → merge" 0 merge
new_case; opt_in
at "$HEAD" '.claude/CLAUDE.md=`@../docs/guides`' 'docs/guides/a.md=x'; at "$BASE" '.claude/CLAUDE.md=`@../docs/guides`'; only docs/guides/a.md
run_case "backticked directory that exists only at head → merge" 0 merge
walk_case '.cursor/rules/r.mdc=`@docs/policies`' 'docs/policies/a.md=x'; only docs/other.md
run_case "backticked directory in a Cursor-read file → incomplete" 10 "$AC"

walk_case $'.claude/CLAUDE.md=```\n@/abs\n```'; only docs/other.md
run_case "@/abs inside a fence → incomplete" 10 "$AC"
walk_case $'.claude/CLAUDE.md=  ~~~\ncode\n~~~\n@../docs/a.md\n~~~' 'docs/a.md=@b.md' 'docs/b.md=x'; only docs/b.md
run_case "indented ~~~ is prose: the import after it is live" 10 "$AC"
walk_case $'.claude/CLAUDE.md=a `b\n`code @../docs/a.md literal`\n` end' 'docs/a.md=@b.md' 'docs/b.md=x'; only docs/b.md
run_case "an unpaired backtick in the paragraph: code spans ignored, the import is live" 10 "$AC"
walk_case '.claude/CLAUDE.md=`@/x`'; only docs/other.md
run_case "a paired code span in a plain paragraph hides @/x" 0 merge
walk_case '.claude/CLAUDE.md=[x](a`) @../docs/a.md `' 'docs/a.md=@b.md' 'docs/b.md=x'; only docs/b.md
run_case "a link destination swallows a backtick: the import is live" 10 "$AC"
walk_case '.claude/CLAUDE.md=| x `y | @../docs/a.md z` |' 'docs/a.md=@b.md' 'docs/b.md=x'; only docs/b.md
run_case "a table cell boundary splits a backtick pair: the import is live" 10 "$AC"
walk_case '.claude/CLAUDE.md=x www.example.com/a` @../docs/a.md `' 'docs/a.md=@b.md' 'docs/b.md=x'; only docs/b.md
run_case "an autolink takes a backtick: the import is live" 10 "$AC"
walk_case '.claude/CLAUDE.md=<https://example.com> `@/x`'; only docs/other.md
run_case "a paragraph with an autolink ignores code spans → incomplete" 10 "$AC"
walk_case '.claude/CLAUDE.md=<1`@example.com> @../docs/a.md `' 'docs/a.md=@b.md' 'docs/b.md=x'; only docs/b.md
run_case "an email autolink swallows a backtick: the import is live" 10 "$AC"

for t in '@~/x.md' '@../../outside.md' '@/abs/x.md'; do
  walk_case ".claude/CLAUDE.md=see $t"; only docs/other.md
  run_case "live $t → incomplete" 10 "$AC"
  walk_case ".claude/CLAUDE.md=see \`$t\`"; only docs/other.md
  run_case "backticked $t → merge" 0 merge
done
walk_case ".claude/CLAUDE.md=see '@/x'"; only docs/other.md
run_case "quoted '@/x' → merge" 0 merge
walk_case '.claude/CLAUDE.md=@../src/a.ts' "src/a.ts=import x from '@/lib'"; only docs/other.md
run_case ".ts from a Claude-only entry: a quoted '@/lib' is not live → merge" 0 merge
walk_case 'AGENTS.md=@src/a.ts' "src/a.ts=import x from '@/lib'"; only docs/other.md
run_case ".ts from AGENTS.md: '@/lib' is Cursor-live → incomplete" 10 "$AC"
walk_case '.cursor/rules/r.mdc=@README' 'README=`@docs/policy.md`' 'docs/policy.md=@detail.md' 'docs/detail.md=x'; only docs/detail.md
run_case "Cursor rule → README → backticked policy → detail → agent config" 10 "$AC"
walk_case '.claude/CLAUDE.md=@../assets/logo.png' 'assets/logo.png@bin'; only docs/other.md
run_case "live binary import → incomplete" 10 "$AC"
walk_case '.claude/CLAUDE.md=`@../assets/logo.png`' 'assets/logo.png@bin'; only docs/other.md
run_case "a backticked binary is not fetched → merge" 0 merge
walk_case '.cursor/skills/s/SKILL.md=see `@/lib`'; only docs/other.md
run_case "@/lib in a Cursor skill → incomplete" 10 "$AC"
walk_case 'frontend/AGENTS.md=@../docs/a.md' 'docs/a.md=x'; only docs/other.md
run_case "a ../ mention in a Cursor-read file leaves the repo from the root → incomplete" 10 "$AC"
walk_case '.claude/CLAUDE.md=@../vendor/link/../../docs/x.md' 'vendor@gitlink' 'docs/x.md=x'; only docs/x.md
run_case "a live path that descends below a gitlink → incomplete" 10 "$AC"
walk_case '.cursor/rules/r.mdc=@/workspace/project/docs/policy.md'; only docs/other.md
run_case "an absolute checkout path in a Cursor rule → incomplete" 10 "$AC"
walk_case '.claude/CLAUDE.md=- **Path alias:** `@/*` maps to `src/*`'; only docs/other.md
run_case "backticked @/* alias note in .claude/CLAUDE.md → merge" 0 merge
walk_case 'CLAUDE.md=- **Path alias:** `@/*` maps to `src/*`'; only docs/other.md
run_case "the same note in root CLAUDE.md is Cursor-live → incomplete" 10 "$AC"
walk_case 'CLAUDE.md=@docs/a://rules.md' 'docs/a:/rules.md=x'; only 'docs/a:/rules.md'
run_case "a later :// is part of a path" 10 "$AC"
walk_case 'CLAUDE.md=@https://example.com/x.md'; only docs/other.md
run_case "a URL is ignored" 0 merge

walk_case '.claude/rules/x.md@link'; only docs/other.md
run_case "symlinked entry → incomplete" 10 "$AC"
walk_case '.cursor/rules@link'; only docs/other.md
run_case "symlinked .cursor/rules → incomplete" 10 "$AC"
walk_case '.claude/rules@gitlink'; only docs/other.md
run_case "submodule at an agent-config path → incomplete" 10 "$AC"
walk_case '.claude/CLAUDE.md=@../docs/link/../payload.md' 'docs/link@link' 'tests/payload.md=x'; only tests/payload.md
run_case "a symlink prefix before .. → incomplete" 10 "$AC"
walk_case '.claude/CLAUDE.md=@../docs/t.md' 'docs/t.md@link'; only docs/other.md
run_case "a live import of a symlink → incomplete" 10 "$AC"
walk_case '.claude/CLAUDE.md=`@../docs/link/x.md`' 'docs/link@link'; only docs/other.md
run_case "a backticked import through a symlink → merge" 0 merge
walk_case '.claude/CLAUDE.md=@../vendor/rules.md' 'vendor@gitlink'; only docs/other.md
run_case "a live import under a gitlink → incomplete" 10 "$AC"
walk_case '.claude/CLAUDE.md=`@../vendor/rules.md`' 'vendor@gitlink'; only docs/other.md
run_case "a backticked import under a gitlink → merge" 0 merge
walk_case '.claude/CLAUDE.md=@../submod/../docs/x.md' 'submod@gitlink' 'docs/x.md=x'; only docs/x.md
run_case "@submod/../docs/x.md imports docs/x.md" 10 "$AC"

for e in .claude/agents/a.md .codex/agents/b.md .cursor/skills/verify-site/SKILL.md .claude/skills/s/SKILL.md \
         frontend/CLAUDE.md frontend/agents.md; do
  walk_case "$e=@docs/x.md" 'docs/x.md=x'; only docs/x.md
  run_case "$e reads @docs/x.md from the repo root" 10 "$AC"
done
walk_case '.cursorrules=@docs/x.md' 'docs/x.md=x'; only docs/x.md
run_case ".cursorrules imports a doc" 10 "$AC"
walk_case '.cursor/rules/r.mdc=@template.ts' 'src/gen/template.ts=x'; only src/gen/template.ts
run_case "a bare Cursor mention is found by name" 10 "$AC"
new_case; opt_in
at "$BASE" '.cursor/rules/r.mdc=@template.ts'; at "$HEAD" '.cursor/rules/r.mdc=x' 'src/gen/template.ts=x'; only src/gen/template.ts
run_case "a base-only bare mention matches a file only head holds" 10 "$AC"
walk_case '.claude/CLAUDE.md=`@shared`' 'shared/a.ts=x'; files "$(plain shared/a.ts)" "$(plain src/y.ts)"
run_case "backticked @shared in .claude/CLAUDE.md is not agent config" 10 "$(ship)"
walk_case '.claude/CLAUDE.md=@../docs/shared.md' '.cursor/rules/r.mdc=@docs/shared.md' 'docs/shared.md=`@docs/policies`' 'docs/policies/a.md=x'
only docs/other.md
run_case "a shared file is parsed again on the Cursor visit: its backticked directory → incomplete" 10 "$AC"

RULES=(); for i in $(seq 60); do RULES+=(".claude/rules/r$i.md=rule $i"); done
walk_case "${RULES[@]}" '.claude/CLAUDE.md=@../docs/a.md' 'docs/a.md=rule 1'; only docs/a.md
run_case "61 entries at both revisions → classified precisely" 10 "$AC"
if [ "$(gql_count)" = 2 ]; then pass "61 blobs shared by both revisions fetched once, in 2 queries"; else fail "61 shared blobs in 2 queries (saw $(gql_count))"; fi
walk_case .claude/rules/{a,b,c,d,e}.md%500000; only docs/other.md
run_case "five 500 KB entries → merge" 0 merge
if [ "$(gql_count)" = 2 ]; then pass "the 2 MiB budget splits five 500 KB entries into 2 queries"; else fail "2 MiB budget split (saw $(gql_count))"; fi
walk_case '.claude/CLAUDE.md=`@../docs/big.md`' 'docs/big.md@big'; only docs/other.md
run_case "a 600 KiB file behind a backticked import is never fetched → merge" 0 merge
walk_case '.claude/CLAUDE.md=x' '@truncated'; only docs/other.md
run_case "truncated recursive tree → incomplete" 10 "$AC"
walk_case '.claude/CLAUDE.md=@../data.json' 'data.json@big'; only docs/other.md
run_case "a live-imported 600 KiB JSON file → incomplete" 10 "$AC"
if [ "$(gql_count)" = 1 ]; then pass "the 600 KiB file is never fetched"; else fail "600 KiB file fetched (saw $(gql_count) queries)"; fi
for k in trunc bin nullbin; do
  walk_case '.claude/CLAUDE.md=@../docs/n.md' "docs/n.md@$k"; only docs/other.md
  run_case "a fetched .md with shape $k → incomplete" 10 "$AC"
done
walk_case '.claude/CLAUDE.md=@../notes.txt' 'notes.txt@bin'; only docs/other.md
run_case "an isBinary notes.txt → incomplete" 10 "$AC"
R301=(); for i in $(seq 301); do R301+=(".claude/rules/r$i.md=rule $i"); done
walk_case "${R301[@]}"; only docs/other.md
run_case "more than 300 blobs → incomplete" 10 "$AC"
Q=(); for i in $(seq 60); do Q+=(".claude/rules/q$i.md%400000"); done
walk_case "${Q[@]}"; only docs/other.md
run_case "exactly 12 GraphQL queries → complete" 0 merge
walk_case "${Q[@]}" .claude/rules/q61.md%400000; only docs/other.md
run_case "a 13th GraphQL query → incomplete" 10 "$AC"
S=(); for i in $(seq 1001); do S+=(".claude/rules/s$i.md=same"); done
walk_case "${S[@]}"; only docs/other.md
run_case "more than 2000 visited states → incomplete" 10 "$AC"
sed 's/^WALK_DEADLINE = 600 /WALK_DEADLINE = 0 /' "$SCRIPT" > "$TMP/ns-deadline.py"
if grep -q '^WALK_DEADLINE = 0 ' "$TMP/ns-deadline.py"; then
  walk_case '.claude/CLAUDE.md=x'; only docs/other.md
  SCRIPT_RUN="$TMP/ns-deadline.py" run_case "a passed walk deadline → incomplete" 10 "$AC"
else
  fail "could not zero WALK_DEADLINE in the test copy"
fi
walk_case '.claude/CLAUDE.md=x'; only docs/other.md; : > "$FIX/rhang"
SCRIPT_RUN="$TMP/needs-shipping-fast.py" run_case "a walk call that times out → incomplete" 10 "$AC"

walk_case '.claude/CLAUDE.md=x'; only docs/other.md; echo '{"errors":[{"message":"boom"}]}' > "$FIX/gql-body"
run_case "GraphQL errors array → error" 1 error
walk_case '.claude/CLAUDE.md=x'; only docs/other.md; echo '{"data":{}}' > "$FIX/gql-body"
run_case "malformed GraphQL response → error" 1 error
new_case; opt_in; echo '{"tree":"x","truncated":false}' > "$FIX/rtree-default"; only docs/other.md
run_case "malformed recursive tree → error" 1 error
new_case; opt_in; only docs/other.md
printf '{"sha":"x","truncated":false,"tree":[{"path":"a.md","mode":"100644","type":"blob","sha":"%s"}]}\n' "$OTHER" > "$FIX/rtree-default"
run_case "a recursive-tree blob row with no size → error" 1 error
new_case; opt_in; echo 1 > "$FIX/rtree-default.rc"; only docs/other.md
run_case "a walk gh call failing without a timeout → error" 1 error
out=$("$PY" -I "$SCRIPT" o/r 42 abc 2>/dev/null); rc=$?
if [ "$rc" = 1 ] && [ "${out#error}" != "$out" ]; then pass "bad arguments → error, exit 1"; else fail "bad arguments → error (rc=$rc)"; fi

echo "── tripwire (#950) ──────────────────────────────────────────"
walk_case '.claude/settings.json={"permissions": {}}' '.claude/CLAUDE.md=x'; only src/x.ts
run_case "permissions-only .claude/settings.json → incomplete" 10 "$AC"
if [ "$(gql_count)" = 0 ]; then pass "structured config trips from the tree alone (no blob fetch)"; else fail "structured config fetched blobs ($(gql_count))"; fi
walk_case '.mcp.json={"mcpServers": {"s": {"url": "https://x"}}}'; only src/x.ts
run_case "url-only .mcp.json → incomplete" 10 "$AC"
new_case; opt_in; at "$HEAD"; at "$BASE" '.cursor/hooks.json={}'; only src/x.ts
run_case ".cursor/hooks.json at base_tip only → incomplete" 10 "$AC"
for p in sub/.claude/settings.local.json .codex/config.toml .codex/hooks.json \
         .claude/skills/p/.claude-plugin/plugin.json .cursor/skills/verify-x/config.yaml; do
  walk_case "$p=x"; only src/x.ts
  run_case "$p → incomplete" 10 "$AC"
done
walk_case '.cursor/environment.json={"install": "npm ci"}'; only src/x.ts
run_case ".cursor/environment.json alone → no trip" 10 "$(ship)"
walk_case '.cursor/environment.json={"install": "npm ci"}'; only .cursor/environment.json
run_case "a PR editing .cursor/environment.json is still agent config" 10 "$AC"
walk_case '.claude/archive.json@dir'; only src/x.ts
run_case "a directory named like config → no trip (blobs only)" 10 "$(ship)"
walk_case $'.claude/agents/x.md=---\nhooks:\n  - x\n---\nbody'; only src/x.ts
run_case "agent frontmatter hooks → incomplete" 10 "$AC"
walk_case $'.claude/agents/x.md=---\nmcpServers: {}\n---\nbody'; only src/x.ts
run_case "agent frontmatter mcpServers → incomplete" 10 "$AC"
walk_case $'.claude/agents/x.md=---\r\nhooks: x\r\n---\r\nbody'; only src/x.ts
run_case "CRLF agent frontmatter hooks → incomplete" 10 "$AC"
walk_case $'.claude/skills/s/SKILL.md=---\nname: s\ndescription: d\n---\nbody'; only src/x.ts
run_case "skill with name/description only → no trip" 10 "$(ship)"
walk_case $'.claude/skills/s/SKILL.md=---\nname: s\n"hooks": x\n---\nbody'; only src/x.ts
run_case "quoted frontmatter key → incomplete" 10 "$AC"
# shellcheck disable=SC2016  # literal backticks in fixture text
walk_case '.claude/skills/s/SKILL.md=Diff: !`./scripts/x.sh`'; only src/x.ts
run_case "skill !\`cmd\` → incomplete" 10 "$AC"
walk_case $'.claude/commands/c.md=```!\n./scripts/x.sh\n```'; only src/x.ts
run_case "command \`\`\`! fence → incomplete" 10 "$AC"
# shellcheck disable=SC2016  # literal backticks in fixture text
walk_case '.claude/skills/s/SKILL.md=Use `println!` here'; only src/x.ts
run_case "skill code span println! → no trip" 10 "$(ship)"
# shellcheck disable=SC2016  # literal backticks in fixture text
walk_case 'CLAUDE.md=Use `println!` and !`x` here'; only src/x.ts
run_case "CLAUDE.md is outside the shell-injection scope → no trip" 10 "$(ship)"
# shellcheck disable=SC2016  # literal backticks in fixture text
walk_case '.claude/agents/x.md=!`./scripts/x.sh`' '.claude/skills/s/SKILL.md=!`./scripts/x.sh`'; only src/x.ts
run_case "same blob at an agent and a skill path → incomplete (checked per path)" 10 "$AC"
# shellcheck disable=SC2016  # literal backticks and $ in fixture text
walk_case $'.claude/skills/s/SKILL.md=---\narguments: [unused]\n---\n$unused!`./scripts/x.sh`'; only src/x.ts
run_case "skill \$placeholder!\`cmd\` → incomplete" 10 "$AC"
# shellcheck disable=SC2016  # literal backticks in fixture text
new_case; opt_in; at "$HEAD"; at "$BASE" '.claude/skills/s/SKILL.md=!`./scripts/x.sh`'; only src/x.ts
run_case "skill !\`cmd\` at base_tip only → incomplete" 10 "$AC"
# shellcheck disable=SC2016  # literal backticks in fixture text
new_case; opt_in; at "$HEAD" '.claude/skills/s/SKILL.md=!$unused`./scripts/x.sh`'; at "$BASE"; only src/x.ts
run_case "skill !\$placeholder\`cmd\` at head only → incomplete" 10 "$AC"
# shellcheck disable=SC2016  # literal backticks in fixture text
walk_case '.claude/CLAUDE.md=@../docs/skills/x.md' $'docs/skills/x.md=---\nhooks: x\n---\n!`./scripts/x.sh`'; only src/x.ts
run_case "triggers in an imported (depth 1) file are not run → no trip" 10 "$(ship)"
walk_case '.claude/skills/a!b/SKILL.md=body'; only src/x.ts
run_case "skill directory with ! → incomplete" 10 "$AC"
# shellcheck disable=SC2016  # literal backtick in fixture path
walk_case '.claude/skills/a`b/SKILL.md=body'; only src/x.ts
run_case "skill directory with a backtick → incomplete" 10 "$AC"
out=$("$PY" -I "$SCRIPT" --selftest 2>&1); rc=$?
if [ "$rc" = 0 ] && [ "$out" = needs_shipping_selftest_ok ]; then pass "--selftest under $PY"; else fail "--selftest under $PY ($out)"; fi

echo "── prose wiring ─────────────────────────────────────────────"
COMP=skills/pr-grind/references/completion.md
SKILL=skills/pr-grind/SKILL.md
QUAL='only when Shipping routing exited 0'
line_of() { grep -nF -- "$2" "$1" | head -1 | cut -d: -f1; }
# t <label> <command...>: pass when the command succeeds.
t() { local label=$1; shift; if "$@"; then pass "$label"; else fail "$label"; fi; }
has() { grep -qF -- "$2" <<<"$1"; }           # has <text> <literal>
lacks() { ! grep -qF -- "$2" <<<"$1"; }       # lacks <text> <literal>

L_VERIFY=$(line_of "$COMP" '**Verify checks are green')
L_ROUTE=$(line_of "$COMP" '**Shipping routing (REQUIRED')
L_BLOCK=$(line_of "$COMP" '**Shipping block:')
L_MARKER=$(line_of "$COMP" '**Write the pr-grind-clean marker')
in_order() { [ -n "$1" ] && [ -n "$2" ] && [ "$1" -lt "$2" ]; }
if in_order "$L_VERIFY" "$L_ROUTE" && in_order "$L_ROUTE" "$L_MARKER"; then
  pass "routing sits between 'Verify checks are green' and the marker write"
else
  fail "routing sits between 'Verify checks are green' and the marker write"
fi

ROUTE_TEXT=$(sed -n "${L_ROUTE},$((L_MARKER - 1))p" "$COMP")
BLOCK_BASH=$(sed -n "${L_BLOCK},\$p" "$COMP" | awk '/^```bash/{f=1;next} f&&/^```/{exit} f')
# shellcheck disable=SC2016  # literal shell text being searched for
t "Shipping block removes both markers" \
  has "$BLOCK_BASH" 'rm -f "$R/.claude/pr-grind-clean.local" "$R/.claude/pr-pending-grind.local"'
writes_marker() { grep -E '(printf|cp|>).*pr-grind-clean\.local' <<<"$1" | grep -qvE '^[[:space:]]*(rm|\[)'; }
if writes_marker "$BLOCK_BASH"; then fail "Shipping block never writes or copies the clean marker"
else pass "Shipping block never writes or copies the clean marker"; fi
# shellcheck disable=SC2016
t "Shipping block iterates roots as a quoted array" has "$BLOCK_BASH" 'for R in "${ROOTS[@]}"'
t "routing names the catch-all" has "$ROUTE_TEXT" '**anything else**'
t "routing BAILs env" has "$ROUTE_TEXT" 'RESULT_BAIL_CATEGORY=env'
# shellcheck disable=SC2016  # literal backticks being searched for
t "routing says --no-merge does not override it" has "$ROUTE_TEXT" '`--no-merge` does not override this'
t "routing section does not prune Codex retrigger markers" lacks "$ROUTE_TEXT" 'codex-retrigger-gc'
if grep -qE '^REVIEWED_HEAD=' <<<"$ROUTE_TEXT"; then fail "routing passes the head inline (no REVIEWED_HEAD= assignment)"
else pass "routing passes the head inline (no REVIEWED_HEAD= assignment)"; fi

# Execute the Shipping block itself (placeholders substituted) in repos whose paths
# contain a space, with markers pre-seeded in both roots.
run_block() { # <session-repo> <orig-path> <no_worktree>
  local blk
  blk=$(printf '%s\n' "$BLOCK_BASH" | sed -e "s|<0\|1 — see \"Resolve flag-to-state translations\" in START>|$3|" \
    -e "s|<original-worktree-path>|\"$2\"|g" -e 's|<PR_NUMBER>|42|g')
  (cd "$1" && bash -c "$blk") >/dev/null 2>&1
}
seed() { for r in "$@"; do mkdir -p "$r/.claude"; echo "42 $HEAD" > "$r/.claude/pr-grind-clean.local"; : > "$r/.claude/pr-pending-grind.local"; done; }
gone() { for f in "$@"; do [ ! -e "$f" ] || return 1; done; }
SP="$TMP/with space"; mkdir -p "$SP"
git init -q "$SP/session repo"; git init -q "$SP/orig repo"
seed "$SP/session repo" "$SP/orig repo"
run_block "$SP/session repo" "$SP/orig repo" 0; rc=$?
if [ "$rc" = 0 ] && gone "$SP/session repo/.claude/pr-grind-clean.local" "$SP/orig repo/.claude/pr-grind-clean.local" "$SP/orig repo/.claude/pr-pending-grind.local"; then
  pass "Shipping block (paths with spaces) exits 0 and removes markers in both roots"
else
  fail "Shipping block (paths with spaces) exits 0 and removes markers in both roots (rc=$rc)"
fi
seed "$SP/session repo"
run_block "$SP/session repo" "$SP/missing repo" 0; rc=$?
if [ "$rc" != 0 ] && gone "$SP/session repo/.claude/pr-grind-clean.local"; then
  pass "Shipping block: unresolvable original root still clears the session marker, then exits non-zero"
else
  fail "Shipping block: unresolvable original root still clears the session marker, then exits non-zero (rc=$rc)"
fi

L_EI=$(awk -v r="$L_ROUTE" 'NR>r && /^<EXTREMELY-IMPORTANT>/{print NR; exit}' "$COMP")
qualified() { sed -n "${1}p" "$COMP" | grep -qiF -- "$QUAL"; }
t "CRITICAL two-call block carries the exit-0 qualifier" qualified "$((L_EI + 1))"
t "marker-write heading carries the exit-0 qualifier" qualified "$L_MARKER"
# shellcheck disable=SC2016  # literal backticks being searched for
t "--no-merge heading carries the exit-0 qualifier" qualified "$(line_of "$COMP" '**If `--no-merge`')"
# shellcheck disable=SC2016  # literal backticks being searched for
for w in 'Ready for Shipping: this repo opted in (base tip has .cursor/skills/verify-*)' \
         'The cloud agent updates a BEHIND branch after PASS.' 'auto-kick skipped: --no-merge; the operator may kick Shipping by hand'; do
  t "output carries: $w" grep -qF -- "$w" "$COMP"
done
# shellcheck disable=SC2016  # literal backticks being searched for
for w in 'Kick Cursor Cloud Shipping on PR' 'Shipping rebases the bottom PR itself' 'before kicking Shipping' '`.claude/**/*.md`, tests)'; do
  t "old wording gone: $w" bash -c '! grep -qF -- "$1" "$2"' _ "$w" "$COMP"
done

L_KICK=$(line_of "$COMP" '**Shipping kick (exit 10 only')
L_NOMERGE=$(awk -v k="$L_KICK" 'NR>k && /^- \*\*With `--no-merge`:\*\*/{print NR; exit}' "$COMP")
L_KCMD=$(awk -v k="$L_KICK" 'NR>k && /scripts\/shipping-kick\.py/{print NR; exit}' "$COMP")
L_EI2=$(awk -v k="$L_KICK" 'NR>k && /^<EXTREMELY-IMPORTANT>/{print NR; exit}' "$COMP")
t "Shipping block before the kick section" in_order "$L_BLOCK" "$L_KICK"
t "--no-merge bullet before the kicker command" in_order "$L_NOMERGE" "$L_KCMD"
t "kick section ends before the marker-write EXTREMELY-IMPORTANT" in_order "$L_KCMD" "$L_EI2"
KICK_TEXT=$(sed -n "${L_KICK},$((L_EI2 - 1))p" "$COMP")
NOMERGE_LINE=$(sed -n "${L_NOMERGE}p" "$COMP")
KICK_BASH=$(printf '%s\n' "$KICK_TEXT" | awk '/^```bash/{f=1;next} f&&/^```/{exit} f')
t "--no-merge bullet never runs the kicker" lacks "$NOMERGE_LINE" 'shipping-kick.py'
t "kick bash block runs only the kicker" [ "$(printf '%s\n' "$KICK_BASH" | grep -c .)" = 1 ]
t "kick bash block never merges" lacks "$KICK_BASH" 'gh pr merge'
if writes_marker "$KICK_TEXT"; then fail "kick section never writes the clean marker"; else pass "kick section never writes the clean marker"; fi
# shellcheck disable=SC2016  # literal backticks being searched for
for row in '`not kicked: mergeStateStatus=`' '`not kicked: protection precondition`' 'naming `author` or `cross-repo`'; do
  ROW=$(printf '%s\n' "$KICK_TEXT" | grep -F -- "$row")
  t "follow-up for $row has no merge command" lacks "$ROW" 'gh pr merge'
  t "follow-up for $row has no skip file" lacks "$ROW" 'skip-pr-grind'
done
ESCAPE=$(printf '%s\n' "$KICK_TEXT" | awk '/^```text/{f=1;next} f&&/^```/{exit} f')
t "D4 escape pins the reviewed head" has "$ESCAPE" '--match-head-commit'
t "D4 escape pins the new head after update-branch" has "$ESCAPE" 'or after update-branch the new head'
t "D4 escape states the skip-file window" has "$ESCAPE" 'wait at least 30s'
t "kick section: a failed Shipping block means no kick" has "$KICK_TEXT" 'do not run the kicker'
t "routing names the eight exit-10 fields" has "$ROUTE_TEXT" 'files_incomplete=<0|1> author=<login|-> cross_repo=<0|1>'

L_SROUTE=$(line_of "$SKILL" 'Shipping routing (scripts/needs-shipping.py')
L_SMARK=$(line_of "$SKILL" 'Write .claude/pr-grind-clean.local at repo root')
t "SKILL.md diagram: routing node above the marker-write node" in_order "$L_SROUTE" "$L_SMARK"
t "SKILL.md diagram: --no-merge node marked exit-0 only" grep -qF '├── --no-merge (exit 0 only)' "$SKILL"

# shellcheck disable=SC2016  # literal backticks being searched for
t "classifier call states its Bash timeout" has "$ROUTE_TEXT" 'Run it with a Bash timeout of 1800000 ms'
t "kicker call states its Bash timeout" has "$KICK_TEXT" 'Run it with a Bash timeout of 3300000 ms'
# shellcheck disable=SC2016  # literal backticks being searched for
t "routing names imported files" has "$ROUTE_TEXT" 'import with `@path` (#936)'
# shellcheck disable=SC2016  # literal backticks being searched for
t "SKILL.md names imported files" grep -qF 'files an agent-config file imports with `@path`' "$SKILL"
t "SKILL.md names the #950 tripwire" grep -qF 'makes every path agent config (#950)' "$SKILL"
t "routing names the #950 tripwire" has "$ROUTE_TEXT" 'makes every path agent config (#950)'
t "kicker CLASSIFIER_TIMEOUT is 1700" grep -q '^CLASSIFIER_TIMEOUT = 1700 ' scripts/shipping-kick.py

echo
echo "needs-shipping: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
