# shellcheck shell=bash
# Sourced by suites that run the pre-implementation gate (#1064).
#
# The gate reads its skip file and lease ledger ($STATE_DIR/skip-design-review.local,
# $STATE_DIR/.skip-design-review-lease.d) and, when python3 is absent, its pending-marker
# probe from its PROCESS cwd. A suite that runs from the checkout's root would therefore
# spend the operator's live design-review lease and see that checkout's pending design
# tokens. This moves the suite into an empty scratch directory that is not a repository,
# so every gate call sees fixture state only.
#
# The cwd alone is enough: the gate resets an absolute or `..` BUSDRIVER_STATE_DIR to
# `.claude` (pre-implementation-gate.sh, the STATE_DIR case), so its state dir is always
# relative to this scratch dir.
#
# Source it AFTER every path the suite derives from the cwd is absolute.
# shortcut: the scratch dir is left behind (suites own their EXIT traps); it is empty.
_gate_cwd_isolation_dir=$(mktemp -d "${TMPDIR:-/tmp}/gate-suite-cwd.XXXXXX") || exit 1
cd "$_gate_cwd_isolation_dir" || exit 1
# A TMPDIR inside a checkout would let git discover that repository from here.
if git rev-parse --git-dir >/dev/null 2>&1; then
    echo "gate-cwd-isolation: $_gate_cwd_isolation_dir is inside a git repository; set TMPDIR outside any checkout" >&2
    exit 1
fi
