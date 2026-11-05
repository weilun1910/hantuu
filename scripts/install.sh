#!/bin/bash
# Builds hantuu and installs it as /Applications/hantuu.app, so it opens from Spotlight,
# Launchpad and the Dock like any other app. Rerun it after pulling changes.
# Usage: scripts/install.sh [folder]    (default /Applications)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST_DIR="${1:-/Applications}"
DEST="$DEST_DIR/hantuu.app"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

"$ROOT/scripts/build.sh" release

# Copy next to the old one and swap at the end, so a hantuu that's already open keeps finding
# its resources while this runs. ditto keeps the code signature intact.
rm -rf "$DEST.new" "$DEST.old"
ditto "$ROOT/build/hantuu.app" "$DEST.new"
[ -d "$DEST" ] && mv "$DEST" "$DEST.old"
mv "$DEST.new" "$DEST"
rm -rf "$DEST.old"

# Register the installed copy, and forget the build folder's copy, so Spotlight, the Dock and
# notification clicks all open the same app.
touch "$DEST"
"$LSREGISTER" -f "$DEST" || true
"$LSREGISTER" -u "$ROOT/build/hantuu.app" 2>/dev/null || true

echo "Installed $DEST"
echo "Agents running in hantuu-session keep going. Quit and reopen hantuu to use this version."
