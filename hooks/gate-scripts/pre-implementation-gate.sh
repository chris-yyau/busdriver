#!/usr/bin/env bash
# PreToolUse hook: block implementation code when design docs are unreviewed
#
# When a design/plan doc is written, check-design-document.sh flags it in
# $STATE_DIR/design-review-needed.local.md. This hook blocks Write/Edit of
# implementation files AND file-modifying Bash commands until design review
# completes.
#
# Without this hook, Claude writes the plan, ignores the "run /blueprint-review"
# warning, and starts writing implementation code — the design review gate only
# fires at commit time, which is too late.
#
# Fail-CLOSED: errors block writes (user preference: stuck > skipped review)
# Skip: $STATE_DIR/skip-design-review.local

set -euo pipefail
# ── Harness-portable state resolution ──────────────────────────────────
# BUSDRIVER_STATE_DIR: state-dir override, defaults to .claude.
# Constrain to a safe relative name (reject absolute/traversal/unsafe chars) so
# repo-root joins resolve correctly and the value is safe to embed in messages.
STATE_DIR="${BUSDRIVER_STATE_DIR:-.claude}"
# Reject absolute, traversal, bad chars — AND any value os.path.normpath would
# collapse (bare `.`, trailing `/`, `./` prefix, `/.` suffix, `//` or `/./`
# segments). The detector greps STATE_DIR against the RAW path while the
# exemption greps the NORMALIZED path; a normalize-unstable STATE_DIR would arm a
# review the exemption then can't match — deadlocking that doc. Default is stable.
case "$STATE_DIR" in ""|.|/*|*/|./*|*/.|*//*|*/./*|*..*|*[!a-zA-Z0-9._/-]*) STATE_DIR=".claude" ;; esac
# Re-export the sanitized value so downstream consumers (the embedded Python
# rm/mkdir allowlist below, sourced helpers) read the constrained STATE_DIR
# rather than the raw env var — otherwise a traversal value could bypass them.
export BUSDRIVER_STATE_DIR="$STATE_DIR"
# Fail-CLOSED: errors block implementation writes rather than silently approving.
# User preference: "a stuck session is better than a skipped review."
# Escape hatch: $STATE_DIR/skip-design-review.local
trap 'printf "{\"decision\":\"block\",\"reason\":\"Pre-implementation gate error — blocking as precaution. If stuck, create %s/skip-design-review.local in your terminal.\"}\n" "$STATE_DIR"; exit 0' ERR

# ── Block emission helper (F6 fix) ────────────────────────────────────
# Uses jq when available, falls back to printf when jq is missing.
block_emit() {
    if command -v jq &>/dev/null; then
        jq -n --arg r "$1" '{decision:"block", reason:$r}'
    else
        local escaped
        escaped=$(printf '%s' "$1" | sed 's/"/\\"/g' | head -c 2000)
        printf '{"decision":"block","reason":"%s"}\n' "$escaped"
    fi
}

# ── Shared marker helpers (Task 2) ────────────────────────────────────
# Sourced BEFORE the python3 pre-check so its pure-shell fallback is available,
# and before the read-gate below uses gate_marker_pending.
_GATE_LIBDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
# shellcheck source=lib/resolve-repo-dir.sh disable=SC1091
source "$_GATE_LIBDIR/resolve-repo-dir.sh"

# #347 item 1 — fail-closed pre-arm. Called just before a Write/Edit/MultiEdit design
# doc is EXEMPTED below. The PostToolUse detector arms the review marker AFTER the
# write but structurally cannot block, so a post-resolution arm failure (marker dir
# resolvable, token write fails) used to silently lose the review requirement — a
# fail-OPEN (design §2/§9, confirmed HIGH in #346). Here, PRE-write, we arm and BLOCK
# when the arm fails while the infra IS resolvable. It returns 0 (proceed to exempt)
# or emits a block decision and returns 1; the caller `exit 0`s either way (an emitted
# block on stdout is what the harness acts on).
#
# It ARMS only for a doc that is neither already honorably-reviewed nor already armed —
# i.e. a genuinely new/unreviewed design doc, the exact initial-arm the residual could
# lose. blueprint-review stamps PASS + prunes via its OWN script (guard-invisible), so
# this never re-arms a doc mid-review. A NEW doc in a NOT-yet-created dir has no norm
# yet → pre-existing §2 best-effort miss (NOT the residual we close) → proceed, and the
# PostToolUse detector best-efforts. Bash-redirect design-doc creation also stays
# PostToolUse best-effort (documented residual — this branch is Write/Edit only).
_design_prearm_or_block() {   # <abspath> <tool>   ; 0 = proceed, 1 = block emitted
    local doc="$1" tool="$2" norm dir sha lib t dcode
    # Mirror the PostToolUse detector's flag logic so the two never disagree on WHETHER a
    # doc needs (re)arming: a Write REWRITES the doc → re-open review even if it currently
    # carries PASS (a rewrite that removes/replaces PASS must not slip through unarmed —
    # #347 round-3 finding); an Edit/MultiEdit is a small change, so a doc that is already
    # honorably reviewed is left alone (blueprint-review's own PASS edits go through its
    # script, not this tool). A NEW doc has no honored PASS under either branch → armed.
    case "$tool" in
        Edit|MultiEdit) gate_design_pass_honored "$doc" && return 0 ;;
    esac
    norm="$(gate_marker_norm_path "$doc")" || return 0   # parent dir absent → §2 best-effort miss
    # Resolve the marker dir. ENOREPO (exit 3) → nothing to arm here (the read gate allows
    # too), proceed. ANY OTHER failure (common-dir unresolvable, exit 1) must NOT proceed:
    # fall through to the arm attempt, which also fails → BLOCK (fail-CLOSED). Proceeding
    # would re-open the exact residual this closes on a transient unreadable common-dir.
    dcode=0; dir="$(gate_marker_dir "$(dirname -- "$norm")")" || dcode=$?
    [ "$dcode" = "3" ] && return 0
    # "Already armed for THIS doc?" is a best-effort spam-avoidance check; only trust it
    # when the dir AND the sha helper both resolved. If either is unavailable, SKIP it and
    # fall through to the arm attempt — never treat an unresolvable helper as "armed".
    if [ "$dcode" = "0" ] && lib="$(_gate_marker_lib_dir)" \
        && sha="$(python3 -S "$lib/marker_ops.py" sha "$norm" 2>/dev/null)"; then
        for t in "$dir/$sha".*; do [ -e "$t" ] && return 0; done   # already armed → skip re-arm
    fi
    gate_marker_arm "$doc" && return 0                   # armed durably → proceed
    # Arm failed while the marker dir was resolvable: THIS is the item-1 residual.
    block_emit "BLOCKED (fail-closed): could not arm the design-review marker for this document, but its marker directory IS resolvable — so allowing the write would silently lose the review requirement (the PostToolUse detector cannot block).

The usual cause is the marker directory under the repo's git dir being unwritable (permissions, a full disk, or a plain file where a directory is expected). Fix that, then re-save the document. Escape hatch: create $STATE_DIR/skip-design-review.local in your terminal."
    return 1
}

# ── python3 pre-check (F5 fix) ────────────────────────────────────────
# python3 is REQUIRED for tool type parsing and command detection. If missing,
# the PARSED variable defaults to "SAFE|" which silently allows ALL writes →
# fail-CLOSED, but only when a review is actually pending. The old probe keyed on
# the CWD-relative marker file (gone post-migration → fail-OPEN); the pure-shell
# probe resolves the SHARED marker dir and blocks if any token OR bounded
# per-worktree-root legacy marker exists (Step 3; test (w)).
if ! command -v python3 &>/dev/null; then
    if ! gate_marker_pending_pureshell "."; then
        block_emit "CRITICAL: python3 not found. Pre-implementation gate cannot parse tool inputs, and a design review is pending. Install python3 to restore enforcement. Escape hatch: $STATE_DIR/skip-design-review.local"
        exit 0
    fi
fi

# ── Read stdin once (shared by marker protection and design review) ───
# BOUNDED. `INPUT=$(cat)` read the whole stream before any ceiling could look at it, and
# then command substitution stripped every trailing newline -- so a small valid object
# followed by an arbitrarily large newline run was READ in full and MEASURED as just the
# object. The ceilings below all sit downstream of that read, which made them guards over
# work already paid for; a large enough suffix re-creates the very timeout fail-open they
# exist to close (a timeout kills this hook with NO decision on stdout, which the harness
# reads as ALLOW). Measured: 256MB of trailing newlines cost 1.92s and reported 63 bytes.
#
# One byte past the HARD cap is all that ever needs reading -- anything longer is refused
# by that cap regardless of tool, so reading further can only cost time. A payload that
# fills the buffer is therefore over the hard cap by construction and blocks below.
#
# `-n`, not `-N`: -N arrived in bash 4.1 and this script runs under `env bash`, which on
# macOS resolves to /bin/bash 3.2 whenever PATH is stripped -- and an unsupported option
# would leave INPUT empty, which the next line turns into exit 0. That is a fail-OPEN in
# the one place that must not have one. `-d ''` makes NUL the delimiter and JSON carries
# no NUL, so -n stops only on the byte count or EOF. Verified identical on 3.2 and 5.3.
# LC_ALL=C so the count is bytes, matching ${#INPUT} below.
INPUT=""
LC_ALL=C IFS= read -r -d '' -n 8388609 INPUT 2>/dev/null || true
[ -z "$INPUT" ] && exit 0

# ── Oversized Bash payload: block without parsing ─────────────────────
# This hook is registered with a 5s timeout, and a timeout kills it with NO decision on
# stdout — which the harness reads as ALLOW. So cost is a correctness property here, not
# just a latency one. The python-side budgets (cmdword._MAX_SCAN_TOKENS / _MAX_CMD_CHARS
# and _HELPER_MAX_TOKENS) bound the O(tokens^2) scans, but the gate decodes this payload
# in several separate python3 blocks, and that per-block JSON cost alone reached ~7s at
# 8MB. One length test before any of them bounds every downstream stage at once.
#
# TOOL-AGNOSTIC, and measured in BYTES. Both properties are deliberate, and the first
# version of this guard got both wrong:
#
#   * It matched two literal spellings of `"tool_name":"Bash"` to scope itself to Bash.
#     But the parsers below accept `d.get("tool_name", d.get("toolName", ""))`, and JSON
#     permits whitespace before the colon and \u escapes in the key -- so `toolName`
#     alone walked past the guard. The defect was not that it matched a spelling -- it is
#     that an UNRECOGNIZED spelling relaxed the guard. The scoping is inverted below: the
#     strict ceiling is the default, and only a recognized Write/Edit raises it. An
#     unknown spelling now gets the STRICT limit, so guessing wrong over-blocks instead of
#     waving through, and a Bash payload dressed as a Write buys nothing -- the Write path
#     is gated on file_path and executes no command.
#   * It compared ${#INPUT}, which counts CHARACTERS under a UTF-8 locale, against a
#     threshold justified by per-byte cost. Four-byte characters make those differ by 4x.
#     LC_ALL=C makes the SAME expansion count bytes.
#
# Counted with builtins only, deliberately. The obvious spelling is `wc -c`, and it was
# tried: it fails-CLOSED-by-accident on the python3-missing path, where the gate runs
# under a deliberately stripped PATH that carries no wc and no tr. The substitution came
# back empty, `[ "" -gt N ]` raised, and the ERR trap turned "nothing pending" into a
# block. printf and ${#} are builtins, so this survives an empty PATH.
#
# TWO ceilings, because the two payload shapes have genuinely different honest sizes. A
# Write/Edit carries file CONTENT and is legitimately megabytes; the gate reads only its
# file_path and never scans the body. Everything else -- a Bash COMMAND above all -- has
# no honest form at 256KB, and the per-command budgets below cannot save it: they
# short-circuit CLASSIFICATION, but the gate still JSON-decodes this payload in several
# separate python3 blocks, and that alone measured 3.9s at 1MB. A single flat 4MB ceiling
# was tried and is what let a 262130-character command sit at 7.8s, past the timeout.
#
# Sizes are of the RAW payload, so the Write ceiling is generous enough to cover JSON
# escaping of the content (ensure_ascii turns one 4-byte character into 12 bytes).
_INPUT_BYTES=$(LC_ALL=C; printf '%s' "${#INPUT}")
# Unmeasurable is the failure case, not the happy path. A `${_INPUT_BYTES:-0}` default
# would SKIP the guard on an empty value, which is a silent fail-open in the one branch
# that exists to stop one. Builtins cannot actually return a non-number here; this is the
# branch being pointed in the correct direction rather than a reachable path.
case "$_INPUT_BYTES" in
    ''|*[!0-9]*)
        block_emit "Pre-implementation gate could not measure its own input size — blocking as precaution. If stuck, create $STATE_DIR/skip-design-review.local in your terminal."
        exit 0
        ;;
esac
# HARD cap first, applied to every payload with no discriminator at all, so the parse
# below is itself bounded: nothing legitimate exceeds the most generous ceiling, and a
# payload that does is refused before anything reads it.
if [ "$_INPUT_BYTES" -gt 8388608 ]; then
    block_emit "Tool input too large to classify ($_INPUT_BYTES bytes, hard limit 8388608). The pre-implementation gate must read this payload to decide whether it modifies files, and one this size cannot be scanned within the hook timeout — so it is refused rather than waved through. Split the command, or write the content to a file in smaller pieces."
    exit 0
fi
# Which tool this is, from the TOP-LEVEL discriminator only. Substring matching over the
# raw payload was tried twice and spoofed twice: `*'"Write"'*` matches the string anywhere,
# so a Bash request carrying tool_input.description="Write" raised its own ceiling from
# 256KB to 8MB and reached the marker and effective-CWD parsers with a megabyte of
# command -- measured at 5.5s, past the timeout. Before that, matching two literal
# `"tool_name":"Bash"` spellings missed the `toolName` alias. There is no glob that
# reliably locates a top-level key in JSON (whitespace, key order, \u escapes), so this
# stops guessing and asks the parser. One decode of an already-capped payload, and it is
# the SAME accessor the classifier blocks below use, so the two cannot disagree.
#
# Anything that is not positively identified as Write/Edit/MultiEdit keeps the strict
# ceiling: unparseable input, a missing python3, an unexpected shape. Each of those is a
# large NON-write being refused, which is the safe direction; the cost is that a large
# legitimate write is refused too while python3 is missing, and in that state the gate is
# already degraded to its pure-shell path.
_INPUT_CEILING=262144
# -I (isolated), like every other stdin parser below. Without it the process CWD lands on
# sys.path, and this gate runs with its CWD inside the repo it is gating -- so a repo-root
# json.py would both execute inside the gate and be free to return tool_name "Write",
# lifting a Bash payload from 256KB to 8MB and restoring the timeout fail-open this ceiling
# exists to close. Pinned by a sentinel test; a convention alone did not hold it.
if command -v python3 >/dev/null 2>&1; then
    _TOOL="$(printf '%s' "$INPUT" | python3 -I -c '
import sys, json
try:
    d = json.load(sys.stdin)
    t = d.get("tool_name", d.get("toolName", "")) if isinstance(d, dict) else ""
except Exception:
    t = ""
sys.stdout.write(t if isinstance(t, str) else "")
' 2>/dev/null || true)"
    case "$_TOOL" in
        Write|Edit|MultiEdit) _INPUT_CEILING=8388608 ;;
    esac
fi
if [ "$_INPUT_BYTES" -gt "$_INPUT_CEILING" ]; then
    block_emit "Tool input too large to classify ($_INPUT_BYTES bytes, limit $_INPUT_CEILING). The pre-implementation gate must read this payload to decide whether it modifies files, and one this size cannot be scanned within the hook timeout — so it is refused rather than waved through. Split the command, or write the content to a file in smaller pieces."
    exit 0
fi

