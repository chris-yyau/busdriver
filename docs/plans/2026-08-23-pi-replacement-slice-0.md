# Pi replacement — Slice 0: land the staged rename coherently

**This document is a single implementation slice, complete in itself.** The
program-level design, threat model, and review provenance for rounds 1–13 live in the
umbrella at `docs/plans/2026-08-23-pi-replacement.md`. Judge *this slice's* contract:
everything the program does beyond it is listed in §6 as an explicit non-goal, and its
absence here is deliberate.

Baseline: worktree `busdriver-remove-opencode`, branch `feat/remove-opencode-pi-read`,
HEAD `6cad2bf9`, origin/main `7e2fee30` (18 behind). Staged candidate backed up at
`/Volumes/Work/.hermes-runtime/tmp/pi-replacement-pre-fable.patch`
(SHA256 `82061951e434568818a8b83b8a164bd46ba6feecbac2fcec8df964417c960b33`).

## 1. What this slice is for

A partial rename is **already staged** (9 files) and is currently *incoherent*: it renames
the pi read lane to `pi-read` in `dispatch.sh` but leaves a test pinning the old spelling,
so the shell suite is **red before any new edit**. Slice 0 makes the staged work
internally consistent and lands it, so every later slice starts from a green suite.

It does not begin the OpenCode removal, does not create the broker or lane, and does not
change the auditor's live behaviour.

## 2. Ground truth

Verified **at authoring time** in this worktree. The first two rows are volatile by nature —
any OID or behind-count written here is stale before it is read — so they are re-verified at
implementation per AC6 rather than refreshed during review.

| Fact | Why it matters |
|---|---|
| origin/main was `7e2fee30`, 18 behind, at authoring; it has moved since. The **twelve** paths this slice touches and the upstream delta share no path | the merge is expected clean; an overlap means a real merge review. AC6 re-derives both operands from a freshly pinned OID, so the stale numbers here are a record, not an input |
| the upstream delta includes **17 `tests/` paths**, among them a dispatch timeout/failure-log test that exercises the very `dispatch.sh` this slice rewrites | the suite must be green on the **merged** HEAD, not only before the merge (§7 AC1) |
| `tests/test-agy-prose-lane.sh` is **already failing** — its line-76 golden grep pins the **`REPORT_NAME` provenance whitelist** (`dispatch.sh:2914`), *not* the `--cli` validator | it is the **tenth** path — the last code/test one — and is **not** in the nine-file staged set; paths eleven and twelve are the two plan documents (§3.1). Naming the site correctly matters because §4.2 must **not** touch it (see §4.2) |
| the `--cli` validator is the `elif [[ "$CLI" != … ]]` chain at `dispatch.sh:589`, with its valid-values error string at `:590`. It is a **different site** from the `REPORT_NAME` `case` at `:2914` | §4.2's refusal branch belongs at :589 and nowhere else |
| in `dispatch.sh`'s pi-read arm the **`pi --version` probe (~:1850) runs BEFORE `resolve_pi_read_model` (~:1871)**, and there is **no dedicated empty-model bail** — an empty model falls through to the generic provider-derivation refusal at ~:2193 | AC3 cannot claim "no pi invocation"; see §4.1.1 |
| `tests/test-pi-dispatch-arm.sh` pins the `_pi_setup_fail` call-site count at **exactly 7**, which is the number today | any new bail routed through `_pi_setup_fail` breaks that pin in the same commit — which is why this slice adds none |
| `BUSDRIVER_PI_READ_MODEL_DEFAULT` has **one definition and two references** in `scripts/lib/resolve-cli.sh` — defined once, then passed as the reader's *default* argument and again as an `\|\|` fallback, both inside `resolve_pi_read_model` | deleting only the definition leaves two dangling references |
| `_bd_read_auditor_model` takes `$1`=HOME, **`$2`=default, `$3`=key** (`"${3:-auditor}"`) — default before key, which is the reverse of the order the names suggest | the obvious two-argument edit silently retargets the read at the live auditor key (§4.1) |
| `_bd_read_auditor_model` is a **closed** `case` whose third parameter defaults to `auditor`, with several call sites, one being the **live** OpenCode auditor path | this is why §4.3 leaves the reader alone entirely — a slice that neither adds nor retargets an arm cannot disturb that live caller |
| `resolve_pi_read_model` already sets `_BD_PI_READ_MIGRATION_REQUIRED`, and the dispatch arm already consumes it to **refuse** a legacy `.pi.model` | the refusal is shipped, not new |
| the `opencode` binary is on PATH and `.claude/busdriver.json` still routes both auditor roles to `["opencode"]` | the Mechanism Witness is **live**; nothing here may disturb it |

**Checked and confirmed NOT broken** — recorded so no round is spent re-litigating them:
`--cli all` batch discovery already tolerates a skipped pi-read; the `awk` arm-slice in
`test-pi-dispatch-arm.sh` is **already retargeted** to `pi-read)`, so the suite-abort hazard
is not triggered by *that* site; and `dispatch.sh`'s library-missing shim **already fails
closed**, so it needs no edit.

**CORRECTION — the leak sweep does NOT survive untouched.** Earlier drafts of this document
recorded "the model-id leak sweep still passes once the constant is gone" as a checked fact.
That was **wrong**, and it is corrected here rather than quietly dropped because the error
survived multiple review rounds. `tests/test-auditor-model-config.sh` runs under
`set -euo pipefail`, and its `pi_default` extraction is a **bare top-level assignment** whose
command substitution begins with a `grep` for the constant. Once the constant is deleted that
`grep` exits 1, `pipefail` propagates it, and **errexit terminates the script at the
assignment** — before `${pi_default:-__none__}` is ever evaluated, and before the sweep and
every later assertion run. Reproduced in isolation: the line before the assignment prints, the
line after does not, exit status 1. The `:-__none__` fallback cannot save a line that never
completes. §5 therefore makes that row **prescriptive**, not "leave or tidy".

