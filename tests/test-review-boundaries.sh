#!/bin/bash
# shellcheck disable=SC2329  # this file intentionally defines poison/sentinel functions invoked inside children or string-eval contexts
# test-review-boundaries.sh — review-lane boundaries that outlived the opencode
# lane (ADR 0051): `_bd_lib_dir` plugin-asset resolution, the dispatch.sh
# function-clean boundary (ADR 0016), the operator-username allowlist, and how a
# stale `opencode` value degrades now that opencode is a removed CLI.
#
# These are cheap static+unit checks; they deliberately do NOT call the network.

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAILURES=0
RC="$REPO_ROOT/scripts/lib/resolve-cli.sh"
DP="$REPO_ROOT/skills/dispatch-cli/scripts/dispatch.sh"

pass() { echo "  ✓ $1"; }
fail() { echo "  ✗ $1"; FAILURES=$((FAILURES + 1)); }

finish() {
  echo
  if [[ "$FAILURES" -eq 0 ]]; then
    echo "PASS (test-review-boundaries)"
    exit 0
  fi
  echo "FAIL: $FAILURES assertion(s) (test-review-boundaries)"
  exit 1
}

echo "test-review-boundaries"

# ── 5. No CWD fallback in the plugin-asset path resolution ─────────
# Under zsh BASH_SOURCE is empty; a `$0` fallback yields `dirname zsh` = "." and
# resolves plugin assets against the REVIEWED REPO — a reviewed repo's own
# plugin asset would then pass the -f check.
# shellcheck disable=SC2016  # literal '$0' is the pattern we grep FOR, not an expansion
if grep -qE '_bd_lib_dir=.*BASH_SOURCE\[0\]:-\$0' "$REPO_ROOT/scripts/lib/resolve-cli.sh"; then
  fail "_bd_lib_dir falls back to \$0 — resolves plugin assets against the reviewed repo under zsh"
else
  pass "_bd_lib_dir has no \$0/CWD fallback"
fi

# ── 7. opencode is a removed CLI (ADR 0051) ─────────────────────────
# A stale `opencode` value must degrade exactly like amp: refused via EVERY entry
# point — env override, route array (with fallback preserved), and defaults —
# for every role, including the retired auditor roles.
if (
  set -uo pipefail
  _tmp_repo="$(mktemp -d)" || exit 1
  # Isolate HOME to an empty dir so the OPERATOR's real ~/.claude/busdriver.json
  # (which may route council.critic elsewhere) cannot resolve via Step 3
  # before the Step 4 defaults guard runs — that leak made the defaults case (d)
  # pass vacuously (agy from user config, never exercising the guard).
  HOME="$(mktemp -d)" || exit 1
  trap 'rm -rf "$_tmp_repo" "$HOME"' EXIT
  git init -q "$_tmp_repo" || exit 1
  mkdir -p "$_tmp_repo/.claude" || exit 1
  # shellcheck source=/dev/null
  source "$RC"
  # Both agy AND opencode "installed" — the resolver must skip opencode BEFORE
  # the availability check, so faking it present proves the refusal isn't just a
  # missing-binary artifact; agy present proves route/defaults fallback works.
  # agy, not codex: council.critic's legacy default is codex, so codex could not tell a route hit from the legacy default.
  # shellcheck disable=SC2329  # invoked indirectly by the sourced resolver
  is_cli_available() { [[ "$1" == "agy" || "$1" == "opencode" ]]; }
  # Fake the #803 trusted resolver too, so opencode and agy look installed
  # whichever availability path the resolver consults — otherwise agy resolves
  # to none on a hermetic runner with no CLIs installed.
  # shellcheck disable=SC2329  # invoked indirectly by the sourced resolver
  _resolve_trusted_cli_bin() { case "$1" in opencode|agy) printf '/usr/bin/true\n' ;; *) return 1 ;; esac; }
  cd "$_tmp_repo" || exit 1
  ok=1

  _write_cfg() { printf '%s\n' "$1" > "$_tmp_repo/.claude/busdriver.json" || exit 1; }

  # (a) env override for a normal role → unsupported:opencode
  rm -f "$_tmp_repo/.claude/busdriver.json"
  r=$(BUSDRIVER_REVIEW_CLI=opencode resolve_role_cli "council.critic")
  [[ "$r" == "unsupported:opencode" ]] || { echo "  ✗ (a) env opencode for council.critic → '$r' (expected unsupported:opencode)"; ok=0; }

  # (b) route ["opencode","agy"] for a normal role → agy (fallback preserved)
  unset BUSDRIVER_REVIEW_CLI
  _write_cfg '{"version":1,"routes":{"council.critic":["opencode","agy"]}}'
  r=$(resolve_role_cli "council.critic")
  [[ "$r" == "agy" ]] || { echo "  ✗ (b) route [opencode,agy] for council.critic → '$r' (expected agy)"; ok=0; }

  # (c) pure ["opencode"] route for a normal role → unsupported:opencode
  _write_cfg '{"version":1,"routes":{"council.critic":["opencode"]}}'
  r=$(resolve_role_cli "council.critic")
  [[ "$r" == "unsupported:opencode" ]] || { echo "  ✗ (c) route [opencode] for council.critic → '$r' (expected unsupported:opencode)"; ok=0; }

  # (d) defaults.primary=opencode with a working fallback → fallback, not opencode
  _write_cfg '{"version":1,"defaults":{"primary":"opencode","fallback":"agy"}}'
  r=$(resolve_role_cli "council.critic")
  [[ "$r" == "agy" ]] || { echo "  ✗ (d) defaults.primary=opencode/fallback=agy for council.critic → '$r' (expected agy)"; ok=0; }

  # (e) A leftover auditor route is a removed-CLI route like any other (ADR 0051).
  for _role in blueprint-review.auditor council.auditor; do
    _write_cfg "{\"version\":1,\"routes\":{\"$_role\":[\"opencode\"]}}"
    r=$(resolve_role_cli "$_role")
    [[ "$r" == "unsupported:opencode" ]] || { echo "  ✗ (e) $_role route [opencode] → '$r' (expected unsupported:opencode)"; ok=0; }
  done

  exit $((1 - ok))
); then
  pass "opencode is refused via env/route/defaults for every role, auditor roles included"
