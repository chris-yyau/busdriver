#!/usr/bin/env bash
# Test: GateGuard consent containment (issue #616).
#
# Runs the EXACT hooks.json invocation for both GateGuard registrations, from a
# deliberately poisoned outer shell, against the REAL wrapper + runner + hook. This is
# the only lane that validates the wrapper boundary: the in-process vitest lanes patch
# os.userInfo and never start `env -i`.
#
# It proves two things the other lanes cannot:
#   (a) all six env channels that used to switch GateGuard off are wiped by `env -i`, and
#   (b) the --fail-open disposition allows on a launch failure without emitting a stdout
#       decision, while the wrapped gates keep failing closed.
#
# REAL-HOME RULE — the same one tests/…-containment siblings and step 7 of the design
# settled after four rounds. This lane has no home seam, so it runs against the operator's
# REAL passwd home. It therefore NEVER touches a pre-existing <passwd-HOME>/.gateguard:
#   * <root> absent  -> claim it with a plain non-recursive mkdir (EEXIST means a real
#                       session raced us, so fall to the marker-free branch), enroll,
#                       run every row, then remove EXACTLY the entries we created, by
#                       name, and the directories only if they are empty.
#   * <root> present -> do not write into it, do not enroll, do not trigger the prune.
#                       Run the rows that need no marker and say loudly which were skipped.
# It is NOT a whole-tree removal: an operator enrolling mid-run must not lose their marker.
# There is deliberately no crash-recovery sweep — any sweep powerful enough to reclaim a
# killed run's tree is also powerful enough to delete an enrollment made afterwards.
#
# The suite never SKIPs: scripts/ci/run-shell-tests.sh declares SKIP_ALLOWED empty by
# policy, and a gate suite is precisely what that policy names.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WRAPPER="$REPO_ROOT/hooks/gate-scripts/lib/sanitized-node.sh"
CONSENT="$REPO_ROOT/scripts/lib/gateguard-consent.js"
EDIT_HOOK_ID="pre:edit-write:gateguard-fact-force"
BASH_HOOK_ID="pre:bash:gateguard-fact-force"
# A path that deliberately does not exist, for the wrapper-disposition rows below.
MISSING_REL="scripts/hooks/does-not-exist.js"
PROFILES="minimal,standard,strict"

PASS=0
FAIL=0
assert() {
    if [[ "$1" -eq 0 ]]; then PASS=$((PASS+1)); printf '  ok   %s\n' "$2"
    else FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$2"; fi
}
assert_true() {
    local msg="${*: -1}"; local cond=("${@:1:$#-1}")
    if "${cond[@]}"; then assert 0 "$msg"; else assert 1 "$msg"; fi
}

TMP="$(mktemp -d)"
RUN_TOKEN="$$-$(date +%s)"
# Enrollment targets a per-run THROWAWAY repo, never $REPO_ROOT. Enrolling the operator's
# real checkout would mean a SIGKILL mid-run leaves a live enrollment behind — a durable
# consent change this suite never asked for — and "a killed run just leaves <root> behind"
# would be false. Step 8 mandates per-run throwaway identities for the same hazard and the
# driver lane already uses a mkdtemp repo; this makes the third lane consistent.
# Named recognisably ON PURPOSE. A SIGKILL skips the EXIT trap, so the fixture repo AND its
# marker survive; the marker's recorded path is then the only thing an operator has to tell it
# apart from a real enrolment. "It sits under the system temp directory" is NOT a safe
# discriminator — the enrolment contract accepts any absolute git repository, and an operator
# may legitimately enrol a checkout under /tmp — so the path carries a distinctive component
# instead. RUN_TOKEN is defined above and makes it unique per run.
FIXTURE_REPO="$TMP/gateguard-containment-fixture-$RUN_TOKEN"
mkdir -p "$FIXTURE_REPO"
git init -q "$FIXTURE_REPO" 2>/dev/null
trap 'rm -rf "$TMP"' EXIT

