#!/usr/bin/env bash
# SessionStart hook: inject orchestrator skill into Claude's context
# Mirrors the superpowers session-start.sh hookSpecificOutput pattern
# Also: gate dependency health check, memory staleness enforcement, instinct loading

set -euo pipefail

# ── Skip for internal observer sessions ───────────────────────────────────
# The ECC observer spawns `claude --model haiku` subprocesses for analysis.
# Those subprocesses trigger SessionStart hooks including this one.
# Loading the full orchestrator context into a haiku subprocess is wasteful
# and can cause the model to attempt starting another observer (recursion).
if [ "${CLAUDE_HOMUNCULUS_INTERNAL:-}" = "1" ]; then
    exit 0
fi

# ── Gate dependency health check ──────────────────────────────────────────
# Gate hooks now fail-CLOSED when python3 is missing (block_emit via printf).
# jq is optional — block_emit falls back to printf when jq is absent.
# This check runs once at session start and warns if deps are absent.
GATE_HEALTH_WARNINGS=""
if ! command -v python3 &>/dev/null; then
    # python3 is missing — this script itself depends on python3 for JSON output,
    # so we must emit the warning as raw hookSpecificOutput JSON using printf.
    # Note: gate hooks fail-CLOSED (block via printf) when python3 is missing,
    # so gates are NOT silently disabled — they block ALL gated actions.
    printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"## CRITICAL: python3 not found\\n\\nAll review gates (codex-reviewer, design-reviewer, pre-implementation, pre-commit) will BLOCK every gated action because gate hooks fail-CLOSED without python3. Gates cannot parse tool input to determine if the action is actually a commit — so they block everything as a precaution.\\n\\n**Install python3 immediately to restore normal gate operation.** Until then, use `.claude/skip-codex-review.local` or `.claude/skip-design-review.local` to bypass individual blocked actions."}}\n'
    exit 0
fi
if ! command -v jq &>/dev/null; then
    GATE_HEALTH_WARNINGS="${GATE_HEALTH_WARNINGS}\n**WARNING: jq not found.** Gate hooks use a printf fallback to emit block decisions — enforcement still works but JSON output may be less robust with special characters. Install jq for reliable gate output.\n\n\`brew install jq\` or \`apt-get install jq\`"
fi
if ! command -v codex &>/dev/null; then
    GATE_HEALTH_WARNINGS="${GATE_HEALTH_WARNINGS}\n**WARNING: codex CLI not found.** Codex reviewer will run in DEGRADED mode (marker-only, no automated review). Install codex CLI for full code review enforcement.\n\n\`npm install -g @openai/codex\`"
fi

