# Reviewer selection — which advisors, which models, how many rounds

Derived from a full three-round review of a launch-gating plan (Lisah, 2026-08-04), where every
advisor was run on the same prompt and their findings compared. The rules below are what that
session established empirically. Each carries its evidence so it does not get eroded by a future
session that finds it inconvenient.

---

## 1. Pick the panel by CONSEQUENCE, not by how big the diff is

| Tier | What it covers | Panel |
|---|---|---|
| **Routine** | ordinary diffs, bug fixes, refactors, single-file changes | **Fable (low)** + **Codex** |
| **Hard-to-reverse** | architecture, migrations, auth/RLS/PHI, wire contracts, any written plan | **Fable (low)** + **Codex** + **Gemini** |
| **Milestone** | launch-gating work, initiative plans, anything an executor will build from | the above **+ Qwen**, and **Fable (high)** at merge |

Cost anchor: a full milestone panel ran ≈ **$0.57 in OpenRouter spend and ~40 minutes wall clock**.
Against the class of defect it catches, that is not a decision that needs analysis.

### Why four, and not two

The panel earns its keep because the reviewers fail *differently*, not because more opinions are
better. Overlap in the source session was low — each found material the others missed:

| Reviewer | The lens it actually brings | Representative unique catch |
|---|---|---|
| **Codex (`gpt-6-astra`)** | code semantics, impossibility, threat model | "atomic compare-and-serve cannot exist — no transaction spans a DB check and bytes reaching a client"; time-derived state absent from a cache key; a `run_id` header being spoofable |
| **Gemini** | product + operational consequence | a 1-minute cron poll meaning 70 s of generic copy after every user action; a DB transaction held across a 22 s model call exhausting the pool; the arithmetic showing a precompute wasted 70% |
| **Qwen** | structure, completeness, missing gates | no go/no-go gate on the metric the whole design depended on; an entire workstream silently dropped between plan versions |
| **Fable** | re-runs reality against **our own** claims | three factual errors in the authoring agent's own document — a wrong arithmetic result, a count off by 2×, a figure built on a lagging data export |

**Fable is not a fifth opinion — it is the only reviewer that checks whether *we* told the truth.**
The advisors reason about the text they are given. Fable re-executes the claims. Adding a fifth
*model* adds little; dropping Fable removes a whole failure class.

---

## 2. The Codex seat: pin the model, and never read a truncated listing

**Native default:** `gpt-6-astra` from `~/.codex/config.toml` (Tom 2026-09-06; supersedes `gpt-5.6-sol`), effort per review tier (medium routine / high hard-to-reverse / xhigh milestone). Verify the invoke
banner shows both.

**On native failure** (429, "Quota exhausted", rate limit — read the error log, do not guess),
fall back to OpenRouter with **`openai/gpt-6-astra`**.

> **This is load-bearing.** In the source session the fallback first ran `openai/gpt-5.3-codex`,
> chosen off a model list truncated by `head -20` that cut off right before the 5.6 family. It
> returned **REVISE**. Re-run on `gpt-5.6-sol`, the *identical prompt* returned **RESTRUCTURE** plus
> three critical findings no other reviewer produced. **Model choice changed the verdict.**
>
> When resolving a model id, list the full family and grep it — never `head` a model listing.

Sol over-flagged nitpicks (CodeRabbit benchmark: 31.6% actionable precision), which is why the prompt
templates carry the suppression instruction — kept on for Astra until measured otherwise. Take the recall; filter the noise.

---

## 3. The Qwen seat (milestone tier only) — and the opt-in GLM seat

Both are **OpenRouter seats driven by the script since 1.6.0**: `--openrouter qwen`
(milestone) or `--openrouter qwen,glm`, alone (`--openrouter-only`) or alongside the CLI
advisors. No hand-built curl — that is how the truncated-listing wrong-model review of
2026-08-04 happened.

