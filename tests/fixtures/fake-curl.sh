#!/usr/bin/env bash
# Fake curl for the OpenRouter seat lane. Understands only the argv shape
# council_invoke.sh emits (-o <raw> -w <fmt> -H @<hdrfile> -H <str> --data-binary @<payload> <url>).
# Logs ARGV + a payload digest to $FAKE_CURL_LOG. Modes via FAKE_CURL_MODE:
#   ok (default) | starved | http402 | badjson | timeout | eof-early | malformed | length | nonstream-nofinish
#   done-nofinish | length-then-stop | content-after-stop | mixed-index | error-after-text
set -euo pipefail
# The lane gates on curl >= 7.55 (`-H @file`); answer the probe like a real curl.
# FAKE_CURL_OLD_VERSION=1 impersonates a pre-7.55 curl so the gate itself is testable.
if [[ "${1:-}" == "--version" ]]; then
  [[ "${FAKE_CURL_OLD_VERSION:-}" == "1" ]] && { echo "curl 7.54.0 (fake-old) libcurl/7.54.0"; exit 0; }
  echo "curl 8.7.1 (fake) libcurl/8.7.1"; exit 0
fi
OUT=""; PAYLOAD=""; HDR_FILES=(); URL=""
ARGS=("$@"); i=0
while [[ $i -lt ${#ARGS[@]} ]]; do
  case "${ARGS[$i]}" in
    http://*|https://*) URL="${ARGS[$i]}"; i=$((i+1)) ;;
    -o) OUT="${ARGS[$((i+1))]}"; i=$((i+2)) ;;
    -w) i=$((i+2)) ;;
    --max-time) MAXT="${ARGS[$((i+1))]}"; i=$((i+2)) ;;
    -H) [[ "${ARGS[$((i+1))]}" == @* ]] && HDR_FILES+=("${ARGS[$((i+1))]#@}"); i=$((i+2)) ;;
    --data-binary) PAYLOAD="${ARGS[$((i+1))]#@}"; i=$((i+2)) ;;
    *) i=$((i+1)) ;;
  esac
done
# --- model listing (public GET /models) ---
if [[ "$URL" == */models ]]; then
  printf 'LISTING:%s\n' "${FAKE_CURL_LISTING_MODE:-ok}" >> "${FAKE_CURL_LOG:?}"
  case "${FAKE_CURL_LISTING_MODE:-ok}" in
    fail) exit 7 ;;
    garbage) printf '<html>503</html>' > "$OUT"; printf '503'; exit 0 ;;
    empty) printf '{"data":[]}' > "$OUT"; printf '200'; exit 0 ;;
  esac
  # Decoys prove the rule: 3.10 beats 3.8 numerically; preview/thinking/flash/turbo/
  # :free/:batch variants and the odd '~' alias rows are ignored; created is a tiebreak only.
  cat > "$OUT" <<'JSON'
{"data":[
 {"id":"qwen/qwen3.8-max-0902","created":1000},
 {"id":"qwen/qwen3.8-max","created":900},
 {"id":"qwen/qwen3.10-max","created":500},
 {"id":"qwen/qwen3.10-max:free","created":2000},
 {"id":"qwen/qwen3.11-max-preview","created":3000},
 {"id":"qwen/qwen3-max-thinking","created":3000},
 {"id":"qwen/qwen3.9-flash","created":3000},
 {"id":"z-ai/glm-5.3","created":1000},
 {"id":"z-ai/glm-5.3-flash","created":3000},
 {"id":"z-ai/glm-5-turbo","created":3000},
 {"id":"z-ai/glm-4.7","created":3000},
 {"id":"~z-ai/glm-latest","created":3000},
 {"id":"z-ai/glm-5.3:batch","created":3000}
]}
JSON
  printf '200'; exit 0
