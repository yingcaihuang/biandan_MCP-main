#!/bin/bash
# 生成自动更新要上传到服务器的文件，放在 dist/update/：
#   appcast.xml               版本列表（Sparkle 读这个），每个包都带 EdDSA 签名
#   Biandan-X.Y.Z.zip         更新包（签名 + 公证过）
#   Biandan-X.Y.Z.html        更新说明（从 CHANGELOG.md 生成，更新窗口里显示）
#   *.delta                   增量包（目录里有旧版本的 zip 时自动生成，升级只下载改动的部分）
#
# 用法（在 BiandanMac 目录，HEAD 在 vX.Y.Z tag 上）：Tools/make_update.sh [--channel beta] [--skip-build]
#   --channel beta  这一版只推给设置里打开了「接收测试版」的人
#   --skip-build    不重新打包，直接用 dist/ 里已有的 Biandan-X.Y.Z.zip
# 环境变量：
#   UPDATE_BASE_URL  服务器上的目录地址，默认 https://www.aigslb.link/biandan/mac/update
#   NOTARIZE=0       打包时不公证（不建议：用户首次打开会被拦下）
#   SPARKLE_ACCOUNT  钥匙串里 EdDSA 私钥的账户名，默认 ai.racore.BiandanMac
#
# 上传：把 dist/update/ 整个目录同步到服务器（appcast.xml 最后传）。dist/update/ 要保留，
# 下一版生成时会在这里找旧版本的包来做增量包，并保留 appcast.xml 里旧版本的条目。
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
cd "$HERE"
BASE="${UPDATE_BASE_URL:-https://www.aigslb.link/biandan/mac/update}"
BASE="${BASE%/}"
ACCOUNT="${SPARKLE_ACCOUNT:-ai.racore.BiandanMac}"
BIN="$HERE/.build/artifacts/sparkle/Sparkle/bin"
CHANNEL=""
BUILD=1
while [ $# -gt 0 ]; do
    case "$1" in
        --channel) CHANNEL="${2:?--channel 后面要写渠道名，例如 beta}"; shift ;;
        --skip-build) BUILD=0 ;;
        -h|--help) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "未知参数：$1" >&2; exit 2 ;;
    esac
    shift
done

TAG="$(git describe --tags --exact-match --match 'v[0-9]*.[0-9]*.[0-9]*' HEAD 2>/dev/null || true)"
[ -n "$TAG" ] || { echo "HEAD 不在 vX.Y.Z tag 上。先提交、用 Tools/tag_release.sh 打 tag 再生成更新。" >&2; exit 1; }
VERSION="${TAG#v}"
ZIP_NAME="Biandan-$VERSION.zip"

if [ ! -x "$BIN/generate_appcast" ]; then
    swift package resolve >/dev/null
    [ -x "$BIN/generate_appcast" ] || { echo "找不到 Sparkle 工具：$BIN" >&2; exit 1; }
fi
"$BIN/generate_keys" --account "$ACCOUNT" -p >/dev/null 2>&1 \
    || { echo "钥匙串里没有账户「${ACCOUNT}」的 Sparkle 私钥（从备份导入：generate_keys --account $ACCOUNT -f <文件>）" >&2; exit 1; }

if [ "$BUILD" = 1 ]; then
    NOTARIZE="${NOTARIZE:-1}" "$HERE/Tools/build_app.sh"
fi
[ -f "dist/$ZIP_NAME" ] || { echo "找不到 dist/${ZIP_NAME}（工作区有未提交改动时打出的是 -dev 包）" >&2; exit 1; }
if ! xcrun stapler validate dist/Biandan.app >/dev/null 2>&1; then
    echo "提醒：dist/Biandan.app 没有公证票据，用户首次打开会被 Gatekeeper 拦下。" >&2
fi

UPDATE="$HERE/dist/update"
mkdir -p "$UPDATE"
# 本机没有 appcast.xml 时，先取服务器上的，保留旧版本的条目。服务器对不存在的文件可能返回网页，要确认是 XML。
if [ ! -f "$UPDATE/appcast.xml" ]; then
    if curl -fsSL "$BASE/appcast.xml" -o "$UPDATE/appcast.remote" 2>/dev/null \
        && head -c 200 "$UPDATE/appcast.remote" | grep -q '<?xml' && grep -q '<rss' "$UPDATE/appcast.remote"; then
        mv "$UPDATE/appcast.remote" "$UPDATE/appcast.xml"
        echo "==> 已取回服务器上的 appcast.xml"
    else
        rm -f "$UPDATE/appcast.remote"
        echo "==> 服务器上还没有 appcast.xml，新建"
    fi
fi

cp "dist/$ZIP_NAME" "$UPDATE/$ZIP_NAME"
python3 "$HERE/Tools/changelog_html.py" "$VERSION" > "$UPDATE/Biandan-$VERSION.html"

echo "==> 生成 appcast.xml（用钥匙串里的私钥签名，可能会弹窗请求访问钥匙串）"
ARGS=(--account "$ACCOUNT" --download-url-prefix "$BASE/" --release-notes-url-prefix "$BASE/" --maximum-deltas 3)
[ -n "$CHANNEL" ] && ARGS+=(--channel "$CHANNEL")
"$BIN/generate_appcast" "${ARGS[@]}" "$UPDATE"

grep -q "sparkle:edSignature" "$UPDATE/appcast.xml" || { echo "appcast.xml 里没有 EdDSA 签名" >&2; exit 1; }
grep -q "$ZIP_NAME" "$UPDATE/appcast.xml" || { echo "appcast.xml 里没有 $ZIP_NAME" >&2; exit 1; }

echo ""
echo "完成：$UPDATE"
ls -la "$UPDATE"
echo ""
echo "把 dist/update/ 同步到 $BASE/（先传 zip、delta、html，最后传 appcast.xml）。"
echo "服务器上 appcast.xml 建议 Cache-Control: max-age=300，不存在的文件返回 404。"
