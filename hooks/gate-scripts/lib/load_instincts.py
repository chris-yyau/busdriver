#!/usr/bin/env python3
"""Instinct loading for SessionStart hook."""
import os, glob, re, subprocess, hashlib
from datetime import datetime

MAX_INSTINCTS = 20
MAX_FILE_SIZE = 10240
MIN_CONFIDENCE = 0.7


def sanitize(s, max_len=200):
    s = re.sub(r'<[^>]+>', '', s)
    s = re.sub(r'```', '', s)
    s = s.replace('<!--', '').replace('-->', '')
    s = re.sub(r'\[([^\]]*)\]\([^)]*\)', r'\1', s)
    s = re.sub(r'[*_~`]{1,3}', '', s)
    s = re.sub(r'\n+', ' ', s)
    s = re.sub(r'#+ ', '', s)
    s = re.sub(r'!\[', '[', s)
    s = re.sub(r'\s+', ' ', s).strip()
    return s[:max_len]


dirs = [
    os.path.expanduser("~/.claude/homunculus/instincts/inherited"),
    os.path.expanduser("~/.claude/homunculus/instincts/personal"),
]

_project_root = os.environ.get("CLAUDE_PROJECT_DIR", "")
_remote = ""
_git_dir = _project_root or "."
try:
    _remote = subprocess.check_output(
        ["git", "-C", _git_dir, "remote", "get-url", "origin"],
        stderr=subprocess.DEVNULL, text=True
    ).strip()
    _remote = re.sub(r"://[^@]+@", "://", _remote)
except Exception:
    pass

_hash_input = _remote or _project_root or ""
if not _hash_input:
    try:
        _hash_input = subprocess.check_output(
            ["git", "rev-parse", "--show-toplevel"],
            stderr=subprocess.DEVNULL, text=True
        ).strip()
    except Exception:
        pass

_hashes_to_check = []
if _hash_input:
    _project_hash = hashlib.sha256(_hash_input.encode()).hexdigest()[:12]
    try:
        _raw_remote = subprocess.check_output(
            ["git", "-C", _project_root or ".", "remote", "get-url", "origin"],
            stderr=subprocess.DEVNULL, text=True
        ).strip()
        if _raw_remote and _raw_remote != _hash_input:
            _legacy_hash = hashlib.sha256(_raw_remote.encode()).hexdigest()[:12]
            if _legacy_hash != _project_hash:
                _hashes_to_check.append(_legacy_hash)
    except Exception:
        pass
    _hashes_to_check.append(_project_hash)
    for _ph in _hashes_to_check:
        for subdir in ["inherited", "personal"]:
            p = os.path.expanduser(f"~/.claude/homunculus/projects/{_ph}/instincts/{subdir}")
            if os.path.isdir(p):
                dirs.append(p)

PENDING_TTL_DAYS = 30
PENDING_NOTIFY_THRESHOLD = 5
pending_count = 0
pending_expired = 0


def _check_pending_dir(pdir):
    global pending_count, pending_expired
    if not os.path.isdir(pdir):
        return
    for pf in glob.glob(os.path.join(pdir, "*.md")):
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
        else:
            try:
                mtime = os.path.getmtime(pf)
                if (datetime.now() - datetime.fromtimestamp(mtime)).days > PENDING_TTL_DAYS:
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


_check_pending_dir(os.path.expanduser("~/.claude/homunculus/instincts/pending"))
if _hash_input:
    for _ph in _hashes_to_check:
        _check_pending_dir(
            os.path.expanduser(f"~/.claude/homunculus/projects/{_ph}/instincts/pending")
        )

instincts = []
for d in dirs:
    if not os.path.isdir(d):
        continue
    for path in sorted(glob.glob(os.path.join(d, "*.md"))):
        if os.path.islink(path):
            continue
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

        source = meta.get("source", "")
        promoted = meta.get("promoted", "").lower() in ("true", "yes", "1")
        if source == "session-observation" and not promoted:
            pending_count += 1
            continue

        inst_id = meta.get("id", os.path.basename(path).replace(".md", ""))
        trigger = meta.get("trigger", "")
        domain = meta.get("domain", "general")

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

seen_ids = {}
for item in instincts:
    seen_ids[item[1]] = item
instincts = list(seen_ids.values())
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
        print(f"\n**{pending_count} pending instinct(s) awaiting review.** Run `/instinct-status` to review, `/promote` to activate.")
    elif pending_count:
        print(f"\n*{pending_count} pending instinct(s) awaiting promotion.* Review: `/instinct-status`")
