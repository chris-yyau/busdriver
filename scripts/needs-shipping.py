#!/usr/bin/env python3
"""needs-shipping.py — decide whether a clean pr-grind stops at Ready for Shipping.

ADR 0054, amended by ADR 0055. A repo opts in by carrying a `.cursor/skills/verify-*/`
directory in the tree of its base branch's LIVE tip (`base_tip`, read from GitHub; never
the PR head, the checkout, or the cached `baseRefOid`, which does not track the base).
In an opted-in repo, a PR whose changed paths are not all on the built-in skip list
must be landed by Cursor Cloud Shipping, so pr-grind must not merge it. Agent-config
paths (`.cursor`, `.claude`, `.codex`, `.agents`, AGENTS.md, CLAUDE.md, ...) are never
skippable, and neither is a file they import with `@path`, followed transitively at the PR
head and `base_tip`. A walk that cannot finish makes every changed path agent config (#936), and
so does a JSON, JSONC, TOML or YAML file in an agent directory or any `.mcp.json`
(`.cursor/environment.json` exempt), a hook, MCP server, LSP server, monitor or settings key or
unreadable frontmatter in agent Markdown, a `!` command in a skill or command body, or a `!` or
backtick in a skill or command path, any of which can run a repo file (#950).

Usage:
    /usr/bin/python3 -I needs-shipping.py <owner>/<repo> <PR_NUMBER> <REVIEWED_HEAD>

stdout / exit:
    merge                                    0   continue to the clean marker + merge path
    shipping mergeStateStatus=<STATE> base_ref=<name> base_tip=<40-hex> skills=<a,b|->
      agent_config_edited=<0|1> files_incomplete=<0|1> author=<login|-> cross_repo=<0|1>
                                             10  Ready for Shipping (one line): no marker, no merge
    error: <reason>                          1   the dispatcher BAILs env and never merges

Fails closed: any API error, unparseable response, invalid field, or a head/base that
moves while classifying exits 1. Kept Python 3.9-compatible (macOS /usr/bin/python3).
"""
import collections
import json
import os
import posixpath
import re
import subprocess
import sys
import time

FILES_CAP = 3000  # GitHub's pulls/<n>/files limit, in file RECORDS; at the cap the list may be truncated
AGENT_DIRS = (".cursor", ".claude", ".codex", ".agents")
AGENT_FILES = ("agents.md", "claude.md", "claude.local.md", ".mcp.json",
               ".cursorrules", ".cursorignore", ".cursorindexingignore")
# `@` only after a word char: after `/`, `.` or `-` GitHub would autolink it as a mention in the posted comment
BASE_REF_RE = r"[A-Za-z0-9_](?:[A-Za-z0-9._/+=-]|(?<=[A-Za-z0-9_])@)*"
SKILL_RE = r"verify-[A-Za-z0-9][A-Za-z0-9._-]*"
LOGIN_RE = r"[A-Za-z0-9][A-Za-z0-9/_.\[\]-]*"


def agent_config(path):
    """True for a path Cursor or Claude Code may load as agent configuration (ADR 0055):
    any `.cursor`/`.claude`/`.codex`/`.agents` component, or one of AGENT_FILES as the
    basename, at any depth. Case-insensitive, so a case variant errs toward refusing.
    Files those paths import are added by is_config() (#936)."""
    parts = path.lower().split("/")
    return any(p in AGENT_DIRS for p in parts) or parts[-1] in AGENT_FILES


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


def files_incomplete(records):
    """The listing may be incomplete: none returned, or GitHub's cap reached."""
    return records == 0 or records >= FILES_CAP


def needs_shipping(paths, records, imported=None):
    """`records` is the number of file records GitHub returned (a rename is one
    record but two paths), so the cap is compared against records, not paths."""
    if files_incomplete(records):
        return True
    return not all(skippable(p, imported) for p in paths)


class Fail(Exception):
    pass


GH_TIMEOUT = 120  # seconds per gh call; a hung request fails closed instead of stalling the grind
# Routing/output hygiene, not containment: drops GH_REPO, GH_DEBUG, GH_PAGER, GH_FORCE_TTY and the like. A committed
# env block can still swap gh identity or config via GH_TOKEN, HOME, XDG_CONFIG_HOME or PATH (ADR 0026 residual).
GH_ENV_KEEP = ("GH_TOKEN", "GITHUB_TOKEN", "GH_CONFIG_DIR")
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


