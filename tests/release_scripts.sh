#!/bin/zsh
# Runs notarize.sh and make_pkg.sh on a scratch copy of the working tree with
# nothing signed and nothing sent to Apple: codesign, xcrun (notarytool and
# stapler) and spctl are replaced by stubs that log what they were asked, and
# pkgbuild runs for real with its --sign dropped. xcodebuild is real.
#
#   1  a good run goes through, and the app it leaves is the version in the script
#   2  a build that fails stops before anything is signed           (B12)
#   3a make_pkg.sh refuses an app of another version                 (S1)
#   3  make_pkg.sh refuses the app a failed notarize.sh run left     (S1)
#   4  make_pkg.sh refuses an app that is not stapled                (S1)
#   5  the package does not let Installer relocate the app           (B3)
#   6  the work folders are not fixed paths in the shared /tmp       (S1)
#   7  the version comes from the Xcode project alone: with only        (M4)
#      MARKETING_VERSION changed, both scripts build and package that version
#   8  make_pkg.sh stopped for want of a signing identity removes the
#      version-less LUFSBar.pkg (the one that gets uploaded) and keeps the
#      archived package of this version
#   9  a package whose notarization fails is not left behind
#  10  a package that was notarized but could not be stapled is kept in the
#      work folder, not put in dist/ and not thrown away
#
# A run that stops (3, 3a, 4, 8, 9, 10) must remove LUFSBar.pkg and leave the
# archived LUFSBar_<version>.pkg alone; only a run that completes replaces it.
#
# Before the fix the scripts ignore LUFSBAR_RELEASE_DIR and use /tmp/LUFSBar_*,
# so after running this against them, remove what it left there.
#
# Usage: release_scripts.sh
# Takes a few minutes (three Release builds). Leaves nothing in the repository.

set -u
REPO=${0:A:h}/..
WORK=$(mktemp -d)
COPY=$WORK/repo
STUBS=$WORK/stubs
CALLS=$WORK/calls.log
FAILED=0
trap 'print "work folder: $WORK"' EXIT

mkdir -p $COPY $STUBS
# Tracked files plus new ones not yet added, so a fix in progress is all there.
(cd $REPO && { git ls-files -z; git ls-files -z --others --exclude-standard; } | xargs -0 tar -cf - ) | tar -xf - -C $COPY

for tool in codesign spctl; do
    print '#!/bin/zsh\nprint "'$tool' $*" >> '$CALLS'\nexit 0' > $STUBS/$tool
