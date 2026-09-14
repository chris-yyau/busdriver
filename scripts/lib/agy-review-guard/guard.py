import json, os, sys, time

# Deny-by-default read-only guard: only these native read tools may run.
READ_ONLY = {"view_file", "list_dir", "grep_search", "find_by_name"}
here = os.path.dirname(os.path.abspath(__file__))
try:
    call = json.load(sys.stdin).get("toolCall") or {}
except Exception as e:
    call = {"name": "", "parse_error": str(e)}
name = call.get("name", "")
allowed = name in READ_ONLY
out = {"decision": "allow" if allowed else "deny",
       "reason": "read-only guard %s tool %r" % ("allowed" if allowed else "denied", name)}
with open(os.path.join(here, "guard.log"), "a") as f:
    f.write(json.dumps({"ts": time.time(), "tool": name, "decision": out["decision"], "args": call.get("args")}) + "\n")
print(json.dumps(out))
