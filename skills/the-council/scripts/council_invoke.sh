#!/usr/bin/env bash
# council_invoke.sh — Invoke Codex and Gemini in parallel, capture responses
#
# Usage: council_invoke.sh [--codex-only|--gemini-only] [--context-file <path>] <prompt_file> [working_directory]
#   --codex-only:         Only invoke Codex (skip Gemini)
#   --gemini-only:        Only invoke Gemini (skip Codex)
#   --context-file <path>: Append contents of this file to the prompt (for retry context)
#   prompt_file:          Path to a text file containing the advisory prompt
#   working_directory:    defaults to current directory
#
# Outputs: Paths to response files (one per line, last lines of stdout)
#   Full mode:   codex response path, then gemini response path
#   Single mode: only the active advisor's response path
#
# Environment:
#   CODEX_MODEL    — Override Codex model (default: auto, from ~/.codex/config.toml)
#   GEMINI_MODEL   — Override Gemini model (unused with agy CLI)
#   COUNCIL_TIMEOUT  — Max seconds to wait per advisor (default: 300)
#   GEMINI_MAX_TURNS — Max Gemini session turns (default: 100; COUNCIL_TIMEOUT is the primary safety net)

set -euo pipefail

# --- Parse flags ---
RUN_CODEX=true
RUN_GEMINI=true
CONTEXT_FILE=""

while [[ "${1:-}" == --* ]]; do
  case "$1" in
    --codex-only)
      RUN_GEMINI=false
      shift
      ;;
    --gemini-only)
      RUN_CODEX=false
      shift
      ;;
    --context-file)
      CONTEXT_FILE="${2:?--context-file requires a path argument}"
      shift 2
      ;;
    *)
      echo "ERROR: Unknown flag: $1" >&2
      exit 1
      ;;
  esac
done

# --- Resolve timeout command (macOS compatibility) ---
if command -v gtimeout &>/dev/null; then
  TIMEOUT_CMD="gtimeout"
elif command -v timeout &>/dev/null; then
  TIMEOUT_CMD="timeout"
else
  # Fallback: no timeout enforcement
  TIMEOUT_CMD=""
fi

# --- Load nvm/node environment if needed (CLIs installed via npm) ---
export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
if [[ -s "$NVM_DIR/nvm.sh" ]]; then
  source "$NVM_DIR/nvm.sh" --no-use 2>/dev/null
  # Ensure the default node version's bin is in PATH
  NODE_BIN="$(nvm which default 2>/dev/null | xargs dirname 2>/dev/null)" || true
  if [[ -n "$NODE_BIN" && -d "$NODE_BIN" ]]; then
    export PATH="$NODE_BIN:$PATH"
  fi
fi

PROMPT_FILE="${1:?Usage: council_invoke.sh [--codex-only|--gemini-only] <prompt_file> [working_directory]}"
WORK_DIR="${2:-.}"
WORK_DIR="$(cd "$WORK_DIR" && pwd)"

CODEX_MODEL="${CODEX_MODEL:-}"
GEMINI_MODEL="${GEMINI_MODEL:-}"
TIMEOUT_SECS="${COUNCIL_TIMEOUT:-300}"
GEMINI_MAX_TURNS="${GEMINI_MAX_TURNS:-100}"

# Resolve display names for models (show user what's actually being used)
if [[ -n "$CODEX_MODEL" ]]; then
  CODEX_MODEL_DISPLAY="$CODEX_MODEL"
else
  CODEX_MODEL_DISPLAY="$(grep '^model' "${HOME}/.codex/config.toml" 2>/dev/null | head -1 | sed 's/model *= *"\(.*\)"/\1/')"
  CODEX_MODEL_DISPLAY="${CODEX_MODEL_DISPLAY:-unknown}"
fi
if [[ -n "$GEMINI_MODEL" ]]; then
  GEMINI_MODEL_DISPLAY="$GEMINI_MODEL"
else
  GEMINI_MODEL_DISPLAY="Gemini 3.5 Flash (default)"
fi

if [[ ! -f "$PROMPT_FILE" ]]; then
  echo "ERROR: Prompt file not found: $PROMPT_FILE" >&2
  exit 1
fi

# Verify required CLIs are available
if [[ "$RUN_CODEX" == "true" ]] && ! command -v codex &>/dev/null; then
  echo "ERROR: 'codex' not found in PATH. Install it or check your shell environment." >&2
  exit 1
