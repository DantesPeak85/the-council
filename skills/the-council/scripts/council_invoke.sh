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
#   AGY_PRINT_TIMEOUT — Override agy --print-timeout (default: 8m)
#                      agy's own 5m default can race with COUNCIL_TIMEOUT; 8m
#                      gives COUNCIL_TIMEOUT room to be the outer bound.

set -euo pipefail

# Locate this script's directory for finding co-located resources
# (e.g., council_sandbox.sb).
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SANDBOX_PROFILE="$SCRIPT_DIR/council_sandbox.sb"

# --- Resolve timeout command (macOS compatibility) ---
if command -v gtimeout &>/dev/null; then
  TIMEOUT_CMD="gtimeout"
elif command -v timeout &>/dev/null; then
  TIMEOUT_CMD="timeout"
else
  # Fallback: no timeout enforcement
  TIMEOUT_CMD=""
fi

### FUNCTIONS ###
# --- Test seam: allow tests to source function definitions only ---
# When COUNCIL_SOURCE_ONLY=1, the function definitions in this region load and
# the script returns at the seam (below, after the last function) BEFORE flag
# parsing / execution. Used by tests/test_snapshot_engine.sh etc. Later tasks
# ADD functions into this region (before the seam) without further top-level
# moves; execution code lives after the ### EXECUTION ### marker. Functions must
# not reference globals defined below the seam except via ${VAR:-default} guards
# (the tests source with a bare environment).

# --- Worktree snapshot engine (v1.4.0) ---
# Change-detection fingerprint of $WORK_DIR. Design (supersedes 1.3.0):
#   * Tracked + untracked-non-ignored files: content-hashed (sha256), BATCHED
#     through a single xargs pipeline — never one shell per file, never
#     re-parsed through `sh -c` (apostrophe-safe; PR #2 superseded).
#   * Gitignored files: recorded at NAME+SIZE level only via
#     `git status --ignored` — a NEW ignored file (.env class) or a size
#     change is detected without content-hashing gigabytes of node_modules
#     (the 1.3GB Lisah harness-timeout root cause; PR #3 superseded).
#   * Excludes: built-in churn paths + COUNCIL_SNAPSHOT_EXCLUDES env var
#     (comma-separated pathspecs).
BUILTIN_EXCLUDES=".council-tmp/**,.antigravitycli/**,.remember/**,.tmp.driveupload/**,**/*.driveupload"

# stat flavor: BSD (macOS) vs GNU — resolved once; used by the ignored-file
# name+size listing. An inline `xargs statA || xargs statB` fallback is
# broken (first xargs consumes stdin), so we probe here instead.
if stat -f '%z' . &>/dev/null; then
  STAT_ARGS=(-f '%z %N')     # BSD/macOS
else
  STAT_ARGS=(-c '%s %n')     # GNU/Linux
fi

build_exclude_pathspecs() {
  # Emits one ':(exclude)<glob>' per line for git commands.
  # Council R1: split with `read -ra`, NOT `for x in $unquoted` — the latter
  # pathname-expands globs like `.council-tmp/**` against the caller's cwd.
  local all="${BUILTIN_EXCLUDES}"
  if [[ -n "${COUNCIL_SNAPSHOT_EXCLUDES:-}" ]]; then
    all="${all},${COUNCIL_SNAPSHOT_EXCLUDES}"
  fi
  local globs=()
  IFS=',' read -ra globs <<< "$all"
  local glob
  for glob in "${globs[@]}"; do
    [[ -n "$glob" ]] && printf ':(exclude)%s\n' "$glob"
  done
}

