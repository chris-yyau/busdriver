---
name: llm-security-audit
description: LLM/AI-specific security audit checklist loaded alongside security-reviewer agent to catch AI-specific attack vectors
targets: security-reviewer agent
type: supplement
source: gstack /cso Phase 7
added: 2026-03-23
---

# LLM & AI Security Audit

> Load alongside `security-reviewer` agent when the codebase contains LLM/AI integrations.

## When to Apply

Trigger this audit when the codebase:
- Calls any LLM API (OpenAI, Anthropic, Google, etc.)
- Accepts user input that flows into LLM prompts
- Uses LLM output to drive actions (tool calls, DB writes, file operations)
- Implements RAG, agent loops, or multi-turn conversations

## Checklist

### 1. Prompt Injection
- [ ] User input NEVER appears in system prompts — use the API's separate `user` message role, not string interpolation into `system`. No amount of sanitization makes user content safe inside system instructions (prompt injection is semantic, not syntactic)
- [ ] System prompts and user messages use separate API fields (not string concatenation)
- [ ] Input that contains prompt-like patterns (e.g., "ignore previous instructions") is flagged or filtered
- [ ] Retrieval-augmented content (RAG chunks) is treated as untrusted input, not system context

### 2. Unsanitized LLM Output
- [ ] LLM output rendered in HTML is escaped (XSS via LLM)
- [ ] LLM output used in SQL queries is parameterized (SQLi via LLM)
- [ ] LLM output used in shell commands is properly escaped (command injection via LLM)
- [ ] LLM-generated URLs are validated before rendering or fetching (SSRF via LLM)
- [ ] Markdown from LLM output is sanitized before rendering (script injection via markdown)

### 3. Tool Calling Without Validation
- [ ] Tool/function call arguments from the LLM are validated against a schema before execution
- [ ] Destructive tool calls (delete, write, execute) require confirmation or have allowlists
- [ ] Tool call results are bounded in size (prevent context stuffing)
- [ ] Recursive or self-referential tool calls are depth-limited

### 4. Code Execution Safety
- [ ] No dynamic code evaluation on LLM-generated strings
- [ ] No shell command execution with LLM output as arguments
- [ ] Code execution sandboxes (if used) have resource limits and network isolation
- [ ] Generated code is reviewed or sandboxed before execution

### 5. Cost and Abuse Attacks
- [ ] Per-user or per-session token/request limits are enforced
- [ ] Unbounded agent loops have iteration caps and cost ceilings
- [ ] Large input payloads are rejected before reaching the LLM API
- [ ] Streaming responses have timeout limits
- [ ] API keys have billing alerts and spend caps configured

### 6. Data Leakage
- [ ] System prompts do not contain secrets, API keys, or PII
- [ ] Conversation context does not persist sensitive data across sessions
- [ ] Fine-tuning data does not contain production secrets or customer PII
- [ ] LLM API calls do not send data to providers who use it for training (check data policies)

## Severity Mapping

| Finding | Severity |
|---------|----------|
| Dynamic code evaluation of LLM output | CRITICAL |
| Prompt injection with tool calling | CRITICAL |
| Unsanitized LLM output in HTML/SQL/shell | HIGH |
| Missing tool call validation | HIGH |
| No cost/abuse limits | MEDIUM |
| Data leakage in prompts | MEDIUM |
