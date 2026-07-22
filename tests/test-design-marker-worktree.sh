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

echo "── (#449) Write of a reviewed doc strips PASS→PENDING (no stale-PASS-with-token) ─"
# Emit a Write payload carrying cwd (production always does) — the strip's symlink-
# containment anchors on the payload cwd (the operator's session repo).
dpay(){ printf '{"tool_name":"Write","tool_input":{"file_path":"%s"},"cwd":"%s"}' "$1" "$2"; }
# A Write re-opens review (arms a token). Older code PRESERVED a committed-HEAD PASS,
# leaving the doc reading PASS while the armed token blocked every worktree — a stale
# lie the operator never knew to re-review out of. The detector must strip PASS→PENDING
# so the doc's marker matches the re-armed token.
t="$(mkrepo)"; mkdir -p "$t/docs/plans"
printf '# plan\n\n<!-- design-reviewed: PASS -->\n' >"$t/docs/plans/DESIGN-rev.md"
git -C "$t" add -A && git -C "$t" commit -q -m 'reviewed doc'   # HEAD now carries PASS
dpay "$t/docs/plans/DESIGN-rev.md" "$t" | bash "$CHECKDOC" >/dev/null 2>&1
grep -q '<!-- design-reviewed: PENDING -->' "$t/docs/plans/DESIGN-rev.md" \
    && ok "(449) Write of HEAD-PASS doc → marker downgraded to PENDING" \
    || no "(449) Write of HEAD-PASS doc → PENDING" "still: $(grep -o 'design-reviewed: [A-Z]*' "$t/docs/plans/DESIGN-rev.md")"
grep -q '<!-- design-reviewed: PASS -->' "$t/docs/plans/DESIGN-rev.md" \
    && no "(449) stale PASS must not survive the Write" \
    || ok "(449) no stale PASS left in the doc"
pending "$t"; eq "(449) token armed → doc+token both PENDING (consistent)" "$PEXIT" "1"
# (449-inline) strip ONLY the WHOLE-LINE PASS (the only form _doc_reviewed honors) —
# an inline-prose marker the reader deliberately ignores must NOT be corrupted. Codex
# PR-review finding: an unanchored/`g` strip would mangle a doc that discusses markers.
t="$(mkrepo)"; mkdir -p "$t/docs/plans"
printf '# plan\nExample: the <!-- design-reviewed: PASS --> marker authorizes impl.\n<!-- design-reviewed: PASS -->\n' >"$t/docs/plans/DESIGN-in.md"
dpay "$t/docs/plans/DESIGN-in.md" "$t" | bash "$CHECKDOC" >/dev/null 2>&1
grep -qxE '[[:space:]]*<!-- design-reviewed: PENDING -->[[:space:]]*' "$t/docs/plans/DESIGN-in.md" \
    && ok "(449-inline) whole-line PASS downgraded to PENDING" \
    || no "(449-inline) whole-line PASS → PENDING" "$(cat "$t/docs/plans/DESIGN-in.md")"
grep -qF 'the <!-- design-reviewed: PASS --> marker authorizes' "$t/docs/plans/DESIGN-in.md" \
    && ok "(449-inline) inline-prose marker left intact (reader ignores it)" \
    || no "(449-inline) inline prose must not be mutated"
# (449-warn) a fail-open hook can't block, but a SILENT strip failure would leave a
# stale PASS beside the armed token. Force sed failure (read-only parent dir → no temp)
# and assert the operator is warned. Codex PR-review finding.
if [ "$(id -u)" != "0" ]; then
    t="$(mkrepo)"; mkdir -p "$t/docs/plans"
    printf '# plan\n<!-- design-reviewed: PASS -->\n' >"$t/docs/plans/DESIGN-ro.md"
    chmod 0555 "$t/docs/plans"   # read-only DIR → atomic mkstemp can't create the temp → downgrade fails
    _warn="$(dpay "$t/docs/plans/DESIGN-ro.md" "$t" | bash "$CHECKDOC" 2>&1 >/dev/null)"
    chmod 0755 "$t/docs/plans"
    case "$_warn" in *"still reads PASS"*) ok "(449-warn) silent strip failure warns operator" ;; *) no "(449-warn) strip failure must warn" "got=$_warn" ;; esac
else
    ok "(449-warn) strip-failure warning [skipped as root]"
