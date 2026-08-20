'use strict';
/**
 * GateGuard consent resolution — issue #616.
 *
 * Consent lives OUT of the repository namespace, under the operator's passwd-derived
 * home:
 *
 *     <passwd-HOME>/.gateguard/enabled/<sha256(realpath(main-worktree))>
 *
 * A pull request against a gated repository is a set of files tracked by that
 * repository, and in the ordinary case it cannot create, delete or modify anything under
 * the operator's passwd home. That is the whole of the protection.
 *
 * The word "ordinary" is load-bearing and an earlier version of this header omitted it,
 * stating the guarantee as absolute. It is not: when the gated repository IS the passwd
 * home (dotfiles-as-worktree), `.gateguard` falls inside the repository's own namespace and
 * a tracked deletion can remove a marker. The threat model records that residual; a header
 * claiming more than the design delivers is the same defect this module exists to remove.
 * See docs/plans/2026-08-13-gateguard-location-authenticated-optin.md.
 *
 * THE ONE RULE THIS FILE EXISTS TO ENFORCE: the home comes from `os.userInfo().homedir`
 * — never the HOME environment variable, and never the `os` module's home-directory
 * convenience call. On POSIX that convenience call returns $HOME when set and only falls
 * back to the passwd entry otherwise, so it is exactly the injectable channel this design
 * removes. Measured:
 *
 *     HOME=/tmp/evilhome node -e 'console.log(os.userInfo().homedir)'  -> /Users/<real>
 *     HOME=/tmp/evilhome node -e 'console.log(process.-env.HOME)'      -> /tmp/evilhome
 *                                          (hyphen inserted — see below)
 *
 * The repo's dominant idiom is the worse form still (14 sites under scripts/ read the env
 * var and fall back to the convenience call), so an implementer reaching for the house
 * pattern lands on the defect.
 *
 * NOTE ON THIS COMMENT'S SPELLING: neither forbidden token appears here verbatim, and the
 * hyphen above is deliberate. V16 greps this file for the literal strings, so the
 * invariant "this file contains no environment read and no home-convenience call" stays
 * MECHANICALLY checkable — a greppable absence rather than an enumeration to keep
 * correct. A comment that names the token defeats its own guard.
 *
 * Read-only on the consent path: nothing isEnabled() touches creates anything.
 * ensureDirNoFollow() is the one creating primitive and is never reached from
 * isEnabled() — only from the hook's saveState(), from the manual enrollment procedure
 * in skills/gateguard/SKILL.md, and from the test fixtures.
 */

const fs = require('fs');
const os = require('os');
const path = require('path');
const { createHash } = require('crypto');
const { execFileSync } = require('child_process');

/** Marker filenames are lowercase sha256 hex, and nothing else counts as a marker. */
const MARKER_RE = /^[0-9a-f]{64}$/;

/**
 * Immutable half of the git child's environment. HOME is NOT here — see gitEnv().
 *
 * Every GIT_* discovery, config and exec variable is absent because it was never
 * copied: absence by construction, not by enumeration (an enumerated unset list missed
 * five variables in an earlier round). GIT_CONFIG_GLOBAL/SYSTEM are pinned to /dev/null
 * rather than unset, matching sanitized-node.sh:53-54 and diverging deliberately from
 * advisory-downgrade-optin.sh:38-40, which unsets them — inside a contained child that
 * would re-enable ~/.gitconfig. LC_ALL=C is load-bearing, not hygiene: classifyGitError()
 * matches git's English "not a git repository" on stderr, and without the pin that holds
 * only accidentally, because the whitelist happens to omit locale variables.
 */
const GIT_ENV_BASE = Object.freeze({
  PATH: '/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin',
  GIT_CONFIG_GLOBAL: '/dev/null',
  GIT_CONFIG_SYSTEM: '/dev/null',
  LC_ALL: 'C',
});

