#!/usr/bin/env bash
# council_preflight.sh — Check CLI availability and authentication
# Exit codes: 0 = at least one advisor available+authenticated, 1 = none
# Outputs key=value status lines to stdout.
# Caches result in .council-tmp/preflight_cache_v3 for session reuse.
#
# Gemini facts are reported INDEPENDENTLY (v1.4.0). The invoke script resolves a
# backend at runtime (gemini CLI when GEMINI_API_KEY is set, else agy), so agy
# availability, gemini-cli availability, and Gemini credentials are three separate
# facts — a gemini-cli-only machine must still be able to authenticate:
#   AGY_AVAILABLE          — antigravity CLI (`agy`) present
#   GEMINI_CLI_AVAILABLE   — Google `gemini` CLI present
#   GEMINI_API_KEY_SET     — GEMINI_API_KEY or GOOGLE_API_KEY exported
#   GEMINI_AUTHENTICATED   — credentials present AND >=1 backend binary present
# OpenRouter seats (v1.6.0) are optional extra advisors; they never make the
# preflight pass on their own:
#   OPENROUTER_API_KEY_SET — OPENROUTER_API_KEY exported
#   OPENROUTER_AVAILABLE   — key set AND curl AND python3 present
#
# Usage: council_preflight.sh [working_directory]
#   working_directory: defaults to current directory

set -euo pipefail

WORK_DIR="${1:-.}"
WORK_DIR="$(cd "$WORK_DIR" && pwd)"

mkdir -p "${WORK_DIR}/.council-tmp"
# v3 schema (1.6.0 adds the OpenRouter facts): older caches lack keys the invoke
# docs tell callers to read, so the filename is bumped rather than reused.
CACHE_FILE="${WORK_DIR}/.council-tmp/preflight_cache_v3"

# Invalidate if the Codex config changed since the cache was written — auth/model
# fixed mid-session must not stay invisible for the 2-hour TTL.
if [[ -f "$CACHE_FILE" && "$HOME/.codex/config.toml" -nt "$CACHE_FILE" ]]; then
  rm -f "$CACHE_FILE"
fi

# Return cached result if fresh (less than 2 hours old). The cached record carries
# its own exit status (PREFLIGHT_EXIT) so replay preserves "no advisor" == nonzero.
if [[ -f "$CACHE_FILE" ]]; then
  FILE_AGE=$(( $(date +%s) - $(stat -f %m "$CACHE_FILE" 2>/dev/null || stat -c %Y "$CACHE_FILE" 2>/dev/null) ))
  if (( FILE_AGE < 7200 )); then
    cat "$CACHE_FILE"
    CACHED_EXIT="$(grep -E '^PREFLIGHT_EXIT=' "$CACHE_FILE" | tail -1 | cut -d= -f2 || true)"
    exit "${CACHED_EXIT:-0}"
  fi
fi

# Load nvm/node environment if needed
export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
if [[ -s "$NVM_DIR/nvm.sh" ]]; then
  source "$NVM_DIR/nvm.sh" --no-use 2>/dev/null
  NODE_BIN="$(nvm which default 2>/dev/null | xargs dirname 2>/dev/null)" || true
  if [[ -n "$NODE_BIN" && -d "$NODE_BIN" ]]; then
    export PATH="$NODE_BIN:$PATH"
  fi
fi

CODEX_INSTALLED=false
CODEX_AUTHENTICATED=false
CODEX_VERSION=""
AGY_AVAILABLE=false
GEMINI_CLI_AVAILABLE=false
GEMINI_API_KEY_SET=false
GEMINI_INSTALLED=false      # any Gemini backend binary present (agy OR gemini-cli)
GEMINI_AUTHENTICATED=false
AGY_VERSION=""
OPENROUTER_API_KEY_SET=false
OPENROUTER_AVAILABLE=false

