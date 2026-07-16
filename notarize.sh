#!/bin/bash
# ============================================================
#  LUFSBar  notarize.sh
#  Xcodeネイティブアプリ(Release)を
#    Developer ID 署名(entitlements込み) → 公証(notarize) → staple
#  ※ VOX Synchronizer/MSWidthのnotarize.shと同じ手順だが、
#    JUCE/Projucerを使わないため該当ステップは無い。
#  ※ .pkg化は別途 make_pkg.sh で行う
# ============================================================
set -e

# ---- 設定（環境固有の値） ----
SIGN_ID="Developer ID Application: Ryo Yoneya (WDFKYGRKRW)"
NOTARY_PROFILE="VOXNotary"
APP_NAME="LUFSBar"
VERSION="1.1"

# ---- パス ----
ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="/tmp/LUFSBar-release-build"
APP_BUILT="$BUILD_DIR/Build/Products/Release/$APP_NAME.app"
ENTITLEMENTS="$ROOT/LUFSBar/LUFSBar.entitlements"

WORK_DIR="/tmp/${APP_NAME}_notarize"
APP_TMP="$WORK_DIR/$APP_NAME.app"
ZIP_NOTARIZE="/tmp/${APP_NAME}_submit.zip"

echo "=========================================="
echo "  LUFSBar  Notarize Build (Release)"
echo "=========================================="

# ---- Step 1: Release ビルド（署名は後で手動） ----
#   -destination を省略すると xcodebuild が「具体的な1台のMac(arch:arm64)」を
#   実行先として選んでしまい、ARCHSに x86_64 を指定していても実質
#   ONLY_ACTIVE_ARCH=YESのように単一アーキテクチャでしかビルドされない
#   （実際にarm64のみのバイナリが生成される罠を踏んだ）。
#   generic/platform=macOS を明示することでARCHS通りのUniversal Binaryになる。
echo "[1/6] xcodebuild Release (Universal) ..."
rm -rf "$BUILD_DIR"
xcodebuild \
    -project "$ROOT/LUFSBar.xcodeproj" \
    -scheme LUFSBar \
    -configuration Release \
    -destination "generic/platform=macOS" \
    -derivedDataPath "$BUILD_DIR" \
    CODE_SIGN_IDENTITY="" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO \
    | grep -E "^(Build|error:|warning:|\*\*)" || true

if [ ! -d "$APP_BUILT" ]; then
    echo "  ERROR: ビルド成果物が見つかりません: $APP_BUILT"
    exit 1
fi

# ---- Step 2: /tmp にクリーンコピー → Developer ID 署名(entitlements込み) ----
#   ※ 重要：プロジェクトは ~/Documents/Claude/... 配下で同期/監視されており、
#      署名直前に com.apple.FinderInfo が付与されて codesign が必ず失敗する。
#      監視外の /tmp にクリーンコピー（ditto --noextattr）してから署名する。
#   ※ xcodebuildで署名を無効化しているため、entitlements(システムオーディオ
#      アクセスに必須)をここで明示的に付与しないと本番ビルドで機能しなくなる。
echo "[2/6] clean copy to /tmp + codesign (Developer ID + hardened runtime + entitlements) ..."
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
ditto --norsrc --noextattr --noqtn --noacl "$APP_BUILT" "$APP_TMP"
codesign --force --options runtime --timestamp \
    --entitlements "$ENTITLEMENTS" \
    --sign "$SIGN_ID" "$APP_TMP"

# ---- Step 3: 署名検証 ----
echo "[3/6] verify signature + entitlements ..."
codesign --verify --strict --verbose=2 "$APP_TMP"
codesign -d --entitlements :- "$APP_TMP"

# ---- Step 4: 公証用zip作成 → notarytool 申請（完了まで待機） ----
echo "[4/6] notarize (submit & wait) ..."
rm -f "$ZIP_NOTARIZE"
ditto -c -k --keepParent "$APP_TMP" "$ZIP_NOTARIZE"
xcrun notarytool submit "$ZIP_NOTARIZE" \
    --keychain-profile "$NOTARY_PROFILE" --wait

# ---- Step 5: staple（公証チケットを.appに添付）＋検証 ----
echo "[5/6] staple ..."
xcrun stapler staple "$APP_TMP"
xcrun stapler validate "$APP_TMP"
spctl -a -vvv "$APP_TMP" || true

echo "[6/6] done."
echo ""
echo "=========================================="
echo "  公証完了！"
echo "  署名済みアプリ: $APP_TMP"
echo "  次は bash make_pkg.sh で.pkgインストーラーを作成できます"
echo "=========================================="
