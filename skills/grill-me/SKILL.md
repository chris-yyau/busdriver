---
name: grill-me
description: Interview the user relentlessly about a plan or design until reaching shared understanding, resolving each branch of the decision tree. Use when user wants to stress-test a plan, get grilled on their design, or mentions "grill me".
---

# Grill-Me

Interview the user relentlessly about every aspect of a plan or design until reaching shared understanding. Walk down each branch of the design tree, resolving dependencies between decisions one-by-one. For each question, provide your recommended answer.

Ask one question at a time. If a question can be answered by exploring the codebase, explore the codebase instead.

## When To Run

Two activation routes:

1. **User explicitly requests** — "grill me", "stress test this", "interrogate me", "challenge this design".
2. **Brainstorming offers it at Step 5.5** — when stakes signals trip (auth, payments, schema migration, irreversible operations, security boundaries, PII, infra/prod state, external API contracts) OR when the design has ≥3 unresolved sub-decisions OR when it spans ≥3 subsystems. Brainstorming asks the user; on "yes", brainstorming invokes this skill.

This skill is an **optional intensifier**, not a gate. It never blocks work.

## Pre-Flight: Check for Existing Decisions

Before asking any questions, locate the design doc under discussion. It may be:
- Passed in by `busdriver:brainstorming` (still in conversation, not yet on disk between Step 5 and Step 6).
- A doc on disk under `docs/superpowers/specs/YYYY-MM-DD-<topic>-design.md` if user invoked grill-me directly on an existing design.

If the design doc (or its in-conversation draft) contains a sentinel-bracketed Key Decisions block:

```markdown
<!-- GRILL-DECISIONS-BEGIN -->
## Key Decisions (resolved during grilling)

- ...

<!-- design-hash: sha256:<hex> -->
<!-- grill-status: complete | truncated -->
<!-- GRILL-DECISIONS-END -->
```

Then run these checks IN ORDER (do NOT short-circuit on `grill-status` before the staleness check). Step 1 sets a `mode` state variable (`fresh_grill` or `resume_existing`) that subsequent steps consume:

1. **Stale-design check (runs first; sets `mode`).**
   - If the design exists as a doc on disk: compute `current_hash` using the canonical algorithm in the "Hash canonicalization algorithm" section below (sha256 of the doc body with the entire `<!-- GRILL-DECISIONS-BEGIN -->...<!-- GRILL-DECISIONS-END -->` block excluded, then CRLF→LF normalized). Read `stored_hash` from the `<!-- design-hash: sha256:<hex> -->` line in the existing block.
     - If `stored_hash == "sha256:PENDING"` (hash not yet finalized — design was written at brainstorming Step 6 but Step 8b has not run yet): treat identically to the missing-hash case — prompt the user: "the design fingerprint is not yet finalized (sha256:PENDING) — has the design been edited since the last grill?". On "yes" → set `mode := fresh_grill`. On "no" → set `mode := resume_existing`.
     - If `current_hash == stored_hash`: set `mode := resume_existing`.
     - If `current_hash != stored_hash`: set `mode := fresh_grill`. Tell the user "design has changed since the last grill — re-walking all branches." The existing block is advisory only (you MAY consult it for prior rationale). The new closing block will replace the old one — either via brainstorming Step 6 (when invoked from brainstorming) or via the Direct-on-disk update procedure (when invoked directly).
   - If `stored_hash` is missing (older block format with no `design-hash` line), prompt the user: "no design fingerprint found on the existing Key Decisions block — has the design been edited since the last grill?". On "yes" → set `mode := fresh_grill`. On "no" → set `mode := resume_existing`.
   - If the design exists only in conversation (not on disk yet — i.e. invoked from brainstorming Step 5.5 between Step 5 and Step 6): no hash to compare; assume not stale; set `mode := resume_existing`.

