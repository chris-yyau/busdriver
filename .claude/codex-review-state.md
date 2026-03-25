---
active: true
iteration: 2
max_iterations: 10
completion_promise: null
review_mode: "commit"
review_status: "FAIL"
started_at: "2026-03-25T11:34:03Z"
last_result: "{
  \"status\": \"FAIL\",
  \"issues\": [
    {
      \"file\": \"skills/dmux-workflows/SKILL.md\",
      \"line\": 153,
      \"severity\": \"medium\",
      \"category\": \"bug\",
      \"description\": \"The new `launcherCommand` is not a valid Codex CLI invocation: `codex exec` supports `-C/--cd`, but not `--cwd`, and there is no `--task-file` flag. Copying this example into `plan.json` will cause the helper workflow to fail immediately with an argument error instead of launching workers.\",
      \"suggestion\": \"Replace the example with a command that uses supported Codex flags, e.g. `-C/--cd`, and feed the task file via stdin or a wrapper script.\"
    },
    {
      \"file\": \"skills/videodb/SKILL.md\",
      \"line\": 307,
      \"severity\": \"medium\",
      \"category\": \"bug\",
      \"description\": \"`python scripts/ws_listener.py` is now resolved relative to the caller's current working directory, but the quick-start steps never tell the user to `cd` into `skills/videodb`. In a normal session started from a project root, this path does not exist, so the listener setup fails with `No such file or directory`.\",
      \"suggestion\": \"Anchor the listener path to the installed skill directory again, or explicitly add a step that changes into `skills/videodb` before running the command.\"
    },
    {
      \"file\": \"skills/benchmark/SKILL.md\",
      \"line\": 1,
      \"severity\": \"medium\",
      \"category\": \"bug\",
      \"description\": \"The frontmatter removal here (and similarly in `skills/browser-qa/SKILL.md` and `skills/canary-watch/SKILL.md`) drops the `name` and `description` metadata that this repo's skill tooling parses from `SKILL.md`. As a result, scanners like `skills/skill-stocktake/scripts/scan.sh` now return empty metadata for these skills, and they may stop being discoverable by name/description in environments that preload skill frontmatter.\",
      \"suggestion\": \"Restore the YAML frontmatter with `name` and `description` on each affected skill file.\"
    }
  ]
}"
---

You are a code reviewer. Review ONLY the following staged changes (git diff --cached output). Do NOT review unstaged or untracked files.

CHANGELOG FROM PREVIOUS TASK:
{{PREV_CHANGELOG}}

STAGED CHANGES TO REVIEW:
{{STAGED_DIFF}}

{{ITERATION_HISTORY}}

Check for:
- Security: dangerous functions (eval, exec), SQL injection, XSS, command injection, path traversal, SSRF
- Bugs: null/undefined errors, race conditions, off-by-one errors, infinite loops
- Performance: N+1 queries, unnecessary re-renders, memory leaks, blocking operations
- Maintainability: code duplication, unclear naming, missing error handling
- Property testing gap: if changes touch parsers, validators, serializers, auth, or financial logic — flag as LOW severity if no property-based tests exist (Hypothesis, fast-check, testing/quick). Advisory only, not blocking.

<CONVERGENCE_RULES>
- Do NOT re-report issues from previous iterations that have been fixed
- Focus on verifying fixes from previous iterations first
- Only report NEW issues not seen in any previous iteration
- If all previous issues are fixed and no new issues found, return PASS
- Maximum 3 new issues per iteration to ensure convergence
- Only report issues present in the STAGED CHANGES above
</CONVERGENCE_RULES>

<CRITICAL_INSTRUCTION>
After your analysis, you MUST execute this final step:

Step 1: Think through the issues (optional)
Step 2: OUTPUT EXACTLY THIS FORMAT:

If issues found:
{"status":"FAIL","issues":[{"file":"path","line":N,"severity":"high|medium|low","category":"security|bug|performance|maintainability","description":"...","suggestion":"..."}]}

If no issues:
{"status":"PASS","issues":[]}

Rules:
- Status "FAIL" = any high/medium severity issues
- Status "PASS" = zero issues OR only low severity
- The JSON must be the absolute LAST line of your response
- No text after the JSON closing brace
</CRITICAL_INSTRUCTION>
