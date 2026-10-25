#!/usr/bin/env bash
# test-resolve-cli-bash32-source.sh — resolve-cli.sh must find its own directory
# inside functions even when the caller defines a same-named fallback.
#
# macOS /bin/bash 3.2 reports a function's ${BASH_SOURCE[0]} from the last PARSED
# definition of that name, taken or not. dispatch.sh carries untaken fallbacks for
# _portable_timeout and the grok_* helpers, so every call-time lookup resolved
# against skills/dispatch-cli/scripts: the checkout pin found no library, skipped
# itself, and an agy shipped inside the reviewed checkout RAN (measured). The grok
# children resolved to /dev/null. bash 5 is unaffected, so the runtime case only
# discriminates where /bin/bash is 3.2; the static case holds everywhere.
set -uo pipefail
. "$(dirname "$0")/lib/git-env-isolation.sh" || exit 1

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
LIB="$ROOT/scripts/lib/resolve-cli.sh"
FAILED=0
pass() { printf 'ok   — %s\n' "$1"; }
fail() { printf 'FAIL — %s\n' "$1"; FAILED=1; }

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

# A caller shaped like dispatch.sh: source, then an untaken fallback of the same name.
cat > "$SCRATCH/caller.sh" <<'CALLER'
source "$1" 2>/dev/null
if ! type grok_sandbox_preflight >/dev/null 2>&1; then
  grok_sandbox_preflight() { :; }
fi
grok_sandbox_preflight "" >/dev/null 2>&1
printf 'GSP=%s\n' "$_GSP_CHILD"
CALLER
want="GSP=$ROOT/scripts/lib/grok-preflight.sh"
out="$(cd "$SCRATCH" && HINDSIGHT_DISABLED=1 /bin/bash "$SCRATCH/caller.sh" "$LIB")"
if grep -qxF "$want" <<<"$out"; then
  pass "/bin/bash $(/bin/bash -c 'echo "$BASH_VERSION"'): grok child resolves beside the library despite a caller fallback"
else
  fail "grok child mis-resolved under a caller fallback — want '$want', got: $out"
fi

# Static: no function body may read ${BASH_SOURCE[0]}. The allowed reads are the
# source-time captures and the unindented `if [[ "${BASH_SOURCE[0]-}" = "${0-}" ...`
# entry-point checks; everything else must use _bd_self_dir.
bad="$(grep -n 'BASH_SOURCE' "$LIB" \
  | grep -vE '^[0-9]+:[[:space:]]*#' \
  | grep -vE '^[0-9]+:if \[\[ (-n )?"\$\{BASH_SOURCE\[0\]' \
  | grep -vE '^[0-9]+:_bd803_pin_src="\$\{BASH_SOURCE\[0\]-\}"$' \
  | grep -vE '^[0-9]+:  _bd_lib_dir="\$\(cd "\$\{BASH_SOURCE\[0\]%/\*\}"' || true)"
if [[ -z "$bad" ]]; then
  pass "resolve-cli.sh reads BASH_SOURCE only at source time"
else
  fail "resolve-cli.sh reads BASH_SOURCE outside a source-time capture: $bad"
fi

exit "$FAILED"
