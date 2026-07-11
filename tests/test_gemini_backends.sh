#!/usr/bin/env bash
# v1.4.0 Gemini lane tests.
# agy backend:
#   A1. No --add-dir <project>: agy must receive --add-dir <council tmpdir> only
#   A2. review_request.md exists in the agy workspace; --prompt is a SHORT driver
#   A3. pty wrap: fake agy only emits on a TTY — output must still be captured
#   A4. NO maxSessionTurns injection: ~/.gemini/antigravity-cli/settings.json untouched
#   A5. Response containing 'policy'/'blocked' words is NOT flagged as failure
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
COUNCIL_SCRIPT="$REPO_ROOT/skills/the-council/scripts/council_invoke.sh"
TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

FAKE_BIN="$TMPDIR_TEST/bin"; mkdir -p "$FAKE_BIN"
cp "$REPO_ROOT/tests/fixtures/fake-agy.sh" "$FAKE_BIN/agy"; chmod +x "$FAKE_BIN/agy"

PROJECT="$TMPDIR_TEST/proj"; mkdir -p "$PROJECT"
git -C "$PROJECT" init -q; echo x > "$PROJECT/f.txt"; git -C "$PROJECT" add -A
git -C "$PROJECT" -c user.email=t@t -c user.name=t commit -qm i

PROMPT="$TMPDIR_TEST/prompt.txt"
python3 -c "print('Please review the RLS policy changes. ' * 100)" > "$PROMPT"

export FAKE_AGY_LOG="$TMPDIR_TEST/agy.log"
GEMINI_SETTINGS="$HOME/.gemini/antigravity-cli/settings.json"
SETTINGS_BEFORE=""
[[ -f "$GEMINI_SETTINGS" ]] && SETTINGS_BEFORE="$(shasum "$GEMINI_SETTINGS")"

set +e
COUNCIL_GEMINI_BACKEND=agy PATH="$FAKE_BIN:$PATH" \
  bash "$COUNCIL_SCRIPT" --gemini-only --allow-unsandboxed-gemini "$PROMPT" "$PROJECT" \
  > "$TMPDIR_TEST/stdout.log" 2> "$TMPDIR_TEST/stderr.log"
RC=$?
set -e
[[ $RC -eq 0 ]] || { cat "$TMPDIR_TEST/stderr.log"; fail "gemini-only agy run exited $RC"; }

# A1: agy must NOT get the project as --add-dir. The council tmpdir is nested
# under the project ($project/.council-tmp/<run>/), so a bare substring grep for
# "--add-dir $PROJECT" would also match the (legitimate) tmpdir path — require a
# space/EOL boundary so ONLY an exact project --add-dir trips this assertion.
grep -Eq "ARGV:.*--add-dir ${PROJECT}( |\$)" "$FAKE_AGY_LOG" && fail "agy still gets project --add-dir (agentic exploration surface)"
grep -q 'ARGV:.*--add-dir.*\.council-tmp' "$FAKE_AGY_LOG" || fail "agy workspace is not the council tmpdir"
grep -q 'REQUEST_FILE_FOUND' "$FAKE_AGY_LOG" || fail "review_request.md missing from agy workspace"
grep -q 'ARGV:.*--prompt' "$FAKE_AGY_LOG" || fail "agy prompt not passed via --prompt"
pass "A1/A2: tmpdir workspace + file-based request + --prompt driver"

RESP="$(find "$PROJECT/.council-tmp" -name gemini_response.md | head -1)"
[[ -s "$RESP" ]] || fail "A3: no captured agy output (pty wrap broken?)"
grep -q 'VERDICT: APPROVE-WITH-CHANGES' "$RESP" || fail "A3: agy TTY-gated output not captured"
pass "A3: pty wrap captures TTY-only stdout"

if [[ -n "$SETTINGS_BEFORE" ]]; then
  [[ "$(shasum "$GEMINI_SETTINGS")" == "$SETTINGS_BEFORE" ]] || fail "A4: settings.json was mutated"
else
  [[ -f "$GEMINI_SETTINGS" ]] && fail "A4: settings.json was created by the script"
fi
pass "A4: no global settings mutation"

# A5: a substantive response containing 'policy'/'blocked' must NOT be flagged.
# KNOWN TASK-3 INTERACTION: the OLD validation section (rewritten in Task 5) greps
# GEMINI_FAILURE_PATTERNS — which lists 'policy|blocked' — against the response
# body, so by old-engine design it flags this response with "failed validation".
# Gate: DEFER A5 while that classifier is live, re-activate automatically once
# Task 5 removes it. No silent skip.
# NOTE: the originally-suggested gate (grep 'COUNCIL-ADVISOR-FAILURE') can't serve
# here — that placeholder is emitted by the Codex lane AND by this task's new agy
# lane, so it's already present and would never defer. We fingerprint the OLD
# response-body classifier's '|policy|blocked' pattern list instead.
if grep -q '|policy|blocked' "$COUNCIL_SCRIPT"; then
  echo "A5 DEFERRED (old validation engine still active — re-verified in Task 5)"
