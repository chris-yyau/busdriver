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
CONTROL = re.compile(r"[\x00-\x1f\x7f\u2028\u2029]")  # raw string: re reads the escapes, nothing invisible in source
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
   c. Run exactly this, with the literal H replaced by H's 40-hex SHA (never pass the letter H): gh pr merge %(N)s -R %(repo)s --squash --delete-branch --match-head-commit H
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
