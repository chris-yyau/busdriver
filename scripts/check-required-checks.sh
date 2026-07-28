#!/usr/bin/env bash
#
# check-required-checks.sh — verify required-checks.lock matches reality.
#
# Drift surfaces in five places, all of which can silently break merge:
#
#   (a) Lock vs workflow source:  a required check's `name:` (or job key
#       when no name is set) was renamed in a .yml without updating the
#       lock — branch protection still requires the old name, no check
#       posts under that name, PRs hang. Matrix-derived names (rendered
#       as `<base> (<label>)` by GitHub) are supported via the optional
#       `matrix_value` lock field — see lock _doc and the matrix_value
#       inline comment near surface (a) for details.
#
#   (b) Lock vs branch protection: lock was updated, branch-protection
#       contexts weren't — server still requires an old or wrong name.
#
#   (c) Lock vs reporting app: a different integration started posting a
#       same-named status, and we didn't notice. Recorded source_app
#       lets us flag spoofing or migration.
#
#   (d) Workflow check-name uniqueness: two workflows post status checks
#       under the same effective name. Branch protection identifies
#       required checks by name only — when names collide, GitHub picks
#       one reporter and ignores the other. Catches accidental rename-
#       collisions, copy-paste duplicates, and matrix template clashes
#       across workflows.
#
#   (e) Lock classification completeness: a workflow posts a status check
#       that the lock knows nothing about — neither `required` nor
#       `advisory`. (a) cannot see this (it walks lock → workflows, so an
#       absent entry is never looked up) and (b) only catches it once the
#       server already requires the name. Because `relevant-check-status.sh`
#       treats lock.required as an ALLOWLIST, an unclassified-but-required
#       check is filtered out of the merge decision entirely — invisible,
#       not pending — so failing required checks can report as green (#530).
#
# Runtime order: (a), (d) and (e) are local (no API) and run first; (b)
# and (c) require gh API calls and run after. Output labels appear in the
# order they ran — `[a]`, `[d]`, `[e]`, `[b]`, `[c]` — not alphabetically.
# `--local-only` runs (a), (d) and (e).
#
# Only (a), (d) and (e) can run in CI on this repo: (b) and (c) need
# `administration: read` / check-run reads that GITHUB_TOKEN cannot be
# granted, so tests.yml invokes `--local-only`. (e) exists precisely so the
# token-free subset still guards the failure mode (b) was meant to catch.
#
# Modes:
#   ./check-required-checks.sh                      # all 5 surfaces (default)
#   ./check-required-checks.sh --local-only         # skip API calls; runs (a), (d), (e)
#   ./check-required-checks.sh --strict-remote      # turn (b)/(c) "couldn't verify" into drift
#   ./check-required-checks.sh --owner OWNER --repo REPO
#                                                    # override repo (default
#                                                    # = current git remote)
#
# Exit codes:
#   0 — no drift
#   1 — drift detected
#   2 — usage / config error

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LOCK="$REPO_ROOT/.github/required-checks.lock"

LOCAL_ONLY=0
STRICT_REMOTE=0
OWNER=""
REPO=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --local-only) LOCAL_ONLY=1; shift ;;
    # `--strict-remote` turns "couldn't verify against the server" into drift
    # (exit 1) instead of a warn-and-continue. Default OFF so the script stays
    # usable during repo onboarding (when branch protection isn't configured
    # yet); ON in CI / scheduled drift checks where missing remote = real
    # drift. Applies to (b) API/auth/shape failures, (c) "no recent commit
    # had check-runs" path, and the two pre-flight conditions that would
    # otherwise prevent any server verification at all: missing git remote
    # 'origin' and missing gh CLI. Per-check missing in (c) (e.g., PR-only
    # checks like version-drift on a main commit) stays warn-only because
    # those are routine and expected.
    --strict-remote) STRICT_REMOTE=1; shift ;;
    # `--owner` and `--repo` each consume the next arg as a value. Validate
    # that the next arg exists and isn't itself another flag (leading `-`)
    # before assigning — otherwise `--owner --repo helmet` would silently
    # set OWNER='--repo' and shift past the real owner value, and `--owner`
    # at end-of-args would crash under `set -u` instead of giving a clean
    # error. Use `${2:-}` for the existence probe so set -u doesn't trip
    # on the access itself.
    --owner)
      if [[ -z "${2:-}" || "$2" == -* ]]; then
        echo "error: --owner requires a non-flag value" >&2; exit 2
      fi
      OWNER="$2"; shift 2 ;;
    --repo)
      if [[ -z "${2:-}" || "$2" == -* ]]; then
        echo "error: --repo requires a non-flag value" >&2; exit 2
      fi
      REPO="$2"; shift 2 ;;
    -h|--help)
      # Range must cover the header block through "Exit codes" — it grew when
      # surface (e) was added, and a stale upper bound silently truncates
      # --help mid-sentence.
      sed -n '3,59p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "error: unknown arg '$1'" >&2; exit 2 ;;
  esac