# ── Unconditional gate marker protection ──────────────────────────────
# These files control review gate bypass. Protect them ALWAYS, not just
# when design review is pending. Without this, Claude can forge a review
# pass by writing the marker directly when no design review is active.
#
# Fix: Previously this protection was below the early-exit, so it only
# ran when design review was pending. Moved here to be unconditional.
# See: "skip codex review" bypass incident 2026-04-01.
# shellcheck disable=SC2016  # python3 -c program; $ and quotes are literal code, not shell expansion
MARKER_CHECK=$(printf '%s' "$INPUT" | python3 -I -c '
import sys
sys.path[:] = [p for p in sys.path if p not in ("", ".")]
import fnmatch, json, posixpath, re, shlex

_SQ = chr(39)
_DQ = chr(34)


def _bn(t):
    return t.rsplit("/", 1)[-1]


def _refs(tok):
    # Shell variable names referenced in a token: $name and ${name}.
    return re.findall(r"\$\{?([A-Za-z_][A-Za-z0-9_]*)", tok)


def _match_marker(tok, markers, simple_vars):
    # Substring match WITHIN the token: robust to wrappers that leave the marker
    # name embedded — parameter expansion (${V:-...}), ANSI-C quoting, path
    # concatenation. Also resolves a write performed through a shell variable
    # assigned earlier in the SAME command (m=.../marker; rm "$m") via
    # simple_vars. Precision is preserved by only calling this on STRUCTURALLY
    # dangerous positions (a redirect target, or a word in an rm/tee segment),
    # so a marker merely mentioned in an unrelated quoted argument or read
    # command is still allowed.
    for mf in markers:
        if _bn(mf) in tok:
            return mf
    for name in _refs(tok):
        val = simple_vars.get(name, "")
        for mf in markers:
            if _bn(mf) in val:
                return mf
    return None


def _is_redir(t):
    # A redirect operator token: pure punctuation that includes < or > (so >, >>,
    # <, <<, <<<, >|, >&, <&, <> all qualify). Bare ; | & ( ) are NOT redirects:
    # after quote-aware segmentation (below) they only reach here as quoted or
    # escaped LITERAL operands, so they must read as words, never operators. This
    # is the fix for the quoted-separator bypass (rm ; .file with a quoted or
    # escaped semicolon) — the old purity test treated ANY pure-punctuation token
    # as an operator, so shlex-stripped quoting let a marker delete masquerade as
    # a separate command.
    return len(t) > 0 and all(c in "<>|&" for c in t) and ("<" in t or ">" in t)


def _split_with_ops(s):
    # _split_simple_commands, but each segment carries the operator RUN that preceded it,
    # so a pipe-fed stage can be told from a `||` one. Consecutive operator characters
    # join into a single run only when no segment text sits between them, which is exactly
    # what separates `a || b` from `a | ; b`.
    # KEEP IN STEP WITH cmdword._split_with_ops.
    pairs, buf, op = [], [], []
    in_s = in_d = esc = False
    # Did the PREVIOUS character open a redirect -- an unquoted, unescaped `<` or `>`? State,
    # not inference: buf[-1] cannot say whether it was escaped, and bash runs
    # `printf <payload> \<|bash` as a real pipeline because the escaped `<` is an argument.
    redir = False
    xglob = 0                             # open EXTGLOB parens -- see the branch below
    for _i, ch in enumerate(s):
        if esc:
            buf.append(ch)
            esc = redir = False
        elif in_s:
            buf.append(ch)
            if ch == _SQ:
                in_s = False
            redir = False
        elif in_d:
            buf.append(ch)
            if ch == "\\":
                esc = True
            elif ch == _DQ:
                in_d = False
            redir = False
        elif ch == "\\":
            buf.append(ch)
            esc = True
            redir = False
        elif ch == _SQ:
            buf.append(ch)
            in_s = True
            redir = False
        elif ch == _DQ:
            buf.append(ch)
            in_d = True
            redir = False
        elif ch in "|&" and redir:
            # `>|` (clobber), `>&` and `<&` (descriptor duplication). `<&` was missed while
            # its output twin was handled, splitting the segment mid-redirect so the producer
            # of `printf <payload> <&0 | bash` became the bare `0`. Keyed on the REDIRECT
            # CHARACTER, so the next spelling cannot reintroduce the asymmetry.
            # KEEP IN STEP WITH cmdword._split_with_ops.
            buf.append(ch)
            redir = False
        elif ch == "&" and s[_i + 1:_i + 2] == ">":
            # `&>` / `&>>` redirect BOTH streams -- the `&` belongs to the redirect, not to
            # the pipeline. Read as a control operator it cut the segment in two and threw
            # the real producer away: `printf <payload> &>/dev/stdout | bash` kept only the
            # `>/dev/stdout` half. KEEP IN STEP WITH cmdword._split_with_ops.
            buf.append(ch)
            redir = False
        elif ch == "(" and buf and buf[-1] in "+*?@!":
            # EXTGLOB, not a group: with `shopt -s extglob`, `+(s)`, `*(…)`, `?(…)`, `@(…)`
            # and `!(…)` are pathname patterns, so `/bin/ba+(s)h` expands to `/bin/bash`.
            # Split on the paren, the receiver command word came apart and the shell name
            # vanished. The lead character is what distinguishes them, and it is finite.
            # KEEP IN STEP WITH cmdword._split_with_ops.
            buf.append(ch)
            xglob += 1
            redir = False
        elif xglob and ch in ";|&":
            # INSIDE a pattern, every control character is pattern text: `@(s|z)` holds a
            # real `|` that separates alternatives, not pipeline stages. Keeping the parens
            # while still splitting on that `|` left the receiver in pieces again. KEEP IN STEP WITH cmdword._split_with_ops.
            buf.append(ch)
            redir = False
        elif ch == ")" and xglob:
            # its matching close -- kept with it, or the command word still comes apart on
            # the other half of the pattern.
            # KEEP IN STEP WITH cmdword._split_with_ops.
            buf.append(ch)
            xglob -= 1
            redir = False
        elif ch in ";|&()":
            if buf or not op:
                pairs.append(("".join(op), "".join(buf)))
                buf, op = [], [ch]
            else:
                op.append(ch)
            redir = False
        else:
            buf.append(ch)
            redir = ch in "<>"
    pairs.append(("".join(op), "".join(buf)))
    return pairs, not (in_s or in_d or esc)


def _split_simple_commands(s):
    # Split into simple-command segments on UNQUOTED, UNESCAPED control operators
    # (; | & and grouping parens) with an explicit quote/escape state machine.
    # This MUST happen before shlex: posix shlex strips quoting, which makes a
    # quoted/escaped separator indistinguishable from a real one and lets a marker
    # delete slip into a "different" command (rm ; .file). Clobber >| and dup >&
    # embed | / & but are part of the redirect, so a | or & directly after > is
    # kept attached rather than treated as a split. Returns (segments, ok); ok is
    # False on an unterminated quote or dangling escape so the caller fails closed.
    # Clobber >| and dup >& embed | / & but are part of the redirect, so a | or & directly
    # after > is kept attached rather than treated as a split -- see _split_with_ops,
    # which does the scanning for both.
    pairs, ok = _split_with_ops(s)
    return [seg for _op, seg in pairs], ok


# Commands that RUN the command that follows them. Open-ended by nature: a launcher not
# listed here is treated as an ordinary command, so its payload is judged by the strict
# rule. That is a known limit of an allowlist, not a claim of completeness -- see the
# RESIDUAL note in _scan_segment. Platform launchers are included because they are
# ordinary, discoverable commands rather than obfuscation.
# KEEP IN STEP WITH cmdword._WRAPPERS -- a launcher missing from either list is a hole
# in that half. `watch` was missing from both: `watch --exec rm -rf src` resolved its
# command word to `watch` and read as a plain observation.
_WRAPPER_CMDS = ("sudo", "doas", "su", "runuser", "env", "nohup", "timeout", "nice",
                 "ionice", "setsid", "stdbuf", "unbuffer", "command", "builtin", "exec",
                 "xargs", "caffeinate", "chroot", "arch", "torify", "proxychains",
                 "proxychains4", "watch", "flock", "script")
# Reserved words that PRECEDE a command. Without these, `if touch <marker>; then :; fi`
# and `{ touch <marker>; }` pick `if` / `{` as the command word and are allowed.
_RESERVED_SH = ("if", "then", "else", "elif", "fi", "do", "done", "while", "until",
                "esac", "coproc", "{", "}", "!", ")", "(")
# Test-expression openers: everything after is an OPERAND, never a command, so a read
# such as `[ -f <marker> ]` must not be read as an invocation.
_TEST_OPEN_SH = ("[[", "[")
# A verb embedded INSIDE one operand — `env -S "touch <marker>"` keeps the whole program
# in a single token, so basename equality never matches it. Only consulted in the
# wrapper regime, which already tolerates over-blocking.
# time/script/flock are listed as VERBS, not wrappers, even though they also run a
# following command: each can write a file ITSELF via a flag or operand
# (`time -o <log> true`, `script <log>`, `flock <log> cmd`). Treating them as pure
# wrappers meant the conservative scan looked for a verb in the payload, found none, and
# allowed a direct overwrite of the protected audit log. As verbs they block whenever a
# marker is also an operand, which is exactly the condition that matters here — and they
# are deliberately NOT in cmdword.py _MOD_VERBS, where there is no marker requirement and
# `time npm test` would become a false positive.
_INDIRECT_CMDS = ("touch", "cp", "mv", "ln", "install", "truncate", "unlink",
                  "rmdir", "dd", "time", "script", "flock")
# Interpreter operands naming a DESCRIPTOR rather than a file on disk: `-` (the
# documented stdin spelling) and the /dev and /proc descriptor directories. Matched as
# a family, not as a list of spellings -- a list covered descriptor 0 only, and
# `exec 3<helper.py; python3 /dev/fd/3` reads the same program through descriptor 3.
# What any of them carries is decided elsewhere in the command, so none can be resolved
# by looking at the operand.
# Leading slashes are `/+` because POSIX keeps exactly two of them meaningful, so
# normpath("//dev/fd/0") stays "//dev/fd/0" while opening the same descriptor.
# The /proc arm matches any process directory (`self`, `thread-self`, a pid, a
# task path), because listing the ones that exist is the enumeration this file keeps
# losing: `self` and a pid were listed, and `thread-self` reached the same descriptor.
_FD_SCRIPT_RE = re.compile(
    r"^(?:-|/+dev/stdin|/+dev/fd/[0-9]+"
    r"|/+proc/[^/]+/(?:task/[^/]+/)?fd/[0-9]+)$")
# A token this scanner cannot resolve to a filename: the shell rewrites it before the
# interpreter sees it. Variable and command substitution (`FD=/dev/fd/0; python3
# "$FD"`) and PATHNAME EXPANSION (`/dev/f?/0`) both land on a descriptor at run time
# while reading here as an ordinary path.
_UNRESOLVED_OPERAND_RE = re.compile(r"[$`*?\[]")
# The same question asked of a COMMAND WORD rather than a filename operand, so brace
# expansion joins the set: `| /bin/{ba,z}sh` resolves to a shell the text never spells.
# KEEP IN STEP WITH cmdword._UNRESOLVED_CW_CHARS.
# An EXTGLOB group, resolved to the text it wraps: shlex splits `/bin/ba+(s)h` into five
# tokens so the command word reads as `ba+`, while bash expands it to `/bin/bash`.
# `!( )` is excluded and cannot be included -- it matches everything EXCEPT its
# contents, so resolving it to the inner text yields the one harmless-looking spelling.
# A negation is unresolvable, and unresolvable fails CLOSED.
# KEEP IN STEP WITH cmdword._EXTGLOB_RE / _EXTGLOB_NEG_RE.
_EXTGLOB_RE = re.compile(r"[+@*?]\(([^()]*)\)")
# Unresolvable: a NEGATION, or an ALTERNATION. `!(x)` matches all but its contents and
# `@(s|z)` names two things, so resolving either to its inner text picks one spelling --
# for `ba@(s|z)h` the harmless-looking one. KEEP IN STEP WITH cmdword._EXTGLOB_NEG_RE.
# The BODY of a command substitution, either spelling. A substitution is executed by
# definition, so an unresolved command word inside one is an unresolved command word.
# KEEP IN STEP WITH cmdword._SUBST_BODY_RE.
_SUBST_BODY_RE = re.compile(r"\$\(([^()]*)\)|`([^`]*)`")
_EXTGLOB_NEG_RE = re.compile(r"!\([^()]*\)|[+@*?!]\([^()]*\|[^()]*\)")
_UNRESOLVED_CW_RE = re.compile(r"[$`*?\[{(]")   # `(` is extglob: ba+(s)h expands to bash
# A module operand spelled as a plain importable name. Anything else -- an escape, a
# brace, a leftover expansion -- is a name the shell will rewrite, and the operand this
# walk sees has already lost some of that syntax, so testing for the UNRESOLVED
# characters alone missed `-m lease_\x73lot` once the `$` had been stripped.
_PLAIN_MODULE_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_.]*$")
# PROCESS SUBSTITUTION hands its reader a generated descriptor, so `python3 <(cat
# .../lease_slot.py)` runs the helper through /dev/fd/N. The segment splitter dismantles
# `<(...)` before the interpreter-operand walk can see it, so this pairing is decided on
# the raw text instead. The interpreter test keeps an ordinary read out of it: `diff
# <(cat .../lease_slot.py) old.py` compares the file, it does not execute it.
_PROC_SUBST_RE = re.compile(r"[<>]\(")
_INTERP_RE = re.compile(r"(?:^|[\s;&|(])(?:python[0-9.]*|(?:ba|da|k|mk|z|a)?sh)\b")
# rm and tee are included HERE even though the scan above matches them by basename:
# when a wrapper embeds the whole program in one token (env -S "rm -f <log>"), basename
# equality never sees the verb, so the embedded form needs them too.
# MUST cover every name in _INDIRECT_CMDS. time/script/flock were listed there and
# omitted here, so the one shape this regex exists for -- the whole program inside a
# single token -- let `env -S "script <log>"` through both checks.
_INDIRECT_VERBS_RE = (r"(?:touch|cp|mv|ln|install|truncate|unlink|rmdir|dd|rm|tee"
                      r"|time|script|flock)")
# `=` is a separator too: env accepts the long form --split-string=<program>, which puts
# the verb immediately after the equals sign rather than after whitespace.
_INDIRECT_EMBEDDED = re.compile(r"(?:^|[\s;&|/=])" + _INDIRECT_VERBS_RE + r"(?:\s|$)")
# The ATTACHED spelling of env -S glues the program to the flag letters, so the token
# reads as -Stouch <marker> and the verb is preceded by a letter rather than whitespace.
# Non-greedy so the flag cluster is consumed but the verb is not -- a greedy strip eats
# the verb along with the flag and matches nothing.
_INDIRECT_ATTACHED = re.compile(r"^-[A-Za-z]*?" + _INDIRECT_VERBS_RE + r"(?:\s|$)")


def _dequote(w):
    return w.replace(chr(34), "").replace(chr(39), "")


def _skippable(w):
    # A leading assignment, a flag, or a bare numeric wrapper operand (timeout 5 ...).
    return (re.match(r"^[A-Za-z_][A-Za-z0-9_]*\+?=", w) is not None
            or w.startswith("-")
            or re.match(r"^[0-9]+(?:\.[0-9]+)?[smhd]?$", w) is not None)


def _peel_wrappers(words):
    # First word that actually EXECUTES: skip leading assignments, flags, bare numeric
    # wrapper operands, and wrapper commands themselves. Returns None when nothing
    # survives, so the caller falls back to its raw first word.
    for w in words:
        if _skippable(w) or _bn(w) in _WRAPPER_CMDS or _bn(w) in _RESERVED_SH:
            continue
        if _bn(w) in _TEST_OPEN_SH:
            return None
        return w
    return None


def _first_word(words):
    # The first word in COMMAND position, ignoring leading assignments/flags/numeric
    # wrapper operands. Reserved words are NOT skipped here: callers that care about a
    # specific keyword (coproc) need to see it exactly where it sits.
    for w in words:
        if _skippable(w):
            continue
        return _bn(w)
    return ""


# A leading redirection, ATTACHED or bare, with an optional leading fd: `<`, `2>`, `>>`,
# `</dev/null`, `2>&1`. KEEP IN STEP WITH cmdword._REDIR_RE.
#
# Needed because the two copies of this scan tokenize DIFFERENTLY. cmdword uses a plain
# shlex, so `</dev/null` survives as ONE token and only this regex can see it. This file
# uses punctuation_chars=True, which splits it into `<` + `/dev/null` -- so here the
# operator is visible to _is_redir but its OPERAND is what lands in command position. Both
# halves have to be handled, and handling only one is what left the guard open twice.
# Every COMPLETE redirection operator, longest-first so `<<<` is not read as `<`. The
# first version matched a single leading `<` only, so a here-string `<<< data` looked
# like an ATTACHED redirect whose own text was `<`, its operand was never skipped, and
# `data` became the command word -- the same regime failure this regex exists to stop.
_REDIR_PREFIX_RE = re.compile(r"^(?:[0-9]+|&)?(?:<<<|<<-?|<>|<&|>>|>\||>&|<|>)")


def _strip_redirs(toks):
    """Drop redirect operators AND the operand each one consumes.

    Filtering on _is_redir alone removed the operator and left the TARGET behind, so
    `</dev/null sudo -u root python3 .../lease_slot.py` reduced to
    `[/dev/null, sudo, ...]`. The basename of `/dev/null` is `null`, which is not a
    wrapper, so the wrapper regime was never selected, the launcher was then peeled to its
    OWN operand, and the interpreter behind it was never located -- the UNCONDITIONAL
    helper guard measured ALLOW for the sudo, script and flock forms alike.

    A leading file descriptor (`2` in `2>&1`) stays, and is already _skippable.
    """
    out, skip = [], False
    for t in toks:
        if skip:
            skip = False
            continue
        if _is_redir(t):
            skip = True          # the following token is this redirect TARGET, not a verb
            continue
        out.append(t)
    return out


def _starts_with_wrapper(words):
    # Is the COMMAND-POSITION word a wrapper? Position matters: a wrapper name appearing
    # only as an ARGUMENT to a read (grep sudo <marker>) must not change the decision.
    #
    # A LEADING REDIRECTION has to be stepped over first. `</dev/null` is not pure
    # punctuation, so _is_redir does not strip it and it arrived here as a word whose
    # basename is `null` -- not a wrapper, so this returned False, the conservative
    # all-token regime was never selected, and the launcher preamble was then peeled up to
    # its OWN operand. That allowed the UNCONDITIONAL helper guard to be walked past:
    # `</dev/null script -q /dev/null python3 .../lease_slot.py` and the sudo and flock
    # forms all measured ALLOW. Same defect as cmdword._starts_with_wrapper, and it has to
    # be fixed in BOTH copies -- fixing only the library left this one open, because this
    # is the copy the helper guard consults.
    skip_next = False
    for w in words:
        if skip_next:
            skip_next = False
            continue
        m = _REDIR_PREFIX_RE.match(w)
        if m:
            # A BARE operator takes the FOLLOWING token as its target (`< in.txt cmd`);
            # an attached one (`</dev/null`) carries its own. Without this the target
            # became the command word and the answer was False all the same.
            skip_next = m.group(0) == w
            continue
        if _skippable(w) or _bn(w) in _RESERVED_SH:
            continue
        if _bn(w) in _TEST_OPEN_SH:
            return False
        return _bn(w) in _WRAPPER_CMDS
    return False


def _scan_segment(segtext, markers, simple_vars, flags=None):
    # Tokenize ONE already-separated simple command and decide block/allow.
    # commenters is cleared because the newline->";" normalization (in
    # _writes_marker) leaves a "#" with no terminating newline, so default shlex
    # comment handling would swallow the rest of the line and hide a trailing
    # marker delete. simple_vars is owned by the caller and persists across
    # segments, so an assignment in one segment resolves a $var use in a later one
    # (m=...; rm "$m"); it is updated in order as tokens are walked.
    try:
        lex = shlex.shlex(segtext, posix=True, punctuation_chars=True)
        lex.whitespace_split = True
        lex.commenters = ""
        toks = list(lex)
    except ValueError:
        # Unparseable segment (e.g. unbalanced quote): a segment that does not
        # even mention a marker basename cannot be a forge (allow); otherwise fail
        # CLOSED (block).
        #
        # This is the SECOND could-not-parse path (the first is the ok=False branch
        # in _writes_marker). Both must report the same TRUTH, or the #365 fix only
        # half-lands: a hit here would still assert "you tried to write a marker"
        # when all we really know is that the text could not be parsed. Signalled via
        # `flags` rather than the return value because this function has several
        # return sites and only one caller — widening them all would be a bigger,
        # riskier diff than an out-param for a message-only distinction.
        if flags is not None:
            flags["unparseable"] = True
        return next((mf for mf in markers if _bn(mf) in segtext), None)
    seg = []
    seg_words = []   # command-position candidates: redirect operators/targets excluded
    seg_has_cmd = False
    seg_cmd_word = None  # first real command word (redirect ops/targets excluded)
    i, n = 0, len(toks)
    while i < n:
        t = toks[i]
        # A lone file-descriptor digit binding a redirect (2>/dev/null, 1>&2) is
        # PART of the redirect, not a command word — skip it so it cannot masquerade
        # as the command word (2>/dev/null touch <marker>) (#290 PR review). Safe
        # even when the digit is really an echo arg (echo 2 >f): the command word
        # is already captured, and a digit is never a marker basename.
        if t.isdigit() and i + 1 < n and _is_redir(toks[i + 1]):
            i += 1
            continue
        if _is_redir(t):
            if ">" in t:  # write redirect; next word is its target
                if i + 1 < n and not _is_redir(toks[i + 1]):
                    nxt = toks[i + 1]
                    m = _match_marker(nxt, markers, simple_vars)
                    if m:
                        return m
                    # A redirect target is NOT a command word: leave seg_has_cmd
                    # unset so a bare name=value in a redirect-only simple command
                    # (> /dev/null m=.../marker) is still recorded as an assignment
                    # and a later rm "$m" resolves to the marker.
                    seg.append(nxt)
                    i += 2
                    continue
                i += 1
                continue
            # "<" read redirect; skip operator AND its source (a read, not a write)
            i += 2 if (i + 1 < n and not _is_redir(toks[i + 1])) else 1
            continue
        # Leading name=value tokens (before the command word) are real shell
        # assignments; once a non-assignment word appears, later name=value tokens
        # are arguments, not assignments. Both NAME=VALUE and bash/zsh NAME+=VALUE
        # (append) are tracked — kept consistent with the +=-aware command-word skip
        # below. Otherwise `M+=.claude/skip-litmus.local ; touch "$M"` would leave M
        # unrecorded and the indirect marker write would slip through (#290 PR review).
        assign_m = re.match(r"^([A-Za-z_][A-Za-z0-9_]*)(\+?)=(.*)$", t, re.DOTALL) if not seg_has_cmd else None
        if assign_m:
            name, plus, val = assign_m.group(1), assign_m.group(2), assign_m.group(3)
            simple_vars[name] = (simple_vars.get(name, "") + val) if plus else val
        else:
            # First non-assignment word to reach here is the command word. Redirect
            # operators AND their targets never reach this branch (handled+continued
            # above), so a leading redirect (>/dev/null touch <marker>) cannot masquerade
            # as the command word (#290 PR review — cursor/codex/devin).
            if not seg_has_cmd:
                seg_cmd_word = t
            seg_has_cmd = True
        seg.append(t)
        seg_words.append(t)
        i += 1
    # A bare rm/tee co-occurring with a marker operand in THIS simple command is a
    # delete / tee-write of the marker. Scanning ALL words (not a pinned command
    # position) means wrapper preambles (sudo/env/nohup/timeout, with flags or
    # leading assignments) cannot hide the rm/tee.
    if any(_bn(w) in ("rm", "tee") for w in seg):
        for w in seg:
            m = _match_marker(w, markers, simple_vars)
            if m:
                return m
    # #290 indirect-write verbs (touch/cp/mv/ln/install) that FORGE the skip/marker
    # file. Unlike rm/tee, these are matched ONLY in COMMAND-WORD position (the
    # first token after any leading name=value assignments), NOT scanned across all
    # words — otherwise a marker READ whose args merely contain one of these words
    # (grep touch <marker>, cat <marker> | grep cp) would be misread as a write.
    # This closes the realistic self-bypass — a bare `touch .claude/skip-litmus.local`,
    # incl. `touch -t` backdating that also defeats the pre-commit 30s age heuristic
    # — while a wrapper-hidden `sudo touch <marker>` and the eval class stay in the
    # ADR 0006 residual (a cooperative agent uses none of those to skip its own gate).
    # seg_cmd_word is captured in the token loop, so leading assignments (NAME=/NAME+=)
    # AND leading redirects (>/dev/null touch <marker>) are already excluded — a naive
    # first-non-assignment scan of seg would mis-pick the redirect target as the verb.
    # Peel wrapper preambles before deciding the verb. Matching the RAW first word let
    # `command rmdir <slot>` and `env truncate <log>` slip past this check, while the
    # wrapper-aware classifier downstream still called them modifications — and the F9
    # state-directory exemption then allowed them. A spent lease slot could therefore be
    # removed and reclaimed without bound, and the protected audit log destroyed.
    # #519: the indirect-write verbs. touch/cp/mv/ln/install come from #290 (the
    # realistic threat is a cooperative agent taking the easy path); truncate/unlink/
    # rmdir/dd were added once the lease ledger and bypass-log.jsonl became gate state,
    # since rmdir on a spent slot resets the 20-use ceiling and truncate/dd erase the
    # audit trail. A residual that is the EASIEST path is not a residual.
    # ── Does this simple command RUN an indirect-write verb? ──────────────────
    # One conservative rule rather than a patch per shape. Chasing each variant found a
    # new one every round (coproc with an optional NAME, sudo before find, a verb
    # embedded in an -exec payload), which is the segment-split arms race this file
    # already warns about.
    #
    # CONSERVATIVE regime when the command executes something it does not name directly:
    # a wrapper in command position, a coproc or function DEFINITION in command position
    # (coproc takes an optional NAME, and a function body executes when the name is later
    # called -- `function f { touch <marker>; }; f`), or find (which runs its own
    # commands). All three are anchored on POSITION -- an any-occurrence test blocked
    # `echo coproc touch <marker>` and `echo find -delete <marker>`, where the marker is
    # only data, breaking the read/mention contract this check exists to preserve.
    # There, EVERY word is checked -- by basename equality, by embedded-verb regex on the
    # dequoted word, and for the -delete action. That cannot fail open; it only
    # over-blocks a wrapped read, which is the right direction for a marker guard.
    #
    # RESIDUAL, deliberately NOT chased: a verb assembled at RUNTIME rather than written
    # literally -- `V=truncate env -S "${V} -s 0 <log>"`, globs, brace expansion. That is
    # the ADR 0006 execute-a-string/computed-name class: the value exists only in the
    # executing shell, so no static scan can see it, and anything able to do it can also
    # `python3 -c` the write directly. Blocking a subset is theater against that actor.
    # The literal spellings above are closed because they are ONE TOKEN away from an
    # ordinary command; this one is not.
    #
    # STRICT regime otherwise: the command word alone decides, so a verb appearing only
    # as an ARGUMENT to a read (grep touch <marker>, echo find -delete <marker>) stays
    # allowed. That read-only contract is the whole point of the position check.
    _INDIRECT = _INDIRECT_CMDS
    _peeled = _peel_wrappers(seg_words)
    # Tested on the PEELED word as well as the first: a reserved word can sit in front
    # of the definition (`if true; then function f { touch <marker>; }; f; fi`), and
    # _first_word then reports `then`, which is neither a wrapper nor a definition.
    # _peel_wrappers already skips reserved words, so it reaches the real introducer.
    _conservative = (_starts_with_wrapper(seg_words)
                     or _first_word(seg_words) in ("coproc", "function")
                     or _bn(_peeled or "") in ("coproc", "function", "find"))
    if _conservative:
        verb_present = (any(_bn(w) in _INDIRECT for w in seg_words)
                        or any(_INDIRECT_EMBEDDED.search(_dequote(w))
                               or _INDIRECT_ATTACHED.match(_dequote(w))
                               for w in seg_words)
                        or any(w == "-delete" for w in seg_words))
    else:
        cmd_word = _peeled if _peeled is not None else seg_cmd_word
        verb_present = cmd_word is not None and _bn(cmd_word) in _INDIRECT
    if verb_present:
        for w in seg:
            m = _match_marker(w, markers, simple_vars)
            if m:
                return m
    return None


