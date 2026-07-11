#!/usr/bin/env bash
# Fake agy CLI: records argv to $FAKE_AGY_LOG; simulates TTY-dependent stdout
# (real agy bug #76: drops stdout when not a TTY) unless FAKE_AGY_TTY_SAFE=1.
# FAKE_AGY_DERAIL=1: emit a plausible verdict-less derail (agy 1.1.1 print-mode
# task-focus bug — answers questions about its own CLI instead of the review).
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
  if [[ "${FAKE_AGY_DERAIL:-}" == "1" ]]; then
    # Verdict-less derail: documentation for agy's own flags (observed live
    # 2026-07-11 on 4/4 runs). No VERDICT line anywhere.
    cat <<'DERAIL'
### The --add-dir flag

When starting a session, the --add-dir flag registers an additional
workspace directory for the agent. Repeat the flag to register several
directories; each path must exist and be readable. Combine with --print
to run non-interactively. Output is written to the attached terminal.
DERAIL
  else
    printf 'VERDICT: APPROVE-WITH-CHANGES\nFake agy review referencing the RLS policy is correct and writes are blocked properly.\n'
  fi
fi
exit 0
