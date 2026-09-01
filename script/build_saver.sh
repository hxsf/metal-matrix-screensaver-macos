#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT/.build"
DIST_DIR="$ROOT/dist"
BUNDLE="$DIST_DIR/MetalMatrix.saver"
EXECUTABLE="$BUNDLE/Contents/MacOS/MetalMatrix"

SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
ARCHS="${ARCHS:-arm64 x86_64}"

rm -rf "$BUILD_DIR" "$BUNDLE"
mkdir -p "$BUILD_DIR" "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
export CLANG_MODULE_CACHE_PATH="$BUILD_DIR/ModuleCache"
export SWIFT_MODULE_CACHE_PATH="$BUILD_DIR/ModuleCache"

ARCH_OUTPUTS=()
for ARCH in $ARCHS; do
  ARCH_EXECUTABLE="$BUILD_DIR/MetalMatrix-$ARCH"
  xcrun --sdk macosx swiftc \
    -parse-as-library \
    -emit-library \
    -module-name MetalMatrix \
    -target "$ARCH-apple-macos11.0" \
    -sdk "$SDK_PATH" \
    -O \
    -Xlinker -bundle \
    -framework AppKit \
    -framework QuartzCore \
    -framework ScreenSaver \
    -framework Metal \
    -framework MetalKit \
    "$ROOT/Sources/MatrixSaverView.swift" \
    "$ROOT/Sources/MatrixSettings.swift" \
    "$ROOT/Sources/MatrixSimulationCoordinator.swift" \
    "$ROOT/Sources/MatrixRenderer.swift" \
    -o "$ARCH_EXECUTABLE"
  ARCH_OUTPUTS+=("$ARCH_EXECUTABLE")
done

if [ "${#ARCH_OUTPUTS[@]}" -gt 1 ]; then
  xcrun lipo -create "${ARCH_OUTPUTS[@]}" -output "$EXECUTABLE"
else
  cp "${ARCH_OUTPUTS[0]}" "$EXECUTABLE"
fi

cp "$ROOT/Resources/Info.plist" "$BUNDLE/Contents/Info.plist"
cp -R "$ROOT"/Resources/*.lproj "$BUNDLE/Contents/Resources/"
cp "$ROOT/Resources/matrix3.xpm" "$BUNDLE/Contents/Resources/matrix3.xpm"
cp "$ROOT/GLMatrix.saver/Icon" "$BUNDLE/Icon" 2>/dev/null || true
codesign --force --sign - "$BUNDLE" >/dev/null

file "$EXECUTABLE"
echo "Built $BUNDLE"
