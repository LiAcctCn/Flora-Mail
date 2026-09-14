#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

# Packaging is local only. It does not sign with a developer identity, notarize,
# upload, include application-support data or access account credentials.
./Scripts/build-app.sh release
APP_PATH="$PROJECT_DIR/build/Flora Mail.app"
STAGING_PATH="$(mktemp -d "$PROJECT_DIR/build/release-package.XXXXXX")"
trap 'rm -rf -- "$STAGING_PATH"' EXIT
ARCHIVE_PATH="$PROJECT_DIR/build/Flora-Mail-Release.zip"
codesign --verify --deep --strict "$APP_PATH"
plutil -lint "$APP_PATH/Contents/Info.plist"

ditto "$APP_PATH" "$STAGING_PATH/Flora Mail.app"
cp "$PROJECT_DIR/Docs/ReleaseGuide.md" "$STAGING_PATH/Read Me.txt"
{
    /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist"
    git rev-parse HEAD
    lipo -archs "$APP_PATH/Contents/MacOS/FloraMail"
    echo "Local ad hoc signature; no Developer ID or notarization."
} > "$STAGING_PATH/Build Information.txt"
ditto -c -k --sequesterRsrc "$STAGING_PATH" "$ARCHIVE_PATH"
(cd "$PROJECT_DIR/build" && shasum -a 256 Flora-Mail-Release.zip > Flora-Mail-Release.zip.sha256)
echo "Packaged: $ARCHIVE_PATH"
