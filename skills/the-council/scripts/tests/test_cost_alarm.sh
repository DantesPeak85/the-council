#!/usr/bin/env bash
# Offline test of the cost alarm: no model, no network. Fake codex_events.jsonl at 4x and 2x the estimate.
set -u
D="$(cd "$(dirname "$0")/.." && pwd)"
source "$D/council_cost_alarm.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export COUNCIL_COST_ALARM_LOG="$T/alarms.log"
PIN=10; POUT=40                      # $/M, fake prices
EST='$1.00'                          # estimate; 4x => $4.00, 2x => $2.00
mk() { printf '{"type":"turn.started"}\n{"type":"turn.completed","usage":{"input_tokens":%s,"cached_input_tokens":0,"output_tokens":%s,"reasoning_output_tokens":0}}\n' "$2" "$3" > "$1"; }
fail=0; ok() { echo "PASS: $1"; }; bad() { echo "FAIL: $1"; fail=1; }

mk "$T/e4.jsonl" 400000 0            # 400k * $10/M = $4.00
mk "$T/e2.jsonl" 200000 0            # $2.00
a4="$(council_codex_actual_cost "$T/e4.jsonl" $PIN $POUT)"; a2="$(council_codex_actual_cost "$T/e2.jsonl" $PIN $POUT)"
echo "actual 4x=$a4 2x=$a2 estimate=$EST"

out4="$(council_cost_check Codex "$a4" "$EST" 2>"$T/err4")"; rc4=$?
[[ $rc4 -eq 1 && "$out4" == "COST ALARM: Codex actual \$4.00 vs estimate \$1.00 (4.0x)" ]] && ok "4x trips alarm: $out4" || bad "4x: rc=$rc4 out=$out4"
grep -q "COST ALARM" "$T/err4" && ok "alarm on stderr" || bad "no stderr alarm"
[[ "$(wc -l < "$T/alarms.log")" -eq 1 ]] && ok "log line: $(cat "$T/alarms.log")" || bad "log lines != 1"

out2="$(council_cost_check Codex "$a2" "$EST" 2>"$T/err2")"; rc2=$?
[[ $rc2 -eq 0 && -z "$out2" && ! -s "$T/err2" ]] && ok "2x no alarm" || bad "2x: rc=$rc2 out=$out2"
[[ "$(wc -l < "$T/alarms.log")" -eq 1 ]] && ok "2x wrote no log line" || bad "2x logged"

council_cost_check Codex '$3.00' "$EST" >/dev/null 2>&1; [[ $? -eq 1 ]] && ok "exactly 3x trips (>=)" || bad "3x"
COUNCIL_COST_ALARM_RATIO=5 council_cost_check Codex "$a4" "$EST" >/dev/null 2>&1; [[ $? -eq 0 ]] && ok "ratio env raises threshold" || bad "ratio env"
council_cost_check Codex '?' "$EST" >/dev/null 2>&1; [[ $? -eq 0 ]] && ok "unknown actual: silent" || bad "unknown"
exit $fail
