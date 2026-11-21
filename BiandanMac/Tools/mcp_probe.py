#!/usr/bin/env python3
"""便单本机 MCP 自检工具：对正在运行的 http://127.0.0.1:42682/mcp 逐项检查。

用法：
  python3 Tools/mcp_probe.py              # 只读检查（HTTP 层、JSON-RPC、只读工具、并发）
  python3 Tools/mcp_probe.py --write      # 额外跑一轮写入往返：新建 → 读取 → 修改 → 完成 → 撤销 → 删除
  python3 Tools/mcp_probe.py --json out.json

密钥默认读取 ~/.biandan-mcp/http-access-key（尊重 BIANDAN_MCP_STATE_DIR），也可用 --token 或
环境变量 BIANDAN_MCP_TOKEN 指定。输出里不会打印完整密钥。只用 Python 标准库。
退出码：全部通过为 0，有失败为 1，无法连接或缺少密钥为 2。
"""
import argparse
import concurrent.futures
import datetime
import itertools
import json
import os
import socket
import sys
import time
from pathlib import Path
from urllib.parse import urlsplit

MAX_BODY = 256 * 1024
EXPECTED_TOOLS = 34


class ProbeError(Exception):
    pass


def expect(condition, message):
    if not condition:
        raise ProbeError(message)


def key_path():
    override = os.environ.get("BIANDAN_MCP_STATE_DIR")
    base = Path(override) if override else Path.home() / ".biandan-mcp"
    return base / "http-access-key"


def masked(token):
    return f"{token[:4]}…{token[-4:]}" if len(token) > 8 else "••••"


class Client:
    def __init__(self, url, token, timeout):
        parts = urlsplit(url)
        self.host = parts.hostname or "127.0.0.1"
        self.port = parts.port or 80
        self.path = parts.path or "/mcp"
        self.token = token
        self.timeout = timeout
        self.ids = itertools.count(1)

    @property
    def authority(self):
        return f"{self.host}:{self.port}"

    def raw(self, method="POST", path=None, host=None, headers=None, body=None, content_length=True):
        """发一个原始 HTTP 请求，返回 (状态码, 响应头, 解析后的 JSON 或 None)。"""
        payload = b"" if body is None else (body if isinstance(body, bytes) else body.encode("utf-8"))
        fields = {"Authorization": f"Bearer {self.token}", "Content-Type": "application/json"}
        fields.update(headers or {})
        lines = [f"{method} {path or self.path} HTTP/1.1", f"Host: {host or self.authority}"]
        lines += [f"{key}: {value}" for key, value in fields.items() if value is not None]
        if content_length and method == "POST":
            lines.append(f"Content-Length: {len(payload)}")
        data = ("\r\n".join(lines) + "\r\n\r\n").encode("latin-1") + payload
        with socket.create_connection((self.host, self.port), timeout=self.timeout) as sock:
            sock.sendall(data)
            chunks = []
            while True:
                try:
                    chunk = sock.recv(65536)
                except ConnectionResetError:
                    break
                if not chunk:
                    break
                chunks.append(chunk)
        response = b"".join(chunks)
        head, _, rest = response.partition(b"\r\n\r\n")
        head_lines = head.decode("latin-1").split("\r\n")
        first = head_lines[0].split() if head_lines else []
        status = int(first[1]) if len(first) > 1 and first[1].isdigit() else 0
        response_headers = {}
        for line in head_lines[1:]:
            if ":" in line:
                key, value = line.split(":", 1)
                response_headers.setdefault(key.strip().lower(), value.strip())
        parsed = None
        if rest:
            try:
                parsed = json.loads(rest.decode("utf-8"))
            except ValueError:
                parsed = None
        return status, response_headers, parsed

    def rpc(self, method, params=None, version="2025-06-18", notify=False):
        message = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            message["params"] = params
        if not notify:
            message["id"] = next(self.ids)
        return self.raw(headers={"MCP-Protocol-Version": version}, body=json.dumps(message, ensure_ascii=False))

    def call(self, name, arguments=None, version="2025-06-18"):
        """调用工具，返回 (是否出错, 结果对象, 原始 result)。"""
        status, _, body = self.rpc("tools/call", {"name": name, "arguments": arguments or {}}, version)
        expect(status == 200 and isinstance(body, dict) and "result" in body, f"HTTP {status}：{body}")
        result = body["result"]
        data = result.get("structuredContent")
        if data is None:
            data = json.loads(result["content"][0]["text"])
        return bool(result.get("isError")), data, result

    def ok(self, name, arguments=None):
        """调用工具并要求成功，返回结果对象。"""
        failed, data, _ = self.call(name, arguments)
        expect(not failed, f"{name} 返回错误：{data.get('error')}" + (f"（{data['action']}）" if data.get("action") else ""))
        return data


