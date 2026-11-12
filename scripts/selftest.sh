#!/bin/bash
# Builds a debug binary and runs the self test in a throwaway folder (tmp/selftest).
# HANTUU_NO_PMSET=1 keeps the test from ever calling pmset.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
swift build -c debug --scratch-path "$ROOT/.build"
# The bare binary reads Ghostty's resources from vendor/, so hantuu's themes go there too.
cp "$ROOT"/Resources/ghostty-themes/* "$ROOT/vendor/ghostty-resources/ghostty/themes/"
# Keep the complete log outside the workdir that the binary clears at startup.
mkdir -p "$ROOT/tmp"
set +e
HANTUU_NO_PMSET=1 "$ROOT/.build/debug/hantuu" --self-test --workdir "$ROOT/tmp/selftest" 2>&1 | tee "$ROOT/tmp/selftest-run.log"
TEST_STATUS=${PIPESTATUS[0]}
set -e
printf 'Self-test process exit status: %s\n' "$TEST_STATUS" | tee -a "$ROOT/tmp/selftest-run.log"
exit "$TEST_STATUS"
