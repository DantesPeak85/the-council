---
name: the-council
description: Multi-model advisory board using OpenAI Codex CLI and Google Antigravity CLI (agy) to provide second opinions on code reviews, architecture plans, debugging, and general engineering decisions. Invoke when the user requests a "council" review, wants a second opinion from other AI models, asks for multi-model consensus, or says "ask the council". Also invoke proactively when making high-stakes architectural decisions or when a code review checkpoint is reached.
---

# The Council

Convene OpenAI Codex and Google Gemini as an advisory board. Both run in parallel via their CLIs, with full project context, and return independent analyses that Claude synthesizes.

## Prerequisites

- Project has a `CLAUDE.md` file in the working directory
- At least one of the following CLIs installed and authenticated:
  - `codex` CLI (`npm i -g @openai/codex`)
  - `agy` CLI (`antigravity` CLI)

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

**Gemini backend resolution** (v1.4.0): the invoke script picks the Gemini
backend automatically (`COUNCIL_GEMINI_BACKEND=auto`):

| `GEMINI_CLI_AVAILABLE` | `GEMINI_API_KEY_SET` | Backend |
|---|---|---|
| true | true | `gemini` (gemini-cli, single-shot JSON — preferred) |
| true | false | `agy` (pty-wrapped, sandboxed, single-shot) |
| false | any | `agy` (pty-wrapped, sandboxed, single-shot) |

Note: gemini-cli's free oauth-personal auth stopped serving 2026-06-18 — the
gemini backend requires a paid `GEMINI_API_KEY` (AI Studio) exported in the
environment.

**Preflight-vs-invoke caveat:** preflight counts `~/.gemini/oauth_creds.json` as
Gemini credentials, but the invoke script's `auto` mode only selects gemini-cli
when `GEMINI_API_KEY` is set — a machine with only stale oauth creds and no
`agy` installed will preflight green but fail loud at invoke (the resolved
backend `agy` is not in PATH).

**If no advisors are available**, display this help and stop:

