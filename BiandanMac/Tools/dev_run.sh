#!/bin/bash
# 编译开发版并启动「便单 Dev」：用 Tools/setup_signing.sh 选好的证书签名，标识符固定为 ai.racore.BiandanMac.dev。
# 签名每次都一样，所以钥匙串「始终允许」、屏幕录制、通知授权一次就一直有效
# （Xcode ⌘R、swift run 出来的是临时签名的裸可执行文件，每次编译都会重新问）。
#
# 用法：Tools/dev_run.sh [--no-open] [--offline] [变量=值 ...]
#   --no-open   只编译、组装、签名，不启动
#   --offline   以 BIANDAN_DEBUG_OFFLINE=1 启动（不联网、不读钥匙串）
#   变量=值     传给 App 的环境变量，例如 BIANDAN_DEBUG_SELECT=腾讯分享会
# 产物：.build/dev/BiandanDev.app（不提交）。调试：Xcode → Debug → Attach to Process →「便单 Dev」。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG_FILE="$ROOT/.signing.local"
if [ ! -f "$CONFIG_FILE" ]; then
    echo "还没有选择签名证书，先运行一次：Tools/setup_signing.sh" >&2
    exit 1
fi
# shellcheck source=/dev/null
source "$CONFIG_FILE"
: "${BIANDAN_DEV_SIGN_IDENTITY:?.signing.local 里没有 BIANDAN_DEV_SIGN_IDENTITY，重新运行 Tools/setup_signing.sh}"
DEV_BUNDLE_ID="${BIANDAN_DEV_BUNDLE_ID:-ai.racore.BiandanMac.dev}"

OPEN=1
ENVS=()
for arg in "$@"; do
    case "$arg" in
        --no-open) OPEN=0 ;;
        --offline) ENVS+=("BIANDAN_DEBUG_OFFLINE=1") ;;
        *=*) ENVS+=("$arg") ;;
        -h|--help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "未知参数：${arg}（用 --help 查看用法）" >&2; exit 2 ;;
    esac
done

DIST="$ROOT/.build/dev"
APP="$DIST/BiandanDev.app"
EXEC="$APP/Contents/MacOS/BiandanMac"

# 先关掉正在运行的开发版，免得启动时打开的是旧进程。
if pgrep -f "$EXEC" >/dev/null 2>&1; then
    pkill -f "$EXEC" || true
    sleep 1
fi
if pgrep -f '/Biandan.app/Contents/MacOS/BiandanMac' >/dev/null 2>&1; then
    echo "提醒：正式版便单也在运行。两个同时开着时 MCP 端口和全局快捷键会冲突，建议先退出正式版。" >&2
fi

mkdir -p "$DIST"
CONFIG=debug \
BIANDAN_SIGN_IDENTITY="$BIANDAN_DEV_SIGN_IDENTITY" \
BUNDLE_ID="$DEV_BUNDLE_ID" \
DISPLAY_NAME="便单 Dev" \
DIST="$DIST" \
APP_FILE="BiandanDev" \
ENTITLEMENTS="$ROOT/Tools/BiandanMac.dev.entitlements" \
HARDENED=0 \
TIMESTAMP=0 \
PACKAGE=0 \
    "$ROOT/Tools/build_app.sh"

# 同一个标识符在系统里登记了好几份（以前放过 ~/Applications、/tmp 等位置）时，小组件服务可能不收这个扩展：
# 只留这次组装的这一份，其余的注销登记（不删文件）。
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
while IFS= read -r stale; do
    [ -n "$stale" ] && [ "$stale" != "$APP" ] || continue
    pluginkit -r "$stale/Contents/PlugIns/BiandanWidget.appex" 2>/dev/null || true
    "$LSREGISTER" -u "$stale" 2>/dev/null && echo "已注销重复登记：${stale}"
done < <("$LSREGISTER" -dump 2>/dev/null | sed -n 's/^path: *\(.*\/BiandanDev\.app\) (0x.*/\1/p' | sort -u)
"$LSREGISTER" -f "$APP"

[ "$OPEN" = "1" ] || exit 0

ARGS=()
for item in ${ENVS[@]+"${ENVS[@]}"}; do
    ARGS+=(--env "$item")
done
open ${ARGS[@]+"${ARGS[@]}"} "$APP"
echo "已启动：${APP}"
