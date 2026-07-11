#!/usr/bin/env bash
# Fake agy CLI: records argv to $FAKE_AGY_LOG; simulates TTY-dependent stdout
# (real agy bug #76: drops stdout when not a TTY) unless FAKE_AGY_TTY_SAFE=1.
set -euo pipefail
{ printf 'ARGV:'; printf ' %q' "$@"; printf '\n'; } >> "${FAKE_AGY_LOG:?}"
# Find the workspace dir passed via --add-dir to prove the request file exists
WS=""
ARGS=("$@"); i=0
while [[ $i -lt ${#ARGS[@]} ]]; do
  case "${ARGS[$i]}" in
    --add-dir) WS="${ARGS[$((i+1))]}"; i=$((i+2)) ;;
    *) i=$((i+1)) ;;
  esac
done
if [[ -n "$WS" && -f "$WS/review_request.md" ]]; then
  echo "REQUEST_FILE_FOUND" >> "$FAKE_AGY_LOG"
fi
if [[ -t 1 || "${FAKE_AGY_TTY_SAFE:-}" == "1" ]]; then
  printf 'VERDICT: APPROVE-WITH-CHANGES\nFake agy review referencing the RLS policy is correct and writes are blocked properly.\n'
fi
exit 0
