#!/usr/bin/env bash
# Fake gemini-cli: records argv + stdin size, emits the documented JSON envelope.
# --version guard mirrors fake-codex: the backend-aware banner probes
# `gemini --version`, and without this guard the unconditional `cat` below would
# block on the banner's inherited stdin. FAKE_GEMINI_FAIL=1 simulates advisor
# death (writes nothing) to exercise the auto-mode fall-back-to-agy path.
set -euo pipefail
if [[ "${1:-}" == "--version" ]]; then echo "gemini-cli 0.42.0 (fake)"; exit 0; fi
if [[ "${FAKE_GEMINI_FAIL:-}" == "1" ]]; then exit 1; fi
STDIN_CONTENT="$(cat)"
{ printf 'ARGV:'; printf ' %q' "$@"; printf '\n'; printf 'STDIN_BYTES:%s\n' "${#STDIN_CONTENT}"; } >> "${FAKE_GEMINI_LOG:?}"
printf '{"response": "VERDICT: APPROVE\\nFake gemini-cli review body with policy analysis.", "stats": {"models": {}}, "error": null}\n'
exit 0
