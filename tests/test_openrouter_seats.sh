#!/usr/bin/env bash
# v1.6.0 OpenRouter seat lane tests (fake curl — no network, no spend).
#   O1. `--openrouter qwen`: pin resolves, payload carries max_tokens 32000, effort
#       follows COUNCIL_CODEX_EFFORT, the prompt reaches the user turn WITH the
#       VERDICT driver, response + usage files land, exit 0, path printed last.
#   O2. Key hygiene: never in the payload, never on argv; header file is mode 600
#       and gone after the call.
#   O3. glm + a raw vendor/model id run side by side; raw id gets a slugged file.
#   O4. Starvation (empty content + reasoning tokens) → honest 'starved' failure, exit 1, usage kept.
#   O5. Error envelope (HTTP 402) → failure placeholder, exit 1.
#   O6. Timeout (curl 28) mid-stream → 'timed out' placeholder naming the salvage, partial text kept, exit 1.
#   O7. Missing OPENROUTER_API_KEY → startup error, curl never called.
#   O8. Unknown bare seat name → startup error. --openrouter-only without seats → error.
#   O9. Overrides: COUNCIL_QWEN_MODEL, COUNCIL_OPENROUTER_EFFORT/MAX_TOKENS honored; env seats work; flag beats env.
#   O10. Combined with --codex-only: both paths printed, aggregate exit reflects the seat.
#   O11. Named seats resolve to the NEWEST flagship on the live listing (numeric version order;
#        variants and alias rows ignored). Listing unreachable → last-known id + loud WARNING.
#        Listing reachable but family rule matches nothing → last-known id + WARNING.
#   O12. An explicit COUNCIL_*_MODEL skips the listing call entirely.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
COUNCIL_SCRIPT="$REPO_ROOT/skills/the-council/scripts/council_invoke.sh"
TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

FAKE_BIN="$TMPDIR_TEST/bin"; mkdir -p "$FAKE_BIN"
cp "$REPO_ROOT/tests/fixtures/fake-curl.sh" "$FAKE_BIN/curl"; chmod +x "$FAKE_BIN/curl"
cp "$REPO_ROOT/tests/fixtures/fake-codex.sh" "$FAKE_BIN/codex"; chmod +x "$FAKE_BIN/codex"
PROJECT="$TMPDIR_TEST/proj"; mkdir -p "$PROJECT"
git -C "$PROJECT" init -q; echo x > "$PROJECT/f.txt"; git -C "$PROJECT" add -A
git -C "$PROJECT" -c user.email=t@t -c user.name=t commit -qm i
PROMPT="$TMPDIR_TEST/prompt.txt"
python3 -c "print('Please review the migration plan for the cycle_history correction RPC. ' * 60)" > "$PROMPT"
export FAKE_CURL_LOG="$TMPDIR_TEST/curl.log"
FAKE_KEY="sk-or-v1-FAKEFAKEFAKE"
run() {  # run <extra env...> -- <flags...>
  : > "$FAKE_CURL_LOG"; rm -rf "$PROJECT/.council-tmp"
  set +e
  env "$@" > "$TMPDIR_TEST/stdout.log" 2> "$TMPDIR_TEST/stderr.log"; RC=$?
  set -e
}
seat_file() { find "$PROJECT/.council-tmp" -name "$1" | head -1; }

# O1
run PATH="$FAKE_BIN:$PATH" OPENROUTER_API_KEY="$FAKE_KEY" COUNCIL_CODEX_EFFORT=high \
  bash "$COUNCIL_SCRIPT" --openrouter-only --openrouter qwen "$PROMPT" "$PROJECT"
