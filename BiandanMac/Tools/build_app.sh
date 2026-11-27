#!/bin/bash
# 编译并打包 Biandan.app，用固定的 Developer ID 证书签名。
# 用法（在 BiandanMac 目录）：Tools/build_app.sh
# 可选环境变量：
#   BIANDAN_SIGN_IDENTITY  证书 SHA-1 或名称（默认 Wuxi Chaorong Developer ID Application）
#   CONFIG                 release（默认）或 debug
#   VERSION / BUILD_NUMBER 版本号 / 构建号（HEAD 在 vX.Y.Z tag 上时版本号取 tag，不能另指定）
#   TIMESTAMP=0            离线时跳过 Apple 时间戳服务器
#   NOTARIZE=1             签名后提交 Apple 公证并钉入票据（见 Tools/notarize.sh）
#   FEED_URL / SPARKLE_PUBLIC_KEY  自动更新的 appcast 地址和 EdDSA 公钥（开发版不写入）
#   以下供 Tools/dev_run.sh 使用（组装开发版），正式打包不用设置：
#   BUNDLE_ID / DISPLAY_NAME / DIST / APP_FILE / ENTITLEMENTS  标识符、显示名、输出目录、.app 文件名、权限文件
#   HARDENED=0             不启用 Hardened Runtime（方便调试器附加）
#   WIDGET=0               不编译桌面小组件扩展（需要 xcodegen：brew install xcodegen）
#   APP_GROUP / URL_SCHEME  小组件共享数据的 App Group 和链接 scheme（默认按标识符：正式版 biandan，开发版 biandan-dev）
#   PACKAGE=0              不打 zip
# 产物：dist/Biandan.app（含 Contents/PlugIns/BiandanWidget.appex 小组件、Contents/Resources/Metadata.appintents 快捷指令），
#       以及带版本号的 dist/Biandan-<版本>.zip 和 .zip.sha256。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IDENTITY="${BIANDAN_SIGN_IDENTITY:-963EFDD532CD44170CF91398025F08D5DB4ADA2F}"
CONFIG="${CONFIG:-release}"
# 不在 tag 上构建时的默认版本号。
DEFAULT_VERSION="1.4.11"
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"
BUNDLE_ID="${BUNDLE_ID:-ai.racore.BiandanMac}"
DISPLAY_NAME="${DISPLAY_NAME:-便单}"
DIST="${DIST:-$ROOT/dist}"
APP="$DIST/${APP_FILE:-Biandan}.app"
ENTITLEMENTS="${ENTITLEMENTS:-$ROOT/Tools/BiandanMac.entitlements}"
# 自动更新（Sparkle）：appcast 地址和 EdDSA 公钥。私钥在钥匙串里（账户 ai.racore.BiandanMac），见 Tools/make_update.sh。
FEED_URL="${FEED_URL:-https://www.aigslb.link/biandan/mac/update/appcast.xml}"
SPARKLE_PUBLIC_KEY="${SPARKLE_PUBLIC_KEY:-70HMm/3664xGGXs5TucPsxcsYO8kOGF5ngpoHcRvU9k=}"
# 小组件和主程序共享数据的 App Group（Developer ID 分发用 Team ID 前缀，不需要描述文件），以及小组件点开便单的链接 scheme。
TEAM_ID="G48CJ2J7C8"
APP_GROUP="${APP_GROUP:-$TEAM_ID.$BUNDLE_ID}"
if [ -z "${URL_SCHEME:-}" ]; then
    URL_SCHEME="biandan"
    [[ "$BUNDLE_ID" == *.dev ]] && URL_SCHEME="biandan-dev"
fi
WIDGET_ID="$BUNDLE_ID.widget"

cd "$ROOT"

