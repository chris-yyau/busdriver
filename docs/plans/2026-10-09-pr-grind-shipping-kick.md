# pr-grind Shipping Auto-Kick Implementation Plan

> **Status: executed — do not re-run.** This plan shipped in #933 (`867c57ac`) and was hardened in #937 (`2791a5b9`). The shipped `scripts/needs-shipping.py`, `scripts/shipping-kick.py` and their test suites are authoritative. Code blocks below are kept as the record of what was planned and are NOT current where they differ. Known differences:
> - `AGENT_FILES` also lists `CLAUDE.local.md` and `.mcp.json`.
> - `gh()` and `run_gh()` pass only `GH_TOKEN`, `GITHUB_TOKEN` and `GH_CONFIG_DIR` from the `GH_*`/`GITHUB_*` family (plus the pinned `GH_HOST`), and every `gh` call has a 120s timeout (spec §2, ADR 0054). The kicker's classifier subprocess has a 1000s timeout and exits 6 on timeout (`CLASSIFIER_TIMEOUT` in `scripts/shipping-kick.py`).
> - The test suites grew past the cases planned here; `tests/test-needs-shipping.sh` and `tests/test-shipping-kick.sh` are the current contract.
> - The `<H>` placeholder wording was changed after all: merge step 2c tells the reader to replace the literal `H` with the full 40-hex SHA. Spec §1 now also rejects `..` in `base_ref`, so deviation 2 below is no longer a deviation.
> - `BASE_REF_RE` is synced below; the review-driven fixes to `verify_skills`, `CONTROL` and the merge-step wording live only in the code.
>
> To change this behaviour, edit the code and tests, not this plan.

> **For agentic workers:** historical record — do NOT execute any task in this plan, and never hand one of its tasks to a worker. Every step below is done (ticked). Running a task as written would overwrite the shipped fixes listed above.

