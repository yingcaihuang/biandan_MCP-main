#!/usr/bin/env python3
"""把 Assets/biandan.png 嵌入为 Sources/BiandanMac/App/BrandIconData.swift。更换图标后重新运行：
    python3 Tools/embed_icon.py
"""
import base64
import hashlib
import pathlib

root = pathlib.Path(__file__).resolve().parent.parent
png = (root / 'Assets/biandan.png').read_bytes()
assert png[:8] == b'\x89PNG\r\n\x1a\n', 'Assets/biandan.png 不是 PNG'
b64 = base64.b64encode(png).decode()
digest = hashlib.sha256(png).hexdigest()
out = root / 'Sources/BiandanMac/App/BrandIconData.swift'
out.write_text(f'''// 由 Tools/embed_icon.py 生成，请勿手改。
// 来源：https://www.biandangroup.com/appIcons/biandan.png（官方授权），本地文件 Assets/biandan.png
// 大小：{len(png)} 字节，SHA-256：{digest}
extension BrandIcon {{
    static let pngBase64 = "{b64}"
}}
''', encoding='utf-8')
print(out.relative_to(root), len(png), digest)
