# ADR 0045 — No positional narrowing in the torn-assignment any-position recovery

**Status:** Accepted
**Date:** 2026-08-24
**Issue:** #589

## Context

`gitcmd_detect._shell_payloads` walks a segment conservatively to find the
command word. Python's `shlex` does not know a `$(` substitution is open, so an
assignment whose value contains whitespace **tears**:

```
X=$(printf x y) bash -c 'git commit -m x'
  -> ['X=$(printf', 'x', 'y)', 'bash', '-c', 'git commit -m x']
```

The walk stops on the debris token `x` and never reaches `bash`, though bash
runs the commit. An **any-position fallback scan** exists for exactly this: when
the walk cannot have read a command word, every token is examined and an
interpreter is recognised wherever it sits. Position is not consulted, by
design — the debris is what destroyed position.

#589 reported a false positive in that scan. A glob-shaped token (`*`, `?`, `[`)
that fails `fnmatch` against `_INTERPRETERS` was promoted to the `sh` stand-in
anyway, so a command that only prints was reported as committing:

```
X=$(printf x y) printf '%s' '*.py' -c 'git commit -m x'   # prints; reported True
```

The first three attempts at this branch fixed it **positionally**: derive
`command_index = len(toks) - len(argv)` and let only that index name an
interpreter. A lead review (Codex) then filed a HIGH asking for that narrowing
to be applied harder — operands after the command word should never be
interpreters, with reproducer:

```
X=$(printf x y) printf '%s' bash -c 'git commit -m x'     # prints; reported True
```

This ADR records why the positional family is rejected in full, what is accepted
instead, and the condition under which the accepted cost may be retired.

## Decision

**The any-position recovery does not narrow by command-word position. Ever.**

The only narrowing #589 justifies is on **resolution**: a glob-shaped word that
matches no interpreter is not the `sh` stand-in. `_fallback_interpreter_name`
is that rule and nothing more:

