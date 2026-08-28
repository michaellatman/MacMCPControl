#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bash "$ROOT_DIR/scripts/build-app.sh"
# Local development only. Releases use notarize.sh and require a Developer ID identity.
codesign --force --sign "${APPLE_SIGNING_IDENTITY:--}" "$ROOT_DIR/MacMCPControl.app"
printf 'Built local app: %s\n' "$ROOT_DIR/MacMCPControl.app"
