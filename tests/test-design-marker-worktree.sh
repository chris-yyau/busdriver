#!/usr/bin/env bash
# Tests for the worktree-safe design-review marker (Task 2).
#
# Design: docs/plans/2026-07-13-task2-worktree-design-marker.md (ADR-A..E, §5, §8).
# The architecture's correctness lives in the shared classifier gate_marker_pending
# (existence-keyed tokens under the git-common-dir); the gates are thin consumers.
# So the classifier layer is tested exhaustively here, plus end-to-end wiring for
# each gate. Case letters (a)-(y) map to design §8.
#
# All token/marker manipulation happens INSIDE this script — the PreToolUse marker
# guard sees only the top-level `bash tests/...` invocation, never these internal
# writes (same property that makes the review loop's inline prune legal).
#
# Usage: bash tests/test-design-marker-worktree.sh   (exit 0 = all pass)

# SC2312: $(...) exit-status masking is intentional throughout this harness.
# SC2015: `cond && ok || no` — ok/no only print+count and always return 0, so the
# A&&B||C caveat does not apply here.
# shellcheck disable=SC2312,SC2015
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
ROOT="$(pwd)"
R="$ROOT/hooks/gate-scripts/lib/resolve-repo-dir.sh"
PREIMPL="$ROOT/hooks/gate-scripts/pre-implementation-gate.sh"
CHECKDOC="$ROOT/hooks/gate-scripts/check-design-document.sh"

PASS=0; FAIL=0
ok(){ printf "  PASS  %s\n" "$1"; PASS=$((PASS + 1)); }
no(){ printf "  FAIL  %s :: %s\n" "$1" "${2:-}"; FAIL=$((FAIL + 1)); }
eq(){ [ "$2" = "$3" ] && ok "$1" || no "$1" "want=$3 got=$2"; }

TMPS=()
mkrepo(){
    local d; d="$(mktemp -d)"; TMPS+=("$d")
    git -C "$d" init -q
    git -C "$d" config user.email t@t; git -C "$d" config user.name t
    git -C "$d" commit -q --allow-empty -m init
    printf '%s' "$d"
}
cleanup(){ local d; for d in "${TMPS[@]:-}"; do [ -n "$d" ] && rm -rf "$d"; done; }
trap cleanup EXIT

# Run the classifier; sets PEXIT and writes NUL records to $RECS.
pending(){ RECS="$(mktemp)"; TMPS+=("$RECS"); PEXIT=0; bash "$R" pending "$1" >"$RECS" 2>/dev/null || PEXIT=$?; }
nrec(){ local n; n=$(tr -cd '\0' <"$RECS" | wc -c | tr -d ' '); echo $(( n / 4 )); }
recs_has(){ tr '\0' '\n' <"$RECS" | grep -qF "$1"; }

# Arm a doc from INSIDE (guard-invisible). Doc must exist.
arm(){ bash "$R" arm "$1" >/dev/null 2>&1; }
markerdir(){ bash "$R" dir "$1" 2>/dev/null; }

# Emit a Bash/Write hook payload. JSON-encode the paths (jq) so a path containing
# a quote/backslash/control byte can't corrupt the payload.
payload_write(){ jq -cn --arg fp "$1" --arg cwd "$2" '{tool_name:"Write",tool_input:{file_path:$fp},cwd:$cwd}'; }

echo "── (Step 1) classifier: arm / existence-keyed / exit codes ───────"

# (t) valid-token positive → exit 1, one token record carrying doc_path.
t="$(mkrepo)"; printf 'x\n' >"$t/doc.md"
pending "$t"; eq "empty repo → exit 0" "$PEXIT" "0"
arm "$t/doc.md"
pending "$t"; eq "(t) armed → exit 1" "$PEXIT" "1"
eq "(t) one record" "$(nrec)" "1"
recs_has "$t/doc.md" && ok "(t) record carries doc abspath" || no "(t) record carries doc abspath"