snapshot_worktree() {
  local dir="$1"
  local out_file="$2"
  local excludes=()
  while IFS= read -r line; do excludes+=("$line"); done < <(build_exclude_pathspecs)

  if git -C "$dir" rev-parse --is-inside-work-tree &>/dev/null; then
    {
      echo "MODE=git"
      git -C "$dir" rev-parse HEAD 2>/dev/null || echo "HEAD=none"
      # Name-level state: tracked/untracked/ignored, minus excludes.
      git -C "$dir" status --porcelain=v1 --untracked-files=all --ignored=traditional \
        -- "${excludes[@]}" || true
      # Content hashes: tracked + untracked-NON-ignored only, batched.
      # `|| true` guards: a file vanishing mid-hash (live repo) must degrade
      # the snapshot, not abort the whole council run under set -e.
      git -C "$dir" ls-files --cached --others --exclude-standard -z \
        -- "${excludes[@]}" 2>/dev/null \
        | ( cd "$dir" && xargs -0 sha256sum -- 2>/dev/null || true ) \
        | LC_ALL=C sort
      # Ignored files: name + size by default (no content hash) — new/removed/
      # grown ignored files trip the diff. SECURITY LIMITATION (Council R1):
      # a same-size in-place rewrite of an ignored file is invisible in this
      # mode. When agy runs UNSANDBOXED (--allow-unsandboxed-gemini), the
      # snapshot is the ONLY protection, so COUNCIL_SNAPSHOT_PARANOID=1 (set
      # automatically in that mode) switches to full content-hashing of
      # ignored files — slow but airtight.
      # STAT_ARGS resolved ONCE at startup — an `xargs A || xargs B` fallback
      # chain is broken because the first xargs consumes stdin (verified live
      # 2026-07-11).
      echo "-- IGNORED --"
      if [[ "${COUNCIL_SNAPSHOT_PARANOID:-}" == "1" ]]; then
        git -C "$dir" ls-files --others --ignored --exclude-standard -z \
          -- "${excludes[@]}" 2>/dev/null \
          | ( cd "$dir" && xargs -0 sha256sum -- 2>/dev/null || true ) \
          | LC_ALL=C sort
      else
        git -C "$dir" ls-files --others --ignored --exclude-standard -z \
          -- "${excludes[@]}" 2>/dev/null \
          | ( cd "$dir" && xargs -0 stat "${STAT_ARGS[@]}" -- 2>/dev/null || true ) \
          | LC_ALL=C sort
      fi
    } > "$out_file"
  else
    {
      echo "MODE=find"
      # Non-git fallback: batched hashing. Council R1: apply BOTH built-in and
      # env-var excludes here too (glob → find -path translation: strip a
      # trailing '/**', then '-not -path "*/<base>/*" -not -path "*/<base>"').
      local find_excludes=(-not -path '*/.git/*')
      local g base
      while IFS= read -r g; do
        g="${g#:(exclude)}"
        base="${g%/\*\*}"
        find_excludes+=(-not -path "*/${base}/*" -not -path "*/${base}")
      done < <(build_exclude_pathspecs)
      find "$dir" -type f "${find_excludes[@]}" -print0 2>/dev/null \
        | xargs -0 sha256sum -- 2>/dev/null \
        | LC_ALL=C sort || true
    } > "$out_file"
  fi
}

diff_worktree() {
  local before="$1"
  local after="$2"
  diff "$before" "$after"
}

# Helper: run a command with timeout enforcement.
# gtimeout/timeout are not guaranteed on macOS (stock macOS has neither).
# When absent, fall back to a pure-bash watchdog: background the command,
# TERM it after $TIMEOUT_SECS (KILL 5s later), report exit 124 like timeout(1).
# Known limitation: the watchdog TERMs the direct child only; `script` and
# `codex` both propagate death to their process trees (pty HUP / child reap).
run_with_timeout() {
  if [[ -n "$TIMEOUT_CMD" ]]; then
    "$TIMEOUT_CMD" "$TIMEOUT_SECS" "$@"
    return $?
  fi
  # `0<&0` explicitly dups the inherited stdin onto the async command. Without
  # it, bash redirects a backgrounded command's stdin from /dev/null "in the
  # absence of any explicit redirections" — which would starve `codex -` of the
  # prompt fed via `run_with_timeout codex ... < "$PROMPT_FILE_FINAL"`.
  "$@" 0<&0 &
  local cmd_pid=$!
  (
    sleep "$TIMEOUT_SECS" || exit 0
    kill -TERM "$cmd_pid" 2>/dev/null || true
    sleep 5
    kill -KILL "$cmd_pid" 2>/dev/null || true
  ) &
  local watchdog_pid=$!
  local status=0
  wait "$cmd_pid" || status=$?
  if kill -0 "$watchdog_pid" 2>/dev/null; then
    # Command finished first — retire the watchdog (its pending sleep exits harmlessly).
    kill "$watchdog_pid" 2>/dev/null || true
    wait "$watchdog_pid" 2>/dev/null || true
  else
    # Watchdog already fired: normalize TERM/KILL deaths to timeout(1)'s 124.
    if [[ "$status" -eq 143 || "$status" -eq 137 ]]; then
      status=124
    fi
  fi
  return "$status"
}