/**
 * The operator's passwd home.
 *
 * `os.userInfo` is read at CALL time and never destructured or cached at module load.
 * That is what lets a test substitute a temp home by patching the `os` module object
 * before requiring — a test-side substitution of a stdlib call, not a seam the hook
 * exposes. It is also why gitEnv() is a factory: a module-scope constant holding
 * `HOME: homeDir()` would throw during require() on a machine with no usable passwd
 * entry, and run-with-flags.js:280-284 catches a failed require and falls through to the
 * legacy spawn path, which for a hook exporting run() with no main() is a pass-through
 * allow. The totality below would be bypassed by the constant that was meant to support
 * it.
 *
 * Throws unless the value is an absolute string: a passwd entry with an empty or
 * relative pw_dir returns happily, and path.join('', '.gateguard') is the RELATIVE
 * '.gateguard', which resolves against whatever cwd the process holds — '/' under the
 * wrapper, but '<repo>/.gateguard' for any uncontained caller. That is simultaneously
 * the contained/uncontained split this design removes and an in-repository marker, the
 * polarity trap the design rejects.
 */
function homeDir() {
  const home = os.userInfo().homedir;
  if (typeof home !== 'string' || !path.isAbsolute(home)) {
    throw new Error(`unusable passwd home: ${JSON.stringify(home)}`);
  }
  return home;
}

function gateguardRoot() {
  return path.join(homeDir(), '.gateguard');
}

function enabledDir() {
  return path.join(gateguardRoot(), 'enabled');
}

/** The five-key positively-constructed child environment. HOME resolved at call time. */
function gitEnv() {
  return { ...GIT_ENV_BASE, HOME: homeDir() };
}

/**
 * lstat ONE component and throw unless it is a real, non-symlink directory.
 * Never recursive: a caller preparing a two-level path calls it once per level.
 */
function assertDirNoFollow(dir) {
  const st = fs.lstatSync(dir); // throws ENOENT/EACCES to the caller
  if (st.isSymbolicLink()) throw new Error(`refusing symlink: ${dir}`);
  if (!st.isDirectory()) throw new Error(`not a directory: ${dir}`);
}

/**
 * Three-way lstat state machine over ONE component.
 *
 *   1. ENOENT             -> non-recursive mkdir, then re-assert (loses a
 *                            create-versus-symlink race rather than trusting the create)
 *   2. real directory     -> do nothing and proceed
 *   3. symlink / non-dir  -> throw; the caller does not write into the target
 *
 * It must be a state machine and not "assert, then create": a bare assertion throws
 * ENOENT on a fresh machine and on every CI runner, while an unconditional create throws
 * EEXIST on the dominant path, because <root> already exists on any machine that has run
 * GateGuard (state files have always lived there). Either throw reaches saveState()'s
 * catch and lands the call on allowWithStateWarning() — an enabled-looking gate that
 * warns and allows every call.
 *
 * Never `recursive`: a recursive create runs BEFORE any refusal could fire and would
 * follow a pre-existing `.gateguard` symlink into its target.
 *
 * `mode` applies only to a directory this call creates — it does not repair the mode of
 * one that already exists, and it is masked by the process umask, so it is a ceiling.
 */
