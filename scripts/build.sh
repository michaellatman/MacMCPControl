#!/bin/bash
set -e

cd "$(dirname "$0")/.."

APP_PATH="MacMCPControl.app"

echo "Building release..."
swift build -c release

echo "Updating app bundle..."
rm -rf "$APP_PATH"
mkdir -p "$APP_PATH/Contents/MacOS"
mkdir -p "$APP_PATH/Contents/Resources"

# Copy the executable
cp .build/release/MacMCPControl "$APP_PATH/Contents/MacOS/"

# Copy resources
cp -R .build/release/MacMCPControl_MacMCPControl.bundle "$APP_PATH/Contents/Resources/"
cp .build/release/MacMCPControl_MacMCPControl.bundle/AppIcon.icns "$APP_PATH/Contents/Resources/"

# Create Info.plist
cat > "$APP_PATH/Contents/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>MacMCPControl</string>
    <key>CFBundleIdentifier</key>
    <string>com.macmcpcontrol.app</string>
    <key>CFBundleName</key>
    <string>Mac MCP Control</string>
    <key>CFBundleDisplayName</key>
    <string>Mac MCP Control</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key>
    <true/>
</dict>
</plist>
EOF

# Code sign the app to preserve permissions across rebuilds
echo "Code signing..."
codesign --force --deep --sign "Apple Development: Michael Latman (LS3WA9CYZ5)" "$APP_PATH"

echo "Build complete: $APP_PATH"
