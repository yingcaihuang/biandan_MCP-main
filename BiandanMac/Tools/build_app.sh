#!/bin/bash
# 编译并打包 Biandan.app，用固定的 Developer ID 证书签名。
# 用法（在 BiandanMac 目录）：Tools/build_app.sh
# 可选环境变量：
#   BIANDAN_SIGN_IDENTITY  证书 SHA-1 或名称（默认 Wuxi Chaorong Developer ID Application）
#   CONFIG                 release（默认）或 debug
#   VERSION / BUILD_NUMBER 版本号 / 构建号
#   TIMESTAMP=0            离线时跳过 Apple 时间戳服务器
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IDENTITY="${BIANDAN_SIGN_IDENTITY:-963EFDD532CD44170CF91398025F08D5DB4ADA2F}"
CONFIG="${CONFIG:-release}"
VERSION="${VERSION:-0.6.1}"
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"
BUNDLE_ID="ai.racore.BiandanMac"
DIST="$ROOT/dist"
APP="$DIST/Biandan.app"
ENTITLEMENTS="$ROOT/Tools/BiandanMac.entitlements"

cd "$ROOT"

if ! security find-identity -v -p codesigning | grep -q "$IDENTITY"; then
    echo "找不到签名证书：$IDENTITY" >&2
    exit 1
fi

echo "==> 编译（${CONFIG}）"
swift build -c "$CONFIG"
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
BINARY="$BIN_DIR/BiandanMac"
if [ ! -x "$BINARY" ]; then
    echo "找不到编译产物：$BINARY" >&2
    exit 1
fi

echo "==> 组装 $APP"
rm -rf "${APP:?}"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> 生成 App 图标"
# 由官方授权的 Assets/biandan.png（512×512）生成 AppIcon.icns。
ICON_SRC="$ROOT/Assets/biandan.png"
ICON_TMP="$(mktemp -d)"
ICONSET="$ICON_TMP/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$ICON_SRC" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    if [ "$double" -le 512 ]; then
        sips -z "$double" "$double" "$ICON_SRC" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
    fi
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "${ICON_TMP:?}"
cp "$BINARY" "$APP/Contents/MacOS/BiandanMac"
# 依赖包的资源包（例如 GRDB 的隐私清单）一并放入。
find "$BIN_DIR" -maxdepth 1 -name '*.bundle' -type d -exec cp -R {} "$APP/Contents/Resources/" \;

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>BiandanMac</string>
    <key>CFBundleName</key><string>便单</string>
    <key>CFBundleDisplayName</key><string>便单</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
    <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHumanReadableCopyright</key><string>© Wuxi Chaorong Technology Co., Ltd.</string>
</dict>
</plist>
PLIST
printf 'APPL????' > "$APP/Contents/PkgInfo"

# 签名前自检：codesign 能否使用证书私钥。
# 失败（errSecInternalComponent）通常是登录钥匙串被锁，或私钥访问需要弹窗确认而当前终端无法弹窗。
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
probe_sign() {
    local dir
    dir="$(mktemp -d)"
    cp /bin/echo "$dir/probe"
    codesign --force --sign "$IDENTITY" --timestamp=none "$dir/probe" >/dev/null 2>&1
    local status=$?
    rm -rf "${dir:?}"
    return $status
}

echo "==> 检查签名证书私钥"
if ! probe_sign; then
    echo "    codesign 无法使用私钥，尝试解锁登录钥匙串（请输入 Mac 登录密码）"
    security unlock-keychain "$KEYCHAIN" || true
    if ! probe_sign; then
        cat >&2 <<'HELP'

签名失败：codesign 仍然无法使用 Developer ID 证书的私钥（errSecInternalComponent）。
请任选一种方式处理后重新运行 Tools/build_app.sh：

  1. 在系统自带的「终端.app」里运行脚本（不要在 IDE 内置终端或 SSH 里运行）。
     弹出「codesign 想要使用钥匙串中的密钥」时，输入登录密码，点「始终允许」。

  2. 打开「钥匙串访问」→ 登录 → 我的证书，展开
     「Developer ID Application: Wuxi Chaorong Technology Co., Ltd.」下面的私钥，
     双击 → 访问控制 → 把 /usr/bin/codesign 加入「始终允许这些应用程序访问」→ 存储更改。

  3. 命令行一次性授权（会作用于登录钥匙串里的所有私钥）：
     security set-key-partition-list -S apple-tool:,apple:,codesign: -s ~/Library/Keychains/login.keychain-db
     （按提示输入 Mac 登录密码）
HELP
        exit 1
    fi
fi

echo "==> 签名"
TS_FLAG="--timestamp"
[ "${TIMESTAMP:-1}" = "0" ] && TS_FLAG="--timestamp=none"
codesign --force --options runtime $TS_FLAG \
    --entitlements "$ENTITLEMENTS" \
    --identifier "$BUNDLE_ID" \
    --sign "$IDENTITY" "$APP"

echo "==> 校验"
codesign --verify --strict --verbose=2 "$APP"
codesign -dvv "$APP" 2>&1 | grep -E '^(Identifier|Authority|TeamIdentifier|Timestamp|Runtime Version|CodeDirectory)' || true
echo "--- 指定要求（Designated Requirement）"
codesign -d -r- "$APP" 2>&1 | sed -n 's/^designated => /  /p'
echo "--- Gatekeeper（未公证时显示 Unnotarized 属正常）"
spctl --assess --type execute -vv "$APP" 2>&1 || true

echo ""
echo "完成：$APP  （版本 $VERSION / 构建 ${BUILD_NUMBER}）"