function ensureDirNoFollow(dir, mode) {
  // THE PARENT IS VALIDATED ON EVERY PATH, not only when creating. `lstat()` does not follow
  // the FINAL component, but it DOES follow intermediate ones. So when the parent is a symlink
  // whose target ALREADY contains `dir`, `lstat(dir)` resolves through the link and reports a
  // real, non-symlink directory — the "already exists, proceed" branch below accepts it and
  // every later write lands inside the link's target. Verified directly: lstat of
  // `<symlinked-root>/enabled` returns isDirectory() true and isSymbolicLink() false.
  //
  // An earlier version checked the parent only inside the ENOENT arm. That closed the
  // create-through-a-link case and left the already-exists case open — the more dangerous
  // half, since it needs no race, only a pre-existing directory under the link target.
  //
  // The passwd home stays EXEMPT, and that exemption is load-bearing: on hosts whose home is
  // itself a symlink (/home/u -> /mnt/u) an unconditional check would refuse to create <root>
  // at all, so every state write would fail and each gated call of an enrolled operator would
  // land on allowWithStateWarning(). The home is this design's trust ANCHOR, not a boundary it
  // defends; what must never be followed is a symlink at or below <root>.
  // path.resolve() on BOTH sides, because the comparison is between a dirname()-normalized
  // string and a raw passwd field. A passwd home recorded with a trailing separator
  // ("/home/u/") never equals dirname()'s "/home/u", so the exemption would miss and
  // assertDirNoFollow() would reject the very symlinked home the exemption exists to allow --
  // enrolment fails and every state write of an enrolled operator lands on
  // allowWithStateWarning(). resolve() normalizes separators WITHOUT resolving symlinks
  // (that is realpath), so it cannot launder a symlink into passing the check below.
  const parent = path.dirname(dir);
  // Neither operand is user input: `parent` is dirname() of a path this module built, and
  // homeDir() is the passwd field. resolve() is used ONLY to normalize separators for the
  // string comparison below -- its result is never opened, joined onto, or returned.
  // nosemgrep
  if (parent !== dir && path.resolve(parent) !== path.resolve(homeDir())) {
    assertDirNoFollow(parent);
  }

  let st;
  try {
    st = fs.lstatSync(dir);
  } catch (err) {
    if (err && err.code === 'ENOENT') {
      fs.mkdirSync(dir, { mode });
      assertDirNoFollow(dir);
      return;
    }
    throw err;
  }
  if (st.isSymbolicLink()) throw new Error(`refusing symlink: ${dir}`);
  if (!st.isDirectory()) throw new Error(`not a directory: ${dir}`);
}

/**
 * No-spawn fast path. Returns exactly one of 'present' | 'absent' | 'unreadable'.
 *
 * A MARKER predicate, not a directory predicate: a directory predicate would leave an
 * empty enabled/ spawning git forever after the last marker is removed, and removal
 * leaves enabled/ in place.
 *
 * 'unreadable' covers both an EACCES/ELOOP/type-wrong ancestor AND the case where
 * hex-named entries exist and every one of them is type-invalid — the operator enrolled
 * something this process cannot use, and they should learn that rather than be silently
 * ungated. Only 'present' proceeds to the git spawn.
 *
 * Machine-global by design: a per-repo fast path would need the hash, which needs the
 * spawn it exists to avoid. So the no-spawn state is "zero markers anywhere".
 */
function anyMarkerPresent() {
  let entries;
  try {
    assertDirNoFollow(gateguardRoot());
    assertDirNoFollow(enabledDir());
    entries = fs.readdirSync(enabledDir());
  } catch (err) {
    if (err && err.code === 'ENOENT') return 'absent';
    return 'unreadable';
  }

  const hexNamed = entries.filter((name) => MARKER_RE.test(name));
  if (hexNamed.length === 0) return 'absent';

  for (const name of hexNamed) {
    try {
      const st = fs.lstatSync(path.join(enabledDir(), name));
      if (st.isFile()) return 'present';
    } catch {
      // fall through — an entry that vanished or cannot be stat'd is not a marker
    }
  }
  // Hex-named entries exist and none is a usable marker.
  return 'unreadable';
}

/** Classify an execFileSync failure into 'absent' (not applicable) or 'error' (a fault). */
function classifyGitError(err) {
  const stderr = err && err.stderr ? String(err.stderr) : '';
  // FIRST LINE ONLY, and anchored. An unanchored search of the whole stderr is forgeable HERE
  // specifically, because this design deliberately supports repository paths containing
  // newlines (it is why the resolver uses `--porcelain -z`): a directory whose name embeds
  // "\nfatal: not a git repository" would appear inside some OTHER status-128 message that
  // echoes the path -- dubious ownership, say -- and be misread as 'absent', which silently
  // switches the gate off instead of reporting the fault. git always writes its own "fatal: "
  // prefix at the start of the first line, so nothing an attacker controls can reach it.
  // Anything unrecognized falls through to 'error', which is the safe direction: 'error'
  // surfaces a diagnostic, 'absent' is silent.
  const firstLine = stderr.split('\n', 1)[0].trim();
  if (err && err.status === 128 && /^fatal: not a git repository\b/i.test(firstLine)) return 'absent';
  return 'error';
}

