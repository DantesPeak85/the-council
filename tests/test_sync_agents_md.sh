#!/usr/bin/env bash
# council_sync.sh must never destroy a user's AGENTS.md.
#   S1. Pre-existing AGENTS.md → backed up; --restore brings back the original
#   S2. No pre-existing AGENTS.md → --restore removes the council-written file
#   S3. Double-sync idempotency → --restore returns the ORIGINAL user content,
#       never the council-written content (the stale-backup collision guard).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SYNC="$REPO_ROOT/skills/the-council/scripts/council_sync.sh"
TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

P="$TMPDIR_TEST/proj"; mkdir -p "$P"
echo "# My CLAUDE rules" > "$P/CLAUDE.md"

# S1
echo "# USER OWNED AGENTS FILE" > "$P/AGENTS.md"
bash "$SYNC" "$P"
grep -q "My CLAUDE rules" "$P/AGENTS.md" || fail "S1: sync did not write council content"
[[ -f "$P/.council-tmp/AGENTS.md.orig" ]] || fail "S1: no backup taken"
bash "$SYNC" --restore "$P"
grep -q "USER OWNED AGENTS FILE" "$P/AGENTS.md" || fail "S1: original not restored"
pass "S1: pre-existing AGENTS.md round-trips"

# S2
rm -f "$P/AGENTS.md"; rm -rf "$P/.council-tmp"
bash "$SYNC" "$P"
[[ -f "$P/AGENTS.md" ]] || fail "S2: sync did not write AGENTS.md"
bash "$SYNC" --restore "$P"
[[ -f "$P/AGENTS.md" ]] && fail "S2: council-written AGENTS.md not removed on restore"
pass "S2: no-original case cleans up"

# S3 — double-sync idempotency (stale-backup collision guard).
# A second sync with NO --restore between must NOT back up the council-written
# AGENTS.md as if it were the user's original. If it did, --restore would hand
# back council content and the user's real file would be lost forever.
rm -f "$P/AGENTS.md"; rm -rf "$P/.council-tmp"
echo "# USER OWNED AGENTS FILE" > "$P/AGENTS.md"
bash "$SYNC" "$P"                                   # sync #1
grep -q "My CLAUDE rules" "$P/AGENTS.md" || fail "S3: sync #1 did not write council content"
bash "$SYNC" "$P"                                   # sync #2 — no restore between
grep -q "My CLAUDE rules" "$P/AGENTS.md" || fail "S3: sync #2 did not write council content"
bash "$SYNC" --restore "$P"
grep -q "USER OWNED AGENTS FILE" "$P/AGENTS.md" || fail "S3: double-sync lost the original user content (stale backup)"
grep -q "My CLAUDE rules" "$P/AGENTS.md" && fail "S3: restore returned council content instead of the original"
# Second --restore must be a clean no-op: exit 0, original left untouched.
bash "$SYNC" --restore "$P" || fail "S3: second --restore did not exit 0"
grep -q "USER OWNED AGENTS FILE" "$P/AGENTS.md" || fail "S3: second --restore disturbed the restored original"
pass "S3: double-sync then --restore returns ORIGINAL user content (idempotent)"

echo ""
echo "ALL SYNC TESTS PASSED"