```python
def _fallback_interpreter_name(tok, raw=None):
    name = _interpreter_name(tok)
    word = _norm_cmd_word(tok)
    if name is None:
        return name
    if not _quoted_literal(raw):
        # Unquoted `./*.py` really globs and reaches a shell when expansion catches one.
        return name
    if word in _INTERPRETERS:
        # A literal interpreter name is not a glob.
        return name
    if not re.search(r'[*?]', word):
        # Only `*` and `?` are where fnmatch and bash agree.
        return name
    if re.search(r'[\[$`{(\\]', tok):
        # fnmatch has no POSIX bracket classes; `$`, backtick, brace, paren, and
        # backslash all resolve before globbing.
        return name
    if any(fnmatch.fnmatchcase(i.lower(), word.lower()) for i in _INTERPRETERS):
        # A resolving glob still names a shell; `bash -O nocaseglob` expands `/bin/B?SH`.
        return name
    return None
```

**Quote provenance is the load-bearing half**, and it is what the issue itself
prescribed. `shlex` strips quotes, so `tok` alone cannot tell `'*.py'` — data,
on which bash performs no pathname expansion, so it can only name a file
*literally* called `*.py` — from `./*.py`, a real glob that expands to whatever
is on disk. A narrowing keyed on `tok` alone suppressed the unquoted form too,
and `X=$(printf x y) ./*.py -c 'git commit -m x'` runs bash whenever the glob
catches a shell (a `shell.py` symlink is enough). That is a bypass, not an
accepted exclusion. `_raw_tokens` supplies the verbatim spelling aligned 1:1;
an unavailable or unaligned raw stream yields `None`, `_quoted_literal` is then
False, and the narrowing simply does not apply — fail CLOSED.

The remaining guards exist because the rest of the rule rests on **"fnmatch
found nothing, so bash finds nothing."** That premise is narrow, and every place
it fails was found by review rather than by design — four consecutive review
rounds, each a real fail-open:

- **Test resolution, not the returned name.** `name == 'sh'` looks equivalent
  and is not: `_interpreter_name` answers `sh` both for the stand-in it invents
  when a glob reaches nothing *and* for a glob that genuinely resolves to the
  real `sh`. `/bin/?h` fnmatches `sh`, so the name comparison suppressed a shell
  that actually runs — `/bin/?h -c 'git commit -m x'` went undetected. Asking
  whether the returned interpreter still matches the pattern separates them.
  `tests/` now generates a resolving glob form for **every** member of
  `_INTERPRETERS`, so a newly added shell cannot miss coverage.
- **A bracket is excluded from the rule entirely.** For `[`, the premise is
  false by construction — `_interpreter_name` already records that fnmatch has
  no POSIX bracket *classes*, so `/bin/ba[[:alpha:]]h` expands to `/bin/bash`
  for the shell and to nothing here. Suppressing on that non-match converted a
  deliberate `sh` stand-in into a bypass.
- **Case is handled, not excluded.** `bash -O nocaseglob` expands `/bin/B?SH`
  to `/bin/bash` while `fnmatchcase` refuses it — suppressing on *that*
  non-match was the third bypass. The resolution test lowercases both sides, so
  any interpreter the pattern could reach in **any** case blocks the narrowing.
- **Only glob-unreadability qualifies.** `_unreadable_word` is true for `$`,
  a backtick, a brace and a paren as well as `*?[`, so gating on it wholesale
  disables this rule entirely — every glob is unreadable by that test.
  Requiring the *absence* of the others keeps `b$a*sh` a fail-CLOSED stand-in:
  the shell expands `$a` before globbing and may reach `bash`, so it is not a
  glob literal. A backslash is excluded for the same reason. #589 does not
  re-open the unreadable-word hole.

- **The word must be quoted.** Round 4, above — the one that decides whether
  this is an exclusion or a bypass.

The generated sweep in `tests/` covers five glob forms per member of
`_INTERPRETERS` — trailing `?`, trailing `*`, leading `*`, a POSIX bracket
class, and an uppercase `nocaseglob` form — so a newly added shell cannot miss
coverage, and none of the four bypasses above can return silently.

Quote provenance is pinned asymmetrically, and deliberately so: the **unquoted**
glob is pinned fail-CLOSED in *both* command and operand position, while the
**quoted** glob is pinned narrowed only as an **operand**. The quoted glob in
command position is exactly the residual exclusion described under Consequences,
so pinning it would be pinning a fail-open as expected — see the note there on
why that case carries no test. The raw/POSIX alignment boundary that decides
whether provenance is trusted at all is pinned separately, since a `None` raw
stream must narrow nothing.

**The generalisable lesson:** all four were the same mistake — treating a
*negative* static result as proof of absence, when the static matcher is
strictly weaker than the shell. `fnmatch` is weaker than bash's globbing
(bracket classes, `nocaseglob`), and a quote-stripped token is weaker than the
raw spelling (it cannot see that the glob was never a glob). Any future
narrowing here must ask what the shell can reach that the scan cannot, and
**refuse** rather than model it.

The reviewer's reproducer stays **DETECTED**, recorded as an accepted cost.

## Alternatives considered

### A. Narrow to `command_index` (what the HIGH prescribed) — REJECTED

Measured against the canonical spec (`tests/test-gitcmd-detect.sh`, 1,808
checks): **10 failures.** Six are `torn-nested+` rows the suite annotates
*"verified to execute the commit inside the child"*:

```
X=$((1 + 2)) bash -c "git commit -m x"
X=${foo:-a b} bash -c "git commit -m x"
X=$(printf x y) bash -c "git commit -m x"
X=<(printf x y) bash -c "git commit -m x"
env A-B=$((1 + 2)) bash -c "git commit -m x"
env -u x X=$(printf x y) bash -c "git commit -m x"
```

plus the two `(accepted)` rows and two `eval` rows. The index is only
trustworthy when the walk **read** a command word — and this branch is reached
precisely when it did not. Narrowing to it means trusting a token the tear
already invalidated. Six fail-opens in three fail-CLOSED gates is not a
precision win.

### B. Narrow to `command_index` only when the segment is not torn — REJECTED

Shipped briefly on this branch as `if not torn: return None`. It has no
counterpart on main, and it is also fail-open — verified against `origin/main`:

| command | main | with B |
|---|---|---|
| `./+ bash -c 'git commit -m x'` | DETECTED | **not detected** |
| `+ bash -c 'git commit -m x'` | DETECTED | **not detected** |

`./+` is unreadable as a command word, which is *why* the scan runs; if it is a
dispatcher (`exec "$@"`) the commit runs. B suppressed the interpreter behind
exactly the command word nothing can vouch for.

B was not required by #589. It existed to satisfy one assertion added by this
branch's own commit `980ab1e3` —
`env -i printf '%s' g$'++' '$x' -c 'git commit -m x'` asserted `False` — which is
out of #589's scope (an unreadable-word operand, not a glob) and asserted a
value `origin/main` does not produce, in the fail-open direction. **Both the
assertion and B were removed.**

### C. Rebuild the `$(` span — REJECTED, previously reverted

Deciding where the substitution closes is the only sound way to separate the two
reproducers. This file already implemented and reverted that scanner after five
verified bypasses; the boundary is forgeable through a quoted closer:

```
X=$(printf ")" x) bash -c '<s>'
```

A forged closer moves the apparent command word **earlier**, so more tokens look
like operands and get suppressed — the failure direction is fail-open, which is
what makes it worse than the over-block it would remove.

### D. "Promote only the first readable-name token after the walk's landing" — REJECTED

Fails on `X=$(printf x y z) bash -c 'git commit'`: the debris token `y` is itself
a readable name, so `bash` is never reached. Fail-open.

### E. Special-case `printf`/`echo` — REJECTED

Starts an executable-semantics table; the next user-written dispatcher defeats
it. This is the per-case table #587 exists to stop building.

## Consequences

### Accepted cost

```
X=$(printf x y) printf '%s' bash -c 'git commit -m x'   -> DETECTED
```

`bash` is a printf argument; nothing commits. After a tear this is
token-for-token indistinguishable from `X=$(printf x y) bash -c '<s>'`, which
does commit. It is **pre-existing on `origin/main`**, not introduced by this
branch, and it costs a visible stall, never a bypass. Prior measurement of this
class: against 29,563 recorded agent commands, 361 (1.22%) yield an extra
payload, commands that would newly trip a fail-closed gate = **zero**, advisory
prompt rate unchanged (27/1,200 before and after).

Pinned as `torn-nested~ (accepted-current)` in `tests/test-gitcmd-detect.sh`.

### Accepted threat-model exclusion

The narrowing applies to a **quoted** glob wherever it sits, command position
included:

```
X=$(printf x y) './*.py' -c 'git commit -m x'   -> not detected (main: DETECTED)
```

Quoted, bash does no pathname expansion, so this can only run if a file
**literally named** `*.py` exists and is an executable shell. That is the whole
of the residual, and it is the narrowest form the exclusion takes — an earlier
draft suppressed the unquoted `./*.py` as well, which was a genuine bypass
(review round 4) rather than this exclusion. Recorded here rather than silently
absorbed.

Unquoted globs are untouched and stay fail-CLOSED, and a quoted glob that
`fnmatch`es a real interpreter (`'./b*sh'`, `/bin/ba?h`) still resolves and is
still promoted.

**The exclusion covers re-expansion by another program, not only an on-disk
`*.py` file.** Quote provenance proves the *current* shell will not expand the
word; it cannot prove nothing downstream will. A dispatcher that re-expands its
arguments unquoted —

```sh
# ./+  contains:  exec $1 "$2" "$3"
X=$(printf x y) ./+ '*.py' -c 'git commit -m x'    # runs bash if shell.py -> /bin/bash
```

— reaches a shell through a word this scan suppressed. **This is not separately
fixable, and the check that proves it is one line:** `./+` is
indistinguishable from `printf` here. Both normalise to a readable, non-glob,
non-interpreter word and both return `None` from `_interpreter_name`:

```
'./+'    norm='+'       unreadable=False  interp=None
'printf' norm='printf'  unreadable=False  interp=None
'x'      norm='x'       unreadable=False  interp=None
'y)'     norm='y)'      unreadable=False  interp=None
```

So any rule that detects the dispatcher shape also detects
`X=$(printf x y) printf '%s' '*.py' -c 'git commit -m x'` — issue #589's own
reproducer, the false positive this ADR exists to remove. Requiring both is
requiring #589 to be unfixable by any static narrowing.

**The exclusion is unbounded, and bash's own hash table proves it.** No file and
no dispatcher is even required:

```sh
hash -p /bin/bash '*.py'
X=$(printf x y) '*.py' -c 'git commit -m x'        # runs the commit
```

`hash -p` maps an arbitrary command *name* straight to an executable, so any
token whatsoever can be made to name bash. The same two lines work with
`printf`, with `x`, with any word this scan reads and declines to promote.

That is the general form of the residual, and it is why no further narrowing
helps: **"could this token be a shell?" has no static answer** once out-of-band
state (an on-disk name, a re-expanding wrapper, a hash-table entry, an alias, a
function, `PATH` order) is admitted as in scope. Admitting it does not make the
scan safer — it makes every exclusion illegal, including the one issue #589
asked for, so the only reachable behaviour would be the false positive #589 was
filed to remove.

This is the same shape as the finding adjudicated in "Alternatives considered" —
a reviewer describing an accepted, unfixable-without-fail-open cost as a defect.
The scan's contract is over the *text it is given*, and within that text the
narrowing is sound. It is recorded here, deliberately **not** pinned as a test
(pinning a fail-open as expected fossilises it; the fail-CLOSED behaviours are
what the suite pins), and it is what the revisit trigger below points at:
runtime interception is the only boundary that answers this question, because it
observes what actually executes rather than what a name might mean.

### The invariant

> **No positional narrowing after a tear** without a real shell parser or an
> execution broker. The scan's job is to ask whether an interpreter appears at
> all, never where.

A future change may only revisit the accepted cost by satisfying the retirement
condition recorded beside the test: the row may flip to `False` **only** when
every `torn-nested+` row still returns `True` under the same change. Narrowing by
command-word position does not qualify — it fails six of them, measured.

### Revisit trigger

The distinction *is* decidable at **process execution** — intercepting `execve`
of `git`/`gh` under an execution broker, where expansions have already resolved.
That is a different architecture, not a change to this scan. Open a separate
issue if the accepted cost ever becomes load-bearing; do not re-attempt it here.
