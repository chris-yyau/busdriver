# pi-read on Antigravity — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use busdriver:subagent-driven-development (recommended) or busdriver:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `pi-read` work on the `antigravity` provider (pi-antigravity extension, an OAuth credential) inside the existing pi jail, and make it the default read lane again. `agy-read` stays in this PR; its withdrawal is a separate follow-up PR (see Out of scope).

**Architecture:** The pi arm in `skills/dispatch-cli/scripts/dispatch.sh` runs pi in a private HOME (the jail) that holds exactly one projected credential, and today that credential must be a static API key. For an allowlisted OAuth provider this plan adds three steps:

1. **Refresh by pi itself.** If the real token has under 300s left, pi refreshes it. 300s is the threshold at which pi-ai refreshes on its own (`resolve.js:46-56`: `now + 300000 >= expires`). The refresh happens in one pi run with the operator's real HOME that sees no repository content: cwd `/`, a constant prompt, `--no-tools`, no context files, and only this extension loaded. pi writes the refreshed credential itself, under its own file lock (`auth-storage.js`, proper-lockfile). Rotation and locking are therefore pi's own, already-shipped behaviour; the save itself is not atomic (an ADR 0052 residual). busdriver never writes the credential store and never copies a refresh token anywhere.
2. **Access-token-only projection with a capped run.** The jail gets the entry without `refresh`, and only with at least 390s left (300 refresh window + 30 margin + 60 minimum run). The jailed run's timeout is capped at `remaining − 330s`, so the run ends before pi would reach its refresh window. pi never attempts a refresh in the jail, and there is no refresh token there to discard.
3. **Extension.** It loads with `-e <fixed trusted path>` (`--no-extensions` disables discovery, but explicit `-e` still loads). It is version-pinned like pi itself, and runs with `ANTIGRAVITY_NO_EXTRA_TOOLS=1`.

**Tech Stack:** bash, python3 (inline `env -i` children), pi 1.0.1, pi-antigravity 0.9.0. Shell tests in `tests/`.

**Global Constraints:**
- **Fail closed.** A branch that cannot prove its condition refuses through `_pi_setup_fail`, and never dispatches with a wider credential set.
- **Follow the pi arm's conventions.** Credential work runs in `/usr/bin/env -i … /bin/bash --noprofile --norc` children with absolute binaries. Secrets are destroyed by grammar (`>|`), guarded by `-f && ! -L`.
- **Exactly one pi invocation in the arm may receive `HOME="$_pi_home"`: the refresh run in `_pi_oauth_refresh_run`.** It must carry `cd /`, `--no-tools`, `--no-context-files`, `--no-approve`, a constant `<<<"ok"` prompt, and no `PROMPT_FILE`. Task 2 narrows the old blanket test to this rule, and ADR 0052 records why.
- API-key providers behave exactly as today.
- **No model id in docs or code.** `tests/test-lane-model-config.sh` sweeps for `gemini[- ][0-9]`, so docs write `antigravity/<model>`.
- Empty arrays are expanded as `${a[@]+"${a[@]}"}`, because bash 4.0–4.3 under `set -u` fail on an empty `"${a[@]}"`.
- **Every new `_pi_setup_fail` message that names `BUSDRIVER_PI_LIVE` says "bump" before it.** `_ritual_msg_check` in the test enforces this.
- ShellCheck output for touched scripts matches `main`. No new dependencies. `hooks/gate-scripts/**` and `scripts/hooks/**` are untouched, so no lock regen.

**Security framing (use it everywhere):** Access-token-only projection removes the refresh token from what pi is handed in the jail and makes an in-jail refresh impossible. It does **not** confine reads. pi's `read` tool accepts absolute paths, so the real `~/.pi/agent/auth.json`, refresh token included, stays reachable by a determined injection. That is ADR 0034's recorded residual, unchanged here.

**Decision record:** ADR 0052, created in Task 4. It supersedes ADR 0040's "agy-read is the default", amends ADR 0034 and ADR 0042, and records the narrowed real-HOME test.

**Evidence so far (2026-10-05, operator Mac):**
- An access-token-only `auth.json` plus `--no-extensions -e <ext> --tools read` answered a constant prompt (rc 0). pi wrote only `models-store.json`.
- `pi auth` loads no extensions (`provider_not_found`), so a pi run is the only refresh path.
- pi-ai refreshes when `now + 300000 >= expires`, and persists the result before the model call (`resolve.js:46-56`).
- Not yet observed: a real-HOME refresh run at the window. Task 3 observes it live, and implementation stops if it fails.