fi
# (449-tab) a TAB-indented whole-line PASS must strip too — the reader honors `[ \t]`
# padding, so the strip must match space+tab portably. `[ \t]` in an ERE bracket is
# literal on BSD sed, so a tab marker would survive on macOS; `[[:blank:]]` fixes it.
t="$(mkrepo)"; mkdir -p "$t/docs/plans"
printf '# plan\n\t<!-- design-reviewed: PASS -->\n' >"$t/docs/plans/DESIGN-tab.md"
dpay "$t/docs/plans/DESIGN-tab.md" "$t" | bash "$CHECKDOC" >/dev/null 2>&1
grep -q '<!-- design-reviewed: PASS -->' "$t/docs/plans/DESIGN-tab.md" \
    && no "(449-tab) tab-indented PASS must be stripped" "$(cat "$t/docs/plans/DESIGN-tab.md")" \
    || ok "(449-tab) tab-indented whole-line PASS stripped (portable [[:blank:]])"
# (449-crlf) a CRLF doc: the reader reads in TEXT mode, so \r\n→\n and the marker IS
# honored; a byte-level strip that ignores the trailing \r would leave an honored PASS
# beside the armed token — the #449 lie for CRLF docs. Assert via the reader itself.
t="$(mkrepo)"; mkdir -p "$t/docs/plans"
printf '# plan\r\n<!-- design-reviewed: PASS -->\r\n' >"$t/docs/plans/DESIGN-crlf.md"
dpay "$t/docs/plans/DESIGN-crlf.md" "$t" | bash "$CHECKDOC" >/dev/null 2>&1
if python3 "$ROOT/hooks/gate-scripts/lib/marker_ops.py" reviewed "$t/docs/plans/DESIGN-crlf.md" >/dev/null 2>&1; then
    no "(449-crlf) CRLF PASS must be stripped (reader still honors it)" "$(cat "$t/docs/plans/DESIGN-crlf.md")"
else
    ok "(449-crlf) CRLF PASS stripped → reader no longer honors it"
fi
# ...and the strip preserves the CRLF line ending (only PASS→PENDING changes, no LF
# conversion / mixed endings). Codex finding.
if command -v xxd >/dev/null 2>&1; then
    xxd "$t/docs/plans/DESIGN-crlf.md" | grep -q '2d2d 3e0d 0a' \
        && ok "(449-crlf) PENDING line keeps its CRLF ending (no formatting churn)" \
        || no "(449-crlf) CRLF ending must be preserved on downgrade" "$(xxd "$t/docs/plans/DESIGN-crlf.md" | tail -2)"
else
    ok "(449-crlf) CRLF-preservation check [xxd unavailable — skipped]"
fi
# (449-cr) bare-CR (classic-Mac) line endings: the reader reads in TEXT mode where a lone
# \r is a line boundary, so it honors the marker; a byte-level LF-only shell strip could
# not see the marker as a whole line. The shared-engine downgrade handles it — this is the
# case that motivated moving the strip into marker_ops. Codex finding.
t="$(mkrepo)"; mkdir -p "$t/docs/plans"
printf '# plan\r<!-- design-reviewed: PASS -->\rnext line\r' >"$t/docs/plans/DESIGN-cr.md"
dpay "$t/docs/plans/DESIGN-cr.md" "$t" | bash "$CHECKDOC" >/dev/null 2>&1
if python3 "$ROOT/hooks/gate-scripts/lib/marker_ops.py" reviewed "$t/docs/plans/DESIGN-cr.md" >/dev/null 2>&1; then
    no "(449-cr) bare-CR PASS must be stripped (reader still honors it)" "$(cat "$t/docs/plans/DESIGN-cr.md")"
else
    ok "(449-cr) bare-CR PASS stripped → reader no longer honors it"