def gh_env():
    env = {k: v for k, v in os.environ.items() if not k.startswith(("GH_", "GITHUB_")) or k in GH_ENV_KEEP}
    env["GH_HOST"] = "github.com"
    return env


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


def nonempty_str(v):
    return isinstance(v, str) and bool(v)


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


def subtree_sha(repo, sha, name):
    """Look up directory `name` among the tree entries of `sha`. Absence is decided from
    a SUCCESSFUL listing, never from a 404."""
    for e in tree_entries(repo, sha):
        if e["type"] == "tree" and e["path"] == name:
            if not nonempty_str(e.get("sha")):
                raise Fail("tree entry %s without a sha" % e["path"])
            return e["sha"]
    return None


def tree_entries(repo, sha):
    """The validated entry list of tree `sha`; any malformed entry fails closed."""
    body = gh_json(["api", "repos/%s/git/trees/%s" % (repo, sha)])
    well_formed = isinstance(body, dict) and body.get("truncated") is False and isinstance(body.get("tree"), list)
    if not well_formed:
        raise Fail("unexpected trees response for %s" % sha)
    if not all(well_formed_entry(e) for e in body["tree"]):
        raise Fail("malformed tree entry in %s" % sha)
    return body["tree"]


def well_formed_entry(e):
    return isinstance(e, dict) and isinstance(e.get("type"), str) and isinstance(e.get("path"), str)


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


STRUCTURED_EXTS = (".json", ".jsonc", ".toml", ".yaml", ".yml")
FM_KEY_RE = re.compile(r"([A-Za-z_][A-Za-z0-9_-]*)[ \t]*:")
FM_RUN_KEYS = ("hooks", "mcpServers", "lspServers", "monitors", "settings")  # keys Claude Code 2.1.296 knows that can start a process
DOLLAR_RUN_RE = re.compile(r"\$[^\s\ufeff`!]*")  # wider than any $-placeholder; keeps every boundary, backtick and !
INLINE_SHELL_RE = re.compile(r"(?:^|(?<=[\s\ufeff\x00]))!\x00*`", re.M)  # \x00: a placeholder, empty or whitespace


def structured_config(path):
    """#950: a JSON/TOML/YAML file in an agent directory, or any `.mcp.json`, can declare a hook,
    MCP server, helper or plugin that runs a repo file, so its presence makes the walk incomplete.
    `.cursor/environment.json` is exempt: it configures the cloud VM, which runs repo code anyway."""
    # keep-simple(UPGRADE: parse declared commands and add the scripts they name to the imported set once an opted-in repo needs structured agent config)
    parts = path.lower().split("/")
    if parts[-2:] == [".cursor", "environment.json"]:
        return False
    return parts[-1] == ".mcp.json" or (any(p in AGENT_DIRS for p in parts) and parts[-1].endswith(STRUCTURED_EXTS))


def md_lines(text):
    return text.replace("\r\n", "\n").replace("\r", "\n").split("\n")


def frontmatter_block(text):
    """The lines between the opening `---` and the closing one (or end of file), else None."""
    lines = md_lines(text[1:] if text.startswith("\ufeff") else text)
    start = next((k for k, ln in enumerate(lines) if ln.strip()), None)
    if start is None or lines[start].strip() != "---":  # an indented opener is read too: only adds trips
        return None
    body = lines[start + 1:]
    # close only on what a YAML reader closes on; `...` never closes
    end = next((k for k, ln in enumerate(body) if ln.rstrip(" \t") == "---"), len(body))
    return body[:end]


def frontmatter_trips(text):
    """#950 §2.1: a reason when YAML frontmatter may declare `hooks` or `mcpServers`, else None.
    Only plain column-0 keys are read; any other spelling YAML allows trips as unreadable."""
    keys = [ln for ln in frontmatter_block(text) or () if ln.strip() and not ln.startswith("#")]
    if keys and keys[0][0] in " \t":  # an indented top level is legal YAML the column-0 rule would never read
        return "unreadable frontmatter"
    return next(filter(None, map(fm_key_trips, (k for k in keys if k[0] not in " \t"))), None)


def fm_key_trips(ln):
    """The frontmatter_trips reason for one column-0 frontmatter line, else None."""
    m = FM_KEY_RE.match(ln)
    if not m:
        return "unreadable frontmatter"
    return "hook or MCP server in frontmatter" if m.group(1) in FM_RUN_KEYS else None