class Report:
    def __init__(self):
        self.results = []
        self.group = ""

    def section(self, title):
        self.group = title
        print(f"\n== {title} ==")

    def check(self, name, fn):
        started = time.monotonic()
        try:
            detail = fn() or ""
            ok = True
        except (ProbeError, OSError, ValueError, KeyError, TypeError, IndexError) as error:
            detail = f"{type(error).__name__}: {error}" if not isinstance(error, ProbeError) else str(error)
            ok = False
        elapsed = (time.monotonic() - started) * 1000
        self.results.append({"group": self.group, "name": name, "ok": ok, "detail": detail, "ms": round(elapsed)})
        mark = "✅" if ok else "❌"
        print(f"{mark} {name}  {detail}  ({elapsed:.0f} ms)")
        return ok

    @property
    def failed(self):
        return [item for item in self.results if not item["ok"]]


# MARK: - 检查项

def http_checks(client, report):
    report.section("HTTP 层")
    init = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "ping"})

    def status_is(expected, **kwargs):
        def run():
            status, headers, body = client.raw(**kwargs)
            expect(status == expected, f"期望 {expected}，实际 {status}：{body}")
            return f"HTTP {status}"
        return run

    report.check("正常请求返回 200", status_is(200, body=init))
    report.check("Host 为 localhost 也接受", status_is(200, host=f"localhost:{client.port}", body=init))
    report.check("陌生 Host 返回 403（防 DNS 重绑定）", status_is(403, host=f"evil.example:{client.port}", body=init))
    report.check("跨站 Origin 返回 403", status_is(403, headers={"Origin": "https://evil.example"}, body=init))
    report.check("非 /mcp 路径返回 404", status_is(404, path="/other", body=init))

    def wrong_token():
        status, headers, _ = client.raw(headers={"Authorization": "Bearer wrong"}, body=init)
        expect(status == 401, f"期望 401，实际 {status}")
        expect("biandan local mcp" in headers.get("www-authenticate", "").lower(), "缺少 WWW-Authenticate")
        return "HTTP 401 + WWW-Authenticate"

    report.check("错误密钥返回 401", wrong_token)
    report.check("缺少密钥返回 401", status_is(401, headers={"Authorization": None}, body=init))

    def get_method():
        status, headers, _ = client.raw(method="GET")
        expect(status == 405 and headers.get("allow") == "POST", f"期望 405 + Allow: POST，实际 {status} {headers.get('allow')}")
        return "HTTP 405, Allow: POST"

    report.check("GET 返回 405", get_method)
    report.check("Content-Type 不是 JSON 返回 415", status_is(415, headers={"Content-Type": "text/plain"}, body=init))
    report.check("不支持的协议版本返回 400", status_is(400, headers={"MCP-Protocol-Version": "2024-11-05"}, body=init))
    report.check("缺少 Content-Length 返回 400", status_is(400, content_length=False))
    report.check("请求体超过 256 KB 返回 413",
                 status_is(413, content_length=False, headers={"Content-Length": str(MAX_BODY + 1)}))

    def parse_error():
        status, _, body = client.raw(body="{not json")
        expect(status == 400 and body and body.get("error", {}).get("code") == -32700, f"{status} {body}")
        return "HTTP 400, -32700"

    report.check("非法 JSON 返回 Parse error", parse_error)

    def notification():
        status, _, body = client.rpc("notifications/initialized", notify=True)
        expect(status == 202 and body is None, f"期望 202 空响应，实际 {status} {body}")
        return "HTTP 202"

    report.check("通知返回 202", notification)


