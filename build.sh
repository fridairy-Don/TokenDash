#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

CONFIG="${CONFIG:-release}"
APP_NAME="TokenDash"
APP_BUNDLE="$APP_NAME.app"

echo "==> Building ($CONFIG)"
swift build -c "$CONFIG"

BIN=".build/$CONFIG/$APP_NAME"
if [ ! -x "$BIN" ]; then
    echo "Build failed: binary not found at $BIN" >&2
    exit 1
fi

echo "==> Assembling $APP_BUNDLE"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$BIN" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"

# Copy the Web/ assets (HTML/JSX + React/Babel UMD) into the bundle.
mkdir -p "$APP_BUNDLE/Contents/Resources/Web"
cp -R "Web/dashboard.html" "$APP_BUNDLE/Contents/Resources/Web/"
cp -R "Web/app.jsx"        "$APP_BUNDLE/Contents/Resources/Web/"
cp -R "Web/vendor"         "$APP_BUNDLE/Contents/Resources/Web/"

# App icon — regenerate if missing, then copy into Resources.
if [ ! -f "Resources/AppIcon.icns" ]; then
    echo "==> Generating AppIcon.iconset"
    swift tools/generate_icon.swift
    iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns
fi
cp "Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

# Ad-hoc sign so Gatekeeper lets us run it locally.
codesign --force --sign - "$APP_BUNDLE" >/dev/null 2>&1 || true

echo "==> Built $(pwd)/$APP_BUNDLE"
echo ""
echo "Run with:"
echo "  open $(pwd)/$APP_BUNDLE"
echo "Or directly (stdout visible):"
echo "  ./$APP_BUNDLE/Contents/MacOS/$APP_NAME"
