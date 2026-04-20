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

# App icon — regenerate icns whenever the iconset PNGs are newer, so edits to
# the source art or re-runs of install_icon.swift always propagate.
ICONSET_DIR="Resources/AppIcon.iconset"
ICNS_OUT="Resources/AppIcon.icns"
need_icns=0
if [ ! -f "$ICNS_OUT" ]; then
    need_icns=1
elif [ -d "$ICONSET_DIR" ]; then
    # any iconset PNG newer than the icns?
    if find "$ICONSET_DIR" -name '*.png' -newer "$ICNS_OUT" -print -quit | grep -q .; then
        need_icns=1
    fi
fi
if [ ! -d "$ICONSET_DIR" ] || [ -z "$(ls "$ICONSET_DIR"/*.png 2>/dev/null)" ]; then
    echo "==> Generating AppIcon.iconset"
    swift tools/generate_icon.swift
    need_icns=1
fi
if [ "$need_icns" = "1" ]; then
    echo "==> Compiling $ICNS_OUT"
    rm -f "$ICNS_OUT"
    iconutil -c icns "$ICONSET_DIR" -o "$ICNS_OUT"
fi
cp "$ICNS_OUT" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

# Ad-hoc sign so Gatekeeper lets us run it locally.
codesign --force --sign - "$APP_BUNDLE" >/dev/null 2>&1 || true

echo "==> Built $(pwd)/$APP_BUNDLE"
echo ""
echo "Run with:"
echo "  open $(pwd)/$APP_BUNDLE"
echo "Or directly (stdout visible):"
echo "  ./$APP_BUNDLE/Contents/MacOS/$APP_NAME"