/**
 * The MAIN worktree for `cwd` — the first `worktree ` record of the porcelain listing.
 *
 * NOT `git rev-parse --show-toplevel`: this repo develops in linked worktrees under
 * .claude/worktrees/, and --show-toplevel would key each worktree to a different
 * identity. Verified from a linked worktree, the first record is the main checkout.
 *
 * `--porcelain -z` (NUL-delimited), matching scripts/design-clear.sh:300-309 which uses
 * it unconditionally — which also settles the version floor in-tree. git-worktree(1)
 * scopes C-quoting to the LOCK REASON, and the git 2.36.0 release notes introduce -z
 * precisely because plain --porcelain "did not c-quote pathnames correctly", so a
 * `worktree "` refusal branch would be a guard whose failure branch can never fire.
 *
 * stderr is PIPED, not discarded: classifyGitError() reads it to separate "not a
 * repository" from a genuine fault. It is never echoed.
 *
 * Re-entering the repo cwd is deliberate. sanitized-node.sh:111-121 does `cd /` to stop a
 * repo-dropped .tool-versions/.nvmrc/package.json/mise file steering a version-manager
 * NODE shim. A git child on a fixed trusted PATH is not that: git reads repo-local
 * .git/config, which is not a tracked file a PR can write, and global/system config are
 * pinned at /dev/null.
 *
 * Throws on failure; callers classify.
 */
function mainWorktree(cwd) {
  const out = execFileSync('git', ['worktree', 'list', '--porcelain', '-z'], {
    cwd,
    encoding: 'utf8',
    timeout: 2000,
    maxBuffer: 1 << 20,
    stdio: ['ignore', 'pipe', 'pipe'],
    env: gitEnv(),
  });
  for (const field of out.split('\0')) {
    if (field.startsWith('worktree ')) return field.slice('worktree '.length);
  }
  throw new Error('no worktree record in porcelain output');
}

/**
 * One resolution, every field read from the one result — main worktree, its realpath,
 * the hash, the marker path. Callers must not re-run mainWorktree()/realpathSync just to
 * print an audit line: that resolves the same identity twice and admits a window where
 * the two disagree.
 *
 * The digest is over the REALPATH, and the marker's contents record that same realpath so
 * the two agree. Hashed as the UTF-8 encoding of that string, no trailing newline.
 */
function resolveIdentity(cwd) {
  const mw = mainWorktree(cwd);
  const real = fs.realpathSync(mw);
  const hash = createHash('sha256').update(real, 'utf8').digest('hex');
  // Assert the digest's shape before it becomes a path component. `digest('hex')` cannot
  // produce anything but 64 lowercase hex characters, so this is not defending against a
  // reachable traversal — `real` never reaches the filename, only its hash does. It is here
  // because a path component derived from a variable is worth proving inert rather than
  // asserting inert, and because the same regex is the marker-name contract everywhere else
  // in this file (MARKER_RE). If a future change ever fed something else in here, this throws
  // instead of composing a path outside `enabledDir()`.
  if (!MARKER_RE.test(hash)) {
    throw new Error(`refusing a non-hex marker name: ${JSON.stringify(hash)}`);
  }
  // The path-traversal rule below is syntactic — it flags any non-literal path component.
  // Here the component is `hash`, a locally computed sha256 digest, not caller input: `cwd`
  // reaches `mainWorktree()` and `realpathSync()` but never the filename. The `MARKER_RE`
  // assertion directly above proves the component is 64 lowercase hex characters before this
  // line runs, so no `..`, no separator and no absolute path can occur. Suppressed by rule id
  // with this reasoning rather than by weakening the code or dropping the check.
  // nosemgrep
  return { mainWorktree: mw, realpath: real, hash, markerPath: path.join(enabledDir(), hash) };
}

