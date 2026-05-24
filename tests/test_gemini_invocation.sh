#!/usr/bin/env bash
# Integration test: Council Gemini branch must engage with project files on
# a multi-kilobyte review prompt. Regression test for the 2026-05-24 silent-
# failure bug (failure modes 1, 2 from the bug report).
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

# --- Fixture: a small project with a sentinel string in a docs file ---
PROJECT="$TMPDIR_TEST/project"
mkdir -p "$PROJECT/docs"
cat > "$PROJECT/README.md" <<EOF
# TestProject

A fixture project used to verify the-council can read files from \$WORK_DIR.
EOF
cat > "$PROJECT/docs/ARCH.md" <<EOF
# Architecture

This system uses the $SENTINEL widget for distributed coordination.
Replacing $SENTINEL would require a v3 protocol migration.
EOF

# --- Fixture: a >2KB prompt that explicitly references project files ---
PROMPT="$TMPDIR_TEST/prompt.md"
{
  echo "# Architecture Review Request"
  echo ""
  echo "Please review the architecture of this project. Read these files first:"
  echo ""
  echo "1. README.md"
  echo "2. docs/ARCH.md"
  echo ""
  echo "Then answer:"
  echo ""
  echo "- What is the project named?"
  echo "- What component name appears in docs/ARCH.md?"
  echo "- What would a v3 migration require?"
  echo ""
  echo "Provide concrete answers grounded in what you read."
  echo ""
  # Pad to >2KB to exercise the long-prompt path (failure mode 2)
  for i in $(seq 1 30); do
    echo "Note $i: be specific. Reference exact file paths and exact strings you read."
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

# Engagement: response must contain the sentinel from docs/ARCH.md
echo "$RESPONSE" | grep -q "$SENTINEL" \
  || fail "Response did not reference sentinel '$SENTINEL' from docs/ARCH.md (agy did not read project files)"

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

echo "PASS: Gemini engaged with project files"
