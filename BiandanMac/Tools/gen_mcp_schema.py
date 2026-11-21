#!/usr/bin/env python3
"""从 Python 版便单 MCP 导出工具清单和帮助示例，生成 Sources/BiandanMac/MCP/MCPSchemaSource.swift。

用法：python3 Tools/gen_mcp_schema.py <解压后的 Python 发布包目录>
工具名和参数格式必须与 Python 版完全一致，AI 客户端才能沿用原配置。
"""
import json
import pathlib
import sys


def main():
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    sys.path.insert(0, sys.argv[1])
    import biandan_mcp as mcp  # noqa: E402

    data = {
        "server_version": mcp.SERVER_VERSION,
        "tools": mcp.TOOLS,
        "help": {name: list(entry) for name, entry in mcp.HELP_EXAMPLES.items()},
        "preview": mcp.PREVIEW_EXAMPLES,
        # Swift 字典不保序；help 的「可选」列表需要与 Python 相同的参数顺序。
        "order": {tool["name"]: list(tool["inputSchema"]["properties"]) for tool in mcp.TOOLS},
    }
    text = json.dumps(data, ensure_ascii=False, separators=(",", ":"))
    # 写进 Swift 原始字符串 #"""..."""#，不能出现结束符或 \# 插值。
    if '"""#' in text or "\\#" in text or "\n" in text:
        raise SystemExit("工具清单里出现了 Swift 原始字符串无法容纳的字符序列")
    lines = [
        "// 由 Tools/gen_mcp_schema.py 从 Python 版便单 MCP 生成，请勿手改。",
        f"// Python 版本 {mcp.SERVER_VERSION}，{len(mcp.TOOLS)} 个工具。",
        "",
        "enum MCPSchemaSource {",
        '    static let json = #"""',
        text,
        '"""#',
        "}",
        "",
    ]
    out = pathlib.Path(__file__).resolve().parent.parent / "Sources/BiandanMac/MCP/MCPSchemaSource.swift"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text("\n".join(lines), encoding="utf-8")
    print(f"wrote {out} · {len(mcp.TOOLS)} tools · {len(text)} chars")


if __name__ == "__main__":
    main()