fi
if [[ "$RUN_GEMINI" == "true" ]] && ! command -v agy &>/dev/null; then
  echo "ERROR: 'agy' not found in PATH. Install it or check your shell environment." >&2
  exit 1
fi

PROMPT="$(cat "$PROMPT_FILE")"

# Append context file if provided (used for retry with Q&A clarification)
if [[ -n "$CONTEXT_FILE" ]]; then
  if [[ ! -f "$CONTEXT_FILE" ]]; then
    echo "ERROR: Context file not found: $CONTEXT_FILE" >&2
    exit 1
  fi
  PROMPT="${PROMPT}

---
Additional Context (follow-up clarification):
---
$(cat "$CONTEXT_FILE")"
fi

TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
if [[ "$RUN_CODEX" == "true" && "$RUN_GEMINI" == "true" ]]; then
  DIR_LABEL="full"
elif [[ "$RUN_CODEX" == "true" ]]; then
  DIR_LABEL="codex"
else
  DIR_LABEL="gemini"
fi
TMPDIR_COUNCIL="${WORK_DIR}/.council-tmp/council_${DIR_LABEL}_${TIMESTAMP}"
mkdir -p "$TMPDIR_COUNCIL"

CODEX_OUT="$TMPDIR_COUNCIL/codex_response.md"
GEMINI_OUT="$TMPDIR_COUNCIL/gemini_response.md"
CODEX_ERR="$TMPDIR_COUNCIL/codex_error.log"
GEMINI_ERR="$TMPDIR_COUNCIL/gemini_error.log"

# Determine mode label
if [[ "$RUN_CODEX" == "true" && "$RUN_GEMINI" == "true" ]]; then
  MODE="Full Council"
elif [[ "$RUN_CODEX" == "true" ]]; then
  MODE="Codex-only"
else
  MODE="Gemini-only"
fi

echo "Invoking The Council ($MODE)..."
[[ "$RUN_CODEX" == "true" ]] && echo "  Codex model:  $CODEX_MODEL_DISPLAY"
[[ "$RUN_GEMINI" == "true" ]] && echo "  Gemini model: $GEMINI_MODEL_DISPLAY"
echo "  Working dir:  $WORK_DIR"
echo "  Timeout:      ${TIMEOUT_SECS}s (${TIMEOUT_CMD:-none})"
[[ "$RUN_GEMINI" == "true" ]] && echo "  Gemini turns: ${GEMINI_MAX_TURNS} (GEMINI_MAX_TURNS)"
echo ""

# Helper: run a command with optional timeout
run_with_timeout() {
  if [[ -n "$TIMEOUT_CMD" ]]; then
    "$TIMEOUT_CMD" "$TIMEOUT_SECS" "$@"
  else
    "$@"
  fi
}

CODEX_PID=""
GEMINI_PID=""

# --- Invoke Codex (non-interactive, read-only sandbox) ---
if [[ "$RUN_CODEX" == "true" ]]; then
  (
    cd "$WORK_DIR"
    CODEX_ARGS=(exec --full-auto --sandbox read-only -o "$CODEX_OUT")
    if [[ -n "$CODEX_MODEL" ]]; then
      CODEX_ARGS+=(-m "$CODEX_MODEL")
    fi
    CODEX_ARGS+=("$PROMPT")
    run_with_timeout codex "${CODEX_ARGS[@]}" \
      2>"$CODEX_ERR" || {
        STATUS=$?
        echo "Codex invocation failed (exit $STATUS). See $CODEX_ERR" >&2
        echo "[Codex failed to respond. Check $CODEX_ERR for details.]" > "$CODEX_OUT"
        exit "$STATUS"
      }
  ) &
  CODEX_PID=$!
fi

# --- Invoke Gemini (non-interactive, plan/read-only mode with codebase access) ---
# Gemini runs via agy CLI. maxSessionTurns is temporarily injected into
# ~/.gemini/antigravity-cli/settings.json (configurable via GEMINI_MAX_TURNS, default 100).
if [[ "$RUN_GEMINI" == "true" ]]; then
  # Sanitize jsr: imports for Gemini to avoid safety/policy blocks
  GEMINI_PROMPT="$(echo "$PROMPT" | sed -E 's/jsr:[a-zA-Z0-9_@/.-]+/[jsr import redacted]/g')"

  # Save prompt to file for diagnostics (auto-cleaned with .council-tmp/)
  GEMINI_PROMPT_FILE="$TMPDIR_COUNCIL/gemini_prompt.txt"
  printf '%s' "$GEMINI_PROMPT" > "$GEMINI_PROMPT_FILE"

  # Temporarily inject settings to bound exploration.
  # We modify the real settings so Gemini's auth works normally.
  # Settings are restored via trap on EXIT/INT/TERM.
  GEMINI_SETTINGS="$HOME/.gemini/antigravity-cli/settings.json"
  GEMINI_SETTINGS_BACKUP=""
  if [[ -f "$GEMINI_SETTINGS" ]]; then
    GEMINI_SETTINGS_BACKUP="$TMPDIR_COUNCIL/gemini_settings_backup.json"
    cp "$GEMINI_SETTINGS" "$GEMINI_SETTINGS_BACKUP"
    python3 -c "
