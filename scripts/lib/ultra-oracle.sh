#!/bin/bash
# ultra-oracle.sh — the ONLY surface that touches the oracle CLI (Layer-2).
# Advisory GPT-5.5 Pro consult via ChatGPT Pro subscription (--engine browser).
# Fails CLOSED: prints ONE typed status token; callers MUST surface it, never
# silently skip. Reuses resolve-cli.sh _portable_timeout + is_cli_available.
# Harness-neutral; no bash-4-isms (no associative arrays / mapfile).
# Conditional style: [[ ]] for string/file tests; POSIX [ ] for integer -gt/-ge
# comparisons. `[ ]` does base-10 strtol with NO arithmetic evaluation, which
# avoids [[ ]]'s octal-parse of leading-zero values (e.g. "09999") AND its
# command-substitution-in-arithmetic injection surface (e.g. RHS "a[$(cmd)]").
# Portable dir resolution. BASH_SOURCE is unset under zsh (and other non-bash shells), where
# `dirname "${BASH_SOURCE[0]}"` silently collapses to "." and mis-sources the sibling libs from
# the CWD — functions end up undefined with no error. Guard loudly: this lib is bash-only, so
# fail closed rather than half-load.
if [ -z "${BASH_SOURCE:-}" ]; then
  echo "ultra-oracle.sh: ERROR — must be sourced under bash (BASH_SOURCE unset; zsh/other shells mis-resolve the script dir and half-load)" >&2
  # shellcheck disable=SC2317  # reached when sourced under a non-bash shell
  return 1 2>/dev/null || exit 1
fi
_ULTRA_ORACLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Attach-mode preflight (ADR 0020). Assigned UNCONDITIONALLY from the resolved lib dir —
# never from the environment — so no exported var can redirect the adapter to an
# attacker-chosen script. In-process test harnesses reassign this shell variable AFTER
# sourcing to stub the preflight; that is deliberately the only override path.
_ULTRA_ORACLE_PREFLIGHT="${_ULTRA_ORACLE_DIR}/../ultra-oracle-attach-preflight.sh"
# shellcheck source=/dev/null
source "${_ULTRA_ORACLE_DIR}/ultra-oracle-config.sh"   # also transitively sources resolve-cli.sh

# _ultra_oracle_verdict_ok <file> -> 0 if the file holds a usable verdict.
# A usable verdict must be more than a degenerate token. The oracle browser engine can
# exit 0 yet write a near-empty body (observed live: a 2-byte "I\n" when extraction
# races the response stream or the ChatGPT session is stale). A bare `-s` (non-empty)
# check accepts that and renders junk as a successful verdict (false-ok). Require a
# minimum count of NON-WHITESPACE bytes so single-token captures ("I", "ok", "n/a")
# fail closed while any real one-sentence advisory passes. Tunable via
# ULTRA_ORACLE_MIN_VERDICT_BYTES (default 8; invalid/empty/zero falls back to 8).
# Note: wc -c counts bytes, not Unicode characters — multibyte chars count more than
# one toward the floor. ASCII verdicts dominate in practice; the byte floor is the
# correct primitive here (we're guarding against near-empty captures, not charset issues).
_ultra_oracle_verdict_ok() {
  local f="$1" min nonws
  min="${ULTRA_ORACLE_MIN_VERDICT_BYTES:-8}"
  case "$min" in ''|*[!0-9]*|0) min=8;; esac
  [[ -s "$f" ]] || return 1
  nonws="$(tr -d '[:space:]' < "$f" 2>/dev/null | wc -c | tr -dc '0-9')"
  [[ -n "$nonws" ]] || return 1
  [ "$nonws" -ge "$min" ]
}

# _ultra_oracle_extract_sid <errfile> -> print oracle's stored session id from its "Session: <id>"
# banner (also echoed as "Reattach: oracle session <id>"), or return 1 if absent/malformed. That id
# names the stored session whose bound tab still holds the answer. Capture the WHOLE remainder
# (leading space trimmed by sed) and trim only TRAILING whitespace/CR — do NOT truncate to a first
# token or `tr -d [:space:]`: both silently turn a MALFORMED "sess -458" into some other valid-looking
# id ("sess" / "sess-458") that could address an unrelated session. Validate as an oracle slug and
# FAIL CLOSED otherwise (it becomes an `oracle session <sid>` argv operand): reject empty, a leading
# '-' (parsed as an OPTION — injection), and any char outside the slug allowlist (alnum . _ - only; a
# space/quote is rejected). Shared by _ultra_oracle_salvage AND the watched-run tab-status probe so
# the two can never drift on what counts as a usable sid.
_ultra_oracle_extract_sid() {
  local sid
  [[ -r "$1" ]] || return 1
  sid="$(sed -n 's/^Session:[[:space:]]*//p' "$1" 2>/dev/null | head -1)"
  sid="${sid%"${sid##*[![:space:]]}"}"   # strip trailing whitespace (incl. CR), keep any internal
  case "$sid" in ''|-*|*[!A-Za-z0-9._-]*) return 1;; esac
  printf '%s' "$sid"
}