# (c) reviewed doc → its <sha>.* tokens pruned → exit 0.
glob="$(bash "$R" marker-glob "$t/doc.md")"; rm -f "${glob}"*
pending "$t"; eq "(c) after prune → exit 0" "$PEXIT" "0"

# (b) two distinct docs → distinct sha; prune A leaves B blocking.
t="$(mkrepo)"; printf a >"$t/A.md"; printf b >"$t/B.md"
arm "$t/A.md"; arm "$t/B.md"
pending "$t"; eq "(b) two docs armed → exit 1" "$PEXIT" "1"; eq "(b) two records" "$(nrec)" "2"
ga="$(bash "$R" marker-glob "$t/A.md")"; rm -f "${ga}"*
pending "$t"; eq "(b) prune A → still exit 1 (B pending)" "$PEXIT" "1"; eq "(b) one record left" "$(nrec)" "1"
recs_has "$t/B.md" && ok "(b) remaining record is B" || no "(b) remaining record is B"

# (i) lost-rearm race (KEYSTONE): arm T1; snapshot; write PASS into doc; re-arm T2;
# prune snapshot → gate still BLOCKS because T2 exists (existence-keyed, not PASS).
t="$(mkrepo)"; printf 'PENDING\n' >"$t/doc.md"
arm "$t/doc.md"
snap=(); g="$(bash "$R" marker-glob "$t/doc.md")"; for f in "${g}"*; do snap+=("$f"); done   # snapshot {T1}
printf '<!-- design-reviewed: PASS -->\n' >>"$t/doc.md"   # loop writes PASS (:1156-1166)
arm "$t/doc.md"                                            # re-arm → T2 (new nonce)
rm -f "${snap[@]}"                                         # prune ONLY the snapshot
pending "$t"; eq "(i) lost-rearm: T2 survives → exit 1 despite PASS" "$PEXIT" "1"

# (d) malformed tokens → unparseable pending, reported by source_path.
t="$(mkrepo)"; md="$(markerdir "$t")"; mkdir -p "$md"
z64="$(printf '%064d' 0)"
printf '/p\n'          >"$md/${z64}.aa"   # hash mismatch
printf ''              >"$md/${z64}.bb"   # empty
printf '/p\r\n'        >"$md/${z64}.cc"   # CR in body
printf '/p\n\n'        >"$md/${z64}.dd"   # extra trailing LF
printf 'notabs\n'      >"$md/${z64}.ee"   # not absolute
pending "$t"; eq "(d) malformed tokens → exit 1" "$PEXIT" "1"
recs_has "unparseable" && ok "(d) reason=unparseable present" || no "(d) reason=unparseable present"

# valid token whose body is a real abspath but that also has a forged PASS in the
# doc → still blocks (existence-keyed forge-resistance) — subsumed by (i)/(t).

echo "── (r/v) resolution-failure policy ──────────────────────────────"

# (v) ENOREPO: a non-git dir → exit 0 (allow; fail-before would block).
nd="$(mktemp -d)"; TMPS+=("$nd")
pending "$nd"; eq "(v) ENOREPO non-git dir → exit 0" "$PEXIT" "0"

# (r1) absent token dir (ENOENT) + no legacy → exit 0.
t="$(mkrepo)"; pending "$t"; eq "(r) absent token dir → exit 0" "$PEXIT" "0"

# (r2) token-dir LIST failure (chmod 000 an existing dir) → exit 2.
if [ "$(id -u)" != "0" ]; then
    t="$(mkrepo)"; md="$(markerdir "$t")"; mkdir -p "$md"; chmod 000 "$md"
    pending "$t"; chmod 755 "$md"
    eq "(r) unlistable token dir → exit 2" "$PEXIT" "2"
else
    ok "(r) unlistable token dir → exit 2 [skipped as root]"
fi