def _defuse_comments(s):
    # Blank the SEPARATOR characters inside shell comments, quote-aware, leaving every other
    # byte -- and the newlines that end the comments -- in place. A comment runs from an
    # unquoted `#` in word position to the end of its LINE and can contain `;`, so a comment
    # reaching the splitter intact turns `printf <payload> | #  ; ignored` + newline + `bash`
    # into a comment segment plus a bare `ignored` that reads as a real command and ends the
    # pipeline one stage before its shell.
    #
    # DEFUSING rather than DELETING: deleting was tried and moved 14 real commands from block
    # to ALLOW, because a comment holding an apostrophe had been making the whole command
    # unparseable, which is the fail-CLOSED path. Blanking in place keeps every byte.
    # QUOTES are blanked too: bash ignores quoting inside a comment, so leaving them
    # let a comment change the quote state of everything after it -- two balanced ones
    # wrap a write in apparent quotes, one unbalanced one hid a redirect write.
    # KEEP IN STEP WITH cmdword._defuse_comments.
    # WORD POSITION as explicit state, not read back off the previous output character:
    # that character does not say whether it was escaped or quoted, and two spellings turn
    # on exactly that. `)` can close a substitution INSIDE the current word, so
    # `echo $(true)#x` is one word; an ESCAPED space is an ordinary character, so
    # `echo foo\ #notcomment` is one word too. Both read as comments and blanked the real
    # separator that followed. `(` does open word position.
    out, in_s, in_d, esc = [], False, False, False
    word = True
    group = []          # one bit per open paren: subshell (delimits) or substitution
    i, n = 0, len(s)
    while i < n:
        ch = s[i]
        if esc:
            out.append(ch); esc = False; word = False
        elif in_s:
            out.append(ch)
            if ch == _SQ:
                in_s = False
            word = False
        elif in_d:
            out.append(ch)
            if ch == chr(92):
                esc = True
            elif ch == _DQ:
                in_d = False
            word = False
        elif ch == chr(92):
            out.append(ch); esc = True; word = False
        elif ch == _SQ:
            out.append(ch); in_s = True; word = False
        elif ch == _DQ:
            out.append(ch); in_d = True; word = False
        elif ch == "#" and out and out[-1] == ")":
            # AMBIGUOUS and deliberately not guessed at: whether this `)` delimited a command
            # depends on what its `(` opened, and bash has four answers -- a SUBSHELL and a
            # case PATTERN delimit, a SUBSTITUTION and a FUNCTION HEADER do not. Three review
            # rounds each closed one spelling and opened another. Left exactly as it stands
            # and flagged, so the caller falls back to the unconditional probe.
            # KEEP IN STEP WITH cmdword._defuse_comments.
            _paren_hash_ambiguous[0] = True
            out.append(ch)
            word = False
        elif ch == "#" and word:
            while i < n and s[i] != "\n":
                out.append(" " if s[i] in ";&|()" + _SQ + _DQ else s[i])
                i += 1
            continue
        elif ch == "(":
            out.append(ch)
            # WHICH kind of paren: a bare `(` in word position opens a SUBSHELL whose `)`
            # ends a command, so `(true)# x` is a comment; a `$(` opens a SUBSTITUTION whose
            # `)` sits mid-word, so `echo $(true)#x` is not. Both were fail-opens in
            # successive rounds. KEEP IN STEP WITH cmdword._defuse_comments.
            group.append(word and not (len(out) > 1 and out[-2] == "$"))
            word = True
        elif ch == ")":
            out.append(ch)
            word = group.pop() if group else False
        else:
            out.append(ch)
            word = ch in " \t\n;&|"
        i += 1
    return "".join(out)


def _norm_for_scan(cmd):
    # Pre-tokenization normalization shared by the marker scan and the helper guard, so
    # the two cannot disagree on what a token is.
    norm = cmd.replace("\r\n", "\n").replace("\r", "\n")
    # Bash removes an unquoted backslash-newline (line continuation) before execution;
    # mirror that BEFORE splitting on newlines so a marker write or basename split
    # across a continuation is rejoined, not broken into pieces.
    norm = norm.replace(chr(92) + chr(10), "")
    # Comments are defused BEFORE the newlines that end them become separators.
    norm = _defuse_comments(norm)
    norm = norm.replace("\n", " ; ")
    # Bash ANSI-C ($...) and locale quoting: shlex does not model the leading $, so
    # strip that prefix and let the quote tokenize to the literal path. (Escape
    # SEQUENCES such as \x6c remain undecodable by shlex and stay out of scope per the
    # residual note above.)
    norm = norm.replace("$" + _SQ, _SQ).replace("$" + _DQ, _DQ)
    # ${IFS}/$IFS expand to whitespace -- a classic field-splitting obfuscation
    # (rm${IFS}<marker>); normalize to a separator so the command word and redirect
    # operands are recognized rather than glued into one token.
    return re.sub(r"\$\{IFS\}|\$IFS(?![A-Za-z0-9_])", " ", norm)


_MUTATING_HELPERS = ("lease_slot.py", "audit_append.py")

# Bound the WIDTH of the helper scan. KEEP IN STEP WITH cmdword._MAX_SCAN_TOKENS, which
# carries the full reasoning. The short version: the -c scan is O(tokens^2) because it
# refuses the per-flag arity table, and this hook is registered with a 5s timeout that on
# expiry kills it with NO decision on stdout -- which the harness reads as allow. Measured
# before this bound existed, 128KB of padding cost 34s here. Tokens rather than bytes, so
# a legitimately long single-token payload is untouched. Charged cumulatively across every
# segment and recursion level.
#
# Exhaustion fails CLOSED, via _HELPER_UNSCANNED. An earlier version degraded to the
# substring probe instead, arguing that any command big enough to exhaust this budget also
# exhausts the cmdword budget, where exhaustion blocks. That argument does not hold, and
# the gap it left was measured: this guard is UNCONDITIONAL, while the cmdword budget only
# decides is_file_mod, which blocks solely WHILE a design review is pending. With nothing
# pending the two do not overlap, so 4001 filler flags followed by `-m lease_slot` was
# ALLOWED. A scan that was abandoned has not found "no helper" -- it has found nothing at
# all, and nothing at all is the fail-CLOSED case.
_HELPER_MAX_TOKENS = 4000
_helper_budget = [0]
# Set by _defuse_comments on a `)#`, whose meaning it refuses to guess. Read by
# _helper_invoked, which answers it by fail-CLOSED probe.
_paren_hash_ambiguous = [False]
# Total BYTES of watch suffix candidates materialized per scan. The cost of that
# expansion is copying, not token count, so it is bounded in the unit it actually spends.
# Exceeding it forces _helper_budget negative, which fails CLOSED -- see _exec_payloads.
_WATCH_MAX_PAYLOAD_BYTES = 1 << 20
# The same helpers as MODULE names. `python3 -m lease_slot` runs the file without
# ever naming it, and `-m` was on the list of flags whose operand gets skipped.
_MUTATING_MODULES = tuple(h[:-3] for h in _MUTATING_HELPERS)

# Modules that CONSUME a following path as data rather than executing it, keyed by the
# first dotted component. Deliberately an allowlist and deliberately short: the inverse
# list (modules that RUN their argument -- cProfile, profile, pdb, trace, timeit, runpy,
# ...) fails OPEN on the one nobody enumerated, and stdlib gains modules. Anything absent
# here is assumed to execute what follows, so an unlisted read-only module costs a false
# block, not a bypass. Add to this list when one shows up; never add to its inverse.
_READONLY_MODULES = frozenset((
    "json",        # json.tool pretty-prints its operand
    "tokenize", "ast", "dis", "pydoc", "pyclbr", "inspect",
    "py_compile", "compileall",   # compile to bytecode; they do not run module level
    "base64", "gzip", "zipfile", "tarfile", "hashlib", "mimetypes",
))

# Isolated-mode flags. `-I` implies `-P` and `-E`; `-P` alone is enough for the question
# asked below, since it is the one that drops the CWD from sys.path.
_ISOLATED_RE = re.compile(r"^-[A-Za-z]*[IP]")


def _readonly_module_trusted(mod, words):
    """Is the READ-ONLY reputation of this -m module actually trustworthy here?

    The name alone is not evidence. For -m, CPython puts the CURRENT DIRECTORY on
    sys.path, and this gate runs with its CWD inside the repository it is gating -- so a
    repo-root `json/` package shadows the stdlib and `python3 -m json.tool <helper>`
    executes whatever the repo says json.tool is. PYTHONPATH does the same from the
    environment. Trusting the spelling is the exact shape ADR 0016 / #325 rejected:
    consent authenticated by content that the gated party controls.

    So the allowlist counts only when the interpreter runs ISOLATED, which is what
    actually removes the CWD -- and, for -I, the environment -- from the module search
    path. A bare `python3 -m json.tool <helper>` is now treated as unknown and scanned,
    which costs a false block on a genuine read. That is recoverable through the skip
    lease; the alternative is not.
    """
    if _bn(mod).split(".")[0] not in _READONLY_MODULES:
        return False
    return any(_ISOLATED_RE.match(t) for t in words)

# Sentinel for a scan that was ABANDONED rather than completed. Not a helper name: it
# means the walk ran out of budget or the command was too large to walk, so this file
# cannot say whether a helper runs. The caller blocks on it, through its OWN action so
# the operator gets an accurate message instead of being told to stop calling a script
# named after a sentinel. Plain ASCII with no pipe: it crosses into shell through a
# pipe-delimited line, and a NUL would be dropped or truncate the field.
_HELPER_UNSCANNED = "UNSCANNABLE"


def _helper_substring(text):
    """Cheap probe: does `text` NAME a mutating helper anywhere, file OR module spelling?

    Every fallback in this file that abandons the structured walk lands here, so the
    MODULE spelling has to be covered: `python3 -m lease_slot` never writes the string
    `lease_slot.py`, so probing the FILE names alone read a real invocation as absent.
    That is the gap a padded command walked through once the token budget cut the walk
    short -- measured ALLOW with nothing pending, against an UNCONDITIONAL guard.

    The module stems subsume the file names (`lease_slot` is a substring of
    `lease_slot.py`), so one pass over the stems answers both spellings.
    """
    return next((m + ".py" for m in _MUTATING_MODULES if m in text), None)


def _module_helper(mod):
    """The helper FILE this `-m` module operand runs, or None. Dotted paths resolve to
    their last component, since `-m gate.lib.audit_append` runs the same file."""
    if not mod:
        return None
    stem = _bn(mod).split(".")[-1]
    return stem + ".py" if stem in _MUTATING_MODULES else None


def _glob_helper(word):
    """The helper FILE a GLOB operand can expand to, or None.

    The shell resolves `lease_slo?.py` against the filesystem, so the question is not
    whether the literal spelling names a helper -- it never does -- but whether the
    PATTERN can. Asking that directly beats searching the command text for a helper
    stem, which a single wildcard in the middle of the name defeats.
    """
    try:
        pat = re.compile(fnmatch.translate(_bn(word)))
    except (re.error, TypeError):
        return _MUTATING_HELPERS[0]      # unparseable pattern: fail closed
    return next((h for h in _MUTATING_HELPERS if pat.match(h)), None)


# A function definition, an alias definition, or eval can re-point a command name, so a
# helper sitting in an operand may be what actually runs. See _helper_invoked.
#
# A function NAME is any word free of the metacharacters that would end it: bash accepts
# f-x, f.x and my:fn, none of which an identifier charset matches, and all of which run.
# The keyword branch requires the KEYWORD in command position and a name, NOT a brace --
# a function body is any compound command, so `function f while ...; do ...; done` and
# `function f [[ ... ]]` both define one. Command position is what keeps the branch from
# firing on the ordinary word (grep function file), and it is structural rather than a
# guess about the body. KEEP IN STEP WITH cmdword._FUNC_NAME / _FUNC_DEF_RE /
# _INDIRECTION_RE, which carry the corpus measurements behind this shape.
# Words that OPEN and CLOSE a compound command. A compound command is ONE pipeline stage no
# matter how many separators sit inside it, so an `if`/`for`/`while` receiver runs the piped
# program while its internal separator looked like the end of the pipeline. Braces were only
# the first spelling of that family, not the family. Counted as whole WORDS.
# KEEP IN STEP WITH cmdword._GROUP_OPEN / _GROUP_CLOSE.
_GROUP_OPEN = ("{", "if", "for", "while", "until", "case", "select")
_GROUP_CLOSE = ("}", "fi", "done", "esac")
# Words in command position that are NOT commands. The leading-run walk steps OVER them, or
# a nested opener behind one goes uncounted while its closer still closes.
# ...and the PIPELINE PREFIXES `time`, `time -p` and `!`, which bash allows in front of a
# compound command and which otherwise stopped the walk before its opener.
_GROUP_CONNECT = ("then", "do", "else", "elif", "time", "-p", "!")

# COMMAND POSITION, derived from the compound-command keyword sets rather than hand-listed,
# because a hand-listed subset is how `if function f { bash; }; then ...` slipped: `then`,
# `do` and `else` were listed while `if`, `while`, `until`, `!` and `time` were not. Anything
# that can precede a command WITHOUT being one belongs here, and those sets already enumerate
# it for the depth walk -- so they are the single source. The trailing repetition covers
# stacked prefixes (`time -p function f { ... }`, `! if ...`).
# KEEP IN STEP WITH cmdword._CMD_POS.
_CMD_POS_LEAD = (r"(?:\b(?:"
                 + "|".join(sorted(w for w in set(_GROUP_OPEN) | set(_GROUP_CONNECT)
                                   if w.isalpha()))
                 + r")\b|!|(?<![\w-])-p\b)")
# ONE prefix, not a repeated group: the repetition was redundant (a single preceding prefix
# already establishes command position, and `-p` and `!` are themselves alternatives) and
# CATASTROPHIC -- 4,000 valid `!` prefixes took 5.4s against a 5s hook timeout that fails
# open. KEEP IN STEP WITH cmdword._CMD_POS.
_CMD_POS = r"(?:^|[\n;&|(){}]|" + _CMD_POS_LEAD + r")\s*"
# The `name()` form cannot sit behind a group CLOSER or a pipeline prefix, so it takes
# openers and reserved words only. KEEP IN STEP WITH cmdword._CMD_POS_WORDS.
_CMD_POS_WORDS = (r"\b(?:"
                  + "|".join(sorted(w for w in set(_GROUP_OPEN) | set(_GROUP_CONNECT)
                                    if w.isalpha()))
                  + r")\b")

_FUNC_NAME = r"[^\s;&|()<>{}]+"
_INDIRECTION_RE = re.compile(
    r"(?:^|[\n;&|{()]\s*|" + _CMD_POS_WORDS + r"\s*)" + _FUNC_NAME + r"\s*\(\s*\)"
    r"|" + _CMD_POS + r"function\s+" + _FUNC_NAME
    # `hash -p PATH NAME` binds NAME to PATH for the rest of the shell -- the same
    # re-pointing `alias` does. NO PREFIX GRAMMAR: modelling what bash allows in front of a
    # builtin (`FOO=x`, `A+=x`, any number, a leading redirection, `builtin`, `command --`,
    # `command -p`) cost three review rounds and left a new prefix open each time, while
    # dropping the anchor measured ZERO further over-blocks. BOUNDED repetition, because the
    # unbounded form backtracked catastrophically -- 7.2s on a valid 59KB command against a
    # 5s hook timeout that fails OPEN, so the regex WAS the fail-open.
    # KEEP IN STEP WITH cmdword._HASH_REMAP.
    # NO OPTION SEARCH either: unbounded it backtracked at 7.2s against a 5s hook timeout,
    # and bounded to 120 characters it was defeated by 121 spaces. Any CHARACTER bound is
    # a guess. The word alone costs 69. KEEP IN STEP WITH cmdword._HASH_REMAP.
    + r"|\bhash\b"
    # A bash ALIAS NAME is not an identifier -- `alias 1x=bash` is valid and runs -- so the
    # branch takes the same word shape the function branches use, plus the end-of-options
    # form. KEEP IN STEP WITH cmdword, whose eval/alias branch matches the WORD and so never
    # had this narrowing.
    + r"|(?:^|[\n;&|(]|\s)\s*alias\s+(?:--\s+)?" + _FUNC_NAME
    # A redirection may follow a command name immediately, so `eval</dev/null <definition>`
    # runs eval while a whitespace-only suffix does not match it. The suffix is widened to
    # the redirect characters rather than to a bare word boundary: a match HERE enables
    # the wholesale helper-name scan, so `\beval\b` would block an innocent
    # `cat docs/eval.md <helper>` and break the read-versus-mention contract. cmdword can
    # afford the bare boundary because a match there only widens WHICH TEXT is scanned.
    # That asymmetry is deliberate; do not "sync" it away.
    #
    # RESIDUAL, and a deliberate over-block: this layer sees TEXT, not a parsed command
    # word, so `cat eval</dev/null <helper>` -- where eval is an ARGUMENT that happens to
    # be followed by a redirect -- matches too. Telling the two apart needs the command
    # word, which is a different layer. An over-block is the safe direction and the shape
    # is contrived; it is pinned in the suite so the choice stays visible. The redirect
    # family is complete -- `<`, `>`, `&>` and `&>>` -- because MISSING one is the unsafe
    # direction, and `&>` was missing.
    + r"|(?:^|[;&|(]|\s)\s*eval(?=\s|$|[<>]|&>>?)"
    # `BASH_CMDS` is the hash table exposed as a writable array: assigning to it binds a
    # NAME to a path exactly as `hash -p` does, without naming the builtin.
    # KEEP IN STEP WITH cmdword._BASH_CMDS_RE.
    + r"|\bBASH_CMDS\s*\[")


