#!/usr/bin/env python3
"""Design review state cleanup for SessionStart hook."""
import os, sys, re
from datetime import datetime, timezone, timedelta

# Resolve the harness state dir, constraining it to a safe relative name (mirror
# the shell gates) so this cleanup reads the markers from the same directory the
# gates write them to. BUSDRIVER_STATE_DIR overrides; defaults to .claude.
state_dir = os.environ.get("BUSDRIVER_STATE_DIR", ".claude")
if (not state_dir or state_dir.startswith("/") or ".." in state_dir
        or not re.fullmatch(r"[A-Za-z0-9._/-]+", state_dir)):
    state_dir = ".claude"

state_file = f"{state_dir}/design-review-needed.local.md"
stale_hours = float(os.environ.get("DESIGN_REVIEW_STALE_HOURS", "2"))

try:
    with open(state_file) as f:
        content = f.read()
except Exception:
    sys.exit(0)

created = None
if content.startswith("---"):
    parts = content.split("---", 2)
    if len(parts) >= 3:
        for line in parts[1].strip().split("\n"):
            if line.strip().startswith("created_at:"):
                ts = line.split(":", 1)[1].strip().strip('"').strip("'")
                for fmt in ("%Y-%m-%dT%H:%M:%SZ", "%Y-%m-%dT%H:%M:%S%z", "%Y-%m-%d"):
                    try:
                        created = datetime.strptime(ts, fmt)
                        if created.tzinfo is None:
                            created = created.replace(tzinfo=timezone.utc)
                        break
                    except ValueError:
                        continue
                break

if created is None:
    try:
        mtime = os.path.getmtime(state_file)
        created = datetime.fromtimestamp(mtime, tz=timezone.utc)
    except Exception:
        sys.exit(0)

lines = re.findall(r"^- (.+)$", content, re.MULTILINE)
unreviewed = []
resolved = []
for f in lines:
    if not os.path.isfile(f):
        resolved.append(f"{f} (deleted)")
    else:
        try:
            with open(f) as fh:
                if "<!-- design-reviewed: PASS -->" in fh.read():
                    resolved.append(f"{f} (reviewed)")
                else:
                    unreviewed.append(f)
        except Exception:
            unreviewed.append(f)

age = datetime.now(timezone.utc) - created
is_stale = age > timedelta(hours=stale_hours)

if not unreviewed:
    os.remove(state_file)
    try:
        os.remove(f"{state_dir}/.impl-gate-block-count.local")
    except Exception:
        pass
    if resolved:
        print(f"Design review state cleaned up ({len(resolved)} resolved entries).")
elif is_stale:
    age_str = f"{age.seconds // 3600}h" if age.days == 0 else f"{age.days}d {age.seconds // 3600}h"
    files = ", ".join(os.path.basename(f) for f in unreviewed)
    print(f"WARNING: Stale design review pending ({age_str} old, from previous session).")
    print(f"Unreviewed: {files}")
    print("Run /design-reviewer to complete review, or create .claude/skip-design-review.local to bypass.")
else:
    files = ", ".join(os.path.basename(f) for f in unreviewed)
    print(f"Active design review pending: {files}")
    print("Run /design-reviewer before writing implementation code.")