# _ultra_oracle_salvage <out> <cap> <attach-target> -> exit 0 iff a usable verdict was
# harvested into <out>. Attach-mode-only recovery for oracle 0.16.0's browser
# completion-detection bug (#458): a fast gpt-5.5-pro response FINISHES but oracle's engine
# never concludes "done" (the streaming shimmer/Stop-button vanish is indistinguishable from
# "not started"), so the run waits out its whole --timeout and writes NO verdict — while the
# completed answer sits in the still-live attached ChatGPT tab. `oracle session <id>
# --harvest` re-reads exactly that tab. Only attempted in ATTACH mode: a non-attach run's
# Chrome is oracle-launched and dies with the SIGKILLed process, so there is no live tab to
# re-read.
_ultra_oracle_salvage() {
  local out="$1" cap="$2" target="$3" sid err="${1}.err" hcap tabref
  ultra_oracle_attach_running || return 1        # live-tab recovery needs the attached browser
  [[ -n "$target" ]] || return 1                 # no pinned CDP target -> nothing to harvest from
  [[ -r "$err" ]] || return 1
  # Fail-closed extraction of oracle's stored session id from its "Session: <id>" banner (shared
  # primitive — same validation the watched-run tab-status probe uses, so they can never drift).
  sid="$(_ultra_oracle_extract_sid "$err")" || return 1
  # NEVER trust whatever oracle left in $out — always re-harvest the tab, the source of truth for
  # #458 (the complete answer lives there). oracle writes --write-output with a NON-atomic
  # fs.writeFile, so a run terminated mid-write can leave a PARTIAL longer than the 8-byte floor;
  # accepting that would promote an incomplete advisory. `oracle session --harvest` instead reads
  # the settled DOM fresh. Truncate $out FIRST so the verdict check below reflects ONLY what
  # harvest wrote: if harvest fails, we fail CLOSED (report timeout) rather than accept a
  # leftover. A verdict oracle genuinely finished is re-read intact by the harvest.
  : > "$out" 2>/dev/null || return 1
  # #458 GAP 2 — bind the harvest to the live tab by its TARGET-ID, NOT the stored URL. A
  # completed-but-hung session stores a `WEB:<uuid>` PLACEHOLDER conversation URL (not the real
  # chatgpt.com/c/<id>), so a plain `oracle session <id> --harvest` looks the tab up by that
  # placeholder, fails ("No live ChatGPT tab matched session"), and its recovery-by-reopening-the-URL
  # also fails (verified live 2026-07-23: 0 bytes). oracle's OWN `status --browser-tabs` DOES know the
  # session->tab linkage and reports the tab's target-id; passing that as `--harvest --browser-tab
  # <target-id>` binds directly and recovers the answer (verified live). PREFER the target-id the
  # watched-run tab probe already CONFIRMED (_UORA_CONFIRMED_REF) — avoids a redundant second status
  # query and the window where that query could fail and drop us to the plain harvest that can't match
  # a WEB:<uuid> URL (PR #460 PR-mode MEDIUM). Consume-and-clear it so a later salvage can't reuse a
  # stale ref. Only when it is empty (streaming heuristic / blocking empty-verdict path) do we
  # re-discover via a bounded status SNAPSHOT (temp file, not a pipeline). If still absent, fall
  # through to a plain harvest — no worse than before, fails CLOSED below.
  tabref="$_UORA_CONFIRMED_REF"; _UORA_CONFIRMED_REF=""
  if [ -z "$tabref" ]; then
    local _svsnap; _svsnap="$(mktemp 2>/dev/null)" || _svsnap=""
    if [ -n "$_svsnap" ]; then
      _uora_status_snapshot "$_svsnap" 6
      tabref="$(_ultra_oracle_tab_ref "$_svsnap" "$sid")"; tabref="${tabref%%$'\t'*}"
      rm -f "$_svsnap"
    fi
  fi
  case "$tabref" in *[!A-Za-z0-9]*) tabref="";; esac   # defense-in-depth: only a plain-alnum target-id reaches argv
  # Bounded harvest; a live-tab DOM read is quick. Pin the SAME attached browser the run drove via
  # --remote-chrome (attach discovery defaults to :9222; our Chrome uses a dynamic port). Append to
  # $err so the harvest log joins the run log. Keep the cap small (ULTRA_ORACLE_SALVAGE_CAP, default
  # 30s) AND clamped to 30s AND below the run cap. The .rc waiters (run-design-review-loop.sh /
  # ultra-oracle-run.sh) allow +90s beyond timeoutCapSeconds; the worst-case subshell tail — cap
  # detection (≤3s) + terminate (≤5s) + a status probe (≤10s) + a 30s harvest + verdict/.rc write —
  # fits inside that with margin for scheduler jitter.
  hcap="${ULTRA_ORACLE_SALVAGE_CAP:-30}"; case "$hcap" in ''|*[!0-9]*|0) hcap=30;; esac
  # Strip leading zeros FIRST so a value like "001" reads as 1, not a 3-digit over-clamp ("00"
  # collapses to "" -> default). Then a length guard BEFORE the numeric `-gt`: the ceiling is 30 (2
  # digits), so any 3+ digit value is over it — clamped by length so an oversized string can't
  # overflow the shell integer parser and slip past `-gt 30` unbounded (defeating the 30s ceiling).
  hcap="${hcap#"${hcap%%[!0]*}"}"; case "$hcap" in '') hcap=30;; esac
  [ "${#hcap}" -gt 2 ] && hcap=30
  [ "$hcap" -gt 30 ] && hcap=30           # bound so watched-run + salvage stays under the waiters' +90s grace
  [ "$cap" -lt "$hcap" ] && hcap="$cap"
  # Capture the harvest's exit status — do NOT discard it. verdict_ok alone is insufficient:
  # a harvest that streams a >8-byte fragment and then CRASHES or TIMES OUT (rc!=0) would
  # otherwise be accepted as a complete verdict. Require a clean exit AND a usable body. (The
  # dead-tab case exits 0 but writes nothing, so verdict_ok still rejects it.)
  # --no-recover on BOTH branches (PR #460 review, MEDIUM): with --browser-tab the ref binds the live
  # tab directly so recovery is never needed anyway; on the no-ref fallback it makes the harvest FAIL
  # FAST on a dead tab instead of reopening the stored `WEB:<uuid>` placeholder URL (or creating stray
  # browser state). Salvage is attach-only, so the tab is either live (found) or gone (fail closed).
  local hrc=0
  if [ -n "$tabref" ]; then
    _portable_timeout "$hcap" oracle session "$sid" --harvest --browser-tab "$tabref" --no-recover \
      --browser-attach-running --remote-chrome "$target" --write-output "$out" >>"$err" 2>&1 || hrc=$?
  else
    _portable_timeout "$hcap" oracle session "$sid" --harvest --no-recover \
      --browser-attach-running --remote-chrome "$target" --write-output "$out" >>"$err" 2>&1 || hrc=$?
  fi
  # On a non-clean harvest, clear any fragment it left so a rejected partial can never linger
  # in $out for a downstream reader, then fail closed.
  [ "$hrc" -eq 0 ] || { : > "$out" 2>/dev/null; return 1; }
  _ultra_oracle_verdict_ok "$out" || return 1
  # Self-label the recovery. Completed-but-hung detection is a HEURISTIC over oracle's own
  # heartbeat (the streaming indicator vanishing + oracle's "last change" stability report) — and
  # oracle itself cannot reliably tell "done" from "still working" (that ambiguity IS the #458
  # bug), so no signal we derive can *prove* completion. In the rare case the response was still
  # generating, the harvested DOM could be incomplete. Prepending this caveat means a salvaged
  # result is never presented as a COMPLETE verdict — it enters the arbiter prompt as an
  # explicitly best-effort, possibly-partial auxiliary note (the advisory is non-gating anyway).
  #
  # Write via an mktemp SIBLING (fresh O_EXCL file — a plain `> "$out.sv"` would follow a symlink
  # planted at that predictable path and clobber an arbitrary file), then atomic mv. The label is
  # MANDATORY, not best-effort: if it cannot be applied we FAIL CLOSED (return 1, salvage rejected)
  # rather than emit an unlabelled heuristic recovery that a downstream reader could mistake for a
  # complete verdict. A rejected salvage just surfaces as the timeout it recovered from.
  local _svtmp
  _svtmp="$(mktemp "${out}.sv.XXXXXX" 2>/dev/null)" || { : > "$out" 2>/dev/null; return 1; }
  if { printf '_[#458 best-effort recovery of a hung ultra-oracle consult — may be incomplete; auxiliary only]_\n\n'; cat "$out"; } > "$_svtmp" 2>/dev/null && mv -f "$_svtmp" "$out" 2>/dev/null; then
    return 0
  fi
  rm -f "$_svtmp" 2>/dev/null; : > "$out" 2>/dev/null; return 1
}

# _uora_terminate <pid> -> reap <pid> and RETURN a code the caller uses to tell "we killed it"
# from "it exited on its own first" (the race where oracle finishes in the window between the
# watchdog's liveness check and this call):
#   * 143 — WE terminated it. Reported UNIFORMLY whenever the process was still alive when this
#           began, regardless of the child's actual exit code — a process can CATCH SIGTERM and
#           exit 0 during cleanup, so the raw exit status cannot distinguish "killed" from "clean".
#   * else — it had ALREADY exited before we signalled (raced completion); its real wait status is
#           returned so the caller can honor that natural finish.
# Bounded TERM->KILL: an ignored TERM degrades to a kill after ~5s, never an indefinite hang, so
# the background .rc marker always lands. Signals the watched PID only. Called ONLY on the
# ATTACH-mode watched run, where oracle attaches to an already-running Chrome and forks NO browser
# — so the node process is its whole footprint and killing that pid is complete. Non-attach modes
# never reach this: they run under the unchanged `_portable_timeout` (timeout(1)'s teardown).
_uora_terminate() {
  local p="$1" st=0
  # The TERM `kill` ITSELF is the ONLY classifier used: it atomically fails with ESRCH only when
  # the pid is FULLY GONE (already exited AND reaped) — a clean natural finish we report as its own
  # wait status — and succeeds otherwise. We deliberately do NOT try to further distinguish a live
  # process from an unreaped zombie or a TERM-catcher that exits 0: every such probe is a
  # check-then-act race with no atomic primitive in portable shell, AND it is unnecessary — the
  # salvage path NEVER trusts oracle's own $out (it always truncates and RE-HARVESTS the live tab),
  # so a run that raced to completion after we signalled is still recovered correctly by the
  # subsequent harvest, not misread as a partial. So on any successful kill we return 143 ("we
  # terminated it") uniformly and let salvage do the right thing.
  if ! kill "$p" 2>/dev/null; then wait "$p" 2>/dev/null || st=$?; return "$st"; fi
  # Signalled a live/zombie pid -> we own the termination. Escalate to KILL if TERM is ignored so
  # this is bounded, then report 143.
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    kill -0 "$p" 2>/dev/null || { wait "$p" 2>/dev/null || true; return 143; }
    sleep 0.5
  done
  kill -9 "$p" 2>/dev/null || true; wait "$p" 2>/dev/null || true; return 143
}

