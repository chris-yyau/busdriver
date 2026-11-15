# Kody unlicensed Cursor-bot skip waiver Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use busdriver:subagent-driven-development (recommended) or busdriver:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement ADR 0064. For exactly one Kody skip — "User Not Licensed" on a PR opened by the Cursor App bot — Tier K returns the bare token `skipped-unlicensed` instead of `stale`. Completion stays the authority and writes an audit event.

**Architecture:** Tier K (`scripts/ack-ledger.sh`) gains one branch. The PR author arrives through the existing `ALL_THREADS` GraphQL query: the four fetch sites each add one selection. Completion's `STALE_BOTS` filter becomes an exact allow-list for `kody-ai` and records the waiver in the main repo's `bypass-log.jsonl`. The worker, dispatcher and SKILL docs add the token to their value contracts. No gate script under `hooks/` changes.

**Tech Stack:** bash 3.2-compatible shell, jq, markdown-embedded bash (worker and completion), shell tests in `tests/`.

**Global Constraints:**
- No skip file, env switch or config opt-in. No change to `hooks/gate-scripts/**`, `.gate-integrity.lock`, required checks or branch protection.
- Fail closed: any missing, malformed or mismatched input → `stale`.
- The token is never a SHA and never tier-suffixed. Every prose mention calls it a "waiver, not an ack".
- The real PR-462 bytes are the positive fixture, extracted with `jq` from the API.
- **ASCII-only source for the summary.** In `scripts/ack-ledger.sh` the jq program builds the em dash from its code point, `([8212] | implode)` (U+2014 = decimal 8212), so no literal U+2014 byte and no escape sequence appear in the ledger. Tests take the real bytes from the fixture file.
- Stay bash 3.2 compatible (`ack-ledger.sh` header).

**Design source:** `docs/adr/0064-kody-unlicensed-cursor-skip.md`, drafted on this branch. Where this plan and that draft differ, **this plan governs**; Task 5 corrects the ADR to match. This plan was reconciled in one pass with the committed implementation (2026-11-13): every listing, file name, test case and contract sentence below matches the code on this branch, including the checks implementation added beyond the first reviewed draft.
- **D1 (seat claim).** The ADR's Context must not say `cursor[bot]` "cannot be given a Kodus seat". The evidence (check-run 131335693133) shows only that the author is currently unlicensed. Reword it to: "currently has no Kodus seat; whether one can be assigned is unverified". The Revisit trigger becomes "a Kodus seat is assigned to `cursor[bot]`, or the summary text changes → drop the waiver, or re-pin the exact text".
- **D2 (exact full HEAD).** The waiver requires `HEAD_FULL_SHA` to be exported as 40 lowercase hex characters, with the run's `head_sha` equal to it byte for byte. Missing, empty, an 8-char prefix, uppercase, malformed or different → `stale`. There is no prefix fallback and no `acks_head` carry-forward. The `success` path is unchanged. Every ledger consumer already exports a full `HEAD_FULL_SHA`:
  - `agents/pr-grinder.md:755`
  - `skills/pr-grind/references/completion.md:132`, which the post-grace refresh at `:361` reuses in the same shell
  - `scripts/fetch-pr-state.sh:233`, which `scripts/dispatcher-commit-block.sh` sources before its two ledger loops

  Task 3 adds the variable explicitly to the dispatcher's own export lists (`:343-344`, `:1520-1521`) and pins all five sites with an anchor test.
- **D3 (audit record).** (Superseded by the 2026-11-14 amendment: D10 replaces the write mechanism — see Task 7.) Completion records the waiver in the **main** repo's state dir: the parent of `git rev-parse --path-format=absolute --git-common-dir`, never `--show-toplevel` (the ephemeral worktree).
  - **State dir.** `BUSDRIVER_STATE_DIR` is sanitized with the dispatcher's pattern (`scripts/dispatcher-commit-block.sh:217-218`): `""|-*|/*|*..*|*[!a-zA-Z0-9._/-]*` → `.claude`.
  - **Writer.** The write goes through the existing hardened writer `audit_append.append`, imported exactly as `hooks/gate-scripts/pre-merge-gate.sh:170-199` imports it: `python3 -S`, scrubbed `sys.path`, cwd = main root. The module is loaded from `${CLAUDE_PLUGIN_ROOT}/hooks/gate-scripts/lib` and nothing under `hooks/` is edited. It walks every path component with `O_NOFOLLOW`, creates missing dirs, refuses a symlink, a non-directory or a torn line, and returns false on any failure. A plain `>>` is not used, because it reports success through a symlink to `/dev/null`.
  - **Inputs.** Before writing, `PR` must be digits with no leading zero and `HEAD_FULL_SHA` must be 40 lowercase hex; otherwise completion blocks. `pr` is recorded as a JSON number (`--argjson`), like the other completion events.
  - **Failure.** If the inputs are invalid, the root cannot be resolved or the append fails, completion blocks.
  - **Meaning.** The event records the waiver **decision at a completion attempt**. The append runs only after `STALE_BOTS` passed. Later completion steps (the checks-green block at `completion.md:543-572`, Shipping routing) can still stop the run, so the event does not prove completion or merge.