```
Neither Codex nor Gemini CLI is available. To use The Council, install at least one:

  Codex:  npm i -g @openai/codex && codex auth
  Gemini: Install agy CLI and verify it is logged in via ~/.gemini/oauth_creds.json (runs automatically on first command)
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

This creates/overwrites AGENTS.md with an advisory preamble + full CLAUDE.md content. Run this once per session or when CLAUDE.md changes. Gemini does not need a context file — it runs from the project directory with read access and receives task-specific context (diffs, plans, questions) via the prompt.

**Important:** After the council session, restore the user's AGENTS.md:
```bash
bash <skill_dir>/scripts/council_sync.sh --restore <working_directory>
```
Never `rm` AGENTS.md directly — repos increasingly own a real AGENTS.md and
the sync script backs it up / restores it.

### 2. Compose the Advisory Prompt

Select the appropriate template from [references/prompt-templates.md](references/prompt-templates.md) based on the use case:

| Use Case | Template |
|----------|----------|
| Code review | Code Review |
| Plan/architecture evaluation | Architecture / Planning |
| Bug investigation | Debugging |
| General question | General Advisory |

Write the composed prompt to a temporary file. Include all relevant context inline (diffs, error messages, plan text) — the advisors cannot read Claude's conversation history.

**Context in prompts:** Both advisors have read-only filesystem access to the working directory (Codex via its native `--sandbox read-only`; Gemini via `agy` wrapped in `sandbox-exec` on macOS — see Permissions and Safety). However, task-specific context (diffs, error messages, plan text, conversation history) must still be inlined because advisors cannot access Claude's conversation or external paths like `~/.claude/plans/`.

- **Always inline:** diffs, error output, plan text, conversation excerpts, and any content from outside the project directory
- **Can reference by path:** codebase files that advisors can read directly (e.g., "see `src/config.ts` for the current implementation")
- For code review: the diff must be inlined (advisors don't have access to git staging), but surrounding context files can be referenced by path
- For large files referenced in the prompt: include the most relevant sections inline, note the file path for full context

#### Mandatory prompt blocks

1. **Defensive framing** (all reviews): open with "This is a defensive code
   review / secure-coding audit of our own application code." Never phrase
   security asks as "find vulnerabilities to exploit" — both advisors'
   safety classifiers throttle offensive framing (Gemini refuses; Codex may
   route to a lesser model).

2. **No-explore directive** (plan reviews and any prompt referencing many
   files): include near the top —
   > Respond fast. Do NOT explore the repository — everything you need is
   > inline. Reason from the inline content only; flag file-dependent
   > concerns as assumptions for the executor to verify.

   Without this, Codex has spidered repos for 30+ minutes (2026-06-09
   incident). Diff reviews on small file sets may omit it so Codex can read
   adjacent code — that adjacency is why Codex catches migration-runtime
   semantics others miss.

3. **Doc-provenance preamble** (any prompt citing internal, owner-revisable
   docs — voice charters, in-house architecture docs): state that the doc is
   the owner's revisable direction, not external scripture; the advisor's
   role is risk-surfacer, not charter-enforcer. List separately which
   constraints ARE non-negotiable (HIPAA/FDA/OWASP, locked domain rules).
   Without this, Council issues strict text-literal REVISE verdicts the
   owner then overrules (2026-05-13 charter-as-decree incident).

4. **Nitpick suppression** (gpt-5.6-sol): Sol over-flags (CodeRabbit
   benchmark: 31.6% actionable precision). Instruct: "Rank findings by
   severity. Suppress low-confidence nitpicks; report only findings you
   would defend in review."

### 3. Invoke The Council (Progressive)

Invoke each advisor as a **separate detached process** so results can be presented as they arrive.

#### 3a. Launch Advisors (detached, NOT harness-background)

Do NOT launch council scripts with the Bash tool's `run_in_background` — codex
hangs at ~0 CPU in that context on large prompts (verified 2026-07-11).
Launch each advisor DETACHED from a normal foreground Bash call, which
returns immediately:

```bash
nohup bash <skill_dir>/scripts/council_invoke.sh --codex-only <prompt_file> <working_directory> \
  > /tmp/council_codex_launch.log 2>&1 & disown
```

```bash
nohup bash <skill_dir>/scripts/council_invoke.sh --gemini-only <prompt_file> <working_directory> \
  > /tmp/council_gemini_launch.log 2>&1 & disown