The *conclusion* the old claim pointed at still holds — with the pi alternative removed from
the allowlist entirely, the sweep over its nine paths returns nothing, because the only
surviving hits are `gemini-…` lines already covered by the `agy_read_default` alternative. It
is the "no edit needed" half that was false.

## 3. Scope — the complete change set

1. **Land the staged rename** (`pi` → `pi-read`, `.pi.model` → `.pi_read.model`) as
   staged, including the staged ADR amendments.
2. **Delete the shipped model default** — the `BUSDRIVER_PI_READ_MODEL_DEFAULT` definition
   *and both* of its references inside `resolve_pi_read_model`. Afterwards an unset or
   invalid `.pi_read.model` resolves empty and — **absent a `--model` override**, which
   supersedes the resolved value at `dispatch.sh:2173` (§4.1.1) — the lane skips rather than
   silently selecting a provider nobody chose. The resulting function body is written out in
   §4.1 because the reader's argument order makes the obvious edit wrong.
3. **Give `--cli pi` the same migration refusal `.pi.model` already has** (§4.2).
4. **No config-reader change** (§4.3). An earlier draft added three inert arms here; they now
   travel with the slices that first read them.
5. **Correct the in-tree text that is wrong after this commit** (§4.4) — *both* classes:
   **four** Class A sites stale from the **rename** (ADR 0034's Status lines, `dispatch.sh:273`
   and `:220`, and ADR 0040's header — all wrong already today or falsified by the staged
   bytes, and item 1 would otherwise land them unamended), and **four** Class B passages that
   assume a **shipped default**. Otherwise the commit whose purpose is to end an incoherence
   ships one.
6. **Repair every test the above breaks** (§5).
7. **Merge `origin/main`** — no rebase, no force, no history rewriting.

Nothing else.

### 3.1 The pre-existing dirt, and what may be done with it

The tree is **not clean at entry**, and an implementer who reaches for `git commit -am` or
`git add -A` will sweep in changes that are not this slice's. `git status --porcelain` at
authoring shows three populations, each with a different legal move:

| Population | Move |
|---|---|
| the **nine staged paths** + `tests/test-agy-prose-lane.sh` | the slice proper — commit them |
| `docs/plans/2026-08-23-pi-replacement.md` and `docs/plans/2026-08-23-pi-replacement-slice-0.md` (both **untracked**) | **commit them with the slice.** They are the program umbrella and this document. Untracked files can never satisfy any definition of "clean", and deleting them destroys the plan the slice implements. This is why §2 says **twelve** paths, not ten |
| `.claude/busdriver.json` (**unstaged**, operator-owned: `blueprint-review.reviewer_1`) | **leave it modified and unstaged.** §6 forbids editing it; committing it would fold an operator's reviewer-routing choice into an unrelated slice |

Therefore: **commit with an explicit pathspec — never `-am`, never `add -A`.** AC7 is
defined against this baseline rather than against an absolute clean tree, which is
unreachable from here (§7).

## 4. The changes that need spelling out

### 4.1 The post-change `resolve_pi_read_model`, written out

The deletion is one line of intent and two lines of edit, but the reader's argument order
makes the *obvious* edit wrong in a way no compiler catches, so the resulting body is
specified rather than described:

```sh
_BD_PI_READ_MODEL=""
_BD_PI_READ_MIGRATION_REQUIRED=0
resolve_pi_read_model() {
  local _new_raw _legacy_raw
  _new_raw="$(_bd_read_auditor_model "$HOME" "" pi_read_raw)"
  _legacy_raw="$(_bd_read_auditor_model "$HOME" "" pi_legacy_raw)"
  _BD_PI_READ_MIGRATION_REQUIRED=0
  if [[ -z "$_new_raw" && -n "$_legacy_raw" ]]; then
    # ... unchanged refusal block ...
  fi
  _BD_PI_READ_MODEL="$(_bd_read_auditor_model "$HOME" "" pi_read)"
  return 0
}
```

Two lines go away — the constant's definition, and the `||` fallback that was the function's
last statement — and one line arrives, the `return 0`. Everything else is untouched.

**The empty second argument is load-bearing.** `_bd_read_auditor_model` is
`(HOME, default, key)` with `key` defaulting to `auditor`. Writing the natural-looking
`_bd_read_auditor_model "$HOME" pi_read` passes `pi_read` as the *default* and lets the key
fall through to `auditor` — the live OpenCode Mechanism Witness key. A configured
`.pi_read.model` would then be ignored and `.auditor.model` would be handed to pi. AC4 and
AC5 exist as the paired regression net for exactly this mistake: AC4 fails if
`.pi_read.model` stops resolving, AC5 fails if `.auditor.model` starts leaking into this
lane.

**Keep the `return 0`, but for the right reason — and know that the shipped comment next
door gives the wrong one.** The `||` line was the last statement and returned 0 incidentally;
with it gone, the reader's status becomes the function's. The tempting rationale — "otherwise
a failed read aborts the lane under `set -e`" — is **false**: under `set -e` a failed command
substitution in an assignment exits *at the assignment*, so a trailing `return 0` never runs
and cannot prevent it. What the line actually does is **normalise the function's exit status**
in contexts where `set -e` is suspended. It is worth keeping — harmless, symmetric with the
auditor, and cheap insurance if the reader ever becomes fallible — but it is not load-bearing
today: the reader is documented and implemented to always exit 0, and the shipped refusal
branch already carries its own `return 0`.

The trap to avoid: `resolve_auditor_model`'s shipped comment states exactly the false `set -e`
rationale. §4.1 says to copy its *shape*; do **not** copy its *reasoning*. Either correct both
comments in this commit or copy it knowingly — but do not silently ship two adjacent functions
whose comments disagree.

### 4.1.1 What the dispatch site actually does with an empty model

Verified in `dispatch.sh`'s pi-read arm, and it is **not** what an earlier draft of AC3
claimed:

