#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

# Local packaging only: no account data, Developer ID, notarization or upload.
./Scripts/build-app.sh release
APP_PATH="$PROJECT_DIR/build/Flora Mail.app"
ICON_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$APP_PATH/Contents/Info.plist")"
ICON_PATH="$PROJECT_DIR/Resources/$ICON_NAME"
test -x "$APP_PATH/Contents/MacOS/FloraMail"
plutil -lint "$APP_PATH/Contents/Info.plist"
cmp "$PROJECT_DIR/Scripts/Info.plist" "$APP_PATH/Contents/Info.plist"
cmp "$ICON_PATH" "$APP_PATH/Contents/Resources/$ICON_NAME"
codesign --verify --deep --strict "$APP_PATH"

WORK_PATH="$(mktemp -d "$PROJECT_DIR/build/dmg-package.XXXXXX")"
PAYLOAD_PATH="$WORK_PATH/payload"
MOUNT_PATH="$WORK_PATH/mount"
TEMP_IMAGE="$WORK_PATH/Flora-Mail-Beta.dmg"
OUTPUT_IMAGE="$PROJECT_DIR/build/Flora-Mail-Beta.dmg"

cleanup() {
  local result=$?
  local mounted_volumes
  trap - EXIT
  # Inspect the actual mount table, including an interrupted attach. Never
  # recursively remove a work directory while its verification volume is mounted.
  if ! mounted_volumes="$(/sbin/mount)"; then
    echo "Cannot inspect mounts; temporary files retained at: $WORK_PATH" >&2
    exit 1
  fi
  if /usr/bin/grep -F " on $MOUNT_PATH (" <<< "$mounted_volumes" >/dev/null; then
    if ! hdiutil detach "$MOUNT_PATH"; then
      echo "Temporary files retained. Detach this volume before cleanup: $MOUNT_PATH" >&2
      exit 1
    fi
  fi
  rm -rf -- "$WORK_PATH"
  exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir -p "$PAYLOAD_PATH" "$MOUNT_PATH"
ditto "$APP_PATH" "$PAYLOAD_PATH/Flora Mail.app"
ln -s /Applications "$PAYLOAD_PATH/Applications"

# A compressed, read-only disk with the standard two-item installation layout.
hdiutil create -volname "Flora Mail Beta" -fs HFS+ -format UDZO \
  -srcfolder "$PAYLOAD_PATH" "$TEMP_IMAGE"
hdiutil verify "$TEMP_IMAGE"
hdiutil attach -readonly -nobrowse -noautoopen -mountpoint "$MOUNT_PATH" "$TEMP_IMAGE"

test -L "$MOUNT_PATH/Applications"
test "$(readlink "$MOUNT_PATH/Applications")" = /Applications
test -x "$MOUNT_PATH/Flora Mail.app/Contents/MacOS/FloraMail"
plutil -lint "$MOUNT_PATH/Flora Mail.app/Contents/Info.plist"
diff -qr "$APP_PATH" "$MOUNT_PATH/Flora Mail.app"
cmp "$ICON_PATH" "$MOUNT_PATH/Flora Mail.app/Contents/Resources/$ICON_NAME"
codesign --verify --deep --strict "$MOUNT_PATH/Flora Mail.app"
hdiutil detach "$MOUNT_PATH"

# Preserve any previous distributable until the new image passes every check.
mv -f "$TEMP_IMAGE" "$OUTPUT_IMAGE"
(cd "$PROJECT_DIR/build" && shasum -a 256 Flora-Mail-Beta.dmg > Flora-Mail-Beta.dmg.sha256)
echo "Packaged and verified: $OUTPUT_IMAGE"
echo "App signing: ad hoc. Disk image: unsigned. Not notarized."