fi
# (449-meta) the atomic downgrade preserves the file MODE (Codex P2) but bumps mtime so
# watchers see the change (Codex — copystat restored the stale mtime).
t="$(mkrepo)"; mkdir -p "$t/docs/plans"
printf '# plan\n<!-- design-reviewed: PASS -->\n' >"$t/docs/plans/DESIGN-meta.md"
chmod 0640 "$t/docs/plans/DESIGN-meta.md"
touch -t 202001010000 "$t/docs/plans/DESIGN-meta.md"   # backdate to 2020
_old_mt="$(stat -c %Y "$t/docs/plans/DESIGN-meta.md" 2>/dev/null || stat -f %m "$t/docs/plans/DESIGN-meta.md")"
dpay "$t/docs/plans/DESIGN-meta.md" "$t" | bash "$CHECKDOC" >/dev/null 2>&1
_mode="$(stat -c %a "$t/docs/plans/DESIGN-meta.md" 2>/dev/null || stat -f %Lp "$t/docs/plans/DESIGN-meta.md")"
_new_mt="$(stat -c %Y "$t/docs/plans/DESIGN-meta.md" 2>/dev/null || stat -f %m "$t/docs/plans/DESIGN-meta.md")"
[ "$_mode" = 640 ] && ok "(449-meta) file mode 0640 preserved through downgrade" || no "(449-meta) mode must be preserved" "got=$_mode"
[ "$_new_mt" -gt "$_old_mt" ] && ok "(449-meta) mtime bumped so watchers see the change" || no "(449-meta) mtime must advance" "old=$_old_mt new=$_new_mt"
# (449-hardlink) KEYSTONE: an in-repo design doc HARD-LINKED to a file OUTSIDE the repo.
# A hard link is a second path to the same inode that realpath containment cannot see,
# so an in-place truncate+rewrite would modify the external alias too — an out-of-repo
# write primitive (Codex HIGH). The atomic temp+os.replace repoints ONLY the in-repo
# path (new inode), never touching the external alias: the external file keeps its
# content byte-for-byte. The in-repo path is downgraded. A hard-linked alias not being
# synced is the accepted, safe residual — containment strictly outranks it.
if command -v ln >/dev/null 2>&1; then
    ext="$(mktemp -d)"; TMPS+=("$ext")
    printf 'EXTERNAL PAYLOAD do not touch\n<!-- design-reviewed: PASS -->\n' >"$ext/victim.md"
    _ext_before="$(cat "$ext/victim.md")"
    t="$(mkrepo)"; mkdir -p "$t/docs/plans"
    if ln "$ext/victim.md" "$t/docs/plans/DESIGN-hl.md" 2>/dev/null; then
        dpay "$t/docs/plans/DESIGN-hl.md" "$t" | bash "$CHECKDOC" >/dev/null 2>&1
        [ "$(cat "$ext/victim.md")" = "$_ext_before" ] \
            && ok "(449-hardlink) external hard-link alias NOT modified (no out-of-repo write)" \
            || no "(449-hardlink) external alias must be untouched" "$(cat "$ext/victim.md")"
        grep -q '<!-- design-reviewed: PENDING -->' "$t/docs/plans/DESIGN-hl.md" \
            && ok "(449-hardlink) in-repo path downgraded to PENDING (new inode)" \
            || no "(449-hardlink) in-repo path must be downgraded" "$(cat "$t/docs/plans/DESIGN-hl.md")"
    else
        ok "(449-hardlink) cross-device hard link unsupported here [skipped]"
    fi
else
    ok "(449-hardlink) ln unavailable [skipped]"
fi
# (449-symlink) an IN-repo symlinked design doc: the strip edits the resolved TARGET
# (in this repo, contained under the payload-cwd repo top), not the link — so the
# target's PASS→PENDING and the symlink survives (sed on the resolved regular file
# never severs the link). Codex finding.
t="$(mkrepo)"; mkdir -p "$t/docs/plans" "$t/real"
printf '# plan\n<!-- design-reviewed: PASS -->\n' >"$t/real/DESIGN.md"
ln -s ../../real/DESIGN.md "$t/docs/plans/DESIGN-link.md"
dpay "$t/docs/plans/DESIGN-link.md" "$t" | bash "$CHECKDOC" >/dev/null 2>&1
[ -L "$t/docs/plans/DESIGN-link.md" ] \
    && ok "(449-symlink) in-repo symlink survives (not severed)" \
    || no "(449-symlink) symlink must not be replaced by a regular file"
grep -q '<!-- design-reviewed: PENDING -->' "$t/real/DESIGN.md" \
    && ok "(449-symlink) in-repo target's PASS downgraded to PENDING" \
    || no "(449-symlink) in-repo target must be stripped" "$(cat "$t/real/DESIGN.md")"