def rpc_checks(client, report):
    report.section("JSON-RPC")

    def initialize():
        status, _, body = client.rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                                    "clientInfo": {"name": "mcp_probe", "version": "1"}})
        expect(status == 200, f"HTTP {status}")
        result = body["result"]
        expect(result["protocolVersion"] == "2025-06-18", f"协商版本 {result['protocolVersion']}")
        info = result["serverInfo"]
        expect(info["name"] == "biandan", f"serverInfo {info}")
        return f"{info['name']} {info['version']}，协议 {result['protocolVersion']}"

    report.check("initialize", initialize)

    def tools_list():
        status, _, body = client.rpc("tools/list")
        tools = body["result"]["tools"]
        names = [tool["name"] for tool in tools]
        expect(len(tools) == EXPECTED_TOOLS, f"工具数 {len(tools)}")
        expect(all(name.startswith("biandan_") for name in names), "有工具没有 biandan_ 前缀")
        expect(all("inputSchema" in tool for tool in tools), "有工具缺少 inputSchema")
        writes = sum(1 for tool in tools if not tool["annotations"]["readOnlyHint"])
        return f"{len(tools)} 个工具（写入类 {writes} 个）"

    report.check("tools/list", tools_list)

    def help_tool():
        data = client.ok("biandan_help", {"tool": "create_task"})
        expect(data.get("工具") == "biandan_create_task", f"{data}")
        return "返回参数说明与示例"

    report.check("biandan_help", help_tool)

    def local_today():
        data = client.ok("biandan_local_today")
        today = datetime.date.today().isoformat()
        expect(data.get("date") == today, f"服务端 {data.get('date')}，本机 {today}")
        return data["date"]

    report.check("biandan_local_today 与本机日期一致", local_today)

    def legacy():
        _, _, result = client.call("biandan_local_today", version="2025-03-26")
        expect("structuredContent" not in result, "旧协议不应返回 structuredContent")
        return "2025-03-26 不带 structuredContent"

    report.check("旧协议版本兼容", legacy)

    def invalid_args():
        failed, data, _ = client.call("biandan_get_task", {})
        expect(failed, "缺少必填参数时应返回 isError")
        return data.get("error", "")

    report.check("缺少必填参数返回 isError", invalid_args)

    def unknown_tool():
        status, _, body = client.rpc("tools/call", {"name": "biandan_nope"})
        expect(body.get("error", {}).get("code") == -32602, f"{status} {body}")
        return "-32602"

    report.check("未知工具返回 -32602", unknown_tool)

    def unknown_method():
        _, _, body = client.rpc("resources/list")
        expect(body.get("error", {}).get("code") == -32601, f"{body}")
        return "-32601"

    report.check("未知方法返回 -32601", unknown_method)


def read_checks(client, report):
    report.section("只读工具（访问云端）")

    def connection():
        data = client.ok("biandan_check_connection")
        expect(data.get("connected") is True, f"{data}")
        return "云端连接正常"

    if not report.check("biandan_check_connection", connection):
        print("   ↳ 云端不可用（可能未登录），跳过其余云端检查。")
        return False

    def lists():
        items = client.ok("biandan_list_lists")["items"]
        expect(any(item["list_id"] == "1" for item in items), "缺少默认待办单 1")
        return f"{len(items)} 个待办单"

    report.check("biandan_list_lists", lists)

    def today():
        data = client.ok("biandan_list_occurrences", {"time_query": "today", "status": "all", "include_summary": True})
        summary = data.get("summary", {})
        return f"今天 {data['total']} 项（待完成 {summary.get('pending')}，已完成 {summary.get('completed')}）"

    report.check("biandan_list_occurrences 今天", today)

    def search():
        data = client.ok("biandan_search_tasks", {"limit": 5})
        if data["items"]:
            task_id = data["items"][0]["task_id"]
            task = client.ok("biandan_get_task", {"task_id": task_id})
            expect(task["task_id"] == task_id, "get_task 返回的 ID 不一致")
        return f"共 {data['total']} 个任务"

    report.check("biandan_search_tasks + get_task", search)

    def focus():
        data = client.ok("biandan_list_focus", {"limit": 5, "include_summary": True})
        return f"{data['total']} 条专注记录"

    report.check("biandan_list_focus", focus)

    # 不能命名为 concurrent，会遮住 concurrent.futures 模块。
    def parallel_calls():
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
            results = list(pool.map(lambda _: client.call("biandan_list_lists"), range(4)))
        expect(all(not failed for failed, _, _ in results), "并发调用有失败")
        return "4 个并发调用全部成功（服务端串行执行，未死锁）"

    report.check("并发调用", parallel_calls)
    return True