else
  fail "removed-CLI opencode handling failed (see assertions above)"
fi

# ── 8. describe_role_resolution reports the FILTERED entry, not the
#      rejected opencode one (Greptile finding, PR #455; ADR 0051) ─────
# resolve_role_cli's route walker skips a removed "opencode" entry and falls
# through to the next route entry, so describe_role_resolution's own scan (used
# only for coverage/provenance metadata) must apply the same filter. Assert
# requested/actual/reason all agree with what resolve_role_cli really did.
if (
  set -uo pipefail
  _tmp_repo="$(mktemp -d)" || exit 1
  HOME="$(mktemp -d)" || exit 1
  trap 'rm -rf "$_tmp_repo" "$HOME"' EXIT
  git init -q "$_tmp_repo" || exit 1
  mkdir -p "$_tmp_repo/.claude" || exit 1
  # shellcheck source=/dev/null
  source "$RC"
  # shellcheck disable=SC2329  # invoked indirectly by the sourced resolver
  is_cli_available() { [[ "$1" == "agy" || "$1" == "opencode" ]]; }
  # Fake the #803 trusted resolver too, so opencode and agy look installed
  # whichever availability path the resolver consults — otherwise agy resolves
  # to none on a hermetic runner with no CLIs installed.
  # shellcheck disable=SC2329  # invoked indirectly by the sourced resolver
  _resolve_trusted_cli_bin() { case "$1" in opencode|agy) printf '/usr/bin/true\n' ;; *) return 1 ;; esac; }
  cd "$_tmp_repo" || exit 1
  ok=1

  _write_cfg() { printf '%s\n' "$1" > "$_tmp_repo/.claude/busdriver.json" || exit 1; }

  # (a) route ["opencode","agy"] for a normal role: resolver falls through
  # to agy, so provenance metadata must say requested=agy (NOT the
  # rejected "opencode" entry), actual=agy, reason=ok.
  _write_cfg '{"version":1,"routes":{"council.critic":["opencode","agy"]}}'
  line=$(describe_role_resolution "council.critic" 2>/dev/null)
  req=$(printf '%s' "$line" | cut -f1); act=$(printf '%s' "$line" | cut -f2); rsn=$(printf '%s' "$line" | cut -f3)
  [[ "$req" == "agy" && "$act" == "agy" && "$rsn" == "ok" ]] \
    || { echo "  ✗ (a) route [opencode,agy] metadata → requested=$req actual=$act reason=$rsn (expected agy/agy/ok)"; ok=0; }

  # (b) defaults.primary=opencode with a fallback for a normal role: same
  # requirement via the defaults path.
  _write_cfg '{"version":1,"defaults":{"primary":"opencode","fallback":"agy"}}'
  line=$(describe_role_resolution "council.critic" 2>/dev/null)
  req=$(printf '%s' "$line" | cut -f1); act=$(printf '%s' "$line" | cut -f2); rsn=$(printf '%s' "$line" | cut -f3)
  [[ "$req" == "agy" && "$act" == "agy" && "$rsn" == "ok" ]] \
    || { echo "  ✗ (b) defaults.primary=opencode metadata → requested=$req actual=$act reason=$rsn (expected agy/agy/ok)"; ok=0; }

  # (c) Provenance for a pure removed route is identical to amp's (ADR 0051).
  _write_cfg '{"version":1,"routes":{"council.critic":["amp"]}}'
  amp_line=$(describe_role_resolution "council.critic" 2>/dev/null)
  _write_cfg '{"version":1,"routes":{"council.critic":["opencode"]}}'
  oc_line=$(describe_role_resolution "council.critic" 2>/dev/null)
  [[ -n "$amp_line" && "$oc_line" == "${amp_line//amp/opencode}" ]] \
    || { echo "  ✗ (c) pure [opencode] provenance '$oc_line' != pure [amp] '$amp_line'"; ok=0; }

  # (d) BOTH defaults.primary AND defaults.fallback = opencode for a normal role.
  # The defaults.fallback path must apply the same removed-CLI filter as
  # defaults.primary — otherwise requested=opencode is recorded while
  # resolve_role_cli rejects both and resolves elsewhere (litmus PR #455 finding).
  # HOME isolated to an empty dir so the operator's real user config can't supply
  # a competing route before the defaults path is reached.
  ( HOME="$(mktemp -d)"; export HOME; trap 'rm -rf "$HOME"' EXIT
    _write_cfg '{"version":1,"defaults":{"primary":"opencode","fallback":"opencode"}}'
    line=$(describe_role_resolution "council.critic" 2>/dev/null)
    req=$(printf '%s' "$line" | cut -f1)
    [[ "$req" != "opencode" ]] || { echo "  ✗ (d) defaults primary+fallback both opencode → requested=opencode (must be filtered)"; exit 1; }
  ) || ok=0

  exit $((1 - ok))
); then
  pass "describe_role_resolution reports the filtered route entry, not rejected opencode"
