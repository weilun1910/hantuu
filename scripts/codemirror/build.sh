#!/bin/bash
# Bundles CodeMirror 6 (state, view, commands, language, search and the languages in entry.js)
# into Resources/web/vendor/codemirror.min.js, one file that sets window.CM, so the Code tab
# works offline. The versions are pinned in package.json and package-lock.json.
# Usage: scripts/codemirror/build.sh   (needs Node and npm; node_modules stays out of git)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
cd "$HERE"
npm ci --no-audit --no-fund
./node_modules/.bin/esbuild entry.js --bundle --minify --format=iife --target=safari17 \
  --legal-comments=none --outfile="$ROOT/Resources/web/vendor/codemirror.min.js"
echo "Wrote Resources/web/vendor/codemirror.min.js ($(wc -c < "$ROOT/Resources/web/vendor/codemirror.min.js" | tr -d ' ') bytes)"
