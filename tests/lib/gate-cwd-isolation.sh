# shellcheck shell=bash
# Sourced by suites that run the pre-implementation gate (#1064).
#
# The gate reads its skip file and lease ledger ($STATE_DIR/skip-design-review.local,
# $STATE_DIR/.skip-design-review-lease.d) and, when python3 is absent, its pending-marker
# probe from its PROCESS cwd. A suite that runs from the checkout's root would therefore
# spend the operator's live design-review lease and see that checkout's pending design
# tokens. This moves the suite into an empty, read-only scratch directory that is not a
# repository, so every gate call sees fixture state only.
#
# The cwd alone is enough: the gate resets an absolute or `..` BUSDRIVER_STATE_DIR to
# `.claude` (pre-implementation-gate.sh, the STATE_DIR case), so its state dir is always
# relative to this scratch dir.
#
# One directory per user, reused by every suite: mode 555, so an ordinary user's
# cwd-relative write fails loudly, and nothing accumulates per run. Root can still write
# into it, which is why emptiness is re-checked on every run rather than assumed.
#
# Source it AFTER every path the suite derives from the cwd is absolute.
# TMPDIR is made absolute (and exported that way) before leaving this cwd, so the checks
# below, the final cd (which would consult CDPATH for a relative path) and the suite's
# own later mktemp calls all mean the same directory.
case "${TMPDIR:-/tmp}" in /*) ;; *) export TMPDIR="$PWD/$TMPDIR" ;; esac
_gate_cwd_isolation_dir="${TMPDIR:-/tmp}/busdriver-gate-suite-cwd.$(id -u)"
mkdir -m 555 "$_gate_cwd_isolation_dir" 2>/dev/null || :
# A symlink, or another account squatting the name (a shared /tmp), gets a private
# directory instead. `-O` follows symlinks, so the symlink case is tested on its own.
# shortcut: that fallback is left behind empty each run; acceptable for a rare collision.
if [ -L "$_gate_cwd_isolation_dir" ] \
   || { [ -e "$_gate_cwd_isolation_dir" ] && [ ! -O "$_gate_cwd_isolation_dir" ]; }; then
    _gate_cwd_isolation_dir=$(mktemp -d "$_gate_cwd_isolation_dir.XXXXXX") \
        && chmod 555 "$_gate_cwd_isolation_dir" || exit 1
fi
# Write bits are read from the mode, not `-w`, which is always true for root.
# find prints whole paths, so even a newline-only name reads as non-empty; a find that
# fails fails the check rather than reading as empty or read-only.
if [ -L "$_gate_cwd_isolation_dir" ] || [ ! -d "$_gate_cwd_isolation_dir" ] \
   || [ ! -O "$_gate_cwd_isolation_dir" ] || [ ! -r "$_gate_cwd_isolation_dir" ] \
   || ! _gate_cwd_isolation_writable=$(find "$_gate_cwd_isolation_dir" -maxdepth 0 \( -perm -0200 -o -perm -0020 -o -perm -0002 \) -print 2>/dev/null) \
   || [ -n "$_gate_cwd_isolation_writable" ] \
   || ! _gate_cwd_isolation_entries=$(find "$_gate_cwd_isolation_dir" -mindepth 1 -maxdepth 1 -print 2>/dev/null) \
   || [ -n "$_gate_cwd_isolation_entries" ]; then
    echo "gate-cwd-isolation: $_gate_cwd_isolation_dir must be an empty, read-only directory you own; remove it, or set TMPDIR to a private directory, and re-run" >&2
    exit 1
fi
cd -P "$_gate_cwd_isolation_dir" || exit 1   # -P: resolve like mkdir and find did, not lexically
# A TMPDIR inside a checkout would let git discover that repository from here.
if git rev-parse --git-dir >/dev/null 2>&1; then
    echo "gate-cwd-isolation: $_gate_cwd_isolation_dir is inside a git repository; set TMPDIR outside any checkout" >&2
    exit 1
fi
