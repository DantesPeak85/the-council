#!/usr/bin/env bash
# v1.6.7 Gemini per-round routing (Tom D-20261123-10), fake gemini on PATH.
#   R1 each round -> right model (+ effort-tier derivation, thinking override written)
#   R2 explicit COUNCIL_GEMINI_MODEL pin wins over COUNCIL_ROUND
#   R3 rejected model -> ONE visible fallback: banner, report line, actual model named
#   R4 usage plan shows the Gemini model + cost, date-aware; "(Gemini excluded)" gone
#   R5 actual cost in the report line feeds the cost alarm
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
COUNCIL_SCRIPT="$REPO_ROOT/skills/the-council/scripts/council_invoke.sh"
TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

FAKE_BIN="$TMPDIR_TEST/bin"; mkdir -p "$FAKE_BIN"
cp "$REPO_ROOT/tests/fixtures/fake-gemini-routing.sh" "$FAKE_BIN/gemini"; chmod +x "$FAKE_BIN/gemini"
PROJECT="$TMPDIR_TEST/proj"; mkdir -p "$PROJECT"
git -C "$PROJECT" init -q; echo x > "$PROJECT/f.txt"; git -C "$PROJECT" add -A
git -C "$PROJECT" -c user.email=t@t -c user.name=t commit -qm i
PROMPT="$TMPDIR_TEST/prompt.txt"
python3 -c "print('Please review the change. ' * 100)" > "$PROMPT"
export FAKE_GEMINI_LOG="$TMPDIR_TEST/gemini.log"
export COUNCIL_COST_ALARM_LOG="$TMPDIR_TEST/alarms.log"

# run <env assignments...>: Gemini-only via the gemini backend; stdout/stderr captured.
run() {
  : > "$FAKE_GEMINI_LOG"; rm -rf "$PROJECT/.council-tmp"
  set +e
  env -u COUNCIL_ROUND -u COUNCIL_GEMINI_MODEL -u COUNCIL_CODEX_EFFORT -u FAKE_GEMINI_REJECT -u FAKE_GEMINI_TOKENS \
    COUNCIL_GEMINI_BACKEND=gemini GEMINI_API_KEY=test-key COUNCIL_TODAY=2026-11-24 PATH="$FAKE_BIN:$PATH" "$@" \
    bash "$COUNCIL_SCRIPT" --gemini-only --allow-unsandboxed-gemini "$PROMPT" "$PROJECT" \
    > "$TMPDIR_TEST/stdout.log" 2> "$TMPDIR_TEST/stderr.log"
  RC=$?
  set -e
}
used_model() { sed -n 's/^MODEL://p' "$FAKE_GEMINI_LOG" | tr '\n' ' ' | sed 's/ $//'; }

# R1: round -> model (explicit COUNCIL_ROUND)
for pair in routine:gemini-4-hydrogen spec:gemini-4-neon hard:gemini-4-neon voice:gemini-4-neon milestone:gemini-4-carbon; do
  r="${pair%%:*}"; want="${pair##*:}"
  run COUNCIL_ROUND="$r"
  [[ $RC -eq 0 ]] || { cat "$TMPDIR_TEST/stderr.log"; fail "R1: round $r exited $RC"; }
  [[ "$(used_model)" == "$want" ]] || fail "R1: round $r used '$(used_model)', want $want"
  grep -q '"thinkingLevel":"HIGH"' "$FAKE_GEMINI_LOG" || fail "R1: round $r did not set thinking level HIGH"
  grep -q "\"model\":\"$want\"" "$FAKE_GEMINI_LOG" || fail "R1: thinking override not scoped to $want"
  grep -q "^  Gemini: .* — model $want" "$TMPDIR_TEST/stdout.log" || fail "R1: report line does not name $want"
done
pass "R1: routine=hydrogen, spec/hard/voice=neon, milestone=carbon; thinking high; report names the model"

# R1b: derived from the Codex effort tier when COUNCIL_ROUND is unset
for pair in medium:gemini-4-hydrogen high:gemini-4-neon xhigh:gemini-4-carbon; do
  e="${pair%%:*}"; want="${pair##*:}"
  run COUNCIL_CODEX_EFFORT="$e"
  [[ "$(used_model)" == "$want" ]] || fail "R1b: effort $e used '$(used_model)', want $want"
done
run
[[ "$(used_model)" == "gemini-4-hydrogen" ]] || fail "R1b: default (no tier) should be routine/hydrogen, got '$(used_model)'"
# explicit COUNCIL_ROUND beats the effort mapping
run COUNCIL_CODEX_EFFORT=xhigh COUNCIL_ROUND=routine
[[ "$(used_model)" == "gemini-4-hydrogen" ]] || fail "R1b: COUNCIL_ROUND should override effort mapping, got '$(used_model)'"
run COUNCIL_ROUND=bogus
[[ $RC -ne 0 ]] && grep -q "COUNCIL_ROUND='bogus' invalid" "$TMPDIR_TEST/stderr.log" || fail "R1b: invalid COUNCIL_ROUND not rejected"
pass "R1b: medium/high/xhigh -> hydrogen/neon/carbon; COUNCIL_ROUND overrides; bogus round refused"

