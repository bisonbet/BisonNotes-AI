#!/bin/bash
# Swift checks for Linux cloud sessions, where Xcode and the iOS SDK are absent.
#
# The Swift toolchain runs from the official swift Docker image. Linux has no
# SwiftUI, UIKit, CoreData, CloudKit or MLX, so:
#   parse     syntax-checks any Swift file (default: files changed vs origin/main)
#   typecheck type-checks the Foundation-only sources in FOUNDATION_SOURCES
#   test      runs TEST_FILES against those sources, skipping tests that
#             need types Linux cannot build (see SKIP_TEST_PATTERN)
#   setup     starts dockerd and pulls the image (run by the SessionStart hook)
# The full app build still needs Xcode.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECK_DIR="$REPO_ROOT/.claude/swift-check"
APP_DIR="BisonNotes AI/BisonNotes AI"
TEST_DIR="BisonNotes AI/BisonNotes AITests"
SWIFT_VERSION_TAG="${SWIFT_VERSION_TAG:-6.2-noble}"
# Docker Hub rate-limits anonymous pulls from shared egress, so mirrors go first.
IMAGE_CANDIDATES=(
    "mirror.gcr.io/library/swift:$SWIFT_VERSION_TAG"
    "public.ecr.aws/docker/library/swift:$SWIFT_VERSION_TAG"
    "swift:$SWIFT_VERSION_TAG"
)
WORK_DIR="${SWIFT_CHECK_WORK_DIR:-/tmp/bisonnotes-swift-check}"

# App sources that import only Foundation, relative to APP_DIR. Add a file
# here when a test needs it and it does not reach Apple-only frameworks.
# Entries missing on the current branch are skipped, so the list can name
# files that land with an open PR.
FOUNDATION_SOURCES=(
    "Models/SummaryPromptStyle.swift"
    "Models/EnhancedSummaryData.swift"
    "Models/SummarizationEngine.swift"
    "Models/SummarizationErrors.swift"
    "Models/SummaryMetadataCodec.swift"
    "OpenAI/OpenAIPromptGenerator.swift"
)
# XCTest files, relative to TEST_DIR, that run against FOUNDATION_SOURCES.
# Missing ones are skipped, like the sources.
TEST_FILES=(
    "SummaryDetailLevelTests.swift"
    "SummaryPromptStyleTests.swift"
)
# Tests whose bodies mention these need CoreData/CloudKit and are skipped.
SKIP_TEST_PATTERN='ProcessingJob|iCloudStorageManager'

log() { echo "[swift-check] $*" >&2; }

ensure_docker() {
    if docker info >/dev/null 2>&1; then
        return
    fi
    if ! command -v dockerd >/dev/null 2>&1; then
        log "dockerd is not installed"
        exit 1
    fi
    log "starting dockerd"
    nohup dockerd >/tmp/dockerd.log 2>&1 &
    for _ in $(seq 1 60); do
        docker info >/dev/null 2>&1 && return
        sleep 1
    done
    log "dockerd did not start; see /tmp/dockerd.log"
    exit 1
}

resolve_image() {
    for image in "${IMAGE_CANDIDATES[@]}"; do
        if docker image inspect "$image" >/dev/null 2>&1; then
            echo "$image"
            return
        fi
    done
    return 1
}

pull_image() {
    if resolve_image >/dev/null; then
        return
    fi
    for image in "${IMAGE_CANDIDATES[@]}"; do
        log "pulling $image"
        if timeout 900 docker pull --quiet "$image" >&2; then
            return
        fi
    done
    log "could not pull a Swift image"
    exit 1
}

swift_run() {
    # Usage: swift_run <host dir mounted at /work> <command...>
    local mount="$1"
    shift
    docker run --rm -v "$mount":/work -w /work "$(resolve_image)" "$@"
}