# 版本号和产物文件名与 git tag 对齐：
# - HEAD 正好在 vX.Y.Z tag 上且没有未提交改动：版本号取 X.Y.Z，产物叫 Biandan-X.Y.Z.zip，与 Release 附件同名；
#   这时用 VERSION 指定了别的版本号会直接报错，避免打出版本号和 tag 对不上的包。
# - 其他情况：文件名带提交号（有未提交改动再加 .dirty），例如 Biandan-0.6.1-dev.abc1234.zip，不会覆盖正式版的包。
EXACT_TAG="$(git describe --tags --exact-match --match 'v[0-9]*.[0-9]*.[0-9]*' HEAD 2>/dev/null || true)"
DIRTY=""
git diff --quiet HEAD -- . 2>/dev/null || DIRTY=1
[ -z "$(git ls-files --others --exclude-standard -- . 2>/dev/null)" ] || DIRTY=1
if [ -n "$EXACT_TAG" ] && [ -z "$DIRTY" ]; then
    TAG_VERSION="${EXACT_TAG#v}"
    if [ -n "${VERSION:-}" ] && [ "$VERSION" != "$TAG_VERSION" ]; then
        echo "版本号和 tag 不一致：VERSION=${VERSION}，HEAD 的 tag 是 ${EXACT_TAG}" >&2
        exit 1
    fi
    VERSION="$TAG_VERSION"
    ARTIFACT="Biandan-$VERSION"
else
    VERSION="${VERSION:-$DEFAULT_VERSION}"
    SHORT="$(git rev-parse --short HEAD 2>/dev/null || echo nogit)"
    ARTIFACT="Biandan-$VERSION-dev.$SHORT${DIRTY:+.dirty}"
fi
echo "==> 版本 ${VERSION}（tag：${EXACT_TAG:-无}），产物 ${ARTIFACT}.zip"

if ! security find-identity -v -p codesigning | grep -q "$IDENTITY"; then
    echo "找不到签名证书：$IDENTITY" >&2
    exit 1
fi

echo "==> 编译（${CONFIG}）"
# 同时输出常量元数据（.swiftconstvalues），后面生成快捷指令的 Metadata.appintents 要用。
PROTOCOLS="$ROOT/Tools/appintents-protocols.json"
CV_FLAGS=(-Xswiftc -emit-const-values -Xswiftc -Xfrontend -Xswiftc -const-gather-protocols-file
          -Xswiftc -Xfrontend -Xswiftc "$PROTOCOLS")
swift build -c "$CONFIG" "${CV_FLAGS[@]}"
BIN_DIR="$(swift build -c "$CONFIG" "${CV_FLAGS[@]}" --show-bin-path)"
BINARY="$BIN_DIR/BiandanMac"
if [ ! -x "$BINARY" ]; then
    echo "找不到编译产物：$BINARY" >&2
    exit 1
fi

echo "==> 组装 $APP"
rm -rf "${APP:?}"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> 生成 App 图标"
# 由 Assets/AppIcon-1024.png（官方原图 Assets/icon-source.png 经 Tools/make_icon.swift 合成）生成 AppIcon.icns。
ICON_SRC="$ROOT/Assets/AppIcon-1024.png"
ICON_TMP="$(mktemp -d)"
ICONSET="$ICON_TMP/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$ICON_SRC" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    if [ "$double" -le 1024 ]; then
        sips -z "$double" "$double" "$ICON_SRC" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
    fi
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "${ICON_TMP:?}"
cp "$BINARY" "$APP/Contents/MacOS/BiandanMac"
# 依赖包的资源包（例如 GRDB 的隐私清单）一并放入。
find "$BIN_DIR" -maxdepth 1 -name '*.bundle' -type d -exec cp -R {} "$APP/Contents/Resources/" \;
# 自动更新用的 Sparkle.framework 放进 Contents/Frameworks（可执行文件的 rpath 指向这里）；ditto 保留里面的符号链接。
if [ ! -d "$BIN_DIR/Sparkle.framework" ]; then
    echo "找不到 Sparkle.framework：$BIN_DIR" >&2
    exit 1
fi
mkdir -p "$APP/Contents/Frameworks"
ditto "$BIN_DIR/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"

