#!/bin/bash
# ============================================================
#  LUFSBar build.sh
#  Building under ~/Documents (which is synced by iCloud Drive) attaches File
#  Provider attributes to the build output, and codesign then fails with a
#  resource fork / Finder info error. Putting DerivedData in /tmp avoids it.
# ============================================================
set -e

ROOT="$(cd "$(dirname "$0")" && pwd)"
DERIVED_DATA="/tmp/LUFSBar-build"
APP_NAME="LUFSBar"

echo "=========================================="
echo "  LUFSBar Build Script"
echo "=========================================="

xcodebuild -project "$ROOT/LUFSBar.xcodeproj" -scheme "$APP_NAME" \
    -configuration Debug -derivedDataPath "$DERIVED_DATA" build

APP_PATH="$DERIVED_DATA/Build/Products/Debug/$APP_NAME.app"

echo ""
echo "=========================================="
echo "  Build complete!"
echo "  App: $APP_PATH"
echo "=========================================="