done

if [[ ! -f "$LOCK" ]]; then
  echo "error: $LOCK not found" >&2
  exit 2
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "error: jq is required" >&2
  exit 2
fi

# Validate lock file shape. Without this, a malformed lock (invalid JSON,
# missing `.required` key, or `.required` set to a non-array) would let the
# downstream `jq -c '.required[]' "$LOCK"` invocations produce empty output
# silently — every read loop would then iterate over nothing and emit
# "ok" lines on every surface, falsely declaring the repo drift-free even
# though no checks were actually verified. Catch the malformation at startup
# so operators see a clear error instead of a fail-OPEN green light.
# `jq -e` exits non-zero on `false`/`null` results, so this rejects all
# three malformation modes in one probe.
#
# `.advisory` is validated to the same standard because surface (e) reads it
# as the other half of the classification set. jq iterates an OBJECT's values
# just as happily as an array's, so an object-shaped `advisory` would still
# yield every expected name and let (e) report "ok" on a malformed lock —
# the same fail-OPEN this block exists to prevent, one key over. Names are
# required to be strings for both lists: a non-string name renders through
# `jq -r` as `null`/`123` and would silently fail to match any workflow check.
# `.advisory` may be absent entirely (treated as empty), but if present it
# must be a well-formed array.
#
# Presence-aware, NOT `.advisory // []`: that alternative fires on `null` and
# `false` too, so an explicitly-null advisory would be accepted as an empty
# array — contradicting the very invariant being asserted, and downgrading a
# malformed lock (exit 2) to ordinary drift (exit 1). Absent is fine; present
# must be a well-formed array.
if ! jq -e '(.required | type == "array")
            and (all(.required[]; .name | type == "string"))
            and (if has("advisory")
                 then (.advisory | type == "array")
                      and (all(.advisory[]; .name | type == "string"))
                 else true end)
            and (all(((.required // [])[], (.advisory // [])[]);
                     (.name // "") | test("[[:cntrl:]]") | not))' \
     "$LOCK" >/dev/null 2>&1; then
  echo "error: $LOCK is malformed — .required must be an array, .advisory (if" >&2
  echo "       present) must be an array, every entry needs a string .name, and" >&2
  echo "       no name may contain a control character — the classifier joins" >&2
  echo "       names with U+001E, so a name carrying one would split into two" >&2
  echo "       and classify a job nobody listed" >&2
  exit 2
fi

# Resolve owner/repo from git remote when not supplied.
if [[ -z "$OWNER" || -z "$REPO" ]]; then
  remote_url=$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null || true)
  if [[ -z "$remote_url" ]]; then
    # Without a remote we can't run (b) or (c) at all. Default behavior is
    # "warn + LOCAL_ONLY=1" for onboarding ergonomics. Under --strict-remote
    # the operator explicitly asked us to treat "couldn't verify against the
    # server" as drift, so a missing remote is exit-1 drift, not a soft
    # skip. Same semantics as the gh-CLI absence path below.
    #
    # `--local-only` is an explicit operator opt-out from remote surfaces.
    # When BOTH --strict-remote and --local-only are set, --local-only wins:
    # the operator has said "I don't care about server verification this
    # run", so silently skipping (b)/(c) is the right outcome rather than
    # double-failing on a contradiction. This matches the gh-CLI absence
    # path which is already gated by the LOCAL_ONLY=1 early-exit at the
    # (b) block below.
    if [[ "$STRICT_REMOTE" -eq 1 && "$LOCAL_ONLY" -ne 1 ]]; then
      echo "[b] DRIFT: no git remote 'origin' — cannot verify against server (--strict-remote)" >&2
      exit 1
    fi
    echo "warn: no git remote 'origin' — running --local-only"
    LOCAL_ONLY=1
  else
    # Parse github.com:OWNER/REPO(.git)? or https://github.com/OWNER/REPO(.git)?
    # Normalize trailing slash + .git first so the regex doesn't have to handle
    # them as alternatives (and so the simpler regex catches both
    # `…/repo`, `…/repo/`, and `…/repo.git`).
    normalized="${remote_url%/}"           # strip one trailing slash if any
    normalized="${normalized%.git}"        # strip .git if any
    parsed=$(echo "$normalized" | sed -E 's#^.*[:/]([^/]+)/([^/]+)$#\1 \2#')
    OWNER="${OWNER:-$(echo "$parsed" | awk '{print $1}')}"
    REPO="${REPO:-$(echo "$parsed" | awk '{print $2}')}"

    # Validate parsed values. GitHub owner/repo names are restricted to
    # `[A-Za-z0-9._-]+`; anything else means the regex matched something it
    # shouldn't have (e.g., a non-github remote, a malformed URL, or a path
    # traversal attempt like `owner/../foo`). Fail-fast rather than feed
    # garbage into `gh api` URLs and get confusing 404s.
    if [[ ! "$OWNER" =~ ^[A-Za-z0-9._-]+$ || ! "$REPO" =~ ^[A-Za-z0-9._-]+$ ]]; then
      echo "error: could not parse OWNER/REPO from remote '$remote_url'" >&2
      echo "       parsed: OWNER='$OWNER' REPO='$REPO'" >&2
      echo "       hint: pass --owner X --repo Y, or --local-only to skip API checks" >&2
      exit 2
    fi
  fi
fi

drift=0

# Per-surface drift flags. Each surface uses its own local flag for its
# end-of-block "ok:" message so that an "ok" still prints when this surface
# itself found nothing — even if an earlier surface already set the global
# `drift` flag. Without per-surface flags, an operator inspecting a multi-
# surface failure sees the failed surface's DRIFT line but only header +
# "using commit:" lines for clean downstream surfaces, which reads as
# "this surface didn't finish" rather than "this surface passed". The
# global `drift` flag still aggregates all surfaces for the script's exit
# code — these locals only gate the per-surface ok messages.
a_drift=0
c_drift=0

# ────────────────────────────────────────────────────────────────────
# (a) Lock vs workflow source — every required entry's workflow file
#     must contain a job whose name (or key when no name) matches.
# ────────────────────────────────────────────────────────────────────
# ── Workflow inventory (single source of truth for (a), (d) and (e)) ────────
#
# Enumerated ONCE, by a real YAML parser, and shared by every surface. The three
# surfaces must agree on which jobs exist: while (a) walked the lock outward with
# one hand-written scanner and (d)/(e) collected with another, any disagreement
# produced an unsatisfiable lock — (e) demanding an entry for a job (a) could not
# resolve. One inventory makes that class of bug unrepresentable.
#
# Fails CLOSED. `node` or js-yaml missing is an ERROR, never a silent fallback to
# a weaker scan: an inventory that quietly under-reports is exactly the #530
# failure (a check nobody can see is a check nobody classifies).
if ! command -v node >/dev/null 2>&1; then
  echo "error: node is required to enumerate workflow checks" >&2
  echo "       (surfaces (a), (d) and (e) parse workflow YAML with js-yaml)" >&2
  exit 2
fi
if ! collected=$(node "$SCRIPT_DIR/lib/list-workflow-checks.mjs" "$REPO_ROOT"); then
  echo "error: could not enumerate workflow checks — refusing to report drift-free" >&2
  echo "       (run 'npm ci' if js-yaml is not installed)" >&2
  exit 2
fi

echo "[a] Checking lock entries against workflow source files…"

# Iterate required AND advisory entries. Use `jq -c` so the entire object stays
# on one line — multi-line outputs would break the read loop.
#
# Advisory entries are validated too, not just required ones. Surface (e)
# classifies a workflow check by NAME, so a STALE advisory entry — one whose
# job was renamed or deleted — keeps on classifying whatever new job later
# happens to post that name, silently satisfying the guard for a job nobody
# ever reviewed. Validating advisory here means a stale entry is caught as
# drift at its source instead of quietly widening (e).
while IFS= read -r entry; do
  name=$(echo "$entry" | jq -r '.name')
  workflow=$(echo "$entry" | jq -r '.workflow')
  job_key=$(echo "$entry" | jq -r '.job')
  source_app=$(echo "$entry" | jq -r '.source_app')
  # Optional `matrix_value` records the rendered matrix label that GitHub
  # appends to a job's effective check name as `<base> (<matrix_value>)`.
  # Examples: `"ubuntu-latest"` for a 1-dim matrix; `"ubuntu-latest, 18"`
  # (with a literal comma-space) for a multi-dim matrix. When set, surface
  # (a) compares against `<base> (<matrix_value>)` rather than `<base>` so
  # matrix-derived required check names line up with the workflow's bare
  # job. Absent / empty / null all degrade to the original non-matrix path.
  # `// ""` collapses null and missing to the empty string so the test below
  # is a clean string-emptiness check.
  #
  # We do NOT parse the workflow's strategy block to verify a matrix is
  # actually declared on this job — surface (a) is purely a name-match.
  # That means setting matrix_value on a non-matrix job and writing a
  # self-consistent `name` (matching `<base> (<matrix_value>)`) passes here.
  # The misuse only manifests downstream as a hung PR (branch protection
  # required name has no posting check). Document this in the lock _doc
  # and SKILL.md B1c so users know to omit matrix_value on non-matrix jobs;
  # do not rely on this surface to flag the mistake.
  matrix_value=$(echo "$entry" | jq -r '.matrix_value // ""')

  wf="$REPO_ROOT/$workflow"
  if [[ ! -f "$wf" ]]; then
    if [[ "$source_app" == "github-actions" ]]; then
      echo "  DRIFT: $name → workflow file missing: $workflow"
      drift=1
      a_drift=1
    else
      # External apps don't ship in our repo; skip the file check.
      :
    fi
    continue
  fi

  # External-app entries don't correspond to a local .yml — they post via
  # the GitHub Apps integration. Skip the source check for them.
  if [[ "$source_app" != "github-actions" ]]; then
    continue
  fi

  # Find the job. The match prefers an explicit `name: <name>` line within
  # the job's body; falls back to the bare job key only when *that specific
  # job* has no `name:` field (per-job bareness — not file-wide, so mixed
  # workflows where some jobs are named and some aren't are handled
  # correctly).
  #
  # All grep ERE patterns interpolate `$name` and `$job_key` via an awk-only
  # parser instead of shell-level regex strings, so check names containing
  # ERE metacharacters (`.`, `+`, `(`, etc.) match literally rather than as
  # patterns. Job keys are restricted to `[A-Za-z0-9_-]` by GitHub Actions'
  # YAML schema, but check names are free-form and routinely contain dots
  # ("CodeScene Code Health Review (main)"), spaces, and slashes.
  #
  # Strategy: walk the file's jobs block once with awk, recording for each
  # job key its declared `name:` value (or empty if none). Then look up the
  # current entry's `job_key`:
  #   - present + name matches      → ok
  #   - present + name empty        → bare-key match against `name`
  #   - present + name differs      → DRIFT (lock vs source disagreement)
  #   - absent                      → DRIFT (job key not found)
  #
  # Matrix jobs: GitHub renders matrix-strategy jobs as
  # `<base> (<matrix-label>)` where <base> is the explicit `name:` (or the
  # bare job key) and <matrix-label> is the joined `${{ matrix.* }}` values.
  # The lock entry expresses this with an optional `matrix_value` field
  # holding the literal label content; the comparison block below appends
  # ` (<matrix_value>)` to <base> before comparing against the lock's
  # `name`. Each matrix combination gets its own lock entry — matching the
  # one-name-per-context shape of branch protection's contexts list.
  #
  # `actual_name` uses string equality, no regex involvement, so the lookup
  # is metacharacter-safe.
  # Use POSIX-portable awk (no gawk-only 3-arg `match()` or `gensub()`).
  # `cur` holds the most recent job key we entered.
  # GitHub renders a matrix combination as `<base> (<label>)`. Non-matrix
  # entries carry no suffix, so this is the empty string for them.
  if [[ -n "$matrix_value" ]]; then
    matrix_suffix=" ($matrix_value)"
  else
    matrix_suffix=""
  fi
  # Look the job up in the shared inventory instead of re-scanning the file.
  actual_name=$(printf '%s\n' "$collected" | awk -F'\t' -v w="$workflow" -v j="$job_key" '
    $2 == w && $3 == j { print "FOUND:" $1; found = 1; exit }
    END { if (!found) print "MISSING" }
  ')
  if [[ "$actual_name" == "MISSING" ]]; then
    echo "  DRIFT: $name expected in $workflow as job '$job_key' — job key not found"
    drift=1
    a_drift=1
  elif [[ "$actual_name" == "FOUND:" ]]; then
    # Job exists with no explicit name — GitHub uses the job key as the
    # check name (plus matrix suffix for matrix jobs), so the lock entry's
    # `name` must equal `<job_key><matrix_suffix>`.
    expected="${job_key}${matrix_suffix}"
    if [[ "$name" != "$expected" ]]; then
      if [[ -n "$matrix_value" ]]; then
        echo "  DRIFT: lock says name='$name' but $workflow:$job_key has no 'name:' field (GitHub will report '$expected' for matrix_value='$matrix_value')"
      else
        echo "  DRIFT: lock says name='$name' but $workflow:$job_key has no 'name:' field (GitHub will report '$job_key')"
      fi
      drift=1
      a_drift=1
    fi
  else
    # FOUND with explicit name. Strip the FOUND: sentinel and append the
    # matrix suffix (empty for non-matrix entries) before comparing.
    observed="${actual_name#FOUND:}"
    expected="${observed}${matrix_suffix}"
    if [[ "$name" == "$expected" ]]; then
      : # explicit name match (with matrix suffix when present)
    else
      if [[ -n "$matrix_value" ]]; then
        echo "  DRIFT: lock says '$name' but $workflow:$job_key renders as '$expected' (name='$observed', matrix_value='$matrix_value')"
      else
        echo "  DRIFT: lock says '$name' but $workflow:$job_key has name '$observed'"
      fi
      drift=1
      a_drift=1
    fi
  fi
done < <(jq -c '(.required[]?, .advisory[]?) | select(.source_app == "github-actions")' "$LOCK")

if [[ "$a_drift" -eq 0 ]]; then
  echo "  ok: every lock entry maps to a workflow job"
fi

# ────────────────────────────────────────────────────────────────────
# (d) Workflow check-name uniqueness — every effective status-check name
#     across all workflows must be globally unique. Branch protection
#     matches required checks by name only; when two jobs in different
#     workflows post under the same name, GitHub picks one reporter
#     non-deterministically and ignores the rest. The lock's source_app
#     check (c) catches *which* app reported, but only after one of the
#     duplicates is already declared required — this check catches the
#     collision before it gets promoted into the lock.
#
# Effective check name = the job's explicit `name:` value, or the bare
# job key when no `name:` is declared — as resolved by the shared inventory.
# The former note about `${{ matrix.* }}` name TEMPLATES being stored
# literally no longer describes anything reachable: the enumerator now
# hard-errors on an expression-bearing name rather than recording a context
# GitHub never posts, so no template ever reaches this comparison.
#
# (d) does NOT consult the lock at all, and therefore does not consider the
# optional `matrix_value` field. Uniqueness is checked against effective
# workflow names, not against per-matrix-combination rendered names.
# That's intentional: collisions across the rendered space already
# manifest as collisions in template form, so checking templates catches
# every real collision without false positives from harmless cases where
# two matrix jobs happen to overlap on a single matrix value but diverge
# elsewhere.
#
# Limitations: reusable workflows (`uses: ./...yml`) are not walked;
# composite actions are not workflows. Both deferred until a real case
# appears in the fleet.
# ────────────────────────────────────────────────────────────────────
echo "[d] Checking workflow check-name uniqueness…"

# `collected` is the shared inventory built above by the YAML enumerator —
# (d) and (e) both read it, so they cannot disagree with (a) about what a
# workflow emits.

# Aggregate by effective name. Anything appearing more than once is drift.
# Use printf to feed a clean list (drops the trailing blank line from the
# loop's `+=$'\n'`) so awk does not see a phantom empty record.
duplicates=$(printf '%s' "$collected" | awk -F'\t' '
  $1 == "" { next }
  {
    count[$1]++
    if (locations[$1]) { locations[$1] = locations[$1] "; " $2 ":" $3 }
    else               { locations[$1] = $2 ":" $3 }
  }
  END {
    for (n in count) if (count[n] > 1) printf("%s\t%s\n", n, locations[n])
  }
' | LC_ALL=C sort)

if [[ -n "$duplicates" ]]; then
  echo "  DRIFT: workflow check name(s) used by multiple jobs:"
  while IFS=$'\t' read -r name locs; do
    echo "    - '$name' appears in: $locs"
  done <<< "$duplicates"
  drift=1
else
  echo "  ok: every workflow job has a unique effective check name"
fi

# ────────────────────────────────────────────────────────────────────
# (e) Lock classification completeness — every status check a workflow
#     posts must appear in lock.required OR lock.advisory.
# ────────────────────────────────────────────────────────────────────
# This is the surface that catches a check being ADDED without the lock
# learning about it — the direction (a) and (b) both miss. (a) walks the
# lock outward to the workflows, so a check absent from the lock is never
# looked up; (b) would catch it, but only once branch protection already
# requires it, and only when it can reach the API.
#
# That gap is not hypothetical (#530): `coverage`, `shell-tests`,
# `validate`, and `version-drift` were required by branch protection while
# absent from the lock. Because `relevant-check-status.sh` treats
# lock.required as an ALLOWLIST, the four were filtered out of the merge
# decision entirely — neither pending nor failed, simply invisible — so a
# PR with two FAILING required checks reported `0 0 required 8`, fully
# green, to both the pre-merge gate and pr-grind.
#
# Deliberately local: no API, no token, so it runs on fork PRs and is the
# only server-drift guard that can. Surface (b) is the authoritative
# comparison but needs `administration: read`, which GITHUB_TOKEN cannot
# be granted — see the CI job in tests.yml. (e) does not replace (b); it
# makes the common cause of (b) drift impossible to introduce silently,
# because adding a job now forces a classification decision in the lock.
#
# Reads `collected` from (d) — the same (name, workflow, job) tuples — so
# the two surfaces cannot disagree about what a workflow emits.
echo "[e] Checking every workflow check is classified in the lock…"

# \036 (RS) as the delimiter: check names legitimately contain spaces
# ("Actions security", "Dormant CVE sweep"), so a whitespace split would
# shatter them into fragments and report false drift.
# Only `github-actions` entries can classify a WORKFLOW check. An external-app
# entry (gitguardian, codecov, …) names a context this repo's workflows do not
# post, so honouring it here would let an Actions job take the name of an
# externally reported required context and still read as classified — a
# workflow-vs-app collision that no other surface catches: (a) skips external
# entries (they have no workflow/job to resolve) and (d) only compares
# workflow names against each other.
#
# Hoisted out of the `awk -v` so jq's exit status is not masked by the
# surrounding substitution (SC2312). The lock's shape was validated at
# startup, so a jq failure here is a genuine fault — fail loudly rather than
# proceed with an empty set, which would report every check as unclassified.
if ! known_names=$(jq -r '(.required[]?, .advisory[]?)
                          | select(.source_app == "github-actions")
                          | select(has("matrix_value") | not)
                          | .name' "$LOCK"); then
  echo "error: could not read check names from $LOCK" >&2
  exit 2
fi
# MATRIX JOBS are classified by their BARE BASE name; matrix entries (those
# carrying `matrix_value`) deliberately classify NOTHING here.
#
# The tempting shortcut — let any matrix entry for a (workflow, job) tuple
# cover that job — is a fail-OPEN, caught in review before this shipped. One
# entry would bless every rendered value of the job, so a matrix that GAINS a
# value (`os: [ubuntu, macos]` -> `+ windows`) keeps matching on the stale
# tuple and the new `<base> (windows-latest)` check is never demanded in the
# lock: the #530 hole again, one level in. Closing it properly means
# statically enumerating strategy.matrix — multi-dimensional products,
# include/exclude, `${{ }}` expressions — and failing closed on anything
# unenumerable. That is a YAML evaluator living inside a guard, far more
# failure surface than the gap it closes.
#
# So (e) asks only what it can answer soundly: is this JOB known to the lock at
# all? A matrix job earns that by listing its bare base name (in `advisory`,
# since the server requires the rendered names, not the base). Completeness of
# the rendered VALUES belongs to the surfaces built for it: (a) verifies each
# `matrix_value` entry resolves to a real job, and (b) set-compares the lock
# against the server contexts — which is where a newly-protected matrix value
# actually surfaces.
known_names=$(printf '%s' "$known_names" | tr '\n' '\036')

# Split the awk from the sort and check awk's status explicitly. Relying on the
# pipeline status alone is fragile here: if awk ever fails while `sort` succeeds,
# `unclassified` comes back EMPTY and (e) reports "ok" — the guard silently
# certifying a repo it never actually inspected. An empty result must mean
# "nothing unclassified", never "the check did not run".
# Passed through the ENVIRONMENT, never `awk -v`. `-v` processes backslash
# escapes in the value, so a lock name containing the literal four characters
# `\036` would be turned into a real record separator by awk and split into TWO
# names — smuggling an extra entry into `seen` and classifying a job nobody
# listed. Lock content is repo-controlled, so that is an injection into the
# guard. `ENVIRON[]` hands the bytes over verbatim.
if ! unclassified_raw=$(printf '%s' "$collected" | BD_KNOWN_NAMES="$known_names" awk -F'\t' '
  BEGIN { n = split(ENVIRON["BD_KNOWN_NAMES"], a, "\036"); for (i = 1; i <= n; i++) if (a[i] != "") seen[a[i]] = 1 }
  $1 == "" { next }
  ($1 in seen) { next }
  { printf("%s\t%s:%s\n", $1, $2, $3) }
'); then
  echo "error: classification scan failed — refusing to report (e) as clean" >&2
  exit 2
fi
unclassified=$(printf '%s' "$unclassified_raw" | LC_ALL=C sort -u)

if [[ -n "$unclassified" ]]; then
  echo "  DRIFT: workflow check(s) in neither lock.required nor lock.advisory:"
  while IFS=$'\t' read -r e_name e_loc; do
    echo "    - '$e_name' ($e_loc)"
  done <<< "$unclassified"
  echo "  fix: add each to .github/required-checks.lock — 'required' if branch"
  echo "       protection gates on it, 'advisory' if it must never gate merge."
  drift=1
else
  echo "  ok: every workflow check name is classified in the lock"
fi

# ────────────────────────────────────────────────────────────────────
# (b) Lock vs branch protection — names in lock.required must equal the
#     server's required_status_checks.contexts (set equality).
# ────────────────────────────────────────────────────────────────────
# Both early-exit paths below print explicit `[c] Skipped …` lines alongside
# the `[b]` label. Without it, output ends with `[a] ok / [d] ok / [b] Skipped`
# and the operator can't tell whether (c) was intentionally skipped or simply
# never ran. The exit code is unchanged — these are output-only additions.
if [[ "$LOCAL_ONLY" -eq 1 ]]; then
  echo "[b] Skipped (--local-only)"
  echo "[c] Skipped (--local-only)"
  exit "$drift"
fi

if ! command -v gh >/dev/null 2>&1; then
  # No gh CLI means we can't query branch protection or check-runs at all.
  # Default behavior is "skip + warn" so the script stays usable on machines
  # without gh installed. Under --strict-remote the operator explicitly asked
  # us to treat "couldn't verify against the server" as drift, so missing gh
  # is exit-1 drift. Same semantics as the missing-remote path above.
  if [[ "$STRICT_REMOTE" -eq 1 ]]; then
    echo "[b] DRIFT: gh CLI not installed — cannot verify against server (--strict-remote)" >&2
    exit 1
  fi
  echo "[b] Skipped (gh CLI not installed). Re-run with gh available or pass --local-only."
  echo "[c] Skipped (gh CLI not installed)."
  exit "$drift"
fi

echo "[b] Checking lock against $OWNER/$REPO branch protection…"

# Default branch lookup (most repos use 'main' but be explicit)
default_branch=$(gh api "repos/$OWNER/$REPO" --jq '.default_branch' 2>/dev/null || echo "main")

# Distinguish three cases that the original `--jq '.contexts[]'` form
# silently merged:
#   (i)   gh api errored / branch unprotected / 404                   → warn-skip
#   (ii)  gh api succeeded with `contexts: []`  (real-empty)          → drift if lock has entries
#   (iii) gh api succeeded with `contexts: ["a",…]`                   → set-compare
#
# Use `gh api` exit code (not response shape) to detect (i). Use `jq -e` to
# detect (ii) vs (iii) without conflating null/missing with empty array.
api_path="repos/$OWNER/$REPO/branches/$default_branch/protection/required_status_checks"
if server_response=$(gh api "$api_path" 2>/dev/null); then
  api_ok=1
else
  api_ok=0
fi

# Two failure paths share a common ladder: emit a label, then either drift
# (under --strict-remote) or warn (default). The (b) check's whole purpose
# is verifying lock matches server, so "couldn't verify" is structurally
# the same shape as drift. Default-warn keeps onboarding ergonomic;
# strict-remote opt-in is for CI / scheduled drift checks where the
# absence of a verifiable answer is itself a problem.
fail_or_warn_b() {
  local msg="$1"
  if [[ "$STRICT_REMOTE" -eq 1 ]]; then
    echo "  DRIFT: $msg (--strict-remote)"
    drift=1
  else
    echo "  warn: $msg"
  fi
}

if [[ "$api_ok" -eq 0 ]]; then
  fail_or_warn_b "could not read required_status_checks (no branch protection? insufficient scope?)"
elif ! contexts_count=$(printf '%s' "$server_response" \
       | jq -er 'if (has("contexts") and (.contexts | type == "array")) then .contexts | length else error("missing-contexts") end' 2>/dev/null); then
  # API returned 200 but the response shape is unexpected: either `.contexts`
  # is absent, or it's not an array. The bare jq form `.contexts | length`
  # would have returned 0 for missing fields (since `null | length` is 0),
  # conflating "missing" with "real-empty".
  fail_or_warn_b "required_status_checks response missing .contexts field — unexpected API shape"
else
  # Force C locale so shell `sort` matches jq's codepoint ordering. Without
  # this, en_US.UTF-8 dictionary order interleaves cases ("commitlint" sorts
  # before "Dependency CVEs"), while jq sort is strict codepoint ("D" < "c"),
  # producing a phantom diff where every item appears on both sides.
  server_contexts=$(printf '%s' "$server_response" | jq -r '.contexts[]?' | LC_ALL=C sort)
  lock_contexts=$(jq -r '.required[].name' "$LOCK" | LC_ALL=C sort)
  lock_count=$(jq -r '.required | length' "$LOCK")

  # `echo "$empty_var"` always emits a trailing newline, so an empty side
  # would feed `comm` a blank line and produce a phantom drift entry. Use
  # `printf '%s\n' | grep -v '^$'` to strip blanks so genuine empty/empty,
  # empty/non-empty, and non-empty/empty cases all report cleanly.
  #
  # `comm` itself must ALSO run under LC_ALL=C: it assumes its inputs are sorted
  # in the SAME collation it uses to compare them. The inputs are LC_ALL=C-sorted
  # (codepoint) above, but a bare `comm` inherits the caller's locale (e.g.
  # en_US/en_HK.UTF-8 dictionary order). When the two lists differ in membership
  # AND contain interleaved case (a lowercase "commitlint" sorting after the
  # uppercase entries in C order but among them in dictionary order), the
  # collation mismatch makes comm emit phantom diffs — e.g. "commitlint" on both
  # sides. This stayed dormant while lock == server (identical line sequences
  # match in lockstep regardless of locale) and only surfaced once entries were
  # added. Pinning comm to C makes its comparison consistent with the sort.
  missing_on_server=$(LC_ALL=C comm -23 <(printf '%s\n' "$lock_contexts" | grep -v '^$' || true) \
                                         <(printf '%s\n' "$server_contexts" | grep -v '^$' || true) || true)
  extra_on_server=$(LC_ALL=C comm -13   <(printf '%s\n' "$lock_contexts" | grep -v '^$' || true) \
                                         <(printf '%s\n' "$server_contexts" | grep -v '^$' || true) || true)

  if [[ -n "$missing_on_server" ]]; then
    echo "  DRIFT: in lock but not required on server:"
    # Parameter expansion replaces sed-subprocess (SC2001): prepend `    - `
    # to the first line via the leading literal, then replace each remaining
    # newline with `\n    - ` so every subsequent line gets the same prefix.
    # Both call sites are inside `[[ -n "$var" ]]` guards, so the empty-input
    # edge case is unreachable here.
    echo "    - ${missing_on_server//$'\n'/$'\n'    - }"
    drift=1
  fi
  if [[ -n "$extra_on_server" ]]; then
    echo "  DRIFT: required on server but not in lock:"
    echo "    - ${extra_on_server//$'\n'/$'\n'    - }"
    drift=1
  fi
  if [[ -z "$missing_on_server" && -z "$extra_on_server" ]]; then
    if [[ "$contexts_count" -eq 0 && "$lock_count" -eq 0 ]]; then
      echo "  ok: both lock and server are empty (no required checks declared anywhere)"
    else
      echo "  ok: lock.required matches server contexts (both contain $contexts_count items)"
    fi
  fi
fi

# ────────────────────────────────────────────────────────────────────
# (c) Lock vs reporting app — for the latest commit on default branch,
#     each required check's reporting `app.slug` must equal its
#     declared source_app. Catches drift when a different integration
#     starts posting a same-named status.
# ────────────────────────────────────────────────────────────────────
echo "[c] Checking lock source_app against latest check-run reporters…"

# Walk back through recent commits to find one that actually ran CI.
# Release commits often use `[skip ci]` and have no check-runs, which is
# expected — keep stepping back until we find a real commit.
runs_json=""
sha=""
for offset in 0 1 2 3 4 5 6 7 8 9; do
  candidate=$(gh api "repos/$OWNER/$REPO/commits?sha=$default_branch&per_page=1&page=$((offset+1))" \
    --jq '.[0].sha' 2>/dev/null || true)
  [[ -z "$candidate" || "$candidate" == "null" ]] && continue
  # The check-runs endpoint paginates at 100 results per page. Repos with many
  # integrations or repeated CI re-runs on the same commit can exceed that, so
  # without --paginate the script emits "warn: no check-run named X" for items
  # past page 1 instead of detecting real drift. --paginate streams items,
  # which `jq -sc '.'` then collapses back into a single JSON array.
  rj=$(gh api "repos/$OWNER/$REPO/commits/$candidate/check-runs" --paginate \
         --jq '.check_runs[]' 2>/dev/null \
       | jq -sc '.' || true)
  count=$(echo "$rj" | jq 'length' 2>/dev/null || echo 0)
  if [[ "${count:-0}" -gt 0 ]]; then
    runs_json="$rj"
    sha="$candidate"
    break
  fi
done

if [[ -z "$runs_json" ]]; then
  # Same fail-closed ladder as (b): under --strict-remote, "couldn't fetch
  # any check-runs from the last 10 commits" means we can't verify the
  # source-app contract — that's drift, not an info skip.
  if [[ "$STRICT_REMOTE" -eq 1 ]]; then
    echo "  DRIFT: no recent commit (last 10) had check-runs — cannot verify source_app (--strict-remote)"
    drift=1
  else
    echo "  warn: no recent commit (last 10) had check-runs — skipping app check"
  fi
  exit "$drift"
fi
echo "  using commit: ${sha:0:7}"

while IFS= read -r entry; do
  name=$(echo "$entry" | jq -r '.name')
  expected_app=$(echo "$entry" | jq -r '.source_app')
  # Pick the most recent check-run for this name (highest started_at).
  actual=$(echo "$runs_json" | jq -r --arg n "$name" '
    [.[] | select(.name == $n)] | sort_by(.started_at) | last
  ')
  if [[ "$actual" == "null" || -z "$actual" ]]; then
    echo "  warn: no check-run named '$name' on HEAD — skipping app check"
    continue
  fi
  actual_slug=$(echo "$actual" | jq -r '.app.slug // "unknown"')
  if [[ "$actual_slug" != "$expected_app" ]]; then
    echo "  DRIFT: '$name' expected source_app='$expected_app' but reported by '$actual_slug'"
    drift=1
    c_drift=1
  fi
done < <(jq -c '.required[]' "$LOCK")

if [[ "$c_drift" -eq 0 ]]; then
  echo "  ok: every required check is reported by its expected source app"
fi

exit "$drift"
