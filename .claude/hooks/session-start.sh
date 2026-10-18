#!/bin/bash
# Prepares the Linux Swift toolchain (Docker image) for cloud sessions.
# See .claude/swift-check/swift-check.sh for what it can and cannot check.
set -euo pipefail

if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
    exit 0
fi

# Runs in the background so the session starts at once. A check that runs
# before setup finishes is still safe: every swift-check.sh command starts
# dockerd and pulls the image itself if they are not ready yet.
echo '{"async": true, "asyncTimeout": 900000}'

"$CLAUDE_PROJECT_DIR/.claude/swift-check/swift-check.sh" setup
