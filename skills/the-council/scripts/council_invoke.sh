#!/usr/bin/env bash
# council_invoke.sh — Invoke Codex, Gemini and optional OpenRouter seats in parallel, capture responses
#
# Usage: council_invoke.sh [--codex-only|--gemini-only|--openrouter-only] [--openrouter <seats>] [--context-file <path>] <prompt_file> [working_directory]
#   --codex-only:         Only invoke Codex (skip Gemini)
#   --gemini-only:        Only invoke Gemini (skip Codex)
#   --openrouter <seats>: Add OpenRouter seats — comma list of qwen | glm | vendor/model (v1.6.0)
#   --openrouter-only:    Skip Codex AND Gemini; run only the OpenRouter seats
#   --context-file <path>: Append contents of this file to the prompt (for retry context)
#   prompt_file:          Path to a text file containing the advisory prompt
#   working_directory:    defaults to current directory
#
# Outputs: Paths to response files (one per line, last lines of stdout)
#   Full mode:   codex response path, then gemini response path, then one per OpenRouter seat
#   Single mode: only the active advisor's response path
#
# Environment:
#   CODEX_MODEL    — Override Codex model (default: auto, from ~/.codex/config.toml)
#   COUNCIL_GEMINI_MODEL — Override Gemini model passed to agy --model (default: agy's own)
#   COUNCIL_OPENROUTER_SEATS — Same as --openrouter (flag wins). Needs OPENROUTER_API_KEY.
#   COUNCIL_OPENROUTER_EFFORT — reasoning effort for OpenRouter seats (default: COUNCIL_CODEX_EFFORT; `none` omits it)
#   COUNCIL_OPENROUTER_MAX_TOKENS — default 32000 (Qwen starves below ~32k)
#   COUNCIL_QWEN_MODEL / COUNCIL_GLM_MODEL — explicit id for a named seat (skips the live-listing lookup)
#   OPENROUTER_MODELS_URL / OPENROUTER_URL — endpoint overrides (tests)
#   COUNCIL_TIMEOUT  — Max seconds to wait per advisor (default: 600)
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
  # Timeout classification is signaled OUT-OF-BAND via a sentinel file the
  # watchdog touches BEFORE sending TERM. Watchdog liveness (`kill -0`) is NOT
  # a valid signal: a TERM-respecting command (codex dies promptly) is reaped
  # by `wait` while the watchdog is still inside its 5s grace `sleep`, so the
  # watchdog looks alive on the timeout path and 143 would never become 124.
  # Sentinel from mktemp, NOT $TMPDIR_COUNCIL — this helper must also work
  # before that dir exists.
  local fired_sentinel
  fired_sentinel="$(mktemp "${TMPDIR:-/tmp}/council_watchdog_fired.XXXXXX")"
  rm -f "$fired_sentinel"   # existence == "watchdog fired"; mktemp only reserved the name
  # `0<&0` explicitly dups the inherited stdin onto the async command. Without
  # it, bash redirects a backgrounded command's stdin from /dev/null "in the
  # absence of any explicit redirections" — which would starve `codex -` of the
  # prompt fed via `run_with_timeout codex ... < "$PROMPT_FILE_FINAL"`.
  "$@" 0<&0 &
  local cmd_pid=$!
  (
    sleep "$TIMEOUT_SECS" || exit 0
    touch "$fired_sentinel"
    kill -TERM "$cmd_pid" 2>/dev/null || true
    sleep 5
    kill -KILL "$cmd_pid" 2>/dev/null || true
  ) &
  local watchdog_pid=$!
  local status=0
  wait "$cmd_pid" || status=$?
  # Retire the watchdog: kill its sleep child FIRST (pkill -P finds children
  # by parent pid; killing the watchdog first would reparent the sleep, leaving
  # an orphaned full-$TIMEOUT_SECS sleep after every successful run), then the
  # watchdog itself. Both no-op harmlessly when the watchdog already exited.
  pkill -P "$watchdog_pid" 2>/dev/null || true
  kill "$watchdog_pid" 2>/dev/null || true
  wait "$watchdog_pid" 2>/dev/null || true
  if [[ -e "$fired_sentinel" ]]; then
    rm -f "$fired_sentinel"
    # Normalize TERM/KILL deaths to timeout(1)'s 124 ONLY when the watchdog
    # fired — a command that legitimately exits 143/137 without a fired
    # watchdog must NOT be misclassified as a timeout.
    if [[ "$status" -eq 143 || "$status" -eq 137 ]]; then
      status=124
    fi
  fi
  return "$status"
}

# Strip terminal artifacts from pty-captured output. Verified live 2026-07-11:
# `script -q` leaks ^D + backspaces before child output. Council R1: also
# cover OSC terminated by ESC-backslash, DCS sequences, and multi-byte CSI.
# Order matters: escape SEQUENCES first (sed), then residual raw control
# bytes (tr). Keep \t (\011) and \n (\012).
# The macOS `script -q /dev/null` startup emits the LITERAL two-char string
# `^D` (0x5E 0x44) followed by backspaces (0x08). The tr below deletes the
# backspaces but leaves the printable `^D` orphaned at the very start — which
# then prefixes the advisor's first line (e.g. `^DVERDICT:`) and defeats the
# validation engine's normalized-verdict-line detection. The final, line-1-only
# `1s///` erases that exact leading artifact AFTER the ESC strips have run, so a
# preceding ESC reset can't hide it. No-op when the artifact is absent.
strip_pty_artifacts() {
  sed -E $'s/\x1B\\[[0-9;:?<=>]*[ -\\/]*[@-~]//g; s/\x1B\\][^\x07\x1B]*(\x07|\x1B\\\\)//g; s/\x1BP[^\x1B]*\x1B\\\\//g; s/\x1B[@-Z\\\\^_]//g; 1s/^\\^D\x08*//' \
    | tr -d '\r\000-\010\013\014\016-\037\177'
}

# agy backend: pty-wrapped print mode.
# WHY pty: agy -p silently drops stdout when stdout is not a TTY (upstream
# issue #76) — exactly what a `> file` redirect creates. macOS `script -q
# /dev/null cmd...` allocates a pty; output is captured from the pty master.
invoke_gemini_agy() {
  local raw_out="$TMPDIR_COUNCIL/gemini_raw_pty.out"
  local driver_prompt="Read the file review_request.md in your workspace directory and respond to it fully. Output ONLY your review — no preamble about the workspace. Start your response with a VERDICT: line."
  local agy_args=(--print --add-dir "$TMPDIR_COUNCIL"
                  --dangerously-skip-permissions
                  --print-timeout "$AGY_PRINT_TIMEOUT"
                  --prompt "$driver_prompt")
  if [[ -n "$COUNCIL_GEMINI_MODEL" ]]; then
    agy_args=(--model "$COUNCIL_GEMINI_MODEL" "${agy_args[@]}")
  fi

  run_agy_pty "${agy_args[@]}" < /dev/null > "$raw_out" 2>"$GEMINI_ERR" || {
    local status=$?
    strip_pty_artifacts < "$raw_out" > "$GEMINI_OUT" || true
    if [[ "$status" -eq 124 ]]; then
      echo "Gemini (agy) timed out after ${TIMEOUT_SECS}s (COUNCIL_TIMEOUT)." >&2
      [[ -s "$GEMINI_OUT" ]] || echo "[COUNCIL-ADVISOR-FAILURE] Gemini (agy) timed out (COUNCIL_TIMEOUT=${TIMEOUT_SECS}s)." > "$GEMINI_OUT"
    else
      echo "Gemini (agy) invocation failed (exit $status). See $GEMINI_ERR" >&2
      [[ -s "$GEMINI_OUT" ]] || echo "[COUNCIL-ADVISOR-FAILURE] Gemini failed to respond (exit $status). See $GEMINI_ERR." > "$GEMINI_OUT"
    fi
    return "$status"
  }
  strip_pty_artifacts < "$raw_out" > "$GEMINI_OUT"

  # One belt-and-braces retry on truly-empty output.
  if [[ ! -s "$GEMINI_OUT" && ! -s "$GEMINI_ERR" ]]; then
    echo "Gemini (agy) returned empty response — retrying once..." >&2
    run_agy_pty "${agy_args[@]}" < /dev/null > "$raw_out" 2>"$GEMINI_ERR" || true
    strip_pty_artifacts < "$raw_out" > "$GEMINI_OUT" || true
  fi

  # Derail gate (live 2026-07-11: agy 1.1.1 answered questions about its own
  # CLI flags instead of the review on 4/4 runs; sub-2KB prompts slipped past
  # the non-engagement gate because it only applies to large prompts). The
  # driver prompt demands a VERDICT: line — enforce it universally for agy.
  # Placed AFTER the empty-retry so a retry gets its chance; it gates the
  # retry's output too. ${VERDICT_LINE:?} fails loudly if the constant is
  # unset — an empty regex matches everything and would silently disarm this.
  if [[ -s "$GEMINI_OUT" ]] && ! head -n "$VERDICT_HEAD_LINES" "$GEMINI_OUT" | grep -Eiq "${VERDICT_LINE:?}"; then
    cp "$GEMINI_OUT" "$TMPDIR_COUNCIL/gemini_derailed.txt"
    echo "Gemini (agy) derailed — no VERDICT line; original preserved to gemini_derailed.txt" >&2
    echo "[COUNCIL-ADVISOR-FAILURE] Gemini (agy) derailed — response has no VERDICT line (agy print-mode task-focus bug; see gemini_derailed.txt). Known agy 1.1.1 issue — consider COUNCIL_GEMINI_BACKEND=gemini with a GEMINI_API_KEY." > "$GEMINI_OUT"
    return 1
  fi
}