def injects_shell(text):
    """#950 §2.2: a `!` command Claude Code may run before a skill or command reaches the model:
    inline `!`cmd` at a word start, or a ```! fence wherever it opens (Claude Code 2.1.296).
    `$` placeholders are substituted first and may become empty or whitespace, so each `$` run
    becomes a sentinel that counts as either."""
    t = DOLLAR_RUN_RE.sub("\x00", text)
    return "```!" in t.replace("\x00", "") or bool(INLINE_SHELL_RE.search(t))


def shell_scope(path):
    return any(p in ("skills", "commands") for p in path.lower().split("/"))


def shell_path(path):
    """#950: `${CLAUDE_SKILL_DIR}`, `${CLAUDE_PLUGIN_ROOT}` and the skill's base-directory prefix put
    the path in the text Claude Code scans for `!`, and every marker needs a `!` or a backtick."""
    return shell_scope(path) and ("!" in path or "`" in path)


def tree_trips(kind, path):
    """Raise Incomplete when a tree entry alone can run a repo file (#950); no blob is fetched."""
    if kind == "blob" and structured_config(path):  # tree-only: no blob is fetched for it (#950 §3)
        raise Incomplete("structured agent config")
    if shell_path(path):  # the path itself reaches the `!` scan (#950)
        raise Incomplete("`!` or backtick in a skill path")


def markdown_trips(path, text):
    """Raise Incomplete when depth-0 agent Markdown can run a repo file (#950)."""
    reason = frontmatter_trips(text)
    if reason:
        raise Incomplete(reason)
    if shell_scope(path) and injects_shell(text):
        raise Incomplete("skill shell injection")


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

def lookup(tmap, prefix, live):
    """The tree entry at `prefix`; DROPPED for a symlink outside the live set, Incomplete inside it."""
    entry = tmap.get(prefix)
    if entry and entry[1] == SYMLINK:
        # keep-simple(UPGRADE: resolve link targets if an opted-in repo needs symlinks)
        if live:
            raise Incomplete("symlink")
        return DROPPED
    return entry

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
        entry = lookup(tmap, prefix, live)
        if entry is DROPPED:
            return Res(DROPPED, False, None, [])
        if entry and entry[0] == "commit":
            gitlinks.append(prefix)
        if entry is None and missing is None and "commit" not in kinds:
            missing = prefix
        kinds.append(entry[0] if entry else None)
    if not stack:
        return Res(ROOT, False, missing, gitlinks)
    return Res("/".join(stack), "commit" in kinds, missing, gitlinks)

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


def para_tokens(para, budget, toks, limit):
    """Append the tokens of one paragraph to `toks` (#936 §4); return the token-text budget left."""
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
    return budget


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
        budget = para_tokens(para, budget, toks, limit)
        para = []
    return toks

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


def entry_level(tmaps, exact):
    """The walk's first level: (rev, path, reader) for each agent-config instruction blob (#936 §5)."""
    level = []
    for rev, tmap in tmaps.items():
        for path, (kind, mode, _sha, _size) in tmap.items():
            if not agent_config(path):
                continue
            if mode == SYMLINK:
                raise Incomplete("symlinked agent-config path")
            if kind == "commit":  # a submodule's instruction files are not in this tree to walk
                raise Incomplete("gitlink at an agent-config path")
            tree_trips(kind, path)
            if kind == "blob" and instruction_file(path):
                exact.add(path)
                level.append((rev, path, reader(path)))
    return level


def file_targets(tmap, names, path, rd, toks, clock, exact, cover):
    """Blob paths imported by one parsed file at `path`, recording every candidate in the sets (#936 §5).
    A generator: the caller handles each target before the next candidate is resolved."""
    for cands, in_span, quoted in toks:
        live = rd != "claude" or not (in_span or quoted)
        for c in cands:
            clock.remaining()  # per candidate: by-name matches can fan one out to many resolves
            for res in candidate_targets(tmap, names, path, c, live, rd):
                clock.remaining()
                target = take(tmap, res, live, exact, cover)
                if target is not None:
                    yield target


