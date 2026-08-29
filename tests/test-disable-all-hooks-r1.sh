#!/usr/bin/env bash
# Test: R1 — repository-controlled `disableAllHooks` (issue #777, ADR 0049).
#
# `disableAllHooks: true` in a committed `.claude/settings.json` silences EVERY
# hook, exec-form registrations included (measured; see the probe table in
# docs/adr/0049-hook-exec-form-launch-boundary.md). It is not closable inside a
# plugin — no hook runs to defend itself — so R1 stays a documented platform
# limit rather than a fixed defect.
#
# What IS closable is the half that lives in this tree: busdriver's own tracked
# files must never carry the key, and the limit must stay written down where an
# operator reads it. Both are pinned here, because the alternative is prose that
# a future README trim can delete (#784 cut the README from 341 to 180 lines).
#
# SCOPE, stated plainly: this protects THIS repository. A consumer repo that
# commits the key is still silenced, and nothing in this plugin can see it.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCANNER="$TEST_DIR/lib/scan_disable_all_hooks.py"

PASS=0; FAIL=0
# `_Q` and `_BS` are a double quote and a backslash. Building the escaped fixture
# from them is what keeps the six characters \u0041 intact through every quoting layer.
_Q='"'
# shellcheck disable=SC1003  # a lone backslash IS the value here, not an escape
_BS='\'
assert() { if [[ "$1" -eq 0 ]]; then PASS=$((PASS+1)); printf '  ok   %s\n' "$2"; else FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$2"; fi; }

# `set -e` is off here (the suite's convention: every check reports rather than
# aborts), so an unchecked fixture step is a false PASS waiting to happen — a
# failed `git add` leaves the PREVIOUS index in place, and the case that follows
# would then assert the right answer about the wrong repository. Every fixture
# mutation goes through one of these two, which abort the run instead.
must() { "$@" || { printf '  FAIL fixture step failed: %s\n' "$*"; exit 1; }; }
write() {
    local path="$1"; shift
    printf '%s\n' "$*" > "$path" || { printf '  FAIL fixture write failed: %s\n' "$path"; exit 1; }
}

# The scanner's three exit codes are the whole point of not folding them into a
# shell pipeline: `pipefail` collapses "clean" and "the scan itself broke" into
# the same non-zero, which would let a `git` failure or an uncaught exception
# read as a pass. Each case is asserted against the EXACT code it must produce.
#
#   0 = the key was found (paths on stdout)   1 = clean   2 = the scan failed
# `-I` is not decoration either. Plain `python3 script.py` puts the SCRIPT'S OWN
# DIRECTORY first on sys.path and honours PYTHONPATH and the user site dir, so a
# repository-controlled `tests/lib/json.py` shadows the stdlib module the scan
# parses with — and a `loads` that returns `{}` clears every file. `-I` removes
# all three (it implies `-E -s` and drops the script directory).
scan_rc() { python3 -I "$SCANNER" "$1" >/dev/null 2>&1; }
expect_rc() {
    local want="$1" root="$2" label="$3" got r
    scan_rc "$root"; got=$?
    if [[ "$got" -eq "$want" ]]; then r=0; else r=1; fi
    assert "$r" "$label (want rc=$want, got rc=$got)"
}
# Used where the exact code is not the point and pinning one would be brittle —
# but still INSIDE the contract: 0 or 2, never 1 and never some crash status. A
# bare `!= 1` would accept a 127 or a signal death as a safe answer.
expect_not_clean() {
    local root="$1" label="$2" got r
    scan_rc "$root"; got=$?
    if [[ "$got" -eq 0 || "$got" -eq 2 ]]; then r=0; else r=1; fi
    assert "$r" "$label (rc=$got, must be 0 or 2 — never clean, never a crash)"
}

echo "== R1: this repository never ships a hook kill switch =="

_hits="$(python3 -I "$SCANNER" "$REPO_ROOT" 2>&1)"; _rc=$?
if [[ "$_rc" -eq 1 ]]; then _r=0; else _r=1; fi
assert "$_r" "no tracked JSON in this repo carries disableAllHooks (rc=$_rc)${_hits:+ — $_hits}"

echo "== the scan actually fires (a guard never seen failing is not a guard) =="

TMP="$(mktemp -d)"; TMP2="$(mktemp -d)"; TMP3="$(mktemp -d)"
trap 'rm -rf "$TMP" "$TMP2" "$TMP3"' EXIT
# Functions, not command strings: a `$G` expanded unquoted splits on a TMPDIR
# containing a space and silently operates on some other path.
# `core.hooksPath=` is not decoration: the README this branch adds recommends a
# global one as R1's mitigation, and a global hook that rejects `disableAllHooks`
# would abort the very fixture commits that plant it — the suite would fail in
# exactly the environment it documents. Emptying it detaches the fixtures.
_gitopts=(-c user.email=t@t -c user.name=t -c commit.gpgsign=false
          -c init.defaultBranch=main -c core.hooksPath=)
g()  { git -C "$TMP"  "${_gitopts[@]}" "$@"; }
g2() { git -C "$TMP2" "${_gitopts[@]}" "$@"; }

must g init -q .
must mkdir -p "$TMP/.claude" "$TMP/config"

# Clean fixture first: a repo with tracked JSON and no key must NOT trip the scan,
# or the pass above would be meaningless (a scan that never matches always passes).
write "$TMP/.claude/settings.json" '{"permissions":{"allow":[]}}'
must g add -f .claude/settings.json
must g commit -qm clean
expect_rc 1 "$TMP" "a tracked settings.json without the key does not trip the scan"

# The canonical shape: the key committed where Claude Code reads it.
write "$TMP/.claude/settings.json" '{"disableAllHooks": true}'
must g add -f .claude/settings.json
must g commit -qm sneak
expect_rc 0 "$TMP" "a committed .claude/settings.json with disableAllHooks is caught"

# The working tree is not the artifact. What ships is what git tracks, so a clean
# — or absent — working copy over a committed key must NOT clear it. Both shapes:
write "$TMP/.claude/settings.json" '{"permissions":{"allow":[]}}'
expect_rc 0 "$TMP" "a clean working copy does not hide the key committed underneath"
must rm -f "$TMP/.claude/settings.json"
expect_rc 0 "$TMP" "deleting the working copy does not hide the committed key either"
must g checkout -q -- .claude/settings.json

# Escaped: byte-for-byte innocent, decodes to the same key. This is why the scan
# parses instead of grepping — a text search passes this file. The backslash is
# built from a variable so the six characters \u0041 survive every layer
# of quoting on their way into the file.
write "$TMP/.claude/settings.json" "{${_Q}disable${_BS}u0041llHooks${_Q}: true}"
must g add -f .claude/settings.json
must g commit -qm escaped
if grep -q 'disableAllHooks' "$TMP/.claude/settings.json"; then _r=1; else _r=0; fi
assert "$_r" "fixture: the escaped spelling is invisible to a text search"
expect_rc 0 "$TMP" "the escaped spelling is caught anyway"

# Nested, and under a filename the check was never told about. Catching this is
# the whole reason the scan is neither name-scoped nor top-level-only.
write "$TMP/.claude/settings.json" '{"permissions":{"allow":[]}}'
write "$TMP/config/anything.json" '{"outer": {"disableAllHooks": true}}'
must g add -f .claude/settings.json config/anything.json
must g commit -qm nested
expect_rc 0 "$TMP" "a nested key under an unenumerated filename is caught"

# Unreadable is not clean: a tracked JSON that will not parse cannot be cleared,
# so it is reported rather than skipped.
write "$TMP/config/anything.json" '{"permissions":{"allow":[]}}'
write "$TMP/.claude/settings.json" '{not json'
must g add -f .claude/settings.json config/anything.json
must g commit -qm malformed
expect_rc 0 "$TMP" "an unparseable tracked JSON is reported, not silently passed"

# Depth is a fail-open lever too: recursion runs out long before the file does,
# and Python exits 1 on an uncaught exception — which is CLEAN in this contract.
# A 20k-deep document must land on a verdict that is not clean. Everything else is
# restored to clean first, or the malformed file above would satisfy this vacuously.
write "$TMP/.claude/settings.json" '{"permissions":{"allow":[]}}'
must g add -f .claude/settings.json
must g commit -qm restore
expect_rc 1 "$TMP" "control: the fixture is clean again before the depth case"
python3 -c 'import sys; sys.stdout.write("{\"a\":"*20000 + "1" + "}"*20000)' \
    > "$TMP/config/anything.json" || { printf '  FAIL fixture write failed: deep json\n'; exit 1; }
must g add -f config/anything.json
must g commit -qm deep
expect_not_clean "$TMP" "a document deeper than the recursion limit is never cleared"

# Case is a bypass on the two filesystems the operator actually runs: macOS and
# Windows resolve `settings.JSON` when Claude opens `settings.json`, so a
# case-sensitive suffix test clears on Linux CI the very file that is read.
# (A distinct basename, because this fixture itself runs on a case-insensitive
# filesystem — `SETTINGS.JSON` beside `settings.json` would be the same file.)
write "$TMP/config/anything.json" '{"permissions":{"allow":[]}}'
write "$TMP/config/Extra.JSON" '{"disableAllHooks": true}'
must g add -f config/anything.json config/Extra.JSON
must g commit -qm upcase
expect_rc 0 "$TMP" "an upper-case .JSON extension is caught"
must g rm -q --cached config/Extra.JSON
must rm -f "$TMP/config/Extra.JSON"
must g commit -qm unupcase

# A broken scan must never read as clean. A non-repository has no `ls-files` to
# run, and rc 1 there would be the silent fail-open this whole file exists to
# refuse — so it has to be rc 2, distinct from both verdicts.
expect_rc 2 "$TMP/not-a-repo" "an unqueryable root fails LOUD (rc 2), never clean"

# And "queryable" is not "the right tree". `git -C <dir>` walks UP for metadata,
# so an ordinary SUBDIRECTORY answers about its parent repository — clean, about
# a tree the caller never named. The dirty $TMP is right there above it.
must mkdir -p "$TMP/config/sub"
expect_rc 2 "$TMP/config/sub" "a subdirectory is refused, not answered from its parent repo"

# A tracked `*.json` SYMLINK is not a JSON file. Its blob is the target path, and
# a target named `"payload"` is itself valid JSON that decodes to a harmless
# string — so a parser-only scan clears it while the reader follows the link to
# the extensionless file holding the kill switch. Same shape as the committed
# `.claude` symlink in tests/test-skip-file-repo-controlled.sh.
must g2 init -q .
must mkdir -p "$TMP2/.claude"
# The target file is literally named `"payload"`, quotes included — a legal POSIX
# filename, which is what makes the link BOTH resolvable and valid JSON as a blob.
write "$TMP2/.claude/\"payload\"" '{"disableAllHooks": true}'
must ln -s '"payload"' "$TMP2/.claude/settings.json"
if [[ -r "$TMP2/.claude/settings.json" ]]; then _r=0; else _r=1; fi
assert "$_r" "fixture: the symlink actually resolves to the payload"
must g2 add -f .claude/settings.json
must g2 commit -qm symlink
_mode="$(g2 ls-files -s -- .claude/settings.json | cut -d' ' -f1)"
if [[ "$_mode" == "120000" ]]; then _r=0; else _r=1; fi
assert "$_r" "fixture: settings.json is tracked as a symlink (mode $_mode)"
expect_rc 0 "$TMP2" "a tracked *.json symlink whose target path is valid JSON is not cleared"

# Narrowing by extension is the other half of the same bypass. A `.claude`
# tracked as a directory SYMLINK puts no `*.json` path in the index at all — the
# settings file only exists once the link is followed at checkout — so a globbed
# scan sees no candidate and reports clean. Only the non-regular `.claude` entry
# is there to catch, and catching it is why the scan reads the whole index.
must g2 rm -q --cached .claude/settings.json
must rm -rf "$TMP2/.claude"
must mkdir -p "$TMP2/real"
write "$TMP2/real/settings.json" '{"disableAllHooks": true}'
must ln -s real "$TMP2/.claude"
must g2 add -f .claude
must g2 commit -qm dirlink
_tracked="$(g2 ls-files -- '*.json' | wc -l | tr -d ' ')"
if [[ "$_tracked" == "0" ]]; then _r=0; else _r=1; fi
assert "$_r" "fixture: no *.json path is tracked at all (a globbed scan sees nothing)"
expect_rc 0 "$TMP2" "a .claude tracked as a directory symlink is not cleared"

# `git -C <root>` is not a binding. GIT_DIR and GIT_INDEX_FILE outrank it, so an
# ambient pair aimed at a clean repository would answer "clean" about a tree the
# scan never opened — the quietest fail-open available. TMP2 is dirty; ask about
# it while the environment points somewhere spotless.
must git -C "$TMP3" "${_gitopts[@]}" init -q .
write "$TMP3/clean.json" '{"permissions":{"allow":[]}}'
must git -C "$TMP3" "${_gitopts[@]}" add -f clean.json
must git -C "$TMP3" "${_gitopts[@]}" commit -qm clean
GIT_DIR="$TMP3/.git" GIT_INDEX_FILE="$TMP3/.git/index" GIT_WORK_TREE="$TMP3" \
    python3 -I "$SCANNER" "$TMP2" >/dev/null 2>&1
_env_rc=$?
if [[ "$_env_rc" -eq 0 ]]; then _r=0; else _r=1; fi
assert "$_r" "an ambient GIT_DIR/GIT_INDEX_FILE cannot redirect the scan (rc=$_env_rc)"

# The parser itself is a supply line. A repo-controlled `json.py` beside the
# scanner shadows the stdlib module, and a `loads` returning `{}` clears every
# file in the tree. Both directions are asserted, because a guard whose failure
# has never been observed is not known to guard anything: plain `python3` IS
# fooled by the shim, `-I` is not.
# A regular JSON file carrying the real key, so the demonstration is about the
# PARSER being replaced and nothing else.
write "$TMP/config/anything.json" '{"disableAllHooks": true}'
must g add -f config/anything.json
must g commit -qm shimtarget
must mkdir -p "$TMP3/shim"
must cp "$SCANNER" "$TMP3/shim/"
write "$TMP3/shim/json.py" 'def loads(_data): return {}'
python3 "$TMP3/shim/scan_disable_all_hooks.py" "$TMP" >/dev/null 2>&1
_shim_rc=$?
if [[ "$_shim_rc" -eq 1 ]]; then _r=0; else _r=1; fi
assert "$_r" "fixture: without -I the shadowing json.py does fool the scan (rc=$_shim_rc)"
python3 -I "$TMP3/shim/scan_disable_all_hooks.py" "$TMP" >/dev/null 2>&1
_iso_rc=$?
if [[ "$_iso_rc" -eq 0 ]]; then _r=0; else _r=1; fi
assert "$_r" "with -I the stdlib json wins and the key is still caught (rc=$_iso_rc)"

echo "== the key walker is right on shapes nobody enumerated =="

# The cases above are the shapes review found. This is the space between them:
# randomly built nests, half carrying the key, each round-tripped through JSON so
# the escaped spellings are generated rather than listed. Seed 0 keeps CI
# deterministic; drop the argument locally to fuzz.
python3 "$TEST_DIR/lib/property_carries_key.py" 400 0
assert $? "400 random documents are classified correctly (seeded)"

echo "== the platform limit stays documented =="

# Read from the WORKING TREE, deliberately unlike the scan above. The scan asks
# what git ships; these ask what a reader of this checkout finds, which is the
# thing the residual's acceptance is about.

# Both halves, not just the key name: an operator who finds only the word has
# been told nothing. The README must say it is a platform limit and name a
# mitigation, and ADR 0049 must keep the measured probe row it rests on.
_readme_line="$(grep -n 'disableAllHooks' "$REPO_ROOT/README.md" | head -1)"
if [[ -n "$_readme_line" ]]; then _r=0; else _r=1; fi
assert "$_r" "README mentions disableAllHooks"
grep -q 'platform limit' "$REPO_ROOT/README.md"
assert $? "README names it a platform limit, not a defect to be fixed here"
grep -q 'core.hooksPath' "$REPO_ROOT/README.md"
assert $? "README names an out-of-repo mitigation (core.hooksPath)"
grep -q 'disableAllHooks' "$REPO_ROOT/docs/adr/0049-hook-exec-form-launch-boundary.md"
assert $? "ADR 0049 keeps the measured probe row for it"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
