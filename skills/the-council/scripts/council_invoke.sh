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
#   COUNCIL_GEMINI_MODEL — Override Gemini model passed to agy --model (default: agy's own)
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
  if [[ -s "$GEMINI_OUT" ]] && ! head -40 "$GEMINI_OUT" | grep -Eq "${VERDICT_LINE:?}"; then
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
# serving 2026-06-18). Request travels via stdin (no ARG_MAX); response is the
# documented JSON envelope {response, stats, error}.
# Council R1 correction: `-p` alone does NOT disable tools/extensions/MCP —
# gemini-cli is still agentic. Enforcement here is layered:
#   (a) explicit flags verified against `gemini --help` at implementation
#       time (gemini-cli 0.42.0): `--approval-mode default` is a valid choice
#       ("prompt for approval") — in headless/non-interactive mode there is no
#       one to prompt, so unapprovable tool calls FAIL instead of executing.
#       (The even-stricter `plan` choice = read-only mode exists too, but
#       `default` matches the brief and layers (b)+(c) already deny writes.)
#   (b) the SAME sandbox-exec deny-write wrapper as agy (no pty needed —
#       gemini-cli has no TTY-gating bug) so any tool write fails at the OS;
#   (c) cwd = $TMPDIR_COUNCIL, not the project.
# All failure placeholders carry the [COUNCIL-ADVISOR-FAILURE] prefix that
# validate_response treats as hard failure.
invoke_gemini_cli() {
  local raw_out="$TMPDIR_COUNCIL/gemini_cli_raw.json"
  local gemini_args=(-p "Respond fully to the review request provided on stdin. Start your response with a VERDICT: line." --output-format json --approval-mode default)
  if [[ -n "$COUNCIL_GEMINI_MODEL" ]]; then
    gemini_args+=(-m "$COUNCIL_GEMINI_MODEL")
  fi
  run_sandboxed_no_pty gemini "${gemini_args[@]}" \
    < "$GEMINI_REQUEST_FILE" \
    > "$raw_out" \
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
  # Extract .response from the JSON envelope (python3: no jq dependency).
  # Council R1: error envelopes exit NONZERO so failures cannot launder into
  # success; the bash fallback writes the standard failure placeholder.
  python3 - "$raw_out" > "$GEMINI_OUT" <<'PYEOF' || {
import json, sys
try:
    data = json.load(open(sys.argv[1]))
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

# sandbox-exec wrapper WITHOUT pty (for gemini-cli). Same profile/params as
# run_agy_pty; refuses on non-macOS unless --allow-unsandboxed-gemini.
run_sandboxed_no_pty() {
  if [[ "$ALLOW_UNSANDBOXED_GEMINI" == "true" ]]; then
    run_with_timeout "$@"
    return $?
  fi
  if command -v sandbox-exec &>/dev/null && [[ -f "$SANDBOX_PROFILE" ]]; then
    local home_gemini="$HOME/.gemini" home_caches="$HOME/Library/Caches"
    local sys_tmp="/tmp" sys_private_tmp="/private/tmp" sys_var_folders="/private/var/folders"
    local var
    for var in home_gemini TMPDIR_COUNCIL home_caches sys_tmp sys_private_tmp sys_var_folders; do
      [[ -z "${!var:-}" ]] && { echo "ERROR: sandbox param '$var' empty." >&2; return 1; }
    done
    run_with_timeout sandbox-exec -f "$SANDBOX_PROFILE" \
      -D HOME_GEMINI="$home_gemini" -D TMPDIR_COUNCIL="$TMPDIR_COUNCIL" \
      -D HOME_LIBRARY_CACHES="$home_caches" -D SYS_TMP="$sys_tmp" \
      -D SYS_PRIVATE_TMP="$sys_private_tmp" -D SYS_VAR_FOLDERS="$sys_var_folders" \
      "$@"
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
VERDICT_LINE='^[[:space:]]*(\**)?VERDICT(\**)?:'
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
  if grep -Eq "$FAILURE_PLACEHOLDER_PREFIX" "$out_file"; then
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
    if head -20 "$out_file" | grep -Eq "$VERDICT_LINE"; then
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
    if ! head -20 "$out_file" | grep -Eq "$VERDICT_LINE"; then
      VALIDATE_REASON="refusal"
      return 1
    fi
  fi

  # 3. Non-engagement: large prompt + short response + no verdict line.
  if [[ "$prompt_bytes" -gt 2048 && "$response_size" -lt 200 ]]; then
    if ! head -20 "$out_file" | grep -Eq "$VERDICT_LINE"; then
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
else
  MODE="Gemini-only"
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

# --- Wait for advisors ---
CODEX_STATUS=0
GEMINI_STATUS=0

if [[ -n "$CODEX_PID" ]]; then
  wait "$CODEX_PID" || CODEX_STATUS=$?
fi
if [[ -n "$GEMINI_PID" ]]; then
  wait "$GEMINI_PID" || GEMINI_STATUS=$?
fi

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

# --- Aggregate exit (v1.4.0) ---
# 0 = every requested advisor produced a validated response
# 1 = at least one requested advisor failed
# 2 = safety-net trip (exits earlier, above)
FINAL_STATUS=0
[[ "$RUN_CODEX" == "true" && "$CODEX_STATUS" -ne 0 ]] && FINAL_STATUS=1
[[ "$RUN_GEMINI" == "true" && "$GEMINI_STATUS" -ne 0 ]] && FINAL_STATUS=1
exit "$FINAL_STATUS"
