#!/bin/bash
# ============================================================
#  LUFSBar build.sh
#  Building under ~/Documents (which is synced by iCloud Drive) attaches File
#  Provider attributes to the build output, and codesign then fails with a
#  resource fork / Finder info error. Putting DerivedData in /tmp avoids it.
#  LUFSBAR_BUILD_DIR overrides where it goes.
# ============================================================
set -e

ROOT="$(cd "$(dirname "$0")" && pwd)"
DERIVED_DATA="${LUFSBAR_BUILD_DIR:-/tmp/LUFSBar-build}"
APP_NAME="LUFSBar"
LOG="$DERIVED_DATA/build.log"

echo "=========================================="
echo "  LUFSBar Build Script"
echo "=========================================="

build() {
    xcodebuild -project "$ROOT/LUFSBar.xcodeproj" -scheme "$APP_NAME" \
        -configuration Debug -derivedDataPath "$DERIVED_DATA" "$@" build > "$LOG" 2>&1
    local status=$?
    # Warnings and errors only; the rest stays in the log.
    grep -E "(warning|error): " "$LOG" | grep -v "^ld: warning" | sort -u || true
    return $status
}
ADHOC=(CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=)

# Whether this Mac has a development identity (certificate and private key)
# for the project's team: the certificate's OU is the team.
has_team_identity() {
    local team hash
    team="$(sed -n 's/^[[:space:]]*DEVELOPMENT_TEAM = \(.*\);$/\1/p' "$ROOT/LUFSBar.xcodeproj/project.pbxproj" | sort -u | head -1)"
    [ -n "$team" ] || return 1
    for hash in $(security find-identity -v -p codesigning 2>/dev/null | awk '/Apple Development|Mac Developer/ { print $2 }'); do
        security find-certificate -a -Z -p 2>/dev/null \
            | awk -v h="$hash" '/^SHA-1 hash:/ { keep = ($3 == h) } keep' \
            | openssl x509 -noout -subject 2>/dev/null | grep -q "OU *= *$team" && return 0
    done
    return 1
}

# The project signs with the author's team. Anyone else building it from the
# README has no certificate for that team, and the build would stop at
# signing, so it is signed ad hoc instead, which is enough to run it on the
# Mac that built it.
mkdir -p "$DERIVED_DATA"
if ! has_team_identity; then
    echo "No development certificate for the project's team here; signing ad hoc."
    build "${ADHOC[@]}" || { echo "Build failed. Full log: $LOG"; exit 1; }
elif ! build; then
    # A certificate that is there but cannot be used (expired, revoked) ends
    # the same way, so the same way out.
    if grep -q "signing certificate\|No Account for Team\|requires a development team" "$LOG"; then
        echo "The team's certificate could not be used; building again, signed ad hoc."
        build "${ADHOC[@]}" || { echo "Build failed. Full log: $LOG"; exit 1; }
    else
        echo "Build failed. Full log: $LOG"
        exit 1
    fi
fi

APP_PATH="$DERIVED_DATA/Build/Products/Debug/$APP_NAME.app"

echo ""
echo "=========================================="
echo "  Build complete!"
echo "  App: $APP_PATH"
echo "=========================================="