# (r3) unreadable INDIVIDUAL token → exit-1 pending (not exit 2).
if [ "$(id -u)" != "0" ]; then
    t="$(mkrepo)"; md="$(markerdir "$t")"; mkdir -p "$md"
    sha="$(bash "$R" sha "/x")"; printf '/x\n' >"$md/${sha}.ff"; chmod 000 "$md/${sha}.ff"
    pending "$t"; chmod 644 "$md/${sha}.ff" 2>/dev/null || true
    eq "(r) unreadable token → exit 1" "$PEXIT" "1"
    recs_has "unreadable" && ok "(r) reason=unreadable" || no "(r) reason=unreadable"
else
    ok "(r) unreadable token → exit 1 [skipped as root]"
fi

echo "── (y) NUL record round-trip ────────────────────────────────────"
# A token whose source_path contains a space round-trips through the NUL stream,
# reconstructed with the ADR-C caller idiom (guards against $()-capture stripping
# records). A newline IN a path can't reach a token body — ADR-B rejects embedded
# CR/LF as unparseable — so the realistic streaming hazard is spaces in paths.
spp="$(mktemp -d)"; TMPS+=("$spp"); sp="$spp/has space"; mkdir -p "$sp"
git -C "$sp" init -q; git -C "$sp" config user.email t@t; git -C "$sp" config user.name t
printf x >"$sp/doc.md"; arm "$sp/doc.md"
pending "$sp"
got=""; i=0; while IFS= read -r -d '' field; do i=$((i + 1)); [ $(( i % 4 )) -eq 2 ] && got="$field"; done <"$RECS"
case "$got" in *"has space"*) ok "(y) space in source_path round-trips intact" ;; *) no "(y) space in source_path round-trips" "got=[$got]" ;; esac