**Goal:** On a Ready-for-Shipping completion, pr-grind posts one validated `@cursor` Shipping kick through a new `scripts/shipping-kick.py`, so opted-in PRs land with no human step (issue #929, ADR 0055).

**Architecture:** The read-only classifier `scripts/needs-shipping.py` moves opt-in to the base branch's live tip and emits seven extra `key=value` fields on exit 10. A new writer `scripts/shipping-kick.py` re-runs the classifier itself, applies every gate in a fixed order (dedupe, eligibility, live status, skills, branch protection, agent-config, head re-read), and posts a comment built only from validated fields. It prints exactly one status line and never the body. `completion.md` calls the kicker after the existing Shipping block and maps its exit code to one follow-up line.

**Tech Stack:** Python 3.9 stdlib (`/usr/bin/python3 -I`), `gh` CLI, bash 3.2-compatible shell tests with a stub `gh` on `PATH`, Markdown skill prose.

**Global Constraints:**
- Spec of record: `docs/specs/2026-10-09-pr-grind-shipping-kick-design.md` (blueprint-review PASS, FULL 3/3). Where this plan deviates, it says so and why.
- Python: stdlib only, 3.9-compatible, always run as `/usr/bin/python3 -I`. No new npm or pip dependencies.
- Every `gh` call pins `GH_HOST=github.com`, removes `GH_REPO`, and names the repo explicitly (`-R o/r` or `repos/o/r`). (Superseded by #937: see the status note above.)
- No environment-variable override of any path, gate or input in either script (a committed `settings.json` `env` block could set it).
- Fail closed: any API error, unparseable response or failed validation exits non-zero; nothing is posted on doubt.
- The kicker's stdout is exactly one line, at most 600 characters, with control characters removed. It never prints the comment body.
- Shell tests run under bash 3.2 (macOS): no `mapfile`, no `${x,,}`, no associative arrays.
- Any edit under `scripts/hooks/**` needs `./scripts/gate-integrity.sh --update` in the same commit.
- Commits use Conventional Commits and go through the litmus pre-commit gate (`init-review-loop.sh` then `run-review-loop.sh`); never `--no-verify`, never a skip file.
- Branch: `feat/929-shipping-kick` in worktree `/Volumes/Work/Projects/busdriver-929`.

**Low findings folded in from the spec review (run 10, `claude.json`):** git-version check worded as a check; `rev-list` wording; "may poll across several tool calls"; post body via stdin instead of a tmpfile; "re-run /pr-grind to evaluate the remaining gates"; one sanitizer for every status line; the D4 escape printed as an operator-only block with `--match-head-commit`; `--no-merge` wording in SKILL.md; line 123 edits only its last sentence; four ADR 0055 residual notes. Not folded: `<H>` placeholder rename (fails safe as is), `H^2 == base tip` (would cause false stops).

**Deviations from the spec text (all fail-closed or wording):**
1. The base-tip read fetches the full ref JSON and checks `ref`, `object.type == "commit"` and a 40-hex sha, instead of `--jq .object.sha`. Stricter.
2. `base_ref` also rejects any name containing `..` (a URL path segment).
3. Agent-config matching is case-insensitive (errs toward refusing the kick).
4. Step 7 checks `required_status_checks` absent or null before `strict`, so a null block names its own condition rather than "strict not enabled".
5. The spec's body test says the body "does not contain `gh pr update-branch`", but its own template says "never `gh pr update-branch`". The test asserts exactly one occurrence, in that "never" phrase.
6. The spec's prose test says the `--no-merge` skip "comes before the Shipping block". The Shipping block runs in both modes (spec §3a), so the test asserts Shipping block → `--no-merge` bullet → kicker command.

**Codex handoff:** not eligible (Outcome 3). The tasks are security-gate code whose verifiers are partly judgment (prose contracts, template wording), so implementation stays in this session.

---

## File Structure

| File | Change | Responsibility |
|---|---|---|
| `scripts/needs-shipping.py` | Modify (full rewrite shown) | Read-only classifier: opt-in from `base_tip`, agent-config paths, seven new exit-10 fields |
| `tests/test-needs-shipping.sh` | Modify | Classifier cases against a stub `gh`; prose-wiring assertions for `completion.md` and `SKILL.md` |
| `scripts/shipping-kick.py` | Create | The only writer: gates, comment body, one post, one status line |
| `tests/test-shipping-kick.sh` | Create | Kicker cases per exit code (stub `gh` + stub classifier), body content, structural-check selftest on a scratch repo |
| `skills/pr-grind/references/completion.md` | Modify | Exit-10 grammar, kicker call, follow-up table, Ready line |
| `skills/pr-grind/SKILL.md` | Modify | Lines 19, 83, 863-865, 1749 |
| `skills/finishing-a-development-branch/SKILL.md` | Modify | Last sentence of line 123 |
| `scripts/hooks/post-bash-pr-created.js` | Modify | Lines 75-76 |
| `.gate-integrity.lock` | Regenerate | Pin the edited hook |
| `docs/adr/0055-pr-grind-shipping-kick.md` | Modify | Four residual notes from the spec review |

New tests are picked up by CI automatically: `scripts/ci/run-shell-tests.sh` shards the live `tests/test-*.sh` glob, and a test absent from `scripts/ci/shell-test-durations.tsv` gets a default weight.

---

### Task 1: Classifier — agent-config paths and the skip list

**Files:**
- Modify: `scripts/needs-shipping.py:27-47` (constants, `skippable`, `needs_shipping`) and `:174-185` (`selftest`)
- Test: `scripts/needs-shipping.py --selftest`, `tests/test-needs-shipping.sh:129-130`

**Interfaces:**
- Produces: `agent_config(path: str) -> bool`, `files_incomplete(records: int) -> bool`, constants `AGENT_DIRS`, `AGENT_FILES`. Task 2 uses all of them.

- [x] **Step 1: Replace lines 27-47 with the agent-config rule**

```python
FILES_CAP = 3000  # GitHub's pulls/<n>/files limit, in file RECORDS; at the cap the list may be truncated
AGENT_DIRS = (".cursor", ".claude", ".codex", ".agents")
AGENT_FILES = ("agents.md", "claude.md", ".cursorrules", ".cursorignore", ".cursorindexingignore")


def agent_config(path):
    """True for a path Cursor or Claude Code may load as agent configuration (ADR 0055):
    any `.cursor`/`.claude`/`.codex`/`.agents` component, or one of AGENT_FILES as the
    basename, at any depth. Case-insensitive, so a case variant errs toward refusing."""
    parts = path.lower().split("/")
    return any(p in AGENT_DIRS for p in parts) or parts[-1] in AGENT_FILES


def skippable(path):
    """True only for paths that cannot change what users get (ADR 0054 D2). An
    agent-config path is never skippable (ADR 0055): every later kicked agent reads it."""
    if agent_config(path):
        return False
    return (
        path.startswith("docs/")
        or ("/" not in path and path.endswith(".md"))
        or path.startswith(("__tests__/", "tests/"))
        or path.endswith((".test.ts", ".test.tsx"))
        or path == ".github/lighthouse.baseline.json"
    )


def files_incomplete(records):
    """The listing may be incomplete: none returned, or GitHub's cap reached."""
    return records == 0 or records >= FILES_CAP


def needs_shipping(paths, records):
    """`records` is the number of file records GitHub returned (a rename is one
    record but two paths), so the cap is compared against records, not paths."""
    if files_incomplete(records):
        return True
    return not all(skippable(p) for p in paths)
```

The `.claude/**/*.md` skip rule is removed, as the spec requires.

- [x] **Step 2: Replace `selftest()` (lines 174-185)**

```python
def selftest():
    for routed in (["src/app/page.tsx"], ["docs/a.md", "src/x.ts"], ["docs/a.ts", "src/a.ts"], [],
                   ["foo/README.md"], [".claude/settings.json"], [".cursor/skills/verify-x/SKILL.md"],
                   ["src/app/a.test.ts\ndocs/x"], [".github/lighthouse.baseline.json.bak"], ["docs"],
                   ["x/docs/a.md"], [".claude/CLAUDE.md"], ["AGENTS.md"], ["CLAUDE.md"], ["docs/AGENTS.md"],
                   ["docs/.agents/skills/x/SKILL.md"], ["tests/.cursorrules"], ["tests/.cursor/rules/x.mdc"],
                   [".claude/agents/verifier.md"]):
        assert needs_shipping(routed, len(routed)), routed
    assert needs_shipping(["docs/a.md"] * FILES_CAP, FILES_CAP)
    assert not needs_shipping(["docs/a.md", "docs/b.md"] * 1500, 1500)  # 1500 renames = 1500 records
    for skipped in (["docs/a/b.md", "README.md"], ["client/x.test.tsx"], ["docs/claude/skills.md"],
                    [".github/lighthouse.baseline.json"], ["tests/e2e/a.spec.ts", "__tests__/b.js"]):
        assert not needs_shipping(skipped, len(skipped)), skipped
    for p in (".cursor/skills/x/SKILL.md", "apps/web/.cursor/skills/x/SKILL.md", ".claude/settings.json",
              ".codex/agents/x.md", ".agents/skills/x/SKILL.md", "AGENTS.md", "docs/CLAUDE.md",
              ".cursorignore", "web/.cursorindexingignore", ".Claude/x.md"):
        assert agent_config(p), p
    for p in ("src/skills/x.ts", "docs/claude/skills.md", "src/my.claude.ts", ".gitignore", "src/claude.md.bak"):
        assert not agent_config(p), p
    assert skills_field(["verify-a", "verify-b"]) == "verify-a,verify-b"
    assert skills_field(["verify-a", "verify-a$b"]) == "-"
    print("needs_shipping_selftest_ok")
```

`skills_field` arrives in Task 2; run the selftest after Task 2's Step 1 if you implement in strict order.

- [x] **Step 3: Commit after Task 2** (Tasks 1 and 2 touch the same file and its test; one commit, see Task 2 Step 6).

---

### Task 2: Classifier — `base_tip`, new fields, exit-10 line

**Files:**
- Modify: `scripts/needs-shipping.py` (docstring lines 1-20, `pr_view`, `subtree_sha`, `opted_in` → `verify_skills`, `classify`)
- Modify: `tests/test-needs-shipping.sh:25-163` (stub, helpers, existing cases, new cases)

**Interfaces:**
- Consumes: `agent_config`, `files_incomplete` from Task 1.
- Produces (Task 3 parses this exact line, fields in this order):
  `shipping mergeStateStatus=<S> base_ref=<name> base_tip=<40-hex> skills=<a,b|-> agent_config_edited=<0|1> files_incomplete=<0|1> author=<login|-> cross_repo=<0|1>`
  plus `skills_field(names: list[str]) -> str`, `verify_skills(repo, tip) -> list[str]`, `base_tip(repo, ref) -> str`.

- [x] **Step 1: Code changes in `scripts/needs-shipping.py`**

Replace the module docstring (lines 1-20):

```python
#!/usr/bin/env python3
"""needs-shipping.py — decide whether a clean pr-grind stops at Ready for Shipping.

ADR 0054, amended by ADR 0055. A repo opts in by carrying a `.cursor/skills/verify-*/`
directory in the tree of its base branch's LIVE tip (`base_tip`, read from GitHub; never
the PR head, the checkout, or the cached `baseRefOid`, which does not track the base).
In an opted-in repo, a PR whose changed paths are not all on the built-in skip list
must be landed by Cursor Cloud Shipping, so pr-grind must not merge it. Agent-config
paths (`.cursor`, `.claude`, `.codex`, `.agents`, AGENTS.md, CLAUDE.md, ...) are never
skippable.

Usage:
    /usr/bin/python3 -I needs-shipping.py <owner>/<repo> <PR_NUMBER> <REVIEWED_HEAD>
    needs-shipping.py --selftest

stdout / exit:
    merge                                    0   continue to the clean marker + merge path
    shipping mergeStateStatus=<STATE> base_ref=<name> base_tip=<40-hex> skills=<a,b|->
      agent_config_edited=<0|1> files_incomplete=<0|1> author=<login|-> cross_repo=<0|1>
                                             10  Ready for Shipping (one line): no marker, no merge
    error: <reason>                          1   the dispatcher BAILs env and never merges

Fails closed: any API error, unparseable response, invalid field, or a head/base that
moves while classifying exits 1. Kept Python 3.9-compatible (macOS /usr/bin/python3).
"""
```

Add after the `AGENT_FILES` constant:

```python
# `@` only after a word char: after `/`, `.` or `-` GitHub would autolink it as a mention in the posted comment
BASE_REF_RE = r"[A-Za-z0-9_](?:[A-Za-z0-9._/+=-]|(?<=[A-Za-z0-9_])@)*"
SKILL_RE = r"verify-[A-Za-z0-9][A-Za-z0-9._-]*"
LOGIN_RE = r"[A-Za-z0-9][A-Za-z0-9/_.\[\]-]*"
```

Replace `pr_view` (lines 77-84):

```python
def pr_view(repo, pr):
    d = gh_json(["pr", "view", pr, "-R", repo, "--json",
                 "headRefOid,baseRefName,mergeStateStatus,author,isCrossRepository"])
    if not (isinstance(d, dict) and nonempty_str(d.get("headRefOid"))):
        raise Fail("gh pr view returned no head OID")
    ref = d.get("baseRefName")
    if not (isinstance(ref, str) and re.fullmatch(BASE_REF_RE, ref) and ".." not in ref):
        raise Fail("invalid base branch name")
    if not isinstance(d.get("isCrossRepository"), bool):
        raise Fail("gh pr view returned no isCrossRepository boolean")
    state = d.get("mergeStateStatus")
    d["mergeStateStatus"] = state if isinstance(state, str) and re.fullmatch(r"[A-Z_]+", state) else "UNKNOWN"
    author = d.get("author")
    login = author.get("login") if isinstance(author, dict) else None
    d["author"] = login if isinstance(login, str) and re.fullmatch(LOGIN_RE, login) else "-"
    return d


def base_tip(repo, ref):
    """The live tip of branch `ref` (never a same-named tag). Slashes stay literal: this
    is a ref path, unlike the percent-encoded protection read in shipping-kick.py."""
    body = gh_json(["api", "repos/%s/git/ref/heads/%s" % (repo, ref)])
    obj = body.get("object") if isinstance(body, dict) else None
    ok = (isinstance(obj, dict) and body.get("ref") == "refs/heads/" + ref and obj.get("type") == "commit"
          and isinstance(obj.get("sha"), str) and re.fullmatch(r"[0-9a-f]{40}", obj["sha"]))
    if not ok:
        raise Fail("unexpected ref response for %s" % ref)
    return obj["sha"]
```

Replace `subtree_sha`, `name_matches` and `opted_in` (lines 87-122; `tree_entries` and `well_formed_entry` stay):

```python
def subtree_sha(repo, sha, name):
    """Look up directory `name` among the tree entries of `sha`. Absence is decided from
    a SUCCESSFUL listing, never from a 404."""
    for e in tree_entries(repo, sha):
        if e["type"] == "tree" and e["path"] == name:
            if not nonempty_str(e.get("sha")):
                raise Fail("tree entry %s without a sha" % e["path"])
            return e["sha"]
    return None
```

(`tree_entries` and `well_formed_entry` stay unchanged between these two functions.)

```python
def verify_skills(repo, tip):
    """Sorted `verify-*` directory names directly under `tip`'s `.cursor/skills/`; an
    empty list means the repo has not opted in."""
    cursor = subtree_sha(repo, tip, ".cursor")
    skills = cursor and subtree_sha(repo, cursor, "skills")
    if not skills:
        return []
    return sorted(e["path"] for e in tree_entries(repo, skills)
                  if e["type"] == "tree" and e["path"].startswith("verify-") and len(e["path"]) > len("verify-"))


def skills_field(names):
    """Comma-joined names, or `-` when any name is unusable (opts in, blocks the kick)."""
    return ",".join(names) if all(re.fullmatch(SKILL_RE, n) for n in names) else "-"
```

Replace `classify` (lines 160-171):

```python
def classify(repo, pr, head):
    first = pr_view(repo, pr)
    if first["headRefOid"] != head:
        raise Fail("head moved after classification; re-run /pr-grind")
    ref = first["baseRefName"]
    tip = base_tip(repo, ref)
    names = verify_skills(repo, tip)
    paths, records = changed_paths(repo, pr) if names else ([], 0)
    shipping = bool(names) and needs_shipping(paths, records)
    last = pr_view(repo, pr)
    if last["headRefOid"] != head or last["baseRefName"] != ref or base_tip(repo, ref) != tip:
        raise Fail("head or base moved while classifying; re-run /pr-grind")
    if not shipping:
        return "merge", 0
    fields = (("base_ref", ref), ("base_tip", tip), ("skills", skills_field(names)),
              ("agent_config_edited", int(any(agent_config(p) for p in paths))),
              ("files_incomplete", int(files_incomplete(records))),
              ("author", last["author"]), ("cross_repo", int(last["isCrossRepository"])))
    return "shipping mergeStateStatus=%s %s" % (
        last["mergeStateStatus"], " ".join("%s=%s" % f for f in fields)), 10
```

`baseRefOid` is no longer requested or read anywhere.

- [x] **Step 2: Stub `gh` and helpers in `tests/test-needs-shipping.sh`**

In the stub heredoc (lines 34-54), add this case as the FIRST arm of `case "$*" in` (before `"api repos/o/r/git/trees/"*`):

```bash
  "api repos/o/r/git/ref/heads/"*)
    echo "${2#repos/o/r/git/ref/heads/}" >> "$FIX/ref_names"
    n=$(grep -c '^api repos/o/r/git/ref/heads/' "$FIX/calls")
    if [ "$n" -gt 1 ] && [ -f "$FIX/ref2" ]; then cat "$FIX/ref2"; else cat "$FIX/ref1"; fi
    exit "$(cat "$FIX/ref.rc" 2>/dev/null || echo 0)" ;;
```

Add to the fixture comment (lines 29-33): `#   ref1, ref2[.rc]  successive git/ref/heads/<b> bodies (ref2 optional) [and exit code]; names logged to ref_names`.

Replace the `view()` helper (line 57) and add `ref()` and `ship()`:

```bash
DEF_AUTHOR='{"login":"op-user"}'
# view <head> [mergeStateStatus-json]; BREF, AUTHOR (JSON) and XREPO (JSON) override the rest.
view() { printf '{"baseRefName":"%s","headRefOid":"%s","mergeStateStatus":%s,"author":%s,"isCrossRepository":%s}\n' \
  "${BREF:-main}" "$1" "${2:-\"CLEAN\"}" "${AUTHOR:-$DEF_AUTHOR}" "${XREPO:-false}"; }
# ref <sha>: a git/ref/heads/<BREF> body.
ref() { printf '{"ref":"refs/heads/%s","node_id":"x","url":"https://api.github.com/x","object":{"sha":"%s","type":"commit","url":"https://api.github.com/x"}}\n' "${BREF:-main}" "$1"; }
# ship [status] [skills] [agent_config_edited] [files_incomplete] [author] [cross_repo] [base_ref] [base_tip]
ship() { printf 'shipping mergeStateStatus=%s base_ref=%s base_tip=%s skills=%s agent_config_edited=%s files_incomplete=%s author=%s cross_repo=%s' \
  "${1:-CLEAN}" "${7:-main}" "${8:-$BASE}" "${2:-verify-site}" "${3:-0}" "${4:-0}" "${5:-op-user}" "${6:-0}"; }
# review <head>: rewrite both views with the current BREF/AUTHOR/XREPO.
review() { view "$1" > "$FIX/view1"; cp "$FIX/view1" "$FIX/view2"; }
```

Replace `new_case()` (lines 66-70); `BASE` is now the base TIP, so every existing `tree-$BASE` fixture is the tip's tree:

```bash
# new_case: fresh fixture dir, both views at HEAD, base tip = BASE, BASE's tree WITHOUT .cursor.
new_case() {
  FIX="$TMP/case$((PASS + FAIL))"; mkdir -p "$FIX"; export FIX; : > "$FIX/calls"
  view "$HEAD" > "$FIX/view1"; cp "$FIX/view1" "$FIX/view2"
  ref "$BASE" > "$FIX/ref1"
  tree "$(entry $BLOB README.md aaa blob)" "$(entry $DIR src bbb tree)" > "$FIX/tree-$BASE"
}
```

- [x] **Step 3: Update the existing cases**

Exact edits (old → new):

| Line | Old | New |
|---|---|---|
| 117 | `new_case; view "$BASE" "$OTHER" > "$FIX/view2"` | `new_case; view "$OTHER" > "$FIX/view2"` |
| 124 | `... 10 "shipping mergeStateStatus=CLEAN"` | `... 10 "$(ship)"` |
| 127 | `... 10 "shipping mergeStateStatus=CLEAN"` | `... 10 "$(ship)"` (the rename `src/a.ts → docs/a.ts` is not agent config) |
| 129-130 | label `opted in, PR deletes the verify skill → shipping`, `"shipping mergeStateStatus=CLEAN"` | same label plus `, agent config`, `"$(ship CLEAN verify-site 1)"` |
| 136 | `... 10 "shipping mergeStateStatus=CLEAN"` | `... 10 "$(ship CLEAN verify-site 0 1)"` |
| 142 | `... 10 "shipping mergeStateStatus=CLEAN"` | `... 10 "$(ship)"` |
| 150-151 | `view "$BASE" "$HEAD" null > "$FIX/view2"` / `"shipping mergeStateStatus=UNKNOWN"` | `view "$HEAD" null > "$FIX/view2"` / `"$(ship UNKNOWN)"` |
| 153-154 | `view "$OTHER" "$HEAD" > "$FIX/view2"`, label `base moved while classifying` | `ref "$OTHER" > "$FIX/ref2"`, label `opted in, base tip moved while classifying → error` |
| 156 | `new_case; view "$BASE" "$OTHER" > "$FIX/view1"` | `new_case; view "$OTHER" > "$FIX/view1"` |
- [x] **Step 4: Add the new classifier cases** (insert after line 157, before the bad-arguments check)

```bash
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

for p in AGENTS.md CLAUDE.md docs/AGENTS.md .claude/AGENTS.md .claude/CLAUDE.md .claude/skills/x/SKILL.md \
         tests/.cursorrules .cursor/rules/x.mdc .agents/skills/x/SKILL.md .codex/skills/x/SKILL.md \
         .claude/agents/verifier.md .codex/agents/x.md .claude/settings.json .cursorignore \
         web/.cursorindexingignore apps/web/.cursor/skills/x/SKILL.md docs/.agents/skills/x/SKILL.md; do
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
new_case; opt_in "$(entry $DIR verify-a 1 tree)" "$(entry $DIR 'verify-a$b' 2 tree)"; files "$(plain src/x.ts)"
run_case "one invalid skill name → skills=-" 10 "$(ship CLEAN -)"
```

- [x] **Step 5: Run the classifier tests**

Run: `/usr/bin/python3 -I scripts/needs-shipping.py --selftest && bash tests/test-needs-shipping.sh`
Expected: `needs_shipping_selftest_ok`, then the classifier section all PASS. The prose section's line-238 loop still expects the old Ready-line literals and passes until Task 4 edits `completion.md`; Task 4 updates both together.

- [x] **Step 6: Commit (Tasks 1 + 2)**

```bash
git add scripts/needs-shipping.py tests/test-needs-shipping.sh
git commit -m "feat(pr-grind): classifier reads opt-in from base_tip and emits kick fields (#929)"
```

---

### Task 3: `scripts/shipping-kick.py` and its tests

**Files:**
- Create: `scripts/shipping-kick.py`
- Create: `tests/test-shipping-kick.sh`

**Interfaces:**
- Consumes: the classifier's exit-10 line from Task 2 (run as `/usr/bin/python3 -I <same dir>/needs-shipping.py <o/r> <N> <head>`).
- Produces: CLI `shipping-kick.py <owner/repo> <PR> <REVIEWED_HEAD>` with exactly one stdout line per outcome:

| Exit | Line |
|---|---|
| 0 | `kicked: <html_url> mergeStateStatus=<S>` |
| 1 | `error: <reason>` |
| 2 | `not kicked: mergeStateStatus=<S>` or `not kicked: protection precondition (<cond>)` |
| 3 | `not eligible: <tokens>` or `not eligible: agent-config mergeStateStatus=<S>` |
| 4 | `already kicked: <html_url>` |
| 5 | `not kicked: no usable verify skill name` |
| 6 | `stale or not shipping-routed (<why>): re-run /pr-grind` |
| 7 | `post failed: <reason>; re-run /pr-grind` |

Every non-zero line ends `; also: agent-config` when the classifier reported `agent_config_edited=1`, unless it is an exit 3 that already names `agent-config`. Task 4's follow-up table keys on these prefixes.

- [x] **Step 1: Create `scripts/shipping-kick.py`**

```python
#!/usr/bin/env python3
"""shipping-kick.py — post one Cursor cloud Shipping kick for a Ready-for-Shipping PR.

ADR 0055. pr-grind runs this after an exit-10 completion. It runs the classifier
(needs-shipping.py, same directory) itself, so every security input is computed here,
never taken from the dispatcher. Gates run in a fixed order: operator login, classifier,
dedupe, eligibility, live status, skills, branch protection, agent-config, head re-read.

Usage:
    /usr/bin/python3 -I shipping-kick.py <owner>/<repo> <PR_NUMBER> <REVIEWED_HEAD>

stdout is exactly ONE status line; the comment body is never printed (a printed body is
a ready-made kick the local session could post past any refusal).
    kicked: <url> mergeStateStatus=<S>                                      0
    error: <reason>                                                         1
    not kicked: mergeStateStatus=<S> | protection precondition (<cond>)     2
    not eligible: <tokens> | not eligible: agent-config mergeStateStatus=<S> 3
    already kicked: <url>                                                   4
    not kicked: no usable verify skill name                                 5
    stale or not shipping-routed (<why>): re-run /pr-grind                  6
    post failed: <reason>; re-run /pr-grind                                 7
When the PR edits agent config, every non-zero line not already naming it ends
"; also: agent-config". Kept Python 3.9-compatible (macOS /usr/bin/python3).
"""
import json
import os
import re
import subprocess
import sys
import time
import urllib.parse

HERE = os.path.dirname(os.path.abspath(__file__))
CLASSIFIER = os.path.join(HERE, "needs-shipping.py")
ACTIONS_APP_ID = 15368  # GitHub Actions: the only required-check source independent of the agent
KICKABLE = ("CLEAN", "UNSTABLE", "HAS_HOOKS", "BEHIND")
UNKNOWN_RETRIES, UNKNOWN_SLEEP = 3, 10
LOGIN_RE = r"[A-Za-z0-9][A-Za-z0-9/_.\[\]-]*"
# `@` only after a word char: after `/`, `.` or `-` GitHub would autolink it as a mention in the posted comment
BASE_REF_RE = r"[A-Za-z0-9_](?:[A-Za-z0-9._/+=-]|(?<=[A-Za-z0-9_])@)*"
SKILL_RE = r"verify-[A-Za-z0-9][A-Za-z0-9._-]*"
CLASSIFIER_LINE = re.compile(
    r"shipping mergeStateStatus=([A-Z_]+) base_ref=(\S+) base_tip=([0-9a-f]{40}) skills=(\S+)"
    r" agent_config_edited=([01]) files_incomplete=([01]) author=(\S+) cross_repo=([01])")
FIELDS = ("status", "base_ref", "base_tip", "skills", "agent_config", "files_incomplete", "author", "cross_repo")
ARG_PATTERNS = (r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", r"[0-9]+", r"[0-9a-f]{40}")
CONTROL = re.compile(r"[\x00-\x1f\x7f  ]")  # raw string: re reads the escapes, nothing invisible in source
MARKER = "<!-- busdriver-shipping-kick head=%s -->"

TEMPLATE = """@cursor Ship this PR with pstack Shipping (poteto-mode playbooks/shipping.md).
0. Setup. First read `gh pr view %(N)s -R %(repo)s --json headRefOid`; if the head is not %(SHA)s, post "head moved" and stop. Run every git step below on %(SHA)s explicitly, never on the checked-out branch. Require `git --version` to report 2.38 or newer (`git merge-tree --write-tree` needs it). Run `git fetch --no-tags origin +refs/heads/%(base_ref)s:refs/remotes/origin/%(base_ref)s %(base_tip)s %(SHA)s`. If `git rev-parse --is-shallow-repository` prints true, run `git fetch --unshallow origin`. If any of this fails, post "SETUP FAIL: <what failed, git version>" and stop.
1. Verify with EVERY skill listed: %(skills)s. Load each from commit %(base_tip)s (list its files with `git ls-tree -r --name-only %(base_tip)s .cursor/skills/<skill>/`, then read each, starting with SKILL.md, with `git show %(base_tip)s:<path>`), never this PR's copy; if any cannot be loaded there, post FAIL. Let M be `git merge-base %(base_tip)s %(SHA)s`. Drive parent M vs head %(SHA)s. For each skill, post PASS, PASS+NOTES or FAIL with per-feature evidence, plus one line naming the skill, the commit it was loaded from, M and %(SHA)s. The overall verdict is PASS only if every skill returns PASS or PASS+NOTES.
2. Only on an overall PASS. Before each of a, b and c, require `gh pr view %(N)s -R %(repo)s --json baseRefName,state` to show baseRefName %(base_ref)s and state OPEN; otherwise post the change and stop.
   a. Read `gh pr view %(N)s -R %(repo)s --json headRefOid`. If the head is not %(SHA)s, post "head moved" and stop. Run `git fetch --no-tags origin +refs/heads/%(base_ref)s:refs/remotes/origin/%(base_ref)s`. If origin/%(base_ref)s is an ancestor of %(SHA)s (`git merge-base --is-ancestor origin/%(base_ref)s %(SHA)s`), H is %(SHA)s; go to b. Otherwise run `gh api -X PUT repos/%(repo)s/pulls/%(N)s/update-branch -f expected_head_sha=%(SHA)s` (never `gh pr update-branch`, never --rebase, never git push). If it exits non-zero, post its output (a conflict means "FAIL: base conflicts, needs a manual merge") and stop. GitHub creates the update commit asynchronously, so poll `gh pr view %(N)s -R %(repo)s --json headRefOid` every 10s for up to 5 minutes until it differs from %(SHA)s; on timeout, post that and stop. Read the new head H (below, H means that 40-hex SHA, not a ref name), run `git fetch --no-tags origin +refs/heads/%(base_ref)s:refs/remotes/origin/%(base_ref)s H`, and require all of:
      - `git rev-parse H^1` equals %(SHA)s;
      - `git merge-base --is-ancestor H^2 origin/%(base_ref)s` succeeds (a stale H^2 is caught by strict protection at merge time);
      - `git rev-list --parents -n 1 H` prints H followed by exactly two parent SHAs;
      - `git rev-parse H^{tree}` equals `git merge-tree --write-tree %(SHA)s H^2` (the clean merge, nothing else).
      If any check fails, post which one and stop.
   b. The required checks are: %(checks)s. Every 60s for up to 45 minutes (you may poll across several tool calls), run `gh pr checks %(N)s -R %(repo)s --required --json name,bucket` and decide from the listed buckets, not the exit code; read `gh pr view %(N)s -R %(repo)s --json headRefOid` on each poll for the head. First, a `fail` or `cancel` bucket on a required check, or a head other than H, means stop with the blocker. An error saying "no checks reported" or "no required checks reported" (a new head whose checks have not started), a required check missing from the list, or a `pending` bucket means wait and poll again. Continue only when every required check above is listed with bucket `pass` or `skipping` and the head is still H. On timeout, stop with the blocker.
   c. Run exactly: gh pr merge %(N)s -R %(repo)s --squash --delete-branch --match-head-commit H
3. Post the verdict, the kicked head %(SHA)s, H, and the merge commit SHA or what blocked it. Never push commits, rebase, or edit files on this branch. Never repeat the marker line below, and never write `@cursor`, in anything you post.
"""


class Fail(Exception):
    """An API or parse failure: exit 1."""


class Exit(Exception):
    def __init__(self, code, line):
        Exception.__init__(self, line)
        self.code, self.line = code, line


def one_line(s, cap):
    """One line, control characters removed, at most `cap` characters."""
    return re.sub(r"\s+", " ", CONTROL.sub(" ", s)).strip()[:cap]


def stale(why):
    return "stale or not shipping-routed (%s): re-run /pr-grind" % why


def run_gh(args, stdin=None):
    """`gh` with needs-shipping.py's pinning: GH_HOST fixed, GH_REPO removed."""
    env = dict(os.environ, GH_HOST="github.com")
    env.pop("GH_REPO", None)
    try:
        return subprocess.run(["gh"] + args, input=stdin, capture_output=True, text=True, env=env)
    except OSError as e:
        raise Fail("gh not runnable: %s" % e)


def gh(args, stdin=None):
    r = run_gh(args, stdin)
    if r.returncode != 0:
        raise Fail("gh %s failed (rc=%d): %s" % (" ".join(args[:2]), r.returncode, one_line(r.stderr, 200)))
    return r.stdout


def gh_json(args, stdin=None):
    try:
        return json.loads(gh(args, stdin))
    except ValueError:
        raise Fail("gh %s returned unparseable JSON" % " ".join(args[:2]))


def gh_status(args):
    """(HTTP status, body) from `gh api -i ...`, so a 404 is told apart from other failures."""
    r = run_gh(args)
    parts = re.split(r"\r?\n\r?\n", r.stdout, maxsplit=1)
    m = re.match(r"HTTP/\S+ ([0-9]{3})", parts[0])
    if not m or len(parts) != 2:
        raise Fail("gh %s gave no HTTP status (rc=%d): %s" % (" ".join(args[:3]), r.returncode, one_line(r.stderr, 200)))
    status = int(m.group(1))
    if (status == 200) != (r.returncode == 0):
        raise Fail("gh %s: HTTP %d with rc=%d" % (" ".join(args[:3]), status, r.returncode))
    return status, parts[1]


def operator_login():
    d = gh_json(["api", "user"])
    login = d.get("login") if isinstance(d, dict) else None
    if not (isinstance(login, str) and re.fullmatch(LOGIN_RE, login)):
        raise Fail("gh api user returned no usable login")
    return login


def classify(repo, pr, head):
    """Run the classifier; return its exit-10 fields, re-validated here."""
    try:
        r = subprocess.run(["/usr/bin/python3", "-I", CLASSIFIER, repo, pr, head], capture_output=True, text=True)
    except OSError as e:
        raise Exit(6, stale("classifier not runnable: %s" % e))
    out = r.stdout.strip()
    m = CLASSIFIER_LINE.fullmatch(out) if r.returncode == 10 else None
    if not m:
        why = "classifier exit %d" % r.returncode
        if out.startswith("error: "):
            why += ": " + one_line(out[len("error: "):], 200)
        raise Exit(6, stale(why))
    f = dict(zip(FIELDS, m.groups()))
    valid = (re.fullmatch(BASE_REF_RE, f["base_ref"]) and ".." not in f["base_ref"]
             and (f["skills"] == "-" or all(re.fullmatch(SKILL_RE, s) for s in f["skills"].split(",")))
             and (f["author"] == "-" or re.fullmatch(LOGIN_RE, f["author"])))
    if not valid:
        raise Exit(6, stale("classifier line failed validation"))
    return f


def find_marker(repo, pr, head, login):
    """html_url of an operator comment carrying this head's marker, or None."""
    marker = MARKER % head
    out = gh(["api", "--paginate", "--jq", ".[]", "repos/%s/issues/%s/comments" % (repo, pr)])
    for line in out.split("\n"):  # "\n" only: a U+2028 inside a comment must not split it
        if not line.strip():
            continue
        try:
            c = json.loads(line)
        except ValueError:
            raise Fail("unparseable comment line")
        if not (isinstance(c, dict) and isinstance(c.get("body"), str) and isinstance(c.get("html_url"), str)):
            raise Fail("malformed comment record")
        user = c.get("user")
        who = user.get("login") if isinstance(user, dict) else None
        if isinstance(who, str) and who.lower() == login.lower() and marker in c["body"]:
            return c["html_url"]
    return None


def reasons(f, login):
    """Eligibility tokens, in the spec's fixed order."""
    tokens = []
    if f["cross_repo"] == "1":
        tokens.append("cross-repo")
    if f["author"] == "-" or f["author"].lower() != login.lower():
        tokens.append("author")
    if f["files_incomplete"] == "1":
        tokens.append("files-incomplete")
    if f["agent_config"] == "1":
        tokens.append("agent-config")
    return tokens


def live_status(repo, pr):
    """Live mergeStateStatus; UNKNOWN is re-read up to UNKNOWN_RETRIES times."""
    for attempt in range(UNKNOWN_RETRIES + 1):
        if attempt:
            time.sleep(UNKNOWN_SLEEP)
        d = gh_json(["pr", "view", pr, "-R", repo, "--json", "mergeStateStatus"])
        s = d.get("mergeStateStatus") if isinstance(d, dict) else None
        s = s if isinstance(s, str) and re.fullmatch(r"[A-Z_]+", s) else "UNKNOWN"
        if s != "UNKNOWN":
            break
    return s


def refuse(cond):
    raise Exit(2, "not kicked: protection precondition (%s)" % cond)


def required_checks(repo, base_ref):
    """Validated required-check names; Exit 2 names the first failing condition."""
    meta = gh_json(["api", "repos/%s" % repo])
    if not (isinstance(meta, dict) and meta.get("private") is True):
        refuse("repository is not private")
    path = "repos/%s/branches/%s/protection" % (repo, urllib.parse.quote(base_ref, safe=""))
    status, body = gh_status(["api", "-i", path])
    if status == 404:
        refuse("404: base branch not protected")
    if status != 200:
        raise Fail("protection read returned HTTP %d" % status)
    try:
        p = json.loads(body)
    except ValueError:
        raise Fail("unparseable protection response")
    if not isinstance(p, dict):
        raise Fail("unexpected protection response")
    ea = p.get("enforce_admins")
    if not (isinstance(ea, dict) and ea.get("enabled") is True):
        refuse("enforce_admins not enabled")
    rsc = p.get("required_status_checks")
    if not isinstance(rsc, dict):
        refuse("required_status_checks absent")
    if rsc.get("strict") is not True:
        refuse("strict not enabled")
    checks = rsc.get("checks")
    if not (isinstance(checks, list) and checks):
        refuse("no required checks")
    names = []
    for c in checks:
        app = c.get("app_id") if isinstance(c, dict) else None
        if type(app) is not int or app != ACTIONS_APP_ID:
            refuse("a required check is not pinned to GitHub Actions")
        name = c.get("context")
        usable = (isinstance(name, str) and 0 < len(name) <= 100
                  and not re.search(r"[,`<>]", name) and not CONTROL.search(name))
        if not usable:
            refuse("a required check name is unusable")
        names.append(name)
    return names


def comment_body(repo, pr, head, f, checks):
    """Built only from validated fields; contains no PR-authored text."""
    values = {"N": pr, "repo": repo, "base_ref": f["base_ref"], "base_tip": f["base_tip"], "SHA": head,
              "skills": ", ".join("/" + s for s in f["skills"].split(",")), "checks": ", ".join(checks)}
    return TEMPLATE % values + MARKER % head + "\n"


def post(repo, pr, head, login, body):
    """Post once (body on stdin, no tmpfile); on failure, re-run dedupe to learn the outcome."""
    try:
        d = gh_json(["api", "-X", "POST", "repos/%s/issues/%s/comments" % (repo, pr), "-F", "body=@-"], stdin=body)
        url = d.get("html_url") if isinstance(d, dict) else None
        if isinstance(url, str):
            return url
        reason = "post response has no html_url"
    except Fail as e:
        reason = str(e)
    try:
        url = find_marker(repo, pr, head, login)
    except Fail:
        raise Exit(1, "error: delivery unknown; check PR #%s before posting anything" % pr)
    if url:
        raise Exit(4, "already kicked: %s" % url)
    raise Exit(7, "post failed: %s; re-run /pr-grind" % one_line(reason, 200))


def kick(repo, pr, head, ctx):
    login = operator_login()                                              # 1
    f = classify(repo, pr, head)                                          # 2
    ctx["agent_config"] = f["agent_config"] == "1"
    url = find_marker(repo, pr, head, login)                              # 3
    if url:
        raise Exit(4, "already kicked: %s" % url)
    tokens = reasons(f, login)                                            # 4
    if [t for t in tokens if t != "agent-config"]:
        raise Exit(3, "not eligible: %s" % ",".join(tokens))
    status = live_status(repo, pr)                                        # 5
    if status not in KICKABLE:
        raise Exit(2, "not kicked: mergeStateStatus=%s" % status)
    if f["skills"] == "-":                                                # 6
        raise Exit(5, "not kicked: no usable verify skill name")
    checks = required_checks(repo, f["base_ref"])                         # 7
    if tokens:                                                            # 8: only agent-config is left
        raise Exit(3, "not eligible: agent-config mergeStateStatus=%s" % status)
    now = gh_json(["pr", "view", pr, "-R", repo, "--json", "headRefOid"])  # 9
    if not (isinstance(now, dict) and now.get("headRefOid") == head):
        raise Exit(6, stale("head moved before the post"))
    url = post(repo, pr, head, login, comment_body(repo, pr, head, f, checks))  # 10 inside post
    raise Exit(0, "kicked: %s mergeStateStatus=%s" % (url, status))


def main(argv):
    if not (len(argv) == len(ARG_PATTERNS) and all(re.fullmatch(p, a) for p, a in zip(ARG_PATTERNS, argv))):
        print("error: usage: shipping-kick.py <owner>/<repo> <PR_NUMBER> <40-hex REVIEWED_HEAD>")
        return 1
    ctx = {}
    try:
        kick(argv[0], argv[1], argv[2], ctx)
        code, line = 1, "error: kicker ended without an outcome"
    except Exit as e:
        code, line = e.code, e.line
    except Exception as e:  # fail closed on anything, including bugs
        code, line = 1, "error: %s" % e
    if code and ctx.get("agent_config") and not (code == 3 and "agent-config" in line):
        line += "; also: agent-config"
    print(one_line(line, 600))
    return code


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
```

- [x] **Step 2: Create `tests/test-shipping-kick.sh`**

```bash
#!/usr/bin/env bash
# Tests for scripts/shipping-kick.py (ADR 0055).
#
# The kicker is copied into $TMP/scripts next to a STUB needs-shipping.py that prints the
# classifier line from $FIX/cls and exits with $FIX/cls.rc, so each gate is driven
# directly. A stub `gh` on PATH serves fixtures and logs every call. Part 3 runs the
# template's structural-check commands on a scratch git repo.
#
# Usage: bash tests/test-shipping-kick.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

PY=/usr/bin/python3
PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }
t() { local label=$1; shift; if "$@"; then pass "$label"; else fail "$label"; fi; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/scripts"
cp scripts/shipping-kick.py "$TMP/scripts/"
cat > "$TMP/scripts/needs-shipping.py" <<'CLS'
import os, sys
fix = os.environ["FIX"]
open(fix + "/cls_args", "w").write(" ".join(sys.argv[1:]))
sys.stdout.write(open(fix + "/cls").read())
sys.exit(int(open(fix + "/cls.rc").read()))
CLS

HEAD=3df45264627e7ff8bf8cacc05a025723929b62d3
TIP=0e1270c5c81c44f7a62f796d7efde58f7eb2d358
OTHER=1111111111111111111111111111111111111111
URL=https://github.com/o/r/pull/42#issuecomment-1

# Stub gh. Fixtures under $FIX: user, comments[2], status (one line per read), headnow,
# repo, prot (full `gh api -i` output), postresp; any <name>.rc sets that call's exit
# code; err is copied to stderr on every call.
cat > "$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$FIX/calls"
printf '%s|%s\n' "${GH_HOST:-}" "${GH_REPO:-}" > "$FIX/gh_env"
[ -f "$FIX/err" ] && cat "$FIX/err" >&2
rc_of() { cat "$FIX/$1.rc" 2>/dev/null || echo 0; }
case "$*" in
  "api user") cat "$FIX/user"; exit "$(rc_of user)" ;;
  "api --paginate --jq .[] repos/o/r/issues/42/comments")
    n=$(grep -c '^api --paginate' "$FIX/calls")
    if [ "$n" -gt 1 ] && [ -f "$FIX/comments2" ]; then cat "$FIX/comments2"; exit "$(rc_of comments2)"; fi
    cat "$FIX/comments"; exit "$(rc_of comments)" ;;
  "pr view 42 -R o/r --json mergeStateStatus")
    n=$(grep -c 'json mergeStateStatus$' "$FIX/calls")
    s=$(sed -n "${n}p" "$FIX/status"); [ -n "$s" ] || s=$(tail -1 "$FIX/status")
    printf '{"mergeStateStatus":"%s"}\n' "$s"; exit 0 ;;
  "pr view 42 -R o/r --json headRefOid") printf '{"headRefOid":"%s"}\n' "$(cat "$FIX/headnow")"; exit 0 ;;
  "api repos/o/r") cat "$FIX/repo"; exit 0 ;;
  "api -i repos/o/r/branches/"*"/protection") echo "$3" >> "$FIX/prot_paths"; cat "$FIX/prot"; exit "$(rc_of prot)" ;;
  "api -X POST repos/o/r/issues/42/comments -F body=@-") cat > "$FIX/posted"; cat "$FIX/postresp"; exit "$(rc_of post)" ;;
