# Issue #876 — litmus enrichment cap aborts with EPIPE on large context

## Problem

`skills/litmus/scripts/run-review-loop.sh` runs under `set -euo pipefail`. The
enrichment budget cap truncates the two collected context strings with an
unguarded pipeline (current `origin/main` f67be92, lines 3440-3445):

```bash
if [ -n "$SMART_CONTEXT_OUTPUT" ]; then
  SMART_CONTEXT_OUTPUT=$(echo "$SMART_CONTEXT_OUTPUT" | head -n "$MAX_ENRICHMENT_LINES")
fi
if [ -n "$DOCS_CONTEXT_OUTPUT" ]; then
  DOCS_CONTEXT_OUTPUT=$(echo "$DOCS_CONTEXT_OUTPUT" | head -n "$MAX_ENRICHMENT_LINES")
fi
```

When a value is larger than the pipe buffer (64 KiB on Linux), `head` exits
after its N lines, the still-writing `echo` gets EPIPE (`echo: write error:
Broken pipe`), `pipefail` makes the pipeline non-zero, and `set -e` aborts the
whole review right after "Context: traced N function(s)". No PASS is written
(fail-closed), but a large diff can never be reviewed, deterministically.

## Decision

Replace both pipelines with a here-string, removing the pipe entirely:

```bash
SMART_CONTEXT_OUTPUT=$(head -n "$MAX_ENRICHMENT_LINES" <<<"$SMART_CONTEXT_OUTPUT")
DOCS_CONTEXT_OUTPUT=$(head -n "$MAX_ENRICHMENT_LINES" <<<"$DOCS_CONTEXT_OUTPUT")
```

Why a here-string rather than appending `|| true` (the other option the issue
names, and the shape used at the HISTORY site):

- **Real failures stay fail-closed.** `|| true` swallows every non-zero exit of
  the substitution, so a genuinely failing `head` (missing binary, I/O error)
  would silently yield empty or partial context and the review would proceed on
  less evidence than intended. With a here-string there is no writer that can
  get EPIPE, so the only way the command fails is a real `head` failure — and
  that still aborts under `set -e`, exactly like today.
- **No producer to SIGPIPE.** Bash materialises the here-string itself (a temp
  file, or a pipe pre-filled before `head` starts when the content fits), so an
  early-exiting `head` cannot fail the command.
- **Byte-identical output for normal input.** A here-string appends one newline,
  as `echo` did, and command substitution strips trailing newlines either way.
  (Minor side benefit: a value that is exactly an `echo` option such as `-n` or
  `-e` is no longer swallowed; values that merely start with one were already
  printed correctly.)
- Works on bash 3.2 (macOS `/bin/bash`) as well as 5.x.

The `[ -n ... ]` guards stay as they are. The HISTORY site (`git log ... | head
-n ... || true`, line ~3456) is already guarded and is not touched: there the
producer is an external `git log`, where `|| true` is the established pattern.

## Out of scope

- #878 (watchdog) and #896 (backstop trust) in the same file — not touched.
- Changing the default budget (`LITMUS_MAX_ENRICHMENT_LINES`, default 100) or the
  context collectors themselves.
- Auditing other `echo | head` sites elsewhere in the repo.

## Test plan

New shell test `tests/test-litmus-enrichment-epipe-876.sh`, auto-discovered by
the full-glob `shell-tests-shard` CI job. It uses the existing sandbox
pattern from `tests/test-litmus-mode-transition.sh` / `tests/test-litmus-terminal-status.sh`
(copy the script and libs into a temp git repo, a mock `agy` reviewer whose
binary lives OUTSIDE the sandbox repo, `BUSDRIVER_REVIEW_CLI=agy`,
SAST/markdown/short-circuit disabled), with these differences:

- The sandbox copies of `lib/smart-context.sh` and `lib/docs-context.sh` are
  replaced by stubs that define only `collect_smart_context` /
  `collect_docs_context` (the only functions the runner calls from those two
  libraries). Each prints several thousand numbered lines with a distinct
  prefix per context (`SMARTCTX-000001 ...` / `DOCSCTX-000001 ...`), padded so
  each payload is at least 256 KiB, written without any pipe of their own. The
  test self-checks the payload size (sources the stub and asserts each output is
  more than 4x the 64 KiB pipe buffer and more than 100 lines), so the fixture
  cannot silently shrink below the trigger.
- The mock reviewer records what it was shown, both stdin and argv (as
  `tests/test-litmus-mode-transition.sh` does: CLI resolution may pass the prompt
  as an argument rather than on stdin), and ignores `--version` probes so a
  resolution probe never creates the capture file. Its behaviour (PASS/FAIL
  verdict) is read from a file, because the runner rebuilds its environment.

Cases:

1. **Large context reaches review (regression).** With the default cap (100),
   the run reaches the reviewer: the capture file exists; the captured prompt
   contains `SMARTCTX-000100` and `DOCSCTX-000100` but neither `SMARTCTX-000101`
   nor `DOCSCTX-000101`; and the loop finishes on the reviewer verdict (FAIL
   mock: exit 1 and `terminal_status: "review_findings"` in the state file).
   The red-before-green proof is the missing capture file plus an exit before
   the reviewer — not a `Broken pipe` message, which only appears when SIGPIPE
   is ignored (normally `echo` is killed silently and the pipeline exits 141).
2. **Genuine truncation failure stays fail-closed.** `run-review-loop.sh` puts
   `/usr/bin:/bin` first in `PATH` and re-execs itself under `bash -p`, so a
   `PATH` shim or an exported function cannot reach the cap. Instead, in the
   SANDBOX COPY only, `sed` rewrites the command word of the two cap lines
   (the `SMART_CONTEXT_OUTPUT=$(head -n ...` and `DOCS_CONTEXT_OUTPUT=$(head -n ...`
   assignments) from `head` to the absolute path of an always-failing shim
   (`exit 3`) outside the repo, and the test asserts exactly two lines were
   rewritten. With a PASS-emitting mock reviewer: the script exits non-zero,
   the reviewer is never invoked for review (no capture file), and no PASS is
   recorded (no PASS terminal status / passed marker). This pins that the fix
   does not degrade into `|| true` semantics: an `|| true` variant would reach
   the reviewer and fail this case.

Also run the existing litmus shell tests that drive `run-review-loop.sh`
(`tests/test-litmus-terminal-status.sh`, `tests/test-numeric-validation.sh`)
to confirm no regression.

## Risk

Very low: a two-line change in one place, same output for normal input. The
one behavioural change is the intended one (large context no longer aborts the
review).

<!-- design-review-coverage: FULL 3/3  -->

<!-- design-reviewed: PASS -->
