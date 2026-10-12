# Imported Agent Config Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use busdriver:subagent-driven-development (recommended) or busdriver:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** In repos opted into Cursor Shipping, files that agent-config files import with `@path` count as agent config. A walk that cannot finish makes every changed path agent config (#936).

**Architecture:** `scripts/needs-shipping.py` gains an import walk: a recursive-tree map per revision, a reader-independent token parser, a lexical resolver, a GraphQL blob fetcher and a breadth-first walk. All of it stays in that one file, because the script runs under `python3 -I`, which keeps sibling modules off `sys.path`. Its result feeds one predicate, `is_config()`, which replaces `agent_config()` in `skippable()` and in the `agent_config_edited` field. The kicker's classifier timeout, the pr-grind prose and ADR 0055 follow.

**Tech Stack:** Python 3.9 stdlib (`/usr/bin/python3 -I`), `gh api` (REST trees, GraphQL blobs), bash test harness with a stub `gh`.

**Global Constraints:**
- Spec: `docs/specs/2026-10-11-shipping-imported-agent-config-design.md` (commit `ef4430f7`). Where this plan and the spec differ, the spec wins, except for the drifts noted up front below.
- Python 3.9-compatible: no `match`, no `X | Y` types. Stdlib only, single file.
- Fail closed. An API or `gh` error raises `Fail` (exit 1). A walk that cannot finish raises `Incomplete`, which is caught only in `imported_config()`.
- A repo that is not opted in makes no `?recursive=1` or GraphQL call.
- The stdout line, stderr and exit codes of the classifier are unchanged. `--selftest` still prints exactly `needs_shipping_selftest_ok`.
- Every existing case in `tests/test-needs-shipping.sh` and `tests/test-shipping-kick.sh` keeps its current expected output.
- Commits go through litmus (pre-commit gate). Conventional Commits, ending with `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`.

