#!/usr/bin/env bash
# test-rules-install-exclude.sh — verify rules/install.sh honors .install-exclude:
#   (1) excluded common rules are NOT installed; kept ones ARE
#   (2) files remain in the repo tree (links resolve there)
#   (3) RULES_INSTALL_NO_EXCLUDE=1 installs everything
#   (4) language packs still install additively
set -euo pipefail
REPO_ROOT=$(git rev-parse --show-toplevel)
cd "$REPO_ROOT"

FAIL=0
_ck() { if eval "$2"; then echo "ok: $1"; else echo "FAIL: $1"; FAIL=1; fi; }

EXCLUDED=(agents code-review coding-style development-workflow patterns performance testing)
KEPT=(git-workflow hooks investigate-before-acting security validate-before-building)

# --- default install (exclusions active) ---
TMP=$(mktemp -d); TMP2=""
trap 'rm -rf "$TMP" "$TMP2"' EXIT
HOME="$TMP" bash rules/install.sh >/dev/null 2>&1
for f in "${EXCLUDED[@]}"; do
  _ck "excluded $f.md NOT installed" "[[ ! -f \"$TMP/.claude/rules/common/$f.md\" ]]"
done
for f in "${KEPT[@]}"; do
  _ck "kept $f.md installed" "[[ -f \"$TMP/.claude/rules/common/$f.md\" ]]"
done
# files remain in the repo tree
for f in "${EXCLUDED[@]}"; do
  _ck "repo still has rules/common/$f.md" "[[ -f \"rules/common/$f.md\" ]]"
done

# --- RULES_INSTALL_NO_EXCLUDE=1 installs everything ---
TMP2=$(mktemp -d)
HOME="$TMP2" RULES_INSTALL_NO_EXCLUDE=1 bash rules/install.sh >/dev/null 2>&1
for f in "${EXCLUDED[@]}"; do
  _ck "NO_EXCLUDE installs $f.md" "[[ -f \"$TMP2/.claude/rules/common/$f.md\" ]]"
done

# --- language pack installs additively (and its own excludes, none here) ---
HOME="$TMP" bash rules/install.sh golang >/dev/null 2>&1
_ck "language pack golang installs" "[[ -f \"$TMP/.claude/rules/golang/coding-style.md\" ]]"
_ck "common exclusions still absent after lang install" "[[ ! -f \"$TMP/.claude/rules/common/testing.md\" ]]"

# --- security: a traversal exclude entry must be rejected, not escape TARGET ---
TMP3=$(mktemp -d)
SENTINEL="$TMP3/sentinel-should-survive"; : > "$SENTINEL"
EXDIR=$(mktemp -d)
printf 'common/../../../../../../..%s\n' "$SENTINEL" > "$EXDIR/.install-exclude"
# point install at a throwaway rules tree that has our custom exclude file
cp -r rules "$EXDIR/rules"; cp "$EXDIR/.install-exclude" "$EXDIR/rules/.install-exclude"
# installer must SUCCEED (warns + skips the unsafe entry, not fatal) — capture
# the exit code explicitly rather than masking it with `|| true`.
INSTALL_RC=0; HOME="$TMP3" bash "$EXDIR/rules/install.sh" >/dev/null 2>&1 || INSTALL_RC=$?
_ck "traversal install exits 0 (unsafe entry skipped, not a crash)" "[[ \"$INSTALL_RC\" -eq 0 ]]"
_ck "traversal exclude entry rejected (sentinel survives)" "[[ -f \"$SENTINEL\" ]]"
rm -rf "$TMP3" "$EXDIR"

if [[ "$FAIL" -eq 0 ]]; then echo "PASS"; else echo "FAILED"; exit 1; fi
