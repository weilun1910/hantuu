#!/bin/bash
# Builds the Swift package and wraps it in build.noindex/hantuu.app, signed ad hoc.
# The .noindex folder keeps Spotlight from listing this copy as an app. Only
# scripts/install.sh puts hantuu where macOS shows it: /Applications/hantuu.app.
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

FINAL="$ROOT/build.noindex/hantuu.app"
# Assemble in a staging folder and swap it in at the end, so a copy of hantuu that's
# already running keeps finding its resources while this builds.
APP="$ROOT/build.noindex/hantuu.app.staging"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/hantuu" "$APP/Contents/MacOS/hantuu"
# The session helper that keeps agents running after the app quits (Sources/hantuu-session).
cp "$BIN_DIR/hantuu-session" "$APP/Contents/MacOS/hantuu-session"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns" 2>/dev/null || true
printf 'APPL????' > "$APP/Contents/PkgInfo"

# The reader and code viewer pages plus their bundled JS libraries.
cp -R "$ROOT/Resources/web" "$APP/Contents/Resources/web"
# hantuu's own terminal look.
cp "$ROOT/Resources/terminal.ghostty" "$APP/Contents/Resources/terminal.ghostty"

# Ghostty's runtime resources, laid out the way libghostty looks for them in an app bundle:
# Contents/Resources/ghostty (shell integration, themes) and
# Contents/Resources/terminfo (xterm-ghostty).
cp -R "$ROOT/vendor/ghostty-resources/ghostty" "$APP/Contents/Resources/ghostty"
cp -R "$ROOT/vendor/ghostty-resources/terminfo" "$APP/Contents/Resources/terminfo"
# hantuu's light and dark terminal themes, found by name from terminal.ghostty.
cp "$ROOT"/Resources/ghostty-themes/* "$APP/Contents/Resources/ghostty/themes/"

# Ad hoc by default. Set SIGN_IDENTITY to a code signing identity from your keychain to
# keep macOS permissions across rebuilds.
# iCloud Drive tags files with extended attributes that codesign refuses to sign over.
xattr -cr "$APP"
IDENTITY="${SIGN_IDENTITY:--}"
# Nested executables are signed before the bundle that contains them.
codesign --force --sign "$IDENTITY" --timestamp=none "$APP/Contents/MacOS/hantuu-session"
codesign --force --sign "$IDENTITY" --timestamp=none "$APP"
rm -rf "$FINAL.old"
[ -d "$FINAL" ] && mv "$FINAL" "$FINAL.old"
mv "$APP" "$FINAL"
rm -rf "$FINAL.old"
# Never register this copy with macOS, and forget it if something did (a launch from here
# registers it), so the Apps view and Spotlight only ever offer /Applications/hantuu.app.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$FINAL" >/dev/null 2>&1 || true
echo "Built $FINAL (signed with ${IDENTITY/#-/ad hoc})"
