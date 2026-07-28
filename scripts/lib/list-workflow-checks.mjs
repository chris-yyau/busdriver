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
    // Effective check name: explicit `name:` when it is a plain string, else
    // the job key. A `name:` carrying a ${{ }} expression cannot be resolved
    // statically, so it is NOT treated as a literal — the base key is used and
    // surface (b) remains the authority on the rendered context.
    const named = typeof job.name === "string" && !job.name.includes("${{");
    const name = named ? job.name : key;
    // Matrix jobs are emitted under their BARE BASE name. GitHub renders each
    // combination as `<base> (<label>)`, and enumerating those statically means
    // evaluating include/exclude and ${{ }} products — a YAML evaluator inside
    // a guard. Completeness of rendered values stays with surface (b), which
    // set-compares the lock against the server's actual contexts.
    rows.push(`${name}\t${rel}\t${key}`);
  }
}

process.stdout.write(rows.length ? rows.join("\n") + "\n" : "");
