#!/bin/bash
# Builds a debug binary and runs the self test in a throwaway folder (tmp/selftest).
# HANTUU_NO_PMSET=1 keeps the test from ever calling pmset.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
swift build -c debug --scratch-path "$ROOT/.build"
HANTUU_NO_PMSET=1 "$ROOT/.build/debug/hantuu" --self-test --workdir "$ROOT/tmp/selftest"