function markerPath(cwd) {
  return resolveIdentity(cwd).markerPath;
}

/**
 * Is GateGuard enabled for the repository containing `cwd`?
 *
 * ALWAYS returns the structured result, never a bare boolean — a boolean cannot carry the
 * distinction the diagnostic depends on: 'absent' must stay silent while 'error' must be
 * reported. NEVER throws: a spawn error, non-zero status, signal, timeout, missing
 * worktree record, realpath failure, os.userInfo() failure or an unusable homedir all
 * resolve to { enabled: false } with the status distinguishing them.
 *
 *   'enabled'  — a valid marker for this repo exists
 *   'absent'   — expected not-applicable, and SILENT: no marker, <root> or enabled/
 *                missing (ENOENT), a non-absolute cwd, or a cwd that is not a git
 *                repository. ENOENT matters because "<root> present, enabled/ absent" is
 *                the dominant state on every machine that has ever run GateGuard, and
 *                folding it into 'error' would emit a line on every gated call for every
 *                unenrolled operator.
 *   'error'    — a genuine fault: an unreadable or type-wrong ancestor, a git spawn
 *                failure or timeout, a realpath failure, an underivable passwd home.
 *                THE ONLY status that produces a stderr line, and the CALLER writes it.
 *
 * Totality is load-bearing, but not because a throw would exit 2: failOpenExitCode()
 * (run-with-flags.js:116-118) is `argv.includes('--fail-closed') ? 2 : 0`, and GateGuard
 * is the open disposition, so a throw exits 0. The real reasons are that an uncaught
 * throw skips this diagnostic, skips the rawInput echo (changing the allow shape), and
 * crashes any test calling run() directly. Do NOT re-add --fail-closed to GateGuard to
 * make an older sentence true — that recreates the unenrolled oversized-payload hard
 * block steps 1 and 5(e) exist to remove.
 */
function isEnabled(cwd) {
  if (typeof cwd !== 'string' || !path.isAbsolute(cwd)) {
    return { enabled: false, status: 'absent', cause: 'payload cwd not absolute' };
  }

  // Resolve the home FIRST so its failure is reported as its own fault. Without this the
  // throw surfaces from inside anyMarkerPresent()'s catch-all as 'marker directory
  // unreadable', which names the wrong subsystem: on a host with no usable passwd entry
  // there is no marker directory to be unreadable, and the operator is sent to check
  // permissions on a path that was never computed.
  try {
    homeDir();
  } catch (err) {
    return { enabled: false, status: 'error', cause: `passwd home unusable: ${err.message}` };
  }

  let presence;
  try {
    presence = anyMarkerPresent();
  } catch (err) {
    return { enabled: false, status: 'error', cause: `marker scan failed: ${err.message}` };
  }
  if (presence === 'absent') return { enabled: false, status: 'absent', cause: 'no markers' };
  if (presence === 'unreadable') {
    return { enabled: false, status: 'error', cause: 'marker directory unreadable' };
  }

  let identity;
  try {
    identity = resolveIdentity(cwd);
  } catch (err) {
    const status = classifyGitError(err);
    return {
      enabled: false,
      status,
      cause: status === 'absent' ? 'not a git repository' : `identity unresolvable: ${err.message}`,
    };
  }

  try {
    const st = fs.lstatSync(identity.markerPath);
    if (!st.isFile()) {
      return { enabled: false, status: 'error', cause: 'marker is not a regular file' };
    }
  } catch (err) {
    if (err && err.code === 'ENOENT') {
      return { enabled: false, status: 'absent', cause: 'repository not enrolled' };
    }
    return { enabled: false, status: 'error', cause: `marker unreadable: ${err.message}` };
  }

  return { enabled: true, status: 'enabled' };
}

module.exports = {
  homeDir,
  gateguardRoot,
  enabledDir,
  gitEnv,
  assertDirNoFollow,
  ensureDirNoFollow,
  anyMarkerPresent,
  mainWorktree,
  resolveIdentity,
  markerPath,
  isEnabled,
};
