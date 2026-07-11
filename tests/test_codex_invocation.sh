#!/usr/bin/env bash
# Asserts the v1.4.0 Codex lane:
#   1. Prompt travels via stdin (`-` + redirect), NOT argv → no ARG_MAX, no stdin-hang
#   2. Explicit flags: --sandbox read-only, --ask-for-approval never; NO --full-auto
#   3. Reasoning effort: -c model_reasoning_effort=xhigh by default;
#      COUNCIL_CODEX_EFFORT=config omits the override
#   4. Timeout enforcement: COUNCIL_TIMEOUT kills a slow codex, exit 124 is
#      classified as timeout (sentinel-based watchdog), no orphaned process
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

# --- timeout classification (watchdog / 124 path) ---
# Slow fake (30s) + COUNCIL_TIMEOUT=2: the run must come back fast, and
# $CODEX_OUT must carry the TIMEOUT placeholder (proving exit 124 was
# classified as a timeout, not the generic failure) — this is the regression
# case for the watchdog-liveness race (TERM-respecting command is reaped
# while the watchdog still sleeps its 5s grace; sentinel must fire instead).
: > "$FAKE_CODEX_LOG"
START_TS=$SECONDS
set +e
COUNCIL_TIMEOUT=2 FAKE_CODEX_SLEEP=30 PATH="$FAKE_BIN:$PATH" \
  bash "$COUNCIL_SCRIPT" --codex-only "$PROMPT" "$PROJECT" \
  > "$TMPDIR_TEST/timeout_stdout.log" 2> "$TMPDIR_TEST/timeout_stderr.log"
set -e
ELAPSED=$(( SECONDS - START_TS ))
[[ "$ELAPSED" -lt 20 ]] || fail "timeout run took ${ELAPSED}s (expected well under 30s) — COUNCIL_TIMEOUT not enforced"
CODEX_OUT_PATH="$(tail -1 "$TMPDIR_TEST/timeout_stdout.log")"
[[ -f "$CODEX_OUT_PATH" ]] || fail "no codex response path emitted on timeout run"
grep -q 'timed out' "$CODEX_OUT_PATH" || fail "timeout placeholder missing — exit 124 not classified as timeout"
grep -q 'COUNCIL_TIMEOUT' "$CODEX_OUT_PATH" || fail "timeout placeholder does not mention COUNCIL_TIMEOUT"
sleep 1  # give the OS a beat to reap
pgrep -f "$FAKE_BIN/codex" >/dev/null && fail "orphaned fake-codex process remains after timeout" || true
pass "COUNCIL_TIMEOUT enforced; exit 124 classified as timeout; no orphaned codex"

echo ""
echo "ALL CODEX INVOCATION TESTS PASSED"