done
cat > $STUBS/xcrun <<EOF
#!/bin/zsh
# Only notarytool and stapler are faked; anything the build asks xcrun for
# goes to the real one.
[[ \$1 == notarytool || \$1 == stapler ]] || exec /usr/bin/xcrun "\$@"
print "xcrun \$*" >> $CALLS
# "stapler validate" answers what STAPLE_VALID says (0 = stapled), "stapler
# staple" fails when STAPLE_FAIL is set, and "notarytool" when NOTARY_FAIL is.
[[ \$1 == stapler && \$2 == validate ]] && exit \${STAPLE_VALID:-0}
[[ \$1 == stapler && \$2 == staple && -n \${STAPLE_FAIL:-} ]] && exit 1
[[ \$1 == notarytool && -n \${NOTARY_FAIL:-} ]] && exit 1
exit 0
EOF
cat > $STUBS/pkgutil <<EOF
#!/bin/zsh
# The packages here are unsigned, so --check-signature is answered yes; the
# rest (--expand) is the real pkgutil.
[[ \$1 == --check-signature ]] && { print "pkgutil \$*" >> $CALLS; exit 0; }
exec /usr/sbin/pkgutil "\$@"
EOF
cat > $STUBS/pkgbuild <<EOF
#!/bin/zsh
print "pkgbuild \$*" >> $CALLS
args=()
while (( \$# )); do
    if [[ \$1 == --sign ]]; then shift 2; else args+=("\$1"); shift; fi
done
exec /usr/bin/pkgbuild "\${args[@]}"
EOF
chmod +x $STUBS/*
# The scripts' work folders go in here too, so a real release in progress in
# the default place is left alone.
export PATH=$STUBS:$PATH SIGNER="Test (TEST)" LUFSBAR_RELEASE_DIR=$WORK/release

# The version the project builds, which is what the scripts must package, read
# the way the scripts read it.
project_version() {
    bash -c 'source "$1/release_settings.sh" >/dev/null && printf %s "$VERSION"' _ $1
}
VERSION=$(project_version $COPY)
PKG=$COPY/dist/LUFSBar_$VERSION.pkg
result() { print "$1  $2"; [[ $1 == FAIL ]] && FAILED=1; }
# Packages from an earlier run. A run that stops must remove the version-less
# one (it is what gets uploaded) and keep the archived one of this version.
stale_packages() { mkdir -p $COPY/dist; print old > $PKG; print old > $COPY/dist/LUFSBar.pkg; }
refused_cleanly() { [[ ! -e $COPY/dist/LUFSBar.pkg && $(cat $PKG 2>/dev/null) == old ]]; }

# 1. A good run.
: > $CALLS
bash $COPY/notarize.sh > $WORK/notarize-good.log 2>&1
GOOD=$?
APP=$(sed -n 's/^  Signed app: //p' $WORK/notarize-good.log)
if (( GOOD == 0 )) && [[ -d $APP ]] && \
   [[ $(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist") == $VERSION ]]; then
    result PASS "1 notarize.sh went through and left version $VERSION at $APP"
else
    result FAIL "1 notarize.sh (exit $GOOD) did not leave version $VERSION: see $WORK/notarize-good.log"
fi

# 5. The package from that app must pin it to /Applications.
bash $COPY/make_pkg.sh > $WORK/make_pkg-good.log 2>&1
if [[ -f $PKG ]] && pkgutil --expand $PKG $WORK/expanded >/dev/null 2>&1; then
    if grep -q "<relocate/>" $WORK/expanded/PackageInfo; then
        result PASS "5 the package does not relocate the app"
    else
        result FAIL "5 the package lets Installer relocate the app: $(grep -A1 '<relocate' $WORK/expanded/PackageInfo | tr -d '\n' | tr -s ' ')"
    fi
else
    result FAIL "5 make_pkg.sh made no package: see $WORK/make_pkg-good.log"
fi

# 9. The same good app, but Apple turns the package down.
stale_packages
: > $CALLS
NOTARY_FAIL=1 bash $COPY/make_pkg.sh > $WORK/make_pkg-rejected.log 2>&1
STATUS=$?
if ! grep -q "^xcrun notarytool submit" $CALLS; then
    result FAIL "9 make_pkg.sh (exit $STATUS) stopped before notarization: see $WORK/make_pkg-rejected.log"
elif (( STATUS != 0 )) && refused_cleanly; then
    result PASS "9 a package that failed notarization was not left in dist/, and the archive was kept"
else
    result FAIL "9 make_pkg.sh (exit $STATUS) after notarization failed: dist/ holds $(ls $COPY/dist 2>/dev/null | tr '\n' ' ')(want the old archive only)"
fi

# 10. Notarized, but the staple fails: the package Apple accepted is kept where
# it can be stapled by hand, and dist/ is left as a stopped run leaves it.
stale_packages
: > $CALLS
STAPLE_FAIL=1 bash $COPY/make_pkg.sh > $WORK/make_pkg-nostaple.log 2>&1
STATUS=$?
KEPT=$LUFSBAR_RELEASE_DIR/LUFSBar-release/pkg/LUFSBar_$VERSION.pkg
if (( STATUS != 0 )) && [[ -f $KEPT ]] && refused_cleanly && grep -q "stapler staple" $WORK/make_pkg-nostaple.log; then
    result PASS "10 a notarized package that could not be stapled was kept in the work folder"
else
    result FAIL "10 make_pkg.sh (exit $STATUS) after the staple failed: kept: $([[ -f $KEPT ]] && print yes || print no), dist/ holds $(ls $COPY/dist 2>/dev/null | tr '\n' ' ')"
fi

# 8. No signing identity at all: no SIGNER, and no signer file under HOME.
stale_packages
mkdir -p $WORK/nohome
env -u SIGNER HOME=$WORK/nohome bash $COPY/make_pkg.sh > $WORK/make_pkg-nosigner.log 2>&1
STATUS=$?
if (( STATUS != 0 )) && refused_cleanly; then
    result PASS "8 without a signing identity make_pkg.sh stopped, removed LUFSBar.pkg and kept the archive"
else
    result FAIL "8 without a signing identity: make_pkg.sh exit $STATUS, got the packages wrong (LUFSBar.pkg left, or the archive removed)"
fi

# 6. No work folder at a fixed name in the shared /tmp: no line that is not a
# comment names /tmp, in any of the scripts (build_script.sh 3 asks the same of
# build.sh).
FIXED=$(grep -Hn '/tmp' $COPY/notarize.sh $COPY/make_pkg.sh $COPY/release_settings.sh | grep -v '^[^:]*:[0-9]*:[[:space:]]*#')
if [[ -n $FIXED ]]; then
    result FAIL "6 fixed paths in the shared /tmp: $(print -r -- $FIXED | tr '\n' ' ')"
else
    result PASS "6 the work folders are private to the account"
fi

# 4. An app that is not stapled.
stale_packages
STAPLE_VALID=1 bash $COPY/make_pkg.sh > $WORK/make_pkg-unstapled.log 2>&1
STATUS=$?
if (( STATUS != 0 )) && refused_cleanly; then
    result PASS "4 make_pkg.sh refused an app that is not stapled"
else
    result FAIL "4 make_pkg.sh (exit $STATUS) wrapped an app that is not stapled, or got the packages wrong (LUFSBar.pkg left, or the archive removed)"
fi

# 2 and 3. Mark the app from the good run as an older version, break the
# source, and run both again.
[[ -d $APP ]] && /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString 1.0" "$APP/Contents/Info.plist"
stale_packages
bash $COPY/make_pkg.sh > $WORK/make_pkg-version.log 2>&1
STATUS=$?
if (( STATUS != 0 )) && refused_cleanly; then
    result PASS "3a make_pkg.sh refused an app of another version"
else
    result FAIL "3a make_pkg.sh (exit $STATUS) wrapped version 1.0 as $VERSION, or got the packages wrong (LUFSBar.pkg left, or the archive removed)"
fi
print "this does not compile" >> $COPY/LUFSBar/LUFSBarApp.swift
: > $CALLS
bash $COPY/notarize.sh > $WORK/notarize-broken.log 2>&1
STATUS=$?
if (( STATUS != 0 )) && ! grep -q "^codesign --force" $CALLS; then
    result PASS "2 a failed build stopped notarize.sh before signing"
else
    result FAIL "2 notarize.sh (exit $STATUS) went on after the build failed: $(grep -c '^codesign' $CALLS) codesign calls"
fi
stale_packages
bash $COPY/make_pkg.sh > $WORK/make_pkg-stale.log 2>&1
STATUS=$?
if (( STATUS != 0 )) && refused_cleanly; then
    result PASS "3 make_pkg.sh refused what the failed run left behind"
else
    result FAIL "3 make_pkg.sh (exit $STATUS) wrapped the app from an earlier run, or got the packages wrong (LUFSBar.pkg left, or the archive removed)"
fi

# 7. A second copy with nothing changed but MARKETING_VERSION.
COPY7=$WORK/repo7
mkdir -p $COPY7
(cd $REPO && { git ls-files -z; git ls-files -z --others --exclude-standard; } | xargs -0 tar -cf - ) | tar -xf - -C $COPY7
sed -i '' 's/MARKETING_VERSION = [^;]*;/MARKETING_VERSION = 9.9.9;/' $COPY7/LUFSBar.xcodeproj/project.pbxproj
LUFSBAR_RELEASE_DIR=$WORK/release7 bash $COPY7/notarize.sh > $WORK/notarize-999.log 2>&1
N_STATUS=$?
LUFSBAR_RELEASE_DIR=$WORK/release7 bash $COPY7/make_pkg.sh > $WORK/make_pkg-999.log 2>&1
PKG7=$COPY7/dist/LUFSBar_9.9.9.pkg
if [[ -f $PKG7 ]] && pkgutil --expand $PKG7 $WORK/expanded7 >/dev/null 2>&1 \
   && grep -q 'version="9.9.9"' $WORK/expanded7/PackageInfo; then
    result PASS "7 with only MARKETING_VERSION set to 9.9.9, the scripts made LUFSBar_9.9.9.pkg"
else
    result FAIL "7 with only MARKETING_VERSION set to 9.9.9: notarize.sh exit $N_STATUS, no 9.9.9 package (see $WORK/notarize-999.log)"
fi

exit $FAILED
