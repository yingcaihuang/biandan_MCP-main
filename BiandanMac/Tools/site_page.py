#!/usr/bin/env python3
"""生成便单 Mac 版的功能介绍页：dist/site/index.html 和 dist/site/icon-256.png。只用标准库（图标用 macOS 自带的 sips 缩放）。

用法（在 BiandanMac 目录）：python3 Tools/site_page.py
页面放在 https://www.aigslb.link/biandan/mac/ 。
- 功能总览在下面的 FEATURES 里，按大类写，写的是现在的功能（不是某一版的改动）；加了新功能记得同步改这里。
- 「更新记录」从 CHANGELOG.md 生成，截图和截图说明不放进去。
- 下载按钮先写死成 CHANGELOG 里最新的版本；页面打开后读同一站点的 appcast.xml，有更新的正式版就换成它（测试版不算）。
"""
import datetime
import hashlib
import html
import pathlib
import re
import subprocess
import sys

HERE = pathlib.Path(__file__).resolve().parent.parent
OUT = HERE / "dist" / "site"
UPDATE_BASE = "https://www.aigslb.link/biandan/mac/update"
APPCAST_PATH = "/biandan/mac/update/appcast.xml"
RELEASES = "https://github.com/yingcaihuang/biandan_MCP-main/releases"

