#!/usr/bin/env bash
# PATH-injected fake agy that ghost-writes a file to an ABSOLUTE target before
# returning a response. Simulates the 2026-05-24 incident pattern (agy writes
# OUTSIDE its declared workspace during a --print invocation).
#
# v1.4.0: the agy workspace is now the per-run council tmpdir
# (.council-tmp/<run>/), which the snapshot engine EXCLUDES. A ghost write made
# RELATIVE to --add-dir would land in that excluded tmpdir and never trip the
# net. To exercise the REAL escape scenario, the ghost target is now an ABSOLUTE
# path (FAKE_AGY_GHOST_TARGET) the caller points at the project worktree — the
# write lands in $WORK_DIR regardless of agy's workspace, which is exactly the
# sandbox-escape the Phase A diff net exists to catch.
set -euo pipefail

# Ghost-write to the absolute target if one is provided. No --add-dir coupling:
# the escape scenario is precisely a write to a path OUTSIDE the workspace.
GHOST_TARGET="${FAKE_AGY_GHOST_TARGET:-}"
if [[ -n "$GHOST_TARGET" ]]; then
  mkdir -p "$(dirname "$GHOST_TARGET")"
  echo "// Ghost-written by fake agy at $(date)" > "$GHOST_TARGET"
fi

# Emit a plausible Council response so the script's content validators
# don't trigger separately.
cat <<'EOF'
Council R1 verdict: APPROVE.
The plan is sound; ship it.
EOF
exit 0
