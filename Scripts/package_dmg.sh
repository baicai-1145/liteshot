#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT_DIR/build/LiteShot.app"
DIST_DIR="$ROOT_DIR/dist"
VERSION="${LITESHOT_VERSION:-0.1.0}"
DMG_PATH="$DIST_DIR/LiteShot-${VERSION}.dmg"
WORK_DIR="$(mktemp -d)"

cleanup() {
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

"$ROOT_DIR/Scripts/package_app.sh" >/dev/null

rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"
cp -R "$APP_DIR" "$WORK_DIR/LiteShot.app"
ln -s /Applications "$WORK_DIR/Applications"

hdiutil create \
    -volname "LiteShot" \
    -srcfolder "$WORK_DIR" \
    -ov \
    -format UDZO \
    "$DMG_PATH" >/dev/null

if [[ "${CODESIGN_IDENTITY:--}" != "-" ]]; then
    codesign --force --sign "$CODESIGN_IDENTITY" --timestamp "$DMG_PATH"
fi

echo "$DMG_PATH"
