#!/usr/bin/env python3
"""agy >=1.2 stream-json review transport helpers (#840). Run with `python3 -I`.

  encode        prompt bytes on stdin -> one stream-json NDJSON user message on stdout (no newline)
  reduce <rc>   agy's captured stream (stdout+stderr merged) on stdin, agy's exit code as <rc>
                -> the final response on stdout, exit 0; anything else -> reason on stdout, exit != 0

The caller (`_agy_stream_review` in resolve-cli.sh) runs agy itself under `_portable_timeout --review
agy`; this file never launches a process. A reduce exit 0 means a COMPLETE transport result only — never
a review verdict or PASS; the review loop's own verdict/countability rules still decide that.
"""
import json
import sys


def encode(prompt_bytes):
    # Strict UTF-8: a prompt byte is never silently replaced.
    text = prompt_bytes.decode("utf-8")
    msg = {"event": "user", "message": {"content": [{"type": "text", "text": text}]}}
    return json.dumps(msg, ensure_ascii=False).encode("utf-8")


def reduce_stream(raw_bytes, rc):
    """Return (ok, response, reason). stderr is merged into raw_bytes by the caller, so any stderr
    line (agy reports a --print-timeout partial as exit 0 plus a warning) fails the every-line-is-an-
    event rule. Also required: rc 0, exactly one terminal result as the LAST event, status SUCCESS,
    no error, num_turns >= 1, a non-empty response and no denied_actions."""
    if rc != 0:
        return False, "", "exit %d" % rc
    try:
        # NDJSON is newline-delimited only: splitlines() would also split on U+2028/U+2029, which
        # are legal unescaped inside a JSON string.
        lines = raw_bytes.decode("utf-8", "strict").split("\n")
    except UnicodeDecodeError:
        return False, "", "stream is not UTF-8"
    events = []
    for n, line in enumerate(lines, 1):
        if not line.strip():
            continue
        try:
            ev = json.loads(line)
        except ValueError:
            return False, "", "line %d is not a stream event" % n
        if not isinstance(ev, dict) or "event" not in ev:
            return False, "", "line %d is not a stream event" % n
        events.append(ev)
    results = [i for i, ev in enumerate(events) if ev["event"] == "result"]
    if len(results) != 1 or results[0] != len(events) - 1:
        return False, "", "missing, repeated or non-final result event"
    res = events[-1].get("result")
    if not isinstance(res, dict) or res.get("status") != "SUCCESS" or res.get("error"):
        return False, "", "result status %r" % (res.get("status") if isinstance(res, dict) else None)
    if not isinstance(res.get("num_turns"), int) or isinstance(res.get("num_turns"), bool) or res["num_turns"] < 1:
        return False, "", "num_turns < 1"
    if not isinstance(res.get("response"), str) or not res["response"].strip():
        return False, "", "empty response"
    if res.get("denied_actions"):
        # Headless permission denial ends the turn early (observed on 1.2.2: SUCCESS + denied_actions).
        return False, "", "denied_actions %s" % json.dumps(res["denied_actions"])
    return True, res["response"], "ok"


def main(argv):
    if len(argv) == 2 and argv[1] == "encode":
        try:
            sys.stdout.buffer.write(encode(sys.stdin.buffer.read()))
        except UnicodeDecodeError:
            sys.stderr.write("agy stream review: prompt is not valid UTF-8 — refusing to re-encode it\n")
            return 1
        return 0
    if len(argv) == 3 and argv[1] == "reduce" and argv[2].isdigit():
        rc = int(argv[2])
        raw = sys.stdin.buffer.read()
        ok, response, reason = reduce_stream(raw, rc)
        if ok:
            sys.stdout.write(response)
            return 0
        sys.stdout.write("agy stream review rejected: %s\n" % reason)
        sys.stdout.buffer.write(raw[-2000:])
        return rc if rc != 0 else 1
    sys.stderr.write("usage: agy-stream-review.py encode | reduce <rc>\n")
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