# <root>, derived through the CONSENT MODULE ITSELF — not a second copy of the rule. The
# suite must agree with the gate by construction; two independent derivations that happen to
# match today are exactly the "third copy drifting" this design rejects elsewhere. It is
# still the passwd home, never $HOME, because that is what the module resolves.
# An underivable/empty/relative value is a hard FAIL, not a SKIP: it means the design's
# cornerstone does not hold on this host.
GG_ROOT="$(node -e 'process.stdout.write(require(process.argv[1]+"/scripts/lib/gateguard-consent.js").gateguardRoot())' "$REPO_ROOT" 2>/dev/null || true)"
if [[ -z "$GG_ROOT" || "$GG_ROOT" != /* ]]; then
    printf '  FAIL passwd home is unusable (resolved root %q) — the consent premise does not hold on this host\n' "$GG_ROOT" >&2
    printf 'RESULT: 0 passed, 1 failed\n'
    exit 1
fi
GG_ENABLED="$GG_ROOT/enabled"

# ── Invocation: the ACTUAL hooks.json command, not a copy of it ─────────────
# An earlier version of this suite hardcoded its own `/usr/bin/env -i … bash "$WRAPPER" …`
# line. That made it a guard that could not fire: deleting `/usr/bin/env -i ` from
# hooks.json:151/161 left this suite fully green, because the suite never read the
# registration it claims to validate. Demonstrated by doing exactly that and watching
# 18/18 still pass. The command is now EXTRACTED from hooks.json and executed, so the
# containment prefix, the wrapper reference, the flag, the profile CSV and the `|| exit 0`
# tail are all live inputs rather than restated constants.
hooks_command_for() {  # hooks_command_for <hook_id>  -> the registration's command string
    node -e '
      const fs=require("fs");
      const j=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
      const id=process.argv[2], cmds=[];
      (function walk(o){ if(Array.isArray(o)) o.forEach(walk);
        else if(o&&typeof o==="object"){ if(typeof o.command==="string"&&o.command.includes(id)) cmds.push(o.command);
          Object.values(o).forEach(walk); } })(j);
      if(cmds.length!==1){ process.stderr.write("expected 1 command for "+id+", got "+cmds.length+"\n"); process.exit(1); }
      process.stdout.write(cmds[0]);
    ' "$REPO_ROOT/hooks/hooks.json" "$1"
}

# A NODE_OPTIONS probe: `--require` runs BEFORE the hook's first line, so it is a
# pre-runtime channel no `process.env` grep can see. `env -i` is the only thing that closes
# it. The probe touches a sentinel; the sentinel must never appear.
NODE_SENTINEL="$TMP/node-options-ran"
cat > "$TMP/probe.js" <<PROBE
require("fs").writeFileSync(process.env.GG_SENTINEL || "$NODE_SENTINEL", "ran");
PROBE

# Every session id this run uses. Cleanup derives exact state filenames from these, so a
# new row that invents an id must add it here or its state file is left behind (visible:
# the final rmdir of <root> then declines, and the suite says so).
our_session_ids() {
    printf '%s\n' \
        "unenrolled-$RUN_TOKEN" \
        "enrolled-e-$RUN_TOKEN" \
        "enrolled-b-$RUN_TOKEN" \
        "retry-$RUN_TOKEN" \
        "nocwd-$RUN_TOKEN" \
        "intree-$RUN_TOKEN"
}

# Mirrors hashSessionKey('sid', raw) in gateguard-fact-force.js: sha256 of the id, first
# 24 hex characters. If that changes, this cleanup stops matching and the suite leaves
# state behind rather than deleting a stranger's — the safe direction.
state_file_name_for() {
    node -e 'const c=require("crypto");process.stdout.write("state-sid-"+c.createHash("sha256").update(String(process.argv[1])).digest("hex").slice(0,24)+".json")' "$1"
}

# Echoes stdout and RETURNS the invocation's exit status. Callers MUST capture it as
# `out=$(run_contained …); RC=$?` — assigning a global inside this function happens in the
# command-substitution SUBSHELL and never reaches the parent, so under `set -u` the first
# read of $RC aborts the entire suite. That defect was invisible locally, because a
# pre-existing ~/.gateguard forces the marker-free branch where the readers are unreachable;
# on CI, whose home is fresh, it would have aborted every run before a single enrolled row.
run_contained() {  # run_contained <hook_id> <payload> ; echoes stdout, RETURNS rc
    local hook_id="$1" payload="$2" cmd out rc
    cmd="$(hooks_command_for "$hook_id")" || return 99
    out="$(
        printf '%s' "$payload" | \
        ECC_HOOK_PROFILE=standard \
        ECC_DISABLED_HOOKS="$EDIT_HOOK_ID,$BASH_HOOK_ID" \
        GATEGUARD_DISABLED=1 \
        ECC_GATEGUARD=off \
        GATEGUARD_STATE_DIR=/dev/null \
        ECC_DRY_RUN=1 \
        NODE_OPTIONS="--require=$TMP/probe.js" \
        GG_SENTINEL="$NODE_SENTINEL" \
        GIT_DIR=/nonexistent GIT_WORK_TREE=/nonexistent GIT_CONFIG_GLOBAL=/nonexistent \
        CLAUDE_PLUGIN_ROOT="$REPO_ROOT" \
        CLAUDE_HOOK_EVENT_NAME="PreToolUse" \
        bash -c "$cmd" 2>/dev/null
    )"
    rc=$?
    printf '%s' "$out"
    return "$rc"
}

decision_of() {  # decision_of <stdout>  -> deny | allow
    printf '%s' "$1" | node -e '
      let d="";process.stdin.on("data",c=>d+=c).on("end",()=>{
        try{const p=JSON.parse(d);
          process.stdout.write(p?.hookSpecificOutput?.permissionDecision ?? "allow");
        }catch{process.stdout.write("allow")}});' 2>/dev/null
}

edit_payload() {  # edit_payload <session> <cwd>
    printf '{"session_id":"%s","cwd":"%s","tool_name":"Edit","tool_input":{"file_path":"/x/a.ts"}}' "$1" "$2"
}

# ── Rows that need NO marker (always run) ───────────────────────────────────
echo "── registration + wrapper-disposition rows (no marker needed)"

# The registrations must reach the hook only through the wrapper.
# The ANCHORED TUPLE #629 keys on, asserted per registration: a leading `/usr/bin/env -i`,
# the exact wrapper reference, the disposition flag, the profile CSV, and the matching outer
# tail. Checked structurally, not by a line grep — and the execution rows above now depend on
# these same strings, so a shape regression breaks both.
for _id in "$EDIT_HOOK_ID" "$BASH_HOOK_ID"; do
    _cmd="$(hooks_command_for "$_id")" || _cmd=""
    assert_true test -n "$_cmd" "hooks.json has exactly one command for $_id"
    case "$_cmd" in
        "/usr/bin/env -i "*) assert 0 "$_id starts with /usr/bin/env -i (containment prefix)" ;;
        *) assert 1 "$_id starts with /usr/bin/env -i (containment prefix)" ;;
    esac
    case "$_cmd" in
        *"hooks/gate-scripts/lib/sanitized-node.sh"*) assert 0 "$_id launches through sanitized-node.sh" ;;
        *) assert 1 "$_id launches through sanitized-node.sh" ;;
    esac
    case "$_cmd" in
        *"--fail-open"*) assert 0 "$_id carries the --fail-open disposition" ;;
        *) assert 1 "$_id carries the --fail-open disposition" ;;
    esac
    case "$_cmd" in
        *'"minimal,standard,strict"'*) assert 0 "$_id passes the full profile CSV" ;;
        *) assert 1 "$_id passes the full profile CSV" ;;
    esac
    case "$_cmd" in
        *"|| exit 0") assert 0 "$_id ends with the fail-open tail || exit 0" ;;
        *) assert 1 "$_id ends with the fail-open tail || exit 0" ;;
    esac
    case "$_cmd" in
        *"run-with-flags.js"*) assert 1 "$_id does not invoke the runner directly (bare node)" ;;
        *) assert 0 "$_id does not invoke the runner directly (bare node)" ;;
    esac
done

# Counted over hook COMMAND strings only, not raw lines: the descriptions mention the flag
# too, and a line grep would score 4 and pass for the wrong reason.
_counts=$(node -e '
  const j=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
  const cmds=[];
  (function walk(o){ if(Array.isArray(o)) o.forEach(walk);
    else if(o&&typeof o==="object"){ if(typeof o.command==="string") cmds.push(o.command);
      Object.values(o).forEach(walk); } })(j);
  const fo=cmds.filter(c=>c.includes("--fail-open"));
  process.stdout.write([fo.length, fo.filter(c=>/gateguard/.test(c)).length,
                        cmds.filter(c=>c.includes("--fail-closed")).length].join(" "));
' "$REPO_ROOT/hooks/hooks.json") || _counts=''
read -r fo fo_gg fc <<<"$_counts"
assert_true test "$fo" -eq 2 "exactly two hook commands carry --fail-open"
assert_true test "$fo_gg" -eq 2 "both --fail-open commands are GateGuard's (no leak to a wrapped gate)"
assert_true test "$fc" -eq 0 "no hook command carries a --fail-closed token (#629 keys on the tuple, not this)"
susp=$(grep -c 'failing CLOSED' "$WRAPPER" || true)
assert_true test "$susp" -eq 0 "wrapper no longer hardcodes the closed-failure suffix"

# V16's static half, observed rather than asserted in prose. These are greppable-absence
# invariants: the point of "the hook contains no environment read at all" is that it is
# mechanically checkable, which is worth nothing if nothing mechanically checks it.
_hook_js="$REPO_ROOT/scripts/hooks/gateguard-fact-force.js"
_consent_js="$REPO_ROOT/scripts/lib/gateguard-consent.js"
_skill_md="$REPO_ROOT/skills/gateguard/SKILL.md"
# Assert the subjects EXIST before grepping them. `grep -c` on a missing file prints nothing,
# and `_n=$(grep -c … || true)` then yields an empty string, so `test "" -eq 0` dies with
# "integer expected" — a confusing failure that reads as a broken test rather than a missing
# file. A greppable-absence invariant is only meaningful if the thing being grepped is there:
# a renamed or deleted file would otherwise "satisfy" every absence check.
for _f in "$_hook_js" "$_consent_js" "$_skill_md"; do
    assert_true test -f "$_f" "grep subject exists: ${_f#"$REPO_ROOT/"}"
done
for _f in "$_hook_js" "$_consent_js"; do
    _n=$(grep -c 'process\.env' "$_f" 2>/dev/null || true); _n=${_n:-X}
    assert_true test "$_n" -eq 0 "$(basename "$_f") contains no environment read"
    _n=$(grep -c 'os\.homedir(' "$_f" 2>/dev/null || true); _n=${_n:-X}
    assert_true test "$_n" -eq 0 "$(basename "$_f") does not use the \$HOME-following home helper"
done
for _tok in GATEGUARD_STATE_DIR GATEGUARD_DISABLED ECC_GATEGUARD BUSDRIVER_STATE_DIR; do
    _n=$(cat "$_hook_js" "$_consent_js" "$_skill_md" 2>/dev/null | grep -c "$_tok" || true); _n=${_n:-X}
    assert_true test "$_n" -eq 0 "retired switch $_tok appears in no hook, resolver or skill text"
done
_n=$(grep -c 'ECC_HOOK_PROFILE=strict' "$_skill_md" 2>/dev/null || true); _n=${_n:-X}
assert_true test "$_n" -eq 0 "SKILL.md no longer documents the retired strict-profile enable path"
# Step 6 names these pre-change assertions as mandatory deletions. They survived one sweep
# (the token greps above cannot see them — they are sentences, not variable names), and the
# file then contradicted itself: the same document said the entries invoke run-with-flags.js
# directly AND that they are contained. Present tense only: the historical note that replaced
# them is deliberately past tense and must not re-trip this.
while IFS= read -r _stale; do
    _n=$(grep -c "$_stale" "$_skill_md" 2>/dev/null || true); _n=${_n:-X}
    assert_true test "$_n" -eq 0 "SKILL.md no longer asserts: $_stale"
done <<'STALE'
Not env-contained, on purpose
These two entries invoke
Do not "harden" this into
STALE

# The profile CSV must equal VALID_PROFILES, or a value of ECC_HOOK_PROFILE disables.
csv_ok=$(node -e '
  const fs=require("fs");
  const src=fs.readFileSync(process.argv[1],"utf8");
  const valid=[...src.matchAll(/VALID_PROFILES = new Set\(\[([^\]]*)\]/g)][0][1]
      .split(",").map(s=>s.trim().replace(/^.|.$/g,"")).sort().join(",");
  const hooks=fs.readFileSync(process.argv[2],"utf8");
  const csvs=[...hooks.matchAll(/gateguard-fact-force\.js\\" \\"([a-z,]+)\\"/g)].map(m=>m[1]);
  const ok=csvs.length===2 && csvs.every(c=>c.split(",").sort().join(",")===valid);
  process.stdout.write(ok?"1":"0");
' "$REPO_ROOT/scripts/lib/hook-flags.js" "$REPO_ROOT/hooks/hooks.json" 2>/dev/null || echo 0)
assert_true test "$csv_ok" = "1" "both registrations name every VALID_PROFILE (no value of the profile var disables)"

# Wrapper disposition, live: a launch failure in the OPEN disposition allows with NO
# stdout decision; the same failure in the CLOSED disposition blocks with one.
open_out=$(bash "$WRAPPER" --fail-open "$EDIT_HOOK_ID" "$MISSING_REL" "$PROFILES" 2>/dev/null); open_rc=$?
assert_true test "$open_rc" -eq 0 "fail-open launch failure exits 0"
assert_true test -z "$open_out" "fail-open launch failure emits NO stdout decision"
closed_out=$(bash "$WRAPPER" "$EDIT_HOOK_ID" "$MISSING_REL" "$PROFILES" 2>/dev/null); closed_rc=$?
assert_true test "$closed_rc" -eq 2 "closed launch failure still exits 2"
grep -q '"decision":"block"' <<<"$closed_out"; assert $? "closed launch failure still emits block JSON"

# A malformed argument list is forced CLOSED whichever disposition was asked for.
for bad in "--fail-open a b c --fail-open" "--fail-open   std" "--fail-open a b"; do
    # shellcheck disable=SC2086
    mal_out=$(bash "$WRAPPER" $bad 2>/dev/null); mal_rc=$?
    assert_true test "$mal_rc" -eq 2 "malformed args ($bad) block in the CLOSED disposition"
    grep -q '"decision":"block"' <<<"$mal_out"; assert $? "malformed args ($bad) emit block JSON"
done
mal_empty_out=$(bash "$WRAPPER" --fail-open "" "" "$PROFILES" 2>/dev/null); mal_empty_rc=$?
assert_true test "$mal_empty_rc" -eq 2 "empty hookId/scriptPath satisfies arity but still blocks CLOSED"
grep -q '"decision":"block"' <<<"$mal_empty_out"; assert $? "empty-arg case emits block JSON"

# Marker-absent behaviour is only assertable when the machine really has no markers.
if [[ ! -e "$GG_ROOT" ]]; then
    _payload=$(edit_payload "unenrolled-$RUN_TOKEN" "$FIXTURE_REPO")

    out=$(run_contained "$EDIT_HOOK_ID" "$_payload"); RC=$?
    assert_true test "$RC" -eq 0 "unenrolled: exit 0"
    _dec=$(decision_of "$out")
    assert_true test "$_dec" = "allow" "unenrolled: no deny (gate OFF by default)"
else
    # Still drive ONE contained call so the NODE_OPTIONS probe below has actually had the
    # chance to fire in this mode too. Its decision is not asserted here (a pre-existing
    # <root> may hold a marker for this repo); only the sentinel is.
    _payload=$(edit_payload "unenrolled-$RUN_TOKEN" "$FIXTURE_REPO")

    run_contained "$EDIT_HOOK_ID" "$_payload" >/dev/null
fi

# V1's pre-runtime channel, ASSERTED — not merely injected. `--require` runs before the
# hook's first line, so no `process.env` grep can see it and only `env -i` closes it.
# An earlier revision of this suite planted the probe and never checked the sentinel: the
# row read as coverage of the hardest channel while being incapable of failing. Removing
# the `env -i` prefix from hooks.json must now make THIS line fail.
assert_true test ! -e "$NODE_SENTINEL" \
    "NODE_OPTIONS=--require never executed (env -i closed the pre-runtime channel)"

# ── Rows that need a marker ─────────────────────────────────────────────────
MODE="marker-free"
# `mkdir -m 700`, not a bare mkdir: the claim creates <root> BEFORE enrollment runs, so
# enrollment sees it as pre-existing and (correctly) does not repair its mode. A bare mkdir
# under a normal umask would leave 0755 for the duration of the run, and permanently if the
# run is killed — contradicting the 0700 creation contract the gate itself honours.
if [[ ! -e "$GG_ROOT" ]] && mkdir -m 700 "$GG_ROOT" 2>/dev/null; then
    MODE="full"
fi

if [[ "$MODE" == "full" ]]; then
    echo "── enrolled rows (this run created <root>; it will remove only what it created)"
    MARKER=""
    cleanup_full() {
        [[ -n "$MARKER" && -f "$MARKER" ]] && rm -f "$MARKER"
        # BY NAME, computed from the session ids this run used — NOT `rm state-*.json`.
        # The glob was a whole-class removal wearing a by-name comment: a session enrolling
        # concurrently writes its own state-*.json into the same <root>, and the glob
        # destroys it. §7/V20 require removing only what this run created, and the state
        # filename is a pure function of the session id (sha256, first 24 hex), so the
        # exact names are computable rather than guessable.
        local _sid _sf _sids
        _sids=$(our_session_ids)
        while IFS= read -r _sid; do
            _sf="$GG_ROOT/$(state_file_name_for "$_sid")"
            rm -f "$_sf"
            # Its own crash-residue temp siblings, scoped to that one filename.
            rm -f "$_sf".tmp.* 2>/dev/null
        done <<< "$_sids"
        rmdir "$GG_ENABLED" 2>/dev/null
        rmdir "$GG_ROOT" 2>/dev/null
        rm -rf "$TMP"
    }
    trap cleanup_full EXIT

    # Enroll by running the documented manual procedure verbatim — one identity producer,
    # no shell-side hash (sha256sum is absent on macOS).
    MARKER=$(cd / && node -e '
      const g=require(process.argv[1]),f=require("fs"),i=g.resolveIdentity(process.argv[2]);
      g.ensureDirNoFollow(g.gateguardRoot(),0o700);
      g.ensureDirNoFollow(g.enabledDir(),0o700);
      f.writeFileSync(i.markerPath,i.realpath+"\n",{flag:"wx",mode:0o600});
      process.stdout.write(i.markerPath);
    ' "$CONSENT" "$FIXTURE_REPO" 2>/dev/null)
    assert_true test -f "$MARKER" "manual enrollment procedure created the marker"

    # V1: all six channels injected, both registrations, contained ⇒ still denies.
    _payload=$(edit_payload "enrolled-e-$RUN_TOKEN" "$FIXTURE_REPO")

    out=$(run_contained "$EDIT_HOOK_ID" "$_payload"); RC=$?
    assert_true test "$RC" -eq 0 "enrolled Edit: exit 0 (deny rides on stdout, not the status)"
    _dec=$(decision_of "$out")
    assert_true test "$_dec" = "deny" \
        "enrolled Edit denies despite all six disable channels injected"

    bash_payload=$(printf '{"session_id":"enrolled-b-%s","cwd":"%s","tool_name":"Bash","tool_input":{"command":"ls -la"}}' "$RUN_TOKEN" "$FIXTURE_REPO")
    out=$(run_contained "$BASH_HOOK_ID" "$bash_payload")
    _dec=$(decision_of "$out")
    assert_true test "$_dec" = "deny" \
        "enrolled Bash denies despite all six disable channels injected"

    # V11: first touch denies, retry allows — state persisted under the passwd home even
    # though GATEGUARD_STATE_DIR=/dev/null was injected.
    _payload=$(edit_payload "retry-$RUN_TOKEN" "$FIXTURE_REPO")

    out=$(run_contained "$EDIT_HOOK_ID" "$_payload")
    _dec=$(decision_of "$out")
    assert_true test "$_dec" = "deny" "retry row: first touch denies"
    _payload=$(edit_payload "retry-$RUN_TOKEN" "$FIXTURE_REPO")

    out=$(run_contained "$EDIT_HOOK_ID" "$_payload")
    _dec=$(decision_of "$out")
    assert_true test "$_dec" = "allow" "retry row: same session allows the retry"

    # V3: no absolute payload cwd ⇒ allow. Under the wrapper process.cwd() is `/`, so an
    # implementation keying consent on it would deny here.
    nocwd=$(printf '{"session_id":"nocwd-%s","tool_name":"Edit","tool_input":{"file_path":"/x/a.ts"}}' "$RUN_TOKEN")
    out=$(run_contained "$EDIT_HOOK_ID" "$nocwd")
    _dec=$(decision_of "$out")
    assert_true test "$_dec" = "allow" "payload without an absolute cwd allows"

    # V5: an in-tree marker is not a consent channel.
    mkdir -p "$FIXTURE_REPO/.claude"
    intree="$FIXTURE_REPO/.claude/gateguard-enabled.local"
    printf 'x' > "$intree"
    rm -f "$MARKER"
    _payload=$(edit_payload "intree-$RUN_TOKEN" "$FIXTURE_REPO")

    out=$(run_contained "$EDIT_HOOK_ID" "$_payload")
    rm -f "$intree"
    _dec=$(decision_of "$out")
    assert_true test "$_dec" = "allow" \
        "an in-tree gateguard-enabled.local does NOT enable the gate (out-of-tree marker removed)"
    MARKER=""
else
    echo "── MARKER-FREE MODE ──────────────────────────────────────────────────────"
    echo "  A <passwd-HOME>/.gateguard already exists, so this run did NOT enroll and did"
    echo "  NOT write into it. NOT exercised here: the enrolled deny rows for both"
    echo "  registrations, the first-touch/retry pair, the absolute-cwd row, the"
    echo "  in-tree-marker row, AND the marker-absent allow row (a pre-existing <root>"
    echo "  may already hold a marker for this repo, so 'allow' is not assertable)."
    echo "  CI runs on a fresh home and covers all of them."
    echo "──────────────────────────────────────────────────────────────────────────"
fi

echo "MODE: $MODE"
# CI is the authoritative lane for the enrolled rows. A degraded CI run must not pass
# quietly; the operator's own machine is never the thing that pays.
if [[ "${CI:-}" == "true" && "$MODE" != "full" ]]; then
    assert 1 "CI must run in 'full' mode (a runner home is fresh) — marker-free means <root> pre-existed"
fi

printf 'RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
