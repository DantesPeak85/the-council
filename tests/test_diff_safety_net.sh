#!/usr/bin/env bash
# Regression test: pre/post-invocation diff safety net (Phase A, 1.3.0+).
#
# Three sub-tests, each with its own clean fixture project:
#   1. Positive: fake agy ghost-writes a tracked file → safety net trips (exit 2)
#   2. Negative: nothing writes inside $WORK_DIR → no trigger (exit 0)
#   3. Gitignore coverage: fake agy writes to a gitignored .env → trips (exit 2)
#                          (this is the Council R1-mandated case — confirms the
#                          --exclude-standard blind spot is closed)
#   4. .council-tmp/ exclusion: fake agy writes inside .council-tmp/ → no trigger
#                               (response files land there; must not false-positive)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
COUNCIL_SCRIPT="$REPO_ROOT/skills/the-council/scripts/council_invoke.sh"

[[ -x "$COUNCIL_SCRIPT" ]] || { echo "FAIL: $COUNCIL_SCRIPT not executable"; exit 1; }

TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; [[ -f "$2" ]] && { echo "--- stderr ---"; cat "$2"; }; exit 1; }

run_council() {
  local fake_target="$1"   # ghost-write target (relative to project) or empty for "no write"
  local project="$2"
  local prompt="$3"
  local stderr_log="$4"

  local fake_bin="$TMPDIR_TEST/fake-bin-$$"
  rm -rf "$fake_bin"
  mkdir -p "$fake_bin"
  ln -sf "$REPO_ROOT/tests/fixtures/ghost-write-agy.sh" "$fake_bin/agy"

  set +e
  if [[ -n "$fake_target" ]]; then
    FAKE_AGY_GHOST_TARGET="$fake_target" PATH="$fake_bin:$PATH" \
      bash "$COUNCIL_SCRIPT" --gemini-only "$prompt" "$project" \
      > "$TMPDIR_TEST/stdout.log" 2> "$stderr_log"
  else
    # No ghost write: point target to a no-op (overwrites a file we'll clean up)
    FAKE_AGY_GHOST_TARGET="/tmp/fake-agy-noop-$$.txt" PATH="$fake_bin:$PATH" \
      bash "$COUNCIL_SCRIPT" --gemini-only "$prompt" "$project" \
      > "$TMPDIR_TEST/stdout.log" 2> "$stderr_log"
    rm -f "/tmp/fake-agy-noop-$$.txt"
  fi
  local exit_code=$?
  set -e
  echo "$exit_code"
}

setup_project() {
  local project="$1"
  local gitignore_extra="${2:-}"
  mkdir -p "$project"
  ( cd "$project" && git init -q && git config user.email "test@test" && git config user.name "test"
    touch baseline.txt
    if [[ -n "$gitignore_extra" ]]; then
      echo "$gitignore_extra" > .gitignore
    fi
    git add -A && git commit -q -m init )
}

build_prompt() {
  local file="$1"
  # >2KB padded prompt to avoid the script's short-prompt early-exit paths
  {
    echo "# Council review request"
    echo ""
    for i in $(seq 1 60); do
      echo "Padding line $i: please review carefully and provide structured feedback."
    done
  } > "$file"
}

# === Test 1: ghost-write to a tracked file → safety net MUST trip ===
echo "=== Test 1: ghost-write to tracked path triggers safety net ==="
PROJECT1="$TMPDIR_TEST/p1"
setup_project "$PROJECT1"
PROMPT1="$TMPDIR_TEST/prompt1.md"
build_prompt "$PROMPT1"

EXIT=$(run_council "GHOST.txt" "$PROJECT1" "$PROMPT1" "$TMPDIR_TEST/stderr1.log")
[[ "$EXIT" -eq 2 ]] || fail "Test 1: expected exit 2, got $EXIT" "$TMPDIR_TEST/stderr1.log"
grep -q "COUNCIL_SAFETY_NET" "$TMPDIR_TEST/stderr1.log" \
  || fail "Test 1: safety net banner missing" "$TMPDIR_TEST/stderr1.log"
[[ -f "$PROJECT1/GHOST.txt" ]] || fail "Test 1: fake agy did not ghost-write" "$TMPDIR_TEST/stderr1.log"
pass "Test 1 — ghost-write detected"

# === Test 2: no ghost-write → safety net MUST NOT trip ===
echo "=== Test 2: clean run does NOT trigger safety net ==="
PROJECT2="$TMPDIR_TEST/p2"
setup_project "$PROJECT2"
PROMPT2="$TMPDIR_TEST/prompt2.md"
build_prompt "$PROMPT2"

EXIT=$(run_council "" "$PROJECT2" "$PROMPT2" "$TMPDIR_TEST/stderr2.log")
[[ "$EXIT" -eq 0 ]] || fail "Test 2: expected exit 0 (clean run), got $EXIT" "$TMPDIR_TEST/stderr2.log"
! grep -q "COUNCIL_SAFETY_NET" "$TMPDIR_TEST/stderr2.log" \
  || fail "Test 2: safety net incorrectly triggered on clean run" "$TMPDIR_TEST/stderr2.log"
pass "Test 2 — clean run did not trip safety net"

# === Test 3 (Council R1-mandated): ghost-write to .gitignored .env → safety net MUST trip ===
echo "=== Test 3: ghost-write to gitignored .env triggers safety net ==="
PROJECT3="$TMPDIR_TEST/p3"
setup_project "$PROJECT3" $'.env\nnode_modules/\n'
PROMPT3="$TMPDIR_TEST/prompt3.md"
build_prompt "$PROMPT3"

EXIT=$(run_council ".env" "$PROJECT3" "$PROMPT3" "$TMPDIR_TEST/stderr3.log")
[[ "$EXIT" -eq 2 ]] || fail "Test 3: gitignored-file ghost-write not detected (got exit $EXIT) — gitignored blind spot is still open" "$TMPDIR_TEST/stderr3.log"
grep -q "COUNCIL_SAFETY_NET" "$TMPDIR_TEST/stderr3.log" \
  || fail "Test 3: safety net banner missing" "$TMPDIR_TEST/stderr3.log"
[[ -f "$PROJECT3/.env" ]] || fail "Test 3: fake agy did not ghost-write .env" "$TMPDIR_TEST/stderr3.log"
pass "Test 3 — gitignored-file ghost-write detected (Council R1-mandated case)"

# === Test 4: write inside .council-tmp/ → safety net MUST NOT trip ===
# This is the negative-control for the .council-tmp/ exclusion.
echo "=== Test 4: writes inside .council-tmp/ do NOT trigger safety net ==="
PROJECT4="$TMPDIR_TEST/p4"
setup_project "$PROJECT4"
PROMPT4="$TMPDIR_TEST/prompt4.md"
build_prompt "$PROMPT4"

EXIT=$(run_council ".council-tmp/legitimate.txt" "$PROJECT4" "$PROMPT4" "$TMPDIR_TEST/stderr4.log")
[[ "$EXIT" -eq 0 ]] || fail "Test 4: writes inside .council-tmp/ falsely tripped safety net (exit $EXIT)" "$TMPDIR_TEST/stderr4.log"
! grep -q "COUNCIL_SAFETY_NET" "$TMPDIR_TEST/stderr4.log" \
  || fail "Test 4: .council-tmp/ writes should be excluded" "$TMPDIR_TEST/stderr4.log"
pass "Test 4 — .council-tmp/ writes correctly excluded"

echo ""
echo "ALL Phase A regression tests passed."