# (449-symlink-parent) a symlinked PARENT dir escaping to a NON-repo dir: the leaf is a
# regular file (leaf `-L` would miss it), but sed would write OUTSIDE the repo (Codex
# HIGH). The physical path is not under the payload-cwd repo top → skip + warn.
ext="$(mktemp -d)"; TMPS+=("$ext")
t="$(mkrepo)"; mkdir -p "$t/docs"
ln -s "$ext" "$t/docs/plans"                 # docs/plans -> external dir (outside the repo)
printf '# plan\n<!-- design-reviewed: PASS -->\n' >"$t/docs/plans/DESIGN.md"   # lands in $ext/DESIGN.md
_ppwarn="$(dpay "$t/docs/plans/DESIGN.md" "$t" | bash "$CHECKDOC" 2>&1 >/dev/null)"
grep -q '<!-- design-reviewed: PASS -->' "$ext/DESIGN.md" \
    && ok "(449-symlink-parent) external file via symlinked PARENT NOT rewritten" \
    || no "(449-symlink-parent) must not write outside the repo" "$(cat "$ext/DESIGN.md")"
case "$_ppwarn" in *"still reads PASS"*) ok "(449-symlink-parent) operator warned" ;; *) no "(449-symlink-parent) must warn" "got=$_ppwarn" ;; esac
# (449-xrepo) KEYSTONE: a symlinked PARENT pointing into a DIFFERENT git repo. `git -C
# dirname` would return the FOREIGN repo's top and authorize a write into it; anchoring
# on the payload-cwd repo instead → foreign target not under this repo → skip + warn.
xrepo="$(mkrepo)"; mkdir -p "$xrepo/docs/plans"
printf '# plan\n<!-- design-reviewed: PASS -->\n' >"$xrepo/docs/plans/VICTIM.md"
t="$(mkrepo)"; mkdir -p "$t/docs"
ln -s "$xrepo/docs/plans" "$t/docs/plans"    # docs/plans -> another repo's docs/plans
_xwarn="$(dpay "$t/docs/plans/VICTIM.md" "$t" | bash "$CHECKDOC" 2>&1 >/dev/null)"
grep -q '<!-- design-reviewed: PASS -->' "$xrepo/docs/plans/VICTIM.md" \
    && ok "(449-xrepo) file in a DIFFERENT repo via symlinked parent NOT rewritten" \
    || no "(449-xrepo) cross-repo escape must be blocked" "$(cat "$xrepo/docs/plans/VICTIM.md")"
case "$_xwarn" in *"still reads PASS"*) ok "(449-xrepo) operator warned" ;; *) no "(449-xrepo) must warn" "got=$_xwarn" ;; esac
# (449-pyhijack) a repo-local sitecustomize.py overriding os.path.realpath (to force a
# contained path) must NOT bypass the containment guard — the realpath calls run
# python3 -I, so PYTHONPATH/cwd sitecustomize never loads. Codex finding. Escape target
# stays external → skip → not rewritten.
ext="$(mktemp -d)"; TMPS+=("$ext")
t="$(mkrepo)"; mkdir -p "$t/docs"
ln -s "$ext" "$t/docs/plans"
printf '# plan\n<!-- design-reviewed: PASS -->\n' >"$t/docs/plans/DESIGN.md"   # → $ext/DESIGN.md
cat >"$t/sitecustomize.py" <<PYEOF
import os
os.path.realpath = lambda p, *a, **k: "$t/docs/plans/DESIGN.md"   # lie: claim containment
PYEOF
( cd "$t" && dpay "$t/docs/plans/DESIGN.md" "$t" | bash "$CHECKDOC" >/dev/null 2>&1 )
grep -q '<!-- design-reviewed: PASS -->' "$ext/DESIGN.md" \
    && ok "(449-pyhijack) sitecustomize realpath-override cannot force an external write" \
    || no "(449-pyhijack) isolated realpath (-I) must resist hijack" "$(cat "$ext/DESIGN.md")"

