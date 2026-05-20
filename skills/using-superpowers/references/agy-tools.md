# Antigravity (agy) CLI Tool Mapping

Antigravity (`agy`) is the successor to the Gemini CLI. It inherits the same tool surface — the names below are carried over from the previous Gemini CLI mapping and should still apply. Verify against your installed `agy` version if a tool behaves unexpectedly.

Skills use Claude Code tool names. When you encounter these in a skill, use your platform equivalent:

| Skill references | Agy equivalent |
|-----------------|----------------|
| `Read` (file reading) | `read_file` |
| `Write` (file creation) | `write_file` |
| `Edit` (file editing) | `replace` |
| `Bash` (run commands) | `run_shell_command` |
| `Grep` (search file content) | `grep_search` |
| `Glob` (search files by name) | `glob` |
| `TodoWrite` (task tracking) | `write_todos` |
| `Skill` tool (invoke a skill) | `activate_skill` |
| `WebSearch` | `google_web_search` |
| `WebFetch` | `web_fetch` |
| `Task` tool (dispatch subagent) | Agy supports dynamic subagents — see "Subagent support" below |

## Subagent support

Agy supports subagents — Google's I/O 2026 launch announcement called out that Antigravity CLI preserves Gemini CLI's Agent Skills, Hooks, and Subagents (Gemini CLI's "Extensions" were rebranded as "Antigravity plugins" rather than carried over under the same name — consult your installed `agy` help for the exact plugin invocation). The official agy tool name for dispatching subagents is not documented here; consult your installed `agy` version's help for the exact invocation. Skills that rely on subagent dispatch (`subagent-driven-development`, `dispatching-parallel-agents`) should work; verify behavior against your agy version.

## Additional agy tools

These tools are available in agy but have no Claude Code equivalent:

| Tool | Purpose |
|------|---------|
| `list_directory` | List files and subdirectories |
| `save_memory` | Persist facts to `GEMINI.md` across sessions (note: `AGENTS.md` is a separate cross-tool rules file, not the `save_memory` target; verify against your installed `agy` version — newer Gemini CLI lineage releases introduced an experimental memory manager subagent as an alternative) |
| `ask_user` | Request structured input from the user |
| `tracker_create_task` | Rich task management (create, update, list, visualize) |
| `enter_plan_mode` / `exit_plan_mode` | Switch to read-only research mode before making changes |
