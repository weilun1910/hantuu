#!/bin/bash
# Makes macOS forget every hantuu app bundle except one, so Spotlight, the Apps view, the
# Dock and notification clicks all open the same copy. Matches any bundle ID starting with
# local.hantuu (test copies included), and also clears records of copies that were deleted.
# It only touches the Launch Services database, never the files.
# Usage: scripts/forget-copies.sh [path to keep]    (default /Applications/hantuu.app)
set -euo pipefail
KEEP="${1:-/Applications/hantuu.app}"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

# lsregister -dump prints one record per bundle, separated by rows of dashes, with
# "path:" and "identifier:" lines. Print the path of every local.hantuu* bundle.
"$LSREGISTER" -dump 2>/dev/null | awk '
  function flush() { if (path != "" && id ~ /^local\.hantuu/) print path; path = ""; id = "" }
  /^-----/ { flush(); next }
  /^path:/ && path == "" { sub(/^path:[ \t]+/, ""); sub(/ \(0x[0-9a-f]+\)$/, ""); path = $0; next }
  /^identifier:/ && id == "" { sub(/^identifier:[ \t]+/, ""); sub(/ \(0x[0-9a-f]+\)$/, ""); id = $0; next }
  END { flush() }
' | sort -u | while IFS= read -r p; do
  [ "$p" = "$KEEP" ] && continue
  "$LSREGISTER" -u "$p" >/dev/null 2>&1 || true
  echo "Forgot $p"
done