# pty wrapper around the (sandboxed) agy call.
# `script -q /dev/null <cmd>` runs <cmd> with stdout attached to a pty. The
# sandbox wrapper goes INSIDE the pty so agy sees the pty (BSD `script`
# propagates the child's exit code — Codex-verified with an exit-7 probe).
# Merged-stream caveat (Council R1): the pty merges agy's stdout AND stderr into
# the capture, so $GEMINI_ERR holds only wrapper/launch errors, not agy
# diagnostics; error forensics happen on the (stripped) raw capture.
run_agy_pty() {
  if [[ "$ALLOW_UNSANDBOXED_GEMINI" == "true" ]]; then
    echo "WARNING: agy running UNSANDBOXED per --allow-unsandboxed-gemini." >&2
    run_with_timeout script -q /dev/null agy "$@"
    return $?
  fi
  if command -v sandbox-exec &>/dev/null && [[ -f "$SANDBOX_PROFILE" ]]; then
    local home_gemini="$HOME/.gemini"
    local home_caches="$HOME/Library/Caches"
    local sys_tmp="/tmp"
    local sys_private_tmp="/private/tmp"
    local sys_var_folders="/private/var/folders"
    local var
    for var in home_gemini TMPDIR_COUNCIL home_caches sys_tmp sys_private_tmp sys_var_folders; do
      if [[ -z "${!var:-}" ]]; then
        echo "ERROR: sandbox-exec parameter '$var' is empty; refusing to run agy." >&2
        return 1
      fi
    done
    run_with_timeout script -q /dev/null sandbox-exec -f "$SANDBOX_PROFILE" \
      -D HOME_GEMINI="$home_gemini" \
      -D TMPDIR_COUNCIL="$TMPDIR_COUNCIL" \
      -D HOME_LIBRARY_CACHES="$home_caches" \
      -D SYS_TMP="$sys_tmp" \
      -D SYS_PRIVATE_TMP="$sys_private_tmp" \
      -D SYS_VAR_FOLDERS="$sys_var_folders" \
      agy "$@"
  else
    echo "ERROR: sandbox-exec not found (non-macOS or missing profile)." >&2
    echo "       Pass --allow-unsandboxed-gemini to override, or use --codex-only." >&2
    return 1
  fi
}

# gemini-cli backend: purpose-built headless mode. Preferred when a paid
# Gemini key exists — GEMINI_API_KEY or GOOGLE_API_KEY (oauth-personal stopped
# serving 2026-06-18). Response is the documented JSON envelope
# {response, stats, error}, extracted from the pty capture.
#
# Live-debugging findings (2026-07-11) that shaped this lane — do not undo:
#   * gemini-cli HANGS when backgrounded without a pty in agent-harness
#     contexts (same Node-CLI class as the codex run_in_background hang and
#     agy issue #76) → it runs under `script -q` like agy.
#   * A pty ECHOES stdin into the capture, so the request CANNOT travel via
#     stdin any more → it is placed in the workspace dir and referenced with
#     gemini's client-side `@file` expansion (no ARG_MAX, no echo).
#   * gemini-cli exits 55 from an untrusted cwd → GEMINI_CLI_TRUST_WORKSPACE.
#   * gemini-cli treats cwd as its workspace and crawls it → cwd is a
#     dedicated subdir holding ONLY the request file.
#   * The sandbox needed /dev/null writes + tty ioctl (setRawMode) allowed —
#     see council_sandbox.sb.
# Enforcement layers (Council R1): `--approval-mode default` (headless =
# unapprovable tool calls fail), sandbox-exec deny-write, minimal workspace.
# All failure placeholders carry the [COUNCIL-ADVISOR-FAILURE] prefix.
invoke_gemini_cli() {
  local raw_pty="$TMPDIR_COUNCIL/gemini_cli_raw_pty.out"
  # Workspace: a dedicated subdir holding only the request file.
  local gemini_ws="$TMPDIR_COUNCIL/gemini_ws"
  mkdir -p "$gemini_ws"
  cp "$GEMINI_REQUEST_FILE" "$gemini_ws/review_request.md"
  local gemini_args=(-p "@review_request.md Respond fully to the review request in that file. Start your response with a VERDICT: line." --output-format json --approval-mode default)
  if [[ -n "$COUNCIL_GEMINI_MODEL" ]]; then
    gemini_args+=(-m "$COUNCIL_GEMINI_MODEL")
  fi
  # Exported (subshell-local): an env-prefix on a *function* call is not
  # reliably exported to grandchildren.
  export GEMINI_CLI_TRUST_WORKSPACE=true
  ( cd "$gemini_ws" && run_gemini_pty "${gemini_args[@]}" ) \
    < /dev/null \
    > "$raw_pty" \
    2>"$GEMINI_ERR" || {
      local status=$?
      if [[ "$status" -eq 124 ]]; then
        echo "Gemini (gemini-cli) timed out after ${TIMEOUT_SECS}s (COUNCIL_TIMEOUT)." >&2
        echo "[COUNCIL-ADVISOR-FAILURE] Gemini timed out (COUNCIL_TIMEOUT=${TIMEOUT_SECS}s)." > "$GEMINI_OUT"
      elif [[ "$status" -eq 53 ]]; then
        echo "Gemini (gemini-cli) hit its turn limit (exit 53)." >&2
        echo "[COUNCIL-ADVISOR-FAILURE] Gemini hit model.maxSessionTurns (exit 53)." > "$GEMINI_OUT"
      else
        echo "Gemini (gemini-cli) invocation failed (exit $status). See $GEMINI_ERR" >&2
        echo "[COUNCIL-ADVISOR-FAILURE] Gemini failed to respond (exit $status). See $GEMINI_ERR." > "$GEMINI_OUT"
      fi
      return "$status"
    }
  # Extract .response from the JSON envelope inside the pty capture: the pty
  # merges warnings/artifacts around the JSON, so slice from the first '{' to
  # the last '}' before parsing (python3: no jq dependency).
  # Council R1: error envelopes exit NONZERO so failures cannot launder into
  # success; the bash fallback writes the standard failure placeholder.
  python3 - "$raw_pty" > "$GEMINI_OUT" <<'PYEOF' || {
import json, sys
raw = open(sys.argv[1], 'rb').read().decode('utf-8', 'replace')
start, end = raw.find('{'), raw.rfind('}')
try:
    if start == -1 or end <= start:
        raise ValueError("no JSON object in pty capture")
    data = json.loads(raw[start:end + 1])
except Exception as e:
    print(f"[COUNCIL-ADVISOR-FAILURE] Gemini JSON envelope unparseable: {e}")
    sys.exit(3)
err = data.get("error")
if err:
    print(f"[COUNCIL-ADVISOR-FAILURE] Gemini error: {err.get('type','?')}: {err.get('message','?')}")
    sys.exit(3)
resp = data.get("response", "")
if not resp.strip():
    print("[COUNCIL-ADVISOR-FAILURE] Gemini returned an empty response field.")
    sys.exit(3)
print(resp)
PYEOF
    return 3
  }
}