[[ $RC -eq 0 ]] || { cat "$TMPDIR_TEST/stderr.log"; fail "O1: exit $RC"; }
grep -q '^MODEL:qwen/qwen3.10-max$' "$FAKE_CURL_LOG" || fail "O1: qwen did not resolve to the newest flagship (got $(grep '^MODEL' "$FAKE_CURL_LOG"))"
grep -q '^LISTING:ok$' "$FAKE_CURL_LOG" || fail "O1: live listing was not consulted"
grep -q '^MAX_TOKENS:32000$' "$FAKE_CURL_LOG" || fail "O1: max_tokens default is not 32000"
grep -q '^EFFORT:high$' "$FAKE_CURL_LOG" || fail "O1: effort did not follow COUNCIL_CODEX_EFFORT"
grep -Eq '^USER_BYTES:[1-9][0-9]{3,}$' "$FAKE_CURL_LOG" || fail "O1: prompt did not reach the user turn"
grep -q '^USER_HAS_VERDICT_DRIVER:True$' "$FAKE_CURL_LOG" || fail "O1: VERDICT driver missing from user turn"
grep -q '^STREAM:True$' "$FAKE_CURL_LOG" || fail "O1: request is not streamed"
grep -q 'ARGV:.* -N ' "$FAKE_CURL_LOG" || fail "O1: curl not in no-buffer (-N) mode"
grep -q '^MAX_TIME:600$' "$FAKE_CURL_LOG" || fail "O1: --max-time not wired to COUNCIL_TIMEOUT"
RESP="$(seat_file qwen_response.md)"; [[ -s "$RESP" ]] || fail "O1: qwen_response.md missing"
grep -q 'VERDICT: APPROVE-WITH-CHANGES' "$RESP" || fail "O1: content not extracted"
grep -q 'no rollback gate for the migration step' "$RESP" || fail "O1: SSE chunks not reassembled to the end"
USAGE="$(seat_file qwen_usage.log)"; grep -q 'model_served=fake/served-0902' "$USAGE" || fail "O1: usage log missing served model"
grep -q 'cost_usd=0.0041' "$USAGE" || fail "O1: usage log missing cost"
[[ "$(tail -1 "$TMPDIR_TEST/stdout.log")" == "$RESP" ]] || fail "O1: response path not printed last"
grep -q 'OpenRouter seat: Qwen → qwen/qwen3.10-max (newest on the live listing)' "$TMPDIR_TEST/stdout.log" || fail "O1: banner line missing/mislabeled"
grep -q 'Qwen: .*(success)' "$TMPDIR_TEST/stdout.log" || fail "O1: report line missing"
# A clean run must be a CLEAN success: no partial-success downgrade, no shell error
# (live 2026-09-06: an EXIT trap naming a function-local died 'unbound variable'
# after every good response, and the verdict-bearing-partial rule hid it).
[[ -z "$(seat_file qwen_response_warnings.log)" ]] || fail "O1: clean run was downgraded to partial ($(cat "$(seat_file qwen_response_warnings.log)"))"
grep -Eq 'unbound variable|command not found|syntax error' "$TMPDIR_TEST/stderr.log" && fail "O1: shell error during a clean run: $(grep -E 'unbound|not found|syntax' "$TMPDIR_TEST/stderr.log" | head -1)"
pass "O1: qwen seat end-to-end (pin, budget, effort, driver, files, banner, exit 0)"

# O2
grep -q '^PAYLOAD_HAS_KEY:False$' "$FAKE_CURL_LOG" || fail "O2: key leaked into payload"
grep 'ARGV:' "$FAKE_CURL_LOG" | grep -q "$FAKE_KEY" && fail "O2: key on curl argv"
grep -q '^HDR_FILE_MODE:600$' "$FAKE_CURL_LOG" || fail "O2: header file not mode 600 ($(grep HDR_FILE_MODE "$FAKE_CURL_LOG"))"
grep -q '^HDR_FILE_HAS_BEARER:1$' "$FAKE_CURL_LOG" || fail "O2: header file lacked the bearer line"
HDR_PATH="$(grep -o 'ARGV:.*' "$FAKE_CURL_LOG" | grep -oE '@[^ ]*council_or_hdr[^ ]*' | head -1 | tr -d '@')"
[[ -n "$HDR_PATH" ]] || fail "O2: header file path not found on argv"
[[ ! -e "$HDR_PATH" ]] || fail "O2: header file left on disk at $HDR_PATH"
[[ "$HDR_PATH" != "$PROJECT"* ]] || fail "O2: header file placed under the project tree"
grep -rq "$FAKE_KEY" "$PROJECT/.council-tmp" && fail "O2: key persisted somewhere under .council-tmp"
pass "O2: key only via mode-600 header file, deleted after the call"

