#!/usr/bin/env python3
"""kody-waiver.py — decide and record the ADR 0064 Kody licensing waiver in one process.

Completion runs it only after the ledger read `kody-ai=skipped-unlicensed` (Kody skipped a
Cursor-bot PR for lack of a Kodus seat). It grants the waiver only for a documentation-only
PR (`needs-shipping.py` docs_only, ADR 0064 D9) and writes ONE fixed-shape
`kody-unlicensed-skip-waived` event to the main checkout's `.claude/bypass-log.jsonl`
through the gate lib's hardened `audit_append` (D10). Nothing reads that event as authority.

Usage:
    cd <grind worktree> && /usr/bin/python3 -I kody-waiver.py <owner>/<repo> <PR_NUMBER> <40-hex HEAD>

stdout / exit:
    waived                          0   the record was appended
    not-docs-only | incomplete      10  nothing written; Kody must review
    error: <reason>                 1   nothing written (or the append failed); fail closed

The state dir is the constant `.claude` (BUSDRIVER_STATE_DIR is not read, as in
design-clear.sh), and every git call runs with all GIT_* variables removed, so neither the
environment nor the repo can move the record. Kept Python 3.9-compatible.
"""
import sys

sys.dont_write_bytecode = True  # leave no .pyc under the gate lib

import importlib.util  # noqa: E402
import json  # noqa: E402
import os  # noqa: E402
import re  # noqa: E402
import subprocess  # noqa: E402
import time  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
STATE_DIR = ".claude"


def load_classifier():
    spec = importlib.util.spec_from_file_location("needs_shipping", os.path.join(HERE, "needs-shipping.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def git(*args):
    """stdout of one git call with every GIT_* variable removed, or None on failure. Bytes are
    decoded with os.fsdecode, not text mode, so a path keeps every byte (no \\r -> \\n translation)."""
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    try:
        r = subprocess.run(["git"] + list(args), capture_output=True, env=env, timeout=60)
    except (OSError, subprocess.TimeoutExpired):
        return None
    return os.fsdecode(r.stdout) if r.returncode == 0 else None


def git_line(*args):
    """One-line git output without its newline (a path may end in spaces), or ""."""
    out = git(*args) or ""
    return out[:-1] if out.endswith("\n") else out


def main_root():
    """The main checkout, resolved as scripts/advisory-downgrade-optin.sh resolves it; None fails closed.
    `-z` (git >= 2.36) keeps a path with a tab, quote or newline byte-exact instead of C-quoted."""
    wt = git("worktree", "list", "--porcelain", "-z")
    first = next((f[len("worktree "):] for f in (wt or "").split("\0") if f.startswith("worktree ")), "")
    if not first:
        return None
    if git_line("-C", first, "rev-parse", "--is-inside-work-tree") == "true":
        return first
    # --separate-git-dir: the porcelain names the git dir; recover only when this IS the main worktree.
    gd = git_line("rev-parse", "--path-format=absolute", "--git-dir")
    gcd = git_line("rev-parse", "--path-format=absolute", "--git-common-dir")
    if gd and gd == gcd:
        return git_line("rev-parse", "--show-toplevel") or None
    return None


def main(argv):
    ns = load_classifier()
    if not (ns.valid_args(argv) and re.fullmatch(r"[1-9][0-9]*", argv[1])):
        print("error: usage: kody-waiver.py <owner>/<repo> <PR_NUMBER> <40-hex HEAD>")
        return 1
    repo, pr, head = argv
    try:
        verdict = ns.docs_only(repo, pr, head)
    except Exception as e:  # fail closed on anything, including bugs
        print("error: %s" % e)
        return 1
    if verdict != "docs-only":
        print(verdict)
        return 10
    root = main_root()
    if not root:
        print("error: cannot resolve the main checkout")
        return 1
    record = json.dumps({
        "event": "kody-unlicensed-skip-waived", "gate": "pr-grind-completion",
        "pr": int(pr), "head_sha": head, "scope": "docs-only",
        "verified": "documentation-only diff at head_sha",
        "basis": "completion ledger read kody-ai=skipped-unlicensed", "adr": "0064",
        "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }, separators=(",", ":"))
    sys.path.insert(0, os.path.join(HERE, os.pardir, "hooks", "gate-scripts", "lib"))
    try:
        import audit_append
        os.chdir(root)
        ok = audit_append.append(STATE_DIR, record)
    except Exception as e:
        print("error: audit append failed: %s" % e)
        return 1
    if not ok:
        print("error: audit append refused")
        return 1
    print("waived")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