echo "── (#446) detector uses the gate's PHYSICAL grammar (no lexical divergence) ─"
# The detector once classified redirect/file targets LEXICALLY while the gate's
# exemption resolved them via realpath. A symlinked docs/plans -> src armed a
# spurious repo-wide review for an impl write the gate then treated as impl. The
# detector now shares gate_design_doc_exempt, so a path that escapes the design-doc
# location through a symlinked PARENT or LEAF must NOT arm a review.
# (446a) symlinked PARENT: docs/plans -> ../build → write lands at build/impl.md.
# `build/` is NOT in the structural-dir exclusion list, so this exercises the
# physical (realpath) grammar itself, not the incidental src/ exclusion.
t="$(mkrepo)"; mkdir -p "$t/build" "$t/docs"; ln -s ../build "$t/docs/plans"
printf 'impl\n' >"$t/docs/plans/impl.md"
printf '{"tool_name":"Write","tool_input":{"file_path":"%s/docs/plans/impl.md"}}' "$t" | bash "$CHECKDOC" >/dev/null 2>&1
pending "$t"; eq "(446a) symlinked-parent impl.md NOT armed (physical grammar)" "$PEXIT" "0"
# (446b) symlinked LEAF: docs/plans/x.md -> ../../src/impl.sh (real docs/plans dir).
t="$(mkrepo)"; mkdir -p "$t/src" "$t/docs/plans"; printf 'code\n' >"$t/src/impl.sh"
ln -s ../../src/impl.sh "$t/docs/plans/x.md"
printf '{"tool_name":"Write","tool_input":{"file_path":"%s/docs/plans/x.md"}}' "$t" | bash "$CHECKDOC" >/dev/null 2>&1
pending "$t"; eq "(446b) symlinked-leaf x.md→src/impl.sh NOT armed" "$PEXIT" "0"
# (446c) control: a GENUINE doc in the same real docs/plans dir still arms (no over-suppression).
printf '# d\n' >"$t/docs/plans/DESIGN-real.md"
printf '{"tool_name":"Write","tool_input":{"file_path":"%s/docs/plans/DESIGN-real.md"}}' "$t" | bash "$CHECKDOC" >/dev/null 2>&1
pending "$t"; eq "(446c) genuine docs/plans design doc still arms" "$PEXIT" "1"

echo "── (#448) relative file_path resolves against payload cwd, not hook cwd ─"
# Codex P2 on #448: a Write/Edit with a RELATIVE file_path passed the raw string to
# gate_design_doc_exempt, whose realpath then anchored on the HOOK PROCESS cwd, not
# the payload's authoritative cwd. When they differ and the hook cwd has a symlinked
# docs/plans, a genuine design doc could be classified non-design and armed no marker
# (fail-OPEN). Use a DIRECTORY-qualified doc (docs/plans/notes.md) — a DESIGN*/PLAN*
# basename would pass on name alone and never exercise the realpath anchor.
t="$(mkrepo)"; mkdir -p "$t/docs/plans"; printf '# genuine plan\n' >"$t/docs/plans/notes.md"
decoy="$(mktemp -d)"; TMPS+=("$decoy"); mkdir -p "$decoy/docs" "$decoy/build"
ln -s ../build "$decoy/docs/plans"   # process-cwd realpath would escape docs/plans/ → non-design
( cd "$decoy" && printf '{"tool_name":"Write","tool_input":{"file_path":"docs/plans/notes.md"},"cwd":"%s"}' "$t" | bash "$CHECKDOC" >/dev/null 2>&1 )
pending "$t"; eq "(448) relative doc armed against payload cwd, not hook cwd" "$PEXIT" "1"

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
# `docs` must start a path segment: notdocs/ is not a docs dir and must not inherit
# the exemption. Nested (monorepo) docs dirs must keep it.
out="$(payload_write "$t/notdocs/specs/impl.sh" "$t" | bash "$PREIMPL" 2>/dev/null || true)"
case "$out" in *'"block"'*) ok "(specs) notdocs/specs/ does not inherit the exemption" ;; *) no "(specs) notdocs/specs/ must NOT be exempt" "got=$out" ;; esac
# ...and with a .md target, which actually REACHES the design-doc regex (a .sh
# never does — the regex is `.*\.md$`, so the .sh case above passes vacuously).
# An unanchored `docs/` alternative matched the `docs/specs/w.md` suffix of this
# path; the `(^|/)` boundary is what makes this assertion real.
out="$(payload_write "$t/notdocs/specs/w.md" "$t" | bash "$PREIMPL" 2>/dev/null || true)"
case "$out" in *'"block"'*) ok "(specs) notdocs/specs/w.md (.md) is not exempt" ;; *) no "(specs) notdocs/specs/w.md MUST NOT be exempt" "got=$out" ;; esac
out="$(payload_write "$t/packages/foo/docs/specs/x-design.md" "$t" | bash "$PREIMPL" 2>/dev/null || true)"
case "$out" in *'"block"'*) no "(specs) nested monorepo docs/specs must stay writable" "got=$out" ;; *) ok "(specs) nested monorepo docs/specs stays writable" ;; esac

