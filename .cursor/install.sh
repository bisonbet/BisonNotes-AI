#!/usr/bin/env bash
# Cloud Agent install script for BisonNotes AI.
#
# This is a native iOS/watchOS Xcode project that cannot be built or tested on
# Linux (xcodebuild + the iOS Simulator require macOS). On a Linux Cloud Agent
# VM the supported development experience is:
#   - SwiftLint    (`swiftlint lint`, filtered by SwiftLintBaseline.json)
#   - Syntax check (`swiftc -parse <file.swift>`)
#
# Both require a Swift toolchain (SourceKit). This script installs Swiftly, a
# pinned Swift toolchain, and SwiftLint, then wires the required environment
# variables into ~/.bashrc. It is idempotent: re-running it is a no-op once the
# tools are present.
set -euo pipefail

SWIFT_VERSION="6.3.3"
SWIFTLINT_VERSION="0.58.2"
SWIFTLY_HOME_DIR="${SWIFTLY_HOME_DIR:-$HOME/.local/share/swiftly}"

log() { printf '[cloud-install] %s\n' "$*"; }

# 1. OS dependencies required by the Swift toolchain / SourceKit.
if ! dpkg -s libcurl4-openssl-dev >/dev/null 2>&1; then
  log "Installing OS dependencies for Swift..."
  sudo apt-get update -qq
  sudo apt-get install -y -qq \
    binutils gnupg2 libc6-dev libcurl4-openssl-dev libedit2 libgcc-13-dev \
    libpython3-dev libstdc++-13-dev libxml2-dev libz3-dev pkg-config tzdata \
    unzip zlib1g-dev libncurses-dev
else
  log "OS dependencies already present."
fi

# 2. Swiftly (Swift toolchain manager).
if [ ! -x "$SWIFTLY_HOME_DIR/bin/swiftly" ]; then
  log "Installing Swiftly..."
  tmp="$(mktemp -d)"
  (
    cd "$tmp"
    curl -fsSL -O "https://download.swift.org/swiftly/linux/swiftly-$(uname -m).tar.gz"
    tar zxf "swiftly-$(uname -m).tar.gz"
    ./swiftly init --skip-install --quiet-shell-followup --assume-yes
  )
  rm -rf "$tmp"
else
  log "Swiftly already installed."
fi

# Make swiftly + the active toolchain available to the rest of this script.
# shellcheck disable=SC1091
. "$SWIFTLY_HOME_DIR/env.sh"
hash -r

# 3. Pinned Swift toolchain. Use --global-default so no repo-local
#    `.swift-version` file is written into the checkout.
if ! "$SWIFTLY_HOME_DIR/bin/swiftly" list 2>/dev/null | grep -q "Swift $SWIFT_VERSION"; then
  log "Installing Swift $SWIFT_VERSION (this downloads ~1 GB)..."
  swiftly install "$SWIFT_VERSION" --assume-yes
else
  log "Swift $SWIFT_VERSION already installed."
fi
swiftly use --global-default "$SWIFT_VERSION" >/dev/null 2>&1 || true
hash -r

# Location of libsourcekitdInProc.so inside the installed toolchain; SwiftLint
# needs this on Linux.
SOURCEKIT_LIB_DIR="$(dirname "$(ls "$SWIFTLY_HOME_DIR"/toolchains/*/usr/lib/libsourcekitdInProc.so 2>/dev/null | head -n1)")"
export LINUX_SOURCEKIT_LIB_PATH="$SOURCEKIT_LIB_DIR"

# 4. SwiftLint (Linux binary release).
current_swiftlint=""
if command -v swiftlint >/dev/null 2>&1; then
  current_swiftlint="$(swiftlint version 2>/dev/null || true)"
fi
if [ "$current_swiftlint" != "$SWIFTLINT_VERSION" ]; then
  log "Installing SwiftLint $SWIFTLINT_VERSION..."
  tmp="$(mktemp -d)"
  (
    cd "$tmp"
    curl -fsSL -o swiftlint_linux.zip \
      "https://github.com/realm/SwiftLint/releases/download/${SWIFTLINT_VERSION}/swiftlint_linux.zip"
    unzip -o -q swiftlint_linux.zip
    sudo install -m 0755 swiftlint /usr/local/bin/swiftlint
  )
  rm -rf "$tmp"
else
  log "SwiftLint $SWIFTLINT_VERSION already installed."
fi

# 5. Wire environment variables into ~/.bashrc (idempotent, guarded block).
#    ~/.profile already sources ~/.bashrc for bash login shells, so a single
#    block here covers both login and interactive Cloud Agent shells.
MARK_BEGIN="# >>> bisonnotes-ai cloud-agent env >>>"
MARK_END="# <<< bisonnotes-ai cloud-agent env <<<"
if ! grep -qF "$MARK_BEGIN" "$HOME/.bashrc" 2>/dev/null; then
  log "Adding Swift environment block to ~/.bashrc..."
  cat >> "$HOME/.bashrc" <<'EOF'

# >>> bisonnotes-ai cloud-agent env >>>
# Swift toolchain (Swiftly) + SwiftLint SourceKit path for Linux dev.
if [ -f "${SWIFTLY_HOME_DIR:-$HOME/.local/share/swiftly}/env.sh" ]; then
  . "${SWIFTLY_HOME_DIR:-$HOME/.local/share/swiftly}/env.sh"
fi
export LINUX_SOURCEKIT_LIB_PATH="$(dirname "$(ls "${SWIFTLY_HOME_DIR:-$HOME/.local/share/swiftly}"/toolchains/*/usr/lib/libsourcekitdInProc.so 2>/dev/null | head -n1)")"
# <<< bisonnotes-ai cloud-agent env <<<
EOF
else
  log "~/.bashrc already configured."
fi

# 6. Report resulting versions.
log "Swift:     $(swift --version 2>/dev/null | head -n1)"
log "SwiftLint: $(swiftlint version 2>/dev/null)"
log "LINUX_SOURCEKIT_LIB_PATH=$LINUX_SOURCEKIT_LIB_PATH"
log "Install complete."
