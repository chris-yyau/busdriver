#!/usr/bin/env python3
"""#685 — is this Bash command a commit whose file set is CLOSED and knowable?

    python3 -I commit_scope.py <repo_dir> <hook_cwd> <state_dir>   < JSON on stdin

Prints the staged paths, one per line, and exits 0 ONLY for a bare single-segment
`git commit -m …` in a repo where nothing can restage before the commit runs.
The file set comes from git, never from the command. Exit 1 = no carve-out, which
is the gate's behaviour without this helper, so refusing is always free.

Rationale for every refusal below, and the accepted residuals (the Bash tool's
own environment; the PreToolUse TOCTOU window), are in ADR 0044. Read it before
loosening anything here.
"""
import sys

# Drop CWD entries so a repo-planted shlex.py/os.py cannot hijack the gate
# (matches marker_ops.py); runs before the first non-builtin import.
sys.path[:] = [p for p in sys.path if p not in ("", ".")]

import json
import os
import shlex
import signal
import stat
import subprocess
import time

# Whole-helper wall-clock budget, shared by every subprocess AND every
# settings-file read below. The pre-commit gate is registered with a
# 10-SECOND PreToolUse timeout and a timed-out hook emits NO decision, which
# the harness reads as ALLOW — so anything that can HANG in here is a bypass,
# not a stall. Repo-influenced git config can hang git outright
# (`[include] path = /dev/zero` makes `git config` read forever), so every
# subprocess AND file read draws from ONE SHARED deadline rather than each
# getting its own: a dozen individually-bounded calls can still overrun the
# hook budget together. Exhaustion refuses, like every other failure in this
# module.
_BUDGET_SECONDS = 4.0
_DEADLINE = None


def _remaining_budget():
    """Seconds left on the shared whole-helper deadline; lazily starts it."""
    global _DEADLINE
    if _DEADLINE is None:
        _DEADLINE = time.monotonic() + _BUDGET_SECONDS
    return _DEADLINE - time.monotonic()


def _run(cmd, env=None):
    """Run a subprocess against the shared deadline. None = refuse."""
    remaining = _remaining_budget()
    if remaining <= 0:
        return None
    try:
        return subprocess.run(cmd, capture_output=True, env=env, timeout=remaining)
    except Exception:
        return None


class _ReadTimeout(Exception):
    pass


class _alarm_bound(object):
    """Bound a WHOLE block by the shared deadline, raising _ReadTimeout on expiry.

    It has to wrap the open() and fstat() too, not just the read: O_NONBLOCK is
    defined to affect FIFOs/sockets/devices, NOT regular files (Linux open(2)),
    so a regular file on a stalled network mount — or a symlink chain resolving
    onto one — can block inside os.open()/os.fstat() before any read is
    attempted. An earlier revision armed the alarm only around the read and left
    exactly that window unbounded; a hang there is a bypass, because the 10s
    PreToolUse timeout emits NO decision and the harness reads that as allow.

    Signals are Unix-only and main-thread-only. Where SIGALRM cannot be armed
    this degrades to unbounded, and the surrounding hook timeout is the only
    backstop — accepted because Claude Code hooks run on Unix, and the
    alternative (thread-based bounding) is more machinery than the residual
    warrants.
    """

    def __enter__(self):
        self.armed = False
        remaining = _remaining_budget()
        if remaining <= 0:
            raise _ReadTimeout
        try:
            signal.signal(signal.SIGALRM, self._on_alarm)
            # setitimer (not alarm) so the deadline preserves fractional
            # seconds instead of rounding up to the next whole second —
            # alarm(max(1, int(remaining) + 1)) could overrun the shared
            # budget by up to 1s (CodeRabbit, PR #697).
            signal.setitimer(signal.ITIMER_REAL, remaining)
            self.armed = True
        except (ValueError, AttributeError):
            pass
        return self

    @staticmethod
    def _on_alarm(signum, frame):
        raise _ReadTimeout

    def __exit__(self, exc_type, exc, tb):
        if self.armed:
            try:
                signal.setitimer(signal.ITIMER_REAL, 0)
            except (ValueError, AttributeError):
                pass
        return False