```

Each produces its own temp directory (`.council-tmp/council_codex_YYYYMMDD_HHMMSS/`
and `.council-tmp/council_gemini_YYYYMMDD_HHMMSS/` inside the working directory).

Then poll for the response files (the launch log's last lines name them) —
e.g. with a Monitor until-loop on file existence, or periodic checks. A
liveness rule: if the advisor process shows under ~2s of CPU time after
120s, treat it as hung, kill it, and relaunch once.

For **single-advisor modes** (Codex-only or Gemini-only), launch only the available advisor as a single detached process.

#### 3b. Poll and Present Progressive Results

After launching both advisors, poll for their response files (per §3a) rather than blocking on either. When the first advisor finishes:

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

An advisor has failed only when the invoke script says so — it prints
`(failed: <reason>)` next to the response path and exits 1. When that happens:

1. **Read the error log first** — always read the `*_error.log` file from the temp directory before reporting failure:
   - Codex: `<working_directory>/.council-tmp/council_codex_*/codex_error.log`
   - Gemini: `<working_directory>/.council-tmp/council_gemini_*/gemini_error.log`
2. **Read the response file** — even failed runs may have partial output worth presenting
3. **Report the script's reason string**, not a guess. The validation engine's failure reasons (v1.4.0):
   - `empty response` — advisor ran but produced no text output
   - `placeholder` — the script wrote a `[COUNCIL-ADVISOR-FAILURE]` placeholder (launch/backend error; the placeholder's first line names the specific cause)
   - `refusal` — refusal phrasing at the start of the response with no verdict line
   - `non-engagement` — short verdict-less response to a large prompt
   - `timed out (COUNCIL_TIMEOUT)` — advisor exceeded the per-advisor timeout
   - `advisor exited N without a verdict-bearing response` — nonzero exit AND no verdict line in the response head

   stderr noise (RESOURCE_EXHAUSTED, rate limit, 429...) alongside a
   substantive response is NOT a failure — it's an advisory warning recorded
   in `*_warnings.log`; see Error Handling. Script-level launch errors
   (`command not found`, missing resolved-backend binary) surface in the
   launch log before any response file exists.
4. **If one advisor succeeds**, present its response and note the other's failure with the actual reason
5. **If both fail**, present both error logs and suggest checking CLI authentication (`codex auth` / `gemini auth`)

#### 3d. Fallback

If detached launching is unavailable in your environment, fall back to the single blocking call:

```bash
bash <skill_dir>/scripts/council_invoke.sh <prompt_file> <working_directory>
```

**Environment overrides:**
- `CODEX_MODEL` — default: from `~/.codex/config.toml` (standard: gpt-5.6-sol)
- `COUNCIL_CODEX_EFFORT` — default: `xhigh`; set `config` to defer to config.toml
- `COUNCIL_TIMEOUT` — default: `600` (seconds per advisor; raise to 900 for very large xhigh reviews)
- `COUNCIL_GEMINI_BACKEND` — default: `auto` (`gemini` | `agy`)
- `COUNCIL_GEMINI_MODEL` — optional model pin for either backend
- `COUNCIL_SNAPSHOT_EXCLUDES` — comma-separated pathspecs excluded from the safety-net snapshot
- `AGY_PRINT_TIMEOUT` — default: `8m` (must stay below COUNCIL_TIMEOUT)

### During the Advisory Window (MANDATORY)

- **No writes anywhere under the working tree while any advisor runs.** Not
  scratch ledgers, not `.generated` regens, not fixes for findings the
  first-returning advisor reported. The safety net hashes everything; a
  one-line append fires exit 2, and applying fixes mid-window makes the
  still-running advisor review a stale tree (2026-06-18 + 2026-07-04
  incidents). Do bookkeeping in the session scratchpad OUTSIDE the repo.
- **Run Council before CodeRabbit, never concurrently.** Concurrent
  CodeRabbit cache writes trip the safety net, and 3 concurrent heavy
  reviews starved Codex to an empty-output death (2026-06-16). Cap
  concurrent heavy review processes at 2 (the two Council advisors).

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

**Claude's Recommendation:** [Your assessment integrating all three perspectives — yours plus both advisors'. Note: Codex remains the primary source of truth and the main shipping gate; Gemini is advisory.]
```

**Side-by-side mode** (when user requests "show me both" or "side by side"):

```
## Codex ({codex_model})
[Full Codex response]

## Gemini ({backend}/{model})
[Full Gemini response]

## Claude's Take
[Your own assessment]
```

#### Single-Advisor Mode (one advisor responded)

Present the single advisor's response with your own assessment.

> [!IMPORTANT]
> If Gemini (agy) dropped out mid-session or failed validation (returning an error log/response), you must explicitly surface this failure as a "degraded one-advisor Council (Codex only)" and never silently ignore it.
>
> If Gemini is the only advisor that responded (e.g. Gemini-only mode or Codex failed), remember that Gemini must never act as a sole shipping gate. Its opinions are strictly advisory, and Codex remains the primary codebase source of truth.
>
> When Gemini failed, name the failure class from the script's reason string
> (empty / refusal / non-engagement / timeout) — "degraded one-advisor
> Council (Codex only; Gemini: refusal)" — so patterns stay visible across
> sessions.

```
## Advisory Opinion ({Advisor Name} / {model})
[Full response from the available advisor]

## Claude's Assessment
[Your own perspective, noting this was a single-advisor review]
```

#### Verdict authority gradient (MANDATORY)

- **APPROVE / APPROVE-WITH-CHANGES:** absorb mechanical refinements and
  proceed.
