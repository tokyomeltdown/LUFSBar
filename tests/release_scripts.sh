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
# "stapler validate" answers what STAPLE_VALID says (0 = stapled).
[[ \$1 == stapler && \$2 == validate ]] && exit \${STAPLE_VALID:-0}
exit 0
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

# The version the project builds, which is what the scripts must package.
project_version() {
    sed -n 's/^[[:space:]]*MARKETING_VERSION = \(.*\);$/\1/p' $1/LUFSBar.xcodeproj/project.pbxproj | sort -u
}
VERSION=$(project_version $COPY)
PKG=$COPY/dist/LUFSBar_$VERSION.pkg
result() { print "$1  $2"; [[ $1 == FAIL ]] && FAILED=1; }
# Packages from an earlier run, which a refused run must not leave behind: the
# version-less one is what gets uploaded.
stale_packages() { mkdir -p $COPY/dist; print old > $PKG; print old > $COPY/dist/LUFSBar.pkg; }
no_packages() { [[ ! -e $PKG && ! -e $COPY/dist/LUFSBar.pkg ]]; }

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

# 6. No work folder at a fixed name in the shared /tmp.
FIXED=$(grep -n '"/tmp/' $COPY/notarize.sh $COPY/make_pkg.sh)
if [[ -n $FIXED ]]; then
    result FAIL "6 fixed paths in the shared /tmp: $(print -r -- $FIXED | tr '\n' ' ')"
else
    result PASS "6 the work folders are private to the account"
fi

# 4. An app that is not stapled.
stale_packages
STAPLE_VALID=1 bash $COPY/make_pkg.sh > $WORK/make_pkg-unstapled.log 2>&1
STATUS=$?
if (( STATUS != 0 )) && no_packages; then
    result PASS "4 make_pkg.sh refused an app that is not stapled"
else
    result FAIL "4 make_pkg.sh (exit $STATUS) wrapped an app that is not stapled, or left an old package"
fi

# 2 and 3. Mark the app from the good run as an older version, break the
# source, and run both again.
[[ -d $APP ]] && /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString 1.0" "$APP/Contents/Info.plist"
stale_packages
bash $COPY/make_pkg.sh > $WORK/make_pkg-version.log 2>&1
STATUS=$?
if (( STATUS != 0 )) && no_packages; then
    result PASS "3a make_pkg.sh refused an app of another version"
else
    result FAIL "3a make_pkg.sh (exit $STATUS) wrapped version 1.0 as $VERSION, or left an old package"
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
if (( STATUS != 0 )) && no_packages; then
    result PASS "3 make_pkg.sh refused what the failed run left behind"
else
    result FAIL "3 make_pkg.sh (exit $STATUS) wrapped the app from an earlier run, or left an old package"
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