# INVARIANT: every path the DETECTOR arms a review for must stay writable by the
# gate. Detector ([^/]+/)* covers nested docs, so root-anchoring the exemption
# would flag a doc as needing review while refusing the write that answers it.
# This pins the two together — narrow one without the other and this fails.
mkdir -p "$t/packages/foo/docs/specs"; printf '# d\n' >"$t/packages/foo/docs/specs/DESIGN-n.md"
printf '{"tool_name":"Write","tool_input":{"file_path":"%s/packages/foo/docs/specs/DESIGN-n.md"}}' "$t" | bash "$CHECKDOC" >/dev/null 2>&1
pending "$t"; eq "(specs) detector arms nested docs/specs → exit 1" "$PEXIT" "1"
out="$(payload_write "$t/packages/foo/docs/specs/DESIGN-n.md" "$t" | bash "$PREIMPL" 2>/dev/null || true)"
case "$out" in *'"block"'*) no "(specs) detector/exemption disagree — nested doc armed but not writable" "got=$out" ;; *) ok "(specs) detector-armed nested doc stays writable (no deadlock)" ;; esac

# Traversal: `docs/specs/../../src/impl.sh` matches the docs glob on the raw path
# but resolves to src/impl.sh — a pending review would be bypassed outright.
# Exemption is matched post-normalization, so the resolved target decides.
out="$(payload_write "$t/docs/specs/../../src/impl.sh" "$t" | bash "$PREIMPL" 2>/dev/null || true)"
case "$out" in *'"block"'*) ok "(specs) docs/specs/../.. traversal cannot bypass the gate" ;; *) no "(specs) traversal MUST NOT be exempt" "got=$out" ;; esac
out="$(payload_write "$t/src/../docs/specs/y-design.md" "$t" | bash "$PREIMPL" 2>/dev/null || true)"
case "$out" in *'"block"'*) no "(specs) traversal resolving INTO docs/specs must stay writable" "got=$out" ;; *) ok "(specs) traversal resolving INTO docs/specs stays writable" ;; esac

# RELATIVE file_path is a real shape: the marker anchor joins it to the payload
# cwd (see the (anchor) case below). A relative `../docs/specs/x.md` sent with
# cwd=<repo>/src resolves INTO docs/specs and must stay writable — matching the
# exemption on the raw string would leave the `..` and refuse the design doc,
# re-deadlocking the review. Found by Codex on PR #369.
mkdir -p "$t/src"
out="$(payload_write "../docs/specs/rel-design.md" "$t/src" | bash "$PREIMPL" 2>/dev/null || true)"
case "$out" in *'"block"'*) no "(specs) relative ../docs/specs from subdir cwd must stay writable" "got=$out" ;; *) ok "(specs) relative ../docs/specs from subdir cwd stays writable" ;; esac
out="$(payload_write "docs/specs/rel2-design.md" "$t" | bash "$PREIMPL" 2>/dev/null || true)"
case "$out" in *'"block"'*) no "(specs) relative docs/specs from repo-root cwd must stay writable" "got=$out" ;; *) ok "(specs) relative docs/specs from repo-root cwd stays writable" ;; esac
# The mirror: a relative traversal that escapes docs/ must still be refused.
out="$(payload_write "../docs/specs/../../src/impl.sh" "$t/src" | bash "$PREIMPL" 2>/dev/null || true)"
case "$out" in *'"block"'*) ok "(specs) relative traversal escaping docs/specs cannot bypass" ;; *) no "(specs) relative traversal MUST NOT be exempt" "got=$out" ;; esac

# LOCKSTEP: every shape the DETECTOR can arm must stay writable, or the gate
# deadlocks on the doc the review waits for. A fixed-depth glob cannot express the
# detector's ([^/]+/)* + unanchored match, so these shapes (nested, $STATE_DIR/,
# lowercase -design.md) each deadlocked under the earlier approximation.
for _rel in \
    "docs/team/specs/2026-07-17-x-design.md" \
    "docs/a/b/plans/2026-07-17-y.md" \
    ".claude/specs/z-design.md" \
    "design-notes.md" \
    "notdocs/specs/w.md" ; do
    # Fresh repo per iteration: markers are sticky per-repo, so reusing one repo
    # would let an earlier shape's armed marker make `pending` report 1 for a
    # shape the detector does NOT arm (e.g. notdocs/specs/w.md post-anchoring),
    # producing a phantom DEADLOCK. Isolate so `pending` reflects THIS shape only.
    t="$(mkrepo)"
    mkdir -p "$t/$(dirname "$_rel")"
    printf '# d\n' >"$t/$_rel"
    printf '{"tool_name":"Write","tool_input":{"file_path":"%s/%s"}}' "$t" "$_rel" | bash "$CHECKDOC" >/dev/null 2>&1
    pending "$t"
    if [ "$PEXIT" = "1" ]; then
        out="$(payload_write "$t/$_rel" "$t" | bash "$PREIMPL" 2>/dev/null || true)"
        case "$out" in
            *'"block"'*) no "(lockstep) detector arms $_rel but gate blocks it — DEADLOCK" "got=$out" ;;
            *) ok "(lockstep) detector-armed $_rel stays writable" ;;
        esac
    else
        ok "(lockstep) detector does not arm $_rel (nothing to reconcile)"
    fi