- The `pi --version` probe runs **before** `resolve_pi_read_model`, so **a `pi` process is
  launched on any path that reaches resolution.** "No pi invocation" is therefore false as an
  acceptance criterion, and AC3 no longer says it.
- There is **no dedicated empty-model bail.** After resolution the arm refuses only on
  `_BD_RESOLVE_CLI_SOURCED` and `_BD_PI_READ_MIGRATION_REQUIRED`; an empty model falls through
  and is caught by the **generic provider-derivation refusal**, which reports that it could
  not derive a provider from an empty model reference.
- **`--model` overrides the resolved value, and every claim below is conditional on its
  absence.** The arm derives the provider as `${MODEL:-$_BD_PI_READ_MODEL}`
  (`dispatch.sh:2173`, `:2189`, `:2193`, `:2308`), so a `--model provider/id` on the command
  line supplies a model even when resolution returned empty — the lane then dispatches
  normally and does **not** skip. The migration refusal is gated the same way: `:1874` reads
  `[[ -z "${MODEL:-}" && "${_BD_PI_READ_MIGRATION_REQUIRED:-0}" == "1" ]]`, so `--model` also
  suppresses the legacy refusal.

**The outcome this slice promises is real, with that precondition stated**: **absent
`--model`**, the lane ends `skipped`, the jail is never created, and no credential is
projected. Only the *message* is generic rather than one naming `.pi_read.model`. With
`--model` supplied the operator has named a provider explicitly and the lane proceeds — which
is the pre-existing contract of that flag, not something this slice changes.

**This slice deliberately adds no new bail.** A dedicated `Skipped:` marker in the auditor's
`_oc_no_model` shape would be nicer, but it is a new branch — and routing it through the
existing `_pi_setup_fail` instead would break the exact-7 call-site pin (§2) in the same
commit. Both are code changes beyond "delete a default", so the better message is recorded in
§6 as a deferred non-goal rather than smuggled in here.

### 4.2 `--cli pi` refuses with a migration message

The staged `dispatch.sh` enum already spells `pi-read` and has no `pi` branch, so at this
commit `--cli pi` degrades to a generic "invalid --cli value" error. That is a regression
in helpfulness and it is inconsistent with `.pi.model`, which already refuses with an
explicit migration message. Slice 0 therefore adds a `pi` branch that emits a migration
message and exits non-zero.

**Exactly where.** An exact-match arm immediately **before** the `--cli` validator chain at
`dispatch.sh:589`:

```sh
elif [[ "$CLI" == "pi" ]]; then
    echo "busdriver: --cli pi is no longer accepted; use --cli pi-read." >&2; exit 1
```

Three ways to get this wrong, all reachable from the current text of the tree:

- **Not a prefix test.** `[[ "$CLI" == pi* ]]` would also swallow the live `pi-read`.
- **Not the `REPORT_NAME` `case` at `dispatch.sh:2914`.** That site is a filename and
  audit-log identity, not the `--cli` validator. Adding `pi` there would accept the legacy
  spelling *as an audit identity* — the opposite of this section's intent. It is also the
  site `tests/test-agy-prose-lane.sh:76` pins (§2, §5), so the two edits are easy to confuse:
  the prose-lane test's pinned literal is retargeted `pi)` → `pi-read)` **there**, while `pi`
  is rejected **here**.
- **Not added to the valid-values string at `:590`**, which enumerates what *is* accepted.

**Its own message, not the key's.** The shipped `.pi.model` refusal says to move a value to
`.pi_read.model`. Reusing that text for a **flag** mistake tells an operator whose config is
already correct to go edit a key they never set. The two refusals get two texts, and AC4
asserts them separately.

This is **not** an enum addition: `pi` remains invalid and nothing dispatches. It is the
same refuse-and-migrate *contract*, applied to the flag as well as the key, so both legacy
spellings fail — each with a message about the thing the operator actually typed.

### 4.3 The config reader — no arm beyond the three staged ones

**Be exact, because "unchanged" would be false.** The staged bytes item 1 lands **do** touch
`_bd_read_auditor_model`: hunk `@@ -308,7 +308,9 @@` adds `pi_read`, `pi_read_raw` and
`pi_legacy_raw` inside it (working tree `resolve-cli.sh:311-313`). What this slice adds is
**nothing beyond those three** — no fourth arm, no rename, no retarget of the third
parameter's `auditor` default. This is the same wording AC5 uses, deliberately.

An earlier draft added three inert arms (`pi_auditor`, `pi_worker`, `auditor_legacy_raw`)
against named future consumers, on the argument that re-opening a closed `case` three times
costs three review passes. **That trade is withdrawn.** Two review rounds rated the arms
plan-blocking, and the cost was never three lines: §5 and a since-deleted acceptance
criterion owed them behavioural tests in *both* a normal and a synthetic no-jq pass — a
meaningful share of this slice's test work spent on code nothing calls, inside the one
function this tree deliberately hardens. **Each arm now travels with the slice that first
reads it**, where its test earns its keep and its shape can be chosen against a real caller
rather than a predicted one:

| Arm | The slice that adds it |
|---|---|
| `pi_auditor` | the slice standing up the Pi auditor role |
| `pi_worker` | the slice adding the bounded Pi worker |
| `auditor_legacy_raw` | the same auditor slice — it is what lets `.auditor.model` refuse-and-migrate |

Deferring costs this slice nothing, but be precise about why. §4.1's post-change
`resolve_pi_read_model` reads the legacy key through **`pi_legacy_raw`**, and that arm — with
`pi_read` and `pi_read_raw` — is **already in the staged bytes item 1 lands** (working tree
`resolve-cli.sh:311-313`; the staged hunk is `@@ -308,7 +308,9 @@`, so none of the three
exists at HEAD). They are *not* "already shipped"; they arrive with the rename, and the three
arms deferred above are **additional** to them. So no part of Slice 0 depends on a *new* arm.
The live OpenCode auditor keeps resolving `.auditor.model` through the untouched `auditor`
arm exactly as today.

