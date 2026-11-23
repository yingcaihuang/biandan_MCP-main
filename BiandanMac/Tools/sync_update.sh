#!/bin/bash
# 把 Tools/make_update.sh 生成的 dist/update/ 同步到更新服务器（www.aigslb.link 源站的 Nginx）。
#
# 用法（在 BiandanMac 目录）：Tools/sync_update.sh [--dry-run]
#   --dry-run  只列出要传哪些文件，不上传
# 环境变量：
#   UPDATE_HOST      SSH 主机，默认 biandan-update（~/.ssh/config 里的别名，用密钥登录）
#   UPDATE_DIR       服务器上的目录，默认 /usr/share/nginx/www/biandan/mac/update
#   UPDATE_BASE_URL  公网地址，默认 https://www.aigslb.link/biandan/mac/update
#
# 顺序：先传 appcast.xml 引用的 zip / delta（服务器上已有的同名文件不覆盖：已发布的包内容不能变），
# 再传更新说明 html，最后传 appcast.xml（先有包、后有列表，用户不会下载到还没传完的包）。
# 传完核对服务器上的文件大小，再从公网（经过 ESA）确认 appcast.xml 已经是新版本。
# 不删除服务器上的旧文件：旧版本的包要留给增量升级和回滚。
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$HERE/dist/update"
HOST="${UPDATE_HOST:-biandan-update}"
DIR="${UPDATE_DIR:-/usr/share/nginx/www/biandan/mac/update}"
BASE="${UPDATE_BASE_URL:-https://www.aigslb.link/biandan/mac/update}"
BASE="${BASE%/}"
DRY=0
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY=1 ;;
        -h|--help) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "未知参数：$1" >&2; exit 2 ;;
    esac
    shift
done

SSH=(ssh -o BatchMode=yes -o LogLevel=ERROR "$HOST")
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP:?}"' EXIT
local_size() { stat -f %z "$SRC/$1"; }
remote_size() { awk -v n="$1" '$1 == n { print $2 }' "$TMP/remote"; }

# ---- 检查本地文件 ----
APPCAST="$SRC/appcast.xml"
[ -f "$APPCAST" ] || { echo "没有 $APPCAST，先运行 Tools/make_update.sh" >&2; exit 1; }
{ head -c 200 "$APPCAST" | grep -q '<?xml' && grep -q '<rss' "$APPCAST"; } \
    || { echo "appcast.xml 不是 RSS" >&2; exit 1; }
grep -q 'sparkle:edSignature' "$APPCAST" || { echo "appcast.xml 里没有 EdDSA 签名" >&2; exit 1; }
LATEST="$(grep -oE '<sparkle:shortVersionString>[^<]+' "$APPCAST" | head -1 | sed 's/.*>//')"
[ -n "$LATEST" ] || { echo "appcast.xml 里读不到版本号" >&2; exit 1; }

