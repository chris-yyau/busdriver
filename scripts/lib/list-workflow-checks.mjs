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
  if (typeof jobs !== "object" || Array.isArray(jobs)) {
    process.stderr.write(`error: ${rel}: 'jobs' is not a mapping\n`);
    process.exit(2);
  }
  for (const [key, job] of Object.entries(jobs)) {
    // A non-mapping job is malformed; refuse rather than guess its check name.
    if (job == null || typeof job !== "object" || Array.isArray(job)) {
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
    // The inventory is TSV and is field-split by awk. A tab or newline inside a
    // name would shift every downstream field, so (a) would compare the wrong
    // column and (e) could read a job as classified that never was. Refuse.
    if (/[\t\r\n]/.test(name)) {
      process.stderr.write(
        `error: ${rel}: job '${key}' name contains a tab or newline\n`,
      );
      process.exit(2);
    }
    // Matrix jobs are emitted under their BARE BASE name. GitHub renders each
    // combination as `<base> (<label>)`, and enumerating those statically means
    // evaluating include/exclude and ${{ }} products — a YAML evaluator inside
    // a guard. Completeness of rendered values stays with surface (b), which
    // set-compares the lock against the server's actual contexts.
    rows.push(`${name}\t${rel}\t${key}`);
  }
}

process.stdout.write(rows.length ? rows.join("\n") + "\n" : "");