# (id, 图标, 颜色, 标题, 一句话, [(功能, 说明)])
FEATURES = [
    ("views", "🗂️", "#F5B800", "任务与视图", "列表、四象限、日历，换个角度看同一份日程", [
        ("三种视图", "列表按待办 / 已过期 / 已完成分组；四象限按重要、紧急分四格，选中任务时所在象限高亮；日历有日、周、月、年视图。"),
        ("日、周时间轴", "按小时刻度排日程块，高度和时长成正比，哪段有事一眼看出；重叠的并排或错开，今天有一条「现在」红线，没有时刻的放在「全天」一栏。"),
        ("侧栏视图", "逾期、今天、近 7 天、全部待办、重要待办、四象限、日历、日程冲突、无日期、收藏、已完成、已放弃，数字实时更新。"),
        ("逾期集中处理", "结束日期早于今天、没完成也没放弃的日程都在「逾期」里，可以完成、放弃、改日期或拖到「今天」；其他视图不再混着显示。"),
        ("今日进度", "问候卡片带完成率圆环（今天 / 近 7 天 / 本月），下面的时间条今天按 0–24 点天色渐变，近 7 天 / 本月按日期标注任务。"),
        ("分类", "自定义分类和颜色，完成圆圈可以用分类颜色。"),
        ("检查器", "右侧编辑标题与备注、时间、时间提醒、地点（地图选点）、完成目标和重复规则；备注框随内容变高，网址和邮箱能直接点。"),
        ("编辑不丢", "自动同步拉到新版本时，你正在改、还没保存的分区保留你的修改。"),
    ]),
    ("capture", "✍️", "#F08A24", "快速记录", "一句话写完，回车就记上", [
        ("快速添加栏", "「后天下午1点跟腾讯开会」「每周一三五 9:00 晨会 @工作 #重要」：认识日期、时刻、时间段、重复、分类、习惯和四象限标记；鼠标移到 ＋ 上看写法说明。"),
        ("AI 整理", "回车后先让 AI 把这句话整理成标题、日期、时刻、地点和四象限，写得随意也能记规范；自己写的 @分类、#重要、#紧急 优先。AI 不可用时按本机规则照常添加。"),
        ("全局快速添加", "在任何 App 里按 ⌃⌥N 弹出输入框，不抢焦点，回车保存，Esc 关闭；快捷键可以改。"),
        ("冲突提前提示", "回车前就用红字提示会和哪项日程撞时间。"),
        ("新建任务面板", "默认开提醒，可以选象限、分类、重复规则和提醒时刻。"),
    ]),
    ("recognize", "🔮", "#E5483A", "识别日程", "桌面浮窗球，从聊天和截图里把日程抓出来", [
        ("桌面浮窗球", "可以拖动、吸附屏幕边缘，全屏应用里也看得到，点它不抢焦点：单击框选聊天区域，双击截所在屏幕，右键还能识别剪贴板；也可以把文字或截图直接拖到球上。"),
        ("本机识别", "用 Apple Vision 识别简繁中文和英文，截图只在内存里处理，不存盘、不上传；macOS 26 开启 Apple 智能时用端侧模型，否则用规则识别。"),
        ("规则识别", "从整句里找出日期、时刻、时长、时间段、模糊日期（「12月中旬」「下个月初」）和地点；一句话里的几件事拆成几条，聊天里的「昨天 14:32」按消息日期换算。"),
        ("AI 兜底（DeepSeek）", "本机没找到时只把识别出的文字交给 AI 提取，不发截图；也可以设成总是用 AI，卡片上能手动重跑。"),
        ("AI 决策", "调用大模型前先用阿里云百炼的决策模型判断有没有日程，没有就不调用，省钱也省时间；三档灵敏度，误拦时可以一键「仍然用 AI 识别」。"),
        ("确认卡片", "每条可以改标题、日期、时刻、象限、分类和地点；拿不准的字段整行标黄，写明文字发给了谁，显示识别过程和用时，时间冲突标红，还能把候选拖到日历上定日期。"),
        ("自动分类与定位", "按情景词归到已有分类或 13 个内置常用分类；识别出的地点用 Apple 地图查坐标；原文里的「务必」「尽快」「不急」自动对应到象限。"),
    ]),
    ("remind", "🔔", "#4BA9E0", "提醒", "到点提醒，没处理就再提醒", [
        ("默认开提醒", "有时刻的按开始时刻提醒，没有时刻的当天 9:00 提醒；新建时可以关掉。"),
        ("追加提醒", "第 1 次提醒后没完成、没放弃、没改期，15 分钟后再提醒一次，再过 1 小时提醒最后一次。"),
        ("通知上直接处理", "完成、放弃本次、10 分钟后提醒、1 小时后提醒；点通知打开便单并定位到这条日程。"),
        ("睡眠补发", "电脑睡眠期间错过的提醒，醒来后补发一次。"),
        ("自定义提醒声音", "系统默认、系统音效，或用 MiniMax 把一句话念出来：第 1 次、第 2 次、最后一次各说一句，可以播报时间和标题，按四象限设不同音色、语速和提示音，还能让 AI 按正式、轻松、幽默、温柔写文案，每处都能试听。"),
    ]),
    ("conflict", "⚠️", "#D93025", "日程冲突", "时间撞在一起，提前看见", [
        ("冲突页", "侧栏「日程冲突」列出 30 天内时间交叉的待办，全天、首尾相接、已过去的不算；有冲突时图标和数字变红。"),
        ("卡片标记", "列表、四象限、日历的卡片右上角显示「⚠︎ 冲突」，鼠标移上去看和谁冲突、重叠多久，点一下直接跳过去。"),
        ("时间条斜纹", "完成率卡片下的时间条上，重叠的时段或日期铺红色斜纹，冲突任务的圆点套红环。"),
    ]),
    ("import", "📥", "#5DB65A", "导入日程", "把外部日历搬进便单，定时同步", [
        ("四种导入方式", "CalDAV（内置钉钉、飞书、企业微信、腾讯会议、iCloud 预设）、订阅地址（webcal / .ics）、Mac「互联网账户」里的 Exchange、Google、QQ、163 等日历，以及 .ics 文件（先预览，逐条勾选）。"),
        ("导入规则", "全天、定时、跨天日程都支持，时区自动换算；地点、坐标、备注、链接一并带过来，简单的重复转成便单重复任务；只单向导入，不会写回原日历。"),
        ("定时同步", "间隔 5 分钟到 3 小时或仅手动；只更新改过的日程，外部取消或删除的标为放弃，不直接删。"),
        ("日志、通知与退避", "每次同步都记一条日志；失败、被暂停、恢复时各发一条通知；连续失败自动放慢间隔，失败 8 次自动暂停。"),
        ("编辑来源", "改名称、换分类（已导入的可以一起搬过去）、暂停或恢复、改地址和密码；密码只存在这台 Mac 的钥匙串里。"),
    ]),
    ("menubar", "🖥️", "#8A6BD1", "菜单栏与窗口", "不打开主窗口，也知道下一件事", [
        ("菜单栏面板", "第一屏只说「现在该做什么、还剩多久」：进行中的日程显示剩余时间和进度条，下一场显示倒计时，底部常驻快速添加框。"),
        ("菜单栏倒计时", "图标旁显示「设计评审 · 8 分钟后」或「剩 25 分钟」，只看今天的定时日程。"),
        ("隐藏 Dock 图标", "打开后只留菜单栏图标。"),
        ("桌面小组件", "「便单 · 今天」小、中、大三种尺寸：今天几项、下一场（进行中显示到几点）和逾期数，大号还列出明天的；到点自动切换，点某一条打开便单定位到它。"),
        ("「服务」菜单", "在任何 App 里选中文字或图片，右键 → 服务 →「用便单识别日程」，弹出和浮窗球一样的确认卡片。"),
        ("Spotlight 搜索", "⌘空格搜日程标题或分类，没完成的日程都能找到，点一下打开便单定位到这条；索引只在本机。"),
        ("快捷指令与 Siri", "「快捷指令」App 里有添加日程、今天还有什么、完成日程、识别剪贴板里的日程、在便单里打开日程 5 个指令，也可以对 Siri 说「用便单添加日程」。"),
        ("窗口置顶", "工具栏图钉或 ⌥⌘P，让主窗口浮在其他窗口之上。"),
        ("液态玻璃", "macOS 26 起，浮在内容上面的控件改用系统液态玻璃，带一点暖米色。"),
    ]),
    ("batch", "⚡️", "#E9BC12", "批量与快捷操作", "少点几下，多做几件", [
        ("批量选择", "所有视图都有「选择」按钮，⇧ 点击连选，⌘ 点击多选；底部操作栏可以完成、放弃、改期、移动、删除，整批 ⌘Z 一次撤回。"),
        ("卡片快捷操作", "鼠标移到卡片上，右下角浮出改期、分类、象限、收藏按钮。"),
        ("拖到侧栏", "拖到「今天」改期，拖到「无日期」清日期，拖到「收藏」「重要待办」或某个分类直接归类。"),
        ("键盘操作", "↑↓ 切换选中，空格完成，⌫ 删除，回车编辑标题，⌘A 全选，Esc 取消多选。"),
    ]),
    ("focus", "🍅", "#E5483A", "习惯与专注", "养成习惯，留下专注记录", [
        ("习惯打卡", "今日打卡、按周期计算的连续次数、最长连续和打卡记录。"),
        ("番茄钟", "工具栏一键开始，可以关联选中的任务，能暂停、提前结束或放弃；结束后自动补记一条专注记录。"),
        ("专注记录", "列表、补记、编辑、按日汇总，和鸿蒙便单同步。"),
    ]),
    ("stats", "📊", "#4BA9E0", "统计", "完成得怎样，AI 花了多少，一目了然", [
        ("任务统计", "近 7 / 30 / 90 天的完成数、按期完成率、当前逾期、日均完成、专注时长，加上完成趋势和象限、分类分布。"),
        ("AI 识别统计", "调用次数、Token、用时、按官方价目估算的费用，多种图表样式可切换。"),
        ("AI 决策统计", "拦截率、省下的费用、少等的时间、误拦率等 14 项指标和 10 张分布图。"),
        ("导入同步统计", "同步成功率、耗时、写入条数、失败原因和每个来源的健康状况。"),
        ("悬停提示与导出", "所有图表鼠标移上去就显示数值；AI 记录可以导出 CSV。"),
    ]),
    ("data", "🔒", "#5DB65A", "同步、备份与隐私", "数据在你手里", [
        ("云同步", "用便单账号登录，和鸿蒙便单同步；还没写回云端的修改逐条列在「设置 → 同步」里，可以重试或放弃。"),
        ("导出与备份", "完整备份（JSON）、任务明细（CSV）、专注记录（CSV）、日历（ICS）；每天第一次同步后自动在本机备份，保留最近 7 份。"),
        ("隐私", "各类 API Key 和日历密码都存在钥匙串里；截图只在内存里处理；交给 AI 的只有识别出的文字，不含截图。"),
        ("远程日程接口", "打开「设置 → 同步 → 远程日程接口」后，全部日程和分类（含 CalDAV、订阅、系统日历导入的）自动推到服务器，ESP32 等设备用读取密钥按分类、日期查询 JSON。"),
    ]),
    ("update", "🚀", "#F08A24", "自动更新", "新版本自己装好", [
        ("工具栏更新按钮", "发现新版本时带动画显示版本号，下载时显示进度环和百分比，出错时提示「下载异常」，可以重新下载。"),
        ("自动下载并安装", "默认打开：下载完倒计时 60 秒安装并重启，番茄钟计时中会等它结束；增量更新只下载变化的部分。"),
        ("安全", "每个更新包都有 EdDSA 签名、和当前版本同一个 Developer ID 签名，并经过 Apple 公证，对不上不会安装。"),
        ("测试版渠道", "打开「接收测试版」可以提前用上还没正式发布的功能。"),
    ]),
    ("guide", "🧭", "#8A6BD1", "新手指引", "第一次用也不迷路", [
        ("欢迎页与功能导览", "第一次打开有几屏介绍；登录后 12 步高亮讲解侧栏、快速添加、视图切换、导入、统计、浮窗球等。"),
        ("上手清单", "「今天」页顶部的卡片，做完对应操作自动打勾；随时可以从「帮助」菜单重看。"),
    ]),
]


