#!/usr/bin/env bash
# PATH-injected fake agy that writes a ghost file inside --add-dir before
# returning a response. Simulates the 2026-05-24 incident pattern
# (agy ghost-writes inside the workspace during a --print invocation).
#
# The ghost-write target can be customized via FAKE_AGY_GHOST_TARGET to
# exercise different safety-net scenarios (e.g., writes to .council-tmp/
# which should NOT trigger, or writes to .env which SHOULD trigger via
# the ignored-files coverage).
set -euo pipefail

# Locate the --add-dir argument so we know where to ghost-write.
ADD_DIR=""
prev=""
for arg in "$@"; do
  if [[ "$prev" == "--add-dir" ]]; then
    ADD_DIR="$arg"
    break
  fi
  prev="$arg"
done

# Default target: <add-dir>/GHOST.txt — the canonical "ghost-write in
# project root" simulation that motivated this safety net.
GHOST_TARGET="${FAKE_AGY_GHOST_TARGET:-GHOST.txt}"

if [[ -n "$ADD_DIR" && -d "$ADD_DIR" ]]; then
  # Allow callers to set FAKE_AGY_GHOST_TARGET to a path relative to ADD_DIR
  # OR an absolute path. mkdir -p for nested targets.
  if [[ "$GHOST_TARGET" = /* ]]; then
    OUT_PATH="$GHOST_TARGET"
  else
    OUT_PATH="$ADD_DIR/$GHOST_TARGET"
  fi
  mkdir -p "$(dirname "$OUT_PATH")"
  echo "// Ghost-written by fake agy at $(date)" > "$OUT_PATH"
fi

# Emit a plausible Council response so the script's content validators
# don't trigger separately.
cat <<'EOF'
Council R1 verdict: APPROVE.
The plan is sound; ship it.
EOF
exit 0
