# Advisory Context (synced from CLAUDE.md)

You are being consulted as an external advisor on this project.
Review the project context below and provide your expert analysis when prompted.
Focus on correctness, potential issues, and alternative approaches.

---

# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

The Council is a **Claude Code Skill plugin** that convenes OpenAI Codex (`codex` CLI) and Google Gemini (`agy` CLI, Google's Antigravity client running Gemini 3.5 Flash by default) as an advisory board. Both run in parallel as effectively read-only consultants, returning independent analyses that Claude synthesizes into unified recommendations.

This is **not** a Node/TypeScript application — it's a pure Bash + Markdown skill with no build system, package manager, or test framework.

## Architecture

```
skills/the-council/
├── SKILL.md                        # Operational guide (skill definition + workflow)
├── references/prompt-templates.md  # 4 prompt templates (review, architecture, debug, general)
└── scripts/
    ├── council_preflight.sh        # Detects available CLIs + auth status (cached 2h)
    ├── council_sync.sh             # Copies CLAUDE.md → AGENTS.md (Codex only)
    └── council_invoke.sh           # Parallel CLI invocation with timeout, settings injection + response validation
```

**Execution flow:** Preflight → Sync context → Compose prompt from template → Invoke advisors in parallel → Synthesize responses (consensus/divergence/recommendation) → Generalize learnings into CLAUDE.md/AGENTS.md.

**Operating modes** are determined by preflight: Full Council (both CLIs), Codex-only, Gemini-only, or abort (neither available).

## Key Design Decisions

- **Read-only enforcement**: Codex uses `--sandbox read-only`. Gemini (via `agy`) is invoked with `--print --dangerously-skip-permissions` and the prompt **piped via stdin** from `$GEMINI_PROMPT_FILE` — stdin reaches EOF after the prompt is consumed, and `--dangerously-skip-permissions` together mean agy cannot prompt for tool approvals (write/exec tools fail closed). Advisors cannot modify files. Note: both the stdin-EOF behavior AND `--dangerously-skip-permissions` are required — removing either alone could allow interactive approvals.
- **Gemini codebase access**: `agy` runs with `--add-dir "$WORK_DIR"` to expose the project (the `--print` mode does NOT honor cwd — it would otherwise operate from an isolated scratch dir at `~/.gemini/antigravity-cli/scratch`). Exploration is bounded by temporarily injecting `maxSessionTurns` (default `100`, configurable via `GEMINI_MAX_TURNS`) into `~/.gemini/antigravity-cli/settings.json`, with the original settings backed up to `gemini_settings_backup.json` and restored by an `EXIT` trap.
- **Prompt sanitization**: `jsr:` import strings are redacted from the Gemini prompt before invocation to avoid spurious safety/policy blocks from `agy`.
- **Empty-response retry**: If `agy` exits 0 with no stdout and no stderr, the invocation is retried once before being reported as failed.
- **Response validation**: After both advisors return, error logs and response files are grep'd against known failure patterns (rate limits, quota, `unproductive state`, `Loop detected`, `Maximum session turns exceeded`, etc.). A match flips status to failure even when the CLI exited 0.
- **Parallel execution**: Both advisors run as background processes with configurable timeout (`COUNCIL_TIMEOUT`, default 300s).
- **NVM compatibility**: `council_invoke.sh` loads NVM environment to find globally-installed CLI tools.
- **macOS support**: Uses `gtimeout` (from coreutils) when available, falls back to `timeout` or no timeout.
- **Graceful degradation**: Works with one advisor if the other is unavailable; shows install help if neither exists.

## Shell Script Conventions

All scripts use `set -euo pipefail`. Variables are quoted. Exit codes are meaningful (0 = success/available, 1 = failure/unavailable). Preflight output uses `key=value` format for parsing.

## Environment Variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `CODEX_MODEL` | auto (from `~/.codex/config.toml`) | Codex advisor model (passed via `-m`) |
| `GEMINI_MODEL` | unused | Reserved variable; `agy` CLI selects the model itself (Gemini 3.5 Flash default). Setting it only affects the display label, not the actual model. |
| `COUNCIL_TIMEOUT` | `300` | Max seconds per advisor (enforced via `gtimeout`/`timeout` when available) |
| `GEMINI_MAX_TURNS` | `100` | Max Gemini session turns; temporarily written into agy's `settings.json` |
| `AGY_PRINT_TIMEOUT` | `8m` | Override agy `--print-timeout`. agy's 5m default can race with `COUNCIL_TIMEOUT`; 8m keeps `COUNCIL_TIMEOUT` as the outer bound. |

## Temp Files

Invocation creates `.council-tmp/council_<mode>_YYYYMMDD_HHMMSS/` (where `<mode>` is `full`, `codex`, or `gemini` depending on which advisors ran) in the working directory containing `{codex,gemini}_{response.md,error.log}`, `gemini_prompt.txt` (sanitized prompt for diagnostics), and `gemini_settings_backup.json` (pre-injection snapshot of `~/.gemini/antigravity-cli/settings.json`, used by the EXIT trap to restore the user's real settings). Preflight cache lives at `.council-tmp/preflight_cache`. Context sync creates `AGENTS.md` in the working directory. All temp files are cleaned up with `rm -rf .council-tmp/`; `AGENTS.md` must be removed separately.
