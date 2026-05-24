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

- **Read-only enforcement**: Codex uses `--sandbox read-only`. Gemini (via `agy`) is invoked with `--print --dangerously-skip-permissions` and **closed stdin** (`< /dev/null`) — without an interactive TTY, agy cannot prompt for tool approvals, so any write or exec tool call fails closed. Advisors cannot modify files.
- **Gemini codebase access**: `agy` runs from the project directory with full read access. Exploration is bounded by temporarily injecting `maxSessionTurns` (default `100`, configurable via `GEMINI_MAX_TURNS`) into `~/.gemini/antigravity-cli/settings.json`. The original settings file is snapshotted to `gemini_settings_backup.json` and restored by an `EXIT` trap, so Ctrl+C, SIGTERM, and `set -e` aborts all leave the user's real settings untouched.
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

## Temp Files

Invocation creates `.council-tmp/council_<mode>_YYYYMMDD_HHMMSS/` (where `<mode>` is `full`, `codex`, or `gemini` depending on which advisors ran) in the working directory containing `{codex,gemini}_{response.md,error.log}`, `gemini_prompt.txt` (sanitized prompt for diagnostics), and `gemini_settings_backup.json` (pre-injection snapshot of `~/.gemini/antigravity-cli/settings.json`, used by the EXIT trap to restore the user's real settings). Preflight cache lives at `.council-tmp/preflight_cache`. Context sync creates `AGENTS.md` in the working directory. All temp files are cleaned up with `rm -rf .council-tmp/`; `AGENTS.md` must be removed separately.