# O3
run PATH="$FAKE_BIN:$PATH" OPENROUTER_API_KEY="$FAKE_KEY" \
  bash "$COUNCIL_SCRIPT" --openrouter-only --openrouter "glm, vendor/x-model-2" "$PROMPT" "$PROJECT"
[[ $RC -eq 0 ]] || { cat "$TMPDIR_TEST/stderr.log"; fail "O3: exit $RC"; }
grep -q '^MODEL:z-ai/glm-5.3$' "$FAKE_CURL_LOG" || fail "O3: glm pin not resolved"
grep -q '^MODEL:vendor/x-model-2$' "$FAKE_CURL_LOG" || fail "O3: raw id not passed verbatim"
[[ -s "$(seat_file glm_response.md)" ]] || fail "O3: glm_response.md missing"
[[ -s "$(seat_file vendor_x-model-2_response.md)" ]] || fail "O3: raw-id response not slugged"
grep -q 'GLM: .*(success)' "$TMPDIR_TEST/stdout.log" || fail "O3: GLM report line missing"
[[ "$(grep -c '^MODEL:' "$FAKE_CURL_LOG")" -eq 2 ]] || fail "O3: expected exactly 2 calls"
[[ "$(grep -c '^LISTING:' "$FAKE_CURL_LOG")" -eq 1 ]] || fail "O3: listing must be fetched exactly once per run"
grep -q 'OpenRouter seat: vendor/x-model-2 → vendor/x-model-2 (raw vendor/model id)' "$TMPDIR_TEST/stdout.log" || fail "O3: raw id banner"
pass "O3: glm + raw id run side by side, slugged files"

# O4
run PATH="$FAKE_BIN:$PATH" OPENROUTER_API_KEY="$FAKE_KEY" FAKE_CURL_MODE=starved \
  bash "$COUNCIL_SCRIPT" --openrouter-only --openrouter qwen "$PROMPT" "$PROJECT"
[[ $RC -eq 1 ]] || fail "O4: starved run must exit 1, got $RC"
RESP="$(seat_file qwen_response.md)"
head -1 "$RESP" | grep -q 'COUNCIL-ADVISOR-FAILURE.*starved: 9000 reasoning tokens' || fail "O4: starvation not named ($(head -1 "$RESP"))"
grep -q 'reasoning_tokens=9000' "$(seat_file qwen_usage.log)" || fail "O4: usage not kept on starvation"
grep -q 'Qwen: .*(failed: placeholder' "$TMPDIR_TEST/stdout.log" || fail "O4: report does not show failure"
pass "O4: starvation → honest failure, usage preserved, exit 1"

# O5
run PATH="$FAKE_BIN:$PATH" OPENROUTER_API_KEY="$FAKE_KEY" FAKE_CURL_MODE=http402 \
  bash "$COUNCIL_SCRIPT" --openrouter-only --openrouter glm "$PROMPT" "$PROJECT"
[[ $RC -eq 1 ]] || fail "O5: error envelope must exit 1, got $RC"
head -1 "$(seat_file glm_response.md)" | grep -q 'HTTP 402: Insufficient credits' || fail "O5: error message not surfaced"
run PATH="$FAKE_BIN:$PATH" OPENROUTER_API_KEY="$FAKE_KEY" FAKE_CURL_MODE=badjson \
  bash "$COUNCIL_SCRIPT" --openrouter-only --openrouter glm "$PROMPT" "$PROJECT"