# pty + sandbox wrapper for gemini-cli. Mirrors run_agy_pty (Node CLIs hang
# when backgrounded without a pty in agent-harness contexts); refuses to run
# unsandboxed on non-macOS unless --allow-unsandboxed-gemini.
run_gemini_pty() {
  if [[ "$ALLOW_UNSANDBOXED_GEMINI" == "true" ]]; then
    run_with_timeout script -q /dev/null gemini "$@"
    return $?
  fi
  if command -v sandbox-exec &>/dev/null && [[ -f "$SANDBOX_PROFILE" ]]; then
    local home_gemini="$HOME/.gemini" home_caches="$HOME/Library/Caches"
    local sys_tmp="/tmp" sys_private_tmp="/private/tmp" sys_var_folders="/private/var/folders"
    local var
    for var in home_gemini TMPDIR_COUNCIL home_caches sys_tmp sys_private_tmp sys_var_folders; do
      [[ -z "${!var:-}" ]] && { echo "ERROR: sandbox param '$var' empty." >&2; return 1; }
    done
    run_with_timeout script -q /dev/null sandbox-exec -f "$SANDBOX_PROFILE" \
      -D HOME_GEMINI="$home_gemini" -D TMPDIR_COUNCIL="$TMPDIR_COUNCIL" \
      -D HOME_LIBRARY_CACHES="$home_caches" -D SYS_TMP="$sys_tmp" \
      -D SYS_PRIVATE_TMP="$sys_private_tmp" -D SYS_VAR_FOLDERS="$sys_var_folders" \
      gemini "$@"
  else
    echo "ERROR: sandbox-exec not found; pass --allow-unsandboxed-gemini to override." >&2
    return 1
  fi
}

# Backend selection (Council R1: resolved ONCE into COUNCIL_GEMINI_BACKEND_RESOLVED
# during startup, shared by banner + availability checks + this dispatcher):
#   gemini — force gemini-cli (missing binary/auth = hard, clearly-labeled failure)
#   agy    — force agy
#   auto   — gemini-cli iff (`gemini` in PATH AND a Gemini key set —
#            GEMINI_API_KEY or GOOGLE_API_KEY), else agy.
#            In auto mode ONLY: if gemini-cli fails for ANY reason and agy is
#            available, fall back ONCE to agy and log the fallback loudly.
invoke_gemini_backend() {
  local backend="$COUNCIL_GEMINI_BACKEND_RESOLVED"
  case "$backend" in
    gemini)
      local status=0
      invoke_gemini_cli || status=$?
      if [[ "$status" -ne 0 ]]; then
        if [[ "$COUNCIL_GEMINI_BACKEND" == "auto" ]] && command -v agy &>/dev/null; then
          echo "gemini-cli failed (exit $status) — auto mode falling back to agy (one attempt)." >&2
          invoke_gemini_agy
          return $?
        fi
        # Forced gemini: fail clearly, never silently succeed (Council R1).
        return "$status"
      fi
      ;;
    agy) invoke_gemini_agy ;;
    *) echo "ERROR: unknown resolved backend '$backend'" >&2; return 1 ;;
  esac
}

# --- Validation engine (v1.4.0) ---
# Philosophy: the response file is ground truth for CONTENT quality, and the
# exit status is ground truth for INVOCATION success — a failure on either
# axis is a failure (Council R1: never launder a nonzero exit into success
# just because the captured output looks substantive; the pty lane merges
# stderr into the capture, so error spew can masquerade as a response).
# v1.3.0 grepped the RESPONSE body for generic words (safety / policy /
# blocked / quota / 429 / rate limit) which false-failed nearly every
# substantive HIPAA/RLS review. Never reintroduce response-body word grepping.
# All script-generated failure placeholders carry one machine-recognizable
# prefix: [COUNCIL-ADVISOR-FAILURE].
FAILURE_PLACEHOLDER_PREFIX='^\[COUNCIL-ADVISOR-FAILURE\]'
# Verdict must be a NORMALIZED LINE near the top (driver prompts demand it) —
# unanchored tokens like a quoted "APPROVE" deep in text do not count (R1).
# Case-insensitive at every grep use-site (-i) — a `verdict:` in any case counts.
VERDICT_LINE='^[[:space:]]*(\**)?VERDICT(\**)?:'
# ONE verdict-detection window shared by the agy derail gate AND all three
# validate_response sites — was 40-vs-20 drift before the hoist (final review).
VERDICT_HEAD_LINES=40
REFUSAL_PATTERNS='I cannot assist|I can.t help with|I am unable to help|I will not provide|declining this request|unable to comply'
STDERR_WARNING_PATTERNS='RESOURCE_EXHAUSTED|rate limit|429|Maximum session turns exceeded|Loop detected, stopping execution|context length'

VALIDATE_REASON=""

validate_response() {
  local out_file="$1" err_file="$2" exit_status="$3" prompt_bytes="$4" advisor="$5"
  VALIDATE_REASON=""
  local warn_file="${out_file%.md}_warnings.log"

  # 1. Hard failures: empty output, script-written placeholder, nonzero exit.
  if [[ ! -s "$out_file" ]]; then
    VALIDATE_REASON="empty response"
    return 1
  fi
  # Anchor to line 1 ONLY — a review that QUOTES the placeholder string at line
  # start (e.g. discussing this very code) must not false-fail (final review).
  if head -1 "$out_file" | grep -Eq "$FAILURE_PLACEHOLDER_PREFIX"; then
    VALIDATE_REASON="placeholder ($(head -1 "$out_file" | cut -c1-120))"
    return 1
  fi
  if [[ "$exit_status" -eq 124 ]]; then
    VALIDATE_REASON="timed out (COUNCIL_TIMEOUT=${TIMEOUT_SECS:-?}s)"
    return 1
  fi
  if [[ "$exit_status" -ne 0 ]]; then
    # One defined partial-response exception (R1): keep output that carries a
    # normalized verdict line in its head DESPITE a nonzero exit (e.g. the
    # advisor finished writing, then its CLI died on teardown) — but downgrade
    # loudly via the warning file, never silently.
    if head -n "$VERDICT_HEAD_LINES" "$out_file" | grep -Eiq "$VERDICT_LINE"; then
      {
        echo "ADVISORY: $advisor exited $exit_status but the response carries a verdict line."
        echo "Treating as PARTIAL SUCCESS — verify the response is complete before relying on it."
      } > "$warn_file"
      echo "$advisor exited $exit_status with a verdict-bearing response — retained as partial (see $warn_file)." >&2
    else
      VALIDATE_REASON="advisor exited $exit_status without a verdict-bearing response"
      return 1
    fi
  fi

  local response_size
  response_size=$(wc -c < "$out_file")

  # 2. Refusal classification: refusal phrasing at the START and no normalized
  #    verdict line in the head = refusal. (A verdict line beats a refusal
  #    phrase only when the refusal phrase is NOT in the first 400 bytes.)
  if head -c 400 "$out_file" | grep -Eiq "$REFUSAL_PATTERNS"; then
    if ! head -n "$VERDICT_HEAD_LINES" "$out_file" | grep -Eiq "$VERDICT_LINE"; then
      VALIDATE_REASON="refusal"
      return 1
    fi
  fi

  # 3. Non-engagement: large prompt + short response + no verdict line.
  if [[ "$prompt_bytes" -gt 2048 && "$response_size" -lt 200 ]]; then
    if ! head -n "$VERDICT_HEAD_LINES" "$out_file" | grep -Eiq "$VERDICT_LINE"; then
      VALIDATE_REASON="non-engagement: ${response_size}-char verdict-less response on ${prompt_bytes}-byte prompt"
      return 1
    fi
  fi

  # 4. stderr patterns: ADVISORY ONLY when invocation succeeded and the
  #    response has substance.
  if [[ -s "$err_file" ]]; then
    local matched
    matched="$(grep -Eio "$STDERR_WARNING_PATTERNS" "$err_file" | head -3 | tr '\n' ';')" || true
    if [[ -n "$matched" ]]; then
      {
        echo "ADVISORY (not a failure — response file has substance):"
        echo "  stderr matched: $matched"
        echo "  full log: $err_file"
      } >> "$warn_file"
      echo "$advisor stderr warning ($matched) — response retained." >&2
    fi
  fi
  return 0
}

