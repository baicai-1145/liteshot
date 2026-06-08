#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/.build/release"
APP_DIR="$ROOT_DIR/build/LiteShot.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
APP_VERSION="${LITESHOT_VERSION:-0.1.0}"
APP_BUILD="${LITESHOT_BUILD:-1}"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"

swift build -c release --product LiteShot

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR"
cp "$BUILD_DIR/LiteShot" "$MACOS_DIR/LiteShot"

cat > "$CONTENTS_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>LiteShot</string>
    <key>CFBundleIdentifier</key>
    <string>local.baicai1145.liteshot</string>
    <key>CFBundleName</key>
    <string>LiteShot</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${APP_VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${APP_BUILD}</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>MIT License</string>
</dict>
</plist>
PLIST

codesign_args=(--force --deep --sign "$CODESIGN_IDENTITY")
if [[ "$CODESIGN_IDENTITY" != "-" ]]; then
    codesign_args+=(--options runtime --timestamp)
fi
codesign "${codesign_args[@]}" "$APP_DIR"

echo "$APP_DIR"
