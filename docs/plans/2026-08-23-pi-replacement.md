# Pi replacement program — umbrella / index

> **Status: UMBRELLA. Not the review target.** Thirteen blueprint-review rounds on this
> document as a monolith oscillated rather than converged (plan-blocking high across
> rounds 6–13: 4, 4, 4, 8, 2, 4, 2, 5) for two structural reasons: at 62 KB it exceeds
> what `reviewer_1` can review inside the loop's 1200s budget, so coverage could not be
> recorded FULL; and fixing a finding here usually required specifying an implementation
> *mechanism* that could not be verified without building it, which then became the next
> round's finding.
>
> The program is therefore **split per slice**. Each slice gets its own self-contained,
> independently reviewable spec that fits the existing coverage budget; this document is
> retained as the umbrella — the program-level design, threat model, inventory and the
> full provenance of rounds 1–13 — and is **not** submitted for review as a whole.
>
> | Slice | Spec | Review status |
> |---|---|---|
> | 0 — land the staged rename coherently | `2026-08-23-pi-replacement-slice-0.md` | in review |
> | 1–7 | not yet split | pending slice 0 |
>
> Everything below is the program design as it stood after round 13. Where a per-slice
> spec exists, **the slice spec governs** and this document is context.

## Program design (rounds 1–13 provenance)

Worktree `busdriver-remove-opencode`, branch `feat/remove-opencode-pi-read`, HEAD
`6cad2bf9`, origin/main `7e2fee30` (18 behind; re-verify both immediately before
slice 0 — the remote moves). Staged candidate backed up at
`/Volumes/Work/.hermes-runtime/tmp/pi-replacement-pre-fable.patch`
(SHA256 `82061951e434568818a8b83b8a164bd46ba6feecbac2fcec8df964417c960b33`).

## How to read this document

Three rules, adopted after nine review rounds in which the failures were
overwhelmingly *self-inflicted inconsistency* rather than bad design:

1. **Nothing is normative about line numbers, flag spellings, or command lines.**
   Where an exact spelling or capability matters, the requirement is a *contract* and
   the implementer discharges a **probe obligation** against the installed tools.
2. **Nothing is normative about which call sites exist.** Where a change touches
   coupled code, the requirement is an invariant plus a **discovery obligation**: the
   implementer enumerates the real call sites and a RED fails if any is missed. Earlier
   revisions asserted counts ("the only caller") that were wrong — `_bd_read_auditor_model`
   has seven call sites, and the pi-arm test suite has ~9 structural couplings, not 4.
3. **Every rule has exactly one canonical home.** Other sections cross-reference it;
   they never restate it. Restating is what produced eight cross-section contradictions
   in round 9 alone.

Canonical homes: legacy keys **§2.2** · write authorization **§2.3** · exit codes and
env vars **§2.5** · run outcomes and keyed strings **§2.6**.

## 0. Product scope

| Invariant | Meaning |
|---|---|
| **Agy Read unchanged** | `--cli agy-read`, `.agy_read.model`, ADR 0040's decision untouched. Pi Read coexists; Agy Read stays the default read route. |
| **OpenCode eliminated** | Both surfaces — the CLI *and* the `opencode-go` provider (§0.1). |
| **Pi splits three ways** | read · auditor · worker (§0.2). **Containment caveat, stated here rather than only in §5.6:** the worker roles are brokered, but the goal playbook runs verifiers in the parent shell *before* its scope check, so a worker with in-scope write authority over a test, build file or sourced config obtains **host-level execution**. That is accepted and mitigated (authorized set, undo log, iteration cap), not eliminated — so "brokered" must never be read as "sandboxed". |
| **Codex = review/gate only, one named carve-out** | Every mutating / implementing / handoff / rescue / orchestration surface is replacement scope **except** the `codex exec` block in `skills/imagegen` behind `CODEX_UNCONFINED_OK` (§7). |
| **Fable never implements** | Fable plans and reviews. Implementation runs on Opus or the brokered pi worker. The operator-driven pi TUI handoff (§7) runs on the operator's own pi session and is explicitly **outside** the broker and outside this program's containment claims. |

### 0.1 Two OpenCode surfaces; two separable decisions

**OpenCode the CLI** is the auditor / Mechanism Witness backend. **OpenCode2 is
`opencode-go`, the model *provider*** — how pi and the auditor reach models. The staged
diff preserves it; it is eliminated too. Not "a second arm".

**Decision A — no pi key ships a model default.** Self-supporting (#666: a default
naming a provider the operator may not hold fails at dispatch rather than being
honestly absent). It closes the in-tree-model-id drift class **for the pi keys only** —
the agy read lane still ships an id and is out of scope here.

**Decision B — the pi lane accepts `cursor/*` only.** A product choice, not a
deduction. Supporting fact: *this host* serves exactly `cursor` and `opencode-go`, both
`api_key`. Providers are per-install, so B is policy: *repo source leaves only through a
provider Busdriver has certified a containment posture for.*

**B gates slice 2 (the lane).** Slice 0, slice 1 (provider-agnostic broker core) and
Decision A depend on B not at all. "PASS contingent on B" is a product gate for the
program, not a gate on broker-core.

If the OpenCode2 reading is wrong and B is withdrawn, what falls is **only the
provider-specific sentences**, not whole sections: the `cursor/<id>` grammar (§2.2),
guarantee 7's MCP-group reduction and the non-`cursor` refusal (§2.1/§5.1), and the
provider check before credential projection (§5.3). Everything else in §2.1 — the result
channel, copy-out ordering, the bash-3.2 floor, lazy sourcing, the privileged child, the
version pin, anti-duplication — is provider-independent and survives.

### 0.2 Vocabulary

| Concept | Values |
|---|---|
| Role / manifest id | `pi-read` · `pi-auditor` · `pi-goal` · `pi-rescue` |
| `--cli` enum additions | `pi-read` · `pi-auditor` only |
| Config keys | `pi_read.model` · `pi_auditor.model` · `pi_worker.model` |
| "The worker" | the `pi-goal` + `pi-rescue` pair. **`pi-worker` is not an identifier.** |

## 1. Inventory — anchors and discovery obligations

Anchors are grep targets. `docs/adr/` (except 0034/0040), `CHANGELOG.md` and
`*-archive/` are historical and untouched.

### 1a. OpenCode the CLI — delete