echo "==> 生成快捷指令元数据（Metadata.appintents）"
# swift build 不会生成这份元数据，Xcode 是用 appintentsmetadataprocessor 生成的，这里照做。源文件必须用绝对路径。
CFG_DIR="$(echo "$CONFIG" | awk '{print toupper(substr($0,1,1)) substr($0,2)}')"
INTENTS_TMP="$(mktemp -d)"
find "$ROOT/Sources/BiandanMac" -name '*.swift' | sort > "$INTENTS_TMP/sources.txt"
# 只取主程序目标（BiandanMac-p.build）的：debug 每个源文件一个，release 整模块编译只有一个 *-primary。
# 测试目标（testable-t.build）的不要；删掉的源文件留下的旧文件也不要，否则元数据工具找不到源文件会报错。
while IFS= read -r cv; do
    name="$(basename "$cv" .swiftconstvalues)"
    if [[ "$name" == *-primary ]] || grep -q "/$name.swift\$" "$INTENTS_TMP/sources.txt"; then
        echo "$cv"
    fi
done < <(find "$ROOT/.build" -path "*/BiandanMac.build/$CFG_DIR/BiandanMac-p.build/*" -name '*.swiftconstvalues') \
    > "$INTENTS_TMP/constvals.txt"
if [ ! -s "$INTENTS_TMP/constvals.txt" ]; then
    echo "找不到编译器输出的常量元数据（.swiftconstvalues），无法生成快捷指令元数据" >&2
    exit 1
fi
XCODE_BUILD="$(xcodebuild -version | sed -n 's/^Build version //p')"
SDK_ROOT="$(xcrun --sdk macosx --show-sdk-path)"
TOOLCHAIN="$(dirname "$(dirname "$(dirname "$(xcrun --find swiftc)")")")"
ARCH="$(uname -m)"
xcrun appintentsmetadataprocessor --output "$APP/Contents/Resources" --toolchain-dir "$TOOLCHAIN" \
    --module-name BiandanMac --sdk-root "$SDK_ROOT" --xcode-version "$XCODE_BUILD" --platform-family macOS \
    --deployment-target 14.0 --target-triple "$ARCH-apple-macos14.0" \
    --source-file-list "$INTENTS_TMP/sources.txt" --swift-const-vals-list "$INTENTS_TMP/constvals.txt" \
    --quiet-warnings 2>&1 | grep -vE 'Starting App Intents|Extracting|Writing Metadata|Metadata root' || true
rm -rf "${INTENTS_TMP:?}"
ACTIONS="$APP/Contents/Resources/Metadata.appintents/extract.actionsdata"
if [ ! -f "$ACTIONS" ]; then
    echo "生成快捷指令元数据失败：没有 $ACTIONS" >&2
    exit 1
fi
echo "    快捷指令：$(python3 -c "import json,sys;d=json.load(open(sys.argv[1]));print(len(d.get('actions',{})),'个，快捷短语',len(d.get('autoShortcuts',[])),'条')" "$ACTIONS")"

WIDGET_APPEX=""
if [ "${WIDGET:-1}" != "0" ]; then
    echo "==> 编译桌面小组件（${WIDGET_ID}）"
    if ! command -v xcodegen >/dev/null 2>&1; then
        echo "编译小组件需要 xcodegen：brew install xcodegen（或用 WIDGET=0 跳过小组件）" >&2
        exit 1
    fi
    WIDGET_DD="$ROOT/.build/widget-$CONFIG"
    (cd "$ROOT/Widget" && xcodegen generate --quiet)
    WIDGET_LOG="$(mktemp)"
    if ! xcodebuild -project "$ROOT/Widget/BiandanWidget.xcodeproj" -scheme BiandanWidget \
        -configuration "$CFG_DIR" -derivedDataPath "$WIDGET_DD" -destination 'generic/platform=macOS' \
        PRODUCT_BUNDLE_IDENTIFIER="$WIDGET_ID" MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
        BIANDAN_APP_GROUP="$APP_GROUP" BIANDAN_URL_SCHEME="$URL_SCHEME" ARCHS="$ARCH" \
        ENABLE_DEBUG_DYLIB=NO ENABLE_PREVIEWS=NO \
        build >"$WIDGET_LOG" 2>&1; then
        grep -E 'error:' "$WIDGET_LOG" | head -20 >&2
        echo "小组件编译失败，完整日志：$WIDGET_LOG" >&2
        exit 1
    fi
    rm -f "$WIDGET_LOG"
    mkdir -p "$APP/Contents/PlugIns"
    ditto "$WIDGET_DD/Build/Products/$CFG_DIR/BiandanWidget.appex" "$APP/Contents/PlugIns/BiandanWidget.appex"
    WIDGET_APPEX="$APP/Contents/PlugIns/BiandanWidget.appex"