def _read_bounded(fh, max_bytes):
    """Read at most max_bytes+1 from fh. None = refuse.

    SIZE bound only — the WALL-TIME bound is supplied by the `_alarm_bound`
    context the caller already holds, which also covers the open and fstat that
    preceded this call. Capping the size matters independently: a huge file
    could burn the remaining budget on decode work even when the read is fast.
    """
    try:
        data = fh.read(max_bytes + 1)
    except _ReadTimeout:
        raise
    except Exception:
        return None
    if len(data) > max_bytes:
        return None
    return data


# Substitution survives quoting (`"$(git add src/x)"` runs before the commit),
# so it is refused anywhere. Glob/brace act only UNQUOTED — `-m {msg,-a}` reads
# as one message and expands into a flag. `();<>|&` would make a second command.
_SUBSTITUTION_CHARS = "$`"
_EXPANSION_CHARS = "*?[]{}"
_PUNCT = "();<>|&"

# NOT -a/--all/--amend/--include/--only/--patch, not a bare operand (a pathspec),
# not --no-verify. A message is REQUIRED: bare `git commit` opens core.editor.
_FLAGS_NOARG = frozenset(("-q", "--quiet"))
_FLAGS_ARG = frozenset(("-m", "--message"))

_REGULAR_MODES = frozenset(("000000", "100644", "100755"))

# See the bound in main(): the caller's per-path work must fit a 10s hook timeout.
_MAX_PATHS = 20

# Settings-file read cap (_read_bounded / _settings_inert). A real
# settings.json/settings.local.json is a few KB at most; 256 KiB is
# generous headroom while still refusing a file large enough to make
# json.loads itself slow inside the shared hook budget.
_MAX_SETTINGS_BYTES = 256 * 1024


def _scan_step(cmd, i, quote):
    """One character of the scan. Returns (next_i, quote), or None to refuse."""
    ch = cmd[i]
    if quote == "'":
        return i + 1, ("" if ch == "'" else quote)
    if quote == '"':
        if ch == "\\" and i + 1 < len(cmd):
            return i + 2, quote
        return i + 1, ("" if ch == '"' else quote)
    if ch == "\\":
        return None if i + 1 >= len(cmd) else (i + 2, quote)
    if ch in "'\"":
        return i + 1, ch
    if ch in _EXPANSION_CHARS or ch in _PUNCT:
        return None
    return i + 1, quote


def _scan_ok(cmd):
    """One quote-balanced segment, no live expansion, substitution or operator."""
    if "\n" in cmd or "\r" in cmd:
        return False
    if any(ch in cmd for ch in _SUBSTITUTION_CHARS):
        return False
    quote = ""
    i, n = 0, len(cmd)
    while i < n:
        step = _scan_step(cmd, i, quote)
        if step is None:
            return False
        i, quote = step
    return not quote


def _commit_form_ok(words):
    """`git commit` with only allowlisted options, and a message.

    Token equality, never a regex: `\\b` matches before a hyphen, so
    `git commit-x` — which a repo-local alias can define freely — matched
    `git\\s+commit\\b`.
    """
    if len(words) < 2 or words[0] != "git" or words[1] != "commit":
        return False
    saw_message = False
    i, n = 2, len(words)
    while i < n:
        w = words[i]
        if w in _FLAGS_NOARG:
            i += 1
        elif w in _FLAGS_ARG:
            if i + 1 >= n:
                return False
            saw_message = True
            i += 2                        # the message operand
        elif w.startswith("--message=") or (w.startswith("-m") and len(w) > 2):
            saw_message = True
            i += 1
        else:
            return False
    return saw_message