| Anchor | Action |
|---|---|
| `resolve-cli.sh` header threat-model comment | rewrite for the pi broker |
| `get_cli_install_hint` opencode branch | delete |
| **`_bd_read_auditor_model`'s key dispatch — split across slice 0 and slice 4** | **Discovery obligation.** The reader is a *closed* `case` whose third parameter defaults to `auditor`, with seven production call sites, only some relying on that default; one of them is the **live** OpenCode auditor path. **Slice 0 is additive only:** add the `pi_auditor`, `pi_worker` and `auditor_legacy_raw` arms; do **not** rename `auditor` and do **not** change the parameter default. RED: `.pi.model` refuses and `.pi_read.model` resolves, **and `.auditor.model` still resolves** through the existing caller. **Slice 4**, in the commit that deletes OpenCode: rename the arm, retarget the default and every dependent call site (enumerated, not assumed), and enable the `.auditor.model` refusal. Doing the rename in slice 0 would leave the still-live witness unconfigurable for three slices |
| `validate_opencode_home_config` + JSONC validator + auth staging | delete |
| `_bd_oc_auth_rc_classify`, `_bd_rm_sandbox_home`, `_bd_oc_lane_cleanup` | delete |
| `_is_auditor_role`; route-array opencode filter; `resolve_role_cli`'s auditor guard; `_resolve_role_cli_impl` branches; `describe_role_resolution`'s mirror | keep the #436 containment shape; substitute `pi-auditor` **only after §2.7** |
| `_oc_output_is_banner_only` (definition, shim, call site) | delete — the #541 class retires with the lane |
| `execute_review`'s `opencode)` case | replace with `pi-auditor)` → one `bd_pi_run` call |
| removed-CLI enums; `get_cli_version`; the `--json` availability loop | route through §2.7 |
| `scripts/lib/opencode-review-config.json` | delete; Auditor prompt text → `roles/pi-auditor.json` |
| `dispatch.sh` help, `--cli` validator, `.meta` whitelist | enum per §0.2 |
| `resolve_auditor_model` shim in `dispatch.sh` | rename; fails closed |
| the `--cli all` candidate list, its cap, the per-candidate `MODE==auto` arm, and the availability probe | changed **in one edit**: the list is already at its cap of 6 including `opencode`, and the loop probes only `pi-read`, so a partial edit silently drops a candidate |
| `_oc_no_model` and the status ladder | → `_pi_auditor_no_model`; §2.6 |
| **the `Skipped:` emitter** (the `printf` in the `opencode)` arm) | **PORT, do not delete** — `council/SKILL.md` documents the string; the deleted arm emits it |
| the `opencode)` **case arm** | delete the case arm only, in slice 4, **after** slice 2 has extracted the neighbouring `pi-read)` arm |
| the droid-escalation exemption predicate | both pi roles exempt |
| `run-design-review-loop.sh` witness block | call shape and `auditor.json` contract unchanged; label → `(pi-auditor)` |
| `skills/council/SKILL.md` | snippet-only instruction deleted (§2.4); the leading-line reader is an edit target per §2.6 |
| `commands/ultimate-council.md`, `blueprint-review/SKILL.md`, `dispatch-cli/SKILL.md`, `writing-prose/SKILL.md` | prose |
| `README.md` — the line holding two sentences | #251 injunction kept **verbatim**; only the "optional review backend" sentence replaced |
| `.claude/busdriver.json` auditor routes | `["pi-auditor"]` |
| `.upstream-sources.json` OpenCode exclusion records | untouched (§6 criterion 2) |
| **the live `pi-read)` case arm** | **MOVED, not deleted — and extraction is owned by slice 2 alone.** Jail construction, credential projection, wipe/trap, version gate and setup-failure helper become `pi-lane.sh`; its dispatch invocation becomes `bd_pi_run`. Because `test-pi-dispatch-arm.sh` awk-slices this arm and `exit 1`s the whole suite on an empty slice, the extraction and that suite's retarget are **one commit**, in slice 2. Slices 0 and 4 must not touch it: slice 0 would break its own "suite runs to completion" RED, and slice 4 only removes the neighbouring `opencode)` arm |

**Test-suite discovery obligation.** `tests/test-pi-dispatch-arm.sh` is bolted to
`dispatch.sh` structurally, not just by grep: it **awk-slices the pi arm and hard-exits
the whole suite if the slice is empty**, so extraction *terminates* the run rather than
failing assertions. The implementer enumerates every coupling (the arm slice, the
setup-failure count, the batch-list and cap literals, the ADR-0042 ritual scans, the
live-canary gate — ~9 at time of writing) and retargets them in the same commit.
**Slice 0's RED is the suite running to completion**, never a single grep, which cannot
distinguish "retargeted" from "hard-exited".

**`test-pi-dispatch-arm.sh` also hard-requires the constant slice 0 deletes.** Its
section 7 greps `BUSDRIVER_PI_READ_MODEL_DEFAULT` out of the library and fails if absent,
and section 8's assertions compare against that `$DEFAULT` value. Deleting the constant
without repairing **both sections** turns slice 0 red for a reason unrelated to the change
under test. Both are named in slice 0's repair list.

Other tests pinning the string, all repaired, none exempted:
`test-opencode-review-arm.sh` (delete), `test-auditor-model-config.sh`,
`test-agy-prose-lane.sh`, `test-agy-read-lane.sh`, `test-auditor-grace-budget.sh`,
`test-grok-sandbox-arm.sh`, `test-pre-pr-gate.sh`, `test-pr-dual-voice.sh`,
`test-dispatch-skipped-status.sh`, `test-ultimate-tier.sh`.

### 1b. OpenCode2 — the `opencode-go` provider — delete

`BUSDRIVER_PI_READ_MODEL_DEFAULT` **and its use as the double fallback**; the
`.auditor.model` config example; the `zenmux/SKILL.md` mentions; the `opencode-go/*`
test fixtures. The staleness sweep **keeps** its `opencode-go` pattern (a denylist of
ids that must not appear) and loses only the allowlist exemption.

### 1c. Codex non-gate execution — replace

| Anchor | Action |
|---|---|
| `skills/codex-goal-handover/` → `skills/pi-goal-handover/` | ported with **three required edits**, so "verbatim" is not claimed: (i) allow-all scope fallback → deny-all (§2.3); (ii) every `/codex:rescue` reference retargeted, including inside the Hard rules; (iii) Step 7's Python `fnmatch` scope block deleted and replaced by a call to the broker matcher's CLI entry point (§2.3) |
| `scripts/codex/codex-goal-dispatch.sh` + schema → `scripts/pi/goal-controller.sh` + schema | §2.5 |
| `commands/codex-goal.md` → `commands/pi-goal.md` | routing arms retargeted |
| `tests/test-codex-goal-dispatch.sh` → `tests/test-pi-goal-controller.sh` | stub, env names and the cases invalidated by §2.5 rewritten in the same commit |
| `skills/writing-plans/SKILL.md` handoff section | `.claude/pi-goal-<slug>.json.local` / `.md.local`; Outcome 2 → pi TUI `/goal` (§7) |
| `skills/orchestrator/SKILL.md`; `tasks-catalog.md` | rows retargeted |
| **`skills/autonomous-loops/SKILL.md` stage table** | `Implement \| Codex` → `pi-goal`; `Review Fix \| Codex` → `pi-rescue`. Identical in HEAD and origin/main; ships no scripts, but `tasks-catalog.md` routes to it, so it is **prescriptive**. **Exactly these two rows.** The `Sonnet` rows are Claude-pin drift owned by **#747**, untouched here |
| `skills/litmus/SKILL.md` stall-rescue protocol | §7 |
| `scripts/orchestrate-codex-worker.sh` + `dmux-workflows` launcher rows | §7 — retired |
| `dispatch.sh` codex arm's `--mode auto` branch | §7 |
| `.gitignore` codex-goal patterns; `validate-commands.js` `KNOWN_EXTERNAL_COMMANDS` | paths → `scripts/pi/.runs/`; `'goal'` kept, comment updated |

### 1d. ADRs 0034 and 0040 — in-scope amendments

The staged index already rewrites both. **0034** is amended for the `pi-read` rename and
`.pi_read.model`, and its **"not aliased" hard-cut paragraph is RETAINED** — it records
exactly the behaviour §2.2 adopts and the staged code already implements. **0040**'s "pi
stays" note becomes a pointer to 0034; its decision is unchanged. A new ADR records the
broker, Decision B and the removal.

## 2. Architecture

### 2.1 Components and the invocation contract

