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
# One directory per user, reused by every suite: read-only, so nothing can leave state
# in it (a cwd-relative write fails loudly instead), and nothing accumulates per run.
#
# Source it AFTER every path the suite derives from the cwd is absolute.
_gate_cwd_isolation_dir="${TMPDIR:-/tmp}/busdriver-gate-suite-cwd.$(id -u)"
mkdir -m 555 "$_gate_cwd_isolation_dir" 2>/dev/null || :
# find prints whole paths, so even a newline-only name reads as non-empty; a find that
# cannot list the directory fails the check rather than reading as empty.
if [ -L "$_gate_cwd_isolation_dir" ] || [ ! -d "$_gate_cwd_isolation_dir" ] \
   || [ ! -O "$_gate_cwd_isolation_dir" ] || [ -w "$_gate_cwd_isolation_dir" ] \
   || [ ! -r "$_gate_cwd_isolation_dir" ] \
   || ! _gate_cwd_isolation_entries=$(find "$_gate_cwd_isolation_dir" -mindepth 1 -maxdepth 1 -print 2>/dev/null) \
   || [ -n "$_gate_cwd_isolation_entries" ]; then
    echo "gate-cwd-isolation: $_gate_cwd_isolation_dir must be an empty, read-only directory you own; remove it and re-run" >&2
    exit 1
fi
cd "$_gate_cwd_isolation_dir" || exit 1
# A TMPDIR inside a checkout would let git discover that repository from here.
if git rev-parse --git-dir >/dev/null 2>&1; then
    echo "gate-cwd-isolation: $_gate_cwd_isolation_dir is inside a git repository; set TMPDIR outside any checkout" >&2
    exit 1
fi