2. **Parse resolved decisions (only when `mode == resume_existing`).** For each line in the existing block matching `- **<decision name>** — chose <X>. Rationale: <Z>.`, treat that decision as already-resolved AND retain it. Bucket by Rationale prefix:
   - If `<Z>` starts with the literal token `[self-decided]` (followed by a space), append to `retained_self_decided` — these are reversible picks the assistant decided per the "Reversible implementation detail" row of the Classify table. Re-askable on user opt-in via Step 2.5 below.
   - Otherwise, append to `retained_grilled` — user-grilled picks plus assistant-recommended-defaults on low-reversibility decisions. NOT re-askable except via `mode := fresh_grill`.
   
   Both lists MUST be carried verbatim into the new closing block — see the "Carry-forward rule" in the Closing Artifact section. The iteration order of decision lines in the prior block is the stable order reference for carry-forward (entries are emitted in that order, with each `retained_self_decided` slot keeping its original or showing the resolved replacement at the same position). Do NOT re-ask retained decisions (regardless of bucket) unless Step 2.5 or Step 4 explicitly transitions them. (Single canonical format — see Closing Artifact.) When `mode == fresh_grill`, SKIP this step entirely; both lists are empty by definition.

2.5. **Optional re-ask of self-decided picks (only when `mode == resume_existing` AND Step 2 populated `retained_self_decided` with ≥1 entry).** Fires ONLY when the user explicitly says any of: `revisit reversible`, `revisit self-decided`, `re-ask reversibles`, `re-ask self-decided` — at any point during the grill, right after Pre-Flight Step 2 completes, OR in response to Step 3's `complete` exit prompt. If the keyword fires but the pre-condition is not met (empty `retained_self_decided`, or `mode == fresh_grill`), reply: "No self-decided picks exist to revisit." and continue normally. On trigger (pre-condition met), list the self-decided picks by decision name (numbered) and prompt: "Which to revisit? `all` / `none` / comma-separated indices (e.g. `1,3`)". On user response, populate a `revisit_queue` ordered list:
   - `none` (or no response, or user moves on): `revisit_queue` stays empty; resume normally.
   - `all`: copy every entry's decision name into `revisit_queue` (originals STAY in `retained_self_decided`).
   - Comma-separated indices: append only the selected decision names to `revisit_queue` (originals STAY in `retained_self_decided`).
   
   **State semantics — entries are NOT removed from `retained_self_decided` at queue time.** Each queued entry stays in `retained_self_decided` until its replacement is fully resolved during this grill. On full resolution: the original entry is REPLACED in carry-forward by the newly-resolved entry (possibly re-tagged `[self-decided]` if the new decision is again reversible; or untagged if reclassified into another row). On truncation before resolution: unanswered queued entries remain verbatim in `retained_self_decided` and carry forward unchanged. This prevents partial-revisit data loss — the worst case is a no-op (closing block identical to prior).
   
   Do NOT prompt for revisit on every resume — only fire on the explicit keyword. Default resume carries both buckets forward without new prompts (zero friction tax on normal resumes; see issue #157 for rationale).

3. **Check `grill-status` flag (only when `mode == resume_existing` AND Step 2 parsed at least one entry).**
   - `complete` AND `revisit_queue` is empty (Step 2.5 not yet fired, or fired with `none`) → tell the user "this design has already been fully grilled; no open branches remain. If you want to re-grill from scratch, say 'grill it again from scratch'." If AND ONLY IF `retained_self_decided` has ≥1 entry, append " If you want to revisit reversible picks only, say 'revisit reversible'." Then EXIT (do not block waiting). Step 4 and Step 2.5 already fire on their respective keywords whenever the user types them in a subsequent turn — re-invoking grill-me is not required. Do NOT silently re-grill. Do NOT advertise the revisit keyword when `retained_self_decided` is empty (no-op path).
   - `complete` AND `revisit_queue` is non-empty → continue to grill ONLY the queued decisions (focused walk over the queue). When the queue exhausts, emit `complete` (design state remains stable: all positions filled by either originals or replacements). When the user halts mid-queue, ALSO emit `complete` — the original status was `complete` and unanswered queue entries remain verbatim in `retained_self_decided`, so the design state is still stable. To finish the partial revisit later, the user must re-fire `revisit reversible` and re-pick the remaining indices (the `revisit_queue` is in-memory and intentionally NOT persisted — keeps the closing block minimal; partial-revisit resume friction is acceptable trade for simpler state machine).
   - `truncated` → continue from the next unresolved branch (plus any `revisit_queue` entries appended at the end of the question order). On halt: emit `truncated` (original status was `truncated` and unresolved original branches remain); unanswered queue entries similarly require keyword re-fire to resume.

4. If the user explicitly says "grill it again from scratch" at any point, set `mode := fresh_grill` and clear BOTH `retained_self_decided` and `retained_grilled`. The new closing block will replace the old one in Step 6 or via Direct-on-disk update.

If no block exists, this is a fresh grill — proceed to ask the root question.

## Beginner-Mode Self-Loading

At session start (before asking the first question), check active auto-memory for any `user`-type entry indicating the user is new to the current domain (pipeline, skill architecture, gates, supplements, etc.). The auto-memory protocol is documented in the user's global system prompt — read `MEMORY.md` in the per-project memory directory for the index and Read referenced `user_*.md` files for matching domains. If such an entry exists, OR if the user has used a beginner-mode trigger phrase ("I'm new", "explain like a beginner", "what does X mean", etc.), load `skills/supplements/beginner-mode.md` and apply its discipline alongside this skill. See `beginner-mode.md`'s "Auto-Memory Protocol" section for read/write/off-ramp specifics.

The supplement teaches: gloss domain terms on first use; accept "what does X mean?" interrupts at any time with gloss-and-resume; stop glossing on user request.

## Halting Rules

Continue asking until **either** of these is true:

1. **Tree exhausted** — no remaining decision in the tree depends on an unanswered question. The closing block's `grill-status` is `complete`.
2. **User stops** — user says any of: "stop", "done", "good enough", "skip rest", "that's enough". The closing block's `grill-status` is `truncated`.

On each question, after presenting your recommendation:
- Accept the user's own answer (record it).
- Accept "ok" / "yes" / "use your recommendation" (record the recommended option).
- Accept a stop signal (halt and emit truncated block).
- If user input is ambiguous, ask "ready to stop, or one more?" — do not silently exit.

Never produce open-ended infinite walks. If you cannot identify any remaining dependent decisions, declare the tree exhausted and emit `complete`.

## Closing Artifact

When the grill ends, emit exactly this block as the **final output of the grill-me Skill invocation** — i.e. the last content in your response before control returns to the calling skill — with nothing else after it. Omit the entire block ONLY if zero decisions are recorded (no `retained_grilled` AND no `retained_self_decided` entries from Pre-Flight Step 2 AND no newly-resolved decisions from this grill).

(Note on continuation: the calling skill — typically `busdriver:brainstorming` — will resume on the next assistant turn after the Skill invocation returns. The "final output" rule is about the grill-me Skill's response, not about ending the conversation.)

```markdown
<!-- GRILL-DECISIONS-BEGIN -->
## Key Decisions (resolved during grilling)

- **<decision name>** — chose <option>. Rationale: <one line, may include why alternatives were rejected>.
- **<decision name>** — chose <option>. Rationale: <one line>.

<!-- design-hash: sha256:PENDING -->
<!-- grill-status: complete -->
<!-- GRILL-DECISIONS-END -->
```

**Carry-forward rule (resume path — CRITICAL):** when Pre-Flight set `mode := resume_existing`, the closing block MUST contain ALL entries from `retained_grilled` AND `retained_self_decided`, EXCEPT that any `retained_self_decided` entry whose decision name appears in this grill's newly-resolved decisions is REPLACED by the newly-resolved entry (this is the Step 2.5 revisit outcome — only fully-resolved revisits replace; unanswered queued entries naturally remain in `retained_self_decided` and carry forward verbatim, so partial revisit + truncate is a safe no-op). PLUS the remaining newly-resolved decisions (those whose names do NOT collide with any `retained_self_decided` entry — i.e. fresh decisions from this grill, not re-grilled revisits). Order: retained entries first (preserving their original order across both buckets — read order from the prior block, with each `retained_self_decided` slot either keeping its original or showing the replacement), then non-replacement newly-resolved decisions (in resolution order). The `[self-decided]` prefix inside each Rationale field round-trips verbatim: Pre-Flight Step 2's parser reads it; this closing block writes it back unchanged. A re-grilled revisit may emit with or without the `[self-decided]` prefix depending on the new decision's classification (still reversible → tagged; now grilled or recommended-default on low-reversibility → untagged). On `mode := fresh_grill` (hash mismatch, missing-hash+user-says-edited, or explicit grill-from-scratch), both retained lists are empty by definition and the closing block contains only this grill's newly-resolved decisions. Without this carry-forward, Direct-on-disk Sub-case A's block replacement would permanently lose prior decisions on every resume — breaking doc-as-state resumability (the central feature this design exists to enable).

**Decision-line format (canonical, single form):** every entry MUST match `- **<name>** — chose <option>. Rationale: <one line>.` exactly. Do NOT use a second "Rejected X because Z" form — fold any rejection rationale into the single Rationale field. The Pre-Flight parser only recognizes this one format; mixing variants breaks resumability.

**`design-hash` field:** emit the literal string `sha256:PENDING`. Brainstorming Step 6 is responsible for computing the actual sha256 of the design doc body (with the Key Decisions block excluded) and replacing `PENDING` with the hex digest after pasting the block into the doc. If grill-me is invoked directly against a doc that's already on disk (resume path), grill-me itself replaces `PENDING` with the current hash before exiting.

**`grill-status` field:** use `complete` if the tree was exhausted, or `truncated` if the user stopped early.

The block is delimited by HTML comments so brainstorming Step 6 can find it by exact-string match (no LLM judgement required).

### Hash canonicalization algorithm (canonical for both writers and readers)

Both the WRITER (brainstorming Step 6 or grill-me Pre-Flight when running on an existing doc) and the READER (grill-me Pre-Flight stale-design check) MUST use this exact algorithm. Divergent implementations break the resumability contract.

1. Read the design doc as raw UTF-8 bytes from disk.
2. Locate the byte range starting from the first byte of the line containing `<!-- GRILL-DECISIONS-BEGIN -->` through the newline byte immediately following the line containing `<!-- GRILL-DECISIONS-END -->` (inclusive on both ends; if no trailing newline, end at the END comment's last byte).
3. Remove that exact byte range. Then normalize line endings on the remaining bytes by replacing every `\r\n` with `\n` (CRLF→LF). This is the ONLY mutation allowed; do NOT trim adjacent whitespace or otherwise alter the bytes.
4. Compute `sha256` of the resulting bytes. Output as lowercase hex (no `sha256:` prefix here — the prefix is added when writing to the sentinel comment).

**Why CRLF normalization is required:** without it, a Windows checkout with `core.autocrlf=true` produces a different sha256 from the same content checked out on macOS/Linux, causing spurious "design changed" verdicts on cross-platform pulls. Normalizing to LF before hashing makes the digest stable across platforms while keeping the on-disk file unchanged.

YAML frontmatter, if present, is INCLUDED in the hash. Trailing newlines that exist in the file (other than the one removed in step 2) are INCLUDED. Hash the file as it sits on disk after the block-removal step.

**Reference Python one-liner** (use this verbatim or any equivalent that produces the same digest):

```bash
python3 -c "import re,hashlib,sys; b=open(sys.argv[1],'rb').read(); body=re.sub(rb'(?m)^[^\n]*<!-- GRILL-DECISIONS-BEGIN -->.*?<!-- GRILL-DECISIONS-END -->[^\n]*(?:\r?\n)?', b'', b, flags=re.DOTALL); body=body.replace(b'\r\n', b'\n'); print(hashlib.sha256(body).hexdigest())" docs/superpowers/specs/YYYY-MM-DD-<topic>-design.md
```

The regex `(?m)^[^\n]*<!-- GRILL-DECISIONS-BEGIN -->.*?<!-- GRILL-DECISIONS-END -->[^\n]*(?:\r?\n)?` with `re.DOTALL` matches:
- `(?m)^[^\n]*` — multiline mode, line start through any leading content on the BEGIN line
- `<!-- GRILL-DECISIONS-BEGIN -->.*?<!-- GRILL-DECISIONS-END -->` — the block contents non-greedily (lets us match across lines because of DOTALL)
- `[^\n]*` — any trailing content on the END line
- `(?:\r?\n)?` — optional trailing newline, handling both LF and CRLF endings

This guarantees writers and readers compute the same digest regardless of: leading whitespace before the BEGIN sentinel, trailing content after the END sentinel, or LF-vs-CRLF line endings.

## Direct-on-disk update (resume path)

When grill-me is invoked directly against a design doc on disk (NOT via brainstorming Step 5.5), grill-me itself owns the file rewrite at end-of-grill. The procedure has two sub-cases depending on whether a Key Decisions block already exists.

### Sub-case A: existing block (replacement)

**Pre-condition:** the new emitted block MUST already comply with the Closing Artifact "Carry-forward rule" — i.e. when `mode == resume_existing`, it includes all `retained_grilled` entries, plus each `retained_self_decided` entry UNLESS that decision name was fully re-resolved in this grill (in which case the newly-resolved entry replaces it AT THE ORIGINAL POSITION), plus only newly-resolved decisions whose names do NOT collide with any `retained_self_decided` entry (those non-colliding newly-resolved entries append after the retained block in resolution order). Sub-case A only handles the byte-range replacement; carry-forward — including the replace-at-position behavior for Step 2.5 revisits — is the writer's responsibility before this procedure runs. Skipping carry-forward here permanently loses prior decisions because the byte-range replacement overwrites them; emitting duplicate lines for re-resolved revisits would corrupt the parser's bucket assignment on subsequent resumes.

1. **Locate the existing block.** Find the byte range from the line containing `<!-- GRILL-DECISIONS-BEGIN -->` through the line containing `<!-- GRILL-DECISIONS-END -->` (inclusive on both ends).
2. **Replace the block.** Substitute exactly that byte range with the new emitted block (including new BEGIN/END sentinels, decision-line entries — retained + newly-resolved per the carry-forward rule above — `<!-- design-hash: sha256:PENDING -->`, `<!-- grill-status: complete | truncated -->`).
3. **Compute the canonical hash** on the rewritten file using the algorithm in the "Hash canonicalization algorithm" section (sha256 of the file bytes with the now-current block excluded).
4. **Inline the hash** by replacing `sha256:PENDING` in the just-written `design-hash` line with `sha256:<actual-hex>`.
5. **Verify uniqueness** — `grep -c '<!-- GRILL-DECISIONS-BEGIN -->'` against the file MUST return exactly `1`. Same for `<!-- GRILL-DECISIONS-END -->`. If either returns ≠ 1, the rewrite corrupted the file — halt and surface to the user; do NOT exit cleanly.
6. **Then exit.** No further conversation output after the verification.

### Sub-case B: fresh insertion (no existing block)

When grill-me is invoked directly on a design doc that contains no Key Decisions block (e.g. user wrote the design doc manually and is now stress-testing it):

1. **Confirm absence.** `grep -c '<!-- GRILL-DECISIONS-BEGIN -->'` against the file MUST return `0`. If ≥ 1, fall back to Sub-case A (replacement).
2. **Choose insertion location: end-of-file.** Append the new block at the very end of the file. **Block placement contract (CRITICAL — same contract used by brainstorming Step 6):**
   - (a) Ensure a blank line immediately precedes the `<!-- GRILL-DECISIONS-BEGIN -->` sentinel. Insert one if existing content does not already end with a blank line.
   - (b) The BEGIN sentinel MUST be the only content on its own line. NEVER share a line with body text — the hash regex `(?m)^[^\n]*<!-- GRILL-DECISIONS-BEGIN -->` matches from the start of the BEGIN line and would silently gobble any preceding text on the same line into the removed block, dropping it from the hash input. Subsequent edits to that text wouldn't change the hash, breaking the stale-design check.
   - (c) Preserve a single trailing newline after `<!-- GRILL-DECISIONS-END -->`.

   End-of-file is chosen for determinism — no risk of confusion with H1 / first-section heuristics in differently-structured design docs.
3. **Insert the new block** verbatim (BEGIN / decisions / `<!-- design-hash: sha256:PENDING -->` / `<!-- grill-status: ... -->` / END), each on its own line, per the block placement contract above.
4. **Compute the canonical hash** on the resulting file with the just-inserted block excluded (per "Hash canonicalization algorithm").
5. **Inline the hash** by replacing `sha256:PENDING`.
6. **Verify uniqueness** — both `grep -c '<!-- GRILL-DECISIONS-BEGIN -->'` and `grep -c '<!-- GRILL-DECISIONS-END -->'` MUST equal exactly `1`.
7. **Exit.**

For the brainstorming-mediated path (Step 5.5 → Step 6), grill-me does NOT write to disk — it emits the block as conversation output and brainstorming Step 6 handles the file write + hash compute. The two paths share the hash algorithm but differ in which actor writes the file.

## Resumability

Grill-me is idempotent. Re-running it on a design that already has a Key Decisions block:
- Skips resolved branches (per Pre-Flight above) IF the design hash still matches.
- Asks only the remaining branches (if `grill-status: truncated`) or exits cleanly (if `grill-status: complete`).
- Updates the closing block in place via the Direct-on-disk update procedure above, re-evaluating the status flag.
- Honors the **opt-in re-ask keyword** (`revisit reversible` / `revisit self-decided` / `re-ask reversibles` / `re-ask self-decided` — see Pre-Flight Step 2.5) for the user to selectively re-grill prior `[self-decided]` reversible picks without nuking grilled decisions. Zero friction on normal resumes; fires only on explicit keyword.

If the design has changed since the last grill (hash mismatch detected in Pre-Flight Step 1), the policy is **deterministic** — declare a fresh grill and re-walk all branches. The user is informed but not asked to choose. Rationale: "only the new branches" would require section-coverage analysis to know which prior decisions still apply, which is too much machinery for this feature. If the user wants to override, they can either (a) say "grill it again from scratch" before Pre-Flight runs (Pre-Flight Step 4 honors this) or (b) manually edit the Key Decisions block to reflect what's still valid before re-invoking.

## Classify Each Branch Before Grilling

For each decision branch in the design tree, classify it first. Use this exact table (mirrors `skills/brainstorming/SKILL.md`'s "Exploring approaches — classify, then propose"; reversibility × confidence determines the route):

| Case | Action |
|---|---|
| **Reversible implementation detail** (any confidence) | Do NOT add to grill queue. State your decision in the closing block's Rationale field with a `[self-decided]` prefix INSIDE the Rationale text — exact form: `- **<name>** — chose <X>. Rationale: [self-decided] <Z>.`. The prefix is parsed by Pre-Flight Step 2 (buckets the line into `retained_self_decided` on resume) and the user can later re-ask any tagged pick by saying "revisit reversible" / "revisit self-decided" (Pre-Flight Step 2.5 — opt-in keyword, zero friction on normal resumes). Reversibility absorbs confidence risk — cost-to-undo is low, so even a 30% confident pick is fine if documented. User can override at decision time or via the revisit keyword later. |
| **Product / risk-appetite decision** (any confidence) | Grill normally (Recommended-Answer-First Style below). This is what the user owns. |
| **Low-reversibility branch** (schema / concurrency / security), **confidence <50%** | Invoke `busdriver:council` if available; otherwise propose a small spike. Do NOT force a blind pick. Resume grill with the verdict or spike result folded in. |
| **Low-reversibility branch, confidence 50–70%** | Propose a small spike (read code, docs lookup) before grilling. Resume grill with findings folded in. |
| **Low-reversibility branch, confidence ≥70%** | State your recommended default in the closing block's Rationale field with risk flags (data integrity, migration burden, security, etc.). Surface to the user as a single recommended pick (override-allowed), NOT as a multi-option grill question. |

**Precedence for mixed-type branches:** A branch can match multiple rows (e.g., "which auth provider" is both a product preference AND a low-reversibility security decision). Resolve the technical-risk row FIRST (council/spike/recommend-default per its confidence band), THEN grill the user on the surviving product axis. The low-reversibility rows override the product row when schema/concurrency/security dimensions are present.

Only branches that survive classification (the "Product / risk-appetite" row, OR the surviving product axis of a mixed-type branch) proceed to the question procedure below.

## Recommended-Answer-First Style

For every question:
1. State the question.
2. Lay out 3–6 options in a table with brief trade-offs.
3. Recommend ONE option with a numbered justification.
4. Ask the user to pick.

Lead with your recommendation. Forcing the user to react to a concrete proposal surfaces disagreements faster than open questions.

## What Grill-Me Is Not

- Not brainstorming. Brainstorming is collaborative dialogue ("what do you want?"). Grill-me is adversarial interrogation ("defend each decision").
- Not blueprint-review. Blueprint-review is a hook-enforced gate on written design docs. Grill-me is a soft intensifier inside Phase 1.
- Not a council. Council convenes 5 voices on questions with multiple viable approaches. Grill-me is one voice walking the dependency tree of a single chosen approach.