# _uora_status_snapshot <outfile> -> run `oracle status --browser-tabs` into <outfile>, BOUNDED by a
# TERM->KILL reaper (reuses _uora_terminate) instead of a pipeline+_portable_timeout. This avoids the
# hang the pipeline form had (PR #460 review, MEDIUM): `_portable_timeout N oracle status | parser`
# on macOS falls back to a perl shim that only sends TERM and exits 124 WITHOUT reaping — if `oracle
# status` ignores TERM or leaves a descendant holding the pipe's write end, the reader never sees EOF
# and the command substitution blocks forever, stalling the watchdog past its own hard cap. Writing to
# a FILE (no pipe) removes the reader-blocks-on-EOF failure mode. It does its OWN bounded
# TERM->KILL-and-reap (NOT _portable_timeout, whose perl fallback only sends TERM and exits without
# reaping — a TERM-ignoring `oracle status` would orphan, PR #460 MEDIUM). And it publishes the live
# status pid in the module var _UORA_STATUS_PID so the watched runner's INT/TERM/HUP/EXIT traps can
# reap it too if the runner is interrupted mid-probe (PR #460 MEDIUM) — the traps only know the main
# consult pid otherwise. Always returns 0 (best effort); an empty/partial file yields no completion
# signal (fail-safe). Cleared to "" on exit so a stale pid is never signalled.
# Set by the watched-run tab probe to the target-id it CONFIRMED completed, so _ultra_oracle_salvage
# can bind the harvest to that exact tab instead of re-discovering it with a second (fallible) status
# query (PR #460 PR-mode MEDIUM). Empty when salvage was reached another way (streaming heuristic,
# blocking empty-verdict) — then salvage re-discovers. Consumed-and-cleared by salvage.
_UORA_CONFIRMED_REF=""
_UORA_STATUS_PID=""
_uora_status_snapshot() {
  local of="$1" maxsecs="$2" sp w=0 steps
  : > "$of" 2>/dev/null || return 0
  # DEADLINE-AWARE poll bound (PR #460 MEDIUM): the caller passes the seconds it can afford before its
  # hard cap, so a hung `oracle status` near the cap cannot push the effective timeout out. Default/
  # clamp to a sane 1..6s (oracle status is normally sub-second; in tests the mock exits instantly, so
  # the poll returns at once regardless). steps = 2 per second (0.5s sleeps).
  case "$maxsecs" in ''|*[!0-9]*|0) maxsecs=6;; esac
  [ "$maxsecs" -gt 6 ] && maxsecs=6
  steps=$(( maxsecs * 2 ))
  oracle status --browser-tabs >"$of" 2>/dev/null &
  sp=$!; _UORA_STATUS_PID="$sp"
  while kill -0 "$sp" 2>/dev/null && [ "$w" -lt "$steps" ]; do sleep 0.5; w=$(( w + 1 )); done
  # Quick TERM->KILL (~0.5s), NOT _uora_terminate's 5s grace: a status snapshot is disposable, and the
  # caller's budget only accounts for maxsecs + a small termination allowance (PR #460 PR-mode MEDIUM).
  if kill -0 "$sp" 2>/dev/null; then
    kill -TERM "$sp" 2>/dev/null; sleep 0.5
    kill -0 "$sp" 2>/dev/null && kill -KILL "$sp" 2>/dev/null
  fi
  wait "$sp" 2>/dev/null || true
  _UORA_STATUS_PID=""
  return 0
}

# _ultra_oracle_run_watched <cap> <errfile> <cmd...> -> run <cmd> (oracle) in the background,
# capturing stdout+stderr to <errfile>. Distinguishes THREE outcomes by exit code so the caller
# salvages ONLY on positive evidence the response completed:
#   * <cmd>'s own rc — it finished on its own.
#   * 125 — CONFIRMED completed-but-hung (#458): the heartbeat streamed and then sat in the
#           "no thinking status detected yet" waiting branch. The stream ENDED, so the tab holds
#           a COMPLETE answer -> caller salvages.
#   * 124 — plain hard cap with NO hung signature: the response may still be mid-stream (a
#           genuinely slow consult), so the tab could hold a PARTIAL -> caller must NOT salvage
#           (harvesting a partial and promoting it to a verdict is the bug this split prevents).
# ONLY used for the ATTACH path — the sole mode where salvage can recover and where oracle forks
# no Chrome to orphan. Non-attach background stays on `_portable_timeout` (unchanged teardown).
#
# Runs oracle DIRECTLY (`"$@" &`) so `$!` is oracle's OWN pid: backgrounding a shell FUNCTION
# (`_portable_timeout … &`) forks a subshell and buries oracle two levels down with no signalable
# pid, and the perl fallback would not forward a TERM to it. We therefore enforce the cap here
# via a wall-clock deadline (`date`, not accumulated sleeps — scheduler delays and the growing
# awk rescans would drift the count below real time).
# _ultra_oracle_hung_signal <errfile> -> print "<waits> <laststable> <laststream> <everstreamed>" for the
# completed-but-hung heuristic, computed from oracle's OWN heartbeat log. Extracted so the watchdog
# AND its unit test invoke the SAME awk — the two can never drift (CodeRabbit, PR #460). Tracks the
# state AFTER the LAST active heartbeat:
#   * laststream = 1 iff the MOST RECENT active heartbeat was "response streaming" (not reasoning /
#                  tool use) — the RESPONSE was the last thing happening before the indicator
#                  vanished. If the model went back to reasoning/tool use after streaming it is 0,
#                  and we do NOT salvage (it may not be done).
#   * waits      = consecutive "no thinking status detected yet" idle ticks since the last ACTIVE
#                  heartbeat. Reset on ANY "ChatGPT thinking" line (streaming OR reasoning OR tool
#                  use — all mean work), so a single transient null between active ticks never
#                  accrues; only a SUSTAINED-gone indicator does.
#   * laststable = seconds the FINAL streaming line reported content unchanged ("last change Ns
#                  ago") — INDEPENDENT stability evidence, computed ONLY from streaming lines (a
#                  reasoning line's "last change" is not response-body stability).
#   * everstreamed = 1 iff a "response streaming" heartbeat was EVER seen. Unlike laststream this is
#                  MONOTONIC (never reset by a later reasoning/tool-use line). The tab-status probe
#                  gates on `everstreamed == 0` — a stream->reasoning->idle sequence leaves laststream
#                  0 but everstreamed 1, and must NOT be treated as "never streamed" (PR #460 HIGH).
# The caller salvages iff laststream AND waits>=2 AND laststable>=$stable — a deliberately
# CONSERVATIVE heuristic biased toward NOT cutting an active stream: oracle's own ambiguity (it
# cannot tell "done" from "working" — the #458 bug) means no signal can prove completion, so we
# accept rare MISSED recoveries (fall through to the hard cap) rather than risk a partial. In
# oracle's observed behavior a finished response keeps emitting streaming heartbeats with a GROWING
# "last change" for minutes before the indicator vanishes, so laststable is large in practice.
_ultra_oracle_hung_signal() {
  awk '
    /ChatGPT thinking/ {
      w = 0; seen = 1
      if ($0 ~ /status=response streaming/) {
        laststream = 1; everstreamed = 1; laststable = 0
        mm = 0; ss = 0
        if (match($0, /last change [0-9]+m/)) { seg = substr($0, RSTART, RLENGTH); gsub(/[^0-9]/, "", seg); mm = seg + 0 }
        if (match($0, /[0-9]+s ago/))         { seg = substr($0, RSTART, RLENGTH); gsub(/[^0-9]/, "", seg); ss = seg + 0 }
        if (index($0, "last change") > 0)     { laststable = mm * 60 + ss }
      } else {
        laststream = 0   # reasoning / tool use was the most recent activity, not streaming (everstreamed unchanged)
      }
    }
    /no thinking status detected yet/ { if (seen) w++ }
    END { print (w + 0) " " (laststable + 0) " " (laststream + 0) " " (everstreamed + 0) }
  ' "$1" 2>/dev/null
}

