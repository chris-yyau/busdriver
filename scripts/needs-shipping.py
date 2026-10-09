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
import json
import os
import re
import subprocess
import sys

FILES_CAP = 3000  # GitHub's pulls/<n>/files limit, in file RECORDS; at the cap the list may be truncated
AGENT_DIRS = (".cursor", ".claude", ".codex", ".agents")
AGENT_FILES = ("agents.md", "claude.md", "claude.local.md", ".mcp.json",
               ".cursorrules", ".cursorignore", ".cursorindexingignore")
BASE_REF_RE = r"[A-Za-z0-9_][A-Za-z0-9._/-]*"
SKILL_RE = r"verify-[A-Za-z0-9][A-Za-z0-9._-]*"
LOGIN_RE = r"[A-Za-z0-9][A-Za-z0-9/_.\[\]-]*"


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


class Fail(Exception):
    pass


def gh(args):
    env = dict(os.environ, GH_HOST="github.com")
    env.pop("GH_REPO", None)
    try:
        r = subprocess.run(["gh"] + args, capture_output=True, text=True, env=env)
    except OSError as e:
        raise Fail("gh not runnable: %s" % e)
    if r.returncode != 0:
        raise Fail("gh %s failed (rc=%d): %s" % (" ".join(args[:2]), r.returncode, r.stderr.strip()[:200]))
    return r.stdout


def gh_json(args):
    try:
        return json.loads(gh(args))
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


def verify_skills(repo, tip):
    """Sorted `verify-*` directory names directly under `tip`'s `.cursor/skills/`; an
    empty list means the repo has not opted in."""
    cursor = subtree_sha(repo, tip, ".cursor")
    skills = cursor and subtree_sha(repo, cursor, "skills")
    if not skills:
        return []
    found = [e for e in tree_entries(repo, skills)
             if e["type"] == "tree" and e["path"].startswith("verify-") and len(e["path"]) > len("verify-")]
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
              ".cursorignore", "web/.cursorindexingignore", ".Claude/x.md", "CLAUDE.local.md",
              "apps/web/CLAUDE.local.md", ".mcp.json"):
        assert agent_config(p), p
    for p in ("src/skills/x.ts", "docs/claude/skills.md", "src/my.claude.ts", ".gitignore", "src/claude.md.bak"):
        assert not agent_config(p), p
    assert skills_field(["verify-a", "verify-b"]) == "verify-a,verify-b"
    assert skills_field(["verify-a", "verify-a$b"]) == "-"
    print("needs_shipping_selftest_ok")


ARG_PATTERNS = (r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", r"[0-9]+", r"[0-9a-f]{40}")


def valid_args(argv):
    return len(argv) == len(ARG_PATTERNS) and all(re.fullmatch(p, a) for p, a in zip(ARG_PATTERNS, argv))


def main(argv):
    if argv == ["--selftest"]:
        selftest()
        return 0
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
