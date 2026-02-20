#!/bin/bash
set -euo pipefail

# Creates a DMG installer for ErrandDesktop.
# Usage: ./scripts/create-dmg.sh <path-to-app-bundle> [output-dmg-path]

APP_PATH="${1:?Usage: create-dmg.sh <path-to-ErrandDesktop.app> [output.dmg]}"
DMG_PATH="${2:-ErrandDesktop.dmg}"
VOLUME_NAME="ErrandDesktop"
STAGING_DIR="$(mktemp -d)"

cleanup() {
    rm -rf "$STAGING_DIR"
    # Detach any leftover mounts
    hdiutil detach "/Volumes/$VOLUME_NAME" 2>/dev/null || true
}
trap cleanup EXIT

echo "==> Preparing DMG contents..."
cp -R "$APP_PATH" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"

echo "==> Creating DMG..."
hdiutil create \
    -volname "$VOLUME_NAME" \
    -srcfolder "$STAGING_DIR" \
    -ov \
    -format UDZO \
    -imagekey zlib-level=9 \
    "$DMG_PATH"

echo "==> DMG created at $DMG_PATH"