fi

# 开发版（标识符以 .dev 结尾）不写更新地址，App 里的自动更新也就不启用，免得被正式版覆盖。
UPDATE_KEYS=""
if [[ "$BUNDLE_ID" != *.dev ]] && [ -n "$FEED_URL" ]; then
    UPDATE_KEYS="    <key>SUFeedURL</key><string>$FEED_URL</string>
    <key>SUPublicEDKey</key><string>$SPARKLE_PUBLIC_KEY</string>
    <key>SUEnableAutomaticChecks</key><true/>
    <key>SUScheduledCheckInterval</key><integer>86400</integer>
    <key>SUAllowsAutomaticUpdates</key><true/>"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>BiandanMac</string>
    <key>CFBundleName</key><string>${DISPLAY_NAME}</string>
    <key>CFBundleDisplayName</key><string>${DISPLAY_NAME}</string>
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
    <key>NSCalendarsFullAccessUsageDescription</key><string>便单需要读取「互联网账户」里邮箱日历（Exchange、Google、QQ、163 等）的日程，导入为便单任务。只读取，不会修改你的日历。</string>
    <key>NSCalendarsUsageDescription</key><string>便单需要读取「互联网账户」里邮箱日历的日程，导入为便单任务。只读取，不会修改你的日历。</string>
    <key>NSServices</key>
    <array>
        <dict>
            <key>NSMenuItem</key><dict><key>default</key><string>用${DISPLAY_NAME}识别日程</string></dict>
            <key>NSMessage</key><string>captureSchedule</string>
            <key>NSPortName</key><string>${DISPLAY_NAME}</string>
            <key>NSSendTypes</key>
            <array>
                <string>public.utf8-plain-text</string>
                <string>public.plain-text</string>
                <string>public.png</string>
                <string>public.tiff</string>
            </array>
            <key>NSRequiredContext</key><dict/>
        </dict>
    </array>
    <key>BiandanAppGroup</key><string>$APP_GROUP</string>
    <key>BiandanURLScheme</key><string>$URL_SCHEME</string>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key><string>$BUNDLE_ID</string>
            <key>CFBundleURLSchemes</key><array><string>$URL_SCHEME</string></array>
        </dict>
    </array>
${UPDATE_KEYS}
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

签名失败：codesign 仍然无法使用所选签名证书的私钥（errSecInternalComponent）。
请任选一种方式处理后重新运行 Tools/build_app.sh：

  1. 在系统自带的「终端.app」里运行脚本（不要在 IDE 内置终端或 SSH 里运行）。
     弹出「codesign 想要使用钥匙串中的密钥」时，输入登录密码，点「始终允许」。

  2. 打开「钥匙串访问」→ 登录 → 我的证书，展开
     所选证书下面的私钥（正式版是「Developer ID Application: Wuxi Chaorong Technology Co., Ltd.」，
     开发版是 Tools/setup_signing.sh 里选的那张，可用 Tools/setup_signing.sh --show 查看），
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
RUNTIME_FLAG="--options runtime"
[ "${HARDENED:-1}" = "0" ] && RUNTIME_FLAG=""
# Sparkle.framework 里的可执行部件由内到外逐个签名，最后签整个 App。
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
for item in "$SPARKLE/Versions/B/XPCServices/Installer.xpc" \
            "$SPARKLE/Versions/B/XPCServices/Downloader.xpc" \
            "$SPARKLE/Versions/B/Autoupdate" \
            "$SPARKLE/Versions/B/Updater.app" \
            "$SPARKLE"; do
    [ -e "$item" ] || continue
    EXTRA=""
    [[ "$item" == *Downloader.xpc ]] && EXTRA="--preserve-metadata=entitlements"
    codesign --force $RUNTIME_FLAG $TS_FLAG $EXTRA --sign "$IDENTITY" "$item"
