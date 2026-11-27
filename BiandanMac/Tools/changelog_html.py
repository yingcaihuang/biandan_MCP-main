#!/usr/bin/env python3
"""从 CHANGELOG.md 取出某个版本的说明，生成 Sparkle 更新窗口里显示的 HTML 更新说明。只用标准库。

用法：Tools/changelog_html.py <版本号> [CHANGELOG 路径] > Biandan-<版本号>.html
解析和渲染和介绍页共用 Tools/changelog_render.py：按新功能 / 改进 / 修复分组标色，每条标题单独一行，
说明拆成分行要点，顶部写发布日期和时刻（取 git tag 的时间）。截图和截图说明不放进更新说明。
"""
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import changelog_render as cr  # noqa: E402

STYLE = """
body { font: 13px -apple-system, "PingFang SC", sans-serif; line-height: 1.55; margin: 10px 16px; color: #2b2720; }
.meta { margin: 2px 0 8px; font-size: 12px; color: #8a8273; }
.meta b { color: #2b2720; font-variant-numeric: tabular-nums; }
h4 { font-size: 13px; margin: 14px 0 4px; }
h4.kind { display: inline-block; padding: 2px 10px; border-radius: 999px; font-size: 12.5px; }
h4.kind .ki { margin-right: 4px; }
h4.kind-new { color: #2e7d32; background: #e6f4e4; }
h4.kind-improve { color: #1565a8; background: #e3f0fa; }
h4.kind-fix { color: #b3261e; background: #fce6e4; }
h5 { font-size: 13px; margin: 10px 0 4px; color: #a87400; }
p { margin: 6px 0; }
ul { margin: 4px 0; padding-left: 20px; }
li { margin: 2px 0; }
ul.ci { list-style: none; padding-left: 0; }
ul.ci > li { margin: 8px 0; padding: 4px 10px; border-left: 3px solid #e6dfcf; }
h4.kind-new + ul.ci > li { border-left-color: #5db65a; }
h4.kind-improve + ul.ci > li { border-left-color: #4ba9e0; }
h4.kind-fix + ul.ci > li { border-left-color: #e5483a; }
.ci-title { font-weight: 700; }
.ci-desc, ul.ci-points li { color: #5e574b; }
.ci-desc { margin-top: 2px; }
ul.ci-points { margin: 3px 0 0; padding-left: 18px; }
code { font: 12px ui-monospace, Menlo, monospace; background: rgba(0, 0, 0, .06); padding: 0 3px; border-radius: 3px; }
@media (prefers-color-scheme: dark) {
  body, .meta b { color: #ebe6dc; }
  .ci-desc, ul.ci-points li { color: #c9c2b4; }
  h5 { color: #f5c542; }
  h4.kind-new { color: #8fd88b; background: rgba(93, 182, 90, .18); }
  h4.kind-improve { color: #8cc8f0; background: rgba(75, 169, 224, .18); }
  h4.kind-fix { color: #f29b92; background: rgba(229, 72, 58, .18); }
  ul.ci > li { border-left-color: #4a453c; }
  code { background: rgba(255, 255, 255, .12); }
}
"""


def main():
    if len(sys.argv) < 2:
        raise SystemExit("用法：Tools/changelog_html.py <版本号> [CHANGELOG 路径]")
    version = sys.argv[1]
    if len(sys.argv) > 2:
        path = pathlib.Path(sys.argv[2])
    else:
        path = pathlib.Path(__file__).resolve().parent.parent / "CHANGELOG.md"
    items = cr.versions(path.read_text(encoding="utf-8"), keep_empty=True)
    item = next((v for v in items if v["version"] == version), None)
    if item is None:
        raise SystemExit("CHANGELOG.md 里没有 ## [" + version + "] 这一节")
    day, clock = cr.when(item, cr.tag_times(path.resolve().parent))
    meta = ""
    if day:
        meta = ('<p class="meta">v' + cr.esc(version) + " · " + cr.esc(day)
                + (" <b>" + cr.esc(clock) + "</b>" if clock else "") + " 发布</p>\n")
    content = cr.render(item["lines"], links=False)
    sys.stdout.write('<!DOCTYPE html>\n<html lang="zh-CN"><head><meta charset="utf-8"><title>便单 ' + version
                     + '</title><style>' + STYLE + '</style></head>\n<body>\n' + meta + content + '\n</body></html>\n')


if __name__ == "__main__":
    main()
