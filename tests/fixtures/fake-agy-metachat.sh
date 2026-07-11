#!/usr/bin/env bash
# PATH-injected fake agy that always emits scratch-workspace meta-chatter
# to stdout and exits 0. Used to verify council_invoke.sh detects
# non-engagement responses.
# --version guard (mirrors fake-codex/fake-gemini): the backend-aware banner
# probes `agy --version`; without this, the unconditional `cat` below would emit
# meta-chatter AS the captured version string. Respond like real agy and exit 0.
if [[ "${1:-}" == "--version" ]]; then echo "1.1.1 (fake)"; exit 0; fi
cat <<'EOF'
I am ready to help! Currently, this session is running with the default
workspace directory set to /Users/test/.gemini/antigravity-cli/scratch.

To work on your project, please provide the path or use --add-dir.
EOF
exit 0
