---
name: the-council
description: Multi-model advisory board using OpenAI Codex CLI and Google Gemini CLI to provide second opinions on code reviews, architecture plans, debugging, and general engineering decisions. Invoke when the user requests a "council" review, wants a second opinion from other AI models, asks for multi-model consensus, or says "ask the council". Also invoke proactively when making high-stakes architectural decisions or when a code review checkpoint is reached.
---

# The Council

Convene OpenAI Codex and Google Gemini as an advisory board. Both run in parallel via their CLIs, with full project context, and return independent analyses that Claude synthesizes.

## Prerequisites

- Project has a `CLAUDE.md` file in the working directory
- At least one of the following CLIs installed and authenticated:
  - `codex` CLI (`npm i -g @openai/codex`)
  - `gemini` CLI (`npm i -g @google/gemini-cli`)
- Gemini experimental plan mode enabled in `~/.gemini/settings.json` (if using Gemini):
  ```json
  { "experimental": { "plan": true } }
  ```

## Permission Setup

Before running any council scripts, request all necessary bash permissions upfront at the start of the session. This prevents permission prompts from interrupting the advisory flow mid-execution.

Tell the user:

```
The Council needs to run bash scripts to invoke external advisors. I'll request permission for all of them now so the flow isn't interrupted.
```

Then run all three scripts in sequence to trigger permission grants:
1. `bash <skill_dir>/scripts/council_preflight.sh <working_directory>` — CLI availability check
2. `bash <skill_dir>/scripts/council_sync.sh <working_directory>` — context sync
3. `bash <skill_dir>/scripts/council_invoke.sh` (with `--help` or a no-op) — advisor invocation

Once permissions are granted, proceed with the workflow. The user will not be prompted again for these scripts during the session.

## Workflow

### 0. Preflight Check (First Invocation Only)

On the first council invocation in a session, run the preflight script to detect available advisors:

```bash
bash <skill_dir>/scripts/council_preflight.sh <working_directory>
```

Parse the output (key=value lines) and determine the operating mode:

| Codex Auth | Gemini Auth | Mode |
|------------|-------------|------|
| `true` | `true` | **Full Council** — both advisors in parallel |
| `true` | `false` | **Codex-only** — single advisor mode |
| `false` | `true` | **Gemini-only** — single advisor mode |
| `false` | `false` | **Abort** — show installation instructions below |

**If no advisors are available**, display this help and stop:

```
Neither Codex nor Gemini CLI is available. To use The Council, install at least one:

  Codex:  npm i -g @openai/codex && codex auth
  Gemini: npm i -g @google/gemini-cli && gemini   (authenticates via OAuth on first run)
```

**If one advisor is missing**, note which mode is active and proceed. Example:

```
Council running in Codex-only mode (Gemini CLI not found).
```

The preflight result is cached for 2 hours — subsequent invocations skip this step automatically.

### 1. Sync Project Context

Run the sync script to copy CLAUDE.md content into AGENTS.md (for Codex):

```bash
bash <skill_dir>/scripts/council_sync.sh <working_directory>
```

This creates/overwrites AGENTS.md with an advisory preamble + full CLAUDE.md content. Run this once per session or when CLAUDE.md changes. Gemini does not need a context file — it runs from an isolated sandbox and receives all context via the prompt.

**Important:** After the council session, clean up the generated file:
```bash
rm <working_directory>/AGENTS.md
```

### 2. Compose the Advisory Prompt

Select the appropriate template from [references/prompt-templates.md](references/prompt-templates.md) based on the use case:

| Use Case | Template |
|----------|----------|
| Code review | Code Review |
| Plan/architecture evaluation | Architecture / Planning |
| Bug investigation | Debugging |
| General question | General Advisory |

Write the composed prompt to a temporary file. Include all relevant context inline (diffs, error messages, plan text) — the advisors cannot read Claude's conversation history.

**IMPORTANT — Inline everything:** Gemini runs in an isolated sandbox without access to the project directory. It CANNOT read project files, external paths like `~/.claude/plans/`, or any file outside its sandbox. When composing the prompt:

- **Read all referenced files yourself** and embed their full contents inline in the prompt text
- **Never include file paths** as references for the advisor to read (e.g., "see ~/.claude/plans/my-plan.md")
- **Always paste the actual content** between delimiter markers (`---`) in the prompt
- For large files (>1000 lines), include the most relevant sections with clear markers indicating what was omitted

