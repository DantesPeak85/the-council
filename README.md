# The Council

*Parallel minds. Singular clarity.*

> **Security advisory (2026-05-25):** Versions **1.2.0 and 1.2.1 do NOT enforce read-only on the Gemini advisor** as their docs claim — `agy`'s `--dangerously-skip-permissions` auto-approves tool calls rather than withholding them, and a 2026-05-24 incident saw agy ghost-write 8 files into a project directory. **Upgrade to 1.3.0 or later** for real OS-level sandbox enforcement (`sandbox-exec` on macOS) and a pre/post-invocation diff safety net. See [SKILL.md → Permissions and Safety](skills/the-council/SKILL.md) for the full incident note.

A Claude Code skill that convenes OpenAI Codex and Google Gemini as an advisory board. Both run in parallel via their CLIs, with full project context, and return independent analyses that Claude synthesizes into a unified recommendation.

## What It Does

When you say "ask the council" or request a second opinion, Claude:

1. Syncs your project context (CLAUDE.md) to both advisors
2. Composes a prompt using the appropriate template (code review, architecture, debugging, or general)
3. Invokes Codex and Gemini in parallel, both in **read-only sandboxes**
4. Synthesizes the responses — highlighting consensus, divergence, and Claude's own recommendation

Codex runs with `xhigh` reasoning effort by default — the invoke script sets `COUNCIL_CODEX_EFFORT=xhigh` explicitly rather than trusting `~/.codex/config.toml` (which often ships a weaker `medium`). Codex has read-only filesystem access to the working directory; Gemini reviews the inlined prompt content in a single shot.

### Learning Loop

After each council session, Claude reflects on what the advisors revealed — gaps, blind spots, or better approaches — and generalizes those learnings into `CLAUDE.md` and `AGENTS.md`. This means future sessions in the same repository start with lessons from previous council deliberations already loaded.

## Installation

### Via Claude Code Plugin Marketplace

```
/plugin marketplace add DantesPeak85/the-council
/plugin install the-council@the-council-marketplace
```

### Manual Installation

Clone this repo and register it as a local plugin in your Claude Code configuration.

You need **at least one** advisor CLI installed and authenticated.

### OpenAI Codex CLI

```bash
npm i -g @openai/codex
codex auth
```

### Google Gemini — two backends

The Council picks the Gemini backend automatically (`COUNCIL_GEMINI_BACKEND=auto`):

- **Antigravity CLI (`agy`)** — the **default** backend. Install Google's Antigravity client; it authenticates via `~/.gemini/oauth_creds.json` on first run. Runs pty-wrapped, sandboxed, single-shot.
- **`gemini` CLI (optional, preferred when available)** — the single-shot JSON backend. Selected automatically **only** when the `gemini` binary is on `PATH` **and** a paid Gemini API key — `GEMINI_API_KEY` or `GOOGLE_API_KEY` (AI Studio) — is exported. gemini-cli's free oauth-personal auth stopped serving 2026-06-18, so this backend requires the paid key.

### System dependencies (macOS)

- **`python3`** — parses the gemini-cli JSON response envelope (no `jq` dependency).
- **`sandbox-exec`** and **`script`** — ship with macOS. The Council uses `sandbox-exec` to wrap `agy`/`gemini` in an OS-level deny-write sandbox and `script` to allocate the pty that `agy --print` needs to emit output. On non-macOS there is no `sandbox-exec`, so `agy` refuses to run unless you pass `--allow-unsandboxed-gemini` (or use `--codex-only`).

### Graceful Degradation

The Council runs a preflight check on first invocation. If only one advisor is available, it operates in single-advisor mode and notes this in the synthesis. If neither is available, it shows installation instructions.

## Usage

Just tell Claude:

- "Ask the council to review this PR"
- "Get a second opinion on this architecture"
- "Council review" on any code changes
- "Debug this with the council"

The council is also invoked proactively during high-stakes architectural decisions or security-sensitive code reviews.

## Recommended Configuration

**Codex** (`~/.codex/config.toml`) — set your preferred model:
```toml
model = "gpt-5.6-sol"
```
Reasoning effort is set by the invoke script (`COUNCIL_CODEX_EFFORT=xhigh` by default), so you do **not** need `model_reasoning_effort` in config. Set `COUNCIL_CODEX_EFFORT=config` if you'd rather the script defer to `config.toml`.

**Gemini** — no config file needed. To pin a model for either backend, export `COUNCIL_GEMINI_MODEL` (run `agy models` for agy ids; an AI Studio model id for gemini-cli). Left unset, each backend uses its own default.

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `CODEX_MODEL` | unset → `~/.codex/config.toml` | Override the Codex model |
| `COUNCIL_CODEX_EFFORT` | `xhigh` | Codex reasoning effort; set `config` to defer to `config.toml` |
| `COUNCIL_TIMEOUT` | `600` | Max seconds per advisor (raise to `900` for very large xhigh reviews) |
| `AGY_PRINT_TIMEOUT` | `8m` | agy `--print-timeout` override; must stay below `COUNCIL_TIMEOUT` |
| `COUNCIL_GEMINI_BACKEND` | `auto` | Gemini backend: `auto`, `gemini`, or `agy` |
| `COUNCIL_GEMINI_MODEL` | unset (backend default) | Pin the Gemini model for either backend |
| `COUNCIL_SNAPSHOT_EXCLUDES` | (none) | Comma-separated pathspecs excluded from the safety-net snapshot |

## Safety

Both advisors run under **OS-enforced read-only sandboxes** on macOS — neither can modify your project:

- **Codex**: `--sandbox read-only` — Codex's built-in OS-level deny-write.
- **Gemini (`agy`)**: wrapped in `sandbox-exec` using the deny-write profile at `skills/the-council/scripts/council_sandbox.sb`, plus a pty (`script`) so `agy --print` actually emits output. Writes are allowed only to `~/.gemini/`, the per-invocation `.council-tmp/` dir, system temp, and agy's cache subdirs — everything else is blocked at the OS layer.
- **Gemini (`gemini` CLI)**: single-shot headless mode with no tool access, wrapped in the same `sandbox-exec` deny-write profile.

As defense in depth on **all platforms**, the script snapshots the working tree before and after the run and fails closed (exit 2) on any unauthorized change. See [SKILL.md → Permissions and Safety](skills/the-council/SKILL.md) for the full model.

## Author

Created by [Tom Wolinitz](https://www.linkedin.com/in/tom-wolinitz/) with [Claude Code](https://claude.ai/code)

More projects at [github.com/DantesPeak85](https://github.com/DantesPeak85)

## License

MIT
