#!/usr/bin/env python3
"""CHANGELOG.md 的解析和渲染：介绍页（site_page.py）和更新窗口说明（changelog_html.py）共用。只用标准库。

写法约定：
- 每个版本以「## [X.Y.Z] - YYYY-MM-DD」开头，也可以写到时刻「YYYY-MM-DD HH:MM」；
  没写时刻时用 git tag vX.Y.Z 的创建时间，同一天发了好几版也能看出先后。
- 版本下按「### 新功能」「### 改进」「### 修复」分组，各有颜色和图标。
- 每条写成「- **标题**：说明」。标题单独一行；说明里用「；」或「。」分开的几句拆成分行要点
  （括号、引号里的不拆）。也可以直接写缩进的子条目，这时说明照原样显示。
"""
import html
import re
import subprocess

# 分组名 → (CSS 类名, 图标)，显示顺序也按这里。
KINDS = {
    "新功能": ("new", "✨"),
    "改进": ("improve", "🛠️"),
    "修复": ("fix", "🐞"),
}

_OPEN = "（(「『“‘[【"
_CLOSE = "）)」』”’]】"
_HEAD = re.compile(r"^## \[([^\]]+)\](?:\s*-\s*(\d{4}-\d{2}-\d{2})(?:[ T](\d{1,2}:\d{2}))?)?")
_BULLET = re.compile(r"^(\s*)[-*]\s+(.*)$")
_ITEM = re.compile(r"^\*\*(.+?)\*\*\s*[：:]\s*(.+)$")


def esc(text):
    return html.escape(text, quote=True)


def inline(text, links=True):
    text = html.escape(text, quote=False)
    text = re.sub(r"`([^`]+)`", r"<code>\1</code>", text)
    text = re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", text)
    if links:
        text = re.sub(r"\[([^\]]+)\]\((https?://[^)\s]+)\)", r'<a href="\2">\1</a>', text)
    return text


def versions(text, keep_empty=False):
    """按「## [版本]」切开，返回 [{version, date, time, lines}]，最新的在前；不含 Unreleased。"""
    out, cur = [], None
    for line in text.splitlines():
        m = _HEAD.match(line)
        if m:
            cur = {"version": m.group(1), "date": m.group(2) or "", "time": m.group(3) or "", "lines": []}
            out.append(cur)
            continue
        if line.startswith("## "):
            cur = None
            continue
        if cur is not None:
            cur["lines"].append(line)
    return [v for v in out
            if v["version"] != "Unreleased" and (keep_empty or any(l.strip() for l in v["lines"]))]


def tag_times(repo):
    """git tag vX.Y.Z 的创建时间：{版本: (日期, 时:分)}。拿不到时返回空字典。"""
    try:
        result = subprocess.run(["git", "for-each-ref", "--format=%(refname:short)|%(creatordate:iso8601)",
                                 "refs/tags"], cwd=str(repo), capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.SubprocessError):
        return {}
    times = {}
    for line in result.stdout.splitlines():
        name, _, stamp = line.partition("|")
        tag = re.match(r"^v(\d+\.\d+\.\d+\S*)$", name)
        at = re.match(r"^(\d{4}-\d{2}-\d{2}) (\d{2}:\d{2})", stamp)
        if tag and at:
            times[tag.group(1)] = (at.group(1), at.group(2))
    return times


def when(item, times):
    """(日期, 时刻)：CHANGELOG 里写了时刻优先，其次 git tag 的时间；都没有时只有日期。"""
    date, clock = item.get("date", ""), item.get("time", "")
    if not clock and item["version"] in times:
        tag_date, tag_clock = times[item["version"]]
        if not date or date == tag_date:
            date, clock = tag_date, tag_clock
    return date, clock


def kind_badges(lines):
    """版本标题旁的分组小标签，例如「✨ 新功能 1」「🐞 修复 2」。"""
    counts, kind = {}, None
    for raw in lines:
        h = re.match(r"^###\s+(.*)$", raw)
        if h:
            title = h.group(1).strip()
            kind = title if title in KINDS else None
            continue
        if kind and re.match(r"^[-*]\s+", raw):
            counts[kind] = counts.get(kind, 0) + 1
    return "".join(f'<span class="kpill k-{KINDS[k][0]}">{KINDS[k][1]} {esc(k)} {counts[k]}</span>'
                   for k in KINDS if k in counts)


def split_points(text):
    """按「；」「。」拆成要点；括号、引号、代码里的不拆。"""
    parts, buf, depth, code = [], [], 0, False
    for ch in text:
        if ch == "`":
            code = not code
        elif not code:
            if ch in _OPEN:
                depth += 1
            elif ch in _CLOSE:
                depth = max(depth - 1, 0)
            elif ch in "；。" and depth == 0:
                piece = "".join(buf).strip()
                if piece:
                    parts.append(piece)
                buf = []
                continue
        buf.append(ch)
    piece = "".join(buf).strip()
    if piece:
        parts.append(piece)
    return parts


def item_html(text, links=True, has_children=False):
    """「**标题**：说明」→ 标题单独一行，说明拆成分行要点；其他写法原样显示。"""
    m = _ITEM.match(text)
    if not m:
        return inline(text, links)
    title, rest = m.group(1), m.group(2).strip()
    head = f'<div class="ci-title">{inline(title, links)}</div>'
    points = [] if has_children else split_points(rest)
    if len(points) < 2:
        return head + f'<div class="ci-desc">{inline(rest, links)}</div>'
    return head + '<ul class="ci-points">' + "".join(f"<li>{inline(p, links)}</li>" for p in points) + "</ul>"


def render(lines, skip=None, links=True):
    """一个版本的正文。截图和「（以上…）」说明不放进去；skip 是已经放在标题里的那句概述。"""
    out, stack = [], []

    def close_to(level):
        while stack and stack[-1] > level:
            stack.pop()
            out.append("</li></ul>")

    def children_follow(index, indent):
        for later in lines[index + 1:]:
            if not later.strip():
                continue
            b = _BULLET.match(later)
            return bool(b) and len(b.group(1).replace("\t", "  ")) > indent
        return False

    for index, raw in enumerate(lines):
        s = raw.strip()
        if not s or s == skip:
            continue
        if s.startswith("![") or re.fullmatch(r"（以上.*）", s):
            continue
        indent = len(raw) - len(raw.lstrip(" "))
        h = re.match(r"^(#{3,4})\s+(.*)$", raw)
        if h:
            close_to(-1)
            title = h.group(2).strip()
            if len(h.group(1)) == 4:
                out.append(f"<h5>{inline(title, links)}</h5>")
            elif title in KINDS:
                cls, icon = KINDS[title]
                out.append(f'<h4 class="kind kind-{cls}"><span class="ki">{icon}</span>{esc(title)}</h4>')
            else:
                out.append(f"<h4>{inline(title, links)}</h4>")
            continue
        b = _BULLET.match(raw)
        if b:
            n = len(b.group(1).replace("\t", "  "))
            close_to(n)
            if stack and stack[-1] == n:
                out.append("</li><li>")
            else:
                out.append('<ul class="ci"><li>' if not stack else "<ul><li>")
                stack.append(n)
            out.append(item_html(b.group(2), links, children_follow(index, n)))
            continue
        if stack and indent > 0:
            close_to(indent - 1)
            out.append(f"<p>{inline(s, links)}</p>")
            continue
        close_to(-1)
        out.append(f"<p>{inline(s, links)}</p>")
    close_to(-1)
    return "".join(out)
