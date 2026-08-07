#!/bin/bash
# ============================================================
#  LUFSBar  make_pkg.sh
#  Builds a .pkg installer from the signed and notarized .app produced by
#  notarize.sh, then notarizes and staples the .pkg itself.
#  Run bash notarize.sh first.
# ============================================================
set -e

SIGN_INST="Developer ID Installer: Ryo Yoneya (WDFKYGRKRW)"
NOTARY_PROFILE="VOXNotary"
APP_NAME="LUFSBar"
VERSION="1.1"
BUNDLE_ID="com.tokyomeltdown.lufsbar"

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_TMP="/tmp/${APP_NAME}_notarize/$APP_NAME.app"
WORK="/tmp/${APP_NAME}_pkg_work"
DIST_DIR="$ROOT/dist"
PKG_SIGNED="$DIST_DIR/${APP_NAME}_${VERSION}.pkg"
# A copy without the version number. Uploading it to GitHub Releases under this
# name makes releases/latest/download/LUFSBar.pkg always point at the newest build.
PKG_LATEST="$DIST_DIR/${APP_NAME}.pkg"

echo "=========================================="
echo "  LUFSBar  make_pkg.sh  (v${VERSION})"
echo "=========================================="

if [ ! -d "$APP_TMP" ]; then
    echo "ERROR: signed and notarized app not found: $APP_TMP"
    echo "Run bash notarize.sh first."
    exit 1
fi

rm -rf "$WORK"
mkdir -p "$WORK/root/Applications" "$WORK/scripts" "$DIST_DIR"
ditto --norsrc --noextattr --noqtn --noacl "$APP_TMP" "$WORK/root/Applications/$APP_NAME.app"

# ---- postinstall: launch LUFSBar as soon as the install finishes ----
#   A pkg postinstall runs as root, so a plain open would start the app as root
#   and it would never appear in the logged-in user menu bar. launchctl asuser
#   enters the console user session first.
#   On an update, the old process is killed first: if it survives, the new
#   process hits the single-instance guard and quits immediately, leaving the
#   app not running after the update.
cat > "$WORK/scripts/postinstall" << 'EOF'
#!/bin/bash
CONSOLE_USER=$(stat -f%Su /dev/console)
USER_ID=$(id -u "$CONSOLE_USER")
if [ -n "$USER_ID" ] && [ "$CONSOLE_USER" != "root" ]; then
    launchctl asuser "$USER_ID" sudo -u "$CONSOLE_USER" \
        pkill -x LUFSBar 2>/dev/null || true
    sleep 1
    launchctl asuser "$USER_ID" sudo -u "$CONSOLE_USER" \
        open -a "/Applications/LUFSBar.app"
fi
exit 0
EOF
chmod +x "$WORK/scripts/postinstall"

# ---- Step 1: pkgbuild (installs into /Applications) + Developer ID Installer signature ----
echo "[1/4] pkgbuild + sign ..."
pkgbuild \
    --root "$WORK/root" \
    --scripts "$WORK/scripts" \
    --install-location "/" \
    --identifier "$BUNDLE_ID" \
    --version "$VERSION" \
    --sign "$SIGN_INST" \
    "$PKG_SIGNED"

# ---- Step 2: notarize the pkg ----
echo "[2/4] notarize pkg (submit & wait) ..."
xcrun notarytool submit "$PKG_SIGNED" \
    --keychain-profile "$NOTARY_PROFILE" --wait

# ---- Step 3: staple ----
echo "[3/4] staple ..."
xcrun stapler staple "$PKG_SIGNED"
xcrun stapler validate "$PKG_SIGNED"

# ---- Step 4: verify ----
echo "[4/5] verify ..."
spctl -a -vvv -t install "$PKG_SIGNED" || true
pkgutil --check-signature "$PKG_SIGNED"

# ---- Step 5: version-less copy for the GitHub Releases upload ----
#   This is a plain copy of an already signed and stapled file, so the signature
#   and the notarization ticket stay valid.
echo "[5/5] copy version-less release asset ..."
cp "$PKG_SIGNED" "$PKG_LATEST"
pkgutil --check-signature "$PKG_LATEST"

echo ""
echo "=========================================="
echo "  .pkg is ready."
echo "  For the archive : $PKG_SIGNED"
echo "  For Releases    : $PKG_LATEST"
echo "=========================================="