# Assembles a SwiftPM package of the Foundation-only sources plus stubs.
build_package() {
    local pkg="$WORK_DIR/pkg"
    rm -rf "$pkg"
    mkdir -p "$pkg/Sources/BisonNotes_AI" "$pkg/Tests/BisonNotes_AITests"
    cp "$CHECK_DIR/Package.swift" "$pkg/"
    cp "$CHECK_DIR/Stubs.swift" "$pkg/Sources/BisonNotes_AI/"
    for source in "${FOUNDATION_SOURCES[@]}"; do
        [ -f "$REPO_ROOT/$APP_DIR/$source" ] || continue
        cp "$REPO_ROOT/$APP_DIR/$source" "$pkg/Sources/BisonNotes_AI/"
    done
    # BetaFeatures' model is Foundation-only; its SwiftUI views come after
    # the "SwiftUI Gate" mark.
    local beta="$REPO_ROOT/$APP_DIR/Models/BetaFeatures.swift"
    if [ -f "$beta" ]; then
        sed -e 's/^import SwiftUI$/import Foundation/' -e '/^\/\/ MARK: - SwiftUI Gate/,$d' \
            "$beta" >"$pkg/Sources/BisonNotes_AI/BetaFeaturesCore.swift"
    fi
    local found=0
    for test_file in "${TEST_FILES[@]}"; do
        [ -f "$REPO_ROOT/$TEST_DIR/$test_file" ] || continue
        python3 "$CHECK_DIR/filter_tests.py" "$SKIP_TEST_PATTERN" \
            "$REPO_ROOT/$TEST_DIR/$test_file" "$pkg/Tests/BisonNotes_AITests/$test_file"
        found=1
    done
    if [ "$found" -eq 0 ]; then
        log "none of TEST_FILES exist on this branch"
        exit 1
    fi
    echo "$pkg"
}

cmd_setup() {
    if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ] && [ "${1:-}" != "--force" ]; then
        log "not a cloud session; skipping setup"
        return
    fi
    ensure_docker
    pull_image
    log "ready: $(resolve_image)"
}

cmd_parse() {
    ensure_docker
    pull_image
    local files=("$@")
    if [ ${#files[@]} -eq 0 ]; then
        git -C "$REPO_ROOT" fetch --quiet origin main 2>/dev/null || true
        local base
        base="$(git -C "$REPO_ROOT" merge-base HEAD origin/main)"
        mapfile -t files < <(
            git -C "$REPO_ROOT" diff --name-only --diff-filter=d "$base" -- '*.swift'
            git -C "$REPO_ROOT" ls-files --others --exclude-standard -- '*.swift'
        )
    fi
    if [ ${#files[@]} -eq 0 ]; then
        log "no Swift files to parse"
        return
    fi
    # Paths are made repo-relative so they resolve inside the container.
    local relative=()
    for file in "${files[@]}"; do
        relative+=("$(realpath --relative-to="$REPO_ROOT" "$file" 2>/dev/null || echo "$file")")
    done
    log "parsing ${#relative[@]} file(s)"
    # One swiftc per file: the app has same-named files in different targets,
    # which a single invocation rejects.
    swift_run "$REPO_ROOT" bash -c '
        failed=0
        for file in "$@"; do
            swiftc -parse "$file" || { echo "[swift-check] parse failed: $file" >&2; failed=1; }
        done
        exit $failed
    ' parse "${relative[@]}"
    log "parse OK"
}

cmd_typecheck() {
    ensure_docker
    pull_image
    local pkg
    pkg="$(build_package)"
    swift_run "$pkg" bash -c 'swiftc -swift-version 5 -typecheck Sources/BisonNotes_AI/*.swift'
    log "typecheck OK"
}

cmd_test() {
    ensure_docker
    pull_image
    local pkg
    pkg="$(build_package)"
    local filter=()
    if [ -n "${1:-}" ]; then
        filter=(--filter "$1")
    fi
    swift_run "$pkg" swift test "${filter[@]}"
}

case "${1:-}" in
    setup) shift; cmd_setup "$@" ;;
    parse) shift; cmd_parse "$@" ;;
    typecheck) shift; cmd_typecheck "$@" ;;
    test) shift; cmd_test "$@" ;;
    *)
        echo "usage: $0 {setup [--force]|parse [files...]|typecheck|test [filter]}" >&2
        exit 2
        ;;
esac
