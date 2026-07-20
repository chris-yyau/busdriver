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
# shellcheck source=lib/resolve-repo-dir.sh disable=SC1091
_GATE_LIBDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
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
INPUT=$(cat 2>/dev/null || true)
[ -z "$INPUT" ] && exit 0

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
import json, re, shlex

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


def _split_simple_commands(s):
    # Split into simple-command segments on UNQUOTED, UNESCAPED control operators
    # (; | & and grouping parens) with an explicit quote/escape state machine.
    # This MUST happen before shlex: posix shlex strips quoting, which makes a
    # quoted/escaped separator indistinguishable from a real one and lets a marker
    # delete slip into a "different" command (rm ; .file). Clobber >| and dup >&
    # embed | / & but are part of the redirect, so a | or & directly after > is
    # kept attached rather than treated as a split. Returns (segments, ok); ok is
    # False on an unterminated quote or dangling escape so the caller fails closed.
    segs, buf = [], []
    in_s = in_d = esc = False
    for ch in s:
        if esc:
            buf.append(ch)
            esc = False
        elif in_s:
            buf.append(ch)
            if ch == _SQ:
                in_s = False
        elif in_d:
            buf.append(ch)
            if ch == "\\":
                esc = True
            elif ch == _DQ:
                in_d = False
        elif ch == "\\":
            buf.append(ch)
            esc = True
        elif ch == _SQ:
            buf.append(ch)
            in_s = True
        elif ch == _DQ:
            buf.append(ch)
            in_d = True
        elif ch in "|&" and buf and buf[-1] == ">":
            buf.append(ch)  # >| (clobber) or >& (dup) -> part of the redirect
        elif ch in ";|&()":
            segs.append("".join(buf))
            buf = []
        else:
            buf.append(ch)
    segs.append("".join(buf))
    return segs, not (in_s or in_d or esc)


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
    cmd_word = seg_cmd_word
    if cmd_word is not None and _bn(cmd_word) in ("touch", "cp", "mv", "ln", "install"):
        for w in seg:
            m = _match_marker(w, markers, simple_vars)
            if m:
                return m
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
    #   - indirect writers NOT enumerated as command words: dd, and other
    #     copy/convert tools (cp/mv/ln/install ARE now blocked — see #290 below)
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
    # to be a deliberate wrapper-hidden or eval-forge a cooperative agent will not
    # build. A human touch typed in a real terminal is unaffected — this hook only
    # sees the Claude tool calls. See #227 and the ADR 0006 residual addendum.
    norm = cmd.replace("\r\n", "\n").replace("\r", "\n")
    # Bash removes an unquoted backslash-newline (line continuation) before
    # execution; mirror that BEFORE splitting on newlines so a marker write or
    # basename split across a continuation is rejoined, not broken into pieces.
    norm = norm.replace(chr(92) + chr(10), "").replace("\n", " ; ")
    # Bash ANSI-C ($'...') and locale ($"...") quoting: shlex does not model the
    # leading $, so strip that prefix and let the quote tokenize to the literal
    # path. (Escape SEQUENCES inside $'...' such as \x6c remain undecodable by
    # shlex and stay out of scope per the residual note above.)
    norm = norm.replace("$" + _SQ, _SQ).replace("$" + _DQ, _DQ)
    # ${IFS}/$IFS expand to whitespace — a classic field-splitting obfuscation
    # (rm${IFS}<marker>); normalize to a separator so the rm/tee command word and
    # redirect operands are recognized rather than glued into one token.
    norm = re.sub(r"\$\{IFS\}|\$IFS(?![A-Za-z0-9_])", " ", norm)
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
        # Block direct invocation of write-review-marker.sh UNLESS called via
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
    _design_prearm_or_block "${_DESIGN_FP#* }" "${_DESIGN_FP%% *}"   # arm-or-block, then
    exit 0                                    # design-doc write is exempt; block (if any) on stdout
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

