# Advisory Context (synced from CLAUDE.md)

You are being consulted as an external advisor on this project.
Review the project context below and provide your expert analysis when prompted.
Focus on correctness, potential issues, and alternative approaches.

---

# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

The Council is a **Claude Code Skill plugin** that convenes Qwen through OpenRouter and Google Gemini as its default advisory board. Codex remains available as an explicit seat or compatibility fallback. The advisors return independent analyses that Claude synthesizes into unified recommendations.

This is **not** a Node/TypeScript application — it's a pure Bash + Markdown skill with no build system, package manager, or test framework.

## Architecture

```
skills/the-council/
├── SKILL.md                        # Operational guide (skill definition + workflow)
├── references/prompt-templates.md  # 4 prompt templates (review, architecture, debug, general)
└── scripts/
    ├── council_preflight.sh        # Detects available CLIs + auth status (cached 2h)
    ├── council_sync.sh             # Read-only shim; legacy interrupted-run recovery only
    └── council_invoke.sh           # Parallel CLI invocation: timeouts, OS sandbox, snapshot safety net, response validation
```

**Execution flow:** Preflight → Compose an inlined prompt → Invoke advisors in parallel → Synthesize responses → Generalize learnings. The project's `AGENTS.md` is never replaced.

**Operating modes** are determined by preflight: Qwen + Gemini by default, Qwen-only, Gemini-only, explicit Codex modes, or a loudly announced Codex compatibility fallback when OpenRouter is unavailable.

## Key Design Decisions

- **Read-only enforcement (1.3.0+)**: Both advisors run with OS-level deny-write sandboxes on macOS. Codex uses its built-in `--sandbox read-only`. Gemini (`agy`) is wrapped in `sandbox-exec` with a deny-write profile at `skills/the-council/scripts/council_sandbox.sb`; writes are allowed only to `~/.gemini/`, the per-invocation `.council-tmp/<...>/` dir, system temp, and agy-specific `~/Library/Caches/` subdirs. On non-macOS, the script refuses to run agy unless `--allow-unsandboxed-gemini` is passed.
- **Diff safety net (1.3.0+)**: pre/post-invocation snapshot of `$WORK_DIR` (git: HEAD + status with `--ignored=traditional` + sha256 of tracked + untracked + gitignored files; non-git: find + sha256). Snapshot excludes `.council-tmp/` (response files) and `.antigravitycli/` (agy's housekeeping dir). Any other change fails the invocation with exit 2 and a `[COUNCIL_SAFETY_NET]` banner. See SKILL.md for the historical 1.2.x ghost-write incident this replaces.
- **Gemini invocation (1.4.0)**: Gemini reviews the INLINED prompt only — no project `--add-dir`, no repo exploration. The composed prompt is written into the per-invocation `.council-tmp/<run>/` dir, which becomes the advisor's only workspace. The backend is resolved at runtime: `gemini` CLI (single-shot, stdin, JSON envelope) when a paid `GEMINI_API_KEY`/`GOOGLE_API_KEY` is set and `gemini` is on PATH, else `agy` (pty-wrapped via `script`, sandboxed). The old `maxSessionTurns` settings injection was a verified no-op and is gone — `~/.gemini/antigravity-cli/settings.json` is never touched.
- **Prompt sanitization**: `jsr:` import strings are redacted from the Gemini prompt before invocation to avoid spurious safety/policy blocks from `agy`.
- **Empty-response retry**: If `agy` exits 0 with no stdout and no stderr, the invocation is retried once before being reported as failed.
- **Response validation (1.4.0)**: an advisor fails only on empty output, a script-written `[COUNCIL-ADVISOR-FAILURE]` placeholder, a nonzero exit with no verdict line, a refusal, or non-engagement (a short verdict-less reply to a large prompt). The old response-body word-grep (`policy`/`blocked`/`quota`/`rate limit`) is gone — it false-failed substantive reviews; stderr noise now demotes to an advisory `*_warnings.log`, not a failure.
- **Parallel execution**: Both advisors run as background processes with configurable timeout (`COUNCIL_TIMEOUT`, default 600s).
- **NVM compatibility**: `council_invoke.sh` loads NVM environment to find globally-installed CLI tools.
- **macOS support**: Uses `gtimeout` (from coreutils) when available, falls back to `timeout` or no timeout.
- **Graceful degradation**: Works with one advisor if the other is unavailable; shows install help if neither exists.

## Shell Script Conventions

All scripts use `set -euo pipefail`. Variables are quoted. Exit codes are meaningful (0 = success/available, 1 = failure/unavailable). Preflight output uses `key=value` format for parsing.

## Environment Variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `CODEX_MODEL` | unset → `~/.codex/config.toml` | Codex advisor model (passed via `-m`) |
| `COUNCIL_CODEX_EFFORT` | `xhigh` | Codex reasoning effort; `config` defers to `config.toml` |
| `COUNCIL_TIMEOUT` | `600` | Max seconds per advisor (enforced via `gtimeout`/`timeout` when available) |
| `AGY_PRINT_TIMEOUT` | `8m` | Override agy `--print-timeout`. agy's 5m default can race with `COUNCIL_TIMEOUT`; 8m keeps `COUNCIL_TIMEOUT` as the outer bound. |
| `COUNCIL_GEMINI_BACKEND` | `auto` | Gemini backend: `auto`, `gemini`, or `agy` |
| `COUNCIL_GEMINI_MODEL` | unset (backend default) | Pin the Gemini model for either backend |
| `COUNCIL_SNAPSHOT_EXCLUDES` | (none) | Comma-separated pathspecs excluded from the safety-net snapshot |

## Temp Files

Invocation creates `.council-tmp/council_<mode>_YYYYMMDD_HHMMSS/` in the working directory, containing the composed prompt, advisor responses, errors, warnings, and safety-net snapshots. The preflight cache lives at `.council-tmp/preflight_cache_v4`. Council never replaces the project's `AGENTS.md`.