[[ $RC -eq 1 ]] || fail "O5b: non-JSON body must exit 1, got $RC"
head -1 "$(seat_file glm_response.md)" | grep -q 'HTTP 502: <html>bad gateway' || fail "O5b: non-JSON body excerpt not surfaced ($(head -1 "$(seat_file glm_response.md)"))"
pass "O5: error envelope + non-JSON body → placeholder, exit 1"

# O6
run PATH="$FAKE_BIN:$PATH" OPENROUTER_API_KEY="$FAKE_KEY" FAKE_CURL_MODE=timeout COUNCIL_TIMEOUT=7 \
  bash "$COUNCIL_SCRIPT" --openrouter-only --openrouter qwen "$PROMPT" "$PROJECT"
[[ $RC -eq 1 ]] || fail "O6: timeout must exit 1, got $RC"
head -1 "$(seat_file qwen_response.md)" | grep -q 'timed out (COUNCIL_TIMEOUT=7s) after streaming [1-9][0-9]* chars' || fail "O6: timeout not named with salvage count ($(head -1 "$(seat_file qwen_response.md)"))"
PART="$(seat_file qwen_partial.md)"; [[ -s "$PART" ]] || fail "O6: partial text not salvaged"
grep -q '^VERDICT: APPROVE-WITH-CHANGES' "$PART" || fail "O6: salvaged text wrong"
grep -q 'chars salvaged' "$TMPDIR_TEST/stderr.log" || fail "O6: salvage not reported"
grep -q '^MAX_TIME:7$' "$FAKE_CURL_LOG" || fail "O6: COUNCIL_TIMEOUT not passed as --max-time"
pass "O6: curl 28 → timed-out placeholder, exit 1"

# O7
run -u OPENROUTER_API_KEY PATH="$FAKE_BIN:$PATH" \
  bash "$COUNCIL_SCRIPT" --openrouter-only --openrouter qwen "$PROMPT" "$PROJECT"
[[ $RC -eq 1 ]] || fail "O7: missing key must exit 1, got $RC"
grep -q 'OPENROUTER_API_KEY is not set' "$TMPDIR_TEST/stderr.log" || fail "O7: missing-key message absent"
[[ ! -s "$FAKE_CURL_LOG" ]] || fail "O7: curl was called without a key"
pass "O7: missing key fails at startup, no call made"

# O8
run PATH="$FAKE_BIN:$PATH" OPENROUTER_API_KEY="$FAKE_KEY" \
  bash "$COUNCIL_SCRIPT" --openrouter-only --openrouter qwne "$PROMPT" "$PROJECT"
[[ $RC -eq 1 ]] || fail "O8: unknown seat must exit 1, got $RC"
grep -q "unknown OpenRouter seat 'qwne'" "$TMPDIR_TEST/stderr.log" || fail "O8: unknown-seat message absent"
[[ ! -s "$FAKE_CURL_LOG" ]] || fail "O8: curl called despite unknown seat"
run PATH="$FAKE_BIN:$PATH" OPENROUTER_API_KEY="$FAKE_KEY" \
  bash "$COUNCIL_SCRIPT" --openrouter-only "$PROMPT" "$PROJECT"
[[ $RC -eq 1 ]] || fail "O8b: --openrouter-only without seats must exit 1, got $RC"
grep -q 'needs at least one seat' "$TMPDIR_TEST/stderr.log" || fail "O8b: message absent"
run PATH="$FAKE_BIN:$PATH" OPENROUTER_API_KEY="$FAKE_KEY" COUNCIL_OPENROUTER_EFFORT=turbo \
  bash "$COUNCIL_SCRIPT" --openrouter-only --openrouter qwen "$PROMPT" "$PROJECT"
[[ $RC -eq 1 ]] || fail "O8c: bad effort must exit 1, got $RC"
pass "O8: unknown seat / no seats / bad effort all fail at startup"

