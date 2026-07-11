#!/usr/bin/env bash
# test_preflight.sh — v1.4.0 preflight hardening tests.
#
# All probes are FULLY ISOLATED from the host: HOME is redirected to a temp dir
# (so the real ~/.codex and ~/.gemini can never leak in), NVM_DIR is pointed at a
# nonexistent path (so the script's nvm sourcing never re-adds the real node/bin
# holding the real codex/agy/gemini), the API-key env vars are unset unless a
# test opts in, and PATH contains ONLY the per-test fake-bin plus core system
# dirs (never the dirs holding the real CLIs). Nothing here reads your real creds.
#
#   P1: gemini-cli-only machine + GEMINI_API_KEY → authenticated, agy unavailable
#   P2: ~/.gemini/antigravity-cli/settings.json does NOT count as credentials
#   P3: new keys survive into the CACHED replay
#   P4: cached replay preserves exit semantics (no advisor → nonzero on BOTH runs)
#   P5: cache invalidates when ~/.codex/config.toml is newer than the cache
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PREFLIGHT="$REPO_ROOT/skills/the-council/scripts/council_preflight.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

# --- helpers -----------------------------------------------------------------

# mkstub <path> <version-banner>: a minimal fake CLI that answers --version and
# otherwise no-ops. Enough for preflight's `command -v` + `--version` probes.
mkstub() {
  local path="$1" banner="$2"
  cat > "$path" <<EOF
#!/usr/bin/env bash
[[ "\${1:-}" == "--version" ]] && { echo "$banner"; exit 0; }
exit 0
EOF
  chmod +x "$path"
}

# run_pf <workdir> <outfile> [extra env KEY=VAL...]: run preflight fully isolated.
# Reads globals FAKE_BIN + FAKEHOME. Captures exit code in PF_RC. API keys are
# unset by default; a test re-adds them via the extra-env args (which win).
run_pf() {
  local wd="$1" out="$2"; shift 2
  set +e
  env -u OPENAI_API_KEY -u GEMINI_API_KEY -u GOOGLE_API_KEY \
      HOME="$FAKEHOME" NVM_DIR="$FAKEHOME/.nvm" \
      PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
      "$@" bash "$PREFLIGHT" "$wd" > "$out" 2> "${out}.err"
  PF_RC=$?
  set -e
}

kv() { grep -E "^$2=" "$1" | tail -1 | cut -d= -f2-; }
assert_kv() { # <file> <key> <expected> <label>
  local got; got="$(kv "$1" "$2")"
  [[ "$got" == "$3" ]] || fail "$4: expected $2=$3, got '$2=$got'"
}

# --- P1: gemini-cli-only + GEMINI_API_KEY → authenticated --------------------
FAKEHOME="$TMP/p1/home"; mkdir -p "$FAKEHOME"
FAKE_BIN="$TMP/p1/bin";  mkdir -p "$FAKE_BIN"
mkstub "$FAKE_BIN/gemini" "gemini-cli 0.42.0 (fake)"   # gemini-cli present, NO agy, NO codex
WD="$TMP/p1/wd"; mkdir -p "$WD"
run_pf "$WD" "$TMP/p1.out" GEMINI_API_KEY=test-key
[[ $PF_RC -eq 0 ]] || { cat "$TMP/p1.out.err"; fail "P1: expected exit 0, got $PF_RC"; }
assert_kv "$TMP/p1.out" GEMINI_CLI_AVAILABLE true   P1
assert_kv "$TMP/p1.out" AGY_AVAILABLE        false  P1
assert_kv "$TMP/p1.out" GEMINI_API_KEY_SET   true   P1
assert_kv "$TMP/p1.out" GEMINI_AUTHENTICATED  true  P1
assert_kv "$TMP/p1.out" CODEX_AUTHENTICATED  false  P1
pass "P1: gemini-cli-only + GEMINI_API_KEY authenticates (agy independent, false)"

# --- P2: antigravity-cli/settings.json is NOT a credential -------------------
FAKEHOME="$TMP/p2/home"; mkdir -p "$FAKEHOME/.gemini/antigravity-cli"
echo '{"note":"created by v1.3.0, not a credential"}' > "$FAKEHOME/.gemini/antigravity-cli/settings.json"
FAKE_BIN="$TMP/p2/bin"; mkdir -p "$FAKE_BIN"
mkstub "$FAKE_BIN/agy" "agy 1.0.2 (fake)"             # a backend IS present…
WD="$TMP/p2/wd"; mkdir -p "$WD"
run_pf "$WD" "$TMP/p2.out"                            # …but no oauth_creds, no API key
[[ $PF_RC -eq 1 ]] || fail "P2: expected exit 1 (unauthenticated), got $PF_RC"
assert_kv "$TMP/p2.out" AGY_AVAILABLE        true   P2
assert_kv "$TMP/p2.out" GEMINI_API_KEY_SET   false  P2
assert_kv "$TMP/p2.out" GEMINI_AUTHENTICATED false  P2
pass "P2: settings.json presence does NOT authenticate"