Round-2 design-review findings about the busdriver-side write-back (lost refreshed token, refresh token left on disk after a signal, deleting paths it didn't create, the fixed tmp name, unbounded timeouts) are removed by this design, with one exception noted below. It has no write-back, no temp copy of a refresh token, and a budget capped by token lifetime. Two residuals remain, both recorded in ADR 0052: pi's own `auth.json` save is in place and not atomic, and a refresh token that Google rotates can be lost if the process dies between the extension's account-mirror write and pi's save.

## As implemented (2026-10-05) — supersedes the task snippets below where they differ

The design review (run 26686178) and litmus found defects in some of the snippets below. The shipped code (`2643a5ad`, `6738d00e`, `40e23341`) differs from those snippets in these ways:

- **Real-HOME test anchor.** Both the negative and the positive assertion match `env -i HOME="$_pi_home"`, not a bare `HOME="$_pi_home"`. The config read `HOME="$_pi_home" resolve_pi_read_model` is not a pi child. The function is sliced at its closing brace, because it has no `return`.
- **Refresh run.**
  - It adds `--offline` (no package installs) and has a 90s timeout.
  - It runs only when at least 150s of `--timeout` budget is left. Otherwise the lane refuses with a budget-specific message.
  - It ends on an assignment, not `return`/`true`.
  - The claim about pi's save is corrected: pi's file lock serialises writers, but the write is not atomic, and that is an ADR 0052 residual.
- **Run cap.**
  - The cap is re-based just before launch on the time since the token was read (`SECONDS`, arithmetic only).
  - Projection checks the token it actually writes against `FLOOR = cap + 310s`, not a fixed 390/360, so a store that changed between reads fails closed.
  - A cap that ran out (the host slept) refuses inside the dispatch subshell, so teardown still runs.
- **Distinct refusals.**
  - Extension version: 1 = mismatch, the bump ritual; 2/3 = unreadable.
  - Auth-store read failure: "not a login problem", as opposed to "no usable credential, /login".
  - The setup-fail count is 11, not 10.
- **Test extraction.** The child bodies are selected by markers inside the body (`print(max(0`, `get("version")`), never by an `env -i` argument.
- **Live certification.** It fails when pi-antigravity is installed but `.pi_read.model` does not name `antigravity`, so the extension pin is never blessed by a run that did not load it.
- **Install instructions** pin `npm:pi-antigravity@0.9.0`.
- **The jailed prompt never starts with `/`** (re-review, run 565a6c09). pi runs an extension *command* for a `/`-leading prompt, outside `--tools read`, so the jailed stdin begins with the fixed line `Read-only repository request:`. A missing `auth.json` also reads as "no credential, /login" rather than as a reader failure.
- **Task 3 refresh path.** This was observed live without waiting: the stored token had expired before the certification run (-4484s), and the refresh run brought it to +3284s.

---

### Task 1: Extension loading and version pin

**Files:**
- Modify: `skills/dispatch-cli/scripts/dispatch.sh`
  - a new constant next to `BUSDRIVER_PI_PROBED_VERSION`
  - the pi arm's `local` declaration (`local _pi_prov _pi_jail _pi_tmp`)
  - the extension path before the branch chain
  - two new branches after the provider-derivation branch
  - the jailed pi invocation
- Test: `tests/test-pi-dispatch-arm.sh`

**Interfaces:**
- Produces:
  - `BUSDRIVER_PI_ANTIGRAVITY_PROBED_VERSION="0.9.0"`
  - `_pi_ext`: string, empty for providers without an extension
  - `_pi_ext_args`: array, empty or `(-e "$_pi_ext")`
  - `_pi_ext_version_ok`: exit 0 iff the extension's `package.json` version equals the pin

- [ ] **Constant**, directly below `BUSDRIVER_PI_PROBED_VERSION="…"`:

```bash
# The pi-antigravity extension runs INSIDE the jailed read lane, so its
# behaviour is part of the lane's posture: the access-token-only projection
# (ADR 0052) was verified against this version only. Same ritual as pi's own
# pin: bump it FIRST, then re-run BUSDRIVER_PI_LIVE=1 tests/test-pi-dispatch-arm.sh.
BUSDRIVER_PI_ANTIGRAVITY_PROBED_VERSION="0.9.0"
```

- [ ] **Locals.** Extend `local _pi_prov _pi_jail _pi_tmp` to `local _pi_prov _pi_jail _pi_tmp _pi_ext _pi_rem _pi_run_budget _pi_prep_why` and add `local -a _pi_ext_args`.

- [ ] **Extension path.** Insert immediately after the `_pi_jail=` assignment and before `if [[ -z "$_pi_prov" …`. These are string and array assignments only, with no I/O, and the branches below check them before any use.

```bash
                    # OAuth providers whose models come from a pi EXTENSION (ADR 0052).
                    # --no-extensions disables discovery but explicit -e still loads,
                    # and the private HOME has no settings.json, so the extension is
                    # named from a FIXED path under the password-DB home — never from
                    # the checkout or the environment. Checked by the branches below.
                    _pi_ext_args=(); _pi_run_budget=""; _pi_prep_why=""
                    case "$_pi_prov" in
                        antigravity) _pi_ext="$_pi_home/.pi/agent/npm/node_modules/pi-antigravity/src/index.ts" ;;
                        *) _pi_ext="" ;;
                    esac
                    [[ -n "$_pi_ext" ]] && _pi_ext_args=(-e "$_pi_ext")
```

- [ ] **Extension checks.** Add these two branches immediately after the provider-derivation branch (the one ending `_pi_setup_fail "could not derive a provider…"`) and before `elif [[ -e "$_pi_jail" || -L "$_pi_jail" ]]`:

```bash
                    elif [[ -n "$_pi_ext" ]] && { [[ ! -f "$_pi_ext" || -L "$_pi_ext" ]]; }; then
                        _pi_setup_fail "provider '${_pi_prov}' needs its pi extension, which is missing from its trusted install path ($_pi_ext) or is a symlink. Install it with: pi install npm:pi-antigravity"
                    elif [[ -n "$_pi_ext" ]] && ! _pi_ext_version_ok; then
                        _pi_setup_fail "pi-antigravity is not the probed ${BUSDRIVER_PI_ANTIGRAVITY_PROBED_VERSION}; the read lane's credential posture was verified against that version only. To clear: bump BUSDRIVER_PI_ANTIGRAVITY_PROBED_VERSION in dispatch.sh FIRST, then run BUSDRIVER_PI_LIVE=1 tests/test-pi-dispatch-arm.sh, and revert the bump if it fails."
```

- [ ] **Version reader**, defined next to `_pi_project`:

```bash
                    _pi_ext_version_ok() {
                        /usr/bin/env -i \
                            "PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" \
                            "PKG=${_pi_ext%/src/index.ts}/package.json" \
                            "WANT=$BUSDRIVER_PI_ANTIGRAVITY_PROBED_VERSION" \
                            /bin/bash --noprofile --norc <<'CHILD'
py=""
for b in /opt/homebrew/bin/python3 /usr/local/bin/python3 /usr/bin/python3 /bin/python3; do
  [ -x "$b" ] && { py="$b"; break; }
done
[ -n "$py" ] && [ -f "$PKG" ] && [ ! -L "$PKG" ] || exit 1
"$py" -I -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1])).get("version")==sys.argv[2] else 1)' "$PKG" "$WANT"
CHILD
                    }
```

- [ ] **Jailed invocation.** Make three changes:
  - Change `/usr/bin/env -i HOME="$_pi_jail" PATH="$_pi_path" \` to `/usr/bin/env -i HOME="$_pi_jail" PATH="$_pi_path" ANTIGRAVITY_NO_EXTRA_TOOLS=1 \`.
  - Change `--no-extensions --no-prompt-templates --no-themes \` to `--no-extensions ${_pi_ext_args[@]+"${_pi_ext_args[@]}"} --no-prompt-templates --no-themes \`.
  - Change `_portable_timeout "$_budget"` on that invocation to `_portable_timeout "${_pi_run_budget:-$_budget}"`. `_pi_run_budget` stays empty until Task 2.

  `--tools read` already restricts extension tools ("Applies to built-in, extension, and custom tools" — `pi --help`). `ANTIGRAVITY_NO_EXTRA_TOOLS=1` is a backstop, because the extension then does not register `google_search` / `generate_image` at all.

- [ ] **Tests** in `tests/test-pi-dispatch-arm.sh`:
  - **Setup-fail count, 7 → 9.** Update the assertion and the comment above it that names each deterministic failure, adding "extension missing/symlinked" and "extension version not probed".
  - **Structural assertions:**

```bash
grep -qE -- '--no-extensions \$\{_pi_ext_args\[@\]\+"\$\{_pi_ext_args\[@\]\}"\}' <<<"$ARM" \
  && ok "jailed pi run adds only the named extension (empty-array safe)" \
  || fail "jailed pi run does not pass _pi_ext_args with the empty-array-safe expansion"
grep -qF 'antigravity) _pi_ext="$_pi_home/.pi/agent/npm/node_modules/pi-antigravity/src/index.ts"' <<<"$ARM" \
  && ok "extension path is fixed under the password-DB home" \
  || fail "antigravity extension path is not the fixed trusted path"
grep -qE '^BUSDRIVER_PI_ANTIGRAVITY_PROBED_VERSION="[0-9]+\.[0-9]+\.[0-9]+"$' "$DISPATCH" \
  && ok "pi-antigravity is version-pinned" \
  || fail "pi-antigravity has no probed-version pin"
grep -qE '/usr/bin/env -i HOME="\$_pi_jail" PATH="\$_pi_path" ANTIGRAVITY_NO_EXTRA_TOOLS=1' <<<"$ARM" \
  && ok "jailed run disables the extension's extra tools" \
  || fail "jailed run does not set ANTIGRAVITY_NO_EXTRA_TOOLS=1"
```

  - **Version reader.** Drive `_pi_ext_version_ok`'s child (the `<<'CHILD'` body containing `PKG=`, extracted with the same awk shape as `MKJAIL_BODY`) against a synthetic `package.json` under `$FAKE_HOME`:
    - version `0.9.0` passes
    - version `0.9.1` fails
    - a symlinked `package.json` fails
  - The existing `_ritual_msg_check` assertion must still pass. The new message says "bump" before `BUSDRIVER_PI_LIVE`.

- [ ] **Run** `bash tests/test-pi-dispatch-arm.sh` and `shellcheck skills/dispatch-cli/scripts/dispatch.sh`.
  - Expected: all offline sections pass. The live section still refuses pi 1.0.1 until Task 3.
- [ ] **Commit:** `feat(pi-read): load and version-pin the pi-antigravity extension in the read jail (ADR 0052)`.

### Task 2: Refresh by pi, access-token-only projection, capped run

**Files:**
- Modify: `skills/dispatch-cli/scripts/dispatch.sh`, pi arm:
  - new functions `_pi_oauth_remaining`, `_pi_oauth_refresh_run`, `_pi_prepare_ext`
  - a new branch before `_pi_mkjail`
  - the projection python
  - `_pi_wipe` STEP 1
  - the projection failure message
- Test: `tests/test-pi-dispatch-arm.sh`

**Interfaces:**
- Consumes:
  - from Task 1: `_pi_ext`, `_pi_ext_args`, `_pi_run_budget`, `_pi_prep_why`
  - existing: `_pi_home`, `_pi_bin`, `_pi_path`, `_pi_prov`, `_budget`, `_portable_timeout`, `MODEL`, `_BD_PI_READ_MODEL`, `TIMEOUT`, `start`
- Produces:
  - `_pi_oauth_remaining`: sets `_pi_rem` to the integer seconds the stored OAuth token has left, or to empty when there is no usable OAuth entry
  - `_pi_oauth_refresh_run`: always returns 0; side effect: pi refreshes the real credential
  - `_pi_prepare_ext`: returns 1 with `_pi_prep_why` set when the run cannot proceed; otherwise sets `_pi_run_budget`
  - projection env `FLOOR=390`

- [ ] **`_pi_oauth_remaining`**, defined next to `_pi_project`. The child prints one integer or nothing, and the parent accepts only digits.

```bash
                    _pi_oauth_remaining() {
                        _pi_rem="$(/usr/bin/env -i \
                            "PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" \
                            "SRC=$_pi_home/.pi/agent/auth.json" "NAME=$_pi_prov" \
                            /bin/bash --noprofile --norc <<'CHILD' 2>/dev/null
py=""
for b in /opt/homebrew/bin/python3 /usr/local/bin/python3 /usr/bin/python3 /bin/python3; do
  [ -x "$b" ] && { py="$b"; break; }
done
[ -n "$py" ] || exit 1
"$py" -I -c 'import json, math, sys, time
e = json.load(open(sys.argv[1])).get(sys.argv[2])
exp = e.get("expires") if isinstance(e, dict) else None
if isinstance(e, dict) and e.get("type") == "oauth" and isinstance(exp, (int, float)) \
   and not isinstance(exp, bool) and math.isfinite(exp):
    print(max(0, int(exp / 1000.0 - time.time())))' "$SRC" "$NAME"
CHILD
)"
                        [[ "$_pi_rem" =~ ^[0-9]+$ ]] || _pi_rem=""
                    }