- **Model: the NEWEST flagship on OpenRouter's live listing at launch** (Tom 2026-09-06):
  `qwen/qwen<ver>-max(-mmdd)` and `z-ai/glm-<ver>`, numeric version order, flash / turbo /
  preview / thinking / vision variants and `:free` / `:batch` rows ignored. The banner prints the
  id and its source; `<seat>_usage.log` records the model actually served. `COUNCIL_QWEN_MODEL` /
  `COUNCIL_GLM_MODEL` pin explicitly. If the listing is unreachable the script says so loudly and
  uses its last-known id (2026-09-06: `qwen3.8-max-0902`, `glm-5.3`).
- **`max_tokens` 32000 by default** (`COUNCIL_OPENROUTER_MAX_TOKENS`). At 9,000 Qwen spent **9,002
  completion tokens entirely on reasoning and returned zero visible text**. The script detects
  that shape and names it (`starved: N reasoning tokens, empty content`).
- The driver line (*keep internal reasoning short, start with VERDICT:*) rides in both the system
  and the user turn — Qwen ignored a system-only instruction on the 2026-09-06 probe.
- Effort follows `COUNCIL_CODEX_EFFORT` (`COUNCIL_OPENROUTER_EFFORT` to decouple).
- Cost: Qwen ~$0.08 for a 26 KB diff review at medium (2026-09-06), ~$0.15 for a 42 KB plan.
- GLM: an unmeasured lens, opt-in only, in no tier by default. ~$0.02 per 26 KB diff review at
  medium, ~70 s. Responses stream (a NON-streaming GLM request sat 9 minutes receiving only
  keep-alive whitespace, then timed out), so a timeout still leaves `<seat>_partial.md`.

Qwen is the third-best of the three advisors on average but consistently finds **absences** — the
gate nobody specified, the section that quietly disappeared between drafts. That is a different
search than either Codex or Gemini performs.

---

## 4. Fable pairing — low by default, high at merge

**Fable (low) — run it alongside every Council invocation.**
Its work is mechanical: re-run the query, re-grep, re-count, re-read the file. Reasoning effort does
not make a grep more true. At low it produced the single most decisive finding of the source
session, mechanically refuting the plan's load-bearing claim before any advisor spoke.

**Fable's limiting factor is claim ENUMERATION, not effort.** Coverage is a function of which claims
it is pointed at — and an authoring agent will naturally hand over the claims it feels confident
about. So:
- Extract the claim list **mechanically** from the document — every number, count, `file:line`,
  "already exists", "X does Y". Do not curate.
- Where possible run it as a **subagent that never sees the authoring reasoning** — just the
  document and the repo. Otherwise the same context that produced the error chooses what to check.

**Fable (high) — only when the deliverable commits to a specific fix.**
High buys one thing low structurally cannot: the judgment *"does this fix close the class, or only
the named trigger?"* That has no command to run. In the source session it found that a plan fixed
four call sites where it should have fixed the shared wrapper — leaving the fifth caller free to
reintroduce the same bug.

Do **not** run high on investigations or plans that merely describe work; low is genuinely enough
there. Budget roughly **one high pass per shipped stage, at merge** — not one per document. High is
expensive even on a Max x20 plan.

### High must delegate the gathering — it is for judgment, not lookup

Measured on the source session's high pass: **~25 claims verified, 24 of which needed a shell
command and exactly one needed reasoning** — and that one produced the entire unique value (a plan
fixing four call sites where it should have fixed the shared wrapper). Running all 25 at high effort
paid a premium 24 times for work a `grep` does better.

Run high as three tiers, and never let a higher tier do a lower tier's work:

| Tier | Does | Runs on |
|---|---|---|
| **T1 — no model** | anything with a deterministic command: counts, `file:line` existence, `git log`/`diff` drift, re-running a test, query or build | plain shell in the main session |
| **T2 — cheap delegate** | claim extraction + per-claim verification where a command must be composed; returns *claim → command run → raw output* | subagent on the cheapest capable model at **low** effort |
| **T3 — high, main session** | only the residue: claims that **cannot** be re-run, and the class-closure question — *"does this fix close the class, or only the named trigger?"* | main session, high effort |

**Four rules that make the tiering real:**

1. **If the high-effort pass is reading files to discover what a claim says, the delegation failed.**
   T3 should receive a finished evidence table and spend its budget on judgment alone.
