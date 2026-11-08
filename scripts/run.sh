#!/bin/bash
# Builds and installs hantuu into /Applications (the one copy macOS knows about), then
# reopens it. Extra arguments go to the app, for example:
#   scripts/run.sh --data-dir "$PWD/tmp/appdata"    keep state out of ~/Library
# A test copy that runs next to your own needs its own bundle ID and a folder outside the
# repo. Run scripts/forget-copies.sh after deleting it.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/scripts/install.sh"
if pgrep -xq hantuu; then
  osascript -e 'tell application id "local.hantuu" to quit' >/dev/null 2>&1 || true
  for _ in $(seq 1 50); do pgrep -xq hantuu || break; sleep 0.1; done
fi
if [ "$#" -gt 0 ]; then
  open /Applications/hantuu.app --args "$@"
else
  open /Applications/hantuu.app
fi