# O9
run PATH="$FAKE_BIN:$PATH" OPENROUTER_API_KEY="$FAKE_KEY" COUNCIL_OPENROUTER_SEATS=glm \
  COUNCIL_QWEN_MODEL=qwen/custom-max COUNCIL_OPENROUTER_EFFORT=none COUNCIL_OPENROUTER_MAX_TOKENS=40000 \
  bash "$COUNCIL_SCRIPT" --openrouter-only --openrouter "qwen,qwen" "$PROMPT" "$PROJECT"
[[ $RC -eq 0 ]] || { cat "$TMPDIR_TEST/stderr.log"; fail "O9: exit $RC"; }
grep -q '^MODEL:qwen/custom-max$' "$FAKE_CURL_LOG" || fail "O9: COUNCIL_QWEN_MODEL override ignored"
grep -q '^MODEL:z-ai' "$FAKE_CURL_LOG" && fail "O9: env seats ran although the flag should win"
[[ "$(grep -c '^MODEL:' "$FAKE_CURL_LOG")" -eq 1 ]] || fail "O9: duplicate seat not de-duplicated"
grep -q '^EFFORT:absent$' "$FAKE_CURL_LOG" || fail "O9: effort=none still sent a reasoning block"
grep -q '^MAX_TOKENS:40000$' "$FAKE_CURL_LOG" || fail "O9: max_tokens override ignored"
run PATH="$FAKE_BIN:$PATH" OPENROUTER_API_KEY="$FAKE_KEY" COUNCIL_OPENROUTER_SEATS=glm \
  bash "$COUNCIL_SCRIPT" --openrouter-only "$PROMPT" "$PROJECT"
[[ $RC -eq 0 ]] || fail "O9b: env-only seats exit $RC"
grep -q '^MODEL:z-ai/glm-5.3$' "$FAKE_CURL_LOG" || fail "O9b: COUNCIL_OPENROUTER_SEATS env ignored"
pass "O9: overrides, dedupe, flag-beats-env, effort=none"

# O10
export FAKE_CODEX_LOG="$TMPDIR_TEST/codex.log"
run PATH="$FAKE_BIN:$PATH" OPENROUTER_API_KEY="$FAKE_KEY" FAKE_CURL_MODE=starved \
  bash "$COUNCIL_SCRIPT" --codex-only --openrouter qwen "$PROMPT" "$PROJECT"
[[ $RC -eq 1 ]] || fail "O10: codex ok + qwen starved must exit 1, got $RC"
grep -q 'Invoking The Council (Codex-only + OpenRouter (qwen))' "$TMPDIR_TEST/stdout.log" || fail "O10: mode label wrong"
grep -q 'Codex: .*(success)' "$TMPDIR_TEST/stdout.log" || fail "O10: codex not reported success"
tail -2 "$TMPDIR_TEST/stdout.log" | grep -q 'codex_response.md' || fail "O10: codex path not in output"
tail -1 "$TMPDIR_TEST/stdout.log" | grep -q 'qwen_response.md' || fail "O10: qwen path not last"
[[ -s "$FAKE_CODEX_LOG" ]] || fail "O10: codex not invoked"
pass "O10: codex + seat combined; aggregate exit reflects the failed seat"

# O11
run PATH="$FAKE_BIN:$PATH" OPENROUTER_API_KEY="$FAKE_KEY" FAKE_CURL_LISTING_MODE=fail \
  bash "$COUNCIL_SCRIPT" --openrouter-only --openrouter "qwen,glm" "$PROMPT" "$PROJECT"
