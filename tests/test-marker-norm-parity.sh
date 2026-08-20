#!/usr/bin/env bash
# #671 — the two marker-key normalizers must agree, byte for byte.
#
# Token keys are produced in bash (gate_marker_norm_path, via gate_marker_arm)
# and legacy-list keys in python (marker_ops._norm_legacy_doc_path). Every
# consumer that screens for a same-document anomaly — design-clear.sh's
# --all-for-doc all-or-nothing refusal, gate_render_pending_records' mixed-doc
# detection — compares those two keys with STRING EQUALITY. A spelling the two
# canonicalize differently therefore splits one document into two keys and the
# screen silently stops seeing the other half.
#
# POSIX leaves a leading `//` implementation-defined: this host's bash preserves
# it through `pwd -P` while python's os.path.realpath collapses it. Both sides
# now collapse it explicitly, so single-slash is canonical by construction.
#
# Usage: bash tests/test-marker-norm-parity.sh
# Exit:  0 if all pass, 1 if any fail.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$REPO_ROOT/hooks/gate-scripts/lib/resolve-repo-dir.sh"
OPS="$REPO_ROOT/hooks/gate-scripts/lib/marker_ops.py"

PASS=0
FAIL=0
ok() { printf "  PASS  %s\n" "$1"; PASS=$((PASS + 1)); }
no() { printf "  FAIL  %s\n        %s\n" "$1" "${2:-}"; FAIL=$((FAIL + 1)); }
check() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "expected: $2 / actual: $3"; fi; }

command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 not available"; exit 0; }

TMP="$(mktemp -d)" || { echo "ERROR: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/docs/plans" || { echo "ERROR: fixture mkdir failed" >&2; exit 1; }
: >"$TMP/docs/plans/alpha-design.md"

# shellcheck source=hooks/gate-scripts/lib/resolve-repo-dir.sh
source "$LIB"

# The python half is module-private (it is an implementation detail of the
# legacy classifier, not a CLI subcommand), so call it by import rather than
# re-implementing it here — a re-implementation would test the copy, not the
# code the classifier actually runs.
py_norm() {
  python3 -I -c '
import importlib.util, sys
spec = importlib.util.spec_from_file_location("marker_ops", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
sys.stdout.write(m._norm_legacy_doc_path(sys.argv[2]))
' "$OPS" "$1"
}

echo "── #671 · bash/python key parity ───────────────────────────────────────"

# The one true key, derived WITHOUT the function under test. `pwd -P` because the
# fixture lives under $TMPDIR, which is a symlink on macOS (/var -> /private/var)
# — the key is the physical path, so hardcoding "$TMP/..." would fail there for a
# reason that has nothing to do with this issue.
CANON="$(cd "$TMP/docs/plans" && pwd -P)/alpha-design.md"

# Every spelling of the SAME document must land on ONE key, whichever normalizer
# produced it. `//` is the divergence the issue names; the others guard against a
# fix that canonicalizes one spelling by breaking another.
for spelling in \
  "$TMP/docs/plans/alpha-design.md" \
  "/$TMP/docs/plans/alpha-design.md" \
  "//$TMP/docs/plans/alpha-design.md" \
  "///$TMP/docs/plans/alpha-design.md" \
  "$TMP/docs/plans/../plans/alpha-design.md"
do
  b="$(gate_marker_norm_path "$spelling")"
  p="$(py_norm "$spelling")"
  check "bash == python for '$spelling'" "$b" "$p"
  # And both must equal the plainly-spelled key, or the two agree on a key that
  # still fails to match a normally-armed token.
  check "canonical key for '$spelling'" "$CANON" "$b"
done

# The specific pairing the issue says actually bites: a token armed from a
# `//`-spelled path vs a legacy entry for the same doc spelled normally.
tok_key="$(gate_marker_norm_path "//$TMP/docs/plans/alpha-design.md")"
leg_key="$(py_norm "$TMP/docs/plans/alpha-design.md")"
check "'//'-armed token key matches normally-spelled legacy key" "$leg_key" "$tok_key"

# Pre-existing root-dir case, fixed by the same collapse: dirname of `/x.md` is
# `/`, so joining produced `//x.md` where python yields `/x.md`. The file need
# not exist — only its parent must resolve, and `/` always does.
check "root-level doc key has no doubled slash" \
  "/x.md" "$(gate_marker_norm_path /x.md)"
check "root-level bash == python" \
  "$(py_norm /x.md)" "$(gate_marker_norm_path /x.md)"

echo
echo "── results ─────────────────────────────────────────────────────────────"
printf "PASS: %d  FAIL: %d\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