def esc(text):
    return html.escape(text, quote=True)


def inline(text):
    text = html.escape(text, quote=False)
    text = re.sub(r"`([^`]+)`", r"<code>\1</code>", text)
    text = re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", text)
    text = re.sub(r"\[([^\]]+)\]\((https?://[^)\s]+)\)", r'<a href="\2">\1</a>', text)
    return text


def versions(text):
    out, cur = [], None
    for line in text.splitlines():
        m = re.match(r"^## \[([^\]]+)\](?:\s*-\s*(\d{4}-\d{2}-\d{2}))?", line)
        if m:
            cur = {"version": m.group(1), "date": m.group(2) or "", "lines": []}
            out.append(cur)
            continue
        if line.startswith("## "):
            cur = None
            continue
        if cur is not None:
            cur["lines"].append(line)
    return [v for v in out if v["version"] != "Unreleased" and any(l.strip() for l in v["lines"])]


def summary(lines):
    """版本开头那段话（第一个小标题之前的普通段落）。"""
    for line in lines:
        s = line.strip()
        if not s:
            continue
        if s.startswith("#") or s.startswith("-") or s.startswith("!["):
            return None
        return s
    return None


def render(lines, skip=None):
    out, stack = [], []

    def close_to(level):
        while stack and stack[-1] > level:
            stack.pop()
            out.append("</li></ul>")

    for raw in lines:
        s = raw.strip()
        if not s or s == skip:
            continue
        if s.startswith("![") or re.fullmatch(r"（以上.*）", s):
            continue
        indent = len(raw) - len(raw.lstrip(" "))
        h = re.match(r"^(#{3,4})\s+(.*)$", raw)
        if h:
            close_to(-1)
            tag = "h4" if len(h.group(1)) == 3 else "h5"
            out.append(f"<{tag}>{inline(h.group(2))}</{tag}>")
            continue
        b = re.match(r"^(\s*)[-*]\s+(.*)$", raw)
        if b:
            n = len(b.group(1))
            close_to(n)
            if stack and stack[-1] == n:
                out.append("</li><li>")
            else:
                stack.append(n)
                out.append("<ul><li>")
            out.append(inline(b.group(2)))
            continue
        if stack and indent > 0:
            close_to(indent - 1)
            out.append(f"<p>{inline(s)}</p>")
            continue
        close_to(-1)
        out.append(f"<p>{inline(s)}</p>")
    close_to(-1)
    return "".join(out)


