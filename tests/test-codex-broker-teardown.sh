#!/usr/bin/env bash
# tests/test-codex-broker-teardown.sh — #901: a Codex review shuts down the
# app-server broker IT started, and nothing else.
#
# `codex-companion.mjs task` keeps its app-server in a detached broker registered
# in <state root>/<slug>-<hash>/broker.json; under the review's env -i allowlist the
# state root is /tmp/codex-companion, where the plugin's SessionEnd never looks, so
# every review-started broker leaked. _execute_codex now fingerprints broker.json
# before the first dispatch (`_bd_codex_broker ... snapshot`) and afterwards shuts
# down only a broker whose registration appeared or changed (`... reap <fp>`).
#
# The companion, its broker, and the plugin lib are stubs here (no Codex, no
# network): the stub companion calls ensureBrokerSession exactly like the real one,
# and the stub broker answers broker/shutdown like app-server-broker.mjs. When the
# real openai-codex plugin is installed, every case ALSO runs against its real
# lib/ (only the broker and companion stay stubbed), so drift in the plugin's
# state layout or shutdown protocol fails here instead of leaking brokers again.
#
# Cases, per lib:
#   (a) no broker before the review  -> the review's broker is dead, its
#       broker.json and session dir are gone
#   (b) broker running before        -> reused by the review, left alive, its
#       broker.json untouched
#   (c) broker ignores broker/shutdown -> its group is SIGKILLed on a re-proven
#       identity (a member that ignores SIGTERM goes too); registration gone
#   (d) unprovable registration      -> a broker.json not in the plugin's shape, or
#       in the right shape but naming an impostor process whose command line only
#       ENDS like the broker's, is left alone and its pid never signalled; a FIFO
#       planted as broker.json neither hangs the helper nor is acted on; a
#       malformed fingerprint refuses
#   (f) litmus runner SIGKILLed after the broker started -> the orphan watchdog
#       (run-review-loop.sh _orphan_watch_start, driven in its production order) runs
#       the reap from the hand-off — also when the review child already exited with
#       the hand-off still populated; an EMPTY hand-off (reap already done) is inert
# SC2015: `cond && ok || bad` is safe, ok() always succeeds. SC2310/SC2312: the
# helpers are deliberately called inside conditions; their status IS the assertion.
# shellcheck disable=SC2015,SC2310,SC2312
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$ROOT/scripts/lib/resolve-cli.sh"
PASS=0
FAIL=0
ok() { echo "  PASS  $1"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL  $1"; FAIL=$((FAIL + 1)); }

# shellcheck source=/dev/null
source "$LIB" >/dev/null 2>&1
NODE="$(_resolve_trusted_cli_bin node 2>/dev/null || true)"
if [[ -z "$NODE" ]]; then
  echo "SKIP: no trusted node — the broker teardown helper cannot run"
  exit 0
fi

WORK="$(mktemp -d)"
WORK="$(cd "$WORK" && pwd -P)"
PIDS_TO_KILL=()
REPOS=()
SESSION_DIRS=()
cleanup() {
  local p r cmd
  # Most recorded pids are long gone by now (stopped by the very teardown under test), so
  # a number may have been reused: signal one only while its command line still carries
  # this run's private $WORK path, which every process the test starts is given (hold()
  # for plain waits). A live pid owns its group id, so the group kill reaches no one else.
  for p in ${PIDS_TO_KILL[@]+"${PIDS_TO_KILL[@]}"}; do
    cmd="$(ps -ww -o command= -p "$p" 2>/dev/null)" || continue
    case "$cmd" in
      *"$WORK"*) ;;
      *) continue ;;
    esac
    kill -KILL "-$p" 2>/dev/null || kill -KILL "$p" 2>/dev/null || true
  done
  for r in ${REPOS[@]+"${REPOS[@]}"}; do
    rm -rf "/tmp/codex-companion/$(basename "$r")"-* 2>/dev/null || true
    rm -f "$(lockfile "$r")" 2>/dev/null || true
  done
  for r in ${SESSION_DIRS[@]+"${SESSION_DIRS[@]}"}; do rm -rf "$r" 2>/dev/null || true; done
  rm -rf "$WORK"
}
trap cleanup EXIT
# A 300s wait whose command line names this run (cleanup matches on $WORK); $1 overrides
# the marker where $WORK is not in scope. It execs, so call it only in a subshell (`&` or
# `$(...)`), where its pid is then the waiting process itself.
hold() { exec /usr/bin/perl -e 'sleep 300' "${1:-$WORK}"; }