# Helper: run agy under a deny-write sandbox profile (macOS sandbox-exec).
# Mirrors Codex's OS-level read-only model. Falls back to unsandboxed only
# when --allow-unsandboxed-gemini was passed (Council R1: don't silently
# run unsandboxed on non-macOS).
#
# Council R1: all -D parameters are asserted non-empty here; an empty
# value would cause sandbox-exec to fail with a confusing parse error.
run_agy_sandboxed() {
  # --allow-unsandboxed-gemini forces unsandboxed even on macOS (useful for
  # exercising the diff safety net in isolation, or for environments where
  # the sandbox profile would need further tuning).
  if [[ "$ALLOW_UNSANDBOXED_GEMINI" == "true" ]]; then
    echo "WARNING: agy running UNSANDBOXED per --allow-unsandboxed-gemini." >&2
    echo "         Phase A diff safety net is the only protection against ghost-writes." >&2
    run_with_timeout agy "$@"
    return $?
  fi
  if command -v sandbox-exec &>/dev/null && [[ -f "$SANDBOX_PROFILE" ]]; then
    local home_gemini="$HOME/.gemini"
    local home_caches="$HOME/Library/Caches"
    local sys_tmp="/tmp"
    local sys_private_tmp="/private/tmp"
    local sys_var_folders="/private/var/folders"
    # Assert all sandbox -D params are non-empty.
    for var in home_gemini TMPDIR_COUNCIL home_caches sys_tmp sys_private_tmp sys_var_folders; do
      if [[ -z "${!var:-}" ]]; then
        echo "ERROR: sandbox-exec parameter '$var' is empty; refusing to invoke agy unsandboxed." >&2
        return 1
      fi
    done
    run_with_timeout sandbox-exec -f "$SANDBOX_PROFILE" \
      -D HOME_GEMINI="$home_gemini" \
      -D TMPDIR_COUNCIL="$TMPDIR_COUNCIL" \
      -D HOME_LIBRARY_CACHES="$home_caches" \
      -D SYS_TMP="$sys_tmp" \
      -D SYS_PRIVATE_TMP="$sys_private_tmp" \
      -D SYS_VAR_FOLDERS="$sys_var_folders" \
      agy "$@"
  else
    echo "ERROR: sandbox-exec not found (non-macOS or missing profile)." >&2
    echo "       agy 1.0.2 has no native read-only mode; running unsandboxed risks" >&2
    echo "       the 2026-05-24 ghost-write incident pattern." >&2
    echo "       Pass --allow-unsandboxed-gemini to override (relies on Phase A diff check only)," >&2
    echo "       or use --codex-only to skip the Gemini advisor entirely." >&2
    return 1
  fi
}

# Test seam (must come AFTER function definitions, BEFORE flag parsing).
if [[ "${COUNCIL_SOURCE_ONLY:-}" == "1" ]]; then
  return 0 2>/dev/null || exit 0
fi

### EXECUTION ###

# --- Parse flags ---
RUN_CODEX=true
RUN_GEMINI=true
CONTEXT_FILE=""
ALLOW_UNSANDBOXED_GEMINI=false

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
    --allow-unsandboxed-gemini)
      # Council R1: on non-macOS (no sandbox-exec), refuse to run agy unless
      # the caller explicitly accepts the risk via this flag. The Phase A
      # diff safety net is still the backstop in that mode.
      ALLOW_UNSANDBOXED_GEMINI=true
      shift
      ;;
    *)
      echo "ERROR: Unknown flag: $1" >&2
      exit 1
      ;;
  esac
done

