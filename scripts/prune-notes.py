#!/usr/bin/env python3
"""Notes pruning and health analysis tool.

Scans ~/.claude/notes/ for orphaned files, dead links, stale entries,
and index drift. Outputs a structured report for Claude to present.

Usage:
    python3 prune-notes.py [--dry-run] [--json]
"""

import os
import re
import sys
import json
from datetime import datetime, timedelta
from pathlib import Path

NOTES_DIR = Path.home() / ".claude" / "notes"
INDEX_FILE = NOTES_DIR / "NOTES.md"

# TTL thresholds (days) — matches load-orchestrator.sh
TTL_WARN = {
    "feedback": 365,
    "user": 365,
    "reference": 180,
    "project": 60,
    "lesson": 365,
}
TTL_ARCHIVE = {
    "feedback": 730,
    "user": 730,
    "reference": 365,
    "project": 120,
    "lesson": 730,
}


def parse_frontmatter(filepath):
    """Extract YAML frontmatter from a note file."""
    result = {}
    try:
        with open(filepath, "r", encoding="utf-8") as f:
            content = f.read()
    except (OSError, UnicodeDecodeError):
        return result

    # Match YAML frontmatter between --- delimiters
    match = re.match(r"^---\s*\n(.*?)\n---", content, re.DOTALL)
    if not match:
        return result

    for line in match.group(1).split("\n"):
        line = line.strip()
        if ":" in line:
            key, _, value = line.partition(":")
            result[key.strip()] = value.strip().strip('"').strip("'")

    return result


def extract_index_refs(index_path):
    """Extract all file references from NOTES.md."""
    refs = set()
    try:
        with open(index_path, "r", encoding="utf-8") as f:
            content = f.read()
    except (OSError, UnicodeDecodeError):
        return refs

    # Match markdown links: [text](./filename.md) and inline refs
    for match in re.finditer(r"\./([^\s)]+\.md)", content):
        refs.add(match.group(1))

    return refs


def scan_notes():
    """Scan notes directory and produce health report."""
    if not NOTES_DIR.exists():
        print("ERROR: Notes directory not found:", NOTES_DIR)
        sys.exit(1)

    # Collect all note files (exclude NOTES.md itself and archive/)
    all_files = {}
    for f in NOTES_DIR.glob("*.md"):
        if f.name == "NOTES.md":
            continue
        all_files[f.name] = f

    # Parse frontmatter for each file
    notes = {}
    for name, path in all_files.items():
        fm = parse_frontmatter(path)
        notes[name] = {
            "path": str(path),
            "frontmatter": fm,
            "type": fm.get("type", "unknown"),
            "last_validated": fm.get("last_validated", ""),
            "name": fm.get("name", name),
            "description": fm.get("description", ""),
            "lines": sum(1 for _ in open(path, encoding="utf-8")),
        }

    # Extract index references
    index_refs = extract_index_refs(INDEX_FILE)

    # --- Analysis ---
    today = datetime.now()
    orphaned = []  # Files not in index
    dead_links = []  # Index refs with no file
    stale_warn = []  # Past warn TTL
    stale_archive = []  # Past archive TTL
    no_frontmatter = []  # Missing frontmatter
    no_validated = []  # Missing last_validated

    # Orphaned files
    for name in sorted(all_files.keys()):
        if name not in index_refs:
            orphaned.append(name)

    # Dead links
    for ref in sorted(index_refs):
        if ref not in all_files:
            dead_links.append(ref)

    # Staleness checks
    for name, info in sorted(notes.items()):
        lv = info["last_validated"]
        if not lv:
            no_validated.append(name)
            continue

        try:
            validated_date = datetime.strptime(lv, "%Y-%m-%d")
        except ValueError:
            no_validated.append(name)
            continue

        note_type = info["type"]
        warn_days = TTL_WARN.get(note_type, TTL_WARN["lesson"])
        archive_days = TTL_ARCHIVE.get(note_type, TTL_ARCHIVE["lesson"])
        age_days = (today - validated_date).days

        if age_days > archive_days:
            stale_archive.append((name, note_type, age_days, archive_days))
        elif age_days > warn_days:
            stale_warn.append((name, note_type, age_days, warn_days))

        if not info["frontmatter"]:
            no_frontmatter.append(name)

    # Type distribution
    type_counts = {}
    for info in notes.values():
        t = info["type"]
        type_counts[t] = type_counts.get(t, 0) + 1

    total_lines = sum(info["lines"] for info in notes.values())

    # --- Output ---
    output_json = "--json" in sys.argv

    report = {
        "summary": {
            "total_files": len(all_files),
            "total_lines": total_lines,
            "indexed": len(index_refs),
            "type_distribution": type_counts,
        },
        "orphaned_files": orphaned,
        "dead_links": dead_links,
        "stale_warn": [
            {"file": f, "type": t, "age_days": a, "ttl_days": ttl}
            for f, t, a, ttl in stale_warn
        ],
        "stale_archive": [
            {"file": f, "type": t, "age_days": a, "ttl_days": ttl}
            for f, t, a, ttl in stale_archive
        ],
        "no_frontmatter": no_frontmatter,
        "no_validated": no_validated,
    }

    if output_json:
        print(json.dumps(report, indent=2))
        return report

    # Human-readable output
    print("=" * 60)
    print(f"  NOTES HEALTH REPORT — {len(all_files)} files, {total_lines} lines")
    print(f"  Indexed: {len(index_refs)} refs | Scanned: {today.strftime('%Y-%m-%d')}")
    print("=" * 60)

    print(f"\n## Type Distribution")
    for t, c in sorted(type_counts.items(), key=lambda x: -x[1]):
        print(f"  {t}: {c}")

    issues_found = False

    if orphaned:
        issues_found = True
        print(f"\n## ORPHANED FILES ({len(orphaned)}) — exist but not in NOTES.md")
        for f in orphaned:
            info = notes[f]
            print(f"  + {f}")
            print(f"    type={info['type']}  desc: {info['description'][:60]}")

    if dead_links:
        issues_found = True
        print(f"\n## DEAD LINKS ({len(dead_links)}) — in NOTES.md but file missing")
        for f in dead_links:
            print(f"  ! {f}")

    if stale_archive:
        issues_found = True
        print(f"\n## ARCHIVE CANDIDATES ({len(stale_archive)}) — past archive TTL")
        for item in stale_archive:
            f, t, a, ttl = item["file"], item["type"], item["age_days"], item["ttl_days"]
            print(f"  >> {f}  (type={t}, {a}d old, ttl={ttl}d)")

    if stale_warn:
        issues_found = True
        print(f"\n## STALE WARNINGS ({len(stale_warn)}) — past warn TTL")
        for item in stale_warn:
            f, t, a, ttl = item["file"], item["type"], item["age_days"], item["ttl_days"]
            print(f"  ~ {f}  (type={t}, {a}d old, ttl={ttl}d)")

    if no_validated:
        issues_found = True
        print(f"\n## MISSING last_validated ({len(no_validated)})")
        for f in no_validated:
            print(f"  ? {f}")

    if no_frontmatter:
        issues_found = True
        print(f"\n## MISSING FRONTMATTER ({len(no_frontmatter)})")
        for f in no_frontmatter:
            print(f"  ? {f}")

    if not issues_found:
        print("\n✓ No issues found. Notes are healthy.")

    print()
    return report


if __name__ == "__main__":
    scan_notes()