# ── Design review state cleanup (F10 fix, updated F11) ────────────────────
# Check for stale design-review-needed.local.md from previous sessions.
# Validates entries (removes resolved ones) but does NOT auto-expire stale state.
# Stale reviews persist until explicitly completed or manually skipped.
DESIGN_STATE=".claude/design-review-needed.local.md"
DESIGN_CLEANUP_MSG=""
if [ -f "$DESIGN_STATE" ]; then
    DESIGN_CLEANUP_MSG=$(python3 << 'DESIGN_CLEANUP_EOF' 2>/dev/null || true
import os, sys
from datetime import datetime, timezone, timedelta

state_file = ".claude/design-review-needed.local.md"
# DESIGN_REVIEW_STALE_HOURS controls the WARNING threshold (not expiry).
# State older than this shows a stale warning; younger shows an active warning.
# The gate enforces regardless of age — this is display-only.
stale_hours = float(os.environ.get("DESIGN_REVIEW_STALE_HOURS", "2"))

try:
    with open(state_file) as f:
        content = f.read()
except Exception:
    sys.exit(0)

# Parse created_at from frontmatter
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

# Fallback: file mtime
if created is None:
    try:
        mtime = os.path.getmtime(state_file)
        created = datetime.fromtimestamp(mtime, tz=timezone.utc)
    except Exception:
        sys.exit(0)

# Parse listed files and validate
import re
lines = re.findall(r"^- (.+)$", content, re.MULTILINE)
unreviewed = []
resolved = []
for f in lines:
    if not os.path.isfile(f):
        resolved.append(f"{f} (deleted)")
    elif "<!-- design-reviewed: PASS -->" in open(f).read():
        resolved.append(f"{f} (reviewed)")
    else:
        unreviewed.append(f)

age = datetime.now(timezone.utc) - created
is_stale = age > timedelta(hours=stale_hours)

if not unreviewed:
    # All entries resolved — clean up silently
    os.remove(state_file)
    try:
        os.remove(".claude/.impl-gate-block-count.local")
    except Exception:
        pass
    if resolved:
        print(f"Design review state cleaned up ({len(resolved)} resolved entries).")
elif is_stale:
    # Stale entries — warn but KEEP enforcing (don't auto-expire)
    # Previous behavior silently cleared state, allowing implementation without review.
    # Now the gate persists until explicitly reviewed or manually skipped.
    age_str = f"{age.seconds // 3600}h" if age.days == 0 else f"{age.days}d {age.seconds // 3600}h"
    files = ", ".join(os.path.basename(f) for f in unreviewed)
    print(f"WARNING: Stale design review pending ({age_str} old, from previous session).")
    print(f"Unreviewed: {files}")
    print(f"Run /design-reviewer to complete review, or create .claude/skip-design-review.local to bypass.")
else:
    # Fresh entries still pending — warn but don't expire
    files = ", ".join(os.path.basename(f) for f in unreviewed)
    print(f"Active design review pending: {files}")
    print(f"Run /design-reviewer before writing implementation code.")
DESIGN_CLEANUP_EOF
)
fi

# Resolve orchestrator SKILL.md — prefer plugin location, fall back to legacy
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "${CLAUDE_PLUGIN_ROOT}/skills/orchestrator/SKILL.md" ]; then
    SKILL_FILE="${CLAUDE_PLUGIN_ROOT}/skills/orchestrator/SKILL.md"
elif [ -f "${HOME}/.claude/skills/orchestrator/SKILL.md" ]; then
    SKILL_FILE="${HOME}/.claude/skills/orchestrator/SKILL.md"
else
    SKILL_FILE="${CLAUDE_PLUGIN_ROOT:-${HOME}/.claude}/skills/orchestrator/SKILL.md"
fi

# Read orchestrator content
content=$(cat "$SKILL_FILE" 2>&1 || echo "Error: orchestrator SKILL.md not found at ${SKILL_FILE}")

# Append design review cleanup message if any
if [ -n "$DESIGN_CLEANUP_MSG" ]; then
    content="${content}

<!-- BEGIN DESIGN REVIEW CLEANUP -->
## Design Review State (SessionStart)
${DESIGN_CLEANUP_MSG}
<!-- END DESIGN REVIEW CLEANUP -->"
fi

# Append gate health warnings if any dependencies are missing
if [ -n "$GATE_HEALTH_WARNINGS" ]; then
    content="${content}

<!-- BEGIN GATE HEALTH CHECK -->
## Gate Health Check (SessionStart)
$(printf '%b' "$GATE_HEALTH_WARNINGS")

**Action required:** Install missing dependencies before proceeding. Without them, review gates provide NO enforcement — commits and implementation bypass all quality checks.
<!-- END GATE HEALTH CHECK -->"
fi