# --- OpenRouter seats (v1.6.0) ---
# Extra advisors reached over plain HTTPS: no CLI, no repo access, no writes
# outside $TMPDIR_COUNCIL. Qwen is the milestone-tier fourth seat; GLM is
# opt-in; any raw `vendor/model` id is accepted verbatim. Before 1.6.0 every
# such run was a hand-built curl from the session — the exact shape that
# produced the truncated-listing wrong-model incident (2026-08-04).
#
# NAMED SEATS ALWAYS RESOLVE TO THE NEWEST FLAGSHIP (Tom 2026-09-06): the
# script fetches OpenRouter's FULL model listing at every run and picks the
# highest version of the family (numeric per segment, so 3.10 > 3.8; then
# newest `created`). Nothing here pins a dated id. The *_FALLBACK constants
# are last-known ids used ONLY when the listing is unreachable or the family
# rule matches nothing — and that is announced in the banner, never silent.
OPENROUTER_URL="${OPENROUTER_URL:-https://openrouter.ai/api/v1/chat/completions}"
OPENROUTER_MODELS_URL="${OPENROUTER_MODELS_URL:-https://openrouter.ai/api/v1/models}"
OPENROUTER_QWEN_FALLBACK="qwen/qwen3.8-max-0902"   # last-known newest on 2026-09-06
OPENROUTER_GLM_FALLBACK="z-ai/glm-5.3"             # last-known newest on 2026-09-06
OPENROUTER_MAX_TOKENS_DEFAULT=32000                 # Qwen at 9k spent every token on reasoning and returned empty content

# Fetch the listing (public endpoint, no key) and prove it parses. $1 = out file.
# $2 = stderr capture (curl + parse diagnostics) so an outage is explainable.
fetch_openrouter_listing() {
  curl -sS --max-time 20 -o "$1" "$OPENROUTER_MODELS_URL" 2>"$2" \
    && python3 -c 'import json,sys; json.load(open(sys.argv[1]))["data"]' "$1" 2>>"$2"
}

# Newest flagship of a family from a listing file. $1 = listing, $2 = qwen|glm.
# Family rules (flagship only — no flash/turbo/air/preview/thinking/vision
# variants, no :free/:batch suffixes):
#   qwen  ^qwen/qwen<ver>-max(-<mmdd>)?$
#   glm   ^z-ai/glm-<ver>$
pick_latest_openrouter_model() {
  python3 - "$1" "$2" <<'PYEOF'
import json, re, sys
listing, family = sys.argv[1], sys.argv[2]
rules = {
    "qwen": re.compile(r"^qwen/qwen(\d+(?:\.\d+)*)-max(?:-\d{4})?$"),
    "glm":  re.compile(r"^z-ai/glm-(\d+(?:\.\d+)*)$"),
}
rule = rules[family]
best = None
for m in json.load(open(listing))["data"]:
    mid = m.get("id", "")
    mt = rule.match(mid)
    if not mt:
        continue
    key = (tuple(int(x) for x in mt.group(1).split(".")), int(m.get("created") or 0), mid)
    if best is None or key > best[0]:
        best = (key, mid)
if best is None:
    sys.exit(1)
print(best[1])
PYEOF
}