```

- [ ] **`_pi_oauth_refresh_run`**, defined next to it. This is the one real-HOME pi run, and it sees no repository content.

```bash
                    # REFRESH BY PI ITSELF (ADR 0052). The jail never holds a refresh
                    # token, so a token inside pi's own 300s refresh window is refreshed
                    # HERE, before any repository content is read, by pi with the real
                    # HOME: pi-ai refreshes when now+300s >= expires and persists the
                    # result under its own file lock before the model call, so rotation
                    # and locking are pi's (the save is not atomic), and busdriver never writes the
                    # credential store or copies a refresh token. The run sees nothing
                    # from the checkout: cwd /, a constant prompt, --no-tools, no context
                    # files, project files ignored, only this extension loaded, its extra
                    # tools off. This is the ONE pi invocation in the arm allowed the real
                    # HOME (tests pin it). `pi auth` cannot do this: it loads no extensions.
                    _pi_oauth_refresh_run() {
                        local _rt=$(( _budget - 90 )); (( _rt > 60 )) && _rt=60
                        (( _rt >= 15 )) || return 0
                        ( cd / && _portable_timeout "$_rt" \
                            /usr/bin/env -i HOME="$_pi_home" PATH="$_pi_path" ANTIGRAVITY_NO_EXTRA_TOOLS=1 \
                            "$_pi_bin" --model "${MODEL:-$_BD_PI_READ_MODEL}" \
                              --print --no-session --no-approve --no-context-files --no-skills \
                              --no-extensions -e "$_pi_ext" --no-prompt-templates --no-themes \
                              --no-tools <<<"ok" >/dev/null ) \
                          || /bin/echo "pi-read: pi could not refresh the ${_pi_prov} token (see pi's message above)." >&2 || true
                        return 0
                    }
