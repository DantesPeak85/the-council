#!/usr/bin/env bash
# Full mocked Council run (--codex-only) through the real council_invoke.sh wiring. A fake `codex` on PATH
# prints canned --json events and a response file, and logs its argv and pwd. No model, no network.
# Usage: tests/test_invoke_mocked.sh [claude_md_to_copy]   (SCRATCH_ROOT overrides where temp dirs go)
set -u
D="$(cd "$(dirname "$0")/.." && pwd)"
SRC_MD="${1:-}"
T="$(mktemp -d "${SCRATCH_ROOT:-$D/../../../.scratch}/mocked.XXXXXX" 2>/dev/null || mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/work"
[[ -n "$SRC_MD" && -f "$SRC_MD" ]] && cp "$SRC_MD" "$T/work/CLAUDE.md" || echo "# scratch" > "$T/work/CLAUDE.md"
# own git repo, so the safety-net snapshot covers only the scratch dir (not the enclosing checkout)
( cd "$T/work" && git init -q && git add -A && git -c user.email=t@t -c user.name=t commit -qm init )
printf 'Reply with exactly: VERDICT: OK\n' > "$T/prompt.txt"
cat > "$T/bin/codex" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == "--version" ]] && { echo "codex-cli fake"; exit 0; }
{ echo "pwd=$(pwd)"; echo "argv=$*"; } >> "$FAKE_CODEX_LOG"
out=""; while [[ $# -gt 0 ]]; do [[ "$1" == "-o" ]] && out="$2"; shift; done
cat > /dev/null
printf '{"type":"turn.completed","usage":{"input_tokens":%s,"cached_input_tokens":0,"output_tokens":0,"reasoning_output_tokens":0}}\n' "$FAKE_IN"
printf '# Fake review\n\nLooks fine.\n\nVERDICT: OK\n' > "$out"
EOF
chmod +x "$T/bin/codex"

fail=0; ok() { echo "PASS: $1"; }; bad() { echo "FAIL: $1"; fail=1; }
run() {  # $1 label, $2 fake input tokens. Model pinned to gpt-6-astra; estimate at medium is $0.55 (24.5k in + 6k out at $10/$50).
  : > "$T/fake.log"; rm -f "$T/alarm.log"
  ( cd "$T/work" && PATH="$T/bin:$PATH" FAKE_CODEX_LOG="$T/fake.log" FAKE_IN="$2" COUNCIL_COST_ALARM_LOG="$T/alarm.log" \
      COUNCIL_CODEX_EFFORT=medium CODEX_MODEL=gpt-6-astra bash "$D/council_invoke.sh" --codex-only "$T/prompt.txt" "$T/work" >"$T/$1.out" 2>"$T/$1.err" )
  echo "exit($1)=$?"
}

echo "=== 4x run (220k input tokens at \$10/M = \$2.20 vs estimate \$0.55) ==="
run four 220000
grep -h "Usage plan\|Codex   " "$T/four.out"
echo "--- stderr:"; grep "COST ALARM" "$T/four.err"
echo "--- report block (stdout):"; sed -n '/Council responses ready/,/^$/p' "$T/four.out"
echo "--- alarm log:"; cat "$T/alarm.log" 2>&1
echo "--- fake codex log:"; cat "$T/fake.log"
grep -q "COST ALARM: Codex actual \$2.20 vs estimate \$0.55" "$T/four.err" && ok "alarm on stderr" || bad "no stderr alarm"
grep -q "COST ALARM: Codex" "$T/four.out" && ok "alarm in report block" || bad "no alarm in report"
[[ "$(wc -l < "$T/alarm.log" 2>/dev/null)" -eq 1 ]] && ok "one log line" || bad "log line count"
grep -q -- "--disable shell_tool --disable unified_exec" "$T/fake.log" && ok "shell flags passed" || bad "shell flags missing"
fpwd="$(sed -n 's/^pwd=//p' "$T/fake.log" | head -1)"
[[ "$fpwd" == *codex_empty.* && "$fpwd" != "$(cd "$T/work" && pwd -P)" ]] && ok "codex ran in empty folder: $fpwd" || bad "codex pwd=$fpwd"
grep -q "SAFETY_NET" "$T/four.out" && bad "safety net tripped" || ok "safety net quiet"

echo; echo "=== 1x run (55k input tokens = \$0.55) ==="
run one 55000
grep -c "COST ALARM" "$T/one.err" "$T/one.out"
[[ ! -e "$T/alarm.log" ]] && ok "1x: no alarm, no log" || bad "1x alarmed"
grep -q "COST ALARM" "$T/one.err" "$T/one.out" && bad "1x alarm text present" || ok "1x silent"

echo; echo "=== opt-out: COUNCIL_CODEX_REPO_ACCESS=1 restores the working dir and the shell ==="
: > "$T/fake.log"
( cd "$T/work" && PATH="$T/bin:$PATH" FAKE_CODEX_LOG="$T/fake.log" FAKE_IN=55000 COUNCIL_COST_ALARM_LOG="$T/alarm.log" COUNCIL_CODEX_REPO_ACCESS=1 CODEX_MODEL=gpt-6-astra \
    bash "$D/council_invoke.sh" --codex-only "$T/prompt.txt" "$T/work" >/dev/null 2>&1 )
grep -q "^pwd=$(cd "$T/work" && pwd)$" "$T/fake.log" && ! grep -q "disable shell_tool" "$T/fake.log" && ok "opt-out honoured" || { bad "opt-out"; cat "$T/fake.log"; }
exit $fail
