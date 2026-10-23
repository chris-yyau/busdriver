# marker_check: a `case` pattern alternation `|` is read as a pipe (#776)

> **For agentic workers:** small change: one pure helper in `hooks/gate-scripts/lib/marker_check.py` (a case-pattern pre-pass) consulted by `_piped_shell_producers`, which gains a `case_ok=False` parameter set by its single caller in `_helper_invoked`, one new shell test, and the regenerated `.gate-integrity.lock`. Execute inline; no subagent fan-out.

**Goal:** Ordinary shell that runs no protected helper stops being refused with `Cannot call lease_slot.py directly` when it uses the POSIX numeric-validation `case` idiom (#776) — including when that idiom appears as text inside a heredoc body the segmenter reads as shell. Every shape that runs a helper today keeps blocking. The only verdicts that move from BLOCK to OK are commands whose trigger was a case PATTERN word evaluated as a pipeline stage, or a pattern `|` read as a pipe — e.g. row 1 below, and also `printf P | case x in a) :;; *) :;; esac`, where the fed `*` pattern was read as an unresolved receiver; no arm there reads stdin as a program, so OK is the correct verdict.

**Scope:** in `marker_check.py`: the new pre-pass, two consult points inside `_piped_shell_producers` plus its new `case_ok=False` parameter, and ONE line at its single call site in `_helper_invoked` (~5341-5345) that computes and passes `case_ok`. No other change to `_helper_invoked`, and none to `_split_with_ops`, `_norm_for_scan`, `_writes_marker`, the probes, `cmdword.py`, any allowlist, budget or timeout. Closes #776.

**Out of scope, by operator decision (2026-10-22):** the quoted-heredoc prose false block (#639). Two review rounds established that excising heredoc bodies necessarily moves file- and FIFO-staged transports from BLOCK to OK (the reader can be prepared in an earlier Bash call, so no command-text test can close it), which loosens the guard. #639 stays open; a follow-up issue records the measured shapes and the two refused designs (line-local and whole-command excision) so they are not re-proposed. Also not addressed: #877 (fail-open inside `$()`), #889 (its repro 1 carries the #776 idiom and may change verdict as a side effect; not claimed or fixture-pinned here), #947.

---

## Evidence (measured on `367d33cd`, classifier called directly as the tests do)

| Command (inert) | Verdict on main | Exit path |
|---|---|---|
| `X=abc; case "$X" in ''\|*[!0-9]*) echo a ;; *) echo b ;; esac` | `BLOCK_MARKER_SCRIPT\|lease_slot.py` | `_helper_invoked:5351` (pipe-producer probe) |
| `cat > c.md <<'EOF'` / `case "$X" in ''\|*[!0-9]*) n=0;; *) ;; esac` / `EOF` | `BLOCK_MARKER_SCRIPT\|lease_slot.py` | `:5351`, same mechanism |

`_split_with_ops` splits on every unquoted `|`, and `_piped_shell_producers` treats the `|` between case PATTERNS as a pipeline. The pattern word after it (`*[!0-9]*`, an unresolved "command word") is then a possible shell receiver, a later `*)` arm extends the producer over the pattern words, and `_abandoned_scan_probe` reads `*[!0-9]*` as a pattern targeting the helper. Removing any one of the three elements passes — exactly the #776 bisection. Row 2 is the same defect reached through a heredoc body, which the segmenter reads as shell text (the heredoc reading itself is unchanged by this plan).

## Decisions

**D1. Case-pattern pre-pass for `_piped_shell_producers`.** A new pure function `_case_pattern_pairs(pairs)` walks the `(op, seg)` pairs — `op` is the operator BEFORE `seg` — and returns two index sets (an index may be in both):
- `alt`: indices `i` whose `op` is a `|` joining two case patterns;
- `pat`: indices `i` whose `seg` is a case pattern word.
A header segment is never in `pat` (it is a command and is evaluated as a stage as today, so a real pipe INTO a case keeps feeding it, and a substitution or expansion in the case SUBJECT is judged exactly as on main). `_piped_shell_producers` computes `alt, pat = _case_pattern_pairs(pairs) if case_ok else (set(), set())` once before its loop and consults them at exactly two points: (1) as the FIRST branch of the operator test, ahead of `if op.replace("(", "").replace(")", "") in ("|", "|&"): fed = True`, `if i in alt: pass` — the operator is treated like grouping punctuation (it neither sets `fed` nor terminates the pipeline, so an existing `fed` survives it); (2) the stage block `if fed:` becomes `if fed and i not in pat:` — the segment is skipped as a stage (no receiver test, no `last`, no `_stage_recv` memo entry, no budget charge). Abandoning returns two empty sets, so for that command NO pattern is released — the false block stays for the whole command, never a partial reading. `_group_delta` depth bookkeeping is unchanged for every segment, so separator suppression can only stay where it was; budget charging is unchanged for every segment that is still evaluated as a stage (a skipped pattern word does no work, so it charges nothing).

**Exact walk.** A stack `st` of frames, each `[state, words_in_list]` with state `PAT` or `BODY`. For each `i, (op, seg)` — **the operator is applied FIRST, then the segment is classified in the state the operator left**:

```
apply op:
  top is PAT:
    op == ""                      -> nothing
    op == "|"                     -> if words_in_list == 0: ABANDON; else alt.add(i)
    op == "("                     -> if words_in_list == 0: nothing; else ABANDON
    op == ";" (any ";" not part of ";;"/";&")
                                  -> ABANDON   (a newline arrives here as ";" -- see below)
    op starts with ")"            -> if words_in_list == 0: ABANDON
                                     state = BODY; apply op[1:] as a BODY operator
    anything else                 -> ABANDON
  top is BODY (or stack empty):
    op contains ";;" or ";&"      -> if top is BODY: state = PAT, words_in_list = 0
                                     (stack empty: nothing)
    anything else                 -> nothing
classify seg (w = seg.split(); h = w with a leading run of _CMD_OPENERS words removed):
  top is PAT:
    w == []                       -> nothing
    w == ["esac"] and words_in_list == 0 -> pop
    len(w) == 1 and no "$" and no "`" in seg -> pat.add(i); words_in_list += 1
    anything else                 -> ABANDON
  top is BODY or stack empty:
    h[:1] == ["esac"] and top is BODY -> pop
    len(h) in (3, 4) and h[0] == "case" and h[2] == "in" (positions, not just a count),
    no "`" and no "$(" in seg, and WORD = h[1] either holds no "$" at all or is exactly
    a PLAIN parameter: "?$NAME"?, "?${NAME}"?, "?$DIGIT"? (regex below)
                                  -> push [PAT, 0]; if PATTERN present:
                                       PATTERN == "esac" -> pop (empty case)
                                       else apply the PAT segment rule to PATTERN alone
                                       (a "$" or "`" in it -> ABANDON), counting it,
                                       but the header index is NOT added to pat
    anything else                 -> nothing
ABANDON -> return (empty, empty)
```

So in `printf P | case x in a|b) sh;; esac` the pairs are `('', printf P)`, `('|', case x in a)`, `('|', b)`, `(')', sh)`, `(';;', esac)`: index 1's real pipe is applied with the stack EMPTY (nothing), its header pushes PAT with `a` read; index 2's `|` is `alt` and `b` is `pat`; index 3's `)` switches to BODY **before** ` sh` is classified, so ` sh` is a body command — not a pattern — and stays a fed receiver. A pattern word may contain no `$` at all: `${P@P}` prompt expansion and an arithmetic subscript `${a[i]}` both execute code that inherits the case's stdin, so any parameter expansion in a pattern keeps today's reading. The numeric idiom's patterns (`''`, `*[!0-9]*`, `*`) carry none. A `$(…)` pattern is cut by the splitter into `$` + `(`: the `$` already abandons. The case SUBJECT is expanded under the same stdin, so it gets the same rule except for a plain parameter: `_CASE_PLAIN_SUBJECT_RE = re.compile(r'"?\$(?:[A-Za-z_][A-Za-z0-9_]*|[0-9]|\{[A-Za-z_][A-Za-z0-9_]*\})"?')`, matched with `fullmatch`. A plain parameter expansion runs no code; `${P@P}`, `${a[i]}`, `${X:-…}` and every other form fail it and the command keeps today's reading (round 4c: with a `*)` arm, `printf P | case ${P@P} in a) :;; *) :;; esac` blocks on main only through the fed `*` stage, so releasing that stage under a code-running subject would have been a fail-open).

**Pattern state never crosses a line.** `_norm_for_scan` turns every newline into ` ; `, so the segmenter reads a heredoc BODY as shell text while bash reads it as data. Round 4 measured the consequence of accepting a `;` before the first pattern: body text such as `case x in` opens a fictitious frame, the newline-`;` keeps it in pattern state, and the REAL `bash` after the body — `printf P | (cat <<';'`⏎`case x in`⏎`;`⏎`bash)`, and the same with `<<''` or a `(` delimiter, or a second heredoc whose body is `esac` — is filed as a pattern and never fed (BLOCK on main). The fix is that pattern state ABANDONS on any `;`: a heredoc body always ends at a newline, and anything real after it arrives behind at least one `;`, so a frame opened by body text can only ever reach real code in BODY state — where every operator and segment is read exactly as today. **…and the walk only runs on text the normalizer did not rewrite.** Rounds 4b and 4c each found a byte `_norm_for_scan` rewrites into syntax bash never sees: a backslash-newline it joins; a bare CR it turns into a separator; `$IFS`/`${IFS}` it turns into a space, manufacturing a `case WORD in` header that bash would run as an ordinary command named `case`. A hand-listed byte guard chases these one at a time, so the guard is stated against the normalizer itself: `_piped_shell_producers` gains `case_ok=False`, and its single caller passes

`case_ok = _norm_for_scan(cmd) == cmd.replace("\n", " ; ")`

— the pre-pass runs only when the ONLY rewrite the normalizer applied was the one the walk is built on (newline → ` ; `). Every other rewrite it performs today or gains tomorrow — CR/CRLF mapping, backslash-newline joining, comment defusing (`_defuse_comments` blanks separators inside a comment), the `for`/`select` newline rejoin, `$'`/`$"` prefix stripping, `$IFS`/`${IFS}` → space — makes the equality false and the command keeps today's reading. `cmd` is the exact text whose normalization produced every pair list the loop walks (`_base_pairs` directly; each `_readings` entry is derived from the same normalized text, and a reading can only ADD producers because the base pairs are always walked on their own). The default `False` means a future caller that does not think about it gets today's behaviour. With the equality holding, every newline in `cmd` is a `;` in the pairs and nothing else was moved, so pattern state cannot cross a line, and every token the walk accepts is a token bash sees. A real `;;` that pops into pattern state is only ever followed, in bash, by a pattern (or a syntax error), so PAT in this model implies PAT in bash for every token the model accepts. (A bare `case x in ; esac` is itself a bash syntax error; nothing legitimate needs the old acceptance.)

**End of input with a frame still open:** the sets computed so far are returned unchanged. Every mark was made while bash, too, was reading patterns of an open `case` (an unterminated `case` is a bash syntax error and runs nothing); a later body-text `esac` that pops a real frame early only drops the model back to today's reading for what follows.

**Fail-closed residuals of the model** (each keeps today's reading, i.e. may still over-block): any command the normalizer rewrites beyond newline → ` ; ` (a line continuation, a CR, `$IFS`, `$'…'`/`$"…"`, a comment holding `;|&()` or a quote, a `for`/`select` header split across lines); a case subject that is not a literal or a plain parameter; any `case` whose pattern list starts on, or continues onto, a new line — patterns on their own lines, `case x in`⏎`a|b)`, a newline after `;;` before the next pattern, a comment between arms; a pattern containing any `$`; a quoted multi-word pattern (`"a b"`); a header whose subject is quoted with a space (`case "$A $B" in`); an alternation split across lines (`a |`⏎`b)`); `time -p case …`; a `case` preceded by an assignment or redirect (a bash syntax error anyway).
- *Why not change `_split_with_ops`:* it is shared with the marker-write scan and kept in step with `cmdword`; splitting differently moves every consumer. The defect is one consumer's reading of one operator.
- *Why not narrow `_glob_helper_targeted` for `*[!0-9]*`:* that weakens glob evidence everywhere (#573's guard). The pattern word should never have reached the probe.
- *cmdword:* `cmdword._piped_shell_producers` has the same reading but answers a different question (is this a file write), and no test enforces parity mechanically. It is left unchanged; the `KEEP IN STEP WITH cmdword._piped_shell_producers` comment in `marker_check.py` gains one line naming this deliberate divergence (#776) so the instruction does not go stale.

**D2. Budget.** One linear walk per `_piped_shell_producers` call, i.e. once per expansion reading (`_MAX_EXPANSION_READINGS` = 64 bounds the fan-out). Gate: time the existing worst-case budget fixtures (`test-marker-glob-expansion-budget-802.sh`) and #877's `eval ${X}[a]…` shape before and after; acceptance is no fixture moving toward the 5s hook timeout by more than noise.

## Tests

New `tests/test-marker-case-776.sh`, modelled on `test-marker-glob-specificity.sh` (`verdict()` calls the classifier directly, so pending-review state cannot decide). Fixtures use the real helper names only as inert classifier input; nothing is executed.
- **A (the bug → `OK|`):** both evidence rows; `;&` and `;;&` arms; a leading `(''|*[!0-9]*)`; the spaced `'' | *[!0-9]* )` style; a nested idiom inside an outer arm (BLOCK on `367d33cd`); the idiom after `if …; then` and after `elif`; a multi-line script whose `case` statement itself sits on one line (`R=…`⏎`case "$N" in ''|*[!0-9]*) N=0;; esac`⏎`echo "$N"`).
- **A″ (Goal example → `OK|`):** `printf P | case x in a) :;; *) :;; esac`; the idiom with each plain subject form (`"$X"`, `$1`, `"${N}"`); the completion.md approver-gap composer's `case "$HUMAN_ADMIN_COUNT" in ''|*[!0-9]*) …` line with a `*)` arm.
- **C (one must-block per normalizer rewrite, round 4c):** for each rewrite `_norm_for_scan` performs, a command that pipes `P` into a real `bash` behind fake `case` syntax manufactured by that rewrite — bare CR, CRLF, `$IFS`, `${IFS}`, `$'…'`, a comment containing a separator, the `for`/`select` newline rejoin — plus code-running subjects `${P@P}` and `${a[i]}` with a `*)` arm and with the idiom. Every row BLOCKs on `367d33cd` (measured) and must keep blocking.
- **A′ (residual pinned as still-BLOCK):** the same idiom with patterns on their own lines; the one-line idiom in a command that also carries a line continuation elsewhere.
- **B (must still block):** `P` below is the literal inert payload `'python3 hooks/gate-scripts/lib/lease_slot.py'`; each row was run against `367d33cd` on 2026-10-22 and returned `BLOCK_MARKER_SCRIPT|lease_slot.py` (none is vacuous). A body pipe in the same statement as an alternation (`case x in a|b) printf P | sh;; esac`); a real pipe INTO a case whose arm is a shell (`printf P | case x in a|b) sh;; esac`); a pipeline AFTER a closed case (`case x in a|b) echo;; esac; printf P | sh`), after a `;;&` arm, and after a nested `esac`; a `$(sh)` pattern word fed by a pipe; a `${P@P}` pattern after `;;` fed by a pipe; quoted and unquoted `$(…)` case subjects fed by a pipe; a quoted multi-word pattern next to a real pipe to `sh`; a glob receiver (`/bin/[b]ash`) in an arm; a helper run directly in an arm; the round-4 fictitious-frame family — `printf P | (cat <<';'`⏎`case x in`⏎`;`⏎`bash)`, the `<<''` and `(`-delimiter variants, and the variant whose frame is closed by a second heredoc body `esac`; the round-4b continuation family — `printf P | (cat <<'\'`⏎`case x in a) :;; \`⏎`\`⏎`bash)` and its `<<-'\'` tab-stripped variant; the unchanged #639 shape (quoted heredoc prose with an odd apostrophe) as a pinned still-BLOCK residual.
Every B fixture is asserted BLOCK on `367d33cd` before the change (a must-block that already reads OK on main is a pre-existing gap, recorded, not a regression). All existing suites that exercise `marker_check.py` or `pre-implementation-gate.sh` stay green against the baseline recorded before the change.

## Consequences

- #776 closes. #639 stays open with a follow-up note; quoted-heredoc prose with an odd apostrophe still blocks.
- The design-review gate's own classifier (`cmdword.is_file_mod`) still reads a `case` with a `*)` arm as a possible file write, so the same idiom can be refused by the pre-implementation gate while design docs are pending. Different question, different module: recorded in the follow-up issue, not changed here.
- Pre-existing, NOT introduced or fixed here (found in review round 4b): a heredoc terminator issue unrelated to `case`, which this plan's guard does not touch. It is tracked privately.
- **Revisit trigger:** a false block on a `case` shape the model abandons (e.g. `time -p case`), or a parity test between `marker_check` and `cmdword` producers.

<!-- design-review-coverage: FULL 3/3  -->

<!-- design-reviewed: PASS -->
