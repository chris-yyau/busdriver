# UltraOracle over Claude-in-Chrome — withdraw the oracle CLI

- **Date:** 2026-11-01, revised 2026-11-03
- **Status:** Approved design, revision 13 (revision 12 plus the round-11 fixes: a browser-cutoff termination publishes `timeout` 124, the post-`SAVED` audit, the process-group invariant, the bash 3.2 floor and the disconnect fixture). On the operator's decision (2026-11-03), v1 runs exactly one child per consult, with no setup retry and no recovery child. The parent runs `open -a "Google Chrome"` before every launch, any failure ends the run with a hint, and the operator re-runs the consult. That removes the cross-child phase rules, `UORA_SEQ`, the post-exit process-group wait and the recovery profile, which carried the round-10 high. Revision 12 also moves the run dir to `$HOME/.cache`, prints hints on `ok`, gives the phase table default rows, records `find`'s match count and a `navigated` flag, and corrects the litmus citation. Revision 11 fixed the guard's concurrency (log writes under the lock in state order, a PostToolUse that waits for the lock) and the recorder's exact token matches. Before that came revision 10. Revision 9 rewrote it from the 2026-11-02 spike results (E15–E21), which settled spikes a, b, c, d, f and g, and §3 lists the three residual checks that remain. Revision 10 makes the audit independent of stream order with a guard decision log joined by `tool_use_id`. It also adds a closed set of deny reasons, with retryable `busy` and `not-yet`, and a reason-precedence rule. A failed residual check sends the design back to review. Brainstorming 2026-11-01; grill declined. A Step 5.6 ChatGPT Pro critique ran over this transport's own prototype, and the operator approved revisions A–E plus conversation archiving. Revisions 3 and 4 fold in blueprint-review iterations 1 (`c8be0cfb`) and 2 (`b8810101`).
- **ADR:** 0061, written with the plan. It supersedes ADR 0020 and ADR 0029 and amends ADR 0007. ADR 0027 and ADR 0030 get amendment notes for the timeout formula (§9).
- **Recovery anchor:** `e69c79f2` (origin/main before this work).
- **Release:** BREAKING — major 4.0.0.

## Goal

Every busdriver surface that consults ChatGPT Pro works again on the operator's Mac:
- `/ultraoracle` and its retrieval loop
- the ultra-council and ultimate-council expert witness
- brainstorming Step 5.6
- the writing-plans advisory
- the blueprint-review advisory

The consult drives the operator's signed-in Chrome through the Claude-in-Chrome extension. Busdriver keeps no dependency on the `oracle` CLI in any form: no code path, config key, preflight, test or doc requires it.

## Problem

The `oracle` browser engine needs a Chrome started with a remote-debugging port. Since about 2026-10-30, every fresh chatgpt.com navigation in that Chrome stops on Cloudflare's "Just a moment…" check, which never clears. Re-sign-in, a fresh profile and closing tabs all changed nothing. Upstream oracle #542 is still open with no fix, so every UltraOracle consult fails. ADR 0020's attach mode was the earlier escape from this same wall, and it no longer works. The same chatgpt.com loads unchallenged in the operator's normal Chrome.

About half of the 1,515-line adapter `scripts/lib/ultra-oracle.sh` works around oracle's own defects. That covers #458 hung-completion detection with its harvest and salvage, the #490 submit watchdog, `oracle status` tab probing, the attach preflight, and the remoteHost, cookie and profile session sources.

## Evidence (spikes, 2026-11-01)

