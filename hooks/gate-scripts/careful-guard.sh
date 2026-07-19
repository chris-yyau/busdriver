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

# Extract the "command" field from tool_input JSON
# Prefer Python for correct JSON parsing (handles escaped quotes, multiline commands)
# Supports both tool_input and toolInput keys, and string payloads
# Fall back to grep only when Python is unavailable
if command -v python3 &>/dev/null; then
  CMD=$(printf '%s' "$INPUT" | python3 -c '
import sys, json
try:
    d = json.loads(sys.stdin.read() or "{}")
    inp = d.get("tool_input", d.get("toolInput", {}))
    if isinstance(inp, str):
        inp = json.loads(inp or "{}")
    if isinstance(inp, dict):
        print(inp.get("command", ""))
except Exception:
    pass
' 2>/dev/null || true)
fi

# Grep fallback when Python is not available
if [[ -z "$CMD" ]]; then
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
# Prints exactly "unsafe" or "safe"; ANY other output (including empty) means
# the scanner itself did not run, which falls through to the grep fallback below.
RM_VERDICT=""
if command -v python3 &>/dev/null; then
  _GUARD_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
  # shellcheck disable=SC2016  # python source: $-expansion must not happen in bash
  RM_VERDICT=$(printf '%s' "$CMD" | PYTHONPATH="$_GUARD_LIB" python3 -S -c '
import sys
# Drop CWD from sys.path (python3 -c prepends it ahead of PYTHONPATH) so a
# repo-controlled gitcmd_detect.py or shadowed stdlib cannot run in the guard.
sys.path[:] = [p for p in sys.path if p not in ("", ".")]
import shlex
# _all_chunks is private but deliberately reused: it expands $(...), backticks
# and `bash -c` payloads recursively, so `bash -c "rm -rf /etc"` is still seen.
# Scanning only the literal command would miss every nested form.
from gitcmd_detect import split_segments, chunks_and_truncation

SAFE = {"node_modules", ".next", "dist", "__pycache__", ".cache",
        "build", ".turbo", "coverage", "target"}


def is_safe(target):
    return target.rstrip("/").rsplit("/", 1)[-1] in SAFE


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


def unsafe(cmd):
    # #377 residual 1: a recursive rm wrapped deeper than _all_chunks expands was
    # never surfaced, so this function cleared a command it had not fully read.
    # Warn on the truncation itself — the PRECISE fail-closed condition
    # ("extraction hit its bound with payloads left"), reported by the traversal
    # itself rather than guessed at from the raw text.
    chunks, truncated = chunks_and_truncation(cmd)
    if truncated:
        return True
    for chunk in chunks:
        for _op, seg in split_segments(chunk):
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
                                  or any(not is_safe(t) for t in targets)):
                    return True
    return False


# SCOPE (advisory guard, fails-open by design). This judges every rm the
# structured scan REACHES: chains, wrappers, command AND process substitutions
# (via gitcmd_detect._all_chunks), operands before or after the flag, and a
# targetless recursive rm. Plus, since #377, it warns when extraction itself was
# TRUNCATED — a command wrapped deeper than _all_chunks expands is no longer
# silently cleared, because "I could not read all of it" is not "it is safe".
#
# A payload behind a CONTROL KEYWORD (`if true; then eval '…'; fi`) is handled at
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
# Both are exotic and, this guard being advisory (it prompts, never blocks),
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
    verdict = "unsafe" if unsafe(_cmd) else "safe"
except TimeoutError:
    verdict = "unsafe"
finally:
    try:
        signal.alarm(0)
    except (ValueError, AttributeError):
        pass
print(verdict)
' 2>/dev/null || true)
fi

if [[ "$RM_VERDICT" != "unsafe" && "$RM_VERDICT" != "safe" ]]; then
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

# TRUNCATE
if [[ -z "$WARN" ]] && printf '%s' "$CMD_LOWER" | grep -qE '\btruncate\b' 2>/dev/null; then
  WARN="Destructive: SQL TRUNCATE detected. This deletes all rows from a table."
fi

# git push --force / git push -f (but NOT --force-with-lease which is the safe alternative)
if [[ -z "$WARN" ]] && printf '%s' "$CMD" | grep -qE 'git\s+push\s+.*(-f\b|--force\b)' 2>/dev/null && ! printf '%s' "$CMD" | grep -qE -- '--force-with-lease' 2>/dev/null; then
  WARN="Destructive: git force-push rewrites remote history."
fi

# git reset --hard
if [[ -z "$WARN" ]] && printf '%s' "$CMD" | grep -qE 'git\s+reset\s+--hard' 2>/dev/null; then
  WARN="Destructive: git reset --hard discards all uncommitted changes."
fi

# git checkout . / git restore . (standalone . only, not .gitignore etc)
if [[ -z "$WARN" ]] && printf '%s' "$CMD" | grep -qE 'git\s+(checkout|restore)\s+\.(\s|$)' 2>/dev/null; then
  WARN="Destructive: discards all uncommitted changes in the working tree."
fi

# git clean -f (removes untracked files)
if [[ -z "$WARN" ]] && printf '%s' "$CMD" | grep -qE 'git\s+clean\s+.*-[a-zA-Z]*f' 2>/dev/null; then
  WARN="Destructive: git clean -f removes untracked files permanently."
fi

# --- Output ---
if [[ -n "$WARN" ]]; then
  WARN_ESCAPED=$(printf '%s' "$WARN" | sed 's/"/\\"/g')
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"[careful] %s"}}\n' "$WARN_ESCAPED"
else
  echo '{}'
fi