[[ $RC -eq 0 ]] || { cat "$TMPDIR_TEST/stderr.log"; fail "O11: fallback run exit $RC"; }
grep -q '^MODEL:qwen/qwen3.8-max-0902$' "$FAKE_CURL_LOG" || fail "O11: qwen fallback id not used"
grep -q '^MODEL:z-ai/glm-5.3$' "$FAKE_CURL_LOG" || fail "O11: glm fallback id not used"
grep -q 'WARNING: OpenRouter model listing unreachable' "$TMPDIR_TEST/stderr.log" || fail "O11: no loud warning on stderr"
grep -q 'FALLBACK last-known id' "$TMPDIR_TEST/stdout.log" || fail "O11: banner does not flag the fallback"
grep -q 'WARNING: OpenRouter model listing unreachable' "$TMPDIR_TEST/stdout.log" || fail "O11: banner warning line missing"
run PATH="$FAKE_BIN:$PATH" OPENROUTER_API_KEY="$FAKE_KEY" FAKE_CURL_LISTING_MODE=garbage \
  bash "$COUNCIL_SCRIPT" --openrouter-only --openrouter qwen "$PROMPT" "$PROJECT"
[[ $RC -eq 0 ]] || fail "O11b: garbage listing run exit $RC"
grep -q '^MODEL:qwen/qwen3.8-max-0902$' "$FAKE_CURL_LOG" || fail "O11b: unparseable listing did not fall back"
run PATH="$FAKE_BIN:$PATH" OPENROUTER_API_KEY="$FAKE_KEY" FAKE_CURL_LISTING_MODE=empty \
  bash "$COUNCIL_SCRIPT" --openrouter-only --openrouter glm "$PROMPT" "$PROJECT"
[[ $RC -eq 0 ]] || fail "O11c: empty listing run exit $RC"
grep -q '^MODEL:z-ai/glm-5.3$' "$FAKE_CURL_LOG" || fail "O11c: no-match did not fall back"
grep -q "no model on the listing matched the 'glm' family rule" "$TMPDIR_TEST/stderr.log" || fail "O11c: no-match warning missing"
grep -q 'listing loaded but nothing matched the family rule' "$TMPDIR_TEST/stdout.log" || fail "O11c: banner must say the listing LOADED (not 'unavailable')"
grep -q 'listing unavailable' "$TMPDIR_TEST/stdout.log" && fail "O11c: banner falsely claims the listing was unavailable"
pass "O11: newest-on-listing by default; unreachable/garbage/no-match → last-known id, loudly"

# O12
run PATH="$FAKE_BIN:$PATH" OPENROUTER_API_KEY="$FAKE_KEY" COUNCIL_QWEN_MODEL=qwen/pinned COUNCIL_GLM_MODEL=z-ai/pinned \
  bash "$COUNCIL_SCRIPT" --openrouter-only --openrouter "qwen,glm,vendor/raw" "$PROMPT" "$PROJECT"
[[ $RC -eq 0 ]] || fail "O12: exit $RC"
grep -q '^LISTING:' "$FAKE_CURL_LOG" && fail "O12: listing fetched although every named seat was overridden"
grep -q 'Qwen → qwen/pinned (explicit id via COUNCIL_\*_MODEL)' "$TMPDIR_TEST/stdout.log" || fail "O12: override not labeled explicit"
pass "O12: explicit ids skip the listing call"

# O13: unit — pick_latest_openrouter_model rule edge cases via the test seam
LISTING="$TMPDIR_TEST/listing.json"
cat > "$LISTING" <<'JSON'
{"data":[{"id":"qwen/qwen4-max","created":1},{"id":"qwen/qwen3.12-max-1101","created":9},{"id":"qwen/qwen4-max-preview","created":9},
         {"id":"z-ai/glm-6","created":1},{"id":"z-ai/glm-5.9","created":9},{"id":"z-ai/glm-6-flash","created":9},{"id":"z-ai/glm-6v","created":9}]}