def walk(repo, revs, clock):
    """Exact and cover path sets reached through imports from agent-config entries at `revs`
    (#936 §5). Raises Incomplete when the walk cannot finish."""
    tmaps = {}
    for rev in revs:
        tmaps[rev] = tree_map(repo, rev, clock)
    names = suffix_index(set().union(*tmaps.values()))
    exact, cover = set(), set()
    level = entry_level(tmaps, exact)
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
            if depth == 0:  # per path, not per sha: shell_scope depends on where the text sits (#950)
                markdown_trips(path, texts[sha])
            if sha not in parsed:
                parsed[sha] = parse(texts[sha], MAX_TOKENS - ntok)  # one budget for the whole walk
                ntok += len(parsed[sha])
            for target in file_targets(tmaps[rev], names, path, rd, parsed[sha], clock, exact, cover):
                key = (rev, target, rd)
                if key in visited:
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


def verify_skills(repo, tip):
    """Sorted `verify-*` directory names directly under `tip`'s `.cursor/skills/`; an
    empty list means the repo has not opted in."""
    cursor = subtree_sha(repo, tip, ".cursor")
    skills = cursor and subtree_sha(repo, cursor, "skills")
    if not skills:
        return []
    found = [e for e in tree_entries(repo, skills)
             if e["type"] == "tree" and e["path"].startswith("verify-")]  # bare `verify-` opts in; skills_field rejects it
    if not all(nonempty_str(e.get("sha")) for e in found):
        raise Fail("verify-* tree entry without a sha")
    return sorted(e["path"] for e in found)


def skills_field(names):
    """Comma-joined names, or `-` when any name is unusable (opts in, blocks the kick)."""
    return ",".join(names) if all(re.fullmatch(SKILL_RE, n) for n in names) else "-"


def changed_paths(repo, pr):
    out = gh(["api", "--paginate", "-X", "GET", "-F", "per_page=100",
              "repos/%s/pulls/%s/files" % (repo, pr), "--jq", ".[] | {filename, previous_filename}"])
    paths, records = [], 0
    # Split on "\n" only: compact JSON escapes newlines inside strings, so "\n" always
    # separates records (str.splitlines would also split on U+2028 inside a filename).
    for line in out.split("\n"):
        if line.strip():
            records += 1
            paths.extend(record_paths(line))
    return paths, records


def record_paths(line):
    """The filename (plus previous_filename on a rename) of one files record."""
    obj = files_record(line)
    prev = obj.get("previous_filename")
    if prev is None:
        return [obj["filename"]]  # null on every non-renamed file
    if not nonempty_str(prev):
        raise Fail("files entry with a malformed previous_filename")
    return [obj["filename"], prev]


def files_record(line):
    """One decoded files record; it must be an object carrying a filename."""
    try:
        obj = json.loads(line)
    except ValueError:
        raise Fail("unparseable files line")
    if not (isinstance(obj, dict) and nonempty_str(obj.get("filename"))):
        raise Fail("files entry without a filename")
    return obj


def classify(repo, pr, head):
    first = pr_view(repo, pr)
    if first["headRefOid"] != head:
        raise Fail("head moved after classification; re-run /pr-grind")
    ref = first["baseRefName"]
    tip = base_tip(repo, ref)
    names = verify_skills(repo, tip)
    paths, records = changed_paths(repo, pr) if names else ([], 0)
    imported = imported_config(repo, (head, tip)) if names else None
    shipping = bool(names) and needs_shipping(paths, records, imported)
    last = pr_view(repo, pr)
    if last["headRefOid"] != head or last["baseRefName"] != ref or base_tip(repo, ref) != tip:
        raise Fail("head or base moved while classifying; re-run /pr-grind")
    if not shipping:
        return "merge", 0
    fields = (("base_ref", ref), ("base_tip", tip), ("skills", skills_field(names)),
              ("agent_config_edited", int(imported is INCOMPLETE or any(is_config(p, imported) for p in paths))),
              ("files_incomplete", int(files_incomplete(records))),
              ("author", last["author"]), ("cross_repo", int(last["isCrossRepository"])))
    return "shipping mergeStateStatus=%s %s" % (
        last["mergeStateStatus"], " ".join("%s=%s" % f for f in fields)), 10


ARG_PATTERNS = (r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", r"[0-9]+", r"[0-9a-f]{40}")


def valid_args(argv):
    return len(argv) == len(ARG_PATTERNS) and all(re.fullmatch(p, a) for p, a in zip(ARG_PATTERNS, argv))


def main(argv):
    if not valid_args(argv):
        print("error: usage: needs-shipping.py <owner>/<repo> <PR_NUMBER> <40-hex REVIEWED_HEAD>")
        return 1
    try:
        line, code = classify(*argv)
    except Exception as e:  # fail closed on anything, including bugs
        print("error: %s" % e)
        return 1
    print(line)
    return code


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