def _config_get(repo, env, key, as_bool=False):
    """(found, value), or None on any failure — never a default."""
    cmd = ["git", "--no-pager", "-C", repo, "config"]
    if as_bool:
        cmd.append("--type=bool")
    cmd += ["--get", key]
    r = _run(cmd, env=env)
    if r is None:
        return None
    if r.returncode == 1:
        return (False, "")
    if r.returncode != 0:
        return None                       # incl. "not a boolean" under --type=bool
    return (True, r.stdout.decode("utf-8", "surrogateescape").strip())


def _no_configured_programs(repo, env):
    """No config naming a program git could run during the commit.

    core.fsmonitor runs during our own diff and again at commit; the pagers are
    shell-interpreted and pager.commit is read before the builtin is entered;
    `hook.<name>.command` and the gpg keys that NAME a signer program refuse.
    core.editor is excluded (a bare commit
    is already refused) as are clean/smudge filters and textconv, which run at
    `git add` and diff-render time — outside this window.

    fsmonitor is classified by git (`--type=bool`), not by string matching: git
    preserves quoted whitespace, so `" true "` is a PATHNAME that `.strip()` read
    as the safe built-in daemon. A boolean names no program.
    """
    # Keys whose VALUE is a program git will execute. Matched by key name, so
    # `gpg.<format>.program` and any `hook.<name>.command` are covered without
    # enumerating them. Config-based hooks (git 2.36+) run with an EMPTY hooks
    # directory, so the filesystem check below cannot see them.
    #
    # Scoped to program-naming keys ON PURPOSE. An earlier revision refused the
    # whole `gpg.*` namespace and `commit.gpgSign=true`, which disabled the
    # carve-out outright for any operator who signs commits — this machine has
    # `gpg.format=ssh` and `commit.gpgSign=true` — while closing nothing: signing
    # runs `gpg`/`ssh-keygen` from PATH, which is the accepted ambient residual,
    # not a repo-configurable program.
    rx = _run(["git", "--no-pager", "-C", repo, "config",
               "--name-only", "--get-regexp",
               r"^(hook\..*\.command|gpg\.program"
               r"|gpg\..*\.program|gpg\.ssh\.defaultkeycommand)$"], env=env)
    if rx is None:
        return False
    if rx.returncode not in (0, 1):
        return False
    if rx.returncode == 0 and rx.stdout.strip():
        return False

    fm = _config_get(repo, env, "core.fsmonitor")
    if fm is None:
        return False
    if fm[0] and _config_get(repo, env, "core.fsmonitor", as_bool=True) is None:
        return False
    for key in ("core.pager", "pager.commit"):
        got = _config_get(repo, env, key)
        if got is None:
            return False
        found, value = got
        if not found:
            continue
        if value.strip().lower() not in ("false", "off", "no", "0"):
            return False
    return True


def _hooks_dir(repo, env):
    hp = _run(["git", "--no-pager", "-C", repo,
               "rev-parse", "--git-path", "hooks"], env=env)
    if hp is None:
        return None
    if hp.returncode != 0:
        return None
    out = hp.stdout.decode("utf-8", "surrogateescape")
    # Exactly one trailing newline: `rstrip("\\n")` would eat one that is part of
    # a core.hooksPath directory NAME and probe a different directory.
    if not out.endswith("\n") or "\n" in out[:-1] or not out[:-1]:
        return None
    d = out[:-1]
    return d if os.path.isabs(d) else os.path.join(repo, d)


