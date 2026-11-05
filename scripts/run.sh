#!/bin/bash
# Builds the app and opens it. Extra arguments go to the app, for example:
#   scripts/run.sh --data-dir "$PWD/tmp/appdata"    keep state out of ~/Library
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/scripts/build.sh" release
if [ "$#" -gt 0 ]; then
  open "$ROOT/build/hantuu.app" --args "$@"
else
  open "$ROOT/build/hantuu.app"
fi