```

- [ ] **`_pi_prepare_ext`**, defined next to it:

```bash
                    # Decides whether the jailed run can proceed, and for how long.
                    # FLOOR 390 = pi's 300s refresh window + 30s margin + 60s minimum run.
                    # The run budget is capped at remaining-330 so the run ends before pi
                    # would enter its refresh window inside the jail.
                    _pi_prepare_ext() {
                        [[ -z "$_pi_ext" ]] && return 0
                        _pi_oauth_remaining
                        if [[ -n "$_pi_rem" ]] && (( _pi_rem < 300 )); then
                            _pi_oauth_refresh_run
                            _now=$(date +%s); _budget=$(( TIMEOUT - (_now - start) ))
                            _pi_oauth_remaining
                        fi
                        if [[ -z "$_pi_rem" ]]; then
                            _pi_prep_why="no usable ${_pi_prov} OAuth credential in the auth store — run pi and /login ${_pi_prov}."
                            return 1
                        elif (( _pi_rem < 300 )); then
                            _pi_prep_why="the ${_pi_prov} token could not be refreshed (${_pi_rem}s left) — run pi once; if it asks, /login ${_pi_prov}."
                            return 1
                        elif (( _pi_rem < 390 )); then
                            _pi_prep_why="the ${_pi_prov} token has ${_pi_rem}s left, too little for a run before pi's refresh window; retry in about $(( _pi_rem - 299 ))s."
                            return 1
                        fi
                        _pi_run_budget=$(( _pi_rem - 330 ))
                        (( _pi_run_budget > _budget )) && _pi_run_budget=$_budget
                        if (( _pi_run_budget < 60 )); then
                            _pi_prep_why="under 60s of --timeout budget left after the token check; re-run or raise --timeout."
                            return 1
                        fi
                        return 0
                    }