# R2: explicit pin wins
run COUNCIL_ROUND=milestone COUNCIL_GEMINI_MODEL=gemini-4-neon
[[ "$(used_model)" == "gemini-4-neon" ]] || fail "R2: pin lost to routing: '$(used_model)'"
grep -q 'explicit COUNCIL_GEMINI_MODEL pin' "$TMPDIR_TEST/stdout.log" || fail "R2: banner does not say pinned"
pass "R2: explicit COUNCIL_GEMINI_MODEL beats COUNCIL_ROUND"

# R3: rejected model -> visible fallback, once
run COUNCIL_ROUND=milestone FAKE_GEMINI_REJECT=gemini-4-carbon
[[ $RC -eq 0 ]] || { cat "$TMPDIR_TEST/stderr.log"; fail "R3: fallback run exited $RC"; }
[[ "$(used_model)" == "gemini-4-carbon gemini-4-argon" ]] || fail "R3: expected exactly carbon then argon, got '$(used_model)'"
grep -q '^GEMINI FALLBACK: gemini-4-carbon rejected (model not found); using gemini-4-argon$' "$TMPDIR_TEST/stderr.log" || fail "R3: banner line missing on stderr"
grep -q '^  Gemini: .* — model gemini-4-argon.*; GEMINI FALLBACK: gemini-4-carbon rejected (model not found); using gemini-4-argon$' "$TMPDIR_TEST/stdout.log" || fail "R3: report line lacks fallback text/actual model: $(grep '^  Gemini:' "$TMPDIR_TEST/stdout.log")"
pass "R3: rejected carbon -> one retry on argon, banner + report line, actual model named"
run COUNCIL_ROUND=milestone FAKE_GEMINI_REJECT=gemini-4-carbon,gemini-4-argon
[[ $RC -ne 0 ]] || fail "R3b: both rejected should fail"
[[ "$(used_model)" == "gemini-4-carbon gemini-4-argon" ]] || fail "R3b: must retry exactly once, got '$(used_model)'"
pass "R3b: fallback is ONE retry only; a second rejection is an honest failure"
run COUNCIL_GEMINI_MODEL=gemini-4-argon FAKE_GEMINI_REJECT=gemini-4-argon
[[ "$(used_model)" == "gemini-4-argon" ]] || fail "R3c: argon pinned must not retry itself, got '$(used_model)'"
pass "R3c: pinned fallback model is not retried"

# R4: usage plan shows model + cost, date-aware
run COUNCIL_ROUND=milestone
grep -q '^    Gemini  gemini-4-carbon: in ≈ 7.8k fixed + [0-9.]*k prompt = [0-9.]*k   out ≈ 12.0k (thinking high; round milestone)   ≈ \$[0-9.]* + \$[0-9.]* = \$[0-9.]* (Google list price, promo to 30 Nov)' "$TMPDIR_TEST/stdout.log" \
  || fail "R4: plan row wrong: $(grep '^    Gemini' "$TMPDIR_TEST/stdout.log")"
grep -q '^    Total ≈ \$[0-9.]* at list   ceiling' "$TMPDIR_TEST/stdout.log" || fail "R4: total line wrong (or still excluding Gemini): $(grep 'Total' "$TMPDIR_TEST/stdout.log")"
PROMO_COST="$(sed -n 's/^    Gemini .*= \(\$[0-9.]*\) (Google.*/\1/p' "$TMPDIR_TEST/stdout.log")"
run COUNCIL_ROUND=milestone COUNCIL_TODAY=2026-12-01
LATE_COST="$(sed -n 's/^    Gemini .*= \(\$[0-9.]*\) (Google.*/\1/p' "$TMPDIR_TEST/stdout.log")"
grep -q 'post-promo' "$TMPDIR_TEST/stdout.log" || fail "R4: no post-promo marker on 1 Dec"
python3 -c 'import sys; a,b=(float(x.lstrip("$")) for x in sys.argv[1:3]); sys.exit(0 if abs(b-2*a)<0.011 else 1)' "$PROMO_COST" "$LATE_COST" || fail "R4: carbon should double on 1 Dec ($PROMO_COST -> $LATE_COST)"
run COUNCIL_ROUND=routine
grep -q '^    Gemini  gemini-4-hydrogen: ' "$TMPDIR_TEST/stdout.log" || fail "R4: routine plan row not hydrogen"
pass "R4: plan lists model + cost; carbon $PROMO_COST -> $LATE_COST on 1 Dec; Gemini no longer excluded"

# R5: actual cost in the report line + the cost alarm
run COUNCIL_ROUND=routine FAKE_GEMINI_TOKENS="7800 100 200"
grep -q '^  Gemini: .*7.8k in / 0.1k out / 0.2k reasoning ≈ \$0.0[0-9]* list' "$TMPDIR_TEST/stdout.log" || fail "R5: actual usage missing from report line: $(grep '^  Gemini:' "$TMPDIR_TEST/stdout.log")"
grep -q 'COST ALARM: Gemini' "$TMPDIR_TEST/stdout.log" && fail "R5: alarm fired on a normal run"
run COUNCIL_ROUND=routine FAKE_GEMINI_TOKENS="500000 100 200"
grep -q '^COST ALARM: Gemini actual \$' "$TMPDIR_TEST/stdout.log" || fail "R5: runaway Gemini cost did not trip the alarm"
pass "R5: actual cost on the report line and wired into the cost alarm"
echo "ALL GEMINI ROUTING TESTS PASSED"