### 3. Invoke The Council (Progressive)

Invoke each advisor as a **separate background bash task** so results can be presented as they arrive.

#### 3a. Launch Advisors as Background Tasks

For **Full Council** mode, launch two separate background bash commands simultaneously:

```bash
# Launch Codex as background task
bash <skill_dir>/scripts/council_invoke.sh --codex-only <prompt_file> <working_directory>
```

```bash
# Launch Gemini as background task
bash <skill_dir>/scripts/council_invoke.sh --gemini-only <prompt_file> <working_directory>
```

Run both commands using `run_in_background: true` in the Bash tool. Each produces its own temp directory (`.council-tmp/council_codex_YYYYMMDD_HHMMSS/` and `.council-tmp/council_gemini_YYYYMMDD_HHMMSS/` inside the working directory).

For **single-advisor modes** (Codex-only or Gemini-only), launch only the available advisor as a single background task.

#### 3b. Poll and Present Progressive Results

After launching both tasks, poll for completion using non-blocking `TaskOutput` checks (with `block: false`). When the first advisor finishes:

1. **Read its response** from the temp directory path printed in its output
2. **Present the early result** to the user immediately:

```
## Early Result: {Advisor Name} ({model})

{advisor response}

---
*Waiting for {other advisor name} to complete...*
```

3. **Continue polling** the second advisor

When the second advisor finishes, read its response and proceed to Step 3.5 (question detection) and then Step 4 (synthesis).

#### 3c. Handling Failures

- If one advisor fails while the other succeeds, present the successful response and note the failure
- If both fail, report the errors and suggest checking CLI authentication

#### 3d. Fallback

If progressive invocation is not possible (e.g., background tasks not supported), fall back to the single blocking call:

```bash
bash <skill_dir>/scripts/council_invoke.sh <prompt_file> <working_directory>
```

**Environment overrides:**
- `CODEX_MODEL` — default: auto (from `~/.codex/config.toml`)
- `GEMINI_MODEL` — default: `auto` (CLI selects best available model)
- `COUNCIL_TIMEOUT` — default: `300` (seconds)

### 3.5. Question Detection & Auto-Retry

After reading each advisor's response (during progressive polling or after completion), check whether the response contains **questions directed at you** rather than analysis. Advisors sometimes ask clarifying questions instead of providing their assessment.

#### Detecting Questions

Scan the advisor response for patterns indicating it needs clarification rather than providing analysis:
- Direct questions ("What is...", "Can you clarify...", "Which approach...", "Could you provide...")
- Requests for information ("I need to know...", "Please share...", "It would help to understand...")
- Conditional analysis ("If X then Y, but if Z then W — which is the case?")

**Not all question marks are triggers.** Rhetorical questions, questions posed as part of analysis ("Have you considered...?"), and section headers ("What could go wrong?") are normal advisory output. Only trigger retry when the advisor is **unable to provide analysis without the answer**.

**Heuristic:** If the response is short (under ~200 words) AND primarily consists of questions rather than analysis, treat it as a question response. If the response contains substantial analysis alongside questions, treat it as a normal response.

#### Auto-Answer and Retry Flow

When a question is detected in an advisor's response:

1. **Extract the question(s)** from the response
2. **Attempt to answer from project context** — search the codebase, CLAUDE.md, conversation history, and relevant files
3. **Assess confidence:**
   - **Confident** (answer clearly supported by project context): proceed to auto-retry
   - **Unsure** (requires judgment or information not available): ask the user:
     ```
     {Advisor Name} asked a clarifying question instead of providing analysis:

     > {advisor's question}

     I'm not confident I can answer this from project context. What's the answer?
     ```
     Wait for the user's response before proceeding.

4. **Compose retry context** — write the Q&A to a temporary context file:
   ```
   Question from {Advisor Name}: {question}
   Answer: {answer from project context or user}

   Please provide your analysis based on this clarification. Do not ask further questions about this topic.
   ```

5. **Re-invoke the same advisor** with the context file:
   ```bash
   bash <skill_dir>/scripts/council_invoke.sh --{advisor}-only --context-file <context_file> <prompt_file> <working_directory>
   ```

6. **Read the new response** and check again for questions (loop back to detection)

#### Retry Guards

- **Question tracking:** Keep a list of questions already asked by each advisor. If the same question (or substantially similar) appears again after a retry, stop retrying and present the best response received so far with a note about the unresolved question.
- **Hard cap:** Maximum **3 retries per advisor**. After 3 retries, present whatever response was received with a note:
  ```
  Note: {Advisor Name} requested clarification {N} times. Presenting the best response received.
  ```
