#!/usr/bin/env bash
# Integration test: Council Gemini branch must engage with the review request on
# a multi-kilobyte prompt. Regression test for the 2026-05-24 silent-failure bug
# (failure modes 1, 2 from the bug report).
#
# v1.4.0 single-shot design: the advisor no longer explores project files. The
# request body is inlined into review_request.md inside agy's tmpdir workspace,
# so the engagement signal is a SENTINEL placed INSIDE the prompt — a response
# that references it proves agy read review_request.md (not the repo).
#
# Requires real `agy` CLI installed and authenticated.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
COUNCIL_SCRIPT="$REPO_ROOT/skills/the-council/scripts/council_invoke.sh"
SENTINEL="WIDGETRON-9000-UNIQUE-SENTINEL"

[[ -x "$COUNCIL_SCRIPT" ]] || { echo "FAIL: $COUNCIL_SCRIPT not executable"; exit 1; }
command -v agy >/dev/null || { echo "FAIL: agy CLI not in PATH"; exit 1; }

TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

# --- Fixture: a minimal git project (WORK_DIR — hosts .council-tmp, NOT read) ---
PROJECT="$TMPDIR_TEST/project"
mkdir -p "$PROJECT"
( cd "$PROJECT" && git init -q && git config user.email "test@test" && git config user.name "test"
  echo "placeholder" > README.md
  git add -A && git commit -q -m init )

# --- Fixture: a >2KB prompt that CONTAINS the sentinel (the single-shot design
#     inlines the whole request into review_request.md; agy reads it there) ---
PROMPT="$TMPDIR_TEST/prompt.md"
{
  echo "# Architecture Review Request"
  echo ""
  echo "The system under review uses the $SENTINEL widget for distributed"
  echo "coordination. Replacing $SENTINEL would require a v3 protocol migration."
  echo ""
  echo "Then answer, grounded ONLY in the text above:"
  echo ""
  echo "- What component name is named in this request?"
  echo "- What would a v3 migration require?"
  echo ""
  echo "Reference the exact component name in your answer."
  echo ""
  # Pad to >2KB to exercise the long-prompt path (failure mode 2)
  for i in $(seq 1 30); do
    echo "Note $i: be specific. Reference the exact strings you were given above."
  done
} > "$PROMPT"

PROMPT_SIZE=$(wc -c < "$PROMPT")
echo "Prompt size: $PROMPT_SIZE bytes (must be >2048 to exercise long-prompt path)"
[[ "$PROMPT_SIZE" -gt 2048 ]] || { echo "FAIL: prompt smaller than 2KB"; exit 1; }

# --- Run the Council in Gemini-only mode ---
echo "Invoking council_invoke.sh (this takes 30-90s)..."
RESPONSE_PATH="$(bash "$COUNCIL_SCRIPT" --gemini-only "$PROMPT" "$PROJECT" | tail -1)"
[[ -f "$RESPONSE_PATH" ]] || { echo "FAIL: no response file at $RESPONSE_PATH"; exit 1; }

RESPONSE="$(cat "$RESPONSE_PATH")"
RESPONSE_LEN=${#RESPONSE}
echo "Response length: $RESPONSE_LEN chars"

# --- Assertions ---
fail() { echo "FAIL: $1"; echo "--- response ---"; echo "$RESPONSE"; echo "--- end ---"; exit 1; }

# Engagement: response must contain the sentinel from the inlined request
echo "$RESPONSE" | grep -q "$SENTINEL" \
  || fail "Response did not reference sentinel '$SENTINEL' from review_request.md (agy did not read the inlined request)"

# Non-meta: response must not be scratch-workspace meta-chatter
echo "$RESPONSE" | grep -qi "scratch workspace" \
  && fail "Response is scratch-workspace meta-chatter"
echo "$RESPONSE" | grep -qi "I am ready to help" \
  && fail "Response is non-engagement boilerplate"
echo "$RESPONSE" | grep -qi "default workspace directory set to" \
  && fail "Response is non-engagement boilerplate"

# Length floor: a >2KB review prompt should not return <200 chars
[[ "$RESPONSE_LEN" -gt 200 ]] \
  || fail "Response shorter than 200 chars on a >2KB prompt"

echo "PASS: Gemini engaged with the inlined review request"

# --- Detection test: meta-chatter response must be flagged ---
echo ""
echo "=== Detection test: meta-chatter must trigger validation failure ==="

FAKE_BIN="$TMPDIR_TEST/fake-bin"
mkdir -p "$FAKE_BIN"
ln -sf "$REPO_ROOT/tests/fixtures/fake-agy-metachat.sh" "$FAKE_BIN/agy"

# Run with the fake agy on PATH; capture stderr where validation messages land.
DETECT_OUT="$(PATH="$FAKE_BIN:$PATH" bash "$COUNCIL_SCRIPT" --gemini-only "$PROMPT" "$PROJECT" 2>&1 || true)"

echo "$DETECT_OUT" | grep -qi "non-engagement" \
  || { echo "FAIL: validation did not flag meta-chatter response"; echo "$DETECT_OUT"; exit 1; }

echo "PASS: meta-chatter response correctly flagged"
