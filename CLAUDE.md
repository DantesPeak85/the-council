# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

The Council is a **Claude Code Skill plugin** that convenes OpenAI Codex and Google Gemini as an advisory board. Both run in parallel via their CLIs in read-only sandboxes, returning independent analyses that Claude synthesizes into unified recommendations.

This is **not** a Node/TypeScript application — it's a pure Bash + Markdown skill with no build system, package manager, or test framework.

## Architecture

```
skills/the-council/
├── SKILL.md                        # Operational guide (skill definition + workflow)
├── references/prompt-templates.md  # 4 prompt templates (review, architecture, debug, general)
└── scripts/
    ├── council_preflight.sh        # Detects available CLIs + auth status (cached 2h)
    ├── council_sync.sh             # Copies CLAUDE.md → AGENTS.md (Codex only)
    └── council_invoke.sh           # Parallel CLI invocation with timeout, sandbox isolation + validation
```

**Execution flow:** Preflight → Sync context → Compose prompt from template → Invoke advisors in parallel → Synthesize responses (consensus/divergence/recommendation).

**Operating modes** are determined by preflight: Full Council (both CLIs), Codex-only, Gemini-only, or abort (neither available).

## Key Design Decisions

- **Read-only enforcement**: Codex uses `--sandbox read-only`, Gemini uses `--approval-mode plan`. Advisors cannot modify files.
- **Gemini sandbox isolation**: Gemini runs from an empty temp directory to prevent auto-loading GEMINI.md, which causes it to burn its turn budget on tool calls. All context is embedded inline in the prompt.
- **Parallel execution**: Both advisors run as background processes with configurable timeout (`COUNCIL_TIMEOUT`, default 300s).
- **NVM compatibility**: `council_invoke.sh` loads NVM environment to find globally-installed CLI tools.
- **macOS support**: Uses `gtimeout` (from coreutils) when available, falls back to `timeout` or no timeout.
- **Graceful degradation**: Works with one advisor if the other is unavailable; shows install help if neither exists.

## Shell Script Conventions

All scripts use `set -euo pipefail`. Variables are quoted. Exit codes are meaningful (0 = success/available, 1 = failure/unavailable). Preflight output uses `key=value` format for parsing.

## Environment Variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `CODEX_MODEL` | auto (CLI default) | Codex advisor model |
| `GEMINI_MODEL` | auto (CLI default) | Gemini advisor model |
| `COUNCIL_TIMEOUT` | `300` | Max seconds per advisor |

## Temp Files

Invocation creates `.council-tmp/council_YYYYMMDD_HHMMSS/` in the working directory containing `{codex,gemini}_{response.md,error.log}`, plus `gemini_sandbox/` (isolated workspace) and `gemini_prompt.txt` (stdin delivery). Preflight cache lives at `.council-tmp/preflight_cache`. Context sync creates `AGENTS.md` in the working directory. All temp files are cleaned up with `rm -rf .council-tmp/`; AGENTS.md must be removed separately.