- **REVISE / RESTRUCTURE:** this is a scope/shape decision the human owns.
  If the human previously approved the scope, HALT — present the finding
  verbatim, a plain-English why, two paths, and one recommendation. Never
  silently fold a scope-reducing REVISE over a prior human approval
  (2026-05-26 incident).
- **Repeated residuals:** when a cheap patch leaks a new residual every
  round and all residuals trace to one structural fact, stop patching and
  take the robust option the reviewer already named (2026-06-24 lesson).

#### Verifying advisor claims

Gemini findings that name specific code patterns MUST be verified with one
grep/build before being surfaced as actionable — Gemini has fabricated
multi-file "compilation blockers" with fake code blocks (2026-04-23).
Sweeping identical cross-file claims are a pattern-match red flag; real bugs
concentrate in 1–2 files. Trust grep over the advisor's quoted snippet.
Codex remains the primary source of truth and the mandatory shipping gate:
wait for its response even when every other layer is green.

### 5. Cleanup

**CRITICAL: Do NOT clean up until ALL of the following conditions are met:**

1. All advisor responses (including retries) have been **fully read into your context** (i.e., you have used the Read tool on every response file and have the content in your conversation)
2. Synthesis (Step 4) is **complete and has been presented to the user**
3. Advisors launched detached (§3a) have each exited AND you have read all output files before cleanup

**Why this matters:** Response files live inside `.council-tmp/`. If you delete that directory before reading the files, the responses are lost permanently.

Once all conditions above are satisfied, clean up in this order (ORDER IS
LOAD-BEARING — the AGENTS.md backup lives inside `.council-tmp/`, so restore
MUST precede deletion):

1. `bash <skill_dir>/scripts/council_sync.sh --restore <working_directory>`
   (restores or removes AGENTS.md from its backup inside .council-tmp/)
2. Remove the prompt file.
3. `rm -rf <working_directory>/.council-tmp/` — LAST, after the restore and
   after every response file has been read into context.

## Permissions and Safety

Both advisors run with **OS-enforced read-only sandboxes** on macOS. Neither can write to your project directory; tool calls that try to write fail at the OS layer.

- **Codex**: `--sandbox read-only` — Codex's built-in OS-level filesystem deny-write.
- **Gemini (`agy`)** on **macOS**: wrapped in `sandbox-exec` using a deny-write profile at `scripts/council_sandbox.sb`. The profile allows reads everywhere; allows writes only to `~/.gemini/`, the per-invocation `.council-tmp/<...>/` dir, system temp (`/tmp`, `/private/tmp`, `/private/var/folders`), and the agy-specific subdirs under `~/Library/Caches/` (`agy/`, `Google/`). All other writes (including the project tree) are blocked at the OS layer.
- **Gemini (`agy`)** on **non-macOS**: `sandbox-exec` is unavailable. The script REFUSES to run agy unless the caller passes `--allow-unsandboxed-gemini`, in which case agy runs unsandboxed with a loud warning — the diff safety net below is the only protection in that mode. Or use `--codex-only` to skip Gemini entirely.

### Diff safety net (defense in depth — runs on all platforms)

Before launching either advisor, the script snapshots `$WORK_DIR` (git: HEAD + status `--ignored=traditional` + sha256 of tracked + untracked + gitignored files; non-git: `find` + sha256). After both advisors return, the snapshot is repeated and diffed. The snapshot excludes `.council-tmp/` (the script's own response files) and `.antigravitycli/` (agy's per-workspace session-metadata directory, created via Apple APIs that bypass `sandbox-exec` and known not to be a security concern).

**Any unauthorized change to the working tree causes the invocation to fail closed with exit code 2 and a `[COUNCIL_SAFETY_NET]` error banner pointing at the diff.** This catches any escape from the sandbox — including writes to gitignored files like `.env`, `dist/`, or `node_modules/`, which the previous `--exclude-standard` snapshot logic would have missed (Council R1 fix, 2026-05-25).

### Historical note (1.2.x ghost-write incident)

