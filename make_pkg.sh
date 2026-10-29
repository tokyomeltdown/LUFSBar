#!/bin/bash
# ============================================================
#  LUFSBar  make_pkg.sh
#  Builds a .pkg installer from the signed and notarized .app produced by
#  notarize.sh, then notarizes and staples the .pkg itself.
#  Run bash notarize.sh first.
# ============================================================
set -e

HERE="$(cd "$(dirname "$0")" && pwd)"

# The version-less package goes first, before anything below can stop this run:
# it is what gets uploaded to Releases, so a run that stops for any reason must
# not leave the last one there looking like this version. It is PKG_LATEST
# below, spelled out here because release_settings.sh, which names it, can
# itself stop the run. The archived package of each version
# (LUFSBar_<version>.pkg) is only replaced by a run that completes.
rm -f "$HERE/dist/LUFSBar.pkg" "$HERE/dist/LUFSBar.pkg.partial"

# Name, version, work folder and signing identity: see release_settings.sh.
source "$HERE/release_settings.sh"
load_signer
SIGN_INST="Developer ID Installer: $SIGNER"

APP_TMP="$RELEASE_DIR/notarize/$APP_NAME.app"
WORK="$RELEASE_DIR/pkg"
DIST_DIR="$ROOT/dist"
PKG_SIGNED="$DIST_DIR/${APP_NAME}_${VERSION}.pkg"
# Built, notarized and stapled in the work folder, and moved into dist/ only
# once every step has gone through, so nothing unfinished ever sits there under
# a finished package's name, whatever stops the run.
PKG_BUILD="$WORK/${APP_NAME}_${VERSION}.pkg"
# Where a package Apple accepted but that could not be stapled is kept: in dist/,
# which nothing cleans (the work folder is wiped by the next run, and macOS
# empties the temporary folder of files left for three days), under a name no
# one would upload.
PKG_UNSTAPLED="$DIST_DIR/${APP_NAME}_${VERSION}-unstapled.pkg"
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
    "$PKG_BUILD"

# The pin from step 0.5 has to have reached the package, checked before it
# goes to Apple: an empty <relocate/> means nothing may be relocated.
pkgutil --expand "$PKG_BUILD" "$WORK/expanded"
if ! grep -q "<relocate/>" "$WORK/expanded/PackageInfo"; then
    echo "ERROR: the package still lets Installer relocate the app."
    exit 1
fi

# ---- Step 2: notarize the pkg ----
echo "[2/5] notarize pkg (submit & wait) ..."
if ! notarize_and_wait "$PKG_BUILD"; then
    echo "ERROR: Apple did not accept the package (see the report above)."
    exit 1
fi

# ---- Step 3: staple ----
#   Apple has accepted the package by now, so a failure here (the ticket not
#   yet reachable, the network gone) keeps it, to be stapled by hand, rather
#   than costing another signing and notarization.
echo "[3/5] staple ..."
if ! xcrun stapler staple "$PKG_BUILD" || ! xcrun stapler validate "$PKG_BUILD"; then
    mv -f "$PKG_BUILD" "$PKG_UNSTAPLED"
    echo "ERROR: the package was notarized but could not be stapled."
    echo "It is kept as $PKG_UNSTAPLED"
    echo "(running this script again would build and notarize a new one)."
    echo "Wait a little, then finish it with this one line, which stops at the"
    echo "first step that fails:"
    echo "  xcrun stapler staple \"$PKG_UNSTAPLED\" && xcrun stapler validate \"$PKG_UNSTAPLED\" && mv \"$PKG_UNSTAPLED\" \"$PKG_SIGNED\" && cp \"$PKG_SIGNED\" \"$PKG_LATEST\""
    exit 1
fi

# ---- Step 4: verify ----
echo "[4/5] verify ..."
spctl -a -vvv -t install "$PKG_BUILD" || true
pkgutil --check-signature "$PKG_BUILD"

# ---- Step 5: into dist/, with a version-less copy for the GitHub Releases upload ----
#   A plain copy of an already signed and stapled file, so the signature and the
#   notarization ticket stay valid. Copied under another name and renamed once
#   checked, so a copy that stops part way (a full disk) is not left as the
#   upload asset.
echo "[5/5] move into dist/ and copy the version-less release asset ..."
mv -f "$PKG_BUILD" "$PKG_SIGNED"
rm -f "$PKG_UNSTAPLED"
cp "$PKG_SIGNED" "$PKG_LATEST.partial"
pkgutil --check-signature "$PKG_LATEST.partial"
mv -f "$PKG_LATEST.partial" "$PKG_LATEST"

echo ""
echo "=========================================="
echo "  .pkg is ready."
echo "  For the archive : $PKG_SIGNED"
echo "  For Releases    : $PKG_LATEST"
echo "=========================================="