```
scripts/lib/pi-lane.sh          ONE transport
scripts/pi/bd-broker-core.mjs   ONE resolver + matcher + intersection helper (no pi import; CLI entry point)
scripts/pi/bd-broker.mjs        ONE extension
scripts/pi/roles/*.json         FOUR manifest templates (§2.3)
scripts/pi/goal-controller.sh   ONE controller, TWO profiles (§2.5)
```

```
bd_pi_run <role> <prompt-file> <stdout-file> <stderr-file>
          [--timeout S] [--write-set FILE] [--report FILE] [--model M]
```

**`--write-set` is a lane input and is deliberately NOT the controller's `--scope-file`.**
The controller consumes `--scope-file` (a goal spec) or `--findings-file` (a findings
artifact) and **produces** the already-intersected, already-validated
`{include, exclude, deny}` JSON that the lane materialises into the jail manifest. Reusing
one flag name for both would let an implementer forward the raw spec straight through,
skipping the rescue intersection and reopening the `include: ["**"]` bypass §2.3 exists to
close. `--write-set` is **required** for `pi-goal`/`pi-rescue` and **rejected** for
`pi-read`/`pi-auditor`. Slice 5 asserts the file the lane received equals the recomputed
set, not the raw spec.

`--model` preserves the live precedence an explicit override has over the role's config
key. stdout and stderr are **separate files** (§2.6 explains why).

**Result channel — and it must not be `.meta`.** §2.6 pins the outcomes and two callers
with exact renderings, so `bd_pi_run` must *say* which occurred rather than leave callers
to infer it. It writes `status=<ok|skipped|refused|timeout|crash> reason=<token>` to
**`<stdout-file>.bdmeta`** and exits 0 only for `ok`. The obvious name is taken:
`dispatch_one` already writes its own `${outfile}.meta` as `status|duration|exit_code` and
parses it with `cut -d'|'`, so a lane sidecar at that path would be overwritten by its own
caller before any consumer read it — and would collide on format as well as path.
`dispatch.sh` maps `.bdmeta` to its batch status; `execute_review` maps `skipped` to rc 4
with an empty output file (§2.6). Callers never parse prose.

**Copy-out ordering — report only.** The broker writes the report inside the jail, and
§5.3 wipes the jail on **every** exit path, so the lane copies it to `--report` after its
schema check and before the wipe. A failed copy is `crash`, not `no_report`: the worker
produced a valid report, so the failure is the lane's and must not be attributed to it.
**The undo log is not copied out, because it is never written inside the jail** — see
§2.3, which is its single canonical home.

**Invocation contract and probe obligations.** Slice 2 discharges each row against the
installed tools; a missing capability blocks the slice.

| # | Guarantee | Probe obligation |
|---|---|---|
| 1 | Prompt on **stdin**, never argv | the tree documents the E2BIG hazard |
| 2 | stdout and stderr captured separately **on the dispatch path** | the blueprint-review call site merges them with `2>&1`, and §1a keeps that call shape, so `execute_review`'s consumer sees one stream. The guarantee is therefore scoped: the lane always *produces* two files, and the `.bdmeta` sidecar — not the leading line — is what that caller keys on |
| 3 | `HOME`, `TMPDIR` and the pi agent dir inside the jail | the Cursor SDK builds its session store under `tmpdir()`, which `env -i` would otherwise resolve outside the wipe |
| 4 | pi builtin tools off; only the broker's tools allowed | confirm the allowlist **fails closed** on an unknown name |
| 5 | No extension *discovery*; only broker and Cursor provider loaded from the promoted install (§5.1) | disabling discovery does not restrict explicit loads |
| 6 | The role's system prompt delivered | probe which flag the installed pi exposes and whether it takes text or a path |
| 7 | Cursor native tools reduced to the MCP capability group | provider prerequisite, §5.1 — **entry criterion for slice 2** |
| 8 | The Cursor interactive question tool disabled | it defaults on and is added *after* tool selection |
| 9 | Session persistence off | — |
| 10 | Project-local config, context files, skills, prompt templates, themes off | this, not a neutral directory, is the injection boundary |

**The bash-3.2 interpreter floor lives inside `bd_pi_run`.** The #595 floor exists
because bash 3.2 mis-parses **a heredoc nested inside a command substitution** — the
named construct — and fails open with exit 0. Its current trigger literal covers only
`pi-read` and non-auto `all`, so adding `pi-auditor` would route the auditor past it.
A floor inside `bd_pi_run` covers every caller and role by construction. Two invariants
make it fire, both checked on this host's `/bin/bash` 3.2.57 (the function *definition*
parses cleanly; the mis-parse is deferred to execution):

1. the guard is the **first statement** of `bd_pi_run`, before any command substitution;
2. **`pi-lane.sh` contains no heredoc-in-command-substitution at file scope** — file-scope
   constructs are parsed at *source* time, before any guard runs. Inside functions the
   construct is permitted, which is how `pi-lane.sh` both carries the preflight and
   sources cleanly on 3.2. Keeping the heredoc lexically outside the command
   substitution is the cheaper structural fix and is why `resolve-cli.sh` survives on
   3.2 today with no guard at all.

**`pi-lane.sh` is sourced lazily, never at file scope.** `execute_review` is a *function
inside* `resolve-cli.sh`, which ~16 consumers source including `hooks/gate-scripts/` and
CI. A top-level source would drag the pi lane into every gate path on a 3.2.57 host. The
`pi-auditor` arm sources it **inside the arm**; `dispatch.sh` does the same. Slice 2
asserts no gate-path consumer loads `pi-lane.sh` and that `resolve-cli.sh` still sources
cleanly on 3.2.

**The privileged boundary is a child process, never a re-exec.** `dispatch.sh` re-execs
under `bash -p` only when it is the entry script; `resolve-cli.sh` explicitly does not,
and says so in-tree. So the same `bd_pi_run` would otherwise build a jail and project a
credential under a hardened shell on one path and a shadowable one on the other — the
weaker path being the auditor's.

A re-exec cannot fix that, and specifying one would have been worse than the disease:
`execute_review` is a **function in a sourced library**, so `exec` there replaces
`run-design-review-loop.sh` itself and never returns, while the "or refuse" branch would
make the Mechanism Witness ship **permanently refused** with slice 2 still passing.

So `bd_pi_run` spawns a **privileged child** — `/usr/bin/env -i /bin/bash -p
<promoted-lane-script> _run …` — waits, and maps the child's status sidecar. The parent
never constructs a jail or projects a credential, and exported `BASH_FUNC_*` from the
parent is not inherited. This is the pattern already used in-tree by `grok-preflight.sh`.
`refused` is reserved for a failed child spawn or a child that cannot obtain `-p`, never
for "the parent happened to be a sourced library".

Slice 2 RED must exercise **the real auditor caller**, not only a unit fixture:
`execute_review pi-auditor` invoked from `run-design-review-loop.sh`'s ordinary
(unprivileged) parent still dispatches — skipping only for a missing model — and a planted
`BASH_FUNC_*` in that parent does not reach the child.

**Version pin.** The probed-version constant moves into `pi-lane.sh` as the single
authority, preserving ADR 0042's **bump-then-verify** ordering (verify-then-bump
deadlocks). The ritual-discovery couplings are retargeted per §1a's discovery obligation.

**Anti-duplication is an acceptance criterion** (#618 was two drifted sibling arms plus
tests running an inline copy of production): exactly one pi invocation exists in the
repo, and the four roles differ only by manifest.

### 2.2 Config keys and legacy surfaces — canonical

