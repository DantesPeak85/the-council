#!/usr/bin/env bash
# Asserts the v1.4.0 Codex lane:
#   1. Prompt travels via stdin (`-` + redirect), NOT argv → no ARG_MAX, no stdin-hang
#   2. Explicit flags: --sandbox read-only, --ask-for-approval never; NO --full-auto
#   3. Reasoning effort: -c model_reasoning_effort=xhigh by default;
#      COUNCIL_CODEX_EFFORT=config omits the override
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
COUNCIL_SCRIPT="$REPO_ROOT/skills/the-council/scripts/council_invoke.sh"
TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

FAKE_BIN="$TMPDIR_TEST/bin"; mkdir -p "$FAKE_BIN"
cp "$REPO_ROOT/tests/fixtures/fake-codex.sh" "$FAKE_BIN/codex"
chmod +x "$FAKE_BIN/codex"

PROJECT="$TMPDIR_TEST/proj"; mkdir -p "$PROJECT"
git -C "$PROJECT" init -q
echo x > "$PROJECT/f.txt"; git -C "$PROJECT" add -A
git -C "$PROJECT" -c user.email=t@t -c user.name=t commit -qm i

PROMPT="$TMPDIR_TEST/prompt.txt"
# 300KB prompt — would exceed ARG_MAX if passed as argv
python3 -c "print('Review this. ' * 25000)" > "$PROMPT"

export FAKE_CODEX_LOG="$TMPDIR_TEST/codex.log"

# --- default invocation ---
PATH="$FAKE_BIN:$PATH" bash "$COUNCIL_SCRIPT" --codex-only "$PROMPT" "$PROJECT" \
  || fail "codex-only invocation errored"
grep -q 'ARGV:.*--sandbox read-only' "$FAKE_CODEX_LOG" || fail "missing --sandbox read-only"
grep -q 'ARGV:.*approval_policy=never' "$FAKE_CODEX_LOG" || fail "missing -c approval_policy=never"
grep -q 'ARGV:.*--full-auto' "$FAKE_CODEX_LOG" && fail "--full-auto still present (deprecated)"
grep -q 'ARGV:.*model_reasoning_effort=xhigh' "$FAKE_CODEX_LOG" || fail "missing xhigh effort override"
grep -Eq 'STDIN_BYTES:3[0-9]{5}' "$FAKE_CODEX_LOG" || fail "prompt did not arrive via stdin"
# the 300KB prompt must NOT appear in argv
grep -q 'ARGV:.*Review this\. Review this\.' "$FAKE_CODEX_LOG" && fail "prompt leaked into argv"
pass "default codex lane: stdin prompt, explicit flags, xhigh"

# --- effort escape hatch ---
: > "$FAKE_CODEX_LOG"
COUNCIL_CODEX_EFFORT=config PATH="$FAKE_BIN:$PATH" \
  bash "$COUNCIL_SCRIPT" --codex-only "$PROMPT" "$PROJECT" || fail "config-effort invocation errored"
grep -q 'model_reasoning_effort' "$FAKE_CODEX_LOG" && fail "effort override present despite COUNCIL_CODEX_EFFORT=config"
pass "COUNCIL_CODEX_EFFORT=config omits override"

echo ""
echo "ALL CODEX INVOCATION TESTS PASSED"
