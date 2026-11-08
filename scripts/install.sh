#!/bin/bash
# Builds hantuu and installs it as /Applications/hantuu.app, so it opens from Spotlight,
# Launchpad and the Dock like any other app. Rerun it after pulling changes: it always
# replaces that one copy, and it makes macOS forget every other hantuu it has seen (build
# folders, worktrees, test copies), so there's only ever one hantuu to open.
# Usage: scripts/install.sh [--relaunch] [folder]    (default /Applications)
#   --relaunch   quit a running hantuu and open the new one (agents keep running)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RELAUNCH=0
if [ "${1:-}" = "--relaunch" ]; then RELAUNCH=1; shift; fi
DEST_DIR="${1:-/Applications}"
DEST="$DEST_DIR/hantuu.app"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

"$ROOT/scripts/build.sh" release

# Copy next to the old one and swap at the end, so a hantuu that's already open keeps finding
# its resources while this runs. ditto keeps the code signature intact.
rm -rf "$DEST.new" "$DEST.old"
ditto "$ROOT/build.noindex/hantuu.app" "$DEST.new"
[ -d "$DEST" ] && mv "$DEST" "$DEST.old"
mv "$DEST.new" "$DEST"
rm -rf "$DEST.old"

# Register the installed copy, then unregister every other bundle macOS knows with a
# local.hantuu bundle ID, including copies that no longer exist. Otherwise Spotlight, the
# Apps view, the Dock and notification clicks can each pick a different one.
touch "$DEST"
"$LSREGISTER" -f "$DEST" || true
"$ROOT/scripts/forget-copies.sh" "$DEST"

echo "Installed $DEST"
if [ "$RELAUNCH" = 1 ]; then
  if pgrep -xq hantuu; then
    osascript -e 'tell application id "local.hantuu" to quit' >/dev/null 2>&1 || true
    for _ in $(seq 1 50); do pgrep -xq hantuu || break; sleep 0.1; done
  fi
  open "$DEST"
  echo "Reopened hantuu. Agents running in hantuu-session kept going."
else
  echo "Agents running in hantuu-session keep going. Quit and reopen hantuu to use this version."
fi
