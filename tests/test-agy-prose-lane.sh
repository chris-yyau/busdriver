#!/usr/bin/env bash
# test-agy-prose-lane.sh — pins the `agy-prose` PROSE lane.
#
# The lane exists so prose drafting does not ride the reviewer's agy route.
# Three properties are load-bearing and each has silently regressed on a
# sibling lane before, so each is pinned here rather than described in prose:
#
#   1. `--mode auto` is REFUSED. Accepting it would turn this lane into
#      `agy --dangerously-skip-permissions`: a writing agent loose in the
#      working tree, wearing the name of a write-blocked lane.
#   2. NO droid escalation. A failed dispatch must fail, not silently re-send
#      the brief — and whatever source material was pasted into it — to a
#      DIFFERENT third party than the operator chose. Same exemption pi,
#      opencode and agy-read carry.
#   3. The model key is lane-scoped. Plain `--cli agy` (the blueprint-review
#      reviewer_1 slot) must pass no --model, so it is never downgraded to
#      whatever cheap model prose is configured with.
# shellcheck disable=SC2016  # Every grep below matches LITERAL shell source
# text. Expanding `$_AGY_PROSE_LANE` / `$CLI` here would compare against this
# test's own empty variables and pass unconditionally — i.e. defeat the pin.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
DISPATCH="skills/dispatch-cli/scripts/dispatch.sh"
RESOLVE="scripts/lib/resolve-cli.sh"
pass_n=0; fail_n=0
pass() { echo "ok   — $1"; pass_n=$((pass_n+1)); }
fail() { echo "FAIL — $1"; fail_n=$((fail_n+1)); }

# ── 1. mode refusals (behavioural — the guard must actually fire) ──
out="$(bash "$DISPATCH" --cli agy-prose --mode auto --prompt x 2>&1)"
case "$out" in
  *"--mode auto is not accepted"*) pass "--mode auto refused" ;;
  *) fail "--mode auto NOT refused: $out" ;;
esac

out="$(bash "$DISPATCH" --cli agy-prose --mode typo --prompt x 2>&1)"
case "$out" in
  *"accepts only readonly"*) pass "invalid --mode refused" ;;
  *) fail "invalid --mode NOT refused: $out" ;;
esac

# Drafts are written to $TMPDIR, so a repo-controlled $TMPDIR pointing INTO the
# checkout would leave prose in the repository. The boundary is the REPO ROOT,
# not $PWD: dispatching from a subdirectory must not let `<root>/.drafts` pass.
# mktemp -d, never a fixed path: this directory is `rm -rf`'d, and a fixed name
# would delete a real directory of the same name if one already existed here.
_probe=""
_probe="$(mktemp -d "$PWD/.tmpdir-guard-probe.XXXXXX")" || _probe=""
if [[ -z "$_probe" || ! -d "$_probe" ]]; then
  fail "could not create the \$TMPDIR probe dir — containment is UNTESTED"
else
  _repo_root="$PWD"
  mkdir -p "$_probe/sub"
  out="$(cd "$_probe/sub" && TMPDIR="$_probe" bash "$_repo_root/$DISPATCH" --cli agy-prose --mode readonly --prompt x 2>&1)"
  rm -rf "$_probe"
fi
case "${out:-}" in
  *"inside the repository"*) pass "\$TMPDIR inside the repo is refused, from a subdirectory too" ;;
  *) fail "\$TMPDIR containment not enforced from a subdirectory — drafts could land in the repo: $out" ;;
esac

# ── 2. droid-escalation exemption (structural: the guard clause) ──
if grep -qE '^[[:space:]]+&& \[\[ -z "\$_AGY_PROSE_LANE" \]\] \\$' "$DISPATCH"; then
  pass "lane is exempt from droid escalation"
else
  fail "droid-escalation exemption missing — a failed prose dispatch would be re-sent to another provider"
fi

# ── 3. write boundary + reporting identity ──
if grep -qE '^[[:space:]]+if \[\[ -n "\$_AGY_READ_LANE" \|\| -n "\$_AGY_PROSE_LANE" \]\]; then$' "$DISPATCH"; then
  pass "--mode plan (the write boundary) is applied to this lane"
else
  fail "--mode plan is NOT applied — the lane is write-capable despite its docs"
fi

if grep -qE '^[[:space:]]+codex\|agy\|agy-read\|agy-prose\|droid\|grok\|opencode\|pi-read\) ;;$' "$DISPATCH"; then
  pass "agy-prose is in the REPORT_NAME provenance vocabulary"
else
  fail "agy-prose missing from the provenance whitelist — audit trail would say plain 'agy'"
fi

# ── 4. model key is lane-scoped, and empty is NORMAL (not a refusal) ──
if grep -qE "writing_prose\) jqf='\.writing_prose\.model" "$RESOLVE"; then
  pass "writing_prose is a literal in the config-block enum"
else
  fail "writing_prose missing from the enum — the model key would degrade to the default"
fi