done

echo "── (statedir) normalize-unstable BUSDRIVER_STATE_DIR cannot deadlock ─"
# A STATE_DIR that os.path.normpath collapses (bare '.', '//', '/./', trailing /)
# matched the DETECTOR's raw path but vanished from the exemption's NORMALIZED
# path, deadlocking the doc — e.g. STATE_DIR=. with a relative `./specs/x.md`
# arms via `^\./…specs/` but normalizes to `specs/x.md`, which the exemption then
# refuses. The sanitizer now rejects such values (→ default .claude), so detector
# and exemption stay in lockstep. Each value must arm-then-allow or never arm.
for _sd in "." "a//b" "a/./b" "foo/" ; do
    t="$(mkrepo)"; mkdir -p "$t/specs"; printf '# d\n' >"$t/specs/x-design.md"
    ( cd "$t" && printf '{"tool_name":"Write","tool_input":{"file_path":"./specs/x-design.md"}}' \
        | BUSDRIVER_STATE_DIR="$_sd" bash "$CHECKDOC" >/dev/null 2>&1 )
    pending "$t"
    if [ "$PEXIT" = "1" ]; then
        out="$(payload_write "./specs/x-design.md" "$t" | BUSDRIVER_STATE_DIR="$_sd" bash "$PREIMPL" 2>/dev/null || true)"
        case "$out" in
            *'"block"'*) no "(statedir) STATE_DIR=$_sd armed ./specs but gate blocks — DEADLOCK" "got=$out" ;;
            *) ok "(statedir) STATE_DIR=$_sd armed doc stays writable" ;;
        esac
    else
        ok "(statedir) STATE_DIR=$_sd sanitized → ./specs not armed (no deadlock)"
    fi
done

echo "── (newline) embedded LF cannot smuggle an exempt second line ───"
# The design-doc arm matches with a LINE-oriented tool, so a path whose first line is
# an impl file and whose second line looks like a design doc would match on line 2 and
# exempt line 1. jq JSON-encodes the LF, so this is a reachable payload shape.
t="$(mkrepo)"; printf x >"$t/doc.md"; arm "$t/doc.md"
out="$(payload_write "$t/src/impl.sh
docs/specs/payload.md" "$t" | bash "$PREIMPL" 2>/dev/null || true)"
case "$out" in
    *'"block"'*) ok "(newline) LF-smuggled docs/specs line cannot exempt an impl write" ;;
    *) no "(newline) LF payload MUST NOT be exempt" "got=$out" ;;
esac

echo "── (pypath) repo-local json.py cannot forge an exempt path ──────"
# The exemption parser runs python3 in the payload's repo. Importing json BEFORE
# scrubbing sys.path let a repo-local json.py execute inside the gate and return a
# forged docs/specs path, exempting an arbitrary impl write. Isolated mode + a scrub
# that precedes the import closes it. The stub must never load: if it does, the gate
# exempts src/impl.sh and this fails.
t="$(mkrepo)"; printf x >"$t/doc.md"; arm "$t/doc.md"
cat >"$t/json.py" <<'PYEOF'
def load(*a, **k):
    return {"tool_input": {"file_path": "docs/specs/pwned-design.md"}, "cwd": "/"}
def loads(*a, **k):
    return {}
PYEOF
out="$( cd "$t" && payload_write "$t/src/impl.sh" "$t" | bash "$PREIMPL" 2>/dev/null || true )"
case "$out" in
    *'"block"'*) ok "(pypath) repo-local json.py cannot exempt an impl write" ;;
    *) no "(pypath) json.py HIJACKED the gate — impl write exempted" "got=$out" ;;
esac
# Control: same repo, same stub, a genuine design doc still resolves.
out="$( cd "$t" && payload_write "$t/docs/specs/real-design.md" "$t" | bash "$PREIMPL" 2>/dev/null || true )"
case "$out" in
    *'"block"'*) no "(pypath) genuine design doc must stay writable" "got=$out" ;;
    *) ok "(pypath) genuine design doc still writable alongside the stub" ;;
