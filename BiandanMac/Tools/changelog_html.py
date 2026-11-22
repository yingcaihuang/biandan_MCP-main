#!/usr/bin/env python3
"""从 CHANGELOG.md 取出某个版本的说明，生成 Sparkle 更新窗口里显示的 HTML 更新说明。只用标准库。

用法：Tools/changelog_html.py <版本号> [CHANGELOG 路径] > Biandan-<版本号>.html
约定和 Tools/tag_release.sh 一样：每个版本以「## [X.Y.Z]」开头；截图和截图说明不放进更新说明。
"""
import html
import pathlib
import re
import sys


def section(text, version):
    out = []
    found = False
    for line in text.splitlines():
        if line.startswith("## [" + version + "]"):
            found = True
            continue
        if found and line.startswith("## "):
            break
        if found:
            out.append(line)
    if not found:
        raise SystemExit("CHANGELOG.md 里没有 ## [" + version + "] 这一节")
    return out


def inline(text):
    text = html.escape(text, quote=False)
    text = re.sub(r"`([^`]+)`", r"<code>\1</code>", text)
    text = re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", text)
    return text


def render(lines):
    body = []
    depth = 0

    def close(level):
        nonlocal depth
        while depth > level:
            body.append("</li></ul>")
            depth -= 1

    for raw in lines:
        if re.match(r"^\s*!\[", raw) or re.match(r"^\s*（以上.*渲染图）", raw):
            continue
        item = re.match(r"^(\s*)[-*] (.*)$", raw)
        if item:
            level = len(item.group(1).replace("\t", "  ")) // 2 + 1
            if level > depth:
                while depth < level:
                    body.append("<ul><li>")
                    depth += 1
            else:
                close(level)
                body.append("</li><li>")
            body.append(inline(item.group(2)))
            continue
        line = raw.strip()
        close(0)
        if not line:
            continue
        heading = re.match(r"^(#{3,6}) (.*)$", line)
        if heading:
            tag = "h3" if len(heading.group(1)) == 3 else "h4"
            body.append("<" + tag + ">" + inline(heading.group(2)) + "</" + tag + ">")
        else:
            body.append("<p>" + inline(line) + "</p>")
    close(0)
    return "\n".join(body)


STYLE = """
body { font: 13px -apple-system, "PingFang SC", sans-serif; line-height: 1.55; margin: 10px 16px; color: #2b2720; }
h3 { font-size: 14px; margin: 16px 0 6px; }
h4 { font-size: 13px; margin: 12px 0 4px; color: #a87400; }
p { margin: 6px 0; }
ul { margin: 4px 0; padding-left: 20px; }
li { margin: 2px 0; }
code { font: 12px ui-monospace, Menlo, monospace; background: rgba(0, 0, 0, .06); padding: 0 3px; border-radius: 3px; }
@media (prefers-color-scheme: dark) {
  body { color: #ebe6dc; }
  h4 { color: #f5c542; }
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
    content = render(section(path.read_text(encoding="utf-8"), version))
    sys.stdout.write('<!DOCTYPE html>\n<html lang="zh-CN"><head><meta charset="utf-8"><title>便单 ' + version
                     + '</title><style>' + STYLE + '</style></head>\n<body>\n' + content + '\n</body></html>\n')


if __name__ == "__main__":
    main()
