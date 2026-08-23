#!/usr/bin/env bash
# Test: node-hook environment containment manifest guard (Task 3, ADR 0016).
#
# ADR 0016 contained the shell gates under `env -i` + sanitized-gate.sh but left
# the PURE-BLOCK node hooks inheriting the session env, so a committed
# settings.json `env` block (ECC_HOOK_PROFILE / ECC_DISABLED_HOOKS) could DISABLE
# them. Task 3 wraps those hooks in sanitized-node.sh. This test is the
# UPGRADE-TRIGGER guard: it fails if a new exit-2-capable node hook appears that
# is neither CONTAINED (wrapped) nor explicitly recorded as ACCEPTED RESIDUAL —
# so containment can't silently rot as hooks are added.
#
# Why not "just grep": the discovery grep is a HEURISTIC, not the authority.
# mcp-health-check blocks via `exitCode: shouldFailOpen() ? 0 : 2`, which a naive
# `grep 'exitCode: 2'` misses entirely. The AUTHORITY is the explicit KNOWN_EXIT2
# list below; the grep only forces NEW naive/ternary exit-2 hooks into it.
#
# #629: the source grep alone is not enough of a net. A hook can block without ever
# exiting 2 — `permissionDecision: "deny"` with exitCode 0 is the canonical PreToolUse
# block shape — and then the ONLY place its blocking-ness is declared is its hooks.json
# registration (`--fail-closed` / `|| exit 2`). Discovery is therefore the UNION of the
# source grep and the registration; KNOWN_EXIT2 stays the human authority over both.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOKS_JSON="$REPO_ROOT/hooks/hooks.json"
HOOKS_DIR="$REPO_ROOT/scripts/hooks"
PASS=0
FAIL=0
assert() {  # assert <rc:0/1> <message>
    if [[ "$1" -eq 0 ]]; then PASS=$((PASS+1)); printf '  ok   %s\n' "$2"
    else FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$2"; fi
}

# ── The authoritative classification (maintained by humans, verified below) ──
# CONTAINED: exit-2 is a gate decision that must be wrapped in sanitized-node.sh.
# mcp-health-check.js joined this set in #351: it reads MCP config from the hook
# PAYLOAD cwd (not process.cwd()), so it no longer needs its env re-imported, and
# `env -i` also wipes its ECC_MCP_RECONNECT_COMMAND shell-exec + ECC_MCP_HEALTH_FAIL_OPEN
# injection channels. See docs/adr/0016-gate-env-containment.md.
CONTAINED=(block-no-verify.js config-protection.js pre-bash-dev-server-block.js mcp-health-check.js)
# ACCEPTED RESIDUAL: exit-2 hooks left uncontained because `env -i` would change
# behavior, not just strip the injection flag. Empty since #351.
RESIDUAL=()
# The full known exit-2 universe = CONTAINED ∪ RESIDUAL. The `${RESIDUAL[@]+…}`
# guard keeps an empty RESIDUAL from tripping `set -u` on bash 3.2 (macOS default).
KNOWN_EXIT2=("${CONTAINED[@]}" ${RESIDUAL[@]+"${RESIDUAL[@]}"})
# DENY-CAPABLE: hooks that block via `permissionDecision: "deny"` rather than exit 2.
# Human authority, exactly like KNOWN_EXIT2 and for the same reason — the guard-3c grep
# cannot see a deny moved into a constant, a helper, or onto its own line, so this list is
# what actually pins those hooks. Membership demands CONTAINMENT (env -i + wrapper), NOT
# fail-closedness: gateguard-fact-force.js is `--fail-open … || exit 0` per #616.
KNOWN_DENY=(gateguard-fact-force.js)

in_list() {  # in_list <needle> <list...>
    local n="$1"; shift
    local x; for x in "$@"; do [[ "$x" == "$n" ]] && return 0; done; return 1
}

