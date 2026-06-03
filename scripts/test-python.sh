#!/usr/bin/env bash
# Run the repo's federated Python test suites.
#
# The Python code in this repo is NOT a single root package — it is organized
# per-skill, where each island owns its own imports and (sometimes) its own
# pyproject.toml. A single root `pytest` would break those import assumptions
# (e.g. skill-comply uses `pythonpath = ["."]` and `from scripts.parser import`).
# So this runner invokes each island in its own context via `uv run`, which
# provisions an isolated, PEP 668-safe environment per suite.
#
# Add new Python test suites to the SUITES list as they appear.
#
# Usage: scripts/test-python.sh        (run all suites)
#        COVERAGE=1 scripts/test-python.sh   (emit coverage.xml per suite)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if ! command -v uv >/dev/null 2>&1; then
  echo "error: 'uv' is required to run Python tests (https://docs.astral.sh/uv/)" >&2
  exit 127
fi

fail=0

run_suite() {
  local label="$1"; shift
  echo "── ${label} ──"
  if "$@"; then
    echo "✓ ${label}"
  else
    echo "✗ ${label}" >&2
    fail=1
  fi
}

# Self-contained uv project (its own pyproject.toml + deps).
run_suite "skill-comply" \
  bash -c "cd skills/skill-comply && uv run --quiet pytest -q"

# Standalone test file with no project config; deps supplied ad hoc.
run_suite "continuous-learning-v2" \
  uv run --quiet --with pytest --with pyyaml \
    pytest skills/continuous-learning-v2/scripts/test_parse_instinct.py -q

exit "$fail"
