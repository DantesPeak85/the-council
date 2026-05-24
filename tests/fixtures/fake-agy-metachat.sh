#!/usr/bin/env bash
# PATH-injected fake agy that always emits scratch-workspace meta-chatter
# to stdout and exits 0. Used to verify council_invoke.sh detects
# non-engagement responses.
cat <<'EOF'
I am ready to help! Currently, this session is running with the default
workspace directory set to /Users/test/.gemini/antigravity-cli/scratch.

To work on your project, please provide the path or use --add-dir.
EOF
exit 0
