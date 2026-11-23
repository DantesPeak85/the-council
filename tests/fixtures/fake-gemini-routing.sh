#!/usr/bin/env bash
# Fake gemini-cli for per-round routing tests (v1.6.7). Records the -m model and
# GEMINI_CLI_SYSTEM_SETTINGS_PATH content; emits a JSON envelope whose stats name
# the model it was asked for (as the real CLI does).
# FAKE_GEMINI_REJECT = comma list of models answered with a ModelNotFoundError envelope (exit 1).
# FAKE_GEMINI_TOKENS = "<prompt> <candidates> <thoughts>" (default "7800 100 200").
set -euo pipefail
if [[ "${1:-}" == "--version" ]]; then echo "gemini-cli 0.58.0 (fake)"; exit 0; fi
MODEL=""
ARGS=("$@"); i=0
while [[ $i -lt ${#ARGS[@]} ]]; do
  if [[ "${ARGS[$i]}" == "-m" ]]; then MODEL="${ARGS[$((i+1))]:-}"; i=$((i+2)); else i=$((i+1)); fi
done
THINK=""
[[ -n "${GEMINI_CLI_SYSTEM_SETTINGS_PATH:-}" && -f "$GEMINI_CLI_SYSTEM_SETTINGS_PATH" ]] && THINK="$(tr -d '\n' < "$GEMINI_CLI_SYSTEM_SETTINGS_PATH")"
{ echo "MODEL:${MODEL}"; echo "SETTINGS:${THINK}"; } >> "${FAKE_GEMINI_LOG:?}"
if [[ ",${FAKE_GEMINI_REJECT:-}," == *",${MODEL},"* ]]; then
  printf '{"session_id":"x","error":{"type":"Error","message":"models/%s is not found for API version v1beta, or is not supported for generateContent."}}\n' "$MODEL"
  exit 1
fi
read -r P C T <<< "${FAKE_GEMINI_TOKENS:-7800 100 200}"
printf '{"response":"VERDICT: APPROVE\\nFake routed review body.","stats":{"models":{"%s":{"tokens":{"input":%s,"prompt":%s,"candidates":%s,"total":%s,"cached":0,"thoughts":%s,"tool":0}}}}}\n' "$MODEL" "$P" "$P" "$C" "$((P+C+T))" "$T"
exit 0
