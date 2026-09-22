import json, os, sys, time

# Deny-by-default read-only guard: only these native read tools may run.
# agy treats an EMPTY hook reply as allow, so the decision is printed before anything else that can
# fail, and malformed input of any shape is a deny.
READ_ONLY = {"view_file", "list_dir", "grep_search", "find_by_name"}
try:
    call = json.load(sys.stdin).get("toolCall")
except Exception:
    call = None
if not isinstance(call, dict):
    call = {}
name = call.get("name")
if not isinstance(name, str):
    name = ""
allowed = name in READ_ONLY
out = {"decision": "allow" if allowed else "deny",
       "reason": "read-only guard %s tool %r" % ("allowed" if allowed else "denied", name)}
print(json.dumps(out), flush=True)
try:
    with open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "guard.log"), "a") as f:
        f.write(json.dumps({"ts": time.time(), "tool": name, "decision": out["decision"], "args": call.get("args")}) + "\n")
except Exception:
    pass  # audit log is best-effort; the decision above is already delivered