esac
echo "stub: unexpected gh $*" >&2
exit 99
STUB
chmod +x "$TMP/bin/gh"

P_OK='{"enforce_admins":{"enabled":true},"required_status_checks":{"strict":true,"checks":[{"context":"build","app_id":15368},{"context":"Code security","app_id":15368}]}}'
# prot <json-body> [status-line]: a `gh api -i` response.
prot() { printf '%s\nContent-Type: application/json; charset=utf-8\n\n%s' "${2:-HTTP/2.0 200 OK}" "$1" > "$FIX/prot"; }
# cls: the classifier line; C_STATUS C_REF C_SKILLS C_AC C_FI C_AUTH C_X override fields.
cls() { printf 'shipping mergeStateStatus=%s base_ref=%s base_tip=%s skills=%s agent_config_edited=%s files_incomplete=%s author=%s cross_repo=%s\n' \
  "${C_STATUS:-CLEAN}" "${C_REF:-main}" "$TIP" "${C_SKILLS:-verify-site}" "${C_AC:-0}" "${C_FI:-0}" "${C_AUTH:-op-user}" "${C_X:-0}" > "$FIX/cls"; }
marker() { printf '{"user":{"login":"%s"},"body":"done <!-- busdriver-shipping-kick head=%s --> x","html_url":"%s"}\n' "$1" "$2" "$3"; }