done
# 主程序和小组件的权限都加上同一个 App Group（主程序原有的权限文件不改，复制一份再加）。
SIGN_TMP="$(mktemp -d)"
APP_ENTITLEMENTS="$SIGN_TMP/app.entitlements"
cp "$ENTITLEMENTS" "$APP_ENTITLEMENTS"
/usr/libexec/PlistBuddy -c "Delete :com.apple.security.application-groups" "$APP_ENTITLEMENTS" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy -c "Add :com.apple.security.application-groups array" \
    -c "Add :com.apple.security.application-groups:0 string $APP_GROUP" "$APP_ENTITLEMENTS"
if [ -n "$WIDGET_APPEX" ]; then
    # 小组件扩展必须开沙盒；只读 App Group 里主程序写的 widget.json。
    WIDGET_ENTITLEMENTS="$SIGN_TMP/widget.entitlements"
    /usr/libexec/PlistBuddy -c "Add :com.apple.security.app-sandbox bool true" \
        -c "Add :com.apple.security.application-groups array" \
        -c "Add :com.apple.security.application-groups:0 string $APP_GROUP" "$WIDGET_ENTITLEMENTS" >/dev/null
    # 只有关掉 Hardened Runtime 的调试包（dev_run.sh）才允许调试器附加；要公证的包不能带 get-task-allow。
    [ "${HARDENED:-1}" = "0" ] && /usr/libexec/PlistBuddy -c "Add :com.apple.security.get-task-allow bool true" "$WIDGET_ENTITLEMENTS"
    codesign --force $RUNTIME_FLAG $TS_FLAG --entitlements "$WIDGET_ENTITLEMENTS" \
        --identifier "$WIDGET_ID" --sign "$IDENTITY" "$WIDGET_APPEX"
fi
codesign --force $RUNTIME_FLAG $TS_FLAG \
    --entitlements "$APP_ENTITLEMENTS" \
    --identifier "$BUNDLE_ID" \
    --sign "$IDENTITY" "$APP"
rm -rf "${SIGN_TMP:?}"
if [ "${NOTARIZE:-0}" = "1" ]; then
    "$ROOT/Tools/notarize.sh" "$APP"
fi

echo "==> 校验"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dvv "$APP" 2>&1 | grep -E '^(Identifier|Authority|TeamIdentifier|Timestamp|Runtime Version|CodeDirectory)' || true
echo "--- 指定要求（Designated Requirement）"
codesign -d -r- "$APP" 2>&1 | sed -n 's/^designated => /  /p'
echo "--- App Group：${APP_GROUP}，链接：${URL_SCHEME}://"
if [ -n "$WIDGET_APPEX" ]; then
    codesign -d --entitlements :- "$WIDGET_APPEX" 2>/dev/null | grep -q "$APP_GROUP" \
        || { echo "小组件签名里没有 App Group $APP_GROUP" >&2; exit 1; }
    echo "--- 小组件：${WIDGET_ID}（沙盒 + App Group）"
fi
echo "--- Gatekeeper（未公证时显示 Unnotarized 属正常）"
spctl --assess --type execute -vv "$APP" 2>&1 || true

echo ""
echo "完成：${APP}  （版本 ${VERSION} / 构建 ${BUILD_NUMBER}）"
if [ "${PACKAGE:-1}" != "0" ]; then
    echo "==> 打包"
    ZIP="$DIST/${ARTIFACT}.zip"
    rm -f "$ZIP" "$ZIP.sha256"
    ditto -c -k --keepParent --sequesterRsrc "$APP" "$ZIP"
    (cd "$DIST" && shasum -a 256 "${ARTIFACT}.zip" > "${ARTIFACT}.zip.sha256")
    echo "      ${ZIP}"
    echo "      SHA-256 $(awk '{print $1}' "$ZIP.sha256")"
fi