def _exec_payloads(words):
    # SCOPE, because the KEEP IN STEP notes further down have been misread in BOTH
    # directions: this feeds the HELPER guard only -- can this command reach
    # lease_slot.py or audit_append. It is NOT the file-mod classifier, which has
    # exactly ONE implementation, cmdword.is_file_mod, imported below.
    #
    # The distinction that matters when editing either file:
    #   - a new file-mod VERB belongs in cmdword._MOD_VERBS alone. It needs no twin
    #     here, because whether a command WRITES is not a question this function asks.
    #   - a new RUNNER -- anything that hands a payload to a shell -- belongs in BOTH,
    #     for different reasons: cmdword so the payload is classified for writes, here
    #     so the payload is searched for a helper. Teaching only one of them leaves the
    #     other blind. That is not hypothetical: `watch` with a quoted payload was added
    #     to cmdword first and reached the helper guard unseen until the branch below
    #     was added.
    #
    # The KEEP IN STEP notes pin the dedup, budget and tokenization details this
    # function shares with cmdword._executed_operands -- never the operand set, which
    # answers a different question and is deliberately wider (no exemption list, any
    # index).
    #
    # Sub-programs this simple command hands to something else to RUN: a find -exec
    # payload (already tokens) and an executed STRING (env -S / a shell -c), which has
    # to be re-tokenized. Without following these, the helper guard only saw the top
    # level, so `find . -exec python3 .../lease_slot.py .claude fake 1 ;` and the same
    # payload inside env -S reached the helper unblocked.
    # A shell/env introducer is matched at ANY index, deliberately, and there is NO
    # exemption list. Requiring command position means knowing where the wrapper preamble
    # ends, which means knowing which wrapper flags take an operand -- and every
    # approximation of that is a fail-open: consuming one operand per flag eats the `find`
    # in `sudo -E find . -exec ...` (-E is boolean), leaving the payload unscanned, and
    # the same holds for `env -i` and `sudo -n`.
    #
    # Exempting commands that "only print their arguments" was tried and REMOVED. Every
    # entry turned out to be another way to execute: `less "+!<cmd>"` runs a shell,
    # `alias echo=eval` re-points the name, a function definition shadows it outright.
    # Patching the list per spelling is the arms race this file exists to avoid, and an
    # exemption in a security detector has to be justified rather than assumed -- so the
    # list is gone and the scan is unconditional.
    #
    # The price is a documented over-block: `echo -exec sh -c "... lease_slot.py ..."`
    # prints a string and is read as an invocation. That is the fail-CLOSED direction on a
    # command nobody writes, and both helpers are safe by construction anyway (lease_slot
    # reads the mtime itself under a lock; audit_append has no writing CLI), so this
    # detector is defence in depth rather than the thing holding the line.
    # Deduped ON INSERT. KEEP IN STEP WITH cmdword._executed_operands, which carries the
    # reasoning: deduping at the END still materializes every duplicate first, and the
    # no-break rescan builds them quadratically -- measured near 203 MiB for a 65KB input
    # whose TIME was already bounded by the token budget.
    tok_payloads, str_payloads = [], []
    _seen_t, _seen_s = set(), set()

    def _add_tok(payload):
        _k = tuple(payload)
        if _k not in _seen_t:
            _seen_t.add(_k)
            tok_payloads.append(payload)

    def _add_str(payload):
        if payload not in _seen_s:
            _seen_s.add(payload)
            str_payloads.append(payload)
    # `-exec` is a find PREDICATE, so it only introduces a payload when some earlier word
    # in the segment is `find`. Treating it as a general convention read the -exec in
    # `bash -c "printf ..." -- -exec sh -c "..."` -- a print -- as an invocation.
    _seen_find = False
    # Only the FIRST watch word is expanded; see the branch below for why.
    _seen_watch = False
    for i, w in enumerate(words):
        # `less "+!<cmd>"` / `more "+!<cmd>"`: the pager runs the rest as a shell command.
        # A startup-command operand is an executed STRING wherever it appears, so it is
        # matched by its own shape rather than by knowing which pagers accept it.
        if w.startswith("+!") and len(w) > 2:
            _add_str(w[2:])
        # ANY earlier token, not command position. Resolving command position needs the
        # end of the wrapper preamble, which needs per-flag arity -- and every
        # approximation of that was a fail-open (see above). So this over-blocks a read
        # that happens to name both, e.g. `printf "%s" find -exec <helper> ";"`. Accepted:
        # fail-CLOSED on a contrived string beats a miss on `sudo -u root find -exec`.
        if _bn(w) == "find":
            _seen_find = True
        if _seen_find and w in ("-exec", "-execdir", "-ok", "-okdir"):
            payload = []
            for w2 in words[i + 1:]:
                if w2 in (";", "+"):
                    break
                payload.append(w2)
            if payload:
                _add_tok(payload)
            continue
        base = _bn(w)
        if base == "env":
            for j in range(i + 1, len(words)):
                t2 = words[j]
                if t2.startswith("--split-string="):
                    _add_str(t2.split("=", 1)[1]); break
                if t2 in ("-S", "--split-string") and j + 1 < len(words):
                    _add_str(words[j + 1]); break
                if t2.startswith("-S") and len(t2) > 2:
                    _add_str(t2[2:]); break
        elif base == "watch" and not _seen_watch:
            # `watch COMMAND` joins its non-option arguments and runs the result through
            # sh -c, so a QUOTED payload is executed shell SOURCE that arrives here as one
            # word. Without this branch the quoted spelling reached the helper unseen while
            # every other one was caught -- sh -c, env -S, find -exec, and even UNQUOTED
            # watch, whose payload is separate words the scan already reads. That gap was
            # real: the guard is introduced by this change set, so it shipped with a hole in
            # the exact shape it exists to catch.
            #
            # Deliberately NO option-arity table. Locating the command start means knowing
            # which watch flags take a value, and every gap in such a list fails OPEN --
            # procps keeps adding options, and spellings that postdate any list we could
            # write here already broke an earlier draft of the sibling rule in cmdword.
            #
            # EVERYTHING after the watch word goes in as one payload, which the sibling rule
            # in cmdword cannot do. cmdword needs the command START, because whether a
            # command writes depends on which word is the verb; this guard does not -- it
            # searches the payload for a helper at ANY index, per the no-exemption-list
            # design above. The option words just ride along at the front as inert tokens,
            # so no arithmetic is needed to step over them.
            #
            # It goes in as a TOKEN payload, not a string, so the call site requotes it. A
            # bare space-join was tried and is wrong for the reason already documented at
            # the -exec requote: it drops the boundary a quoted token carried, so
            # `watch -- " sh" -c "python3 -I <helper> ..."` re-lexes as `sh -c python3 -I
            # <helper>`, whose -c handler reads only `python3` and never scans the helper
            # demoted to $0/$1.
            #
            # Each token is STRIPPED first. Scanning tokens individually was the first fix
            # here and was itself defeated by `watch -- " python3" -I <helper>`: one word
            # plus a leading space, so a multi-word test skips it while the shell ignores the
            # space and runs it. Padding is attacker-chosen, so it is normalized away rather
            # than matched against a whitespace list.
            # BOTH payload kinds, because the two shapes need opposite handling and each
            # candidate is judged alone anyway. The token payload keeps quoting boundaries
            # so an inner `-c` operand survives; but requoting also stops a payload that is
            # ITSELF one quoted command from being re-lexed, which is the common
            # `watch "python3 <helper> ..."` spelling. So each shell-source token is added
            # as a STRING too. Fixing only one of these swaps which spelling gets through --
            # it was measured in both directions before landing both.
            # The token payload is added only for a real ARGV of two or more words. A lone
            # token is not an argv -- it is one word the shell re-parses -- so requoting it
            # asserts a boundary that does not exist, and the requoted result is a single
            # word whose basename is the tail of the path INSIDE it. That made
            # `watch "grep -n x <helper>"` read as a bare helper invocation and block, while
            # the identical `sh -c "grep -n x <helper>"` correctly allowed. The string
            # branch below already covers the lone-token case faithfully.
            if len(words[i + 1:]) > 1:
                _add_tok([_t.strip() for _t in words[i + 1:]])
            # The JOIN, not the individual arguments. watch really does join its arguments
            # into one sh -c string, so the joined text is the faithful model AND it keeps
            # operand position: `watch grep -n x <helper>` joins back to the read it started
            # as. Adding each argument separately was tried and promotes every atom to
            # command position, so that same read blocked as a bare helper invocation.
            #
            # Joining also needs no test for which arguments are "really" shell source --
            # the detector that failed three times, first missing ` python3` (one word plus
            # a leading space), then missing `>src/file` (one bare word that redirects).
            # Stripping each token first keeps the padding from surviving the join.
            # A SUFFIX from each argument position, as far as the token budget allows, so the
            # command word is covered wherever the options happen to end. Five narrower
            # formulations were measured first and every one of them fixed one spelling and
            # opened the next -- multi-word arguments only missed a space-padded ` python3`;
            # adding a padding test still missed a lone `>src/file`; the whole-argument join
            # missed a payload behind a value-taking option. All three were fail-OPEN, and
            # the common cause is that telling an OPERAND from a COMMAND WORD is precisely
            # what needs the option-arity table this file refuses to keep.
            #
            # So the trade is taken in the other direction, which is the direction this repo
            # already chose: a suffix set resolves the command word without any arity
            # knowledge, at the cost of also promoting operands, so `watch cat <helper>`
            # reads as an invocation and blocks. That is a FALSE BLOCK on a contrived read,
            # against a FAIL-OPEN on a real invocation, in a fail-CLOSED gate -- and it is
            # the same trade already documented two branches up for `echo -exec sh -c
            # <helper>` and for the helper passed as ARGV to another script.
            #
            # Two bounds. Only the FIRST watch word is expanded: doing it per occurrence made
            # `watch watch watch ...` materialize a suffix per token -- O(tokens^2) bytes,
            # measured near 218 MB -- in a hook whose 5s timeout kills it with NO decision on
            # stdout, which the harness reads as ALLOW. A nested watch is still reached, one
            # recursion later, inside an emitted suffix. And the suffix set is charged to
            # the shared token budget, so a long argv cannot outrun it -- and exhausting it
            # blocks rather than quietly searching less.
            _starts = words[i + 1:]
            if _starts:
                # The full join goes in first and unconditionally, so there is always
                # something to scan no matter what the budget does below.
                _add_str(" ".join(_t.strip() for _t in _starts if _t.strip()))
            _bytes_left = _WATCH_MAX_PAYLOAD_BYTES
            for _k in range(1, len(_starts)):
                # Bounded by BYTES, not by a token count and not by a fixed position cap.
                # Each was tried and each was wrong in its own way. A fixed cap stops
                # searching silently -- a fail-OPEN dressed as a limit, walked past by six
                # repeated value-taking options. Charging token COUNT misses that the cost
                # is the copying: one ~8 MiB argument re-joined into ~88 suffixes is ~700 MB
                # against a budget that only ever saw 88 tokens.
                #
                # Running out does NOT quietly stop the search. The budget is forced
                # negative, so every payload already emitted fails CLOSED the moment it is
                # re-entered, exactly as budget exhaustion does everywhere else here.
                # Not-knowing blocks; it never allows.
                _suffix = " ".join(_t.strip() for _t in _starts[_k:] if _t.strip())
                _bytes_left -= len(_suffix)
                if _bytes_left < 0:
                    _helper_budget[0] = -1
                    break
                if _suffix:
                    _add_str(_suffix)
            _seen_watch = True
        # KEEP IN STEP WITH cmdword._DASH_C_RUNNERS. ash and mksh were listed there and
        # missing here, so `ash -c "<helper>"` walked straight past this guard.
        elif base in ("sh", "bash", "zsh", "dash", "ksh", "mksh", "ash", "su", "runuser",
                      "flock", "script"):
            for j in range(i + 1, len(words)):
                t2 = words[j]
                if t2.startswith("--"):
                    # getopt_long accepts any UNAMBIGUOUS ABBREVIATION, so a shortened
                    # --command runs exactly what the full spelling runs. Comparing
                    # against the full spelling left every shorter one unread.
                    name, eq, val = t2.partition("=")
                    _LONG_RUN = ("command", "session-command")
                    # su and runuser also execute --session-command, documented as
                    # equivalent to -c, so the abbreviation test covers both spellings.
                    if len(name) > 2 and any(l.startswith(name[2:]) for l in _LONG_RUN):
                        if eq:
                            _add_str(val)
                        elif j + 1 < len(words):
                            _add_str(words[j + 1])
                    continue          # NO break, for the reason given below
                if t2.startswith("-") and not t2.startswith("--") and "c" in t2[1:]:
                    # ATTACHED or separated, and NOT decidable from the spelling: after
                    # dequoting, a bundle whose tail is MORE FLAGS (bash takes the next
                    # word as the program) and a payload written flush against the -c
                    # are both a -c plus a tail. Both candidates are taken; each is
                    # re-classified alone, so a tail that is really a flag letter
                    # classifies as nothing and the extra one only ever adds a block.
                    tail = t2[t2.index("c", 1) + 1:]
                    if tail:
                        _add_str(tail)
                    if j + 1 < len(words):
                        _add_str(words[j + 1])
                    # NO break. Stopping at the first `c` assumed this token IS the -c,
                    # which needs to know whether an EARLIER flag took it as an operand:
                    # a log-file option hands the -c-looking token to itself as a
                    # FILENAME, and stopping there missed the real program behind it.
                    # That arity table is the one this gate refuses to keep, because it
                    # fails OPEN when wrong. Every token that COULD be a -c operand is a
                    # candidate instead; each is judged alone, so a filename is inert.
                    continue
    # Dedupe, order-preserving. KEEP IN STEP WITH cmdword._executed_operands, which
    # carries the full reasoning: dropping the break makes every runner rescan every later
    # c-looking option, so N repeated option pairs yield O(N^2) candidates but only O(N)
    # distinct ones. Each candidate is judged alone and the verdicts are OR-ed, so a
    # repeat can only re-derive the answer, never change it. Unbounded re-derivation here
    # is not merely slow: this hook is registered with a 5s timeout, and a timeout kills
    # it with NO decision on stdout, which the harness reads as allow.
    return tok_payloads, str_payloads


_ESC_RE = re.compile(
    r"\\(?:x([0-9A-Fa-f]{1,2})"      # \xH, \xHH
    r"|u([0-9A-Fa-f]{1,4})"          # \uH .. \uHHHH
    r"|U([0-9A-Fa-f]{1,8})"          # \UH .. \UHHHHHHHH
    r"|0?([0-7]{1,3}))")             # \ooo, \0ooo


def _decode_escapes(text):
    # Decode the ANSI-C escapes bash decodes, at bash digit widths. Python
    # `unicode_escape` codec is NOT a stand-in: it demands exactly four digits after
    # \u and eight after \U, so bash short forms survived it unchanged and a module
    # name spelled lease_$-quoted-\u73-lot read as an unrelated string. Over-decoding
    # can only make more text match, so it adds blocks and never removes one.
    def _sub(m):
        hexit = m.group(1) or m.group(2) or m.group(3)
        try:
            return chr(int(hexit, 16) if hexit else int(m.group(4), 8))
        except ValueError:
            return ""
    return _ESC_RE.sub(_sub, text)


def _ansi_c(text):
    # ANSI-C quoting as bash resolves it: escapes decoded, the dollar prefix dropped.
    # shlex knows
    # nothing of ANSI-C quoting, so EVERY token it hands back may still be encoded --
    # the interpreter name, the option letter, the operand. Resolving the whole command
    # text before it is tokenized is what makes the token comparisons downstream see
    # what bash will see, instead of only the operands one call site remembered to decode.
    return _decode_escapes(text).replace("$" + chr(39), chr(39))


def _shell_variants(text):
    # The text as written, and as the shell will have rewritten it before running it.
    # Quoting, escaping, the ANSI-C `$` prefix and a backslash-newline continuation are
    # removed before the command word is resolved; ANSI-C escapes are DECODED, so a
    # hex-escaped module name resolves to lease_slot. Additive: any variant blocks.
    out = [text, _decode_escapes(text)]
    for base in list(out):
        sq = base.replace(chr(92) + chr(10), "")
        for _ch in (chr(39), chr(34), chr(92), "$"):
            sq = sq.replace(_ch, "")
        out.append(sq)
    return out


# Shells that run a program fed to them on STDIN -- a SUPERSET of the -c runner list above,
# and separate from it on purpose: that list drives RECURSION into a -c operand, while this
# one answers only "could this consume stdin as a program". csh/tcsh/fish belong here (each
# verified executing a piped program) without dragging their -c semantics along.
# KEEP IN STEP WITH cmdword._STDIN_SHELLS.
# RESIDUAL: an ENUMERATION, so a shell nobody listed still reads as a non-shell. The family
# does not close; adding a name is free, so add rather than argue when one is found.
# The last six are not shells, but they read a PROGRAM from stdin exactly as one does --
# `printf <program> | python3` runs it -- and this list answers only that question.
# KEEP IN STEP WITH cmdword._STDIN_SHELLS.
_SHELL_NAMES = ("sh", "bash", "zsh", "dash", "ksh", "mksh", "ash", "csh", "tcsh", "fish",
                "yash", "posh", "bosh", "osh", "oil", "elvish", "xonsh", "nu",
                "python", "python2", "python3", "perl", "ruby", "node",
                "tclsh", "wish", "lua", "php",
                "awk", "gawk", "mawk", "nawk",
                "sqlite3", "ed", "ex", "psql", "gdb",
                "source", "xargs", "make")


# Compound-command keyword sets -- see the definitions above _FUNC_NAME.


def _group_delta(words):
    # How much this segment opens or closes, counting only the LEADING run: a compound
    # keyword is one only in command position, and segments are already split on separators.
    # Counting the keyword ANYWHERE was measured far wider, because `if`, `for` and `done`
    # are ordinary words in ordinary commands and a stray one opened a depth nothing closed.
    # KEEP IN STEP WITH cmdword._group_delta.
    delta = 0
    for w in words:
        if w in _GROUP_CONNECT:
            continue
        if w in _GROUP_OPEN:
            delta += 1
        elif w in _GROUP_CLOSE:
            delta -= 1
        else:
            break
    return delta


def _carries_no_command(segtext):
    # A stage holding no command at all: empty, or only a comment. _norm_for_scan turns a
    # NEWLINE into a separator, so an ordinary pipeline broken across lines arrives as a pipe
    # feeding an empty stage followed by a separator -- and reading that as the end of the
    # pipeline dropped the fed state one stage before the receiver.
    # KEEP IN STEP WITH cmdword._carries_no_command.
    stripped = segtext.strip()
    return stripped == "" or stripped.startswith("#")


def _stage_words(toks):
    # Every word a stage could resolve to a command NAME. Whitespace-splitting each token is
    # not enough: an option can carry its value ATTACHED, and BSD/macOS `env -S` + a quoted
    # program lexes to ONE token whose first word matches no shell. General rather than
    # env-specific -- drop the leading dashes and one option letter, and take everything past
    # a long option separator. Over-generating is free here.
    # KEEP IN STEP WITH cmdword._stage_words.
    for t in toks:
        forms = [t]
        # A COMMAND SUBSTITUTION inside an argument inherits the pipeline stdin, so
        # `printf <payload> | echo "$(bash)"` runs the payload while the stage command word
        # is `echo`. Splitting the substitution punctuation into whitespace hands the body to
        # the SAME shell-name test the stage gets. KEEP IN STEP WITH cmdword._stage_words.
        if "$(" in t or chr(96) in t or "(" in t:
            forms.append(t.replace("$(", " ").replace(chr(96), " ")
                          .replace("(", " ").replace(")", " "))
        if t.startswith("-"):
            forms.append(t.lstrip("-")[1:])
            forms.append(t.partition("=")[2])
        for f in forms:
            for w in f.split():
                yield w


def _piped_shell_producers(pairs):
    # Text feeding each pipeline stage that might be a shell reading its PROGRAM from
    # stdin. `bash -c "<helper> ..."` was blocked while `printf "<helper> ..." | bash` was
    # allowed -- the same invocation, one transport apart. What the producer WRITES is not
    # recoverable by parsing (a split printf assembles the name from operands that are each
    # inert), so the producer text is handed to the wider name probe instead.
    #
    # The stage test is deliberately WIDE and carries no option-arity table: deciding
    # whether a shell reads stdin from its FLAGS is the arity question this file refuses to
    # answer, and it failed open four ways when tried (`bash --norc` read as "-c present",
    # `bash --rcfile -c` read the VALUE of --rcfile as the option). The pipeline structure
    # already says the stage is fed; all that is left is whether it might be a shell. So a
    # shell name anywhere counts, tokens are re-split on whitespace (a quoted `env -S`
    # operand arrives as ONE token), and a command word carrying an expansion or a glob
    # counts too -- the shell expands /bin/[b]ash onto bash, and a literal-name test reads a
    # command word that no set contains.
    #
    # GROUPING IS TRANSPARENT. This splitter breaks on parens and on every `;`, so a
    # grouped producer, a parenthesised receiver, and a receiver whose group holds its own
    # separator all hide behind an apparent pipeline boundary -- each measured as an
    # executing write that classified as a read. A group DEPTH is tracked instead: only a
    # separator at depth 0 starts a new pipeline. Braces are counted as whole WORDS, so
    # a ${VAR} reference is not read as a group.
    #
    # ONE producer per pipeline, from its LAST candidate stage: every earlier candidate
    # produces a PREFIX of that text, so the probe sees the same thing either way, and
    # building one per stage is O(stages^2) bytes -- the shape that put the watch scan
    # above near 218 MB inside a hook whose timeout reads as allow.
    # KEEP IN STEP WITH cmdword._piped_shell_producers.
    # TWO depths, each clamped at zero, never one sum: a `case` pattern terminator is a bare
    # `)` with no opener, so a single counter let it cancel the `case` keyword depth and the
    # `;;` behind it then discarded the producer.
    out, start, last, fed, bare = [], 0, None, False, False
    pdepth = kdepth = 0
    for i, (op, seg) in enumerate(pairs):
        pdepth = max(0, pdepth + op.count("(") - op.count(")"))
        depth = pdepth + kdepth
        # A PIPE FEEDS AT ANY DEPTH, and this test comes FIRST. Folding it into the
        # in-a-group branch meant a pipeline written wholly inside a group had its pipe
        # ignored and its shell never seen as fed. Depth suppresses only the SEPARATOR.
        # Brace counting is therefore loose-but-safe: an over-count only stops a separator
        # from resetting, which WIDENS the producer, and can never hide a pipe.
        # Grouping punctuation joins the run when no segment text separates it, so a
        # valid `cmd ||(sub)` arrived as `||(` and read as a pipe. Parens carry no
        # pipeline meaning here. KEEP IN STEP WITH cmdword._is_pipe.
        if op.replace("(", "").replace(")", "") in ("|", "|&"):
            fed = True
        elif (op and all(ch in "()" for ch in op)) or depth > 0:
            pass                          # grouping: does not terminate the pipeline
        elif fed and bare:
            pass                          # a normalized newline/comment between | and the shell
        else:
            if last is not None:
                out.append(" ; ".join(p[1] for p in pairs[start:last]))
            start, last, fed = i, None, False
        _words = seg.split()
        bare = _carries_no_command(seg)
        if fed:
            try:
                lex = shlex.shlex(seg, posix=True, punctuation_chars=True)
                lex.whitespace_split = True
                lex.commenters = ""
                toks = list(lex)
            except ValueError:
                toks = None               # unparseable stage: assume the worst
            _sw = None if toks is None else list(_stage_words(toks))
            # The third disjunct is the option BUNDLE with its value attached: peeling one
            # option letter leaves `Sbash`, and peeling a fixed number never terminates
            # because the caller chooses the bundle length. endswith is O(names), not O(len^2).
            # CHARGE FIRST. _exec_payloads below is the same potentially quadratic walk
            # the budget at the end of _helper_invoked exists to bound, and this loop
            # reached it once per stage without paying. A permitted 64,004-character
            # command (`: | ` then `env ` sixteen thousand times) took 5.4s -- past the
            # hook timeout, and a timed-out hook writes NO decision, which the harness
            # reads as ALLOW. Overrunning the budget leaves it negative, so the charge at
            # the end of _helper_invoked fails CLOSED on the very first segment.
            _helper_budget[0] -= len(toks) if toks is not None else len(seg.split())
            if _helper_budget[0] < 0:
                break
            if toks is None or any(_bn(w) in _SHELL_NAMES for w in _sw) \
               or any(w.startswith("-") and any(w.endswith(n) for n in _SHELL_NAMES)
                      for w in _sw):
                last = i
            else:
                # A stage can RUN a shell without ever NAMING one in command position:
                # `env -S"$A"` hands its operand to execvp, and _peel_wrappers skips
                # `-S$A` as an option and returns None, so the command word alone can
                # never see it. The operands this stage EXECUTES are therefore asked the
                # same two questions the stage itself was. KEEP IN STEP WITH
                # cmdword._may_read_program_from_stdin, whose _executed_operands loop
                # this mirrors -- the gate lacking it was a live fail-OPEN.
                cw = _peel_wrappers(toks)
                # `.` is the POSIX `source`, and `. /dev/stdin` runs the piped text. Command
                # position ONLY: a bare `.` is an ordinary argument (`find . -name x`), and
                # putting it in _SHELL_NAMES -- matched against every word -- cost 100
                # over-blocks. KEEP IN STEP WITH cmdword._may_read_program_from_stdin.
                if cw and _bn(cw) == ".":
                    last = i
                    kdepth = max(0, kdepth + _group_delta(_words))
                    continue
                # A SUBSTITUTION is executed, so an unresolved word inside one is an
                # unresolved command word. KEEP IN STEP WITH cmdword.
                _sub_unres = False
                _flat_dollar = 0
                for _m in _SUBST_BODY_RE.finditer(seg):
                    # Only the `$(` spelling counts, because only `$(` openers are counted
                    # below -- a shared counter let an unrelated backtick substitution pay
                    # for a `$(` opener, so a nested `$( ( . /dev/stdin ) )` read as fully
                    # resolved. KEEP IN STEP WITH cmdword.
                    _flat_dollar += _m.group(1) is not None
                    _body = _m.group(1) or _m.group(2) or ""
                    # A body is a COMPOUND command, so it is SPLIT and every segment gets the
                    # receiver questions the stage got, not a weaker one asked of the body as
                    # a whole: `$(. /dev/stdin)` runs the piped payload while the outer command
                    # word is `echo`, and `$(true; . /dev/stdin)` hides the `.` behind a
                    # harmless first command that _peel_wrappers would read instead.
                    # KEEP IN STEP WITH cmdword.
                    _bsegs, _bok = _split_simple_commands(_body)
                    if not _bok or _UNRESOLVED_CW_RE.search(_body):
                        _sub_unres = True
                        break
                    for _bseg in _bsegs:
                        _bt = None
                        try:
                            _bl = shlex.shlex(_bseg, posix=True, punctuation_chars=True)
                            _bl.whitespace_split = True
                            _bl.commenters = ""
                            _bt = list(_bl)
                        except ValueError:
                            _bt = None
                        _bw = [] if _bt is None else list(_stage_words(_bt))
                        _bcw = None if _bt is None else _peel_wrappers(_bt)
                        if _bt is None \
                           or any(_bn(w) in _SHELL_NAMES for w in _bw) \
                           or (_bcw and _bn(_bcw) == "."):
                            _sub_unres = True
                            break
                    if _sub_unres:
                        break
                # NESTED substitutions have inner parens the flat pattern cannot cross, so
                # counting openers against matches is how this notices it cannot read the
                # text. Unresolved fails CLOSED. KEEP IN STEP WITH cmdword.
                if seg.count("$(") > _flat_dollar:
                    _sub_unres = True
                # UNBALANCED parens break the flat extraction without nesting anything: a
                # `case` PATTERN closes it early, so `$(case x in x) $SHELL;; esac)` yields
                # the body `case x in x` and the `$SHELL` receiver behind it is never seen.
                # Which `)` bash treats as the close is context-sensitive, so this refuses to
                # resolve it rather than model it. Scoped to substitution-bearing stages, so
                # an ordinary `case` pays nothing. KEEP IN STEP WITH cmdword.
                # KNOWN BYPASS, same as cmdword: the count is QUOTE-BLIND, so an inert
                # `echo "("` re-balances it and the truncation is exploitable again. An
                # `esac` NAME tripwire was tried and reverted -- segments split on `;`
                # first, so `esac` never lands in the `$(` segment. Recorded in ADR 0032
                # with the rest of the residual family. KEEP IN STEP WITH cmdword.
                if "$(" in seg and seg.count("(") != seg.count(")"):
                    _sub_unres = True
                if _sub_unres:
                    last = i
                    kdepth = max(0, kdepth + _group_delta(_words))
                    continue
                # The EXTGLOB spelling, resolved, in front of the same name test.
                if _EXTGLOB_NEG_RE.search(seg):
                    last = i
                    kdepth = max(0, kdepth + _group_delta(_words))
                    continue
                _deglob = _EXTGLOB_RE.sub(r"\1", seg)
                if _EXTGLOB_RE.search(_deglob) or _EXTGLOB_NEG_RE.search(_deglob):
                    # NESTED: `ba@(+(s))h` still holds a group after the inner one resolves,
                    # and iterating to a fixed point is a slower guess at a grammar. Same
                    # exit the negation and the alternation take -- unresolved, fail CLOSED.
                    last = i
                    kdepth = max(0, kdepth + _group_delta(_words))
                    continue
                if _deglob != seg:
                    _dtoks = None
                    try:
                        _dlex = shlex.shlex(_deglob, posix=True, punctuation_chars=True)
                        _dlex.whitespace_split = True
                        _dlex.commenters = ""
                        _dtoks = list(_dlex)
                    except ValueError:
                        _dtoks = None
                    if _dtoks is None or any(_bn(w) in _SHELL_NAMES
                                             for w in _stage_words(_dtoks)):
                        last = i
                        kdepth = max(0, kdepth + _group_delta(_words))
                        continue
                _tokp, _strp = _exec_payloads(toks)
                _progs = [" ".join(p) for p in _tokp] + list(_strp)
                # A WRAPPER hides the real program among its operands, and peeling can land
                # on the wrong word: `env -u X /bin/[b]ash` peels to `X`, the operand of
                # `-u`, so the globbed receiver behind it is never tested. Asking the whole
                # stage is the arity-free answer, scoped to wrapper-led stages because
                # asking it of EVERY stage measured 8.63% against ZERO for this.
                # KEEP IN STEP WITH cmdword._may_read_program_from_stdin.
                if (cw and _UNRESOLVED_CW_RE.search(cw)) \
                   or (_starts_with_wrapper(toks)
                       and any(_UNRESOLVED_CW_RE.search(w) for w in _sw)) \
                   or any(_UNRESOLVED_CW_RE.search(p) for p in _progs) \
                   or any(_bn(w) in _SHELL_NAMES for p in _progs for w in p.split()):
                    last = i
        kdepth = max(0, kdepth + _group_delta(_words))
    if last is not None:
        out.append(" ; ".join(p[1] for p in pairs[start:last]))
    return out


