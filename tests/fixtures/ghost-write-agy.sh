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

# Emit a plausible Council response so the script's content validators don't
# trigger separately. v1.4.0: the validator requires a NORMALIZED `VERDICT:`
# line in the head AND >200 chars of substance on a >2KB prompt, else it flags
# non-engagement (which now propagates to a nonzero aggregate exit). This
# fixture exists to exercise the SAFETY NET, not validation, so the response
# below deliberately clears both bars — leaving exit code attributable solely
# to the diff net (or its absence).
cat <<'EOF'
VERDICT: APPROVE
The plan is sound and the migration's rollback path is safe. This review body is
deliberately padded well beyond the two-hundred-character engagement floor so the
content validators treat it as a genuine, substantive response and never interfere
with the safety-net assertions this fixture exists to exercise. Ship it.
EOF
exit 0
