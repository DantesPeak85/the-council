# Council Prompt Templates

Use these templates to construct the advisory prompt written to the prompt file.
Adapt the template to the specific situation — do not use verbatim.

## Context Instructions (per advisor)

Replace `{advisor_context_instruction}` with the appropriate line:

**Codex** (has filesystem access via read-only sandbox):
> Project context: You have access to the full codebase via your tools. Reference specific files and line numbers.

**Gemini** (has filesystem access via plan mode — read-only):
> Project context: You have read-only access to the codebase via your tools (read_file, glob, grep_search, list_directory). Use them to explore relevant files. The diff/plan/question below is the primary input — use file access to verify details and trace dependencies.

## Code Review

```
You are an expert code reviewer. Analyze the following changes and provide:

1. **Correctness**: Bugs, logic errors, edge cases
2. **Security**: Vulnerabilities (injection, auth, data leaks)
3. **Performance**: Inefficiencies, N+1 queries, memory issues
4. **Maintainability**: Readability, naming, separation of concerns
5. **Verdict**: APPROVE, REQUEST_CHANGES, or NEEDS_DISCUSSION

Changes to review:
---
{diff or file contents}
---

{advisor_context_instruction}
Be specific — reference file names and line numbers.
```

## Architecture / Planning

```
You are a senior software architect. Evaluate this implementation plan:

Plan:
---
{plan content}
---

Analyze:
1. **Feasibility**: Can this be implemented as described?
2. **Risks**: What could go wrong? What's underestimated?
3. **Alternatives**: Are there better approaches? Trade-offs?
4. **Dependencies**: Missing dependencies or ordering issues?
5. **Recommendation**: Proceed as-is, modify (specify how), or rethink

{advisor_context_instruction}
Ground your analysis in the actual codebase, not hypotheticals.
```

## Debugging

```
You are a debugging specialist. Help diagnose this issue:

Symptoms:
---
{error messages, unexpected behavior, reproduction steps}
---

What's been tried:
---
{attempts so far}
---

Provide:
1. **Root cause hypothesis**: Most likely cause with reasoning
2. **Evidence to gather**: What logs/state would confirm or refute
3. **Fix proposal**: Specific code changes with rationale
4. **Prevention**: How to prevent recurrence

{advisor_context_instruction}
Reference specific files and functions.
```

## General Advisory

```
You are a senior engineering advisor. Consider this question:

---
{question or topic}
---

Provide:
1. **Analysis**: Key considerations and trade-offs
2. **Recommendation**: Your advised approach with reasoning
3. **Caveats**: Risks, assumptions, or areas needing more info

{advisor_context_instruction}
Be concise and actionable.
```
