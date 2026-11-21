#!/bin/bash
# 在这台 Mac 上开发前运行一次：从钥匙串里选一张代码签名证书，存到 .signing.local（只在本机，不提交）。
# 之后 Tools/dev_run.sh 用这张证书和固定的标识符签名开发版，钥匙串、屏幕录制、通知授权一次就一直有效。
#
# 用法：Tools/setup_signing.sh              列出证书，按序号选择
#       Tools/setup_signing.sh --list       只列出证书
#       Tools/setup_signing.sh <序号|SHA-1>  直接指定
#       Tools/setup_signing.sh --show       查看当前设置
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FILE="$ROOT/.signing.local"
DEV_BUNDLE_ID="ai.racore.BiandanMac.dev"

IDS=()
NAMES=()
while IFS= read -r line; do
    sha="$(echo "$line" | awk '{print $2}')"
    [[ "$sha" =~ ^[0-9A-F]{40}$ ]] || continue
    name="$(echo "$line" | sed -E 's/^[^"]*"(.*)"[^"]*$/\1/')"
    IDS+=("$sha")
    NAMES+=("$name")
done < <(security find-identity -v -p codesigning)

if [ ${#IDS[@]} -eq 0 ]; then
    cat >&2 <<'HELP'
钥匙串里没有可用的代码签名证书。
可以在 Xcode → 设置 → Accounts 登录 Apple ID，选中团队后点「Manage Certificates…」→「+」→「Apple Development」生成一张，
然后重新运行 Tools/setup_signing.sh。
HELP
    exit 1
fi

CURRENT=""
if [ -f "$FILE" ]; then
    CURRENT="$(sed -n 's/^BIANDAN_DEV_SIGN_IDENTITY=//p' "$FILE")"
fi

list() {
    local i mark
    for i in "${!IDS[@]}"; do
        mark="  "
        [ "${IDS[$i]}" = "$CURRENT" ] && mark="* "
        printf '%s%d) %s  [%s…]\n' "$mark" $((i + 1)) "${NAMES[$i]}" "${IDS[$i]:0:10}"
    done
}

show() {
    if [ -f "$FILE" ]; then
        echo "当前设置（${FILE}）："
        sed -n '/^BIANDAN_/p' "$FILE" | sed 's/^/  /'
    else
        echo "还没有设置，运行 Tools/setup_signing.sh 选择证书。"
    fi
}

ARG="${1:-}"
case "$ARG" in
    --list) list; exit 0 ;;
    --show) show; exit 0 ;;
    -h|--help) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
esac

# 默认选中：已有设置，否则第一张 Apple Development 证书，否则第一张。
DEFAULT=1
for i in "${!IDS[@]}"; do
    if [ -n "$CURRENT" ] && [ "${IDS[$i]}" = "$CURRENT" ]; then DEFAULT=$((i + 1)); break; fi
done
if [ -z "$CURRENT" ]; then
    for i in "${!IDS[@]}"; do
        case "${NAMES[$i]}" in "Apple Development:"*) DEFAULT=$((i + 1)); break ;; esac
    done
fi

CHOICE="$ARG"
if [ -z "$CHOICE" ]; then
    echo "这台 Mac 上可用的代码签名证书（* 为当前设置）："
    list
    echo ""
    echo "开发版建议用「Apple Development」证书；「Developer ID Application」也可以。"
    read -r -p "选择序号 [${DEFAULT}]：" CHOICE
    CHOICE="${CHOICE:-$DEFAULT}"
fi

INDEX=""
if [[ "$CHOICE" =~ ^[0-9]+$ ]] && [ "$CHOICE" -ge 1 ] && [ "$CHOICE" -le ${#IDS[@]} ]; then
    INDEX=$((CHOICE - 1))
else
    for i in "${!IDS[@]}"; do
        [ "${IDS[$i]}" = "$(echo "$CHOICE" | tr 'a-f' 'A-F')" ] && INDEX=$i
    done
fi
if [ -z "$INDEX" ]; then
    echo "没有这个证书：${CHOICE}。用 Tools/setup_signing.sh --list 查看。" >&2
    exit 2
fi
SHA="${IDS[$INDEX]}"
NAME="${NAMES[$INDEX]}"

# 先试签一个临时文件，确认 codesign 能用这张证书的私钥。
echo "==> 检查「${NAME}」能否用于签名"
PROBE_DIR="$(mktemp -d)"
cp /bin/echo "$PROBE_DIR/probe"
if ! codesign --force --sign "$SHA" --timestamp=none "$PROBE_DIR/probe" >/dev/null 2>&1; then
    rm -rf "${PROBE_DIR:?}"
    cat >&2 <<'HELP'
codesign 无法使用这张证书的私钥（通常是登录钥匙串锁着，或私钥还没允许 codesign 访问）。
请在系统自带的「终端.app」里重新运行本脚本；弹出「codesign 想要使用钥匙串中的密钥」时输入登录密码，点「始终允许」。
也可以一次性授权：security set-key-partition-list -S apple-tool:,apple:,codesign: -s ~/Library/Keychains/login.keychain-db
HELP
    exit 1
fi
rm -rf "${PROBE_DIR:?}"

{
    echo "# 由 Tools/setup_signing.sh 生成，只在本机使用，不要提交。"
    echo "BIANDAN_DEV_SIGN_IDENTITY=${SHA}"
    printf 'BIANDAN_DEV_SIGN_NAME=%q\n' "$NAME"
    echo "BIANDAN_DEV_BUNDLE_ID=${DEV_BUNDLE_ID}"
} > "$FILE"

echo "已保存：${FILE}"
echo "  证书：${NAME}"
echo "  开发版标识符：${DEV_BUNDLE_ID}"
echo ""
echo "以后用 Tools/dev_run.sh 编译并启动「便单 Dev」。第一次运行时按提示授权一次，之后重新编译也不会再问。"