def _hooks_absent(repo):
    """No hook, and no program-naming config, anywhere git might look.

    Not a denylist of hook NAMES — a three-name list missed post-index-change,
    which fires during `git add`. Any non-sample entry refuses.

    Resolved TWICE. sanitized-gate.sh exports GIT_CONFIG_GLOBAL/SYSTEM=/dev/null
    (ADR 0016) while the authorized commit runs with the operator's real config,
    so a global core.hooksPath is invisible here and live there. The second pass
    drops those two vars; `rev-parse --git-path` under --no-pager runs no helper,
    alias or pager. Declining to look is the fail-OPEN direction.

    Git's default global file is `$XDG_CONFIG_HOME/git/config` (falling back to
    `$HOME/.config/git/config`), read alongside `~/.gitconfig`. `env -i`
    (ADR 0016) strips XDG_CONFIG_HOME before this process starts, so an operator
    whose XDG_CONFIG_HOME diverges from `$HOME/.config` would have a real
    core.hooksPath the second pass could never see — hooks.json now re-imports
    it (empty when absent, which git treats identically to unset) specifically
    for this gate, so os.environ already carries the real value here; both
    passes inherit it, and GIT_CONFIG_GLOBAL=/dev/null still makes the FIRST
    pass (and every other gate's git calls) blind to it regardless. This does
    not close the gap for a Claude session launched outside the shell where
    XDG_CONFIG_HOME is set (ADR 0044) — see that ADR's environment-residual note.

    The second pass's HOME has the SAME gap, one layer up: sanitized-gate.sh
    deliberately substitutes a passwd-derived HOME for its own subprocess calls
    (defense against a poisoned HOME feeding an evil ~/.gitconfig to THIS
    process), but the authorized `git commit` that runs right after this gate
    approves is a *different* process — it inherits the launching session's
    ORIGINAL HOME, never the substitution. When the two diverge, `~/.gitconfig`
    at the real HOME could carry a live core.hooksPath this pass, reading under
    the passwd HOME, never sees. hooks.json re-imports the pre-substitution
    value as BUSDRIVER_ORIG_HOME (mirroring the XDG_CONFIG_HOME import; that
    name is untouched by sanitized-gate.sh's own HOME override, so it survives),
    and this pass overrides HOME with it before resolving config — checking the
    SAME effective global config the real commit will read, not the wrapper's
    defensive stand-in. A repo cannot steer this value: `_settings_inert` above
    already refuses any settings.json `env` block before this ever runs, so the
    only source left is the operator's own ambient session — exactly what the
    real commit inherits too, so resolving under it is checking ground truth,
    not trusting an attacker-supplied one. Reported by Codex on PR #697,
    reproduced.

    Re-importing ANY variable into a `env -i` gate deserves the obvious
    objection, so state the answer: XDG_CONFIG_HOME and BUSDRIVER_ORIG_HOME are
    repo-injectable (a committed settings.json `env` block is exactly ADR
    0016's threat). Both are safe on THIS path for two reasons, both checked
    rather than assumed. (1) The tool whose config XDG would otherwise steer is
    `gh` — the spoofed `~/.config/gh` that sanitized-gate.sh names as its
    bounded residual — and `pre-commit-gate.sh` invokes `gh` nowhere on this
    path (the only matches in it and its sourced libs are comments); a poisoned
    BUSDRIVER_ORIG_HOME reaches the same tools a poisoned HOME already does,
    closed the same way. (2) For git, every knob a hostile config could set
    that this helper reads — core.hooksPath, core.pager, core.fsmonitor,
    hook.<name>.command, gpg.*.program — makes it REFUSE. A repo can therefore
    use either variable to deny itself the carve-out, which is the pre-#685
    behaviour, and cannot use either to obtain one.
    """
    envs = [dict(os.environ)]
    unsanitized = dict(os.environ)
    for k in ("GIT_CONFIG_GLOBAL", "GIT_CONFIG_SYSTEM"):
        unsanitized.pop(k, None)
    orig_home = os.environ.get("BUSDRIVER_ORIG_HOME", "")
    if orig_home:
        # isdir() stats a path this process did not choose; bound it for the same
        # reason as every other filesystem touch here.
        try:
            with _alarm_bound():
                is_dir = os.path.isdir(orig_home)
        except (OSError, _ReadTimeout):
            return False
        if is_dir:
            unsanitized["HOME"] = orig_home
    if unsanitized != envs[0]:
        envs.append(unsanitized)
    for env in envs:
        if not _no_configured_programs(repo, env):
            return False
        hooks_dir = _hooks_dir(repo, env)
        if hooks_dir is None:
            return False
        # Bound by the shared deadline: a huge or stalled `core.hooksPath`
        # directory (a tracked `.githooks` tree, or a stalled mount) can make
        # os.listdir() hang or run long outside every other call's bound in
        # this module. Unbounded here is a bypass, not a stall: the 10s
        # PreToolUse timeout emits NO decision on expiry, which the harness
        # reads as ALLOW (Codex, PR #697).
        try:
            with _alarm_bound():
                entries = os.listdir(hooks_dir)
        except FileNotFoundError:
            continue
        except (_ReadTimeout, OSError):
            return False
        if any(not e.endswith(".sample") for e in entries):
            return False
    return True


