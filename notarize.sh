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

# ---- Settings (specific to this machine and account) ----
# The signing identity names the Apple account and the team it belongs to.
# Every signed copy carries it, so it is not much of a secret, but AGENTS.md
# section 3 keeps values of that kind out of the source. It is read from the
# environment, or from one line in a file outside the tree.
SIGNER_FILE="$HOME/.config/tokyomeltdown/signer"
if [ -z "${SIGNER:-}" ] && [ -f "$SIGNER_FILE" ]; then
    SIGNER="$(head -1 "$SIGNER_FILE")"
fi
if [ -z "${SIGNER:-}" ]; then
    echo "ERROR: no signing identity."
    echo "Put the account name and team on one line in $SIGNER_FILE"
    exit 1
fi
SIGN_ID="Developer ID Application: $SIGNER"
NOTARY_PROFILE="VOXNotary"
APP_NAME="LUFSBar"
VERSION="1.1"

# ---- Paths ----
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

# ---- Step 1: Release build (signed manually later) ----
#   Without -destination, xcodebuild picks one specific Mac (arch:arm64) as the
#   destination, and even with x86_64 listed in ARCHS it effectively builds a
#   single architecture, as if ONLY_ACTIVE_ARCH=YES were set.
#   (An arm64-only binary really was produced this way once.)
#   Passing generic/platform=macOS gives the universal binary ARCHS asks for.
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
    echo "  ERROR: build output not found: $APP_BUILT"
    exit 1
fi

# ---- Step 2: clean copy to /tmp, then sign with the Developer ID and entitlements ----
#   IMPORTANT: the project lives under a synced/watched folder, which attaches
#   com.apple.FinderInfo just before signing and makes codesign fail every time.
#   Copying to /tmp with ditto --noextattr first avoids it.
#   Signing is disabled during xcodebuild, so the entitlements (required for
#   system audio access) must be applied explicitly here or they are lost.
echo "[2/6] clean copy to /tmp + codesign (Developer ID + hardened runtime + entitlements) ..."
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
xcrun notarytool submit "$ZIP_NOTARIZE" \
    --keychain-profile "$NOTARY_PROFILE" --wait

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