JSON
Q="$(COUNCIL_SOURCE_ONLY=1 bash -c 'source "$1"; pick_latest_openrouter_model "$2" qwen' _ "$COUNCIL_SCRIPT" "$LISTING")"
[[ "$Q" == "qwen/qwen4-max" ]] || fail "O13: qwen rule picked $Q (expected qwen/qwen4-max: 4 > 3.12, preview ignored)"
G="$(COUNCIL_SOURCE_ONLY=1 bash -c 'source "$1"; pick_latest_openrouter_model "$2" glm' _ "$COUNCIL_SCRIPT" "$LISTING")"
[[ "$G" == "z-ai/glm-6" ]] || fail "O13: glm rule picked $G (expected z-ai/glm-6: 6 > 5.9, flash/vision ignored)"
pass "O13: family rules — numeric version order, variants excluded"

# O14: two raw ids that slug to the same filename must be refused at startup (GLM finding, 2026-09-06)
run PATH="$FAKE_BIN:$PATH" OPENROUTER_API_KEY="$FAKE_KEY" \
  bash "$COUNCIL_SCRIPT" --openrouter-only --openrouter "vendor/a_b,vendor/a/b" "$PROMPT" "$PROJECT"
[[ $RC -eq 1 ]] || fail "O14: slug collision must exit 1, got $RC"
grep -q "collide on output filename 'vendor_a_b_\*'" "$TMPDIR_TEST/stderr.log" || fail "O14: collision message missing ($(cat "$TMPDIR_TEST/stderr.log"))"
grep -q '^MODEL:' "$FAKE_CURL_LOG" && fail "O14: a seat was called despite the collision"
pass "O14: slug collision refused at startup"

# O15: a pre-7.55 curl cannot send `-H @file` — refuse at startup, never a mid-run 401
run PATH="$FAKE_BIN:$PATH" OPENROUTER_API_KEY="$FAKE_KEY" FAKE_CURL_OLD_VERSION=1 \
  bash "$COUNCIL_SCRIPT" --openrouter-only --openrouter qwen "$PROMPT" "$PROJECT"
[[ $RC -eq 1 ]] || fail "O15: old curl must exit 1, got $RC"
grep -q 'need curl >= 7.55 (found: curl 7.54.0' "$TMPDIR_TEST/stderr.log" || fail "O15: version-gate message missing ($(cat "$TMPDIR_TEST/stderr.log"))"
grep -q '^MODEL:' "$FAKE_CURL_LOG" && fail "O15: a seat was called despite the old curl"
pass "O15: curl version gate fails at startup"

# O16: stream-completion contract (Codex R2 High, 2026-09-06) — a verdict-bearing stream that
#      ends without completion, carries a malformed event, or finishes on `length` is a FAILURE
#      with the text preserved, never a success.
for mode in eof-early malformed length; do
  run PATH="$FAKE_BIN:$PATH" OPENROUTER_API_KEY="$FAKE_KEY" FAKE_CURL_MODE=$mode \
    bash "$COUNCIL_SCRIPT" --openrouter-only --openrouter qwen "$PROMPT" "$PROJECT"
  [[ $RC -eq 1 ]] || fail "O16/$mode: must exit 1, got $RC"
  RESP="$(seat_file qwen_response.md)"
  head -1 "$RESP" | grep -q 'COUNCIL-ADVISOR-FAILURE' || fail "O16/$mode: not a failure placeholder ($(head -1 "$RESP"))"
  PART="$(seat_file qwen_partial.md)"; [[ -s "$PART" ]] || fail "O16/$mode: streamed text not preserved"
  grep -q '^VERDICT: APPROVE-WITH-CHANGES' "$PART" || fail "O16/$mode: preserved text wrong"
  head -1 "$RESP" | grep -q 'chars preserved' || fail "O16/$mode: placeholder does not point at the preserved text"
done
run PATH="$FAKE_BIN:$PATH" OPENROUTER_API_KEY="$FAKE_KEY" FAKE_CURL_MODE=eof-early \
  bash "$COUNCIL_SCRIPT" --openrouter-only --openrouter qwen "$PROMPT" "$PROJECT"