| Key | Grammar | Default | Unset |
|---|---|---|---|
| `pi_read.model` | `cursor/<id>` | none | `skipped` (§2.6), names the key |
| `pi_auditor.model` | `cursor/<id>` | none | `skipped` → `MECHANISM_ABSENT [no .pi_auditor.model configured]` |
| `pi_worker.model` | `cursor/<id>` | none | exit 127 (§2.5) |

**Legacy surfaces refuse and migrate. They never resolve.** This matches what the staged
tree already implements for `.pi.model` and what ADR 0034 records:

| Legacy | Behaviour |
|---|---|
| `.pi.model` | refuse, naming `.pi_read.model` (already implemented) |
| `--cli pi` | refuse with the same message; `pi` is **not** added to the enum |
| `.auditor.model` | refuse, naming `.pi_auditor.model` |

Refusal — not silent resolution, not silent absence — is the answer to #666: a
configured-but-legacy witness must say *why* it did not run.

**Mechanism.** A refusal needs a *presence* probe for the legacy key, because the reader
returns a value, not a provenance. `.pi.model`'s refusal works only because a
`pi_legacy_raw` presence arm exists; `.auditor.model` needs an equivalent
`auditor_legacy_raw` arm, added in the same unit as §1a's discovery obligation.

**Ordering — the `.auditor.model` refusal lands with slice 4, not slice 0.** The live
OpenCode auditor still resolves that key through the reader's default arm, and OpenCode is
not deleted until slice 4. Refusing it in slice 0 would leave the Mechanism Witness
**unconfigurable for slices 1–3** — a working surface broken for three slices to no
benefit. Slice 0 adds the new arms (harmless while unused); the refusal is enabled in the
same commit that removes the OpenCode auditor and routes the role to `pi-auditor`. The
`.pi.model` and `--cli pi` refusals have no such dependency and land in slice 0.

**`.claude/CLAUDE.md` currently advertises `--cli pi` / `.pi.model` as live guidance.**
That line becomes wrong the moment refusal ships. This program does not edit that file
(§4), so the follow-up PR is a **release blocker** — stated once here, referenced by §9.

### 2.3 Manifests and write authorization — canonical

The role file is a **template** of role-fixed fields (`role`, `tools`, `deny`, `limits`,
`system_prompt`, `exec:{enabled:false}`); the lane **materialises** a per-run manifest
into the jail with `root`, `model`, `report_path` and the authorized write set. The
broker reads only the materialised copy. `report_path` is inside the jail and is not
writable through `bd_write`.

**Exclusion grammar — component-wise, no globs, and case-insensitive.** Per path
component after normalisation: `names` (`.git`, `.ssh`, `node_modules`), `suffixes`
(`.local`), `prefixes` (`.env`). `.git` is matched as a **name**, catching both a
directory and the regular gitdir-pointer *file* a linked worktree has — verified: `.git`
here is an 82-byte regular file, which a `.git/**` glob never matched. `.github/` must
**not** be denied; that is a test case.

**Comparison is case-insensitive and Unicode-normalised (NFC), not exact equality.**
This host's volume is case-insensitive — `ls .GIT` resolves — so an exact-equality deny
list is bypassable by spelling: `.GIT/config` and `.Env.local` would pass a rule written
against `.git` and `.env`. Matching therefore case-folds both sides and normalises
Unicode before comparing. On a case-sensitive volume this is stricter than necessary and
that is the correct direction for a deny list. RED: `.GIT`, `.Git`, `.ENV.local` and an
NFD-composed variant are all denied, while `.github/` still is not.

**Glob grammar for write authorization — closed and defined here**, because it is the
security contract for every worker write: `*` matches within one component, never `/`;
`**` matches zero or more whole components; `?` matches one character within a component;
character classes, brace expansion, extglob and negation are **rejected at validation
time**, not treated as literals; matching is on the normalised repo-relative path,
anchored at the root. One implementation, in `bd-broker-core.mjs`, with a CLI entry
point that the controller's post-hoc diff and the ported playbook's Step 7 both call.

**Precedence:** `deny` ∪ `exclude` always beat `include`.

**Authorization is evaluated on the RESOLVED path, not the requested one.** §5.2 resolves
symlinks and then re-checks only *containment*, so matching include/deny against the
normalised **requested** path leaves an in-root symlink pointing at an excluded in-root
directory — say `src/auth/notes → .git` or `→ src/legacy` — passing both checks: the
request looks authorized and the target is still inside the root. Include, exclude and
deny are therefore applied to the post-resolve path, and slice 1's RED covers **in-root**
symlink targets (into a denied component and into an excluded directory), not only the
out-of-root cases it had.

**Authorization differs by profile, and the rescue set is never caller-supplied:**

| Profile | Input | Who computes the authorized set |
|---|---|---|
| `goal` | `--scope-file` — the goal spec | the **controller**, from the spec it has already validated |
| `rescue` | `--findings-file` — see the producer note below | the **controller**, as (paths named in findings) ∩ (**the staged set**, `git diff --cached --name-only`). A `--scope-file` passed to `rescue` is **rejected** (exit 64) |

The second operand is the **staged** set, not staged-plus-unstaged: litmus reviews
`git diff --cached`, so anything outside it was never reviewed and must not become
writable merely because it happened to be dirty in the worktree.

**The findings artifact does not exist yet, and creating it is part of this program.**
The live stall protocol passes issues to the rescue Agent inside a *prompt*, not a file,
so `--findings-file` currently has no producer, path or schema. §7's litmus change
therefore includes **writing** it: litmus persists its findings to
`.claude/pi-rescue-findings-<run>.json.local` with a minimal schema (a list of
repo-relative paths plus free-text detail), and the controller reads only the path list.
Without that producer the rescue profile is unreachable, not merely unspecified.

Note also that the intersection is **not** typically empty: litmus reviews
`git diff --cached`, so its findings name staged files by construction. The exception is
findings that name clean importer or caller files, which the intersection correctly drops
— that narrow case, not general emptiness, is what the no-dispatch state exists for.

If rescue accepted a caller-supplied scope, a caller passing `include: ["**"]` would
dispatch with repo-wide authority and the containment would exist only in prose. The
second operand is deliberately **not** a committed range: rescue never commits and runs
against a dirty tree, so a committed-range reading would make §8's rescue canary vacuous.

**Authorized-set states — one table per input type**, because the two live inputs have
different shapes and a single `include` key matches neither. The goal spec nests its list
at `scope.include`; the findings artifact has no `include` at all.

| Goal — `--scope-file`, key `scope.include` | Outcome |
|---|---|
| file absent, unreadable, or unparseable | exit 64; no dispatch |
| `scope.include` **omitted or null** | exit 64 — an absent key is not an authorization. (The ported playbook treats this as allow-all today; that is what §1c reverses) |
| `scope.include` present and **empty** | **no dispatch**, reported as such |
| `scope.include` non-empty | dispatch; `deny` ∪ `scope.exclude` still win |

| Rescue — `--findings-file`, key `paths` | Outcome |
|---|---|
| file absent, unreadable, or unparseable | exit 64; no dispatch |
| `paths` omitted or null | exit 64 |
| `paths` present and empty, **or the intersection is empty** | **no dispatch**, reported as such |
| intersection non-empty | dispatch; `deny` still wins |

Slice 5 carries one fixture per row per profile.

| Role | root | tools | writes |
|---|---|---|---|
| `pi-read` | `$PWD` realpath | read/list/search/stat | none — write tools **not registered** |
| `pi-auditor` | repo root, read-confined (§2.4) | same | none — not registered |
| `pi-goal` | repo root | + write/edit/delete/report | per the table above |
| `pi-rescue` | repo root | same | per the table above |