| # | Finding |
|---|---|
| E1 | `claude -p --chrome --model sonnet`, launched headless from a shell, drove the operator's Chrome to chatgpt.com with "Pro" selected and returned a reply in 58 s. There was no Cloudflare challenge. |
| E2 | `file_upload` of a 101,016-byte prompt file worked, and Pro answered with the code word on its last line. Two files uploaded in one call also worked. |
| E3 | `file_upload` refuses files the session may not Read: "only files this session is allowed to read can be uploaded". A blanket Read deny therefore breaks upload. A path-scoped `Read(//abs/path)` allow fixes it. |
| E4 | A `javascript_tool` call is cut off at 45 s ("CDP … timed out after 45000ms"). |
| E5 | `javascript_tool` results are truncated to about 1,000 characters (`[TRUNCATED]`). A result whose text looks like JSON or key/value data comes back as `[BLOCKED: Cookie/query string data]`. Getting the answer through a JS return value is therefore not viable. |
| E6 | ChatGPT's DOM no longer carries `data-testid` or `data-message-author-role` hooks. An in-page `fetch('/backend-api/conversation/<id>')`, using the bearer token from `/api/auth/session`, returns the message tree. |
| E7 | The tree walked from `current_node` through `parent` reads: final `assistant` / `text` / `end_turn: true` / `model_slug: gpt-6-pro` ← `reasoning_recap` ← `thoughts` ← `execution_output` ← `code` ← an intermediate `assistant` `text` with `end_turn` unset ← `thoughts` ← the `user` message, whose `metadata.attachments[].name` held the uploaded file name. The intermediate `text` message shows why `end_turn` is required. The prototype's completion check `message.status === 'finished_successfully' && message.end_turn === true` returned DONE on that final node. |
| E8 | An in-page Blob download (`a.download = 'uora-spike01.json'`) landed in `~/Downloads` with no prompt, and its SHA-256 matched the hash the page computed. Chrome's download prompt is off on the operator's profiles. |
| E9 | `PATCH /backend-api/conversation/<id> {"is_archived": true}` returned 200. A later GET returned 200 with `is_archived: true`, so archived conversations stay readable. |
| E10 | Closing the child's last tab closed its window. With no other window open, the extension disconnected, and every later run reported `extension-not-connected` until Chrome had a window again. |
| E11 | The prototype child (sonnet) ran the single-line J-id, J-poll and J-get snippets from its instruction text and got the expected results on every call. That shows they can be reproduced well enough to work. Whether the reproduction is byte-identical was not measured. |
| E12 | On a fresh `https://chatgpt.com/` in the operator's Chrome, the composer's model control is `button[aria-label="Select ChatGPT model"]`, with the text "Thinking effort / Pro". Pro is the operator's sticky selection, and a fixed snippet can read it with no model-side page read. The composer is a `.ProseMirror` element that has focus on load, and there are `input[type=file]` elements. A `?model=` URL parameter was consumed (the URL was rewritten to `/`), but whether it has any effect was not shown, and nothing relies on it. |
| E13 | On the same fresh home page (2026-11-02), `find` with the query `file input element for attaching files to the message composer` returned exactly four refs, each one line of the form `- ref_<n>: button ""<label>"" (file) - <one-sentence description>`. The labels were `Attach files`, `Attach photos or videos`, `Attach photos` and `Take a photo`. Only aria labels and find's own descriptions came back, with no sidebar or conversation text. The `ref` that `file_upload` requires (its schema marks `paths`, `ref` and `tabId` required, and says the ref comes from `read_page` or `find`) is therefore obtainable from one pinned query. |
| E14 | On that page, a single `javascript_tool` call focused `.ProseMirror` (`document.activeElement` matched), inserted text with `document.execCommand('insertText', …)` (it returned `true` and the composer's `textContent` equalled the text), and found an enabled `button[aria-label="Send"]`. It then deleted the text again, and nothing was sent. Submitting through that button from a snippet was not exercised. |
| E15 | Spike b (2026-11-02). In a `claude -p --chrome --permission-mode default --setting-sources '' --strict-mcp-config` child, `claude-in-chrome` was `connected`. Chrome tools absent from `--allowedTools` ran on a PreToolUse hook's explicit allow, and a hook deny blocked `navigate` ("hook error: spike deny"). The PostToolUse payload's `tool_response` is an array of content blocks, and the tool's own result is `tool_response[0].text`. PostToolUse did not fire for a call that failed (`javascript_tool` on `chrome://newtab`). |
| E16 | Spike c. With the hook script missing, exiting 1, or exceeding a 3 s timeout, `tabs_context_mcp` with `createIfEmpty: true` fell to the permission layer and was denied in all three cases ("Claude in Chrome requires permission."). The same was true with no hook at all. A pre-approved `Read` of a canary file ran in all three failure cases. `tabs_context_mcp` with `createIfEmpty: false`, which only reports, also ran. |
| E17 | Spike e, partly. Each fresh child's `tabs_context_mcp` with `createIfEmpty: true` returned a new `tabGroupId` holding one `chrome://newtab/` tab. Closing that tab returned "Group is now empty (auto-removed)", and this session's own group was untouched. |
| E18 | Spike d. In a child whose hook denied every Read, the pinned `find` returned four refs with `Attach files` among them, and `file_upload` to that ref returned "Uploaded 1 file(s)". The stream held no Read call. The quoting of the label differs between sessions (`""Attach files""` in the child, `"Attach files"` in this session), and the recorder pattern `"+Attach files"+` matches both. |
| E19 | Spike g, live consult (conversation archived afterwards with `PATCH` 200). After an upload, the form held `button[aria-label="Remove <file name>"]`, an enabled `Send` button and no `[role=progressbar]`. The J-send body sent the message, and `location.pathname` became `/c/<uuid>` within 4 s. ChatGPT had renamed this re-uploaded file `uora-spike02(1).txt`, because the account already held one with that name. The full mapping (12 nodes, saved as the freshness fixture) walks `assistant text` (final) ← `reasoning_recap` ← `thoughts` ← `execution_output` ← `code` ← … ← an intermediate visible `assistant text` ← `thoughts` ← `user text` ← null root, with no system or hidden node. |
| E20 | Opcodes. A PreToolUse hook answering a `javascript_tool` call whose `text` was `j-test` with `updatedInput` carrying a different `text` ran the substituted code: the result was `42 OPCODE-REWRITTEN https://example.com`. |
| E21 | Spike a. With `--setting-sources ''`, a canary in the cwd's `CLAUDE.md` and a phrase from the user `CLAUDE.md` were both absent from the child's context. Without the flag, both were present. A child launched with `/usr/bin/env -i` (only HOME, USER, LOGNAME, TMPDIR, LANG and PATH) and an absolute `claude` path authenticated with the subscription (`apiKeySource: none`), and the chrome server was `connected`. |

## Design

### 1. Boundary: replace the transport only

The only function whose behavior changes is `ultra_oracle_consult` in `scripts/lib/ultra-oracle.sh`. Its contract stays the same:
- the flags `--prompt`, `--prompt-file`, `--context`, `--mode blocking|background`, `--out`, `--slug` and `--timeout-cap-seconds`
- the typed status tokens and their return codes: `ok` 0, `dispatched` 0, `skipped:user` 0 (`:884`), `error` 1, `skipped:unavailable` 3, `timeout` 124. `skipped:disabled` comes from the wrappers (`ultra-oracle-consult-run.sh`, `run-retrieval-loop.sh`), not from the consult, and also stays unchanged.
- the background `.rc` contract (`0`, `1` or `124`, written last), the `$out.hint` and `$out.dispatch.err` sidecars, the verdict floor `_ultra_oracle_verdict_ok`, and the cap validation and ceiling
- `skip-ultra-oracle.local` and the per-surface USER-config opt-ins

**Cross-process browser mutex.** Today the lock key exists only in the attach and remoteHost branches (`ultra-oracle.sh:1013`, `:1046`). An empty key means no lock, and this design deletes both branches. The Chrome transport therefore always takes the mutex under the fixed key `chrome-extension`, since every consult shares one Chrome and one extension. It requires a non-empty lock handle before launching a child. `_ultra_oracle_browser_lock` currently degrades to unlocked when the lock dir is unwritable (`:723-749`); for this transport that case is `error`, not an unlocked run. The no-auto-reclaim semantics and the `dispatch.err` recovery line stay. The line is now printed whenever a waiter gives up on a held lock, not only once the lock passes `now+hcap+120` (`:746`). Both callers pass `wait=cap` (`:1300`, `:1431`), so today a waiter queued behind a crashed holder gives up before the lock counts as stale and never sees the line. The line stays conditional. The line's text is rewritten for the new transport: today it says to verify with `pgrep -fl oracle` (`:776`), which matches nothing once oracle is gone. It now names the lock path and says to remove it only when `pgrep -fl 'claude -p --chrome'` shows no child.

These stay stable: the `ultra_oracle_consult` flags, the status tokens and return codes, the `.rc` contract, the names of the entry points that survive, and the `ultraOracle.*` namespace. Consumers do change in a closed set of places: the wrappers' success branches print the `.hint` `NOTE:` line (§6), and the banners, the skill timeout formulas, the docs and the deleted preflight script change as listed in §9. `delib_gate.py` and the `pre-implementation-gate.sh` entry-point allowlists need no edit, and no gate is loosened. "UltraOracle" now names the surface. It no longer means the CLI.

### 2. Lifecycle: the parent owns it

The adapter, called the parent here, owns the whole consult and records it in a 0700 run directory, `$HOME/.cache/busdriver/ultra-oracle/run-<tag>/`, next to the mutex. It is outside every repository on purpose. A consumer repo does not gitignore `.claude/ultra-oracle/` (only busdriver's own `.gitignore:50` does), so a run dir inside the repo would let a `git add -A` stage prompt and answer bytes. Here `<tag>` is 16 hex characters from `/dev/urandom`. The run dir is resolved once to an absolute canonical path with `pwd -P`. That exact string is used in the Read allow rule, the instructions and the guard's expected values.

**Staging.** The parent builds a single prompt file, `run-<tag>/uora-<tag>.txt`. It holds the `--prompt` text or a private copy of the `--prompt-file` bytes, followed by each `--context` file in argument order. Each context file goes under a header `=== [<n>] <basename> ===`, where `<n>` is its 1-based index, and a newline is always written before the header. The header deliberately carries the basename only. Today's frame (`ultra-oracle.sh:1198`) repeats the caller's full path, which sends local directory names to ChatGPT, and that change is intentional. Each input, the `--prompt-file` and every `--context` path alike, must pass a new predicate: `[[ -L ]]` false, `[[ -f ]]` and `[[ -r ]]` true, otherwise `error`. This is stricter than today's check (`ultra-oracle.sh:1179-1184` has no symlink test and falls back to attaching), which it replaces. Staging copies with a cumulative bounded `head -c` of 10 MB + 1 bytes, headers included, so a FIFO, `/dev/zero` or a growing file cannot stall it, and an over-limit staged file is detected from the bounded copy and is `error`. An input holding a NUL byte is `error` too, because the upload is a text file. The staged file's SHA-256 goes into `run-<tag>/record.json`. Callers may then delete or change their own files without affecting the run.

**Phase file.** `run-<tag>/phase` holds one word, and it is only ever written by an atomic rename. There is exactly one child per consult, with no setup retry and no recovery child, so the phase only records how far that child got. The parent's post-exit pass classifies the exit from it:

| Phase | Written by, and when | On child exit without a verified answer |
|---|---|---|
| `setup` | Parent, at start | No retry; the operator re-runs the consult. A disconnect is `extension-not-connected` (§6), and a child auth, usage or rate failure is `claude-unavailable` (§7). Every `ERR` a snippet returns before submission is `error`: `ERR pro` publishes as `pro-unavailable`, `ERR not-home` as `not-home` and `ERR origin` as `origin` (§6). **Default:** any other exit is `error child-died`. |
| `submitting` | **The guard (§4)**, before it allows `file_upload`. That is the earliest point at which the prompt bytes can reach ChatGPT, whatever the child does next. The parent also classifies the exit as `submitting` when `phase` still reads `setup` but the stream holds a `file_upload` `tool_use` whose paired `tool_result` reports the upload (`Uploaded …`). If the paired result is missing (the child died mid-call), it does so only when the decision log holds an allow for that `tool_use_id`, or holds no line for it, which fails closed. A logged deny, or a paired result that is a guard deny or a permission refusal, leaves the exit at `setup`, because nothing was uploaded. | No resubmit, ever. The result depends on how far the stream got:
- no J-send `tool_use` (for example J-attached `ERR upload`, or a child that stops after the upload while time remains) → `error upload`, since no click can have happened
- J-send `ERR origin`, `ERR not-home`, `ERR focus` or `ERR send`, all returned before any click → `error send`
- a J-send `tool_use` with no result, or `SENT` followed by J-id `NOID` or by no J-id result → `error submit-uncertain`
- **default:** any other exit → `error submit-uncertain`, because a send cannot be ruled out |
| `submitted` | Parent, in its post-exit pass, when the stream holds a J-id `tool_result` of `UORA_ID <id>`. The id goes into `record.json`. While the child runs, what it may do after the send is keyed on its own guard state (§4), not on the phase word. | `error`, and no second child. The reason comes from the last structured `ERR` token the stream holds: `ERR auth`, `rate`, `server`, `gone`, `binding`, `schema`, `origin`, `timeout` or `network`. `ERR timeout` publishes as reason `fetch-timeout` (rc 1), never as status `timeout`; every other token publishes under its own name (§6). **Default:** any other exit without `SAVED`, such as a disconnect, a crash, a CDP timeout, a `[TRUNCATED]` or `[BLOCKED]` result, or exit 0 after `PENDING`, `UORA_ID` or `DONE`, is `error child-died`. The hint names the recorded conversation id (§6). |
| `captured` | Parent, when the audit is clean and §6 has verified the answer | Nothing to classify. |

The child's stream goes to `run-<tag>/stream.jsonl`.

**Publication follows the audit.** The parent publishes nothing while the child runs. After the child exits, the parent runs the §4 stream audit over its stream. If the audit is clean, the stream holds `SAVED`, and §6 verifies the file, the result is `ok`. That holds even if the browser cutoff (below) killed the child during J-archive or the tab close. The archive or close failure then goes into `.err` and `.hint` before `.rc` is written. A clean audit with no `SAVED` follows §4 reason precedence: a child terminated at the browser cutoff is `timeout` 124, and any other exit follows the phase table above. An audit violation is `error`.

**Deadline.** A single deadline, derived from the timeout cap, covers the whole consult. It is split in two:
- **Browser work** (mutex wait, the Chrome reopen, setup, upload, polling) stops at the browser cutoff, which is deadline minus 60 s. A child still running then is terminated, and the parent records in `record.json` that it terminated the child at the cutoff. Unless §6 then verifies an answer, that run ends `timeout` 124 (§4 reason precedence), not with a phase reason.
- The deadline is anchored once, at consult start, before the mutex wait. The existing lock-wait deductions (`ultra-oracle.sh:1305-1314` in background mode, `:1436-1444` in blocking mode) are removed, since the wait is already inside the deadline. A run whose mutex wait passes the browser cutoff ends `timeout` 124 without launching a child.
- **The final 60 s** are reserved for download settling (at most 30 s, §6), the audit, verification and publication.

The callers' contract is cap + 90 s (`_UORA_RC_GRACE_DEFAULT`), which covers only child termination and the `.rc` write after the deadline.

**Process model.** This is the adapter's existing split, kept as it is:
- **Blocking mode:** the sourced function runs the consult in the caller's shell. It releases the mutex with `_ultra_oracle_browser_unlock` and runs the cleanup below explicitly at every exit. It sets no trap in the caller's shell (`:1424-1428`).
- **Background mode:** the sourced function validates, stages, prints `dispatched` and returns. The existing disowned subshell (`:1283-1407`) owns the mutex, the child, publication and cleanup. It may set an `EXIT` trap inside that subshell only, and it unlocks immediately before the atomic `.rc` rename, as at `:1355-1361` today.

**Cleanup.** One rule for both modes. On every exit path, cleanup deletes the staged prompt, every copy of the answer file, the child stream, the decision log and its `oob/` files (§4), `guard.json` (or its `guard.json.done` tombstone, §4) and `guard-state.json`. Cleanup never deletes the published `<out>`, `.err`, `.hint`, `.rc` or `.dispatch.err`. It keeps the 0700 `run-<tag>/` dir holding only `record.json` until the age sweep below removes it. `record.json` holds no content: hashes, phase, id, reason, and the tab ledger.

**Platform and process seams.** The platform probe and the Chrome-reopen command are held in source-time shell variables, `_ULTRA_ORACLE_PLATFORM` (from `uname -s`) and `_ULTRA_ORACLE_OPEN_CMD` (`open -a "Google Chrome"`). They are assigned unconditionally when the adapter is sourced, never read from the environment, following `_ULTRA_ORACLE_PREFLIGHT` (`ultra-oracle.sh:20-25`). In-process test harnesses reassign them after sourcing, which is the only override path. So the fake-`claude` adapter suite runs on the Linux CI runners, and only the live smoke is Mac-only. The mutex has no test bypass: tests use the real lock under a temporary `HOME`.

**Chrome reopen.** After acquiring the mutex and before the launch, the parent runs `_ULTRA_ORACLE_OPEN_CMD` exactly once, unconditionally. It starts Chrome if it is not running and opens a window if Chrome has none, which covers E10. It also brings Chrome to the front, which is accepted. Running it is safe when Chrome already has a window, so the parent needs no probe of Chrome's state. A non-zero exit is `extension-not-connected`, and no child is launched. The command runs under the existing `_portable_timeout` (`resolve-cli.sh:1532`), bounded by the budget left before the browser cutoff, because it runs while the mutex is held. If it expires, the parent releases the mutex and the run ends `timeout` 124 with no child. r4 (§3) measures whether the extension is connected by the time the child's first chrome call runs.

**Tab ledger.** In the post-exit pass, the parent appends to `record.json` the own tab id from the child's `tabs_context_mcp` `tool_result`, and whether a `tabs_close_mcp` of it succeeded. The guard allows `tabs_close_mcp` only on the child's own recorded tab, and each child is a separate session with its own group (E17). So a tab left by a crashed, killed or cut-off child is named in `.err` and `.hint` (`tab-cleanup`) for the operator to close, without changing an `ok` result.

After acquiring the mutex, each consult also sweeps two kinds of leftovers, such as a late download that lands after its child was killed:
- `run-*` dirs older than twice the cap ceiling
- files matching `uora-[0-9a-f]{16}( \([0-9]+\))?\.json(\.crdownload)?` in the candidate download dirs (§6) older than the ceiling, regular files only, never through a symlink. The per-run cleanup deletes the same names, `.crdownload` included, for its own tag.

### 3. The child

```
/usr/bin/env -i HOME USER LOGNAME TMPDIR LANG PATH=<resolver PATH>  (cwd = <run-dir>; loader vars cleared)
<absolute claude> -p --chrome --model sonnet --permission-mode default --setting-sources '' \
  --tools "Read,ToolSearch" --strict-mcp-config --no-session-persistence \
  --output-format stream-json --verbose \
  --allowedTools "ToolSearch,Read(/<run-dir>/uora-<tag>.txt)" \
  --disallowedTools "Bash,Write,Edit,NotebookEdit,WebFetch,WebSearch,Glob,Grep,Agent,Task" \
  --settings <run-dir>/child-settings.json        # PreToolUse guard + PostToolUse recorder, §4
  "<rendered instructions>"                         # positional prompt, from a repo template
```

`--allowedTools` is variadic, so the prompt follows a non-variadic flag, as in every E15–E21 run.

The child uses six chrome tools: `tabs_context_mcp`, `tabs_close_mcp`, `navigate`, `find`, `file_upload` and `javascript_tool`. It has no `tabs_create_mcp`: each child is a fresh `claude -p` session with no tab group, so `tabs_context_mcp` with `createIfEmpty: true` opens a new window holding one empty tab, and that bootstrap tab is the child's own tab. It has no `computer` tool at all, so it has no mouse, keyboard, wait or screenshot action. Each name carries the `mcp__claude-in-chrome__` prefix. **None of them is pre-approved** in `--allowedTools`. The guard's explicit PreToolUse allow is the only way a state-changing chrome call runs (E15). A guard that fails without a decision leaves the call to the permission layer, which denied it in every measured case (E16). The one chrome call that ran without an allow, `tabs_context_mcp` with `createIfEmpty: false`, only reports, and the guard never allows that form.

These choices follow existing practice in the repo:
- **Launch environment.** `claude` is resolved to an absolute path through the trusted-CLI resolver (`--print-trusted-cli claude`), and its `PATH` through `--print-review-dispatch-path`. Both resolver calls run under `/usr/bin/env -i` with loader variables cleared, exactly as the litmus backstop runs them (`skills/litmus/scripts/run-review-loop.sh:1169-1177`). The child launch itself goes further than litmus, whose claude launch does not use `env -i`. It runs under `/usr/bin/env -i` with loader variables cleared and only the six variables above. A non-absolute resolution is `skipped:unavailable` (`claude-unavailable`). The allowlist drops `CLAUDECODE`, `CLAUDE_CODE_SAFE_MODE`, `CLAUDE_CODE_SIMPLE`, `SHELLOPTS`, `BASH_ENV` and `ENV` by construction. E21 shows that subscription auth and the chrome server both survive it. The binary is held in a source-time variable, `_ULTRA_ORACLE_CLAUDE_BIN`, which the fake-`claude` tests reassign after sourcing.
- `--setting-sources ''` follows the blueprint-review #198 fix: the operator's user, project and local permission allows, and a merged `disableAllHooks`, must not load into the child. With it, neither the project nor the user `CLAUDE.md` loads (E21). `<run-dir>` is the absolute `pwd -P` path, so `Read(/<run-dir>/…)` renders as the root-anchored `//` form.
- `--strict-mcp-config` keeps `claude-in-chrome`, which is registered dynamically by `--chrome` (E15).
- Before setup, the parent capability-probes `<absolute claude> --help` for `--chrome` and `--setting-sources`, under the same environment as the dispatch, following the litmus backstop's capability guard (`skills/litmus/scripts/run-review-loop.sh:1182-1192`): the help text is captured once into a variable and then matched, which avoids a SIGPIPE under `pipefail`. Unlike the litmus probe, it runs under `_portable_timeout` with a fixed 15 s bound, and an expiry is `skipped:unavailable` (`claude-unavailable`). The same pre-launch check requires `[ -x /usr/bin/jq ]`, since the guard calls `jq` by that absolute path; a missing `jq` is `skipped:unavailable` (`claude-unavailable`) with the hint naming `/usr/bin/jq`, never `guard-denied`. A missing flag means `skipped:unavailable` (`claude-unavailable`).

**Spikes.** Spikes a, b, c, d, f and g ran on 2026-11-02 from a busdriver session, and their results are E15–E21. Every design choice below that depended on one now cites the result. Three residual checks remain for plan step 1, before code depends on them:
- **r1. Qualification runs.** Three full guarded consults finish `ok`. This criterion applies to these qualification runs only; production behavior follows §4. They must show:
  - zero `forbidden`, `no-ref` and `post-lost` lines in any decision log (§4). Retryable denials (`busy`, `not-yet`) are counted and reported, not failures.
  - a p99 guard runtime under 1 s across every hook call, measured with the real `/usr/bin/jq` and the lock path. This is the spike c condition for accepting the hook-timeout residual, and it has not been measured yet.
  - that each hook payload's `tool_use_id` (present in the E15 PreToolUse payload keys) equals the `id` of the matching stream `tool_use` record, because the audit joins on it
  - which `text` the stream's `javascript_tool` `tool_use` holds after an `updatedInput` rewrite, the opcode or the rendered snippet. One such record is committed as a fixture, and §4's audit accepts only the recorded form.

  A failure of any of the three sends the design back to review.
- **r2. Cross-session close.** Withdrawn in revision 12. With one child per consult, no child shares a run with another child's tab, and the guard allows a close of the own tab only.
- **r3. Block-on-hook-failure.** The Claude Code hook documentation and `claude --help` are checked for a setting that turns a hook timeout into a block. If one exists, the adapter requires and probes it, which closes the §4 timeout and disclosure residuals. If none exists, those residuals stand as written.
- **r4. Reopen settle.** Qualification also starts once with Chrome not running and once with Chrome running but windowless (E10). In both, after the pre-launch `open -a`, the extension must be connected for the child's first chrome call. If it is not yet connected, the plan adds a fixed wait after the reopen, sized from the measurement, and an adapter test pins it. Neither outcome changes the rest of the design.

The original spike definitions follow, for the record.
- a. The flag set combines. The chrome tools load through `ToolSearch` under `--tools "Read,ToolSearch"`. Subscription OAuth survives `--setting-sources ''`. A canary line planted in the project and user CLAUDE.md is checked against the child's stream. If it appears, the run dir moves outside the repo (next to the lock under `$HOME/.cache/busdriver`), and any remaining user-level load is recorded as a residual.
- b. PreToolUse and PostToolUse hooks from `--settings` fire for MCP tool calls in `-p` mode and can deny them. This must still hold with a user settings file that allows Bash and sets `disableAllHooks`. The same spike records the shapes of the `tabs_context_mcp` and `find` results, as the PostToolUse half receives them, that the recorder parses. Every containment property depends on this spike.
- c. Hook failure modes: a missing guard script, a guard exiting 1, and a guard exceeding its timeout, each with its observed behavior recorded. The spike passes when the first two block (through the §4 wrapper) and one of these holds for the third:
  - a block-on-hook-failure setting exists and is shown to block; the adapter then requires it and capability-probes it
  - the same three cases are also run against the pre-approved `Read` of the staged path, since a hook failure there runs the call instead of leaving it to the permission layer (see the disclosure residual, §4)
  - or, absent such a setting, a timeout that proceeds is accepted as the same residual every busdriver gate already carries (project CLAUDE.md "Enforcement Gates", ADR 0050), under the condition that applies there: the guard bounds its own work (no network, a non-blocking PreToolUse lock, and no sleep except the PostToolUse lock wait, capped at 5 s). ADR 0032:128 records the measurement that a timed-out hook reads as allow. The hook timeout is set to 30 s, and the spike must measure a p99 guard runtime under 1 s, reported separately for PostToolUse calls that overlap another hook. The stream audit then catches anything that slipped through, and publication waits for that audit (§2).
- d. In a fresh tab driven by the exact guarded initial template, with no earlier refs: the pinned `find` (§4) returns exactly one line matching the recorder's `Attach files` pattern on every run of the set (E13 is one run), and `file_upload` of the staged path to that recorded ref succeeds while the guard denies every Read call. The stream contains no executed Read, and the `find` result holds only file-input labels and find's descriptions, with no sidebar or conversation text. The same runs capture the full sanitized conversation `mapping` of one live consult, root included, as the §5 freshness fixture. If any part fails, the design goes back to review. There is no fallback that lets Read execute, because that would put the prompt bytes into the child's context.
- e. A fresh child's `tabs_context_mcp` with `createIfEmpty: true` opens a new window holding exactly one tab and returns that tab's id, which the recorder parses (E10). The same spike runs two children in sequence and confirms that the second cannot close the first one's tab: the installed `tabs_close_mcp` schema says only tabs in the session's own group are closable. If a fresh child instead finds an existing group, the design goes back to review.
- f. The operator's download directory is among the §6 candidates.
- g. Snippet hash-match rate over several initial and recovery runs with the real templates (E11 left this unmeasured). The ship criterion is 100%. Below that, the fallback is opcodes: the child sends a short name such as `j-poll`, and the PreToolUse guard rewrites it to the repo file's text through the hook's `updatedInput`, provided the same spike shows `updatedInput` applies to `mcp__claude-in-chrome__javascript_tool`. Normalizing whitespace before hashing is not an accepted fallback. With opcodes, the audit checks the opcode text and the phase, and the opcode→snippet mapping is the repo file the lock pins. The same runs record three things: whether J-attached detects the finished attachment chip from a stable DOM marker; whether J-send, after an upload, inserts exactly the fixed sentence into the composer and submits it through the composer's `Send` button (E14 showed the focus and insert halves, not the submit); and whether J-home's Pro read (E12) holds. Any of the three failing sends the design back to review. There is no keyboard fallback.

Results: a passed (E21). b passed (E15). c showed that state-changing chrome calls are denied on every hook failure, while the pre-approved Read runs on every one (E16). d passed (E18). e is partly shown (E17); r2, which would have completed it, is withdrawn because there is one child per consult. f: the downloads landed in `~/Downloads` (E8, E19). g: E20 showed that opcodes work, so the design adopts them (§4) and the child never reproduces snippet text. That makes the hash-match rate moot. E19 showed J-send's submit, the attachment marker, and that J-home's Pro read held.

**The template.** It is a repo file (§4 gives its location). The parent fills in only the tag and the staged path.

The template starts with step 0: `ToolSearch` selecting exactly the six chrome tool names. **The child has no input device and reads the page exactly once**, through one guard-pinned `find` whose result is a list of file-input refs (E13). No `computer` action, `read_page` or second `find` is allowed. Everything else it learns about the page comes back as a closed status token from a fixed snippet.

The child:
1. `tabs_context_mcp` with `createIfEmpty: true`, then navigate the bootstrap tab to `https://chatgpt.com/`.
2. **J-home**, which must return `READY`. It confirms the home page with Pro selected (E12). The child never changes the model. On `ERR pro` the run ends `pro-unavailable`, and the operator selects Pro once by hand.
3. `find` with exactly the pinned query `file input element for attaching files to the message composer`.
4. Call `file_upload` with the staged path and the ref of the `Attach files` line.
5. **J-attached**, repeated while it returns `PENDING`, until it returns `ATTACHED`.
6. **J-send**, once. It must return `SENT`.
7. **J-id**, once (it waits internally).
8. **J-poll**, repeated while it returns `PENDING` (each call waits internally).
9. **J-get**.
10. **J-archive**.
11. Close its own tab.

### 4. Containment: prevention first, audit second

**Files.** The guard and everything it compares against live in `scripts/hooks/ultra-oracle-child/`:
- `guard.sh`
- the template
- `j-home.js`, `j-attached.js`, `j-send.js`, `j-id.js`, `j-poll.js`, `j-get.js` and `j-archive.js`

**bash 3.2 floor.** `contained-launch.sh:129` accepts only `/bin/bash` as the interpreter, and on the operator's Mac that is bash 3.2.57. `guard.sh` therefore follows the adapter's own floor (`ultra-oracle.sh:6`): no associative arrays, `mapfile`/`readarray`, `[[ -v ]]`, namerefs, case-modification expansions (`${x,,}`, `${x^^}`) or `$BASHPID`, and empty arrays use the `${arr[@]+"${arr[@]}"}` form under `set -u`. Linux CI runs bash 4 or 5, so a static test enforces the floor by grepping `guard.sh` for those constructs.

`.gate-integrity.lock` already pins that directory (#742), so no change to the guard's body or its expected values can land without the lock regen appearing in the reviewed diff. The plan confirms that `tests/test-node-hook-containment.sh` accepts a directory there with no `hooks.json` registration. If the suite does not accept it, the plan instead extends the lock's scope explicitly to the guard's own location, with a test that fails if it is unpinned.

**Hook registration.** `child-settings.json` registers the same script twice, in **exec form** (ADR 0049; a shell-form string with an `|| exit 2` tail is not a boundary there). Both use the repo's existing first hop `hooks/gate-scripts/lib/contained-launch.sh` with the `closed` disposition, which turns a launch failure such as a missing or unreadable `guard.sh` (bash exit 127) into exit 2:
- PreToolUse: `command` = `<plugin root>/hooks/gate-scripts/lib/contained-launch.sh`, `args` = `["closed", "PATH=/usr/bin:/bin", "UORA_RUN_DIR=<absolute pwd -P run dir>", "/bin/bash", "<absolute guard.sh>", "pre"]`, `"timeout": 30`. There is no `-p` operand: the launcher requires the first operand after `/bin/bash` to be an absolute path (`contained-launch.sh:173-181`), so a `-p` operand would be refused. The launcher itself runs under `bash -p` and execs the guard through `/usr/bin/env -i` with only the listed assignments (`:270`), so the guard runs as plain `/bin/bash` in a cleared environment. This matches the existing `closed` registrations in `hooks/hooks.json`.
- PostToolUse: the same with `"post"`

Both registrations use the match-all matcher (`"*"`), so every tool, including `Read` and `ToolSearch`, passes through the guard. A guard test asserts that the rendered `child-settings.json` hooks `Read` and `ToolSearch`.

The guard denies (exit 2) when `UORA_RUN_DIR` is missing, is not absolute, or is not a dir holding a mode-0600 `guard.json`. A guard test runs the exact rendered `child-settings.json` argv through `contained-launch.sh` and requires an explicit allow (exit 0 plus allow JSON) for a legal call, as well as the block cases.

The blocking claim applies to the PreToolUse half only. There, an allow is exit 0 with explicit allow JSON, and a deny emits deny JSON and exits 2. Inside `guard.sh`, an `EXIT` trap turns every path that has not emitted an explicit allow, including a crash, into deny JSON and exit 2. The PostToolUse half runs after its tool has executed, so it cannot block anything. Its only jobs are to record six values: the own tab id from the `tabs_context_mcp` result, J-home's `READY`, the upload ref from the `find` result, J-attached's `ATTACHED`, J-send's `SENT`, and J-get's `SAVED`. Each value is read from `.tool_response[0].text` of the PostToolUse payload (E15), with at most one trailing newline removed. The matches are spelled out: `ready`, `attached` and `sent` latch only on exactly `READY`, `ATTACHED` and `SENT`, and `saved` latches only on `^SAVED [0-9]+ [0-9a-f]{64}$` (§5's J-get grammar). Anything else records nothing. A call that fails fires no PostToolUse (E15), so it records nothing. The guard matches tool names in their full `mcp__claude-in-chrome__` form. Each of these payload shapes, captured in E15 and E18, is a guard fixture. For the `find` result, the recorder always records the match count (`0`, `1` or `many`) for lines matching `^- (ref_[0-9]+): button "+Attach files"+ \(file\)( - |$)`. When the count is `1`, it also records the ref. `navigate`'s PostToolUse latches `navigated`, since it fires only for a call that succeeded (E15). The recorder parses the result itself, so the child's reading of it decides nothing. If the PostToolUse half fails, nothing is recorded, so every later tab-scoped call and the upload are denied, which fails closed. The guard is pure bash and `/usr/bin/jq`, called by absolute path because `PATH` is only `/usr/bin:/bin` (§3 probes it), with no network access, so it finishes in milliseconds. A hook timeout is the one failure mode the wrapper cannot turn into a block. E16 measured what it does: a state-changing chrome call is still denied by the permission layer, while the pre-approved Read runs (the disclosure residual below; r3 checks for a setting that would close it).

**Guard state.** Before the launch, the parent writes `run-<tag>/guard.json` (mode 0600). It holds the tag, the staged path and the rendered text of each snippet. The guard reads its expected values only from this file and the `phase` file, never from the tool input. The child's own state lives in `run-<tag>/guard-state.json`, which starts empty:
- the own tab id, `find`'s match count, the upload ref, and the flags `navigated`, `ready`, `attached`, `sent` and `saved`, all recorded by the PostToolUse half as above. The allow table's columns and preconditions key on them.
- a counter for each once-only action, incremented in PreToolUse at the moment of allowing

A model can issue tool calls in parallel, so every state read-decide-write takes a `mkdir` lock, `run-<tag>/guard.lock`, and finishes with an atomic rename. The two halves treat contention differently:
- **PreToolUse** tries once. If the lock dir already exists, the call is denied at once with reason `busy`. Nothing has run yet, so the child can reissue the call.
- **PostToolUse** spins for the lock in 10 ms steps for at most 5 s, well inside the 30 s hook timeout. Its tool has already run, so its record must not be dropped. If it still cannot get the lock, it writes a `post-lost` line outside the lock, to its own `oob/` file (decision log, below). The audit treats `post-lost` as a violation (`error audit`), which fails closed, and an overlap test shows that it does not occur under normal contention.

**Writes happen under the lock, in a fixed order.** Each state-dependent decision and each recorded transition appends its decision-log line while it still holds `guard.lock`, then renames the new state into place, then releases the lock. A failed append is a failed transition: PreToolUse denies, and PostToolUse records nothing and exits non-zero. Only `busy` and `post-lost` lines are written outside the lock, and replay takes both as logged. So the log order is the order in which state actually changed.

**Hooks that outlive the child cannot write.** The child runs in its own process group. In both modes, a dedicated subshell turns on `set -m`, starts `claude` as a background job, and the publisher waits for it with `wait $!`. With monitor mode on, that job's process group id equals its pid (measured under `/bin/bash` 3.2; the launcher already relies on this at `ultra-oracle.sh:1284-1285`). Every signal goes to `-$pid` only. The publisher is never a member of that group: in background mode it is the inner subshell that writes `.rc` (`:1361`). The caller's shell never has monitor mode set, so blocking mode, which today runs in the caller's shell (`:1424-1428`), gets a nested subshell for the launch. Termination sends TERM and then, after 5 s, KILL to the whole group, not only the watched PID that `_uora_terminate` signals today (`ultra-oracle.sh:182-216`). After every exit, whether natural, crashed or terminated, the parent also sends KILL to the group before the post-exit pass, so no hook of the child is left running. The post-exit pass then starts by renaming `guard.json` to `guard.json.done`, as a second fence for a hook outside the group. The guard checks for `guard.json` again once it holds `guard.lock`, and if the file is gone it denies and writes nothing. So a hook still running after its child cannot change the state or the log the audit reads. A write already in flight at the rename can at most leave the log's last line torn or absent. A torn line fails to parse, and an absent PreToolUse line leaves a stream `tool_use` with no log line; both are violations, so the audit fails closed.

A lock dir stranded by a hook killed mid-update makes every later PreToolUse `busy` and every later PostToolUse `post-lost`, so that run fails closed and never publishes `ok`. A call whose payload or state file cannot be parsed is denied at once. There is no lock stealing. "Own tab" means the recorded id.

**Deny reasons** are a closed set, and every deny carries exactly one:
- `busy`: PreToolUse found the lock dir already existing
- `not-yet`: the call is allowed in the current column of the allow table, but something it depends on has not been recorded yet. That covers:
- a tab-scoped call before the own tab id is recorded
- J-home before `navigated`, so a navigate batched with J-home cannot race it into a terminal `ERR origin`
- `find` before `READY`
- J-send before `attached`
- a `file_upload` while no `find` match count is recorded yet

No counter is spent on a `not-yet` deny.
- `no-ref`: a `file_upload` when the recorded `find` match count is `0` or `many`. The two cases are told apart by whether a count is recorded, not by timing.
- `forbidden`: everything else, including any call outside the allow table, a foreign input, and a once-only action already spent

`busy` and `not-yet` are retryable. They are PreToolUse denies only, since PostToolUse never denies. The instructions tell the child to issue one tool call per turn and, on a `busy` or `not-yet` deny, to reissue the same call after its previous call has returned. Once-only counters count allows only, so a retried call can still be allowed once. A model that batches J-home and `find`, or `find` and `file_upload`, therefore loses nothing: the second call is denied `not-yet` and reissued.

**Decision log.** The guard appends one line per PreToolUse decision and per PostToolUse record to `run-<tag>/decisions.jsonl` (mode 0600), under the lock in the order given above. Each line is built in full first and then written with one `printf` and a single `>>`. `busy` and `post-lost` lines are the only ones written outside the lock, so they never touch `decisions.jsonl`. Each one goes to its own new file, created with `mktemp` in `run-<tag>/oob/`, whose name is not derived from the payload. The parent merges those files into the audit input only after the child's group is dead. Neither line changes state, so where it sits in the merged order does not affect replay. Each line holds the payload's `tool_use_id`, the hook half, the tool name, the input with the opcode name in place of the rewritten text, and the decision with its deny reason or the recorded value. The log is in live hook order, which the stream is not: stream-json emits every `tool_use` block of an assistant turn before their results.

**Allow table.** Everything not listed is denied.

The last two columns are keyed on the child's own guard state (whether it was allowed the upload, and `sent`), never on the `phase` word.

| Call | Before the upload | Upload allowed, not `sent` | `sent` |
|---|---|---|---|
| `ToolSearch` selecting only the six chrome names above | yes | yes | yes |
| `tabs_context_mcp` with exactly `createIfEmpty: true` | once | — | — |
| `navigate`, own tab | exactly `https://chatgpt.com/`, once | — | — |
| `javascript_tool` J-home, own tab | yes | — | — |
| `find`, own tab, with exactly the pinned query (§3) | once, and only after this child's J-home returned `READY` | — | — |
| `file_upload` with exactly `[<staged path>]`, the recorded ref, own tab | once, and only after `READY` and a recorded ref. The guard writes `submitting` **before** it allows the upload. | — | — |
| `javascript_tool` J-attached, own tab | — | yes | — |
| `javascript_tool` J-send, own tab | — | once, and only after `attached` | — |
| `javascript_tool` J-id, own tab | — | — | yes |
| `javascript_tool` J-poll, own tab | — | — | yes |
| `javascript_tool` J-get, own tab | — | — | once |
| `javascript_tool` J-archive, own tab | — | — | once, and only after `saved` |
| `tabs_close_mcp`, own tab only | yes | yes | yes |
| `Read` | **deny** (the scoped allow exists only for E3) | deny | deny |
| any `computer` action, `read_page`, or any other tool | deny | deny | deny |

**Opcodes (E20).** The child never sends script text. Its `javascript_tool` `text` is exactly one opcode: `j-home`, `j-attached`, `j-send`, `j-id`, `j-poll`, `j-get` or `j-archive`. The guard allows a listed opcode by answering with `updatedInput`, which carries the same tool input with `text` replaced by that snippet's rendered text from `guard.json`. Any other `text` is denied. The instructions therefore contain no JS, and nothing depends on a model reproducing code byte for byte. There is one audit rule for this text. The decision log's input `text` is always the opcode. The stream's `text` for that `tool_use_id` must equal the form r1 recorded for the same opcode, which is either the opcode itself or `guard.json`'s rendered snippet for it. Any other stream text is a violation.

**Stream audit (second check).** After the child exits, the parent checks it in two steps, neither of which depends on the order in which stream-json emits records.
1. **Replay.** It replays the decision log, in its live hook order, from fresh state seeded from a copy of `guard.json.done` and phase `setup`. It runs `guard.sh` in a replay mode, so there is one implementation. Replay mode is pure: it works on private copies of `guard.json`, `phase` and the state file in a scratch dir, and never renames `run-<tag>/phase` or `guard-state.json`. It re-decides each logged PreToolUse line and applies each logged PostToolUse record, and every re-decision must equal the logged one. A logged `busy` line is taken as logged without a re-decision, because lock contention cannot be replayed. A `post-lost` line is a violation.
2. **Join.** It joins the stream to the log by `tool_use_id`. Each stream `tool_use` must have a logged PreToolUse line whose input matches. The stream's `javascript_tool` text is compared in the form r1 recorded. Field by field: the log's `text` equals the opcode, the stream's `text` equals the r1 form for that opcode, and every other input field is byte-equal. The logged allow records the opcode, not the snippet body. A `tool_use` whose paired `tool_result` shows it executed (anything but a guard deny or a permission refusal) must have a logged allow.

A stream `tool_use` with no log line, an executed call without an allow, a re-decision mismatch, or any `forbidden` deny is a violation: `error`, reason `audit`, or `guard-denied` for a `forbidden` deny. These are not violations:
- a `busy` or `not-yet` deny, because nothing ran
- a record that is absent after `SAVED`, meaning an allowed J-archive or `tabs_close_mcp` whose result never arrived because the browser cutoff killed the child.

That exemption covers only absence. Every record the stream and the log do hold is audited by the same rules, before or after `SAVED`. So a `forbidden` deny, an unlogged `tool_use` or an executed call without an allow after `SAVED` is still a violation.

**Reason precedence** picks a reason only when the run does not publish `ok`. A clean audit of a stream that holds `SAVED`, with an answer §6 verifies, is `ok`, whatever retryable denies came before it. Otherwise the reason is chosen in this order:
1. Any violation gives `audit`, or `guard-denied` for a `forbidden` deny.
2. If the stream holds `SAVED` and any §6 check fails, the run is `error` with that check's reason (`download-missing`, `hash-mismatch`, `schema`, `binding`, `verdict-floor`). This holds whether or not the cutoff fired.
3. If the parent terminated the child at the browser cutoff (§2, recorded in `record.json`), the status is `timeout` 124 with the §6 timeout hint, which also names the conversation id when `UORA_ID` was recorded. Background mode writes `.rc` `124`.
4. A `no-ref` deny gives `upload`.
5. Otherwise the §2 phase table decides. It applies only to exits while time remains.

The audit always runs before publication (§2).

**What the child sees.** Status tokens from the fixed snippets, the tab ids, the results of its own `navigate` and `file_upload` calls, and the one pinned `find` result: file-input refs with their aria labels and find's one-line descriptions (E13). Nothing else it can call reads page content, so neither the operator's sidebar nor the rendered answer enters its context or transcript. J-get returns only a byte count and a hash.

**Data flow.**
- The prompt is uploaded to ChatGPT, the same as with oracle.
- `--no-session-persistence` keeps the child's transcript out of Claude Code's session storage. It combined with the other flags in every E15–E21 run.
- The prompt and answer pass through the run dir and the download dir until cleanup removes them. In blocking mode that is the explicit cleanup at each exit. In background mode it is the subshell's `EXIT` trap. Otherwise the start-of-consult sweep removes them. A caller killed in blocking mode leaves them for that sweep, which is accepted as a residual.
- The session token is never written to any file.

**Residuals.**
- A timed-out hook may let a call proceed (E16). For the chrome tools, which are not pre-approved, the call then falls to the permission layer and is denied. The audit catches anything else afterwards.
- **Disclosure residual, separate from the gate residual.** The staged-path `Read` is pre-approved, because `file_upload` requires it (E3). If a hook timeout lets that Read run, the prompt bytes enter the Claude child session's model context and its stream file. The audit can only refuse publication (`error audit`); it cannot undo the read, and deleting the stream file at cleanup does not retract the disclosure. The recipient is the Claude child session, not ChatGPT. The provider is not new, because the caller is itself a Claude session, but `--context` files may never have entered any model context before. The child's only outputs are the guard-pinned calls. E16 shows that it can: a pre-approved Read runs when its hook is missing, exits 1 or times out. `contained-launch.sh closed` turns the first two into blocks, so only a hook timeout remains. r3 checks for a block-on-hook-failure setting; if one exists, the adapter requires it, which closes this residual.
- The `find` result is page-derived text in the child's context. Every call after it is pinned by the guard: the query, the upload path and ref (parsed by the recorder, not the child), and the snippet texts. So text in that result can at most make the child stop early, which ends the run as `error`. Spike d checks that the result holds only file-input labels.
- With no input device and one pinned `navigate`, the only thing that can move the own tab is the page itself. J-home checks the home page before the upload. J-get's and J-archive's fresh-conversation checks (§5) are the second line, so J-archive never archives an operator chat. J-home is denied `not-yet` until `navigate`'s result is recorded. If it still runs before the page has loaded, it returns `ERR origin`, a false negative that ends the run as `error` but is never a breach.
- If the operator's sticky selection is not Pro, every consult ends `pro-unavailable` until they select Pro by hand. The child never changes the model.
- The extension's own site permissions remain the fence for anything the guard misses.
- A `guard.lock` stranded by a hook killed mid-update is never removed during the run (§4). Every later call is then denied `busy` until the browser cutoff, so the consult fails, never publishing `ok`, and the operator re-runs it in a fresh run dir. This is accepted for v1: the guard's locked work takes milliseconds, so a stranded lock needs a hook killed inside that window, and the one child per consult means no later child depends on the lock.
- Consult chats are created in the operator's ChatGPT account and archived by J-archive. Archived chats stay readable (E9) and are not deleted.

### 5. The fixed snippets

The snippets are repo files. The only substitution is `<tag>` (`^[0-9a-f]{16}$`), in J-attached, J-get and J-archive. The parent renders all seven into `guard.json`, and the guard delivers them by opcode (§4). No snippet carries a conversation id: each one reads it from `location.pathname`, which must match `^/c/[0-9a-f-]{36}$`, and every one first asserts `location.origin === 'https://chatgpt.com'` (otherwise `ERR origin`). The parent binds the id by comparing it with the recorded `UORA_ID` (§6).

Every `fetch` uses an `AbortController` with a timeout, so the whole call stays inside 45 s (E4). An aborted fetch returns `ERR timeout`, and a rejected one returns `ERR network`. Each snippet returns one closed, single-line status matching `^(READY|ATTACHED|SENT|UORA_ID [0-9a-f-]{36}|NOID|PENDING|DONE|SAVED [0-9]+ [0-9a-f]{64}|ARCHIVED|ERR [a-z0-9_-]+( [0-9]{3})?)$`. Anything else is a parse failure, which ends the run as `error` (§2). Each snippet wraps its whole body in one top-level `try`/`catch`, whose `catch` returns only a grammar line (`ERR schema` by default) and never `String(e)` or any response text, so an exception cannot carry page or response bytes to the child.

The field paths are written in full. `node = j.mapping[j.current_node]` and `msg = node.message`, with `msg.author.role`, `msg.content.content_type`, `msg.content.parts`, `msg.status`, `msg.end_turn` and `msg.metadata.model_slug`. Ancestors are reached through `node.parent`, and the user message's attachments are at `msg.metadata.attachments[].name`. A sanitized E7 node is kept as the fixture these paths are tested against.

- **J-home:** returns `READY` only when all of the following hold:
  - `location.origin` is `https://chatgpt.com` and `location.pathname` is exactly `/`
  - the text of `button[aria-label="Select ChatGPT model"]` contains `Pro` (E12)

  J-home makes no claim about existing turns. After the guard-pinned navigate to exactly `https://chatgpt.com/`, pathname `/` is ChatGPT's new-chat composer. Freshness is enforced where it can be checked against data: J-get's and J-archive's fresh-conversation check over the message tree. It returns `ERR pro` when the Pro check fails and `ERR not-home` otherwise. Both are terminal before submission: the child closes its tab, and the run ends `error` with no upload.
- **J-attached:** within 38 s, it polls the composer's `form`. It returns `ATTACHED` when that form holds `button[aria-label="Remove uora-<tag>.txt"]`, an enabled `button[aria-label="Send"]` and no `[role=progressbar]`, which are the markers E19 observed. It returns `PENDING` until then, and `ERR upload` if a `Remove` button exists for a different name, such as ChatGPT's renamed `uora-<tag>(1).txt` (E19). The random tag makes that collision possible only on a repeated upload, which the `submitting` latch forbids. The tag is substituted here as well.
- **J-send:** one call that targets elements directly, so nothing depends on where keyboard focus sits. It asserts origin and pathname `/` before any focus, insert or click, returning `ERR origin` or `ERR not-home` if either fails. Then it takes the `.ProseMirror` composer and its enclosing `form`, focuses the composer and requires `document.activeElement` to be it, and inserts exactly `Follow the instructions in the attached file.` with `document.execCommand('insertText', …)` (E14). It requires the composer's `textContent` to equal that sentence, then calls `.click()` on the enabled `button[aria-label="Send"]` inside that same `form`. It returns `SENT`, `ERR origin`, `ERR not-home`, `ERR focus` (no composer, or focus or text did not take) or `ERR send` (no enabled Send button in the form). The sentence is fixed, so nothing is substituted.
- **J-id:** waits up to 30 s for `location.pathname` to match `^/c/[0-9a-f-]{36}$` and returns `UORA_ID <id>`, or `NOID`.
- **J-poll:** GETs the conversation with the session token, polling every 4 s for up to 38 s. It returns `DONE` as soon as the current message is a finished assistant turn: `role == assistant`, `content_type == text`, `status == finished_successfully` and `end_turn === true`, the E7 predicate. That holds **whether or not it binds** to the model and attachment, so a wrong-model or wrong-attachment answer fails fast in J-get instead of polling until the deadline. If `end_turn` is set without a finished status, J-poll keeps returning `PENDING`. The HTTP mapping below applies to every fetching snippet (J-poll, J-get and J-archive):
  - 401/403 → `ERR auth <code>`
  - 404 → `ERR gone`
  - 408 → `ERR timeout`
  - 429 → `ERR rate <code>`
  - any other 4xx (400, 422, …) → `ERR schema <code>`, terminal
  - 5xx → `ERR server <code>`
  - any other non-200 status → `ERR schema <code>`
  - a 200 with malformed JSON or missing fields → `ERR schema`

  J-poll returns `PENDING` only for a 200 whose tree is well formed and not yet finished. J-get and J-archive use the same mapping; a well-formed but unfinished tree in J-get is `ERR binding`.
- **J-get:** re-fetches the conversation and walks from the current node to the first `user` ancestor. Binding requires all of the following:
  - `role == assistant`, `content_type == text` and `status == finished_successfully`
  - `end_turn === true`
  - `model_slug` matching `^gpt-[0-9]+(\.[0-9]+)*-pro$`
  - the user ancestor's attachments include `uora-<tag>.txt`
  - **fresh conversation:** that user message is the conversation's only **visible** user turn. Walking on from it through `parent` to the root passes no other visible turn, so a consult continued inside an existing chat never binds. A visible turn is a node whose `message` is non-null, whose `author.role` is `user` or `assistant`, whose `content.content_type` is `text` or `multimodal_text`, and whose `metadata.is_visually_hidden_from_conversation` is not `true`. Everything else on the walk is ignored: the null-message root, `system` nodes, and hidden context nodes such as `user_editable_context`. The predicate is tested against the full sanitized `mapping` captured in E19 (12 nodes, root included), which must return `SAVED` unmodified. That capture had no system or hidden node, so the harness also runs a variant with a hidden `user_editable_context` node inserted above the user message, which must still bind.

  A failed check returns `ERR binding`, and a non-string element of `parts` returns `ERR schema`. On success it builds one object with exactly these fields, `{tag, id, user_message_id, assistant_message_id, role, content_type, status, end_turn, model, attachment, text}`, and downloads `JSON.stringify` of it as `uora-<tag>.json`. It never revokes the Blob object URL synchronously after the click, and r1 records that the download settled after `tabs_close_mcp`. `text` is the `parts` array (all strings) joined with the empty string `''`. The Blob holds exactly `new TextEncoder().encode(JSON.stringify(obj))`. `<bytes>` is that array's length (UTF-8 bytes, never `.length` of the string), and `<sha256>` is SHA-256 over exactly those bytes. It then returns `SAVED <bytes> <sha256>`. The harness and adapter fixtures include CJK and non-BMP answer text.
- **J-archive:** repeats J-get's fresh-conversation and attachment checks (returning `ERR binding` and archiving nothing if either fails), then sends `PATCH {"is_archived": true}`, returning `ARCHIVED` or `ERR archive <code>`.

### 6. Result acceptance and publication

**Finding the file.** The candidate download dirs are:
- the `download.default_directory` from every `~/Library/Application Support/Google/Chrome/*/Preferences`
- `~/Downloads`

keep-simple(UPGRADE: read the `com.google.Chrome` managed-preferences `DownloadDirectory` if a policy-managed host is ever the consult host): no managed-policy lookup in v1, since the operator's Mac has no such policy (checked 2026-11-03: no `/Library/Managed Preferences/<user>` dir, and `defaults read com.google.Chrome DownloadDirectory` finds no key) and its download dir (E8, E19) is already a candidate.

Because the tag is random, a regular file named exactly `uora-<tag>.json` in any of those dirs is ours, so the parent never needs to know which profile the extension drives. After `SAVED`, the parent polls once a second, for up to 30 s within the deadline, until the file has settled: it exists, is not a symlink, has no `.crdownload` sibling, and its size equals the `SAVED` byte count. A `uora-<tag>.json` with no `SAVED` line in the stream, as when the child died between the download and `SAVED`, is never accepted, and cleanup deletes it.

A ` (1)` file is a candidate like any other. It is accepted only if it matches a `SAVED` line by size and hash.

**Checks.** The parent moves the file into the run dir and checks every one of these:
- The byte count and SHA-256 equal J-get's `SAVED` line, which the parent reads from the stream's `tool_result` paired by `tool_use_id`.
- The JSON parses into exactly the §5 schema.
- `tag` equals this run's tag.
- `role`, `content_type`, `status`, `end_turn`, `model` and `attachment` satisfy the §5 binding rules.
- `id` equals the recorded `UORA_ID`.
- `_ultra_oracle_verdict_ok` passes on `<out>.tmp`, which holds `.text` extracted with `jq -j`, so no trailing newline is added. The function takes a file path.

The binding fields come from the page through the fixed J-get. This re-check protects against a truncated, stale or substituted file. It does not protect against ChatGPT itself.

**Publication.** If every check passes, the parent renames `<out>.tmp` to `<out>` atomically. It writes `.err` and `.hint`, if any, and only then writes `.rc`. Stale `<out>`, `.err`, `.rc` and `.hint` files are cleared at start, as today.

**Reasons.** Every non-`ok` outcome writes one stable reason to `.err` and one operator sentence to `$out.hint`, which is what the existing banners show (`scripts/ultra-oracle-run.sh:94-104`, `run-design-review-loop.sh:1596-1621`). `$out.dispatch.err` keeps the mutex-recovery line.

| Reason | Status (rc) | `$out.hint` says |
|---|---|---|
| bad arguments, a cap under the 120 s floor (new for this transport, so the 60 s browser cutoff always leaves browser time), or staging input (symlink, unreadable, over 10 MB) | `error` (1) | names the bad argument or file |
| `skip-ultra-oracle.local` present | `skipped:user` (0) | — (unchanged) |
| background launch succeeded | `dispatched` (0) | — (the outcome arrives through `.rc`) |
| `claude-unavailable`: `claude` missing, capability probe failed, `/usr/bin/jq` missing, auth/usage/rate failure before setup | `skipped:unavailable` (3) | Claude Code is missing, too old, or not signed in. A missing jq has its own sentence: the browser guard needs `/usr/bin/jq` |
| `extension-not-connected`, including a failed Chrome reopen (§2) | blocking: `skipped:unavailable` (3); background: `.rc` `1` (the token was already `dispatched`) | Open a Chrome window, reconnect Claude in Chrome, and re-run the consult |
| `not-macos` | `skipped:unavailable` (3) | The Chrome transport runs only on the operator's Mac |
| `claude-unavailable` discovered after a background dispatch (auth, usage or rate failure of the child) | `.rc` `1` | Same sentence as the pre-dispatch row |
| `pro-unavailable` (J-home `ERR pro`) | `error` (1) | ChatGPT is not set to Pro; select Pro once in Chrome |
| `upload` (J-attached `ERR upload`; a `no-ref` deny; or a `submitting` exit with no J-send `tool_use`, §2) | `error` (1) | The prompt attachment could not be uploaded. When the paired `file_upload` result read `Uploaded …`, the hint adds: a draft with the attachment may remain in the consult tab. When no ref was found, it adds that ChatGPT's UI must be in English (§10) |
| `send` (J-send `ERR origin`, `ERR not-home`, `ERR focus` or `ERR send`; the upload happened but nothing was sent) | `error` (1) | The composer could not send the prompt; a draft with the attachment may remain in the consult tab |
| `tab-cleanup` (appended, any status) | unchanged | A consult tab could not be closed; names the tab ids |
| `gone` (HTTP 404) | `error` (1) | The consult conversation no longer exists |
| `submit-uncertain` | `error` (1) | A send may have happened; check ChatGPT for an unarchived consult chat before retrying |
| `child-died`: the child exited before an answer was captured, with no structured reason (§2) | `error` (1) | The browser child exited before an answer was captured; re-run the consult |
| `binding`, `schema`, `origin`, `not-home` | `error` (1) | ChatGPT's page or answer did not match this consult (wrong model, attachment or page). For `not-home`, the hint adds that the consult needs ChatGPT's UI in English (`Attach files`, `Send`, `Remove <name>`; §10) |
| `fetch-timeout` (`ERR timeout`), `network` (`ERR network`). The reason token `timeout` is not used here, so it never collides with the `timeout` status below | `error` (1) | ChatGPT could not be reached from the page |
| `auth`, `rate`, `server` | `error` (1) | ChatGPT returned HTTP `<code>` |
| `guard-denied`, `audit` | `error` (1) | The browser child attempted an action outside its fixed steps |
| `download-missing`, `hash-mismatch` | `error` (1) | The answer download was not found or did not match (names the dirs searched) |
| `verdict-floor` | `error` (1) | The answer was empty or below the verdict floor |
| browser cutoff reached (a mutex wait past it, or the child terminated there, §4 precedence) | `timeout` (124) | No answer within the cap; generation on ChatGPT's server is not cancelled |
| `archive` (appended after `ok`) | `ok` (0) | The consult chat could not be archived |

When a run fails after a `UORA_ID` was recorded, the hint also names that conversation id: the consult chat is left unarchived in ChatGPT and may still finish there. The operator re-runs the consult. Nothing retries automatically.

Appended notices (`archive`, `tab-cleanup`, the legacy-keys notice) must reach the operator on `ok` too. Today the success branches drop `.hint`: `ultra-oracle-run.sh:95` prints only `VERDICT` and the answer, and the blueprint-review advisory's success branch reads `.hint` only on failure (`run-design-review-loop.sh:1606`). Both, and every other wrapper's success branch, print a non-empty `.hint` as one `NOTE:` line after the verdict. A test asserts this for each wrapper.

On `timeout` the child's process group is terminated (§4), and a later run never picks up that answer.

### 7. Status mapping

The table in §6 is the consult's whole mapping. `skipped:disabled` comes from the wrappers and is unchanged. The skip file, argument and staging validation, the platform check, and the `claude` binary and capability probe all run synchronously before `dispatched`, and return their token directly. Two things are discovered only after a background dispatch, which is why their rows differ by mode:
- the extension's connection. Plan step 1 captures a fixture from a live run with the extension disconnected: the stream record that carries `extension-not-connected` (E10), whether that is a chrome `tool_result` text or the final `result` record, whichever is observed. The classifier matches only that fixture.
- a child's auth, usage or rate failure. The child's final stream-json `result` record reports it before any chrome call. Its exact shape is captured as a fixture from a real signed-out run in plan step 1, and the classifier matches that fixture.

A `setup` exit that matches neither fixture stays `child-died`. After the launch, background mode reports through `.rc` (`0`, `1` or `124`). A run only ends `skipped:unavailable` before the phase reaches `submitting`. Once it is past that point, every failure is `error`, or `timeout` if the browser cutoff ended it (§4 precedence).

### 8. USER config format (`~/.claude/busdriver.json`)

The `ultraOracle` namespace stays. It holds only these keys:

```jsonc
"ultraOracle": {
  "timeoutCapSeconds": 1800,            // optional, default 900, ceiling 3600
  "brainstorming":   { "enabled": true },
  "blueprintReview": { "enabled": true },
  "council":         { "enabled": true },
  "writingPlans":    { "enabled": true }
}
```

The removed keys are `model`, `browserModelStrategy`, `chromeProfileDir`, `cookiePath`, `remoteHost`, `remoteToken`, `hideWindow`, `attachRunning` and `attachProfileDir`. No getter reads them. A single function, `_ultra_oracle_legacy_keys_notice`, lists the object's key names with `jq -r '(.ultraOracle // {}) | if type == "object" then keys[] else empty end'`. A missing config file counts as no keys. It writes a one-line notice naming any removed key still present. The notice goes to stderr and is also appended to `$out.hint`, since the witness wrapper discards the consult's stderr (`ultra-oracle-run.sh:72`), because silently ignoring `remoteHost` could leave an operator believing remote execution still works. It never reads their values, so `remoteToken` is never touched. Pro is not configurable: it is the operator's sticky selection, which J-home checks before the upload and J-get verifies from `model_slug`. The child never selects a model.

### 9. Deletions

- **Adapter:**
  - the oracle argv and invocation
  - `_ultra_oracle_salvage`, `_ultra_oracle_hung_signal`, `_uora_status_snapshot`, `_ultra_oracle_tab_ref` and `_ultra_oracle_extract_sid`
  - the oracle heuristics in `_ultra_oracle_run_watched`
  - the oracle hints inside `_ultra_oracle_diagnose_hint`, which are replaced by the §6 hint sentences (the function stays)
  - the inline-bytes cap, the attach and remoteHost lock-key branches, and the remote-token plumbing
  - the `ULTRA_ORACLE_TEST_NO_LOCK` test hook (`:1064`); the mutex is mandatory for this transport (§1)
- **Script:** `scripts/ultra-oracle-attach-preflight.sh`. The `LAUNCH_WAIT_SECONDS` term goes out of the timeout formulas in `skills/council/SKILL.md`, `skills/brainstorming/SKILL.md` and `skills/blueprint-review/SKILL.md`, with no replacement term: setup sits inside the cap (§2), and the caller contract is cap + 90 s, anchored at consult start. ADR 0030 (decision 5, `cap + 90 + LAUNCH_WAIT_SECONDS`) and ADR 0027 (`:218`) each get a 4.0.0 amendment note stating that formula.
- **Strings:** the stale-lock line's `pgrep -fl oracle` (`ultra-oracle.sh:776`, rewritten per §1), and the `absent -- oracle CLI not available` banner at `run-design-review-loop.sh:1642`. The banner is replaced by the §6 hint, and its banner tests are retargeted.
- **Config getters:** the getters for the removed keys. `docs/examples/busdriver.json` is rewritten to the §8 format.
- **Docs:** every reference to installing or configuring `oracle`: the skills (ultraoracle, council, brainstorming, writing-plans, blueprint-review, orchestrator), the commands, the README and `.claude/CLAUDE.md`. ADR 0020 and ADR 0029 are marked superseded, and ADR 0007 is amended.
- **Tests:** the suites that only test oracle — the attach preflight and the hung, salvage and submit-watchdog behavior.

### 10. Host coverage

| Host | Surfaces | Result |
|---|---|---|
| Mac with Chrome and the extension connected | all | full consult |
| Mac, Chrome with no window, or closed | all | the pre-launch `open -a` (§2) opens a window, then a full consult (r4) |
| Mac, the child's tab close leaves Chrome with no window (E10) | all | that consult is already `ok`. The next consult's pre-launch `open -a` opens a new window. Each child's bootstrap tab lives in its own new group (E17), so closing it removes only that group, and the operator's own windows are untouched. Only when Chrome had no window before the consult does the close leave none. |
| Mac, ChatGPT UI language not English | all | `error`. The snippets and the pinned `find` match English labels (`Attach files`, `Send`, `Remove <name>`), so another language fails at J-home, `find` or J-attached. The hint names those labels. English UI is a precondition (§12). |
| um (Linux, headless) | all | `skipped:unavailable` (`not-macos`), the same as oracle's attach mode, which was Mac-only. Every caller already handles it. The oracle `remoteHost` route could consult from um. Withdrawing it is accepted: the operator does not use it, and the Mac remains the consult host. |

### 11. Testing

- **Fixtures come from real runs, re-captured in plan step 1.** The 2026-11-02 spike logs and the E19 download were in temporary locations and no longer exist, so the r1 qualification runs capture them again. Fixtures go straight into the repo's fixture dir after sanitizing. They are sanitized stream-json recordings, answer files, an E7 node, the full root-included conversation `mapping` (E19) and the recorded `find` result (E13) from live consults are the fixture base, so the parser is tested against what the producer actually emits. A fake `claude` on `PATH` replays them and drops the matching download file.
- **Snippet harness (vitest).** The seven snippet files run against a mocked `fetch`, `location`, `document` and anchor download. A `fetch`, `crypto.subtle.digest` or anchor click that throws must still yield a result matching the §5 grammar. It covers:
  - an intermediate assistant `text` node and a wrong attachment ancestry
  - a malformed tree and non-string `parts`
  - the full live `mapping` fixture binding unmodified, and the same fixture with an extra visible user turn → `ERR binding`, with a hidden `user_editable_context` node → still binds
  - each HTTP class, including 400, 408 and 422, and an origin mismatch
  - J-send: no composer, focus not taken, inserted text not equal to the sentence, no or a disabled `Send` button in the form, a `Send` button outside the form only → the matching `ERR`; a wrong origin → `ERR origin` and a wrong pathname → `ERR not-home`, each with zero focus, insert or click calls; the happy path clicks only the in-form button
  - the `AbortController` budget
  - J-poll returning `DONE` on a terminal but unbound turn
- **Adapter cases (fake `claude`):**
  - success
  - non-Pro `model_slug` and wrong attachment tag, both finishing as `error binding` well before the deadline
  - a final node without `end_turn`
  - a wrong conversation id
  - an envelope with missing or malformed fields
  - hash mismatch and missing download
  - download settling: a late `.crdownload` rename, a file that never settles, a non-default profile's custom directory
  - a stream that ends right after the J-send `tool_use` → exactly one child invocation and `error submit-uncertain`
  - a stream that ends after `file_upload` with no J-send → exactly one child, `error upload`, and the hint names the possible draft
  - a defensive fake stream: a `file_upload` `tool_result` reading `Uploaded …` while `phase` still reads `setup` → the parent classifies the exit as `submitting` from the stream, `error upload`
  - the measured E16 case: the guard times out on `file_upload` → a permission refusal, `phase` stays `setup`, and no upload
  - J-send `ERR focus` and `ERR send` → `error send`
  - a `find` result with zero or two `Attach files` lines → no ref recorded, `file_upload` denied `no-ref`, `error upload` (not `guard-denied`)
  - a crashed child that left its tab → the run's `.hint` names the tab under `tab-cleanup`
  - a queued run with a fake clock → the mutex wait counts once against the deadline, and a wait past the browser cutoff ends `timeout` with no child
  - the adapter suite runs with `_ULTRA_ORACLE_PLATFORM` and `_ULTRA_ORACLE_OPEN_CMD` reassigned after sourcing, on Linux; an exported variable of either name changes nothing
  - blocking and background cleanup leave `run-<tag>/` holding only `record.json`, removed later by the age sweep
  - every consult runs `_ULTRA_ORACLE_OPEN_CMD` exactly once, after the mutex and before the launch, and launches exactly one child whatever the outcome; a failing open command → `extension-not-connected` with no child
  - a `forbidden` deny before `SAVED` → `error guard-denied`, never `ok`
  - a continued existing conversation → `ERR binding`, and nothing archived
  - J-home `ERR not-home` or `ERR pro` → `error`, and no `file_upload` in the stream
  - `find` or `file_upload` before J-home `READY` → denied; any `computer` action, `read_page`, a second `find` or a `find` with another query → denied
  - J-attached `ERR upload` → `error upload`; J-attached `PENDING` until the browser cutoff with no J-send `tool_use` → `timeout` 124; a child that stops after the upload with time remaining and no J-send `tool_use` → `error upload`
  - the browser cutoff during J-poll `PENDING` after `UORA_ID` → blocking `timeout` 124 and background `.rc` `124`, each with the conversation id in the hint; the same child exiting on its own with time remaining → `error child-died`
  - a premature `file_upload` before `READY`, denied `not-yet`, then reissued after `READY` → allowed once, `ok`
  - a `file_upload` with a foreign path, denied `forbidden` → `phase` stays `setup`, `error guard-denied`, not `submit-uncertain`
  - J-home and `find` batched in one assistant message: the stream emits both `tool_use` blocks before either result, while the decision log shows J-home allowed, `find` denied `not-yet`, then `find` reissued and allowed → the audit is clean and the consult ends `ok`
  - a stream `tool_use` whose `tool_use_id` has no decision-log line, and an executed call logged as denied → `error audit`
  - `find` and `file_upload` batched in one message: `file_upload` is denied `not-yet` and reissued after `find`'s record → `ok`
  - a `file_upload` `tool_use` with no result whose decision-log line is a deny → the exit stays at `setup`, `error child-died`
  - a fake child that exits 0 while a hook descendant is still running → the parent kills the group before the post-exit pass, the publisher's pid is still alive after the group KILL, and `.rc` is written afterwards, in both modes; the caller's shell has monitor mode off after a blocking consult; a hook outside the group that writes after `guard.json` was renamed → nothing is written; a torn last log line → `error audit`
  - a stream ending in `post-lost` → `error audit`
  - in phase `submitted`, exit 0 right after `UORA_ID` and exit 0 after `DONE` → `error child-died`, the hint names the conversation id, nothing is archived, and no second child runs
  - a lock dir stranded by a killed hook → later calls denied `busy`, and the run never ends `ok`
  - staging a FIFO, `/dev/zero`, a combined set over 10 MB, a file that grows during staging, and a NUL-containing context → `error`, none of them blocking
  - an exported `PATH` shim or `CLAUDE_CODE_SAFE_MODE=1` in the caller's environment → the child still runs the guard (env -i allowlist)
  - a chrome call while the guard exits 0 with no output → not run (nothing is pre-approved)
  - background child auth failure after `dispatched` → `.rc` `1`, `claude-unavailable`
  - a cap under 120 s → `error`
  - a `busy` denial, a `not-yet` denial and a stream cut off after `SAVED` (an allowed J-archive with no result) → none is an audit violation
  - `SAVED` followed by a `forbidden` deny → `error guard-denied`; `SAVED` followed by an unlogged `tool_use`, or by an executed call with no allow → `error audit`
  - `busy` and `post-lost` lines land in separate `oob/` files under concurrent appends, the merged audit input parses, and no line is torn
  - J-archive against a conversation with a wrong attachment tag → no PATCH sent
  - `ERR timeout` and `ERR network` during `PENDING` → `error fetch-timeout` and `error network`, with the conversation id in the hint; an unlisted `ERR` code → terminal `error`
  - `extension-not-connected` in background mode → `.rc` `1` with the reconnect hint
  - the skip file present → `skipped:user` with rc 0
  - the browser cutoff at deadline minus 60 s, and publication finishing inside the reserve
  - a child that dies between the download and `SAVED` → the file is never accepted, cleanup deletes it, and the run ends `error`
  - an unwritable lock dir → `error`, never an unlocked run
  - disconnect at `setup`, replayed from the captured disconnect fixture (§7) → blocking: `skipped:unavailable`; background: stdout stays `dispatched`, `.rc` `1` and the reconnect hint; each with exactly one child launched;
  - a hanging fake open command → `timeout` 124, the mutex released and no child; a hanging fake `claude --help` → `skipped:unavailable`; both in both modes
  - `SAVED` followed by a missing file, by a hash mismatch, or by a verdict-floor failure → `error` with that reason, with and without a cutoff termination; a `setup` exit that matches neither the disconnect nor the auth fixture → `error child-died`
  - archive failure after a clean `SAVED` → `ok`, with `.err` and `.hint` written before `.rc`
  - the browser cutoff kills the child during J-archive after a clean `SAVED` → `ok`
  - a stale `<out>` from an earlier run is never mistaken for success
  - two concurrent consults → the `chrome-extension` mutex orders them, and the queued run respects its deadline
  - the mutex key is non-empty on the default path
  - cleanup on every exit path, and the start-of-consult sweep, including an interrupted `uora-<tag>.json.crdownload` that survives until the next consult's sweep
  - staging: duplicate basenames and a prompt file with no trailing newline
- **Guard unit tests** feed hook-shaped JSON to `guard.sh` and assert allow or deny for every row of the §4 table. They run `guard.sh` under `/bin/bash` where it is 3.2, and a static check fails if `guard.sh` contains any construct outside the §4 bash 3.2 floor. They also cover:
  - other-tab JS and the close of any tab other than the own tab
  - a second `tabs_context_mcp`, one without `createIfEmpty: true`, and any `tabs_create_mcp`
  - J-send without `attached`, J-archive without `saved`, and a second J-get or J-archive
  - the registered exec-form argv run under `SHELLOPTS=noexec` and with `guard.sh` missing → the call is blocked (exit 2); the same argv for a legal call → explicit allow (exit 0 plus allow JSON)
  - `UORA_RUN_DIR` missing, relative, or pointing at a dir without a 0600 `guard.json` → denied
  - a `javascript_tool` `text` that is not one of the seven opcodes, including the snippet's own source text → denied; each opcode → allowed with `updatedInput` carrying exactly the rendered snippet
  - the recorder fed the captured E15 and E18 PostToolUse payloads → tab id, ref and flags recorded; a token with surrounding text → not recorded
  - a tab-scoped call before a tab id is recorded
  - any `computer` action or `read_page`, in every phase
  - J-home with a non-Pro model label, and J-attached with no chip, a failed chip, and a finished chip (harness)
  - J-send before `ATTACHED`, a second J-send, and J-id/J-poll before `sent`
  - `file_upload` with a ref other than the recorded one
  - a foreign JS text, a foreign upload path, a Read call and a foreign tool
  - replay mode leaves `run-<tag>/phase` and `guard-state.json` byte-identical
  - an unparseable payload or state file
  - a guard crash → the registered command blocks
  - a missing or crashing PostToolUse half → no tab id, and later tab-scoped calls are denied
  - parallel calls racing the once-only counters, and a pre-existing lock dir → denied `busy` within milliseconds
  - each deny carries exactly one reason from the closed set (`busy`, `not-yet`, `no-ref`, `forbidden`), and a `not-yet` deny leaves the once-only counter unspent
  - J-send's PostToolUse overlapping another hook that holds `guard.lock` → `sent` is still recorded, and the following J-id is allowed
  - a forced interleaving of `READY`'s PostToolUse and a concurrent `find` PreToolUse → the log order matches the state order, and replay is clean
  - a failed log append → PreToolUse denies, and PostToolUse records nothing
  - a hook that takes the lock after `guard.json` was renamed away → denies and writes nothing
  - the recorder on `SAVED 1234 <64 hex>` → `saved` latches; on `SAVED`, `SAVED 12` or a 63-hex hash → nothing
  - a tab-scoped call before the own tab id is recorded → `not-yet`
  - J-home batched with `navigate` → J-home denied `not-yet` until `navigated`, then allowed
  - `file_upload` with no recorded `find` count → `not-yet`; with count `0` or `many` → `no-ref`
  - a crashed lock holder at t=0 and one waiter with an equal cap → the waiter's `dispatch.err` holds the recovery line
  - an `ok` result with an `archive`, `tab-cleanup` or legacy-keys notice → every wrapper prints the `NOTE:` line
  - the run dir is created under `$HOME/.cache/busdriver/ultra-oracle/`, never inside the repository
  - every PreToolUse decision and PostToolUse record, `busy` included, appends exactly one decision-log line holding the payload's `tool_use_id`
  - the guard resolves `jq` only as `/usr/bin/jq`; with a `jq` shim first on the caller's `PATH`, the shim never runs
- **Retargeted:** the existing adapter-contract suites (status tokens, background `.rc`, lock, config, advisory, deadline, council, brainstorming wrapper, retrieval-loop contract) move from the fake `oracle` to the fake `claude`. The advisory tests assert the new hint sentences.
- **Sweep test:** nothing under `scripts/`, `skills/`, `commands/`, `hooks/` or `docs/examples/`, and nothing in `README.md` or `.claude/CLAUDE.md`, invokes the `oracle` CLI, calls `is_cli_available oracle`, contains `pgrep -fl oracle` or `oracle CLI not available`, or reads a removed key. The one named exception is `_ultra_oracle_legacy_keys_notice`, which lists key names only. A second check covers the docs. Under `docs/adr` and `docs/examples`, `LAUNCH_WAIT_SECONDS` may appear only in 0027 and 0030, the two ADRs that carry the 4.0.0 amendment note (`git grep` finds no other). `docs/plans` is exempt as history.
- **Gate-integrity:** `scripts/hooks/ultra-oracle-child/` is pinned by the lock.
- Full shell suite, vitest, `npm run validate`, gate-integrity, version check.
- **Live smoke from the real busdriver environment**, real ChatGPT Pro, each run returning `ok`, a Pro `model_slug` and an archived chat:
  - `/ultraoracle` quick consult
  - ultra-council witness, background
  - ultimate-council witness
  - brainstorming wrapper, blocking
  - writing-plans advisory
  - blueprint-review advisory dispatch
  - retrieval loop, both rounds
  - one forced tab-close during `PENDING` → `error` with the conversation id in the hint, and exactly one child

### 12. Operator steps after release

1. Rewrite the `ultraOracle` block in `~/.claude/busdriver.json` to the §8 format. `remoteToken` is a secret, so delete it rather than leaving it.
2. `brew uninstall steipete/tap/oracle`. Optionally remove `~/.oracle` and `~/Library/Application Support/oracle-attach`.
3. Keep the Claude-in-Chrome extension connected, and keep Chrome's download prompt off.
4. Keep ChatGPT's UI language set to English (§10).
5. The transport requires macOS 15 or later, for Apple's bundled `/usr/bin/jq`. On an older Mac, the `[ -x /usr/bin/jq ]` probe fails closed to `skipped:unavailable` (§6).

## Alternatives rejected

- **OpenAI Responses API.** Its background jobs and polling primitives are a better fit, but the operator's requirement is the ChatGPT Pro web subscription, not API billing.
- **Manual paste and import.** No unattended background run. It remains the documented emergency fallback: stage the prompt file and the operator attaches it by hand.
- **Chunked base64 through JS results.** Roughly 40 calls for a 32 KB answer, and the answer passes through the child's context. Superseded by the download path.
- **Rendering the conversation id into the initial child's snippets.** The id does not exist until after the send, and the child cannot fetch a re-rendered snippet. Reading it from `location.pathname` and binding it in the parent removes the problem.
- **Letting Read execute for the upload.** It would put the prompt bytes into the child's context. Spike d must show it is unnecessary.
- **Automatic recovery in v1**, meaning a setup retry and recovery children that resume a submitted consult by its conversation id. Design-review rounds 9 and 10 kept finding races in the state the children shared. v1 has one child, and the operator re-runs after a failure. Revisit if real use shows dropped consults are common. Recovery would then come back as its own design, with the fencing between children reviewed on its own.

## Out of scope

- Renaming the UltraOracle surface, its scripts or its namespace.
- Consults on hosts without the Chrome extension.
- Cancelling server-side generation after a timeout.
- Deleting consult chats. They are archived, not deleted.
