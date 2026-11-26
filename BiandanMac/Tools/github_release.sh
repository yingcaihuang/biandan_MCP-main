#!/bin/bash
# 给已经推送的 vX.Y.Z 建 GitHub Release：标题「便单 Mac X.Y.Z」，附上 dist/Biandan-X.Y.Z.zip。
# 说明依次是：一句升级提示、CHANGELOG 里这一版的内容（同 tag 说明，来自 Tools/tag_release.sh）、安装包的 SHA-256。
#
# 用法（在 BiandanMac 目录）：Tools/github_release.sh <X.Y.Z> [--channel beta] [--dry-run]
#   --channel <名>  测试版：标为预发布，不设为 Latest
#   --dry-run       只打印说明，不建 Release
# 通常不用单独运行：Tools/release.sh 推送 tag 后会自动调用。Release 已经存在时跳过，不覆盖。
# 需要 gh 并已登录（gh auth login）。
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
cd "$HERE"

VERSION=""
CHANNEL=""
DRY_RUN=0
while [ $# -gt 0 ]; do
    case "$1" in
        --channel) CHANNEL="${2:?--channel 后面要写渠道名，例如 beta}"; shift ;;
        --dry-run) DRY_RUN=1 ;;
        -h|--help) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) echo "未知参数：${1}" >&2; exit 2 ;;
        *) VERSION="$1" ;;
    esac
    shift
done
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "用法：$0 <X.Y.Z> [--channel beta] [--dry-run]" >&2; exit 2; }
TAG="v${VERSION}"
ZIP="$HERE/dist/Biandan-${VERSION}.zip"

die() { echo "✗ $*" >&2; exit 1; }

REPO="$(git remote get-url origin | sed -E 's#^(https://github\.com/|git@github\.com:)##; s#\.git$##')"
[[ "$REPO" == */* ]] || die "认不出 origin 对应的 GitHub 仓库：$(git remote get-url origin)"
[ -f "$ZIP" ] || die "找不到安装包 ${ZIP}"
SHA="$(shasum -a 256 "$ZIP" | awk '{print $1}')"
if [ -f "${ZIP}.sha256" ] && [ "$SHA" != "$(awk '{print $1}' "${ZIP}.sha256")" ]; then
    die "${ZIP} 和它的 .sha256 对不上"
fi

# 升级提示：从 1.3.0（第一个带自动更新的版本）到上一个正式版的，会在 App 里自动收到。
PREV="$(git tag -l 'v[0-9]*.[0-9]*.[0-9]*' --sort=-v:refname | grep -vx "$TAG" | head -1 | sed 's/^v//')"
if [ -n "$PREV" ] && [ "$PREV" != "1.3.0" ]; then
    INTRO="装了 1.3.0 到 ${PREV} 的会在 App 里自动收到这次更新；还在用 1.2.0 或更早版本的需要手动下载安装一次。"
else
    INTRO="装了 1.3.0 的会在 App 里自动收到这次更新；还在用 1.2.0 或更早版本的需要手动下载安装一次。"
fi
[ -n "$CHANNEL" ] && INTRO="这是 ${CHANNEL} 测试版，只有在「设置 → 关于」里打开了「接收测试版」的人会自动收到。"

NOTES="$(mktemp)"
trap 'rm -f "${NOTES:?}"' EXIT
{
    echo "> ${INTRO}"
    echo
    "$HERE/Tools/tag_release.sh" "$VERSION" --dry-run | sed '1d'
    echo
    echo
    echo "SHA-256（Biandan-${VERSION}.zip）：${SHA}"
} > "$NOTES"

if [ "$DRY_RUN" = 1 ]; then
    echo "仓库：${REPO}，标题：便单 Mac ${VERSION}${CHANNEL:+（预发布）}，附件：$(basename "$ZIP")"
    echo "--- 说明"
    cat "$NOTES"
    exit 0
fi

command -v gh >/dev/null 2>&1 || die "没有 gh 命令（brew install gh，再 gh auth login）"
gh auth status >/dev/null 2>&1 || die "gh 没有登录（gh auth login）"
git ls-remote --exit-code --tags origin "refs/tags/${TAG}" >/dev/null 2>&1 || die "GitHub 上还没有 ${TAG}，先推送 tag"
if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
    echo "GitHub Release ${TAG} 已经存在，不覆盖：https://github.com/${REPO}/releases/tag/${TAG}"
    exit 0
fi

FLAGS=(--latest=true)
[ -n "$CHANNEL" ] && FLAGS=(--prerelease --latest=false)
gh release create "$TAG" "$ZIP" --repo "$REPO" --verify-tag --title "便单 Mac ${VERSION}" \
    --notes-file "$NOTES" "${FLAGS[@]}" >/dev/null
ASSET="$(gh release view "$TAG" --repo "$REPO" --json assets --jq '.assets[0].size' 2>/dev/null || echo 0)"
[ "$ASSET" = "$(stat -f %z "$ZIP")" ] || die "Release 建好了，但附件大小（${ASSET}）和本地不一致，去网页上检查"
echo "已建 GitHub Release：https://github.com/${REPO}/releases/tag/${TAG}${CHANNEL:+（预发布）}"
