#!/usr/bin/env bash
# careful-guard.sh — PreToolUse hook for Bash commands
# Detects destructive operations and triggers confirmation prompt.
# Emits the PreToolUse hookSpecificOutput schema (permissionDecision "ask") to warn,
# or {} to allow. The old top-level {"permissionDecision":...} shape was ignored by
# the harness, leaving the guard silently inert.
#
# Ported from garrytan/gstack careful/bin/check-careful.sh (MIT)
# Stripped: telemetry, kubectl/docker patterns (not relevant for solo dev)
# Added: git clean -f detection
set -euo pipefail

# Advisory guard: on any internal error, fail OPEN (allow) rather than blocking
# every Bash command. This is a warn/ask guard, not a fail-closed review gate.
trap 'echo "{}"; exit 0' ERR

INPUT=$(cat)
CMD=""
AUTO_MODE=0

# --- Auto mode: stand down on what the classifier already owns ---
# In `auto`, a classifier model judges every non-read action and blocks force-push,
# git reset --hard, checkout/restore ., clean -fd, and "irreversibly destroying files
# that existed before the session" — against the ACTUAL request, which a regex cannot
# do. SQL DROP/TRUNCATE is the one pattern the classifier does not name, so it stays
# live in EVERY mode.
#
# BE PRECISE ABOUT WHAT THIS BUYS. The stand-down is belt-and-braces plus a real cost
# win; it is NOT what prevents a duplicate prompt, because in `auto` there was never
# a prompt to duplicate. Measured across a live session per mode (hooks and settings
# load at session START, so this can only be probed from a FRESH session in the mode
# under test — probing in-session reads the old config and returns a false negative):
#
#     mode      guard "ask"   hook block   operator prompt
#     auto      DISCARDED     honored      suppressed
#     bypass    HONORED       honored      delivered
#     default   HONORED       honored      delivered
#
# So in `auto`, emitting `ask` and standing down are behaviourally identical. What the
# stand-down actually saves is the work: the python rm scanner (and its interpreter
# spawn) is skipped on every Bash call. The load-bearing half of this block is the
# other direction — `bypassPermissions` is where the guard's `ask` IS honored and no
# classifier exists, so nothing there may ever stand down.
#
# `bypassPermissions` gets no exemption: it has no classifier at all, so this guard is
# the only thing left besides the rm -rf / and rm -rf ~ circuit breaker.
#
# EXTERNAL DEPENDENCY (CodeRabbit, PR #543): this stand-down's safety hinges on
# Anthropic's `auto`-mode classifier continuing to block exactly these patterns
# (force-push, reset --hard, checkout/restore ., clean -fd, pre-existing-file
# deletion) — a probabilistic model behavior this repo cannot verify or pin.
# Re-check tests/test-careful-guard-auto-mode.sh's six classifier-covered cases
# whenever the Claude Code version pin changes, not just at initial review.
#
# PARSED, never grepped off the raw JSON: `"permission_mode":"auto"` can also appear
# INSIDE tool_input.command, so a raw-text match would let a crafted command disarm
# the guard. No python3, unparseable input, or any other mode leaves AUTO_MODE=0 and
# every check runs — over-warning stays the safe direction.
# SINGLE PASS. The command extraction and the auto decision come from ONE python
# invocation. Two passes cost a second interpreter spawn on EVERY Bash command
# (measured by Codex on PR #543: ~1.54-1.61s vs ~1.02-1.06s at the parent commit,
# against the 3s budget hooks.json gives this whole guard) — and splitting them is
# also what let the two disagree (cubic, same PR): a malformed tool_input made
# python bail on the command while the raw-text grep fallback still produced one,
# so `auto` stood the guard down on a command python never validated. One parse
# cannot contradict itself.
#
# Prefer python for correct JSON parsing (escaped quotes, multiline commands);
# both tool_input and toolInput keys, dict or JSON-string payloads. The grep
# fallback below covers python being absent — AUTO_MODE stays 0 on that path.
if command -v python3 &>/dev/null; then
  # shellcheck disable=SC2016  # python source: $ / backticks must not expand in bash
  _GUARD_PAYLOAD=$(printf '%s' "$INPUT" | python3 -E -S -c '
import sys
# -E + -S + this scrub for the same reason the rm scanner below does it: `python3 -c`
# prepends the CWD to sys.path, so a repo shipping its own json.py would execute
# inside this hook -- and here it could emit the auto token and disarm the checks.
# -E also drops PYTHONPATH, which could otherwise smuggle the CWD back in as an
# ABSOLUTE path that this relative-only scrub would not catch.
sys.path[:] = [p for p in sys.path if p not in ("", ".")]
import json
try:
    d = json.loads(sys.stdin.read() or "{}")
    inp = d.get("tool_input", d.get("toolInput", {}))
    if isinstance(inp, str):
        inp = json.loads(inp or "{}")
    cmd = inp.get("command") if isinstance(inp, dict) else None
    shape_ok = isinstance(cmd, str)
    # Line 1 is the auto token; the command follows verbatim and MUST come last,
    # because it may itself be multiline. The mode is compared HERE rather than in
    # bash: $( ) strips trailing newlines, so a permission_mode of "auto\n" would
    # collapse to "auto" and stand the guard down. A non-str never equals "auto",
    # so this also subsumes an isinstance check.
    sys.stdout.write("1\n" if shape_ok and d.get("permission_mode") == "auto" else "0\n")
    if shape_ok:
        sys.stdout.write(cmd)
except Exception:
    pass
' 2>/dev/null || true)
  # $( ) stripped the trailing newline, so a token-only payload has no newline left.
  if [[ "$_GUARD_PAYLOAD" == *$'\n'* ]]; then
    [[ "${_GUARD_PAYLOAD%%$'\n'*}" == 1 ]] && AUTO_MODE=1
    CMD=${_GUARD_PAYLOAD#*$'\n'}
  elif [[ "$_GUARD_PAYLOAD" == 1 ]]; then
    AUTO_MODE=1
  fi
fi

# Grep fallback when Python is not available (AUTO_MODE stays 0 — see above)
if [[ -z "$CMD" ]]; then
  # Reset, do not merely leave at 0. The parse can SUCCEED and still land here:
  # a valid but EMPTY tool_input.command satisfies the shape check, so the token
  # may already be 1 while CMD is empty. The grep then takes the first "command"
  # match anywhere in the payload — possibly from OUTSIDE tool_input — and that
  # string was never validated by the parse the auto decision was made on.
  # Measured (coderabbitai + cubic, PR #543), before this reset:
  #   {"permission_mode":"auto","command":"rm -rf /etc","tool_input":{"command":""}}
  #   auto -> {} (allowed)   default -> ask
  # Whatever supplies CMD here did not come from the validated parse, so the auto
  # decision cannot apply to it: run every check.
  AUTO_MODE=0
  CMD=$(printf '%s' "$INPUT" | grep -o '"command"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*:[[:space:]]*"//;s/"$//' || true)
fi

# No command extracted — allow
if [[ -z "$CMD" ]]; then
  echo '{}'
  exit 0
fi

CMD_LOWER=$(printf '%s' "$CMD" | tr '[:upper:]' '[:lower:]')

# --- Recursive rm: judge EVERY rm in the chain, not just the last one ---
# `rm -rf /etc && rm -rf node_modules` must warn about /etc even though the last
# rm targets a safe artifact. The previous greedy sed stripped to the final rm,
# so only that one was ever judged, and a trailing safe rm also short-circuited
# every other check below (git reset --hard, DROP TABLE, ...).
# Segment splitting is delegated to gitcmd_detect.split_segments (quote-aware);
# the safe-artifact carve-out stays here because it is this guard's own policy.
# Prints "<rm> <truncate>": rm is exactly "unsafe" or "safe", truncate exactly
# "truncate" or "notruncate". ANY other output (including empty) means the
# scanner itself did not run, which falls through to the grep fallbacks below.
RM_VERDICT=""
TRUNC_VERDICT=""
if [[ "$AUTO_MODE" == 0 ]] && command -v python3 &>/dev/null; then
  _GUARD_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
  # shellcheck disable=SC2016  # python source: $-expansion must not happen in bash
  # ONE line, TWO verdicts: "<rm> <truncate>". Split below rather than spawning
  # a second interpreter — see the SINGLE PASS note at the top of the file.
  _SCAN_OUT=$(printf '%s' "$CMD" | PYTHONPATH="$_GUARD_LIB" python3 -S -c '
import sys
# Drop CWD from sys.path (python3 -c prepends it ahead of PYTHONPATH) so a
# repo-controlled gitcmd_detect.py or shadowed stdlib cannot run in the guard.
sys.path[:] = [p for p in sys.path if p not in ("", ".")]
import re
import shlex
# _all_chunks is private but deliberately reused: it expands $(...), backticks
# and `bash -c` payloads recursively, so `bash -c "rm -rf /etc"` is still seen.
# Scanning only the literal command would miss every nested form.
from gitcmd_detect import split_segments, chunks_and_truncation

# Build artifacts a rebuild reproduces. `out` is Next.js static export (and the
# `distDir`/output convention generally): measured over ~/.claude/watch-hooks.log,
# `rm -rf out && npm run build` was 24% of ALL Bash permission prompts — the single
# largest interruption source, and every one of them regenerable. Matching is by
# BASENAME, same as every other entry here, so `output/` is untouched.
SAFE = {"node_modules", ".next", "dist", "__pycache__", ".cache",
        "build", ".turbo", "coverage", "target", "out"}

# `out` is the one SAFE name generic enough to be somebody real data: `./out` in
# a Next.js project is a build artifact, but `/important/out` is not, and this
# guard cannot tell them apart from the basename alone. So it is safe only as a
# RELATIVE target — the shape actually observed (`rm -rf out && npm run build`).
# An absolute or ~-anchored path falls through and warns.
SAFE_RELATIVE_ONLY = {"out"}


def is_safe(target):
    base = target.rstrip("/").rsplit("/", 1)[-1]
    if base not in SAFE:
        return False
    if base not in SAFE_RELATIVE_ONLY:
        return True
    # `out` clears ONLY as a bare name in the current directory — `out`, `./out`,
    # `out/`. Anything carrying a path falls through and warns: absolute, `~`,
    # `../out`, `sub/out`, and `$VAR/out` (unexpanded, so its target is unknown).
    # `cd /elsewhere && rm -rf out` still clears, because this guard cannot see
    # cwd — that residual is the pre-existing semantics of every SAFE entry
    # (`build`, `dist`, `target` behave identically), not something `out` adds.
    stripped = target.rstrip("/")
    if stripped.startswith("./"):
        stripped = stripped[2:]
    return stripped == base and "$" not in stripped


# A name THIS SAME command string bound to mktemp points at a directory the
# command itself just created, so removing it cannot destroy anything that
# existed beforehand. Measured over ~/.claude/watch-hooks.log, `rm -rf "$T"`
# after a `T=$(mktemp -d)` was 45 of 209 Bash permission prompts (22%) - the
# second largest interruption source after `out`, and every one self-created.
#
# Clearing the WRONG name is a fail-OPEN, so attribution is strict: quotes are
# stripped by shlex, so the RHS reaching here is bare. The apostrophe below is
# spelled \x27 because this whole block is embedded in a bash single-quoted
# string and a literal one would terminate it.
MKTEMP_BIN = r"(?:/bin/|/usr/bin/|/usr/local/bin/|/opt/homebrew/bin/)?mktemp"
MKTEMP_RHS = re.compile(r"^[\"]?[$`]\(?\s*" + MKTEMP_BIN + r"(?![\w.-])")
ASSIGN = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)=(.*)$", re.S)
# shlex reports where an assignment SITS but not where its RHS ENDS - it splits
# an unquoted `$(mktemp -d)` in two, so a prefix match alone also accepts
# `T=$(mktemp -d)x` and `T=$(mktemp -d 2>/dev/null || echo /etc)`, whose real
# values are not temp dirs at all. So the RHS is re-read from the raw text and
# must be ONE complete, plain mktemp substitution: the substitution has to close
# its own parenthesis or backtick, and the body may not contain a nested
# expansion, a quote, or another command.
SIMPLE_MKTEMP = re.compile(
    r"[\"]?(?:\$\(\s*" + MKTEMP_BIN + r"(?![\w.-])[^()`$\"\x27;&|]*\)"
    r"|`\s*" + MKTEMP_BIN + r"(?![\w.-])[^()`$\"\x27;&|]*`)[\"]?\s*$")
# The carve-out may arm ONLY when the invocation PROVABLY creates the path.
# `-u`/`--dry-run` print a name without creating it, so another process can take
# that path before the `rm -rf` runs. Enumerating the no-create spellings lost:
# quoting and escapes (`-\u`), attached bundles (`-up/tmp`), long-option
# abbreviation (`--dr`), brace expansion (`-{u,d}`) - a ladder with no top.
# So this is INVERTED and fail-CLOSED: list the options that keep the create
# semantics, and refuse anything unrecognised, including a form this parser
# cannot read. Parsed with shlex, never text-matched.
SAFE_SHORT = set("dqt")                # -d directory, -q quiet, -t prefix
ARG_SHORT = set("p")                   # -p DIR (attached or separate)
SAFE_LONG = ("--directory", "--quiet", "--tmpdir", "--suffix")
ALL_LONG = SAFE_LONG + ("--dry-run", "--help", "--version")
# --suffix REQUIRES its argument and accepts it as a separate token; --tmpdir
# takes an OPTIONAL one, which GNU requires be attached with `=`. Treating a
# separate token as the argument of --tmpdir would skip it, and `--tmpdir -u`
# would then hide the -u.
ARG_LONG = ("--suffix",)


def _mktemp_creates(rhs):
    body = rhs.strip().strip(chr(34))
    for pre in ("$(", chr(96)):
        if body.startswith(pre):
            body = body[len(pre):]
            break
    body = body.rstrip(chr(96)).rstrip(")")
    try:
        toks = shlex.split(body, posix=True)
    except ValueError:
        return False
    expect_arg = False
    end_of_options = False
    for t in toks[1:]:
        # EVERY token, arguments included: bash resolves brace expansion long
        # after this scan, and `-p {/tmp,-u}` becomes `-p /tmp -u`. A token
        # carrying shell metacharacters is not readable here, so refuse.
        if any(ch in t for ch in "{}*?[]"):
            return False
        if expect_arg:
            expect_arg = False
            continue
        if end_of_options:
            continue                   # an operand, whatever it looks like
        if t == "--":
            end_of_options = True      # POSIX option terminator
            continue
        if t.startswith("--"):
            name = t.split("=", 1)[0]
            # GNU accepts an unambiguous abbreviation; an ambiguous one is an
            # ERROR, so refuse it rather than guess which option was meant.
            hits = [l for l in ALL_LONG if l.startswith(name)]
            if len(hits) != 1 or hits[0] not in SAFE_LONG:
                return False
            if hits[0] in ARG_LONG and "=" not in t:
                expect_arg = True
            continue
        if t.startswith("-") and len(t) > 1:
            rest = t[1:]
            i = 0
            while i < len(rest):
                ch = rest[i]
                if ch in ARG_SHORT:
                    if i == len(rest) - 1:
                        expect_arg = True
                    break              # whatever follows is its argument
                if ch not in SAFE_SHORT:
                    return False       # -u, a brace, anything unrecognised
                i += 1
            continue
        # anything else is the TEMPLATE operand
    return True


# Routes that rebind a name WITHOUT a command-prefix assignment. The first is the
# ${VAR:=default} expansion; the second is any word-binding builtin, whose
# operands are read out and disqualified.
REBIND_EXPANSION = re.compile(r"\$\{\s*([A-Za-z_][A-Za-z0-9_]*)\s*:?=")
REBIND_BUILTIN = re.compile(
    r"\b(?:for|select|read|export|unset|declare|local|typeset|getopts"
    r"|mapfile|readarray)"
    r"\b([^;&|\n]*)")
# ONLY the bare expansions `$V` and `${V}` - nothing appended. A suffix cannot be
# proven to stay inside the directory: it can carry its own expansion
# (backtick, brace) and, more basically, if mktemp FAILED then V is empty and
# `"$V/etc"` is `/etc` while `"$V/"` is `/`. Every cleared target measured in
# ~/.claude/watch-hooks.log was already the bare form, so this costs nothing.
# `${V%/*}` names the PARENT and must not match either - it does not, because
# anything after the name fails the anchor.
TEMP_TARGET = re.compile(r"^\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?$")


# Anything that can rebind a name, or redefine mktemp itself, from outside the
# text this function can read. Any of these voids the carve-out for the whole
# chunk - there is no way to prove what the name holds afterwards.
#   mktemp(){ echo /etc; }   a shell function shadows the binary
#   PATH=... / printf -v PATH so does a prepended directory
#   alias mktemp=...         and so does an alias, expanded on a later line
#   source f / . f           the sourced file runs in THIS shell and can assign
#   eval                     builds the assignment out of unreadable text
#   if/while/case/...        the assignment may sit in a branch that never runs,
#                            and the segment walk cannot see block nesting
UNTRUSTED = re.compile(
    r"(?:^|[\s;&|(])(?:mktemp\s*\(\s*\)|function\s+mktemp\b|source\s"
    r"|\.\s|eval\b|alias\s|PATH=|-v\s*[\"\x27]?PATH\b)"
    # ...plus an INDIRECT write target, whose name this scan cannot resolve:
    r"|-v\s*[\"\x27]?\$")
#
# ACCEPTED LIMIT, and a CLOSED question - do not reopen it. These patterns are
# matched as TEXT, so a quote-constructed spelling defeats each one (`tr"ap"`,
# `sou"rce"`, `mk"temp"()`), and a bash NAMEREF evades them all: after
# `R=T; declare -n R`, writing R writes through to T, so the rebind never names
# T at all. Closing that was attempted and REVERTED. It cannot be done by
# matching spellings - the ladder ran `declare -n` -> `declare -"n"` ->
# `builtin declare` -> `O=-n; declare "$O"` -> `B=declare; "$B"` -> `d"$B"` ->
# `command -- "$B"` -> `{ "$B"; }` -> `> /dev/null "$B"` -> `trap ... DEBUG` ->
# `tr"ap"` -> `mktemp ()` -> `re"ad"`, fourteen rungs with no top - and closing
# it structurally instead (require every command word to be READABLE) cost 9
# points of the measured 59% prompt reduction, which is the entire point of the
# carve-out. Reaching it needs a command that writes the mktemp assignment, the
# nameref indirection AND the rm in one string: this session attacking its own
# advisory guard, which merely prompts. Same call as the variable-command-name
# resolution removed above, for the same reason.
#
# Not in UNTRUSTED (which voids the whole chunk): a block only makes assignments
# that FOLLOW it conditional. `T=$(mktemp -d); for f in *; do ...; done` is fine.
BLOCK_KEYWORD = re.compile(
    r"(?:^|[\s;&|(])(?:if|then|elif|else|fi|while|until|case|esac|do|done)"
    r"(?=[\s;&|]|$)")


def temp_vars(chunk):
    """name -> index of the segment binding it to a fresh mktemp path.

    The index matters: `rm -rf "$T"; T=$(mktemp -d)` deletes the INHERITED T,
    so an assignment only clears deletions in a LATER segment.

    Deliberately per-chunk, never across them. chunks_and_truncation expands a
    child shell (`bash -c ...`) into its own chunk, and an assignment there
    cannot change the parent: in `bash -c \x27T=$(mktemp -d)\x27; rm -rf "$T"`
    the rm still sees whatever T the parent inherited.
    """
    if UNTRUSTED.search(chunk):
        return {}
    from_mktemp = {}
    from_other = set()
    segs = split_segments(chunk)
    # First segment that opens or continues a block; assignments from there on
    # may sit in a branch that never runs.
    block_at = next((i for i, (_o, sg) in enumerate(segs)
                     if BLOCK_KEYWORD.search(sg)), len(segs))
    for idx, (op, seg) in enumerate(segs):
        # The assignment has to be UNCONDITIONAL and in THIS shell, or the
        # `rm` that follows can still see an inherited value:
        #   `true || T=$(mktemp -d); rm -rf "$T"`  - never assigned
        #   `false && T=$(mktemp -d); rm -rf "$T"` - never assigned
        #   `T=$(mktemp -d) | cat;   rm -rf "$T"`  - assigned in a subshell
        #   `T=$(mktemp -d) & wait;   rm -rf "$T"`  - backgrounded, same thing
        # so only a segment that leads, or follows a plain separator, counts.
        if op not in ("", ";", "\n"):
            continue
        if idx + 1 < len(segs) and segs[idx + 1][0] in ("|", "&"):
            continue
        try:
            toks = shlex.split(seg, posix=True)
        except ValueError:
            toks = seg.split()
        # bash requires assignment prefixes to PRECEDE the command word, so
        # the walk stops at the first token that is not one. That is what
        # keeps `echo "T=$(mktemp -d)"` from arming the carve-out: there the
        # assignment is an operand of echo and never runs.
        #
        # It does NOT need to reject `T=$(mktemp -d) true` here (an assignment
        # PREFIX, which sets T only in the environment of that one command): the
        # raw-RHS check below already does, because the text after the closing
        # paren fails the end anchor in SIMPLE_MKTEMP. Doing it in THIS walk
        # anyway - shlex splits an unquoted `$(mktemp -d)` into two tokens, so
        # "the segment is assignments only" is not decidable here.
        for tok in toks:
            m = ASSIGN.match(tok)
            if not m:
                break
            if MKTEMP_RHS.match(m.group(2)) and idx < block_at:
                from_mktemp.setdefault(m.group(1), idx)
            else:
                from_other.add(m.group(1))
    # Order is not tracked, so ANY non-mktemp assignment to the name disqualifies
    # it - `T=/etc; T=$(mktemp -d)` reads the same here as the reverse.
    names = {n: i for n, i in from_mktemp.items() if n not in from_other}
    if names:
        for m in REBIND_EXPANSION.finditer(chunk):
            names.pop(m.group(1), None)
        for m in REBIND_BUILTIN.finditer(chunk):
            # Chosen at runtime and therefore unreadable here: an expansion, a
            # substitution, or a GLOB - bash expands `read d*` against filenames
            # before running it, so a `docs` directory makes it `read docs`.
            if any(ch in m.group(1) for ch in "$`*?["):
                return {}
            for word in re.findall(r"[A-Za-z_][A-Za-z0-9_]*", m.group(1)):
                names.pop(word, None)
    for name in list(names):
        # Spellings that rebind a name WITHOUT producing a plain `NAME=` token,
        # so neither the prefix walk nor the builtin scan above sees them:
        #   T+=/etc        append
        #   T[0]=/etc      array element
        #   printf -v T    print INTO the variable
        esc = re.escape(name)
        if (re.search(r"\b%s(?:\[|\+=)" % esc, chunk)
                or re.search(r"-v\s*[\"\x27]?%s\b" % esc, chunk)):
            names.pop(name, None)
            continue
        for m in re.finditer(r"\b%s=" % esc, chunk):
            # The RHS runs to the next command boundary. Anything the operators
            # below can reach is a second command, so it is outside the RHS and
            # the substitution must already have closed before it.
            rhs = m.string[m.end():]
            for sep in ";&|\n":
                cut = rhs.find(sep)
                if cut >= 0:
                    rhs = rhs[:cut]
            if not SIMPLE_MKTEMP.match(rhs) or not _mktemp_creates(rhs):
                names.pop(name, None)
                break
    return names


def is_temp(target, tmpvars, seg_idx):
    m = TEMP_TARGET.match(target)
    return bool(m) and tmpvars.get(m.group(1), seg_idx) < seg_idx


def recursive_targets(argv):
    """(is_recursive, targets) for an rm argv starting at the command word."""
    recursive = False
    targets = []
    opts = True
    for tok in argv[1:]:
        if opts and tok == "--":
            opts = False
        elif opts and len(tok) >= 3 and tok.startswith("--") \
                and "recursive".startswith(tok[2:]):
            # GNU rm accepts any unambiguous prefix of --recursive (--r, --rec,
            # and so on). recursive is the only r-prefixed long option rm has,
            # so any --r prefix means recursive. Verified.
            recursive = True
        elif opts and tok.startswith("--"):
            pass
        elif opts and len(tok) > 1 and tok.startswith("-"):
            if "r" in tok[1:].lower():
                recursive = True
        else:
            targets.append(tok)
    return recursive, targets


# KNOWN LIMIT, same shape as the SQL client list below: an allowlist of launcher
# binaries is never complete, so an unlisted one puts itself in the command slot
# and the truncate behind it reads as an operand. Add names here as they come up.
# The alternative — treating every unrecognized command word as a wrapper — is
# the any-token scan, which is what cost 11% of ALL prompts in false positives.
WRAPPERS = {"sudo", "doas", "su", "runuser", "env", "xargs", "nohup", "timeout",
            "command", "time", "stdbuf", "nice", "ionice", "exec", "setsid",
            "chroot", "unshare", "flock", "script", "watch", "parallel",
            "caffeinate", "arch", "xcrun"}


# `if`/`while`/`until` introduce a CONDITION, which is an executed command:
# `if truncate -s 0 audit.log; then :; fi` runs truncate. They belong here with
# `then`/`do`, not treated as command words in their own right.
# `case`/`in`/`esac` belong here for the same reason if/then do: `in` introduces
# a case PATTERN, and the token after that pattern is a command word. Relying on
# the pattern token ending in `)` instead was fragile - a pattern that is (or
# merely looks like) a command substitution does not present as a closer.
CONTROL = {"if", "while", "until", "then", "do", "else", "elif", "!", "{", "(",
           "case", "in", "esac", "&&", "||", ";", "|", "&", "eval", "coproc"}
# find/xargs style dispatch: the token AFTER these is a command word.
DISPATCH = {"-exec", "-execdir", "-ok", "-okdir", "--exec"}


DYN_FD = re.compile(r"^\{[A-Za-z_][A-Za-z0-9_]*\}[<>]")
DYN_FD_NAME = re.compile(r"^\{[A-Za-z_][A-Za-z0-9_]*\}")
# A redirection operator carrying no target takes the NEXT token as its target.
BARE_REDIRECT = ("<", ">", ">>", "<<", "<<<", "&>", ">|", "<>", "&>>")


def _is_redirect(tok):
    """A leading redirection is not the command word: `</dev/null truncate ...`.

    Covers the numeric form (`2>f`) and bash dynamic-FD allocation (`{fd}>f`),
    which likewise runs the command that follows it.
    """
    return (tok.lstrip("0123456789")[:1] in ("<", ">")
            or tok.startswith("&>") or bool(DYN_FD.match(tok)))


def _whole_substitution(tok):
    """True iff tok is ENTIRELY one `$(...)` - not merely starting with one.

    Balance alone is not enough: `$(echo x)()` is balanced and starts with `$(`
    yet its final `)` is a case delimiter. Track depth and require it to reach
    zero exactly at the last character.
    """
    # Exactly one `(` (the leading one) and exactly one `)` (the last char).
    # Depth-tracking is not enough: shlex has already dropped quote provenance,
    # so a LITERAL paren inside the substitution counts the same as a syntactic
    # one and can balance a case delimiter. Anything more complex is treated as
    # a closer, which over-warns - the safe direction.
    # A non-empty body is required: quoted TEXT spelling a bare opener collapses to the
    # empty `$()` once shlex drops the quotes, and treating that as a real
    # substitution would hand a case pattern the command position.
    #
    # KNOWN LIMIT, same family as the ANSI-C quoting one below: shlex removes
    # quote provenance entirely, so quoted text spelling a NON-empty
    # substitution is indistinguishable from the real thing. The
    # alternative - treating every such token as a closer - over-warns on the
    # ordinary `echo "$(cmd)" ...` operand this change exists to keep silent.
    return (tok.startswith("$(") and tok.endswith(")") and len(tok) > 3
            and tok.count("(") == 1 and tok.count(")") == 1)


def has_truncate(chunks):
    """True iff coreutils `truncate` appears as a COMMAND WORD.

    NOTE: this whole block is embedded in a bash single-quoted string, so it
    must contain no apostrophe anywhere, comments included.

    Regex over the raw string cannot do this: it either misses an operand-first
    invocation (`truncate audit.log -s 0`, legal under GNU option permutation)
    or fires on the word inside a quoted literal (a grep -F for the same text).
    Those two demands are contradictory for a text match and were the whole
    reason the bare-word rule mis-fired. shlex settles both — a quoted literal
    collapses into ONE token, so it is never a command word, while wrappers and
    absolute paths (`sudo truncate`, `env truncate`, `/usr/bin/truncate`) still
    expose theirs. Same walk the rm scanner below uses, same reasons.
    """
    for chunk in chunks:
        for _op, seg in split_segments(chunk):
            try:
                toks = shlex.split(seg, posix=True)
            except ValueError:
                toks = seg.split()
            # COMMAND WORD only, not any token: `truncate` is an ordinary
            # operand in `grep -F truncate script.sh` and `echo truncate`, so an
            # any-token scan fires on both. But "first token of the segment" is
            # not the command word either — bash puts assignments, redirections,
            # control keywords, negation and dispatch flags ahead of it. Tracking
            # command POSITION closes that whole class at once, instead of
            # enumerating one more prefix each time another is found.
            cmd_pos = True      # the next non-prefix token runs
            skip_next = False   # ...unless it is a redirection target
            for j, tok in enumerate(toks):
                if skip_next:
                    skip_next = False
                    continue
                word = tok.lstrip("({").rsplit("/", 1)[-1].lower()
                if word == "truncate" and cmd_pos:
                    return True
                if _is_redirect(tok):
                    # `>x` carries its target; a bare `>` takes the next token.
                    skip_next = (DYN_FD_NAME.sub("", tok).lstrip("0123456789")
                                 in BARE_REDIRECT)
                    continue                     # position is unchanged
                if word in CONTROL or tok in DISPATCH:
                    cmd_pos = True               # `then truncate`, `-exec truncate`
                    continue
                # A token CLOSING a construct is followed by a command word: a
                # case pattern (`x) truncate`), a function header (`f(){
                # truncate`), a group (`{ truncate`). Catching the shape rather
                # than naming each keyword also covers `esac`/`;;` spellings.
                #
                # A trailing `)` alone is ambiguous: `$(printf x)` (a completed
                # command substitution, already ONE token after shlex) also ends
                # in `)`, but is not a construct closer - the token that follows
                # it is an ordinary OPERAND, not a command word. A genuine closer
                # like `x)` carries an unmatched `)` (no earlier `(` in the same
                # token); a self-contained substitution is parenthesis-balanced.
                #
                # A token that is ONLY grouping punctuation is checked FIRST and
                # by identity: `word` is computed with lstrip("({"), which turns
                # a standalone `(` into the EMPTY string - matching nothing above
                # and then falling through to consume the command slot. That is
                # how `( truncate -s 0 f )` escaped: a REGRESSION against the
                # bare-word rule this file replaced, which caught it as text.
                if tok in ("(", ")", "{", "}", ";;"):
                    cmd_pos = True
                    continue
                # A trailing `)` closes a construct UNLESS the token is a
                # command SUBSTITUTION, which is self-contained and yields an
                # OPERAND. Parenthesis BALANCE cannot tell them apart: bash
                # allows a leading `(` on a case pattern, so `(x)` is balanced
                # and is still a closer. Presence of a substitution opener is
                # what actually distinguishes them.
                # A trailing `)` closes a construct UNLESS the whole token IS
                # a complete command substitution, which yields an OPERAND.
                # Merely CONTAINING one is not enough - `x$(true))` is a case
                # pattern - and parenthesis balance alone is not either, since
                # bash allows a leading `(` on a pattern.
                # A whole substitution leaves the position UNCHANGED rather
                # than consuming it: unquoted, it can expand to nothing at all,
                # and then the NEXT token is the command word - `$(true)
                # truncate -s 0 f` really does run truncate. At an operand
                # position it is simply an operand, so preserving is right in
                # both directions.
                if _whole_substitution(tok):
                    continue
                if tok.endswith(("{", ";;", ")")):
                    cmd_pos = True
                    continue
                if "=" in word and not word.startswith("-"):
                    continue                     # VAR=val prefix
                if word in WRAPPERS:
                    # A wrapper hides the command word behind its own options AND
                    # THEIR ARGUMENTS (`sudo -u root`, `env -u FOO`, `timeout 5`,
                    # `nice -n 10`). Skipping that correctly needs an arity table
                    # per wrapper, which fails OPEN wherever it is wrong — so once
                    # a wrapper holds the slot, ANY later token in the segment
                    # counts. `sudo grep -F truncate f` then over-warns: the safe
                    # direction, and rare next to a wrapped truncate.
                    # `break`, never `return False`: chunks_and_truncation
                    # expands nested payloads (`env -S`, `bash -c`) into FURTHER
                    # chunks, and returning here would abandon them unexamined —
                    # which is exactly how the #519 `env -S` case slipped through.
                    # A later token can also CARRY a command string rather than
                    # be one: `xargs sh -c "truncate -s 0 f"` is one quoted token
                    # after shlex, so an exact-token match reads it as an operand.
                    # Re-enter on any token holding whitespace — that is a payload
                    # to parse, and the recursion terminates because a token
                    # without whitespace never re-enters.
                    for t in toks[j + 1:]:
                        if t.lstrip("({").rsplit("/", 1)[-1].lower() == "truncate":
                            return True
                        if (" " in t or "\t" in t) and has_truncate([t]):
                            return True
                    break
                cmd_pos = False                  # a real command word, not truncate
    return False


def unsafe(chunks, truncated):
    # Takes the ALREADY-EXPANDED chunks: chunks_and_truncation is documented
    # below as potentially exponential and shares the 3s alarm with everything
    # else here, so it runs exactly once per command and both scanners read the
    # same result.
    #
    # #377 residual 1: a recursive rm wrapped deeper than _all_chunks expands was
    # never surfaced, so this function cleared a command it had not fully read.
    # Warn on the truncation itself — the PRECISE fail-closed condition
    # ("extraction hit its bound with payloads left"), reported by the traversal
    # itself rather than guessed at from the raw text.
    if truncated:
        return True
    for chunk in chunks:
        # Scoped to THIS chunk: an assignment in an expanded child shell never
        # reaches an rm in the parent.
        tmpvars = temp_vars(chunk)
        for seg_idx, (_op, seg) in enumerate(split_segments(chunk)):
            try:
                toks = shlex.split(seg, posix=True)
            except ValueError:
                toks = seg.split()
            for i, tok in enumerate(toks):
                # basename match so `env rm`, `sudo rm` and /bin/rm all count;
                # lstrip the shell grouping punctuation `(`/`{` so a grouped
                # command like `(rm -rf /etc)` still exposes its command word.
                # lower() because a case-insensitive filesystem (macOS default)
                # runs `RM` as /bin/rm — matches CMD_LOWER + the grep fallback.
                if tok.lstrip("({").rsplit("/", 1)[-1].lower() != "rm":
                    continue
                recursive, targets = recursive_targets(toks[i:])
                # A recursive rm with NO visible literal target takes its targets
                # from elsewhere (xargs/stdin, "$@", a glob, a variable), e.g.
                # `... | xargs rm -rf` — we cannot prove those are safe artifacts,
                # so warn. Otherwise warn iff any listed target is non-safe.
                if recursive and (not targets
                                  or any(not is_safe(t)
                                         and not is_temp(t, tmpvars, seg_idx)
                                         for t in targets)):
                    return True
    return False


# SCOPE (advisory guard, fails-open by design). This judges every rm the
# structured scan REACHES: chains, wrappers, command AND process substitutions
# (via gitcmd_detect._all_chunks), operands before or after the flag, and a
# targetless recursive rm. Plus, since #377, it warns when extraction itself was
# TRUNCATED — a command wrapped deeper than _all_chunks expands is no longer
# silently cleared, because "I could not read all of it" is not "it is safe".
#
# A payload behind a CONTROL KEYWORD (`if true; then eval <payload>; fi`) is at
# the detector level in _command_argv (the shell-reserved-word stripping added in
# #426), which defeated the fail-CLOSED commit/PR/merge gates too — a far bigger
# deal than this advisory guard. This guard shares _shell_payloads → _command_argv,
# so it sees through keywords for free.
#
# PERMANENT LIMITATIONS (decided in #377, not deferred work — do not reopen as a
# raw-text backstop; that family drew a fresh adversarial finding on all ~12
# iterations in #376):
#   - a recursive rm carried by a NON-shell interpreter (python -c, perl -e).
#     This is a SHELL-structure guard; modelling arbitrary interpreter semantics
#     is out of scope by design.
#   - ANSI-C quoted spellings of the command word (the dollar-single-quote form,
#     e.g. rm spelled as dollar-quote-rm-quote). shlex yields a different token.
#   - a command word held in a VARIABLE, e.g. cmd=truncate then "$cmd" -s 0 f.
#     Resolution for this WAS built and then removed deliberately: it means
#     emulating bash assignment semantics (export/declare/typeset/readonly,
#     stacked and interleaved, both option polarities, which options assign
#     versus print), and every rung of that ladder produced a fresh adversarial
#     finding while silencing none of the 237 measured prompts. Do not reopen it
#     for the same reason #377 closed the raw-text backstop: the scanner reads
#     command POSITION, not values.
# All are exotic and, this guard being advisory (it prompts, never blocks),
# non-blocking; the grep fallback below still catches many of them in the
# python-absent path.


_cmd = sys.stdin.read()
# Bound the scan. _all_chunks expands nested command substitutions with an
# exponential over-count (accepted in #426), and the #377 truncation collector
# runs the boundary extractors on top — a pathologically deep `$(...)` command
# could make this PreToolUse hook slow. Cap wall time with SIGALRM and, on
# timeout, WARN (the safe direction for an advisory guard: "could not finish
# analyzing" is not "safe"). Signals are Unix-only, which is fine for this hook.
import signal


def _on_timeout(signum, frame):
    raise TimeoutError


try:
    signal.signal(signal.SIGALRM, _on_timeout)
    signal.alarm(3)
except (ValueError, AttributeError):
    pass  # no SIGALRM (non-Unix / non-main-thread) — run unbounded, fail-open trap still applies
try:
    _chunks, _truncated = chunks_and_truncation(_cmd)
    verdict = "unsafe" if unsafe(_chunks, _truncated) else "safe"
    # Same single pass, same bound: a second interpreter spawn on every Bash
    # call is what the SINGLE PASS note above exists to avoid.
    trunc = "truncate" if has_truncate(_chunks) else "notruncate"
except TimeoutError:
    verdict, trunc = "unsafe", "truncate"
finally:
    try:
        signal.alarm(0)
    except (ValueError, AttributeError):
        pass
print(verdict, trunc)
' 2>/dev/null || true)
  read -r RM_VERDICT TRUNC_VERDICT <<<"$_SCAN_OUT" || true
fi

if [[ "$AUTO_MODE" == 0 && "$RM_VERDICT" != "unsafe" && "$RM_VERDICT" != "safe" ]]; then
  # The scanner did not run (no python3, import failure, crash). Do NOT treat a
  # missing verdict as safe — drop the safe-artifact carve-out and warn on any
  # recursive rm. Over-warning is the safe direction for an advisory guard.
  # ponytail: grep, not a bash port of split_segments; revisit only if a
  # python3-less host ever actually matters.
  # Match a recursive rm crudely but broadly (this path is the degraded, no-
  # python fallback, so it biases hard toward warning): case-insensitive so -Rf
  # counts, and allowing quotes/backslashes/whitespace between the rm word and
  # the flag so "rm" -rf and env rm -Rf still trip. Over-warning is the safe
  # direction here.
  if printf '%s' "$CMD" | grep -qiE 'rm[^|;&]{0,20}(-[a-z]*r|--r)' 2>/dev/null; then
    RM_VERDICT="unsafe"
  fi
fi

# --- Destructive pattern checks (first match wins) ---
WARN=""

# rm -rf / rm -r / rm --recursive (non-safe targets)
if [[ "$RM_VERDICT" == "unsafe" ]]; then
  WARN="Destructive: recursive delete (rm -r). This permanently removes files."
fi

# DROP TABLE / DROP DATABASE
if [[ -z "$WARN" ]] && printf '%s' "$CMD_LOWER" | grep -qE 'drop\s+(table|database)' 2>/dev/null; then
  WARN="Destructive: SQL DROP detected. This permanently deletes database objects."
fi

# TRUNCATE — the OPERATION, never the english word.
# A bare `\btruncate\b` over the whole command matched the word wherever it
# appeared: in a grep pattern, in a python string literal, in prose inside an
# echo. Measured over ~/.claude/watch-hooks.log (176 real Bash permission
# prompts, six days) this rule fired 20 times — 11% of EVERY prompt — and not
# one of the 20 was SQL. All 20 were this repo's own gate tests naming the word.
#
# The fix is precision, not relaxation: the rule keeps warning on both things it
# can legitimately mean, and goes silent only where it meant nothing at all.
#   SQL       -> `TRUNCATE TABLE`, or `truncate` alongside a SQL client
#   coreutils -> `truncate` at command-word position (erases a file in place)
#
# KNOWN LIMIT, accepted: the client list is an allowlist and allowlists of
# third-party binaries are never complete — a bare `TRUNCATE users` through a
# client not named here goes unwarned, where the old bare-word rule warned.
# `TRUNCATE TABLE` is the client-independent backstop and covers the spelling
# most tools emit; the residual is bare-TRUNCATE through an unlisted client.
# Add names here as they come up rather than reverting to the bare word, which
# cost 11% of ALL prompts in false positives.
#
# `truncate table` is matched WHEREVER it appears, including inside a quoted
# string, and that is deliberate: it is the operation phrase, not the english
# word, and `psql -c "TRUNCATE TABLE t"` puts real SQL inside quotes too. So
# `echo "do not truncate table users"` over-warns. Accepted — over-warning is
# this guard's safe direction, the phrase is rare in prose (0 of the 20 measured
# false positives were it, all 20 were the bare word), and the alternative —
# requiring a client — would go silent on a bare `TRUNCATE TABLE users;`.
# Deliberately NOT gated on AUTO_MODE, same as DROP above: the classifier does
# not name either, so both stay live in every mode.
if [[ -z "$WARN" ]]; then
  if printf '%s' "$CMD_LOWER" | grep -qE 'truncate[[:space:]]+table\b' 2>/dev/null \
     || { printf '%s' "$CMD_LOWER" | grep -qE '\btruncate\b' 2>/dev/null \
          && printf '%s' "$CMD_LOWER" \
             | grep -qE '\b(psql|pgcli|mysql|mysqlsh|mycli|mariadb|sqlite3|litecli|sqlcmd|sqlplus|snowsql|usql|clickhouse-client|clickhouse|duckdb|cockroach|cqlsh|beeline|trino|presto|impala-shell|spark-sql|bq)\b' 2>/dev/null; }; then
    WARN="Destructive: SQL TRUNCATE detected. This deletes all rows from a table."
  # Command-word detection is delegated to the quote-aware scanner above
  # (has_truncate), not grepped. Every regex attempt here was bypassable in one
  # direction or false-positive in the other: keying on flags missed
  # `truncate audit.log -s 0` (GNU permutes options after operands), and keying
  # on position missed `sudo truncate` / `/usr/bin/truncate` / the `env -S`
  # audit-log erasure #519 tests for — while any text match fired on
  # `grep -F 'truncate -s'`. shlex resolves both at once.
  #
  # The fallback fires only when the scanner did NOT run (no python3, AUTO_MODE):
  # there, the original broad bare-word match is restored deliberately, because a
  # degraded path must over-warn rather than under-detect.
  elif [[ "$TRUNC_VERDICT" == "truncate" ]] \
       || { [[ "$TRUNC_VERDICT" != "notruncate" ]] \
            && printf '%s' "$CMD_LOWER" | grep -qE '\btruncate\b' 2>/dev/null; }; then
    WARN="Destructive: truncate empties a file in place."
  fi
fi

# The four git patterns below are all named in auto mode's own default block list,
# so each is gated on AUTO_MODE=0 — see the stand-down note above. The SQL checks
# are deliberately NOT gated: the classifier does not name DROP/TRUNCATE.

# git push --force / git push -f (but NOT --force-with-lease which is the safe alternative)
if [[ -z "$WARN" && "$AUTO_MODE" == 0 ]] && printf '%s' "$CMD" | grep -qE 'git\s+push\s+.*(-f\b|--force\b)' 2>/dev/null && ! printf '%s' "$CMD" | grep -qE -- '--force-with-lease' 2>/dev/null; then
  WARN="Destructive: git force-push rewrites remote history."
fi

# git reset --hard
if [[ -z "$WARN" && "$AUTO_MODE" == 0 ]] && printf '%s' "$CMD" | grep -qE 'git\s+reset\s+--hard' 2>/dev/null; then
  WARN="Destructive: git reset --hard discards all uncommitted changes."
fi

# git checkout . / git restore . (standalone . only, not .gitignore etc)
if [[ -z "$WARN" && "$AUTO_MODE" == 0 ]] && printf '%s' "$CMD" | grep -qE 'git\s+(checkout|restore)\s+\.(\s|$)' 2>/dev/null; then
  WARN="Destructive: discards all uncommitted changes in the working tree."
fi

# git clean -f (removes untracked files)
if [[ -z "$WARN" && "$AUTO_MODE" == 0 ]] && printf '%s' "$CMD" | grep -qE 'git\s+clean\s+.*-[a-zA-Z]*f' 2>/dev/null; then
  WARN="Destructive: git clean -f removes untracked files permanently."
fi

# --- Output ---
if [[ -n "$WARN" ]]; then
  WARN_ESCAPED=$(printf '%s' "$WARN" | sed 's/"/\\"/g')
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"[careful] %s"}}\n' "$WARN_ESCAPED"
else
  echo '{}'
fi