def _names_helper(text):
    # Which mutating helper does this text NAME, quotes resolved? A raw substring test
    # is defeated by quote concatenation -- the shell runs `lease_"slot.py"`, but the
    # text holds no contiguous `lease_slot.py` -- which is the same defeat that made
    # the rest of this detector tokenize. Tokenizing first resolves it; the substring
    # test stays as the backstop, since it is WIDER and only ever adds a block.
    try:
        lex = shlex.shlex(text, posix=True, punctuation_chars=True)
        lex.whitespace_split = True
        lex.commenters = ""
        hit = next((t for t in lex if _bn(t) in _MUTATING_HELPERS), None)
        if hit:
            return _bn(hit)
    except ValueError:
        pass
    hit = next((h for h in _MUTATING_HELPERS
                for v in _shell_variants(text) if h in v), None)
    if hit:
        return hit
    # SQUEEZED backstop: the shell joins a name across ANSI-C quoting
    # (`lease_$'slot.py'`), which shlex does not implement, and across PATHNAME
    # EXPANSION (`lease_slo[t].py`), which no static reader can evaluate. Dropping the
    # quoting and glob characters can only make more text match, never less, so it
    # adds blocks and never removes one.
    squeezed = text
    for _ch in ("$", chr(39), chr(34), "*", "?", "[", "]"):
        squeezed = squeezed.replace(_ch, "")
    return _helper_substring(squeezed)


def _abandoned_scan_probe(text):
    """Widest cheap probe for a helper NAME, for the paths where the walk cannot run.

    _names_helper alone is not enough. Its squeezed backstop DELETES glob characters, so
    `lease_slo[t].py` collapses to `lease_slot.py` and hits, while `lease_slo?.py`
    collapses to `lease_slo.py` and misses: the `?` stands FOR a character rather than
    beside one, and deleting it removes the very character that has to be there. So each
    whitespace-separated word is also asked, as a PATTERN, whether the shell could expand
    it onto a helper -- which is the question _glob_helper already answers for the
    parseable path.
    """
    hit = _names_helper(text)
    if hit:
        return hit
    return next((h for w in text.split() if any(c in w for c in "*?[")
                 for h in [_glob_helper(w)] if h), None)


def _helper_invoked(cmd, _depth=0, _full=None):
    # Which gate-state helper does this command RUN, if any? Token-level, per simple
    # command -- a raw substring test over the whole string was defeated two ways:
    # quote concatenation (lease_"slot.py" contains no matching substring, yet the shell
    # runs it), and a trailing `; : --self-check` that satisfied a whole-string exemption
    # while the FIRST segment mutated the real ledger. Segmenting and tokenizing makes
    # both spellings resolve to the same token, and scopes the exemption to the segment
    # that actually carries it.
    # RESIDUAL, same class the verb scan above declares out of scope: a name the shell
    # ASSEMBLES at run time. Quote concatenation, ANSI-C quoting and globbing are
    # squeezed out below because that is cheap; a brace RANGE is not
    # (`lease_slo{t..t}.py` yields the name only by expanding it), and neither is a name
    # built from variables. It reaches the `-m` operand on the same terms: an
    # unresolvable operand is answered by searching the command for a helper STEM, which
    # finds `M=lease_slot` but not `A=lease; B=slot; python3 -m "${A}_${B}"` or
    # `-m lease_{slot,x}`. Closing one spelling would not close the class -- the same
    # actor writes `python3 -c "$(cat lease_slo{t..t}.py)"`, where the name is equally
    # invisible -- so this stays documented rather than half-chased. See ADR 0006.
    #
    # The command as the OPERATOR typed it. A payload is re-entered on its own, so the
    # stdin check below -- which needs the redirect that feeds the payload, and that
    # redirect lives OUTSIDE it -- has to read the outer text, not this fragment.
    _whole = cmd if _full is None else _full
    if _depth == 0:
        _helper_budget[0] = _HELPER_MAX_TOKENS
        _paren_hash_ambiguous[0] = False
    if _PROC_SUBST_RE.search(_whole) and _INTERP_RE.search(_whole):
        hit = _names_helper(_whole)
        if hit:
            return hit
    if _depth > 3:
        # Fail CLOSED, for the same reason the token budget does. This was left returning
        # the bare probe when the other two abandonment paths were converted, which is an
        # inconsistency an attacker only has to find once: four nested `sh -c` layers
        # around a GLOBBED helper name (`lease_slo[t].py`) reach here, match no literal
        # stem, and measured ALLOW against the unconditional guard. Depth exhaustion is
        # not "no helper found" any more than budget exhaustion is.
        return _helper_substring(cmd) or _HELPER_UNSCANNED
    # Bash resolves ANSI-C quoting BEFORE it resolves the command word, so any token can
    # reach shlex still encoded -- not just the operand. A hex-escaped SWITCH resolves to
    # -m, and a scan for a literal `m` in the option token missed it entirely.
    # Re-entering on the resolved text puts every downstream comparison on what bash will
    # actually see; additive, so it can only add a block.
    _resolved = _ansi_c(cmd)
    if _resolved != cmd:
        hit = _helper_invoked(_resolved, _depth + 1, _full=_ansi_c(_whole))
        if hit:
            return hit
    # A COMMAND SUBSTITUTION runs before the command that consumes its output, so the
    # consumer being harmless proves nothing: `echo "$(... lease_slot.py ...)"` claims a
    # slot and logs a sanctioned-bypass event, then prints the slot number. Flatten the
    # substitution markers into separators and re-scan, so the body is judged as the
    # command it is. Deliberately crude rather than a second parser: dropping quotes and
    # turning `$(`/backtick/`)` into `;` can only ADD segments, so it errs toward
    # blocking. The one over-block it admits is a command that both substitutes AND names
    # a helper in the same breath, e.g. echo "see $(ls) lease_slot.py".
    if _depth <= 2 and ("$(" in cmd or chr(96) in cmd):
        # Quotes are removed, NOT replaced with a space: the shell CONCATENATES adjacent
        # quoted runs, so `lease_"slot.py"` is one word and spacing it out unmatched it.
        _flat = cmd.replace(chr(34), "").replace(chr(39), "")
        _flat = (_flat.replace("$(", " ; ").replace(chr(96), " ; ")
                      .replace(")", " ; "))
        _hit = _helper_invoked(_flat, _depth + 1, _full=_whole)
        if _hit:
            return _hit
    # INDIRECTION WITHDRAWS THE MENTION CONTRACT. Normally a helper NAMED in an operand
    # is data -- that is what keeps `cat .../lease_slot.py` and `echo lease_slot.py`
    # allowed. But a command that defines a function, defines an alias, or calls eval can
    # re-point a name so an operand becomes the thing that runs:
    #   echo() { "$@"; }; echo sh -c "<payload>"
    #   shopt -s expand_aliases; alias echo=eval; echo "<payload>"
    # Rather than model the rebinding (or keep an exemption list and lose to the next
    # spelling), the contract is dropped WHOLESALE for such a command and every token is
    # examined. It only ever blocks more, and only for commands that asked for it by
    # introducing indirection in the first place.
    # Matched on a DEQUOTED copy: the shell concatenates adjacent quoted runs, so
    # `ev"al" "<payload>"` runs eval while the raw text contains no contiguous `eval`.
    # Both the trigger AND the search run on the dequoted copy. Dequoting only one of
    # them left `eval "... lease_""slot.py ..."` -- eval detected, helper name split
    # across two quoted runs and therefore not found in the raw text.
    # ...and against the NORMALIZED copy as well, where a backslash-newline continuation has
    # been rejoined and `${IFS}` restored to whitespace. `ha\<newline>sh -p ...` and
    # `hash${IFS}-p${IFS}...` are indirection that the raw text spells neither of.
    # KEEP IN STEP WITH cmdword._has_indirection.
    _dq = _dequote(cmd)
    # _shell_variants, not just _dequote: the shell strips ESCAPES before it resolves a
    # command word, so `h\a\s\h -p ...` runs the builtin while neither the raw text nor the
    # dequoted copy spells it. cmdword._has_indirection already asked the variants; this
    # copy asked only the dequoted text, which is the same defect one layer down.
    # KEEP IN STEP WITH cmdword._has_indirection.
    if any(_INDIRECTION_RE.search(_v)
           for _text in (cmd, _norm_for_scan(cmd))
           for _v in _shell_variants(_text)):
        # _abandoned_scan_probe, NOT the plain substring test: it also squeezes quoting and
        # GLOB characters, so an indirect receiver carrying a globbed helper name
        # (`eval "$A"` fed `lease_slo[t].py`) is caught. The substring test saw no literal
        # name and allowed it -- and this guard is UNCONDITIONAL, so that was a live hole.
        _hit = _abandoned_scan_probe(_dq)
        if _hit:
            return _hit
    _pairs, ok = _split_with_ops(_norm_for_scan(cmd))
    # `)#` -- the comment defuser could not tell whether that paren delimited a command and
    # said so instead of guessing. Unresolved is the fail-CLOSED case, the same as an
    # unparseable command below, so the squeezed probe answers it.
    if _paren_hash_ambiguous[0]:
        _hit = _abandoned_scan_probe(cmd)
        if _hit:
            return _hit
    segs = [_s for _op, _s in _pairs]
    if ok:
        # A shell on the RECEIVING end of a pipe runs whatever the producer wrote, and the
        # walk below can only see that payload as data. Same condition and same reason as
        # cmdword._piped_shell_producers -- keep the two in step.
        for _prod in _piped_shell_producers(_pairs):
            # _abandoned_scan_probe, NOT the plain _names_helper: the probe also squeezes
            # GLOB characters, so a payload naming `lease_slo?.py` -- which the shell
            # expands to the helper while the text names none literally -- is caught. The
            # sibling call sites already used the probe; this one did not, and a glob in a
            # PIPED payload walked through.
            _hit = _abandoned_scan_probe(_prod)
            if _hit:
                return _hit
    if not ok:
        # Unparseable -- most often a Bash-VALID heredoc whose BODY contains an
        # apostrophe, which this segmenter models as shell source (a known limitation the
        # block message below names). Probed with _names_helper, not the plain substring:
        # it also squeezes quoting and GLOB characters, so `lease_slo[t].py` -- which the
        # shell expands to a helper while naming none literally -- is caught here.
        #
        # NOT fail-closed, deliberately, and this is the one abandonment path where that
        # is right. The others (budget, oversize, depth) are reached only by shapes with
        # no honest form. This one is reached by a heredoc carrying prose,
        # which is ordinary; blocking every heredoc containing an apostrophe trades a
        # narrow bypass for a constant, benign failure. The squeezed probe closes the
        # bypass without that cost. Residual: a name assembled at RUN time still escapes,
        # which is the accepted ADR 0006 limitation, not a new one.
        return _abandoned_scan_probe(cmd)
    for segtext in segs:
        try:
            lex = shlex.shlex(segtext, posix=True, punctuation_chars=True)
            lex.whitespace_split = True
            lex.commenters = ""
            toks = list(lex)
        except ValueError:
            # Unbalanced quoting inside ONE segment: same reasoning and same probe as the
            # segmenter above -- squeezed, so a globbed helper name is still caught.
            return _abandoned_scan_probe(segtext)
        # Charge before scanning: the O(tokens^2) walk below is what this bounds.
        _helper_budget[0] -= len(toks)
        if _helper_budget[0] < 0:
            # Fail CLOSED. The earlier version returned only the substring probe, on the
            # reasoning that the cmdword budget blocks the same shape anyway -- and that
            # reasoning was WRONG in the one way that matters. This guard is
            # UNCONDITIONAL: it blocks whether or not a design review is pending. The
            # cmdword budget only decides is_file_mod, which blocks solely WHILE a review
            # is pending. So with nothing pending the two do not overlap at all, and a
            # command of 4001 filler flags followed by `-m lease_slot` measured ALLOW.
            # Abandoning the scan cannot report "no helper" -- it can only report that it
            # does not know, and not-knowing blocks here.
            return _helper_substring(cmd) or _HELPER_UNSCANNED
        # Follow sub-programs FIRST: a payload handed to find -exec, env -S or a shell
        # -c is executed just as surely as the top level, and looking only at the top
        # level let `find . -exec python3 .../lease_slot.py .claude fake 1 ;` through.
        # WHICH token list, decided once and used for both scans below. Stripping is only
        # safe in the command-position regime. After shlex has dequoted, a literal `>`
        # handed to a wrapper as an OPERAND is byte-identical to a redirect operator --
        # the case _is_redir warns about above -- so _strip_redirs would drop it AND the
        # token after it. That is the interpreter: `env -u ">" python3 .../lease_slot.py`
        # runs the helper and measured ALLOW. The wrapper regime scans EVERY token and so
        # needs no stripping at all; the command-position regime needs it, because there a
        # redirect TARGET left in place (</dev/null -> /dev/null) becomes the command
        # word and hides the interpreter behind it. Two different failures, one on each
        # side, which is why the choice is conditional rather than either one alone.
        _wrapped = _starts_with_wrapper(toks)
        _scan_toks = toks if _wrapped else _strip_redirs(toks)
        _tokp, _strp = _exec_payloads(_scan_toks)
        for _p in _tokp:
            # shlex.quote per token, NOT a bare join. A bare join loses the boundary a
            # quoted token carried, so `-exec sh -c "python3 -I .../lease_slot.py ..."`
            # re-lexed as `sh -c python3 -I .../lease_slot.py ...` -- and the -c handler
            # then reads only `python3` as the program, with the helper demoted to $0/$1
            # and never scanned. Requoting round-trips the token list exactly.
            _hit = _helper_invoked(" ".join(shlex.quote(_t) for _t in _p),
                                   _depth + 1, _full=_whole)
            if _hit:
                return _hit
        for _p in _strp:
            _hit = _helper_invoked(_p, _depth + 1, _full=_whole)
            if _hit:
                return _hit
        # The helper must be EXECUTED, not merely named. Naming one is an ordinary read
        # -- `cat .../lease_slot.py`, `git diff -- .../audit_append.py`,
        # `echo lease_slot.py`, `python3 safe.py lease_slot.py` -- and blocking those
        # contradicts the read/mention contract the rest of this detector maintains.
        words = _scan_toks
        # Locate the interpreter. Two regimes, same reasoning as the verb scan above: a
        # wrapper can carry flags that take an OPERAND (`env -u FOO python3 ...`,
        # `sudo -u root python3 ...`), so peeling to the first non-flag word picks the
        # operand and misses the interpreter behind it. When the segment STARTS with a
        # wrapper, look for the interpreter anywhere; otherwise require it in command
        # position, which is what keeps `echo python3 lease_slot.py` a mention.
        pyi = None
        if _wrapped:
            pyi = next((i for i, t in enumerate(words)
                        if _bn(t).startswith("python")), None)
        else:
            cw = _peel_wrappers(words)
            if cw is not None and _bn(cw).startswith("python"):
                pyi = words.index(cw)
            elif cw is not None and _bn(cw) in _MUTATING_HELPERS:
                # The script itself is the command word (executable bit set).
                i = words.index(cw)
                if not (i + 1 < len(words) and words[i + 1] == "--self-check"):
                    return _bn(cw)
                continue
        if pyi is None:
            continue
        # The EXECUTED script is the interpreter first non-flag argument. Anything later
        # is that script own argument, so `python3 safe.py lease_slot.py` runs safe.py,
        # and `python3 -c ... # lease_slot.py` runs a -c program.
        script = None
        j = pyi + 1
        while j < len(words):
            w = words[j]
            # Normalized first: `/dev/fd/./0`, `/dev//fd/0` and `/dev/fd/../fd/0` all
            # open descriptor 0, and matching the canonical spelling alone let each of
            # them read as an ordinary script name.
            if (_FD_SCRIPT_RE.match(posixpath.normpath(w))
                    or _UNRESOLVED_OPERAND_RE.search(w)):
                # The PROGRAM comes from stdin, so it is not an argument at all and the
                # operand walk picked the next plain operand as the script:
                # `python3 - .claude 20 0 3600 < .../lease_slot.py` ran the helper while
                # the parser judged `.claude`. What stdin carries is not statically
                # visible -- it arrives by redirect, by pipe from an earlier segment, or
                # by heredoc -- so the WHOLE command is searched, not this segment.
                # That over-blocks a contrived `python3 - lease_slot.py </dev/null`,
                # where the helper is only an argument and stdin is empty. Accepted:
                # `python3 -` is an execution context, not a mention, and enumerating
                # the empty-stdin spellings is the allowlist this file keeps deleting.
                hit = _glob_helper(w) or _names_helper(_whole)
                if hit:
                    return hit
                break
            if w.startswith("-"):
                # A flag that takes an operand consumes the next word (-c PROG, -m MOD).
                # `-m MODULE` runs the helper without ever naming the FILE, and `-m`
                # was on the list of flags whose operand is skipped as an option value.
                # Matched inside a short-flag CLUSTER, the same way the -c handler
                # reads its program: CPython accepts `-Bm mod` and `-Bmmod`, so
                # anchoring on a leading `-m` caught only the simplest spelling.
                # `--` ends option parsing: the NEXT word is the script, and a word that
                # merely looks like an option is a filename from here on.
                if w == "--":
                    script = words[j + 1] if j + 1 < len(words) else None
                    break
                if w == "--module" and j + 1 < len(words):
                    if _module_helper(words[j + 1]):
                        return _module_helper(words[j + 1])
                    if not _PLAIN_MODULE_RE.match(words[j + 1]):
                        stem = next((m for m in _MUTATING_MODULES
                                     for v in _shell_variants(_whole) if m in v), None)
                        if stem:
                            return stem + ".py"
                    break
                if w.startswith("--"):
                    j += 2 if w == "--check-hash-based-pycs" else 1
                    continue
                # A short-option CLUSTER is consumed left to right, and the FIRST
                # option taking an operand swallows the cluster remainder -- or the
                # next word when the cluster ends there. Testing for an `m` ANYWHERE
                # read `-Wm` (which is `-W m`) as a module switch, then skipped the
                # script word that followed it as if it were the module name.
                k = next((i for i, ch in enumerate(w[1:]) if ch in "cmWXQ"), None)
                if k is None:
                    j += 1
                    continue
                tail = w[2 + k:]
                if w[1 + k] == "m":
                    mod = tail if tail else (words[j + 1] if j + 1 < len(words) else "")
                    if _module_helper(mod):
                        return _module_helper(mod)
                    # An operand the shell rewrites (`M=lease_slot; python3 -m "$M"`)
                    # names its module only at run time, so the whole command is
                    # searched for a helper STEM -- the module spelling, which carries
                    # no `.py` for _names_helper to find.
                    if not _PLAIN_MODULE_RE.match(mod):
                        stem = next((m for m in _MUTATING_MODULES
                                     for v in _shell_variants(_whole) if m in v), None)
                        if stem:
                            return stem + ".py"
                if w[1 + k] in ("c", "m"):
                    # CPython STOPS parsing options at -c and -m; everything after is
                    # argv for the program it already chose. Walking on read the next
                    # operand as a second module or as a script, so `python3 -m json.tool
                    # lease_slot.py` -- which only READS the helper -- was blocked.
                    #
                    # But stopping OUTRIGHT was a fail-open: several stdlib modules take a
                    # SCRIPT PATH and run it. `python3 -m cProfile <helper>.py .claude 20
                    # 0 3600` executes the helper -- claiming a real lease slot and
                    # minting a skip-review-consumed event -- while this walk classified
                    # only `cProfile` and allowed it. Confirmed for cProfile, profile,
                    # pdb, trace, timeit and runpy, which is already too many spellings to
                    # chase one at a time.
                    #
                    # So the question is INVERTED, the way it is everywhere else in this
                    # file: an executes-its-argument list fails OPEN on the module nobody
                    # thought of, while a READS-ONLY list fails CLOSED on it. Only the
                    # handful of modules that provably just read their operand let the
                    # walk stop; for anything else the remaining words are still searched
                    # for a protected helper. The cost of being wrong is a false block on
                    # an unlisted read-only module, which is the safe direction and is
                    # cleared by adding it to the list.
                    # Both spellings of "the helper", because a runner module accepts
                    # both. _glob_helper resolves a FILE operand, including the expanded
                    # forms `lease_slo[t].py` and `lease_slot*.py` -- an equality test on
                    # the literal spelling never matches those while the command still
                    # runs the helper, and the direct-script path below already resolves
                    # operands this way. _module_helper resolves a MODULE operand:
                    # `python3 -m cProfile -m lease_slot` hands cProfile its OWN -m, which
                    # runs the helper as __main__ without the name ever carrying `.py`.
                    #
                    # EVERY later word is scanned, with no stop. A stop at the first `.py`
                    # operand was tried, to spare the one false positive where the helper
                    # is merely argv to another profiled script -- and it was a bad trade:
                    # an option operand can itself end in `.py`, so `-o out.py <helper>`
                    # broke at out.py while cProfile still executed the helper. That
                    # exchanged a false BLOCK for a fail-OPEN. Any narrowing here needs
                    # per-option arity, the table this file refuses everywhere because it
                    # fails open wherever it is wrong. The residual false positive is
                    # deliberate and recoverable through the skip lease.
                    if w[1 + k] == "m" and not _readonly_module_trusted(mod, words):
                        for later in words[j + 1:]:
                            _g = _glob_helper(later) or _module_helper(later)
                            if _g:
                                return _g
                    break
                j += 1 if tail else 2
                continue
            script = w
            break
        if script is None or _bn(script) not in _MUTATING_HELPERS:
            continue
        # Exempt ONLY the exact `<helper> --self-check` shape: the flag must be the
        # helper FIRST argument. A looser any-token test was satisfied by a trailing
        # `# --self-check`, which bash treats as a comment but this parser (with
        # commenters disabled) tokenizes -- so the real, mutating invocation ran.
        if j + 1 < len(words) and words[j + 1] == "--self-check":
            continue
        return _bn(script)
    return None