# Skip overrides — unified with pre-commit-gate.sh behavior
# Both gates use the same pattern: single-use consumption + self-bypass detection
# A git-tracked (git add -f'd) skip file is repo-controlled, not operator consent
# (issue #325) — resolve the repo root and refuse it. FAIL-CLOSED via the helper.
# (resolve-repo-dir.sh is already sourced near the top of this script.)
# Anchor the guard on the SAME path the `-f` check tests. That check is relative to
# the hook CWD, so resolve the guard against the CWD too (git -C ".") — otherwise a
# committed subdir/.claude skip file could satisfy one check and evade the other.
# FAIL-CLOSED: outside a git repo the helper returns "repo-controlled" → skip ignored.
if [ -f "$STATE_DIR/skip-design-review.local" ] \
   && ! gate_skip_file_repo_controlled "." "$STATE_DIR/skip-design-review.local"; then
    # Reject skip files created within the last 30 seconds — likely Claude self-bypass.
    # A human-created skip file (via terminal) will typically be older.
    FILE_AGE=999
    _MTIME=$(stat -f %m "$STATE_DIR/skip-design-review.local" 2>/dev/null) \
        || _MTIME=$(stat -c %Y "$STATE_DIR/skip-design-review.local" 2>/dev/null) \
        || _MTIME=""
    [ -n "$_MTIME" ] && FILE_AGE=$(( $(date +%s) - _MTIME ))
    if [ "$FILE_AGE" -lt 30 ]; then
        # Likely self-bypass — reject and warn
        rm -f "$STATE_DIR/skip-design-review.local"
        REASON="BLOCKED: skip-design-review.local was created moments ago (likely self-bypass).

Do NOT create $STATE_DIR/skip-design-review.local yourself. Run /blueprint-review instead.
If the user wants to skip, they should create the file manually in their terminal."
        block_emit "$REASON"
        exit 0
    fi
    # Single-use: consume the skip file after allowing one bypass.
    # This prevents stale skip files from permanently disabling review gates.
    rm -f "$STATE_DIR/skip-design-review.local"
    rm -f "$STATE_DIR/.impl-gate-block-count.local" 2>/dev/null || true
    # ── Bypass telemetry ──────────────────────────────────────────────
    mkdir -p "$STATE_DIR"
    printf '{"ts":"%s","event":"skip-review-consumed","gate":"pre-implementation"}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$STATE_DIR/bypass-log.jsonl" 2>/dev/null || true
    exit 0
fi
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
import json, re, os
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
        FILE_MOD_PATTERNS = [
            r"\bsed\s+-i",
            r"\btee\s",
            r"\bpatch\s",
            r"\bcp\s",
            r"\bmv\s",
            r"\brm\s",
            r"\bln\s",
            r"\binstall\s",
        ]
        has_explicit_mod = any(re.search(p, cmd) for p in FILE_MOD_PATTERNS)
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
' 2>/dev/null || echo "SAFE|")

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
    cwd = d.get("cwd") or "."
    target = fp if os.path.isabs(fp) else os.path.join(cwd, fp)
    # LEXICAL on purpose. check-design-document.sh arms reviews from the LEXICAL path,
    # and this exemption must stay in lockstep with it: resolving physically here makes
    # a legitimately symlinked docs/specs -> shared/specs arm as a design doc but
    # resolve outside docs/, so the gate would refuse the write answering its own
    # review — the deadlock this branch exists to fix. Residual (shared with the
    # pre-existing docs/plans and docs/reviews arms, not new here): a symlinked
    # docs/specs reads as a docs path. Not reachable through the gated toolset — `ln`
    # is a FILE_MOD command, so creating that symlink is itself blocked while a review
    # is pending. UPGRADE: close it in the same change that anchors these arms to a
    # repo-relative path (see the ancestor-path note on the case block below).
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
            if printf '%s' "$_NORM_FP" \
                | grep -qiE '(^|/)(PLAN|DESIGN|ARCHITECTURE)[^/]*\.md$'; then
                exit 0
            fi
            STATE_DIR_ESC="$(gate_ere_escape "$STATE_DIR")"
            if printf '%s' "$_NORM_FP" \
                | grep -qE "(^|/)(${STATE_DIR_ESC}|docs)/([^/]+/)*(plans|specs)/.*\.md$"; then
                exit 0
            fi
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
    # FAIL-CLOSED: gate_marker_relpath resolves FILE_PATH's PHYSICAL repo-relative
    # path. A relative FILE_PATH is resolved against the gate CWD, which for an impl
    # file yields e.g. `src/…` (not `$STATE_DIR/…`) → not exempted → the marker
    # check runs. It can only ever FAIL to exempt (block), never wrongly exempt, so
    # the payload-cwd nicety is deferred rather than plumb a newline-unsafe abspath.
    _REL="$(gate_marker_relpath "$FILE_PATH" 2>/dev/null || true)"
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