def archs():
    folder = HERE / "dist" / "Biandan.app" / "Contents" / "MacOS"
    try:
        exe = next(p for p in folder.iterdir() if p.is_file())
        found = subprocess.run(["lipo", "-archs", str(exe)], capture_output=True, text=True).stdout.split()
    except Exception:
        return ""
    if "arm64" in found and "x86_64" in found:
        return "Apple 芯片和 Intel 芯片"
    if "arm64" in found:
        return "Apple 芯片（M 系列）"
    if "x86_64" in found:
        return "Intel 芯片"
    return ""


def min_macos():
    m = re.search(r"\.macOS\(\.v(\d+)\)", (HERE / "Package.swift").read_text(encoding="utf-8"))
    return f"macOS {m.group(1)} 及以上" if m else "macOS"


def mb(size):
    return f"{size / 1024 / 1024:.1f} MB"


def make_icon():
    OUT.mkdir(parents=True, exist_ok=True)
    target = OUT / "icon-256.png"
    for name in ("Assets/AppIcon-1024.png", "Assets/biandan.png"):
        src = HERE / name
        if src.exists():
            subprocess.run(["sips", "-Z", "256", str(src), "--out", str(target)],
                           check=True, capture_output=True)
            return True
    return False


CSS = r"""
:root{--bg:#F4EFE3;--panel:#FBF8F1;--card:#FFFDF8;--line:#E6DFCF;--text:#1F1D1A;--sub:#8A8273;--field:#B3AA97;
--accent:#F5B800;--orange:#F08A24;--sel:#FFF4CC;--done:#5DB65A;--over:#D93025;--q1:#E5483A;--q2:#E9BC12;--q3:#4BA9E0;--q4:#5DB65A}
*{box-sizing:border-box}
html{scroll-behavior:smooth;scroll-padding-top:72px}
body{margin:0;background:var(--bg);color:var(--text);font:15px/1.65 -apple-system,BlinkMacSystemFont,"PingFang SC","Hiragino Sans GB","Microsoft YaHei",sans-serif;-webkit-font-smoothing:antialiased}
a{color:#B07A00;text-decoration:none}a:hover{text-decoration:underline}
code{font:12.5px/1.4 ui-monospace,SFMono-Regular,Menlo,monospace;background:#F1EADA;border:1px solid var(--line);border-radius:5px;padding:1px 5px}
.wrap{max-width:1120px;margin:0 auto;padding:0 24px}
header.top{position:sticky;top:0;z-index:20;background:rgba(244,239,227,.82);backdrop-filter:saturate(1.6) blur(14px);-webkit-backdrop-filter:saturate(1.6) blur(14px);border-bottom:1px solid rgba(230,223,207,.8)}
header.top .wrap{display:flex;align-items:center;gap:20px;height:60px}
.brand{display:flex;align-items:center;gap:10px;font-weight:800;font-size:17px;color:var(--text)}
.brand img{width:30px;height:30px;border-radius:7px}
.brand:hover{text-decoration:none}
nav.links{display:flex;gap:22px;margin-left:auto;font-size:14px}
nav.links a{color:var(--sub)}nav.links a:hover{color:var(--text);text-decoration:none}
.btn{display:inline-flex;align-items:center;gap:8px;border-radius:12px;padding:12px 22px;font-weight:700;font-size:15.5px;border:1px solid transparent;cursor:pointer;transition:transform .15s,box-shadow .15s,background .15s}
.btn:hover{text-decoration:none;transform:translateY(-1px)}
.btn-primary{background:linear-gradient(135deg,#F5B800,#F08A24);color:#fff;box-shadow:0 8px 22px rgba(240,138,36,.32),inset 0 1px 0 rgba(255,255,255,.35);text-shadow:0 1px 1px rgba(120,60,0,.25)}
.btn-primary:hover{box-shadow:0 12px 28px rgba(240,138,36,.42),inset 0 1px 0 rgba(255,255,255,.35)}
.btn-ghost{background:var(--card);color:var(--text);border-color:var(--line)}
.btn-ghost:hover{background:#fff}
.btn-sm{padding:7px 14px;font-size:13.5px;border-radius:10px}
.hero{position:relative;overflow:hidden;padding:72px 0 64px}
.hero .wrap{position:relative;display:grid;grid-template-columns:1.25fr .75fr;gap:40px;align-items:center}
.eyebrow{display:inline-flex;align-items:center;gap:8px;background:var(--card);border:1px solid var(--line);border-radius:999px;padding:4px 12px 4px 6px;font-size:12.5px;color:var(--sub)}
.eyebrow b{background:var(--sel);color:#8A6300;border-radius:999px;padding:1px 8px;font-weight:700}
h1{font-size:52px;line-height:1.12;margin:18px 0 14px;letter-spacing:-.5px;font-weight:900}
h1 .hl{background:linear-gradient(120deg,#F5B800 10%,#F08A24 60%,#E5483A);-webkit-background-clip:text;background-clip:text;color:transparent}
.lead{font-size:18px;color:#5E574B;max-width:620px;margin:0 0 28px}
.cta{display:flex;flex-wrap:wrap;gap:12px;align-items:center}
.meta{margin-top:16px;font-size:12.5px;color:var(--sub);display:flex;flex-wrap:wrap;gap:6px 16px}
.meta span::before{content:"·";margin-right:16px;color:var(--field)}.meta span:first-child::before{content:none;margin:0}
.stage{position:relative;height:340px;display:grid;place-items:center}
.orb{position:absolute;width:300px;height:300px;border-radius:50%;filter:blur(2px);
background:radial-gradient(circle at 30% 30%,#FFE7A8 0,#F5B800 28%,transparent 60%),radial-gradient(circle at 70% 65%,#FFB38A 0,#F08A24 30%,transparent 62%),radial-gradient(circle at 45% 80%,#FFD3C2 0,#E5483A 22%,transparent 55%);
opacity:.55;animation:float 9s ease-in-out infinite}
.orb.b{width:220px;height:220px;opacity:.35;animation-duration:12s;animation-direction:reverse}
@keyframes float{0%,100%{transform:translate(0,0) rotate(0) scale(1)}33%{transform:translate(18px,-14px) rotate(40deg) scale(1.05)}66%{transform:translate(-16px,12px) rotate(-30deg) scale(.96)}}
.app-icon{position:relative;width:168px;height:168px;border-radius:38px;box-shadow:0 24px 50px rgba(120,80,20,.22);animation:bob 6s ease-in-out infinite}
@keyframes bob{0%,100%{transform:translateY(0)}50%{transform:translateY(-8px)}}
.chip-float{position:absolute;background:var(--card);border:1px solid var(--line);border-radius:12px;padding:7px 12px;font-size:12.5px;box-shadow:0 8px 20px rgba(80,60,20,.08);white-space:nowrap}
.chip-float i{display:inline-block;width:8px;height:8px;border-radius:50%;margin-right:7px;vertical-align:1px}
.cf1{top:34px;left:0}.cf2{bottom:58px;right:-6px}.cf3{bottom:14px;left:22px}
.stats{display:grid;grid-template-columns:repeat(4,1fr);gap:14px;margin:0 0 56px}
.stat{background:var(--card);border:1px solid var(--line);border-radius:16px;padding:16px 18px}
.stat b{display:block;font-size:26px;font-weight:900;line-height:1.2}
.stat span{font-size:12.5px;color:var(--sub)}
section{padding:8px 0 56px}
h2{font-size:30px;margin:0 0 6px;font-weight:900;letter-spacing:-.3px}
.sec-lead{color:var(--sub);margin:0 0 22px}
.toolbar{position:sticky;top:60px;z-index:10;background:linear-gradient(var(--bg) 78%,rgba(244,239,227,0));padding:10px 0 14px;display:flex;flex-direction:column;gap:12px}
.search{display:flex;align-items:center;gap:10px;background:var(--card);border:1px solid var(--line);border-radius:12px;padding:9px 14px;max-width:440px}
.search:focus-within{border-color:var(--accent);box-shadow:0 0 0 3px rgba(245,184,0,.18)}
.search input{border:0;background:transparent;outline:0;font:inherit;flex:1;color:var(--text)}
.search .count{font-size:12px;color:var(--sub);white-space:nowrap}
.chips{display:flex;flex-wrap:wrap;gap:8px}
.chips a{display:inline-flex;align-items:center;gap:6px;font-size:13px;color:var(--text);background:var(--card);border:1px solid var(--line);border-radius:999px;padding:4px 12px}
.chips a:hover{text-decoration:none;border-color:var(--accent);background:var(--sel)}
.grid{display:grid;grid-template-columns:repeat(2,1fr);gap:18px}
.cat{background:var(--card);border:1px solid var(--line);border-radius:18px;padding:22px 22px 10px;position:relative;overflow:hidden;transition:box-shadow .2s,transform .2s}
.cat::before{content:"";position:absolute;left:0;top:0;bottom:0;width:4px;background:var(--c)}
.cat:hover{box-shadow:0 14px 34px rgba(90,70,30,.10);transform:translateY(-2px)}
.cat-head{display:flex;gap:14px;align-items:center;margin-bottom:10px}
.badge{flex:none;width:44px;height:44px;border-radius:13px;display:grid;place-items:center;font-size:22px;background:color-mix(in srgb,var(--c) 16%,#fff);border:1px solid color-mix(in srgb,var(--c) 30%,#fff)}
.cat h3{margin:0;font-size:18px;font-weight:800}
.cat-head p{margin:0;font-size:13px;color:var(--sub)}
.cat ul{list-style:none;margin:0;padding:0}
.cat li{padding:10px 0;border-top:1px solid #F0EADD}
.cat li:first-child{border-top:0}
.cat li b{display:block;font-size:14.5px;margin-bottom:2px}
.cat li span{font-size:13.5px;color:#5E574B}
.cat li.hide,.cat.hide{display:none}
mark{background:var(--sel);color:inherit;border-radius:3px;padding:0 1px}
.empty{display:none;text-align:center;color:var(--sub);padding:40px 0}
.install{display:grid;grid-template-columns:repeat(3,1fr);gap:16px}
.step{background:var(--card);border:1px solid var(--line);border-radius:16px;padding:20px}
.step .n{width:30px;height:30px;border-radius:50%;background:var(--accent);color:#fff;font-weight:800;display:grid;place-items:center;margin-bottom:10px}
.step h4{margin:0 0 4px;font-size:15.5px}.step p{margin:0;font-size:13.5px;color:#5E574B}
.notice{margin-top:16px;background:var(--sel);border:1px solid #F3DE94;border-radius:14px;padding:12px 16px;font-size:13.5px;color:#6B5412}
.timeline{position:relative;padding-left:26px}
.timeline::before{content:"";position:absolute;left:8px;top:8px;bottom:8px;width:2px;background:linear-gradient(var(--accent),var(--orange),var(--line))}
details.ver{position:relative;background:var(--card);border:1px solid var(--line);border-radius:16px;margin-bottom:12px}
details.ver::before{content:"";position:absolute;left:-23px;top:20px;width:12px;height:12px;border-radius:50%;background:var(--card);border:3px solid var(--accent)}
details.ver[open]::before{background:var(--accent)}
details.ver summary{list-style:none;cursor:pointer;padding:14px 18px;display:flex;align-items:baseline;gap:12px;flex-wrap:wrap}
details.ver summary::-webkit-details-marker{display:none}
details.ver summary::after{content:"展开";margin-left:auto;font-size:12px;color:var(--sub)}
details.ver[open] summary::after{content:"收起"}
.vtag{font-weight:900;font-size:16px}
.vlatest{font-size:11.5px;font-weight:700;color:#fff;background:var(--done);border-radius:999px;padding:1px 8px}
.vdate{font-size:12.5px;color:var(--sub)}
.vsum{flex-basis:100%;font-size:13.5px;color:#5E574B}
.vbody{padding:2px 22px 16px;border-top:1px solid #F0EADD;font-size:13.8px}
.vbody h4{font-size:14.5px;margin:16px 0 6px;color:#8A6300}
.vbody h5{font-size:13.8px;margin:12px 0 4px}
.vbody ul{margin:4px 0;padding-left:20px}.vbody li{margin:3px 0}.vbody li::marker{color:var(--accent)}
.vbody p{margin:6px 0}
footer{border-top:1px solid var(--line);padding:28px 0 40px;color:var(--sub);font-size:12.5px}
footer .wrap{display:flex;flex-wrap:wrap;gap:10px 24px;justify-content:space-between}
.dl-band{background:linear-gradient(135deg,#FFF4CC,#FFE3C8);border:1px solid #F3DE94;border-radius:22px;padding:30px;display:flex;align-items:center;gap:24px;flex-wrap:wrap}
.dl-band img{width:72px;height:72px;border-radius:17px;box-shadow:0 10px 24px rgba(120,80,20,.18)}
.dl-band h3{margin:0;font-size:22px;font-weight:900}.dl-band p{margin:2px 0 0;color:#6B5412;font-size:13.5px}
.dl-band .cta{margin-left:auto}
.sha{font:11.5px/1.5 ui-monospace,Menlo,monospace;color:var(--sub);word-break:break-all;flex-basis:100%}
@media (max-width:860px){.hero .wrap{grid-template-columns:1fr}.stage{height:240px}.grid,.install{grid-template-columns:1fr}.stats{grid-template-columns:repeat(2,1fr)}h1{font-size:38px}nav.links{display:none}}
@media (prefers-reduced-motion:reduce){*{animation:none!important;transition:none!important}html{scroll-behavior:auto}}
"""

