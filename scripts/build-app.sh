#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
APP_NAME=MacMCPControl
APP_DIR="$ROOT_DIR/$APP_NAME.app"
swift build -c release --product "$APP_NAME"
BUILD_DIR="$(swift build -c release --show-bin-path)"

# Replace only this script's generated app bundle.
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BUILD_DIR/$APP_NAME" "$APP_DIR/Contents/MacOS/"
cp -R "$BUILD_DIR/MacMCPControl_MacMCPControl.bundle" "$APP_DIR/Contents/Resources/"
cp "$ROOT_DIR/Sources/MacMCPControl/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/"
cp "$ROOT_DIR/Vendor/Swifter/LICENSE" "$APP_DIR/Contents/Resources/Swifter-LICENSE"
# SwiftPM bundles can be flat or use Contents/Resources, depending on Xcode.
NGROK_PATH="$(find "$APP_DIR/Contents/Resources/MacMCPControl_MacMCPControl.bundle" -type f -name ngrok)"
[[ -f "$NGROK_PATH" ]] || { echo "Expected exactly one bundled ngrok executable" >&2; exit 1; }
chmod +x "$NGROK_PATH"
cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>MacMCPControl</string>
  <key>CFBundleIdentifier</key><string>com.macmcpcontrol.app</string>
  <key>CFBundleName</key><string>Mac MCP Control</string>
  <key>CFBundleDisplayName</key><string>Mac MCP Control</string>
  <key>CFBundleVersion</key><string>1.0</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
</dict></plist>
PLIST
# Run the packaged executable, not the SwiftPM build-tree executable. This must work
# without reaching back into the build directory or starting the control server.
"$APP_DIR/Contents/MacOS/$APP_NAME" --check-bundled-resources
printf 'Built %s\n' "$APP_DIR"
