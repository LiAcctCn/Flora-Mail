#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
CONFIGURATION="${1:-release}"
if [[ "$CONFIGURATION" != "release" && "$CONFIGURATION" != "debug" ]]; then
  echo "Usage: ./Scripts/build-app.sh [release|debug]" >&2
  exit 1
fi
export CLANG_MODULE_CACHE_PATH="$PROJECT_DIR/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PROJECT_DIR/.build/ModuleCache"
swift build --disable-sandbox --cache-path "$PROJECT_DIR/.build/cache" -c "$CONFIGURATION"
BINARY_DIR="$(swift build --disable-sandbox --cache-path "$PROJECT_DIR/.build/cache" -c "$CONFIGURATION" --show-bin-path)"
APP_PATH="$PROJECT_DIR/build/Flora Mail.app"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
cp "$BINARY_DIR/FloraMail" "$APP_PATH/Contents/MacOS/FloraMail"
cp "$PROJECT_DIR/Scripts/Info.plist" "$APP_PATH/Contents/Info.plist"
codesign --force --sign - "$APP_PATH"
echo "Built: $APP_PATH"
echo "Launch: open \"$APP_PATH\""
