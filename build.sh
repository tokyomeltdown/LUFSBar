#!/bin/bash
# ============================================================
#  LUFSBar build.sh
#  ~/Documents配下(iCloud Drive同期下)でxcodebuildすると、ビルド成果物に
#  File Provider属性が付いてcodesignが失敗する(resource fork/Finder情報エラー)。
#  DerivedDataを/tmp(同期対象外)に出すことでこれを回避する。
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