import json, sys
s = json.load(open(sys.argv[1]))
s['maxSessionTurns'] = int(sys.argv[2])
json.dump(s, open(sys.argv[1], 'w'), indent=2)
" "$GEMINI_SETTINGS" "$GEMINI_MAX_TURNS"
  else
    mkdir -p "$(dirname "$GEMINI_SETTINGS")"
    printf '{"maxSessionTurns":%d}' "$GEMINI_MAX_TURNS" > "$GEMINI_SETTINGS"
    GEMINI_SETTINGS_BACKUP="__CREATED__"
  fi

  # Ensure settings are restored even if the script is killed (Ctrl+C, SIGTERM, set -e abort)
  restore_gemini_settings() {
    if [[ -n "${GEMINI_SETTINGS_BACKUP:-}" ]]; then
      if [[ "$GEMINI_SETTINGS_BACKUP" == "__CREATED__" ]]; then
        rm -f "$GEMINI_SETTINGS"
      elif [[ -f "$GEMINI_SETTINGS_BACKUP" ]]; then
        cp "$GEMINI_SETTINGS_BACKUP" "$GEMINI_SETTINGS"
      fi
    fi
  }
  trap restore_gemini_settings EXIT

  (
    cd "$WORK_DIR" || exit 1
    run_with_timeout agy --print --add-dir "$WORK_DIR" --dangerously-skip-permissions "$GEMINI_PROMPT" < /dev/null \
      > "$GEMINI_OUT" \
      2>"$GEMINI_ERR" || {
        STATUS=$?
        echo "Gemini (agy) invocation failed (exit $STATUS). See $GEMINI_ERR" >&2
        echo "[Gemini failed to respond. Check $GEMINI_ERR for details.]" > "$GEMINI_OUT"
        exit "$STATUS"
      }

    # Auto-retry once on transient empty response (exit 0, no stdout, no stderr).
    if [[ ! -s "$GEMINI_OUT" && ! -s "$GEMINI_ERR" ]]; then
      echo "Gemini (agy) returned empty response with no errors — retrying once..." >&2
      run_with_timeout agy --print --add-dir "$WORK_DIR" --dangerously-skip-permissions "$GEMINI_PROMPT" < /dev/null \
        > "$GEMINI_OUT" \
        2>"$GEMINI_ERR" || {
          STATUS=$?
          echo "Gemini (agy) retry failed (exit $STATUS). See $GEMINI_ERR" >&2
          echo "[Gemini failed to respond on retry. Check $GEMINI_ERR for details.]" > "$GEMINI_OUT"
          exit "$STATUS"
        }
    fi
  ) &
  GEMINI_PID=$!
fi

# --- Wait for advisors ---
CODEX_STATUS=0
GEMINI_STATUS=0

if [[ -n "$CODEX_PID" ]]; then
  wait "$CODEX_PID" || CODEX_STATUS=$?
fi
if [[ -n "$GEMINI_PID" ]]; then
  wait "$GEMINI_PID" || GEMINI_STATUS=$?
fi

# Gemini settings are restored automatically via the EXIT trap set during injection.
# The trap handles normal exit, Ctrl+C (SIGINT), SIGTERM, and set -e aborts.

# --- Validate responses ---
CODEX_FAIL_REASON=""
GEMINI_FAIL_REASON=""

# Known failure patterns in error logs (exit code 0 but actual failure)
GEMINI_FAILURE_PATTERNS="unproductive state|Path not in workspace|exceeded maximum number of turns|RESOURCE_EXHAUSTED|rate limit|Maximum session turns exceeded|Loop detected, stopping execution|Agent execution blocked|Agent execution stopped|No input provided via stdin|Argument list too long|E2BIG|429|quota|safety|policy|blocked"
CODEX_FAILURE_PATTERNS="rate limit|context length|unauthorized|Argument list too long|E2BIG"