# _ultra_oracle_tab_ref <tabs-file> <sid> -> print the browser TARGET-ID of the live tab bound to
# session <sid> IFF oracle's OWN `status --browser-tabs` output (captured in <tabs-file>) reports it
# `completed` with a non-empty `last=` answer preview; print nothing otherwise. The non-empty return
# is BOTH oracle's AUTHORITATIVE completion signal AND the exact tab handle the salvage harvest needs.
# Two jobs, one parser:
#   * PRIMARY completed-but-hung trigger (#458 GAP 1): non-empty ref means completed — fires even for
#     a FAST/short response that never streamed (the streaming heuristic's laststream stays 0 and its
#     gate can never pass; the real-world common case the merged fix missed).
#   * salvage tab binding (#458 GAP 2): `oracle session <id> --harvest` looks the tab up by the stored
#     `WEB:<uuid>` PLACEHOLDER URL and CANNOT match the live tab (verified: it logs "No live ChatGPT
#     tab matched" then fails), but `--harvest --browser-tab <target-id>` binds directly and recovers
#     the answer (verified live 2026-07-23). This ref is that target-id.
# oracle 0.16.0 prints ONE MULTI-LINE BLOCK per tab (verified live), NOT one line:
#     - <TARGET-ID> <status> model=Pro turns=1 stop=no send=no
#       title=<…>
#       url=<…>
#       session=<slug>
#       last=<preview…>
# so the target-id is field 2 and status field 3 of the `- `-prefixed header, while session=/last=
# are on their OWN indented lines — parse the block, not a single line. The session value is matched
# EXACTLY (whole remainder after `session=`) so `session=foo` never matches `session=foobar`, and the
# target-id is emitted only if it is plain alnum (it becomes a `--browser-tab` argv value — fail
# closed on anything odd). Shared by the watchdog probe and the salvage so the two can never drift.
# Prints "<target-id>\t<last-preview>" (tab-separated) for the matching completed tab, so callers get
# BOTH the --browser-tab handle AND the answer preview the stability guard compares across probes.
_ultra_oracle_tab_ref() {
  awk -v sid="$2" '
    # Accumulate matches; emit ONLY if EXACTLY ONE completed tab carries this session. If two tabs
    # ever share the session (a nonce collision, or oracle transiently double-binding), fail CLOSED —
    # ambiguous state must not pick an arbitrary tab to kill/harvest (PR #460 HIGH).
    function flush() { if (sess == sid && status == "completed" && haslast && tid ~ /^[A-Za-z0-9]+$/) { n++; out = tid "\t" lastv } }
    /^- / { flush(); tid = $2; status = $3; sess = ""; haslast = 0; lastv = "" }   # new tab block: "- <TARGET-ID> <status> …"
    /^[[:space:]]*session=/ { s = $0; sub(/^[[:space:]]*session=/, "", s); sess = s }
    /^[[:space:]]*last=/    { l = $0; sub(/^[[:space:]]*last=/, "", l); if (length(l) > 0) { haslast = 1; lastv = l } }
    END { flush(); if (n == 1) print out }
  ' "$1" 2>/dev/null
}

_ultra_oracle_run_watched() {
  local cap="$1" errf="$2"; shift 2
  local pid grace stable sig waits laststable streamed everstreamed start now elapsed ownrc _sig _signame _sigcode
  local sidw tabsnap tabstate ref curlast prev_last="" last_probe_at=0
  _UORA_CONFIRMED_REF=""   # fresh per run; only OUR confirmed tab-probe sets it (below)
  "$@" >"$errf" 2>&1 &
  pid=$!
  # If this subshell is interrupted (INT/TERM/HUP) or exits before the watchdog reaches its own
  # terminate, clean up the oracle child so it can't keep driving the browser consult orphaned.
  # Each signal arm runs the BOUNDED `_uora_terminate` (TERM->KILL, never an indefinite wait even if
  # oracle ignores TERM), clears the traps, then EXITS with that signal's conventional status
  # (128+signum: INT->130, TERM->143, HUP->129) — preserving interruption identity WITHOUT re-raising.
  # We deliberately avoid `kill -s <sig> $BASHPID`: BASHPID is a bash-4 builtin, UNSET on the repo's
  # supported macOS bash 3.2, so under an inherited `set -u` it would abort the trap with an
  # unbound-variable error before cleanup completes (Codex P2, PR #460). Encoding the identity in the
  # exit code is bash-3.2-safe and equivalent for a disowned background subshell (nothing waits on
  # its signal disposition). The EXIT arm handles a non-signal abnormal exit. All are cleared
  # (`trap - …`) before every NORMAL return below so none fire on an already-reaped pid.
  for _sig in INT:130 TERM:143 HUP:129; do
    _signame="${_sig%%:*}"; _sigcode="${_sig##*:}"
    # shellcheck disable=SC2064  # $_signame/$_sigcode expanded NOW (per-signal identity); $pid deferred
    # `|| true` keeps the handler errexit-safe: _uora_terminate returns 143 on a normal kill, which
    # under a caller's `set -e` would otherwise abort the trap before it clears traps / exits.
    trap "{ [ -n \"\$_UORA_STATUS_PID\" ] && _uora_terminate \"\$_UORA_STATUS_PID\" >/dev/null 2>&1; } || true; _uora_terminate \"\$pid\" >/dev/null 2>&1 || true; trap - INT TERM HUP EXIT; exit $_sigcode" "$_signame"
  done
  trap '{ [ -n "$_UORA_STATUS_PID" ] && _uora_terminate "$_UORA_STATUS_PID" >/dev/null 2>&1; } || true; _uora_terminate "$pid" >/dev/null 2>&1 || true' EXIT
  grace="${ULTRA_ORACLE_HUNG_GRACE:-45}";  case "$grace"  in ''|*[!0-9]*) grace=45;;  esac
  # Minimum seconds the LAST streaming line must have reported content unchanged ("last change Ns
  # ago") before a vanished indicator counts as completion — INDEPENDENT stability evidence (see
  # the three-condition gate below). Guards against cutting an active stream.
  stable="${ULTRA_ORACLE_HUNG_STABLE:-45}"
  case "$stable" in ''|*[!0-9]*) stable=45;; esac
  stable="${stable#"${stable%%[!0]*}"}"            # strip leading zeros ("045"->"45", "00"->"")
  case "$stable" in '') stable=45;; esac           # 0/all-zero must NOT disable the stability guard
  start="$(date +%s)"
  # Iteration backstop: `date +%s` is WALL-CLOCK, so a backward system-clock adjustment could keep
  # `elapsed` below cap and extend the run unbounded. The loop sleeps ~3s per turn, so a monotonic
  # count bounds it regardless of clock: cap/3 turns for the cap itself + a SMALL slack (+10 ≈ 30s)
  # for per-iteration work. Kept small on purpose — the .rc waiters give only cap+90s, and the
  # subshell still needs its salvage harvest (<=30s) + write afterward, so a larger backstop could
  # push .rc past the waiters' window. Whichever bound (elapsed OR iters) trips first ends the run.
  local iters=0 maxiters
  maxiters=$(( cap / 3 + 10 ))
  while :; do
    # Finished on its own: return oracle's rc — but REMAP a genuine 125 to 1 so the 125 sentinel
    # below is produced EXCLUSIVELY by our own confirmed-hung exit and can never be forged by
    # oracle happening to exit 125.
    if ! kill -0 "$pid" 2>/dev/null; then
      # errexit-safe: capture via `|| ownrc=$?` so a non-zero oracle exit under a caller's
      # `set -e` cannot abort before ownrc is read (which would skip the .rc marker).
      ownrc=0; wait "$pid" || ownrc=$?; [ "$ownrc" = 125 ] && ownrc=1
      trap - INT TERM HUP EXIT; return "$ownrc"
    fi
    iters=$(( iters + 1 ))
    now="$(date +%s)"; elapsed=$(( now - start ))
    [ "$elapsed" -lt 0 ] && elapsed=0                 # clock went backward -> lean on the iters backstop
    # Check the hung signature BEFORE the hard cap: if the confirmed-hung signature lands in the
    # same interval the cap fires, the recoverable answer must win (125), not be misread as an
    # ambiguous timeout (124).
    if [ "$elapsed" -ge "$grace" ]; then
      # Heartbeat signal over oracle's OWN log — the SHARED primitive _ultra_oracle_hung_signal (so the
      # watchdog and its unit test can never drift). Computed FIRST because it also GATES the tab
      # probe below (which case this consult is in).
      sig="$(_ultra_oracle_hung_signal "$errf")"
      read -r waits laststable streamed everstreamed <<< "$sig"
      case "$waits"        in ''|*[!0-9]*) waits=0;;        esac
      case "$laststable"   in ''|*[!0-9]*) laststable=0;;   esac
      case "$streamed"     in ''|*[!0-9]*) streamed=0;;     esac
      case "$everstreamed" in ''|*[!0-9]*) everstreamed=0;; esac
      # PRIMARY completed-but-hung signal (#458 GAP 1): oracle's OWN `status --browser-tabs`. It covers
      # the fast-response hang the streaming FALLBACK below CANNOT — a short reply never emits a
      # "response streaming" heartbeat, so laststream stays 0 and the three-condition streaming gate can
      # never pass (the common real-world case the merged fix missed). GATED to `everstreamed == 0`
      # (MONOTONIC never-streamed — laststream alone resets after reasoning, PR #460 HIGH) ON PURPOSE:
      # a response that EVER streamed is left entirely to the
      # streaming heuristic, whose independent content-stability floor guards it. This sidesteps a real
      # trap (PR #460 review, HIGH): oracle's `last=` preview is truncated to ~120 chars, so a LONG
      # answer still growing beyond the preview shows an identical `last=` across probes; confining the
      # tab probe to the non-streaming case keeps it away from long, still-growing responses. Probe
      # every ~5th iteration (~15s) to bound the extra `oracle status` spawn; the query is bounded by
      # _uora_status_snapshot (TERM->KILL to a temp FILE, not a pipeline — a hung `oracle status` can't
      # stall the watchdog). Per-dispatch UNIQUE slugs (see the argv build) guarantee ONE fresh tab per
      # session, so `completed` here is OUR answer, never a reused-tab stale prior verdict. STABILITY
      # GUARD: require the SAME completed preview on two probes scheduled by WALL-CLOCK ≥15s apart
      # (`now - last_probe_at`, NOT an iteration count — an iteration's duration varies with the probe
      # cost, so counting drifts) before killing — dodges a mid-render `completed`+partial flit. The
      # The status query is DEADLINE-BOUNDED to the remaining budget (`cap - elapsed`, passed to
      # _uora_status_snapshot) and skipped entirely in the last 2s, so a hung `oracle status` cannot
      # push the hard cap out. ponytail: no machine-readable oracle status API exists.
      if [ "$everstreamed" = 0 ] && [ $(( now - last_probe_at )) -ge 15 ] && [ $(( cap - elapsed )) -gt 2 ]; then
        last_probe_at="$now"
        sidw="$(_ultra_oracle_extract_sid "$errf" 2>/dev/null)" || sidw=""
        ref=""; curlast=""
        if [ -n "$sidw" ]; then
          tabsnap="$(mktemp 2>/dev/null)" || tabsnap=""
          if [ -n "$tabsnap" ]; then
            _uora_status_snapshot "$tabsnap" "$(( cap - elapsed - 2 ))"   # -2 reserves the ~1s TERM/KILL grace
            tabstate="$(_ultra_oracle_tab_ref "$tabsnap" "$sidw")"   # "<tid>\t<last>" or empty
            rm -f "$tabsnap"
            ref="${tabstate%%$'\t'*}"; curlast="${tabstate#*$'\t'}"
            [ "$tabstate" = "$ref" ] && curlast=""   # no TAB -> empty state, not a real last
          fi
        fi
        if [ -n "$ref" ] && [ "$curlast" = "$prev_last" ]; then
          # Completed AND stable across two probes -> confirmed done. Publish the confirmed tab target so
          # salvage binds to THIS tab without a second (fallible) status query. Same raced-completion
          # handling as the streaming path: _uora_terminate returns the real status if oracle finished
          # naturally in the window, else 143 -> our 125 sentinel.
          _UORA_CONFIRMED_REF="$ref"
          ownrc=0; _uora_terminate "$pid" || ownrc=$?; trap - INT TERM HUP EXIT
          case "$ownrc" in 143) return 125;; *) [ "$ownrc" = 125 ] && ownrc=1; return "$ownrc";; esac
        fi
        prev_last="$curlast"   # remember this probe's answer; a stable repeat next probe fires above
      fi
      # Completed-but-hung FALLBACK over oracle's OWN heartbeat (streamed-then-stalled long responses).
      # Refresh elapsed FIRST: the tab-status probe above may have spent several seconds (status query
      # + TERM/KILL), so re-read the clock before the hung/hard-cap checks so a bounded status stall
      # can't push the effective cap out by a whole probe's worth of time (PR #460 MEDIUM).
      now="$(date +%s)"; elapsed=$(( now - start )); [ "$elapsed" -lt 0 ] && elapsed=0
      if [ "$streamed" = 1 ] && [ "$waits" -ge 2 ] && [ "$laststable" -ge "$stable" ]; then
        # Confirmed hung (indicator gone + content stable) -> salvage. But oracle may have exited
        # NATURALLY in the window before this call; _uora_terminate returns its real status, so a
        # raced-to-completion run is honored (its own rc) rather than forced to the 125 sentinel.
        # errexit-safe: _uora_terminate returns 143 on a normal kill (non-zero), so capture via
        # `|| ownrc=$?` lest a caller's `set -e` abort before the sentinel is translated.
        ownrc=0; _uora_terminate "$pid" || ownrc=$?; trap - INT TERM HUP EXIT
        case "$ownrc" in 143) return 125;; *) [ "$ownrc" = 125 ] && ownrc=1; return "$ownrc";; esac
      fi
    fi
    if [ "$elapsed" -ge "$cap" ] || [ "$iters" -ge "$maxiters" ]; then   # hard cap (elapsed OR monotonic backstop); ambiguous -> no salvage
      ownrc=0; _uora_terminate "$pid" || ownrc=$?; trap - INT TERM HUP EXIT
      case "$ownrc" in 143) return 124;; *) [ "$ownrc" = 125 ] && ownrc=1; return "$ownrc";; esac
    fi
    sleep 3
  done
}

