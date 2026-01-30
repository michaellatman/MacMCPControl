#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="MacMCPControl"
APP_DIR="$ROOT_DIR/${APP_NAME}.app"

cd "$ROOT_DIR"

swift build -c release

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$ROOT_DIR/.build/release/$APP_NAME" "$APP_DIR/Contents/MacOS/$APP_NAME"

cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>
  <string>Mac MCP Control</string>
  <key>CFBundleDisplayName</key>
  <string>Mac MCP Control</string>
  <key>CFBundleIdentifier</key>
  <string>com.michaellatman.mac-mcp-control</string>
  <key>CFBundleExecutable</key>
  <string>MacMCPControl</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon.icns</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSHumanReadableCopyright</key>
  <string>Copyright (c) 2026</string>
</dict>
</plist>
PLIST

if [ -f "$ROOT_DIR/Sources/MacMCPControl/Resources/AppIcon.icns" ]; then
  cp "$ROOT_DIR/Sources/MacMCPControl/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
fi

if [ -f "$ROOT_DIR/Sources/MacMCPControl/Resources/MenuBarIcon.png" ]; then
  cp "$ROOT_DIR/Sources/MacMCPControl/Resources/MenuBarIcon.png" "$APP_DIR/Contents/Resources/MenuBarIcon.png"
fi

for bundle in "$ROOT_DIR/.build/release"/*.bundle; do
  if [ -d "$bundle" ]; then
    cp -R "$bundle" "$APP_DIR/Contents/Resources/"
  fi
done

if command -v ngrok >/dev/null 2>&1; then
  NGR_BIN="$(command -v ngrok)"
  cp "$NGR_BIN" "$APP_DIR/Contents/Resources/ngrok"
  chmod +x "$APP_DIR/Contents/Resources/ngrok"
  echo "Bundled ngrok from $NGR_BIN"
else
  echo "ngrok not found on PATH. App will expect ngrok on PATH." >&2
fi

echo "Built $APP_DIR"