echo "── (f) git init --separate-git-dir ──────────────────────────────"
gd="$(mktemp -d)"; wt="$(mktemp -d)"; TMPS+=("$gd" "$wt")
git init -q --separate-git-dir="$gd" "$wt" >/dev/null 2>&1
git -C "$wt" config user.email t@t; git -C "$wt" config user.name t
mdir="$(markerdir "$wt")"
gdp="$(cd "$gd" && pwd -P)"   # compare physical paths (macOS /var → /private/var)
case "$mdir" in "$gdp"/*) ok "(f) marker dir resolves under separate git dir" ;; *) no "(f) marker dir under separate git dir" "got=$mdir want-prefix=$gdp" ;; esac

echo "── (a/x) linked worktrees ───────────────────────────────────────"
# busdriver-style linked worktree homed under <main>/.claude/worktrees/<name>.
main="$(mkrepo)"; wtname="$main/.claude/worktrees/w1"
git -C "$main" worktree add -q -b feat "$wtname" >/dev/null 2>&1
if [ -d "$wtname" ]; then
    printf a >"$main/docs-plan.md"; arm "$main/docs-plan.md"     # arm in MAIN
    # (a) the SAME shared marker dir is visible from the linked worktree.
    pending "$wtname"; eq "(a) doc armed in main → pending from linked worktree" "$PEXIT" "1"
    # (x1) review/prune from MAIN of a token armed in the WORKTREE stays fail-CLOSED
    # in the worktree (abspath key never cross-clears).
    printf b >"$wtname/wt-doc.md"; arm "$wtname/wt-doc.md"
    gmain="$(bash "$R" marker-glob "$main/docs-plan.md")"; rm -f "${gmain}"*   # prune only main's doc
    pending "$wtname"; eq "(x1) worktree token survives main's prune → exit 1" "$PEXIT" "1"
    recs_has "wt-doc.md" && ok "(x1) worktree doc still pending" || no "(x1) worktree doc still pending"
else
    no "(a/x) worktree add failed"
fi

echo "── (g) legacy marker union ──────────────────────────────────────"
# A legacy design-review-needed.local.md (no PASS) in the repo root → pending union.
t="$(mkrepo)"; mkdir -p "$t/.claude"
{ printf -- '---\nactive: true\n---\n\n- doc-legacy.md\n'; } >"$t/.claude/design-review-needed.local.md"
printf 'no marker here\n' >"$t/doc-legacy.md"
pending "$t"; eq "(g) legacy pending entry → exit 1" "$PEXIT" "1"
recs_has "legacy" && ok "(g) legacy record present" || no "(g) legacy record present"
# reviewed legacy doc → allow
printf '<!-- design-reviewed: PASS -->\n' >>"$t/doc-legacy.md"
pending "$t"; eq "(g/o) legacy doc with PASS → exit 0" "$PEXIT" "0"

echo "── (l/ADR-E) pre-implementation gate end-to-end ─────────────────"
# Impl Write from a linked worktree homed under .claude/worktrees/ must BLOCK.
# fail-before: pre-impl reads CWD-relative marker + .claude/ substring allowlist
# exempts the worktree path. pass-after: Steps 3 (existence-keyed + ADR-E).
main="$(mkrepo)"; wtname="$main/.claude/worktrees/w2"
git -C "$main" worktree add -q -b feat2 "$wtname" >/dev/null 2>&1
if [ -d "$wtname" ]; then
    printf a >"$main/docs-plan2.md"; arm "$main/docs-plan2.md"
    out="$(payload_write "$wtname/src/impl.sh" "$wtname" | bash "$PREIMPL" 2>/dev/null || true)"
    case "$out" in *'"block"'*) ok "(l/ADR-E) impl Write in linked worktree → BLOCK" ;; *) no "(l/ADR-E) impl Write in linked worktree → BLOCK [needs Step 3]" "got=$out" ;; esac
else
    no "(l) worktree add failed"
fi

echo "── (Step 2) detector arms a token end-to-end ────────────────────"
t="$(mkrepo)"; mkdir -p "$t/docs/plans"; printf '# plan\n' >"$t/docs/plans/DESIGN-x.md"
printf '{"tool_name":"Write","tool_input":{"file_path":"%s/docs/plans/DESIGN-x.md"}}' "$t" | bash "$CHECKDOC" >/dev/null 2>&1
pending "$t"; eq "(Step2) detector armed a token → pending exit 1" "$PEXIT" "1"

echo "── (specs) design-doc paths stay writable while a review pends ──"
# c0bdaf7f moved docs/superpowers/{plans,specs} → docs/{plans,specs}, but the
# gate's exemption list still named the old dir. A lowercase *-design.md under
# docs/specs/ also misses the case-sensitive *DESIGN*.md glob, so with any review
# pending the gate blocked the very spec the review waits on — a deadlock
# brainstorming could not write its way out of. Needs a pending marker: with none
# armed the gate approves everything and this test would pass vacuously.
t="$(mkrepo)"; printf x >"$t/doc.md"; arm "$t/doc.md"
out="$(payload_write "$t/src/impl.sh" "$t" | bash "$PREIMPL" 2>/dev/null || true)"
case "$out" in *'"block"'*) ok "(specs) control: impl Write blocks while review pends" ;; *) no "(specs) control: impl Write should block" "got=$out" ;; esac
out="$(payload_write "$t/docs/specs/2026-07-17-x-design.md" "$t" | bash "$PREIMPL" 2>/dev/null || true)"
case "$out" in *'"block"'*) no "(specs) docs/specs design doc must stay writable" "got=$out" ;; *) ok "(specs) docs/specs design doc stays writable" ;; esac
out="$(payload_write "$t/docs/plans/2026-07-17-x.md" "$t" | bash "$PREIMPL" 2>/dev/null || true)"
case "$out" in *'"block"'*) no "(specs) docs/plans plan doc must stay writable" "got=$out" ;; *) ok "(specs) docs/plans plan doc stays writable" ;; esac

echo "── (h) deleted pending doc still blocks ─────────────────────────"
t="$(mkrepo)"; printf x >"$t/doc.md"; arm "$t/doc.md"; rm -f "$t/doc.md"
pending "$t"; eq "(h) doc deleted, token remains → exit 1" "$PEXIT" "1"

echo "── (q/Step 5) marker-forge guard covers token paths ─────────────"
t="$(mkrepo)"; md="$(markerdir "$t")"; tokpath="$md/$(printf '%064d' 1).beef"
out="$(printf '{"tool_name":"Write","tool_input":{"file_path":"%s"},"cwd":"%s"}' "$tokpath" "$t" | bash "$PREIMPL" 2>/dev/null || true)"
case "$out" in *'"block"'*) ok "(q) Claude Write to a token path is blocked" ;; *) no "(q) Write to token path blocked" "got=$out" ;; esac
out="$(printf '{"tool_name":"Bash","tool_input":{"command":"rm -f %s"},"cwd":"%s"}' "$tokpath" "$t" | bash "$PREIMPL" 2>/dev/null || true)"
case "$out" in *'"block"'*) ok "(q) Claude Bash rm of a token path is blocked" ;; *) no "(q) Bash rm of token path blocked" "got=$out" ;; esac

echo "── (m) legacy marker in a linked worktree root ──────────────────"
main="$(mkrepo)"; wtm="$main/wt-m"; git -C "$main" worktree add -q -b featm "$wtm" >/dev/null 2>&1
if [ -d "$wtm" ]; then
    mkdir -p "$wtm/.claude"; printf -- '- wtdoc.md\n' >"$wtm/.claude/design-review-needed.local.md"; printf 'x\n' >"$wtm/wtdoc.md"
    pending "$main"; eq "(m) legacy marker in linked worktree root → union blocks" "$PEXIT" "1"
else
    no "(m) worktree add failed"
fi

echo "── (x2) divergent same-relpath docs across branches → no cross-clear ─"
main="$(mkrepo)"; wtx="$main/wt-x"; git -C "$main" worktree add -q -b featx "$wtx" >/dev/null 2>&1
if [ -d "$wtx" ]; then
    mkdir -p "$main/d" "$wtx/d"
    printf 'A version\n' >"$main/d/same.md"; printf 'B version\n' >"$wtx/d/same.md"  # divergent, same relpath
    arm "$main/d/same.md"; arm "$wtx/d/same.md"                                       # distinct abspath → distinct sha
    gA="$(bash "$R" marker-glob "$main/d/same.md")"; rm -f "${gA}"*                    # "review" branch-a only
    pending "$wtx"; eq "(x2) branch-b token NOT pruned by branch-a review → exit 1" "$PEXIT" "1"
    recs_has "$wtx/d/same.md" && ok "(x2) branch-b divergent doc still pending" || no "(x2) branch-b still pending"
else
    no "(x2) worktree add failed"
fi

echo "── (w) python3-missing post-migration → pure-shell block ────────"
bindir="$(mktemp -d)"; TMPS+=("$bindir")
for tool in git bash ls sed cat rm grep dirname basename mktemp head tail sh env stat date printf; do
    src="$(command -v "$tool" 2>/dev/null)"; [ -n "$src" ] && ln -s "$src" "$bindir/$tool"
done  # deliberately NOT python3
t="$(mkrepo)"; printf x >"$t/doc.md"; arm "$t/doc.md"   # arm WHILE python3 is available
out="$( cd "$t" && printf '{"tool_name":"Write","tool_input":{"file_path":"%s/src/x.sh"},"cwd":"%s"}' "$t" "$t" | PATH="$bindir" bash "$PREIMPL" 2>/dev/null || true )"
case "$out" in *'"block"'*) ok "(w) python3 absent + pending token → pure-shell block" ;; *) no "(w) python3-missing → block" "got=$out" ;; esac
# and NOT pending → allow (no false block)
t2="$(mkrepo)"
out="$( cd "$t2" && printf '{"tool_name":"Write","tool_input":{"file_path":"%s/src/x.sh"},"cwd":"%s"}' "$t2" "$t2" | PATH="$bindir" bash "$PREIMPL" 2>/dev/null || true )"
case "$out" in *'"block"'*) no "(w) python3-missing + nothing pending should ALLOW" "got=$out" ;; *) ok "(w) python3 absent + nothing pending → allow" ;; esac

echo "── (HIGH-1) pure-shell fast-path is fail-closed on errors ───────"
# An unlistable token dir must NOT read as "empty" — pureshell returns 1 so the
# read gate falls through to the authoritative classifier (exit 2 = block).
if [ "$(id -u)" != "0" ]; then
    t="$(mkrepo)"; md="$(markerdir "$t")"; mkdir -p "$md"; chmod 000 "$md"
    bash "$R" pending-pureshell "$t"; pshx=$?; chmod 755 "$md"
    eq "(HIGH-1) unlistable token dir → pureshell 1 (not fast-allow)" "$pshx" "1"
else
    ok "(HIGH-1) pureshell fail-closed [skipped as root]"
fi

echo "── (HIGH-3) dangling-symlink marker state is fail-closed ────────"
if [ "$(id -u)" != "0" ]; then
    t="$(mkrepo)"; md="$(markerdir "$t")"; mkdir -p "$(dirname "$md")"
    ln -s /nonexistent-marker-target "$md"          # marker dir = DANGLING symlink
    bash "$R" pending-pureshell "$t"; eq "(HIGH-3) dangling token dir → pureshell 1" "$?" "1"
    bash "$R" pending "$t" >/dev/null 2>&1; eq "(HIGH-3) dangling token dir → classifier exit 2" "$?" "2"
    rm -f "$md"
else ok "(HIGH-3) dangling symlink [skipped as root]"; fi

echo "── (HIGH-2) C-quoted worktree path defers to authoritative ──────"
main="$(mkrepo)"; wtq="$main/wt$(printf '\t')q"      # tab in name → git C-quotes it
if git -C "$main" worktree add -q "$wtq" -b featq >/dev/null 2>&1; then
    mkdir -p "$wtq/.claude"; printf -- '- d.md\n' >"$wtq/.claude/design-review-needed.local.md"; printf x >"$wtq/d.md"
    bash "$R" pending-pureshell "$main"; eq "(HIGH-2) C-quoted worktree → pureshell 1 (defer)" "$?" "1"
    bash "$R" pending "$main" >/dev/null 2>&1; eq "(HIGH-2) C-quoted worktree legacy → classifier blocks" "$?" "1"
else ok "(HIGH-2) C-quoted worktree [git rejected tab path — skipped]"; fi

echo "── (HIGH-glob) newline-only token filename is not fast-allowed ──"
t="$(mkrepo)"; md="$(markerdir "$t")"; mkdir -p "$md"
nlf=$'\n'; : > "$md/$nlf"   # token file whose NAME is a single newline byte ($'\n', not $() which strips)
bash "$R" pending-pureshell "$t"; eq "(glob) newline-named entry → pureshell 1" "$?" "1"
bash "$R" pending "$t" >/dev/null 2>&1; eq "(glob) newline-named entry → classifier 1" "$?" "1"

echo "── (anchor) relative file_path resolves against PAYLOAD cwd ─────"
ra="$(mkrepo)"; printf x >"$ra/doc.md"; arm "$ra/doc.md"   # repo A: pending token
rb="$(mkrepo)"                                             # repo B: clean
out="$( cd "$rb" && printf '{"tool_name":"Write","tool_input":{"file_path":"src/impl.sh"},"cwd":"%s"}' "$ra" | bash "$PREIMPL" 2>/dev/null || true )"
case "$out" in *'"block"'*) ok "(anchor) relative path + cwd=pending-repo → BLOCK" ;; *) no "(anchor) relative path anchors to payload cwd" "got=$out" ;; esac

echo
echo "════ design-marker-worktree: $PASS passed, $FAIL failed ════"
[ "$FAIL" -eq 0 ]