else
  fail "describe_role_resolution opencode provenance metadata mismatch (see assertions above)"
fi

# ── 9. droid is a removed CLI (ADR 0053) ────────────────────────────
# A stale `droid` value degrades exactly like opencode, via EVERY entry point.
# droid is faked INSTALLED so a refusal cannot be a missing-binary artifact, and
# the legacy per-role defaults must no longer fall back to it.
if (
  set -uo pipefail
  _tmp_repo="$(mktemp -d)" || exit 1
  HOME="$(mktemp -d)" || exit 1
  trap 'rm -rf "$_tmp_repo" "$HOME"' EXIT
  git init -q "$_tmp_repo" || exit 1
  mkdir -p "$_tmp_repo/.claude" || exit 1
  # shellcheck source=/dev/null
  source "$RC"
  unset BUSDRIVER_REVIEW_CLI   # an exported pin would override every route case below
  # shellcheck disable=SC2329  # invoked indirectly by the sourced resolver
  is_cli_available() { [[ "$1" == "droid" || "$1" == "codex" ]]; }
  # shellcheck disable=SC2329  # invoked indirectly by the sourced resolver
  _resolve_trusted_cli_bin() { case "$1" in droid|codex) printf '/usr/bin/true\n' ;; *) return 1 ;; esac; }
  cd "$_tmp_repo" || exit 1
  ok=1
  _write_cfg() { printf '%s\n' "$1" > "$_tmp_repo/.claude/busdriver.json" || exit 1; }

  # The role under test is council.pragmatist: its legacy default (agy) is NOT
  # faked installed, so with no usable config it resolves to `none`. A `codex`
  # result below therefore proves the route/defaults entry was used — it cannot
  # be the legacy default answering instead (council.critic's legacy default IS
  # codex, which would make these cases unable to tell the two apart).
  R=council.pragmatist

  # (a) env override → unsupported:droid
  rm -f "$_tmp_repo/.claude/busdriver.json"
  r=$(BUSDRIVER_REVIEW_CLI=droid resolve_role_cli "$R" 2>/dev/null)
  [[ "$r" == "unsupported:droid" ]] || { echo "  ✗ (a) env droid → '$r' (expected unsupported:droid)"; ok=0; }

  # (b) route ["droid","codex"] → codex, with the removed-CLI warning
  _write_cfg '{"version":1,"routes":{"council.pragmatist":["droid","codex"]}}'
  err=$(resolve_role_cli "$R" 2>&1 >/dev/null)
  r=$(resolve_role_cli "$R" 2>/dev/null)
  [[ "$r" == "codex" ]] || { echo "  ✗ (b) route [droid,codex] → '$r' (expected codex)"; ok=0; }
  [[ "$err" == *"unsupported 'droid'"* ]] || { echo "  ✗ (b) no removed-CLI warning for droid: '$err'"; ok=0; }

  # (c) pure ["droid"] route → unsupported:droid
  _write_cfg '{"version":1,"routes":{"council.pragmatist":["droid"]}}'
  r=$(resolve_role_cli "$R" 2>/dev/null)
  [[ "$r" == "unsupported:droid" ]] || { echo "  ✗ (c) route [droid] → '$r' (expected unsupported:droid)"; ok=0; }

  # (d) defaults.primary=droid with a working fallback → fallback, with warning
  _write_cfg '{"version":1,"defaults":{"primary":"droid","fallback":"codex"}}'
  err=$(resolve_role_cli "$R" 2>&1 >/dev/null)
  r=$(resolve_role_cli "$R" 2>/dev/null)
  [[ "$r" == "codex" ]] || { echo "  ✗ (d) defaults droid/codex → '$r' (expected codex)"; ok=0; }
  [[ "$err" == *"defaults.primary=droid is no longer supported"* ]] || { echo "  ✗ (d) no defaults.primary warning: '$err'"; ok=0; }

  # (e) no config: legacy defaults no longer fall back to droid
  rm -f "$_tmp_repo/.claude/busdriver.json"
  for _role in council.pragmatist council.researcher blueprint-review.reviewer_3; do
    r=$(resolve_role_cli "$_role" 2>/dev/null)
    [[ "$r" == "none" ]] || { echo "  ✗ (e) $_role with droid and codex installed → '$r' (expected none)"; ok=0; }
  done

  # (f) provenance names the filtered route entry, never droid
  _write_cfg '{"version":1,"routes":{"council.pragmatist":["droid","codex"]}}'
  line=$(describe_role_resolution "$R" 2>/dev/null)
  [[ "$line" == $'codex\tcodex\tok' ]] || { echo "  ✗ (f) route provenance → '$line' (expected codex/codex/ok)"; ok=0; }

  # (g) defaults.fallback=droid is refused too. droid is faked installed and,
  # after this change, no longer on the trusted allowlist — so it reaches
  # is_cli_available (faked true): if the fallback filter is missed, these
  # resolve to droid instead of unsupported:droid.
  _write_cfg '{"version":1,"defaults":{"fallback":"droid"}}'
  err=$(resolve_role_cli "$R" 2>&1 >/dev/null)
  r=$(resolve_role_cli "$R" 2>/dev/null)
  [[ "$r" == "unsupported:droid" ]] || { echo "  ✗ (g) defaults.fallback=droid → '$r' (expected unsupported:droid)"; ok=0; }
  [[ "$err" == *"defaults.fallback=droid is no longer supported"* ]] || { echo "  ✗ (g) no defaults.fallback warning: '$err'"; ok=0; }
  _write_cfg '{"version":1,"defaults":{"primary":"droid","fallback":"droid"}}'
  r=$(resolve_role_cli "$R" 2>/dev/null)
  [[ "$r" == "unsupported:droid" ]] || { echo "  ✗ (g) defaults droid/droid → '$r' (expected unsupported:droid)"; ok=0; }

  # (h) provenance through the defaults scan skips a droid primary
  _write_cfg '{"version":1,"defaults":{"primary":"droid","fallback":"codex"}}'
  line=$(describe_role_resolution "$R" 2>/dev/null)
  [[ "$line" == $'codex\tcodex\tok' ]] || { echo "  ✗ (h) defaults provenance → '$line' (expected codex/codex/ok)"; ok=0; }

  exit $((1 - ok))
); then
  pass "droid is refused via env/route/defaults and is no legacy fallback"
