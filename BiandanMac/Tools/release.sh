#!/bin/bash
# 一条命令发布 Mac 版：公证凭据 → 检查私钥、证书、服务器 → 打 tag → 打包、签名、公证、生成更新文件 → 上传 → 推送。
#
# 用法（在 BiandanMac 目录）：
#   Tools/release.sh 1.3.0                    发布 1.3.0
#   Tools/release.sh 1.3.1 --channel beta     只推给设置里打开了「接收测试版」的人
#   Tools/release.sh --check                  只检查凭据、私钥、证书、服务器，不打包、不上传
# 其他参数：
#   --no-push      上传后不推送分支和 tag（默认全部成功后推送到 origin）
#   --skip-build   不重新打包，用 dist/ 里已有的包（传给 make_update.sh）
#
# .env（已被 git 忽略，权限 600）里的公证凭据按格式识别，行的顺序和前面的说明文字都不要紧：
#   appleid:<Apple ID 邮箱>
#   <说明>:<10 位 Team ID>
#   <说明>:<App 专用密码，xxxx-xxxx-xxxx-xxxx>
# 第一次（或钥匙串里的凭据失效时）把凭据存进钥匙串的公证配置 biandan-notary，之后公证都从钥匙串读。
# 脚本不打印任何凭据。上传走 ~/.ssh/config 里的 biandan-update（密钥登录）。
#
# 发布前：CHANGELOG.md 里有「## [X.Y.Z]」一节，Tools/build_app.sh 的 DEFAULT_VERSION 是 X.Y.Z，改动都已提交。
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
cd "$HERE"
ENVF="$HERE/.env"
PROFILE="${NOTARY_PROFILE:-biandan-notary}"
EXPECTED_TEAM="G48CJ2J7C8"
SPARKLE_ACCOUNT="${SPARKLE_ACCOUNT:-ai.racore.BiandanMac}"
UPDATE_HOST="${UPDATE_HOST:-biandan-update}"
BASE="${UPDATE_BASE_URL:-https://www.aigslb.link/biandan/mac/update}"
BASE="${BASE%/}"

VERSION=""
CHANNEL=""
PUSH=1
CHECK=0
SKIP_BUILD=0
while [ $# -gt 0 ]; do
    case "$1" in
        --check) CHECK=1 ;;
        --no-push) PUSH=0 ;;
        --skip-build) SKIP_BUILD=1 ;;
        --channel) CHANNEL="${2:?--channel 后面要写渠道名，例如 beta}"; shift ;;
        -h|--help) sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        [0-9]*) VERSION="$1" ;;
        *) echo "未知参数：$1" >&2; exit 2 ;;
    esac
    shift
done
if [ "$CHECK" = 0 ] && ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "用法：Tools/release.sh <X.Y.Z> [--channel beta] [--no-push] [--skip-build]，或 Tools/release.sh --check" >&2
    exit 2
fi

step() { echo; echo "==> $*"; }
die() { echo "✗ $*" >&2; exit 1; }

# ---- 1. 公证凭据 ----
step "1. 公证凭据"
if xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
    echo "钥匙串里的公证配置 ${PROFILE} 可用"
else
    [ -f "$ENVF" ] || die "钥匙串里没有可用的公证配置 ${PROFILE}，也没有 .env"
    if [ "$(stat -f %Lp "$ENVF")" != 600 ]; then
        chmod 600 "$ENVF"
        echo "已把 .env 的权限改为 600"
    fi
    APPLE_ID=""
    TEAM_ID=""
    APP_PW=""
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"
        if [ -z "$APPLE_ID" ] && [[ "$line" =~ ([^[:space:]:=@]+@[^[:space:]@]+\.[^[:space:]@]+) ]]; then
            APPLE_ID="${BASH_REMATCH[1]}"; continue
        fi
        if [ -z "$APP_PW" ] && [[ "$line" =~ ([a-z]{4}-[a-z]{4}-[a-z]{4}-[a-z]{4}) ]]; then
            APP_PW="${BASH_REMATCH[1]}"; continue
        fi
        if [ -z "$TEAM_ID" ] && [[ "$line" =~ (^|[^A-Za-z0-9])([A-Z0-9]{10})([^A-Za-z0-9]|$) ]]; then
            TEAM_ID="${BASH_REMATCH[2]}"; continue
        fi
    done < "$ENVF"
    missing=""
    [ -n "$APPLE_ID" ] || missing="$missing Apple ID（邮箱）"
    [ -n "$TEAM_ID" ] || missing="$missing Team ID（10 位大写字母和数字）"
    [ -n "$APP_PW" ] || missing="$missing App 专用密码（xxxx-xxxx-xxxx-xxxx）"
    [ -z "$missing" ] || die ".env 里没找到：${missing}"
    [ "$TEAM_ID" = "$EXPECTED_TEAM" ] \
        || die ".env 里的 Team ID 和签名证书的团队（${EXPECTED_TEAM}）不一致"
    echo "从 .env 读到 Apple ID、Team ID 和 App 专用密码，存进钥匙串（会先向 Apple 验证）"
    ERR="$(mktemp)"
    if ! xcrun notarytool store-credentials "$PROFILE" --apple-id "$APPLE_ID" --team-id "$TEAM_ID" \
            --password "$APP_PW" >/dev/null 2>"$ERR"; then
        msg="$(tail -3 "$ERR")"
        msg="${msg//"$APP_PW"/<专用密码>}"
        msg="${msg//"$APPLE_ID"/<Apple ID>}"
        rm -f "$ERR"
        unset APP_PW
        echo "$msg" >&2
        die "保存公证凭据失败：检查 .env 里的 Apple ID 和 App 专用密码（account.apple.com → 登录与安全 → App 专用密码）"
    fi
    rm -f "$ERR"
    unset APP_PW APPLE_ID
    xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1 \
        || die "凭据已保存，但钥匙串里的公证配置 ${PROFILE} 还是不能用"
    echo "已保存公证配置 ${PROFILE}，以后公证都从钥匙串读"