def _staged_paths(repo):
    """Staged paths, or None to refuse.

    `--raw` carries BOTH modes, so one call answers "what is staged" and "is
    every side a regular blob". The caller judges these by NAME while resolving
    the WORKING-TREE path, so a symlink (120000) or gitlink (160000) in the index
    would be vouched for by a file git is not committing; checking only the NEW
    mode let a staged DELETION — no index entry at all — skip the check.
    `--no-renames`: with detection on, a staged src/impl.py -> docs/plans/x.md
    reports only the destination and reads as a lone document.
    """
    r = _run(["git", "--no-pager", "-C", repo, "diff", "--cached",
              "--raw", "--no-renames", "--no-ext-diff", "-z"])
    if r is None:
        return None
    if r.returncode != 0:
        return None
    fields = r.stdout.decode("utf-8", "surrogateescape").split("\0")
    paths, i = [], 0
    while i < len(fields):
        meta = fields[i]
        if not meta:
            i += 1
            continue
        if not meta.startswith(":") or i + 1 >= len(fields):
            return None
        parts = meta[1:].split()
        if len(parts) < 5:
            return None
        if parts[0] not in _REGULAR_MODES or parts[1] not in _REGULAR_MODES:
            return None
        path = fields[i + 1]
        # The caller reads this list line by line, so a name carrying a line
        # break would split into two paths and could present an all-docs face.
        if not path or "\n" in path or "\r" in path:
            return None
        paths.append(path)
        i += 2
    return paths


def _settings_inert(repo, state_dir):
    """No in-repo settings file declaring `env` or `hooks`.

    Claude Code merges a committed settings file into the session the commit runs
    in (ADR 0016): an `env` block can supply GIT_INDEX_FILE/GIT_DIR, and a `hooks`
    block registers a PreToolUse hook that can rewrite the approved command via
    `updatedInput` or restage after the index sample. Both are repo-controlled and
    live from CHECKOUT, not from being committed, so both refuse here — as do
    `enabledPlugins`/`extraKnownMarketplaces`, which reach the same capability by
    activating a plugin whose manifest registers the hook. Any `env` at all — an
    allowlist would have to track every variable git and sh read.

    Checked in BOTH `state_dir` and `.claude`, deduplicated when they resolve to
    the same directory: `state_dir` is the caller's own bookkeeping location
    (`BUSDRIVER_STATE_DIR`, always `.claude` on the sole production call path —
    sanitized-gate.sh's `env -i` strips that var before this ever runs), but
    Claude Code itself always merges `<repo>/.claude/settings*.json` into the
    session regardless of that override. Checking only `state_dir` would miss
    `.claude` on any caller that legitimately overrides it.
    """
    dirs = {os.path.join(repo, state_dir), os.path.join(repo, ".claude")}
    for d in dirs:
        for name in ("settings.json", "settings.local.json"):
            path = os.path.join(d, name)
            # O_NONBLOCK: a FIFO planted at this path passes os.path.exists()
            # and a plain blocking open(path, "rb") hangs until a writer
            # connects — and this gate runs under a 10s PreToolUse timeout
            # whose expiry emits NO decision, which the harness reads as
            # allow (see main()'s comment on the path-count bound). A hang
            # here is therefore a bypass, not just a stall. O_NONBLOCK makes
            # the open return immediately regardless of file type; the fstat
            # below then refuses anything that isn't a plain regular file
            # BEFORE any read is attempted.
            try:
                with _alarm_bound():
                    try:
                        fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
                    except FileNotFoundError:
                        continue
                    except OSError:
                        return False
                    with os.fdopen(fd, "rb") as fh:
                        if not stat.S_ISREG(os.fstat(fh.fileno()).st_mode):
                            return False
                        # The fstat only rules out FIFOs/devices; a large or
                        # slow REGULAR file still needs the size cap, and the
                        # enclosing _alarm_bound supplies the wall-time one.
                        raw = _read_bounded(fh, _MAX_SETTINGS_BYTES)
                        if raw is None:
                            return False
                        data = json.loads(raw.decode("utf-8", "surrogateescape"))
            except Exception:
                return False
            if not isinstance(data, dict):
                return False
            # `hooks` registers a PreToolUse hook directly; `enabledPlugins` and
            # `extraKnownMarketplaces` do it indirectly, by activating a plugin
            # whose manifest carries one. All three reach the same capability.
            for key in ("env", "hooks", "enabledPlugins", "extraKnownMarketplaces"):
                if data.get(key):
                    return False
    return True