# seat → "model<TAB>source" — NO trailing newline; the caller splits on the tab.
# $1 = seat, $2 = listing file ('' if unavailable).
# Named seats: COUNCIL_QWEN_MODEL / COUNCIL_GLM_MODEL override (source=override)
# → newest on the listing (source=listing) → last-known id (source=fallback).
# Anything containing '/' is a raw id used verbatim (source=raw). An unknown
# bare name returns 1 so a typo fails at startup, not mid-run.
resolve_openrouter_seat_model() {
  local seat="$1" listing="${2:-}" override fallback picked
  case "$seat" in
    qwen) override="${COUNCIL_QWEN_MODEL:-}"; fallback="$OPENROUTER_QWEN_FALLBACK" ;;
    glm)  override="${COUNCIL_GLM_MODEL:-}";  fallback="$OPENROUTER_GLM_FALLBACK" ;;
    */*)  printf '%s\traw' "$seat"; return 0 ;;
    *)    return 1 ;;
  esac
  if [[ -n "$override" ]]; then printf '%s\toverride' "$override"; return 0; fi
  if [[ -n "$listing" && -s "$listing" ]] && picked="$(pick_latest_openrouter_model "$listing" "$seat")"; then
    printf '%s\tlisting' "$picked"; return 0
  fi
  printf '%s\tfallback' "$fallback"
}

# Display label (banner / report) and filesystem-safe slug (raw ids carry '/').
seat_label() { case "$1" in qwen) printf 'Qwen' ;; glm) printf 'GLM' ;; *) printf '%s' "$1" ;; esac; }
seat_slug()  { printf '%s' "$1" | tr '/:' '__'; }

# Parse an OpenRouter response capture. $1 raw, $2 http code, $3 label,
# $4 usage file, $5 partial file, $6 mode (complete|partial).
# Handles BOTH shapes: SSE (the lane streams — `stream: true`; a non-streaming
# request to GLM sat 9 minutes receiving only keep-alive whitespace and timed
# out, while the same prompt streamed completes in ~70 s — and a timeout still
# salvages whatever text arrived) and a
# plain JSON object (error envelopes; a server that ignored `stream`).
# complete mode: prints the review or a [COUNCIL-ADVISOR-FAILURE] line, exit 3 on failure.
#   A streamed review counts as COMPLETE only when choice 0 carried
#   `finish_reason: stop` — the FIRST finish is binding, content after it is a
#   defect, other choice indices are unexpected, and `[DONE]` proves only that
#   the transport ended. A clean EOF without a finish, a malformed event, an
#   error event, `length` (budget exhausted mid-review) or any other finish
#   are failures — text that did arrive is preserved to $5 so nothing is
#   lost, but nothing is laundered into success (Codex R2+R3, 2026-09-06).
# partial mode:  writes salvaged text to $5, prints "PARTIAL <chars>", exit 0.
# Usage is written BEFORE any verdict so a failed run still shows its cost.
parse_openrouter_response() {
  python3 - "$1" "$2" "$3" "$4" "$5" "$6" <<'PYEOF'
import json, sys
raw_path, http_code, label, usage_path, partial_path, mode = sys.argv[1:7]
raw = open(raw_path, "rb").read().decode("utf-8", "replace")
stripped = raw.lstrip()
content, usage, served, err = [], {}, None, None
was_stream, malformed, parse_note = False, 0, ""
# Terminal state of CHOICE 0 — the one review we return (Codex R3, 2026-09-06):
# the FIRST finish_reason is binding (a later `stop` cannot launder an earlier
# `length`), content after the finish is a defect, and any other choice index
# is unexpected. `[DONE]` only proves the transport ended, never success.
finish, content_after_finish, unexpected_choice = None, False, False

def take_choice(ch, text_of):
    global finish, content_after_finish, unexpected_choice
    if (ch.get("index") or 0) != 0:
        unexpected_choice = True
        return
    piece = text_of(ch) or ""
    if piece:
        if finish is not None:
            content_after_finish = True
        content.append(piece)
    fr = ch.get("finish_reason")
    if fr and finish is None:
        finish = fr

if stripped.startswith("{"):
    try:
        data = json.loads(stripped)
    except Exception as e:
        if mode == "complete":
            print(f"[COUNCIL-ADVISOR-FAILURE] {label}: HTTP {http_code}, body is not JSON ({e}).")
            sys.exit(3)
        data, parse_note = {}, f" (body is not JSON: {e})"
    err = data.get("error")
    if not err and data.get("choices"):          # non-streaming shape: a parsed body IS the completion
        served, usage = data.get("model"), data.get("usage") or {}
        for ch in data["choices"]:
            take_choice(ch, lambda c: (c.get("message") or {}).get("content"))
else:                                              # SSE
    was_stream = True
    for line in raw.splitlines():
        if not line.startswith("data:"):
            continue                                # keep-alive comments start with ':'
        payload = line[5:].strip()
        if not payload or payload == "[DONE]":
            continue
        try:
            chunk = json.loads(payload)
        except Exception:
            malformed += 1                          # complete mode: any malformed data: event fails the seat
            continue
        if chunk.get("error"):
            err = chunk["error"]; break             # handled below — after usage + salvage
        served = chunk.get("model") or served
        if chunk.get("usage"):
            usage = chunk["usage"]                  # usage-only trailing events are legitimate
        for ch in chunk.get("choices") or []:
            take_choice(ch, lambda c: (c.get("delta") or {}).get("content"))

text = "".join(content)
reasoning = (usage.get("completion_tokens_details") or {}).get("reasoning_tokens", 0) or 0
with open(usage_path, "w") as f:                   # written BEFORE any verdict: a failed run still shows its cost
    f.write(f"model_served={served or '?'} http={http_code} finish_reason={finish} "
            f"prompt_tokens={usage.get('prompt_tokens', '?')} completion_tokens={usage.get('completion_tokens', '?')} "
            f"reasoning_tokens={reasoning} cost_usd={usage.get('cost', '?')} chars={len(text)}\n")

def preserve():
    if not text.strip():
        return ""
    with open(partial_path, "w") as f:
        f.write(text if text.endswith("\n") else text + "\n")
    return f" {len(text)} chars preserved in {partial_path}."

if mode == "partial":
    # Salvage runs BEFORE the HTTP-code check: a timed-out curl reports no code
    # (000), and that must not stop the text that did arrive from being kept.
    preserve()
    if err:
        print(f"note: error object in body: {err}", file=sys.stderr)
    if parse_note:
        print(f"note:{parse_note}", file=sys.stderr)
    print(f"PARTIAL {len(text)}")
    sys.exit(0)

def fail(reason):
    print(f"[COUNCIL-ADVISOR-FAILURE] {label}: {reason}.{preserve()}")
    sys.exit(3)

if err or not http_code.startswith("2"):
    msg = err.get("message", "?") if isinstance(err, dict) else (str(err) if err else stripped[:200])
    fail(f"HTTP {http_code}: {msg}")
if malformed:
    fail(f"stream carried {malformed} malformed event(s)")
if unexpected_choice:
    fail("stream carried a choice index other than 0")
if content_after_finish:
    fail(f"content arrived after finish_reason={finish}")
if finish == "length" and not text.strip() and reasoning:
    fail(f"starved: {reasoning} reasoning tokens, empty content (finish_reason=length). "
         f"Raise COUNCIL_OPENROUTER_MAX_TOKENS or lower COUNCIL_OPENROUTER_EFFORT")
if finish not in (None, "stop"):
    hint = " Raise COUNCIL_OPENROUTER_MAX_TOKENS or lower COUNCIL_OPENROUTER_EFFORT" if finish == "length" else ""
    fail(f"finish_reason={finish} — the review did not complete.{hint}")
if was_stream and finish != "stop":
    fail("stream ended without a successful finish_reason for choice 0 ([DONE] alone is not completion)")
if not text.strip():
    fail(f"returned empty content (finish_reason={finish})")
sys.stdout.write(text if text.endswith("\n") else text + "\n")
PYEOF
}

# One seat, one HTTPS call. Files (all under $TMPDIR_COUNCIL, slug-prefixed):
#   <slug>_request.json  the payload actually sent (key-free by construction)
#   <slug>_raw.json      the verbatim capture (SSE stream or JSON error body)
#   <slug>_usage.log     served model / tokens / reasoning tokens / USD cost
#   <slug>_partial.md    text salvaged from a timed-out stream (when any)
#   <slug>_response.md   the review, or a [COUNCIL-ADVISOR-FAILURE] placeholder
# The API key travels ONLY via a mode-600 mktemp header file in the user's
# private $TMPDIR passed as `-H @file` (never on argv, never in the payload),
# removed by an EXIT trap so a killed subshell cannot leave it behind.
# curl exit 28 (--max-time) is normalized to 124 like the CLI lanes.
invoke_openrouter_seat() {
  local seat="$1" model="$2" out_file="$3" err_file="$4"
  local label slug payload raw usage_file partial hdr http_code status=0 salvage
  label="$(seat_label "$seat")"; slug="$(seat_slug "$seat")"
  payload="$TMPDIR_COUNCIL/${slug}_request.json"
  raw="$TMPDIR_COUNCIL/${slug}_raw.json"
  usage_file="$TMPDIR_COUNCIL/${slug}_usage.log"
  partial="$TMPDIR_COUNCIL/${slug}_partial.md"
  if [[ -z "${OPENROUTER_API_KEY:-}" ]]; then
    echo "[COUNCIL-ADVISOR-FAILURE] $label: OPENROUTER_API_KEY is not set." > "$out_file"
    echo "$label: OPENROUTER_API_KEY is not set." >&2
    return 1
  fi
  # Payload built by python so the prompt is never shell-escaped. The driver
  # line rides in the USER turn as well as the system turn: on the 2026-09-06
  # probe Qwen ignored a system-only VERDICT demand.
  # (heredoc feeds python's stdin; the `|| { … }` after the terminator handles
  # a non-zero exit — valid bash 3.2, just unusual to read.)
  python3 - "$PROMPT_FILE_FINAL" "$model" "$COUNCIL_OPENROUTER_EFFORT" "$COUNCIL_OPENROUTER_MAX_TOKENS" > "$payload" <<'PYEOF' || {
import json, sys
prompt = open(sys.argv[1], encoding="utf-8", errors="replace").read()
model, effort, max_tokens = sys.argv[2], sys.argv[3], int(sys.argv[4])
driver = ("You are one seat on a multi-model engineering review council. Respond fully to the "
          "review request below. Start your response with a VERDICT: line. Keep internal reasoning "
          "brief - spend the budget on the written review.")
body = {
    "model": model,
    "max_tokens": max_tokens,
    "stream": True,
    "usage": {"include": True},
    "messages": [
        {"role": "system", "content": driver},
        {"role": "user", "content": driver + "\n\n---\n\n" + prompt},
    ],
}
if effort != "none":
    body["reasoning"] = {"effort": effort}
json.dump(body, sys.stdout)
PYEOF
    echo "[COUNCIL-ADVISOR-FAILURE] $label: could not build the request payload." > "$out_file"
    return 1
  }
  hdr="$(mktemp "${TMPDIR:-/tmp}/council_or_hdr.XXXXXX")"   # mktemp → mode 600
  # The trap fires at SUBSHELL exit, after this function's locals are gone —
  # under `set -u` a local in the trap string is an unbound-variable death
  # (live 2026-09-06: every seat exited 1 AFTER a good response). Park the
  # path in a subshell-scoped global the trap can always read.
  OPENROUTER_HDR_FILE="$hdr"
  trap 'rm -f "${OPENROUTER_HDR_FILE:-}"' EXIT
  printf 'Authorization: Bearer %s\n' "$OPENROUTER_API_KEY" > "$hdr"
  http_code="$(curl -sS -N --max-time "$TIMEOUT_SECS" -o "$raw" -w '%{http_code}' \
      -H "@$hdr" -H 'Content-Type: application/json' \
      --data-binary "@$payload" "$OPENROUTER_URL" 2>"$err_file")" || status=$?
  rm -f "$hdr"
  if [[ "$status" -eq 28 ]]; then
    salvage="$(parse_openrouter_response "$raw" "${http_code:-000}" "$label" "$usage_file" "$partial" partial 2>/dev/null || true)"
    salvage="${salvage#PARTIAL }"
    echo "$label timed out after ${TIMEOUT_SECS}s (COUNCIL_TIMEOUT); ${salvage:-0} chars salvaged." >&2
    if [[ "${salvage:-0}" -gt 0 ]]; then
      echo "[COUNCIL-ADVISOR-FAILURE] $label timed out (COUNCIL_TIMEOUT=${TIMEOUT_SECS}s) after streaming ${salvage} chars — partial text preserved in $partial. Raise COUNCIL_TIMEOUT or lower COUNCIL_OPENROUTER_EFFORT." > "$out_file"
    else
      echo "[COUNCIL-ADVISOR-FAILURE] $label timed out (COUNCIL_TIMEOUT=${TIMEOUT_SECS}s) with no text streamed. Raise COUNCIL_TIMEOUT or lower COUNCIL_OPENROUTER_EFFORT." > "$out_file"
    fi
    [[ -s "$usage_file" ]] && echo "$label usage: $(cat "$usage_file")" >&2
    return 124
  elif [[ "$status" -ne 0 ]]; then
    echo "$label transport failed (curl exit $status). See $err_file" >&2
    echo "[COUNCIL-ADVISOR-FAILURE] $label transport failed (curl exit $status). See $err_file." > "$out_file"
    return "$status"
  fi
  status=0
  parse_openrouter_response "$raw" "$http_code" "$label" "$usage_file" "$partial" complete > "$out_file" || status=$?
  [[ -s "$usage_file" ]] && echo "$label usage: $(cat "$usage_file")" >&2
  return "$status"
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
OPENROUTER_SEATS_FLAG=""
OPENROUTER_ONLY=false

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
    --openrouter)
      OPENROUTER_SEATS_FLAG="${2:?--openrouter requires a comma-separated seat list (qwen,glm,vendor/model)}"
      shift 2
      ;;
    --openrouter-only)
      RUN_CODEX=false
      RUN_GEMINI=false
      OPENROUTER_ONLY=true
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
# Tom 2026-08-20: effort follows the review tier (medium routine / high
# hard-to-reverse / xhigh milestone) — caller escalates via COUNCIL_CODEX_EFFORT.
# Blanket xhigh burned native quota + OpenRouter spend on routine diffs.
COUNCIL_CODEX_EFFORT="${COUNCIL_CODEX_EFFORT:-medium}"
TIMEOUT_SECS="${COUNCIL_TIMEOUT:-600}"
AGY_PRINT_TIMEOUT="${AGY_PRINT_TIMEOUT:-8m}"
COUNCIL_GEMINI_BACKEND="${COUNCIL_GEMINI_BACKEND:-auto}"
COUNCIL_GEMINI_MODEL="${COUNCIL_GEMINI_MODEL:-}"

# --- OpenRouter seats (v1.6.0): flag beats env; comma-separated; de-duplicated;
# an unknown bare name fails HERE, before any advisor is launched. Named seats
# resolve against the LIVE listing (newest flagship); the source of every id
# is recorded so the banner can say "listing" / "override" / "FALLBACK".
COUNCIL_OPENROUTER_SEATS="${OPENROUTER_SEATS_FLAG:-${COUNCIL_OPENROUTER_SEATS:-}}"
COUNCIL_OPENROUTER_EFFORT="${COUNCIL_OPENROUTER_EFFORT:-${COUNCIL_CODEX_EFFORT:-medium}}"
COUNCIL_OPENROUTER_MAX_TOKENS="${COUNCIL_OPENROUTER_MAX_TOKENS:-$OPENROUTER_MAX_TOKENS_DEFAULT}"
SEAT_NAMES=(); SEAT_MODELS=(); SEAT_SOURCES=(); SEAT_OUTS=(); SEAT_ERRS=(); SEAT_PIDS=(); SEAT_STATUS=(); SEAT_REASONS=()
OPENROUTER_LISTING_FILE=""
OPENROUTER_LISTING_NOTE=""
if [[ -n "$COUNCIL_OPENROUTER_SEATS" ]]; then
  case "$COUNCIL_OPENROUTER_EFFORT" in
    none|minimal|low|medium|high|xhigh) ;;
    *) echo "ERROR: COUNCIL_OPENROUTER_EFFORT='$COUNCIL_OPENROUTER_EFFORT' — use none|minimal|low|medium|high|xhigh." >&2; exit 1 ;;
  esac
  command -v curl &>/dev/null    || { echo "ERROR: OpenRouter seats need 'curl' in PATH." >&2; exit 1; }
  # `-H @file` (how the key travels) needs curl >= 7.55; older curl would send the
  # literal string and fail with a 401 mid-run instead of here.
  curl --version 2>/dev/null | awk 'NR==1{split($2,v,"."); if (v[1]>7 || (v[1]==7 && v[2]>=55)) exit 0; exit 1}' \
    || { echo "ERROR: OpenRouter seats need curl >= 7.55 (found: $(curl --version 2>/dev/null | head -1))." >&2; exit 1; }
  command -v python3 &>/dev/null || { echo "ERROR: OpenRouter seats need 'python3' in PATH." >&2; exit 1; }
  [[ -n "${OPENROUTER_API_KEY:-}" ]] || { echo "ERROR: OpenRouter seats requested but OPENROUTER_API_KEY is not set (export it in ~/.zshenv; never paste it into a prompt)." >&2; exit 1; }
  _seats=()
  IFS=',' read -ra _seats <<< "$COUNCIL_OPENROUTER_SEATS"
  _needs_listing=false
  for _s in "${_seats[@]}"; do
    _s="$(printf '%s' "$_s" | tr -d '[:space:]')"
    case "$_s" in
      qwen) [[ -n "${COUNCIL_QWEN_MODEL:-}" ]] || _needs_listing=true ;;
      glm)  [[ -n "${COUNCIL_GLM_MODEL:-}" ]]  || _needs_listing=true ;;
    esac
  done
  if [[ "$_needs_listing" == "true" ]]; then
    OPENROUTER_LISTING_FILE="$(mktemp "${TMPDIR:-/tmp}/council_openrouter_models.XXXXXX")"
    _listing_err="$(mktemp "${TMPDIR:-/tmp}/council_openrouter_models_err.XXXXXX")"
    if ! fetch_openrouter_listing "$OPENROUTER_LISTING_FILE" "$_listing_err"; then
      rm -f "$OPENROUTER_LISTING_FILE"; OPENROUTER_LISTING_FILE=""
      OPENROUTER_LISTING_NOTE="OpenRouter model listing unreachable ($(head -1 "$_listing_err" 2>/dev/null | cut -c1-120)) — named seats use LAST-KNOWN ids (fallback pins), not necessarily the newest."
      echo "WARNING: $OPENROUTER_LISTING_NOTE" >&2
    fi
    rm -f "$_listing_err"
  fi
  for _s in "${_seats[@]}"; do
    _s="$(printf '%s' "$_s" | tr -d '[:space:]')"
    [[ -z "$_s" ]] && continue
    _dup=false
    for _n in ${SEAT_NAMES[@]+"${SEAT_NAMES[@]}"}; do [[ "$_n" == "$_s" ]] && _dup=true; done
    [[ "$_dup" == "true" ]] && continue
    _resolved="$(resolve_openrouter_seat_model "$_s" "$OPENROUTER_LISTING_FILE")" || {
      echo "ERROR: unknown OpenRouter seat '$_s' — use qwen, glm, or a raw vendor/model id." >&2
      exit 1
    }
    _m="${_resolved%%$'\t'*}"; _src="${_resolved##*$'\t'}"
    if [[ "$_src" == "fallback" && -n "$OPENROUTER_LISTING_FILE" ]]; then
      echo "WARNING: no model on the listing matched the '$_s' family rule — using last-known id $_m. Update the rule in council_invoke.sh." >&2
      _src="fallback-nomatch"
    fi
    # GLM #1 (2026-09-06): two raw ids can slug to the same filename
    # (vendor/a_b vs vendor/a/b → both vendor_a_b) and silently overwrite each other's files.
    _slug="$(seat_slug "$_s")"
    for _n in ${SEAT_NAMES[@]+"${SEAT_NAMES[@]}"}; do
      [[ "$(seat_slug "$_n")" == "$_slug" ]] && { echo "ERROR: seats '$_n' and '$_s' collide on output filename '${_slug}_*' — rename one." >&2; exit 1; }
    done
    SEAT_NAMES+=("$_s"); SEAT_MODELS+=("$_m"); SEAT_SOURCES+=("$_src")
  done
  [[ -n "$OPENROUTER_LISTING_FILE" ]] && rm -f "$OPENROUTER_LISTING_FILE"
fi
RUN_OPENROUTER=false
[[ "${#SEAT_NAMES[@]}" -gt 0 ]] && RUN_OPENROUTER=true
if [[ "$OPENROUTER_ONLY" == "true" && "$RUN_OPENROUTER" != "true" ]]; then
  echo "ERROR: --openrouter-only needs at least one seat (--openrouter qwen,glm or COUNCIL_OPENROUTER_SEATS)." >&2
  exit 1
fi

# Resolve the Gemini backend ONCE (Council R1) — banner, availability checks,
# and the dispatcher all read this. `auto` prefers gemini-cli only when BOTH a
# `gemini` binary is on PATH AND a paid Gemini key is set — GEMINI_API_KEY or
# GOOGLE_API_KEY; otherwise agy. Honoring BOTH keys matches preflight, which
# reports GEMINI_API_KEY_SET on either; checking only GEMINI_API_KEY here would
# let a GOOGLE_API_KEY-only machine preflight green then resolve to agy.
COUNCIL_GEMINI_BACKEND_RESOLVED="$COUNCIL_GEMINI_BACKEND"
if [[ "$COUNCIL_GEMINI_BACKEND" == "auto" ]]; then
  if command -v gemini &>/dev/null && [[ -n "${GEMINI_API_KEY:-}${GOOGLE_API_KEY:-}" ]]; then
    COUNCIL_GEMINI_BACKEND_RESOLVED="gemini"
  else
    COUNCIL_GEMINI_BACKEND_RESOLVED="agy"
  fi
fi

# Resolve display names for models (show user what's actually being used)
if [[ -n "$CODEX_MODEL" ]]; then
  CODEX_MODEL_DISPLAY="$CODEX_MODEL"
else
  CODEX_MODEL_DISPLAY="$(grep -E '^model[[:space:]]*=' "${HOME}/.codex/config.toml" 2>/dev/null | head -1 | sed 's/model *= *"\(.*\)"/\1/')"
  CODEX_MODEL_DISPLAY="${CODEX_MODEL_DISPLAY:-unknown}"
fi
if [[ -n "$COUNCIL_GEMINI_MODEL" ]]; then
  GEMINI_MODEL_DISPLAY="$COUNCIL_GEMINI_MODEL"
else
  GEMINI_MODEL_DISPLAY="backend default"
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
if [[ "$RUN_GEMINI" == "true" ]]; then
  # Check the RESOLVED backend's binary (resolution happens near the env
  # defaults above). auto-with-gemini-but-no-key resolves to agy, so this
  # verifies agy — NOT gemini — is present, closing the old gap where auto
  # passed the check then dispatched to a missing binary (Council R1).
  case "$COUNCIL_GEMINI_BACKEND_RESOLVED" in
    agy)
      command -v agy &>/dev/null || { echo "ERROR: resolved Gemini backend is 'agy' but agy is not in PATH." >&2; exit 1; } ;;
    gemini)
      command -v gemini &>/dev/null || { echo "ERROR: resolved Gemini backend is 'gemini' but gemini is not in PATH." >&2; exit 1; } ;;
  esac
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
elif [[ "$RUN_GEMINI" == "true" ]]; then
  DIR_LABEL="gemini"
else
  DIR_LABEL="openrouter"
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
for ((i=0; i<${#SEAT_NAMES[@]}; i++)); do
  _slug="$(seat_slug "${SEAT_NAMES[$i]}")"
  SEAT_OUTS[$i]="$TMPDIR_COUNCIL/${_slug}_response.md"
  SEAT_ERRS[$i]="$TMPDIR_COUNCIL/${_slug}_error.log"
  SEAT_STATUS[$i]=0; SEAT_REASONS[$i]=""
done

# Unsandboxed agy → the snapshot is the ONLY ghost-write guard; force paranoid
# (content-hash ignored files) so same-size in-place rewrites are still caught.
[[ "$ALLOW_UNSANDBOXED_GEMINI" == "true" ]] && export COUNCIL_SNAPSHOT_PARANOID=1

# --- Phase A safety net: snapshot $WORK_DIR BEFORE invocation ---
WORKTREE_SNAPSHOT_BEFORE="$TMPDIR_COUNCIL/worktree_snapshot_before.txt"
snapshot_worktree "$WORK_DIR" "$WORKTREE_SNAPSHOT_BEFORE"

# Determine mode label
if [[ "$RUN_CODEX" == "true" && "$RUN_GEMINI" == "true" ]]; then
  MODE="Full Council"
elif [[ "$RUN_CODEX" == "true" ]]; then
  MODE="Codex-only"
elif [[ "$RUN_GEMINI" == "true" ]]; then
  MODE="Gemini-only"
else
  MODE="OpenRouter-only"
fi
if [[ "$RUN_OPENROUTER" == "true" ]]; then
  _seat_list="$(IFS=,; echo "${SEAT_NAMES[*]}")"
  [[ "$MODE" == "OpenRouter-only" ]] || MODE="$MODE + OpenRouter"
  MODE="$MODE ($_seat_list)"
fi

# Capture CLI versions for the banner (1.3.0+: forensic continuity per
# Council R1). Lightweight — these are direct CLI calls, not preflight cache.
# Query only the RESOLVED Gemini backend's binary (Council R1: no hardcoded
# agy). `< /dev/null` guards against a --version probe blocking on inherited
# stdin (some CLIs read stdin unconditionally).
CODEX_VERSION_DISPLAY=""
GEMINI_VERSION_DISPLAY=""
[[ "$RUN_CODEX" == "true" ]] && CODEX_VERSION_DISPLAY="$(codex --version </dev/null 2>/dev/null | head -1 | tr -d '\r' || true)"
if [[ "$RUN_GEMINI" == "true" ]]; then
  case "$COUNCIL_GEMINI_BACKEND_RESOLVED" in
    agy)    GEMINI_VERSION_DISPLAY="$(agy --version </dev/null 2>/dev/null | head -1 | tr -d '\r' || true)" ;;
    gemini) GEMINI_VERSION_DISPLAY="$(gemini --version </dev/null 2>/dev/null | head -1 | tr -d '\r' || true)" ;;
  esac
fi

echo "Invoking The Council ($MODE)..."
[[ "$RUN_CODEX" == "true" ]] && echo "  Codex model:  $CODEX_MODEL_DISPLAY"
[[ "$RUN_CODEX" == "true" ]] && echo "  Codex effort: ${COUNCIL_CODEX_EFFORT} (COUNCIL_CODEX_EFFORT)"
[[ "$RUN_CODEX" == "true" ]] && echo "  Codex CLI:    ${CODEX_VERSION_DISPLAY:-unknown}"
[[ "$RUN_GEMINI" == "true" ]] && echo "  Gemini backend: $COUNCIL_GEMINI_BACKEND_RESOLVED"
[[ "$RUN_GEMINI" == "true" ]] && echo "  Gemini model:   $GEMINI_MODEL_DISPLAY"
[[ "$RUN_GEMINI" == "true" ]] && echo "  Gemini CLI:     ${GEMINI_VERSION_DISPLAY:-unknown}"
for ((i=0; i<${#SEAT_NAMES[@]}; i++)); do
  case "${SEAT_SOURCES[$i]}" in
    listing)  _src_note="newest on the live listing" ;;
    override) _src_note="explicit id via COUNCIL_*_MODEL" ;;
    raw)      _src_note="raw vendor/model id" ;;
    fallback) _src_note="FALLBACK last-known id — listing unavailable" ;;
    fallback-nomatch) _src_note="FALLBACK last-known id — listing loaded but nothing matched the family rule; update the rule" ;;
    *)        _src_note="${SEAT_SOURCES[$i]}" ;;
  esac
  echo "  OpenRouter seat: $(seat_label "${SEAT_NAMES[$i]}") → ${SEAT_MODELS[$i]} ($_src_note)"
done
[[ -n "$OPENROUTER_LISTING_NOTE" ]] && echo "  WARNING: $OPENROUTER_LISTING_NOTE"
[[ "$RUN_OPENROUTER" == "true" ]] && echo "  OpenRouter effort/max_tokens: ${COUNCIL_OPENROUTER_EFFORT} / ${COUNCIL_OPENROUTER_MAX_TOKENS} (COUNCIL_OPENROUTER_EFFORT / COUNCIL_OPENROUTER_MAX_TOKENS)"
echo "  Working dir:  $WORK_DIR"
echo "  Timeout:      ${TIMEOUT_SECS}s ($([[ -n "$TIMEOUT_CMD" ]] && echo "$TIMEOUT_CMD" || echo "bash watchdog"))"
# Agy-specific banner lines: only meaningful when the resolved backend is agy
# (the gemini-cli lane has its own timeout/sandbox story — don't mislabel it).
[[ "$RUN_GEMINI" == "true" && "$COUNCIL_GEMINI_BACKEND_RESOLVED" == "agy" ]] \
  && echo "  Agy timeout:  ${AGY_PRINT_TIMEOUT} (AGY_PRINT_TIMEOUT)"
if [[ "$RUN_GEMINI" == "true" && "$COUNCIL_GEMINI_BACKEND_RESOLVED" == "agy" ]]; then
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
    # --skip-git-repo-check: the skill's isolated-scratch-workspace mode runs in a
    # non-repo dir, where codex otherwise refuses ("Not inside a trusted directory",
    # live 2026-09-06). Harmless under --sandbox read-only.
    CODEX_ARGS=(exec --sandbox read-only --skip-git-repo-check -c approval_policy=never -o "$CODEX_OUT")
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

# --- Invoke Gemini (single-shot, no repo access) ---
# v1.4.0 design: the advisor reviews INLINED content only. The prompt file is
# placed in the per-invocation tmpdir which becomes agy's ONLY workspace —
# no --add-dir on the project, so there is no repo-exploration turn burn,
# no timeout race, and near-zero ghost-write surface (sandbox still wraps it).
# The old settings-injection block (which set a gemini-cli session-turns cap)
# was a verified NO-OP (agy never reads that key) and is deleted, not ported.
if [[ "$RUN_GEMINI" == "true" ]]; then
  # jsr:/registry specifiers trip Gemini's content classifier — redact for
  # Gemini only (Codex sees the original). printf, not echo (escape safety).
  GEMINI_PROMPT="$(printf '%s' "$PROMPT" | sed -E 's/jsr:[a-zA-Z0-9_@/.-]+/[jsr import redacted]/g')"
  GEMINI_REQUEST_FILE="$TMPDIR_COUNCIL/review_request.md"
  printf '%s' "$GEMINI_PROMPT" > "$GEMINI_REQUEST_FILE"

  (
    cd "$TMPDIR_COUNCIL" || exit 1
    invoke_gemini_backend
  ) &
  GEMINI_PID=$!
fi

# --- Invoke OpenRouter seats (HTTPS, inlined prompt, no repo access) ---
for ((i=0; i<${#SEAT_NAMES[@]}; i++)); do
  (
    cd "$TMPDIR_COUNCIL" || exit 1
    invoke_openrouter_seat "${SEAT_NAMES[$i]}" "${SEAT_MODELS[$i]}" "${SEAT_OUTS[$i]}" "${SEAT_ERRS[$i]}"
  ) &
  SEAT_PIDS[$i]=$!
done

# --- Wait for advisors ---
CODEX_STATUS=0
GEMINI_STATUS=0

if [[ -n "$CODEX_PID" ]]; then
  wait "$CODEX_PID" || CODEX_STATUS=$?
fi
if [[ -n "$GEMINI_PID" ]]; then
  wait "$GEMINI_PID" || GEMINI_STATUS=$?
fi
for ((i=0; i<${#SEAT_NAMES[@]}; i++)); do
  wait "${SEAT_PIDS[$i]}" || SEAT_STATUS[$i]=$?
done

# --- Validate responses ---
CODEX_FAIL_REASON=""
GEMINI_FAIL_REASON=""
PROMPT_BYTES=$(wc -c < "$PROMPT_FILE_FINAL")

if [[ "$RUN_CODEX" == "true" ]]; then
  if ! validate_response "$CODEX_OUT" "$CODEX_ERR" "$CODEX_STATUS" "$PROMPT_BYTES" "Codex"; then
    CODEX_FAIL_REASON="$VALIDATE_REASON"
    CODEX_STATUS=1
    echo "Codex failed validation ($CODEX_FAIL_REASON). See $CODEX_ERR" >&2
  else
    CODEX_STATUS=0   # validate_response already honored the raw exit status
  fi
fi

if [[ "$RUN_GEMINI" == "true" ]]; then
  if ! validate_response "$GEMINI_OUT" "$GEMINI_ERR" "$GEMINI_STATUS" "$PROMPT_BYTES" "Gemini"; then
    GEMINI_FAIL_REASON="$VALIDATE_REASON"
    GEMINI_STATUS=1
    echo "Gemini failed validation ($GEMINI_FAIL_REASON). See $GEMINI_ERR" >&2
  else
    GEMINI_STATUS=0
  fi
fi

for ((i=0; i<${#SEAT_NAMES[@]}; i++)); do
  _label="$(seat_label "${SEAT_NAMES[$i]}")"
  if ! validate_response "${SEAT_OUTS[$i]}" "${SEAT_ERRS[$i]}" "${SEAT_STATUS[$i]}" "$PROMPT_BYTES" "$_label"; then
    SEAT_REASONS[$i]="$VALIDATE_REASON"
    SEAT_STATUS[$i]=1
    echo "$_label failed validation ($VALIDATE_REASON). See ${SEAT_ERRS[$i]}" >&2
  else
    SEAT_STATUS[$i]=0
  fi
done
SEAT_PATHS_DISPLAY=""
for ((i=0; i<${#SEAT_NAMES[@]}; i++)); do
  SEAT_PATHS_DISPLAY="${SEAT_PATHS_DISPLAY}  $(seat_label "${SEAT_NAMES[$i]}"): ${SEAT_OUTS[$i]}
"
done

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
${SEAT_PATHS_DISPLAY}
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
for ((i=0; i<${#SEAT_NAMES[@]}; i++)); do
  STATUS_MSG="(success)"
  [[ "${SEAT_STATUS[$i]}" -ne 0 ]] && STATUS_MSG="(failed${SEAT_REASONS[$i]:+: ${SEAT_REASONS[$i]}})"
  echo "  $(seat_label "${SEAT_NAMES[$i]}"): ${SEAT_OUTS[$i]} $STATUS_MSG"
done
echo ""

# Output the paths for the caller to read
if [[ "$RUN_CODEX" == "true" ]]; then
  echo "$CODEX_OUT"
fi
if [[ "$RUN_GEMINI" == "true" ]]; then
  echo "$GEMINI_OUT"
fi
for ((i=0; i<${#SEAT_NAMES[@]}; i++)); do
  echo "${SEAT_OUTS[$i]}"
done

# --- Aggregate exit (v1.4.0) ---
# 0 = every requested advisor produced a validated response
# 1 = at least one requested advisor failed
# 2 = safety-net trip (exits earlier, above)
FINAL_STATUS=0
[[ "$RUN_CODEX" == "true" && "$CODEX_STATUS" -ne 0 ]] && FINAL_STATUS=1
[[ "$RUN_GEMINI" == "true" && "$GEMINI_STATUS" -ne 0 ]] && FINAL_STATUS=1
for ((i=0; i<${#SEAT_NAMES[@]}; i++)); do
  [[ "${SEAT_STATUS[$i]}" -ne 0 ]] && FINAL_STATUS=1
done
exit "$FINAL_STATUS"