fi

# ---- 2. Sparkle 私钥、签名证书、更新服务器 ----
step "2. 检查 Sparkle 私钥、签名证书、更新服务器"
BIN="$HERE/.build/artifacts/sparkle/Sparkle/bin"
[ -x "$BIN/generate_keys" ] || swift package resolve >/dev/null
[ -x "$BIN/generate_keys" ] || die "找不到 Sparkle 工具：${BIN}"
PUB="$("$BIN/generate_keys" --account "$SPARKLE_ACCOUNT" -p 2>/dev/null | tail -1 || true)"
[ -n "$PUB" ] || die "钥匙串里没有 Sparkle 私钥（账户 ${SPARKLE_ACCOUNT}），从备份导入：generate_keys --account ${SPARKLE_ACCOUNT} -f <文件>"
grep -qF "$PUB" Tools/build_app.sh || die "钥匙串里的 Sparkle 公钥和 Tools/build_app.sh 里的不一致，已安装的便单不会认这次的更新包"
echo "Sparkle 私钥在钥匙串里，公钥和打包脚本一致"
security find-identity -v -p codesigning | grep -q "Developer ID Application: .*(${EXPECTED_TEAM})" \
    || die "没有找到团队 ${EXPECTED_TEAM} 的 Developer ID Application 证书"
echo "Developer ID 证书可用"
ssh -o BatchMode=yes -o LogLevel=ERROR -o ConnectTimeout=10 "$UPDATE_HOST" true \
    || die "连不上更新服务器 ${UPDATE_HOST}（ssh 密钥登录）"
echo "更新服务器可以用密钥登录"
read -r code ctype <<<"$(curl -s -o /dev/null -w '%{http_code} %{content_type}' "$BASE/appcast.xml" || echo '000 -')"
case "$code" in
    404) echo "公网 appcast.xml 返回 404（还没发布过）" ;;
    200) [[ "$ctype" == *html* ]] && die "公网 appcast.xml 返回的是网页，检查 Nginx / ESA 配置"
         echo "公网 appcast.xml 可以访问" ;;
    *) die "公网 appcast.xml 返回 ${code}" ;;
esac

if [ "$CHECK" = 1 ]; then
    echo
    echo "检查都通过了。发布时运行：Tools/release.sh <X.Y.Z>"
    exit 0
fi

# ---- 3. tag ----
TAG="v$VERSION"
step "3. tag ${TAG}"
git diff --quiet && git diff --cached --quiet || die "工作区有未提交的修改，先提交"
if [ "$(git describe --tags --exact-match --match "$TAG" HEAD 2>/dev/null || true)" = "$TAG" ]; then
    echo "HEAD 已经在 ${TAG} 上"
else
    git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && die "${TAG} 已经存在，但不在 HEAD 上"
    grep -q "^## \[$VERSION\]" CHANGELOG.md || die "CHANGELOG.md 里没有「## [${VERSION}]」这一节"
    grep -q "^DEFAULT_VERSION=\"$VERSION\"" Tools/build_app.sh || die "Tools/build_app.sh 的 DEFAULT_VERSION 不是 ${VERSION}"
    "$HERE/Tools/tag_release.sh" "$VERSION"
fi

# ---- 4. 打包、签名、公证、生成更新文件 ----
step "4. 打包、签名、公证，生成 dist/update/（公证通常 1–5 分钟）"
ARGS=()
[ -n "$CHANNEL" ] && ARGS+=(--channel "$CHANNEL")
[ "$SKIP_BUILD" = 1 ] && ARGS+=(--skip-build)
NOTARY_PROFILE="$PROFILE" NOTARIZE=1 "$HERE/Tools/make_update.sh" ${ARGS[@]+"${ARGS[@]}"}
xcrun stapler validate dist/Biandan.app >/dev/null 2>&1 \
    || die "dist/Biandan.app 没有公证票据，不上传（用户首次打开会被拦下）"
spctl --assess --type execute dist/Biandan.app 2>/dev/null || die "Gatekeeper 不接受 dist/Biandan.app，不上传"
echo "已公证，Gatekeeper 检查通过"

# ---- 5. 上传 ----
step "5. 上传到 ${UPDATE_HOST}"
"$HERE/Tools/sync_update.sh"

# ---- 6. 推送 ----
if [ "$PUSH" = 1 ]; then
    step "6. 推送分支和 ${TAG}"
    BRANCH="$(git branch --show-current)"
    git push origin "$BRANCH"
    git push origin "$TAG"
else
    step "6. 没有推送（--no-push）。需要时运行：git push origin $(git branch --show-current) && git push origin ${TAG}"
fi

echo
echo "发布完成：${VERSION}${CHANNEL:+（${CHANNEL} 渠道）}"
echo "更新包：$BASE/Biandan-$VERSION.zip"
echo "dist/update/ 要留着：下一版靠它保留旧条目、生成增量包。"
