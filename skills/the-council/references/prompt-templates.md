# Council Prompt Templates

Use these templates to construct the advisory prompt written to the prompt file.
Adapt the template to the specific situation — do not use verbatim.

## Standard preamble blocks

Every advisory prompt is a template body (below) plus one or more of these
standard blocks. They mirror SKILL.md §2 "Mandatory prompt blocks" — prepend
the blocks a template calls for, then the template body. Each block's
copy-pasteable text is fenced; the surrounding prose says when and why.

### 1. Defensive framing (all reviews)

Open every review with this line:

```text
This is a defensive code review / secure-coding audit of our own application code.
```

Never phrase security asks as "find vulnerabilities to exploit" — both
advisors' safety classifiers throttle offensive framing (Gemini refuses;
Codex may route to a lesser model).

### 2. No-explore directive (plan reviews and any prompt referencing many files)

Include near the top:

```text
Respond fast. Do NOT explore the repository — everything you need is
inline. Reason from the inline content only; flag file-dependent
concerns as assumptions for the executor to verify.
```

Without this, Codex has spidered repos for 30+ minutes (2026-06-09 incident).
Diff reviews on small file sets may omit it so Codex can read adjacent code —
that adjacency is why Codex catches migration-runtime semantics others miss.

### 3. Doc-provenance preamble (any prompt citing internal, owner-revisable docs)

For any prompt citing internal, owner-revisable docs — voice charters,
in-house architecture docs — state that the doc is the owner's revisable
direction, not external scripture; the advisor's role is risk-surfacer, not
charter-enforcer. List separately which constraints ARE non-negotiable
(HIPAA/FDA/OWASP, locked domain rules). A copy-pasteable form:

```text
The doc cited below is the owner's revisable direction, not external
scripture — your role is risk-surfacer, not charter-enforcer. NON-NEGOTIABLE
constraints (flag any violation hard): [HIPAA/FDA/OWASP, locked domain rules].
Everything else in the doc is open to revision.
```

Without this, Council issues strict text-literal REVISE verdicts the owner
then overrules (2026-05-13 charter-as-decree incident).

### 4. Nitpick suppression (every Codex model — measured on gpt-5.6-sol, kept on for gpt-6-astra)

Sol over-flagged (CodeRabbit benchmark: 31.6% actionable precision); Astra is unmeasured, so keep it on. Instruct:

```text
Rank findings by severity. Suppress low-confidence nitpicks; report only findings you would defend in review.
```

## Context Instructions (per advisor)

Replace `{advisor_context_instruction}` with the appropriate line:

**Codex** (has filesystem access via read-only sandbox):
> Project context: You have access to the full codebase via your tools. Reference specific files and line numbers.

**Gemini** (reviews inlined content only — no repo access):
> Project context: Everything you need is inlined in this request. You have NO access to the project repository — do not attempt to read, list, or search files. Reason from the provided content only. The diff/plan/question below is your complete input.
> 
> **Important Rules:**
> 1. **No Hallucinated Blockers**: Only raise blockers, errors, or issues grounded in the content provided in this request. Do not assert claims about files, structure, or code you cannot see — state file-dependent concerns as assumptions for the executor to verify, not as confirmed findings.
> 2. **Documentation Revisions**: Documentation files (e.g., inside Docs/, brand/, or spec/ directories) are fully revisable. Do not treat them as inviolable charters or block changes to them; Tom revisions these documents regularly as part of development.

## Code Review

*Prepend: defensive framing (always); no-explore for large/multi-file diffs; doc-provenance if it cites owner-revisable docs; nitpick suppression (always).*

```
Begin your response with a `VERDICT:` line (e.g. `VERDICT: APPROVE — one-sentence reason`). Valid verdicts: APPROVE, APPROVE-WITH-CHANGES, REVISE, RESTRUCTURE.

You are an expert code reviewer. Analyze the following changes and provide:

1. **Correctness**: Bugs, logic errors, edge cases
2. **Security**: Vulnerabilities (injection, auth, data leaks)
3. **Performance**: Inefficiencies, N+1 queries, memory issues
4. **Maintainability**: Readability, naming, separation of concerns

Then, after the analysis, close by restating your verdict with a one-line reason.

Changes to review:
---
{diff or file contents}
---

{advisor_context_instruction}
Be specific — reference file names and line numbers.
```

## Architecture / Planning

*Prepend: defensive framing (always); no-explore directive (plan reviews are fully inline); doc-provenance if the plan cites owner-revisable docs; nitpick suppression (always).*

```
Begin your response with a `VERDICT:` line (e.g. `VERDICT: APPROVE — one-sentence reason`). Valid verdicts: APPROVE, APPROVE-WITH-CHANGES, REVISE, RESTRUCTURE.

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
5. **Recommendation**: Expand on your verdict — if not APPROVE, specify exactly what to change.

{advisor_context_instruction}
Codex: ground your analysis in the actual codebase; Gemini: ground it in the inlined content provided.
```

## Debugging

*Prepend: defensive framing (always); no-explore if the prompt references many files; doc-provenance if it cites owner-revisable docs; nitpick suppression (always).*

```
Begin your response with a `VERDICT:` line (e.g. `VERDICT: APPROVE — one-sentence reason`). Valid verdicts: APPROVE, APPROVE-WITH-CHANGES, REVISE, RESTRUCTURE.

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

*Prepend: defensive framing (always); no-explore if referencing many files; doc-provenance if it cites owner-revisable docs; nitpick suppression (always).*

```
Begin your response with a `VERDICT:` line (e.g. `VERDICT: APPROVE — one-sentence reason`). Valid verdicts: APPROVE, APPROVE-WITH-CHANGES, REVISE, RESTRUCTURE.

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
