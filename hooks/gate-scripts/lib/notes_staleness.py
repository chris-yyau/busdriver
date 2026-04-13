#!/usr/bin/env python3
"""Notes staleness checker for SessionStart hook."""
import os, glob
from datetime import datetime, timezone

memory_dir = os.environ.get("MEMORY_DIR_PY", "")
archive_dir = os.path.join(memory_dir, "archive")
now = datetime.now(timezone.utc)

TYPE_TTLS = {
    "feedback": (365, 730),
    "reference": (180, 365),
    "project": (60, 120),
    "user": (365, 730),
}
DEFAULT_TTL = (365, 730)

warnings = []
archived = []

for path in glob.glob(os.path.join(memory_dir, "*.md")):
    basename = os.path.basename(path)
    if basename == "NOTES.md":
        continue

    try:
        with open(path) as f:
            content = f.read()
    except Exception:
        continue

    if not content.startswith("---"):
        continue

    parts = content.split("---", 2)
    if len(parts) < 3:
        continue

    meta = {}
    for line in parts[1].strip().split("\n"):
        if ":" in line:
            k, v = line.split(":", 1)
            meta[k.strip()] = v.strip().strip('"').strip("'")

    last_validated = meta.get("last_validated", "")
    mem_type = meta.get("type", "")

    if not last_validated:
        warnings.append(f"- `{basename}` — no last_validated date (type: {mem_type})")
        continue

    try:
        lv_date = datetime.strptime(last_validated, "%Y-%m-%d").replace(tzinfo=timezone.utc)
    except Exception:
        warnings.append(f"- `{basename}` — malformed last_validated: '{last_validated}'")
        continue

    age_days = (now - lv_date).days

    if basename.startswith("lesson-"):
        warn_days, archive_days = DEFAULT_TTL
    else:
        warn_days, archive_days = TYPE_TTLS.get(mem_type, DEFAULT_TTL)

    if age_days >= archive_days:
        os.makedirs(archive_dir, exist_ok=True)
        dest = os.path.join(archive_dir, basename)
        try:
            os.rename(path, dest)
            archived.append(f"- `{basename}` ({age_days}d old, type={mem_type}, limit={archive_days}d)")
            index_path = os.path.join(memory_dir, "NOTES.md")
            if os.path.isfile(index_path):
                with open(index_path) as f:
                    lines_md = f.readlines()
                filtered = [l for l in lines_md if basename not in l]
                if len(filtered) < len(lines_md):
                    with open(index_path, "w") as f:
                        f.writelines(filtered)
        except Exception:
            pass
    elif age_days >= warn_days:
        warnings.append(f"- `{basename}` — {age_days}d since validation (type={mem_type}, warn={warn_days}d, archive={archive_days}d)")

output_lines = []
if archived:
    output_lines.append("### Notes Auto-Archived")
    output_lines.extend(archived)
    output_lines.append("")
if warnings:
    output_lines.append("### Stale Notes")
    output_lines.extend(warnings)
    output_lines.append("")

if output_lines:
    print("\n".join(output_lines))
