# Codex Reviewer Troubleshooting

Common issues and solutions when using the codex-reviewer skill.

## General Issues

### Issue: "stdin is not a terminal" error

**Solution:** Codex doesn't accept piped input. The skill automatically handles uncommitted changes, so no manual diff piping is needed.

### Issue: Codex CLI not found

**Solution:** Check if Codex is installed:
```bash
which codex
```
If not installed, install it according to your system's package manager.

### Issue: Codex is taking a very long time (10+ minutes)

**Solution:** This is normal for large diffs (700+ lines). Consider:
- Reviewing in smaller chunks (per-file or per-feature)
- Reading the reasoning output to start fixing issues early (look for "thinking" sections)
- Running in background with `run_in_background=true`
- Using TaskOutput tool to monitor background progress

### Issue: Output contains reasoning/thinking text mixed with JSON

**Solution:** The final JSON appears at the end of the output. Codex includes reasoning sections throughout the analysis. Extract just the JSON block from the end, or use the reasoning output to identify issues early.

### Issue: Codex returns narrative feedback instead of JSON format

**Solution:** Despite the strict prompt, Codex occasionally returns narrative feedback (e.g., "P2: Missing ON DELETE CASCADE..."). When this happens:

1. **Parse the narrative** to extract issues and severity levels (look for P1/high, P2/medium, P3/low markers)
2. **Assess status manually**:
   - FAIL if any high/medium severity issues mentioned
   - PASS if only low severity or "no issues" mentioned
3. **Triage issues** normally (ACCEPT/REJECT/QUESTION)
4. **Fix issues** and re-run review
5. **Subsequent runs** often return proper JSON format

Example of parsing narrative output:
- "P2: Missing ON DELETE CASCADE" → medium severity, treat as FAIL
- "No concrete bugs evident" → treat as PASS
- Continue with normal fix-and-retest workflow

### Issue: No git changes detected

**Solution:** Ensure changes are staged with `git add` or committed to see them in `git diff HEAD`

### Issue: Review finds issues you've already fixed

**Solution:** Make sure to stage all changes before re-running:
```bash
git add -A  # Stage all changes
# Review will automatically detect staged changes
```

### Issue: Reached max iterations (10) without PASS

**Solution:** This indicates cascading issues or complex changes. When loop stops at iteration 10, Claude will ask you what to do next. Options:

1. **Continue loop** - Reset counter and continue iterating
2. **Break into smaller changes** - Separate concerns, review each independently
3. **Manually review together** - Interactive review of remaining issues
4. **Commit with issues** - Acknowledge technical debt, file issues for follow-up

**Common causes:**
- Fixes introducing new issues
- Misunderstanding Codex suggestions
- Changes too large (300+ lines)
- Architectural issues requiring design discussion

**Prevention:**
- Review smaller incremental changes
- Understand Codex feedback before fixing
- Break large refactorings into multiple commits

## Automation Issues

### Issue: Getting "Do you want to proceed?" prompt during review loop

**Root cause:** Missing `run_in_background=true` in Bash tool calls

**Solution:**

1. Verify all Bash calls use run_in_background=true:
   ```python
   # CORRECT - automated
   Bash(
     command="bash execute_review.sh",
     run_in_background=true,  # This prevents prompts
     timeout=600000
   )

   # WRONG - will prompt
   Bash(
     command="bash execute_review.sh",
     timeout=600000
   )
   ```

2. If prompts still appear, check Claude Code settings:
   - Ensure dangerous commands approval is disabled for trusted directories
   - Check ~/.claude/config.json for approval policies

### Issue: Iteration counter commands asking for approval

**Solution:** These are simple file writes and shouldn't need approval. If they do:
1. Use run_in_background=false for simple commands (< 2 seconds)
2. Only use run_in_background=true for long-running commands like codex review
3. Check if your shell has aliases that make commands interactive

### Issue: Automation works for first iteration, then prompts on second

**Solution:** This means run_in_background=true wasn't used consistently. Every review call in the loop must use it:
```python
# Iteration 1: run_in_background=true ✓
# Iteration 2: run_in_background=true ✓  <- Must be here too!
# Iteration 3: run_in_background=true ✓  <- And here!
```

**Best Practice:** Create a wrapper function that always includes the flag:
```python
def run_codex_review(iteration_num):
    return Bash(
        command="bash ${CLAUDE_PLUGIN_ROOT}/skills/codex-reviewer/scripts/execute_review.sh",
        description=f"Run Codex review iteration {iteration_num}",
        run_in_background=True,  # Always included
        timeout=600000
    )
```

## JSON Parsing Issues

### Issue: Cannot parse JSON from codex output

**Common causes:**
1. Output contains both reasoning text and JSON
2. JSON is wrapped in markdown code blocks
3. Codex returned narrative feedback instead of JSON
4. Output was truncated

**Solution:**

1. **Extract JSON block from end of output:**
   ```python
   # Look for last occurrence of { ... }
   import re
   json_match = re.search(r'\{[^{}]*"status"[^{}]*\}', output, re.DOTALL)
   if json_match:
       json_str = json_match.group(0)
   ```

2. **Remove markdown code fences:**
   ```python
   # Remove ```json and ``` markers
   json_str = output.strip()
   json_str = re.sub(r'^```json\s*', '', json_str)
   json_str = re.sub(r'\s*```$', '', json_str)
   ```

3. **Handle narrative output:**
   - See "Issue: Codex returns narrative feedback" above

## Performance Issues

### Issue: Review is slow (>5 minutes)

**Factors affecting speed:**
- Size of changes (lines modified)
- Number of files changed
- Complexity of code
- Current API load

**Optimization strategies:**
1. Review smaller chunks (< 300 lines per review)
2. Focus on high-risk files first
3. Use background execution and continue with other work
4. Consider breaking large refactorings into multiple commits

### Issue: Running out of memory

**Solution:**
- Review is limited to analyzing code, not executing it
- If memory issues occur, it's likely a system issue
- Check available RAM: `free -h` (Linux) or `vm_stat` (macOS)
- Close other applications during review
- Consider reviewing in smaller chunks

## Integration Issues

### Issue: Task integration not working

**Solution:**
- Task integration is optional
- Skill works without task system
- If task-related errors occur, they should not block review workflow
- File issue for task integration bugs separately

### Issue: Changelog not saving

**Solution:**
- Changelog system is optional
- Failures don't block the review workflow
- Check write permissions to ~/.claude/projects/
- Verify git repository is properly initialized
- File issue if changelog is important to your workflow
