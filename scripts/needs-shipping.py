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

FILES_CAP = 3000  # GitHub's pulls/<n>/files hard limit; at the cap the list may be truncated


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


def needs_shipping(paths):
    if not paths or len(paths) >= FILES_CAP:
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


def pr_view(repo, pr):
    d = gh_json(["pr", "view", pr, "-R", repo, "--json", "headRefOid,baseRefOid,mergeStateStatus"])
    if not isinstance(d, dict) or not all(isinstance(d.get(k), str) and d.get(k) for k in ("headRefOid", "baseRefOid")):
        raise Fail("gh pr view returned no head/base OID")
    state = d.get("mergeStateStatus")
    d["mergeStateStatus"] = state if isinstance(state, str) and re.fullmatch(r"[A-Z_]+", state) else "UNKNOWN"
    return d


def subtree_sha(repo, sha, name, prefix=False):
    """Look up `name` (or any entry starting with `name` when prefix) among the tree
    entries of `sha`. Absence is decided from a SUCCESSFUL listing, never from a 404."""
    body = gh_json(["api", "repos/%s/git/trees/%s" % (repo, sha)])
    if not isinstance(body, dict) or body.get("truncated") is not False or not isinstance(body.get("tree"), list):
        raise Fail("unexpected trees response for %s" % sha)
    for e in body["tree"]:
        if not isinstance(e, dict) or e.get("type") != "tree" or not isinstance(e.get("path"), str):
            continue
        if (e["path"].startswith(name) and len(e["path"]) > len(name)) if prefix else e["path"] == name:
            if not isinstance(e.get("sha"), str) or not e["sha"]:
                raise Fail("tree entry %s without a sha" % e["path"])
            return e["sha"]
    return None


def opted_in(repo, base):
    cursor = subtree_sha(repo, base, ".cursor")
    skills = cursor and subtree_sha(repo, cursor, "skills")
    return bool(skills and subtree_sha(repo, skills, "verify-", prefix=True))


def changed_paths(repo, pr):
    out = gh(["api", "--paginate", "-X", "GET", "-F", "per_page=100",
              "repos/%s/pulls/%s/files" % (repo, pr), "--jq", ".[] | {filename, previous_filename}"])
    paths = []
    # Split on "\n" only: compact JSON escapes newlines inside strings, so "\n" always
    # separates records (str.splitlines would also split on U+2028 inside a filename).
    for line in out.split("\n"):
        if not line.strip():
            continue
        try:
            obj = json.loads(line)
        except ValueError:
            raise Fail("unparseable files line")
        if not isinstance(obj, dict) or not isinstance(obj.get("filename"), str) or not obj["filename"]:
            raise Fail("files entry without a filename")
        paths.append(obj["filename"])
        prev = obj.get("previous_filename")
        if prev is None:
            continue  # null on every non-renamed file
        if not isinstance(prev, str) or not prev:
            raise Fail("files entry with a malformed previous_filename")
        paths.append(prev)
    return paths


def classify(repo, pr, head):
    first = pr_view(repo, pr)
    if first["headRefOid"] != head:
        raise Fail("head moved after classification; re-run /pr-grind")
    base = first["baseRefOid"]
    decision = "shipping" if opted_in(repo, base) and needs_shipping(changed_paths(repo, pr)) else "merge"
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
                   ["x/docs/a.md"], ["docs/a.md"] * FILES_CAP):
        assert needs_shipping(routed), routed
    for skipped in (["docs/a/b.md", "README.md"], [".claude/CLAUDE.md"], ["client/x.test.tsx"],
                    [".github/lighthouse.baseline.json"], ["tests/e2e/a.spec.ts", "__tests__/b.js"]):
        assert not needs_shipping(skipped), skipped
    print("needs_shipping_selftest_ok")


def main(argv):
    if argv == ["--selftest"]:
        selftest()
        return 0
    if (len(argv) != 3 or not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", argv[0])
            or not re.fullmatch(r"[0-9]+", argv[1]) or not re.fullmatch(r"[0-9a-f]{40}", argv[2])):
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