JS = r"""
(function(){
  var input=document.getElementById('q'),count=document.getElementById('qcount'),empty=document.getElementById('empty');
  var items=[].slice.call(document.querySelectorAll('.cat li'));
  function esc(s){return s.replace(/[&<>]/g,function(c){return{'&':'&amp;','<':'&lt;','>':'&gt;'}[c];});}
  function hl(text,q){if(!q)return esc(text);var out='',low=text.toLowerCase(),i=0,j;
    while((j=low.indexOf(q,i))>=0){out+=esc(text.slice(i,j))+'<mark>'+esc(text.slice(j,j+q.length))+'</mark>';i=j+q.length;}
    return out+esc(text.slice(i));}
  items.forEach(function(li){li.setAttribute('data-t',li.textContent.toLowerCase());
    [].slice.call(li.querySelectorAll('b,span')).forEach(function(n){n.setAttribute('data-raw',n.textContent);});});
  function run(){var q=input.value.trim().toLowerCase(),shown=0;
    items.forEach(function(li){var ok=!q||li.getAttribute('data-t').indexOf(q)>=0;li.classList.toggle('hide',!ok);if(ok)shown++;
      [].slice.call(li.querySelectorAll('b,span')).forEach(function(n){n.innerHTML=hl(n.getAttribute('data-raw'),q);});});
    [].slice.call(document.querySelectorAll('.cat')).forEach(function(c){c.classList.toggle('hide',!c.querySelector('li:not(.hide)'));});
    count.textContent=q?('找到 '+shown+' 项'):('共 '+items.length+' 项');empty.style.display=shown?'none':'block';}
  input.addEventListener('input',run);run();
  var SP='http://www.andymatuschak.org/xml-namespaces/sparkle';
  function cmp(a,b){a=a.split('.').map(Number);b=b.split('.').map(Number);
    for(var i=0;i<Math.max(a.length,b.length);i++){var d=(a[i]||0)-(b[i]||0);if(d)return d;}return 0;}
  var current=document.body.getAttribute('data-version');
  fetch('__APPCAST__',{cache:'no-store'}).then(function(r){return r.ok?r.text():Promise.reject(r.status);}).then(function(t){
    var d=new DOMParser().parseFromString(t,'application/xml'),best=null;
    [].slice.call(d.getElementsByTagName('item')).forEach(function(it){
      if(it.getElementsByTagNameNS(SP,'channel').length)return;
      var v=it.getElementsByTagNameNS(SP,'shortVersionString')[0],enc=null;
      for(var k=0;k<it.children.length;k++){if(it.children[k].localName==='enclosure'){enc=it.children[k];break;}}
      if(!v||!enc)return;v=v.textContent.trim();
      var url;try{url=new URL(enc.getAttribute('url'),location.href);}catch(e){return;}
      if(url.origin!==location.origin)return;
      if(!best||cmp(v,best.v)>0)best={v:v,url:url.href,len:+enc.getAttribute('length')||0};
    });
    if(!best||cmp(best.v,current)<=0)return;
    [].slice.call(document.querySelectorAll('.js-dl')).forEach(function(a){a.href=best.url;});
    [].slice.call(document.querySelectorAll('.js-ver')).forEach(function(n){n.textContent=best.v;});
    if(best.len)[].slice.call(document.querySelectorAll('.js-size')).forEach(function(n){n.textContent=(best.len/1048576).toFixed(1)+' MB';});
    [].slice.call(document.querySelectorAll('.js-sha')).forEach(function(n){n.style.display='none';});
  }).catch(function(){});
})();
"""