# --- Check Codex CLI ---
if command -v codex &>/dev/null; then
  CODEX_INSTALLED=true
  CODEX_VERSION="$(codex --version 2>/dev/null | head -1 | tr -d '\r' || true)"
  # File-existence heuristic only — a live auth probe would cost a model call.
  if [[ -n "${OPENAI_API_KEY:-}" ]] || [[ -f "$HOME/.codex/config.toml" ]]; then
    CODEX_AUTHENTICATED=true
  fi
fi

# --- Gemini backends: three INDEPENDENT facts ---
# Fact 1: antigravity CLI present.
if command -v agy &>/dev/null; then
  AGY_AVAILABLE=true
  AGY_VERSION="$(agy --version 2>/dev/null | head -1 | tr -d '\r' || true)"
fi
# Fact 2: Google gemini CLI present.
if command -v gemini &>/dev/null; then
  GEMINI_CLI_AVAILABLE=true
fi
# Fact 3: Gemini credentials — env API key OR persisted OAuth creds.
# NOTE: ~/.gemini/antigravity-cli/settings.json is deliberately NOT a credential
# signal: v1.3.0's invoke script used to CREATE that file, so its mere presence
# proves nothing about authentication (and would falsely authenticate machines
# that only ever ran the old script).
if [[ -n "${GEMINI_API_KEY:-}" ]] || [[ -n "${GOOGLE_API_KEY:-}" ]]; then
  GEMINI_API_KEY_SET=true
fi
GEMINI_CREDENTIALS=false
if [[ "$GEMINI_API_KEY_SET" == "true" ]] || [[ -f "$HOME/.gemini/oauth_creds.json" ]]; then
  GEMINI_CREDENTIALS=true
fi

if [[ "$AGY_AVAILABLE" == "true" || "$GEMINI_CLI_AVAILABLE" == "true" ]]; then
  GEMINI_INSTALLED=true
fi

# Authenticated iff credentials exist AND at least one backend binary can use them.
if [[ "$GEMINI_CREDENTIALS" == "true" && "$GEMINI_INSTALLED" == "true" ]]; then
  GEMINI_AUTHENTICATED=true
fi

# --- OpenRouter seats: key + transport. Optional; never satisfies the gate alone.
if [[ -n "${OPENROUTER_API_KEY:-}" ]]; then
  OPENROUTER_API_KEY_SET=true
  if command -v curl &>/dev/null && command -v python3 &>/dev/null; then
    OPENROUTER_AVAILABLE=true
  fi
fi

# At least one advisor must be ready.
if [[ "$CODEX_AUTHENTICATED" == "true" || "$GEMINI_AUTHENTICATED" == "true" ]]; then
  PREFLIGHT_EXIT=0
else
  PREFLIGHT_EXIT=1
fi

# Build result (1.4.0: independent Gemini facts + self-describing exit status).
# Every key here is both echoed AND cached, so a cached replay is byte-identical
# to a fresh probe — nothing the caller reads can differ between the two paths.
RESULT="CODEX_INSTALLED=$CODEX_INSTALLED
CODEX_AUTHENTICATED=$CODEX_AUTHENTICATED
CODEX_VERSION=$CODEX_VERSION
GEMINI_INSTALLED=$GEMINI_INSTALLED
GEMINI_AUTHENTICATED=$GEMINI_AUTHENTICATED
AGY_VERSION=$AGY_VERSION
AGY_AVAILABLE=$AGY_AVAILABLE
GEMINI_CLI_AVAILABLE=$GEMINI_CLI_AVAILABLE
GEMINI_API_KEY_SET=$GEMINI_API_KEY_SET
OPENROUTER_API_KEY_SET=$OPENROUTER_API_KEY_SET
OPENROUTER_AVAILABLE=$OPENROUTER_AVAILABLE
PREFLIGHT_EXIT=$PREFLIGHT_EXIT"

# Cache and output
echo "$RESULT" > "$CACHE_FILE"
echo "$RESULT"

exit "$PREFLIGHT_EXIT"