else
  fail "removed-CLI droid handling failed (see assertions above)"
fi

# (h) dispatch.sh keeps the pi-required PATH-resolved bash shebang (the pi
# lane needs bash 4+ via PATH — a `#!/bin/bash` shebang would pin /bin/bash
# 3.2) WITH `-p` (`#!/usr/bin/env -S bash -p`): the first process is
# privileged, so no BASH_FUNC_* shadow is imported from the start, and the
# nonce+sentinel re-exec guard precedes set -euo pipefail (a shadowed `set`
# must not run before the guard).
# shellcheck disable=SC2016,SC2312  # single-quoted patterns; head/cut in pipeline are not load-bearing
if grep -qE '^#!/usr/bin/env -S bash -p$' "$DP" \
   && grep -qF 'exec "$BASH" -p "$0" "_bd_priv_${_bd_nonce}" "$@"' "$DP" \
   && grep -q 'type -t _bd_sentinel' "$DP" \
   && [[ "$(grep -nF 'exec "$BASH" -p' "$DP" | head -1 | cut -d: -f1)" -lt "$(grep -n 'set -euo pipefail' "$DP" | head -1 | cut -d: -f1)" ]]; then
  pass "dispatch.sh keeps env-resolved -p bash shebang + nonce+sentinel re-exec backstop before set -euo"