# P2b positive control: same, but a real oauth_creds.json DOES authenticate —
# proves the detector isn't just broken, it specifically ignores settings.json.
echo '{"access_token":"x"}' > "$FAKEHOME/.gemini/oauth_creds.json"
WD="$TMP/p2b/wd"; mkdir -p "$WD"
run_pf "$WD" "$TMP/p2b.out"
[[ $PF_RC -eq 0 ]] || fail "P2b: oauth_creds.json should authenticate, got exit $PF_RC"
assert_kv "$TMP/p2b.out" GEMINI_AUTHENTICATED true P2b
pass "P2b: oauth_creds.json authenticates (control)"

# --- P3: new keys present in CACHED replay -----------------------------------
FAKEHOME="$TMP/p3/home"; mkdir -p "$FAKEHOME"
FAKE_BIN="$TMP/p3/bin";  mkdir -p "$FAKE_BIN"
mkstub "$FAKE_BIN/gemini" "gemini-cli 0.42.0 (fake)"
WD="$TMP/p3/wd"; mkdir -p "$WD"
run_pf "$WD" "$TMP/p3.first.out" GEMINI_API_KEY=test-key
[[ $PF_RC -eq 0 ]] || fail "P3: first run exit $PF_RC"
# Remove the gemini stub. If the second run PROBED, it would report false; a cache
# hit reports the stale true — so a `true` here proves the replay came from cache.
rm -f "$FAKE_BIN/gemini"
run_pf "$WD" "$TMP/p3.cached.out" GEMINI_API_KEY=test-key
grep -q '^GEMINI_CLI_AVAILABLE=' "$TMP/p3.cached.out" || fail "P3: GEMINI_CLI_AVAILABLE missing from cached output"
grep -q '^GEMINI_API_KEY_SET='   "$TMP/p3.cached.out" || fail "P3: GEMINI_API_KEY_SET missing from cached output"
assert_kv "$TMP/p3.cached.out" GEMINI_CLI_AVAILABLE true P3   # stale value ⇒ served from cache
pass "P3: new keys carry into cached replay (served from cache, not re-probed)"

# --- P4: cached replay preserves nonzero exit when no advisor ----------------
FAKEHOME="$TMP/p4/home"; mkdir -p "$FAKEHOME"      # no config.toml, no oauth
FAKE_BIN="$TMP/p4/bin";  mkdir -p "$FAKE_BIN"      # no codex, no agy, no gemini
WD="$TMP/p4/wd"; mkdir -p "$WD"
run_pf "$WD" "$TMP/p4.first.out"
[[ $PF_RC -eq 1 ]] || fail "P4: fresh no-advisor run should exit nonzero, got $PF_RC"
assert_kv "$TMP/p4.first.out" PREFLIGHT_EXIT 1 P4
run_pf "$WD" "$TMP/p4.cached.out"                  # cache hit (config absent ⇒ no invalidation)
[[ $PF_RC -eq 1 ]] || fail "P4: CACHED no-advisor replay must also exit nonzero, got $PF_RC"
[[ -s "$TMP/p4.cached.out" ]] || fail "P4: cached replay produced no output"
grep -q '^GEMINI_CLI_AVAILABLE=' "$TMP/p4.cached.out" || fail "P4: cached output missing new keys"
pass "P4: nonzero exit preserved across fresh AND cached no-advisor runs"

# --- P5: cache invalidates when ~/.codex/config.toml is newer than cache -----
FAKEHOME="$TMP/p5/home"; mkdir -p "$FAKEHOME/.codex"
echo 'model = "gpt-5.5"' > "$FAKEHOME/.codex/config.toml"
FAKE_BIN="$TMP/p5/bin"; mkdir -p "$FAKE_BIN"
mkstub "$FAKE_BIN/gemini" "gemini-cli 0.42.0 (fake)"
WD="$TMP/p5/wd"; mkdir -p "$WD"
CACHE="$WD/.council-tmp/preflight_cache_v2"
run_pf "$WD" "$TMP/p5.first.out" GEMINI_API_KEY=test-key
[[ $PF_RC -eq 0 ]] || fail "P5: first run exit $PF_RC"
assert_kv "$TMP/p5.first.out" GEMINI_CLI_AVAILABLE true P5
[[ -f "$CACHE" ]] || fail "P5: cache file $CACHE not written (v2 name?)"
rm -f "$FAKE_BIN/gemini"                            # gemini now gone from a fresh probe

# Control: config UNCHANGED → run replays the cache → still reports stale true.
run_pf "$WD" "$TMP/p5.control.out" GEMINI_API_KEY=test-key
assert_kv "$TMP/p5.control.out" GEMINI_CLI_AVAILABLE true "P5 control"

# Treatment: make config.toml strictly newer than the (run1) cache → invalidate.
CM="$(stat -f %m "$CACHE" 2>/dev/null || stat -c %Y "$CACHE" 2>/dev/null)"
NEWER=$(( CM + 60 ))
TS="$(date -r "$NEWER" +%Y%m%d%H%M.%S 2>/dev/null || date -d "@$NEWER" +%Y%m%d%H%M.%S)"
touch -t "$TS" "$FAKEHOME/.codex/config.toml"
run_pf "$WD" "$TMP/p5.fresh.out" GEMINI_API_KEY=test-key
assert_kv "$TMP/p5.fresh.out" GEMINI_CLI_AVAILABLE false "P5 treatment"
pass "P5: newer codex config invalidates cache → fresh probe (marker flipped)"

echo ""
echo "ALL PREFLIGHT TESTS PASSED"