# _ultra_oracle_diagnose_hint <err-file> -> print ONE human-actionable line (no
# trailing newline) naming the operator's next step for a KNOWN oracle failure
# signature, else print nothing. Matches the ABE / login / Cloudflare cases from
# issue #340 so a failed consult tells the operator WHAT to do instead of surfacing a
# bare 'error' token. Read-only; matches only oracle's own captured STDOUT text, never
# any secret (the token is never written to the .err file).
_ultra_oracle_diagnose_hint() {
  local f="$1"
  [[ -r "$f" ]] || return 0
  # Backticks below are LITERAL operator-facing command examples, not command
  # substitution — the strings are printed verbatim, never evaluated.
  # shellcheck disable=SC2016
  if grep -qiE 'no chatgpt cookies|cookie extraction is unavailable|cookie sync' "$f" 2>/dev/null; then
    printf 'cookie sync unavailable (this Chrome blocks programmatic cookie decryption, #340): set ultraOracle.attachRunning=true in ~/.claude/busdriver.json (ADR 0020) — attach mode reuses a signed-in browser and needs no cookie decryption'
  elif grep -qiE 'login button detected|session not detected|not signed in|please log ?in' "$f" 2>/dev/null; then
    # Recovery differs per transport: attach mode has ONE browser the operator signs into,
    # while remoteHost/cookiePath/profile runs have their own session sources. Naming the
    # attached window unconditionally would misdirect every non-attach install.
    if ultra_oracle_attach_running; then
      printf 'ChatGPT session not detected: sign in to the attached Chrome window (profile ultraOracle.attachProfileDir, default ~/Library/Application Support/oracle-attach; run scripts/ultra-oracle-attach-preflight.sh to open it), then re-run'
    else
      printf 'ChatGPT session not detected: sign in to the browser session this transport uses (oracle serve --manual-login window for remoteHost, or the profile behind cookiePath/chromeProfileDir), then re-run'
    fi
  elif grep -qiE 'just a moment|cloudflare|verify you are human|are you human|challenge' "$f" 2>/dev/null; then
    # ADR 0020: a challenge means the run used an oracle-LAUNCHED Chrome (automation-
    # fingerprinted). Clearing the check by hand does not stick — switching transports does.
    # Under attach mode the browser is NOT oracle-launched, so that advice would be a no-op;
    # point at the attached window instead.
    if ultra_oracle_attach_running; then
      printf 'Cloudflare "Just a moment" challenge in the ATTACHED browser: complete the check in that Chrome window (profile ultraOracle.attachProfileDir), then re-run'
    else
      printf 'Cloudflare "Just a moment" challenge: oracle-launched Chrome is fingerprinted — set ultraOracle.attachRunning=true in ~/.claude/busdriver.json (ADR 0020) to attach to an ordinary browser instead'
    fi
  fi
}