else
  fail "dispatch.sh missing/incorrectly-placed function-clean boundary"
fi
# (i) privileged bash suppresses imported function shadows (the mechanism the
# re-exec relies on) — verified on the repo's target /bin/bash 3.2. Uses a
# non-command name (_mechpoison) so the test itself never shadows a real tool.
# shellcheck disable=SC2329  # _mechpoison invoked inside the /bin/bash -c strings
_mechpoison() { echo MECH-POISONED; }
export -f _mechpoison
if /bin/bash -c '_mechpoison' 2>&1 | grep -q MECH-POISONED \
   && ! /bin/bash -p -c '_mechpoison' 2>&1 | grep -q MECH-POISONED; then
  unset -f _mechpoison
  pass "privileged bash (-p) suppresses imported function shadows (3.2-verified mechanism)"
else
  unset -f _mechpoison
  fail "privileged bash does not suppress imported function shadows (re-exec is ineffective)"
fi
# (j) function-clean boundary: (a) the `-p`-in-shebang (env -S bash -p) keeps
# poisoned exec/set shadows INERT (the first process imports nothing); (b) a
# naive exec shadow (returns without re-exec'ing) aborts; (c) a FORGED
# re-exec (exec shadow calls builtin exec WITHOUT -p but WITH the marker) is
# caught by the sentinel probe — the script refuses to continue; (d) a source
# shadow never runs (the guard does not call source before the re-exec).
if (
  set -uo pipefail
  # (a) shebang path (the harness invocation): poisons never imported
  exec() { echo EXEC-POISONED; }
  set() { echo SET-POISONED; }
  export -f exec set
  out="$(echo test | "$DP" --help 2>&1)"; rc=$?
  [[ "$rc" -eq 0 ]] || { echo "  ✗ (j-a) dispatch failed under poisoned env (rc=$rc)"; exit 1; }
  printf '%s' "$out" | grep -q "EXEC-POISONED\|SET-POISONED" && { echo "  ✗ (j-a) poison ran via shebang"; exit 1; }
  # (b) naive exec shadow → abort, no continuation
  exec() { echo EXEC-POISONED; }
  export -f exec
  out2="$(bash "$DP" --help 2>&1)"; rc2=$?
  [[ "$rc2" -ne 0 ]] || { echo "  ✗ (j-b) naive exec shadow continued (rc=0)"; exit 1; }
  printf '%s' "$out2" | grep -q "refusing to continue" || { echo "  ✗ (j-b) missing abort"; exit 1; }
  # (c) FORGED re-exec: the exec shadow re-execs WITHOUT -p but WITH the
  # marker (script called: exec /bin/bash -p "$0" _bd_priv "$@" → shadow sees
  # $1=/bin/bash $2=-p $3=script $4=_bd_priv $5+=orig). The re-exec'd process
  # imports the sentinel → the sentinel probe refuses continuation.
  exec() { echo EXEC-FORGED; builtin exec /bin/bash "$3" "$4" "${@:5}"; }
  export -f exec
  out3="$(bash "$DP" --help 2>&1)"; rc3=$?
  [[ "$rc3" -ne 0 ]] || { echo "  ✗ (j-c) forged re-exec continued unprivileged (rc=0)"; exit 1; }
  printf '%s' "$out3" | grep -q "refusing to continue" || { echo "  ✗ (j-c) sentinel abort missing"; exit 1; }
  printf '%s' "$out3" | grep -q "EXEC-FORGED" || { echo "  ✗ (j-c) forged exec did not run"; exit 1; }
  printf '%s' "$out3" | grep -q "Usage:" && { echo "  ✗ (j-c) script continued past the guard"; exit 1; }
  # (d) source shadow: must never run (the guard calls no source before the
  # re-exec; exec is forwarded to the real builtin so the privileged child
  # runs and --help exits clean)
  exec() { builtin exec "$@"; }
  source() { echo SRC-POISONED; }
  export -f exec source
  out4="$(bash "$DP" --help 2>&1)"; rc4=$?
  [[ "$rc4" -eq 0 ]] || { echo "  ✗ (j-d) dispatch failed under source poison (rc=$rc4)"; exit 1; }
  printf '%s' "$out4" | grep -q "SRC-POISONED" && { echo "  ✗ (j-d) source shadow ran"; exit 1; }
  # (e) a caller-supplied BARE marker (_bd_priv, no nonce) must not bypass
  # the boundary: the guard re-execs anyway (bare never matches
  # "_bd_priv_<nonce>"), so under a naive exec shadow it aborts instead of
  # continuing unprivileged.
  exec() { echo EXEC-POISONED; }
  export -f exec
  out5="$(bash "$DP" _bd_priv --help 2>&1)"; rc5=$?
  [[ "$rc5" -ne 0 ]] || { echo "  ✗ (j-e) bare marker bypassed the boundary (rc=0)"; exit 1; }
  printf '%s' "$out5" | grep -q "refusing to continue" || { echo "  ✗ (j-e) missing abort on bare-marker attempt"; exit 1; }
  printf '%s' "$out5" | grep -q "EXEC-POISONED" || { echo "  ✗ (j-e) exec shadow did not run (guard never re-exec'd?)"; exit 1; }
  # (f) empty-nonce marker (_bd_priv_ with no env nonce) must also fall
  # through to the re-exec → same abort under a naive exec shadow.
  out6="$(bash "$DP" _bd_priv_ --help 2>&1)"; rc6=$?
  [[ "$rc6" -ne 0 ]] || { echo "  ✗ (j-f) empty-nonce marker bypassed the boundary (rc=0)"; exit 1; }
  printf '%s' "$out6" | grep -q "refusing to continue" || { echo "  ✗ (j-f) missing abort on empty-nonce attempt"; exit 1; }
  # (g) dual-forge (matching env nonce + argv marker, no code execution): the
  # re-exec branch was skipped so the sentinel was never exported — the env-
  # presence check aborts.
  out7="$(_bd_nonce=known bash "$DP" _bd_priv_known --help 2>&1)"; rc7=$?
  [[ "$rc7" -ne 0 ]] || { echo "  ✗ (j-g) dual-forge bypassed the boundary (rc=0)"; exit 1; }
  printf '%s' "$out7" | grep -q "refusing to continue" || { echo "  ✗ (j-g) missing abort on dual-forge attempt"; exit 1; }
  # (h) substring forge (an env var whose VALUE contains the sentinel name):
  # printenv's exact NAME lookup must not be fooled by a value match.
  out8="$(_bd_nonce=known X='BASH_FUNC__bd_sentinel%%' bash "$DP" _bd_priv_known --help 2>&1)"; rc8=$?
  [[ "$rc8" -ne 0 ]] || { echo "  ✗ (j-h) substring-forge bypassed the boundary (rc=0)"; exit 1; }
  printf '%s' "$out8" | grep -q "refusing to continue" || { echo "  ✗ (j-h) missing abort on substring-forge attempt"; exit 1; }
  # (i) env-NAME forge with a NON-function value (via `env`): the sentinel
  # value check (must start with "() {" and end with "}") refuses it.
  out9="$(env '_bd_nonce=known' 'BASH_FUNC__bd_sentinel%%=x' bash "$DP" _bd_priv_known --help 2>&1)"; rc9=$?
  [[ "$rc9" -ne 0 ]] || { echo "  ✗ (j-i) env-NAME forge bypassed the boundary (rc=0)"; exit 1; }
  printf '%s' "$out9" | grep -q "refusing to continue" || { echo "  ✗ (j-i) missing abort on env-NAME forge"; exit 1; }
  # (j) TRUNCATED-function forge: `BASH_FUNC__bd_sentinel%%='() {'` (no closing
  # brace) is NOT imported on bash 5.x but satisfies a bare "() {" prefix — the
  # trailing-`}` shape check must refuse it.
  out10="$(env '_bd_nonce=known' 'BASH_FUNC__bd_sentinel%%=() {' bash "$DP" _bd_priv_known --help 2>&1)"; rc10=$?
  [[ "$rc10" -ne 0 ]] || { echo "  ✗ (j-j) truncated-function forge bypassed the boundary (rc=0)"; exit 1; }
  printf '%s' "$out10" | grep -q "refusing to continue" || { echo "  ✗ (j-j) missing abort on truncated-function forge"; exit 1; }
  exit 0
); then
  pass "function-clean boundary: shebang inert; naive+forged exec shadows abort; source shadow never runs"
