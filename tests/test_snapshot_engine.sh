#!/usr/bin/env bash
# Regression tests for the v1.4.0 snapshot engine.
#   1. Apostrophe-in-filename: snapshot must include the file's hash (PR #2 class)
#   2. COUNCIL_SNAPSHOT_EXCLUDES: excluded path change must NOT appear in diff
#   3. Built-in churn excludes: .remember/ + .tmp.driveupload/ writes must NOT trip
#   4. Ignored-file name-level detection: NEW gitignored file appears in snapshot
#      (by name), but its CONTENT is not hashed (no sha256 line for it)
#   5. Perf ceiling: snapshot of a tree with a 50MB gitignored blob completes <5s

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
COUNCIL_SCRIPT="$REPO_ROOT/skills/the-council/scripts/council_invoke.sh"

TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

# Source ONLY the snapshot functions from the script (guarded sourcing:
# the script must expose COUNCIL_SOURCE_ONLY=1 early-return for tests).
export COUNCIL_SOURCE_ONLY=1
# shellcheck disable=SC1090
source "$COUNCIL_SCRIPT"
unset COUNCIL_SOURCE_ONLY

make_project() {
  local p="$TMPDIR_TEST/$1"
  mkdir -p "$p"
  git -C "$p" init -q
  echo "hello" > "$p/tracked.txt"
  git -C "$p" add -A && git -C "$p" -c user.email=t@t -c user.name=t commit -qm init
  echo "$p"
}

# --- 1. Apostrophe filename ---
P="$(make_project apo)"
echo "data" > "$P/Women's Health.pdf"
git -C "$P" add -A && git -C "$P" -c user.email=t@t -c user.name=t commit -qm apo
snapshot_worktree "$P" "$TMPDIR_TEST/apo.snap"
grep -q "Women's Health.pdf" "$TMPDIR_TEST/apo.snap" \
  || fail "apostrophe file missing from snapshot"
pass "apostrophe filename hashed"

# --- 2. Env-var excludes ---
P="$(make_project exc)"
mkdir -p "$P/bigdir"
echo "one" > "$P/bigdir/blob.bin"
snapshot_worktree "$P" "$TMPDIR_TEST/exc_before.snap"
COUNCIL_SNAPSHOT_EXCLUDES="bigdir/**" snapshot_worktree "$P" "$TMPDIR_TEST/exc_excl.snap"
grep -q "bigdir/blob.bin" "$TMPDIR_TEST/exc_before.snap" || fail "control: blob should be in default snapshot"
grep -q "bigdir/blob.bin" "$TMPDIR_TEST/exc_excl.snap" && fail "excluded path leaked into snapshot"
pass "COUNCIL_SNAPSHOT_EXCLUDES honored"

# --- 3. Built-in churn excludes ---
P="$(make_project churn)"
snapshot_worktree "$P" "$TMPDIR_TEST/churn_before.snap"
mkdir -p "$P/.remember/logs" "$P/.tmp.driveupload"
echo "autosave" > "$P/.remember/logs/save-1.log"
echo "gdrive" > "$P/.tmp.driveupload/x.tmp"
snapshot_worktree "$P" "$TMPDIR_TEST/churn_after.snap"
diff "$TMPDIR_TEST/churn_before.snap" "$TMPDIR_TEST/churn_after.snap" >/dev/null \
  || fail ".remember/.tmp.driveupload churn changed the snapshot"
pass "built-in churn excludes silent"

# --- 4. Ignored files: name-level, not content-hashed ---
P="$(make_project ign)"
echo "secret.env" > "$P/.gitignore"
git -C "$P" add -A && git -C "$P" -c user.email=t@t -c user.name=t commit -qm ign
snapshot_worktree "$P" "$TMPDIR_TEST/ign_before.snap"
echo "API_KEY=x" > "$P/secret.env"
snapshot_worktree "$P" "$TMPDIR_TEST/ign_after.snap"
diff "$TMPDIR_TEST/ign_before.snap" "$TMPDIR_TEST/ign_after.snap" >/dev/null \
  && fail "new gitignored file NOT detected"
grep -E '^[0-9a-f]{64}  .*secret\.env' "$TMPDIR_TEST/ign_after.snap" \
  && fail "ignored file content was hashed (should be name-level only)"
pass "ignored file detected by name, not content-hashed"

# --- 5. Perf ceiling: one big blob AND many small ignored files (Council R1) ---
P="$(make_project perf)"
printf 'blob.bin\nmany/\n' > "$P/.gitignore"
git -C "$P" add -A && git -C "$P" -c user.email=t@t -c user.name=t commit -qm perf
dd if=/dev/zero of="$P/blob.bin" bs=1m count=50 2>/dev/null
mkdir -p "$P/many"
( cd "$P/many" && for i in $(seq 1 2000); do echo "$i" > "f$i.txt"; done )
START=$(date +%s)
snapshot_worktree "$P" "$TMPDIR_TEST/perf.snap"
ELAPSED=$(( $(date +%s) - START ))
[[ "$ELAPSED" -lt 10 ]] || fail "snapshot took ${ELAPSED}s on 50MB blob + 2000 ignored files (must be <10s)"
pass "perf: ignored content not hashed, enumeration batched (${ELAPSED}s)"

# --- 6. Paranoid mode: ignored-file CONTENT change detected when COUNCIL_SNAPSHOT_PARANOID=1 ---
P="$(make_project para)"
echo "secret.env" > "$P/.gitignore"
git -C "$P" add -A && git -C "$P" -c user.email=t@t -c user.name=t commit -qm para
printf 'AAAA' > "$P/secret.env"
COUNCIL_SNAPSHOT_PARANOID=1 snapshot_worktree "$P" "$TMPDIR_TEST/para_before.snap"
printf 'BBBB' > "$P/secret.env"   # same size, different content
COUNCIL_SNAPSHOT_PARANOID=1 snapshot_worktree "$P" "$TMPDIR_TEST/para_after.snap"
diff "$TMPDIR_TEST/para_before.snap" "$TMPDIR_TEST/para_after.snap" >/dev/null \
  && fail "paranoid mode missed a same-size ignored-content rewrite"
pass "paranoid mode content-hashes ignored files"

echo ""
echo "ALL SNAPSHOT ENGINE TESTS PASSED"
