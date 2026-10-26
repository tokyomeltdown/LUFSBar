#!/bin/bash
# ============================================================
#  LUFSBar  make_pkg.sh
#  Builds a .pkg installer from the signed and notarized .app produced by
#  notarize.sh, then notarizes and staples the .pkg itself.
#  Run bash notarize.sh first.
# ============================================================
set -e

# Name, version, work folder and signing identity: see release_settings.sh.
source "$(cd "$(dirname "$0")" && pwd)/release_settings.sh"
load_signer
SIGN_INST="Developer ID Installer: $SIGNER"

APP_TMP="$RELEASE_DIR/notarize/$APP_NAME.app"
WORK="$RELEASE_DIR/pkg"
DIST_DIR="$ROOT/dist"
PKG_SIGNED="$DIST_DIR/${APP_NAME}_${VERSION}.pkg"
# A copy without the version number. Uploading it to GitHub Releases under this
# name makes releases/latest/download/LUFSBar.pkg always point at the newest build.
PKG_LATEST="$DIST_DIR/${APP_NAME}.pkg"

echo "=========================================="
echo "  LUFSBar  make_pkg.sh  (v${VERSION})"
echo "=========================================="

# Last run's packages go first. The version-less one is what gets uploaded to
# Releases, so a run that stops at a check below must not leave an older one
# there looking like this version.
rm -f "$PKG_SIGNED" "$PKG_LATEST"

if [ ! -d "$APP_TMP" ]; then
    echo "ERROR: signed and notarized app not found: $APP_TMP"
    echo "Run bash notarize.sh first."
    exit 1
fi

# ---- Step 0: is this the app that was just notarized? ----
#   Whatever sits at APP_TMP gets wrapped, and nothing later would notice a
#   wrong one: an app from another version would pass notarization as part of
#   the pkg and ship labelled with this VERSION, and so would an app that was
#   signed but never stapled, since the pkg gets its own ticket.
echo "[0/5] check the app's version and its notarization ..."
APP_VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_TMP/Contents/Info.plist")"
if [ "$APP_VERSION" != "$VERSION" ]; then
    echo "ERROR: $APP_TMP is version $APP_VERSION, not $VERSION."
    echo "Run bash notarize.sh again (the version comes from MARKETING_VERSION)."
    exit 1
fi
if ! xcrun stapler validate "$APP_TMP"; then
    echo "ERROR: $APP_TMP has no notarization ticket stapled to it."
    echo "Run bash notarize.sh again."
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

# ---- Step 0.5: never relocate ----
#   pkgbuild's default makes the bundle relocatable (PackageInfo carries
#   <relocate>): if a copy with the same bundle id is found anywhere else, in
#   the Trash, Downloads or a build folder, Installer updates that one and
#   /Applications keeps the old version, which postinstall then relaunches.
#   1.1 shipped like that.
echo "[0.5/5] component plist (BundleIsRelocatable false) ..."
COMPONENT_PLIST="$WORK/component.plist"
pkgbuild --analyze --root "$WORK/root" "$COMPONENT_PLIST"
/usr/libexec/PlistBuddy -c "Set :0:BundleIsRelocatable false" "$COMPONENT_PLIST"

# ---- Step 1: pkgbuild (installs into /Applications) + Developer ID Installer signature ----
echo "[1/5] pkgbuild + sign ..."
pkgbuild \
    --root "$WORK/root" \
    --component-plist "$COMPONENT_PLIST" \
    --scripts "$WORK/scripts" \
    --install-location "/" \
    --identifier "$BUNDLE_ID" \
    --version "$VERSION" \
    --sign "$SIGN_INST" \
    "$PKG_SIGNED"

# The pin from step 0.5 has to have reached the package, checked before it
# goes to Apple: an empty <relocate/> means nothing may be relocated.
pkgutil --expand "$PKG_SIGNED" "$WORK/expanded"
if ! grep -q "<relocate/>" "$WORK/expanded/PackageInfo"; then
    echo "ERROR: the package still lets Installer relocate the app."
    rm -f "$PKG_SIGNED"
    exit 1
fi

# ---- Step 2: notarize the pkg ----
echo "[2/5] notarize pkg (submit & wait) ..."
xcrun notarytool submit "$PKG_SIGNED" \
    --keychain-profile "$NOTARY_PROFILE" --wait

# ---- Step 3: staple ----
echo "[3/5] staple ..."
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