def _writes_marker(cmd, markers):
    # Decide block/allow by SEGMENTING then TOKENIZING the command instead of
    # regex: a marker basename that is a redirect (>) target or a tee/rm operand
    # is a write/forge attempt -> block; a marker that appears only as a read
    # (cat / [ -f ] / < input) or a quoted string literal in an unrelated command
    # is allowed.
    #
    # Out of scope (accepted defense-in-depth residual, ADR 0006 — the real
    # anti-forge boundary is the trusted writers plus diff-hash binding, and
    # Claude is the trusted dispatcher). The detector stops the DIRECT, common
    # forms — redirect/tee/rm/touch/cp/mv/ln/install to a marker, plus quoting, ${IFS}, same-command
    # variable, line-continuation, and ANSI-C-prefix obfuscation of them. It does
    # NOT try to stop a dispatcher that runs an ARBITRARY STRING OR PROGRAM; that
    # is an unbounded class, all equivalent to eval, and is left to the diff-hash
    # backstop:
    #   - execute-a-string: eval, sh/bash/zsh/dash -c "...", and interpreter
    #     evaluation (python -c, perl -e, ruby -e, node -e, awk, xargs,
    #     find -exec/-delete)
    #   - command substitution: backticks and $(...)
    #   - indirect writers NOT enumerated as command words: other copy/convert tools
    #     (cp/mv/ln/install ARE blocked — see #290 below; truncate/unlink/rmdir/dd
    #     joined them in #519 once the lease ledger and audit log became gate state)
    #   - runtime name synthesis: pathname globbing (* ? [ ]) and brace expansion
    #     ({a,b}) that expand to the marker (rm ...loca?, tee ...loca{l,})
    #   - environment / nested / computed shell variables, ANSI-C escape
    #     SEQUENCES (\x6c-style), and the nested single-quote idiom (which trips
    #     the segmenter into its fail-closed substring fallback)
    # These are one tier against a HOSTILE dispatcher: one that can eval can forge
    # the marker directly, so blocking a subset is theater against that actor.
    # #290 extended the blocked verbs (rm/tee → +touch/cp/mv/ln/install as command
    # words) anyway, because the realistic threat is an accidental/lazy self-bypass
    # by a COOPERATIVE agent (a bare `touch .claude/skip-litmus.local`); blocking the
    # bare-command indirect-write forms removes the easy path and forces any bypass
    # to be a deliberate eval-forge a cooperative agent will not build. A human touch
    # typed in a real terminal is unaffected — this hook only sees the Claude tool
    # calls. See #227 and the ADR 0006 residual addendum.
    #
    # #519 CLOSED the wrapper-hidden half of that residual (`sudo touch <marker>`,
    # `command rmdir <slot>`, `env truncate <log>`): the command word is now chosen
    # after peeling wrapper preambles. The residual was tolerable while the only
    # wrapper-reachable targets were markers a cooperative agent had no reason to
    # forge; it stopped being tolerable once the skip LEASE ledger and the bypass
    # audit log became gate state, since those two shapes reset the use ceiling and
    # erase the trail respectively. A residual that is the EASIEST path is not a
    # residual. The execute-a-string class (eval, sh -c, python -c) is UNCHANGED and
    # remains the documented residual.
    norm = _norm_for_scan(cmd)
    # Returns (marker_or_None, unparseable). `unparseable` is TRUE only for the
    # fail-CLOSED raw-substring path below, where the command could not be parsed
    # at all and a marker WRITE is therefore indistinguishable from a mere MENTION.
    # It changes NO decision -- both paths block -- it only lets the caller emit an
    # accurate diagnostic instead of asserting a write that may not exist (#365).
    segs, ok = _split_simple_commands(norm)
    if not ok:
        # Unterminated quote / dangling escape: fail CLOSED via raw substring.
        return (next((mf for mf in markers if _bn(mf) in cmd), None), True)
    # simple_vars persists across segments so a cross-segment assignment
    # (m=.../marker ; rm "$m") resolves; updated in order, so a write sees the
    # value assigned BEFORE it and a later reassignment cannot mask it.
    simple_vars = {}
    flags = {"unparseable": False}
    for segtext in segs:
        # Reset per segment: the flag must describe the segment that PRODUCED the
        # hit, not some earlier one. Shared across the loop it would report
        # "could not parse" for a genuine forge that merely FOLLOWED an unparseable
        # segment — and that error runs the wrong way, telling the operator "nothing
        # was necessarily being written" about a real write attempt. A security
        # message may overstate; it must not understate.
        #
        # Defensive, not known-reachable: _split_simple_commands splits only on
        # UNQUOTED separators, so each segment inherits balanced quote parity and the
        # shlex ValueError below has nothing to reject — a real imbalance trips the
        # whole-command ok=False path first. The reset costs one assignment and holds
        # the invariant if the two parsers ever drift apart.
        flags["unparseable"] = False
        hit = _scan_segment(segtext, markers, simple_vars, flags)
        if hit:
            return (hit, flags["unparseable"])
    return (None, False)


try:
    d = json.load(sys.stdin)
    tool = d.get("tool_name", d.get("toolName", ""))
    inp = d.get("tool_input", d.get("toolInput", {}))
    if isinstance(inp, str):
        inp = json.loads(inp)

    MARKER_FILES = [
        "litmus-passed.local",
        "pr-review-passed.local",
        # Dual-voice PR artifacts — writable ONLY by run-review-loop.sh: the
        # backstop verdict via --run-backstop (a captured claude -p dispatch → an
        # internal writer; no public writer subcommand — removes the easy #350 retype
        # forge, though a Bash-holding dispatcher can still fabricate: accepted ADR
        # 0006 residual), the Codex-lead verdict inline on an actual Codex PASS.
        # Direct Write/Edit/MultiEdit/shell-redirect/rm against them is blocked so
        # the hash re-derivation in the writer cannot be bypassed by a file forge.
        # (Keystone for ADR 0006; .local.json suffix matched as a substring.)
        "pr-codex-lead.local.json",
        "pr-backstop-verdict.local.json",
        "skip-litmus.local",
        "skip-design-review.local",
        # #519 — the skip LEASE ledger. Its per-use slots are what bound the bypass to
        # 20 writes, so it is gate state exactly like the skip file itself. Unprotected,
        # the ceiling is trivially resettable BY the agent it constrains: the gate grants
        # a use for `rm -rf .claude/.skip-design-review-lease.d`, that command erases
        # every slot, and the next write starts again at slot 1 — an unbounded lease
        # that merely looks bounded. (No apostrophes in this block: it is a
        # single-quoted shell string, so one would terminate the Python source.)
        # Listed here so the unconditional forge guard
        # (which runs before the F9 $STATE_DIR rm/mkdir exemption could allow it) blocks
        # the delete outright. The cleanup done by this gate is script code, not a
        # tool call, so it is unaffected.
        ".skip-design-review-lease.d",
        # #519 — the bypass audit log. Hardening the APPEND is worth nothing if the
        # FILE can be erased for free: writes under $STATE_DIR classify as SAFE and a
        # bare rm of a $STATE_DIR path hits the F9 exemption, so a session could delete
        # bypass-log.jsonl without even spending a lease use, wiping every recorded
        # bypass — and the next use simply recreates the file and is granted. The whole
        # design-clear/lease story is detection rather than prevention, which only holds
        # while the record survives. Reads (cat/grep) are unaffected: the forge detector
        # blocks only redirect/tee/rm/touch/cp/mv/ln/install positions.
        "bypass-log.jsonl",
        "reviewed-commits.local",
        "design-review-needed.local",
    ]

    if tool in ("Write", "Edit", "MultiEdit"):
        fp = inp.get("file_path", inp.get("filePath", ""))
        for mf in MARKER_FILES:
            if mf in fp:
                print("BLOCK_MARKER|" + mf)
                sys.exit(0)

    elif tool == "Bash":
        cmd = inp.get("command", "")
        # #519 helpers that MUTATE gate state (lease slots, the audit log). They are
        # internal to this gate, which runs them as a subprocess -- never as a Claude
        # Bash tool call -- so a Bash call naming them is either a mistake or a bypass.
        # DEFENCE IN DEPTH, not the only defence. The helpers are also safe by
        # construction now: lease_slot.py reads the skip file mtime ITSELF rather than
        # accepting it (a caller-supplied mtime was forgeable, and a fabricated one
        # prunes the genuine slots and resets the ceiling), and audit_append.py builds
        # its record from fixed fields rather than accepting arbitrary JSON. That
        # matters because neither command has to name a protected path or a
        # modification verb, so nothing else in this detector would notice it — and
        # guessing every invocation spelling is the arms race this file already warns
        # about. Same treatment as the marker writer below.
        # --self-check is exempt: it runs entirely in a temp dir, mutates no real state,
        # and the test suite invokes it through Bash.
        # Oversized commands skip the full walk, which is what the 5s hook timeout cannot
        # afford; a substring probe stays cheap at any length. But NOT scanning is not the
        # same as finding nothing, and the note that used to sit here -- that a command
        # this large is independently called BASH_MOD by the classifier below -- does not
        # rescue it: BASH_MOD only blocks WHILE a design review is pending, and this guard
        # is unconditional. So an unscannable command fails CLOSED here too.
        _blocked_helper = (_helper_invoked(cmd) if len(cmd) <= 65536
                           else (_helper_substring(cmd) or _HELPER_UNSCANNED))
        if _blocked_helper == _HELPER_UNSCANNED:
            print("BLOCK_UNSCANNABLE|")
            sys.exit(0)
        if _blocked_helper:
            print("BLOCK_MARKER_SCRIPT|" + _blocked_helper)
            sys.exit(0)
        # Block direct invocation of the marker writer UNLESS called via
        # the canonical litmus plugin path. The script validates internally that
        # a builtin review was actually triggered (checks handoff file existence).
        # Without this allowlist, builtin fallback (exit 3) creates a catch-22:
        # SKILL.md tells Claude to call the script, but the gate blocks it.
        if "write-review-marker" in cmd:
            if re.search(r"(?:ba)?sh\s+.*litmus/scripts/write-review-marker", cmd):
                print("OK|")
            else:
                print("BLOCK_MARKER_SCRIPT|write-review-marker.sh")
            sys.exit(0)
        # Block shell redirects / tee / rm TARGETING marker files. ALWAYS
        # tokenizes (see _writes_marker) rather than pre-filtering on the raw
        # command, because shell quote concatenation can assemble a marker
        # filename that no contiguous raw substring contains. Quoted, wrapped,
        # and multi-operand targets are caught without false-positiving benign
        # commands that merely mention a marker name in a non-write position.
        hit, unparseable = _writes_marker(cmd, MARKER_FILES)
        if hit:
            print(("BLOCK_MARKER_UNPARSED|" if unparseable else "BLOCK_MARKER|") + hit)
            sys.exit(0)

    print("OK|")
except Exception:
    print("OK|")
' 2>/dev/null || echo "OK|")

MARKER_ACTION="${MARKER_CHECK%%|*}"
MARKER_TARGET="${MARKER_CHECK#*|}"

# Fail-CLOSED fallback block (#365) — the command could not be PARSED (unbalanced
# quote / dangling escape), so the detector cannot tell a marker WRITE from a mere
# MENTION and blocks on the raw substring. Same decision as BLOCK_MARKER, different
# TRUTH: asserting "you tried to write a marker" here is often simply false, and the
# generic message sent operators hunting for a write that never existed.
#
# The realistic trigger is prose, not a forge: a possessive apostrophe inside a
# heredoc commit message that documents a bypass ("the operator's skip file"). Bash
# does no quote processing in a heredoc BODY, but this gate models the body as shell
# source, so one apostrophe opens a quote that never closes. Deciding data-vs-source
# properly needs a real shell parser (quoted vs unquoted delimiters change expansion;
# wrappers/pipelines/later commands change the consumer), and building one INSIDE the
# forge detector was tried and rejected: every iteration opened a new segment-split
# bypass. Naming the cause precisely costs nothing and stays fail-closed.
if [ "$MARKER_ACTION" = "BLOCK_MARKER_UNPARSED" ]; then
    block_emit "BLOCKED (fail-closed): this command could not be parsed — it has an unbalanced quote or a dangling escape — and its text mentions the gate marker ($MARKER_TARGET).

Nothing was necessarily being written. Because the command is unparseable, the gate cannot distinguish a marker WRITE from a mere MENTION, so it blocks.

If you are only NAMING the marker in text (a commit message, a heredoc, an echo), the usual cause is an apostrophe in prose inside a heredoc body — bash treats a heredoc body as literal text, but this gate parses it as shell source. Any of these clears it:
  - rephrase to avoid the literal filename (say \"the operator-created skip file\")
  - use: git commit -m \"...\" instead of a heredoc (a quoted -m argument parses fine)
  - balance the quotes in the body

If you ARE trying to write a marker: gate markers are written by review infrastructure after a genuine review pass. Writing them manually forges compliance. Run /litmus or /blueprint-review instead.

Note: a block here does NOT consume a skip file — but an earlier gate in the SAME tool call may already have, which is why a retry can fail with a different gate's message. Do NOT create or re-touch a skip file yourself: it is a user-only escape hatch. If the user is bypassing a gate, ask them to re-create it in their terminal before you retry."
    exit 0
fi

if [ "$MARKER_ACTION" = "BLOCK_MARKER" ]; then
    # Breadcrumb back to the legitimate writer. A Claude that went off-script
    # (direct redirect instead of the trusted wrapper) lands here; without a
    # pointer to the real command it tends to reach for the skip file instead.
    WRITER_HINT=""
    case "$MARKER_TARGET" in
        pr-review-passed.local)
            WRITER_HINT="
To write this marker correctly: finish the PR deep review, then run the trusted wrapper (it computes the diff hash and writes the marker — direct writes stay blocked by design):
  bash \"\${BUSDRIVER_PLUGIN_ROOT:-\${CLAUDE_PLUGIN_ROOT}}/skills/litmus/scripts/run-review-loop.sh\" --write-pr-marker" ;;
        litmus-passed.local)
            WRITER_HINT="
This marker is written automatically when the /litmus commit review passes — re-run the review loop to completion instead of writing it by hand." ;;
        pr-backstop-verdict.local.json)
            WRITER_HINT="
This is the PR security/bugs backstop artifact. It is written ONLY by --run-backstop, which dispatches the read-only backstop as a captured claude -p subprocess and pipes the result to an internal strict writer (re-derives the diff hash, fails closed on stale/bad input). There is no manual writer subcommand — that would let the verdict be forged by hand (#350):
  bash \"\${BUSDRIVER_PLUGIN_ROOT:-\${CLAUDE_PLUGIN_ROOT}}/skills/litmus/scripts/run-review-loop.sh\" --run-backstop" ;;
        pr-codex-lead.local.json)
            WRITER_HINT="
This is the PR Codex-lead artifact. It is written ONLY by the litmus PR review, inline on an actual Codex PASS — there is no manual writer subcommand (that would let a PASS be forged without a review). Re-run the PR review to (re)produce it:
  LITMUS_MODE=pr bash \"\${BUSDRIVER_PLUGIN_ROOT:-\${CLAUDE_PLUGIN_ROOT}}/skills/litmus/scripts/run-review-loop.sh\"" ;;
    esac
    block_emit "BLOCKED: Cannot write to gate marker file ($MARKER_TARGET) directly.
Gate markers are written by review infrastructure after a genuine review pass.
Writing them manually forges compliance. Run /litmus or /blueprint-review instead.${WRITER_HINT}
If you need to skip review, ask the user to run: touch $(git rev-parse --show-toplevel 2>/dev/null || echo '.')/$STATE_DIR/skip-litmus.local"
    exit 0
fi

if [ "$MARKER_ACTION" = "BLOCK_UNSCANNABLE" ]; then
    block_emit "BLOCKED: this command is too large or too deeply nested for the gate to determine whether it invokes a gate-state helper.
The check that guards those helpers runs on EVERY command, not only while a review is pending, so a scan it could not finish is refused rather than assumed safe.
Split the command into smaller ones, or write long content to a file instead of passing it inline."
    exit 0
fi

if [ "$MARKER_ACTION" = "BLOCK_MARKER_SCRIPT" ]; then
    block_emit "BLOCKED: Cannot call $MARKER_TARGET directly.
This script is internal to the review loop and should only be invoked by run-review-loop.sh after a genuine review pass.
Run /litmus instead."
    exit 0
fi

