#!/usr/bin/python3 -I
"""grok PostToolUse hook: hand grok its Claude Mem and Hindsight context.

grok never shows SessionStart or UserPromptSubmit hook context to the model
(vectorize-io/hindsight#5467); only tool hooks reach it. So this runs after a
tool call and emits each source once per session, one source per hook entry
because grok clips each hook's additionalContext at 10,000 characters.

Read-only. Claude Mem: a GET to the local worker. Hindsight: the text busdriver
prefetched outside the sandbox (BUSDRIVER_GROK_HINDSIGHT), because the
busdriver-review sandbox cannot run node or read the Hindsight token.
Any failure emits nothing and exits 0, so grok is never blocked.
"""
import json
import os
import re
import sys
import urllib.parse
import urllib.request

CAP = 9500


def claude_mem():
    port = int(os.environ.get("CLAUDE_MEM_WORKER_PORT") or 37700 + os.getuid() % 100)
    cwd = os.environ.get("GROK_WORKSPACE_ROOT") or os.getcwd()
    # Scheme and host are fixed and the port is an int, so no file:// or remote URL.
    url = f"http://127.0.0.1:{port}/api/context/inject?" + urllib.parse.urlencode({"cwd": cwd})
    with urllib.request.urlopen(url, timeout=8) as resp:  # nosemgrep: python.lang.security.audit.dynamic-urllib-use-detected.dynamic-urllib-use-detected
        text = resp.read().decode("utf-8", "replace")
    # The leading work-state block tells the model to call work_state_write; drop it.
    m = re.search(r"^# \[", text, re.M)
    text = text[m.start():] if m else text
    # The timeline is oldest-first, so keep the newest end.
    return ("[older entries truncated]\n" + text[-CAP:]) if len(text) > CAP else text


def hindsight():
    # Pages arrive ranked by relevance, so keep the head.
    return os.environ.get("BUSDRIVER_GROK_HINDSIGHT", "")[:CAP]


def main():
    sys.stdin.read()  # the tool result is reviewed, untrusted content: drained, never parsed
    src = sys.argv[1] if len(sys.argv) > 1 else ""
    sid = re.sub(r"[^A-Za-z0-9_-]", "", os.environ.get("GROK_SESSION_ID", ""))
    if src not in ("claude-mem", "hindsight") or not sid:
        return
    try:
        os.close(os.open(f"/tmp/busdriver-grok-mem-{src}-{sid}", os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600))
    except OSError:
        return  # already sent this session
    try:
        text = (claude_mem() if src == "claude-mem" else hindsight()).strip()
    except Exception as e:  # noqa: BLE001 - a memory miss must never block grok
        print(f"busdriver-memory: {src} skipped: {e}", file=sys.stderr)
        return
    if text:
        print(json.dumps({"hookSpecificOutput": {"hookEventName": "PostToolUse", "additionalContext": text}}))


main()