**Write-tool contract:** regular files only; refuse FIFOs, devices, sockets; refuse
multi-link targets; delete refuses directories, no recursion; creation via §5.2's create
path; replacement is same-directory temp + rename; mode preserved on replace; ownership
never changed. `limits` bounds both directions — read bytes, list entries, search hits,
tool calls, **and** total written bytes, files written, and exactly one accepted report.

**Atomicity is per file; the run is made recoverable separately — over a finite set.**
Rename makes each write all-or-nothing, but a `timeout` or `crash` partway through a
multi-file edit leaves earlier writes behind, and the rescue profile never commits.

The snapshot is **write-ahead over paths the broker actually touches**, not over the
authorized set: an authorized glob like `src/auth/**` has no finite pre-image, so
"snapshot every authorized path including absence" is unbuildable. Instead, immediately
before each `bd_write`/`bd_edit`/`bd_delete` the broker records that path's prior content
(or its absence) into an undo log; on a non-success terminal state the controller replays
the log in reverse. The set is finite by construction because it is exactly what was
written.

**The log lives outside the jail — one writer, one path, no copy-out.** Writing it in-jail
would place it inside the directory §5.3 wipes unconditionally, destroying the record of
what to restore precisely on the `crash`/`timeout` paths that need it; and a
copy-out-at-the-end never runs on those paths either. So the **broker** appends framed
records directly to a controller-owned path outside the jail, over a **descriptor
inherited at spawn** — the broker never holds that path and cannot redirect it, and the
jail wipe cannot reach it. An abrupt death leaves a complete, replayable log rather than
none. This is the log's only definition; §2.1 defers to it.

**Scope of the restore.** It covers the **rescue** profile entirely (which never commits),
and the **goal** profile only up to its commit step. The ported controller commits and
*then* runs its ignored-write and out-of-scope checks, so a post-commit failure cannot be
undone by restoring file content — HEAD and the index have already moved. For those paths
the recovery is the existing exit codes plus git history (the commit is revertible), and
the spec does not pretend otherwise. Canary 6 therefore kills a **rescue** run mid-write.

**No `bd_exec`.** A worker with in-scope write authority over a test, build file or
sourced config already obtains parent-shell execution when the controller runs verifiers
(§5.6); `bd_exec`'s absence avoids a *second*, direct channel rather than closing the
first. **Upgrade trigger:** a rescue case not expressible as edits plus parent-run
verifiers.

### 2.4 The auditor is read-confined, not snippet-only

Opencode's neutral temp dir + `external_directory: deny` is why the council skill orders
the caller to paste every snippet. **That is a property of the OpenCode harness, not a
requirement** — ADR 0027 decides a rename, a budget and a tier, and never contemplates
repo access. It is also harmful: **#662** (the extractor exhausts its fail-closed
unbalanced-scan budget sweeping an echoed snippet-heavy prompt) reproduced on this
document in **every** review round, and **#476** is the same constraint from the other
side. `pi-auditor` gets a read-confined repo root — stronger than directory scoping,
which never stopped an absolute path — with the injection boundary held by guarantee 10.
The cure is a **hypothesis** until the §8 canary confirms it; #476/#662 close only then.

### 2.5 The controller — profiles, exit codes, env vars (canonical)

**Shared trust core (kept verbatim):** path-smuggling rejection (NUL/TAB/newline,
detected before bash strips them), absolute/`..`/pathspec-magic/glob rejection, directory
rejection, content-hash out-of-scope detection.

**Profile discriminator:** `--profile goal|rescue`, **required, no default**, validated
before any tree inspection. It does not exist today, so it is a new required argument, not
a port. Absent or invalid → exit 64 before the dirty check runs.

| | `goal` | `rescue` |
|---|---|---|
| Tree at entry | must be clean → exit 4 | **may be dirty**; no gate |
| Commit / SHA / injected fields | yes, dispatcher-side | **absent by construction** |
| Verifier loop | yes, parent-run | no |
| Authorized set | §2.3 | §2.3 |

**Other changes:** result production becomes `bd_pi_run --report` plus the existing
re-validation; the codex availability probe → §2.7; `.codex.log` → `.pi.log`; `--effort`
is **dropped** (pi has no equivalent) and `commands/pi-goal.md` says so.

**The staging set is intersected with the authorized set before anything is committed.**
The ported controller stages from the worker-declared `files_changed` in the result JSON,
filtered only for filename shape, directory-ness and pre-existing dirt — it is **never**
intersected with the authorized write set. That declaration is model-produced text, so as
inherited it is a path by which a worker names a file outside its authorization and the
controller stages and commits it, entirely bypassing the broker's write gate (the broker
guards *writes*; this guards *staging*). The controller therefore intersects
`files_changed` with the authorized set (§2.3) before staging, and any declared path
outside it is dropped and reported as **exit 3** (out-of-scope), not silently ignored.
Slice 5 RED: a worker that declares an out-of-authorization path has it refused at
staging even when the file exists and is clean.

**Environment variables — the complete disposition.** The controller carries exactly
three `BUSDRIVER_CODEX_*` gates today:

| Existing | Disposition |
|---|---|
| `…_ALLOW_DIRTY_TREE` | **deleted entirely.** Rescue no longer needs it, and the goal profile's clean-tree precondition becomes unconditional. It is env-injectable, against this repo's own ADR 0016/#325 precedent, and it committed afterwards anyway. The ported test case that asserts this bypass reaching exit 0 is **rewritten in the same commit** to assert the new contract |
| `…_ALLOW_UNCLAIMED` | **deleted, not renamed.** It downgrades an out-of-scope modification (exit 3) to exit 0 — a containment bypass by the same ADR 0016 argument. Its ported test case is rewritten alongside |
| `…_FAIL_ON_IGNORED` | **renamed** to `BUSDRIVER_PI_FAIL_ON_IGNORED`. It only ever makes the controller *stricter*, so it is not a bypass |

There is no blanket rename; each variable is dispositioned individually, because two of
the three are bypasses and one is not.

**Closed exit-code table.** Meanings of existing codes are byte-stable so ported
assertions survive:

| Code | Meaning |
|---|---|
| 0 | success |
| 1 | worker exited non-zero; also `refused`, `timeout`, `crash` (§2.6) |
| 2 | result file missing **or** schema-invalid — `no_report` stays 2 |
| 3 | out-of-scope modification (no longer downgradable) |
| 4 | dirty tree at entry — **goal profile only** |
| 5 | staging/commit failure — goal only |
| 6 | gitignored writes (opt-in) — goal only |
| 7 | `dup_report` — the only new code |
| 64 | bad usage / invalid argument only — including a missing `--profile`, a `--scope-file` on `rescue`, and every §2.3 no-dispatch state |
| 66 | required schema file missing |
| 127 | required CLI missing; also configuration-absence (`skipped`) |

The existing test cases prove the goal profile once their stub, env names and the cases
invalidated above move in the same commit.

**Untested-mechanism disclosure.** Those tests pin the controller and the contract and
nothing else — the verifier loop, iteration cap, scope-enforcement step and `.git/hooks`
bail are prose executed by Claude, untested today. The port does not worsen them and this
program does not fix them (§9).

### 2.6 Run outcomes and keyed strings — canonical