# ── Design-review pending? (ADR-A/C — replaces the CWD-relative marker check) ──
# Anchor = the target file's dir (resolves the file's OWN worktree common-dir, so
# a Write in a linked worktree sees the shared marker), else the hook cwd. All
# linked worktrees share one common-dir, so any in-repo anchor yields the same set.
#
# #347 item 2b — "Bash-write effective-directory resolution" (was DEFERRED §2/§9):
# a Bash tool call has no file_path, so the anchor was the payload cwd. A command that
# changes directory inline (`cd /other-repo && > src/impl.sh`) then wrote in the WRONG
# repo relative to the checked anchor. The inline python imports the shared best-effort
# effective_cwd() parser (gitcmd_detect.py) and anchors the Bash case on the directory
# the write LANDS in, honoring a leading `cd` when it can resolve one confidently. This
# is BEST-EFFORT accuracy, NOT fail-closed: an unresolvable/ambiguous cd falls back to
# the payload cwd (the pre-existing cd-blind anchor — never worse). Perfect static cd
# resolution is undecidable, so a fail-closed promise here is an unwinnable arms race
# (ADR 0021); item 1's fail-closed is on the ARM, a filesystem fact, not cd parsing.
# shellcheck disable=SC2016  # python3 -c program; $/quotes are literal code
_MK_ANCHOR="$(printf '%s' "$INPUT" | python3 -I -c '
import sys
sys.path[:] = [p for p in sys.path if p not in ("", ".")]
# argv[1] is the TRUSTED gate lib dir (BASH_SOURCE-derived). Prepend it AFTER the
# CWD scrub so a repo-planted gitcmd_detect.py cannot hijack the import; -I already
# ignores PYTHONPATH and site.
sys.path.insert(0, sys.argv[1])
import json, os
try:
    from gitcmd_detect import effective_cwd
except Exception:
    effective_cwd = None
try:
    d = json.load(sys.stdin)
    tool = d.get("tool_name", d.get("toolName", ""))
    inp = d.get("tool_input", d.get("toolInput", {}))
    if isinstance(inp, str):
        inp = json.loads(inp)
    cwd = d.get("cwd") or "."
    if tool == "Bash":
        cmd = inp.get("command", "") if isinstance(inp, dict) else ""
        # Best-effort: honor a resolvable leading `cd`, else the payload cwd. A missing
        # parser just means the pre-existing cd-blind anchor — no worse than before.
        eff = effective_cwd(cmd, cwd)[0] if effective_cwd is not None else cwd
        anchor = eff or cwd
    else:
        fp = inp.get("file_path", inp.get("filePath", "")) if isinstance(inp, dict) else ""
        # Resolve a RELATIVE file_path against the PAYLOAD cwd (where the write lands),
        # NOT the gate process CWD — otherwise a write with cwd=/other/repo and a
        # relative path would inspect the wrong repo and fast-allow despite that repo
        # having pending markers (litmus HIGH).
        if fp:
            target = fp if os.path.isabs(fp) else os.path.join(cwd, fp)
            anchor = os.path.dirname(target)
        else:
            anchor = cwd
    anchor = os.path.abspath(anchor)
    # The target file (and its parent dirs) may not exist yet — walk up to the
    # deepest EXISTING ancestor so git -C can resolve the repo (§11 / ADR-B). A
    # non-existent anchor would make git fail and the gate fall-OPEN as ENOREPO.
    while anchor and anchor != os.path.dirname(anchor) and not os.path.isdir(anchor):
        anchor = os.path.dirname(anchor)
    print(anchor or ".")
except Exception:
    print(".")
' "$_GATE_LIBDIR" 2>/dev/null || echo ".")"
[ -n "$_MK_ANCHOR" ] || _MK_ANCHOR="."

# #347 item 1 — fail-closed PRE-ARM, BEFORE the pending fast-reject. A NEW design doc
# is written into a repo where nothing is pending yet, so the "nothing pending → exit 0"
# fast-reject below would allow it WITHOUT arming (the arm would fall to the PostToolUse
# detector, which cannot block — the residual we close). So detect a Write/Edit/MultiEdit
# design-doc target here and arm-or-block it up front. The doc's own write is always
# exempt from the impl-block, so this branch exits after arming either way. The grammar
# mirrors the detector (check-design-document.sh) VERBATIM — a mismatch would deadlock a
# review on the doc it waits for. Bash-redirect design-doc creation is NOT handled here
# (stays PostToolUse best-effort — documented residual).
# shellcheck disable=SC2016  # python3 -c program; $ and quotes are literal code
_DESIGN_FP="$(printf '%s' "$INPUT" | python3 -I -c '
import sys
sys.path[:] = [p for p in sys.path if p not in ("", ".")]
import json, os, re
try:
    d = json.load(sys.stdin)
    tool = d.get("tool_name", d.get("toolName", ""))
    if tool not in ("Write", "Edit", "MultiEdit"):
        raise SystemExit
    inp = d.get("tool_input", d.get("toolInput", {}))
    if isinstance(inp, str):
        inp = json.loads(inp)
    if not isinstance(inp, dict):
        raise SystemExit
    fp = inp.get("file_path", inp.get("filePath", ""))
    if not fp and tool == "MultiEdit":
        eds = inp.get("edits", [])
        if isinstance(eds, list) and eds and isinstance(eds[0], dict):
            fp = eds[0].get("file_path", eds[0].get("filePath", ""))
    if not fp:
        raise SystemExit
    cwd = d.get("cwd") or "."
    norm = os.path.normpath(fp if os.path.isabs(fp) else os.path.join(cwd, fp))
    sd = os.environ.get("BUSDRIVER_STATE_DIR", ".claude")
    if (re.search(r"(^|/)(PLAN|DESIGN|ARCHITECTURE)[^/]*\.md$", norm, re.I)
            or re.search(r"(^|/)(" + re.escape(sd) + r"|docs)/([^/]+/)*(plans|specs)/.*\.md$", norm)):
        # Emit "<tool> <abspath>". The abspath is the payload-cwd-resolved `norm` (NOT the
        # raw fp): _design_prearm_or_block re-resolves via gate_marker_norm_path (cd+pwd -P),
        # which for a RELATIVE fp would use the gate PROCESS cwd — a possibly different repo.
        # The tool lets the pre-arm mirror the detector: a Write RE-ARMS even a reviewed doc
        # (a rewrite re-opens review), while an Edit/MultiEdit of a reviewed doc is left alone.
        sys.stdout.write(tool + " " + norm)
except Exception:
    pass
' 2>/dev/null || true)"
if [ -n "$_DESIGN_FP" ]; then
    # "<tool> <abspath>" — tool is the first word, abspath the rest (may contain spaces).
    _DF="${_DESIGN_FP#* }"; _DT="${_DESIGN_FP%% *}"
    # Only PRE-ARM a path that is a design doc BOTH lexically AND physically — a symlinked
    # `docs/plans -> src` parent must not let `docs/plans/impl.md` (physically src/impl.md)
    # be armed/exempted. If it's a real design doc, arm-or-block, then FALL THROUGH: the
    # WRITE_EDIT exemption below uses the SAME gate_design_doc_exempt check to make the
    # exit-0 decision (one physical grammar, no duplication). A symlink-escape write is not
    # pre-armed here and falls through to the normal gate → blocked if a review is pending.
    # `|| _DDE=$?` (not `; _DDE=$?`): a bare non-zero return would trip `set -e` (the ERR
    # trap) before the assignment; the OR-list form suppresses that and captures the code.
    _DDE=0; gate_design_doc_exempt "$_DF" "$STATE_DIR" || _DDE=$?
    if [ "$_DDE" = "0" ]; then
        _design_prearm_or_block "$_DF" "$_DT" || exit 0   # arm-failure block on stdout
    elif [ "$_DDE" = "2" ]; then
        # Cannot verify design-doc-ness (marker helper unavailable) AND cannot arm →
        # fail-CLOSED: block rather than silently lose the review requirement.
        block_emit "BLOCKED (fail-closed): the design-review marker helper is unavailable, so this write to a possible design document can be neither verified nor armed. Restore hooks/gate-scripts/lib/marker_ops.py and python3, then retry. If the user wants to bypass: create $STATE_DIR/skip-design-review.local in their terminal."
        exit 0
    fi
    # _DDE=1 (not a design doc) → fall through to the normal gate.
fi

# Hot-path fast reject: a pure-shell probe (no python3 fork) approves the common
# "nothing pending" case immediately, keeping benign edits cheap on the 5s budget.
if gate_marker_pending_pureshell "$_MK_ANCHOR"; then
    rm -f "$STATE_DIR/.impl-gate-block-count.local" 2>/dev/null || true
    exit 0
fi

# Maybe pending → the authoritative classifier builds the NUL records + exact code
# (0 none / 1 pending / 2 enumerate-or-list failure). A bash var cannot hold NUL,
# so STREAM the records via a temp file and capture the exit separately (ADR-C).
_MK_RECS="$(mktemp 2>/dev/null)" || _MK_RECS=""
_MK_CODE=0
if [ -n "$_MK_RECS" ]; then
    trap 'rm -f "$_MK_RECS" 2>/dev/null || true' EXIT
    gate_marker_pending "$_MK_ANCHOR" >"$_MK_RECS" 2>/dev/null || _MK_CODE=$?
else
    # mktemp failed — NEVER fall back to a predictable path (a pre-placed symlink
    # there would be truncated/clobbered). Take the decision without records; the
    # block message degrades to a generic line.
    gate_marker_pending "$_MK_ANCHOR" >/dev/null 2>&1 || _MK_CODE=$?
fi
if [ "$_MK_CODE" = "0" ]; then
    rm -f "$STATE_DIR/.impl-gate-block-count.local" 2>/dev/null || true
    exit 0
fi

# ── F10 staleness auto-expiry REMOVED (F11) ───────────────────────────
# Design review state now persists across sessions unconditionally.
# Previously, state older than DESIGN_REVIEW_STALE_HOURS was auto-expired
# here, creating a session-boundary gap where reviews silently disappeared.
# SessionStart (load-orchestrator.sh) still warns about stale state for UX.
# Escape hatch: $STATE_DIR/skip-design-review.local (user-created only).

# ── Skip override: a LEASE, not a single use (#519 item 3) ────────────
# Defined here (where the old single-use block lived) but INVOKED far below, only
# once a write is known to be genuinely gated. Two changes from the old block:
#
#   1. LEASED, not consumed-on-first-use. The unit of work is a PLAN, not a write:
#      implementing one approved sub-plan takes ~10 gated writes, so a single-use
#      hatch cost ~10 operator `touch` cycles with a mandatory 30s wait each. That
#      pressure pushed operators toward the WORSE exit — deleting marker tokens,
#      i.e. destroying the gate's own audit trail. An escape hatch too expensive to
#      use correctly is one that gets used incorrectly. One `touch` now authorizes
#      $LEASE_MAX_USES gated writes inside a $LEASE_MAX_AGE window, and EVERY use
#      appends to bypass-log.jsonl — strictly MORE audit signal than before, where
#      the pressure-release valve was an unlogged `rm`.
#
#   2. Bounded in time as well as count. The old file had no maximum age, so a
#      forgotten skip stayed armed indefinitely (the hazard #516 records for the
#      sibling litmus skip). The lease now expires.
#
# UNCHANGED, deliberately: the >=30s anti-self-bypass check and the #325
# repo-controlled rejection. Both are sound; #519 explicitly did not propose
# weakening either, and a lease does not need them relaxed — it re-checks the
# ORIGINAL file's mtime on every use, so an agent cannot extend a lease by
# re-touching (that resets the counter but also resets the 30s clock, which then
# rejects). Only a genuine operator touch, waited out, opens a new lease.
LEASE_MAX_USES=20
LEASE_MAX_AGE=3600
_SKIP_FILE="$STATE_DIR/skip-design-review.local"
# DISARMING IS NOT DONE HERE. lease_slot.py removes a refused skip file itself, through
# the O_NOFOLLOW component walk, at the dir fd it has already validated. A shell `rm -f`
# resolves the path afresh and follows a symlinked INTERMEDIATE component of the
# repo-influenced state dir, so it could delete outside the repository — and it runs
# BEFORE lease_slot.py validates anything, so the later safe resolution cannot undo it.
# A `--unlink <dir> <name>` subcommand was the first fix and was worse: it took any
# slash-free basename, so anything reaching it could delete the protected audit log.
# Per-use lease slots live as immutable <mtime>.<n> directories in here, never
# as a mutable counter file — see the claim block below for why.
# Referenced only in messages/tests; every real operation on the ledger goes through
# lease_slot.py, which resolves the path with O_NOFOLLOW at each component rather than
# by string join.
_LEASE_DIR="$STATE_DIR/.skip-design-review-lease.d"

# Exit: 0 = a lease use was granted (allow the write)
#       1 = no usable skip file (fall through to the normal block)
#       2 = a block decision has ALREADY been emitted on stdout (caller exits)
_skip_lease_consume() {
    local claimed
    [[ -f "$_SKIP_FILE" ]] || return 1
    # A git-tracked (git add -f'd) skip file is repo-controlled, not operator consent
    # (#325). Anchor the guard on the SAME path the `-f` check tests — that check is
    # relative to the hook CWD, so resolve against the CWD too, or a committed
    # subdir/.claude skip file could satisfy one check and evade the other.
    # FAIL-CLOSED: outside a git repo the helper reports repo-controlled → refuse.
    # `if`, not `&& return`: under `set -e` a naked `cmd && return 1` whose cmd fails
    # makes the whole list non-zero and trips the ERR trap before the next line runs.
    if gate_skip_file_repo_controlled "." "$_SKIP_FILE"; then return 1; fi

    # ── Age checks AND the claim, from ONE stat ─────────────────────────────
    # Both live in lease_slot.py. The shell used to stat the file for the 30s floor and
    # the 3600s ceiling and then let the helper stat it AGAIN for the lease key, so a
    # touch or replacement between the two produced a lease whose new mtime had passed
    # neither check. One read, one decision.
    #
    # Every path component is opened with dir_fd + O_NOFOLLOW and every operation happens
    # AT that fd, so the directory validated is the one written to. The shell version
    # could not hold that: `-L "$STATE_DIR"` tests only the final name (a nested
    # `link/state` with a symlinked PREFIX passes), the check was separated from the use,
    # and a glob + `rm -rf` prune would follow such a symlink into a tree outside the
    # repo — where slots are also outside the protected-marker guard, so they could be
    # erased through the external name and the ceiling reset indefinitely.
    #
    # Exit 0 = claimed (slot on stdout); 2 = exhausted; 3 = too new; 4 = expired;
    # anything else = could not record, which must REFUSE the bypass —
    # unbounded-because-unrecordable is the fail-open this whole block exists to avoid.
    _CLAIM_RC=0
    # A missing/unreadable helper also exits 2 (CPython's own "can't open file"
    # exit code), which the `2)` branch below would misreport as a spent lease --
    # naming a use that was never granted and a file that was never removed. Route
    # that case to the generic fail-closed refusal (`*)`) instead, before invoking
    # python3, so exit code 2 stays exclusively the helper's own spent-lease signal.
    [ -f "$_GATE_LIBDIR/lease_slot.py" ] || _CLAIM_RC=1
    if [ "$_CLAIM_RC" -eq 0 ]; then
        claimed="$(python3 -I "$_GATE_LIBDIR/lease_slot.py" "$STATE_DIR" "$LEASE_MAX_USES" 30 "$LEASE_MAX_AGE" 2>/dev/null)" || _CLAIM_RC=$?
    fi
    # The `-f` test above is a cheap early exit, NOT the discriminator: it cannot see an
    # UNREADABLE regular file, and the helper can be removed between the test and the
    # interpreter opening it. Both still exit 2. So exit 2 is re-verified rather than
    # trusted -- if the helper is not openable now, that 2 was CPython refusing to open
    # a file, not the helper reporting a spent lease. Costs one probe, and only on the
    # exhausted path. Both branches BLOCK either way; what this buys is that the operator
    # is told the truth, instead of being sent to re-touch a lease that was never spent
    # and hunting for a skip file that was never removed.
    if [ "$_CLAIM_RC" -eq 2 ] \
       && ! python3 -I -c 'import sys; open(sys.argv[1], "rb").close()' \
                    "$_GATE_LIBDIR/lease_slot.py" 2>/dev/null; then
        _CLAIM_RC=1
    fi
    case "$_CLAIM_RC" in
        0) : ;;
        3)
            # Created moments ago — likely a self-bypass, not operator consent.
            # lease_slot.py has already disarmed it, and if it could NOT (an immutable
            # file in a writable dir) it poisoned the lease instead, so aging past the
            # floor buys nothing.
            block_emit "BLOCKED: skip-design-review.local was created moments ago (likely self-bypass).

Do NOT create $STATE_DIR/skip-design-review.local yourself. Run /blueprint-review instead.
If the user wants to skip, they should create the file manually in their terminal."
            return 2 ;;
        4)
            # Disarmed by lease_slot.py. Slots are left in place for the same anti-TOCTOU
            # reason as the exhausted branch; the mtime-keyed prune clears them when a new
            # lease is armed.
            block_emit "BLOCKED: the design-review skip lease has EXPIRED (the limit is ${LEASE_MAX_AGE}s).

The file has been removed so it cannot stay armed and silently authorize a later session.
Run /blueprint-review to clear the review properly. If the user still wants to bypass,
they can create $STATE_DIR/skip-design-review.local again in their terminal."
            return 2 ;;
        2)
            # lease_slot.py removed ONLY the skip file. Deleting the slots would be a
            # TOCTOU: a concurrent gate that already passed the skip-file/mtime checks
            # would recreate the directory, claim slot 1 under the same mtime, and be
            # granted a 21st use. The slots are the exhaustion proof and must outlive the
            # file that spent them; a later touch changes the mtime and lease_slot prunes
            # them. (The ledger is a protected marker, so it cannot be wiped to reset.)
            block_emit "BLOCKED: the design-review skip lease is EXHAUSTED (all $LEASE_MAX_USES uses spent).

