#!/usr/bin/env node
// list-workflow-checks.mjs — enumerate the status checks this repo's workflows
// post, as TSV: <effective_name>\t<workflow_rel_path>\t<job_key>
//
// Single source of truth for surfaces (a), (d) and (e) of
// check-required-checks.sh. They MUST agree on which jobs exist: when (a)
// walked the lock outward with one parser and (d)/(e) collected with another,
// any disagreement produced an unsatisfiable lock — (e) demanding an entry for
// a job (a) could not resolve, CI red with no state that satisfies both.
//
// Uses a real YAML parser deliberately. The regex scanner this replaces was
// probed apart one shape at a time over six review rounds — four-space
// indentation, flow mappings, mixed block+flow, flow-style-first ordering,
// anchors, aliases, quoted `"jobs":` — and each fix only exposed the next
// shape, because a hand-written parser cannot enumerate a YAML document. Every
// one of those shapes is a job that posts a real check; a scanner that cannot
// see it is a merge gate certifying a repo it never inspected (#530).
//
// Exit codes: 0 ok (TSV on stdout) · 2 unreadable/unparseable workflow.
// Fails CLOSED — it never emits a partial list, because "no jobs" and "I could
// not read the jobs" must never look identical to the caller.

import { readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { load } from "js-yaml";

// Shared by the job-name check and the matrix dimension-value check below —
// see the rationale at the job-name call site. A single constant makes it
// structurally impossible for the two sites to drift onto different
// predicates; two independent literals would only be caught by convention
// plus a test.
const CONTROL_CHAR_RE = /\p{Cc}/u;

const root = process.argv[2];
if (!root) {
  process.stderr.write("usage: list-workflow-checks.mjs <repo-root>\n");
  process.exit(2);
}

const dir = join(root, ".github", "workflows");
let files;
try {
  // Both extensions: Actions accepts .yml and .yaml, and a .yaml workflow that
  // collided with a .yml one would otherwise be invisible to surface (d).
  files = readdirSync(dir)
    .filter((f) => f.endsWith(".yml") || f.endsWith(".yaml"))
    .sort();
} catch (err) {
  if (err.code === "ENOENT") process.exit(0); // no workflows dir: nothing to emit
  process.stderr.write(`error: cannot read ${dir}: ${err.message}\n`);
  process.exit(2);
}

// js-yaml resolves several YAML scalars to OBJECTS: `2026-01-01` becomes a
// Date, `!!binary SGVsbG8=` a Uint8Array. Every one of them satisfies a
// `typeof v === "object" && !Array.isArray(v)` test while carrying none of the
// keys the caller then reads — so a malformed `strategy:` of that shape read as
// "no matrix" and the job emitted its bare name. That is a fail-OPEN in a file
// where every other unresolvable shape refuses, and the same hole existed for
// `jobs:`, an individual job, and `matrix:`. Require a genuine mapping at all
// four, from one predicate, so they cannot drift apart.
const isPlainMapping = (v) => {
  if (typeof v !== "object") return false;
  if (v === null) return false;
  if (Array.isArray(v)) return false;
  const proto = Object.getPrototypeOf(v);
  return proto === Object.prototype || proto === null;
};

// GitHub formats numbers with .NET G15. For an integer of at most 15
// significant digits that is exactly String(v), so the common `node: [18, 20]`
// is safe. Beyond that they diverge — 1e20 renders as `1E+20`, and 1.10 as
// `1.1` — and a mismatch names a context that is never posted. NaN and
// ±Infinity are numbers too, and fail Number.isInteger, so they're excluded
// here rather than rendering as labels. Named and extracted (not an inline
// `&&` chain) to keep the matrix-dimension guard below at one condition per
// branch (#536).
const isRenderableMatrixInteger = (v) =>
  typeof v === "number" && Number.isInteger(v) && Math.abs(v) < 1e15;

const rows = [];
for (const file of files) {
  const rel = join(".github", "workflows", file);
  const abs = join(dir, file);
  let doc;
  try {
    doc = load(readFileSync(abs, "utf8"));
  } catch (err) {
    process.stderr.write(`error: cannot parse ${rel}: ${err.message}\n`);
    process.exit(2);
  }
  if (doc == null || typeof doc !== "object") continue;
  const jobs = doc.jobs;
  if (jobs == null) continue; // a workflow with no jobs block emits no checks
  if (!isPlainMapping(jobs)) {
    process.stderr.write(`error: ${rel}: 'jobs' is not a mapping\n`);
    process.exit(2);
  }
  for (const [key, job] of Object.entries(jobs)) {
    // A non-mapping job is malformed; refuse rather than guess its check name.
    if (!isPlainMapping(job)) {
      process.stderr.write(`error: ${rel}: job '${key}' is not a mapping\n`);
      process.exit(2);
    }
    // A `name:` carrying a ${{ }} expression is REFUSED, not silently replaced
    // by the job key. GitHub evaluates the expression and posts the rendered
    // name, so falling back to the key would have every surface inspect a
    // context that is never posted — (e) could then report a repo fully
    // classified while the real check went unlisted, which is #530 exactly.
    // "I cannot resolve this" must never read as "this is fine".
    if (typeof job.name === "string" && job.name.includes("${{")) {
      process.stderr.write(
        `error: ${rel}: job '${key}' has an expression-bearing name ` +
          `(${job.name}) that cannot be resolved statically\n`,
      );
      process.exit(2);
    }
    // A non-string `name:` is REFUSED — including numbers and booleans.
    //
    // Coercing them looked reasonable and is wrong: GitHub formats numeric job
    // names with .NET's G15, so `name: 1e20` posts the context `1E+20` while
    // js-yaml + String() yields `100000000000000000000`. Reproducing that
    // formatting means embedding another runtime's number rendering inside a
    // merge gate, and any mismatch records a context that is never posted.
    // Quoting (`name: "2024"`) is unambiguous, is what the lock must contain
    // anyway, and is what the error tells the author to do.
    let name;
    if (job.name === undefined) {
      name = key;
    } else if (typeof job.name === "string") {
      name = job.name;
    } else {
      process.stderr.write(
        `error: ${rel}: job '${key}' has a non-string name: ` +
          `${JSON.stringify(job.name)} — quote it so the rendered check name is ` +
          `unambiguous (e.g. name: "2024")\n`,
      );
      process.exit(2);
    }
    // An empty or whitespace-only name is REFUSED. It would be emitted as a row
    // with an empty first field, and both (d) and (e) skip empty names — so the
    // job would bypass the collision check AND the classification check at once,
    // which is the widest fail-open in this file.
    if (name.trim() === "") {
      process.stderr.write(
        `error: ${rel}: job '${key}' has an empty name:\n`,
      );
      process.exit(2);
    }
    // The inventory is TSV and is field-split by awk. A control character in a
    // name would shift every downstream field, so (a) would compare the wrong
    // column and (e) could read a job as classified that never was. Refuse.
    //
    // `CONTROL_CHAR_RE` matches the lock validator BY CONSTRUCTION, not by eye:
    // check-required-checks.sh rejects lock names matching jq's `[[:cntrl:]]`,
    // and jq's `[[:cntrl:]]` is exactly the Unicode Cc category — U+0000-U+001F
    // AND U+007F-U+009F. An ASCII-only range silently accepts the C1 block, so
    // a job name containing U+0085 would enter the inventory while its lock
    // entry was rejected: an UNSATISFIABLE lock, (e) demanding an entry that
    // (a) can never validate. The two predicates are asserted equal over every codepoint by
    // tests/test-required-checks-lock-classification.sh rather than trusted to
    // this comment. Shared as a single constant (used again for matrix dimension
    // values below) so the two sites can never drift apart.
    if (CONTROL_CHAR_RE.test(name)) {
      process.stderr.write(
        `error: ${rel}: job '${key}' name contains a control character\n`,
      );
      process.exit(2);
    }
    // Matrix jobs: emit one row per RENDERED combination, `<base> (<label>)`.
    //
    // The bare base name is not enough. Surface (e) would accept one advisory
    // entry for the base while a newly required rendered context — `build
    // (windows-latest)` — stayed absent from the lock, and (d) would miss
    // collisions between rendered names. Surface (b) does catch that, but (b)
    // needs `administration: read` and therefore cannot run in CI, so in CI the
    // gap is unguarded. That is #530's shape exactly.
    //
    // Only the statically determinable subset is enumerated: literal scalar
    // lists, multiplied across dimensions in declaration order (which is the
    // order GitHub joins the label in). Anything whose values cannot be known
    // from the file alone — a ${{ }} expression, fromJSON(), or the
    // include/exclude reshaping rules — is REFUSED rather than guessed at.
    // Enumerating those would mean reimplementing Actions expression
    // evaluation inside a merge gate; refusing keeps the failure visible.
    // A reusable-workflow caller (`jobs.<id>.uses:`) posts one check per job of
    // the CALLED workflow, named `<caller> / <called job>`, and nothing under
    // the caller name itself. Emitting `<name>` here would invent a context that
    // is never posted while leaving the real ones unlisted. Resolving them means
    // following the callee (and remote callers are not on disk at all), so this
    // refuses rather than guessing.
    if (job.uses !== undefined) {
      process.stderr.write(
        `error: ${rel}: job '${key}' calls a reusable workflow; its checks are ` +
          `named '<caller> / <called job>' and cannot be resolved from this file\n`,
      );
      process.exit(2);
    }
    const refuse = (why) => {
      process.stderr.write(`error: ${rel}: job '${key}' matrix ${why}\n`);
      process.exit(2);
    };
    // A non-mapping `strategy` must not be silently read as "no matrix" —
    // `job.strategy?.matrix` yields undefined for a string, array, number AND
    // for a Date or Uint8Array (see isPlainMapping), letting the job through
    // with its bare name while every other unresolvable shape here fails closed.
    if (job.strategy !== undefined && !isPlainMapping(job.strategy)) {
      refuse("has a non-mapping 'strategy'");
    }
    const matrix = job.strategy?.matrix;
    if (matrix === undefined) {
      rows.push(`${name}\t${rel}\t${key}`);
      continue;
    }
    if (typeof matrix === "string") refuse("is an expression, not a literal mapping");
    if (!isPlainMapping(matrix)) refuse("is not a mapping");
    if ("include" in matrix || "exclude" in matrix) {
      refuse("uses include/exclude, whose rendered names are not derivable here");
    }
    const dims = [];
    for (const [dim, values] of Object.entries(matrix)) {
      if (!Array.isArray(values)) refuse(`dimension '${dim}' is not a literal list`);
      // One flat guard per rejected shape, accepted shapes returning early.
      // Deliberately NOT nested by type (`if string { if expression … }`): the
      // types are mutually exclusive, so nesting bought no precision while
      // hiding each refusal one level deeper than the shape it names. Read it
      // as a list of "which values are refusable, and why" — every branch is
      // one line and no branch is reachable through another (#536).
      const labels = values.map((v) => {
        if (typeof v === "boolean") return String(v);
        // See isRenderableMatrixInteger above for why this range is safe and
        // everything outside it is refused rather than rendered.
        if (isRenderableMatrixInteger(v)) return String(v);
        if (typeof v === "number") {
          refuse(
            `dimension '${dim}' has a number (${v}) whose rendered form is ` +
              `ambiguous — quote it (e.g. "${v}")`,
          );
        }
        // Anything still here is neither boolean nor number, so a non-string is
        // a nested list/mapping, null, or a js-yaml object scalar (Date,
        // Uint8Array) — none of which has a rendered form to emit.
        if (typeof v !== "string") refuse(`dimension '${dim}' has a non-scalar value`);
        if (v.includes("${{")) refuse(`dimension '${dim}' contains an expression`);
        // Same rule, same predicate as the job name above: a control
        // character would shift TSV fields downstream, letting a surface read
        // the wrong column or ingest an injected row.
        if (CONTROL_CHAR_RE.test(v)) {
          refuse(`dimension '${dim}' has a value containing a control character`);
        }
        return v;
      });
      if (labels.length === 0) refuse(`dimension '${dim}' is empty`);
      dims.push(labels);
    }
    if (dims.length === 0) refuse("declares no dimensions");
    // Size the product BEFORE expanding it. Twenty dimensions of twenty values
    // is 20^20 combinations — enough to exhaust memory inside the gate long
    // before any per-row check could reject it. GitHub caps a matrix at 256
    // jobs, so anything larger is not a workflow this repo could run anyway.
    const total = dims.reduce((n, labels) => n * labels.length, 1);
    if (total > 256) {
      refuse(`expands to ${total} combinations, above GitHub's limit of 256`);
    }
    // Cartesian product in declaration order; GitHub joins the label with ", ".
    let combos = [[]];
    for (const labels of dims) {
      combos = combos.flatMap((c) => labels.map((l) => [...c, l]));
    }
    // An explicit `name:` is used VERBATIM by GitHub — the `(values)` suffix is
    // synthesized only for a job with no name of its own. Expression-bearing
    // names are refused above, so a named matrix job here has a STATIC name and
    // every leg posts that same context.
    //
    // With ONE combination that is unambiguous: a single check under that name,
    // representable exactly. With more, several check runs compete for one
    // context name — the ambiguity surface (d) exists to catch — and neither
    // available shape is honest (appending the combination invents contexts
    // that are never posted; collapsing to one row hides the competition). So
    // only the many-leg case is refused.
    if (job.name !== undefined) {
      if (combos.length === 1) {
        rows.push(`${name}\t${rel}\t${key}`);
        continue;
      }
      // The remedy is ONLY "drop the name": suggesting an expression would be
      // self-contradictory, since expression-bearing names are refused above.
      process.stderr.write(
        `error: ${rel}: job '${key}' has a ${combos.length}-leg matrix and a ` +
          `static name ('${name}'), so every leg posts that same context — ` +
          `drop the name: and GitHub will render '<job-key> (<values>)'\n`,
      );
      process.exit(2);
    }
    for (const combo of combos) {
      rows.push(`${name} (${combo.join(", ")})\t${rel}\t${key}`);
    }
  }
}

process.stdout.write(rows.length ? rows.join("\n") + "\n" : "");