# --- Load nvm/node environment if needed (CLIs installed via npm) ---
export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
if [[ -s "$NVM_DIR/nvm.sh" ]]; then
  source "$NVM_DIR/nvm.sh" --no-use 2>/dev/null
  # Ensure the default node version's bin is in PATH
  NODE_BIN="$(nvm which default 2>/dev/null | xargs dirname 2>/dev/null)" || true
  if [[ -n "$NODE_BIN" && -d "$NODE_BIN" ]]; then
    # Append (not prepend): make npm-global CLIs findable as a fallback WITHOUT
    # shadowing a codex/agy the caller deliberately placed earlier in PATH
    # (e.g. a test fake). Prepending here silently overrode the caller's PATH.
    export PATH="$PATH:$NODE_BIN"
  fi
fi

PROMPT_FILE="${1:?Usage: council_invoke.sh [--codex-only|--gemini-only] <prompt_file> [working_directory]}"
WORK_DIR="${2:-.}"
WORK_DIR="$(cd "$WORK_DIR" && pwd)"

CODEX_MODEL="${CODEX_MODEL:-}"
COUNCIL_CODEX_EFFORT="${COUNCIL_CODEX_EFFORT:-xhigh}"
TIMEOUT_SECS="${COUNCIL_TIMEOUT:-600}"
AGY_PRINT_TIMEOUT="${AGY_PRINT_TIMEOUT:-8m}"
COUNCIL_GEMINI_BACKEND="${COUNCIL_GEMINI_BACKEND:-auto}"
COUNCIL_GEMINI_MODEL="${COUNCIL_GEMINI_MODEL:-}"
# GEMINI_MODEL / GEMINI_MAX_TURNS are retained here (not in the v1.4.0 defaults
# block above) because the Gemini lane rewrite lands in a later task; the
# current agy lane still references both, so removing them now breaks set -u.
GEMINI_MODEL="${GEMINI_MODEL:-}"
GEMINI_MAX_TURNS="${GEMINI_MAX_TURNS:-100}"

# Resolve display names for models (show user what's actually being used)
if [[ -n "$CODEX_MODEL" ]]; then
  CODEX_MODEL_DISPLAY="$CODEX_MODEL"
else
  CODEX_MODEL_DISPLAY="$(grep -E '^model[[:space:]]*=' "${HOME}/.codex/config.toml" 2>/dev/null | head -1 | sed 's/model *= *"\(.*\)"/\1/')"
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

# Final composed prompt lives in a file; both lanes feed it via file I/O,
# never argv (ARG_MAX) and never an open pipe (codex stdin-hang #27019).
# $PROMPT is fully composed above (prompt file + optional --context-file append)
# before this point, so the file captures the complete final prompt.
PROMPT_FILE_FINAL="$TMPDIR_COUNCIL/prompt_final.txt"
printf '%s' "$PROMPT" > "$PROMPT_FILE_FINAL"

CODEX_OUT="$TMPDIR_COUNCIL/codex_response.md"
GEMINI_OUT="$TMPDIR_COUNCIL/gemini_response.md"
CODEX_ERR="$TMPDIR_COUNCIL/codex_error.log"
GEMINI_ERR="$TMPDIR_COUNCIL/gemini_error.log"

# --- Phase A safety net: snapshot $WORK_DIR BEFORE invocation ---
WORKTREE_SNAPSHOT_BEFORE="$TMPDIR_COUNCIL/worktree_snapshot_before.txt"
snapshot_worktree "$WORK_DIR" "$WORKTREE_SNAPSHOT_BEFORE"

# Determine mode label
if [[ "$RUN_CODEX" == "true" && "$RUN_GEMINI" == "true" ]]; then
  MODE="Full Council"
elif [[ "$RUN_CODEX" == "true" ]]; then
  MODE="Codex-only"
else
  MODE="Gemini-only"
fi

# Capture CLI versions for the banner (1.3.0+: forensic continuity per
# Council R1). Lightweight — these are direct CLI calls, not preflight cache.
CODEX_VERSION_DISPLAY=""
AGY_VERSION_DISPLAY=""
[[ "$RUN_CODEX" == "true" ]] && CODEX_VERSION_DISPLAY="$(codex --version 2>/dev/null | head -1 | tr -d '\r' || true)"
[[ "$RUN_GEMINI" == "true" ]] && AGY_VERSION_DISPLAY="$(agy --version 2>/dev/null | head -1 | tr -d '\r' || true)"

