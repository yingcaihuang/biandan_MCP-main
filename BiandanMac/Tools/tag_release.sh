#!/bin/bash
# 从 CHANGELOG.md 取出某个版本的说明，打带说明的 git tag（vX.Y.Z）。
#
# 用法：Tools/tag_release.sh <版本号> [--dry-run] [--push]
#   --dry-run  只打印 tag 说明，不打 tag
#   --push     打完后推送当前分支和这个 tag 到 origin
#
# 约定：CHANGELOG.md 里每个版本以「## [X.Y.Z]」开头；tag 说明里去掉截图，
#       末尾附上这个 tag 下 CHANGELOG 的链接，截图在那里看。
set -euo pipefail

VERSION="${1:-}"
shift || true
DRY_RUN=0
PUSH=0
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        --push) PUSH=1 ;;
        *) echo "未知参数：$arg" >&2; exit 2 ;;
    esac
done
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "用法：$0 <X.Y.Z> [--dry-run] [--push]" >&2; exit 2; }

HERE="$(cd "$(dirname "$0")/.." && pwd)"
CHANGELOG="$HERE/CHANGELOG.md"
TAG="v$VERSION"
REPO_ROOT="$(git -C "$HERE" rev-parse --show-toplevel)"
REL="${HERE#"$REPO_ROOT"/}"

# 取出「## [VERSION]」到下一个「## 」之间的内容。
SECTION="$(awk -v v="$VERSION" '
    index($0, "## [" v "]") == 1 { found = 1; next }
    found && /^## / { exit }
    found { print }
' "$CHANGELOG")"
[ -n "$(echo "$SECTION" | tr -d '[:space:]')" ] || { echo "CHANGELOG.md 里没有 ## [$VERSION] 这一节" >&2; exit 1; }

# 去掉截图和截图说明，「### 新功能」改成「新功能」，去掉粗体标记，合并多余空行。
BODY="$(echo "$SECTION" \
    | grep -vE '^[[:space:]]*!\[|^[[:space:]]*（以上.*渲染图）' \
    | sed -E 's/^#{2,6} //; s/\*\*//g' \
    | cat -s \
    | sed -e '/./,$!d')"

URL=""
ORIGIN="$(git -C "$HERE" remote get-url origin 2>/dev/null || true)"
if [[ "$ORIGIN" =~ github\.com[:/](.+)$ ]]; then
    SLUG="${BASH_REMATCH[1]%.git}"
    URL="https://github.com/$SLUG/blob/$TAG/$REL/CHANGELOG.md"
fi

MESSAGE="BiandanMac $TAG

$BODY

完整说明与截图：${URL:-$REL/CHANGELOG.md}"

if [ "$DRY_RUN" = 1 ]; then
    echo "$MESSAGE"
    exit 0
fi

git -C "$HERE" diff --quiet && git -C "$HERE" diff --cached --quiet \
    || { echo "工作区有未提交的修改，先提交再打 tag" >&2; exit 1; }
if git -C "$HERE" rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
    echo "tag $TAG 已经存在" >&2; exit 1
fi
grep -q "^DEFAULT_VERSION=\"$VERSION\"" "$HERE/Tools/build_app.sh" \
    || echo "提醒：Tools/build_app.sh 的默认版本号不是 $VERSION" >&2

echo "$MESSAGE" | git -C "$HERE" tag -a "$TAG" -F -
echo "已打 tag ${TAG}（$(git -C "$HERE" rev-parse --short "${TAG}^{commit}")）"

if [ "$PUSH" = 1 ]; then
    BRANCH="$(git -C "$HERE" branch --show-current)"
    git -C "$HERE" push origin "$BRANCH"
    git -C "$HERE" push origin "$TAG"
    echo "已推送 $BRANCH 和 $TAG"
fi
