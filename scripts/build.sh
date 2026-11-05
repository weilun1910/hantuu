#!/bin/bash
# Builds the Swift package and wraps it in build/hantuu.app, signed ad hoc.
# Usage: scripts/build.sh [release|debug]
# Needs vendor/GhosttyKit.xcframework first: run scripts/build-libghostty.sh once.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-release}"
cd "$ROOT"

if [ ! -d "$ROOT/vendor/GhosttyKit.xcframework" ]; then
  echo "vendor/GhosttyKit.xcframework is missing. Run scripts/build-libghostty.sh first." >&2
  exit 1
fi

# Pin the Xcode SDK so the build doesn't pick up a newer Command Line Tools SDK.
export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"

swift build -c "$CONFIG" --scratch-path "$ROOT/.build"
BIN_DIR="$(swift build -c "$CONFIG" --scratch-path "$ROOT/.build" --show-bin-path)"

APP="$ROOT/build/hantuu.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/hantuu" "$APP/Contents/MacOS/hantuu"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns" 2>/dev/null || true
printf 'APPL????' > "$APP/Contents/PkgInfo"

# The reader and code viewer pages plus their bundled JS libraries.
cp -R "$ROOT/Resources/web" "$APP/Contents/Resources/web"

# Ghostty's runtime resources, laid out the way libghostty looks for them in an app bundle:
# Contents/Resources/ghostty (shell integration, themes) and
# Contents/Resources/terminfo (xterm-ghostty).
cp -R "$ROOT/vendor/ghostty-resources/ghostty" "$APP/Contents/Resources/ghostty"
cp -R "$ROOT/vendor/ghostty-resources/terminfo" "$APP/Contents/Resources/terminfo"

# Ad hoc by default. Set SIGN_IDENTITY to a code signing identity from your keychain to
# keep macOS permissions across rebuilds.
# iCloud Drive tags files with extended attributes that codesign refuses to sign over.
xattr -cr "$APP"
IDENTITY="${SIGN_IDENTITY:--}"
codesign --force --sign "$IDENTITY" --timestamp=none "$APP"
echo "Built $APP (signed with ${IDENTITY/#-/ad hoc})"
