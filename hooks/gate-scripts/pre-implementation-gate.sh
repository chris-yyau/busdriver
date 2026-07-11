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
case "$STATE_DIR" in ""|/*|*..*|*[!a-zA-Z0-9._/-]*) STATE_DIR=".claude" ;; esac
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

# ── python3 pre-check (F5 fix) ────────────────────────────────────────
# python3 is REQUIRED for tool type parsing and command detection.
# If missing, block — fail-closed principle. Without python3, the PARSED
# variable defaults to "SAFE|" which silently allows ALL writes.
if ! command -v python3 &>/dev/null; then
    # Only block if there are pending design reviews (avoid false blocks when no reviews needed)
    if [ -f "$STATE_DIR/design-review-needed.local.md" ]; then
        block_emit "CRITICAL: python3 not found. Pre-implementation gate cannot parse tool inputs. Install python3 to restore enforcement. Escape hatch: $STATE_DIR/skip-design-review.local"
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
MARKER_CHECK=$(printf '%s' "$INPUT" | python3 -c '
import sys, json, re, shlex

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


def _scan_segment(segtext, markers, simple_vars):
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
    segs, ok = _split_simple_commands(norm)
    if not ok:
        # Unterminated quote / dangling escape: fail CLOSED via raw substring.
        return next((mf for mf in markers if _bn(mf) in cmd), None)
    # simple_vars persists across segments so a cross-segment assignment
    # (m=.../marker ; rm "$m") resolves; updated in order, so a write sees the
    # value assigned BEFORE it and a later reassignment cannot mask it.
    simple_vars = {}
    for segtext in segs:
        hit = _scan_segment(segtext, markers, simple_vars)
        if hit:
            return hit
    return None


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
        # backstop verdict via --write-backstop-verdict, the Codex-lead verdict
        # inline on an actual Codex PASS (no subcommand, so it cannot be forged).
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
        hit = _writes_marker(cmd, MARKER_FILES)
        if hit:
            print("BLOCK_MARKER|" + hit)
            sys.exit(0)

    print("OK|")
except Exception:
    print("OK|")
' 2>/dev/null || echo "OK|")

MARKER_ACTION="${MARKER_CHECK%%|*}"
MARKER_TARGET="${MARKER_CHECK#*|}"

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
This is the PR security/bugs backstop artifact. It is written ONLY by the trusted strict writer, which re-derives the diff hash itself and fails closed on stale/bad input:
  <pr-security-backstop agent JSON> | bash \"\${BUSDRIVER_PLUGIN_ROOT:-\${CLAUDE_PLUGIN_ROOT}}/skills/litmus/scripts/run-review-loop.sh\" --write-backstop-verdict" ;;
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

# No pending design reviews → approve immediately
DESIGN_STATE="$STATE_DIR/design-review-needed.local.md"
[ ! -f "$DESIGN_STATE" ] && exit 0

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
# shellcheck source=lib/resolve-repo-dir.sh disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/resolve-repo-dir.sh"
_IMPL_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
if [ -f "$STATE_DIR/skip-design-review.local" ] \
   && ! gate_skip_file_repo_controlled "$_IMPL_ROOT" "$STATE_DIR/skip-design-review.local"; then
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
PARSED=$(printf '%s' "$INPUT" | python3 -c '
import sys, json, re, os
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
    case "$FILE_PATH" in
        *PLAN*.md|*DESIGN*.md|*ARCHITECTURE*.md) exit 0 ;;
        *docs/plans/*) exit 0 ;;
        *docs/reviews/*) exit 0 ;;
        *docs/superpowers/*) exit 0 ;;
        *CLAUDE.md|*NOTES.md) exit 0 ;;
    esac

    # Allow $STATE_DIR/ config writes (marker files already guarded unconditionally above)
    case "$FILE_PATH" in
        *"$STATE_DIR"/*) exit 0 ;;
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

# ── Check if ANY flagged design docs are still unreviewed ──────────────
UNREVIEWED=""
DESIGN_LINES=$(grep '^\- ' "$DESIGN_STATE" 2>/dev/null || true)
while IFS= read -r line; do
    file="${line#- }"
    [ -z "$file" ] && continue
    if [ -f "$file" ] && ! grep -q "<!-- design-reviewed: PASS -->" "$file" 2>/dev/null; then
        UNREVIEWED="${UNREVIEWED}  - ${file}\n"
    fi
done <<< "$DESIGN_LINES"

# All reviewed → clean up and approve
if [ -z "$UNREVIEWED" ]; then
    rm -f "$DESIGN_STATE"
    rm -f "$STATE_DIR/.impl-gate-block-count.local" 2>/dev/null || true
    exit 0
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