echo "Invoking The Council ($MODE)..."
[[ "$RUN_CODEX" == "true" ]] && echo "  Codex model:  $CODEX_MODEL_DISPLAY"
[[ "$RUN_CODEX" == "true" ]] && echo "  Codex effort: ${COUNCIL_CODEX_EFFORT} (COUNCIL_CODEX_EFFORT)"
[[ "$RUN_CODEX" == "true" ]] && echo "  Codex CLI:    ${CODEX_VERSION_DISPLAY:-unknown}"
[[ "$RUN_GEMINI" == "true" ]] && echo "  Gemini model: $GEMINI_MODEL_DISPLAY"
[[ "$RUN_GEMINI" == "true" ]] && echo "  agy CLI:      ${AGY_VERSION_DISPLAY:-unknown}"
echo "  Working dir:  $WORK_DIR"
echo "  Timeout:      ${TIMEOUT_SECS}s ($([[ -n "$TIMEOUT_CMD" ]] && echo "$TIMEOUT_CMD" || echo "bash watchdog"))"
[[ "$RUN_GEMINI" == "true" ]] && echo "  Gemini turns: ${GEMINI_MAX_TURNS} (GEMINI_MAX_TURNS)"
[[ "$RUN_GEMINI" == "true" ]] && echo "  Agy timeout:  ${AGY_PRINT_TIMEOUT} (AGY_PRINT_TIMEOUT)"
if [[ "$RUN_GEMINI" == "true" ]]; then
  if command -v sandbox-exec &>/dev/null && [[ -f "$SANDBOX_PROFILE" ]] && [[ "$ALLOW_UNSANDBOXED_GEMINI" != "true" ]]; then
    echo "  agy isolation: sandbox-exec (OS-level deny-write)"
  elif [[ "$ALLOW_UNSANDBOXED_GEMINI" == "true" ]]; then
    echo "  agy isolation: UNSANDBOXED (--allow-unsandboxed-gemini); diff check is the only protection"
  fi
fi
echo ""

CODEX_PID=""
GEMINI_PID=""