# ── stub plugin ─────────────────────────────────────────────────────────────
STUB="$WORK/stub/scripts"
mkdir -p "$STUB/lib"
cat > "$STUB/lib/workspace.mjs" <<'JS'
import { spawnSync } from "node:child_process";
export function resolveWorkspaceRoot(cwd) {
  const r = spawnSync("git", ["rev-parse", "--show-toplevel"], { cwd, encoding: "utf8" });
  return r.status === 0 ? r.stdout.trim() : cwd;
}
JS
# Same algorithm as openai-codex 1.0.5 scripts/lib/state.mjs resolveStateDir.
cat > "$STUB/lib/state.mjs" <<'JS'
import { createHash } from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { resolveWorkspaceRoot } from "./workspace.mjs";
export function resolveStateDir(cwd) {
  const root = resolveWorkspaceRoot(cwd);
  let canon = root;
  try { canon = fs.realpathSync.native(root); } catch { canon = root; }
  const slug = (path.basename(root) || "workspace").replace(/[^a-zA-Z0-9._-]+/g, "-").replace(/^-+|-+$/g, "") || "workspace";
  const hash = createHash("sha256").update(canon).digest("hex").slice(0, 16);
  const pd = process.env.CLAUDE_PLUGIN_DATA;
  return path.join(pd ? path.join(pd, "state") : path.join(os.tmpdir(), "codex-companion"), `${slug}-${hash}`);
}
JS
# The subset of broker-lifecycle.mjs the companion and the teardown use.
cat > "$STUB/lib/broker-lifecycle.mjs" <<'JS'
import fs from "node:fs";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import { spawn } from "node:child_process";
import { resolveStateDir } from "./state.mjs";
const file = (cwd) => path.join(resolveStateDir(cwd), "broker.json");
const sock = (ep) => ep.slice("unix:".length);
async function ready(ep, ms) {
  const t = Date.now();
  while (Date.now() - t < ms) {
    const ok = await new Promise((r) => { const s = net.createConnection({ path: sock(ep) }); s.on("connect", () => { s.end(); r(true); }); s.on("error", () => r(false)); });
    if (ok) return true;
    await new Promise((r) => setTimeout(r, 50));
  }
  return false;
}
export async function sendBrokerShutdown(ep) {
  await new Promise((resolve) => {
    const s = net.createConnection({ path: sock(ep) });
    s.setEncoding("utf8");
    s.on("connect", () => s.write(`${JSON.stringify({ id: 1, method: "broker/shutdown", params: {} })}\n`));
    s.on("data", () => { s.end(); resolve(); });
    s.on("error", resolve);
    s.on("close", resolve);
  });
}
export function loadBrokerSession(cwd) {
  try { return JSON.parse(fs.readFileSync(file(cwd), "utf8")); } catch { return null; }
}
export function clearBrokerSession(cwd) { if (fs.existsSync(file(cwd))) fs.unlinkSync(file(cwd)); }
export function teardownBrokerSession({ endpoint = null, pidFile, logFile, sessionDir = null }) {
  for (const f of [pidFile, logFile, endpoint ? sock(endpoint) : null]) if (f && fs.existsSync(f)) fs.unlinkSync(f);
  if (sessionDir && fs.existsSync(sessionDir)) { try { fs.rmdirSync(sessionDir); } catch { /* non-empty */ } }
}
export async function ensureBrokerSession(cwd, options = {}) {
  const existing = loadBrokerSession(cwd);
  if (existing && (await ready(existing.endpoint, 150))) return existing;
  const sessionDir = fs.mkdtempSync(path.join(os.tmpdir(), "cxc-"));
  const endpoint = `unix:${path.join(sessionDir, "broker.sock")}`;
  const pidFile = path.join(sessionDir, "broker.pid");
  const logFile = path.join(sessionDir, "broker.log");
  const fd = fs.openSync(logFile, "a");
  const child = spawn(process.execPath, [options.scriptPath, "serve", "--endpoint", endpoint, "--cwd", cwd, "--pid-file", pidFile], { cwd, env: process.env, detached: true, stdio: ["ignore", fd, fd] });
  child.unref();
  fs.closeSync(fd);
  if (!(await ready(endpoint, 2000))) return null;
  const session = { endpoint, pidFile, logFile, sessionDir, pid: child.pid };
  fs.mkdirSync(resolveStateDir(cwd), { recursive: true });
  fs.writeFileSync(file(cwd), `${JSON.stringify(session, null, 2)}\n`);
  return session;
}
JS
# Stub broker: answers broker/shutdown like app-server-broker.mjs. A `.stub-hang`
# file in its --cwd makes it ignore the request and park a child in its group.
cat > "$STUB/app-server-broker.mjs" <<'JS'
import fs from "node:fs";
import net from "node:net";
import path from "node:path";
import { spawn } from "node:child_process";
const a = process.argv.slice(2);
const get = (k) => a[a.indexOf(k) + 1];
const ep = get("--endpoint").slice("unix:".length);
const pidFile = get("--pid-file");
const cwd = get("--cwd");
const hang = fs.existsSync(path.join(cwd, ".stub-hang"));
fs.writeFileSync(pidFile, `${process.pid}\n`);
if (hang) {
  // A group member that ignores SIGTERM (the disposition survives exec).
  const kid = spawn("/usr/bin/perl", ["-e", "$SIG{TERM} = q(IGNORE); sleep 300", process.cwd()], { stdio: "ignore" });
  fs.writeFileSync(path.join(cwd, ".stub-child"), `${kid.pid}\n`);
}
const srv = net.createServer((s) => {
  s.setEncoding("utf8");
  let buf = "";
  s.on("data", (c) => {
    buf += c;
    let i;
    while ((i = buf.indexOf("\n")) !== -1) {
      const m = JSON.parse(buf.slice(0, i));
      buf = buf.slice(i + 1);
      if (m.method === "broker/shutdown" && !hang) {
        s.write(`${JSON.stringify({ id: m.id, result: {} })}\n`);
        srv.close();
        for (const f of [ep, pidFile]) { try { fs.unlinkSync(f); } catch { /* gone */ } }
        process.exit(0);
      }
    }
  });
});
srv.listen(ep);
JS
# Stub companion: registers/reuses a broker exactly as `task` does.
cat > "$STUB/codex-companion.mjs" <<'JS'
import path from "node:path";
import { fileURLToPath } from "node:url";
import { ensureBrokerSession } from "./lib/broker-lifecycle.mjs";
import { resolveWorkspaceRoot } from "./lib/workspace.mjs";
const here = path.dirname(fileURLToPath(import.meta.url));
const s = await ensureBrokerSession(resolveWorkspaceRoot(process.cwd()), { scriptPath: path.join(here, "app-server-broker.mjs") });
if (!s) { process.stderr.write("stub companion: broker did not start\n"); process.exit(1); }
process.stdout.write(`${s.pid}\n`);
// `linger`: stay running like a companion mid-review, so the broker is still its child.
if (process.argv[2] === "linger") setInterval(() => {}, 1000);
JS

