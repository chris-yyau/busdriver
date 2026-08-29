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

    0  the tree could not be cleared; the paths responsible are on stdout. That
       is the key found, and also every entry whose contents are unknowable —
       malformed JSON, a symlink, a gitlink — because "I could not read it" is
       not "it is clean".
    1  clean: every tracked entry was read and none carries the key
    2  the scan could not complete at all; the reason is on stderr
"""

import json
import os
import subprocess
import sys

KEY = "disableAllHooks"

# `git -C <root>` does NOT bind git to <root>: GIT_DIR, GIT_INDEX_FILE,
# GIT_WORK_TREE, GIT_OBJECT_DIRECTORY and their siblings all outrank it, so an
# ambient one aims the scan at a different repository — or a different index —
# and it reports clean about a tree it never read. Everything `GIT_*` is dropped
# rather than enumerated, because the enumeration is the part that goes stale.
GIT_ENV = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}


def carries_key(node):
    """True if `node` contains KEY anywhere in its decoded key space.

    Nested as well as top-level: a settings fragment is still a settings
    fragment, and a rule that only reads the root is one `{"outer": …}` away
    from being useless.
    """
    if isinstance(node, dict):
        return any(key == KEY or carries_key(value) for key, value in node.items())
    if isinstance(node, list):
        return any(carries_key(value) for value in node)
    return False


def git(root, *args):
    """Run git under `root`, raising on any non-zero so it can never look clean."""
    done = subprocess.run(
        # `--no-replace-objects`: a refs/replace/ entry rewrites what an object
        # id resolves to, so without it "the blob named in the index" and "what
        # cat-file prints" are not the same content.
        ["git", "--no-replace-objects", "-C", root, *args],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=GIT_ENV,
    )
    if done.returncode != 0:
        raise RuntimeError(
            "git %s failed (rc=%d): %s"
            % (" ".join(args), done.returncode, done.stderr.decode("utf-8", "replace").strip())
        )
    return done.stdout


def classify_entry(root, entry):
    """Classify one `git ls-files -s -z` record: a hit line, or None when clean.

    Raises `RuntimeError`/`OSError` — already carrying the path — when the blob
    cannot be read, so the caller answers 2 rather than clearing what it never saw.
    """
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
        return "%s (tracked mode %s, not a regular file — cannot clear)" % (rel, mode)
    # Case-INsensitively: macOS and Windows resolve `.claude/settings.JSON`
    # when Claude opens `.claude/settings.json`, so a case-sensitive suffix
    # test clears on Linux CI exactly the file the operator's machine reads.
    if not rel.lower().endswith(".json"):
        return None
    try:
        # By SHA, not by `git show :<path>`: that spec is ambiguous for a
        # filename beginning with a digit and a colon — `0:clean.json` reads
        # as stage 0 of `clean.json`, so a dirty file could be cleared by a
        # clean namesake. `ls-files -s` already handed us the exact blob.
        content = git(root, "cat-file", "blob", blob)
    except (RuntimeError, OSError) as exc:
        raise RuntimeError("%s: %s" % (rel, exc)) from exc
    try:
        doc = json.loads(content)
    except Exception as exc:  # noqa: BLE001 — any decode failure is "cannot clear"
        return "%s (unparseable, cannot clear: %s)" % (rel, exc)
    return rel if carries_key(doc) else None


def main(argv):
    if len(argv) != 2:
        print("usage: scan_disable_all_hooks.py <repo-root>", file=sys.stderr)
        return 2
    root = argv[1]

    try:
        # `git -C <dir>` walks UP for repository metadata, so an ordinary
        # subdirectory of some other repository answers happily — about that
        # other repository. The caller asked about `root`; anything else is a
        # different tree wearing the right name, and reporting it clean is the
        # same fail-open as a redirected GIT_DIR. Confirm the discovered
        # top-level IS the requested root before reading a single entry.
        top = git(root, "rev-parse", "--show-toplevel").decode("utf-8", "surrogateescape").strip()
    except (RuntimeError, OSError) as exc:
        print("scan failed: %s" % exc, file=sys.stderr)
        return 2
    if os.path.realpath(top) != os.path.realpath(root):
        print(
            "scan failed: %s is not a repository root (git resolved %s)" % (root, top),
            file=sys.stderr,
        )
        return 2

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
        try:
            hit = classify_entry(root, entry)
        except (RuntimeError, OSError) as exc:
            # A tracked path whose blob cannot be read is not evidence of
            # anything, least of all cleanliness. `exc` already names the path.
            print("scan failed on %s" % exc, file=sys.stderr)
            return 2
        if hit is not None:
            hits.append(hit)

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