One \`touch\` authorizes $LEASE_MAX_USES gated writes so a whole approved plan can be
implemented without re-arming per write — but not an unbounded number. The file has
been removed.

Run /blueprint-review to clear the pending review properly. To release ONE specific
pending token with a recorded audit event instead, run scripts/design-clear.sh with no
arguments to list what is pending. If the user wants another lease, they can re-create
$STATE_DIR/skip-design-review.local in their terminal."
            return 2 ;;
        *) return 1 ;;   # FAIL-CLOSED: could not record a use → grant none
    esac
    case "$claimed" in ''|*[!0-9]*) return 1 ;; esac

    # Exit 0 means the slot is durable on disk AND the bypass-telemetry event for it is
    # durably logged — lease_slot.py mints that event inside the same call that created
    # the slot, and reports ERROR (refuse, slot stays spent) if the append did not land.
    # It is NOT a second command here, because a record-writing CLI is a forge primitive:
    # it needs no protected path and no modification verb, so nothing else in the Bash
    # detector would notice one, and post-commit-consume-marker.sh reads a recent
    # `skip-review-consumed` line as proof that a bypass was sanctioned.
    rm -f "$STATE_DIR/.impl-gate-block-count.local" 2>/dev/null || true
    return 0
}
# (env-based SKIP_DESIGN_REVIEW removed — issue #325; use the .local skip file. ADR 0016.)

# ── Parse tool type and relevant input ─────────────────────────────────
# Returns: WRITE_EDIT|<file_path>  or  BASH_MOD|<command>  or  SAFE|
# NOTE: Python block uses single-quoted shell string to avoid bash 3.2
# quote-matching issues with $(...)  — all Python strings use double quotes.
# F7 fix: Strip fd-to-fd redirects (2>&1, >&2) before file-redirect detection.
# F8 fix: Allow review infrastructure scripts (blueprint-review, litmus)
# to run even when design docs are unreviewed — prevents circular dependency.
# shellcheck disable=SC2016  # python3 -c string uses '\'' idiom intentionally
PARSED=$(printf '%s' "$INPUT" | python3 -I -c '
import sys
sys.path[:] = [p for p in sys.path if p not in ("", ".")]
# argv[1] is the TRUSTED gate lib dir (BASH_SOURCE-derived; -I already ignores
# PYTHONPATH/site). The deliberation-dispatcher exemption (#484) lives there —
# it recognizes a dispatcher by its literal plugin script path (see delib_gate.py
# for why operand validation is deliberately NOT attempted). Import failure
# leaves is_exempt=None → the dispatcher falls through to BASH_MOD (fail-CLOSED:
# a missing lib blocks, never allows).
sys.path.insert(0, sys.argv[1])
import json, re, os
try:
    from delib_gate import is_exempt
except Exception:
    is_exempt = None
# #519 item 4 — token-level file-mod classification. Import failure leaves it None
# and the raw-string regexes below run instead, i.e. the pre-#519 behaviour, which
# is strictly WIDER (blocks more). A missing lib can therefore never fail-OPEN here.
try:
    from cmdword import is_file_mod
except Exception:
    is_file_mod = None
try:
    d = json.load(sys.stdin)
    tool = d.get("tool_name", d.get("toolName", ""))
    inp = d.get("tool_input", d.get("toolInput", {}))
    if isinstance(inp, str):
        inp = json.loads(inp)
    if tool in ("Write", "Edit", "MultiEdit"):
        print("WRITE_EDIT|" + inp.get("file_path", inp.get("filePath", "")))
    elif tool == "Bash":
        cmd = inp.get("command", "")
        # KEEP IN STEP WITH cmdword._MAX_CMD_CHARS. Classifying a command costs time
        # linear in its length even after the token budgets bound the quadratic part, and
        # this hook is registered with a 5s timeout whose expiry emits NO decision -- read
        # by the harness as allow. So size is checked FIRST, before any parsing, and an
        # oversized command is called a modification without being read. Fail CLOSED: the
        # padding is attacker-chosen, so anything cleverer here can be aimed.
        if len(cmd) > 65536:
            print("BASH_MOD|" + cmd[:500])
            sys.exit(0)
        # MUST stay in step with cmdword.FILE_MOD_PATTERNS: this list is the
        # import-failure fallback, so a verb missing here fails OPEN on exactly the
        # damaged-installation path the comment below promises is fail-CLOSED.
        FILE_MOD_PATTERNS = [
            # `sed` WHOLE, matching cmdword.FILE_MOD_PATTERNS. The classifier blocks
            # arrangements `\bsed\s+-i` cannot see -- `sed -f -- -i file` writes in
            # place, because the `--` is the script operand of -f -- and this list is
            # the import-failure stand-in, so it has to be the WIDER of the two.
            r"\bsed\s",
            r"\btee\s",
            r"\bpatch\s",
            r"\bcp\s",
            r"\bmv\s",
            r"\brm\s",
            r"\bln\s",
            r"\binstall\s",
            r"\btruncate\s",
            r"\bunlink\s",
            r"\brmdir\s",
            r"\bdd\s",
            # `git` WHOLE, not per-subcommand. This list is the damaged-installation
            # fallback and its one job is to be WIDER than the classifier it stands in
            # for; the classifier blocks `git clean -fd`, `git restore .` and every
            # unknown subcommand, and no verb pattern here matched any of them, so a
            # missing cmdword.py made the fail-CLOSED gate fail OPEN.
            r"\bgit\s",
        # A verb at END OF STRING (`echo hi | xargs rm`) and find -delete. The `\s` in
        # every pattern above requires something to follow the verb, and -delete names
        # no verb at all, so the classifier blocked both while this list allowed them.
        r"\b(?:tee|patch|cp|mv|rm|ln|install|truncate|unlink|rmdir|dd)$",
        r"-delete\b",
        ]
        # #519 item 4: these raw-string regexes match INSIDE quoted operands, so a
        # read-only `grep -nE "rm |mv " f` or `echo "(mv FAILS)"` read as file-modifying
        # and got blocked. cmdword.is_file_mod tokenizes first and compares token
        # basenames for equality — a verb inside a quoted string is one token that
        # equals no verb, while `sudo rm -rf src` still matches. It falls back to these
        # same regexes on an unparseable command, so the failure mode is the old
        # behaviour, never a new over-block. Kept here as the import-failure fallback.
        # SQUEEZED as well as raw, matching cmdword._regex_fallback. Quotes and
        # backslashes are the word-concatenation characters bash removes before it
        # resolves the command word, so `g"it" clean -fd` matched no contiguous pattern
        # while running git -- in the one path that exists for a damaged installation.
        # Escapes are decoded at BASH digit widths, not Python ones: `unicode_escape`
        # demands four digits after \u and eight after \U, so bash short forms passed
        # through it untouched and a hex-spelled verb matched nothing.
        _esc = re.compile(r"\\(?:x([0-9A-Fa-f]{1,2})|u([0-9A-Fa-f]{1,4})"
                          r"|U([0-9A-Fa-f]{1,8})|0?([0-7]{1,3}))")

        def _dec(m):
            hexit = m.group(1) or m.group(2) or m.group(3)
            try:
                return chr(int(hexit, 16) if hexit else int(m.group(4), 8))
            except ValueError:
                return ""

        def _variants(t):
            out = [t, _esc.sub(_dec, t)]
            for base in list(out):
                sq = base.replace(chr(92) + chr(10), "")
                for _ch in (chr(39), chr(34), chr(92), "$"):
                    sq = sq.replace(_ch, "")
                out.append(sq)
            return out
        has_explicit_mod = (is_file_mod(cmd) if is_file_mod is not None
                            else any(re.search(p, v) for p in FILE_MOD_PATTERNS
                                     for v in _variants(cmd)))
        is_mod = has_explicit_mod
        # Check for shell redirects (>, >>) not targeting /dev/null.
        # Strip single-quoted strings first (literal text like jq .x > 0).
        if not is_mod:
            no_single = re.sub(r"'\''[^'\'']*'\''", "", cmd)
            safe = re.sub(r"[12]>\s*/dev/null", "", no_single)
            safe = re.sub(r"&>\s*/dev/null", "", safe)
            safe = re.sub(r">\s*/dev/null", "", safe)
            # Strip fd-to-fd redirects: 2>&1, >&2, 1>&2 (not file writes)
            safe = re.sub(r"[012]?>&[012]", "", safe)
            if re.search(r">{1,2}\s*\S", safe):
                is_mod = True
        # Allow review infrastructure scripts when flagged only by redirects
        # (not explicit file-mod patterns like rm/cp/mv). This prevents
        # compound command bypass: "bash reviewer.sh && rm -rf src" still
        # blocked because rm triggers has_explicit_mod.
        if is_mod and not has_explicit_mod and re.search(r"(?:^|[\s;|&])(?:ba)?sh\s+\S*(?:blueprint-review|litmus)/(?:scripts|config)/", cmd):
            print("SAFE|")
        # F10 (#484): deliberation-tool dispatchers (council / ultra-council /
        # ultimate-council, ultraoracle, dispatch-cli) legitimately create and
        # clean up their OWN temp/state files in a single pasted dispatch block
        # (mktemp prompt files, a captured result, $STATE_DIR/ultra-oracle
        # output). Those rm/redirects trip has_explicit_mod, so the F8 exemption
        # (NOT has_explicit_mod) can never cover them, and the council convened
        # to fix a pending design would be blocked BY the design gate. delib_gate
        # (imported above) exempts a command that invokes a recognized dispatcher
        # by its literal plugin script path. It does NOT validate the rest of the
        # command: the dispatch blocks use $(...) and heredocs, so $(mktemp) and
        # $(rm -rf src) are statically indistinguishable — no scan can separate
        # them. This is a COOPERATIVE gate (any session bypasses via python -c),
        # so exempting a dispatcher command wholesale adds no residual the gate
        # did not already carry; an ACCIDENTAL bare `rm -rf src` has no dispatcher
        # path and is still blocked. See delib_gate.py + #484 review history.
        elif is_mod and is_exempt is not None and is_exempt(cmd):
            print("SAFE|")
        elif is_mod:
            # F9 fix: Allow rm/mkdir targeting only $STATE_DIR/ infrastructure.
            # Prevents circular dependency where gate blocks cleanup of its
            # own state files. Conservative: no command chaining allowed,
            # only $STATE_DIR/ relative paths, only rm and mkdir.
            state_dir = os.environ.get("BUSDRIVER_STATE_DIR", ".claude")
            state_pattern = re.escape(state_dir) + "/"
            clean = re.sub(r"\s*(?:2>/dev/null\s*)?(?:\|\|\s*(?:true|:)\s*)?$", "", cmd)
            if re.match(r"^\s*(?:rm|mkdir)\s+(?:-[a-zA-Z]+\s+)*(?:" + state_pattern + r"\S+\s*)+$", clean):
                print("SAFE|")
            else:
                print("BASH_MOD|" + cmd[:500])
        else:
            print("SAFE|")
    else:
        print("SAFE|")
except Exception:
    print("SAFE|")
' "$_GATE_LIBDIR" 2>/dev/null || echo "SAFE|")

TOOL_TYPE="${PARSED%%|*}"
TOOL_VALUE="${PARSED#*|}"

# Non-Write/Edit or safe Bash → approve
[ "$TOOL_TYPE" = "SAFE" ] && exit 0

# ── For Write/Edit: apply file-path allowlists ─────────────────────────
if [ "$TOOL_TYPE" = "WRITE_EDIT" ]; then
    FILE_PATH="$TOOL_VALUE"

    # No file path → approve
    [ -z "$FILE_PATH" ] && exit 0

    # Allow writing to these paths (review infrastructure, not implementation):
    #   - Design/plan docs themselves (writing/editing the plan is fine)
    #   - Review output files (blueprint-review generates these)
    #   - $STATE_DIR/ config files
    #   - docs/reviews/ (review artifacts)
    #   - CLAUDE.md, NOTES.md, *.local* files
    # The docs/ arms require `docs` to START a path segment: a bare `*docs/specs/*`
    # also matches `notdocs/specs/impl.sh` — not a docs dir at all.
    #
    # They are deliberately NOT anchored to the repo root. This exemption MUST stay
    # at least as wide as the design-doc DETECTOR it is paired with: check-design-
    # document.sh matches ($STATE_DIR|docs)/([^/]+/)*(plans|specs)/*.md, whose
    # ([^/]+/)* arms a review for nested docs — e.g. packages/foo/docs/specs/x.md.
    # Root-anchoring to `docs/specs/*` would flag that doc as needing review while
    # refusing the write that answers it: the exact deadlock this change fixes,
    # relocated one directory down. Detector and exemption must agree.
    #
    # Ceiling: src/docs/specs/impl.sh stays exempt. Accepted — unlike the $STATE_DIR
    # case below, where worktree homing under <main>/.claude/ made EVERY file match
    # (a true fail-open), nothing homes a repo under docs/, so there is no universal
    # match to exploit; the "bypass" costs the writer their impl file's real location.
    # UPGRADE: if the detector ever root-anchors, anchor these in the same change.
    # Matched against the RESOLVED, normalized write target — a relative file_path
    # joined to the PAYLOAD cwd exactly as the _MK_ANCHOR block above does, then
    # lexically normalized. Both halves are load-bearing:
    #   - Without normalization, `docs/specs/../../src/impl.sh` matches the docs glob
    #     while resolving to `src/impl.sh` — the exemption hands a pending review's
    #     impl write a free pass.
    #   - Without the cwd join, a legitimate `../docs/specs/x-design.md` sent with
    #     cwd=<repo>/src stays relative, trips the `..` arm below, and is refused —
    #     re-deadlocking the very doc the review waits on. Relative file_path IS a
    #     real shape here: the marker code joins it to the payload cwd, and
    #     test-design-marker-worktree.sh's "(anchor)" case exercises it.
    # Lexical, NOT gate_marker_relpath: that resolves physically (cd + pwd -P) and so
    # fails on a not-yet-created docs/specs/ dir — the exact case a new design doc needs.
    # shellcheck disable=SC2016  # python3 -c program; $ and quotes are literal code
    # -I (isolated): ignores PYTHONPATH/PYTHONHOME, skips site, and keeps the cwd off
    # sys.path — a repo-local sitecustomize.py must not get to redefine realpath inside
    # a security gate. The explicit sys.path scrub runs BEFORE json/os are imported and
    # covers pythons predating -I's -P behaviour: importing first and filtering after is
    # too late, since a repo-local json.py would already have executed and could forge an
    # exempt path (demonstrated: a stub json.load returning docs/specs/... exempts an
    # arbitrary impl write). `import sys` alone is safe — it is built in, never from disk.
    _NORM_FP="$(printf '%s' "$INPUT" | python3 -I -c '
import sys
sys.path[:] = [p for p in sys.path if p not in ("", ".")]
import json, os
try:
    d = json.load(sys.stdin)
    inp = d.get("tool_input", d.get("toolInput", {}))
    if isinstance(inp, str):
        inp = json.loads(inp)
    fp = inp.get("file_path", inp.get("filePath", "")) if isinstance(inp, dict) else ""
    if not fp:
        raise ValueError("no file_path")
    cwd = d.get("cwd")
    if os.path.isabs(fp):
        target = fp
    elif cwd and os.path.isabs(cwd):
        target = os.path.join(cwd, fp)
    else:
        # Greptile P1 (#451): a relative fp with a MISSING/empty payload cwd, OR a
        # payload cwd that is itself relative (e.g. a literal "."), must NOT be
        # resolved here. A relative cwd is not an anchor by itself -- "." only means
        # something once resolved against SOME real directory, and the two consumers
        # below (the design-doc exemption arm and the STATE_DIR arm further down) would
        # do that resolution via the GATE PROCESS own cwd (gate_marker_relpath uses
        # git -C / cd), not the payload real effective directory -- reproducing the
        # exact fail-open this ADR closes, just gated on "cwd missing/relative" instead
        # of "cwd present but wrong". Absent an absolute cwd, the target is
        # UNRESOLVABLE; raise so the outer except leaves _NORM_FP empty, so no
        # exemption fires on either arm (fail-CLOSED, matching the documented
        # unparseable-payload contract just below).
        raise ValueError("relative file_path with no absolute payload cwd, cannot resolve safely")
    # LEXICAL join+normpath ON PURPOSE — this is only the INPUT to gate_design_doc_exempt
    # below, which does the physical resolution safely (deepest EXISTING ancestor via pwd -P,
    # new tail reappended). Resolving physically HERE would fail on a not-yet-created
    # docs/specs/ dir and deadlock a new doc; the helper avoids that while still catching a
    # symlinked `docs/plans -> src` parent (#347 — the prior lexical-only residual is now
    # closed, so a symlinked docs/specs no longer laundering an impl write).
    print(os.path.normpath(target))
except Exception:
    pass
' 2>/dev/null || true)"
    # FAIL-CLOSED: an unparseable payload / absent python3 leaves this empty, and the
    # placeholder matches no arm below → no exemption. (python3 is already a hard
    # requirement whenever a review is pending — see the pre-check near the top — so
    # this and the `..` arm are belt-and-braces, not the primary defense.)
    case "${_NORM_FP:-<unresolved>}" in
        # A `..` surviving the join+normalize escapes even the payload cwd, so the real
        # target cannot be proven. Grant no exemption.
        ../*|*/../*|*/..) ;;
        # A newline in the path: the design-doc arm below matches with a LINE-oriented
        # tool, so `src/impl.sh<LF>docs/specs/x.md` would match on its second line and
        # exempt the first. No real design-doc path carries one — refuse outright.
        *$'\n'*) ;;
        docs/reviews/*|*/docs/reviews/*) exit 0 ;;
        *CLAUDE.md|*NOTES.md) exit 0 ;;
        *)
            # Design docs: mirror the DETECTOR's grammar VERBATIM rather than
            # approximate it. check-design-document.sh arms a review via TWO arms —
            # a fixed-depth or case-sensitive glob can express neither, and any
            # mismatch deadlocks the review on the doc it waits for:
            #   1. basename STARTS WITH plan/design/architecture, CASE-INSENSITIVE. The
            #      detector arms lowercase `design.md`, so the earlier case-sensitive
            #      `*DESIGN*.md` glob refused the very write answering its own review.
            #   2. path under ($STATE_DIR|docs)/([^/]+/)*(plans|specs)/*.md, case-
            #      SENSITIVE (matches the detector's plans_re / line-139 grep) — the
            #      detector's ([^/]+/)* admits intermediate dirs (docs/team/specs/…),
            #      and `docs` must START a segment: a bare `docs/` also matched the
            #      suffix of notdocs/specs/x.md. $STATE_DIR is regex-escaped (its
            #      default `.claude` carries a `.` metachar). An earlier
            #      `docs/specs/*|*/docs/specs/*` approximation silently deadlocked
            #      nested, $STATE_DIR/, and lowercase-*-design.md docs (the shape
            #      brainstorming actually emits).
            # Safe despite being wider than the globs: the `.md` requirement means
            # neither arm can launder implementation code. A test pins the lockstep.
            # (#347 item 1 pre-arm runs EARLY — before the pending fast-reject — so a
            # design-doc write reaching here when a review is already pending is simply
            # exempted; it was already armed up top.)
            # #347 — gate_design_doc_exempt applies the detector grammar to BOTH the lexical
            # path AND os.path.realpath (every symlink resolved, leaf and parents) evaluated
            # REPO-RELATIVE, so neither a symlinked `docs/plans -> src` nor an ancestor named
            # docs/plans can launder an impl .md past the gate. A genuinely new doc keeps its
            # lexical location and stays exempt (no deadlock). Single helper — no early-vs-late
            # drift. Exempt ONLY on a clean 0; a 1 (not a design doc) or 2 (helper error) falls
            # through → blocked if a review is pending (fail-CLOSED on error).
            gate_design_doc_exempt "$_NORM_FP" "$STATE_DIR" && exit 0
            ;;
    esac

    # ADR-E: allow $STATE_DIR/ config writes — but ONLY when the path is
    # $STATE_DIR/… RELATIVE TO ITS OWN REPO ROOT. busdriver homes linked worktrees
    # at <main>/.claude/worktrees/<name>/, so a plain `*"$STATE_DIR"/*` substring
    # match vacuously exempts EVERY impl file in a linked worktree — the exact
    # pre-implementation fail-open this PR closes. Fail-CLOSED: if the repo root
    # can't be resolved, do NOT exempt (fall through to the marker check).
    # (The unconditional marker-forge guard at the top already ran, so the marker
    # files themselves stay protected regardless.)
    # #347 item 4 (ADR 0023): resolve this allowlist against the PAYLOAD-cwd-joined,
    # normalized target ($_NORM_FP) — NOT the raw $FILE_PATH. gate_marker_relpath
    # resolves a *relative* path against the GATE PROCESS cwd, so when the payload cwd
    # is a repo SUBDIR (e.g. /repo/src) and the gate cwd is /repo, a relative
    # `.claude/impl.py` resolves gate-cwd-relative to `.claude/impl.py` → EXEMPT, while
    # the write actually lands at /repo/src/.claude/impl.py — an impl file wrongly
    # exempted: a design-review fail-OPEN (Codex litmus HIGH; issue #347's original
    # "fail-closed-safe" read only saw the opposite over-block direction). Feeding the
    # already-payload-cwd-joined $_NORM_FP makes this arm consistent with the sibling
    # design-doc arm above (which resolves $_NORM_FP too) and keys on the write's REAL
    # repo/dir. $_NORM_FP is normpath'd + newline-rejected above, so this carries none
    # of the newline-truncation fail-open that reverted the #346 attempt. FAIL-CLOSED:
    # an empty $_NORM_FP (python failure) or an out-of-repo target makes
    # gate_marker_relpath return non-zero → no exemption → the marker check runs.
    # This includes a MISSING/empty payload cwd on a relative file_path (Greptile P1,
    # PR #451): the $_NORM_FP block above now raises (leaving $_NORM_FP empty) rather
    # than defaulting cwd to "." — a bare "." is a lexical no-op that would otherwise
    # leave the relative path to be resolved against the GATE PROCESS's own cwd right
    # here (gate_marker_relpath's `git -C`), reopening the exact bypass this arm exists
    # to close, just triggered by an absent cwd instead of a present-but-different one.
    _REL="$(gate_marker_relpath "$_NORM_FP" 2>/dev/null || true)"
    case "$_REL" in
        "$STATE_DIR"/*) exit 0 ;;
    esac

    # Allow files with .local suffix ONLY if they match known config patterns
    # (not broad *.local* which catches localStorage-handler.ts etc.)
    case "$FILE_PATH" in
        *.local.md|*.local.json|*.local.yaml|*.local.yml) exit 0 ;;
    esac
fi

# For BASH_MOD: the command was already identified as file-modifying.
# No file-path allowlist needed — Bash command parsing is unreliable for
# extracting target paths, and the patterns (sed -i, tee, patch) are
# unambiguous file-modification operations.

# ── Spend a skip-lease use, if one is armed (#519 item 3) ──────────────
# Invoked HERE, not before the classifier, and that placement is the fix for the
# "any intervening tool call can consume it" sharp edge. The old block ran ahead of
# the tool-type parse and every allowlist, so a read-only `ls`, a `git status`, or a
# write to an already-EXEMPT path (a design doc, docs/reviews/, $STATE_DIR/) burned
# the single use before the operator's intended write ever arrived. By this line the
# operation is known to be genuinely gated — a real implementation write with a real
# pending review — so a use is spent only on the thing the operator armed it for.
_LEASE_RC=0; _skip_lease_consume || _LEASE_RC=$?
case "$_LEASE_RC" in
    0) exit 0 ;;   # lease use granted → allow this write
    2) exit 0 ;;   # self-bypass / expired / exhausted — block already on stdout
esac
# 1 = no usable skip file → fall through and block normally.

# ── Render the pending records (ADR-C) into the block message ──────────
# _MK_CODE is 1 (>=1 pending) or 2 (enumerate/list failure) — this write is gated
# either way. Stream the NUL records (a bash var cannot hold NUL); NEVER re-open
# the doc — the block signal is token EXISTENCE, not the doc's PASS comment. The
# readers never mutate (ADR-C removes the old whole-file `rm`, divergence 4).
UNREVIEWED=""
if [ "$_MK_CODE" = "2" ] || [ -z "$_MK_RECS" ]; then
    UNREVIEWED="  - (design review pending — run /blueprint-review to see the specific documents)\n"
else
    # Shared renderer (resolve-repo-dir.sh) — annotates each doc with the worktree
    # that armed it when it isn't THIS write's worktree (#356 cross-worktree
    # visibility). _MK_ANCHOR is the write's own worktree anchor.
    UNREVIEWED="$(gate_render_pending_records "$_MK_RECS" "$_MK_ANCHOR")"
fi

# ── Circuit breaker: detect repeated blocking ──────────────────────────
# Mirrors pre-commit-gate.sh: warns after 10 blocks so user knows to
# either run /blueprint-review or create skip-design-review.local manually.
BLOCK_COUNTER="$STATE_DIR/.impl-gate-block-count.local"
BLOCK_COUNT=0
if [ -f "$BLOCK_COUNTER" ]; then
    BLOCK_COUNT=$(cat "$BLOCK_COUNTER" 2>/dev/null || echo "0")
fi
BLOCK_COUNT=$((BLOCK_COUNT + 1))
echo "$BLOCK_COUNT" > "$BLOCK_COUNTER" 2>/dev/null || true

ESCAPE_HINT=""
if [ "$BLOCK_COUNT" -ge 10 ]; then
    ESCAPE_HINT="

WARNING: This gate has blocked $BLOCK_COUNT consecutive implementation attempts this session.
If you believe the gate is stuck, the user can create $STATE_DIR/skip-design-review.local in their terminal to bypass."
fi

# ── Block: unreviewed design docs exist ────────────────────────────────
if [ "$TOOL_TYPE" = "BASH_MOD" ]; then
    REASON=$(printf "Design review must complete before modifying files via Bash.\n\nDetected file-modifying Bash command while design docs are unreviewed:\n%b\nRun /blueprint-review to review these documents first.\n\nIMPORTANT: Do NOT create $STATE_DIR/skip-design-review.local yourself. That is a user-only escape hatch. You MUST run the blueprint review instead.%s" "$UNREVIEWED" "$ESCAPE_HINT")
else
    REASON=$(printf "Design review must complete before writing implementation code.\n\nUnreviewed design documents:\n%b\nRun /blueprint-review to review these documents first.\n\nIMPORTANT: Do NOT create $STATE_DIR/skip-design-review.local yourself. That is a user-only escape hatch. You MUST run the blueprint review instead.%s" "$UNREVIEWED" "$ESCAPE_HINT")
fi
block_emit "$REASON"