### 4.4 Text that becomes false — two different staleness classes

This slice exists to end an incoherence, so it must not commit one. There are **two**
classes here and they have different causes; both ship in this commit.

**Class A — stale from the *rename*, already true today.** Four sites, all owed whether or
not the default is deleted:

- **`docs/adr/0034`** — one of the files item 1 lands "exactly as staged", and its **Status
  lines still name the `pi)` arm and the `resolve_pi_model` symbol**. Neither exists after
  the staged rename. Landing the file unamended would knowingly commit a document that
  misnames the two things it points at. Retarget to `pi-read)` and `resolve_pi_read_model`.
- **`skills/dispatch-cli/scripts/dispatch.sh:273`** — the version-pin comment reads "the
  `pi)` arm and docs/adr/0034": an exact reference to a **case label the rename removes**.
  Retarget the label.
- **`skills/dispatch-cli/scripts/dispatch.sh:220`** — "Deliberately NOT a duplicated default
  (unlike the pi stub above, which is the drift class this repo has already paid for)". At
  HEAD that parenthetical is **true**: the stub really is
  `resolve_pi_model() { _BD_PI_MODEL="opencode-go/deepseek-v4-flash"; }`. The **staged diff
  already replaces it** with `resolve_pi_read_model() { _BD_PI_READ_MODEL=""; }`, so the
  staged bytes falsify a comment three lines below them. Drop the parenthetical — the
  contrast it drew no longer exists.
- **`docs/adr/0040-agy-read-lane-default.md:5-6`** — the header still reads "**Amends:** ADR
  0034 … pi is retained and **unchanged**", which this slice falsifies **twice** (the rename,
  and again by deleting the default). The staged diff already removes the matching "**pi
  stays.**" bullet further down that file but **leaves the header untouched**, so the file
  this slice commits would ship self-contradicting. Amend the header to match the bullet
  that is already going.

**Class B — made false by deleting the default.** Four passages describe a constant this
slice removes:

- **ADR 0034** — the sentence warning that a legacy-only config must not "silently fall
  through to the shipped default provider" (there is no longer a default to fall through
  to; the behaviour is refusal), and the paragraph about the shipped default's
  provider-region opt-in, which becomes a historical note rather than live guidance.
- **`scripts/lib/resolve-cli.sh`** — the comment asserting that the auditor-default
  deletion left "the `.pi_read.model` default below" unaffected; and the `OPERATOR CAVEAT`
  block above `resolve_pi_read_model`, which is built entirely on the shipped default's
  China-hosting opt-in.

  **Do not point that rewrite at the auditor's header.** The auditor's rationale turns on it
  being an *optional advisory voice* whose unconfigured operator holds no credential — an
  argument that does not transfer to a **read lane that ships repo source to a named third
  party**. The conclusion transfers; the reason does not. Use §3 item 2's own sentence
  instead: *NO shipped default, deliberately — an unset or invalid `.pi_read.model` resolves
  empty and the lane skips, rather than silently selecting a provider nobody chose.* Keep the
  surviving half of the old caveat — that a **configured** model may be region-gated, which
  is why the arm surfaces the child's stderr — as live guidance.
- **`skills/dispatch-cli/scripts/dispatch.sh`** — the pi-read arm comment reads "the
  configured model can be region-gated (the shipped default returns HTTP 403 RegionError
  …)". The outer claim stays true and is the reason stderr is merged; only the
  shipped-default parenthetical goes.
A comment-only edit inside the pi-read arm does not move the arm, so it does not disturb the
`awk` slice in `tests/test-pi-dispatch-arm.sh` (§2). The `:220` and `:273` edits sit **outside**
that arm, so they cannot disturb it either.

## 5. Test repairs — the complete list

The suite is **run**, not asserted (§7 AC1).

| Suite | What breaks |
|---|---|
| `tests/test-agy-prose-lane.sh` | Already red at entry. Its line-76 golden grep pins the **`REPORT_NAME` provenance whitelist** at `dispatch.sh:2914` — *not* the `--cli` validator. Retarget the pinned literal `pi)` → `pi-read)`. `tests/test-agy-read-lane.sh` holds the already-retargeted sibling pin, which is the shape to copy |
| `tests/test-auditor-model-config.sh` | Exactly **one** pair of lines breaks: the `PI_DEFAULT` grep of the constant and the `[[ -n "$PI_DEFAULT" ]]` assertion immediately under it. Note it **aborts** the script rather than reporting a failed assertion — same errexit mechanism as the leak-scan row below — which is harmless only because the prescribed replacement removes the assignment. Invert them to the **auditor** half of the same file — which already asserts `grep -qE '^BUSDRIVER_AUDITOR_MODEL_DEFAULT=' ⇒ fail` — so the pi half becomes the same present-⇒-fail pin. The `PI_SHIM_DEFAULT` assertion **two lines further down already asserts empty** and must be **left alone**: collapsing the pair into it would delete the only pin that keeps the constant deleted |
| `tests/test-auditor-model-config.sh` — leak scan | **Mandatory, not a tidy-up.** The `pi_default` extraction is a bare assignment from a `grep` for the deleted constant; under this file's `set -euo pipefail` it **aborts the whole script** at that line (§2 CORRECTION), so the sweep and every later assertion never run and AC1 cannot pass. **Delete that assignment and drop the `${pi_default:-__none__}` alternative from `model_value_allow`** — verified safe: re-running the full sweep with only the `agy_read_default` alternative returns nothing. (`\|\| true` inside the substitution would also work, but deleting a now-dead lookup is cleaner.) **Keep** the `PI_READ_MODEL_DEFAULT` token inside the `grep -vE` exclusion — that one *is* just a pattern and cannot fail. The `agy_read_default` alternative **must survive**: it is what excludes the live `.claude/CLAUDE.md` prose line from the sweep |
| `tests/test-pi-dispatch-arm.sh` sections 7 and 8 | **Five sites, and running the suite will surface only the first.** `:1306` (section 7) is a bare top-level assignment `DEFAULT="$(grep -E '^BUSDRIVER_PI_READ_MODEL_DEFAULT=' "$LIB" \| cut -d'"' -f2)"`; under this file's `set -euo pipefail` (`:32`) the grep exits 1 once the constant is gone, `pipefail` propagates it and errexit **aborts the whole file at that line** — the same mechanism as the §2 CORRECTION and the leak-scan row, *not* a reported assertion failure. So AC1 cannot enumerate the downstream damage and the four `$DEFAULT` comparison sites must be named here instead: **`:1321` (leading-dash), `:1324` (no-slash), `:1334` (missing config) — all three in section 7 — and `:1338` (`.auditor.model does not leak into the pi lane`), which is in section **8** (its header is `:1336`). An earlier draft attributed the first three to section 8 and never named `:1338` at all. **All four expect empty** after the deletion. **Repair:** invert `:1306`–`:1308` to the auditor absence pin (copy the block shape at `tests/test-auditor-model-config.sh:57-58`: `grep -qE '^BUSDRIVER_PI_READ_MODEL_DEFAULT=' ⇒ fail`), then **explicitly re-bind `DEFAULT=""`** — without it `$DEFAULT` is unset and the four expansions abort the file under `set -u`, `:1338` included. Update the three now-false assertion texts (`:1321` / `:1324` "degrades to the default", `:1334` "falls back to the default"); `:1338`'s text stays true. **Keep `:1339-1340`** — the "auditor still resolves" half is unaffected |
| `tests/test-agy-read-lane.sh` | Reads `pi_default` the same way and has an explicit `fail` branch when the constant cannot be read, so after the deletion it **fails on the read, before its comparison is reached**. Drop the `pi_default` lookup entirely and assert a bare (non-`provider/`) id resolves **empty** — which still proves the grammar did not leak. Its `--cli` enum pin is already updated in the staged tree |