- **Per-advisor tracking:** Retry counts and question lists are tracked independently for Codex and Gemini. One advisor hitting its cap does not affect the other.

#### Retry During Progressive Invocation

When using progressive invocation (Step 3), retries happen per-advisor:
- If one advisor finishes with a question, begin the retry flow for that advisor while the other is still running
- If the other advisor finishes with analysis while the first is retrying, present its result immediately
- Synthesis (Step 4) waits until all retries are complete and both advisors have final responses

### 4. Analyze and Present

If you presented an early result during progressive polling (Step 3b), the user has already seen one advisor's response. Do not re-print it. Present only the new response and the synthesis.

#### Full Council Mode (both advisors responded)

**Default mode — Synthesis:** Read both responses, identify areas of agreement and disagreement, then present:

```
## Council Synthesis

**Consensus:** [Points both advisors agree on]

**Divergence:** [Points where they disagree, with each position]

**Claude's Recommendation:** [Your assessment integrating all three perspectives — yours plus both advisors']
```

**Side-by-side mode** (when user requests "show me both" or "side by side"):

```
## Codex ({codex_model})
[Full Codex response]

## Gemini
[Full Gemini response]

## Claude's Take
[Your own assessment]
```

#### Single-Advisor Mode (one advisor responded)

Present the single advisor's response with your own assessment:

```
## Advisory Opinion ({Advisor Name} / {model})
[Full response from the available advisor]

## Claude's Assessment
[Your own perspective, noting this was a single-advisor review]
```

### 5. Cleanup

**CRITICAL: Do NOT clean up until ALL of the following conditions are met:**

1. All advisor responses (including retries) have been **fully read into your context** (i.e., you have used the Read tool on every response file and have the content in your conversation)
2. Synthesis (Step 4) is **complete and has been presented to the user**
3. If running with `run_in_background: true`, ensure the background task has finished AND you have read all output files before cleanup

**Why this matters:** Response files live inside `.council-tmp/`. If you delete that directory before reading the files, the responses are lost permanently.

Once all conditions above are satisfied, remove temporary files:

- The prompt file
- The `.council-tmp/` directory from the working directory (`rm -rf <working_directory>/.council-tmp/`) — this removes all response files, error logs, context files, and the preflight cache at once
- AGENTS.md from the working directory

## Permissions and Safety

Both advisors run in **read-only mode** — they can explore the codebase but cannot modify it:

- **Codex**: `--sandbox read-only` — filesystem writes are blocked by the sandbox
- **Gemini**: `--approval-mode plan` — strict read-only mode; only read tools (read_file, glob, search) are allowed; write tools are blocked

This ensures advisors never modify project files. If either CLI updates its permission model, verify read-only enforcement before updating the scripts.

## Model and Effort Configuration

Both advisors run at maximum capability:

- **Codex**: Model auto-selected from `~/.codex/config.toml` (override with `CODEX_MODEL` env var), reasoning effort `xhigh` (set via `~/.codex/config.toml` key `model_reasoning_effort = "xhigh"`)
- **Gemini**: Model auto-selected by CLI (override with `GEMINI_MODEL` env var), thinking level `HIGH` (set via `~/.gemini/settings.json` in `modelConfigs`)

If the user's config doesn't have these settings, advise them to add:

Codex (`~/.codex/config.toml`):
```toml
model_reasoning_effort = "xhigh"
```

Gemini (`~/.gemini/settings.json`):
```json
{
  "modelConfigs": {
    "customAliases": {
      "council": {
        "modelConfig": {
          "model": "gemini-2.5-pro",
          "generateContentConfig": {
            "thinkingConfig": { "thinkingLevel": "HIGH" }
          }
        }
      }
    }
  }
}
```

## Error Handling

- If one advisor fails, present the other's response and note the failure
- If both fail, report the errors from the log files and suggest checking CLI authentication
- Timeout defaults to 5 minutes — suggest increasing `COUNCIL_TIMEOUT` for large reviews

## When to Convene The Council

- User explicitly asks for it ("ask the council", "get a second opinion", "council review")
- High-stakes architectural decisions affecting multiple systems
- Debugging sessions stuck after multiple failed attempts
- Before finalizing major implementation plans
- Code review of security-sensitive changes
