#!/usr/bin/env python3
"""CLV2 fast-path writer: replaces observe.sh's three inline python blocks
(parse, validate, build+scrub+write) plus rotation/purge with ONE spawn.

Bash owns: all guards, project detection (cached), observer lazy-start/signal.
Contract: INPUT_JSON on stdin; HOOK_PHASE, PROJECT_ID, PROJECT_NAME,
PROJECT_DIR via env. Output is schema-parity with the legacy inline blocks
(tests/test-observe-parity.sh); the str() fallback for non-dict tool I/O is
INTENTIONAL parity behavior (legacy observe.sh str() fallback) — do not "fix"
it here without a separately-scoped behavior change + test.
"""
import json
import os
import re
import signal
import sys
import time


def _bail(*_):
    # Self-terminate before the async hook 10s timeout can orphan us (#2300)
    print("[observe] SIGALRM timeout: observation dropped before write (#2300)",
          file=sys.stderr)
    sys.exit(0)


try:
    signal.signal(signal.SIGALRM, _bail)
    signal.alarm(8)
except Exception:
    pass

# Linear-time secret matcher — bounded quantifiers and a fixed set of auth
# schemes prevent the catastrophic backtracking that pegged python at 100%
# CPU (#2278). Port of the legacy pattern, byte-for-byte semantics.
_SECRET_RE = re.compile(
    r"(?i)(api[_-]?key|token|secret|password|authorization|credentials?|auth)"
    r"(['\"\s:=]{1,8})"
    r"((?:bearer|basic|token|bot)\s+)?"
    r"([A-Za-z0-9_\-/.+=]{8,256})"
)


def scrub(v):
    if v is None:
        return None
    return _SECRET_RE.sub(
        lambda m: m.group(1) + m.group(2) + (m.group(3) or "") + "[REDACTED]",
        str(v))


pdir = os.environ.get("PROJECT_DIR", "")
if not pdir:
    sys.exit(0)
obs_file = os.path.join(pdir, "observations.jsonl")
ts = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
raw = sys.stdin.read()
if not raw.strip():
    sys.exit(0)
phase = os.environ.get("HOOK_PHASE", "post")

try:
    data = json.loads(raw)
    if not isinstance(data, dict):
        raise ValueError("payload is not a JSON object")
except Exception:
    # Parse-error fallback: log scrubbed raw input for debugging (legacy parity)
    os.makedirs(pdir, exist_ok=True)
    with open(obs_file, "a") as fh:
        fh.write(json.dumps({"timestamp": ts, "event": "parse_error",
                             "raw": scrub(raw[:2000])}) + "\n")
    sys.exit(0)

# 30-day purge, throttled to once/day, RECURSIVE — parity with legacy
# `find "$PROJECT_DIR" -name "observations-*.jsonl" -mtime +30 -delete`
# (includes observations.archive/).
marker = os.path.join(pdir, ".last-purge")
try:
    stale = os.path.getmtime(marker) < time.time() - 86400
except OSError:
    stale = True
if stale:
    cutoff = time.time() - 30 * 86400
    for root, _dirs, names in os.walk(pdir):
        for n in names:
            if n.startswith("observations-") and n.endswith(".jsonl"):
                p = os.path.join(root, n)
                try:
                    if os.path.getmtime(p) < cutoff:
                        os.remove(p)
                except OSError:
                    pass
    try:
        open(marker, "w").close()
    except OSError:
        pass

# 10MB rotation — port of the legacy archive block (atomic rename, unique suffix)
try:
    if os.path.getsize(obs_file) >= 10 * 1024 * 1024:
        adir = os.path.join(pdir, "observations.archive")
        os.makedirs(adir, exist_ok=True)
        os.rename(obs_file, os.path.join(
            adir,
            "observations-%s-%d.jsonl" % (time.strftime("%Y%m%d-%H%M%S"),
                                          os.getpid())))
except OSError:
    pass

tool = data.get("tool_name", data.get("tool", "unknown"))
ti = data.get("tool_input", data.get("input", {}))
to = data.get("tool_response")
if to is None:
    to = data.get("tool_output", data.get("output", ""))

obs = {"timestamp": ts,
       "event": "tool_start" if phase == "pre" else "tool_complete",
       "tool": tool,
       "session": data.get("session_id", "unknown"),
       "project_id": os.environ.get("PROJECT_ID") or "global",
       "project_name": os.environ.get("PROJECT_NAME") or "global"}
# Truncate-then-scrub order + str() fallback + conditional field emission:
# byte-parity with the legacy inline blocks.
if phase == "pre":
    v = scrub((json.dumps(ti) if isinstance(ti, dict) else str(ti))[:5000])
    if v:
        obs["input"] = v
else:
    v = scrub((json.dumps(to) if isinstance(to, dict) else str(to))[:5000])
    if v is not None:
        obs["output"] = v

os.makedirs(pdir, exist_ok=True)
with open(obs_file, "a") as fh:
    fh.write(json.dumps(obs) + "\n")