# The read lane forces a default on empty; this one must NOT — empty means
# "pass no --model". Assert the absence of a fallback assignment.
body="$(sed -n '/^resolve_writing_prose_model()/,/^}/p' "$RESOLVE")"
if [[ -n "$body" ]] && ! grep -q '||[[:space:]]*_BD_WRITING_PROSE_MODEL=' <<<"$body"; then
  pass "empty model is passed through, not defaulted (deliberate divergence from pi/agy_read)"
else
  fail "resolve_writing_prose_model missing, or it forces a default on empty"
fi

# Plain `--cli agy` must not reach the prose desugar.
lane_sets=0
lane_sets="$(grep -cE '^[[:space:]]+_AGY_PROSE_LANE=1$' "$DISPATCH")" || true
if [[ "$lane_sets" == "1" ]] \
   && grep -qE '^if \[\[ "\$CLI" == "agy-prose" \]\]; then$' "$DISPATCH"; then
  pass "lane flag set only inside the agy-prose desugar"
else
  fail "lane flag set outside the desugar — plain --cli agy could inherit prose pins"
fi

# ── 5. resolver BEHAVIOUR, not just its source text ──
# The greps above still pass if pykey, the shape grammar, JSON-type handling or
# the call itself is broken — the lane would then silently ignore its model
# configuration. Drive the real resolver against a throwaway HOME instead.
# shellcheck source=/dev/null
source "$RESOLVE" 2>/dev/null
if declare -F resolve_writing_prose_model >/dev/null; then
  # A failed mktemp would leave $_tmph empty, aiming every fixture write at
  # `/.claude`. Those writes fail, but the non-string and absent-key assertions
  # would still PASS against an empty resolver result — a false green. Bail.
  _tmph=""
  _tmph="$(mktemp -d)" || _tmph=""
  if [[ -z "$_tmph" || ! -d "$_tmph" ]]; then
    fail "could not create a temp HOME — resolver behaviour is UNTESTED (not passing)"
    echo
    echo "FAIL: test-agy-prose-lane ($fail_n failed, $pass_n passed)"
    exit 1
  fi
  mkdir -p "$_tmph/.claude"

  printf '{"writing_prose":{"model":"probe-model-id"}}' > "$_tmph/.claude/busdriver.json"
  HOME="$_tmph" resolve_writing_prose_model
  if [[ "$_BD_WRITING_PROSE_MODEL" == "probe-model-id" ]]; then
    pass "resolver returns a configured bare model id"
  else
    fail "configured model ignored (got '$_BD_WRITING_PROSE_MODEL') — lane would run on agy's own model regardless of config"
  fi

  # A non-string must be REJECTED, not stringified: the value becomes an argv
  # word naming the third party the brief is sent to.
  printf '{"writing_prose":{"model":123}}' > "$_tmph/.claude/busdriver.json"
  HOME="$_tmph" resolve_writing_prose_model
  if [[ -z "$_BD_WRITING_PROSE_MODEL" ]]; then
    pass "non-string model rejected"
  else
    fail "non-string model accepted as '$_BD_WRITING_PROSE_MODEL'"
  fi

  # Absent key → empty, which for THIS lane means "pass no --model" (normal),
  # not the refusal agy_read/pi treat it as.
  printf '{}' > "$_tmph/.claude/busdriver.json"
  HOME="$_tmph" resolve_writing_prose_model
  if [[ -z "$_BD_WRITING_PROSE_MODEL" ]]; then
    pass "absent key yields empty (no --model), not a forced default"
  else
    fail "absent key produced '$_BD_WRITING_PROSE_MODEL' — a default crept in"
  fi

  # A non-empty INVALID string (e.g. a provider/model id pasted from the pi
  # config) must leave the validated model empty — the `bare` grammar rejects
  # a `/` — while the presence probe still reports the raw value, which is
  # what lets dispatch.sh (resolve-cli.sh:810-813) tell "absent" from
  # "present but rejected" and refuse instead of silently falling back to
  # agy's default model.
  if declare -F resolve_writing_prose_raw >/dev/null; then
    printf '{"writing_prose":{"model":"provider/model"}}' > "$_tmph/.claude/busdriver.json"
    HOME="$_tmph" resolve_writing_prose_model
    HOME="$_tmph" resolve_writing_prose_raw
    if [[ -z "$_BD_WRITING_PROSE_MODEL" && "$_BD_WRITING_PROSE_RAW" == "provider/model" ]]; then
      pass "invalid non-empty model rejected by the grammar but preserved by the presence probe"
    else
      fail "invalid model handling broken (model='$_BD_WRITING_PROSE_MODEL', raw='$_BD_WRITING_PROSE_RAW') — dispatch.sh could silently fall back to agy's default model"
    fi
  else
    fail "resolve_writing_prose_raw not defined after sourcing $RESOLVE"
  fi

  rm -rf "$_tmph"
else
  fail "resolve_writing_prose_model not defined after sourcing $RESOLVE"
fi

echo
if [[ "$fail_n" -eq 0 ]]; then
  echo "PASS: test-agy-prose-lane ($pass_n assertions)"; exit 0
else
  echo "FAIL: test-agy-prose-lane ($fail_n failed, $pass_n passed)"; exit 1
fi