# --- Invoke Codex (non-interactive, read-only, never-approve) ---
# Prompt via stdin-from-file (`-`): kills ARG_MAX (E2BIG) on large diffs AND
# the codex-exec stdin-hang (openai/codex #27019) — stdin gets EOF at file end.
# --full-auto removed: deprecated hidden alias (workspace-write + on-failure
# approval) that contradicted --sandbox read-only and could pause headless runs.
if [[ "$RUN_CODEX" == "true" ]]; then
  (
    cd "$WORK_DIR"
    CODEX_ARGS=(exec --sandbox read-only -c approval_policy=never -o "$CODEX_OUT")
    if [[ -n "$CODEX_MODEL" ]]; then
      CODEX_ARGS+=(-m "$CODEX_MODEL")
    fi
    # Reasoning effort: explicit by default (config.toml ships "medium" which
    # silently under-powers reviews). COUNCIL_CODEX_EFFORT=config defers to config.
    if [[ "$COUNCIL_CODEX_EFFORT" != "config" ]]; then
      CODEX_ARGS+=(-c "model_reasoning_effort=${COUNCIL_CODEX_EFFORT}")
    fi
    CODEX_ARGS+=(-)
    run_with_timeout codex "${CODEX_ARGS[@]}" \
      < "$PROMPT_FILE_FINAL" \
      2>"$CODEX_ERR" || {
        STATUS=$?
        if [[ "$STATUS" -eq 124 ]]; then
          echo "Codex timed out after ${TIMEOUT_SECS}s (COUNCIL_TIMEOUT). See $CODEX_ERR" >&2
          echo "[COUNCIL-ADVISOR-FAILURE] Codex timed out (COUNCIL_TIMEOUT=${TIMEOUT_SECS}s). Raise COUNCIL_TIMEOUT for xhigh/large-diff reviews." > "$CODEX_OUT"
        else
          echo "Codex invocation failed (exit $STATUS). See $CODEX_ERR" >&2
          echo "[COUNCIL-ADVISOR-FAILURE] Codex failed to respond (exit $STATUS). See $CODEX_ERR." > "$CODEX_OUT"
        fi
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
    # Pipe prompt via stdin and wrap agy in an OS-level deny-write sandbox.
    # The previous belief that --print + --dangerously-skip-permissions made
    # agy read-only was wrong (--dangerously-skip-permissions is auto-approve);
    # the 2026-05-24 incident proved it. Now agy is wrapped in sandbox-exec
    # (council_sandbox.sb) so write attempts inside $WORK_DIR fail at the OS
    # layer, mirroring Codex's --sandbox read-only.
    run_agy_sandboxed --print --add-dir "$WORK_DIR" --dangerously-skip-permissions \
      --print-timeout "$AGY_PRINT_TIMEOUT" \
      < "$GEMINI_PROMPT_FILE" \
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
      run_agy_sandboxed --print --add-dir "$WORK_DIR" --dangerously-skip-permissions \
        --print-timeout "$AGY_PRINT_TIMEOUT" \
        < "$GEMINI_PROMPT_FILE" \
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

# Phrases agy emits when it didn't engage with the prompt (scratch-workspace
# meta-chatter, "ready to help" boilerplate, asking for the prompt back, etc.)
GEMINI_NON_ENGAGEMENT_PATTERNS="I am ready to help|scratch workspace directory|default workspace directory set to|please let me know what you would like to build|provide the path|/goal slash command|specified in the chat|empty except for a \`test_write.txt\`"

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

  # Non-engagement heuristic: on prompts > 2KB, agy should produce a substantive
  # response. If exit 0 + non-empty $GEMINI_OUT but (very short OR matches a
  # non-engagement phrase), treat as silent failure (see 2026-05-24 bug report).
  if [[ -z "$GEMINI_FAIL_REASON" && -s "$GEMINI_OUT" ]]; then
    PROMPT_SIZE=$(wc -c < "$GEMINI_PROMPT_FILE" 2>/dev/null || echo 0)
    RESPONSE_SIZE=$(wc -c < "$GEMINI_OUT" 2>/dev/null || echo 0)
    if [[ "$PROMPT_SIZE" -gt 2048 ]]; then
      if [[ "$RESPONSE_SIZE" -lt 200 ]]; then
        GEMINI_FAIL_REASON="non-engagement: ${RESPONSE_SIZE}-char response on ${PROMPT_SIZE}-byte prompt"
      else
        META_MATCH="$(grep -Eio "$GEMINI_NON_ENGAGEMENT_PATTERNS" "$GEMINI_OUT" | head -1)" || true
        if [[ -n "$META_MATCH" ]]; then
          GEMINI_FAIL_REASON="non-engagement: $META_MATCH"
        fi
      fi
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

# --- Phase A safety net: snapshot $WORK_DIR AFTER invocation and diff ---
# Fails closed (exit 2) on any unauthorized worktree change. The diff
# excludes .council-tmp/ (where response files legitimately land); any
# other change in $WORK_DIR — including writes to gitignored files like
# .env, dist/, node_modules/ — trips this guard.
WORKTREE_SNAPSHOT_AFTER="$TMPDIR_COUNCIL/worktree_snapshot_after.txt"
snapshot_worktree "$WORK_DIR" "$WORKTREE_SNAPSHOT_AFTER"
if ! diff_worktree "$WORKTREE_SNAPSHOT_BEFORE" "$WORKTREE_SNAPSHOT_AFTER" \
     > "$TMPDIR_COUNCIL/worktree_diff.txt" 2>&1; then
  cat >&2 <<EOF

=====================================================================
[COUNCIL_SAFETY_NET] UNAUTHORIZED WORKTREE CHANGES DETECTED

Files in $WORK_DIR changed during the advisory invocation. This is
either an advisor sandbox escape, or genuine concurrent work by you
or another process during the council run.

Diff:   $TMPDIR_COUNCIL/worktree_diff.txt
Before: $WORKTREE_SNAPSHOT_BEFORE
After:  $WORKTREE_SNAPSHOT_AFTER

Advisor responses (still readable):
  Codex:  $CODEX_OUT
  Gemini: $GEMINI_OUT

Review the diff carefully before integrating any advisor recommendations.
=====================================================================

EOF
  exit 2
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
