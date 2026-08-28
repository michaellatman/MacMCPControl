#!/usr/bin/env bash
set -euo pipefail
: "${APPLE_SIGNING_IDENTITY:?Set a Developer ID Application signing identity}"
: "${APP_STORE_CONNECT_API_KEY_BASE64:?Set the base64-encoded App Store Connect API private key}"
: "${APP_STORE_CONNECT_KEY_ID:?Set the App Store Connect API key ID}"
: "${APP_STORE_CONNECT_ISSUER_ID:?Set the App Store Connect API issuer ID}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
APP_PATH="$ROOT_DIR/MacMCPControl.app"
NOTARY_DIR="$(mktemp -d)"
trap 'rm -rf "$NOTARY_DIR"' EXIT
umask 077
printf '%s' "$APP_STORE_CONNECT_API_KEY_BASE64" | base64 --decode > "$NOTARY_DIR/AuthKey.p8"

# Sign nested executable code before sealing the outer app.
NGROK_PATH="$(find "$APP_PATH/Contents/Resources/MacMCPControl_MacMCPControl.bundle" -type f -name ngrok)"
[[ -f "$NGROK_PATH" ]] || { echo "Expected exactly one bundled ngrok executable" >&2; exit 1; }
codesign --force --options runtime --timestamp --sign "$APPLE_SIGNING_IDENTITY" "$NGROK_PATH"
codesign --force --options runtime --timestamp --sign "$APPLE_SIGNING_IDENTITY" "$APP_PATH"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
ditto -c -k --keepParent "$APP_PATH" "$NOTARY_DIR/submission.zip"

xcrun notarytool submit "$NOTARY_DIR/submission.zip" \
  --key "$NOTARY_DIR/AuthKey.p8" --key-id "$APP_STORE_CONNECT_KEY_ID" \
  --issuer "$APP_STORE_CONNECT_ISSUER_ID" --wait --output-format json > "$NOTARY_DIR/result.json"
NOTARY_STATUS="$(plutil -extract status raw -o - "$NOTARY_DIR/result.json")"
if [[ "$NOTARY_STATUS" != Accepted ]]; then
  NOTARY_ID="$(plutil -extract id raw -o - "$NOTARY_DIR/result.json")"
  xcrun notarytool log "$NOTARY_ID" --key "$NOTARY_DIR/AuthKey.p8" \
    --key-id "$APP_STORE_CONNECT_KEY_ID" --issuer "$APP_STORE_CONNECT_ISSUER_ID"
  printf 'Notarization failed: %s\n' "$NOTARY_STATUS" >&2
  exit 1
fi
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
spctl --assess --type execute --verbose=4 "$APP_PATH"

# Archive only after stapling; validate the exact ZIP that will be uploaded.
ditto -c -k --keepParent "$APP_PATH" "$ROOT_DIR/MacMCPControl.zip"
tar -czf "$ROOT_DIR/MacMCPControl.app.tar.gz" -C "$ROOT_DIR" MacMCPControl.app
mkdir "$NOTARY_DIR/extracted"
ditto -x -k "$ROOT_DIR/MacMCPControl.zip" "$NOTARY_DIR/extracted"
codesign --verify --deep --strict --verbose=2 "$NOTARY_DIR/extracted/MacMCPControl.app"
xcrun stapler validate "$NOTARY_DIR/extracted/MacMCPControl.app"
spctl --assess --type execute --verbose=4 "$NOTARY_DIR/extracted/MacMCPControl.app"