new_case() {
  FIX="$TMP/case$((PASS + FAIL))"; mkdir -p "$FIX"; export FIX; : > "$FIX/calls"
  echo '{"login":"op-user"}' > "$FIX/user"
  cls; echo 10 > "$FIX/cls.rc"
  : > "$FIX/comments"
  echo CLEAN > "$FIX/status"
  echo "$HEAD" > "$FIX/headnow"
  echo '{"private":true}' > "$FIX/repo"
  prot "$P_OK"
  printf '{"html_url":"%s"}\n' "$URL" > "$FIX/postresp"
}

# run_kick: always with a hostile ambient GH_HOST / GH_REPO.
run_kick() {
  out=$(PATH="$TMP/bin:$PATH" GH_HOST=evil.example GH_REPO=x/y "$PY" -I "$TMP/scripts/shipping-kick.py" o/r 42 "$HEAD" 2>/dev/null); rc=$?
}
posted() { grep -q '^api -X POST' "$FIX/calls"; }
single_line_no_body() {
  [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 1 ] || return 1
  case "$out" in *"Ship this PR"*|*"busdriver-shipping-kick"*|*"@cursor"*) return 1 ;; esac
}
# check <label> <rc> <exact line|prefix:...> <post attempted 0|1>
check() {
  local ok=1
  run_kick
  [ "$rc" = "$2" ] || ok=0
  case "$3" in prefix:*) [ "${out#"${3#prefix:}"}" != "$out" ] || ok=0 ;; *) [ "$out" = "$3" ] || ok=0 ;; esac
  if [ "$4" = 1 ]; then posted || ok=0; else ! posted || ok=0; fi
  single_line_no_body || ok=0
  [ "$(cat "$FIX/gh_env")" = "github.com|" ] || ok=0
  if [ "$ok" = 1 ]; then pass "$1"; else fail "$1 (rc=$rc out=$out, want rc=$2 out=$3 posted=$4)"; fi
}

echo "── exit 0 ───────────────────────────────────────────────────"
new_case
check "kicks once" 0 "kicked: $URL mergeStateStatus=CLEAN" 1
t "classifier gets repo, PR and head" [ "$(cat "$FIX/cls_args")" = "o/r 42 $HEAD" ]
t "exactly one POST" [ "$(grep -c '^api -X POST' "$FIX/calls")" = 1 ]
BODY="$TMP/body0"; cp "$FIX/posted" "$BODY"

new_case; marker someone "$HEAD" u1 > "$FIX/comments"
check "a non-operator marker is ignored" 0 "kicked: $URL mergeStateStatus=CLEAN" 1
new_case; echo BEHIND > "$FIX/status"
check "BEHIND kicks and reports BEHIND" 0 "kicked: $URL mergeStateStatus=BEHIND" 1
new_case; printf 'UNKNOWN\nCLEAN\n' > "$FIX/status"
check "UNKNOWN then CLEAN kicks" 0 "kicked: $URL mergeStateStatus=CLEAN" 1
new_case; echo '{"login":"Op-User"}' > "$FIX/user"
check "logins compare case-insensitively" 0 "kicked: $URL mergeStateStatus=CLEAN" 1

echo "── exit 4 ───────────────────────────────────────────────────"
new_case; marker op-user "$HEAD" "$URL-9" > "$FIX/comments"
check "operator marker → already kicked" 4 "already kicked: $URL-9" 0
new_case; { for i in $(seq 150); do printf '{"user":{"login":"bot%s"},"body":"hi","html_url":"u%s"}\n' "$i" "$i"; done; marker op-user "$HEAD" "$URL-9"; } > "$FIX/comments"
check "marker after 150 comments (second page)" 4 "already kicked: $URL-9" 0
new_case; marker op-user "$HEAD" "$URL-9" > "$FIX/comments"; C_X=1 cls; echo DIRTY > "$FIX/status"
check "dedupe beats eligibility and status" 4 "already kicked: $URL-9" 0
new_case; marker op-user "$HEAD" "$URL-9" > "$FIX/comments"; C_AC=1 cls
check "marker with agent-config" 4 "already kicked: $URL-9; also: agent-config" 0
new_case; echo 1 > "$FIX/post.rc"; echo '{"message":"boom"}' > "$FIX/postresp"; marker op-user "$HEAD" "$URL-9" > "$FIX/comments2"
check "post fails but the marker landed" 4 "already kicked: $URL-9" 1
new_case; marker op-user "$OTHER" "$URL-9" > "$FIX/comments"
check "a marker for another head does not dedupe" 0 "kicked: $URL mergeStateStatus=CLEAN" 1

echo "── exit 3 ───────────────────────────────────────────────────"
new_case; C_X=1 cls; check "cross-repo alone" 3 "not eligible: cross-repo" 0
new_case; C_AUTH=someone cls; check "author alone" 3 "not eligible: author" 0
new_case; C_AUTH=- cls; check "author - alone" 3 "not eligible: author" 0
new_case; C_FI=1 cls; check "files-incomplete alone" 3 "not eligible: files-incomplete" 0
new_case; C_X=1 C_AC=1 cls; check "cross-repo + agent-config" 3 "not eligible: cross-repo,agent-config" 0
new_case; C_AUTH=someone C_FI=1 C_AC=1 cls; check "author + files-incomplete + agent-config, in order" 3 "not eligible: author,files-incomplete,agent-config" 0
new_case; C_AC=1 cls; check "agent-config alone, every other gate passing" 3 "not eligible: agent-config mergeStateStatus=CLEAN" 0
t "agent-config alone is decided after the protection read" [ -s "$FIX/prot_paths" ]
new_case; C_AC=1 cls; echo BEHIND > "$FIX/status"
check "agent-config alone reports the live status, not the classifier's" 3 "not eligible: agent-config mergeStateStatus=BEHIND" 0

echo "── exit 2 ───────────────────────────────────────────────────"
for s in BLOCKED DIRTY DRAFT; do
  new_case; echo "$s" > "$FIX/status"; check "status $s" 2 "not kicked: mergeStateStatus=$s" 0
  new_case; echo "$s" > "$FIX/status"; C_AC=1 cls; check "status $s + agent-config" 2 "not kicked: mergeStateStatus=$s; also: agent-config" 0
done
new_case; echo UNKNOWN > "$FIX/status"
check "UNKNOWN after 3 re-reads" 2 "not kicked: mergeStateStatus=UNKNOWN" 0
t "UNKNOWN read 4 times" [ "$(grep -c 'json mergeStateStatus$' "$FIX/calls")" = 4 ]

PC="not kicked: protection precondition"
prot_case() { # prot_case <label> <expected condition> <setup command...>
  local label=$1 cond=$2; shift 2
  new_case; "$@"; check "$label" 2 "$PC ($cond)" 0
  new_case; "$@"; C_AC=1 cls; check "$label + agent-config" 2 "$PC ($cond); also: agent-config" 0
}
public() { echo '{"private":false}' > "$FIX/repo"; }
p404() { prot '{"message":"Branch not protected"}' 'HTTP/2.0 404 Not Found'; echo 1 > "$FIX/prot.rc"; }
pj() { prot "$1"; }
prot_case "public repository" "repository is not private" public
prot_case "protection 404" "404: base branch not protected" p404
prot_case "enforce_admins off" "enforce_admins not enabled" pj '{"enforce_admins":{"enabled":false},"required_status_checks":{"strict":true,"checks":[{"context":"build","app_id":15368}]}}'
prot_case "required_status_checks null" "required_status_checks absent" pj '{"enforce_admins":{"enabled":true},"required_status_checks":null}'
prot_case "strict off" "strict not enabled" pj '{"enforce_admins":{"enabled":true},"required_status_checks":{"strict":false,"checks":[{"context":"build","app_id":15368}]}}'
prot_case "empty checks" "no required checks" pj '{"enforce_admins":{"enabled":true},"required_status_checks":{"strict":true,"checks":[]}}'
prot_case "check with app_id null" "a required check is not pinned to GitHub Actions" pj '{"enforce_admins":{"enabled":true},"required_status_checks":{"strict":true,"checks":[{"context":"build","app_id":null}]}}'
prot_case "check pinned to another app" "a required check is not pinned to GitHub Actions" pj '{"enforce_admins":{"enabled":true},"required_status_checks":{"strict":true,"checks":[{"context":"build","app_id":1234}]}}'
prot_case "check name with a backtick" "a required check name is unusable" pj '{"enforce_admins":{"enabled":true},"required_status_checks":{"strict":true,"checks":[{"context":"bu`ild","app_id":15368}]}}'
prot_case "check name with a comma" "a required check name is unusable" pj '{"enforce_admins":{"enabled":true},"required_status_checks":{"strict":true,"checks":[{"context":"test (a, b)","app_id":15368}]}}'
new_case; C_REF=release/1.2 cls; run_kick
t "protection path percent-encodes the slash" grep -qx 'repos/o/r/branches/release%2F1.2/protection' "$FIX/prot_paths"

echo "── exit 5 ───────────────────────────────────────────────────"
new_case; C_SKILLS=- cls; check "skills=-" 5 "not kicked: no usable verify skill name" 0
new_case; C_SKILLS=- C_AC=1 cls; check "skills=- + agent-config" 5 "not kicked: no usable verify skill name; also: agent-config" 0

echo "── exit 6 ───────────────────────────────────────────────────"
new_case; printf 'error: gh api failed\nsecond line\n' > "$FIX/cls"; echo 1 > "$FIX/cls.rc"
check "classifier exit 1 carries its reason" 6 "stale or not shipping-routed (classifier exit 1: gh api failed second line): re-run /pr-grind" 0
new_case; echo merge > "$FIX/cls"; echo 0 > "$FIX/cls.rc"
check "classifier exit 0" 6 "stale or not shipping-routed (classifier exit 0): re-run /pr-grind" 0
new_case; C_REF='a/../b' cls
check "classifier line failing validation" 6 "stale or not shipping-routed (classifier line failed validation): re-run /pr-grind" 0
new_case; echo "$OTHER" > "$FIX/headnow"
check "head moved before the post" 6 "stale or not shipping-routed (head moved before the post): re-run /pr-grind" 0

echo "── exit 1 ───────────────────────────────────────────────────"
new_case; echo 1 > "$FIX/user.rc"; printf 'line one\nline two\n' > "$FIX/err"
check "gh api user fails (multi-line stderr stays one line)" 1 "prefix:error: " 0
new_case; echo 1 > "$FIX/comments.rc"; check "comment listing fails" 1 "prefix:error: " 0
new_case; echo 'not json' > "$FIX/comments"; check "unparseable comment listing" 1 "prefix:error: " 0
new_case; prot '{"message":"boom"}' 'HTTP/2.0 500 Internal Server Error'; echo 1 > "$FIX/prot.rc"
check "protection read fails (500)" 1 "prefix:error: " 0
new_case; echo 1 > "$FIX/post.rc"; : > "$FIX/postresp"; echo 1 > "$FIX/comments2.rc"; : > "$FIX/comments2"
check "post fails and the re-read fails" 1 "error: delivery unknown; check PR #42 before posting anything" 1
out=$("$PY" -I "$TMP/scripts/shipping-kick.py" o/r 42 abc 2>/dev/null); rc=$?
t "bad arguments → error, exit 1" [ "$rc" = 1 ]

echo "── exit 7 ───────────────────────────────────────────────────"
new_case; echo 1 > "$FIX/post.rc"; : > "$FIX/postresp"
check "post fails, marker not found" 7 "prefix:post failed: " 1
t "exit 7 line ends with the re-run instruction" [ "${out%; re-run /pr-grind}" != "$out" ]

echo "── comment body ─────────────────────────────────────────────"
b() { grep -qF -- "$1" "$BODY"; }
for frag in \
  "@cursor Ship this PR with pstack Shipping (poteto-mode playbooks/shipping.md)." \
  "First read \`gh pr view 42 -R o/r --json headRefOid\`; if the head is not $HEAD" \
  "Require \`git --version\` to report 2.38 or newer" \
  "git fetch --no-tags origin +refs/heads/main:refs/remotes/origin/main $TIP $HEAD" \
  "git fetch --unshallow origin" \
  "Verify with EVERY skill listed: /verify-site." \
  "git show $TIP:<path>" \
  "one line naming the skill, the commit it was loaded from, M and $HEAD" \
  "baseRefName main and state OPEN" \
  "git merge-base --is-ancestor origin/main $HEAD" \
  "gh api -X PUT repos/o/r/pulls/42/update-branch -f expected_head_sha=$HEAD" \
  "\`git rev-parse H^1\` equals $HEAD" \
  "\`git merge-base --is-ancestor H^2 origin/main\` succeeds" \
  "\`git rev-list --parents -n 1 H\` prints H followed by exactly two parent SHAs" \
  "\`git rev-parse H^{tree}\` equals \`git merge-tree --write-tree $HEAD H^2\`" \
  "The required checks are: build, Code security." \
  "decide from the listed buckets, not the exit code" \
  "\"no required checks reported\"" \
  "First, a \`fail\` or \`cancel\` bucket" \
  "a required check missing from the list, or a \`pending\` bucket means wait" \
  "gh pr merge 42 -R o/r --squash --delete-branch --match-head-commit H" \
  "the kicked head $HEAD, H," \
  "Never repeat the marker line below, and never write \`@cursor\`"; do
  t "body has: $frag" b "$frag"
done
t "body ends with the marker" [ "$(tail -1 "$BODY")" = "<!-- busdriver-shipping-kick head=$HEAD -->" ]
t "body has no patch-id" bash -c '! grep -q patch-id "$1"' _ "$BODY"
t "gh pr update-branch appears once, as 'never'" [ "$(grep -o 'gh pr update-branch' "$BODY" | wc -l | tr -d ' ')" = 1 ]
t "...and that occurrence is the 'never' phrase" b "never \`gh pr update-branch\`"
for ph in '<N>' '<owner/repo>' '<SHA>' '<base_tip>' '<base_ref>' '%('; do
  t "no unfilled placeholder $ph" bash -c '! grep -qF -- "$1" "$2"' _ "$ph" "$BODY"
done
new_case; C_SKILLS=verify-a,verify-b cls; run_kick
t "every skill is listed" grep -qF "Verify with EVERY skill listed: /verify-a, /verify-b." "$FIX/posted"

echo "── structural check (template commands, scratch repo) ───────"
G="$TMP/git"; git init -q "$G"
gx() { git -C "$G" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false "$@"; }
mk() { echo "$1" > "$G/$1"; gx add "$1"; gx commit -q -m "$1"; gx rev-parse HEAD; }
B0=$(mk a)
gx checkout -q -b side "$B0"; S=$(mk s)
gx checkout -q -b head "$B0"; SHA=$(mk h)
gx checkout -q -b mainline "$B0"; B1=$(mk b)
gx update-ref refs/remotes/origin/main "$B1"
merge_of() { gx checkout -q --detach "$1"; shift; gx merge -q --no-ff --no-edit "$@" >/dev/null; gx rev-parse HEAD; }
GOOD=$(merge_of "$SHA" "$B1")
EXTRA=$(gx checkout -q --detach "$GOOD"; echo x > "$G/extra"; gx add extra; gx commit -q --amend --no-edit; gx rev-parse HEAD)
BADP1=$(merge_of "$B1" "$SHA")
OCTO=$(merge_of "$SHA" "$B1" "$S")
NOTBASE=$(merge_of "$SHA" "$S")
# structural <H> <SHA>: the template's four checks, verbatim.
structural() {
  (cd "$G" && H=$1 && SHA=$2 &&
    [ "$(git rev-parse "$H^1")" = "$SHA" ] &&
    git merge-base --is-ancestor "$H^2" origin/main &&
    [ "$(git rev-list --parents -n 1 "$H" | wc -w | tr -d ' ')" = 3 ] &&
    [ "$(git rev-parse "$H^{tree}")" = "$(git merge-tree --write-tree "$SHA" "$H^2")" ])
}
nparents() { gx rev-list --parents -n 1 "$1" | awk '{print NF - 1}'; }
t "fixture GOOD has 2 parents" [ "$(nparents "$GOOD")" = 2 ]
t "fixture OCTO has 3 parents" [ "$(nparents "$OCTO")" = 3 ]
t "fixture EXTRA keeps GOOD's parents" [ "$(gx rev-parse "$EXTRA^@" | tr '\n' ' ')" = "$(gx rev-parse "$GOOD^@" | tr '\n' ' ')" ]
t "fixture BADP1 has first parent B1" [ "$(gx rev-parse "$BADP1^1")" = "$B1" ]
t "fixture NOTBASE has second parent S" [ "$(gx rev-parse "$NOTBASE^2")" = "$S" ]
t "accepts a real --no-ff merge of head and base" structural "$GOOD" "$SHA"
rejects() { if structural "$1" "$SHA"; then return 1; fi; }
t "rejects a merge whose tree carries an extra edit" rejects "$EXTRA"
t "rejects a merge whose first parent is not the head" rejects "$BADP1"
t "rejects a three-parent merge" rejects "$OCTO"
t "rejects a merge whose second parent is not on the base" rejects "$NOTBASE"
t "ancestry: behind head is not up to date" bash -c '! git -C "$1" merge-base --is-ancestor origin/main "$2"' _ "$G" "$SHA"
t "ancestry: a head containing the base tip is up to date" git -C "$G" merge-base --is-ancestor origin/main "$GOOD"

echo
echo "shipping-kick: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
```
- [x] **Step 3: Run the kicker tests**

Run: `bash tests/test-shipping-kick.sh`
Expected: every line PASS, final line `shipping-kick: <n> passed, 0 failed`. Two UNKNOWN cases sleep about 40s in total; that is the real retry interval, not a hang.

- [x] **Step 4: Prove a gate fires both ways** (designing-enforcement-gates: a guard never seen failing is not a guard)

Temporarily change `ACTIONS_APP_ID = 15368` to `ACTIONS_APP_ID = 1` in `scripts/shipping-kick.py`, run `bash tests/test-shipping-kick.sh`, confirm "kicks once" FAILS (exit 2 instead of 0), then restore `15368` and re-run to green. Do not commit the temporary change.

- [x] **Step 5: Lint**

Run: `shellcheck --severity=warning tests/test-shipping-kick.sh && /usr/bin/python3 -I -m py_compile scripts/shipping-kick.py`
Expected: no output, exit 0.

- [x] **Step 6: Commit**

```bash
git add scripts/shipping-kick.py tests/test-shipping-kick.sh
git commit -m "feat(pr-grind): shipping-kick.py posts one validated Shipping kick (#929)"
```

---

### Task 4: `completion.md` wiring and its prose tests

**Files:**
- Modify: `skills/pr-grind/references/completion.md:571`, `:577`, after `:602`, `:1382-1386`
- Modify: `tests/test-needs-shipping.sh:165-246` (prose section)

**Interfaces:**
- Consumes: the kicker CLI and status-line prefixes from Task 3; the exit-10 grammar from Task 2.

- [x] **Step 1: Line 571 (routing description)**

Replace the sentence "ADR 0054. A repo opts into Cursor Cloud Shipping by carrying a `.cursor/skills/verify-*/` directory in the PR's base commit. In an opted-in repo, a PR that touches anything outside the built-in skip list (docs, root `*.md`, `.claude/**/*.md`, tests) is landed by Shipping, not by pr-grind." with:

```markdown
ADR 0054, amended by ADR 0055. A repo opts into Cursor Cloud Shipping by carrying a `.cursor/skills/verify-*/` directory in the tree of its base branch's live tip. In an opted-in repo, a PR that touches anything outside the built-in skip list (docs, root `*.md`, tests; agent-config paths such as `.cursor/`, `.claude/`, `.codex/`, `.agents/`, `AGENTS.md` and `CLAUDE.md` are never skipped) is landed by Shipping, not by pr-grind.
```

The rest of line 571 is unchanged.

- [x] **Step 2: Line 577 (exit-10 bullet)**

Replace the whole bullet with:

```markdown
- **stdout `shipping mergeStateStatus=<S> base_ref=<name> base_tip=<40-hex> skills=<a,b|-> agent_config_edited=<0|1> files_incomplete=<0|1> author=<login|-> cross_repo=<0|1>`, exit 10** (exactly these eight fields, in this order, on one line): run the Shipping block below as its own Bash call, then the Shipping kick below, print the completion output with the Ready-for-Shipping line, and **stop**. Do NOT write or copy the clean marker, and do NOT run Branch-Currency Detection, Approver-Gap Detection, any merge block, or the `--no-merge` block. `--no-merge` does not override this; it only skips the kick.
```

- [x] **Step 3: Insert the kick section after line 602** ("This path does not prune the per-PR Codex retrigger markers…"), before `<EXTREMELY-IMPORTANT>`:

````markdown
**Shipping kick (exit 10 only, after the Shipping block; ADR 0055):**
- **With `--no-merge`:** do not run the kicker; a kick authorizes a merge. The Ready line reports `auto-kick skipped: --no-merge; the operator may kick Shipping by hand`. Stop.
- **Otherwise** run the kicker as its own Bash call at the AMBIENT session cwd, with the same `<REVIEWED_HEAD>` routing used. It runs the classifier itself and applies every other gate.
```bash
/usr/bin/python3 -I "${CLAUDE_PLUGIN_ROOT}/scripts/shipping-kick.py" "<owner>/<repo>" <PR_NUMBER> <full 40-char HEAD_FULL_SHA from the classification block>
```
It prints exactly one line and never the comment body. Report that line verbatim in the Ready line, then print exactly ONE follow-up, chosen by exit code and line prefix:

| Exit | Line starts with | Follow-up |
|---|---|---|
| 0 | `kicked:` | none |
| 1 | `error:` | none; the line says what to do |
| 2 | `not kicked: mergeStateStatus=` | `fix that (conflict, draft, failing check or uncomputed status), then re-run /pr-grind to evaluate the remaining gates` |
| 2 | `not kicked: protection precondition` | `fix that, then re-run /pr-grind` |
| 3 | `not eligible:` naming `author` or `cross-repo` | `security refusal: review this PR yourself before landing it by any route` |
| 3 | `not eligible:` naming only `files-incomplete` and/or `agent-config` | the operator-only D4 escape below |
| 4 | `already kicked:` | `to retry this head, delete that comment, then re-run /pr-grind` |
| 5 | `not kicked: no usable verify skill name` | `fix that, then re-run /pr-grind` |
| 6 | `stale or not shipping-routed` | none |
| 7 | `post failed:` | none |
| anything else | | none; report the line |

Whenever the line contains `agent-config` (the token or the `; also: agent-config` suffix), also print `this PR edits agent configuration: review it before landing it by any route`.

**Operator-only D4 escape** (printed for the operator; never run by pr-grind or the session). BEHIND is read from the kicker's line when it ends `mergeStateStatus=<S>`, otherwise from the classifier's exit-10 line:
```text
Operator only, in your own terminal, after reviewing the full change yourself:
  (only when BEHIND) gh pr update-branch <PR_NUMBER> -R <owner>/<repo>, then wait for the new head's required checks to pass
  touch <PROJECT_ROOT>/.claude/skip-pr-grind.local   (wait at least 30s before merging; it is valid for 3600s)
  gh pr merge <PR_NUMBER> -R <owner>/<repo> --squash --delete-branch --match-head-commit <the head you reviewed, or after update-branch the new head>
```
Exits 1-7 are expected outcomes, not errors: none is a BAIL, and no kicker exit leads to a `RESULT_BAIL_CATEGORY` or to `gh pr merge` run by pr-grind. If the Shipping block itself exits non-zero, BAIL `env` as the routing section says and do not run the kicker. The classifier's `mergeStateStatus` warnings are not printed.
````

- [x] **Step 4: Lines 1382-1386 (Ready line)**

Replace the "With Shipping routing (exit 10)…" paragraph and its four bullets with:

```markdown
**With Shipping routing (exit 10), on any invocation (default or `--no-merge`):** this supersedes the Default and `--no-merge` lines above, so append neither `- Merged.` nor `- Ready for merge.`. Instead append:
- `- Ready for Shipping: this repo opted in (base tip has .cursor/skills/verify-*). Busdriver did not merge and wrote no clean marker. Kick: <the kicker's line, or "auto-kick skipped: --no-merge; the operator may kick Shipping by hand">`
- When the kicker's line is `kicked: … mergeStateStatus=BEHIND`, also: `- The cloud agent updates a BEHIND branch after PASS.`
- Then the follow-up chosen in "Shipping kick" above, if any.
```

- [x] **Step 5: Update the prose tests in `tests/test-needs-shipping.sh`**

Replace the loop at lines 237-241 with:

```bash
# shellcheck disable=SC2016  # literal backticks being searched for
for w in 'Ready for Shipping: this repo opted in (base tip has .cursor/skills/verify-*)' \
         'The cloud agent updates a BEHIND branch after PASS.' 'auto-kick skipped: --no-merge; the operator may kick Shipping by hand'; do
  t "output carries: $w" grep -qF -- "$w" "$COMP"
done
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
```

`ROUTE_TEXT` (line 186) runs from the routing heading to the marker heading, so it now also contains the kick section; the existing `routing section does not prune Codex retrigger markers` and `routing BAILs env` assertions still hold against it.

- [x] **Step 6: Run both suites**

Run: `bash tests/test-needs-shipping.sh && bash tests/test-shipping-kick.sh`
Expected: both end `0 failed`.

- [x] **Step 7: Commit**

```bash
git add skills/pr-grind/references/completion.md tests/test-needs-shipping.sh
git commit -m "feat(pr-grind): completion runs the Shipping kicker and maps its outcome (#929)"
```

---

### Task 5: SKILL.md, finishing skill, post-PR hook

**Files:**
- Modify: `skills/pr-grind/SKILL.md:19`, `:83`, `:863-865`, `:1749`
- Modify: `skills/finishing-a-development-branch/SKILL.md:123` (last sentence only)
- Modify: `scripts/hooks/post-bash-pr-created.js:75-76`
- Regenerate: `.gate-integrity.lock`
- Test: `tests/test-needs-shipping.sh:243-246`, `tests/test-gate-integrity.sh`

- [x] **Step 1: `skills/pr-grind/SKILL.md`**

Line 19, replace `or stop at Ready for Shipping if the repo opted in."` with `or stop at Ready for Shipping (posting one Cursor Shipping kick when eligible) if the repo opted in."`.

Line 83, replace the sentence starting `**Exception — Shipping routing (ADR 0054):**` through `See \`scripts/needs-shipping.py\`.` with:

```markdown
**Exception — Shipping routing (ADR 0054, amended by ADR 0055):** in a repo whose base branch tip carries `.cursor/skills/verify-*/`, a PR that touches anything outside the built-in skip list (docs, root `*.md`, tests; agent-config paths are never skipped) stops at "Ready for Shipping" instead, even with `--no-merge`: no merge, no clean marker. pr-grind then posts one Cursor Shipping kick when the PR is eligible (`scripts/shipping-kick.py`), and the cloud agent lands it; with `--no-merge` it still removes the markers but posts no kick. See `scripts/needs-shipping.py`.
```

Lines 863-865, replace with (four lines; the first is unchanged so the test anchor holds):

```text
  ├── Shipping routing (scripts/needs-shipping.py, ADR 0054; runs even with --no-merge):
  │   stdout `merge`/exit 0 → continue below; exit 10 → rm both markers, post one
  │   Shipping kick unless --no-merge (scripts/shipping-kick.py, ADR 0055), report
  │   Ready for Shipping, STOP; anything else → rm both markers, BAIL env. Never merge.
```

Line 1749, replace `a Shipping-routed PR stops at Ready for Shipping with no marker regardless (ADR 0054)` with `a Shipping-routed PR stops at Ready for Shipping with no marker regardless (ADR 0054); there \`--no-merge\` only stops pr-grind from posting the Shipping kick (ADR 0055)`.

- [x] **Step 2: `skills/finishing-a-development-branch/SKILL.md:123`**

Replace only the final sentence `If pr-grind prints "Ready for Shipping", stop: do not merge, and do not re-run with \`--no-merge\`; kick Cursor Cloud Shipping on the PR, which then lands it (ADR 0054).` with:

```markdown
If pr-grind prints "Ready for Shipping", stop: do not merge, and do not re-run with `--no-merge`. pr-grind posts the Shipping kick itself. Never post an `@cursor` comment yourself, in any mode, AFK included. After a skip, report the skip line to the operator; after the kicker's `post failed` line, re-run `/pr-grind`. A skip for author or cross-repo is a security refusal (ADR 0054, ADR 0055).
```

The default-flow contract earlier on line 123 stays.

- [x] **Step 3: `scripts/hooks/post-bash-pr-created.js:75-76`**

Replace the two array entries:

```js
      'If pr-grind prints "Ready for Shipping", stop: do not merge, and do not re-run with',
      '`--no-merge`; Cursor Cloud Shipping lands it.',
```

with:

```js
      'If pr-grind prints "Ready for Shipping", stop: do not merge, do not re-run with',
      '`--no-merge`, and never post an `@cursor` comment yourself; pr-grind posts the',
      'Shipping kick when the PR is eligible.',
```

- [x] **Step 4: Regenerate the gate-integrity lock and look for pinned hook text**

Run: `./scripts/gate-integrity.sh --update && bash tests/test-gate-integrity.sh && grep -rn "Cursor Cloud Shipping lands it" tests __tests__ scripts skills hooks`
Expected: the integrity test passes; the grep prints nothing. If the grep finds a test pinning the old hook text, update that literal to the new text in the same commit.

- [x] **Step 5: Run the affected suites**

Run: `bash tests/test-needs-shipping.sh && npm test -- --run 2>&1 | tail -5`
Expected: `0 failed`; vitest green.

- [x] **Step 6: Commit**

```bash
git add skills/pr-grind/SKILL.md skills/finishing-a-development-branch/SKILL.md scripts/hooks/post-bash-pr-created.js .gate-integrity.lock
git commit -m "docs(pr-grind): skill and post-PR hook describe the Shipping auto-kick (#929)"
```

---

### Task 6: ADR 0055 residual notes

**Files:**
- Modify: `docs/adr/0055-pr-grind-shipping-kick.md` (Consequences section, after the "A subverted agent can land code nobody reviewed" bullet)

- [x] **Step 1: Add four Consequences bullets**

```markdown
- In a private repo, anyone with read access (org members, outside collaborators) can
  comment on an operator PR, and the agent reads those comments. Re-measure that set
  alongside rulesets whenever a repo is newly opted in.
- With no required reviews, write access already implies landing power, so a
  collaborator who pushes to an operator PR between the kick and the agent's checkout
  gains nothing new.
- A required check whose name contains a comma (a matrix job such as `test (a, b)`) is
  refused (exit 2). None exists in the three repos today; revisit with a
  newline-delimited list if one is needed.
- `gh pr checks --required` resolves required checks through GraphQL `isRequired`
  (measured with the operator's token, gh 2.102.0). The first watched kick in each repo
  confirms it works with the cloud agent's token; if it does not, the agent waits out its
  45 minutes and never merges.
```

- [x] **Step 2: Commit**

```bash
git add docs/adr/0055-pr-grind-shipping-kick.md
git commit -m "docs(adr): ADR 0055 records the spec review's residuals (#929)"
```

---

### Task 7: Full verification

- [x] **Step 1: Run everything the change touches**

Run:
```bash
/usr/bin/python3 -I scripts/needs-shipping.py --selftest
bash tests/test-needs-shipping.sh
bash tests/test-shipping-kick.sh
bash tests/test-gate-integrity.sh
shellcheck --severity=warning tests/test-needs-shipping.sh tests/test-shipping-kick.sh
npm run validate
npm test -- --run
```
Expected: selftest prints `needs_shipping_selftest_ok`; each shell suite ends `0 failed`; shellcheck and validate exit 0; vitest green.

- [x] **Step 2: Live read-only smoke of the classifier** (no post; the kicker is NOT run live here)

Run: `gh pr list -R chris-yyau/busdriver --state open --limit 1 --json number,headRefOid --jq '.[0] | "\(.number) \(.headRefOid)"'`, then `/usr/bin/python3 -I scripts/needs-shipping.py chris-yyau/busdriver <that number> <that head>`. If no PR is open, skip this step and say so in the report.
Expected: `merge` and exit 0 (busdriver has no `.cursor/skills/verify-*`). This proves the new `git/ref/heads` read and the extended `pr view` fields work against the real API.

- [x] **Step 3: Report the operator's remaining manual steps** (not code; listed so they are not lost)
  1. Turn on "Do not allow bypassing" (`enforce_admins`) in diveand.dev, jikdak and chrisyau.me.
  2. Pin chrisyau.me's required `test` check to GitHub Actions (app 15368).
  3. Watch the first kicked PR in each repo and record the result in ADR 0055.

---

## Spec coverage map

| Spec item | Task |
|---|---|
| §1 exit-10 line, `base_ref`, `base_tip`, opt-in move, movement check | 2 |
| §1 `skills` sorted, `-` on invalid | 2 |
| §1 agent-config paths, skip-list change, `files_incomplete`, `author`, `cross_repo` | 1, 2 |
| §2 kicker steps 1-10, output, agent-config suffix, body | 3 |
| §3 completion.md a-d | 4 |
| §4 SKILL.md | 5 |
| §5 finishing skill | 5 |
| §6 ADR 0055 / 0054 pointer | done in `9b5d27ac`; residuals in 6 |
| §7 post-PR hook + lock | 5 |
| Testing: classifier cases, kicker per-exit table, body, structural selftest, prose order | 2, 3, 4 |

<!-- design-review-coverage: FULL 3/3  -->

<!-- design-reviewed: PASS -->
