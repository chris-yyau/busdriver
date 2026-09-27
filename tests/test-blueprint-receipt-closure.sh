#!/usr/bin/env bash
# #840: the receipt writer's `runner_closure` must equal the same digest computed from
# `git ls-tree -r <commit>` over the closure dirs — that equality is how a run is tied to
# a litmus-reviewed commit — and must move when any sourced file changes.
# shellcheck disable=SC2015  # `test && ok || bad`: ok/bad only echo and count
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
LOOP="$REPO/skills/blueprint-review/scripts/run-design-review-loop.sh"
PASS=0 FAIL=0
ok()  { echo "  PASS  $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL  $1"; FAIL=$((FAIL + 1)); }

W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
P="$W/plugin"
mkdir -p "$P/skills/blueprint-review/scripts" "$P/scripts/lib" "$P/hooks/gate-scripts/lib" \
         "$P/skills/dispatch-cli/scripts" "$P/other" "$W/reviews"
printf 'runner\n' > "$P/skills/blueprint-review/scripts/run.sh"
printf 'lib\n'    > "$P/scripts/lib/resolve-cli.sh"
printf 'gate\n'   > "$P/hooks/gate-scripts/lib/marker_ops.py"
printf 'disp\n'   > "$P/skills/dispatch-cli/scripts/dispatch.sh"
printf 'out\n'    > "$P/other/ignored.txt"
git -C "$P" init -q . && git -C "$P" add -A && git -C "$P" -c user.name=t -c user.email=t@t commit -qm init

# The writer and its globals, lifted from the real runner.
_agy_bytelen() { printf '%s' "${#1}"; }
get_review_file() { printf '%s/%s' "$W/reviews" "$1"; }
eval "$(grep -E '^_BP_CLOSURE_DIRS=' "$LOOP")"
eval "$(sed -n '/^_bp_runner_identity() {/,/^}/p' "$LOOP")"
eval "$(sed -n '/^_bp_write_receipt() {/,/^}/p' "$LOOP")"
_BP_RUNNER_FILE="$P/skills/blueprint-review/scripts/run.sh"
# shellcheck disable=SC2034  # read by the lifted writer
_PLUGIN_ROOT="$P" RUN_ID=r1
printf 'raw\n' > "$W/raw.txt"

_sha256() { if command -v shasum >/dev/null 2>&1; then shasum -a 256; else sha256sum; fi; }
closure_of_tree() {  # <rev> — the BOOTSTRAP side: same lines, from git
  # shellcheck disable=SC2086  # the dir list is a word list by design
  git -C "$P" ls-tree -r "$1" -- $_BP_CLOSURE_DIRS \
    | awk -F'\t' '{split($1,m," "); print m[3] " " $2}' | grep -v '/__pycache__/' \
    | LC_ALL=C sort -k2 | _sha256 | cut -d' ' -f1
}
HEADC=ffeeddccbbaa99887766554433221100 TAILC=00112233445566778899aabbccddeeff
# Dispatch-time identity is re-taken per call here, so each call sees the tree as it is now.
recorded() { _BP_IDENTITY_AT_DISPATCH=$(_bp_runner_identity) \
               && _bp_write_receipt codex codex "p" "$W/raw.txt" "$HEADC" "$TAILC" \
               && jq -r .runner_closure "$W/reviews/codex-receipt.json"; }

c1=$(recorded)
[[ "$c1" == "$(closure_of_tree HEAD)" ]] && ok "recorded closure equals the committed tree's" \
  || bad "recorded closure $c1 != tree $(closure_of_tree HEAD)"
[[ "$(jq -r .runner_blob "$W/reviews/codex-receipt.json")" == "$(git -C "$P" rev-parse HEAD:skills/blueprint-review/scripts/run.sh)" ]] \
  && ok "runner_blob is the runner file's git blob" || bad "runner_blob mismatch"