| State | Meaning | `--cli all` | explicit `--cli` | `execute_review` | Council render |
|---|---|---|---|---|---|
| `ok` | verdict produced | counted | success | 0 | findings |
| `skipped` | absent by configuration or eligibility — no model key, role not routed, pi absent, version-pin mismatch, install manifest absent | **drops out** (#594) | fails | 4 + empty output | `MECHANISM_ABSENT [...]` |
| `refused` | tamper/integrity — install-path refusal, hash mismatch, credential-projection failure | **fails the batch** | fails | non-zero | `MECHANISM_FAILED [refused: reason]` |
| `timeout` / `crash` | budget exhausted, or broker/pi died | **fails the batch** | fails | non-zero | `MECHANISM_FAILED [...]` |

`timeout` and `crash` fail the batch because the live dispatcher already sets its
any-failed flag on both; only `skipped` drops out. A projection failure that leaves the
jail behind keeps the live, more conservative classification — a possibly-leaked
credential must never read as "did not run".

**Keyed strings.** The `Skipped:` **prefix** on the leading line of the stdout file must
stay byte-identical; its emitter is ported from the deleted arm (§1a), and its assertion
moves into `test-pi-auditor-role.sh` **before** the deleting slice. The key name in that
line's tail and the two `MECHANISM_ABSENT` renderings change by design.

**Why stdout and stderr are separate, and the forgery boundary.** The council treats the
leading line of the stdout file as its only durable signal, while the model's own output
lands in that same file — so a model emitting `Skipped: …` first is indistinguishable
from a genuine skip. The lane closes this **for the pi lane**: it writes the skip line
only on the no-dispatch path, and on the dispatch path guarantees the leading line is
lane-owned, with model output beneath a lane-written marker. Because the council and
`execute_review` read that line, both are **named edit targets** for the marker
convention (§1a). **Scope of the claim:** the identical forgeable shape exists in the
grok arm, which this program does not touch — closing that is a named follow-up (§9), not
something claimed here. §8 canary: a model instructed to emit `Skipped: …` first is not
recorded as skipped.

### 2.7 Role availability — a role name is not a binary

The availability predicate is `command -v <name>` with one special case (grok).
`pi-read`/`pi-auditor` are **role names**; nothing of that name is on PATH. The existing
pi probe lives in `dispatch.sh`, is invisible to `resolve-cli.sh`, and is deliberately
path-only — preserved, not "fixed". A shared `_bd_role_available` moves into
`resolve-cli.sh` mirroring the grok delegation, routed through every availability site
(discovery obligation). It must be a plain path probe with **no heredoc-in-command-
substitution**, since `resolve-cli.sh` has no interpreter guard and is not covered by
`bd_pi_run`'s floor. RED: auditor route resolution succeeds on a host with `pi` installed
and no `pi-auditor` binary.

## 3. Slices

| # | Slice | RED | GREEN |
|---|---|---|---|
| 0 | Land the staged rename coherently | **the full shell suite runs to completion** (not a grep) | staged rename + delete the default constant and its fallback + §1a's reader unit (arm, parameter default, all dependent call sites, the three new presence/key arms) + the `.pi.model` / `--cli pi` refusals. **The `.auditor.model` refusal does NOT land here** — it lands in slice 4 (§2.2 ordering). ADR 0034's paragraph is retained. **No extraction of the `pi-read)` arm happens in this slice.** Re-verify origin/main and the zero-overlap check, then merge |
| 1 | Broker core (**no entry criterion — provider-agnostic**) | `test-bd-broker-core.sh`: read path · create path · outside-root · symlink escape · leaf swap via the named dev/ino comparison · `.git` file and dir denied, `.github/` allowed · nested `.env.local` denied · the closed glob grammar incl. rejected constructs · precedence · all four §2.3 authorized-set states · write-contract table · snapshot/restore on kill · report exactly-once · CLI entry point and in-process call agree | resolver + matcher + intersection helper + tools |
| 2 | Lane (**entry: §5.1 provider prerequisite released and pinned**) | `test-pi-lane.sh`: every §2.1 guarantee probed, missing capability fails the slice · one pi invocation in the repo · lazy sourcing, no gate-path consumer loads `pi-lane.sh` · `resolve-cli.sh` and `pi-lane.sh` both source cleanly on 3.2 · 3.2 refuses non-zero for both roles from both call sites · install resolved from the promoted path or refused · shadow broker never executed · unknown tool name yields zero tools · prompt on stdin · stdout/stderr separate · grandchild reaped on this host's actual timeout branch · TMPDIR store gone after wipe · non-`cursor` provider refused · OAuth refused · manifest absent → `skipped`; hash mismatch → `refused` fails a batch | lane |
| 3 | §2.7 predicate, then the two read roles | §2.7 RED, then `test-pi-auditor-role.sh` **against fixture configs, not the live repo config** (which still routes both auditors to `["opencode"]` until slice 4, and the `opencode` binary is genuinely on PATH here): route resolution for `pi-auditor` · non-auditor rejection · unset key → `Skipped:` prefix + `skipped` on the dispatch path, and `.bdmeta` `status=skipped` on the `execute_review` path · invocation carries the role system prompt. **No `.auditor.model` refusal assertion here** — that behaviour is enabled in slice 4 (§2.2) | §2.7 + both roles |
| 4 | Remove OpenCode + OpenCode2 | §6's sweep; flip the transitional assertions; the `--cli all` substitution in one edit | delete per §1a/§1b, extract-then-delete ordering |
| 5 | Controller: both profiles | ported cases (with the §2.5-invalidated ones rewritten) · `--profile` required → 64 · rescue: dirty tree accepted with no override, no commit, no SHA, `--scope-file` rejected · rescue set recomputed from `--findings-file`, `include:["**"]` unreachable · snapshot restored after a kill · `no_report`=2, `dup_report`=7 · Step 7 calls the broker matcher | §2.5 |
| 6 | Codex non-gate replacement | `validate-commands.js` green · zero live Codex invocation paths under §6's Codex sweep and exclusion list · explicit `--cli codex --mode auto` rejected **and** codex excluded from `--cli all --mode auto` discovery · the two `autonomous-loops` rows and only those two | §1c, §7 |
| 7 | Live certification of the promoted artifact | §8 canaries, live mode — FAIL, never skip | — |

## 4. Git strategy

1. This document passes blueprint-review before anything is committed.
2. Slice 0, then merge origin/main — no rebase, no force, no history rewriting.
   **"Zero-overlap check" means:** `git diff --cached --name-only` and
   `git diff --name-only HEAD origin/main` share no path (`comm -12` on the sorted lists is
   empty). It was empty against `7e2fee30`; re-run it at slice 0, because the remote moves.
   A hit does not block the merge — it means the overlapping file needs a real merge review
   rather than the assumed clean fast-forward.
3. Slices 1–7 are separate commits. No `git stash` (shared stack) — WIP commits.
4. `.claude/CLAUDE.md` is not edited here; its correction is the release-blocking
   follow-up named in §2.2 and §9.
5. One PR; rollback = `git revert` of the squash-merge commit.

## 5. Trust boundaries

### 5.1 Cursor — the transport and the external prerequisite

**Layer 1 — native tools reduced to the MCP capability group.** Not "no tools": an empty
list leaves the model text-only, and omitting the MCP group disables MCP entirely,
killing the broker bridge. Reducing to that group removes native read, edit, shell, task,
glob, grep and ls. The 2026-08-23 eval showed this is the only lever that removes them,
and that a workspace-read-only `pi-seatbelt-sandbox` policy still permitted a native
write — Cursor native tools run in the Cursor agent process and bypass pi's guards, so
seatbelt is not in this design. *(SDK semantics are documented-not-probed; slice 2
verifies them.)*

**Layer 2 — the bridge carries only the broker's tools**, because pi-cursor-sdk snapshots
pi's active tool set and guarantees 4, 8 and 10 reduce it to the broker's. Asserted as
**set equality** per role (§8).

**Layer 3 — the broker confines paths** (§5.2). Layers 1–2 are capability boundaries;
only Layer 3 is a path boundary — under a tool-type allowlist the eval still read siblings
by absolute path.

**Dependency ownership.** `pi-cursor-sdk` is third-party and the installed version
registers **no tools-allowlist flag at all**; the evaluation clone's uncommitted diff adds
only a narrower preset. Busdriver does not vendor, fork, or depend on an unreleased diff;
it fails closed on a capability probe before any credential is projected. The prerequisite
is a brokered (MCP-group-only) preset upstreamed and **released**, owned by this repo's
maintainer as an upstream PR. **Entry criterion for slice 2.**

**Promotion and its anchor.** A digest check over files inside the audited checkout is
circular, so: package the candidate commit **out of tree**, install it to a named path
outside every manifest root, and record `{install_path, commit_id, surface_hash}` in an
operator-owned file outside the repo. **`surface_hash` is defined as** the SHA-256 of a
deterministic manifest listing every shipped broker/lane/role file path and its content
hash, sorted by path — not a hash of a tarball, which would vary by packaging.

The manifest is read by a **small dedicated reader**, not the model-key reader: that one
hard-codes a single config path and returns a single string, so it cannot express a
three-field record. The new reader carries the same trust rules (USER-owned path outside
the repo, no env override, password-DB `$HOME`).

**The entry point must be the promoted copy.** `pi-lane.sh` performs the verification and
also lives in the repo, so a checkout that edited it could skip its own check. The
operator invokes the **promoted install's** lane; in-repo callers resolve the lane from
the install manifest and refuse if it resolves inside the target root. Absent manifest →
`skipped` (never promoted is configuration absence, #594); mismatch → `refused`. What this
buys is **detection of drift after promotion**, not proof the promoted commit was benign —
that is what review and the §8 canaries are for.

**Residuals:** the bridge endpoint has no bearer token (loopback + unguessable path), so
an untrusted *local* process is out of model; the Cursor agent holds ambient network to
its backend; the SDK runs in-process, so a defect in it is a defect inside the boundary.

### 5.2 Filesystem — two paths, one honest residual

**Read path:** lexical reject (`..`, NUL, absolute-outside-root) → resolve → re-check
containment → open without following the final symlink → compare the descriptor's
`(dev, ino)` against the values recorded at resolve time. **Create path:** resolve the
**parent** → verify parent containment → create exclusively without following the final
symlink.

Inode metadata carries no pathname and no ancestry, so it cannot establish subtree
membership: the dev/ino comparison proves **leaf-replacement detection**, the no-follow
open proves **leaf-symlink refusal**, and containment is decided at resolve time. An
**intermediate-directory redirect** by a concurrent local process is not closed — a §5.6
residual whose upgrade path is a component-wise `openat` walk in a small native helper.
Proportionate, because the adversary in model is a **remote model choosing paths**, not a
local process racing the filesystem.

### 5.3 Credentials

Private HOME jail: password-DB-derived real home, `env -i`, only the resolved provider's
credential projected. **`api_key` only** — OAuth/refreshable refused, because in-jail
refresh would be discarded and could invalidate the operator's real token; this host's
`cursor` entry is `api_key`-typed. The ambient provider key never reaches the child.
Projection happens **after** the install verification and the provider check, so a refused
run never writes a credential. The jail — including its tmp and broker copies — is wiped
on every exit path; a projection failure that leaves it behind is classified per §2.6 with
the leaked-credential caveat recorded. The wipe is asserted by a deterministic teardown
test, not only by live canaries.

### 5.4 Subprocess

`setsid` does not exist on this host (verified absent from PATH and the three standard
prefixes; util-linux, not stock macOS), so the session leader is a portable helper —
`perl` is present and can call `setsid(2)` before exec. Teardown must signal the whole
**process group**, and pi-cursor-sdk's own tree-kill is Windows-only, so this is the only
reaper. Both `timeout` and `gtimeout` are present here, so the timeout wrapper's perl
fallback never executes: slice 2's RED must exercise **the branch this host actually
takes**.

### 5.5 Network, session, artifacts

Network is not confined and not claimed to be; no broker tool performs network I/O, and
the operator's other installed pi packages never load. Session persistence is off and the
agent dir and tmp live inside the deleted jail. Everything a lane returns is untrusted
text: reports are schema-validated in the broker **and** re-validated by the controller,
verifier output is fenced before being fed back, and **model-produced text never becomes
write authority *directly*** — which is why §2.3 has the controller recompute the rescue
set. It can still obtain parent execution *indirectly* (§5.6).

### 5.6 Residuals

Not an OS sandbox. Out of model: a compromised host; a compromised pi, pi-cursor-sdk or
Cursor SDK; another local process on the same machine — which owns both the untokened
loopback bridge and the §5.2 intermediate-directory redirect.

In model and **accepted: worker-written code executed by the parent.** The playbook runs
verifiers *before* its scope check, so the post-hoc diff bounds **compounding across
iterations, not execution within one**. A worker that edits an in-scope test, build file
or sourced config obtains parent-shell execution on that iteration. The mitigations are
the authorized set (§2.3), the snapshot/restore, and the iteration cap — not the diff.
Closing it properly means running verifiers before applying worker output, or in a
container; both are §9.

**What tests can prove:** the broker's unit tests exercise the resolver as a module — they
never start pi, never cross the MCP bridge — so confinement of the deployed stack is
certified only by the §8 canaries against the promoted artifact. That is how the
2026-08-23 eval found the native-tool bypass no unit test surfaced.

## 6. Removal criteria; supersession

An **executable-surface sweep** plus a mechanically checked exclusion list — a zero-hit
repo-wide grep is incompatible with flipping rather than deleting the transitional
assertions, and would drive an implementer to mutilate the README's #251 injunction.

1. No live **executable** OpenCode surface: no `--cli opencode`, no `opencode` route
   value, no `opencode-go`/`opencode-go-lb` provider id in a default or example, no
   `opencode)` case label, no `~/.opencode` path.
2. Exclusion list, checked mechanically: the README #251 sentence; the flipped rejection
   assertions; the staleness **denylist** pattern; the `.upstream-sources.json` OpenCode
   exclusion records; `docs/adr/`; `CHANGELOG.md`; this plan.
3. `opencode-review-config.json` and `test-opencode-review-arm.sh` deleted.
4. Both former arms gone; both callers reach pi through one `bd_pi_run`.
5. The `Skipped:` prefix still emitted by the ported emitter, with its assertion live.

**The Codex sweep is the same shape and uses the same exclusion list.** Slice 6's
criterion is *not* a raw token grep for `codex:rescue`, which hits `CHANGELOG.md`,
`docs/adr/`, this plan, and the retained litmus docs that legitimately reference the
**external** `/codex:rescue` plugin as a complementary command. Count **live invocation
paths only**.

**#618** and **#730** are superseded on terms: every replacement test invokes production
functions — no inline copies anywhere in `tests/` — and no test consumes a producer through
process substitution without checking its exit status, with every generated-case loop
asserting a minimum case count. Slice-4 acceptance criteria. **#476** and **#662** are
superseded by §2.4, closing only after the §8 canary confirms the mechanism.

## 7. Codex retained vs replaced

**Retained — review or gate:** litmus pre-commit and pre-PR gates (Codex xhigh lead +
Opus backstop); pr-grind lead-reviewer handling, acks, retrigger and nudge scripts;
blueprint `reviewer_2`; council `critic`; the read-only codex execute path; `--cli codex`
**read-only**; `santa-loop` Reviewer B; `codex:setup` (external plugin, zero in-tree refs).

**Replaced:**

| Surface | Verdict |
|---|---|
| `codex-goal-handover` + `scripts/codex/*` + `/busdriver:codex-goal` + its test | → `pi-goal-handover`, controller goal profile, `/busdriver:pi-goal` |
| Codex TUI `/goal` (writing-plans Outcome 2) | → pi TUI `/goal`. Operator-driven, runs with the operator's own pi tools **outside the broker**, as the Codex TUI does today — parity, never described as brokered. Slice 6 records the specific extension and version |
| `skills/autonomous-loops` stage table | `Implement \| Codex` → `pi-goal`; `Review Fix \| Codex` → `pi-rescue`. Only these two rows (#747 owns the Sonnet rows) |
| litmus stall rescue | Uses the **rescue profile** (§2.5) with the authorized set computed per §2.3 — the live protocol dispatches an external Agent against a dirty tree and applies the result without committing, which the goal profile cannot serve. No new Agent is created |
| `scripts/orchestrate-codex-worker.sh` + `dmux-workflows` rows | **Retired, not renamed** — free-form task file, no goal spec, no scope, no verifier contract, no clean-tree precondition, so it cannot derive an authorized set. Script removed, its `.upstream-sources.json` entry updated, dmux rows point at the controller with a required spec file. Unscoped mutation is the pi TUI, explicitly outside the broker |
| `--cli codex --mode auto` | **Restricted** to read-only, treated as grok and the pi roles already are: codex excluded from `--cli all --mode auto` discovery, and an explicit `--cli codex --mode auto` rejected with a pointer to `pi-goal`. Both asserted, so the write branch cannot return by omission |

**Replacement scope, externally blocked:** `commands/multi-*` drive Codex implementation
through an external `ccg-workflow` wrapper Busdriver does not own, with no pi backend.
This program **refuses the Codex backend** there with a pointer to `pi-goal`. For commands
offering a choice, other backends stay intact; **`commands/multi-backend.md` hard-codes
Codex as its only backend**, so refusing it disables the command — it is therefore marked
**unsupported pending the `ccg-workflow` replacement** rather than left silently broken.
A tracking issue records the full replacement.

**The one carve-out:** the `codex exec` block in `skills/imagegen` and its
`CODEX_UNCONFINED_OK` guard test — **asset generation, not code implementation**, and pi
exposes no image tool on either provider. **Revisit trigger:** a pi-reachable image tool.
`skills/image-to-code` is **not** in the carve-out (no guard, no in-tree `codex exec`); it
is a Claude-side playbook that may call imagegen. The codex install-target and
session-adapter files provision a harness and never run Codex to mutate this repo.

## 8. Canaries and independent security review

**Focused:** the slice's own test. **Full:** the shell suite, `npm test`, the Python
suite, `validate-commands.js`, ShellCheck on new `.sh`.

**Live canaries** — live mode; FAIL, never skip; run against the **promoted artifact**.
Evidence is required per denial class, because one global rule is unsatisfiable for a tool
that is deliberately never registered:

| Denial class | Required evidence |
|---|---|
| **Broker refusal** (tool registered, path rejected) | the broker tool call in the event stream **and** the exact reason string **and** no side effect |
| **Unregistered tool** | the protocol's unknown-tool rejection **and** absence of native read/edit/shell/write events **and** no side effect. A model that merely declines is **not** a pass: the run is retried with a prompt forcing an explicit attempt, and a run with no attempt fails the canary |

1. `pi-read`: attempt a write → unregistered-tool class; read a sibling outside the root
   → broker-refusal class. *(This exact probe **succeeded** against the Cursor reviewer
   preset on 2026-08-23.)*
2. `pi-read`: in-root symlink pointing out → symlink escape.
3. `pi-auditor`: a **code-heavy** design document parses and returns findings — the #662
   confirmation gate; a path outside the root → refused.
4. `pi-goal`: in-scope **create** committed; out-of-scope write refused with a clean
   controller scope; the worktree `.git` **file** refused.
5. `pi-rescue`: dirty tree accepted, edits confined to the recomputed set, **no commit and
   no SHA**; empty set → no dispatch; a caller-supplied `--scope-file` rejected.
6. Kill mid-run after partial writes → snapshot restored, tree byte-identical.
7. Transport: bridged tool names **set-equal** to the role's tools; no native
   read/edit/shell/task/question events.
8. Negative control: capability probe forced to fail → `refused`, no credential projected,
   no jail left, batch **fails**; version-pin mismatch and absent install manifest →
   `skipped`, batch **succeeds**.
9. Teardown (deterministic stub): forced timeout → process group reaped on this host's
   actual timeout branch; jail, tmp and broker copies gone.
10. Signal forgery: a model emitting `Skipped: …` first is **not** recorded as skipped.

**Independent security review** before `gh pr create` → merge: normal litmus PR mode; a
`busdriver:security-reviewer` pass scoped **by name to the integration points** —
`scripts/pi/`, `scripts/lib/pi-lane.sh`, the role-resolution and availability changes in
`resolve-cli.sh`, the `--cli all` substitution and enum changes in `dispatch.sh`, and the
controller's profile discriminator; the canary transcript and the promoted commit id in
the PR body; pr-grind to clean.

**Certification is bound to what ships:** canaries are re-run against the **final PR head
after the last pr-grind push**, and the PR body records that SHA next to the promoted
commit id.

## 9. Delivery, rollback, follow-ups

Normal pipeline: per-slice commit-time litmus, `gh pr create` → PR litmus, pr-grind,
squash-merge behind the required checks. No gate skips; `--admin` only to clear a `BEHIND`
head. Rollback: `git revert` the squash commit; operator config is additive;
#618/#730/#476/#662 reopen if reverted.

**Release-blocking follow-up:** the `.claude/CLAUDE.md` correction (§2.2) — its current
text advertises surfaces that refuse once this ships.

Other follow-ups, outside this program: tests for the controller's untested prose layer
(§2.5); **verifier-before-apply or containerised verifiers** to close §5.6's execution
channel; the forgeable `Skipped:` shape in the grok arm (§2.6); the `multi-*` /
`ccg-workflow` replacement (§7); `bd_exec` if a rescue case demands it (§2.3); the §5.2
intermediate-directory redirect if the threat model gains a hostile local process;
**#747** (Claude model-route drift), which owns the Sonnet rows this program does not
touch.

## Handoff — Opus implementation

1. Implementation starts only after blueprint-review stamps PASS with **FULL 3/3
   coverage**. `agy` is geo-blocked on this host
   (`FAILED_PRECONDITION (400): User location is not supported for the API use`), so
   `blueprint-review.reviewer_1` is routed to `droid` by operator config. **Coverage
   caveat to carry:** droid's underlying model is Grok 4.6, the same family as
   reviewer_3, so the three lenses are effectively Grok ×2 + Codex ×1 with an Opus
   arbiter. Codex is the only independent reviewer lens and was the sole finder of the
   §2.3 atomicity gap.
2. Confirm Decision B — entry criterion for slice 2. Decision A, slice 0 and slice 1
   proceed regardless.
3. Land the upstream brokered-preset release — entry criterion for slice 2.
4. Slices in §3 order, RED first, one commit each, full suite between.
5. `busdriver:security-reviewer` on the broker before `gh pr create`.