else
  fail "function-clean boundary failed (see above)"
fi

# ── 10. Operator-username allowlist refuses tilde SPECIAL forms ─────
# `eval echo "~$u"` must never see a name that starts with `-`, `+`, or a
# digit: `~-`/`~-0` expand to $OLDPWD/$PWD, `~+`/`~0` to $PWD — a special-form
# "username" would make the reviewed checkout the "trusted home". Behavioral
# test on the REAL helper (sourced, not copied).
if ( # shellcheck disable=SC1090,SC2016  # source target is a variable; '$u' is a literal grep pattern
     source "$RC" && _bd_valid_username "vfrvndtt" && _bd_valid_username "0abc" \
     && ! _bd_valid_username "-0" && ! _bd_valid_username "-" && ! _bd_valid_username "+1" \
     && ! _bd_valid_username "7" && ! _bd_valid_username "-" && ! _bd_valid_username "a;rm" \
     && ! _bd_valid_username 'a b' && ! _bd_valid_username "" ); then
  pass "username allowlist: plain + digit-leading ok, tilde-stack/metachar/empty refused"
else
  fail "username allowlist: a tilde-stack or metacharacter name passed validation"
fi
# #789 round 4: the validator moved off shadowable `return` (an exported
# BASH_FUNC_return%% made an all-digit username pass and let the shadow write
# _trusted_operator_home's globals), so the tilde-stack regex now sits on an
# `elif`. Same regex, same rejection — the behavioural assertion above proves the
# semantics; this pin only proves the guard is still PRESENT.
# shellcheck disable=SC2016  # single-quoted pattern is a literal grep for source text
if grep -qF 'elif [[ "$1" =~ ^[-+]?[0-9]*$ ]]; then' "$RC"; then
  pass "resolve-cli.sh: allowlist rejects tilde stack forms (^[-+]?[0-9]*$)"
else
  fail "resolve-cli.sh: allowlist does not reject tilde stack forms"
fi
# shellcheck disable=SC2016  # single-quoted pattern is a literal grep for the pi-probe source text
if [[ "$(grep -cF '[[ "$u" =~ ^[-+]?[0-9]*$ ]] && exit 1' "$DP")" -eq 2 ]]; then
  pass "dispatch.sh pi probes: both username checks reject tilde stack forms"
else
  fail "dispatch.sh pi probes: username checks missing tilde-stack guard"
fi

finish