**New coverage this slice owes**, because deleting a default is a behaviour change and no
existing test asserts the replacement behaviour:

1. **Resolver-level, hermetic** — and it must assert **two** variables, not one. Against a
   fixture `HOME`, assert `_BD_PI_READ_MODEL` *and* `_BD_PI_READ_MIGRATION_REQUIRED` together
   across three configs:

   | Config | `_BD_PI_READ_MODEL` | `_BD_PI_READ_MIGRATION_REQUIRED` |
   |---|---|---|
   | neither key | empty | `0` |
   | legacy-only `.pi.model` | empty | **`1`** |
   | both keys valid | the `.pi_read.model` value | `0` |

   **Why the flag is not optional.** Deleting the default destroys the discrimination the
   existing legacy-refusal pin relies on. Today a legacy-only config yields empty *with* the
   refusal and the shipped default *without* it, so the pin "legacy-only `.pi.model` fails
   closed instead of selecting the shipped default" is real. After this commit both outcomes
   are empty — the same value an unset config returns — so that assertion goes **vacuous in
   the same commit that this slice makes**, and would keep passing if the entire refusal branch
   were deleted. `_BD_PI_READ_MIGRATION_REQUIRED` restores the distinction: it is an ordinary
   shell variable the function already sets and `dispatch.sh` already consumes, needing no
   stderr capture and no new harness. One extra `printf` per case.

   **The helper must be spelled out, because the existing one is not adequate and AC2 forbids
   it.** The in-tree shape `bash -c 'source "$0"; …' "$LIB"` starts a **fresh shell that does
   not inherit `set -u`**, so a leftover unbound `$BUSDRIVER_PI_READ_MODEL_DEFAULT` expansion
   inside the function resolves to empty and this bullet goes **green** while production
   `dispatch.sh` (`set -euo pipefail`, `:176`) aborts on it. Write it with the option on:

   ```
   read_pi_read() ( HOME="$FAKE_HOME" bash -c 'set -u; source "$0"; resolve_pi_read_model 2>/dev/null; printf "%s|%s" "$_BD_PI_READ_MODEL" "${_BD_PI_READ_MIGRATION_REQUIRED:-0}"' "$LIB" )
   ```

   Do **not** copy the existing helper verbatim; `set -u` is the load-bearing difference.
2. **`--cli pi`** emits its own migration message (§4.2's text, not the key's) and exits
   non-zero.
