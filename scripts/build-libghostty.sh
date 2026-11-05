#!/bin/bash
# Builds GhosttyKit.xcframework (libghostty) from the official Ghostty v1.4.0 source.
#
# Everything lands inside vendor/: the Zig toolchain, the Ghostty checkout, the Zig caches,
# the finished xcframework and Ghostty's runtime resources (terminfo, shell integration).
# Run it once before scripts/build.sh. Re-running is cheap: finished steps are skipped.
#
# Sources:
#   Zig 0.17.0 (the version Ghostty 1.4.0's build.zig.zon asks for) from ziglang.org
#   Ghostty v1.4.0 from github.com/ghostty-org/ghostty
#   Ghostty's own pinned build dependencies, fetched by Zig and checked against the hashes
#   in Ghostty's build.zig.zon (mostly deps.files.ghostty.org)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/vendor"
ZIG_VERSION="0.17.0"
ZIG_SHA256="b607e9b9234790a008116ae5bdb71c6243b84b9fb42a53a9e70fde41c06c536a"
GHOSTTY_TAG="v1.4.0"
mkdir -p "$VENDOR"

# 1. Zig
ZIG="$VENDOR/zig-$ZIG_VERSION/zig"
if [ ! -x "$ZIG" ]; then
  mkdir -p "$VENDOR/zig-dl"
  TARBALL="$VENDOR/zig-dl/zig-aarch64-macos-$ZIG_VERSION.tar.xz"
  curl -sSfL "https://ziglang.org/download/$ZIG_VERSION/zig-aarch64-macos-$ZIG_VERSION.tar.xz" -o "$TARBALL"
  echo "$ZIG_SHA256  $TARBALL" | shasum -a 256 -c -
  tar -xJf "$TARBALL" -C "$VENDOR"
  mv "$VENDOR/zig-aarch64-macos-$ZIG_VERSION" "$VENDOR/zig-$ZIG_VERSION"
fi
echo "zig $("$ZIG" version)"

# 2. Ghostty source
SRC="$VENDOR/ghostty"
if [ ! -d "$SRC/.git" ]; then
  git clone --depth 1 --branch "$GHOSTTY_TAG" https://github.com/ghostty-org/ghostty.git "$SRC"
fi

# 3. Patch: compile the Metal shaders at runtime. Ghostty 1.4.0 embeds a precompiled
#    .metallib made with `xcrun metal`, and Xcode 26 ships without the Metal Toolchain
#    (it's a separate download). The patch embeds the shader source and compiles it with
#    MTLDevice newLibraryWithSource at startup instead, which needs no extra toolchain.
PATCH="$ROOT/patches/ghostty-v1.4.0-runtime-metal-shaders.patch"
if git -C "$SRC" apply --check "$PATCH" 2>/dev/null; then
  git -C "$SRC" apply "$PATCH"
  echo "applied $(basename "$PATCH")"
else
  echo "patch already applied"
fi

# 4. Build. Caches stay in vendor/. Sentry and i18n are off: the embedded app doesn't need
#    crash reporting into Ghostty's cache folder or translations.
export ZIG_GLOBAL_CACHE_DIR="$VENDOR/zig-cache/global"
export ZIG_LOCAL_CACHE_DIR="$VENDOR/zig-cache/local"
(cd "$SRC" && "$ZIG" build \
  -Doptimize=ReleaseFast \
  -Demit-xcframework=true \
  -Dxcframework-target=native \
  -Demit-macos-app=false \
  -Dsentry=false \
  -Di18n=false)

# 5. Copy the outputs where Package.swift and build.sh expect them.
rm -rf "$VENDOR/GhosttyKit.xcframework" "$VENDOR/ghostty-resources"
cp -R "$SRC/macos/GhosttyKit.xcframework" "$VENDOR/GhosttyKit.xcframework"
mkdir -p "$VENDOR/ghostty-resources"
cp -R "$SRC/zig-out/share/ghostty" "$VENDOR/ghostty-resources/ghostty"
cp -R "$SRC/zig-out/share/terminfo" "$VENDOR/ghostty-resources/terminfo"
echo "GhosttyKit ready at $VENDOR/GhosttyKit.xcframework"