2. **T2 returns raw command output, never a summary or a verdict.** A cheap verifier's report is
   itself a claim — summarising at T2 moves the over-claim problem down a tier and hides it behind a
   smaller model. This is the same discipline the judge applies to everyone else; it applies to its
   own delegates.
3. **Skip T3 entirely** when T1+T2 return zero discrepancies **and** the deliverable ships no fix.
   With no fix there is no class to close, so there is nothing high effort can contribute.
4. **One high pass per shipped stage.** Wanting a second is a signal the first was scoped wrong, not
   that more effort is required.

### What Fable cannot do, at any effort
It verifies claims that were **made**. It cannot audit what was **omitted**, and it cannot reason
about what **would happen**. Both categories were the majority of serious findings in the source
session — and both are what the advisors are for. Fable and Council are not substitutes.

---

## 5. The stopping rule — three rounds is a ceiling, not a floor

**If two consecutive rounds trace to the same root cause, stop reviewing and take the robust option
the reviewers already named.**

In the source session, three rounds produced three RESTRUCTURE/REVISE verdicts and the residual never
moved — it was the same root fact each time, wearing new vocabulary. The conclusion finally adopted
was available at round one; two further rounds confirmed it at real cost in time and scope.

This is the operational form of two standing lessons: *Council ratchets guards and never releases
them* ("is this safe?" has no failing state toward too-quiet), and *when residuals recur, take the
robust option*. Without a stopping rule, a four-way panel becomes a scope-inflation engine at exactly
the moment you need to ship.

Corollary: after each round, state the **root cause** of the residual in one sentence. If that
sentence is the same as last round's, the next action is a decision, not another review.

---

## 6. Isolated workspace when the repo is busy

Council writes `AGENTS.md` and `.council-tmp/` into `$WORK_DIR`, and its safety net hashes the whole
tree and **fails closed (exit 2) on any change**. If another session, agent, or watcher is writing to
the repo during the advisory window, that net will false-trip — and the sync itself will have
modified the repo you were asked not to touch.

**When the target repo is busy, or the review is of a document rather than a diff:**

```bash
mkdir -p <scratch>/review-ws
cp <repo>/CLAUDE.md <scratch>/review-ws/CLAUDE.md
git -C <scratch>/review-ws init -q && git -C <scratch>/review-ws add -A && git -C <scratch>/review-ws commit -qm base
# then run preflight / sync / invoke with WORK_DIR = <scratch>/review-ws
```

Codex loses read-only repo access, which costs nothing for a **plan review** — those already require
the no-explore directive and full inlining. Do **not** do this for a diff review where Codex reading
adjacent code is the point.

---

## 7. OpenRouter operations

- A `403 "Key limit exceeded (total limit)"` is a **per-key spend cap**, not an account balance.
  Adding credit does nothing. Raise the limit on the key itself, at the URL in the error body.
  Check with `GET /api/v1/key` → `usage` / `limit` / `limit_remaining`.
- Long reviews exceed a 2-minute foreground tool timeout. Launch the `curl` **detached**
  (`nohup … & disown`) and poll the response file, exactly as §3a does for the advisors.
- The response file is written progressively — a `json.load` mid-write fails with "Expecting value".
  Confirm the writer has exited before parsing.
- Always report the `usage` block: `cost`, and
  `completion_tokens_details.reasoning_tokens`. A high reasoning count with empty content is the
  starvation signature in §3, not a refusal.

---

## 8. Quick reference

```
Routine change     → Fable(low) + Codex(gpt-6-astra)
Hard-to-reverse    → Fable(low) + Codex(gpt-6-astra) + Gemini
Milestone / plan   → Fable(low) + Codex(gpt-6-astra) + Gemini + Qwen(--openrouter qwen: newest on listing, 32k tokens)
GLM                → opt-in only (--openrouter glm), no tier
At merge of a stage that ships a fix → add Fable(high)

Fable HIGH tiering  → T1 shell (no model) · T2 cheap delegate, low effort, RAW output
                      · T3 high, main session, judgment only
                      skip T3 if T1+T2 clean AND no fix shipped
Codex native fails → OpenRouter openai/gpt-6-astra   (never a lesser variant)
Repo busy          → isolated scratch workspace
Same root cause 2 rounds running → stop; decide
```