- **D4 (no earlier unposted findings).** A skip reviews nothing, so on the waiver path **any** Kody comment whose first line says "could not be posted" vetoes the waiver, whenever it was created. The `started_at` window exists because a newer *review* supersedes an older run, and a skip supersedes nothing. The `success` path keeps its window unchanged.
- **D5 (orderable runs).** The waiver is granted only when every candidate Kody run has a positive integral numeric `id`, so that `max_by(.id)` provably picks the newest. Otherwise → `stale`. The `success` path's selection is unchanged.
- **D7 (bound to this PR).** Check-runs are commit-scoped, so the waiver also requires the deciding run's `pull_requests` to list exactly one PR, whose number equals `pullRequest.number` from the same `ALL_THREADS` snapshot. Task 3 adds `number` to the selection. If two PRs share the commit, or the list is empty, mismatched or not an array → `stale`. The live run 131335693133 carries `pull_requests: [{number: 462}]`.
- **D8 (seat vs waiver is the operator's choice).** Upstream Kodus source (`validate-prerequisites.stage.ts`, `resolveIgnoreState`) suggests a seat can override the automatic bot exclusion. Whether the deployed Kodus org lets `cursor[bot]` hold a seat is **unverified**: this task does not touch account or billing settings. The waiver does not compete with a seat. It fires only while Kody reports "User Not Licensed", so once a seat is assigned, Kody reviews and Tier K's `success` path decides. Paying for a seat instead of shipping the waiver is a spend/product decision. The operator decided it on 2026-11-13: ship the waiver, not a seat. ADR 0064 lists "assign a Kodus seat to `cursor[bot]`" as the first Alternative: supported upstream, and **rejected for this task by operator decision** because it introduces billing and account changes outside this task's scope. The rejection is about scope, not feasibility. The PR stops before merge in any case.
- **D6 (amend recovery).** A message-only amend creates a new HEAD. The predecessor's skip does not carry over (no `acks_head`), so `kody-ai` reads `stale` until Kody posts its own check-run on the new HEAD. Kody does that on every push, and it skips again for the same author. If it does not, the operator comments `@kody review --force`. This goes into degraded-modes and the ADR's Consequences.

---

### Task 1: Tier K waiver branch in the ledger

**Files:**
- Modify: `scripts/ack-ledger.sh`. Sites:
  - header step-3 export list at line 56: add `HEAD_FULL_SHA`
  - `# Output:` at line 64: add `skipped-unlicensed (kody-ai only, ADR 0064)`
  - tier-exposure paragraph near lines 86-96: `skipped-unlicensed` is never suffixed
  - the Tier K comment and capability marker near lines 503-530
  - the Tier K block at lines 555-592
  - the self-resolve clause at line 180

**Interfaces:**
- Consumes:
  - `ALL_THREADS` pages may carry `.data.repository.pullRequest.number` and `.data.repository.pullRequest.author {__typename, login, databaseId}`.
  - Check-runs carry `.pull_requests[].number`.
  - `ALL_CHECK_RUNS` runs carry `.app.id` and `.output.{title,summary}` (raw REST `commits/<sha>/check-runs`).
  - `HEAD_FULL_SHA` is required for the waiver.
- Produces: `ack-ledger.sh kody-ai` stdout ∈ `{<sha>[:K], stale, skipped-unlicensed}`.

- [ ] **Full replacement of the Tier K block body** below the existing `kody_open` veto. That veto, together with `THREADS_SHAPE`, stays above unchanged at lines 559-564. The `success` path is behaviourally identical to today. Every waiver predicate is decided **inside jq on the raw JSON values** (D2: byte-for-byte), so no IFS split can make a padded value compare equal.

```bash
  # ADR 0064 waiver inputs. kody_pr: the PR number, printed only when EVERY
  # ALL_THREADS page carries the pinned Cursor App bot as pullRequest.author
  # (__typename is GitHub-set, so a user named "cursor" reads "User") and the
  # same integer pullRequest.number; empty otherwise, which refuses the waiver.
  kody_pr=$(printf '%s' "$ALL_THREADS" | jq -rs '
    if length > 0
       and all(.[]; .data.repository.pullRequest
             | ((.author | type == "object" and .__typename == "Bot" and .login == "cursor"
                 and .databaseId == 206951365)
                and (.number | type == "number" and . > 0 and floor == .)))
       and ([.[].data.repository.pullRequest.number] | unique | length) == 1
    then .[0].data.repository.pullRequest.number | tostring else "" end' 2>/dev/null) || kody_pr=""
  # The deciding run maps to `success`, `skipped-unlicensed` or `other`, never the
  # raw conclusion. Every waiver predicate is decided here on the raw JSON (ADR
  # 0064), so the whitespace-split `read` below cannot shift a value into place:
  # exact skip text (the U+2014 is built from its code point, keeping this source
  # ASCII), app id, full-HEAD equality (no acks_head carry-forward), the run bound
  # to exactly this PR (check-runs are commit-scoped), orderable ids, array-shaped
  # containers and well-formed timestamps. The success branch is unchanged.
  kody_runs_ok=$(printf '%s' "$ALL_CHECK_RUNS" | jq -s '
    all(.[]; (.check_runs | type) == "array")
    and all(.[].check_runs[] | select(.app.slug == "kody-ai" and .name == "Kody Code Review");
            (.id | type) == "number" and .id > 0 and (.id | floor) == .id)' 2>/dev/null) || kody_runs_ok=false
  [ "$kody_runs_ok" = "true" ] || kody_runs_ok=false
  kody_run=$(printf '%s' "$ALL_CHECK_RUNS" | jq -rs --arg full "${HEAD_FULL_SHA:-}" --arg pr "$kody_pr" \
    --arg ts "$GH_TS_RE" --argjson runs_ok "$kody_runs_ok" '
    [.[].check_runs[] | select(.app.slug == "kody-ai" and .name == "Kody Code Review")] as $runs
    | if ($runs | length) == 0 then "absent"
      elif any($runs[]; .status != "completed") then "running"
      else ($runs | max_by(.id))
        | (if .conclusion == "success" then "success"
           elif .conclusion == "skipped" and .app.id == 413034
                and $runs_ok
                and .output.title == "Code Review Skipped"
                and .output.summary == ("User Not Licensed " + ([8212] | implode) + " Assign seat to user")
                and ($full | test("^[0-9a-f]{40}$")) and .head_sha == $full
                and (.completed_at | type == "string" and test($ts))
                and (.started_at | type == "string" and test($ts))
                and $pr != "" and (.pull_requests | type == "array")
                and (.pull_requests | map(.number) == [($pr | tonumber)])
           then "skipped-unlicensed"
           else "other" end) as $c
        | "\($c) \(.head_sha // "") \(.completed_at // "") \(.started_at // "")"
      end' 2>/dev/null) || kody_run=""
  read -r kody_conc kody_head kody_done kody_start <<EOF
$kody_run
EOF
  kody_ok=""
  if [ "$kody_conc" = "success" ] && [ -n "$kody_head" ] && acks_head "$kody_head"; then
    kody_ok=ack
  elif [ "$kody_conc" = "skipped-unlicensed" ]; then
    kody_ok=waive
  fi
  if [ -n "$kody_ok" ] && [ "$(ts_ok "$kody_done")" = "1" ] && [ "$(ts_ok "${THREADS_FETCHED_AT:-}")" = "1" ]; then
    kody_age=$(jq -nr --arg f "$THREADS_FETCHED_AT" --arg c "$kody_done" \
      '($f | fromdateiso8601) - ($c | fromdateiso8601)' 2>/dev/null)
    if [ "$(num_or "$kody_age" 0)" -ge 60 ]; then
      [ "$(ts_ok "$kody_start")" = "1" ] || { echo "stale"; exit 0; }
      [ "$(json_shape_ok "$ALL_COMMENTS" "$COMMENTS_SHAPE")" = "1" ] || { echo "stale"; exit 0; }
      # A waiver counts every "could not be posted" comment ever posted: the
      # started_at window exists because a newer REVIEW supersedes an older run,
      # and a skip reviews nothing (ADR 0064).
      kody_unposted=$(printf '%s' "$ALL_COMMENTS" | jq -rs --arg login "$login" --arg login_bot "${login}[bot]" \
        --arg start "$kody_start" --arg mode "$kody_ok" \
        '[.[].comments[]
          | select(.author.login == $login or .author.login == $login_bot)
          | select(.body | split("\n")[0] | test("could not be posted"; "i"))
          | select($mode == "waive" or ((.createdAt | fromdateiso8601) >= (($start | fromdateiso8601) - 60)))] | length' \
        2>/dev/null || echo 1)
      if [ "$(num_or "$kody_unposted" 1)" -eq 0 ]; then
        # The waiver is a bare token: never a SHA, never tier-suffixed.
        if [ "$kody_ok" = ack ]; then emit_head_ack "$HEAD_SHA" K; else echo "skipped-unlicensed"; fi
        exit 0
      fi
    fi
  fi
  echo "stale"; exit 0
```

  `[8212] | implode` is U+2014 (EM DASH, decimal 8212) built in jq, so the shell source stays ASCII (see Global Constraints). The emit sits only inside the `kody_unposted == 0` arm, as it does today.

- [ ] **Bump the marker** to `# ack-ledger-capability: tier-k4`, changing both the comment line and the grep at line 180. Add the comment line "`tier-k4` also waives the ADR 0064 unlicensed-Cursor skip". In the same edit, add `HEAD_FULL_SHA` to the self-resolve comment's list of preserved exports (lines 155-157).

### Task 2: Ledger tests (positive real fixture + negatives)

**Files:**
- Create `tests/fixtures/kody/unlicensed-cursor-462.json`: the real check-run from the list endpoint the ledger reads, trimmed to the fields Tier K reads:

```bash
gh api "repos/Dive-And-Dev/chrisyau.me/commits/3fe501d075a49d7aa6cdd463783e986024c0dcc6/check-runs" \
  | jq -c '{check_runs:[.check_runs[] | select(.id == 131335693133)
            | {id,name,status,conclusion,head_sha,started_at,completed_at,
               app:{slug:.app.slug,id:.app.id},output:{title:.output.title,summary:.output.summary},
               pull_requests:[.pull_requests[] | {number}]}]}'
```

- Create `tests/fixtures/kody/unlicensed-cursor-462-pr.json`: the real GraphQL `pullRequest` number and author, `{"number":462,"author":{"__typename":"Bot","login":"cursor","databaseId":206951365}}`, taken from `gh api graphql`.
- Modify `tests/test-ack-ledger-kody.sh`.

- [ ] **`run_ledger` forwards `HEAD_FULL_SHA` only when the case sets it.** It must keep set-empty distinct from unset, and it keeps the scrub otherwise. `reset()` unsets it. Replace the `env -u HEAD_FULL_SHA` element with a conditional:

```bash
run_ledger() {
  ( cd "${2:-$repo}" && env -u HEAD_FULL_SHA -u ACK_CONTENT_IDENTITY \
      -u HEAD_PUSH_DATE -u HEAD_CHECKS_DATE \
      ${CASE_FULL_SHA+HEAD_FULL_SHA="$CASE_FULL_SHA"} \
      ... (rest unchanged) )
}
# reset(): add `unset CASE_FULL_SHA`
```

  `env -u X ... X=v` unsets X first and then sets it, so the forward wins only when `CASE_FULL_SHA` is set.
- [ ] **Test-local helpers:**
  - `fixture_runs [jq-filter]` reads the fixture, sets `head_sha` to `$HEAD` (the test repo's full HEAD) and applies an optional jq mutation to the page. The title, summary and app stay the real bytes.
  - `pr_page [jq-filter]` is the existing `NO_THREADS` page (`reviewThreads.nodes: []`, so `THREADS_SHAPE` passes) merged with the `-pr.json` fixture, then an optional mutation: `jq -c --slurpfile p "$FIX_PR" ".data.repository.pullRequest += \$p[0] | ${1:-.}" <<<"$NO_THREADS"`. Author and number cases mutate or delete keys through the filter.
  - The fixture keeps the real `pull_requests` (`[{"number":462}]`); see the jq projection in the fixture command.
  - `waive_reset` sets the positive defaults: `CASE_FULL_SHA=$HEAD`, `THREADS_FETCHED_AT` = `completed_at` + 70 s, `ALL_THREADS=$(pr_page)`, `ALL_CHECK_RUNS=$(fixture_runs)`, with the existing empty comments.
- [ ] **Cases** (each runs `run_ledger kody-ai`; `ACK_EMIT_TIER=1` is already set):

| # | Variation | Expect |
|---|---|---|
| P1 | real fixture, defaults | `skipped-unlicensed` (exact; no `:`); a byte check also asserts the fixture summary carries the real U+2014 bytes (`e28094`) |
| P2a–e | `CASE_FULL_SHA` unset / empty / `$HEAD8` / uppercase `$HEAD` / `$OTHER` | `stale` each |
| P3a–b | `head_sha` **and** `CASE_FULL_SHA` both `$HEAD8`; both uppercase `$HEAD`. Only the regex rejects these. | `stale` each |
| N1 | author `{"__typename":"User","login":"cursor","databaseId":206951365}` | `stale` |
| N2 | author Bot/cursor, `databaseId` 1 | `stale` |
| N3 | author Bot/`cursor-agent` | `stale` |
| N4 | `author` key missing; `author:null` | `stale` |
| N5 | two pages, the second with a User author | `stale` |
| N6 | `ALL_THREADS` empty | `stale` |
| N7 | `.app.id=1` | `stale` |
| N8 | `.app.slug="kody-ai-evil"` | `stale` |
| N9 | summary with the em dash replaced by `-` (jq `sub`) | `stale` |
| N10 | summary + `" (x)"`; title `"Code Review skipped"` | `stale` |
| N11 | `.conclusion="neutral"` | `stale` |
| N12 | summary `"Only Merge Commits"`; `"Branch Mismatch"` | `stale` |
| N13 | plus a newer `in_progress` Kody run | `stale` |
| N14 | plus a `success` run on HEAD with `id` = fixture id + 1, `completed_at` and `started_at` equal to the fixture's (timestamps shifted with jq, so the settle check passes) | `<HEAD8>:K` |
| N15 | plus a `success` run with `id` = fixture id − 1 → the skip decides | `skipped-unlicensed` |
| N26 | `pull_requests` `[]`; `[{number:999}]`; `[{number:462},{number:999}]`; object-shaped `{"bogus":{"number":462}}`; missing (D7) | `stale` each |
| N27 | `pullRequest.number` missing on a page; two pages disagreeing (462 / 463) | `stale` each |
| N28 | `head_sha` = `$HEAD` + a trailing space; the padded value must not compare equal (D2 in jq) | `stale` |
| N29 | `completed_at=null` with both timestamps smuggled into `started_at` (the whitespace `read` must not shift them into place) | `stale` |
| N30 | object-shaped `check_runs` | `stale` |
| N16 | `head_sha=$OLD` (content-identical predecessor) | `stale` |
| N17 | `head_sha` = `${HEAD:0:8}` + 32 other hex; and `head_sha=$OTHER` | `stale` |
| N18 | an unresolved outdated Kody thread on the same page as the author | `stale` |
| N19 | snapshot 59 s after; `THREADS_FETCHED_AT` empty | `stale` |
| N20 | `.started_at=null` | `stale` |
| N21a | `ALL_COMMENTS='{}'` (fails `COMMENTS_SHAPE`) | `stale` |
| N21b | well-formed comments whose only entry is a Kody "could not be posted" comment created after `started_at` | `stale` |
| N21c | the same comment created **an hour before** `started_at` (an earlier run's unposted findings, D4) | `stale` |
| N21d | control for the `success` path: N21c's comment with a settled `success` run | `<HEAD8>:K` (window unchanged) |
| N22 | `FETCH_OK=0` | `stale` |
| N23 | raw `.conclusion="skipped-unlicensed"` with `.app.id=1` and no output | `stale` |
| N24 | the P1 inputs run for login `chatgpt-codex-connector` | not `skipped-unlicensed` |
| N25 | the skip run's `id` is `"invalid"`, `null`, missing, `0` or `1.5`; and a second run with a string id beside a numeric skip (D5) | `stale` each |

- [ ] **Decision 8 marker cases:**
  - Add the case "checkout carrying only `tier-k3` is not trusted". It copies the existing `tier-k2` case's pattern: `reset; SELF_RESOLVE_OFF=0; ALL_CHECK_RUNS="$SUCCESS"`, expecting `$HEAD8:K` from the loaded ledger.
  - The trusted case and the closing grep move to `tier-k4`.
- [ ] Run `bash tests/test-ack-ledger-kody.sh`. Expected: `0 failed`.
- [ ] **Mutation check** (manual, not committed). Apply each mutation separately: drop the `.app.id` clause; drop the author `.__typename` clause; drop the `HEAD_FULL_SHA` regex check; change `8212` to `45` (a hyphen); make the projection's `else` pass `.conclusion` through. Each must turn at least one case red. Only P3a–b pin the regex; only N21c pins D4; only N25 pins D5; only N26–N27 pin D7; N29 pins the timestamp type checks. Also mutate the waiver comment window back to `started_at`, and drop the id check. Record the results in the PR body.

### Task 3: Author selection and HEAD_FULL_SHA at every ledger site

**Files:**
- Modify: `scripts/fetch-pr-state.sh:98`, `agents/pr-grinder.md:647` (Step 6.5), `skills/pr-grind/references/completion.md:40` and `:361`. In each query, add one line inside `pullRequest(number:…){`, before `reviewThreads`:

```graphql
number author{__typename login ... on Bot{databaseId}}
```

  The worker's Step 2 triage query (`pr-grinder.md:196`) does not feed the ledger and stays unchanged.
- Modify: `scripts/dispatcher-commit-block.sh:343-344` and `:1520-1521`: add `HEAD_FULL_SHA` to both explicit `export` lists.
- Test: `tests/test-pr-grind-codex-wiring.sh`, next to the existing `THREADS_FETCHED_AT` anchor test.

- [ ] **Anchor A (per fetch block):** mirror k1's enumeration (`grep -rlE '(ALL_THREADS|_tmp)=\$\(gh api graphql' scripts agents skills`) and skip comment lines. A block starts at a line matching `^[[:space:]]*(ALL_THREADS|_tmp)=\$\(gh api graphql` and ends at the first following line containing `2>/dev/null)` (the line that closes the command substitution; at all four sites this is where the `gh api graphql` command ends). Each block must contain `number author{__typename login ... on Bot{databaseId}}`. The block count must be **exactly 4**: fetch-pr-state 1, worker Step 6.5 1, completion 2. The worker's Step 2 triage query is excluded by construction, because its assignment target is neither `ALL_THREADS` nor `_tmp`. A fifth site, or a block missing the selection, fails.
- [ ] **Anchor B (continuation-folded):** fold backslash-continued lines (`awk '/\\$/ {sub(/\\$/,""); printf "%s", $0; next} {print}'`), then require `HEAD_FULL_SHA` as a word in every folded statement matching `^[[:space:]]*export FETCH_OK ALL_THREADS`. Three of the five statements are indented:
  - `agents/pr-grinder.md` (exactly 1 statement)
  - `skills/pr-grind/references/completion.md` (exactly 1)
  - `scripts/fetch-pr-state.sh` (exactly 1)
  - `scripts/dispatcher-commit-block.sh` (exactly 2)
- [ ] Run `bash tests/test-fetch-pr-state-shape.sh`, `bash tests/test-pr-grind-codex-wiring.sh` and `bash tests/test-dispatcher-commit-block.sh`. All must pass.

### Task 4: Completion authority and audit

**Files:**
- Modify: `skills/pr-grind/references/completion.md` at these sites:
  - criteria 3 and 7 near lines 12-15
  - the COMPLETION summary in `skills/pr-grind/SKILL.md:887`: "assert all entries are <HEAD-SHA> or `none`"
  - the Codex `case` comment at lines 429-437
  - the `STALE_BOTS` awk at lines 524-527
  - the new audit block right after the `STALE_BOTS` `fi`, at line 533
  - the "PR Grind Complete" summary template's "Automated reviewers" line: when completion printed the ADR 0064 `kody-ai` notice, it says Kody did NOT review (licensing waiver) instead of "all completed"
- Test: `tests/test-pr-grind-codex-wiring.sh` (k5 and a new k5b)

- [ ] **Exact allow-list.** Two fields, string compares, `kody-ai` handled first:

```bash
STALE_BOTS=$(echo "$FRESH_ACKS" | tr ',' '\n' | awk -F= -v downgraded="$REVALIDATED_DOWNGRADE" -v head="$HEAD_SHA" '
  BEGIN { n = split(downgraded, arr, ","); for (i = 1; i <= n; i++) if (arr[i] != "") skip[arr[i]] = 1 }
  $1 == "kody-ai" {
    ok = (NF == 2 && ((head != "" && ("x" $2) == ("x" head)) || ("x" $2) == "xskipped-unlicensed"))
    if (!ok) print $1
    next
  }
  $2 == "stale" && !($1 in skip) { print $1 }
')
```

  A downgraded `kody-ai` is still never skipped, as before.
- [x] superseded — (Superseded by the 2026-11-14 amendment — see Task 7.) **Audit block** (D3), placed after the `STALE_BOTS` block has passed. It is fenced by the two marker comments, which k5b uses to extract it, since the block contains nested one-line `case ... esac`:

```bash
# >>> ADR 0064 kody waiver audit
case ",$FRESH_ACKS," in
  *,kody-ai=skipped-unlicensed,*)
    echo "ℹ️  kody-ai: Kody did NOT review HEAD ($HEAD_SHA). PR author cursor[bot] has no Kodus seat; ADR 0064 licensing waiver applied (a waiver, not an ack)."
    case "${PR:-}" in ""|0*|*[!0-9]*) echo "❌ BLOCKED: invalid PR number '${PR:-}' for the ADR 0064 waiver audit"; exit 1 ;; esac
    printf '%s' "${HEAD_FULL_SHA:-}" | grep -Eqx '[0-9a-f]{40}' \
      || { echo "❌ BLOCKED: HEAD_FULL_SHA is not a full SHA; cannot record the ADR 0064 waiver"; exit 1; }
    _WAIVE_GCD=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || _WAIVE_GCD=""
    case "$_WAIVE_GCD" in /*) : ;; *) echo "❌ BLOCKED: cannot resolve the main repo root to record the ADR 0064 waiver"; exit 1 ;; esac
    _WAIVE_ROOT=$(dirname "$_WAIVE_GCD")
    _WAIVE_STATE="${BUSDRIVER_STATE_DIR:-.claude}"
    case "$_WAIVE_STATE" in ""|-*|/*|*..*|*[!a-zA-Z0-9._/-]*) _WAIVE_STATE=".claude" ;; esac
    _WAIVE_REC=$(jq -nc --argjson pr "$PR" --arg sha "$HEAD_FULL_SHA" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '{event:"kody-unlicensed-skip-waived", gate:"pr-grind-completion", pr:$pr, head_sha:$sha,
        author:"cursor[bot]", reason:"Kody Code Review skipped: User Not Licensed", adr:"0064", ts:$ts}') || _WAIVE_REC=""
    # Same writer and import shape as hooks/gate-scripts/pre-merge-gate.sh audit_authorized_merge.
    if [ -z "$_WAIVE_REC" ] || ! (cd "$_WAIVE_ROOT" && PYTHONPATH="${CLAUDE_PLUGIN_ROOT}/hooks/gate-scripts/lib" python3 -S -c "
import sys
_gatelib = [q for q in sys.path if q.endswith('gate-scripts/lib')]
sys.path[:] = [q for q in sys.path if q not in ('', '.') and q not in _gatelib] + _gatelib
from audit_append import append
raise SystemExit(0 if append(sys.argv[1], sys.argv[2]) else 1)
" "$_WAIVE_STATE" "$_WAIVE_REC"); then
      echo "❌ BLOCKED: could not durably record the ADR 0064 waiver in $_WAIVE_ROOT/$_WAIVE_STATE/bypass-log.jsonl"; exit 1
    fi ;;
esac
# <<< ADR 0064 kody waiver audit
```

- [ ] **Text updates:**
  - Criterion 3: Kody counts as completed when acked by Tier K, or when ADR 0064 waived its unlicensed skip (not a review).
  - Criterion 7: `kody-ai` is `<HEAD-short-SHA>` or `skipped-unlicensed`; any other value blocks.
  - `SKILL.md:887`: entries are `<HEAD-SHA>` or `none`, except `kody-ai`, which is `<HEAD-SHA>` or `skipped-unlicensed`.
  - The Codex `case` comment: this normalization is Codex-only; `kody-ai` is validated by the `STALE_BOTS` allow-list below, and routing it through this `case` would turn the waiver into `stale`.
- [ ] **k5 test:**
  - `k5_run` takes the head as a third argument: `awk -F= -v downgraded="$2" -v head="$3" "$K5_PROG"`.
  - Every existing row passes `abc12345`.
  - New rows:
    - `kody-ai=skipped-unlicensed` and `kody-ai=abc12345` pass.
    - These block: `kody-ai=deadbeef`, `kody-ai=garbage`, `kody-ai=`, `kody-ai=skipped-unlicensed=x`, `kody-ai=012345678` with head `12345678`, `kody-ai=none`, `kody-ai=stale`, and `kody-ai=abc12345` with an empty head.
    - Codex `stale` still blocks.
    - A downgraded `chatgpt-codex-connector=stale` is still skipped.
- [x] superseded — (Superseded by the 2026-11-14 amendment: tests/test-kody-waiver.sh — see Task 7.) **New k5b test:** extract the lines between `# >>> ADR 0064 kody waiver audit` and `# <<< ADR 0064 kody waiver audit`. Assert the slice contains `from audit_append import append`, so a bad slice cannot pass vacuously. Run it as a child `bash` under `env -u BUSDRIVER_STATE_DIR PYTHONDONTWRITEBYTECODE=1` (no inherited state dir; no bytecode left under the locked gate lib) with `CLAUDE_PLUGIN_ROOT` = the repo root, `PR=462`, `HEAD_SHA`, a 40-hex `HEAD_FULL_SHA`, and **cwd = a linked worktree** of a temp main repo. Assertions:
  - `git rev-parse --path-format=absolute --git-common-dir` resolves to the main `.git`.
  - Exactly one line lands in the **main** repo's `.claude/bypass-log.jsonl`, even when `.claude` did not exist beforehand. `jq -e` on it: `event=="kody-unlicensed-skip-waived"`, `gate=="pr-grind-completion"`, `adr=="0064"`, `author=="cursor[bot]"`, `(.head_sha|test("^[0-9a-f]{40}$"))`, `.pr == 462` (a number).
  - No `bypass-log.jsonl` appears in the worktree.
  - Exit 1 with nothing written when the main `.claude/bypass-log.jsonl` is a symlink to `/dev/null`, and again when `.claude` is a symlink to another directory.
  - `BUSDRIVER_STATE_DIR=../x` and `/tmp/x` both fall back to `.claude`.
  - Nothing is written when `FRESH_ACKS` carries a SHA.

### Task 5: Contract text (worker, dispatcher, SKILL, ADRs, docs)

**Files:**
- Modify `agents/pr-grinder.md`:
  - `:24` `PRIOR_REVIEWER_ACKS`: may also read `kody-ai=skipped-unlicensed`.
  - `:257` `kody-ai` row: one sentence on the ADR 0064 waiver.
  - `:273` clean rule: `skipped-unlicensed` is not `stale`.
  - `:287` and `:289`: a waived `kody-ai` **normally** posts no Source 2/3/4 artifact (PR 462 has none, and Kodus notifies org owners off the PR), so it usually enumerates as `kody-ai=0/0:none` beside `kody-ai=skipped-unlicensed`. If a Kody artifact does exist, enumerate the real count; never overwrite a real count. Invariant 3 ignores either form because the value is not SHA-shaped.
  - `:737`: the ledger emits `<short-sha> | none | stale`, and for `kody-ai` only also `skipped-unlicensed`.
  - `:783-787` sole-stale comment: "no registered bot reads the literal `stale`".
  - `:885` `RESULT_REVIEWER_ACKS`: add `skipped-unlicensed` (kody-ai only; a waiver, not an ack).
  - `:886` `RESULT_ACK_TIERS`: a waived `kody-ai` is tier `none`; `skipped-unlicensed` is never a tier letter.
  - `:920`: the `clean` status row admits `kody-ai=skipped-unlicensed`; `kody-ai=none` and `stale` still block.
  - `:939` anti-pattern row: `0/0` is paired with `none`, or with `kody-ai`'s `skipped-unlicensed`.
- Modify `skills/pr-grind/SKILL.md`:
  - Invariant 3: the token is not SHA-shaped, so Invariant 3 does not apply, and there is nothing to enumerate
  - `:648-651` sole-stale comment: same rewording as the worker's
  - `:1415` `RESULT_REVIEWER_ACKS` values: `<short-sha> | none | stale | skipped-unlicensed (kody-ai only, ADR 0064 waiver)`
  - `:1416` `RESULT_ACK_TIERS`: a waived `kody-ai` is tier `none`.
- Modify `scripts/dispatcher-commit-block.sh`, comments only:
  - beside the Decision 7 bail: the token passes through, and completion is the authority;
  - `:234-235`: "compulsory — it never reads `none`; the ADR 0064 unlicensed-Cursor waiver reads `skipped-unlicensed`".
- Modify `docs/adr/0058-kodus-replaces-cubic-coderabbit-greptile.md`:
  - Status line: "Amended by ADR 0064"
  - one amendment note each under Decision 2's conclusion bullet and Decision 8's marker paragraph (`tier-k4`)
  - the Revisit trigger bullet
- Modify `docs/adr/0064-kody-unlicensed-cursor-skip.md`:
  - apply D1–D8: the completion bullet becomes the D3 writer and meaning; Decision 1's veto list gains D4, D5 and D7; Consequences gains D6; Alternatives opens with D8's seat option, supported upstream and rejected for this task by operator decision (billing/account scope, not feasibility)
  - mention `HEAD_FULL_SHA` in the ADR's Decision 2 reader list
  - set Status to Accepted
- Modify `docs/degraded-modes.md`, in the "`kody-ai` stays stale" section. Add exactly this: "Exception (ADR 0064): on a PR opened by the Cursor App bot, Kody's `skipped` run titled `Code Review Skipped` with summary `User Not Licensed — Assign seat to user` reads `skipped-unlicensed`. That is a waiver, not an ack, and it applies only while every Tier K veto holds, including no Kody "could not be posted" comment anywhere on the PR and an exact full-HEAD match. The waiver does not carry across an amend: until Kody posts its own run on the new HEAD, `kody-ai` reads `stale`. If no run appears, comment `@kody review --force`."
- Modify `docs/observability.md`: one row in the bypass-log event table for `kody-unlicensed-skip-waived`. It is written by pr-grind completion when it applies the ADR 0064 waiver at a completion attempt, through `audit_append`. It is not an ack and not proof of merge. Also add an example query beside the per-PR merge query at `:75-76`, which filters on the pre-/post-merge gates and so would not show this event: `jq -r --arg pr 462 'select(.gate == "pr-grind-completion" and (.pr|tostring) == $pr) | "\(.ts) \(.event) \(.head_sha)"' .claude/bypass-log.jsonl`. Leave the merge-authorization query itself unchanged.
- Test: `tests/test-dispatcher-commit-block.sh`: one clean-path case where `RESULT_REVIEWER_ACKS=kody-ai=skipped-unlicensed` passes through unchanged (no bail); the `kody-ai=none` bail case stays.

- [ ] Make the edits and add the test.

### Task 6: Full verification, replay and commit

- [ ] Run:
  - `npm run validate`
  - `shellcheck scripts/ack-ledger.sh scripts/dispatcher-commit-block.sh scripts/fetch-pr-state.sh`
  - `bash tests/test-ack-ledger-kody.sh`
  - `bash tests/test-pr-grind-codex-wiring.sh`
  - `bash tests/test-dispatcher-commit-block.sh`
  - `bash tests/test-fetch-pr-state-shape.sh`
  - `bash tests/test-advisory-stale-downgrade.sh`
  - `bash tests/test-gate-integrity.sh` (no locked path changed)
- [ ] **Read-only replay of live PR 462.** (Its query uses D11's selection, and its audit expectations are superseded by the 2026-11-14 amendment — see Task 7.) No comment or write to PR 462. A scratchpad script fetches the real inputs and runs this branch's ledger with the full SHA:

```bash
R=Dive-And-Dev/chrisyau.me; FULL=3fe501d075a49d7aa6cdd463783e986024c0dcc6
FETCH_OK=1
export HEAD_SHA=${FULL:0:8} HEAD_FULL_SHA=$FULL BUSDRIVER_DISABLE_ACK_SELF_RESOLVE=1 ACK_CONTENT_IDENTITY=0
# Assign first, then export, so a failed fetch sets FETCH_OK=0 instead of being masked (as completion.md:53-66 does).
THREADS_FETCHED_AT=$(bash scripts/github-server-now.sh) || FETCH_OK=0
Q='<paste verbatim the post-Task-3 query string from scripts/fetch-pr-state.sh: query($number:Int!,$owner:String!,$name:String!,$endCursor:String){ ... author{__typename login ... on Bot{databaseId}} reviewThreads(...){...} ... }>'
ALL_THREADS=$(gh api graphql --paginate -F number=462 -F owner=Dive-And-Dev -F name=chrisyau.me -f query="$Q") || FETCH_OK=0
# Its variables are $number/$owner/$name and match the -F flags. Never use the worker or completion queries, whose variables are $owner/$repo/$pr.
ALL_COMMENTS=$(gh pr view 462 -R $R --json comments) || FETCH_OK=0
ALL_CHECK_RUNS=$(gh api --paginate "repos/$R/commits/$FULL/check-runs") || FETCH_OK=0
ALL_REVIEWS=$(gh api --paginate "repos/$R/pulls/462/reviews") || FETCH_OK=0
ALL_STATUSES="" ALL_REACTIONS="[]"
export FETCH_OK THREADS_FETCHED_AT ALL_THREADS ALL_COMMENTS ALL_CHECK_RUNS ALL_REVIEWS ALL_STATUSES ALL_REACTIONS
[ "$FETCH_OK" = 1 ] || { echo "replay fetch failed; not recorded"; exit 1; }
ACK_EMIT_TIER=1 bash scripts/ack-ledger.sh kody-ai   # expect: skipped-unlicensed
HEAD_FULL_SHA= ACK_EMIT_TIER=1 bash scripts/ack-ledger.sh kody-ai   # expect: stale
```

  Record both outputs in the PR body. The replay is diagnostic. If the first read is `stale`, print each predicate before concluding anything:
  - the projected `kody_run` line;
  - the author jq result;
  - `HEAD_FULL_SHA` == `head_sha`;
  - the unresolved Kody thread count;
  - `THREADS_FETCHED_AT` − `completed_at`;
  - the "could not be posted" comment count.

  A live `stale` with a named, legitimate cause (for example an open Kody thread) is reported as such. It is never "fixed" by loosening a predicate.
- [x] done (the original commits on this branch; the 2026-11-14 amendment's commit step is Task 7's last step) — Commit through the Litmus gate. Its commit-mode size limit (8 staged files) splits the change into logical commits, each Litmus-reviewed: the ledger with its fetch callers, completion and SKILL text (`feat(pr-grind): waive Kody's unlicensed skip on Cursor-bot PRs (ADR 0064)`); the dispatcher and wiring tests; the ADRs and docs; and this plan. Open a **draft** PR and run `/pr-grind --no-merge`, because pr-grind merges by default (`skills/pr-grind/SKILL.md:83`). Stop at "Ready for merge" (this loosens a review check). If Kody skips the draft, comment `@kody review --force` or mark the PR ready for review; neither merges. The PR body records D8 (seat vs waiver) as the operator's decision.

---

## Amendment (2026-11-14): a runnable waiver, for documentation-only PRs

This amendment replaces D3's write mechanism and Task 4's audit block, and adds D9-D11 with Task 7. Where it conflicts with earlier text, it governs.

**Why.** The design review of 2026-11-14 measured three defects in the branch as built:
1. **The audit block cannot run.** Fed to `hooks/gate-scripts/lib/marker_check.py` as a Bash command, the `# >>> ADR 0064 kody waiver audit` slice returns `BLOCK_MARKER_SCRIPT|audit_append.py`, and `pre-implementation-gate.sh` blocks that verdict on every command. That is correct: `audit_append` is a hook-internal writer, and agent-issued Bash must not import it. k5b passed only because it ran the slice in a child bash, which the gate never sees. So the waiver could never be recorded, and completion would block every waived PR.
2. **The first completion fence becomes unscannable.** The author selection `author{__typename login ... on Bot{databaseId}}` pushes that fence over the classifier's budget (`_HELPER_MAX_TOKENS`), so it returns `BLOCK_UNSCANNABLE|`. With the selection removed, or written without the nested braces, the same fence returns `origin/main`'s verdict (a separate, pre-existing false positive that names the lease helper; tracked outside this PR).
3. **The waiver is too wide.** The operator decided on 2026-11-14 that Kody is waived only for documentation-only PRs.

- **D9 (documentation only).** The waiver is granted only when every path the PR changes is documentation at the reviewed HEAD.
  - **Documentation path:** a path ending in `.md` (extension matched case-insensitively) that is either under `docs/` (matched case-sensitively, as `skippable()` does) or at the repository root. This excludes `docs/*.test.ts`, `docs/conf.py`, scripts and any other file type a docs build can execute.
  - **Agent configuration is never documentation.** That covers `agent_config()` and any file agent configuration imports with `@path`. The imports are walked at HEAD and at the base tip by `imported_config(repo, (head, tip), trips=False)`.
    - **Why `trips=False`.** The new keyword goes `imported_config(repo, revs, trips)` → `walk(repo, revs, clock, trips)`, which then reaches the only two trip call sites:
      - `entry_level(tmaps, exact, trips)` at `:631`, which guards its `tree_trips(kind, path)` call at `:602`;
      - `markdown_trips(path, texts[sha])` in `walk()` at `:645`, which is guarded inline.

      With it off, those two sites do not raise. `entry_level`'s symlink and gitlink refusals at `:599-601` are resolution limits, not trips, and stay unconditional. These are the structured-config, frontmatter, `!`-command and skill-path checks, which make every path agent config for Shipping (#950). Every resolution limit still raises `Incomplete`: deadline, depth, blobs, queries, tokens, symlinks, gitlinks and truncated trees.
    - **Why it is needed.** Measured: busdriver's own tree tracks `.claude/busdriver.json`, so with trips on, every busdriver PR would read `incomplete` and the waiver could never apply in the repo it exists for.
    - **Residual.** A hook in base-branch agent configuration that executes a documentation `.md` file is not detected. That hook was itself added through a reviewed change. This is recorded in ADR 0064's Consequences.
    - **Shipping is unchanged.** `classify()` keeps `trips=True`, the default.
  - **Its own listing, with status.** `docs_only` lists files through a sibling of `changed_paths()` that also projects `status`: `--jq '.[] | {filename, previous_filename, status}'`. Every path the listing names, whether old or new, must pass `doc_path` and not be agent config, and that includes removed files. `status` decides only the mode check that follows.
  - **Every surviving path is a plain file at HEAD.** The mode check applies to exactly one path per record: its `filename`, and only when `status` is not `removed`. That path must be a mode `100644` blob in HEAD's recursive tree (`tree_map`), so it is not a symlink, an executable or a gitlink. A `filename` absent from that tree is an error.
    - Name-only checks: a `removed` record's `filename`, and every `previous_filename` (the old side of a rename or copy, which by design is no longer in HEAD's tree). Deleting or moving away a file cannot add code that runs.
    - A docs-to-docs rename therefore reads `docs-only`.
    - The basename must be longer than `.md`.
    - `tree_map` raising `Incomplete` (a truncated tree, or the deadline) returns `incomplete`, not an error.
  - **`incomplete` comes first.** `docs_only` tests `imported is INCOMPLETE` and returns `incomplete` before any per-path `is_config` call. `is_config` treats the sentinel as true, which would otherwise report `not-docs-only`.
  - **The listing must be complete:** `files_incomplete(records)` is false, so there is at least one record and fewer than the 3000-record cap. A rename contributes both of its paths.
  - **Nothing moves while classifying.** Like `classify()`, the check takes a `pr_view` plus `base_tip` snapshot before the listing and the walk, and another after. `headRefOid` must equal HEAD in both, and `baseRefName` and the base tip must not change. Any difference is an error.
  - **Result tokens:** `docs-only`; `not-docs-only`; `incomplete` (the walk could not finish, so no classification was established); or an error.
- **D10 (one fixed-purpose writer, outside `hooks/`).** A new script, `scripts/kody-waiver.py`, decides and records in one process. It follows the precedent of `scripts/design-clear.sh`, a `scripts/` entry point that imports `audit_append` from the plugin's own gate lib to write one fixed event type:
  - **Usage:** `/usr/bin/python3 -I kody-waiver.py <owner>/<repo> <PR_NUMBER> <40-hex HEAD>`. It reuses `needs-shipping.py`'s `valid_args`, loaded by path with `importlib`, the way `tests/needs-shipping-selftest.py` loads it. It also requires the PR number to match `[1-9][0-9]*`, so a leading zero is refused.
  - **Decision:** it calls the new `docs_only(repo, pr, head)` function in `needs-shipping.py` (D9):
    - `not-docs-only` or `incomplete`: prints that token, exits 10, writes nothing;
    - an error (`Fail`, or any exception): prints `error: <reason>`, exits 1, writes nothing.
  - **Clean git environment:** every `git` subprocess runs with an environment copied from `os.environ` minus every key starting with `GIT_`. That is a superset of the `unset` list `advisory-downgrade-optin.sh:38-40` relies on, and it includes the `GIT_CONFIG_COUNT`/`KEY_n`/`VALUE_n` family. So the repository, work tree and config are discovered from the cwd alone. The script also sets `sys.dont_write_bytecode = True` before importing anything, so it leaves no `.pyc` under the gate lib.
  - **Main checkout:** resolved as `scripts/advisory-downgrade-optin.sh:94-116` resolves it, with `git worktree list --porcelain` (no `-z`, so it works on older git). A main-checkout path that itself contains a newline would be split and truncated by that parse. The truncated path then fails the `--is-inside-work-tree` check, so it fails closed with exit 1. The script adds no separate newline check.
  - **Its cwd is the grind worktree.** The step runs as `cd "<WORKTREE_DIR>" && /usr/bin/python3 -I ...`, following SKILL.md's "CWD Reset Across Bash Calls" rule for every new Bash call that runs git. `<WORKTREE_DIR>` is the literal path resolved in Step 0, and with `NO_WORKTREE=1` it is the checkout itself. From there, the first `git worktree list` entry is the operator's main checkout, wherever the session's ambient cwd happens to be. The first entry must be a work tree. A `--separate-git-dir` main checkout is recovered only when the script runs in the main worktree itself, and from a linked worktree it fails closed. `dirname(--git-common-dir)` is not used.
  - **State dir:** the constant `.claude`, exactly as `scripts/design-clear.sh:89-98` fixes it. `BUSDRIVER_STATE_DIR` is not read, so the environment cannot move the record.
  - **Write:** `audit_append.append(state_dir, record)`, imported from `<script dir>/../hooks/gate-scripts/lib` with that directory inserted at `sys.path[0]`, running with the main root as cwd.
  - **Record:** every field except `pr`, `head_sha` and `ts` is a constant: `{event:"kody-unlicensed-skip-waived", gate:"pr-grind-completion", pr:<number>, head_sha:<40-hex>, scope:"docs-only", verified:"documentation-only diff at head_sha", basis:"completion ledger read kody-ai=skipped-unlicensed", adr:"0064", ts}`. Nothing caller-supplied beyond the validated PR and SHA reaches it. The record states only what the script verified (`verified`), and it names the Kody skip as completion's ledger result (`basis`), not as something the script checked.
  - **Exit codes:** `waived` and 0 only after the append returned true; `error: <reason>` and 1 on anything else, including a failed append. Errors fail closed.
  - **Why this is not a new bypass primitive.** The script can write only this one self-incriminating event type, and only for a PR GitHub reports as documentation-only at the given HEAD. Nothing reads `kody-unlicensed-skip-waived` as authority: no gate, revalidator or downgrade joins on it. Calling it grants nothing. Deciding and recording in one process also means the record cannot exist without the docs-only decision.
- **D11 (the author pin without an inline fragment).** All four `ALL_THREADS` fetch sites select `number author{__typename login resourcePath}` instead of `... on Bot{databaseId}`. The four sites are the worker, `fetch-pr-state.sh` and completion twice. Tier K's author predicate becomes `__typename == "Bot" and login == "cursor" and resourcePath == "/apps/cursor"`.
  - **Why it is equivalent.** `resourcePath` is on the `Actor` interface, so it needs no fragment. Live, PR 462 reads `{"__typename":"Bot","login":"cursor","resourcePath":"/apps/cursor"}`, and its `databaseId` is 206951365. `/apps/<slug>` is the GitHub App's own page: a user account cannot have it, and app slugs are unique.
  - **Tests and fixture.** The fixture `tests/fixtures/kody/unlicensed-cursor-462-pr.json` is regenerated from the live API with the new selection. The ledger negatives that varied `databaseId` now vary `resourcePath` instead: `/cursor`, `/apps/cursor2`, missing, `null`, and a number.
- **Completion wiring** replaces Task 4's audit block. That block is deleted, so the first fence no longer mentions `audit_append`.
  - **The first fence** keeps the exact `STALE_BOTS` allow-list. When `FRESH_ACKS` carries `kody-ai=skipped-unlicensed`, it prints one line and decides nothing more: `ADR 0064: kody-ai skipped for licensing; run the waiver step before any clean marker.`
  - **A new step, "ADR 0064 waiver step"**, sits immediately after the first fence and before "Verify checks are green". It runs only when that line printed. It is its own Bash call with `timeout: 1800000`, because the walk can take up to `WALK_DEADLINE` plus the `gh` calls. Its command is `cd "<WORKTREE_DIR>" && /usr/bin/python3 -I "${CLAUDE_PLUGIN_ROOT}/scripts/kody-waiver.py" "<owner>/<repo>" <PR_NUMBER> <full HEAD_FULL_SHA>`, with the placeholders template-substituted exactly like the existing needs-shipping call. The `cd` is described under D10. Outcomes:
    - **Exit 0, stdout exactly `waived`:** completion prints the notice "Kody did NOT review HEAD; documentation-only Cursor-bot PR; ADR 0064 licensing waiver applied (a waiver, not an ack)" and continues.
    - **Exit 10:** run the existing Shipping block, which removes both markers on every root, then BAIL with `RESULT_BAIL_CATEGORY=policy`, quoting the token. The message reads "Kody must review this PR; the merge decision is the operator's", and it does not tell anyone to merge.
    - **Exit 1 or anything else:** run the same Shipping block, then BAIL with `RESULT_BAIL_CATEGORY=env`.
    - **Never:** a clean marker, a merge or a re-wait after a non-zero exit. Removing markers covers one case: a marker left by an earlier `--no-merge` run for the same PR and HEAD would otherwise let the pre-merge gate authorize a later merge.
  - **The marker write requires the waiver.** Two blocks gain this precondition, as their first lines and before any `printf` or `cp` of the marker, using the same template substitution:
    - the default-merge marker block under "Write the pr-grind-clean marker" (`completion.md:721`, whose write is at `:742`);
    - the `--no-merge` block (`:1450`), which covers both of its marker branches, `:1468` and `:1473`.
    ```bash
    KODY_WAIVER_REQUIRED=<0|1: 1 if the first fence printed the ADR 0064 line>
    WAIVER_GRANTED=<0|1: 1 only if the waiver step exited 0 AND its stdout was exactly `waived`>
    [ "$KODY_WAIVER_REQUIRED" = 0 ] || [ "$WAIVER_GRANTED" = 1 ] \
      || { echo "❌ BLOCKED: ADR 0064 waiver not granted for this HEAD; no clean marker"; exit 1; }
    ```
    This is as strong as the existing Shipping precondition, and of the same kind: the dispatcher carries the result between Bash calls. Only the literal digits `0`/`1` are substituted, never the step's stdout. The error branch's text is untrusted, and it must never be pasted into a shell line.
  - **Ledger timestamps refuse control characters (D12).** jq's `test($ts)` with `GH_TS_RE` accepts a trailing `"\n"`, because `$` matches before a final newline; Codex and Grok reproduced it. `started_at` is the last projected field, so `$(...)` then strips that newline.
    - **Fix.** The waiver predicate in `scripts/ack-ledger.sh` adds `(test("[\u0000-\u001f\u007f]") | not)` to both `completed_at` and `started_at`, next to `test($ts)`. The `success` path's own timestamp handling is unchanged.
    - **Tests.** In `tests/test-ack-ledger-kody.sh`, `"…Z\n"` on either field, and `"…Z\r"`, read `stale`.
  - **The summary template** says Kody did NOT review only when the waiver step printed its notice.
  - **Shipping:** a refused waiver never reaches Shipping, so a Cursor Cloud Shipping run cannot land a code PR that Kody never reviewed. That matches `main`, where an unwaived skip reads `stale` and blocks before Shipping.

### Task 7: Docs-only classifier, the waiver writer, and runnable completion

**Files:**
- Modify `scripts/needs-shipping.py`:
  - Add `doc_path(path)` and `docs_only(repo, pr, head)` per D9. Document both in the module docstring.
  - `skippable()`, `classify()` and the three-argument CLI are unchanged.
- Create `scripts/kody-waiver.py` per D10.
- Modify the fetch sites and the ledger per D11:
  - `scripts/ack-ledger.sh`: the author predicate and its comment;
  - `agents/pr-grinder.md`, `scripts/fetch-pr-state.sh` and `skills/pr-grind/references/completion.md`: the two selections;
  - `tests/fixtures/kody/unlicensed-cursor-462-pr.json`.
- Modify `skills/pr-grind/references/completion.md` for the wiring above:
  - delete the audit block and its fence markers;
  - add the waiver step and the marker-write precondition at both sites;
  - **Criterion 3**, which becomes: "Kody counts as completed when Tier K acked HEAD, or when its run on HEAD was skipped because the Cursor-bot author has no Kodus seat AND the ADR 0064 waiver step printed `waived` (documentation-only PR). The waiver is not a review.";
  - **Criterion 7**, which appends: "`skipped-unlicensed` only lets completion reach the waiver step; without `waived` it blocks.";
  - the summary template, which says "Kody did NOT review — ADR 0064 waiver (documentation-only Cursor-bot PR)" only when the waiver step printed its notice.
- Modify the docs:
  - **`skills/pr-grind/SKILL.md`:**
    - the waiver summary;
    - the completion flow diagram, which gains the waiver step box;
    - the bail list, which gains: "ADR 0064 waiver refused (`not-docs-only`/`incomplete`) → `policy`; waiver step error → `env`";
    - the COMPLETION summary line.
  - **ADR 0064:**
    - Decision is amended per D9-D11.
    - Consequences gains "the waiver applies only to documentation-only PRs" and the `trips=False` residual.
  - **`docs/degraded-modes.md`:** keep the ledger sentence, and append "Completion grants it only when `scripts/kody-waiver.py` prints `waived` (documentation-only PR); otherwise pr-grind stops and Kody must review."
  - **`docs/observability.md`:** the event row is rewritten for the new writer (`scripts/kody-waiver.py`) and its fields (`scope`, `verified`, `basis`).
  - **`scripts/ack-ledger.sh`:** the capability marker becomes `tier-k5`, because the author predicate and timestamp checks changed, and gets its comment line. Every reader of the marker moves with it in the same commit:
    - the self-resolve grep at `ack-ledger.sh:186`;
    - the marker assertions at `tests/test-ack-ledger-kody.sh:398-404`;
    - ADR 0058's capability-marker note.
  - **Dependency, stated:** the first completion fence is still blocked on `main` by the existing lease-helper false positive (#1078). The waiver cannot run end to end until that lands. The first-fence row asserts only "not `BLOCK_UNSCANNABLE|`".
- **Superseded steps, marked in place.** D3's write mechanism, Task 4's "Audit block" step, the "New k5b test" step and the Task 6 replay's audit expectations each get a leading "(Superseded by the 2026-11-14 amendment — see Task 7.)", and their checkboxes become `[x] superseded`.
- **Tests:**
  - **`tests/test-needs-shipping.sh`**, through its stub `gh`, driving `docs_only` through a small `-c` harness:
    - `docs-only`: `docs/a.md`; `README.md`; `README.MD` (the extension is case-insensitive); `docs/a.md` plus `README.md`; a rename inside `docs/`.
    - `not-docs-only` because the directory match is case-sensitive: `Docs/a.md`.
    - `not-docs-only`:
      - `src/x.ts`; `tests/t.sh`; `docs/widget.test.ts`; `docs/conf.py`; `docs/a.md` plus `src/x.ts`;
      - `CLAUDE.md`; `AGENTS.md`; `.claude/x.md`; `docs/AGENTS.md`;
      - `docs/imported.md` when the head or base `CLAUDE.md` imports it;
      - a rename from `src/x.ts` to `docs/x.md`;
      - an empty listing; a listing at the cap, counted in records.
    - `incomplete`: a walk that hits its limit.
    - Errors: a `files` API failure; the head moved before the listing; only the second snapshot's head differs; only the second snapshot's base name differs; only the second snapshot's base tip differs.
    - One row in a repo not opted into Shipping, to prove the walk is not gated on opt-in.
  - **`tests/needs-shipping-selftest.py`**: `doc_path` rows. The existing `skippable` rows stay green.
  - **New `tests/test-kody-waiver.sh`**: temp repos, with a stub `gh` on `PATH` serving `docs_only`'s calls.
    - `waived` and exit 0 write exactly one record to the main checkout's state dir. It is checked with `jq -e`: every constant field, `scope=="docs-only"`, `pr` as a number, and `head_sha` as 40 hex characters. This holds from the main worktree, from a linked worktree (nothing lands in the linked one), and from a `--separate-git-dir` main worktree.
    - From a linked worktree of a `--separate-git-dir` repo it exits 1 and writes nothing.
    - `not-docs-only` and `incomplete` exit 10 and write nothing.
    - These exit 1 and write nothing: bad arguments, including a leading-zero PR and a short SHA; the state file as a symlink to `/dev/null`; and the state dir as a symlink.
    - With `BUSDRIVER_STATE_DIR=alt`, a value any sanitizer would accept, the record still lands in `.claude/bypass-log.jsonl` and nothing is created under `alt/`. This proves the variable is not read.
    - With `GIT_DIR` and `GIT_WORK_TREE` exported to point at a second temp repo, the record still lands in the cwd's main checkout and the second repo is untouched.
    - No `__pycache__` appears under `hooks/gate-scripts/lib` after a run.
  - **Gate runnability in `tests/test-pr-grind-codex-wiring.sh`:**
    - **Waiver step.** The waiver-step command, as written in `completion.md` with its placeholders filled, fed to `marker_check.py`, returns `OK|`. A control importing `audit_append` directly returns `BLOCK_MARKER_SCRIPT|audit_append.py`.
    - **First fence.** It does not return `BLOCK_UNSCANNABLE|`. It cannot be required to return `OK|` until the pre-existing lease-helper false positive on `main` (#1078) is fixed. Once #1078 lands, the row tightens to `OK|`.
    - **Wiring text.** `completion.md` contains no `audit_append` inside any bash fence. The waiver step comes after the first fence and before "Verify checks are green".
  - **`tests/test-ack-ledger-kody.sh`**: the D11 author rows and the D12 timestamp rows.
  - **k5 and k5b** live in `tests/test-pr-grind-codex-wiring.sh`. The k5 allow-list rows there are unchanged. k5b is deleted, along with the block it extracted, and `tests/test-kody-waiver.sh` covers what it covered.
  - **`tests/test-pr-grind-codex-wiring.sh`**:
    - **k1c** (`:838`), which pins the author selection, now requires `number author{__typename login resourcePath}` at all four sites, and requires that `on Bot{databaseId}` appears at none of them.
    - **New rows:**
      - the marker-write precondition is present at both sites;
      - the Shipping-block call is present on both waiver-step failure branches.
  - **`tests/test-needs-shipping.sh`, more rows:**
    - `trips=False` still raises `incomplete` on a depth or blob limit, and on a symlink;
    - a tree carrying `.claude/busdriver.json` gives `docs-only` for `docs/a.md` under `trips=False`, and still makes `classify()` route Shipping (`trips=True`);
    - a `docs/a.md` that is a symlink (mode `120000`) or executable (`100755`) at HEAD gives `not-docs-only`;
    - a removed `docs/a.md` is allowed.
- [ ] **Live read-only replays of `docs_only`:** Dive-And-Dev/chrisyau.me#462, which changes `docs/decisions/analytics-provider.md`, and busdriver#1084, which changes `docs/degraded-modes.md`, both at their head SHAs, both expecting `docs-only`. Record the output in the PR body. Nothing is written to either PR.
- [ ] Verify by running these, all green:
  - `bash tests/test-needs-shipping.sh`
  - `bash tests/test-kody-waiver.sh`
  - `bash tests/test-ack-ledger-kody.sh`
  - `bash tests/test-pr-grind-codex-wiring.sh`
  - `bash tests/test-dispatcher-commit-block.sh`
  - `npm run validate`
  - `shellcheck`
  - the gate-integrity check, after deleting `__pycache__`

  Replay PR 462 read-only through the ledger with the new selection. Then commit through Litmus, push to #1106 (still a draft), and stop at a green PR: the merge is the operator's.

<!-- design-review-coverage: FULL 3/3  -->

<!-- design-reviewed: PASS -->
