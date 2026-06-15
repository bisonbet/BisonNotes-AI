#!/bin/bash
# Archive the Mac Catalyst app, arm64-only, and place it where Xcode Organizer finds it.
#
# Why a script instead of Product > Archive:
# EXCLUDED_ARCHS set in the project does NOT propagate to Swift Package targets,
# so a GUI archive still compiles MLX, AWS SDK, etc. for x86_64. Passing the
# setting as an xcodebuild command-line override applies it to every target,
# packages included. (x86_64 is useless here anyway: the llama.xcframework
# Catalyst slice and MLX are Apple Silicon-only.)

set -euo pipefail

cd "$(dirname "$0")/.."

ARCHIVE_DIR="$HOME/Library/Developer/Xcode/Archives/$(date +%Y-%m-%d)"
ARCHIVE_PATH="$ARCHIVE_DIR/BisonNotes AI (Catalyst) $(date +%m-%d-%y,\ %H.%M).xcarchive"

xcodebuild archive \
  -project "BisonNotes AI/BisonNotes AI.xcodeproj" \
  -scheme "BisonNotes AI" \
  -destination 'generic/platform=macOS,variant=Mac Catalyst' \
  -archivePath "$ARCHIVE_PATH" \
  -allowProvisioningUpdates \
  EXCLUDED_ARCHS=x86_64

echo
echo "Archive created: $ARCHIVE_PATH"
echo "It will appear in Xcode Organizer (Window > Organizer) for upload."