# ── Notes staleness check ─────────────────────────────────────────────────
# Scans ~/.claude/notes/ for files with stale last_validated dates.
# Per-type TTLs: feedback/user=365d, reference=180d, project=60d, lesson/default=365d
# Warn at TTL, auto-archive at 2x TTL (move to notes/archive/).
MEMORY_DIR="${HOME}/.claude/notes"
if [ -d "$MEMORY_DIR" ]; then
    staleness_output=$(MEMORY_DIR_PY="$MEMORY_DIR" python3 << 'STALE_EOF' 2>/dev/null || true
import os, re, glob
from datetime import datetime, timezone

memory_dir = os.environ.get("MEMORY_DIR_PY", "")
archive_dir = os.path.join(memory_dir, "archive")
now = datetime.now(timezone.utc)

# Per-type TTLs in days: (warn_days, archive_days)
TYPE_TTLS = {
    "feedback": (365, 730),
    "reference": (180, 365),
    "project": (60, 120),
    "user": (365, 730),
}
DEFAULT_TTL = (365, 730)  # lesson files and unknown types

warnings = []
archived = []

for path in glob.glob(os.path.join(memory_dir, "*.md")):
    basename = os.path.basename(path)
    if basename == "NOTES.md":
        continue

    # Parse frontmatter
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
    name = meta.get("name", basename)

    if not last_validated:
        warnings.append(f"- `{basename}` — no last_validated date (type: {mem_type})")
        continue

    try:
        lv_date = datetime.strptime(last_validated, "%Y-%m-%d").replace(tzinfo=timezone.utc)
    except Exception:
        warnings.append(f"- `{basename}` — malformed last_validated: '{last_validated}' (cannot enforce TTL)")
        continue

    age_days = (now - lv_date).days

    # Lesson files (lesson-*) get shorter TTLs even if type=feedback
    if basename.startswith("lesson-"):
        warn_days, archive_days = DEFAULT_TTL  # 90d/180d
    else:
        warn_days, archive_days = TYPE_TTLS.get(mem_type, DEFAULT_TTL)

    if age_days >= archive_days:
        # Auto-archive: move to notes/archive/ AND remove from NOTES.md index
        os.makedirs(archive_dir, exist_ok=True)
        dest = os.path.join(archive_dir, basename)
        try:
            os.rename(path, dest)
            archived.append(f"- `{basename}` ({age_days}d old, type={mem_type}, limit={archive_days}d)")
            # Remove from NOTES.md index to prevent archive leakage
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
    output_lines.append("These notes exceeded their type TTL and were moved to `notes/archive/`:")
    output_lines.extend(archived)
    output_lines.append("Retrieve from archive if still relevant, then update `last_validated`.")
    output_lines.append("")
if warnings:
    output_lines.append("### Stale Notes")
    output_lines.append("These notes are approaching their archive deadline. Re-validate or update `last_validated`:")
    output_lines.extend(warnings)
    output_lines.append("")

if output_lines:
    print("\n".join(output_lines))
STALE_EOF
)

    if [ -n "$staleness_output" ]; then
        content="${content}

<!-- BEGIN NOTES STALENESS -->
${staleness_output}
<!-- END NOTES STALENESS -->"
    fi
fi