```

- [ ] **Branch.** Insert immediately before `elif ! _pi_mkjail; then`:

```bash
                    elif ! _pi_prepare_ext; then
                        _pi_setup_fail "$_pi_prep_why"
```

- [ ] **Projection python.** In `_pi_project`, add `"FLOOR=390"` to the `env -i` list and pass `"$FLOOR"` as `sys.argv[4]`. Keep the existing comment block verbatim and add the ADR 0052 paragraph:

```python
"$py" -I -c 'import json, math, sys, time
src, dst, prov, floor = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
d = json.load(open(src))
if prov not in d:
    raise SystemExit("provider not in auth store")
entry = d[prov]
# REFUSE refreshable credentials. pi rewrites auth.json in place when it
# refreshes an OAuth token — inside the jail, which is discarded. For a provider
# that ROTATES refresh tokens that silently invalidates the credential still
# sitting in the real store, and the operator has to re-authenticate for reasons
# they cannot see. Copying the jail copy back is not the fix: it would put a
# write to the real credential store on the far side of an untrusted-input run.
# Static API keys have no such lifecycle, so project those and fail closed on
# anything else.
# ALLOWLIST of known-static credential types (pi 0.84.1 stores API keys as
# type="api_key"). An allowlist, not a denylist of oauth-ish field names: an
# unrecognised future type fails closed rather than being projected on the
# assumption it has no refresh lifecycle.
# EXCEPTION, ACCESS-TOKEN-ONLY (ADR 0052): an allowlisted OAuth provider is
# projected WITHOUT its refresh token and only with >= FLOOR seconds left; the
# parent caps the run at remaining-330s, so pi never reaches its 300s refresh
# window here, and there is no refresh token in the jail to discard anyway.
OAUTH_ACCESS_ONLY = ("antigravity",)
if not isinstance(entry, dict):
    raise SystemExit("unrecognised credential shape")
kind = entry.get("type")
if kind in ("api_key", "api"):
    out = entry
elif kind == "oauth" and prov in OAUTH_ACCESS_ONLY:
    exp, acc = entry.get("expires"), entry.get("access")
    if isinstance(exp, bool) or not isinstance(exp, (int, float)) or not math.isfinite(exp) \
       or not isinstance(acc, str) or not acc:
        raise SystemExit("oauth entry without a usable access token and expiry")
    if exp / 1000.0 < time.time() + floor:
        raise SystemExit("oauth access token expires within FLOOR")
    out = {k: v for k, v in entry.items() if k != "refresh"}
else:
    raise SystemExit("refreshable or unrecognised credential type")
json.dump({prov: out}, open(dst, "w"))' "$SRC" "$D/.pi/agent/auth.json" "$PROV" "$FLOOR" 2>/dev/null || exit 1
```

- [ ] **Jail wipe of the extension's account mirror.** In `_pi_wipe` STEP 1, immediately after the `auth.json` zeroing `if … fi`, add:

```bash
                            # shellcheck disable=SC2188
                            if [[ -f "$_pi_jail/.pi/agent/antigravity-accounts.json" && ! -L "$_pi_jail/.pi/agent/antigravity-accounts.json" ]] \
                               && ! >| "$_pi_jail/.pi/agent/antigravity-accounts.json"; then
                                /bin/echo "WARNING: could not zero $_pi_jail/.pi/agent/antigravity-accounts.json — remove it by hand." >&2 || _pi_wipe_warn=1
                            fi
```

- [ ] **Projection failure message.** Replace the existing message with:

```bash
                        _pi_setup_fail "could not project a credential for '${_pi_prov}' into a private HOME for pi — refusing to dispatch with the full credential store exposed. Either python3 is unavailable, the provider is not authenticated, or it uses a refreshable credential this lane does not project. For an API-key provider check with: pi auth check --provider ${_pi_prov} --model <model>. For an allowlisted OAuth provider (antigravity), run pi once and, if asked, /login ${_pi_prov}."
```

- [ ] **Tests** in `tests/test-pi-dispatch-arm.sh`:
  - **Narrow the real-HOME pin (lines ~180-183).** Replace the blanket refusal with this rule: the only `HOME="$_pi_home"` pi invocation lives inside `_pi_oauth_refresh_run`, and that body carries the no-repo-content guarantees. The jailed dispatch keeps its existing `HOME="$_pi_jail"` pin at lines ~176-178.

```bash
_rf="$(awk '/_pi_oauth_refresh_run\(\) \{/,/^                    \}$/' <<<"$ARM")"
_arm_wo_rf="$(awk '/_pi_oauth_refresh_run\(\) \{/{skip=1} !skip{print} skip && /^                    \}$/{skip=0}' <<<"$ARM")"
if grep -qE 'env -i HOME="\$_pi_home"' <<<"$_arm_wo_rf"; then
  fail "a pi child outside _pi_oauth_refresh_run receives the operator's REAL home — credential projection bypassed"
