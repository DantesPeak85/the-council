#!/usr/bin/env bash
# v1.4.0 validation engine:
#   V1. Response containing 'policy'/'safety'/'blocked'/'429' English words → SUCCESS
#   V2. Empty response file → FAILURE (reason: empty response)
#   V3. Genuine refusal text → FAILURE (reason: refusal)
#   V4. Short response WITH verdict token on large prompt → SUCCESS
#   V5. Short response WITHOUT verdict token on large prompt → FAILURE (non-engagement)
#   V6. stderr matching 'RESOURCE_EXHAUSTED' + substantive response → SUCCESS + warning file
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
COUNCIL_SCRIPT="$REPO_ROOT/skills/the-council/scripts/council_invoke.sh"
TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

export COUNCIL_SOURCE_ONLY=1
# shellcheck disable=SC1090
source "$COUNCIL_SCRIPT"
unset COUNCIL_SOURCE_ONLY

OUT="$TMPDIR_TEST/resp.md"; ERR="$TMPDIR_TEST/err.log"

# V1
cat > "$OUT" <<'EOF'
VERDICT: APPROVE-WITH-CHANGES
The RLS policy is correct. Writes to cycle_history are blocked by the trigger.
Consider adding a rate limit check; see line 429 for the quota handling. This
safety-critical path looks sound overall. (Well over two hundred characters of
substantive review text to clear the length floor for engagement checking....)
EOF
: > "$ERR"
validate_response "$OUT" "$ERR" 0 5000 "Gemini" || fail "V1: substantive response with scary words flagged as failure ($VALIDATE_REASON)"
pass "V1: policy/safety/blocked/429 words in response = success"

# V2
: > "$OUT"; : > "$ERR"
validate_response "$OUT" "$ERR" 0 5000 "Gemini" && fail "V2: empty response passed validation"
[[ "$VALIDATE_REASON" == *"empty"* ]] || fail "V2: wrong reason: $VALIDATE_REASON"
pass "V2: empty response = failure"

# V3
printf 'I cannot assist with finding vulnerabilities in this codebase.' > "$OUT"; : > "$ERR"
validate_response "$OUT" "$ERR" 0 5000 "Gemini" && fail "V3: refusal passed validation"
[[ "$VALIDATE_REASON" == *"refusal"* ]] || fail "V3: wrong reason: $VALIDATE_REASON"
pass "V3: refusal detected"

# V4
printf 'VERDICT: APPROVE — no issues found; the diff is straightforward.' > "$OUT"; : > "$ERR"
validate_response "$OUT" "$ERR" 0 5000 "Gemini" || fail "V4: terse verdict flagged as non-engagement ($VALIDATE_REASON)"
pass "V4: short response WITH verdict token = success"

# V5
printf 'I am ready to help with your project.' > "$OUT"; : > "$ERR"
validate_response "$OUT" "$ERR" 0 5000 "Gemini" && fail "V5: non-engagement passed"
[[ "$VALIDATE_REASON" == *"non-engagement"* ]] || fail "V5: wrong reason: $VALIDATE_REASON"
pass "V5: short verdict-less response on large prompt = non-engagement"

# V6
cat > "$OUT" <<'EOF'
VERDICT: REVISE
Substantive review content that is comfortably longer than the two hundred
character engagement floor, discussing the migration and its rollback path in
enough detail to demonstrate the advisor genuinely engaged with the prompt.
EOF
printf 'WARN: RESOURCE_EXHAUSTED on subrequest, retried internally\n' > "$ERR"
validate_response "$OUT" "$ERR" 0 5000 "Gemini" || fail "V6: stderr warning flipped success to failure ($VALIDATE_REASON)"
[[ -s "${OUT%.md}_warnings.log" ]] || fail "V6: warning file not written"
pass "V6: stderr pattern = advisory warning, not failure"

# V7: script-written failure placeholder → FAILURE regardless of length
printf '[COUNCIL-ADVISOR-FAILURE] Gemini failed to respond (exit 7). See err.' > "$OUT"; : > "$ERR"
validate_response "$OUT" "$ERR" 0 5000 "Gemini" && fail "V7: failure placeholder passed validation"
[[ "$VALIDATE_REASON" == *"placeholder"* ]] || fail "V7: wrong reason: $VALIDATE_REASON"
pass "V7: [COUNCIL-ADVISOR-FAILURE] placeholder = failure"

# V8: nonzero exit + NO verdict line → FAILURE (no laundering)
printf 'A long stream of merged pty error spew that looks superficially like content but carries no verdict line anywhere in its head, well over the two hundred character floor so length alone cannot rescue it from the nonzero exit status it rode in on.' > "$OUT"; : > "$ERR"
rm -f "${OUT%.md}_warnings.log"
validate_response "$OUT" "$ERR" 7 5000 "Gemini" && fail "V8: nonzero exit laundered into success"
[[ "$VALIDATE_REASON" == *"exited 7"* ]] || fail "V8: wrong reason: $VALIDATE_REASON"
pass "V8: nonzero exit without verdict = failure"

