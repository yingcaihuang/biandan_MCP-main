#!/bin/bash
# 把签好名的 .app 提交 Apple 公证，通过后把公证票据钉进 .app（stapler），用户下载后打开不会被 Gatekeeper 拦下。
#
# 用法：Tools/notarize.sh <App 路径>
#   通常不用单独运行：NOTARIZE=1 Tools/build_app.sh 会在签名后自动调用。
#
# 第一次使用先在「终端」里保存一次凭据（App 专用密码只存在钥匙串里，不写进任何文件）：
#   xcrun notarytool store-credentials biandan-notary --apple-id <你的 Apple ID> --team-id G48CJ2J7C8
#   按提示粘贴 App 专用密码。凭据名可以用环境变量 NOTARY_PROFILE 改，默认 biandan-notary。
set -euo pipefail

APP="${1:-}"
[ -n "$APP" ] && [ -d "$APP" ] || { echo "用法：$0 <App 路径>" >&2; exit 2; }
PROFILE="${NOTARY_PROFILE:-biandan-notary}"

if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
    cat >&2 <<HELP
公证凭据「${PROFILE}」不可用（还没保存，或者 App 专用密码已失效）。先在「终端」里运行一次：

  xcrun notarytool store-credentials ${PROFILE} --apple-id <你的 Apple ID> --team-id G48CJ2J7C8

按提示粘贴 App 专用密码（在 account.apple.com → 登录与安全 → App 专用密码 里生成），然后重新运行。
HELP
    exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP:?}"' EXIT
ZIP="$TMP/$(basename "$APP" .app)-notarize.zip"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> 提交公证（通常 1–5 分钟）"
RESULT="$(xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait --output-format json)"
STATUS="$(plutil -extract status raw -o - - <<<"$RESULT" 2>/dev/null || echo unknown)"
ID="$(plutil -extract id raw -o - - <<<"$RESULT" 2>/dev/null || echo "")"
echo "    提交 ${ID:-?}：${STATUS}"
if [ "$STATUS" != "Accepted" ]; then
    echo "公证没有通过，Apple 返回的日志：" >&2
    if [ -n "$ID" ]; then
        xcrun notarytool log "$ID" --keychain-profile "$PROFILE" >&2 || true
    else
        echo "$RESULT" >&2
    fi
    exit 1
fi

echo "==> 钉入公证票据"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
echo "--- Gatekeeper"
spctl --assess --type execute -vv "$APP"