def main():
    changelog = (HERE / "CHANGELOG.md").read_text(encoding="utf-8")
    vs = versions(changelog)
    if not vs:
        sys.exit("CHANGELOG.md 里没有版本")
    latest = vs[0]
    v = latest["version"]
    zip_path = HERE / "dist" / f"Biandan-{v}.zip"
    if not zip_path.exists():
        sys.exit(f"找不到 {zip_path}，先发布 {v}")
    size = zip_path.stat().st_size
    sha = hashlib.sha256(zip_path.read_bytes()).hexdigest()
    zip_url = f"{UPDATE_BASE}/Biandan-{v}.zip"
    arch = archs()
    system = min_macos()
    if not make_icon():
        sys.exit("找不到 Assets/AppIcon-1024.png 或 Assets/biandan.png")
    total = sum(len(c[5]) for c in FEATURES)
    today = datetime.date.today().isoformat()
    released = latest["date"] or today

    chips = "".join(f'<a href="#f-{cid}">{icon} {esc(title)}</a>' for cid, icon, _, title, _, _ in FEATURES)
    cats = []
    for cid, icon, color, title, sub, items in FEATURES:
        lis = "".join(f"<li><b>{esc(t)}</b><span>{esc(d)}</span></li>" for t, d in items)
        cats.append(f'<article class="cat" id="f-{cid}" style="--c:{color}"><div class="cat-head"><div class="badge">{icon}</div>'
                    f'<div><h3>{esc(title)}</h3><p>{esc(sub)}</p></div></div><ul>{lis}</ul></article>')
    vers = []
    for i, item in enumerate(vs):
        s = summary(item["lines"])
        latest_tag = '<span class="vlatest">最新</span>' if i == 0 else ""
        date = f'<span class="vdate">{esc(item["date"])}</span>' if item["date"] else ""
        sum_html = f'<span class="vsum">{inline(s)}</span>' if s else ""
        opened = " open" if i == 0 else ""
        vers.append(f'<details class="ver"{opened}><summary><span class="vtag">v{esc(item["version"])}</span>'
                    f'{latest_tag}{date}{sum_html}</summary><div class="vbody">{render(item["lines"], skip=s)}</div></details>')

    meta = [f'<span>版本 <b class="js-ver">{esc(v)}</b></span>', f'<span class="js-size">{mb(size)}</span>', f"<span>{esc(system)}</span>"]
    if arch:
        meta.append(f"<span>{esc(arch)}</span>")
    meta.append("<span>已通过 Apple 公证</span>")
    meta_html = "".join(meta)
    arch_text = ("，" + esc(arch)) if arch else ""
    script = JS.replace("__APPCAST__", APPCAST_PATH)
    V = esc(v)
    Z = esc(zip_url)

    page = f"""<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>便单 for Mac · 功能一览与下载</title>
<meta name="description" content="便单 macOS 客户端：列表、四象限、日历时间轴，桌面浮窗球从聊天里识别日程，AI 快速添加，提醒与导入日历。下载最新版 {V}。">
<meta name="theme-color" content="#F4EFE3">
<meta property="og:title" content="便单 for Mac">
<meta property="og:description" content="把聊天里的日程一键收进来，到点提醒，四象限排优先级。">
<link rel="icon" href="icon-256.png">
<style>{CSS}</style>
</head>
<body data-version="{V}">
<header class="top"><div class="wrap">
  <a class="brand" href="#"><img src="icon-256.png" alt="">便单 <span style="font-weight:600;color:var(--sub)">for Mac</span></a>
  <nav class="links"><a href="#features">功能</a><a href="#install">安装</a><a href="#changelog">更新记录</a></nav>
  <a class="btn btn-primary btn-sm js-dl" href="{Z}">下载 <span class="js-ver">{V}</span></a>
</div></header>

<div class="hero"><div class="wrap">
  <div>
    <span class="eyebrow"><b>v<span class="js-ver">{V}</span></b>支持工具栏一键更新</span>
    <h1>聊天里的日程，<br><span class="hl">一键收进便单</span></h1>
    <p class="lead">列表、四象限、日历时间轴管好每一件事；桌面浮窗球从微信、飞书截图里识别日程，AI 帮你把随手一句话整理规范，到点提醒，没处理还会再提醒。</p>
    <div class="cta">
      <a class="btn btn-primary js-dl" href="{Z}"><svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><path d="M12 3v12m0 0-5-5m5 5 5-5M4 19h16"/></svg>下载 便单 <span class="js-ver">{V}</span></a>
      <a class="btn btn-ghost" href="#features">看看都能做什么</a>
    </div>
    <div class="meta">{meta_html}</div>
  </div>
  <div class="stage" aria-hidden="true">
    <div class="orb"></div><div class="orb b"></div>
    <img class="app-icon" src="icon-256.png" alt="">
    <div class="chip-float cf1"><i style="background:var(--q1)"></i>设计评审 · 8 分钟后</div>
    <div class="chip-float cf2"><i style="background:var(--q3)"></i>识别到 3 条日程</div>
    <div class="chip-float cf3"><i style="background:var(--done)"></i>今天完成 67%</div>
  </div>
</div></div>

<div class="wrap">
  <div class="stats">
    <div class="stat"><b>{len(FEATURES)}</b><span>大类功能</span></div>
    <div class="stat"><b>{total}</b><span>项具体功能</span></div>
    <div class="stat"><b>{len(vs)}</b><span>个版本持续更新</span></div>
    <div class="stat"><b>{esc(released)}</b><span>最近更新</span></div>
  </div>

  <section id="features">
    <h2>功能一览</h2>
    <p class="sec-lead">按更新记录整理的全部功能，写的是现在的样子。可以搜一下，比如「提醒」「飞书」「⌘Z」。</p>
    <div class="toolbar">
      <label class="search"><svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="#8A8273" stroke-width="2.2" stroke-linecap="round"><circle cx="11" cy="11" r="7"/><path d="m20 20-3.5-3.5"/></svg><input id="q" type="search" placeholder="搜索功能" autocomplete="off"><span class="count" id="qcount"></span></label>
      <div class="chips">{chips}</div>
    </div>
    <div class="grid">{"".join(cats)}</div>
    <div class="empty" id="empty">没有找到相关功能，换个词试试。</div>
  </section>

  <section id="install">
    <h2>下载与安装</h2>
    <p class="sec-lead">{esc(system)}{arch_text}。</p>
    <div class="install">
      <div class="step"><div class="n">1</div><h4>下载</h4><p>点下面的按钮下载 zip（<span class="js-size">{mb(size)}</span>）。</p></div>
      <div class="step"><div class="n">2</div><h4>拖进「应用程序」</h4><p>双击解压，把「便单」拖进「应用程序」文件夹。已经过 Apple 公证，可以直接打开。</p></div>
      <div class="step"><div class="n">3</div><h4>登录</h4><p>打开便单，用便单账号登录，和鸿蒙便单里的日程同步。</p></div>
    </div>
    <div class="notice">已经装了 1.3.0 或更新的版本？不用重新下载：便单会自动检查并安装新版本，也可以点主窗口右上角的更新按钮。还在用 1.2.0 及更早版本的，需要手动下载安装一次。</div>
    <div style="height:22px"></div>
    <div class="dl-band">
      <img src="icon-256.png" alt="">
      <div><h3>便单 <span class="js-ver">{V}</span></h3><p>{esc(released)} 发布 · <span class="js-size">{mb(size)}</span> · {esc(system)}</p></div>
      <div class="cta"><a class="btn btn-primary js-dl" href="{Z}">立即下载</a><a class="btn btn-ghost" href="{RELEASES}">GitHub 上的历史版本</a></div>
      <div class="sha js-sha">SHA-256：{sha}</div>
    </div>
  </section>

  <section id="changelog">
    <h2>更新记录</h2>
    <p class="sec-lead">每个版本具体改了什么。</p>
    <div class="timeline">{"".join(vers)}</div>
  </section>
</div>

<footer><div class="wrap">
  <span>便单 for Mac · 页面由更新记录生成于 {today}</span>
  <span><a class="js-dl" href="{Z}">下载最新版</a> · <a href="{RELEASES}">GitHub Releases</a></span>
</div></footer>
<script>{script}</script>
</body>
</html>
"""
    (OUT / "index.html").write_text(page, encoding="utf-8")
    print(f"已生成 {OUT / 'index.html'}（{len(page.encode('utf-8'))} 字节）：{len(FEATURES)} 类 {total} 项功能，{len(vs)} 个版本，下载 {v}（{mb(size)}，{arch or '架构未知'}，{system}）")


if __name__ == "__main__":
    main()