# V9: nonzero exit + verdict line in head → PARTIAL success with warning
printf 'VERDICT: APPROVE-WITH-CHANGES\nComplete-looking review whose CLI died on teardown after writing everything, comfortably exceeding the two hundred character engagement floor with genuine analytical content about the change under review.' > "$OUT"; : > "$ERR"
rm -f "${OUT%.md}_warnings.log"
validate_response "$OUT" "$ERR" 7 5000 "Gemini" || fail "V9: verdict-bearing partial rejected ($VALIDATE_REASON)"
[[ -s "${OUT%.md}_warnings.log" ]] || fail "V9: partial-success warning not written"
pass "V9: nonzero exit with verdict = loud partial success"

# V10: quoted unanchored token must NOT rescue a refusal ("I cannot APPROVE this")
printf 'I cannot assist with this review request as framed; I cannot APPROVE this.' > "$OUT"; : > "$ERR"
validate_response "$OUT" "$ERR" 0 5000 "Gemini" && fail "V10: unanchored token rescued a refusal"
[[ "$VALIDATE_REASON" == *"refusal"* ]] || fail "V10: wrong reason: $VALIDATE_REASON"
pass "V10: only a normalized VERDICT: line counts, not embedded tokens"

# ============================================================================
# End-to-end aggregate exit-code cases (drive the FULL script with fake bins).
# Implementer note (brief Step 3 says test_validation_engine.sh; task text
# allows either file): kept HERE because they exercise the validation → aggregate
# exit path this task owns.
#   E1. codex-only, fake-codex dies (FAKE_CODEX_FAIL=1), no verdict → script exit 1
#   E2. gemini-only success → script exit 0
#   E3. full council, one advisor (codex) fails → script exit 1
# ============================================================================
E2E_BIN="$TMPDIR_TEST/e2e-bin"; mkdir -p "$E2E_BIN"
cp "$REPO_ROOT/tests/fixtures/fake-codex.sh" "$E2E_BIN/codex"; chmod +x "$E2E_BIN/codex"
cp "$REPO_ROOT/tests/fixtures/fake-agy.sh"   "$E2E_BIN/agy";   chmod +x "$E2E_BIN/agy"
export FAKE_CODEX_LOG="$TMPDIR_TEST/e2e-codex.log"
export FAKE_AGY_LOG="$TMPDIR_TEST/e2e-agy.log"

E2E_PROJECT="$TMPDIR_TEST/e2e-proj"; mkdir -p "$E2E_PROJECT"
git -C "$E2E_PROJECT" init -q
echo x > "$E2E_PROJECT/f.txt"; git -C "$E2E_PROJECT" add -A
git -C "$E2E_PROJECT" -c user.email=t@t -c user.name=t commit -qm i

E2E_PROMPT="$TMPDIR_TEST/e2e-prompt.txt"
python3 -c "print('Please review these changes carefully. ' * 100)" > "$E2E_PROMPT"

# E1: codex-only advisor death → exit 1
rc=0
FAKE_CODEX_FAIL=1 PATH="$E2E_BIN:$PATH" \
  bash "$COUNCIL_SCRIPT" --codex-only "$E2E_PROMPT" "$E2E_PROJECT" >/dev/null 2>&1 || rc=$?
[[ "$rc" -eq 1 ]] || fail "E1: codex-only advisor failure should exit 1, got $rc"
pass "E1: codex-only advisor failure → script exit 1"

# E2: gemini-only success → exit 0
rc=0
COUNCIL_GEMINI_BACKEND=agy PATH="$E2E_BIN:$PATH" \
  bash "$COUNCIL_SCRIPT" --gemini-only --allow-unsandboxed-gemini "$E2E_PROMPT" "$E2E_PROJECT" >/dev/null 2>&1 || rc=$?
[[ "$rc" -eq 0 ]] || fail "E2: gemini-only success should exit 0, got $rc"
pass "E2: gemini-only success → script exit 0"

# E3: full council, codex fails + gemini succeeds → exit 1
rc=0
FAKE_CODEX_FAIL=1 COUNCIL_GEMINI_BACKEND=agy PATH="$E2E_BIN:$PATH" \
  bash "$COUNCIL_SCRIPT" --allow-unsandboxed-gemini "$E2E_PROMPT" "$E2E_PROJECT" >/dev/null 2>&1 || rc=$?
[[ "$rc" -eq 1 ]] || fail "E3: full council with a failing advisor should exit 1, got $rc"
pass "E3: full council, one advisor fails → script exit 1"

echo ""
echo "ALL VALIDATION ENGINE TESTS PASSED"