def main(argv):
    if len(argv) != 3:
        return 1
    repo, hook_cwd, state_dir = argv
    if (not state_dir or os.path.isabs(state_dir)
            or ".." in state_dir.split("/") or state_dir == "."):
        return 1
    # Nothing here is cwd-relative, so this is not load-bearing; it is kept
    # because it is free and a commit from elsewhere is not the docs-loop shape.
    # Bounded like every other filesystem touch in this module: realpath walks
    # the path on disk, so a stalled mount hangs it, and a hang here is a bypass
    # (the 10s hook timeout emits no decision, which the harness reads as allow).
    try:
        with _alarm_bound():
            if not hook_cwd or os.path.realpath(hook_cwd) != os.path.realpath(repo):
                return 1
    except (OSError, _ReadTimeout):
        return 1

    try:
        d = json.load(sys.stdin)
        inp = d.get("tool_input", d.get("toolInput", {}))
        if isinstance(inp, str):
            inp = json.loads(inp)
        cmd = inp.get("command", "") if isinstance(inp, dict) else ""
    except Exception:
        return 1
    if not isinstance(cmd, str) or not cmd.strip():
        return 1

    if not _scan_ok(cmd):
        return 1
    try:
        words = shlex.split(cmd)
    except ValueError:
        return 1
    if not _commit_form_ok(words):
        return 1
    # ORDER IS LOAD-BEARING. _settings_inert refuses the repo whose settings file
    # can inject env into this very session (XDG_CONFIG_HOME among them), so it
    # must run BEFORE _hooks_absent, which reads git config under that injected
    # environment. Reversed, a hostile XDG config gets to hang git — and hanging
    # is a bypass here, not a stall — before the check that would have refused
    # the repo ever ran.
    if not _settings_inert(repo, state_dir):
        return 1
    if not _hooks_absent(repo):
        return 1

    paths = _staged_paths(repo)
    if not paths:
        return 1
    # The caller runs the design-doc predicate PER PATH, and each one forks
    # python3 + git. The pre-commit hook is registered with a 10-SECOND timeout,
    # and a timed-out PreToolUse hook emits NO decision — which the harness reads
    # as allow, i.e. a commit past BOTH review gates. So the set is bounded here,
    # fail-CLOSED: too many paths refuses rather than risking the timeout. 20
    # matches the classifier's own record budget (marker_ops.K) and is far above
    # any documentation remediation commit.
    if len(paths) > _MAX_PATHS:
        return 1
    sys.stdout.write("\n".join(paths) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
