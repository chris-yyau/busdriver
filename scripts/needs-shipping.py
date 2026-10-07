#!/usr/bin/env python3
"""needs-shipping.py — decide whether a clean pr-grind stops at Ready for Shipping.

ADR 0054. A repo opts in by carrying a `.cursor/skills/verify-*/` directory in the
PR's BASE commit tree (read from GitHub, never from the PR head or the checkout).
In an opted-in repo, a PR whose changed paths are not all on the built-in skip list
must be landed by Cursor Cloud Shipping, so pr-grind must not merge it.

Usage:
    /usr/bin/python3 -I needs-shipping.py <owner>/<repo> <PR_NUMBER> <REVIEWED_HEAD>
    needs-shipping.py --selftest

stdout / exit:
    merge                              0   continue to the clean marker + merge path
    shipping mergeStateStatus=<STATE> 10   Ready for Shipping: no marker, no merge
    error: <reason>                    1   the dispatcher BAILs env and never merges

Fails closed: any API error, unparseable response, or a head/base that moves while
classifying exits 1. Kept Python 3.9-compatible (macOS /usr/bin/python3).
"""
import json
import os
import re
import subprocess
import sys

FILES_CAP = 3000  # GitHub's pulls/<n>/files limit, in file RECORDS; at the cap the list may be truncated


def skippable(path):
    """True only for paths that cannot change what users get (ADR 0054 D2)."""
    return (
        path.startswith("docs/")
        or ("/" not in path and path.endswith(".md"))
        or (path.startswith(".claude/") and path.endswith(".md"))
        or path.startswith(("__tests__/", "tests/"))
        or path.endswith((".test.ts", ".test.tsx"))
        or path == ".github/lighthouse.baseline.json"
    )


def needs_shipping(paths, records):
    """`records` is the number of file records GitHub returned (a rename is one
    record but two paths), so the cap is compared against records, not paths."""
    if records == 0 or records >= FILES_CAP:
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
    d = gh_json(["pr", "view", pr, "-R", repo, "--json", "headRefOid,baseRefOid,mergeStateStatus"])
    has_oids = isinstance(d, dict) and nonempty_str(d.get("headRefOid")) and nonempty_str(d.get("baseRefOid"))
    if not has_oids:
        raise Fail("gh pr view returned no head/base OID")
    state = d.get("mergeStateStatus")
    d["mergeStateStatus"] = state if isinstance(state, str) and re.fullmatch(r"[A-Z_]+", state) else "UNKNOWN"
    return d


def subtree_sha(repo, sha, name, prefix=False):
    """Look up `name` (or any entry starting with `name` when prefix) among the tree
    entries of `sha`. Absence is decided from a SUCCESSFUL listing, never from a 404."""
    for e in tree_entries(repo, sha):
        if e["type"] == "tree" and name_matches(e["path"], name, prefix):
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
    for e in body["tree"]:
        if not (isinstance(e, dict) and isinstance(e.get("type"), str) and isinstance(e.get("path"), str)):
            raise Fail("malformed tree entry in %s" % sha)
    return body["tree"]


def name_matches(path, name, prefix):
    if prefix:
        return path.startswith(name) and len(path) > len(name)
    return path == name


def opted_in(repo, base):
    cursor = subtree_sha(repo, base, ".cursor")
    skills = cursor and subtree_sha(repo, cursor, "skills")
    return bool(skills and subtree_sha(repo, skills, "verify-", prefix=True))


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
    try:
        obj = json.loads(line)
    except ValueError:
        raise Fail("unparseable files line")
    if not (isinstance(obj, dict) and nonempty_str(obj.get("filename"))):
        raise Fail("files entry without a filename")
    prev = obj.get("previous_filename")
    if prev is None:
        return [obj["filename"]]  # null on every non-renamed file
    if not nonempty_str(prev):
        raise Fail("files entry with a malformed previous_filename")
    return [obj["filename"], prev]


def classify(repo, pr, head):
    first = pr_view(repo, pr)
    if first["headRefOid"] != head:
        raise Fail("head moved after classification; re-run /pr-grind")
    base = first["baseRefOid"]
    decision = "shipping" if opted_in(repo, base) and needs_shipping(*changed_paths(repo, pr)) else "merge"
    last = pr_view(repo, pr)
    if last["headRefOid"] != head or last["baseRefOid"] != base:
        raise Fail("head or base moved while classifying; re-run /pr-grind")
    if decision == "shipping":
        return "shipping mergeStateStatus=%s" % last["mergeStateStatus"], 10
    return "merge", 0


def selftest():
    for routed in (["src/app/page.tsx"], ["docs/a.md", "src/x.ts"], ["docs/a.ts", "src/a.ts"], [],
                   ["foo/README.md"], [".claude/settings.json"], [".cursor/skills/verify-x/SKILL.md"],
                   ["src/app/a.test.ts\ndocs/x"], [".github/lighthouse.baseline.json.bak"], ["docs"],
                   ["x/docs/a.md"]):
        assert needs_shipping(routed, len(routed)), routed
    assert needs_shipping(["docs/a.md"] * FILES_CAP, FILES_CAP)
    assert not needs_shipping(["docs/a.md", "docs/b.md"] * 1500, 1500)  # 1500 renames = 1500 records
    for skipped in (["docs/a/b.md", "README.md"], [".claude/CLAUDE.md"], ["client/x.test.tsx"],
                    [".github/lighthouse.baseline.json"], ["tests/e2e/a.spec.ts", "__tests__/b.js"]):
        assert not needs_shipping(skipped, len(skipped)), skipped
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