# ultra_oracle_consult --prompt <t> | --prompt-file <p>  [--context <glob>]... \
#   --out <path> [--mode blocking|background] [--timeout-cap-seconds <n>] [--slug <words>]
# Prints exactly one of: ok | skipped:unavailable | skipped:user | timeout | error | dispatched
#
# --prompt-file is the ADAPTER's interface (injection-safe for untrusted text);
# oracle v0.15.0 has no --prompt-file flag, so the file content is passed via
# --prompt "$(cat ...)". Command-substitution output is NOT re-parsed by the
# shell, so backticks/$()/$VAR in the file stay literal.
ultra_oracle_consult() {
  # oracle requires a 3-5 word --slug; default accordingly (callers override).
  local prompt="" prompt_file="" mode="blocking" out="" slug="ultra oracle consult" cap=""
  local -a ctx_arr=()   # indexed array (bash-3.2 safe) — preserves paths with spaces
  while [ $# -gt 0 ]; do
    # Value-flags require an argument; a missing value returns a typed 'error'
    # rather than an unbound-variable crash under the caller's `set -u`.
    case "$1" in
      --prompt|--prompt-file|--context|--mode|--out|--slug|--timeout-cap-seconds)
        [ $# -ge 2 ] || { printf 'error'; return 1; } ;;
    esac
    case "$1" in
      --prompt) prompt="$2"; shift 2;;
      --prompt-file) prompt_file="$2"; shift 2;;
      --context) ctx_arr+=("$2"); shift 2;;
      --mode) mode="$2"; shift 2;;
      --out) out="$2"; shift 2;;
      --slug) slug="$2"; shift 2;;
      --timeout-cap-seconds) cap="$2"; shift 2;;
      *) shift;;
    esac
  done
  [[ -n "$out" ]] || { printf 'error'; return 1; }
  # Require a prompt source — otherwise oracle would be dispatched with an empty
  # prompt and could return a meaningless advisory.
  [[ -n "$prompt" ]] || [[ -n "$prompt_file" ]] || { printf 'error'; return 1; }
  [[ -n "$cap" ]] || cap="$(ultra_oracle_timeout_cap)"
  # Validate the cap regardless of source (explicit --timeout-cap-seconds bypasses
  # ultra_oracle_timeout_cap); a 0/non-numeric value would break the fail-closed timeout.
  # Strip leading zeros on an all-digit cap so "0600" normalizes to "600" and any
  # all-zero string ("00") collapses to "" — rejected below. A 0 cap is unsafe:
  # `timeout 0` / the Perl fallback's `alarm 0` DISABLE the timeout (unbounded run).
  case "$cap" in *[!0-9]*) : ;; *) cap="${cap#"${cap%%[!0]*}"}" ;; esac
  case "$cap" in ''|*[!0-9]*|0)
    echo "ultra-oracle: invalid timeout cap '$cap' — using config/default" >&2
    cap="$(ultra_oracle_timeout_cap)" ;;
  esac
  # Clamp an explicit numeric --timeout-cap-seconds to the same ceiling
  # ultra_oracle_timeout_cap enforces (default 3600s) — otherwise an explicit cap
  # bypasses the guardrail and can stall a reviewer with an arbitrarily long wait.
  local _uora_cap_ceil
  _uora_cap_ceil="$(_ultra_oracle_sanitize_ceiling "${ULTRA_ORACLE_CAP_CEILING:-3600}")"
  # A value with 19+ digits would overflow bash's signed-64-bit `-gt` (INT64_MAX is
  # 19 digits) and could wrap to compare as SMALLER, slipping an absurd cap past the
  # guardrail; anything that long is nonsensical as a second count, so clamp it
  # outright. Below 19 digits the numeric `-gt` is safe.
  if [ "${#cap}" -ge 19 ] || [ "$cap" -gt "$_uora_cap_ceil" ]; then
    echo "ultra-oracle: timeout cap $cap exceeds ceiling $_uora_cap_ceil — clamping" >&2
    cap="$_uora_cap_ceil"
  fi
  # Fail closed if the output dir can't be created — otherwise background mode
  # would return 'dispatched' but the child could never write "$out.rc".
  mkdir -p "$(dirname "$out")" 2>/dev/null || { printf 'error'; return 1; }
  # Clear any stale output from a prior run at the same path before dispatching.
  # A non-empty leftover "$out" would make the fail-closed verdict check
  # succeed even if this oracle invocation exits 0 but writes nothing — silently
  # returning ok with stale content. Truncate both output and .rc marker so each
  # run starts from a clean slate regardless of caller's output-path reuse policy.
  # `--` guards against option-looking paths; fail CLOSED if the cleanup itself
  # fails — a surviving stale file is the exact bug this prevents, so suppressing
  # the error would defeat the purpose. `rm -f` is a no-op on nonexistent files,
  # so the || branch only fires when a file EXISTS but cannot be removed.
  rm -f -- "$out" "$out.rc" "$out.rc.partial" "$out.err" "$out.hint" || {
    echo "ultra-oracle: cannot clear stale output '$out' — failing closed" >&2
    printf 'error'; return 1
  }

  # Operator escape (persistent opt-out; fail-closed-with-escape). State-dir resolved.
  local state_dir git_root skip
  state_dir="${BUSDRIVER_STATE_DIR:-.claude}"
  git_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  skip="${git_root:+$git_root/}$state_dir/skip-ultra-oracle.local"
  if [[ -f "$skip" ]]; then printf 'skipped:user'; return 0; fi

  # Health check — fail CLOSED (typed), never silent.
  if ! is_cli_available oracle; then printf 'skipped:unavailable'; return 3; fi

  local model profile cookie_path remote_host remote_token
  # The token we inject via ORACLE_REMOTE_TOKEN — set ONLY on the remoteHost delegation
  # path (below). Empty elsewhere so a configured remoteToken can NEVER pair with an
  # ambient host (oracle-config browser.remoteHost / ORACLE_REMOTE_HOST) and transmit to a
  # destination busdriver did not pin: the confidentiality guarantee holds only because we
  # both pass --remote-host AND supply the credential exclusively in that same branch.
  local _uora_env_token=""
  # Declared here (not only inside the attach branch) so the #458 salvage calls in the
  # blocking/background paths can reference it in NON-attach runs without tripping `set -u`.
  # The attach branch assigns it; salvage no-ops when it stays empty.
  local _uora_target=""
  model="$(ultra_oracle_model)"; profile="$(ultra_oracle_chrome_profile)"
  cookie_path="$(ultra_oracle_cookie_path)"
  remote_host="$(ultra_oracle_remote_host)"; remote_token="$(ultra_oracle_remote_token)"

  # Per-dispatch UNIQUE slug (#458 GAP 1 root cause). Callers pass a STABLE slug
  # ("ultra oracle plan review"), which makes oracle REUSE one stored session/tab across
  # consults. A reused tab is why the tab-status completion probe is unsafe: verified live
  # 2026-07-23, a re-dispatch leaves the PREVIOUS answer visible under `completed` until the
  # new response lands, spawns MULTIPLE tabs bound to the same `session=`, and shows
  # mid-render garbage in `last=` — so the probe could kill the live consult and harvest the
  # prior review's verdict. Appending a nonce gives every dispatch its OWN fresh conversation
  # (one tab, `last=` empty until OUR answer), which is exactly what the probe needs and what
  # unique-slug live runs recover cleanly. Fire-and-forget consults never reattach by slug, so
  # uniqueness costs nothing (and --force already handles the dup-guard, which keys on the
  # prompt not the slug).
  #
  # The nonce must be COMPACT and go FIRST: oracle 0.16.0 normalizes a slug to the first FIVE words
  # and truncates each word to 10 CHARACTERS (verified live 2026-07-23: the session came out
  # "…-u178477529" — a longer nonce lost its $RANDOM/$$ tail to the 10-char cut, and a 5-word caller
  # slug would drop a trailing nonce word entirely). So build a ≤10-char hex token (prefix + 16 bits
  # of epoch-seconds + 15 bits of $RANDOM = "x########", 9 chars) and PREPEND it. To make a same-second
  # collision astronomically unlikely (one $RANDOM word alone is 1/32768 — PR #460 HIGH), use TWO ≤10-
  # char nonce words drawing THREE independent $RANDOM values plus the epoch; both survive as words 1-2
  # of the 5-word limit. printf -v is bash-3.1+, safe on the repo's bash 3.2. Defense in depth:
  # _ultra_oracle_tab_ref additionally fails closed if two tabs ever share one session.
  local _uora_nonce _uora_epoch
  _uora_epoch="$(date +%s)"
  printf -v _uora_nonce 'x%04x%04x y%04x%04x' "$(( _uora_epoch & 0xffff ))" "$RANDOM" "$RANDOM" "$RANDOM"
  slug="$_uora_nonce $slug"
  # Build argv (set -- positional building is bash-3.2 safe).
  # --force bypasses oracle's duplicate-prompt guard (#333). That guard blocks a new run
  # when a session with the SAME prompt signature is still status="running"
  # (duplicatePromptGuard.js keys on the prompt, NOT the slug). Every ultra-oracle consult is
  # fire-and-forget: it reads its own RUN_ID-scoped --write-output and never reattaches, so
  # "prefer reattaching" does not apply — a fresh run each time is exactly what we want.
  # Critically, oracle never reaps a crashed/interrupted session (its status stays "running"
  # in the store forever), so without --force a single stale phantom permanently blocks EVERY
  # future same-prompt dispatch — most visibly blueprint-review, whose prompt is fixed (design
  # goes via --context). --force makes us immune regardless of WHY a stale session lingers.
  set -- --engine browser -m "$model" --timeout "$cap" --force \
         --write-output "$out" --no-notify --heartbeat 30 --slug "$slug"
  # Session source, in precedence order (all opt-in; empty by default so we do NOT
  # expose the operator's main browser session unless explicitly configured):
  #   0. attachRunning — attach to an ordinary, already-running Chrome (ADR 0020). The
  #                     only path that is not Cloudflare-challenged: oracle's OWN Chrome
  #                     launches carry automation flags Cloudflare fingerprints, so
  #                     serve/cookiePath consults hit a "Just a moment" wall that
  #                     re-login never clears. Highest precedence for that reason.
  #   1. remoteHost   — delegate to a running `oracle serve` (issue #340). The ONLY
  #                     path that works when Chrome blocks programmatic cookie
  #                     decryption (recent cookie-encryption hardening), where
  #                     cookiePath/copy-profile cannot reuse the session. serve owns
  #                     its own signed-in browser.
  #   2. cookiePath   — decrypt a live Cookies DB in place via the OS keychain.
  #   3. chromeProfileDir — clone a dedicated profile (heaviest; last resort).
  # These are MUTUALLY EXCLUSIVE: when remoteHost is set we pass ONLY
  # --remote-host/--remote-token and never also --browser-cookie-path/--copy-profile
  # (a second, ABE-broken session source that would confuse oracle). A configured
  # cookiePath is AUTHORITATIVE within its own branch: if it is set but unreadable we
  # FAIL CLOSED rather than let oracle default to the standard Chrome profile and
  # silently reuse whatever ChatGPT session is signed in there (wrong account / a
  # data-boundary surprise the operator did not authorize). Fix the path or unset it.
  if ultra_oracle_attach_running; then
    # Preflight resolves (and self-heals) the attach target: ensures a vanilla Chrome is
    # running on the discoverable profile and that its DevToolsActivePort is current,
    # then prints `ok <host>:<port>`. The port is DYNAMIC by design (Chrome only records
    # the file when it picks its own), so it is resolved per-run and never pinned.
    # Fail CLOSED: without a live attach target oracle would silently fall back to
    # launching its own Chrome and walk straight back into the Cloudflare wall.
    local _uora_pf   # _uora_target hoisted above (referenced by #458 salvage in non-attach runs too)
    _uora_pf="$("$_ULTRA_ORACLE_PREFLIGHT" "$(ultra_oracle_attach_profile_dir)" 2>&1)" || {
      echo "ultra-oracle: attach preflight failed — ${_uora_pf}" >&2
      printf 'error'; return 1
    }
    # Parse STRICTLY. A loose `*:[0-9]*` match accepts `garbage:1x`, trailing junk, an
    # out-of-range port, or a NON-LOOPBACK host — and whatever survives is handed to
    # oracle as --remote-chrome, i.e. the address a browser session is driven through.
    # Take the LAST line only (diagnostics may precede it), require the exact `ok <target>`
    # shape, pin the host to loopback, and range-check the port.
    _uora_target="${_uora_pf##*$'\n'}"
    case "$_uora_target" in
      "ok 127.0.0.1:"*) _uora_target="${_uora_target#ok }" ;;
      *) echo "ultra-oracle: attach preflight returned no usable target ('$_uora_pf')" >&2
         printf 'error'; return 1 ;;
    esac
    local _uora_port="${_uora_target#127.0.0.1:}"
    case "$_uora_port" in
      ''|*[!0-9]*) _uora_port="" ;;
    esac
    # Length-guard BEFORE the numeric comparisons (same reasoning as the timeout cap above):
    # an all-digit value with 19+ digits overflows bash's signed-64-bit `-lt`/`-gt`, which
    # then return status 2 and let the `||` chain fall through — validation failing OPEN on
    # exactly the malformed input it exists to reject. A port is at most 5 digits.
    if [[ -z "$_uora_port" ]] || [ "${#_uora_port}" -gt 5 ] \
       || [ "$_uora_port" -lt 1 ] || [ "$_uora_port" -gt 65535 ]; then
      echo "ultra-oracle: attach preflight returned an invalid port ('$_uora_pf')" >&2
      printf 'error'; return 1
    fi
    # --browser-attach-running is mutually exclusive with --browser-port/--browser-debug-port
    # (oracle rejects the combination outright) and with the remoteHost/cookiePath/profile
    # session sources — attach mode reuses a browser rather than configuring one.
    set -- "$@" --browser-attach-running --remote-chrome "$_uora_target"
  elif [[ -n "$remote_host" ]]; then
    # remoteToken is REQUIRED with remoteHost — fail CLOSED if empty. Empty would leave the
    # consult to fail auth against a token-protected serve; refuse up front with guidance.
    if [[ -z "$remote_token" ]]; then
      echo "ultra-oracle: remoteHost set but remoteToken empty — failing closed (set ultraOracle.remoteToken in ~/.claude/busdriver.json; the consult would otherwise fail auth against a token-protected 'oracle serve')" >&2
      printf 'error'; return 1
    fi
    # Deliver the token via the ORACLE_REMOTE_TOKEN env at the invocation sites — NOT
    # --remote-token on argv, which `ps` exposes to same-user/root for the whole
    # multi-minute consult. Only the non-secret host goes on argv. Scope the env token to
    # _uora_env_token, set ONLY here, so it is delivered EXCLUSIVELY on this path — never
    # paired with an ambient host on a cookiePath/profile run.
    #
    # Confidentiality does NOT rest on this token. Oracle resolves the destination as
    #   host  = cliHost(--remote-host) ?? config.browser.remoteHost ?? ORACLE_REMOTE_HOST
    #   token = cliToken(--remote-token) ?? config.browser.remoteToken ?? ORACLE_REMOTE_TOKEN
    # (verified in oracle 0.15.2 remoteServiceConfig.js). We ALWAYS pass --remote-host here,
    # so the destination is PINNED to busdriver's USER-config host — no ambient config/env
    # can redirect the plan elsewhere. The token is merely the bearer credential presented
    # TO that pinned host: if an ambient oracle-config `browser.remoteToken` outranks our env
    # token (config > env), the only effect is the pinned serve accepts or rejects the
    # connection — a wrong token fails auth LOUDLY (the #340 hint surfaces), it can never
    # divert the plan. So env delivery is safe WITHOUT out-parsing oracle's (JSON5 keys,
    # symlink-physical CWD) config discovery to detect an ambient token.
    _uora_env_token="$remote_token"
    set -- "$@" --remote-host "$remote_host"
  elif [[ -n "$cookie_path" ]]; then
    if [[ -r "$cookie_path" ]]; then
      set -- "$@" --browser-cookie-path "$cookie_path"
    else
      echo "ultra-oracle: cookiePath '$cookie_path' unreadable — failing closed (configured cookiePath is authoritative; NOT degrading to the default Chrome session or --copy-profile)" >&2
      printf 'error'; return 1
    fi
  elif [[ -n "$profile" ]] && [[ -d "$profile" ]]; then
    set -- "$@" --copy-profile "$profile"
  fi
  # Hide the automation Chrome window ONLY when explicitly opted in (B8). Passing
  # --browser-hide-window was root-caused as breaking oracle's ChatGPT browser engine,
  # so the window is now VISIBLE by default; set ultraOracle.hideWindow=true to restore.
  # Skip entirely when attach mode is active: oracle documents
  # --browser-attach-running as mutually exclusive with --browser-hide-window, so
  # passing both is a hard CLI rejection — attach mode always reuses (and never
  # hides) the operator's already-visible Chrome window.
  if ! ultra_oracle_attach_running && ultra_oracle_hide_window; then set -- "$@" --browser-hide-window; fi
  local g; for g in "${ctx_arr[@]:-}"; do [[ -n "$g" ]] && set -- "$@" --file "$g"; done
  if [[ -n "$prompt_file" ]]; then
    # Fail closed if the prompt file is unreadable/empty — otherwise a silent cat
    # failure would invoke oracle with an empty prompt.
    if [[ ! -r "$prompt_file" ]] || [[ ! -s "$prompt_file" ]]; then printf 'error'; return 1; fi
    local pf_size; pf_size="$(wc -c < "$prompt_file" 2>/dev/null || echo 0)"
    if [ "$pf_size" -gt "${ULTRA_ORACLE_INLINE_BYTES:-100000}" ]; then
      # Too large to safely inline into argv (ARG_MAX) — attach as a file instead.
      set -- "$@" --file "$prompt_file" \
        --prompt "Follow the instructions in the attached file: $(basename "$prompt_file")"
    else
      local pf_content; pf_content="$(cat "$prompt_file")"
      set -- "$@" --prompt "$pf_content"
    fi
  else set -- "$@" --prompt "$prompt"; fi

  if [[ "$mode" = "background" ]]; then
    # RUN_ID-scoped output is the CALLER's responsibility (--out includes RUN_ID).
    # Emit an .rc marker on completion so the caller can bounded-wait + read status.
    # disown so an early parent exit cannot orphan/kill it before the .rc lands.
    ( set +e   # a caller's errexit must NOT abort the subshell before "$out.rc" is written
      # Capture oracle STDOUT+STDERR to "$out.err" (B8): oracle emits its failure
      # diagnostics on STDOUT, so the old >/dev/null 2>&1 discarded them and every
      # failure looked silent. Keep the file on failure for diagnosis; remove on success.
      # #458: ONLY the attach path gets the completed-but-hung watchdog + salvage — it is the
      # sole mode where the answer survives in a live tab AND where oracle forks no Chrome to
      # orphan. Non-attach modes run under `_portable_timeout` EXACTLY as the pre-#458 background
      # path did — this PR does not alter their teardown (whatever `timeout(1)`/the perl fallback
      # do about oracle's launched Chrome is unchanged, in or out of scope of #458), and no
      # salvage is possible there without a live tab.
      if ultra_oracle_attach_running && [[ -n "$_uora_target" ]]; then
        ORACLE_REMOTE_TOKEN="$_uora_env_token" _ultra_oracle_run_watched "${cap}" "$out.err" oracle "$@"; _uora_bg_rc=$?
        # Salvage ONLY on positive completion evidence: 125 = confirmed completed-but-hung (stream
        # ended), or exit-0-but-empty (oracle concluded, extraction raced). NOT on a plain 124
        # hard cap — that response may still be mid-stream, and harvesting a partial would promote
        # an incomplete answer to a verdict. Harvest re-reads the live tab and normalizes to 0.
        if [[ "$_uora_bg_rc" = 125 ]] || { [[ "$_uora_bg_rc" = 0 ]] && ! _ultra_oracle_verdict_ok "$out"; }; then
          _ultra_oracle_salvage "$out" "$cap" "$_uora_target" && _uora_bg_rc=0
        fi
        # A confirmed-hung run that salvage did NOT recover is still a timeout to the caller.
        [[ "$_uora_bg_rc" = 125 ]] && _uora_bg_rc=124
      else
        ORACLE_REMOTE_TOKEN="$_uora_env_token" _portable_timeout "${cap}" oracle "$@" >"$out.err" 2>&1; _uora_bg_rc=$?
      fi
      # Map exit-0-but-empty-verdict to failure so the .rc matches blocking mode's
      # fail-closed contract (timeout already surfaces as rc 124). Salvage may have fixed it.
      [[ "$_uora_bg_rc" = 0 ]] && ! _ultra_oracle_verdict_ok "$out" && _uora_bg_rc=1
      # On ANY non-success, clear $out: a hard-capped/killed oracle can leave a PARTIAL verdict
      # there (it writes --write-output directly), and though the waiters gate on .rc=0, a stale
      # partial next to a 124 marker is a latent misread. Success keeps the (salvaged/normal) body.
      [[ "$_uora_bg_rc" != 0 ]] && : > "$out" 2>/dev/null
      if [[ "$_uora_bg_rc" = 0 ]]; then
        rm -f "$out.err" "$out.hint"   # success: drop the captured stdout + any stale hint
      else
        # Persist a human-actionable hint (#340) next to the .err so the caller's FAILED
        # banner can name the operator's next step, not just a bare status code.
        _uora_hint="$(_ultra_oracle_diagnose_hint "$out.err")"
        if [[ -n "$_uora_hint" ]]; then printf '%s' "$_uora_hint" > "$out.hint"; else rm -f "$out.hint"; fi
      fi
      # Write .rc ATOMICALLY and LAST: the waiters treat .rc's existence as completion, so a
      # created-but-not-yet-written .rc could be read empty (reported as a spurious timeout,
      # no hint). Rename is atomic on one filesystem, and it lands after .err/.hint are
      # already in place, so once a waiter sees .rc every sibling file is fully written.
      printf '%s' "$_uora_bg_rc" > "$out.rc.partial" && mv -f "$out.rc.partial" "$out.rc" ) &
    disown 2>/dev/null || true
    printf 'dispatched'; return 0
  fi

  # blocking, under the portable timeout cap. Keep stderr (oracle's --heartbeat
  # progress) on the terminal; capture STDOUT to "$out.err" (B8) — oracle emits its
  # failure diagnostics on STDOUT, so the old >/dev/null hid them and made every
  # failure look silent. The .err file is kept on any failure (a stderr pointer names
  # it) and removed on success.
  # errexit-safe: capture rc via `|| rc=$?` so a non-zero oracle exit cannot abort
  # the caller (this lib may be sourced under `set -e`) before the status token is
  # printed — the fail-closed 'error'/'timeout' tokens below depend on reaching them.
  local rc=0 _hint=""
  ORACLE_REMOTE_TOKEN="$_uora_env_token" _portable_timeout "${cap}" oracle "$@" >"$out.err" || rc=$?
  if [[ "$rc" = 124 ]]; then
    # #458 NOTE: blocking mode does NOT salvage on a bare timeout. Without the background
    # watchdog's heartbeat analysis a blocking timeout is ambiguous — the response could be
    # completed-but-hung OR genuinely still streaming — and harvesting a mid-stream tab would
    # promote a PARTIAL to a verdict. Blocking still recovers the safe case (exit-0-but-empty,
    # where oracle concluded) below. The completed-but-hung recovery is a background-mode
    # (blueprint-review / council) feature, which is where #458 actually bites.
    # A login/Cloudflare wall that never clears also manifests AS a timeout — the
    # partial page oracle wrote to $out.err before the cap fired can still carry the
    # signature, so name the operator's next step here too, not only on hard errors.
    _hint="$(_ultra_oracle_diagnose_hint "$out.err")"; [[ -n "$_hint" ]] && echo "ultra-oracle: $_hint" >&2
    # Clear any PARTIAL a killed oracle wrote to $out via --write-output — a timeout must leave no
    # misleading verdict artifact behind (the caller ignores $out on non-ok status, but be tidy).
    : > "$out" 2>/dev/null
    echo "ultra-oracle: timed out after ${cap}s — oracle STDOUT captured at $out.err" >&2; printf 'timeout'; return 124
  fi
  if [[ "$rc" != 0 ]]; then
    # Name the operator's next step for a known failure (ABE / login / Cloudflare, #340)
    # before the generic pointer, so a failed consult is actionable, not just 'error'.
    _hint="$(_ultra_oracle_diagnose_hint "$out.err")"; [[ -n "$_hint" ]] && echo "ultra-oracle: $_hint" >&2
    echo "ultra-oracle: oracle exited $rc — STDOUT/diagnostics captured at $out.err" >&2; printf 'error'; return 1
  fi
  if ! _ultra_oracle_verdict_ok "$out"; then
    # exit 0 but empty/degenerate verdict — extraction can race the stream (#458). Re-read
    # the stable tab once (attach mode) before failing closed.
    if _ultra_oracle_salvage "$out" "$cap" "$_uora_target"; then rm -f "$out.err"; printf 'ok'; return 0; fi
    _hint="$(_ultra_oracle_diagnose_hint "$out.err")"; [[ -n "$_hint" ]] && echo "ultra-oracle: $_hint" >&2
    echo "ultra-oracle: exit 0 but missing/degenerate verdict — oracle STDOUT at $out.err" >&2; printf 'error'; return 1
  fi   # exit 0 but missing/degenerate verdict = fail-closed (unless salvaged)
  rm -f "$out.err"   # success: drop the captured stdout
  printf 'ok'; return 0
}