esac

echo "── (pypath-detector) repo-local json.py cannot disable the detector ─"
# check-design-document.sh parses the payload with python3 too. Importing json
# BEFORE scrubbing sys.path let a repo-local json.py hijack the DETECTOR so no
# marker arms — the pre-implementation gate then fast-allows every impl write
# (fail-OPEN, the same class this branch closes, at an 8th interpreter site the
# other fixes missed). Isolated mode + a scrub ahead of the import closes it: a
# genuine design doc must still arm its marker with the stub present.
t="$(mkrepo)"
cat >"$t/json.py" <<'PYEOF'
def load(*a, **k):
    return {}
def loads(*a, **k):
    return {}
PYEOF
mkdir -p "$t/docs/specs"; printf '# d\n' >"$t/docs/specs/real-design.md"
( cd "$t" && printf '{"tool_name":"Write","tool_input":{"file_path":"%s/docs/specs/real-design.md"}}' "$t" | bash "$CHECKDOC" >/dev/null 2>&1 )
pending "$t"; eq "(pypath-detector) json.py cannot suppress marker arming" "$PEXIT" "1"

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

echo "── (#356) cross-worktree provenance annotation in the block list ─"
# The shared marker dir blocks impl in every worktree; the render helper LOCATES
# the owning worktree (naming its current branch) so a blocked session doesn't
# misdiagnose an unrelated doc. Note is present iff the pending doc is in a
# DIFFERENT worktree than the write. Arm the doc IN a named-branch worktree so the
# owning branch is deterministic and can be asserted (a bare "another worktree"
# grep would pass even if the branch were missing/wrong).
main="$(mkrepo)"; wtn="$main/.claude/worktrees/wnote"
git -C "$main" worktree add -q -b annot-note "$wtn" >/dev/null 2>&1
if [ -d "$wtn" ]; then
    printf x >"$wtn/plan-note.md"; arm "$wtn/plan-note.md"         # arm IN wnote (branch annot-note)
    # (356a) rendered from MAIN's anchor → doc is in wnote → annotated + named.
    pending "$main"
    rn="$(bash "$R" render "$RECS" "$main" 2>/dev/null || true)"
    case "$rn" in *"another worktree"*) ok "(356a) foreign-worktree doc is annotated" ;; *) no "(356a) foreign-worktree doc annotated" "got=$rn" ;; esac
    case "$rn" in *annot-note*) ok "(356a) annotation names the owning branch" ;; *) no "(356a) annotation names owning branch" "got=$rn" ;; esac
    # (356b) rendered from wnote's OWN anchor (the doc's worktree) → NO annotation.
    pending "$wtn"
    rb="$(bash "$R" render "$RECS" "$wtn" 2>/dev/null || true)"
    case "$rb" in *"another worktree"*) no "(356b) same-worktree doc must NOT be annotated" "got=$rb" ;; *) ok "(356b) same-worktree doc is not annotated (no noise)" ;; esac
    # (356c) end-to-end: a blocked impl Write in MAIN carries the branch-named note.
    out="$(payload_write "$main/src/impl.sh" "$main" | bash "$PREIMPL" 2>/dev/null || true)"
    case "$out" in *'"block"'*) : ;; *) no "(356c) precondition: impl Write should block" "got=$out" ;; esac
    case "$out" in *annot-note*) ok "(356c) block reason names the arming worktree branch" ;; *) no "(356c) block reason carries the branch-named annotation" "got=$out" ;; esac
else
    no "(356) worktree add failed"
fi
# (356d) abandoned marker: the doc's directory is gone → flagged as abandoned, not
# silently rendered as a live doc (the drain-hint rm on the same line resolves it).
t="$(mkrepo)"; mkdir -p "$t/sub"; printf x >"$t/sub/doc.md"; arm "$t/sub/doc.md"; rm -rf "$t/sub"
pending "$t"
rd="$(bash "$R" render "$RECS" "$t" 2>/dev/null || true)"
case "$rd" in *abandoned*) ok "(356d) abandoned doc (dir gone) is flagged" ;; *) no "(356d) abandoned doc flagged" "got=$rd" ;; esac

echo
echo "════ design-marker-worktree: $PASS passed, $FAIL failed ════"
[ "$FAIL" -eq 0 ]
