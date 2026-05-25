#!/usr/bin/env bash
# Regression test: council_sandbox.sb deny-write profile (Phase B, 1.3.0+).
#
# Uses /usr/bin/touch under sandbox-exec instead of agy so the test is
# cheap, deterministic, and independent of agy API quota. Confirms:
#   1. Writes inside $WORK_DIR are blocked at the OS layer
#   2. Writes inside $TMPDIR_COUNCIL are allowed
#   3. Writes inside the narrowed Library/Caches subpaths are allowed
#   4. Writes inside the unrelated Library/Caches/Other-app are blocked
#      (verifies Council R1 narrowing: the whole cache root is NOT allowed)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROFILE="$REPO_ROOT/skills/the-council/scripts/council_sandbox.sb"

command -v sandbox-exec >/dev/null \
  || { echo "SKIP: sandbox-exec unavailable (non-macOS)"; exit 0; }
[[ -f "$PROFILE" ]] || { echo "FAIL: sandbox profile not found at $PROFILE"; exit 1; }

TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST" "$HOME/Library/Caches/__council_sandbox_test_other__" 2>/dev/null' EXIT

# Shared param block (matches the production invocation in council_invoke.sh).
SBARGS=(
  -D HOME_GEMINI="$HOME/.gemini"
  -D TMPDIR_COUNCIL="$TMPDIR_TEST/council"
  -D HOME_LIBRARY_CACHES="$HOME/Library/Caches"
  -D SYS_TMP="/tmp"
  -D SYS_PRIVATE_TMP="/private/tmp"
  -D SYS_VAR_FOLDERS="/private/var/folders"
)
mkdir -p "$TMPDIR_TEST/council"
mkdir -p "$HOME/Library/Caches"

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

# === Test 1: write inside repo (project) is BLOCKED ===
set +e
sandbox-exec -f "$PROFILE" "${SBARGS[@]}" /usr/bin/touch "$REPO_ROOT/SANDBOX_TEST_SHOULD_FAIL.txt" 2>/dev/null
exit1=$?
set -e
[[ "$exit1" -ne 0 ]] || { rm -f "$REPO_ROOT/SANDBOX_TEST_SHOULD_FAIL.txt"; fail "Test 1: write to repo root was NOT blocked (exit $exit1)"; }
[[ ! -f "$REPO_ROOT/SANDBOX_TEST_SHOULD_FAIL.txt" ]] \
  || { rm -f "$REPO_ROOT/SANDBOX_TEST_SHOULD_FAIL.txt"; fail "Test 1: file landed in repo despite sandbox block"; }
pass "Test 1 — write to project root is blocked"

# === Test 2: write inside $TMPDIR_COUNCIL is ALLOWED ===
sandbox-exec -f "$PROFILE" "${SBARGS[@]}" /usr/bin/touch "$TMPDIR_TEST/council/ok.txt"
[[ -f "$TMPDIR_TEST/council/ok.txt" ]] || fail "Test 2: sandbox blocked write to allowed TMPDIR_COUNCIL"
pass "Test 2 — write to TMPDIR_COUNCIL is allowed"

# === Test 3: write inside ~/Library/Caches/agy is ALLOWED (narrowed scope) ===
mkdir -p "$HOME/Library/Caches/agy"
sandbox-exec -f "$PROFILE" "${SBARGS[@]}" /usr/bin/touch "$HOME/Library/Caches/agy/__council_test__.txt"
[[ -f "$HOME/Library/Caches/agy/__council_test__.txt" ]] || fail "Test 3: sandbox blocked write to agy cache subdir"
rm -f "$HOME/Library/Caches/agy/__council_test__.txt"
pass "Test 3 — write to ~/Library/Caches/agy/ is allowed"

# === Test 4 (Council R1-mandated): write inside an unrelated Library/Caches
#     subdir is BLOCKED (proves the narrowing held — not a blanket Cache allow). ===
mkdir -p "$HOME/Library/Caches/__council_sandbox_test_other__"
set +e
sandbox-exec -f "$PROFILE" "${SBARGS[@]}" /usr/bin/touch "$HOME/Library/Caches/__council_sandbox_test_other__/probe.txt" 2>/dev/null
exit4=$?
set -e
[[ "$exit4" -ne 0 ]] \
  || { rm -f "$HOME/Library/Caches/__council_sandbox_test_other__/probe.txt"; fail "Test 4: write to unrelated Library/Caches subdir was NOT blocked — narrowing failed"; }
[[ ! -f "$HOME/Library/Caches/__council_sandbox_test_other__/probe.txt" ]] \
  || fail "Test 4: file landed in unrelated cache subdir"
rm -rf "$HOME/Library/Caches/__council_sandbox_test_other__"
pass "Test 4 — write to unrelated Library/Caches subdir is blocked (narrowing held)"

# === Test 5: read access is broadly available (sanity — sandbox shouldn't block reads) ===
sandbox-exec -f "$PROFILE" "${SBARGS[@]}" /bin/cat "$REPO_ROOT/README.md" > /dev/null
pass "Test 5 — broad read access works"

echo ""
echo "ALL Phase B sandbox tests passed."