Versions 1.2.0 and 1.2.1 documented agy's read-only property as "stdin-EOF + `--dangerously-skip-permissions` together prevent tool approvals." That reasoning was **wrong**: `agy --help` says `--dangerously-skip-permissions` is `"Auto-approve all tool permission requests without prompting"` — it grants permission, not withholds it. A 2026-05-24 incident saw agy ghost-write 8 files inside `$WORK_DIR` during what was supposed to be an advisory Council R1. **Upgrade to 1.3.0 or later** to get the OS-level sandbox enforcement above.

### When you see `[COUNCIL_SAFETY_NET]` fire

Either (a) an advisor sandbox escape (rare — investigate as a real security issue), or (b) genuine concurrent work in `$WORK_DIR` by you or another process during the invocation window. Inspect the diff file the banner points at; you'll get response files and a clean before/after snapshot regardless. Do not trust the advisor recommendations until you've audited the diff.

## Model and Effort Configuration

- **Codex**: model from `~/.codex/config.toml` (standard: `gpt-5.6-sol`,
  1.05M context), overridable via `CODEX_MODEL`. Reasoning effort is set
  EXPLICITLY by the script: `-c model_reasoning_effort=xhigh` by default
  (`COUNCIL_CODEX_EFFORT` to change). Sol note: highest review recall of any
  current model, but over-flags nitpicks — the prompt templates include a
  suppression instruction.
- **Gemini**: backend-dependent. gemini-cli: model via `COUNCIL_GEMINI_MODEL`
  → `-m`. agy: `COUNCIL_GEMINI_MODEL` → `--model` (run `agy models` for ids;
  a Pro tier gives deeper reviews than the default Flash).
- Both advisors review INLINED content; only Codex additionally has
  read-only filesystem access to the working directory.

## Error Handling

See **Section 3c** above for detailed failure diagnostics. Never guess error
messages — always read the actual error log files before reporting failures.
Key rules:

- An advisor has FAILED only when the script says so: reasons are `empty
  response`, `placeholder`, `refusal`, `non-engagement`, `timed out`, or
  `advisor exited N without a verdict-bearing response`.
- Loud partial success: a nonzero advisor exit WITH a verdict line in the
  response head is RETAINED, not failed — the script writes a
  `*_warnings.log` advisory and logs it loudly. Verify the response is
  complete before relying on it.
- stderr noise (RESOURCE_EXHAUSTED, rate limit, 429...) with a substantive
  response file is an ADVISORY WARNING (`*_warnings.log`), not a failure —
  present the response normally and mention the warning.
- On `[COUNCIL_SAFETY_NET]` exit 2: read `worktree_diff.txt` FIRST. Known
  benign churn (`.remember/`, `.tmp.driveupload/`) is already excluded; any
  remaining diff is either a real advisor escape (investigate as a security
  issue) or your own concurrent edit (see During the Advisory Window).
  Advisor responses remain readable either way.

## Learning from the Council (Generalize Knowledge)

After presenting the council synthesis, reflect on what the advisors revealed — gaps, blind spots, better approaches, or project-specific conventions that Claude missed.

Generalize these learnings into `CLAUDE.md` and `AGENTS.md` so future agents start with those lessons already loaded. Write down any information that would be useful for a future agent working in this repository, including:

- What the advisors caught that Claude missed
- Why it was missed (root cause, not just symptom)
- The corrected approach or pattern to use next time
- Any project-specific conventions the council surfaced

**Template for a council learning entry:**
```
## Council Learning — [date]
- **Insight:** [what the council revealed]
- **Caught by:** Codex / Gemini / both
- **Root cause:** [why this was missed]
- **Lesson:** [concrete rule or pattern for future sessions]
```

This closes the feedback loop: the council exposes blind spots → learnings become permanent project memory → future sessions start smarter.

## When to Convene The Council

- User explicitly asks for it ("ask the council", "get a second opinion", "council review")
- High-stakes architectural decisions affecting multiple systems
- Debugging sessions stuck after multiple failed attempts
- Before finalizing major implementation plans
- Code review of security-sensitive changes
