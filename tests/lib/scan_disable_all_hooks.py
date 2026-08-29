#!/usr/bin/env python3
"""Refuse a repository-controlled hook kill switch — R1, issue #777 / ADR 0049.

Reports any tracked JSON in the repository at `sys.argv[1]` that carries the
`disableAllHooks` key. Driven by tests/test-disable-all-hooks-r1.sh, which is
where the reasoning for each rule below is written down.

Two decisions here are load-bearing and neither is cosmetic:

* **The INDEX blob is read, never the working tree.** What ships is what git
  tracks. An unstaged edit, a deletion, or a sparse checkout would otherwise
  present a clean file over a committed key and clear it.
* **Three exit codes, because "clean" and "the scan broke" are different
  answers.** A single non-zero would let a `git` failure or an uncaught
  exception read as a pass — the exact fail-open shape this scan exists to
  refuse.

    0  the key was found; the offending paths are on stdout
    1  clean
    2  the scan could not complete; the reason is on stderr
"""

import json
import subprocess
import sys

KEY = "disableAllHooks"


def carries_key(node):
    """True if `node` contains KEY anywhere in its decoded key space.

    Nested as well as top-level: a settings fragment is still a settings
    fragment, and a rule that only reads the root is one `{"outer": …}` away
    from being useless.
    """
    if isinstance(node, dict):
        for key, value in node.items():
            if key == KEY or carries_key(value):
                return True
    elif isinstance(node, list):
        for value in node:
            if carries_key(value):
                return True
    return False


def git(root, *args):
    """Run git under `root`, raising on any non-zero so it can never look clean."""
    done = subprocess.run(
        ["git", "-C", root, *args],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if done.returncode != 0:
        raise RuntimeError(
            "git %s failed (rc=%d): %s"
            % (" ".join(args), done.returncode, done.stderr.decode("utf-8", "replace").strip())
        )
    return done.stdout


def main(argv):
    if len(argv) != 2:
        print("usage: scan_disable_all_hooks.py <repo-root>", file=sys.stderr)
        return 2
    root = argv[1]

    try:
        # The WHOLE index, not a `*.json` pathspec, and `-s` for the mode. Both
        # narrowings are bypasses:
        #
        #   * by extension — a `.claude` tracked as a SUBMODULE or a directory
        #     SYMLINK puts no `*.json` path in this index at all. The settings
        #     file materializes at checkout and Claude reads it; a globbed scan
        #     never saw a candidate and reports clean.
        #   * by assuming a tracked `*.json` is a JSON file — a
        #     `.claude/settings.json` symlink stores its TARGET PATH as the blob,
        #     and a target named `"payload"` parses as valid, harmless JSON while
        #     the reader follows the link to the file holding the kill switch.
        #
        # Same family as the committed-`.claude`-symlink case in
        # tests/test-skip-file-repo-controlled.sh. So: every non-regular entry is
        # reported wherever it sits, and only regular `*.json` blobs are parsed.
        listing = git(root, "ls-files", "-s", "-z")
    except (RuntimeError, OSError) as exc:
        print("scan failed: %s" % exc, file=sys.stderr)
        return 2

    hits = []
    for entry in listing.split(b"\0"):
        if not entry:
            continue
        meta, _, name = entry.partition(b"\t")
        fields = meta.split(b" ")
        mode = fields[0].decode()
        blob = fields[1].decode() if len(fields) > 1 else ""
        rel = name.decode("utf-8", "surrogateescape")
        if mode not in ("100644", "100755"):
            # A symlink (120000) or gitlink (160000) — anywhere, not just at a
            # `*.json` path. What it resolves to at checkout is not in this index
            # and not this scan's to decide, so it cannot be cleared and is
            # reported. There are none in this tree today; the day one arrives it
            # is a deliberate decision, which is exactly when someone should look.
            hits.append("%s (tracked mode %s, not a regular file — cannot clear)" % (rel, mode))
            continue
        if not rel.endswith(".json"):
            continue
        try:
            # By SHA, not by `git show :<path>`: that spec is ambiguous for a
            # filename beginning with a digit and a colon — `0:clean.json` reads
            # as stage 0 of `clean.json`, so a dirty file could be cleared by a
            # clean namesake. `ls-files -s` already handed us the exact blob.
            content = git(root, "cat-file", "blob", blob)
        except (RuntimeError, OSError) as exc:
            # A tracked path whose blob cannot be read is not evidence of
            # anything, least of all cleanliness.
            print("scan failed on %s: %s" % (rel, exc), file=sys.stderr)
            return 2
        try:
            doc = json.loads(content)
        except Exception as exc:  # noqa: BLE001 — any decode failure is "cannot clear"
            hits.append("%s (unparseable, cannot clear: %s)" % (rel, exc))
            continue
        if carries_key(doc):
            hits.append(rel)

    for hit in hits:
        print(hit)
    return 0 if hits else 1


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except SystemExit:
        raise
    except BaseException as exc:  # noqa: BLE001 — see below
        # An uncaught exception exits 1, and 1 is CLEAN in this contract — so the
        # default Python traceback would turn any unforeseen fault (a RecursionError
        # from `carries_key` on deeply nested input, a MemoryError, an OSError from
        # the pipe) into a silent pass. Everything lands on 2 instead.
        print("scan failed: %r" % (exc,), file=sys.stderr)
        sys.exit(2)
