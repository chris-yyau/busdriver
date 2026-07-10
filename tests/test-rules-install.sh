#!/usr/bin/env bash
# test-rules-install.sh — verify rules/install.sh:
#   (1) installs the common canon
#   (2) refuses to write outside $HOME (physical-containment guard)
#   (3) does not follow a pre-existing destination symlink (clean install)
set -euo pipefail
REPO_ROOT=$(git rev-parse --show-toplevel)
cd "$REPO_ROOT"

FAIL=0
_ck() { if eval "$2"; then echo "ok: $1"; else echo "FAIL: $1"; FAIL=1; fi; }

# The hand-written canon — every file rules/install.sh must install.
CANON=(investigate-before-acting validate-before-building tool-discipline policy)

# Initialize every temp var and set the cleanup trap ONCE, before any
# allocation, so a mktemp failure mid-test can never leak a dir the trap
# doesn't cover.
TMP=""; TMP2=""; ESC=""; TMP3=""; OUTSIDE=""; TMP4=""; TMP5=""
trap 'rm -rf "$TMP" "$TMP2" "$ESC" "$TMP3" "$OUTSIDE" "$TMP4" "$TMP5"' EXIT

# --- default install: the canon lands under ~/.claude/rules/common ---
TMP=$(mktemp -d)
HOME="$TMP" bash rules/install.sh >/dev/null 2>&1
for f in "${CANON[@]}"; do
  _ck "installs common/$f.md" "[[ -f \"$TMP/.claude/rules/common/$f.md\" ]]"
done
_ck "no language dirs installed" "[[ ! -d \"$TMP/.claude/rules/typescript\" ]]"
# The canon is common-only: retired ECC common rules must NOT be installed
# (proves the source tree, not just install.sh, carries only the canon).
RETIRED=(agents code-review coding-style development-workflow git-workflow hooks patterns performance security testing)
for f in "${RETIRED[@]}"; do
  _ck "retired common/$f.md NOT installed" "[[ ! -f \"$TMP/.claude/rules/common/$f.md\" ]]"
done
NCOMMON=$(find "$TMP/.claude/rules/common" -type f | wc -l | tr -d ' ')
_ck "installed common/ holds exactly ${#CANON[@]} canon files (got $NCOMMON)" "[[ \"$NCOMMON\" -eq ${#CANON[@]} ]]"

# --- containment: a ~/.claude symlinked OUTSIDE $HOME is refused, nothing written ---
TMP2=$(mktemp -d); ESC=$(mktemp -d)
ln -s "$ESC" "$TMP2/.claude"   # ~/.claude escapes $HOME
INSTALL_RC=0; HOME="$TMP2" bash rules/install.sh >/dev/null 2>&1 || INSTALL_RC=$?
_ck "install refuses target resolving outside \$HOME (exit non-zero)" "[[ \"$INSTALL_RC\" -ne 0 ]]"
_ck "nothing created outside \$HOME (not even empty dirs)" "[[ ! -e \"$ESC/rules\" ]]"

# --- destination-symlink safety: a planted symlink at a target file is unlinked,
#     not followed (its external referent must survive untouched) ---
TMP3=$(mktemp -d); OUTSIDE=$(mktemp -d)
EXTFILE="$OUTSIDE/external.txt"; printf 'ORIGINAL\n' > "$EXTFILE"
mkdir -p "$TMP3/.claude/rules/common"
ln -s "$EXTFILE" "$TMP3/.claude/rules/common/policy.md"   # planted destination symlink
HOME="$TMP3" bash rules/install.sh >/dev/null 2>&1
_ck "planted dest symlink not followed (external file intact)" "[[ \"\$(cat \"$EXTFILE\")\" == ORIGINAL ]]"
_ck "installed policy.md is a real file, not a symlink" "[[ -f \"$TMP3/.claude/rules/common/policy.md\" && ! -L \"$TMP3/.claude/rules/common/policy.md\" ]]"

# --- target-resolves-to-source: install must NOT delete its own source. Uses a
#     THROWAWAY copy of the repo checked out UNDER the fake $HOME (never the real
#     checkout) so a regression that rm's the source can only harm the temp copy.
#     ~/.claude/rules → the copy's rules/, so both are under $HOME (containment
#     passes) and dst (…/rules/common) resolves to src (…/rules/common). ---
TMP4=$(mktemp -d)                                   # fake $HOME
mkdir -p "$TMP4/checkout" "$TMP4/.claude"
cp -r rules "$TMP4/checkout/rules"                  # throwaway source, UNDER $HOME
ln -s "$TMP4/checkout/rules" "$TMP4/.claude/rules"  # install target == source
HOME="$TMP4" bash "$TMP4/checkout/rules/install.sh" >/dev/null 2>&1 || true
_ck "install does not delete its own source when target resolves to source" \
  "[[ -f \"$TMP4/checkout/rules/common/policy.md\" ]]"

# --- source-under-target: refuse rather than delete the checkout. THROWAWAY copy
#     nested under the (fake) install target so a regression can only harm it. ---
TMP5=$(mktemp -d)                                        # fake $HOME
mkdir -p "$TMP5/.claude/rules/common/checkout"
cp -r rules "$TMP5/.claude/rules/common/checkout/rules"  # src nested UNDER dst
RC5=0
HOME="$TMP5" bash "$TMP5/.claude/rules/common/checkout/rules/install.sh" >/dev/null 2>&1 || RC5=$?
_ck "refuses when source lives under the install target (exit non-zero)" "[[ \"$RC5\" -ne 0 ]]"
_ck "nested source survives the refusal" \
  "[[ -f \"$TMP5/.claude/rules/common/checkout/rules/common/policy.md\" ]]"

if [[ "$FAIL" -eq 0 ]]; then echo "PASS"; else echo "FAILED"; exit 1; fi
