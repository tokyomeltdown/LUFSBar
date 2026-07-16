#!/bin/bash
# ============================================================
#  LUFSBar  make_pkg.sh
#  notarize.sh で署名・公証済みの.appから.pkgインストーラーを作成し、
#  .pkg自体も公証してstapleする。
#  ※ 先に notarize.sh を実行しておくこと
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

echo "=========================================="
echo "  LUFSBar  make_pkg.sh  (v${VERSION})"
echo "=========================================="

if [ ! -d "$APP_TMP" ]; then
    echo "ERROR: 署名・公証済みアプリが見つかりません: $APP_TMP"
    echo "先に bash notarize.sh を実行してください。"
    exit 1
fi

rm -rf "$WORK"
mkdir -p "$WORK/root/Applications" "$WORK/scripts" "$DIST_DIR"
ditto --norsrc --noextattr --noqtn --noacl "$APP_TMP" "$WORK/root/Applications/$APP_NAME.app"

# ---- postinstall: インストール完了直後にLUFSBarを自動起動する ----
#   pkgのpostinstallはroot権限で走るため、そのままopenするとrootとして起動して
#   しまいログイン中ユーザーのメニューバーに出ない。launchctl asuserで
#   ログイン中のコンソールユーザーのセッションに入ってから起動する。
#   アップデートインストール時は先に旧プロセスを終了しておく
#   (生き残っていると新プロセス起動時の二重起動防止で新プロセスの方が
#   即終了してしまい、アップデート後にアプリが起動しないままになる)。
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

# ---- Step 1: pkgbuild（/Applicationsへインストール）+ Developer ID Installer署名 ----
echo "[1/4] pkgbuild + sign ..."
pkgbuild \
    --root "$WORK/root" \
    --scripts "$WORK/scripts" \
    --install-location "/" \
    --identifier "$BUNDLE_ID" \
    --version "$VERSION" \
    --sign "$SIGN_INST" \
    "$PKG_SIGNED"

# ---- Step 2: pkgを公証 ----
echo "[2/4] notarize pkg (submit & wait) ..."
xcrun notarytool submit "$PKG_SIGNED" \
    --keychain-profile "$NOTARY_PROFILE" --wait

# ---- Step 3: staple ----
echo "[3/4] staple ..."
xcrun stapler staple "$PKG_SIGNED"
xcrun stapler validate "$PKG_SIGNED"

# ---- Step 4: 検証 ----
echo "[4/4] verify ..."
spctl -a -vvv -t install "$PKG_SIGNED" || true
pkgutil --check-signature "$PKG_SIGNED"

echo ""
echo "=========================================="
echo "  .pkg 完成！"
echo "  $PKG_SIGNED"
echo "=========================================="