**Spec drift noted up front:** spec §4 says `` `@/*` `` yields `` /*` `` and `/*`. The trailing strip removes both `` ` `` and `*`, so the stripped candidate is the root-only `/`, which is dropped. `` `@/*` `` therefore yields only `` /*` ``. The spec's conclusion, never `/`, holds; the selftest pins the real list.

**Second drift, a limit the spec does not name:** every `@` in a whitespace run starts a token, so a run of adjacent `@`s copies the rest of the run once per `@`, which is quadratic in the file size. `parse()` therefore gives each file a token-text budget of twice its length plus 4096 characters. Ordinary text, whose tokens barely overlap, stays far below it; exceeding it makes the walk incomplete, like every other limit in §5. Everything else in `parse()` is linear: backtick runs pair through a next-same-length index, and span membership uses one forward index per line. So `walk()` checks the deadline between files and tokens rather than inside `parse()`, and the overrun is at most one file's parse; the selftest pins a 512 KiB line under 20 seconds. `resolve()` is quadratic in a candidate's component count, so `candidate_targets()` does not resolve a candidate of `PATH_MAX` (4096) bytes or more. A live one makes the walk incomplete, because a tool may normalise `./` and `..` before it opens the path. A non-live one is dropped, as every non-live candidate that cannot be resolved is. `walk()` also checks the deadline before each candidate, so the overrun past the deadline is at most one candidate's resolves. Lines end at LF, CR or CRLF, and a blank line holds only spaces and tabs, as in CommonMark. Any other split could move a token into a code span that Markdown would not form, and that would hide an import.

**Third drift, a gitlink at an agent-config path** (for example a submodule at `.claude/rules`): §3 does not name this case. The plan makes the walk incomplete, because the submodule's instruction files are not in this tree to walk.

**Fourth drift, `|` switches code spans off:** spec §4 lists `<`, `\`, `](` and `]:`. The plan adds `|`, because a GFM table splits a row into cells before code spans form, so a backtick pair that crosses a cell boundary is not a span. A probe on 2026-10-12 found one table paragraph with `@` tokens in the three repos: jikdak's `.claude/CLAUDE.md` has `@shared` and a bare `` @` ``. Read live, they resolve to covers under `.claude/`, which is agent config already, so the cost is nil. For the same reason the plan adds `://` and `www.`: a GFM autolink such as `` `www.example.com/a` `` takes the first backtick, so a later pair does not form a span. The same probe found `@` tokens in URL paragraphs only in Cursor-read files, which are live anyway, so that cost is nil too.

**Token limit:** parsed tokens are cached for the whole walk, so a dense `@a @a ...` file holds memory in proportion to its token count. `MAX_TOKENS` (20000) bounds the tokens held across the walk; past it the walk is incomplete, like every other §5 limit, instead of running out of memory.

**Fifth drift, a live path below a gitlink:** spec §3 resolves through a gitlink and records it. The plan makes the walk incomplete as soon as a live path pushes a component below one, because the submodule's entries are not in this tree and a symlink there would be invisible. A path that pops back out through the gitlink itself (`sub/../docs/a.md`) still resolves.

**By-name index:** `suffix_index()` maps each basename to its paths, so memory is linear in the tree. `by_name()` filters that bucket for paths equal to the candidate or ending in `/` plus the candidate, which is exactly the set the spec's component-boundary suffix match gives. Indexing every suffix would be cubic in the depth of a nested chain.

**Head or base moving during the walk:** the walk runs between `classify()`'s two reads of head and base, so a slow walk widens the window in which a push makes the classifier exit 1. That is the existing fail-closed path, unchanged in kind; the ADR amendment notes it.

**Parser tests:** example rows pin each §4 rule. A seeded fuzz (3000 strings) checks the parser against brute-force oracles: no eligible `@` loses its token, pairing matches the quadratic reference, and on single-line inputs every span flag matches.

**Follow-up the spec handed to the plan, deferred:** walking a directory that a live token names, including a Cursor-read file naming one by its bare name. The by-name index covers directories and gitlinks as well as files, so such a mention resolves to a tree and makes the walk incomplete (§4, §6). That fails closed and must stay so: indexing only files would let a PR edit a file under that directory and merge. The follow-up is to walk the directory's instruction files instead of hand-landing. It changes nothing in the three opted-in repos: the 2026-10-12 walk over their default branches found no live token that names a directory. Task 3 Step 9 files the follow-up issue before the PR is opened, and the PR body links it.

**Cursor root-relative `..`:** for a Cursor-read file, every live candidate is also resolved from the repo root (spec §4). So a relative import such as `@../docs/a.md` in `frontend/AGENTS.md` leaves the repo from the root, and that makes the walk incomplete (§3). This is the spec's literal rule and it fails closed. A Cursor-read file with a `../` token therefore hand-lands every PR in that repo; the three opted-in repos have none. Task 2 pins it with a walk case, and the ADR amendment lists it.

---

## File Structure

| File | Change |
|---|---|
| `scripts/needs-shipping.py` | Import walk (Task 1), wired into `classify()` (Task 2), docstrings and module header |
| `tests/test-needs-shipping.sh` | Stub `gh` serves recursive trees and GraphQL; fixture builder; walk cases; prose greps (Tasks 2, 3) |
| `scripts/shipping-kick.py` | `CLASSIFIER_TIMEOUT` 1000 → 1700 (Task 3) |
| `tests/test-shipping-kick.sh` | `sed` pattern follows the new literal (Task 3) |
| `skills/pr-grind/references/completion.md` | Import clause; two Bash-timeout sentences (Task 3) |
| `skills/pr-grind/SKILL.md` | Import clause at line 83 (Task 3) |
| `docs/adr/0055-pr-grind-shipping-kick.md` | Amendment note and a Consequences bullet (Task 3) |

---

### Task 1: The import walk, with selftest rows

**Files:**
- Modify: `scripts/needs-shipping.py` (imports at lines 26-30; `gh`/`gh_json` at lines 93-109; new code between `well_formed_entry` (line 168) and `verify_skills` (line 172); `selftest()` at lines 248-270)

**Interfaces:**
- Produces: `class Incomplete(Exception)`; `class GhTimeout(Fail)`; `gh(args, timeout=GH_TIMEOUT)`; `gh_json(args, timeout=GH_TIMEOUT)`; `Clock(budget).remaining() -> float`; `tree_map(repo, rev, clock) -> {path: (type, mode, sha, size)}`; `instruction_file(path) -> bool`; `reader(path) -> "cursor"|"claude"|"both"`; `resolve(tmap, path, live) -> Res(path, under_gitlink, missing, gitlinks)` with sentinels `OUTSIDE`, `ROOT`, `DROPPED`; `parse(text) -> [(candidates, in_code_span, quoted)]`; `blob_query(n) -> str`; `Fetcher(repo, clock).fetch({sha: size}) -> {sha: text}`; `walk(repo, revs, clock) -> (exact, cover)`; `imported_config(repo, revs) -> (exact, cover) | INCOMPLETE`; `is_config(path, imported=None) -> bool`.

- [ ] **Step 1: Imports and constants.** Replace the import block (lines 26-30) with:

```python
import collections
import json
import os
import posixpath
import re
import subprocess
import sys
import time
```

After `GH_ENV_KEEP = ...` (line 84), add:

```python
# Import walk (#936). Every limit, and the deadline, makes the walk INCOMPLETE (every changed
# path then counts as agent config) instead of exiting 1, so a large tree never blocks merges.
WALK_DEADLINE = 600  # seconds for the whole walk, measured from its first call
MAX_DEPTH, MAX_BLOBS, MAX_QUERIES, MAX_STATES = 5, 300, 12, 2000
MAX_TOKENS = 20000  # @-tokens held across the whole walk; the three opted-in repos hold under 100
BLOB_MAX, BATCH_ALIASES, BATCH_BYTES = 512 * 1024, 50, 2 * 1024 * 1024
PATH_MAX = 4096  # a live candidate this long makes the walk incomplete instead of being resolved
SYMLINK = "120000"
OUTSIDE, ROOT, DROPPED, INCOMPLETE = object(), object(), object(), object()
STRIP = ".,;:!?)]}>\"'*_~`"
SPAN_UNSAFE = ("<", "\\", "](", "]:", "|", "://", "www.")  # GFM tables and autolinks preempt spans
URL_RE = re.compile(r"[A-Za-z][A-Za-z0-9+.-]*://")
CURSOR_SEGS = ("/.agents/skills/", "/.claude/skills/", "/.codex/skills/", "/.claude/agents/", "/.codex/agents/")
BLOB_FIELDS = "... on Blob { byteSize isBinary isTruncated text }"
Res = collections.namedtuple("Res", "path under_gitlink missing gitlinks")
```

- [ ] **Step 2: Timeout-aware `gh`.** Replace `gh` and `gh_json` (lines 93-109) with:

```python
class GhTimeout(Fail):
    pass


def gh(args, timeout=GH_TIMEOUT):
    try:
        r = subprocess.run(["gh"] + args, capture_output=True, text=True, env=gh_env(), timeout=timeout)
    except subprocess.TimeoutExpired:
        raise GhTimeout("gh %s timed out after %ds" % (" ".join(args[:2]), timeout))
    except OSError as e:
        raise Fail("gh not runnable: %s" % e)
    if r.returncode != 0:
        raise Fail("gh %s failed (rc=%d): %s" % (" ".join(args[:2]), r.returncode, r.stderr.strip()[:200]))
    return r.stdout


def gh_json(args, timeout=GH_TIMEOUT):
    try:
        return json.loads(gh(args, timeout))
    except ValueError:
        raise Fail("gh %s returned unparseable JSON" % " ".join(args[:2]))
```

`class Fail` (line 77) already precedes this, so `GhTimeout` can subclass it. The existing hung-call test still sees `timed out after 1s`.

- [ ] **Step 3: Walk plumbing.** Insert after `well_formed_entry` (line 169):

```python
class Incomplete(Exception):
    """The import walk cannot finish; every changed path then counts as agent config (#936)."""


class Clock:
    """The walk's own wall-clock budget (#936 §7)."""

    def __init__(self, budget):
        self.end = time.monotonic() + budget

    def remaining(self):
        left = self.end - time.monotonic()
        if left <= 0:
            raise Incomplete("walk deadline")
        return left


def walk_gh_json(clock, args):
    """gh_json bounded by the walk deadline; a timeout makes the walk incomplete, not exit 1."""
    try:
        return gh_json(args, min(GH_TIMEOUT, clock.remaining()))
    except GhTimeout:
        raise Incomplete("walk call timed out")


def tree_map(repo, rev, clock):
    """Path -> (type, mode, sha, size) for the whole tree at `rev` (#936 §2)."""
    body = walk_gh_json(clock, ["api", "repos/%s/git/trees/%s?recursive=1" % (repo, rev)])
    if not (isinstance(body, dict) and isinstance(body.get("truncated"), bool) and isinstance(body.get("tree"), list)):
        raise Fail("unexpected recursive trees response for %s" % rev)
    if body["truncated"]:
        raise Incomplete("truncated tree")
    out = {}
    for e in body["tree"]:
        ok = (isinstance(e, dict) and nonempty_str(e.get("path")) and e.get("type") in ("blob", "tree", "commit")
              and isinstance(e.get("mode"), str) and isinstance(e.get("sha"), str)
              and re.fullmatch(r"[0-9a-f]{40}", e["sha"]) is not None)
        size = e.get("size") if ok else None
        if ok and e["type"] == "blob":  # GitHub omits size on tree and commit rows
            ok = isinstance(size, int) and not isinstance(size, bool) and size >= 0
        if not ok:
            raise Fail("malformed recursive tree entry in %s" % rev)
        out[e["path"]] = (e["type"], e["mode"], e["sha"], size)
    return out


def instruction_file(path):
    base = path.lower().rsplit("/", 1)[-1]
    return base.endswith((".md", ".mdc")) or base == ".cursorrules"


def reader(path):
    """Who loads this entry as instructions: `cursor`, `claude` or `both` (#936 §3)."""
    p = path.lower()
    parts = p.split("/")
    base = parts[-1]
    cursor = (".cursor" in parts or any(s in "/" + p for s in CURSOR_SEGS)
              or base in ("agents.md", ".cursorrules") or (base == "claude.md" and ".claude" not in parts[:-1]))
    claude = ".claude" in parts or base in ("claude.md", "claude.local.md", "agents.md") or not cursor
    return "both" if cursor and claude else ("cursor" if cursor else "claude")


def suffix_index(paths):
    """Basename -> the paths with that last component, for Cursor's by-name lookup; linear in the tree."""
    idx = {}
    for p in paths:
        idx.setdefault(p.rsplit("/", 1)[-1], []).append(p)
    return idx


def by_name(idx, norm):
    """The paths equal to `norm` or ending in "/" + `norm`: a match at a component boundary."""
    return [p for p in idx.get(norm.rsplit("/", 1)[-1], ()) if p == norm or p.endswith("/" + norm)]
```

- [ ] **Step 4: Resolver.** Append:

```python
def resolve(tmap, path, live):
    """Resolve `path` one component at a time against a tree map (#936 §3). Every prefix is
    looked up before a later `..` can pop it, so normalisation cannot hide a symlink."""
    stack, kinds, gitlinks, missing = [], [], [], None
    for comp in path.split("/"):
        if comp in ("", "."):
            continue
        if comp == "..":
            if not stack:
                return Res(OUTSIDE, False, missing, gitlinks)  # sticky: nothing after this can re-enter
            stack.pop()
            kinds.pop()
            continue
        if live and "commit" in kinds:  # entries below a gitlink are not in this tree, so a symlink there is invisible
            raise Incomplete("a path below a gitlink")
        stack.append(comp)
        prefix = "/".join(stack)
        entry = tmap.get(prefix)
        if entry and entry[1] == SYMLINK:
            # keep-simple(UPGRADE: resolve link targets if an opted-in repo needs symlinks)
            if live:
                raise Incomplete("symlink")
            return Res(DROPPED, False, None, [])
        if entry and entry[0] == "commit":
            gitlinks.append(prefix)
        if entry is None and missing is None and "commit" not in kinds:
            missing = prefix
        kinds.append(entry[0] if entry else None)
    if not stack:
        return Res(ROOT, False, missing, gitlinks)
    return Res("/".join(stack), "commit" in kinds, missing, gitlinks)
```

- [ ] **Step 5: Parser.** Append:

```python
def code_spans(line):
    """Code spans paired on one line as (start, end), and whether every backtick run paired."""
    runs = [(m.start(), m.end()) for m in re.finditer(r"`+", line)]
    nxt, last = [None] * len(runs), {}
    for k in range(len(runs) - 1, -1, -1):  # next run of the same length, so pairing stays linear
        n = runs[k][1] - runs[k][0]
        nxt[k], last[n] = last.get(n), k
    spans, i, paired = [], 0, True
    while i < len(runs):
        j = nxt[i]
        if j is None:
            paired, i = False, i + 1
        else:
            spans.append((runs[i][0], runs[j][1]))
            i = j + 1
    return spans, paired


def token_text(line, i, cap):
    """Token text from line[i] to the next whitespace not escaped with a backslash; `\\ ` is a space.
    Stops after cap + 1 characters, so the caller's budget bounds the copying."""
    out = []
    while i < len(line) and not line[i].isspace() and len(out) <= cap:
        if line[i] == "\\" and line[i + 1:i + 2] == " ":
            out.append(" ")
            i += 2
        else:
            out.append(line[i])
            i += 1
    return "".join(out)


def candidates(text):
    """Candidate paths of one token's text (#936 §4). A root-only candidate counts only as the text as is."""
    bases = [text] + [text.split(sep, 1)[0] for sep in ("](", "#") if sep in text]
    out = []
    for c in [v for b in bases for v in (b, b.rstrip(STRIP))]:
        root_only = c and not c.strip("/.")
        if c and c not in out and (not root_only or c == text):
            out.append(c)
    return out


def parse(text, limit=None):
    """Reader-independent syntax of one file (#936 §4): (candidates, in_code_span, quoted) per token.
    Code spans count only in a paragraph plain enough that per-line pairing matches Markdown.
    Lines end at LF, CR or CRLF, and a blank line holds only spaces and tabs, as in CommonMark.
    More than `limit` tokens (default MAX_TOKENS) makes the walk incomplete, bounding held memory."""
    limit = MAX_TOKENS if limit is None else limit
    toks, para = [], []
    budget = 2 * len(text) + 4096  # adjacent @s re-copy the run; a quadratic file is a walk limit
    for line in text.replace("\r\n", "\n").replace("\r", "\n").split("\n") + [""]:
        if line.strip(" \t"):
            para.append(line)
            continue
        pairs = [code_spans(ln) for ln in para]
        joined = "\n".join(para)
        plain = all(ok for _, ok in pairs) and not any(u in joined for u in SPAN_UNSAFE)
        for ln, (spans, _) in zip(para, pairs):
            s = 0  # spans are sorted and disjoint, and k only grows, so one forward index suffices
            for k, ch in enumerate(ln):
                prev = ln[k - 1] if k else ""
                if ch != "@" or (prev.isascii() and prev.isalnum()):
                    continue
                quoted = prev in ("\"", "'") and ln[k - 2:k - 1] != "\\"
                while s < len(spans) and spans[s][1] <= k:
                    s += 1
                in_span = plain and s < len(spans) and spans[s][0] < k
                word = token_text(ln, k + 1, budget)
                budget -= len(word)
                if budget < 0:
                    raise Incomplete("token text over budget")
                if len(toks) >= limit:
                    raise Incomplete("token limit")
                toks.append((candidates(word), in_span, quoted))
        para = []
    return toks
```

- [ ] **Step 6: Fetcher.** Append:

```python
def blob_query(n):
    """GraphQL text fetching `n` blobs by object id; every value is a variable (#936 §5)."""
    decl = "".join(", $o%d: GitObjectID!" % i for i in range(n))
    fields = " ".join("f%d: object(oid: $o%d) { %s }" % (i, i, BLOB_FIELDS) for i in range(n))
    return "query($owner: String!, $name: String!%s) { repository(owner: $owner, name: $name) { %s } }" % (
        decl, fields)


def blob_text(node):
    """The text of one fetched blob; any shape the walk cannot parse makes it incomplete."""
    size = node.get("byteSize") if isinstance(node, dict) else None
    ok = (isinstance(node, dict) and node.get("isBinary") is False and node.get("isTruncated") is False
          and isinstance(size, int) and not isinstance(size, bool) and size <= BLOB_MAX
          and isinstance(node.get("text"), str))
    if not ok:
        raise Incomplete("unparsed blob shape")
    return node["text"]


class Fetcher:
    """Blob text by object id through GraphQL, in batches of at most 50 aliases and 2 MiB (#936 §5)."""

    def __init__(self, repo, clock):
        self.owner, self.name = repo.split("/")
        self.clock, self.texts, self.queries = clock, {}, 0

    def fetch(self, sizes):
        """Fetch every sha in `sizes` (sha -> tree-map size) not fetched yet; return the text map."""
        todo = sorted(s for s in sizes if s not in self.texts)
        if any(sizes[s] > BLOB_MAX for s in todo):
            raise Incomplete("blob over 512 KiB")
        if len(self.texts) + len(todo) > MAX_BLOBS:
            raise Incomplete("blob limit")
        batch, total = [], 0
        for s in todo:
            if batch and (len(batch) == BATCH_ALIASES or total + sizes[s] > BATCH_BYTES):
                self.query(batch)
                batch, total = [], 0
            batch.append(s)
            total += sizes[s]
        if batch:
            self.query(batch)
        return self.texts

    def query(self, shas):
        self.queries += 1
        if self.queries > MAX_QUERIES:
            raise Incomplete("query limit")
        args = ["api", "graphql", "-f", "query=" + blob_query(len(shas)),
                "-f", "owner=" + self.owner, "-f", "name=" + self.name]
        for i, s in enumerate(shas):
            args += ["-f", "o%d=%s" % (i, s)]
        body = walk_gh_json(self.clock, args)
        data = body.get("data") if isinstance(body, dict) and "errors" not in body else None
        nodes = data.get("repository") if isinstance(data, dict) else None
        if not isinstance(nodes, dict):
            raise Fail("unexpected graphql blob response")
        for i, s in enumerate(shas):
            self.texts[s] = blob_text(nodes.get("f%d" % i))
```

- [ ] **Step 7: Walk, result and predicate.** Append:

```python
def candidate_targets(tmap, names, path, c, live, rd):
    """resolve() results for one candidate found in the file at `path` (#936 §4), yielded one
    at a time so the walk's state limit and deadline bound a large by-name fan-out."""
    if not c or URL_RE.match(c):
        return
    if len(c.encode()) >= PATH_MAX:  # resolve() is quadratic in the component count
        if live:
            raise Incomplete("candidate of PATH_MAX bytes or more")
        return
    if c.startswith(("~", "/")):
        # keep-simple(UPGRADE: resolve absolute paths against the checkout root if an opted-in repo needs Cursor alias notes)
        if live:
            raise Incomplete("home or absolute path")
        return
    yield resolve(tmap, posixpath.join(posixpath.dirname(path), c), live)
    if live and rd != "claude":  # Cursor's Agent also finds a mention from the root, or by name
        yield resolve(tmap, c, live)
        norm = "/".join(x for x in c.split("/") if x not in ("", "."))
        if norm and ".." not in norm.split("/"):
            for m in by_name(names, norm):
                yield resolve(tmap, m, live)

def take(tmap, res, live, exact, cover):
    """Record one resolved candidate in the sets; return a blob path to walk next, or None (#936 §5)."""
    if res.path is DROPPED:
        return None
    if res.path is OUTSIDE or res.path is ROOT:
        if live:
            raise Incomplete("outside the repo or the repo root")
        return None
    exact.update(res.gitlinks)
    exact.add(res.path)
    if not live:
        return None
    if res.missing:
        cover.add(res.missing)
    entry = tmap.get(res.path)
    if res.under_gitlink or (entry and entry[0] != "blob"):
        # keep-simple(UPGRADE: walk a tree's instruction files if an opted-in repo mentions a directory)
        raise Incomplete("directory or gitlink")
    if entry is None:
        cover.add(res.path)
        return None
    return res.path


def walk(repo, revs, clock):
    """Exact and cover path sets reached through imports from agent-config entries at `revs`
    (#936 §5). Raises Incomplete when the walk cannot finish."""
    tmaps = {}
    for rev in revs:
        tmaps[rev] = tree_map(repo, rev, clock)
    names = suffix_index(set().union(*tmaps.values()))
    exact, cover, level = set(), set(), []
    for rev, tmap in tmaps.items():
        for path, (kind, mode, _sha, _size) in tmap.items():
            if not agent_config(path):
                continue
            if mode == SYMLINK:
                raise Incomplete("symlinked agent-config path")
            if kind == "commit":  # a submodule's instruction files are not in this tree to walk
                raise Incomplete("gitlink at an agent-config path")
            if kind == "blob" and instruction_file(path):
                exact.add(path)
                level.append((rev, path, reader(path)))
    visited = set(level)
    if len(visited) > MAX_STATES:
        raise Incomplete("visited-state limit")
    fetcher, parsed, ntok = Fetcher(repo, clock), {}, 0
    for depth in range(MAX_DEPTH + 1):
        if not level:
            break
        texts = fetcher.fetch({tmaps[rev][p][2]: tmaps[rev][p][3] for rev, p, _ in level})
        nxt = []
        for rev, path, rd in level:
            clock.remaining()  # the deadline also bounds parsing and traversal, not only gh calls
            sha = tmaps[rev][path][2]
            if sha not in parsed:
                parsed[sha] = parse(texts[sha], MAX_TOKENS - ntok)  # one budget for the whole walk
                ntok += len(parsed[sha])
            for cands, in_span, quoted in parsed[sha]:
                live = rd != "claude" or not (in_span or quoted)
                for c in cands:
                    clock.remaining()  # per candidate: by-name matches can fan one out to many resolves
                    for res in candidate_targets(tmaps[rev], names, path, c, live, rd):
                        clock.remaining()
                        target = take(tmaps[rev], res, live, exact, cover)
                        key = (rev, target, rd)
                        if target is None or key in visited:
                            continue
                        if depth == MAX_DEPTH:
                            raise Incomplete("import chain deeper than 5")
                        visited.add(key)
                        if len(visited) > MAX_STATES:
                            raise Incomplete("visited-state limit")
                        nxt.append(key)
        level = nxt
    clock.remaining()
    return exact, cover


def imported_config(repo, revs):
    """Lower-cased (exact, cover) sets imported from agent config at `revs`, or INCOMPLETE (#936)."""
    try:
        exact, cover = walk(repo, revs, Clock(WALK_DEADLINE))
    except Incomplete:
        return INCOMPLETE
    return {p.lower() for p in exact}, {p.lower() for p in cover}


def is_config(path, imported=None):
    """agent_config(path), or a path an agent-config file imports (#936 §6). `imported` is None
    when no walk ran, INCOMPLETE when it could not finish, else the (exact, cover) pair."""
    if agent_config(path) or imported is INCOMPLETE:
        return True
    if imported is None:
        return False
    exact, cover = imported
    parts = path.lower().split("/")
    return "/".join(parts) in exact or any("/".join(parts[:i]) in cover for i in range(1, len(parts) + 1))
```

- [ ] **Step 8: Selftest rows.** In `selftest()`, insert before `print("needs_shipping_selftest_ok")`:

```python
    # #936 import walk: parser, readers, resolver, query text, predicate
    def first(text):
        return parse(text)[0]
    assert first("see @docs/a.md.") == (["docs/a.md.", "docs/a.md"], False, False)
    assert parse("a@b.com serve@14") == []
    assert len(parse("@@a")) == 2 and len(parse("@x " * 1000)) == 1000
    try:
        parse("@" * 20000)
        raise AssertionError("an @-run past the token budget must make the walk incomplete")
    except Incomplete:
        pass
    assert not first("`\r\r@../docs/a.md `")[1] and not first("`\r\n\r\n@../docs/a.md `")[1]
    assert not parse("a `b\n" + chr(0xA0) + "\n`@../docs/a.md`")[0][1]  # a no-break-space line is not blank
    assert first("`@x` `@y`")[1] and parse("`@x` `@y` @z")[2][1] is False
    big = "`x` " * 120000 + "@a " * 10000  # one ~500 KiB line: 120k spans x 10k tokens, linear time
    t0 = time.monotonic()
    assert len(parse(big)) == 10000 and time.monotonic() - t0 < 20
    try:
        parse("@a " * (MAX_TOKENS + 1))
        raise AssertionError("more than MAX_TOKENS tokens must make the walk incomplete")
    except Incomplete:
        pass
    def spans_ref(line):  # the quadratic pairing the linear code_spans must reproduce
        runs = [(m.start(), m.end()) for m in re.finditer(r"`+", line)]
        out, i, ok = [], 0, True
        while i < len(runs):
            n = runs[i][1] - runs[i][0]
            j = next((k for k in range(i + 1, len(runs)) if runs[k][1] - runs[k][0] == n), None)
            if j is None:
                ok, i = False, i + 1
            else:
                out.append((runs[i][0], runs[j][1]))
                i = j + 1
        return out, ok
    import random
    rnd = random.Random(936)  # seeded fuzz against brute-force oracles: no token lost, spans exact
    for _ in range(3000):
        s = "".join(rnd.choice("`@x/. \n\r\t\"'\\<a") for _ in range(rnd.randrange(40)))
        eligible = [k for k, ch in enumerate(s) if ch == "@" and not (k and s[k - 1].isalnum())]
        try:
            got = parse(s)
        except Incomplete:
            continue
        assert len(got) == len(eligible), s
        line = s.replace("\n", "").replace("\r", "")
        spans, ok = spans_ref(line)
        assert code_spans(line) == (spans, ok), line
        if line.strip(" \t") and line == s:
            plain = ok and not any(u in line for u in SPAN_UNSAFE)
            assert [t[1] for t in got] == [plain and any(a < k < b for a, b in spans) for k in eligible], s
    try:
        Clock(0).remaining()
        raise AssertionError("a spent clock must make the walk incomplete")
    except Incomplete:
        pass
    assert first("@my\\ notes.md")[0] == ["my notes.md"]
    assert "docs/x.md" in first("[**@docs/x.md**](docs/x.md)")[0]
    assert "docs/x.md" in first("[@docs/x.md](docs/x.md)")[0]
    assert "docs/policy.md" in first("@docs/policy.md#rules")[0]
    assert first("`@/*`")[0] == ["/*`"] and first("@.")[0] == ["."] and first("@./")[0] == ["./"]
    assert first("@/.,")[0] == ["/.,"]  # neither "/." nor the root-only "/" comes back
    for opener in ("(", "[", "{", "<", ")", ">", "\\", "*", "_", "~", '"', "'", "`"):
        assert len(parse(opener + "@x")) == 1, opener
    assert first("`@/x`")[1] and not first("<a> `@/x`")[1] and not first("[a](b) `@/x`")[1]
    assert not first("| x `y | @../docs/a.md z` |")[1]
    assert first("x a/b` @../docs/a.md `")[1]  # control: the same pair without a URL is a span
    assert not first("x www.example.com/a` @../docs/a.md `")[1] and not first("x https://e.com/a` @a `")[1]
    names = suffix_index(["docs/a.md", "src/docs/a.md", "xdocs/a.md", "docs"])
    assert sorted(by_name(names, "docs/a.md")) == ["docs/a.md", "src/docs/a.md"] and by_name(names, "docs") == ["docs"]
    assert not parse("a `b\n`code @x literal`\n` end")[0][1]
    assert not parse("```\n@x\n```")[0][1]
    assert first('"@docs/a"')[2] and not first("don't @docs/a")[2]
    assert not first('"see @docs/a"')[2] and not first('"done" @docs/a')[2] and not first('\\"@docs/a')[2]
    for path, who in (("CLAUDE.md", "both"), ("AGENTS.md", "both"), ("frontend/agents.md", "both"),
                      (".claude/CLAUDE.md", "claude"), (".claude/rules/x.md", "claude"),
                      (".claude/skills/s/SKILL.md", "both"), (".claude/agents/a.md", "both"),
                      (".cursor/rules/r.mdc", "cursor"), (".cursor/CLAUDE.md", "both"),
                      (".claude/rules/.cursor/x.md", "both"), ("pkg/.agents/skills/s/SKILL.md", "cursor"),
                      ("pkg/.cursorrules", "cursor"), (".codex/agents/b.md", "cursor")):
        assert reader(path) == who, path
    z = "0" * 40
    tm = {"docs": ("tree", "040000", z, None), "docs/a.md": ("blob", "100644", z, 1),
          "docs/link": ("blob", SYMLINK, z, 1), "sub": ("commit", "160000", z, None)}
    try:
        resolve(tm, "docs/link/../a.md", True)
        raise AssertionError("a live symlink prefix must make the walk incomplete")
    except Incomplete:
        pass
    assert resolve(tm, "docs/link/../a.md", False).path is DROPPED
    r = resolve(tm, "sub/../docs/a.md", True)
    assert (r.path, r.under_gitlink, r.gitlinks) == ("docs/a.md", False, ["sub"])
    assert resolve(tm, "sub/x.md", False).under_gitlink
    for below in ("sub/x.md", "sub/link/../../docs/a.md"):
        try:
            resolve(tm, below, True)
            raise AssertionError("a live path below a gitlink must make the walk incomplete: " + below)
        except Incomplete:
            pass
    assert resolve(tm, "a/../../docs/a.md", True).path is OUTSIDE
    long_c = "./" * 2045 + "docs/a.md"  # 4099 bytes that normalise to docs/a.md
    assert len(list(candidate_targets(tm, {}, "CLAUDE.md", long_c[4:], True, "claude"))) == 1  # 4095 bytes
    assert list(candidate_targets(tm, {}, "CLAUDE.md", long_c, False, "claude")) == []
    try:
        list(candidate_targets(tm, {}, "CLAUDE.md", long_c, True, "claude"))
        raise AssertionError("a live candidate of PATH_MAX bytes or more must make the walk incomplete")
    except Incomplete:
        pass
    assert resolve(tm, "./", True).path is ROOT
    assert resolve(tm, "new/../docs/a.md", True).missing == "new"
    assert resolve(tm, "docs/new/x.md", True).missing == "docs/new"
    assert blob_query(2) == ("query($owner: String!, $name: String!, $o0: GitObjectID!, $o1: GitObjectID!) "
                             "{ repository(owner: $owner, name: $name) { "
                             "f0: object(oid: $o0) { ... on Blob { byteSize isBinary isTruncated text } } "
                             "f1: object(oid: $o1) { ... on Blob { byteSize isBinary isTruncated text } } } }")
    assert is_config("Docs/A.md", ({"docs/a.md"}, set())) and is_config("docs/n/x", (set(), {"docs/n"}))
    assert is_config("docs/n", (set(), {"docs/n"})) and not is_config("docs/nx", (set(), {"docs/n"}))
    assert is_config("src/x.ts", INCOMPLETE) and not is_config("src/x.ts", None)
```

- [ ] **Step 9: Run the selftest and the existing suite.**

Run: `/usr/bin/python3 -I scripts/needs-shipping.py --selftest`
Expected: `needs_shipping_selftest_ok`

Run: `bash tests/test-needs-shipping.sh`
Expected: every case passes. `classify()` does not call the walk yet, so nothing else changes.

- [ ] **Step 10: Commit.**

```bash
git add scripts/needs-shipping.py
git commit -m "feat(needs-shipping): add the agent-config import walk (#936)

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Wire the walk into routing, with stub-`gh` tests

**Files:**
- Modify: `scripts/needs-shipping.py` (module docstring at lines 2-25; `agent_config`, `skippable`, `needs_shipping` at lines 42-74; `classify` at lines 226-245)
- Modify: `tests/test-needs-shipping.sh` (stub at lines 29-62; `new_case` at lines 84-89; `run_case` at line 105; new section before line 283)

**Interfaces:**
- Consumes: `imported_config`, `is_config`, `INCOMPLETE` from Task 1.
- Produces: `skippable(path, imported=None)`, `needs_shipping(paths, records, imported=None)`. The defaults keep every existing selftest call valid.

- [ ] **Step 1: Routing.** Replace `skippable` and `needs_shipping` with:

```python
def skippable(path, imported=None):
    """True only for paths that cannot change what users get (ADR 0054 D2). Agent config is
    never skippable (ADR 0055): every later kicked agent reads it. That includes a file an
    agent-config file imports, and every path when the import walk is incomplete (#936)."""
    if is_config(path, imported):
        return False
    return (
        path.startswith("docs/")
        or ("/" not in path and path.endswith(".md"))
        or path.startswith(("__tests__/", "tests/"))
        or path.endswith((".test.ts", ".test.tsx"))
        or path == ".github/lighthouse.baseline.json"
    )
```

```python
def needs_shipping(paths, records, imported=None):
    """`records` is the number of file records GitHub returned (a rename is one
    record but two paths), so the cap is compared against records, not paths."""
    if files_incomplete(records):
        return True
    return not all(skippable(p, imported) for p in paths)
```

In `classify()`, replace the two lines from `paths, records = ...` through `shipping = ...` with:

```python
    paths, records = changed_paths(repo, pr) if names else ([], 0)
    imported = imported_config(repo, (head, tip)) if names else None
    shipping = bool(names) and needs_shipping(paths, records, imported)
```

and the `agent_config_edited` tuple entry with:

```python
              ("agent_config_edited", int(imported is INCOMPLETE or any(is_config(p, imported) for p in paths))),
```

`is_config` and `imported_config` are defined after `skippable` in the file. That is fine: names resolve at call time.

- [ ] **Step 2: Docstrings.** In the module docstring, replace the sentence ending `... are never\nskippable.` (lines 8-10) with:

```text
must be landed by Cursor Cloud Shipping, so pr-grind must not merge it. Agent-config
paths (`.cursor`, `.claude`, `.codex`, `.agents`, AGENTS.md, CLAUDE.md, ...) are never
skippable, and neither is a file they import with `@path`, followed transitively at the PR
head and `base_tip`. A walk that cannot finish makes every changed path agent config (#936).
```

In `agent_config`'s docstring, append: `Files those paths import are added by is_config() (#936).`

- [ ] **Step 3: Test stub.** In `tests/test-needs-shipping.sh`, extend the fixture comment block (lines 29-34) with:

```bash
#   rtree-<sha>[.rc]       `gh api .../git/trees/<sha>?recursive=1` body [and exit code];
#                          rtree-default when absent. rhang delays only these calls.
#   blob-<sha>             GraphQL Blob node served for variable o<N>=<sha>; gql-body overrides the whole reply
```

Insert these two arms into the stub's `case "$*" in`, BEFORE the existing `"api repos/o/r/git/trees/"*)` arm:

```bash
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
```

In `new_case()`, add a final line:

```bash
  printf '{"sha":"x","url":"x","tree":[],"truncated":false}\n' > "$FIX/rtree-default"
```

In `run_case()`, change the classifier invocation to `"$PY" -I "${SCRIPT_RUN:-$SCRIPT}" o/r 42 "$HEAD"`, so a case can run a patched copy.

- [ ] **Step 4: Fixture builder and helpers.** Insert after the `plain()` helper (line 99):

```bash
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
```

After `ship()` is defined (line 73), add `AC=$(ship CLEAN verify-site 1)`.

- [ ] **Step 5: Walk cases.** Insert before `out=$("$PY" -I "$SCRIPT" o/r 42 abc ...)` (line 283):

```bash
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
```

`$TMP/needs-shipping-fast.py` is the GH_TIMEOUT=1 copy built near the top of the file; it carries the walk too.

- [ ] **Step 6: Run the suite.**

Run: `bash tests/test-needs-shipping.sh`
Expected: `needs-shipping: N passed, 0 failed`. Every pre-existing case keeps its output: their default recursive trees are empty, so their walks find nothing.

Run: `shellcheck --severity=warning tests/test-needs-shipping.sh` (the CI severity)
Expected: no new warnings. If `SCRIPT_RUN=... run_case` draws SC2097/SC2098, add a `# shellcheck disable=` line with the reason, as the file already does for SC2016.

- [ ] **Step 7: Commit.**

```bash
git add scripts/needs-shipping.py tests/test-needs-shipping.sh
git commit -m "feat(needs-shipping): count imported files as agent config (#936)

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Timeouts, prose and ADR

**Files:**
- Modify: `scripts/shipping-kick.py:89`
- Modify: `tests/test-shipping-kick.sh:31-32`
- Modify: `skills/pr-grind/references/completion.md:571-573`, `:605-609`
- Modify: `skills/pr-grind/SKILL.md:83`
- Modify: `tests/test-needs-shipping.sh` (prose section, before the final `echo`)
- Modify: `docs/adr/0055-pr-grind-shipping-kick.md` (Status block, Consequences)

**Interfaces:**
- Consumes: the walk's worst case, 600s (`WALK_DEADLINE`, Task 1).

- [ ] **Step 1: Kicker timeout.** Replace `scripts/shipping-kick.py:89` with:

```python
# Classifier worst case: 8 gh calls x GH_TIMEOUT (960s) + its 600s import walk (#936) = 1560s.
# Kicker worst case: this 1700s + 11 more gh calls x 120s + 3 x 10s of UNKNOWN retries = 3050s,
# under the 3300000 ms Bash timeout completion.md states for the kick.
CLASSIFIER_TIMEOUT = 1700  # above the classifier's 1560s worst case
```

- [ ] **Step 2: Kicker test follows the literal.** In `tests/test-shipping-kick.sh:31`, change the `sed` expression to `'s/^CLASSIFIER_TIMEOUT = 1700 /CLASSIFIER_TIMEOUT = 1 /'`. Line 32's grep still checks `'^CLASSIFIER_TIMEOUT = 1 '`.

- [ ] **Step 3: completion.md.** In the routing paragraph (line 571), change `... `CLAUDE.md`, `CLAUDE.local.md` and `.mcp.json` are never skipped)` to:

```text
`CLAUDE.md`, `CLAUDE.local.md` and `.mcp.json` are never skipped, and neither is a file those agent-config files import with `@path` (#936))
```

In the same paragraph, after the sentence ending `... so a short or wrong SHA exits 1.`, add:

```text
Run it with a Bash timeout of 1800000 ms: its import walk can take up to 600s, about 1560s in all (#936).
```

In the kick section, after `It runs the classifier itself and applies every other gate.`, add:

```text
Run it with a Bash timeout of 3300000 ms: its worst case is about 3050s (#936). An interrupted kick can still have posted; a re-run dedupes on the head marker.
```

- [ ] **Step 4: SKILL.md.** In `skills/pr-grind/SKILL.md:83`, change `(docs, root `*.md`, tests; agent-config paths are never skipped)` to:

```text
(docs, root `*.md`, tests; agent-config paths, and files an agent-config file imports with `@path`, are never skipped)
```

- [ ] **Step 5: Prose tests.** In `tests/test-needs-shipping.sh`, insert before the final `echo`:

```bash
t "classifier call states its Bash timeout" has "$ROUTE_TEXT" 'Run it with a Bash timeout of 1800000 ms'
t "kicker call states its Bash timeout" has "$KICK_TEXT" 'Run it with a Bash timeout of 3300000 ms'
t "routing names imported files" has "$ROUTE_TEXT" 'import with `@path` (#936)'
t "SKILL.md names imported files" grep -qF 'files an agent-config file imports with `@path`' "$SKILL"
t "kicker CLASSIFIER_TIMEOUT is 1700" grep -q '^CLASSIFIER_TIMEOUT = 1700 ' scripts/shipping-kick.py
```

Each literal that holds backticks needs the file's existing `# shellcheck disable=SC2016` comment on the line above.

- [ ] **Step 6: ADR 0055.** Directly under the `# ADR 0055 — ...` title, add:

```markdown
> **Amended (2026-10-12, #936).** Agent config also includes every path reached through `@path`
> imports from agent-config files at the PR head or `base_tip` (`scripts/needs-shipping.py` import
> walk; spec `docs/specs/2026-10-11-shipping-imported-agent-config-design.md`). A walk that cannot
> finish (a symlink, a directory, absolute or home mention, a gitlink, a binary, a mention that
> leaves the repo — including a `../` mention in a Cursor-read file, which Cursor may also resolve
> from the repo root — a limit, or the 600s walk deadline) makes every changed path agent config instead of exiting 1, so the PR lands
> by hand through the ADR 0054 D4 escape. Symlinks and directories are not resolved. The walk
> runs between the classifier's two reads of head and base, so a push during a slow walk makes
> it exit 1, as before.
> `CLASSIFIER_TIMEOUT` rises to 1700s.
```

At the end of `## Consequences`, add:

```markdown
- (#936) A docs-only PR that edits a file `CLAUDE.md`, an agent rule or a skill imports now routes to
  Shipping with `agent_config_edited=1`, and needs the D4 hand landing. A repo that adds a symlink,
  a live directory mention or a leading-`/` mention in a Cursor-read file hand-lands every PR until
  the walk learns to resolve it; on 2026-10-11 none of the three opted-in repos had one.
```

- [ ] **Step 7: Run every affected suite.**

Run: `bash tests/test-needs-shipping.sh && bash tests/test-shipping-kick.sh && /usr/bin/python3 -I scripts/needs-shipping.py --selftest`
Expected: both suites report 0 failed, and the selftest prints `needs_shipping_selftest_ok`.

- [ ] **Step 8: Commit.**

```bash
git add scripts/shipping-kick.py tests/test-shipping-kick.sh skills/pr-grind/references/completion.md skills/pr-grind/SKILL.md tests/test-needs-shipping.sh docs/adr/0055-pr-grind-shipping-kick.md
git commit -m "docs(pr-grind): document imported agent config and the longer classifier timeout (#936)

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

- [ ] **Step 9: File the deferred follow-up, before the PR is opened.**

```bash
gh issue create --title "needs-shipping: by-name directory matching for Cursor-read files" --body "Follow-up from #936. A live token that resolves to a directory, including a Cursor-read file naming one by its bare name, makes the import walk incomplete, so every PR in that repo hand-lands. That fails closed on purpose; do not drop directories from the by-name index. On 2026-10-12 no opted-in repo had such a token. If one appears, walk the directory's instruction files instead of hand-landing."
```

Link the new issue number from the PR body ("Deferred: #N").

---

## Spec coverage

| Spec section | Task |
|---|---|
| §1 When it runs (opted-in only, same branch of `classify()`) | 2 (Step 1), test "not opted in makes no walk calls" |
| §2 Two revisions, recursive tree map, truncated → incomplete | 1 (`tree_map`), 2 (tests) |
| §3 Entries, readers, `resolve()` | 1 (`reader`, `resolve`, selftest), 2 (tests) |
| §4 Tokens, candidates, liveness, candidate rules | 1 (`parse`, `candidates`, `candidate_targets`), 2 (tests) |
| §5 Walking, depth, cache, fetching, limits | 1 (`walk`, `Fetcher`, `take`, the token budget in `parse`), 2 (tests) |
| §6 Effect, incomplete list | 1 (`is_config`), 2 (Step 1, tests) |
| §7 Timeouts | 1 (`Clock`, `walk_gh_json`, deadline checks in `walk`), 3 (Steps 1-3) |
| §8 Docs | 2 (Step 2), 3 (Steps 3-6) |
| Testing | 1 (Step 8, including the seeded parser fuzz), 2 (Step 5), 3 (Step 5) |
| Open item: by-name directory match for Cursor-read files | Deferred; Task 3 Step 9 files the follow-up issue |

<!-- design-review-coverage: DEGRADED 2/3 reviewer_3=runtime-failed -->

<!-- design-reviewed: PENDING -->
