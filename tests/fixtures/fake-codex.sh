#!/usr/bin/env bash
# Fake codex CLI (STRICT — Council R1: a permissive fake falsely passes bad flags).
# Rejects flags real `codex exec` 0.144 rejects; reads stdin ONLY when the
# prompt arg is `-` (mirrors real behavior; also prevents hangs on bare calls
# like `codex --version`).
set -euo pipefail
if [[ "${1:-}" == "--version" ]]; then echo "codex-cli 0.144.1 (fake)"; exit 0; fi
if [[ "${FAKE_CODEX_FAIL:-}" == "1" ]]; then exit 1; fi   # simulate advisor death (writes nothing)
# Simulate a slow advisor (timeout tests): sleep before doing anything, so a
# TERM from the watchdog lands mid-run and no log/response is ever written.
if [[ -n "${FAKE_CODEX_SLEEP:-}" ]]; then sleep "$FAKE_CODEX_SLEEP"; fi
OUT=""; WANT_STDIN=false; JSON=false
ARGS=("$@"); i=0
while [[ $i -lt ${#ARGS[@]} ]]; do
  case "${ARGS[$i]}" in
    --ask-for-approval|--full-auto|-a)
      echo "error: unexpected argument '${ARGS[$i]}' found" >&2; exit 2 ;;
    -o|--output-last-message) OUT="${ARGS[$((i+1))]}"; i=$((i+2)) ;;
    -) WANT_STDIN=true; i=$((i+1)) ;;
    --json) JSON=true; i=$((i+1)) ;;
    *) i=$((i+1)) ;;
  esac
done
STDIN_BYTES=0
if [[ "$WANT_STDIN" == "true" ]]; then
  STDIN_CONTENT="$(cat)"
  STDIN_BYTES=${#STDIN_CONTENT}
fi
{
  printf 'ARGV:'; printf ' %q' "$@"; printf '\n'
  printf 'STDIN_BYTES:%s\n' "$STDIN_BYTES"
} >> "${FAKE_CODEX_LOG:?}"
[[ -n "$OUT" ]] && printf 'VERDICT: APPROVE\nFake codex review body, substantive enough to clear the two-hundred-character engagement floor for validation purposes in tests.\n' > "$OUT"
# Real `codex exec --json` streams JSONL events on stdout; the last turn.completed carries usage.
if [[ "$JSON" == "true" ]]; then
  printf '{"type":"thread.started","thread_id":"fake-thread"}\n'
  printf '{"type":"turn.started"}\n'
  printf '{"type":"item.completed","item":{"type":"agent_message","text":"VERDICT: APPROVE"}}\n'
  printf '{"type":"turn.completed","usage":{"input_tokens":30123,"cached_input_tokens":7040,"cache_write_input_tokens":0,"output_tokens":3532,"reasoning_output_tokens":1525}}\n'
fi
exit 0
