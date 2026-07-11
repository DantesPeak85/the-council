#!/usr/bin/env bash
# Fake gemini-cli: records argv + the @file request it was pointed at, emits
# the documented JSON envelope on stdout.
# --version guard mirrors fake-codex (the backend-aware banner probes it).
# FAKE_GEMINI_FAIL=1 simulates advisor death (writes nothing, exit 1) to
# exercise the auto-mode fall-back-to-agy path.
# v1.4.1: the request travels via gemini's client-side @file expansion in the
# -p argument (relative to cwd), NOT stdin — a pty echoes stdin, so the real
# lane closed stdin and moved the request into the workspace file.
set -euo pipefail
if [[ "${1:-}" == "--version" ]]; then echo "gemini-cli 0.42.0 (fake)"; exit 0; fi
if [[ "${FAKE_GEMINI_FAIL:-}" == "1" ]]; then exit 1; fi
REQUEST_BYTES=0
ARGS=("$@"); i=0
while [[ $i -lt ${#ARGS[@]} ]]; do
  if [[ "${ARGS[$i]}" == "-p" ]]; then
    PROMPT="${ARGS[$((i+1))]:-}"
    if [[ "$PROMPT" =~ ^@([^[:space:]]+) ]]; then
      REQ_FILE="${BASH_REMATCH[1]}"
      [[ -f "$REQ_FILE" ]] && REQUEST_BYTES=$(wc -c < "$REQ_FILE" | tr -d ' ')
    fi
    i=$((i+2))
  else
    i=$((i+1))
  fi
done
{ printf 'ARGV:'; printf ' %q' "$@"; printf '\n'; printf 'REQUEST_BYTES:%s\n' "$REQUEST_BYTES"; } >> "${FAKE_GEMINI_LOG:?}"
printf '{"response": "VERDICT: APPROVE\\nFake gemini-cli review body with policy analysis.", "stats": {"models": {}}, "error": null}\n'
exit 0