# Real plugin lib (when installed): same stub companion + broker, real lib/.
LIB_DIRS=("$STUB")
REAL_LIB=""
for d in "$HOME"/.claude/plugins/cache/openai-codex/codex/*/scripts/lib; do
  [[ -f "$d/broker-lifecycle.mjs" && -f "$d/state.mjs" && -f "$d/workspace.mjs" ]] && REAL_LIB="$d"
done
if [[ -n "$REAL_LIB" ]]; then
  mkdir -p "$WORK/real/scripts"
  cp "$STUB/codex-companion.mjs" "$STUB/app-server-broker.mjs" "$WORK/real/scripts/"
  ln -s "$REAL_LIB" "$WORK/real/scripts/lib"
  LIB_DIRS+=("$WORK/real/scripts")
else
  echo "  NOTE  openai-codex plugin not installed — stub lib only"
fi

# ── helpers ─────────────────────────────────────────────────────────────────
# Sets R (not printed: REPOS must be appended in THIS shell for the cleanup trap).
new_repo() {
  R="$(mktemp -d "$WORK/repo.XXXXXX")"
  git -C "$R" init -q
  REPOS+=("$R")
}
# Run the stub companion in <repo> under the review allowlist (the same env the
# teardown resolves broker.json in). Prints the broker pid.
companion() { (cd "$1" && _bd_codex_broker_env "$PATH" "$NODE" "$2/codex-companion.mjs"); }
snapshot() { (cd "$1" && _bd_codex_broker "$NODE" "$2/codex-companion.mjs" "$PATH" snapshot); }
reap() { (cd "$1" && _bd_codex_broker "$NODE" "$2/codex-companion.mjs" "$PATH" reap "$3"); }
regfile() {
  (cd "$1" && _bd_codex_broker_env "$PATH" "$NODE" --input-type=module -e '
    const { pathToFileURL } = await import("node:url");
    const { resolveStateDir } = await import(pathToFileURL(process.argv[1] + "/state.mjs").href);
    const { resolveWorkspaceRoot } = await import(pathToFileURL(process.argv[1] + "/workspace.mjs").href);
    console.log(resolveStateDir(resolveWorkspaceRoot(process.cwd())) + "/broker.json");' -- "$2/lib")
}
# The per-workspace broker lock the helper launcher takes: keyed by the realpath of
# the repo toplevel (R is already physical, WORK is pwd -P'd), under the operator home.
# Hashed with the same perl module the launcher uses, so the key cannot diverge from it.
lockfile() {
  local h
  # shellcheck disable=SC2016 # perl body is single-quoted on purpose
  h="$(/usr/bin/perl -MDigest::SHA=sha256_hex -e 'print sha256_hex($ARGV[0])' "$1")"
  [[ "$h" =~ ^[0-9a-f]{64}$ ]] || return 1
  _trusted_operator_home >/dev/null 2>&1 || true
  printf '%s/.claude/busdriver-broker-locks/%s.lock' "${_TOH_HOME:-$HOME}" "$h"
}
# Zombie-aware, like the production running(): a killed process its parent has not yet
# reaped (common where PID 1 in a container reaps late) still passes kill -0, so read
# its state and count Z (and gone) as dead.
alive() { case "$(ps -o stat= -p "$1" 2>/dev/null | tr -d ' ')" in ''|Z*) return 1 ;; *) return 0 ;; esac; }
wait_dead() { local _; for _ in $(seq 1 50); do alive "$1" || return 0; sleep 0.1; done; return 1; }
sha() { shasum -a 256 "$1" 2>/dev/null | cut -d' ' -f1 || sha256sum "$1" | cut -d' ' -f1; }

for L in "${LIB_DIRS[@]}"; do
  tag="$([[ "$L" == "$STUB" ]] && echo stub-lib || echo real-lib)"
  echo "── $tag ($L/lib)"

  # (a) no broker before the review
  new_repo
  pre="$(snapshot "$R" "$L")"
  [[ "$pre" == absent ]] && ok "$tag (a) snapshot of an unregistered workspace is 'absent'" || bad "$tag (a) snapshot: '$pre'"
  pid="$(companion "$R" "$L")"; PIDS_TO_KILL+=("$pid")
  reg="$(regfile "$R" "$L")"
  sd="$(dirname "$(sed -n 's/.*"pidFile": "\(.*\)".*/\1/p' "$reg")")"
  if alive "$pid" && [[ -f "$reg" && "$reg" == /tmp/codex-companion/* ]]; then
    ok "$tag (a) review broker registered under /tmp/codex-companion (env -i state root)"
  else
    bad "$tag (a) broker not registered where expected: pid=$pid reg=$reg"
  fi
  if reap "$R" "$L" "$pre" && wait_dead "$pid"; then ok "$tag (a) reap stopped the broker the review started"; else bad "$tag (a) broker $pid still alive"; fi
  [[ ! -e "$reg" ]] && ok "$tag (a) its broker.json is gone" || bad "$tag (a) broker.json left behind: $reg"
  [[ -n "$sd" && ! -e "$sd" ]] && ok "$tag (a) its session dir is gone" || bad "$tag (a) session dir left behind: $sd"

  # (b) broker running before the review -> reused, untouched
  new_repo
  pid="$(companion "$R" "$L")"; PIDS_TO_KILL+=("$pid")
  reg="$(regfile "$R" "$L")"
  pre="$(snapshot "$R" "$L")"
  before="$(sha "$reg")"
  pid2="$(companion "$R" "$L")"
  [[ "$pid2" == "$pid" ]] && ok "$tag (b) the review reused the pre-existing broker" || bad "$tag (b) review started a new broker ($pid2 != $pid)"
  reap "$R" "$L" "$pre" || true
  sleep 0.3
  alive "$pid" && ok "$tag (b) pre-existing broker left alive" || bad "$tag (b) pre-existing broker $pid was stopped"
  [[ -f "$reg" && "$(sha "$reg")" == "$before" ]] && ok "$tag (b) its broker.json untouched" || bad "$tag (b) broker.json changed or removed"
  reap "$R" "$L" absent >/dev/null 2>&1 || true   # cleanup through the same path

  # (c) broker ignores broker/shutdown -> identity-checked group SIGKILL
  new_repo
  : > "$R/.stub-hang"
  pre="$(snapshot "$R" "$L")"
  pid="$(companion "$R" "$L")"; PIDS_TO_KILL+=("$pid")
  reg="$(regfile "$R" "$L")"
  kid="$(cat "$R/.stub-child" 2>/dev/null || true)"
  [[ -n "$kid" ]] && PIDS_TO_KILL+=("$kid")   # cleanup cannot reach it by group once the broker is gone
  if reap "$R" "$L" "$pre" 2>/dev/null && wait_dead "$pid"; then ok "$tag (c) unresponsive broker stopped after identity check"; else bad "$tag (c) unresponsive broker $pid still alive"; fi
  if [[ -n "$kid" ]] && wait_dead "$kid"; then ok "$tag (c) its SIGTERM-ignoring group member went with it"; else bad "$tag (c) group child ${kid:-?} survived"; fi
  [[ ! -e "$reg" ]] && ok "$tag (c) its broker.json is gone" || bad "$tag (c) broker.json left behind"
done

# (d) unprovable registrations are never acted on
new_repo
reg="$(regfile "$R" "$STUB")"
mkdir -p "$(dirname "$reg")"
hold & victim=$!; PIDS_TO_KILL+=("$victim")
printf '{"endpoint":"unix:/tmp/elsewhere/broker.sock","pidFile":"/tmp/elsewhere/broker.pid","logFile":"/tmp/elsewhere/broker.log","sessionDir":"/tmp/elsewhere","pid":%s}\n' "$victim" > "$reg"
reap "$R" "$STUB" absent 2>/dev/null || true
sleep 0.3
alive "$victim" && ok "(d) a registration not in the plugin's shape never gets its pid signalled" || bad "(d) foreign pid $victim was signalled"
[[ -f "$reg" ]] && ok "(d) and its broker.json is left in place" || bad "(d) foreign broker.json removed"
if reap "$R" "$STUB" "not-a-fingerprint" 2>/dev/null; then bad "(d) malformed fingerprint accepted"; else ok "(d) malformed fingerprint refused"; fi
alive "$victim" && ok "(d) refused reap touched nothing" || bad "(d) refused reap signalled $victim"

# (d) right shape, wrong process: the registration is well-formed and ours, but its
# pid is an impostor whose command line ENDS exactly like the broker's would (a
# suffix or substring identity check accepts it). Nothing may be signalled.
new_repo
reg="$(regfile "$R" "$STUB")"
mkdir -p "$(dirname "$reg")"
top="$(git -C "$R" rev-parse --show-toplevel)"
sd="$(mktemp -d /tmp/cxc-XXXXXX)"; SESSION_DIRS+=("$sd")
node_exec="$("$NODE" -p process.execPath)"
# setpgrp: lead its own group like a detached broker does — otherwise the group
# signal the teardown sends could not reach it and this case would prove nothing.
/usr/bin/perl -e 'setpgrp(0, 0); sleep 300' "$node_exec" "$STUB/app-server-broker.mjs" serve --endpoint "unix:$sd/broker.sock" --cwd "$top" --pid-file "$sd/broker.pid" &
impostor=$!; PIDS_TO_KILL+=("$impostor")
printf '{"endpoint":"unix:%s/broker.sock","pidFile":"%s/broker.pid","logFile":"%s/broker.log","sessionDir":"%s","pid":%s}\n' "$sd" "$sd" "$sd" "$sd" "$impostor" > "$reg"
sleep 0.3
if reap "$R" "$STUB" absent 2>/dev/null; then bad "(d) impostor reap reported success"; else ok "(d) impostor reap reports the broker as not stopped"; fi
alive "$impostor" && ok "(d) impostor whose command line merely ends like a broker's is never signalled" || bad "(d) impostor $impostor was signalled"
[[ -f "$reg" ]] && ok "(d) and the registration naming it is kept" || bad "(d) impostor registration removed"

# (d) right shape, real broker, wrong workspace: a registration copied from another
# workspace's LIVE broker. Even broker/shutdown alone would stop it, so it must not
# be sent — that broker and its own registration stay intact.
new_repo; other="$R"
opid="$(companion "$other" "$STUB")"; PIDS_TO_KILL+=("$opid")
oreg="$(regfile "$other" "$STUB")"
new_repo
reg="$(regfile "$R" "$STUB")"
mkdir -p "$(dirname "$reg")"
cp "$oreg" "$reg"
if reap "$R" "$STUB" absent 2>/dev/null; then bad "(d) cross-workspace reap reported success"; else ok "(d) cross-workspace reap refuses (identity names another workspace)"; fi
sleep 0.3
alive "$opid" && ok "(d) the other workspace's live broker is not shut down" || bad "(d) other workspace's broker $opid was stopped"
[[ -f "$oreg" && -S "$(sed -n 's/.*"endpoint": "unix:\(.*\)".*/\1/p' "$oreg")" ]] && ok "(d) its registration and socket are untouched" || bad "(d) other workspace's registration or socket removed"
reap "$other" "$STUB" absent >/dev/null 2>&1 || true   # cleanup through the same path

# (d) a FIFO planted as broker.json: open must not block, nothing is acted on
new_repo
reg="$(regfile "$R" "$STUB")"
mkdir -p "$(dirname "$reg")"
mkfifo "$reg"
t0=$(date +%s)
if snapshot "$R" "$STUB" >/dev/null 2>&1; then bad "(d) snapshot accepted a FIFO registration"; else ok "(d) snapshot of a FIFO registration fails (no teardown can follow)"; fi
# Unreadable is a failure, not "nothing to do": _execute_codex then keeps the hand-off.
if reap "$R" "$STUB" absent >/dev/null 2>&1; then bad "(d) reap of an unreadable registration reported success"; else ok "(d) reap of an unreadable registration reports failure"; fi
(( $(date +%s) - t0 < 15 )) && ok "(d) FIFO registration did not hang the helper" || bad "(d) FIFO registration stalled the helper"
[[ -p "$reg" ]] && ok "(d) FIFO left in place" || bad "(d) FIFO removed"

# (g) a helper that died between the clear's rename and its unlink left the registration
# under a sidecar name: the next helper puts it back before reading anything, so the
# broker stays registered (and "pre-existing" to the next review) instead of orphaned.
new_repo
pid="$(companion "$R" "$STUB")"; PIDS_TO_KILL+=("$pid")
reg="$(regfile "$R" "$STUB")"
h="$(sha "$reg")"
mv "$reg" "$reg.busdriver-reap-0123456789abcdef01234567"
got="$(snapshot "$R" "$STUB")"
[[ "$got" == "$h" ]] && ok "(g) snapshot sees the registration an interrupted clear left aside" || bad "(g) snapshot after interrupted clear: '$got' (want $h)"
[[ -f "$reg" && "$(sha "$reg")" == "$h" ]] && ok "(g) broker.json restored intact" || bad "(g) broker.json not restored"
compgen -G "$reg.busdriver-reap-*" >/dev/null && bad "(g) sidecar left behind" || ok "(g) sidecar consumed"
alive "$pid" && ok "(g) its broker left running" || bad "(g) broker $pid was stopped"

# (g) helpers in one workspace are serialized: while another holds the workspace lock,
# a helper waits (here until its alarm ends it) instead of reading broker.json.
lf="$(lockfile "$R")"
mkdir -p "$(dirname "$lf")"
# shellcheck disable=SC2016 # perl body is single-quoted on purpose
/usr/bin/perl -e 'use Fcntl qw(:flock); open(my $f, ">>", $ARGV[0]) or die; flock($f, LOCK_EX) or die; $| = 1; print "held\n"; sleep 30' "$lf" "$WORK" > "$WORK/held" &
holder=$!; PIDS_TO_KILL+=("$holder")
for _ in $(seq 1 50); do [[ -s "$WORK/held" ]] && break; sleep 0.1; done
t0=$(date +%s)
if got="$(cd "$R" && _BD_CODEX_BROKER_ALARM=2 _bd_codex_broker "$NODE" "$STUB/codex-companion.mjs" "$PATH" snapshot 2>/dev/null)"; then
  bad "(g) snapshot ran while another helper held the workspace lock ('$got')"
else
  ok "(g) a helper waits on the workspace lock"
fi
(( $(date +%s) - t0 < 10 )) && ok "(g) ...bounded by its alarm" || bad "(g) lock wait outlived the alarm"
kill "$holder" 2>/dev/null || true; wait "$holder" 2>/dev/null || true
got="$(snapshot "$R" "$STUB")"
[[ "$got" == "$h" ]] && ok "(g) the lock is released when its holder exits" || bad "(g) snapshot after holder exit: '$got'"
reap "$R" "$STUB" absent >/dev/null 2>&1 || true   # cleanup through the same path

# (g) the bound covers the whole helper, not just node: a lookup that stalls before the
# alarm is armed still ends at the caller's budget, and takes its subprocesses with it.
t0=$(date +%s)
if (
  # shellcheck disable=SC2329 # invoked by _bd_codex_broker_env, which this overrides
  _trusted_operator_home() { hold & printf '%s\n' "$!" > "$WORK/stallpid"; hold; }
  cd "$R" && _BD_CODEX_BROKER_ALARM=2 _bd_codex_broker "$NODE" "$STUB/codex-companion.mjs" "$PATH" snapshot
) >/dev/null 2>&1; then
  bad "(g) a snapshot whose lookup stalled reported success"
else
  ok "(g) a snapshot whose lookup stalls fails (no teardown can follow)"
fi
(( $(date +%s) - t0 < 6 )) && ok "(g) ...within the caller's bound" || bad "(g) stalled lookup outlived the bound ($(( $(date +%s) - t0 ))s)"
st="$(cat "$WORK/stallpid" 2>/dev/null || true)"
[[ -n "$st" ]] && PIDS_TO_KILL+=("$st")
[[ -n "$st" ]] && wait_dead "$st" && ok "(g) ...and its stalled subprocess is killed" || bad "(g) stalled lookup subprocess ${st:-?} survived"

# (f) the litmus runner is SIGKILLed after its review started a broker. The watchdog
# kills the review subtree, which never reaches the detached broker; it must run the
# reap from the hand-off _execute_codex wrote. $1 = "handed" (inputs present),
# "withdrawn" (emptied, as _execute_codex does after its own reap: must stay inert) or
# "stalled" (a reap that never returns: the watchdog must still collapse the subtree).
RUNNER="$ROOT/skills/litmus/scripts/run-review-loop.sh"
WATCH_KILL() {
  local mode="$1" d
  new_repo
  d="$(mktemp -d "$WORK/watch.XXXXXX")"
  sed -n '/^_orphan_watch_start()/,/^}/p' "$RUNNER" > "$d/funcs.sh"
  grep -q '_orphan_watch_start' "$d/funcs.sh" || return 9
  cat > "$d/parent.sh" <<'P'
# $1 lib  $2 funcs  $3 node  $4 companion  $5 review PATH  $6 mode  $7 out-dir
source "$1" >/dev/null 2>&1
source "$2"
hold() { exec /usr/bin/perl -e 'sleep 300' "$1"; }   # as in the test: a marked wait
hand="$7/handoff"; brk="$7/broker-handoff"
: > "$hand"; : > "$brk"
if [ "$6" = stalled ]; then
  # Defined before the watchdog forks, so the watchdog's reap is the one that hangs: in
  # the operator-home lookup, before the helper can arm its alarm, with a subprocess.
  stallpid="$7/stallpid"
  _trusted_operator_home() { hold "$stallpid" & printf '%s\n' "$!" > "$stallpid"; hold "$stallpid"; }
  _orphan_watch_start "$hand" "" "$brk" || exit 8
  printf '%s\n' "$3" "$4" "$5" absent > "$brk"
else
  _orphan_watch_start "$hand" "" "$brk" || exit 8
  pre="$(_bd_codex_broker "$3" "$4" "$5" snapshot)" || exit 7
  printf '%s\n' "$3" "$4" "$5" "$pre" > "$brk"
fi
if [ "$6" = stalled ]; then
  hold "$7" &
  printf '%s\n' "$!" > "$7/childpid"
  printf '%s\n' "$!" > "$hand"
elif [ "$6" = handed ]; then
  # The review: a companion that starts a broker and keeps running, so at the moment the
  # runner dies the detached broker is still ITS child — inside the subtree the watchdog
  # freezes and kills by ppid. The reap has to reach it first, or its files are left.
  _bd_codex_broker_env "$5" "$3" "$4" linger > "$7/brokerpid" &
  printf '%s\n' "$!" > "$7/childpid"
  printf '%s\n' "$!" > "$hand"
  for _ in $(seq 1 100); do [ -s "$7/brokerpid" ] && break; sleep 0.05; done
  ps -ww -o command= -p "$(cat "$7/brokerpid")" | sed -n 's/.*--pid-file \(.*\)\/broker\.pid$/\1/p' > "$7/sessiondir"
elif [ "$6" = exited ]; then
  # The review child has already EXITED (so the watchdog's latch no longer holds, or its
  # STOP fails) but left the hand-off populated — its own reap did not complete — and the
  # runner is killed before _orphan_watch_stop. The broker's companion has exited too
  # (broker reparented). The watchdog must still run the reap: its licence is the broker's
  # identity proof, not ownership of a subtree that is already gone.
  sleep 0.1 &
  printf '%s\n' "$!" > "$7/childpid"
  printf '%s\n' "$!" > "$hand"
  _bd_codex_broker_env "$5" "$3" "$4" > "$7/brokerpid"
  ps -ww -o command= -p "$(cat "$7/brokerpid")" | sed -n 's/.*--pid-file \(.*\)\/broker\.pid$/\1/p' > "$7/sessiondir"
else
  # The broker's companion has exited (broker reparented, outside the subtree) and the
  # review withdrew the hand-off after its own reap: nothing may touch the broker.
  hold "$7" &
  printf '%s\n' "$!" > "$7/childpid"
  printf '%s\n' "$!" > "$hand"
  _bd_codex_broker_env "$5" "$3" "$4" > "$7/brokerpid"
  : > "$brk"
fi
sleep 0.3
kill -9 $$
P
  (cd "$R" && bash "$d/parent.sh" "$LIB" "$d/funcs.sh" "$NODE" "$STUB/codex-companion.mjs" "$PATH" "$mode" "$d") >/dev/null 2>&1 || true
  W_PID="$(cat "$d/brokerpid" 2>/dev/null || true)"
  W_REG="$(regfile "$R" "$STUB")"
  W_SD="$(cat "$d/sessiondir" 2>/dev/null || true)"
  [[ -n "$W_PID" ]] && PIDS_TO_KILL+=("$W_PID")
  local c; c="$(cat "$d/childpid" 2>/dev/null || true)"
  [[ -n "$c" ]] && PIDS_TO_KILL+=("$c")
  W_CHILD="$c"
  W_DIR="$d"
}
WATCH_KILL handed
if [[ -n "$W_PID" ]] && { for _ in $(seq 1 250); do alive "$W_PID" || break; sleep 0.1; done; ! alive "$W_PID"; }; then
  ok "(f) watchdog stops the broker a SIGKILLed runner's review started"
else
  bad "(f) broker ${W_PID:-?} survived its SIGKILLed runner"
fi
[[ ! -e "$W_REG" ]] && ok "(f) and its registration is gone" || bad "(f) registration left behind: $W_REG"
[[ -n "$W_SD" && ! -e "$W_SD" ]] && ok "(f) and its session dir is gone (reaped, not merely killed by the subtree sweep)" || bad "(f) session dir left behind: ${W_SD:-?}"
WATCH_KILL exited
if [[ -n "$W_PID" ]] && { for _ in $(seq 1 250); do alive "$W_PID" || break; sleep 0.1; done; ! alive "$W_PID"; }; then
  ok "(f) watchdog reaps a populated hand-off even after the review child exited"
else
  bad "(f) broker ${W_PID:-?} leaked: review child gone, hand-off populated, runner SIGKILLed"
fi
[[ ! -e "$W_REG" ]] && ok "(f) ...and its registration is gone" || bad "(f) registration left behind after child-exited reap: $W_REG"
[[ -n "$W_SD" && ! -e "$W_SD" ]] && ok "(f) ...and its session dir is gone" || bad "(f) session dir left behind after child-exited reap: ${W_SD:-?}"
reap "$R" "$STUB" absent >/dev/null 2>&1 || true   # cleanup through the same path
WATCH_KILL withdrawn
sleep 8
alive "$W_PID" && ok "(f) an emptied hand-off (reap already done) is inert" || bad "(f) watchdog acted on a withdrawn hand-off"
[[ -f "$W_REG" ]] && ok "(f) ...and leaves the registration alone" || bad "(f) withdrawn hand-off still removed the registration"
reap "$R" "$STUB" absent >/dev/null 2>&1 || true   # cleanup through the same path
WATCH_KILL stalled
if [[ -n "$W_CHILD" ]] && { for _ in $(seq 1 500); do alive "$W_CHILD" || break; sleep 0.1; done; ! alive "$W_CHILD"; }; then
  ok "(f) a reap that never returns does not stop the watchdog collapsing the subtree"
else
  bad "(f) review child ${W_CHILD:-?} survived behind a stalled reap"
fi
# Read only now: the watchdog starts the reap after the runner is gone, not before.
W_STALL="$(cat "$W_DIR/stallpid" 2>/dev/null || true)"
[[ -n "$W_STALL" ]] && PIDS_TO_KILL+=("$W_STALL")
if [[ -n "$W_STALL" ]] && wait_dead "$W_STALL"; then
  ok "(f) ...and the stalled reap's own subprocesses are killed at its bound"
else
  bad "(f) stalled reap subprocess ${W_STALL:-?} survived its bound"
fi

echo
echo "test-codex-broker-teardown: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