# Check Codex response
if [[ "$RUN_CODEX" == "true" && "$CODEX_STATUS" -eq 0 ]]; then
  if [[ ! -s "$CODEX_OUT" ]]; then
    CODEX_FAIL_REASON="empty response"
  fi

  # Check error log for known failure patterns
  if [[ -s "$CODEX_ERR" ]]; then
    MATCHED_PATTERN="$(grep -Eio "$CODEX_FAILURE_PATTERNS" "$CODEX_ERR" | head -1)" || true
    if [[ -n "$MATCHED_PATTERN" ]]; then
      CODEX_FAIL_REASON="${CODEX_FAIL_REASON:+${CODEX_FAIL_REASON}; }error log: $MATCHED_PATTERN"
    fi
  fi

  if [[ -n "$CODEX_FAIL_REASON" ]]; then
    CODEX_STATUS=1
    echo "Codex failed validation ($CODEX_FAIL_REASON). See $CODEX_ERR" >&2
    if [[ ! -s "$CODEX_OUT" ]]; then
      ERR_CONTENT=""
      [[ -s "$CODEX_ERR" ]] && ERR_CONTENT="$(tail -20 "$CODEX_ERR")"
      echo "[Codex failed ($CODEX_FAIL_REASON). Error log: ${ERR_CONTENT:-no errors captured}]" > "$CODEX_OUT"
    fi
  fi
fi

# Check Gemini response
if [[ "$RUN_GEMINI" == "true" && "$GEMINI_STATUS" -eq 0 ]]; then
  # Check for empty response
  if [[ ! -s "$GEMINI_OUT" ]]; then
    GEMINI_FAIL_REASON="empty response"
  fi

  # Check error log for known failure patterns (even with non-empty response)
  if [[ -s "$GEMINI_ERR" ]]; then
    MATCHED_PATTERN="$(grep -Eio "$GEMINI_FAILURE_PATTERNS" "$GEMINI_ERR" | head -1)" || true
    if [[ -n "$MATCHED_PATTERN" ]]; then
      GEMINI_FAIL_REASON="${GEMINI_FAIL_REASON:+${GEMINI_FAIL_REASON}; }error log: $MATCHED_PATTERN"
    fi
  fi

  # Check response file for known failure patterns
  if [[ -f "$GEMINI_OUT" ]]; then
    MATCHED_PATTERN="$(grep -Eio "$GEMINI_FAILURE_PATTERNS" "$GEMINI_OUT" | head -1)" || true
    if [[ -n "$MATCHED_PATTERN" ]]; then
      GEMINI_FAIL_REASON="${GEMINI_FAIL_REASON:+${GEMINI_FAIL_REASON}; }response: $MATCHED_PATTERN"
    fi
  fi

  if [[ -n "$GEMINI_FAIL_REASON" ]]; then
    GEMINI_STATUS=1
    echo "Gemini failed validation ($GEMINI_FAIL_REASON). See $GEMINI_ERR" >&2
    # Only overwrite if response was empty; keep partial response otherwise
    if [[ ! -s "$GEMINI_OUT" ]]; then
      ERR_CONTENT=""
      [[ -s "$GEMINI_ERR" ]] && ERR_CONTENT="$(tail -20 "$GEMINI_ERR")"
      echo "[Gemini failed ($GEMINI_FAIL_REASON). Error log: ${ERR_CONTENT:-no errors captured}]" > "$GEMINI_OUT"
    fi
  fi
fi

# --- Report results ---
echo ""
echo "Council responses ready:"
if [[ "$RUN_CODEX" == "true" ]]; then
  STATUS_MSG="(success)"
  [[ "$CODEX_STATUS" -ne 0 ]] && STATUS_MSG="(failed${CODEX_FAIL_REASON:+: $CODEX_FAIL_REASON})"
  echo "  Codex:  $CODEX_OUT $STATUS_MSG"
fi
if [[ "$RUN_GEMINI" == "true" ]]; then
  STATUS_MSG="(success)"
  [[ "$GEMINI_STATUS" -ne 0 ]] && STATUS_MSG="(failed${GEMINI_FAIL_REASON:+: $GEMINI_FAIL_REASON})"
  echo "  Gemini: $GEMINI_OUT $STATUS_MSG"
fi
echo ""

# Output the paths for the caller to read
if [[ "$RUN_CODEX" == "true" ]]; then
  echo "$CODEX_OUT"
fi
if [[ "$RUN_GEMINI" == "true" ]]; then
  echo "$GEMINI_OUT"
fi
