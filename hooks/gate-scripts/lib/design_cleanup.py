#!/usr/bin/env python3
"""Design review state cleanup for SessionStart hook (Task 2 / Decision-D2).

WARN-ONLY. It shells out to the shared existence-keyed classifier
(`resolve-repo-dir.sh pending`) and prints a warning built from its NUL records.
It NEVER mutates marker state (ADR-C: readers never mutate — the old whole-file
`os.remove` is gone). It may still delete the local `.impl-gate-block-count.local`
counter when nothing is pending. No SessionStart subtree scan (D3 — the ~10s
budget forbids a recursive walk; subdir-CWD legacy markers are an operator drain).

The warning goes to STDOUT because load-orchestrator.sh captures stdout into the
session message and drops stderr.
"""
import os
import re
import sys
import subprocess

state_dir = os.environ.get("BUSDRIVER_STATE_DIR", ".claude")
if (not state_dir or state_dir.startswith("/") or ".." in state_dir
        or not re.fullmatch(r"[A-Za-z0-9._/-]+", state_dir)):
    state_dir = ".claude"

resolver = os.path.join(os.path.dirname(os.path.abspath(__file__)), "resolve-repo-dir.sh")


def classify(anchor="."):
    """(code, records): code is 0 none / 1 pending / 2 failure, or None if the
    resolver is unavailable. records = list of (kind, source_path, doc_path, reason)."""
    try:
        p = subprocess.run(["bash", resolver, "pending", anchor], capture_output=True)
    except Exception:
        return None, []
    fields = p.stdout.split(b"\0")
    if fields and fields[-1] == b"":
        fields = fields[:-1]  # trailing empty after the final NUL terminator
    recs = []
    for i in range(0, len(fields) - 3, 4):
        recs.append(tuple(f.decode("utf-8", "surrogateescape") for f in fields[i:i + 4]))
    return p.returncode, recs


code, recs = classify(".")

if code is None:
    sys.exit(0)  # resolver unavailable — SessionStart is non-gating; say nothing

if code == 0:
    try:
        os.remove(f"{state_dir}/.impl-gate-block-count.local")
    except OSError:
        pass
    sys.exit(0)

if code != 1:
    # Anything other than 0 (handled above) or 1 (pending, below) — 2, or a child
    # 127/126 (python3 missing/uninvocable) — is an enumeration failure, not "clean".
    print("WARNING: could not enumerate the design-review marker set — the review gate will block as a precaution.")
    print("Run /blueprint-review, or inspect the repo's git-common-dir marker directory.")
    sys.exit(0)

names = []
for _kind, sp, dp, reason in recs[:8]:
    names.append(os.path.basename(dp) if dp else f"{os.path.basename(sp)} [{reason}]")
extra = f" (+{len(recs) - 8} more)" if len(recs) > 8 else ""
print(f"Design review pending ({len(recs)} marker(s)): {', '.join(names)}{extra}")
print("Run /blueprint-review before writing implementation code. To drain an abandoned")
print("marker, rm its token file in your terminal (the exact path is in the block message).")
