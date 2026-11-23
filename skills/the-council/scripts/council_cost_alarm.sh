# Sourced by council_invoke.sh (and tests/test_cost_alarm.sh). Defines the post-run cost guard.
# council_cost_check <seat> <actual_usd> <estimate_usd>
#   Values may carry a leading "$". "?" / empty / non-numeric / estimate<=0 => no check (returns 0, silent).
#   If actual/estimate >= COUNCIL_COST_ALARM_RATIO (default 3): prints
#     "COST ALARM: <seat> actual $X vs estimate $Y (Nx)"
#   to stdout (caller adds it to the report) and stderr, appends one line to
#   ${COUNCIL_COST_ALARM_LOG:-$HOME/.lisah/council-cost-alarms.log}, and returns 1. Otherwise returns 0.
council_cost_check() {
  local seat="$1" actual="$2" est="$3" out
  out="$(python3 - "$seat" "$actual" "$est" "${COUNCIL_COST_ALARM_RATIO:-3}" <<'PYEOF_CA'
import sys
seat, a, e, ratio = sys.argv[1:5]
try:
    a = float(a.lstrip("$")); e = float(e.lstrip("$")); ratio = float(ratio)
except ValueError:
    sys.exit(0)
if e <= 0 or a / e < ratio:
    sys.exit(0)
print(f"COST ALARM: {seat} actual ${a:.2f} vs estimate ${e:.2f} ({a/e:.1f}x)\t{a:.4f}\t{e:.4f}\t{a/e:.2f}")
PYEOF_CA
)" || return 0
  [[ -n "$out" ]] || return 0
  local line="${out%%$'\t'*}" rest="${out#*$'\t'}"
  local log="${COUNCIL_COST_ALARM_LOG:-$HOME/.lisah/council-cost-alarms.log}"
  echo "$line" >&2
  echo "$line"
  { mkdir -p "$(dirname "$log")" && printf '%s\t%s\tactual=%s\testimate=%s\tratio=%s\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$seat" $(echo "$rest" | tr '\t' ' ') >> "$log"; } 2>/dev/null || true
  return 1
}
# council_codex_actual_cost <events.jsonl> <price_in_per_M> <price_out_per_M> → "$X.XX" or "?"
# Same arithmetic as the report line: input*pin + (output+reasoning)*pout, last turn.completed wins.
council_codex_actual_cost() {
  python3 - "$@" <<'PYEOF_CC'
import json, sys
events, pin, pout = sys.argv[1:4]
u = None
for line in open(events, encoding="utf-8", errors="replace"):
    line = line.strip()
    if not line.startswith("{"): continue
    try: ev = json.loads(line)
    except Exception: continue
    if ev.get("type") == "turn.completed" and isinstance(ev.get("usage"), dict):
        u = ev["usage"]
if u is None or pin == "?": print("?"); sys.exit(0)
i, o, r = (int(u.get(k) or 0) for k in ("input_tokens", "output_tokens", "reasoning_output_tokens"))
print(f"${(i*float(pin) + (o+r)*float(pout))/1e6:.2f}")
PYEOF_CC
}
