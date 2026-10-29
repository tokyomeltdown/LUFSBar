# ============================================================
#  LUFSBar  release_settings.sh
#  Sourced by notarize.sh and make_pkg.sh: the settings both need, written
#  down once. The version is read from the Xcode project, so
#  MARKETING_VERSION is the only place it is set.
# ============================================================

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="LUFSBar"
BUNDLE_ID="com.tokyomeltdown.lufsbar"
NOTARY_PROFILE="VOXNotary"

# Debug and Release each carry MARKETING_VERSION; they have to agree.
# Xcode puts the value in quotes when it holds characters such as '-'.
VERSION="$(sed -n 's/^[[:space:]]*MARKETING_VERSION = "\{0,1\}\([^";]*\)"\{0,1\};$/\1/p' \
    "$ROOT/LUFSBar.xcodeproj/project.pbxproj" | sort -u)"
if [ -z "$VERSION" ] || [ "$(printf '%s\n' "$VERSION" | wc -l | tr -d ' ')" != 1 ]; then
    echo "ERROR: the project does not have one MARKETING_VERSION:" $VERSION
    exit 1
fi

# Work folders live in the per-user temporary folder (private to this account)
# rather than at fixed names in the shared /tmp, where another account could
# have put a folder or a link first. Either way they are outside the synced
# project folder, which is what codesign needs. Asked of getconf rather than
# taken from $TMPDIR, so that both scripts agree even when they are started
# from different shells. LUFSBAR_RELEASE_DIR overrides it.
RELEASE_DIR="${LUFSBAR_RELEASE_DIR:-$(getconf DARWIN_USER_TEMP_DIR)}"
RELEASE_DIR="${RELEASE_DIR%/}/LUFSBar-release"

# The signing identity names the Apple account and the team it belongs to.
# Every signed copy carries it, so it is not much of a secret, but AGENTS.md
# section 3 keeps values of that kind out of the source. It is read from the
# environment, or from one line in a file outside the tree. A function, so
# that notarize.sh can clear the last run's app before it can stop here.
load_signer() {
    local signer_file="$HOME/.config/tokyomeltdown/signer"
    if [ -z "${SIGNER:-}" ] && [ -f "$signer_file" ]; then
        SIGNER="$(head -1 "$signer_file")"
    fi
    if [ -z "${SIGNER:-}" ]; then
        echo "ERROR: no signing identity."
        echo "Put the account name and team on one line in $signer_file"
        exit 1
    fi
}

# Sends a file to Apple's notary service and waits for the answer, printing the
# report as it comes. Succeeds only when the report says Accepted: notarytool's
# exit status says the request went through, which on its own was taken for
# Apple's yes, and a package Apple turned down was then treated as one that
# only needed stapling.
notarize_and_wait() {
    mkdir -p "$RELEASE_DIR"
    local report="$RELEASE_DIR/notary-report.txt"
    xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1 | tee "$report"
    [ "${PIPESTATUS[0]}" = 0 ] && grep -q "status: Accepted" "$report"
}