else
  grep -q 'failed validation' "$TMPDIR_TEST/stdout.log" "$TMPDIR_TEST/stderr.log" \
    && fail "A5: substantive response false-flagged as failure"
  pass "A5: 'policy'/'blocked' words in response not treated as failure"
fi

# gemini-cli backend:
#   G1. COUNCIL_GEMINI_BACKEND=gemini uses `gemini` CLI with --output-format json
#   G2. Request content travels via stdin; response parsed from JSON .response
#   G3. auto: GEMINI_API_KEY set + gemini in PATH → gemini backend chosen
#   G4. auto: no GEMINI_API_KEY → agy fallback chosen
cp "$REPO_ROOT/tests/fixtures/fake-gemini.sh" "$FAKE_BIN/gemini"; chmod +x "$FAKE_BIN/gemini"
export FAKE_GEMINI_LOG="$TMPDIR_TEST/gemini.log"

rm -rf "$PROJECT/.council-tmp"
set +e
COUNCIL_GEMINI_BACKEND=gemini GEMINI_API_KEY=test-key PATH="$FAKE_BIN:$PATH" \
  bash "$COUNCIL_SCRIPT" --gemini-only --allow-unsandboxed-gemini "$PROMPT" "$PROJECT" \
  > "$TMPDIR_TEST/gstdout.log" 2> "$TMPDIR_TEST/gstderr.log"
RC=$?
set -e
[[ $RC -eq 0 ]] || { cat "$TMPDIR_TEST/gstderr.log"; fail "G1: gemini backend run exited $RC"; }
grep -q 'ARGV:.*--output-format json' "$FAKE_GEMINI_LOG" || fail "G1: missing --output-format json"
grep -Eq 'STDIN_BYTES:[1-9][0-9]{2,}' "$FAKE_GEMINI_LOG" || fail "G2: request did not travel via stdin"
RESP="$(find "$PROJECT/.council-tmp" -name gemini_response.md | head -1)"
grep -q 'Fake gemini-cli review body' "$RESP" || fail "G2: .response not extracted from JSON envelope"
pass "G1/G2: gemini-cli backend, stdin request, JSON parse"

: > "$FAKE_GEMINI_LOG"; : > "$FAKE_AGY_LOG"
rm -rf "$PROJECT/.council-tmp"
COUNCIL_GEMINI_BACKEND=auto GEMINI_API_KEY=test-key PATH="$FAKE_BIN:$PATH" \
  bash "$COUNCIL_SCRIPT" --gemini-only --allow-unsandboxed-gemini "$PROMPT" "$PROJECT" >/dev/null 2>&1 \
  || fail "G3: auto+key run errored"
[[ -s "$FAKE_GEMINI_LOG" ]] || fail "G3: auto with key did not pick gemini-cli"
pass "G3: auto prefers gemini-cli when GEMINI_API_KEY set"

: > "$FAKE_GEMINI_LOG"; : > "$FAKE_AGY_LOG"
rm -rf "$PROJECT/.council-tmp"
env -u GEMINI_API_KEY COUNCIL_GEMINI_BACKEND=auto PATH="$FAKE_BIN:$PATH" \
  bash "$COUNCIL_SCRIPT" --gemini-only --allow-unsandboxed-gemini "$PROMPT" "$PROJECT" >/dev/null 2>&1 \
  || fail "G4: auto-no-key run errored"
[[ -s "$FAKE_AGY_LOG" ]] || fail "G4: auto without key did not fall back to agy"
pass "G4: auto falls back to agy without GEMINI_API_KEY"

# G5. auto + GEMINI_API_KEY set + gemini-cli DIES (FAKE_GEMINI_FAIL=1) + agy present
#     → the run falls back to agy ONCE, exits 0, and the fallback is LOUD.
: > "$FAKE_GEMINI_LOG"; : > "$FAKE_AGY_LOG"
rm -rf "$PROJECT/.council-tmp"
set +e
FAKE_GEMINI_FAIL=1 COUNCIL_GEMINI_BACKEND=auto GEMINI_API_KEY=test-key PATH="$FAKE_BIN:$PATH" \
  bash "$COUNCIL_SCRIPT" --gemini-only --allow-unsandboxed-gemini "$PROMPT" "$PROJECT" \
  > "$TMPDIR_TEST/g5stdout.log" 2> "$TMPDIR_TEST/g5stderr.log"
RC=$?
set -e
[[ $RC -eq 0 ]] || { cat "$TMPDIR_TEST/g5stderr.log"; fail "G5: fallback run should exit 0, got $RC"; }
[[ -s "$FAKE_AGY_LOG" ]] || fail "G5: gemini-cli death did not fall back to agy (agy log empty)"
grep -q 'falling back to agy' "$TMPDIR_TEST/g5stdout.log" "$TMPDIR_TEST/g5stderr.log" \
  || fail "G5: loud fallback line ('falling back to agy') missing"
pass "G5: gemini-cli failure → loud one-shot agy fallback, exit 0"

echo ""
echo "ALL GEMINI BACKEND TESTS PASSED"