# ── 3. Discovery: any registered node hook that exits 2 must be classified ──────
# HEURISTIC net, not the authority (the KNOWN_EXIT2 list is). Tolerant of whitespace
# so `process.exit( 2 )`, `exitCode: 2`, and `exitCode = 2` all match, plus the
# fail-closed ternary `? 0 : 2` (mcp-health-check). A hook that hides its exit-2
# behind a constant or a helper call is genuinely undetectable by grep — that gap is
# WHY the explicit KNOWN_EXIT2 list is the real guard and guard #4 pins the trio.
discover_exit2() {
    { grep -lE 'process\.exit\([[:space:]]*2|exitCode[[:space:]]*[:=][[:space:]]*2' "$HOOKS_DIR"/*.js 2>/dev/null
      grep -lE '\?[[:space:]]*0[[:space:]]*:[[:space:]]*2' "$HOOKS_DIR"/*.js 2>/dev/null
    } | sort -u
}

# ── Structural registration index — the ONE hooks.json reader both nets share ───
# A LINE IS NOT A REGISTRATION. The nets below used to grep hooks.json line-wise, which is
# wrong in both directions: a JSON formatter may put `"command"` and its value on separate
# lines (the blocking tail then never appears on the hook's line, so the registration is
# invisible), and two registrations may share one line (one registration's `|| exit 2` is
# then attributed to the other's hook). So parse the document ONCE, structurally, and
# evaluate every command string on its own. Both the registration-blocking net and the
# deny-hook containment lookup read this index — the parse lives in exactly one place.
#
# Emits one record per (command, hook it names):
#     `<basename> <blocking> <contained> <disposition>`
#   blocking  1 = the registration declares the hook a gate (a `|| exit 2` tail), OR the
#                 command matches no canonical shape at all.
#   contained 1 = the registration is the canonical `env -i … bash "<wrapper>"` launch and
#                 hands THIS hook to the wrapper as its script argument.
#   disposition   the wrapper's own fail disposition — `open` under `--fail-open`, else
#                 `closed`; `-` where no wrapper is involved. It is a separate field because
#                 it can CONTRADICT the tail: `--fail-open … || exit 2` reads as blocking,
#                 but the wrapper resolves a launch failure to exit 0 and the tail never
#                 fires. See guard 1.
# Plus one `!unrecognized\t<command>` line per command matching no shape, which guard #3a
# below turns into a failure — see the shape allowlist for why that is the whole design.
# python3 is already a hard dependency of this repo's gate tooling
# (scripts/relevant-check-status.sh fails CLOSED without it) — no new dependency.
registration_index() {
    python3 - "$HOOKS_JSON" <<'PY'
import json, re, sys

doc_path = sys.argv[1]

# ── Canonical registration shapes ─────────────────────────────────────────────────────
# What this file needs of each registration is small — is it blocking, is it contained,
# which hook does it name — and what it must never do is get any of the three WRONG.
# Deciding them by parsing arbitrary shell does not converge: quoting, expansion,
# redirection, nested interpreters, comments and heredocs each give a command a meaning
# that differs from its text, and every one of those is a way for an uncontained blocking
# hook to read as safe. So the parser is gone. A registration is matched WHOLE against the
# handful of shapes this repo actually uses; anything else is `!unrecognized`, which the
# suite fails on while still emitting its hooks as blocking-and-uncontained.
#
# That inverts the burden for good: a novel command shape can no longer slip through
# quietly, it can only stop the suite until a human classifies it. Adding a genuinely new
# shape means adding it here — deliberately, in review — which is exactly the human
# authority KNOWN_EXIT2 and KNOWN_DENY already encode for the hooks themselves.
ROOT = r'\$\{CLAUDE_PLUGIN_ROOT\}'
EVENT = r'"[a-z0-9:._-]+"'
SCRIPT = r'"scripts/hooks/([A-Za-z0-9._-]+\.js)"'
PROFILES = r'"[a-z,]+"'
# Assignments carried into a sanitized-GATE launch. Those gates name no node hook, so this
# run is only ever "recognized as not our business"; the node shape below pins its own.
ASSIGN = r'(?:[A-Z_][A-Z0-9_]*(?:="[^"]*"|=[A-Za-z0-9_:/.,-]+)[ \t]+)*'

# The one shape that may claim containment: env -i, the pinned PATH, only the assignments
# the wrapper contract re-imports, and sanitized-node.sh as bash's double-quoted operand.
NODE_GATE = re.compile(
    r'/usr/bin/env -i PATH=/usr/bin:/bin (?:HOME="\$HOME" )?'
    r'CLAUDE_PLUGIN_ROOT="' + ROOT + r'" CLAUDE_HOOK_EVENT_NAME="\$CLAUDE_HOOK_EVENT_NAME" '
    r'bash "' + ROOT + r'/hooks/gate-scripts/lib/sanitized-node\.sh" '
    # ONLY `--fail-open` — `sanitized-node.sh` shifts that token and nothing else, so a
    # `--fail-closed` registration leaves four operands, trips the wrapper's arity check and
    # is force-blocked on every invocation. Accepting it here would have this file approve a
    # registration the wrapper itself rejects; as an unrecognized shape it fails loudly.
    r'(?:(--fail-open) )?' + EVENT + ' ' + SCRIPT + ' ' + PROFILES + r' \|\| exit (0|2)'
)
SHELL_GATE = re.compile(
    r'/usr/bin/env -i PATH=/usr/bin:/bin ' + ASSIGN +
    r'bash "' + ROOT + r'/hooks/gate-scripts/lib/sanitized-gate\.sh" [A-Za-z0-9._-]+\.sh'
)
RUNNER = re.compile(
    r'node "' + ROOT + r'/scripts/hooks/run-with-flags\.js" ' + EVENT + ' ' + SCRIPT
    + ' ' + PROFILES
)
BARE_NODE = re.compile(r'node "' + ROOT + r'/scripts/hooks/([A-Za-z0-9._-]+\.js)"')
# Its payload operand is normally a shell hook, but the shape does not forbid a node one —
# so capture it and index any `scripts/hooks/*.js` it names rather than assuming the runner
# is never our business. A node hook registered this way would otherwise be absent from the
# index entirely, which reads as "not wired" to every guard below.
SHELL_RUNNER = re.compile(
    r'bash "' + ROOT + r'/scripts/hooks/run-with-flags-shell\.sh" ' + EVENT
    + r' "([A-Za-z0-9._/-]+)" ' + PROFILES
)
PLAIN_BASH = re.compile(r'bash "' + ROOT + r'/(?:hooks/gate-scripts|scripts/hooks)/[A-Za-z0-9._/-]+\.sh"')
# The session-start launcher nests a whole script in a quoted `bash -lc` payload. There is
# no shape to write for it that is not just the script, so it is pinned verbatim: any edit
# to it becomes an unrecognized registration and gets re-reviewed.
SESSION_START = (
    'bash -lc \'input=$(cat); root="${CLAUDE_PLUGIN_ROOT}"; if [ -n "$root" ] && '
    '[ -f "$root/scripts/hooks/run-with-flags.js" ]; then printf "%s" "$input" | '
    'node "$root/scripts/hooks/run-with-flags.js" "session:start" '
    '"scripts/hooks/session-start.js" "minimal,standard,strict"; exit $?; fi; '
    'printf "%s" "$input"; exit 0\''
)
# Case-INSENSITIVE: this filesystem is case-insensitive, so `scripts/hooks/GATE.JS`
# executes `gate.js`. A spelling that runs the hook must not be a spelling that hides it.
HOOK = re.compile(r"scripts/hooks/([A-Za-z0-9._-]+\.js)", re.IGNORECASE)


def classify(cmd):
    """Yield (hook, blocking, contained, disposition) per registration, None if unrecognized.

    The DISPOSITION is the wrapper's, and it decides whether the `|| exit 2` tail means
    anything: under `--fail-open` the wrapper converts a missing runtime, a missing runner
    and every other launch failure to exit 0, so the outer tail never runs and the action is
    allowed. `1 1` alone therefore does not describe a fail-closed gate — the two halves can
    contradict each other, and only a record carrying both settles it.
    """
    matched = NODE_GATE.fullmatch(cmd)
    if matched:
        disposition = "open" if matched.group(1) == "--fail-open" else "closed"
        return [(matched.group(2), 1 if matched.group(3) == "2" else 0, 1, disposition)]
    matched = RUNNER.fullmatch(cmd) or BARE_NODE.fullmatch(cmd)
    if matched:
        return [(matched.group(1), 0, 0, "-")]
    if cmd == SESSION_START:
        return [("run-with-flags.js", 0, 0, "-"), ("session-start.js", 0, 0, "-")]
    matched = SHELL_RUNNER.fullmatch(cmd)
    if matched:
        operand = matched.group(1)
        named = HOOK.fullmatch(operand)
        if named:
            return [(named.group(1), 0, 0, "-")]
        if operand.lower().endswith(".js"):
            # A node hook by a path spelling this file does not index (`scripts/hooks/./x.js`)
            # must not read as "recognized, nothing to see" — that is the unwired-by-accident
            # hole again. Report it unrecognized instead.
            return None
        return []
    if SHELL_GATE.fullmatch(cmd) or PLAIN_BASH.fullmatch(cmd):
        return []
    return None


def commands(node):
    if isinstance(node, dict):
        cmd = node.get("command")
        if isinstance(cmd, str):
            yield cmd
        for value in node.values():
            for found in commands(value):
                yield found
    elif isinstance(node, list):
        for value in node:
            for found in commands(value):
                yield found


try:
    with open(doc_path) as fh:
        doc = json.load(fh)
except Exception as exc:                      # unreadable/malformed → fail CLOSED (rc 1)
    sys.stderr.write("registration_index: %s\n" % exc)
    sys.exit(1)

mentioned = set()
for cmd in commands(doc):
    # Every hook basename named ANYWHERE in a DECODED command, case-folded. The wiring
    # check downstream needs "is this hook referenced at all", and asking that of the raw
    # file text answers the wrong question twice over: a `\u0047ATE.js` escape is invisible
    # to it, and this filesystem is case-insensitive, so `GATE.js` executes `gate.js`.
    for name in HOOK.findall(cmd):
        mentioned.add(name.lower())

for cmd in commands(doc):
    records = classify(cmd)
    if records is None:
        # Unrecognized: report it, and meanwhile treat every hook it names the only safe
        # way — blocking (so it must be classified) and uncontained (so it must be wrapped).
        print("!unrecognized\t%s" % " ".join(cmd.split()))
        records = [(name, 1, 0, "-") for name in dict.fromkeys(HOOK.findall(cmd))]
    for name, blocking, contained, disposition in records:
        print("%s %d %d %s" % (name, blocking, contained, disposition))

for name in sorted(mentioned):
    print("!named %s" % name)

PY
}

# The SECOND net (#629): hooks.json declares blocking-ness directly. Any registration
# carrying `|| exit 2` (or `--fail-closed`, should a registration ever pass it — today the
# wrapper appends that token itself) names a blocking gate whatever its script returns,
# including one that blocks purely through `permissionDecision: "deny"` and is invisible to
# the source grep above. Selection is deliberately UNFILTERED: non-node registrations drop
# out on their own (they name no scripts/hooks/*.js), and a future fail-closed registration
# routed through run-with-flags.js should surface loudly rather than be silently excused.
#
# This net covers the FAIL-CLOSED-registration half of #629. A deny-capable hook whose
# registration is NOT fail-closed still blocks (`--fail-open` governs a LAUNCH failure,
# never a successful deny) — guard 3c below is the half that covers it.
discover_registered_blocking() {   # <index>
    awk '$1 !~ /^!/ && $2 == 1 { print $1 }' <<< "$1" | sort -u
}

# Union of both nets, as basenames.
discover_blocking() {   # <index>
    # Capture first (SC2312): a pipeline feed would mask each discoverer's rc.
    local _src _reg
    _src="$(discover_exit2)"; _reg="$(discover_registered_blocking "$1")"
    { sed 's|.*/||' <<< "$_src"; printf '%s\n' "$_reg"; } | sed '/^$/d' | sort -u
}

# Blocking hooks wired into hooks.json but absent from KNOWN_EXIT2.
unclassified_blocking() {   # <index>
    local out="" b _discovered _idx="$1"
    # Capture first (SC2312): a process-substitution feed would mask discover_blocking's rc.
    _discovered="$(discover_blocking "$_idx")"
    while IFS= read -r b; do
        [[ -z "$b" ]] && continue
        # Only care about hooks actually wired into hooks.json — structurally, not by line.
        grep -qE "^$b " <<< "$_idx" || continue
        in_list "$b" "${KNOWN_EXIT2[@]}" || out+="$b "
    done <<< "$_discovered"
    printf '%s' "$out"
}

# Read the document ONCE, at top level so a parse failure can abort for real (an `exit`
# inside a command substitution would only end the subshell and read as an empty, green net).
REG_INDEX="$(registration_index)" \
  || { printf '  FAIL %s\n' "hooks.json parsed structurally (see stderr)"; exit 1; }

# ── 1. Every CONTAINED hook's registration routes through the wrapper ───────────
# EVERY registration naming the hook must be the canonical wrapped launch — `/usr/bin/env
# -i` (which is what wipes ECC_HOOK_PROFILE / ECC_DISABLED_HOOKS; the wrapper rebuilds PATH
# but does NOT itself clear those flags) handing sanitized-node.sh this hook as its script
# — AND carry the fail-closed `|| exit 2` tail. That tail matters on its own: if bash cannot
# launch the wrapper (bad CLAUDE_PLUGIN_ROOT, missing file, ENOEXEC) the command exits
# 1/126/127 BEFORE the wrapper's internal fail-closed runs, a non-2 exit the harness treats
# as non-blocking — UNLESS the wrapper itself is fail-open, in which case it swallows that
# launch failure as exit 0 and the tail never runs, so the disposition must be `closed` too.
# In index terms: `<hook> 1 1 closed`.
#
# Read from the structural index, like every other guard here — these two used to grep
# physical LINES, which made "one structural reader" untrue and carried exactly the defect
# the other nets were fixed for: compacting the document onto one line let an unrelated
# bare-node registration sharing that line satisfy a contained hook's lookup.
for h in "${CONTAINED[@]}"; do
    _recs="$(awk -v hook="$h" '$1 == hook { print ($2 == 1 && $3 == 1 && $4 == "closed") ? "ok" : "bad" }' <<< "$REG_INDEX")"
    _found=0; _bad=0
    while IFS= read -r _rec; do
        [[ -z "$_rec" ]] && continue
        _found=$((_found+1))
        [[ "$_rec" == "ok" ]] || _bad=1
    done <<< "$_recs"
    if [[ "$_found" -ge 1 && "$_bad" -eq 0 ]]; then
        assert 0 "$h: every registration launches via /usr/bin/env -i + sanitized-node.sh, fail-closed with || exit 2"
    else
        assert 1 "$h: every registration launches via /usr/bin/env -i + sanitized-node.sh, fail-closed with || exit 2"
    fi
done

# ── 2. No CONTAINED hook has a bare (un-wrapped) registration ──────────────────
# The same index, asked the complementary question: any record for the hook that is not
# contained is a launch outside the wrapper, whatever shape it wears.
for h in "${CONTAINED[@]}"; do
    if awk -v hook="$h" '$1 == hook && $3 != 1 { bare = 1 } END { exit !bare }' <<< "$REG_INDEX"; then
        assert 1 "$h has NO bare 'node run-with-flags.js' registration"
    else
        assert 0 "$h has NO bare 'node run-with-flags.js' registration"
    fi
done

# ── 3a. Every registration matches a canonical shape (#629) ────────────────────
# The index reports a command it cannot classify rather than guessing at it. That report is
# the reason the shape allowlist is safe to be narrow: an unrecognized registration stops
# the suite instead of being quietly assumed harmless, and its hooks are meanwhile treated
# as blocking-and-uncontained. Widening the allowlist is a deliberate, reviewed act.
_unrecognized="$(grep '^!unrecognized' <<< "$REG_INDEX" | cut -f2-)"
if [[ -z "$_unrecognized" ]]; then
    assert 0 "every hooks.json registration matches a canonical launch shape"
else
    printf '  ↳ unrecognized registration(s):\n'
    printf '      %s\n' "$_unrecognized"
    printf '  ↳ ADD the shape to the allowlist in registration_index (deliberately, in review)\n'
    assert 1 "every hooks.json registration matches a canonical launch shape"
fi

unclassified="$(unclassified_blocking "$REG_INDEX")"
if [[ -z "$unclassified" ]]; then
    assert 0 "no unclassified blocking node hooks (all are CONTAINED or ACCEPTED RESIDUAL)"
else
    printf '  ↳ unclassified: %s\n' "$unclassified"
    printf '  ↳ ADD each to CONTAINED (and wrap in hooks.json) or to RESIDUAL (and document in ADR 0016)\n'
    assert 1 "no unclassified blocking node hooks (all are CONTAINED or ACCEPTED RESIDUAL)"
fi

# ── 3b. Regression (#629): the registration net actually fires ──────────────────
# Guard #3 can only prove itself on a tree that HAS an unclassified blocking hook, and the
# real tree does not (#616 landed). So mutate a throwaway tree into exactly the shape that
# used to slip through: a hook that blocks via permissionDecision with exitCode 0, wired in
# with a fail-closed `|| exit 2` registration and absent from KNOWN_EXIT2. The second assert
# is the negative control — it pins that the SOURCE grep misses it, so a pass on the first
# can only come from the registration net.
#
# The ONE fixture also carries the layouts a line-oriented reader gets wrong, so structural
# per-registration isolation is proven rather than asserted: `"command"` split from its
# value across lines, a tab and non-canonical spacing around the fail-closed tail, and a
# decoy hook sharing its LINE with an unrelated blocking registration — the decoy must NOT
# be classified as blocking, which is precisely what the old line grep got wrong.
_fix="$(mktemp -d)"
# Fail CLOSED on a mktemp failure: an empty $_fix would write the fixture to /hooks and
# /scripts/hooks and leave the EXIT trap unable to clean up.
[[ -n "$_fix" && -d "$_fix" ]] || { printf '  FAIL %s\n' "regression fixture tempdir created"; exit 1; }
trap 'rm -rf "$_fix"' EXIT
mkdir -p "$_fix/hooks" "$_fix/scripts/hooks"
cat > "$_fix/scripts/hooks/synthetic-deny-gate.js" <<'JS'
// Blocks via permissionDecision with exitCode 0 — never exits 2, so the exit-2 grep
// cannot see it. Only the registration below declares it blocking.
//
// The decision is deliberately spelled across LINES, the way a formatter wraps a long
// object literal: a line-oriented deny scan sees neither half and the hook drops out of
// the deny net silently. Guard 3b asserts below that it is still found.
module.exports = () => ({
  stdout: JSON.stringify({
    hookSpecificOutput: {
      permissionDecision:
        'deny',
    },
  }),
  exitCode: 0,
});
JS
cat > "$_fix/hooks/hooks.json" <<'JSON'
{ "hooks": { "PreToolUse": [ { "matcher": "Edit|Write", "hooks": [
  { "type": "command",
    "command":
      "node \"${CLAUDE_PLUGIN_ROOT}/scripts/hooks/synthetic-deny-gate.js\" ||\texit  2" },
  { "type": "command", "command": "node \"${CLAUDE_PLUGIN_ROOT}/scripts/hooks/synthetic-decoy.js\"" }, { "type": "command", "command": "bash \"${CLAUDE_PLUGIN_ROOT}/hooks/gate-scripts/unrelated.sh\" || exit 2" },
  { "type": "command",
    "command": "/usr/bin/env -i PATH=/usr/bin:/bin CLAUDE_PLUGIN_ROOT=\"${CLAUDE_PLUGIN_ROOT}\" CLAUDE_HOOK_EVENT_NAME=\"$CLAUDE_HOOK_EVENT_NAME\" bash \"${CLAUDE_PLUGIN_ROOT}/hooks/gate-scripts/lib/sanitized-node.sh\" \"pre:synthetic\" \"scripts/hooks/synthetic-canonical-gate.js\" \"strict\" || exit 2" }
] } ] } }
JSON
# Subshells so the fixture paths can never leak into the guards below.
_fixture_index="$( HOOKS_JSON="$_fix/hooks/hooks.json"; registration_index )"
_fixture_unclassified="$( HOOKS_JSON="$_fix/hooks/hooks.json"; HOOKS_DIR="$_fix/scripts/hooks"; unclassified_blocking "$_fixture_index" )"
_fixture_src_only="$( HOOKS_DIR="$_fix/scripts/hooks"; discover_exit2 )"
_m1="registration-only permissionDecision gate is discovered and flagged unclassified"
_m2="↳ control: the source grep alone does NOT see it (the registration net is what fired)"
_m3="↳ structural isolation: split key/value + tab-spaced tail found, shared-line decoy not blamed"
_m4="↳ a canonical fail-closed registration is classified by the RULE, not the unrecognized fallback"
if [[ "$_fixture_unclassified" == *"synthetic-deny-gate.js"* ]]; then assert 0 "$_m1"; else assert 1 "$_m1"; fi
if [[ -z "$_fixture_src_only" ]]; then assert 0 "$_m2"; else assert 1 "$_m2"; fi
if [[ "$_fixture_unclassified" != *"synthetic-decoy.js"* ]]; then assert 0 "$_m3"; else assert 1 "$_m3"; fi
# `1 1` = blocking AND contained, which only the canonical NODE_GATE shape can produce;
# the `!unrecognized` fallback can only ever emit `1 0`.
if grep -qx "synthetic-canonical-gate.js 1 1 closed" <<< "$_fixture_index"; then assert 0 "$_m4"; else assert 1 "$_m4"; fi

# ── 3c. Deny-capable node hooks must be CONTAINED (#629) ───────────────────────
# The third discovery class. `permissionDecision: "deny"` blocks the tool call from a hook
# that ran SUCCESSFULLY, so the registration tail says nothing about it: `--fail-open …
# || exit 0` only resolves a LAUNCH failure to ALLOW. Such a hook is therefore invisible to
# both nets above, and what it must satisfy is CONTAINMENT — `env -i` + the wrapper, so a
# committed settings.json `env` block can't disable it — NOT fail-closedness. Guard #1 is
# left alone deliberately: gateguard-fact-force.js is `--fail-open … || exit 0` by the
# settled #616 decision, and demanding `|| exit 2` of it would reopen that. Same heuristic
# caveat as the exit-2 grep: a deny hidden behind a constant is not greppable, which is why
# the explicit lists stay the human authority.
discover_deny_capable() {
    # WHOLE-FILE, not line-by-line. `permissionDecision:` and its value routinely land on
    # separate lines once a formatter wraps a long object literal, and a line-oriented grep
    # sees neither half as a deny — the hook then bypasses KNOWN_DENY, `env -i` and the
    # wrapper checks entirely. `\s` spans the newline.
    #
    # The value's quote is CAPTURED and must close with the same character, so `'deny'`,
    # `"deny"` and a `` `deny` `` template literal all match while a mismatched pair —
    # which is not valid JS and does not produce a deny decision — does not.
    python3 - "$HOOKS_DIR" <<'PY'
import glob, os, re, sys

DENY = re.compile(r"""(?:['"`]?permissionDecision['"`]?)\s*:\s*(['"`])deny\1""")
for path in sorted(glob.glob(os.path.join(sys.argv[1], "*.js"))):
    try:
        with open(path, errors="replace") as handle:
            body = handle.read()
    except OSError:          # unreadable file: report it rather than pass it over
        print(os.path.basename(path))
        continue
    if DENY.search(body):
        print(os.path.basename(path))
PY
}

_m5="↳ a deny decision split across lines is still discovered (whole-file scan)"
_fixture_deny="$( HOOKS_DIR="$_fix/scripts/hooks"; discover_deny_capable )"
if grep -qx "synthetic-deny-gate.js" <<< "$_fixture_deny"; then assert 0 "$_m5"; else assert 1 "$_m5"; fi
# Capture first (SC2312): a process-substitution feed would mask discover_deny_capable's rc.
# The `${KNOWN_DENY[@]+…}` guard keeps an emptied list from tripping `set -u` on bash 3.2
# (macOS default), exactly as RESIDUAL above does.
_deny_grep="$(discover_deny_capable)"
# UNION with the human list, so a deny that stops being greppable stays guarded.
_deny="$( { printf '%s\n' "$_deny_grep"; printf '%s\n' ${KNOWN_DENY[@]+"${KNOWN_DENY[@]}"}; } \
          | sed '/^$/d' | sort -u )"
while IFS= read -r _dh; do
    [[ -z "$_dh" ]] && continue
    # Only care about hooks actually wired into hooks.json — read from the structural
    # index, so a split-line or shared-line registration is judged on its own command.
    _regs="$(awk -v h="$_dh" '$1 == h { print $3 }' <<< "$REG_INDEX")"
    if [[ -z "$_regs" ]]; then
        # Not wired at all is fine. NAMED in hooks.json yet resolving to no registration is
        # not: a dynamically-built path (`scripts/hooks/${HOOK_NAME:-the-gate.js}`) runs the
        # hook while producing no record, and silently skipping it would retire the guard.
        # Asked of the DECODED commands, case-folded — see the `!named` note in the index.
        grep -qx "!named $(tr '[:upper:]' '[:lower:]' <<< "$_dh")" <<< "$REG_INDEX" || continue
        assert 1 "$_dh (deny-capable): named in hooks.json but no registration resolves to it"
        continue
    fi
    _lines=0; _bad=0
    while IFS= read -r _contained; do
        [[ -z "$_contained" ]] && continue
        _lines=$((_lines+1))
        [[ "$_contained" == "1" ]] || _bad=1
    done <<< "$_regs"
    _dm="$_dh (deny-capable): every registration launches via /usr/bin/env -i + sanitized-node.sh"
    if [[ "$_lines" -ge 1 && "$_bad" -eq 0 ]]; then assert 0 "$_dm"; else assert 1 "$_dm"; fi
done <<< "$_deny"

# KNOWN_DENY is an AUTHORITY, not decoration. Containment alone is not enough: a NEW
# greppable deny gate could satisfy 3c while never being listed, and the day its deny
# literal moves behind a constant it drops out of the grep with nothing left pinning it —
# the net silently shrinks and no assertion fails. So a wired, source-discovered deny hook
# that nobody added to the list is an unclassified failure, mirroring guard #3.
_deny_unlisted=""
while IFS= read -r _dh; do
    [[ -z "$_dh" ]] && continue
    grep -qE "^$_dh " <<< "$REG_INDEX" || continue
    in_list "$_dh" ${KNOWN_DENY[@]+"${KNOWN_DENY[@]}"} || _deny_unlisted+="$_dh "
done <<< "$_deny_grep"
if [[ -z "$_deny_unlisted" ]]; then
    assert 0 "every discovered deny-capable hook is recorded in KNOWN_DENY"
else
    printf '  ↳ unlisted deny-capable: %s\n' "$_deny_unlisted"
    printf '  ↳ ADD each to KNOWN_DENY (it is what still pins the hook once the literal moves)\n'
    assert 1 "every discovered deny-capable hook is recorded in KNOWN_DENY"
fi

# Sanity, mirroring guard #4: the deny grep must still see every listed hook, so a refactor
# that hides the literal is caught here instead of silently shrinking the net.
for _dh in ${KNOWN_DENY[@]+"${KNOWN_DENY[@]}"}; do
    _dm="deny grep still detects $_dh"
    if grep -q "^$_dh\$" <<<"$_deny_grep"; then assert 0 "$_dm"; else assert 1 "$_dm"; fi
done

# ── 4. Sanity: the discovery grep actually still finds the CONTAINED trio ───────
# (guards against a future refactor that hides their exit-2 from discovery,
# which would silently weaken guard #3.)
found="$(discover_exit2)"
for h in "${CONTAINED[@]}"; do
    if grep -q "/$h\$" <<<"$found"; then
        assert 0 "discovery grep still detects $h"
    else
        assert 1 "discovery grep still detects $h"
    fi
done

# ── 5. The wrapper exists and is fail-closed (blocks when node/runner absent) ───
[[ -f "$REPO_ROOT/hooks/gate-scripts/lib/sanitized-node.sh" ]]; assert $? "sanitized-node.sh launcher exists"
grep -q '"decision":"block"' "$REPO_ROOT/hooks/gate-scripts/lib/sanitized-node.sh"; assert $? "launcher has a fail-closed block path"

echo ""
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
echo "ALL NODE-HOOK CONTAINMENT ASSERTIONS PASSED"
