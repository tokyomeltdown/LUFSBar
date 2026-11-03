#!/bin/zsh
# Checks that build.sh, as the README tells people to run it, works on a Mac
# without the author's signing certificate, and still signs with the team's
# certificate on a Mac that has it.
#
#   1  on a scratch copy whose DEVELOPMENT_TEAM is a team this Mac has no
#      certificate for (standing in for anyone else's Mac), build.sh builds
#      the app, signed ad hoc                                          (B11)
#   2  on an unchanged copy, build.sh signs with the team's certificate
#   3  build.sh does not build into a fixed name in the shared /tmp, where
#      another account could have put a folder or a link first        (S1)
#   4  the app carries libebur128's licence (COPYING) and that of the queue.h
#      it builds with (COPYING-queue.h), which their terms require     (P-01)
#
# Usage: build_script.sh
# Two Debug builds into a work folder; leaves nothing in the repository.

set -u
REPO=${0:A:h}/..
WORK=$(mktemp -d)
FAILED=0
result() { print "$1  $2"; [[ $1 == FAIL ]] && FAILED=1; }
trap 'print "work folder: $WORK"' EXIT

copy() {
    mkdir -p $1
    (cd $REPO && { git ls-files -z; git ls-files -z --others --exclude-standard; } | xargs -0 tar -cf - ) | tar -xf - -C $1
}
# "adhoc", the team identifier, or "none" when there is no app.
signature() {
    [[ -d $1 ]] || { print none; return }
    local info=$(codesign -dv $1 2>&1)
    if [[ $info == *"Signature=adhoc"* ]]; then print adhoc
    else print -r -- $info | sed -n 's/^TeamIdentifier=//p'
    fi
}

copy $WORK/other
sed -i '' 's/DEVELOPMENT_TEAM = [^;]*;/DEVELOPMENT_TEAM = ZZZZZZZZZZ;/' $WORK/other/LUFSBar.xcodeproj/project.pbxproj
LUFSBAR_BUILD_DIR=$WORK/dd-other bash $WORK/other/build.sh > $WORK/other.log 2>&1
STATUS=$?
SIG=$(signature $WORK/dd-other/Build/Products/Debug/LUFSBar.app)
if (( STATUS == 0 )) && [[ $SIG == adhoc ]]; then
    result PASS "1 without the team's certificate, build.sh built the app and signed it ad hoc"
else
    result FAIL "1 without the team's certificate: build.sh exit $STATUS, app signature: $SIG (see $WORK/other.log)"
fi

copy $WORK/own
TEAM=$(sed -n 's/^[[:space:]]*DEVELOPMENT_TEAM = \(.*\);$/\1/p' $WORK/own/LUFSBar.xcodeproj/project.pbxproj | sort -u)
LUFSBAR_BUILD_DIR=$WORK/dd-own bash $WORK/own/build.sh > $WORK/own.log 2>&1
STATUS=$?
SIG=$(signature $WORK/dd-own/Build/Products/Debug/LUFSBar.app)
if (( STATUS == 0 )) && [[ $SIG == $TEAM ]]; then
    result PASS "2 with the team's certificate, build.sh signed with it"
else
    result FAIL "2 with the team's certificate: build.sh exit $STATUS, app signature: $SIG (see $WORK/own.log)"
fi

# Any line that is not a comment naming /tmp (release_scripts.sh 6 asks the same
# of the release scripts).
FIXED=$(grep -n '/tmp' $REPO/build.sh | grep -v '^[0-9]*:[[:space:]]*#')
if [[ -n $FIXED ]]; then
    result FAIL "3 build.sh builds into a fixed path in the shared /tmp: $FIXED"
else
    result PASS "3 build.sh builds into a folder private to the account"
fi

APP2=$WORK/dd-own/Build/Products/Debug/LUFSBar.app
if [[ -f $APP2/Contents/Resources/COPYING ]] && grep -q "Permission is hereby granted" $APP2/Contents/Resources/COPYING \
    && grep -q "The Regents of the University of California" $APP2/Contents/Resources/COPYING-queue.h 2>/dev/null; then
    result PASS "4 the app carries the licences of libebur128 and its queue.h"
else
    result FAIL "4 the app does not carry the licences (Contents/Resources/COPYING, COPYING-queue.h)"
fi

exit $FAILED