# appcast.xml 引用的文件（更新包、增量包、更新说明），都要在 dist/update/ 里、都在 $BASE/ 下。
PACKAGES=()
NOTES=()
while IFS= read -r url; do
    [ -n "$url" ] || continue
    case "$url" in
        "$BASE"/*) ;;
        *) echo "appcast.xml 里有不在 $BASE/ 下的地址：$url" >&2; exit 1 ;;
    esac
    name="${url#"$BASE"/}"
    [ -f "$SRC/$name" ] || { echo "appcast.xml 引用了 $name，但 dist/update/ 里没有" >&2; exit 1; }
    case "$name" in
        *.zip|*.delta) PACKAGES+=("$name") ;;
        *) NOTES+=("$name") ;;
    esac
done < <({ grep -oE 'url="[^"]+"' "$APPCAST" | sed -E 's/^url="//; s/"$//'
           grep -oE '<sparkle:releaseNotesLink[^>]*>[^<]+' "$APPCAST" | sed 's/.*>//'; } | sort -u)
[ ${#PACKAGES[@]} -gt 0 ] || { echo "appcast.xml 里没有更新包" >&2; exit 1; }

# ---- 服务器上已有的文件 ----
if [ "$DRY" = 1 ]; then
    "${SSH[@]}" "cd '$DIR' 2>/dev/null && find . -maxdepth 1 -type f -printf '%f %s\n' || true" > "$TMP/remote"
else
    "${SSH[@]}" "mkdir -p '$DIR' && cd '$DIR' && find . -maxdepth 1 -type f -printf '%f %s\n'" > "$TMP/remote"
fi

# 已发布的包不能改：服务器上同名、大小不同就停下，一个文件也不传。
UPLOAD=()
for name in "${PACKAGES[@]}"; do
    remote="$(remote_size "$name")"
    if [ -z "$remote" ]; then
        UPLOAD+=("$name")
    elif [ "$remote" != "$(local_size "$name")" ]; then
        echo "服务器上的 $name（$remote 字节）和本地（$(local_size "$name") 字节）不一样。" >&2
        echo "已发布的包不能替换（用户和 CDN 可能已经拿到旧的），请换一个版本号重新打包。" >&2
        exit 1
    fi
done

echo "版本 $LATEST → $HOST:$DIR"
echo "  更新包：${#UPLOAD[@]} 个要上传，$((${#PACKAGES[@]} - ${#UPLOAD[@]})) 个服务器上已有"
for name in ${UPLOAD[@]+"${UPLOAD[@]}"}; do echo "    + $name（$(local_size "$name") 字节）"; done
echo "  更新说明：${NOTES[*]:-无}"
echo "  最后：appcast.xml"
if [ "$DRY" = 1 ]; then
    echo "（--dry-run：没有上传）"
    exit 0
fi

RSYNC=(rsync -t -e "ssh -o BatchMode=yes -o LogLevel=ERROR")
put() {
    local files=()
    for name in "$@"; do files+=("$SRC/$name"); done
    "${RSYNC[@]}" "${files[@]}" "$HOST:$DIR/"
}

echo "==> 1/3 更新包"
[ ${#UPLOAD[@]} -gt 0 ] && put "${UPLOAD[@]}"
echo "==> 2/3 更新说明"
[ ${#NOTES[@]} -gt 0 ] && put "${NOTES[@]}"
echo "==> 3/3 appcast.xml"
put appcast.xml
"${SSH[@]}" "chmod 755 '$DIR' && find '$DIR' -maxdepth 1 -type f -exec chmod 644 {} +"

# ---- 核对服务器上的文件大小 ----
"${SSH[@]}" "cd '$DIR' && find . -maxdepth 1 -type f -printf '%f %s\n'" > "$TMP/remote"
for name in "${PACKAGES[@]}" ${NOTES[@]+"${NOTES[@]}"} appcast.xml; do
    [ "$(remote_size "$name")" = "$(local_size "$name")" ] \
        || { echo "服务器上的 $name 大小不对，请检查" >&2; exit 1; }
done
echo "==> 服务器上的文件大小都和本地一致"

# ---- 从公网（经过 ESA）确认 ----
ZIP="Biandan-$LATEST.zip"
if curl -fsS "$BASE/appcast.xml" -o "$TMP/public.xml" 2>/dev/null \
    && grep -q "<sparkle:shortVersionString>$LATEST<" "$TMP/public.xml"; then
    echo "==> 公网的 appcast.xml 已经是 $LATEST"
else
    echo "提醒：公网的 appcast.xml 还不是 $LATEST，多半是 ESA 还缓存着旧内容。" >&2
    echo "      到 ESA 控制台按 URL 刷新 $BASE/appcast.xml，或等最多 5 分钟。" >&2
fi
if [ -f "$SRC/$ZIP" ]; then
    length="$(curl -fsSI "$BASE/$ZIP" 2>/dev/null | awk -F': ' 'tolower($1) == "content-length" { gsub(/\r/, "", $2); print $2 }' | tail -1)"
    if [ "$length" = "$(local_size "$ZIP")" ]; then
        echo "==> 公网可以下载 $ZIP（$length 字节）"
    else
        echo "提醒：公网下载 $ZIP 的大小是「${length:-读不到}」，本地是 $(local_size "$ZIP")，请检查 ESA。" >&2
    fi
fi
echo "完成。"