fi
{
  printf 'ARGV:'; printf ' %q' "$@"; printf '\n'
  printf 'MAX_TIME:%s\n' "${MAXT:-}"
  for h in ${HDR_FILES[@]+"${HDR_FILES[@]}"}; do
    printf 'HDR_FILE_MODE:%s\n' "$(stat -f %Lp "$h" 2>/dev/null || stat -c %a "$h" 2>/dev/null)"
    printf 'HDR_FILE_HAS_BEARER:%s\n' "$(grep -c 'Authorization: Bearer' "$h" || true)"
  done
  python3 - "$PAYLOAD" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
u = [m for m in d["messages"] if m["role"] == "user"][0]["content"]
print(f"MODEL:{d['model']}")
print(f"MAX_TOKENS:{d['max_tokens']}")
print(f"EFFORT:{(d.get('reasoning') or {}).get('effort', 'absent')}")
print(f"USER_BYTES:{len(u.encode())}")
print(f"USER_HAS_VERDICT_DRIVER:{'VERDICT:' in u}")
print(f"PAYLOAD_HAS_KEY:{'sk-or-' in open(sys.argv[1]).read()}")
print(f"STREAM:{d.get('stream')}")
PY
} >> "${FAKE_CURL_LOG:?}"
mode="${FAKE_CURL_MODE:-ok}"
sse_head() { printf 'data: {"id":"x","model":"%s","choices":[{"index":0,"delta":{"role":"assistant","content":"VERDICT: APPROVE-WITH-CHANGES\\n"}}]}\n\n: OPENROUTER PROCESSING\n\n' "$1"; }
sse_body() { printf 'data: {"id":"x","model":"%s","choices":[{"index":0,"delta":{"content":"Fake OpenRouter seat review body. It is long enough to clear the two-hundred-character engagement floor that the validation engine applies to responses on large prompts, "}}]}\n\n' "$1"; }
case "$mode" in
  timeout)
    # A slow model: two chunks streamed, then the clock runs out (curl exit 28).
    # Real curl reports code 000 on a timeout — the salvage path must not depend on a 2xx.
    { sse_head fake/served-slow; sse_body fake/served-slow; } > "$OUT"; printf '000'; exit 28 ;;
  nonstream-nofinish)
    # A backend that ignored `stream` and omits finish_reason on a good reply — a parsed body IS complete.
    printf '{"id":"x","model":"fake/nonstream","choices":[{"index":0,"message":{"role":"assistant","content":"VERDICT: APPROVE\\nNon-streaming body, no finish_reason, long enough to clear the two-hundred-character engagement floor the validation engine applies on large prompts; it should be accepted as a complete review."}}],"usage":{"prompt_tokens":1000,"completion_tokens":90,"cost":0.001,"completion_tokens_details":{"reasoning_tokens":10}}}' > "$OUT"; printf '200'; exit 0 ;;
  eof-early)
    # Clean HTTP close with a verdict streamed but NO finish_reason and NO [DONE] (curl exit 0).
    { sse_head fake/served; sse_body fake/served; } > "$OUT"; printf '200'; exit 0 ;;
  malformed)
    # A verdict, then a garbage event, then a tidy [DONE] — must not launder into success.
    { sse_head fake/served; printf 'data: {"id":"x","choices":[{"index":0,"delta":{"content":"partial…"}\n\ndata: [DONE]\n'; } > "$OUT"; printf '200'; exit 0 ;;
  length)
    # Budget exhausted mid-review: real text, finish_reason=length, usage present.
    { sse_head fake/served; sse_body fake/served
      printf 'data: {"id":"x","model":"fake/served","choices":[{"index":0,"delta":{"content":"and then it ran ou"},"finish_reason":"length"}],"usage":{"prompt_tokens":1200,"completion_tokens":32000,"cost":0.2,"completion_tokens_details":{"reasoning_tokens":31000}}}\n\ndata: [DONE]\n'
    } > "$OUT"; printf '200'; exit 0 ;;
  done-nofinish)
    # Text, then [DONE] with no finish_reason ever — transport ended, review did not finish.
    { sse_head fake/served; sse_body fake/served; printf 'data: [DONE]\n'; } > "$OUT"; printf '200'; exit 0 ;;
  length-then-stop)
    # A `length` finish followed by a later `stop` — the FIRST finish is binding.
    { sse_head fake/served
      printf 'data: {"id":"x","choices":[{"index":0,"delta":{"content":"cut"},"finish_reason":"length"}]}\n\n'
      printf 'data: {"id":"x","choices":[{"index":0,"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":1,"completion_tokens":2,"cost":0.001}}\n\ndata: [DONE]\n'; } > "$OUT"; printf '200'; exit 0 ;;
  content-after-stop)
    # `stop`, then more content, then EOF — the earlier stop must not authorize success.
    { sse_head fake/served; sse_body fake/served
      printf 'data: {"id":"x","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}\n\n'
      printf 'data: {"id":"x","choices":[{"index":0,"delta":{"content":"trailing text that never fini"}}]}\n'; } > "$OUT"; printf '200'; exit 0 ;;
  mixed-index)
    # A second choice index appears — not the review we asked for.
    { sse_head fake/served; sse_body fake/served
      printf 'data: {"id":"x","choices":[{"index":1,"delta":{"content":"other choice"}}]}\n\n'
      printf 'data: {"id":"x","choices":[{"index":0,"delta":{"content":"done."},"finish_reason":"stop"}]}\n\ndata: [DONE]\n'; } > "$OUT"; printf '200'; exit 0 ;;
  error-after-text)
    # Text streamed, then an explicit error event — fail, but keep the text and the usage seen so far.
    { sse_head fake/served; sse_body fake/served
      printf 'data: {"id":"x","usage":{"prompt_tokens":700,"completion_tokens":40,"cost":0.003}}\n\n'
      printf 'data: {"error":{"message":"upstream provider reset (fake)","code":502}}\n\ndata: [DONE]\n'; } > "$OUT"; printf '200'; exit 0 ;;
  http402)
    printf '{"error":{"message":"Insufficient credits (fake)","code":402}}' > "$OUT"; printf '402'; exit 0 ;;
  badjson)
    printf '<html>bad gateway</html>' > "$OUT"; printf '502'; exit 0 ;;
  starved)
    { printf 'data: {"id":"x","model":"fake/served","choices":[{"index":0,"delta":{"role":"assistant","content":""}}]}\n\n'
      printf 'data: {"id":"x","model":"fake/served","choices":[{"index":0,"delta":{"content":""},"finish_reason":"length"}],"usage":{"prompt_tokens":900,"completion_tokens":9000,"cost":0.05,"completion_tokens_details":{"reasoning_tokens":9000}}}\n\ndata: [DONE]\n'
    } > "$OUT"; printf '200'; exit 0 ;;
  ok|*)
    { sse_head fake/served-0902; sse_body fake/served-0902
      printf 'data: {"id":"x","model":"fake/served-0902","choices":[{"index":0,"delta":{"content":"and it names one concrete absence: the plan has no rollback gate for the migration step."},"finish_reason":"stop"}],"usage":{"prompt_tokens":1200,"completion_tokens":300,"cost":0.0041,"completion_tokens_details":{"reasoning_tokens":120}}}\n\ndata: [DONE]\n'
    } > "$OUT"; printf '200'; exit 0 ;;
esac
