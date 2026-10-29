#!/bin/bash
# ============================================================
#  LUFSBar  notarize.sh
#  Takes the native Xcode app (Release) through
#    Developer ID signing (with entitlements) -> notarization -> stapling
#  The steps mirror the notarize.sh of the JUCE projects, minus the
#  Projucer stage, which does not apply here.
#  Building the .pkg is a separate step: see make_pkg.sh
# ============================================================
set -e

# Name, version, work folder and signing identity: see release_settings.sh.
source "$(cd "$(dirname "$0")" && pwd)/release_settings.sh"
WORK_DIR="$RELEASE_DIR/notarize"
# The last run's signed app goes first, before any check below can stop this
# run: left behind, make_pkg.sh would wrap it as though it were this build.
rm -rf "$WORK_DIR"

load_signer
SIGN_ID="Developer ID Application: $SIGNER"

# ---- Paths ----
BUILD_DIR="$RELEASE_DIR/build"
APP_BUILT="$BUILD_DIR/Build/Products/Release/$APP_NAME.app"
ENTITLEMENTS="$ROOT/LUFSBar/LUFSBar.entitlements"

APP_TMP="$WORK_DIR/$APP_NAME.app"
ZIP_NOTARIZE="$RELEASE_DIR/submit.zip"

echo "=========================================="
echo "  LUFSBar  Notarize Build (Release)"
echo "=========================================="

# ---- Step 1: Release build (signed manually later) ----
#   Without -destination, xcodebuild picks one specific Mac (arch:arm64) as the
#   destination, and even with x86_64 listed in ARCHS it effectively builds a
#   single architecture, as if ONLY_ACTIVE_ARCH=YES were set.
#   (An arm64-only binary really was produced this way once.)
#   Passing generic/platform=macOS gives the universal binary ARCHS asks for.
echo "[1/6] xcodebuild Release (Universal) ..."
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
BUILD_LOG="$RELEASE_DIR/xcodebuild.log"
set +e
xcodebuild \
    -project "$ROOT/LUFSBar.xcodeproj" \
    -scheme LUFSBar \
    -configuration Release \
    -destination "generic/platform=macOS" \
    -derivedDataPath "$BUILD_DIR" \
    CODE_SIGN_IDENTITY="" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO \
    > "$BUILD_LOG" 2>&1
BUILD_STATUS=$?
set -e
grep -E "^(Build|error:|warning:|\*\*)|: error:" "$BUILD_LOG" || true

# The build's own answer decides, not whether a bundle appeared: a failed
# compile still leaves LUFSBar.app behind, with an empty MacOS folder, and the
# old check let it go on to be signed. (Piping xcodebuild into grep with
# "|| true" had thrown that answer away.)
if [ "$BUILD_STATUS" -ne 0 ]; then
    echo "  ERROR: xcodebuild failed (exit $BUILD_STATUS). Full log: $BUILD_LOG"
    exit 1
fi
if [ ! -x "$APP_BUILT/Contents/MacOS/$APP_NAME" ]; then
    echo "  ERROR: no executable in the build output: $APP_BUILT"
    exit 1
fi
BUILT_VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_BUILT/Contents/Info.plist")"
if [ "$BUILT_VERSION" != "$VERSION" ]; then
    echo "  ERROR: the build is version $BUILT_VERSION, but the project says $VERSION."
    exit 1
fi

# ---- Step 2: clean copy to the work folder, then sign with the Developer ID and entitlements ----
#   IMPORTANT: the project lives under a synced/watched folder, which attaches
#   com.apple.FinderInfo just before signing and makes codesign fail every time.
#   Copying it out of the project with ditto --noextattr first avoids it.
#   Signing is disabled during xcodebuild, so the entitlements (required for
#   system audio access) must be applied explicitly here or they are lost.
echo "[2/6] clean copy to the work folder + codesign (Developer ID + hardened runtime + entitlements) ..."
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
ditto --norsrc --noextattr --noqtn --noacl "$APP_BUILT" "$APP_TMP"
codesign --force --options runtime --timestamp \
    --entitlements "$ENTITLEMENTS" \
    --sign "$SIGN_ID" "$APP_TMP"

# ---- Step 3: verify the signature ----
echo "[3/6] verify signature + entitlements ..."
codesign --verify --strict --verbose=2 "$APP_TMP"
codesign -d --entitlements :- "$APP_TMP"

# ---- Step 4: zip for submission, then notarize and wait ----
echo "[4/6] notarize (submit & wait) ..."
rm -f "$ZIP_NOTARIZE"
ditto -c -k --keepParent "$APP_TMP" "$ZIP_NOTARIZE"
if ! notarize_and_wait "$ZIP_NOTARIZE"; then
    echo "ERROR: Apple did not accept the app (see the report above)."
    exit 1
fi

# ---- Step 5: staple the ticket to the .app and validate ----
echo "[5/6] staple ..."
xcrun stapler staple "$APP_TMP"
xcrun stapler validate "$APP_TMP"
spctl -a -vvv "$APP_TMP" || true

echo "[6/6] done."
echo ""
echo "=========================================="
echo "  Notarization complete."
echo "  Signed app: $APP_TMP"
echo "  Next, run  bash make_pkg.sh  to build the installer"
echo "=========================================="
