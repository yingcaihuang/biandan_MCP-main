#!/bin/bash
# 重新生成便单 Mac 版介绍页（Tools/site_page.py → dist/site/），上传到更新服务器的 /biandan/mac/，再核对。
#
# 用法（在 BiandanMac 目录）：
#   Tools/sync_site.sh            生成并上传
#   Tools/sync_site.sh --dry-run  只生成和检查，不上传
#
# 服务器上原来的 index.html、icon-256.png 先备份到 /root/nginx-backup/。走 ~/.ssh/config 里的 biandan-update（密钥登录）。
# 下载按钮指向 CHANGELOG 里最新版本的 zip（dist/ 里要有这个包）。ESA 对 html 缓存 1 小时，公网可能晚一点才是新页面。
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
cd "$HERE"
HOST="${UPDATE_HOST:-biandan-update}"
REMOTE_DIR="${SITE_REMOTE_DIR:-/usr/share/nginx/www/biandan/mac}"
SITE_URL="${SITE_URL:-https://www.aigslb.link/biandan/mac/}"
SITE_HOST="www.aigslb.link"
DRY=0
case "${1:-}" in
    --dry-run) DRY=1 ;;
    "") ;;
    -h|--help) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "未知参数：${1}" >&2; exit 2 ;;
esac
SSHO=(-o BatchMode=yes -o LogLevel=ERROR -o ConnectTimeout=10)
die() { echo "✗ $*" >&2; exit 1; }

echo "==> 生成介绍页"
python3 Tools/site_page.py
F=dist/site/index.html
ICON=dist/site/icon-256.png
DEMO=dist/site/install.gif
HAS_DEMO=0
[ -s "$DEMO" ] && HAS_DEMO=1
[ -s "$F" ] && [ -s "$ICON" ] || die "没有生成 dist/site/"

# 页面里不能有服务器 IP 和密钥
if [ -f .env ]; then
    IP="$(sed -n 2p .env | tr -d '[:space:]')"
    if [ -n "$IP" ] && grep -qF "$IP" "$F"; then die "页面里有服务器 IP，不上传"; fi
fi
# 写成 PRIVATE[ ]KEY：匹配的内容一样，脚本自己不会被提交前的密钥检查当成私钥。
if grep -qE 'sk-[A-Za-z0-9]{20,}|PRIVATE[ ]KEY|AKIA[0-9A-Z]{16}' "$F"; then die "页面里有疑似密钥，不上传"; fi
ZIP_URL="$(grep -oE 'https://[^"]+/Biandan-[0-9.]+\.zip' "$F" | head -1)"
[ -n "$ZIP_URL" ] || die "页面里没有下载链接"
code="$(curl -s -o /dev/null -w '%{http_code}' -r 0-0 "$ZIP_URL" || echo 000)"
case "$code" in
    200|206) echo "下载链接可以访问：${ZIP_URL##*/}" ;;
    *) die "下载链接 ${ZIP_URL##*/} 返回 ${code}，不上传（先把更新包传上去）" ;;
esac
SHA="$(shasum -a 256 "$F" | cut -d' ' -f1)"

if [ "$DRY" = 1 ]; then
    echo "（--dry-run：没有上传）"
    exit 0
fi

echo "==> 上传到 ${HOST}:${REMOTE_DIR}"
TS="$(date +%Y%m%d-%H%M%S)"
scp -q "${SSHO[@]}" "$F" "${HOST}:/tmp/biandan-site-index.${TS}.html"
scp -q "${SSHO[@]}" "$ICON" "${HOST}:/tmp/biandan-site-icon.${TS}.png"
if [ "$HAS_DEMO" = 1 ]; then scp -q "${SSHO[@]}" "$DEMO" "${HOST}:/tmp/biandan-site-demo.${TS}.gif"; fi
REMOTE_SHA="$(ssh "${SSHO[@]}" "$HOST" bash -s "$TS" "$REMOTE_DIR" "$SITE_HOST" "$HAS_DEMO" <<'REMOTE'
set -e
TS=$1
D=$2
H=$3
DEMO=$4
mkdir -p /root/nginx-backup "$D"
for f in index.html icon-256.png install.gif; do
    if [ -f "$D/$f" ]; then cp -p "$D/$f" "/root/nginx-backup/biandan-mac-$f.$TS"; fi
done
install -m 644 -o root -g root "/tmp/biandan-site-index.$TS.html" "$D/index.html"
install -m 644 -o root -g root "/tmp/biandan-site-icon.$TS.png" "$D/icon-256.png"
rm -f "/tmp/biandan-site-index.$TS.html" "/tmp/biandan-site-icon.$TS.png"
if [ "$DEMO" = 1 ]; then
    install -m 644 -o root -g root "/tmp/biandan-site-demo.$TS.gif" "$D/install.gif"
    rm -f "/tmp/biandan-site-demo.$TS.gif"
fi
# 从服务器本机访问源站，核对 nginx 返回的就是刚传的文件
curl -sk --resolve "$H:443:127.0.0.1" "https://$H/biandan/mac/" | sha256sum | cut -d' ' -f1
REMOTE
)"
[ "$REMOTE_SHA" = "$SHA" ] || die "源站返回的页面和本地不一致"
echo "==> 源站页面和本地一致（备份在 /root/nginx-backup/biandan-mac-*.${TS}）"

PUB_SHA="$(curl -s "$SITE_URL" | shasum -a 256 | cut -d' ' -f1)"
if [ "$PUB_SHA" = "$SHA" ]; then
    echo "==> 公网页面已经是新的：${SITE_URL}"
else
    echo "==> 公网暂时还是旧页面（ESA 缓存最多 1 小时，急的话在 ESA 控制台刷新 /biandan/mac/）：${SITE_URL}"
fi
echo "完成。"