[[ "$(jq -r '.input_canary_head + " " + .input_canary' "$W/reviews/codex-receipt.json")" == "$HEADC $TAILC" ]] \
  && ok "the receipt records both lens canaries" || bad "canaries not recorded"
[[ "$(jq -c '[.truncated,.reasons]' "$W/reviews/codex-receipt.json")" == '[false,[]]' ]] \
  && ok "an unchanged runner leaves the receipt clean" || bad "clean receipt was flagged"

_BP_IDENTITY_AT_DISPATCH=$(_bp_runner_identity)
printf 'swapped during the review\n' > "$P/hooks/gate-scripts/lib/marker_ops.py"
_bp_write_receipt codex codex "p" "$W/raw.txt" "$HEADC" "$TAILC"
[[ "$(jq -c '[.truncated,.reasons,.runner_closure==$c]' --arg c "$c1" "$W/reviews/codex-receipt.json")" == '[true,["runner_changed"],true]' ]] \
  && ok "code changed between dispatch and receipt flags runner_changed, keeping the dispatch identity" \
  || bad "a mid-review code swap was not flagged"
git -C "$P" checkout -q -- hooks/gate-scripts/lib/marker_ops.py

mkdir -p "$P/scripts/lib/__pycache__"; printf 'x' > "$P/scripts/lib/__pycache__/a.pyc"
printf 'changed\n' > "$P/other/ignored.txt"
[[ "$(recorded)" == "$c1" ]] && ok "__pycache__ and files outside the closure dirs do not move it" \
  || bad "closure moved on an excluded file"

printf 'lib edited\n' > "$P/scripts/lib/resolve-cli.sh"
[[ "$(recorded)" != "$c1" ]] && ok "editing a sourced lib moves the closure" || bad "closure missed a lib edit"
git -C "$P" checkout -q -- scripts/lib/resolve-cli.sh

ln -s resolve-cli.sh "$P/scripts/lib/alias.sh"
c2=$(recorded)
[[ "$c2" != "$c1" && "$c2" != "$(closure_of_tree HEAD)" ]] && ok "a symlink in the closure can never match a tree" \
  || bad "symlink did not break the closure"
rm "$P/scripts/lib/alias.sh"

printf 'agy: review prompt is 9B, over the argv ceiling (8B)\n' > "$W/agyraw.txt"
_BP_IDENTITY_AT_DISPATCH=$(_bp_runner_identity)
_bp_write_receipt agy agy "p" "$W/agyraw.txt" "$HEADC" "$TAILC"
[[ "$(jq -c '[.truncated,.reasons]' "$W/reviews/agy-receipt.json")" == '[true,["argv_refused"]]' ]] \
  && ok "an agy argv refusal sets the truncation flag" || bad "argv refusal not flagged"
_bp_write_receipt grok grok "p" "$W/nope.txt" "$HEADC" "$TAILC"
[[ "$(jq -c '[.truncated,.reasons]' "$W/reviews/grok-receipt.json")" == '[true,["raw_missing"]]' ]] \
  && ok "a missing raw file sets the truncation flag" || bad "missing raw not flagged"

eval "$(sed -n '/^_bp_mark_dispatched() {/,/^}/p' "$LOOP")"
_bp_mark_dispatched grok
[[ "$(jq -c '[.run_id,.slot,.truncated,.reasons]' "$W/reviews/grok-receipt.json")" == '["r1","grok",true,["not_finalized"]]' ]] \
  && ok "the dispatch record is a this-run receipt flagged not_finalized" || bad "dispatch record wrong"
_BP_IDENTITY_AT_DISPATCH=$(_bp_runner_identity)
_bp_write_receipt grok grok "p" "$W/raw.txt" "$HEADC" "$TAILC"
[[ "$(jq -c '[.truncated,.reasons]' "$W/reviews/grok-receipt.json")" == '[false,[]]' ]] \
  && ok "the post-exit receipt replaces the dispatch record" || bad "dispatch record not replaced"

echo; echo "  $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