3. **The identifier-absence instrument** — the second of AC2's three discharges, and it is a
   *different* instrument from bullet 1, not a rewording of it. Bullet 1 observes a resolved
   **value**; this observes the **function body**:

   ```
   sed -n '/^resolve_pi_read_model()/,/^}/p' "$LIB" | grep -q 'BUSDRIVER_PI_READ_MODEL_DEFAULT' && fail || ok
   ```

   Scoped to the function, so it is unaffected by the definition pin's own spelling of the
   name elsewhere in the file (§7 AC2's explicit `tests/` exception).
4. **One no-jq pass over the three STAGED arms.** No coverage is owed for the three *deferred*
   arms — they travel with the slices that add them (§4.3). But `pi_read`, `pi_read_raw` and
   `pi_legacy_raw` **do** ship here and `resolve_pi_read_model` consumes all three, so waiving
   their python-fallback coverage would rest on a premise the staged diff contradicts.

   Each arm carries two independently-typo-able fields, `jqf` and `pykey`, and the child tries
   jq first, falling back to python3 **only when jq returns empty**. With jq present a wrong
   `pykey` is never consulted, so the normal pass cannot see it. Reuse the harness already in
   `tests/test-auditor-model-config.sh:143-144` — a `sed` repointing the jq loop at
   `/nonexistent/jq` — and re-run **two** existing bullet-1 cases against it: legacy-only still
   yields `_BD_PI_READ_MIGRATION_REQUIRED == 1`, and both-keys still resolves
   `.pi_read.model`. Together those exercise all three arms' `pykey` fields.

   **Named residual — `jqf` is still not covered.** A wrong `jqf` makes jq return empty, which
   is exactly the condition that triggers the python fallback, so a correct `pykey` silently
   rescues it in both passes. It is observable only on a **jq-present, python-less** host,
   which neither pass simulates. Closing it needs a second synthetic library repointing the
   *python* loop; this slice deliberately does not, and records `jqf` as a residual instead —
   stating the weaker claim next to the weaker test rather than the stronger one.

**A dispatch-level end-to-end case is deliberately NOT owed**, and this is a correction of an
earlier draft rather than an omission. It could not be made hermetic: the arm pins `HOME` to a
password-DB-derived path **at the resolve call itself**, with no `$HOME` fallback, so neither a
process `HOME` nor a `PATH` stub can substitute a fixture config — `tests/test-dispatch-skipped-status.sh`
documents this exact footgun. Worse, such a test would go **green for the wrong reason** on both
plausible hosts: on CI with no `pi` it short-circuits at binary-not-found to the same `skipped`
status without ever reaching the empty-model path, and on this host the key is unset anyway
(§8). A test that never executes the changed code is not caught by running the suite — which is
precisely why this is settled here, in the plan, rather than left to be discovered.

## 6. Non-goals — deliberately deferred

- **No OpenCode removal.** The CLI arm, its review config, its dedicated test file and the
  `opencode-go` provider references remain untouched and working.
- **No `.auditor.model` behaviour change.** No rename of the `auditor` arm, no retarget of
  the reader's default, no refusal for that key. The Mechanism Witness resolves exactly as
  today.
- **No broker, no lane, no manifests, no worker, no controller profiles.**
- **No extraction of the `pi-read)` dispatch arm.** It stays put; extraction and its test
  retargeting are one later commit.
- **No `.claude/busdriver.json` edit.** Both auditor roles keep routing to `["opencode"]`.
- **No `--cli` enum additions** (§4.2 adds a rejection branch, not an accepted value).
- **No dedicated empty-model `Skipped:` bail** in the pi-read arm. The behaviour is already
  correct (§4.1.1); only the message is generic. Adding an `_oc_no_model`-shaped branch, or
  routing one through `_pi_setup_fail` and raising the exact-7 pin, is a code change beyond
  "delete a default" and belongs to the slice that next touches that arm.
- **No Codex changes.**
- **No `.claude/CLAUDE.md` edit.** Known residual: that file advertises `--cli pi` /
  `.pi.model` as live, it is itself in the upstream delta, and the merge re-lands that
  stale guidance. Correcting it travels with the later slice that completes the cut; this
  slice records the staleness rather than silently leaving it undocumented. **The same
  residual covers one line in `skills/writing-prose/SKILL.md`** — `:111`, listing "a
  deliberate divergence from `pi` and `agy_read`", where the neighbouring `agy_read` is in
  **config-key** form, making `pi` there read as the renamed `.pi.model` key.

  **Four further sites are LANE-name references, and are deferred as named residuals.** An
  earlier draft asserted that every *other* `pi` in `SKILL.md` names the **binary**. That is
  false, and the error matters because this inventory is what a later slice will trust.
  `skills/writing-prose/SKILL.md:140` ("the same exemption `pi`, `opencode` and `agy-read`
  carry") and `skills/dispatch-cli/scripts/dispatch.sh:433` ("Like `pi` it runs IN the
  working tree"), `:605` ("exactly like `pi`, `opencode` and `agy-read`") and `:625` ("equally
  to `agy-read`, `pi` and the reviewer slots") each sit `--cli` **lane** names beside
  `opencode` / `agy-read` — the identical neighbour-form argument this section uses to
  classify `:111` as a key reference. They are **deferred**, not fixed here: they travel with
  the later slice that completes the cut, alongside `.claude/CLAUDE.md`. What is not
  acceptable is leaving them **recorded as binary references**, which is why they are named.
  `SKILL.md`'s remaining `pi` mentions (e.g. `:126`, "use `pi` if you need an enforced
  boundary") do name the **binary**, whose name this slice does not change, and must not be
  swept.

  **Do not run a broad tracked-index sweep for the token `pi`.** Most hits are correct
  references to the pi binary — ADR 0034 is titled for the tool — and sweeping them would
  inflate the slice and introduce errors. §4.4's two classes are deliberately narrow.

  **Correction — the library-missing shim comment is NOT pre-existing debt.** An earlier
  draft filed `dispatch.sh:220` ("a duplicated default") here as debt predating the slice, on
  the reading that the shim "is not" a duplicated default. That is backwards: at HEAD the pi
  stub *is* one, so the comment is true today and is falsified by **this slice's own staged
  bytes**. It is therefore a §4.4 Class A site and is listed there. Nothing about it is
  deferred.

## 7. Acceptance criteria

1. `scripts/ci/run-shell-tests.sh` **runs to completion and is green on the merged HEAD** —
   not only before the merge. The runner globs `tests/test-*.sh`, and the merge adds test
   files including one that exercises the `dispatch.sh` this slice rewrites, so a pre-merge
   green run does not establish a post-merge green tree. Running it is the criterion; no
   grep substitutes.
2. No `^BUSDRIVER_PI_READ_MODEL_DEFAULT=` **definition** survives under `scripts/` or
   `skills/dispatch-cli/scripts/`, and `resolve_pi_read_model` has no `$BUSDRIVER_PI_READ_MODEL_DEFAULT`
   fallback.

   **Explicit exception: `tests/` may — and after this slice must — spell the identifier
   out.** The absence pin §5 requires is `grep -qE '^BUSDRIVER_PI_READ_MODEL_DEFAULT=' ⇒ fail`,
   which necessarily contains the name, as does the leak scan's exclusion pattern. An earlier
   draft demanded the name appear nowhere under `tests/`, which contradicted §5 and pushed an
   implementer toward deleting the very pin that keeps the constant deleted. This criterion is
   about the **definition and the fallback**, never about a literal name search.

   **Three instruments discharge this criterion, and they are listed here so §5 and AC2 cannot
   drift apart again:**

   1. **The definition pin** — `grep -qE '^BUSDRIVER_PI_READ_MODEL_DEFAULT=' "$LIB" ⇒ fail`
      (§5's `test-pi-dispatch-arm.sh` row, and the sibling in `test-auditor-model-config.sh`).
   2. **The identifier-absence pin** — `sed`-scoped to the function body (§5 bullet 3). This
      is what discharges the **fallback** half.
   3. **The resolver assertion** under `set -u` (§5 bullet 1).

   **Why 2 is needed and 3 alone is not.** The bullet-1 helper runs
   `bash -c '…' "$LIB"` — a **fresh shell that does not inherit `set -u`** unless the command
   string sets it. A leftover `${BUSDRIVER_PI_READ_MODEL_DEFAULT}` expansion inside the
   function would resolve to empty there and the suite would go **green**, while production
   `dispatch.sh` (`set -euo pipefail`, `:176`) aborts on the same unbound expansion. Observing
   only the *resolved value* is therefore a guard that cannot fire. §5 bullet 1 turns `set -u`
   on for that reason, and instrument 2 covers it independently of shell options.
3. An unset `.pi_read.model` resolves **empty** — asserted at the resolver, hermetically
   (§5 bullet 1). **That resolver assertion is the whole of AC3.**

   The lane-level consequence (**absent `--model`** — §4.1.1: it supersedes the resolved value
   at `dispatch.sh:2173`, and also suppresses the migration refusal at `:1874`) is that the
   lane ends `skipped` with no prompt-bearing pi dispatch, no jail creation and no credential
   projection. That is **recorded as the intended behaviour, not asserted as a criterion** —
   §5 establishes that a dispatch-level end-to-end test cannot be made hermetic here and is
   deliberately not owed, so a clause no test in this slice discharges must not stand as an
   acceptance criterion. An earlier draft asserted it outright; the criterion is now the
   resolver assertion, which §5 bullet 1 actually enforces.

   Note deliberately *not* claimed: "no pi invocation" — the version probe runs before
   resolution (§4.1.1).
4. A **legacy-ONLY** non-empty `.pi.model` refuses with its shipped migration message. When
   **both** keys hold valid values there is **no refusal** — `.pi_read.model` wins without
   aliasing the legacy key, which the tree already pins. The shipped condition is
   `[[ -z "$_new_raw" && -n "$_legacy_raw" ]]`, so "a configured `.pi.model` refuses" — the
   earlier wording — was simply wrong and would have had an implementer assert a refusal that
   contradicts both the shipped behaviour and that existing pin.

   Additionally: a configured `.pi_read.model` resolves, and `--cli pi` refuses with **its
   own** message (§4.2). **Only the `--cli pi` message is asserted against its text** — the
   shipped `.pi.model` sentence goes to stderr, and the existing helper that reads this
   resolver discards stderr, so asserting that text would require a new stderr-capturing
   variant. That is not owed here.

   The legacy refusal is instead asserted on `_BD_PI_READ_MIGRATION_REQUIRED == 1` (§5 bullet
   1). It must **not** be asserted on empty resolution alone: after this commit an empty model
   no longer distinguishes "refused" from "nothing configured", so an effect-only assertion
   would pass with the refusal branch deleted. The tree currently gets away with that only
   because the shipped default supplies the contrast this slice removes.
5. A configured `.auditor.model` **still resolves** through the existing caller — proving the
   `auditor` arm was left alone.

   **State the instrument precisely: "no diff in `_bd_read_auditor_model`" would be false.**
   The staged bytes item 1 lands *do* touch that function — hunk `@@ -308,7 +308,9 @@` adds
   the `pi_read`, `pi_read_raw` and `pi_legacy_raw` arms inside it. The criterion is therefore
   that the implementation adds **no arm beyond those three staged ones**, and leaves the
   `auditor` arm and the third parameter's `auditor` default untouched (§4.3). Discharged by
   reading the function's diff, plus the behavioural resolve above.

   The three staged arms additionally carry **one no-jq pass** (§5 bullet 4), so a `pykey`
   typo in code this slice actually ships fails the suite. `jqf` remains a named residual
   there — do not restate it as covered.
6. **Overlap is checked against the upstream-only delta, with the target OID pinned once.**
   `git fetch`, then `M=$(git rev-parse origin/main)` and keep that `$M` for both the check
   and the merge, so a mid-run upstream push cannot make the checked set and the merged set
   differ. The check is
   `comm -12 <(<slice path set> | sort) <(git diff --name-only $(git merge-base HEAD "$M") "$M" | sort)`
   — **both** operands explicitly sorted. `git diff --name-only` happens to emit sorted paths
   today, so sorting only one side is latent rather than live breakage, but the asymmetry
   invites an unsorted hand-built slice list.

   Two details that made the earlier form vacuous, recorded so they are not reintroduced:
   the slice's own path set must come from `git diff --name-only HEAD^ HEAD` **after** the
   commit (or the staged set **before** it) — `--cached` is empty once committed, making the
   intersection trivially empty; and the upstream operand must be the merge-base diff, not
   `git diff HEAD origin/main`, which is a two-dot tree comparison that also lists this
   branch's own paths as soon as the slice has a commit.

   A non-empty intersection means **inspect those files' merge by hand** — nothing more. It
   is not a statement about fast-forwarding: that is decided by ancestry, and once this
   slice has its own commit `git merge` produces a merge commit whatever the path sets are,
   which is what §3 item 7 wants.

   Because the slice set is derived from what the commit **actually contains**, the two plan
   documents added by §3.1 enter the check automatically — correct behaviour, but it means
   §2's path count and this set must agree. Both say **twelve**.
7. **No new dirt, measured against a `git status --porcelain` captured before implementation**
   — not an absolute clean tree, which is unreachable from this baseline (§3.1). Concretely:
   the twelve slice paths are committed and clean; `.claude/busdriver.json` still carries
   **exactly** its pre-implementation unstaged diff, neither staged nor reverted; and nothing
   else has appeared. No rebase, no force-push, no history rewriting.

   **Porcelain alone cannot discharge the "exactly" clause — capture the content too.**
   `git status --porcelain` emits one line for that path (` M .claude/busdriver.json`)
   carrying status and path and **no content**, so it cannot tell the operator's original
   diff from a different one. An earlier draft named it as the sole instrument, which made
   the strictest clause in this criterion unmeasurable for precisely the operator-owned file
   §3.1 and §6 exist to protect. Therefore, **before** implementation capture *both*
   `git status --porcelain` **and** `git diff --binary -- .claude/busdriver.json` with its
   SHA-256; afterwards require the patch hash **and** the staged/unstaged status to match.
   (The current bytes are pinned in the parked handoff, so the baseline is already recorded.)

   **AC6's intersection also excludes this path**, because the file is never in the slice's
   committed path set — so an upstream change to it is invisible to that preflight while
   still able to complicate the merge. Run the AC6 intersection a **second** time against the
   pre-existing dirty path set (`.claude/busdriver.json`) and stop before merging if upstream
   touched it.

## 8. Risks and residuals

- **The suite is red at entry**, so only a green run proves success; a partially repaired
  suite that aborts early can look like progress.
- **The reader is a closed `case` with several call sites.** Enumerate them rather than
  trusting a count here; only some rely on the third parameter's default, and the live
  auditor is among them.
- **Deleting the default is a behaviour change** for anyone relying on it. Intended: the
  operator-visible outcome, **absent `--model`**, is a skip rather than a silent provider
  selection. Note what AC3 actually asserts — only that an unset `.pi_read.model` resolves
  **empty at the resolver**; the lane-level skip is recorded there, not asserted, because §5
  establishes that no hermetic test in this slice can discharge it. The key is unset on this
  host.
- **The merge may stop being clean** — origin/main moves; AC6 re-checks rather than
  trusting §2's numbers.
- **Residual after this slice:** the program is more consistent but not migrated — OpenCode
  remains live, the pi lane still has no broker, and `.claude/CLAUDE.md` still advertises
  the legacy spellings. That is the intended end state of slice 0.

## 9. Delivery

Normal Busdriver pipeline: commit-time litmus, then the merge, then the post-merge suite
run required by AC1. This slice opens no PR of its own; it lands on the existing branch and
the program's PR follows later slices. No gate skips, no skip markers, no `--admin`.

**Rollback, defined by intent rather than by commit count.** The slice leaves two commits —
its own, and the `origin/main` merge — and they roll back differently:

- **To undo the slice:** `git revert <slice-commit>` and **leave the merge in place**. This
  is the rollback that is actually wanted: the merge exists to catch the branch up to
  upstream, and undoing it is not part of undoing the rename or the default deletion.
- **To undo the merge as well** (rarely wanted): `git revert -m 1 <merge-commit>`. Plain
  `git revert` on a merge errors without `-m`. State the consequence precisely, because the
  obvious wording is wrong: this is a **content** rollback, not an ancestry one. It reverses
  the tree changes the merge brought in, but the merge commit and every `origin/main` commit
  it carried **remain ancestors of HEAD** — the branch is *not* behind upstream, and
  `git rev-list --count HEAD..origin/main` still reads `0`. An earlier draft said "putting the
  branch back behind upstream", which is false and hides the operationally important hazard:
  because those commits are still ancestors, a later ordinary `git merge origin/main` of the
  same tip is a no-op and will **not** restore the reverted upstream content. Recovering it
  requires reverting the merge-revert commit, or another deliberate reapplication.
- **To recover the pre-slice staged candidate:** the backup patch named in the header, with
  its SHA256.

No rebase, no force-push, no history rewriting in any of the three paths.

## 10. Errata — binding on the implementer

Accepted knowingly at Round 8 (`run_id=e9c10ee9`, verdict **FAIL**, `parked_no_progress`).
The verdict is **not** relabeled; these six corrections bind where they contradict §1–§9.

1. **Do not redefine `read_pi_read()`.** It exists at `tests/test-pi-dispatch-arm.sh:1304`,
   prints the **model only**, and is consumed as a bare string at `:1311`, `:1314`, `:1317`,
   `:1321`, `:1324`, `:1334`, `:1338`. Leave it alone. §5 bullet 1's two-value assertion uses
   a **new, separately named** helper — `read_pi_read_pair()` — emitting `model|flag`.
2. **`set -eu`, not `set -u`.** `set -u` alone does **not** abort when the leftover
   `$BUSDRIVER_PI_READ_MODEL_DEFAULT` sits in the default-argument position
   (`resolve-cli.sh:890`): the subshell errors but the outer shell continues with an empty
   value and the assertion passes. Only `set -eu` aborts. Applies to §5 bullet 1's snippet and
   AC2's prose wherever they say `set -u`.
3. **`dispatch.sh:270`, not `:273`.** `:270` is the version-pin comment naming the `pi)` arm;
   `:273` reads "where a stuck lane beats a skipped check". Applies to §3 item 5 and §4.4
   Class A.
4. **Class B has five sites, not four** — ADR 0034:79, ADR 0034:178, `resolve-cli.sh:400`, the
   OPERATOR CAVEAT (~`:867-873`), and the pi-read arm parenthetical. §3 item 5's count is wrong.
5. **`git add` the two untracked plan documents before the explicit-path commit.**
   `git commit -- <pathspec>` cannot stage an untracked file, so §3.1/AC7's twelve-path commit
   is unbuildable as written. Explicit pathspec still applies — never `-am`, never `add -A`.
6. **Umbrella `docs/plans/2026-08-23-pi-replacement.md:619-621` is vacuous** — it defines the
   overlap check as two-dot `git diff --name-only HEAD origin/main`, the exact form AC6 exists
   to retire. Use the AC6 mechanism (merge-base diff, both operands sorted, OID pinned once).
   Umbrella repair is out of scope for this slice; this records the defect.
