#!/bin/bash
# Prepares the Linux Swift toolchain (Docker image) for cloud sessions.
# See .claude/swift-check/swift-check.sh for what it can and cannot check.
set -euo pipefail

if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
    exit 0
fi

"$CLAUDE_PROJECT_DIR/.claude/swift-check/swift-check.sh" setup