# ── Instinct loading (reflection system consumer) ────────────────────────
# Loads instincts from ~/.claude/homunculus/instincts/{personal,inherited}/
# into session context. Instincts are atomic behavioral patterns learned from
# observation (ECC v2 observer + /reflect manual system). Only loads instincts with
# confidence >= 0.7 (strong patterns only). Format: compact one-liner per instinct.
# Security: instinct content is sanitized (HTML tags, markdown injection stripped).
instinct_output=$(python3 << 'INSTINCT_EOF' 2>/dev/null || true
import os, glob, re
from datetime import datetime

MAX_INSTINCTS = 20       # Cap: oldest evicted beyond this
MAX_FILE_SIZE = 10240    # 10KB per instinct file
MIN_CONFIDENCE = 0.7     # Only strong patterns

def sanitize(s, max_len=200):
    """Strip potential injection vectors from instinct content.
    Instincts are untrusted input (auto-generated by ECC observer).
    Even after promotion, sanitize to prevent semantic injection.
    See: H13 finding, Sprint 1 audit (2026-03-19)."""
    s = re.sub(r'<[^>]+>', '', s)           # strip HTML tags
    s = re.sub(r'```', '', s)               # strip code fences
    s = s.replace('<!--', '').replace('-->', '')  # strip HTML comments
    s = re.sub(r'\[([^\]]*)\]\([^)]*\)', r'\1', s)  # strip markdown links (keep text)
    s = re.sub(r'[*_~`]{1,3}', '', s)      # strip bold/italic/strikethrough/inline code
    s = re.sub(r'\n+', ' ', s)             # collapse newlines to spaces (prevent injection via line breaks)
    s = re.sub(r'#+ ', '', s)              # strip markdown headers
    s = re.sub(r'!\[', '[', s)             # strip image markers
    s = re.sub(r'\s+', ' ', s).strip()     # normalize whitespace
    return s[:max_len]

dirs = [
    os.path.expanduser("~/.claude/homunculus/instincts/inherited"),
    os.path.expanduser("~/.claude/homunculus/instincts/personal"),
]

# Also load project-scoped instincts (ECC v2.1)
# Matches detect-project.sh hash logic: CLAUDE_PROJECT_DIR first, then
# git remote (strip credentials), fall back to repo path
import subprocess, hashlib, re as _re

# detect-project.sh priority: CLAUDE_PROJECT_DIR > cwd detection > git
_project_root = os.environ.get("CLAUDE_PROJECT_DIR", "")

_remote = ""
if _project_root or True:  # always try git for hash
    _git_dir = _project_root or "."
    try:
        _remote = subprocess.check_output(
            ["git", "-C", _git_dir, "remote", "get-url", "origin"],
            stderr=subprocess.DEVNULL, text=True
        ).strip()
        _remote = _re.sub(r"://[^@]+@", "://", _remote)
    except Exception:
        pass

# Fall back: CLAUDE_PROJECT_DIR path, then git toplevel (matches detect-project.sh)
_hash_input = _remote
if not _hash_input:
    _hash_input = _project_root or ""
if not _hash_input:
    try:
        _hash_input = subprocess.check_output(
            ["git", "rev-parse", "--show-toplevel"],
            stderr=subprocess.DEVNULL, text=True
        ).strip()
    except Exception:
        pass

if _hash_input:
    _project_hash = hashlib.sha256(_hash_input.encode()).hexdigest()[:12]
    # Legacy hash first, then current — so current wins in dedup (last write wins)
    _hashes_to_check = []
    try:
        _raw_remote = subprocess.check_output(
            ["git", "-C", _project_root or ".", "remote", "get-url", "origin"],
            stderr=subprocess.DEVNULL, text=True
        ).strip()
        if _raw_remote and _raw_remote != _hash_input:
            _legacy_hash = hashlib.sha256(_raw_remote.encode()).hexdigest()[:12]
            if _legacy_hash != _project_hash:
                _hashes_to_check.append(_legacy_hash)  # legacy first
    except Exception:
        pass
    _hashes_to_check.append(_project_hash)  # current last (wins in dedup)
    for _ph in _hashes_to_check:
        # personal AFTER inherited so personal wins in dedup (last write wins)
        for subdir in ["inherited", "personal"]:
            p = os.path.expanduser(f"~/.claude/homunculus/projects/{_ph}/instincts/{subdir}")
            if os.path.isdir(p):
                dirs.append(p)

# ── Pending instinct TTL (30 days) ────────────────────────────────────
# Auto-delete unreviewed pending instincts older than 30 days.
# Council decision (2026-03-21): don't auto-promote, fix garbage collection.
# If the pattern is real, the observer will regenerate it.
PENDING_TTL_DAYS = 30
PENDING_NOTIFY_THRESHOLD = 5

pending_dir = os.path.expanduser("~/.claude/homunculus/instincts/pending")
pending_count = 0
pending_expired = 0

if os.path.isdir(pending_dir):
    for pf in glob.glob(os.path.join(pending_dir, "*.md")):
        if os.path.islink(pf):
            continue
        try:
            with open(pf) as f:
                praw = f.read()
        except Exception:
            continue
        # Parse created date from frontmatter
        p_created = ""
        if praw.startswith("---"):
            pparts = praw.split("---", 2)
            if len(pparts) >= 3:
                for pline in pparts[1].strip().split("\n"):
                    if pline.strip().startswith("created:"):
                        p_created = pline.split(":", 1)[1].strip().strip('"').strip("'")
                        break
        expired = False
        if p_created:
            try:
                p_date = datetime.strptime(p_created, "%Y-%m-%d")
                if (datetime.now() - p_date).days > PENDING_TTL_DAYS:
                    expired = True
            except Exception:
                pass
        else:
            # No created date — check file mtime as fallback
            try:
                import time as _time
                mtime = os.path.getmtime(pf)
                age_days = (datetime.now() - datetime.fromtimestamp(mtime)).days
                if age_days > PENDING_TTL_DAYS:
                    expired = True
            except Exception:
                pass
        if expired:
            try:
                os.remove(pf)
                pending_expired += 1
            except Exception:
                pass
        else:
            pending_count += 1

# Also check project-scoped pending directories
if _hash_input:
    for _ph in _hashes_to_check:
        _ppd = os.path.expanduser(f"~/.claude/homunculus/projects/{_ph}/instincts/pending")
        if os.path.isdir(_ppd):
            for pf in glob.glob(os.path.join(_ppd, "*.md")):
                if os.path.islink(pf):
                    continue
                try:
                    with open(pf) as f:
                        praw = f.read()
                except Exception:
                    continue
                p_created = ""
                if praw.startswith("---"):
                    pparts = praw.split("---", 2)
                    if len(pparts) >= 3:
                        for pline in pparts[1].strip().split("\n"):
                            if pline.strip().startswith("created:"):
                                p_created = pline.split(":", 1)[1].strip().strip('"').strip("'")
                                break
                expired = False
                if p_created:
                    try:
                        p_date = datetime.strptime(p_created, "%Y-%m-%d")
                        if (datetime.now() - p_date).days > PENDING_TTL_DAYS:
                            expired = True
                    except Exception:
                        pass
                if expired:
                    try:
                        os.remove(pf)
                        pending_expired += 1
                    except Exception:
                        pass
                else:
                    pending_count += 1

instincts = []
for d in dirs:
    if not os.path.isdir(d):
        continue
    for path in sorted(glob.glob(os.path.join(d, "*.md"))):
        # Security: reject symlinks (path traversal vector)
        if os.path.islink(path):
            continue

        # Security: reject oversized files (DoS / injection payload)
        try:
            if os.path.getsize(path) > MAX_FILE_SIZE:
                continue
        except Exception:
            continue

        try:
            with open(path) as f:
                raw = f.read()
        except Exception:
            continue

        if not raw.startswith("---"):
            continue

        parts = raw.split("---", 2)
        if len(parts) < 3:
            continue

        meta = {}
        for line in parts[1].strip().split("\n"):
            if ":" in line:
                k, v = line.split(":", 1)
                meta[k.strip()] = v.strip().strip('"').strip("'")

        confidence = 0.0
        try:
            confidence = float(meta.get("confidence", "0"))
        except Exception:
            pass

        # ── Confidence decay (F14 fix) ────────────────────────────────
        # Reduce effective confidence by 0.1 per 60 days since creation.
        # Does NOT modify the file — only affects loading threshold.
        # Instincts that decay below MIN_CONFIDENCE stop loading naturally.
        created_str = meta.get("created", "")
        if created_str:
            try:
                created_date = datetime.strptime(created_str, "%Y-%m-%d")
                age_days = (datetime.now() - created_date).days
                decay = (age_days // 60) * 0.1
                confidence = max(0.0, confidence - decay)
            except Exception:
                pass

        if confidence < MIN_CONFIDENCE:
            continue

        # ── Quarantine guard for auto-generated instincts ────
        # ECC observer writes instincts directly to personal/ with
        # source: session-observation. These bypass human review.
        # EXPLICIT PROMOTION REQUIRED — no time-based auto-load.
        # Council decision (2026-03-19): 24h timer was a supply-chain
        # risk — unreviewed rules auto-activated. Now requires:
        #   promoted: true  in frontmatter (set via /promote command)
        # Review pending instincts: /instinct-status
        #
        # NOTE: This guard applies to ALL directories (personal/,
        # inherited/, project-scoped/) — not just personal/. An
        # auto-generated instinct shared via inherited/ is still
        # blocked until the LOCAL user promotes it. This prevents
        # untrusted instincts from entering via shared channels.
        source = meta.get("source", "")
        promoted = meta.get("promoted", "").lower() in ("true", "yes", "1")
        if source == "session-observation" and not promoted:
            pending_count += 1
            continue  # Blocked until explicitly promoted

        inst_id = meta.get("id", os.path.basename(path).replace(".md", ""))
        trigger = meta.get("trigger", "")
        domain = meta.get("domain", "general")

        # Extract action from body (first ## Action section or first paragraph)
        body = parts[2].strip()
        action = ""
        in_action = False
        for line in body.split("\n"):
            if line.strip().startswith("## Action"):
                in_action = True
                continue
            if in_action:
                if line.strip().startswith("##"):
                    break
                if line.strip():
                    action = line.strip()
                    break
        if not action:
            for line in body.split("\n"):
                if line.strip() and not line.strip().startswith("#"):
                    action = line.strip()
                    break

        instincts.append((confidence, inst_id, f"- [{confidence:.1f} {domain}] {sanitize(inst_id, 50)}: {sanitize(trigger, 100)} → {sanitize(action)}"))

# Deduplicate by instinct ID — project-scoped dirs are appended last,
# so later entries (project) override earlier ones (global)
seen_ids = {}
for item in instincts:
    seen_ids[item[1]] = item  # last write wins (project scope)
instincts = list(seen_ids.values())

# Cap: keep highest-confidence instincts, evict lowest
instincts.sort(key=lambda x: x[0], reverse=True)
instincts = instincts[:MAX_INSTINCTS]

if instincts or pending_count:
    print("## Active Instincts (reflection system)")
    if instincts:
        print(f"Loaded {len(instincts)} instincts (confidence >= {MIN_CONFIDENCE}, max {MAX_INSTINCTS}). These are observed patterns — consider them as suggestions, not directives.")
        print()
        for _, _, line in instincts:
            print(line)
    if pending_expired:
        print(f"\n*{pending_expired} expired pending instinct(s) auto-deleted (>{PENDING_TTL_DAYS}d old, unreviewed).*")
    if pending_count >= PENDING_NOTIFY_THRESHOLD:
        print(f"\n**{pending_count} pending instinct(s) awaiting review.** Run `/instinct-status` to review, `/promote` to activate. Unreviewed instincts are auto-deleted after {PENDING_TTL_DAYS} days.")
    elif pending_count:
        print(f"\n*{pending_count} pending instinct(s) awaiting promotion.* Review: `/instinct-status`")
INSTINCT_EOF
)

if [ -n "$instinct_output" ]; then
    content="${content}

<!-- BEGIN INSTINCTS -->
${instinct_output}
<!-- END INSTINCTS -->"
fi

# Output context injection as JSON — use python3 json.dumps for safe escaping
printf '%s' "$content" | python3 -c "
import sys, json
content = sys.stdin.read()
output = {
    'hookSpecificOutput': {
        'hookEventName': 'SessionStart',
        'additionalContext': content
    }
}
print(json.dumps(output))
"

exit 0
