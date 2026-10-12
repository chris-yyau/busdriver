"""Fetch prompt-matched Hindsight pages for a grok review, outside grok's sandbox.

Run by grok_hindsight_prefetch in resolve-cli.sh under `env -i` with the
preflight's PATH and HOME. argv[1] is the query (the head of the review
prompt). Prints the page text, or nothing. It runs the operator's own Hindsight
grok prompt hook once with a throwaway session id: page search only, with
seeding, session retain, survey and self-update forced off, so nothing is
written to Hindsight. Hindsight not installed prints nothing; a failed fetch
prints one stderr line. The exit status is always 0, so a memory miss never
blocks a review.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import uuid

CAP = 9500
# Hindsight's config file beats its env vars, and its nested override sections
# (harnesses, banks, paths, and any nesting of them) beat the top level, so
# these are set at the top and overwritten wherever they appear below it.
READ_ONLY = {
    "autoInject": "pages",
    "autoSeed": False,
    "retainSessions": False,
    "codebaseSurvey": False,
    "autoUpdate": False,
}


def checkout_root():
    # The same rule as grok-preflight.sh: the nearest ancestor holding .git.
    root = walk = os.path.realpath(os.getcwd())
    while walk and walk != os.sep:
        if os.path.exists(os.path.join(walk, ".git")):
            return walk
        walk = os.path.dirname(walk)
    return root


def inside(path, root):
    return path == root or path.startswith(root.rstrip(os.sep) + os.sep)


def force_read_only(node):
    if isinstance(node, dict):
        for key in node:
            if key in READ_ONLY:
                node[key] = READ_ONLY[key]
            else:
                force_read_only(node[key])
    elif isinstance(node, list):
        for item in node:
            force_read_only(item)


def read_only_config(home):
    try:
        with open(os.path.join(home, ".hindsight", "coding-agent.json"), encoding="utf-8") as f:
            cfg = json.load(f)
    except FileNotFoundError:
        cfg = {}
    if not isinstance(cfg, dict):
        raise ValueError("coding-agent.json is not an object")
    force_read_only(cfg)
    cfg.update(READ_ONLY)
    return cfg


def main():
    query = (sys.argv[1] if len(sys.argv) > 1 else "")[:2000].strip()
    home = os.environ.get("HOME", "")
    hook = os.path.join(home, ".hindsight", "coding-agents", "dist", "grok-hook.js")
    node = shutil.which("node")
    if not query or not home or not node or not os.path.isfile(hook):
        return
    # This runs unsandboxed with the operator's home: refuse a node or hook that
    # resolves into the checkout under review, which the branch controls.
    checkout = checkout_root()
    for exe in (node, hook):
        if inside(os.path.realpath(exe), checkout):
            print(f"grok-hindsight-prefetch: skipped: {exe} resolves into the reviewed checkout", file=sys.stderr)
            return
    event = {"prompt": query, "cwd": os.getcwd(), "sessionId": "busdriver-prefetch-" + uuid.uuid4().hex}
    try:
        with tempfile.TemporaryDirectory() as tmp:  # mode 0700: the copy holds the API token
            config = os.path.join(tmp, "coding-agent.json")
            with open(os.open(config, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600), "w", encoding="utf-8") as f:
                json.dump(read_only_config(home), f)
            env = {"PATH": os.environ.get("PATH", ""), "HOME": home, "HINDSIGHT_CONFIG": config}
            out = subprocess.run(
                [node, hook], input=json.dumps(event), capture_output=True, text=True, env=env, timeout=25
            ).stdout.strip()
        if not out:
            return  # no matching pages
        text = json.loads(out)["hookSpecificOutput"]["additionalContext"]
    except Exception as e:  # noqa: BLE001 - a memory miss must never block a review
        print(f"grok-hindsight-prefetch: skipped: {e}", file=sys.stderr)
        return
    if isinstance(text, str) and text.strip():
        print(text.strip()[:CAP])


main()