def write_checks(client, report):
    report.section("写入往返（会在云端新建并删除一个测试任务）")
    state = {}
    today = datetime.date.today().isoformat()
    title = f"MCP 自检 {datetime.datetime.now():%H:%M:%S}"
    try:
        def create():
            data = client.ok("biandan_create_task", {"title": title, "start_date": today, "remark": "mcp_probe 自动创建，稍后删除"})
            state.update(task_id=data["task_id"], occurrence_id=data["occurrence_id"])
            expect(data["operation_id"] == data["task_id"], "operation_id 应等于 task_id")
            return f"task_id {data['task_id']}"

        if not report.check("create_task", create):
            return

        def get():
            task = client.ok("biandan_get_task", {"task_id": state["task_id"]})
            expect(task["title"] == title and task["start_date"] == today, f"{task['title']} {task['start_date']}")
            return "标题与日期一致"

        report.check("get_task 读回", get)

        def update():
            task = client.ok("biandan_update_task", {"task_id": state["task_id"], "important": True})
            expect(task["important"] is True, "important 未生效")
            return "important = true"

        report.check("update_task", update)

        def complete():
            data = client.ok("biandan_complete_occurrence", {"occurrence_id": state["occurrence_id"]})
            expect(data["occurrence"]["status"] == "completed" and data["task_completed"] is True, f"{data}")
            return "已完成，任务汇总为完成"

        report.check("complete_occurrence", complete)

        def reopen():
            data = client.ok("biandan_change_progress", {"occurrence_id": state["occurrence_id"], "action": "reopen"})
            expect(data["occurrence"]["status"] == "pending", f"{data}")
            return "已撤销"

        report.check("change_progress reopen", reopen)

        def preview():
            data = client.ok("biandan_delete_task", {"task_id": state["task_id"], "preview": True})
            expect(data.get("preview") is True and data["deletes_task_definition"] is True, f"{data}")
            return f"将删除 {len(data['occurrence_ids'])} 个实例"

        report.check("delete_task 预览", preview)
    finally:
        if "task_id" in state:
            def delete():
                data = client.ok("biandan_delete_task", {"task_id": state["task_id"]})
                expect(data.get("deleted") is True, f"{data}")
                failed, _, _ = client.call("biandan_get_task", {"task_id": state["task_id"]})
                expect(failed, "删除后仍能读到任务")
                return "已删除，读取返回找不到"

            report.check("delete_task 清理", delete)


# MARK: - 入口

def main():
    parser = argparse.ArgumentParser(description="便单本机 MCP 自检")
    parser.add_argument("--url", default="http://127.0.0.1:42682/mcp")
    parser.add_argument("--token", help="访问密钥（默认读取密钥文件或 BIANDAN_MCP_TOKEN）")
    parser.add_argument("--write", action="store_true", help="额外跑写入往返（新建并删除一个测试任务）")
    parser.add_argument("--timeout", type=float, default=60, help="单个请求超时秒数")
    parser.add_argument("--json", metavar="PATH", help="把结果写成 JSON 报告")
    args = parser.parse_args()

    token = args.token or os.environ.get("BIANDAN_MCP_TOKEN")
    if not token:
        try:
            token = key_path().read_text(encoding="ascii").strip()
        except OSError as error:
            print(f"读取访问密钥失败：{error}。请先在便单设置里启用 MCP，或用 --token 指定。", file=sys.stderr)
            return 2
    client = Client(args.url, token, args.timeout)
    print(f"目标 {args.url}，密钥 {masked(token)}")
    try:
        socket.create_connection((client.host, client.port), timeout=3).close()
    except OSError as error:
        print(f"无法连接 {client.authority}：{error}。请确认便单已打开且设置里启用了本机 MCP 服务。", file=sys.stderr)
        return 2

    report = Report()
    http_checks(client, report)
    rpc_checks(client, report)
    cloud_ok = read_checks(client, report)
    if args.write:
        if cloud_ok:
            write_checks(client, report)
        else:
            print("\n云端不可用，跳过写入往返。")

    failed = report.failed
    print(f"\n结果：{len(report.results) - len(failed)}/{len(report.results)} 通过")
    for item in failed:
        print(f"  ❌ [{item['group']}] {item['name']}：{item['detail']}")
    if args.json:
        Path(args.json).write_text(json.dumps(report.results, ensure_ascii=False, indent=2), encoding="utf-8")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