else
  ok "only the refresh run receives the operator's real home"
fi
for _needle in 'cd /' '--no-tools' '--no-context-files' '--no-approve' '<<<"ok"' '-e "$_pi_ext"' 'ANTIGRAVITY_NO_EXTRA_TOOLS=1' '--no-session'; do
  [[ "$_rf" == *"$_needle"* ]] && ok "real-HOME refresh run carries $_needle" \
    || fail "real-HOME refresh run is missing $_needle"
done
[[ "$_rf" != *'PROMPT_FILE'* && "$_rf" != *'--tools '* ]] \
  && ok "real-HOME refresh run receives no repo prompt and no tool allowlist" \
  || fail "real-HOME refresh run references the repo prompt or enables tools"
```

  - **Setup-fail count, 9 → 10.** The `_pi_setup_fail "$_pi_prep_why"` branch is deterministic for its run. Update the comment.
  - **Synthetic store, written with python so expiries are computed:**

```bash
  python3 - "$_AS" <<'PY'
import json, sys, time
now_ms = int(time.time() * 1000)
json.dump({
  "goodprov":  {"type": "api_key", "key": "FAKE-NOT-A-REAL-KEY"},
  "otherprov": {"type": "api_key", "key": "FAKE-ALSO-NOT-REAL"},
  "oauthprov": {"type": "oauth", "refresh": "FAKE-REFRESH", "access": "FAKE-ACCESS", "expires": now_ms + 3600000},
  "antigravity": {"type": "oauth", "refresh": "FAKE-REFRESH", "access": "FAKE-ACCESS",
                  "expires": now_ms + 3600000, "projectId": "p", "email": "e@example.invalid"},
}, open(sys.argv[1], "w"))
PY
```

  - **Projection checks** (`_runchild` passes `"FLOOR=390"`):
    - (a) `antigravity` is projected with `refresh` absent and `access` kept.
    - (b) the existing `oauthprov` refusal still holds.
    - (c) `antigravity` with `expires = now+200000` is refused.
    - (d) `antigravity` with `expires` written as `Infinity` (via `json.dump(float("inf"))`) is refused.
  - **Remaining-seconds reader.** Extract `_pi_oauth_remaining`'s child (the `<<'CHILD'` body containing `NAME=` and `print(max(0`) and run it against the synthetic store:
    - `antigravity` at `now+3600000` prints a number in 3590–3600.
    - `goodprov` prints nothing.
    - `Infinity` prints nothing.
  - **`_pi_prepare_ext` decision table.** Source just the three functions into a test shell with stubs:
    - `_pi_oauth_remaining` is stubbed to set `_pi_rem` from a queue.
    - `_pi_oauth_refresh_run` is stubbed to record a call.
    - `TIMEOUT=600`, `start=$(date +%s)`, `_budget=600`, `_pi_ext=/x`, `_pi_prov=antigravity`.

    | queued `_pi_rem` | expected result |
    |---|---|
    | `3600` | 0, `_pi_run_budget=600`, no refresh |
    | `700` | 0, `_pi_run_budget=370`, no refresh |
    | `350` | 1, "retry in about 51s", no refresh |
    | `100` then `3500` | 0, refresh called once, `_pi_run_budget≤600` |
    | `100` then `100` | 1, "could not be refreshed" |
    | `` (empty) | 1, "no usable" |
    | `3600` with `_budget=40` | 1, "under 60s" |

  - **Wipe check:** `grep -qF '"$_pi_jail/.pi/agent/antigravity-accounts.json"'` passes.
- [ ] **Run** `bash tests/test-pi-dispatch-arm.sh` and shellcheck. Expected: all offline sections pass.
- [ ] **Commit:** `feat(pi-read): access-token-only OAuth projection with pi-side refresh and a lifetime-capped run (ADR 0052)`.

### Task 3: Certify pi 1.0.1 live, including the refresh path

**Files:** Modify `skills/dispatch-cli/scripts/dispatch.sh`, changing `BUSDRIVER_PI_PROBED_VERSION="0.84.2"` to `"1.0.1"`.

- [ ] **Bump, then certify, in the order the gate demands.**
  1. Set the constant.
  2. With `~/.claude/busdriver.json` holding `{"pi_read":{"model":"antigravity/<model>"}}` on the operator Mac, run `BUSDRIVER_PI_LIVE=1 bash tests/test-pi-dispatch-arm.sh`.
  3. Expected: `0 failed`, with the live write-denial section certified.
  4. On failure, revert step 1 and stop, quoting the failing line.
- [ ] **Live end-to-end, normal path.**
  - Run `bash skills/dispatch-cli/scripts/dispatch.sh --cli pi-read --prompt "Which file defines resolve_pi_read_model and on what line?"`.
  - Expected: a correct `file:line`.
  - Expected: `ls -d ${TMPDIR:-/tmp}/busdriver-pi-* 2>/dev/null` prints nothing.
- [ ] **Live end-to-end, refresh path.** This settles the one unobserved behaviour.
  - Wait until the stored token is inside pi's window. The expiry value is not a secret: `jq '.antigravity.expires' ~/.pi/agent/auth.json`. Use `Monitor` with an until-loop on `expires/1000 - now < 290`, and do not use pi interactively meanwhile.
  - Repeat the dispatch.
  - Expected: a correct answer, and `.antigravity.expires` advanced by roughly an hour.
  - **Stop condition:** if the token did not advance, stop and report. The pi-side refresh design does not hold.
- [ ] **Commit:** `chore(pi-read): certify pi 1.0.1 for the read lane (ADR 0042 ritual)`. The body quotes the live summary line, both end-to-end results and the date.

### Task 4: Doctrine, docs, ADR 0052

**Files:**
- Create: `docs/adr/0052-pi-read-on-antigravity.md`
- Modify:
  - `.claude/CLAUDE.md` (the Conventions bullet beginning `**Reading routes to \`agy-read\` first`)
  - `docs/adr/0040-*.md` (status line)
  - `docs/adr/0034-pi-in-tree-read-lane.md`, `docs/adr/0042-pi-version-certification-cache.md` (amendment lines)
  - `skills/dispatch-cli/SKILL.md` (lines naming `agy-read` as the default lane, currently ~38, 44, 90, 120, 422)
  - `README.md` (prerequisites table)

- [ ] **ADR 0052:**

```markdown
# ADR 0052 — pi-read on Antigravity: access-token-only OAuth projection, pi-side refresh; pi-read is the default read lane

**Status:** Accepted (2026-10-05). **Supersedes:** ADR 0040's "agy-read is the default read lane".
**Amends:** ADR 0034 (pi read lane), ADR 0042 (pi version pin — extension pin added).

## Context
The operator wants one swappable layer: busdriver talks to pi, and changing vendor is a
`.pi_read.model` change. agy remains for the reviewer slots and agy-prose. The chosen provider
is `antigravity` (the pi-antigravity extension), an OAuth credential. The jail projected static
API keys only, because an in-jail refresh is discarded and can invalidate a rotating real
credential.

## Decision
1. An allowlisted OAuth provider is projected into the jail WITHOUT `refresh`, only with >= 390s
   left, and the run is capped at `remaining - 330s`, so pi (which refreshes when
   now+300s >= expires) never reaches its refresh window in the jail.
2. A token inside the 300s window is refreshed by pi itself, with the real HOME, in a run that
   sees no repository content (cwd /, constant prompt, --no-tools, no context files, only the
   extension, extra tools off). pi persists the refresh under its own file lock, so rotation
   and locking are pi's own; the save itself is not atomic (an ADR 0052 residual). busdriver never writes the credential store and never
   copies a refresh token.
3. The extension loads with `-e` from a fixed path under the password-DB home, is version-pinned
   (`BUSDRIVER_PI_ANTIGRAVITY_PROBED_VERSION`), and runs with ANTIGRAVITY_NO_EXTRA_TOOLS=1.
   pi 1.0.1 is the probed pi.
4. pi-read is the default read lane. agy-read is deprecated, to be withdrawn in a follow-up PR.

## The narrowed real-HOME test
`tests/test-pi-dispatch-arm.sh` used to refuse ANY `HOME="$_pi_home"` pi child in the arm. It now
refuses one anywhere except `_pi_oauth_refresh_run`, and pins that function's no-repo-content
guarantees (cd /, constant prompt, --no-tools, --no-context-files, --no-approve, no PROMPT_FILE).
That run's inputs are a constant string and the operator's own config; nothing from the
checkout reaches it, so there is nothing to inject.

## Security posture, stated precisely
Access-token-only projection removes the refresh token from what pi is handed in the jail and
makes in-jail refresh impossible. It does NOT confine reads: pi's read tool accepts absolute
paths, so the real auth.json, refresh token included, stays reachable by a determined injection
(ADR 0034's residual, unchanged).

## Alternatives
- busdriver-side refresh in a throwaway HOME plus write-back (design-review round 2): it lost a
  rotated token on failure paths, left a refresh token on disk on signal, raced pi's lock, and
  added a credential writer to the dispatcher. Rejected.
- Refresh only after expiry: pi refreshes inside its 300s window, so an admitted token near
  expiry would refresh in the jail. Rejected (round 1).
- pi-antigravity-bridge (drives the official agy binary): ToS-clean, but agy's native tools
  bypass pi's --tools read, and it needs ~/.gemini in the jail. Rejected.
- API-key provider for pi-read: works today; not the operator's choice.

## Consequences
- Read content goes to Google via the Antigravity API. The trust rule is unchanged.
- pi-antigravity uses Google's Antigravity desktop OAuth client from a third-party tool, a
  pattern Google has suspended accounts for. Accepted by the operator. Use a Google account
  separate from the agy reviewer account, so a ban cannot take the reviewers down.
- With 300-390s left on the token, pi-read refuses and says when to retry (at most ~90s per
  token lifetime).
- Adding another OAuth provider needs: the allowlist entry, an extension-path case, a version
  pin, and a live refresh-path check.

## Revisit trigger
Google ships an official API-key or pi-native path for these models; a ban occurs; pi stops
honouring -e under --no-extensions; pi-ai changes its 300s refresh threshold.
```

- [ ] **Replace the CLAUDE.md reading bullet** with:

```markdown
- **Reading routes to `pi-read` first — money-for-time is the intended trade** — the cheapest read is the one that never enters context. **Read it yourself only when you can name the region up front *and* it is under ~200 lines; everything else goes to `skills/dispatch-cli/scripts/dispatch.sh --cli pi-read` first** — then `Read` only the `file:line` ranges it cites. File count is not a criterion; a dispatch carries a fixed ~2.5k-token floor, so a small named read stays local. Dispatch in the **background** when later steps don't depend on the answer. **The model is operator config, not code**: `~/.claude/busdriver.json` → `{"pi_read":{"model":"<provider>/<model>"}}` (no shipped default; `pi --list-models` enumerates). Changing vendor is a config change for an API-key provider; an OAuth provider additionally needs its allowlist entry, extension path and version pin in the pi arm (ADR 0052). **Containment, stated precisely:** pi runs in a private HOME holding one projected credential and `--tools read`, which blocks writes but does NOT confine reads — absolute paths still resolve, so the real credential store stays reachable by a determined injection (ADR 0034's residual). An OAuth provider is projected access-token-only; pi refreshes it itself, before any repository content is read (ADR 0052). **Gate on who wrote the content, not where it sits** — in-tree is not trusted (a fork checkout, a bot quoting a fork, a CI log echoing source all carry the fork's authorship) — and **confidentiality fails independently**: everything reachable from the prompt, untracked files included, goes to the configured provider (`antigravity` → Google). If either answer is no, read it yourself. pi-read is a **reader, never an authority** — verify load-bearing claims against source. pi and pi-antigravity are **version-pinned** (ADR 0042, ADR 0052) and the lane goes offline on upgrade until re-certified with `BUSDRIVER_PI_LIVE=1 tests/test-pi-dispatch-arm.sh`. `agy-read` is deprecated (withdrawn in a follow-up); plain `--cli agy` (reviewers) and `--cli agy-prose` (writing-prose) are unaffected. Do **not** wire pi-read into pr-grind rounds: measured ~5% there because that loop is `gh`-fetch dominated.
```

- [ ] **ADR 0040 status line:** append `Superseded in part by ADR 0052 (2026-10-05): pi-read is the default read lane again; agy-read is deprecated.`
- [ ] **ADR 0034 / ADR 0042:** append one-line amendment notes.
  - 0034: OAuth access-token-only projection plus pi-side refresh.
  - 0042: extension version pin.
- [ ] **dispatch-cli SKILL.md:**
  - Every line that names `agy-read` as the default or first-choice read lane now names `pi-read`, with `agy-read` marked deprecated. Find them with `grep -n 'agy-read' skills/dispatch-cli/SKILL.md`; at time of writing they are ~38, 44, 90, 120 and 422.
  - Add one paragraph on antigravity setup:
    - `pi install npm:pi-antigravity`
    - `/login antigravity`, using the paste-the-callback flow on a remote host
    - set `.pi_read.model`
- [ ] **README:** add a prerequisites row: `| **pi** | pi-read dispatch lane (default read lane) | \`pi install npm:pi-antigravity\` + \`/login antigravity\` for the antigravity provider |`.
- [ ] **Run** `npm run validate` and `bash tests/test-lane-model-config.sh`.
  - Expected: pass. The sweep finds no `gemini-<n>` id.
- [ ] **Commit:** `docs: pi-read on Antigravity is the default read lane; record ADR 0052`.

### Task 5: Verify and ship

- [ ] **Run the local checks:**
  - `npm run validate`
  - shellcheck (compare with `main`)
  - `./scripts/gate-integrity.sh --check`
  - every touched suite
  - the full shell suite (`bash scripts/ci/run-shell-tests.sh` or on um), compared with an unmodified-tree baseline
- [ ] **Ship:** pre-PR litmus (PR mode), then `gh pr create`, then pr-grind, then merge.
- [ ] **Operator, post-merge, on `um`:**
  - `pi install npm:pi-antigravity`
  - `/login antigravity` (paste-the-callback flow)
  - set `.pi_read.model`

## Out of scope
- **Withdrawing `agy-read` (follow-up PR).** It needs restructuring `tests/test-agy-read-lane.sh`:
  - sections 5/6 pin `_AGY_READ_LANE`
  - 5b dispatches `--cli agy-read`
  - 7–11 depend on the lane
  - 10/10b hold #689 coverage that must be re-homed

  It also needs updates to the `tests/test-lane-model-config.sh` sweep list, the writing-prose comparisons and the durations TSV, with its docs edits ordered before its residue scan.
- OS-enforced read confinement for pi (ADR 0034's residual).
- pi worker / pi-goal lanes (interactive; not jailed by busdriver).
- Droid fallback removal (separate PR).

<!-- design-review-coverage: FULL 3/3  -->

<!-- design-reviewed: PASS -->