head -1 "$(seat_file qwen_response.md)" | grep -q 'without a successful finish_reason for choice 0' || fail "O16: eof-early cause not named"
run PATH="$FAKE_BIN:$PATH" OPENROUTER_API_KEY="$FAKE_KEY" FAKE_CURL_MODE=malformed \
  bash "$COUNCIL_SCRIPT" --openrouter-only --openrouter qwen "$PROMPT" "$PROJECT"
head -1 "$(seat_file qwen_response.md)" | grep -q 'malformed event' || fail "O16: malformed cause not named"
run PATH="$FAKE_BIN:$PATH" OPENROUTER_API_KEY="$FAKE_KEY" FAKE_CURL_MODE=length \
  bash "$COUNCIL_SCRIPT" --openrouter-only --openrouter qwen "$PROMPT" "$PROJECT"
head -1 "$(seat_file qwen_response.md)" | grep -q 'finish_reason=length' || fail "O16: length cause not named"
grep -q 'reasoning_tokens=31000' "$(seat_file qwen_usage.log)" || fail "O16: usage not kept on length"
pass "O16: incomplete / malformed / length streams fail loudly with text preserved"

# O17: a NON-streaming body with no finish_reason is a complete review (Qwen+GLM live finding, 2026-09-06)
run PATH="$FAKE_BIN:$PATH" OPENROUTER_API_KEY="$FAKE_KEY" FAKE_CURL_MODE=nonstream-nofinish \
  bash "$COUNCIL_SCRIPT" --openrouter-only --openrouter qwen "$PROMPT" "$PROJECT"
[[ $RC -eq 0 ]] || { cat "$TMPDIR_TEST/stderr.log"; fail "O17: non-streaming reply without finish_reason must succeed, got $RC"; }
grep -q '^VERDICT: APPROVE' "$(seat_file qwen_response.md)" || fail "O17: content not extracted"
grep -q 'model_served=fake/nonstream' "$(seat_file qwen_usage.log)" || fail "O17: usage not recorded"
pass "O17: non-streaming body without finish_reason accepted"

# O18: choice-0 terminal-state contract (Codex R3, 2026-09-06) — every shape that is not
#      "choice 0 finished with stop, nothing after" is a failure with the text preserved.
check_fail() {  # <mode> <expected cause substring>
  run PATH="$FAKE_BIN:$PATH" OPENROUTER_API_KEY="$FAKE_KEY" FAKE_CURL_MODE=$1 \
    bash "$COUNCIL_SCRIPT" --openrouter-only --openrouter qwen "$PROMPT" "$PROJECT"
  [[ $RC -eq 1 ]] || fail "O18/$1: must exit 1, got $RC"
  local head1; head1="$(head -1 "$(seat_file qwen_response.md)")"
  echo "$head1" | grep -q 'COUNCIL-ADVISOR-FAILURE' || fail "O18/$1: not a failure ($head1)"
  echo "$head1" | grep -q -- "$2" || fail "O18/$1: cause not named — wanted '$2', got: $head1"
  [[ -s "$(seat_file qwen_partial.md)" ]] || fail "O18/$1: streamed text not preserved"
  grep -q '^VERDICT: APPROVE-WITH-CHANGES' "$(seat_file qwen_partial.md)" || fail "O18/$1: preserved text wrong"
}
check_fail done-nofinish      'without a successful finish_reason for choice 0'
check_fail length-then-stop   'finish_reason=length'
check_fail content-after-stop 'content arrived after finish_reason=stop'
check_fail mixed-index        'choice index other than 0'
check_fail error-after-text   'HTTP 200: upstream provider reset'
grep -q 'cost_usd=0.003' "$(seat_file qwen_usage.log)" || fail "O18/error-after-text: usage seen before the error was not kept"
pass "O18: [DONE]-only, length→stop, content-after-stop, mixed index, error-after-text all fail with text preserved"

echo ""
echo "ALL OPENROUTER SEAT TESTS PASSED"
