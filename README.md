# The Council

*Parallel minds. Singular clarity.*

A Claude Code skill that convenes OpenAI Codex and Google Gemini as an advisory board. Both run in parallel via their CLIs, with full project context, and return independent analyses that Claude synthesizes into a unified recommendation.

## What It Does

When you say "ask the council" or request a second opinion, Claude:

1. Syncs your project context (CLAUDE.md) to both advisors
2. Composes a prompt using the appropriate template (code review, architecture, debugging, or general)
3. Invokes Codex and Gemini in parallel, both in **read-only sandboxes**
4. Synthesizes the responses — highlighting consensus, divergence, and Claude's own recommendation

Both advisors run at maximum capability (Codex with `xhigh` reasoning effort, Gemini with `HIGH` thinking level) and have full codebase access in read-only mode.

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

## Prerequisites

You need **at least one** of these CLIs installed and authenticated:

### OpenAI Codex CLI

```bash
npm i -g @openai/codex
codex auth
```

### Google Gemini CLI

```bash
npm i -g @google/gemini-cli
gemini   # Authenticates via OAuth on first run
```

Enable experimental plan mode in `~/.gemini/settings.json`:
```json
{ "experimental": { "plan": true } }
```

### Graceful Degradation

The Council runs a preflight check on first invocation. If only one CLI is available, it operates in single-advisor mode and notes this in the synthesis. If neither is available, it shows installation instructions.

## Usage

Just tell Claude:

- "Ask the council to review this PR"
- "Get a second opinion on this architecture"
- "Council review" on any code changes
- "Debug this with the council"

The council is also invoked proactively during high-stakes architectural decisions or security-sensitive code reviews.

## Recommended Configuration

For maximum advisor capability:

**Codex** (`~/.codex/config.toml`):
```toml
model_reasoning_effort = "xhigh"
```

**Gemini** (`~/.gemini/settings.json`):
```json
{
  "modelConfigs": {
    "customAliases": {
      "council": {
        "modelConfig": {
          "model": "gemini-3-pro-preview",
          "generateContentConfig": {
            "thinkingConfig": { "thinkingLevel": "HIGH" }
          }
        }
      }
    }
  }
}
```

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `CODEX_MODEL` | auto (CLI default) | Model for Codex advisor |
| `GEMINI_MODEL` | `gemini-3-pro-preview` | Model for Gemini advisor |
| `COUNCIL_TIMEOUT` | `300` | Max seconds per advisor |

## Safety

Both advisors run in **read-only mode** and cannot modify your project:

- **Codex**: `--sandbox read-only`
- **Gemini**: `--approval-mode plan`

## Author

Created by [Tom Wolinitz](https://www.linkedin.com/in/tom-wolinitz/) with [Claude Code](https://claude.ai/code)

More projects at [github.com/DantesPeak85](https://github.com/DantesPeak85)

## License

MIT
