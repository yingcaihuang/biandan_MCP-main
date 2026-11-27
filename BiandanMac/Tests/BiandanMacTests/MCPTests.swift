import Foundation
import XCTest
@testable import BiandanMac

private actor CallRecorder {
    var names: [String] = []
    func add(_ name: String) { names.append(name) }
}

final class MCPTests: XCTestCase {
    // MARK: 辅助

    private func message(_ text: String) throws -> JSONValue {
        try JSONValue.parse(Data(text.utf8))
    }

    private func object(_ value: JSONValue?) -> JSONObject? {
        if case .object(let object)? = value { return object }
        return nil
    }

    private func record(_ kind: RecordKind, _ attributes: JSONObject) -> RawRecord {
        RawRecord(kind: kind, cloudID: "c", version: 1, createdTime: nil, editedTime: nil, attributes: attributes)
    }

    private func dispatcher(_ recorder: CallRecorder? = nil) -> MCPDispatcher {
        MCPDispatcher { name, _ in
            await recorder?.add(name)
            return ["ok": .bool(true)]
        }
    }

    // MARK: 工具清单

    func testSchemaMatchesPythonVersion() {
        let schema = MCPSchema.shared
        XCTAssertEqual(schema.tools.count, 35)
        XCTAssertEqual(schema.serverVersion, "0.4.6")
        XCTAssertNotNil(schema.inputSchema("biandan_create_task"))
        XCTAssertEqual(schema.propertyOrder["biandan_complete_occurrence"], ["occurrence_id", "completed_at"])
        XCTAssertEqual(schema.help.count, 35)
    }

    // MARK: 参数格式

    func testCalendarDateAndClockTime() throws {
        XCTAssertEqual(try MCPArgs.calendarDate("2026-11-21").iso, "2026-11-21")
        for bad in ["2026-1-01", "2026-13-01", "2026-02-30", "20261121", ""] {
            XCTAssertThrowsError(try MCPArgs.calendarDate(bad), bad)
        }
        let time = try MCPArgs.clockTime("09:05")
        XCTAssertEqual(time.hour, 9)
        XCTAssertEqual(time.minute, 5)
        for bad in ["9:05", "24:00", "09:60", "09:05:00"] {
            XCTAssertThrowsError(try MCPArgs.clockTime(bad), bad)
        }
        XCTAssertEqual(try MCPArgs.businessID("123"), "123")
        for bad in ["0", "01", "-1", "abc", "99999999999999999"] {
            XCTAssertThrowsError(try MCPArgs.businessID(bad), bad)
        }
    }

    func testRepeatRuleParsing() throws {
        let weekly = try MCPArgs.repeatRule(["mode": .string("custom"), "unit": .string("week"),
                                             "dates": .array([.string("1"), .string("3")])])
        XCTAssertEqual(weekly.mode, .custom)
        XCTAssertEqual(weekly.unit, .week)
        XCTAssertEqual(try weekly.encode().loopDate, "1,3")
        XCTAssertEqual(try MCPArgs.repeatRule(["mode": .string("daily")]).mode, .daily)
        XCTAssertThrowsError(try MCPArgs.repeatRule(["mode": .string("none")]))
        XCTAssertThrowsError(try MCPArgs.repeatRule(["mode": .string("fortnightly")]))
        XCTAssertThrowsError(try MCPArgs.repeatRule(["mode": .string("daily"), "unit": .string("week")]))
        XCTAssertThrowsError(try MCPArgs.repeatRule(["mode": .string("custom"), "unit": .string("week")]))
        XCTAssertThrowsError(try MCPArgs.repeatRule(["mode": .string("custom"), "unit": .string("decade")]))
    }

    // MARK: schema 校验

    func testValidator() throws {
        let schema = MCPSchema.shared
        let getTask = try XCTUnwrap(schema.inputSchema("biandan_get_task"))
        XCTAssertNoThrow(try MCPValidator.validate(.object(["task_id": .string("1")]), getTask, "arguments"))
        XCTAssertThrowsError(try MCPValidator.validate(.object([:]), getTask, "arguments"))
        XCTAssertThrowsError(try MCPValidator.validate(.object(["task_id": .int(1)]), getTask, "arguments"))
        XCTAssertThrowsError(try MCPValidator.validate(.object(["task_id": .string("1"), "extra": .bool(true)]),
                                                       getTask, "arguments"))
        XCTAssertThrowsError(try MCPValidator.validate(.array([]), getTask, "arguments"))

        let subtask = try XCTUnwrap(schema.inputSchema("biandan_complete_subtask"))
        XCTAssertNoThrow(try MCPValidator.validate(
            .object(["occurrence_id": .string("1"), "subtask_index": .int(19)]), subtask, "arguments"))
        XCTAssertThrowsError(try MCPValidator.validate(
            .object(["occurrence_id": .string("1"), "subtask_index": .int(20)]), subtask, "arguments"))

        let focus = try XCTUnwrap(schema.inputSchema("biandan_create_focus"))
        // number 同时接受整数和小数。
        XCTAssertNoThrow(try MCPValidator.validate(
            .object(["started_at": .string("2026-11-21T09:00"), "minutes": .int(25)]), focus, "arguments"))
        XCTAssertNoThrow(try MCPValidator.validate(
            .object(["started_at": .string("2026-11-21T09:00"), "minutes": .double(25.5)]), focus, "arguments"))
    }

    // MARK: help

    func testHelp() throws {
        let schema = MCPSchema.shared
        XCTAssertNotNil(try MCPHelp.help(nil, schema: schema)["常见流程"])
        let entry = try MCPHelp.help("complete_occurrence", schema: schema)
        XCTAssertEqual(entry["工具"], .string("biandan_complete_occurrence"))
        XCTAssertEqual(entry["必填"], .array([.string("occurrence_id")]))
        XCTAssertEqual(entry["可选"], .array([.string("completed_at")]))
        XCTAssertEqual(try MCPHelp.help("biandan_complete_occurrence", schema: schema)["工具"], entry["工具"])
        XCTAssertNotNil(try MCPHelp.help("delete_task", schema: schema)["预览返回示例"])
        XCTAssertNotNil(try MCPHelp.help("create_task", schema: schema)["repeat_rule 字段"])
        XCTAssertThrowsError(try MCPHelp.help("nope", schema: schema))
    }

    // MARK: JSON-RPC 分发

    func testInitializeAndPing() async throws {
        let rpc = dispatcher()
        let reply = await rpc.respond(try message(
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#),
            version: "2025-06-18")
        let result = try XCTUnwrap(object(reply?["result"]))
        XCTAssertEqual(result["protocolVersion"], .string("2025-06-18"))
        XCTAssertEqual(object(result["serverInfo"])?["name"], .string("biandan"))

        let unknown = await rpc.respond(try message(
            #"{"jsonrpc":"2.0","id":2,"method":"initialize","params":{"protocolVersion":"1999-01-01"}}"#),
            version: "2025-03-26")
        XCTAssertEqual(object(unknown?["result"])?["protocolVersion"], .string("2025-11-25"))

        let ping = await rpc.respond(try message(#"{"jsonrpc":"2.0","id":"p","method":"ping"}"#), version: "2025-06-18")
        XCTAssertEqual(ping?["id"], .string("p"))
        XCTAssertEqual(ping?["result"], .object([:]))
    }

    func testNotificationsAndInvalidRequests() async throws {
        let rpc = dispatcher()
        let note = await rpc.respond(try message(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#),
                                     version: "2025-06-18")
        XCTAssertNil(note)

        for text in [#"{"id":1,"method":"ping"}"#, #"[1,2]"#, #"{"jsonrpc":"2.0","id":[1],"method":"ping"}"#] {
            let reply = await rpc.respond(try message(text), version: "2025-06-18")
            XCTAssertEqual(object(reply?["error"])?["code"], .int(-32600), text)
        }
        let params = await rpc.respond(try message(#"{"jsonrpc":"2.0","id":1,"method":"ping","params":[]}"#),
                                       version: "2025-06-18")
        XCTAssertEqual(object(params?["error"])?["code"], .int(-32602))
        let method = await rpc.respond(try message(#"{"jsonrpc":"2.0","id":1,"method":"resources/list"}"#),
                                       version: "2025-06-18")
        XCTAssertEqual(object(method?["error"])?["code"], .int(-32601))
    }

    func testToolsListAndCall() async throws {
        let recorder = CallRecorder()
        let rpc = dispatcher(recorder)
        let list = await rpc.respond(try message(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#),
                                     version: "2025-06-18")
        if case .array(let tools)? = object(list?["result"])?["tools"] {
            XCTAssertEqual(tools.count, 35)
        } else {
            XCTFail("tools/list 没有返回工具数组")
        }

        // 业务工具交给 runner；新版本带 structuredContent。
        let call = await rpc.respond(try message(
            #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"biandan_get_task","arguments":{"task_id":"5"}}}"#),
            version: "2025-06-18")
        let result = try XCTUnwrap(object(call?["result"]))
        XCTAssertEqual(result["isError"], .bool(false))
        XCTAssertEqual(result["structuredContent"], .object(["ok": .bool(true)]))
        let names = await recorder.names
        XCTAssertEqual(names, ["biandan_get_task"])

        // 旧协议版本去掉 structuredContent。
        let legacy = await rpc.respond(try message(
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"biandan_get_task","arguments":{"task_id":"5"}}}"#),
            version: "2025-03-26")
        XCTAssertNil(object(legacy?["result"])?["structuredContent"])

        // 参数校验失败：isError，不调用 runner。
        let invalid = await rpc.respond(try message(
            #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"biandan_get_task","arguments":{}}}"#),
            version: "2025-06-18")
        XCTAssertEqual(object(invalid?["result"])?["isError"], .bool(true))
        // 前面新旧协议各调用一次 get_task；校验失败的这次不应增加。
        let afterInvalid = await recorder.names
        XCTAssertEqual(afterInvalid, ["biandan_get_task", "biandan_get_task"])

        // help 与 local_today 在本地处理；help 不带 structuredContent。
        let help = await rpc.respond(try message(
            #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"biandan_help"}}"#),
            version: "2025-06-18")
        XCTAssertNil(object(help?["result"])?["structuredContent"])
        XCTAssertEqual(object(help?["result"])?["isError"], .bool(false))
        let today = await rpc.respond(try message(
            #"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"biandan_local_today","arguments":{}}}"#),
            version: "2025-06-18")
        XCTAssertEqual(object(object(today?["result"])?["structuredContent"])?["date"], .string(LocalDate.today().iso))
        // help 与 local_today 不经过业务工具。
        let finalNames = await recorder.names
        XCTAssertEqual(finalNames.count, 2)

        let unknown = await rpc.respond(try message(
            #"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"biandan_nope"}}"#),
            version: "2025-06-18")
        XCTAssertEqual(object(unknown?["error"])?["code"], .int(-32602))
    }

    func testGateOnlyForCloudTools() throws {
        XCTAssertTrue(MCPDispatcher.needsGate(try message(
            #"{"method":"tools/call","params":{"name":"biandan_create_task"}}"#)))
        XCTAssertFalse(MCPDispatcher.needsGate(try message(
            #"{"method":"tools/call","params":{"name":"biandan_help"}}"#)))
        XCTAssertFalse(MCPDispatcher.needsGate(try message(#"{"method":"tools/list"}"#)))
    }

    func testFailureCarriesDetails() {
        let tool = MCPDispatcher.failure(MCPToolError("boom", details: ["operation_id": .string("9")]))
        XCTAssertEqual(tool["error"], .string("boom"))
        XCTAssertEqual(tool["operation_id"], .string("9"))
        let service = MCPDispatcher.failure(ServiceError("写入失败", mayHaveWritten: true, recovery: "重试"))
        XCTAssertEqual(service["error"], .string("写入失败"))
        XCTAssertEqual(service["may_have_written"], .bool(true))
        XCTAssertEqual(service["recovery"], .string("重试"))
        let wrapped = MCPDispatcher.failure(MCPCallFailure(underlying: MCPToolError("inner"), changes: ChangeSet()))
        XCTAssertEqual(wrapped["error"], .string("inner"))
        let auth = MCPDispatcher.failure(AuthError.reauthorizationRequired)
        XCTAssertEqual(auth["action"], .string(MCPDispatcher.signInAction))
    }

    // MARK: HTTP 请求头

    func testRequestHeadParsing() throws {
        let text = "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:42682\r\nContent-Type: Application/JSON; charset=utf-8\r\n"
            + "authorization: Bearer abc\r\nContent-Length: 12"
        let head = try XCTUnwrap(MCPRequestHead(Data(text.utf8)))
        XCTAssertEqual(head.method, "POST")
        XCTAssertEqual(head.target, "/mcp")
        XCTAssertEqual(head.header("host"), "127.0.0.1:42682")
        XCTAssertEqual(head.header("Authorization"), "Bearer abc")
        XCTAssertEqual(head.contentType, "application/json")
        XCTAssertNil(head.header("Origin"))

        let bare = try XCTUnwrap(MCPRequestHead(Data("GET /mcp HTTP/1.1\r\nHost: localhost:42682".utf8)))
        XCTAssertEqual(bare.contentType, "text/plain")
        XCTAssertNil(MCPRequestHead(Data("GARBAGE".utf8)))
        XCTAssertNil(MCPRequestHead(Data("POST /mcp HTTP/1.1\r\nno-colon-line".utf8)))
    }

    // MARK: 返回格式

    func testTaskView() {
        let view = MCPView.task(record(.task, [
            "id1": .int(123), "taskTitle": .string("阅读"), "taskContent": .string(#"["备注","第一章","第二章"]"#),
            "id3": .int(5), "isImportant": .int(1), "isUrgency": .int(0), "isCollectible": .int(0),
            "unitTimeNumber": .int(300), "loopSet": .int(1), "loopUnit": .int(1), "loopBaseNumber": .int(1),
            "loopDate": .string("1,3"), "duration": .int(0), "isLoop": .int(2), "haveNoTime": .int(0),
            "startTime": .string("2026-11-21"), "endTime": .string("2026-12-31"),
            "validStartTime": .string("00:00:00"), "validEndTime": .string("23:59:00"),
            "isFinish": .int(0), "isRemind": .int(1), "remindDate": .string("2026-11-21"),
            "remindTime": .string("09:00:00"), "latitude": .int(-1), "longitude": .int(-1), "location": .string(""),
        ]))
        XCTAssertEqual(view["task_id"], .string("123"))
        XCTAssertEqual(view["list_id"], .string("5"))
        XCTAssertEqual(view["remark"], .string("备注"))
        XCTAssertEqual(view["subtasks"], .array([.string("第一章"), .string("第二章")]))
        XCTAssertEqual(view["target_count"], .int(2))
        XCTAssertEqual(view["important"], .bool(true))
        XCTAssertEqual(view["is_habit"], .bool(true))
        XCTAssertEqual(view["location"], .null)
        XCTAssertEqual(object(view["time_reminder"])?["time"], .string("09:00:00"))
        let rule = object(view["recurrence"])
        XCTAssertEqual(rule?["mode"], .string("custom"))
        XCTAssertEqual(rule?["unit"], .string("week"))
        XCTAssertEqual(rule?["day_filter"], .string("all"))
        XCTAssertEqual(rule?["dates"], .array([.string("1"), .string("3")]))
        XCTAssertEqual(rule?["duration_days"], .int(1))

        // 缺省待办单为 1；无循环时 recurrence 为 null。
        let plain = MCPView.task(record(.task, ["id1": .string("7"), "taskTitle": .string("x")]))
        XCTAssertEqual(plain["list_id"], .string("1"))
        XCTAssertEqual(plain["recurrence"], .null)
        XCTAssertEqual(plain["target_count"], .int(1))
    }

    func testOccurrenceView() {
        let task = record(.task, ["id1": .int(1), "unitTimeNumber": .int(700)])
        let partial = MCPView.occurrence(record(.showTask, [
            "id1": .int(1), "id2": .int(9), "completedCount": .int(500), "isFinish": .int(0),
            "recentFinishedTime": .string("2026-11-21 08:00:00"),
        ]), task: task)
        XCTAssertEqual(partial["status"], .string("pending"))
        XCTAssertEqual(partial["completed_count"], .int(2))
        XCTAssertEqual(partial["target_count"], .int(3))
        XCTAssertEqual(partial["completed_subtask_indices"], .array([.int(0), .int(2)]))
        XCTAssertEqual(partial["completed_at"], .null)

        let abandoned = MCPView.occurrence(record(.showTask, ["id1": .int(1), "id2": .int(9),
                                                              "completedCount": .int(-1)]), task: task)
        XCTAssertEqual(abandoned["status"], .string("abandoned"))
        XCTAssertEqual(abandoned["completed_count"], .int(0))

        let counted = record(.task, ["id1": .int(1), "unitTimeNumber": .int(3)])
        let done = MCPView.occurrence(record(.showTask, ["id1": .int(1), "id2": .int(9), "completedCount": .int(3),
                                                          "isFinish": .int(1),
                                                          "recentFinishedTime": .string("2026-11-21 08:00:00")]),
                                      task: counted)
        XCTAssertEqual(done["status"], .string("completed"))
        XCTAssertEqual(done["completed_at"], .string("2026-11-21 08:00:00"))
        XCTAssertEqual(done["completed_subtask_indices"], .array([]))
    }

    func testListViewAndPage() throws {
        let list = MCPView.list(record(.favorites, ["id3": .int(5), "favoritesName": .string("工作"),
                                                    "favoritesColor": .int(203)]))
        XCTAssertEqual(list["sort_index"], .int(2))
        XCTAssertEqual(list["color"], .int(3))

        let items: [JSONObject] = (0..<5).map { ["n": .int(Int64($0))] }
        let first = try MCPView.page(items, limit: 2, offset: 0)
        XCTAssertEqual(first["total"], .int(5))
        XCTAssertEqual(first["next_offset"], .int(2))
        let last = try MCPView.page(items, limit: 2, offset: 4)
        XCTAssertEqual(last["items"], .array([.object(["n": .int(4)])]))
        XCTAssertEqual(last["next_offset"], .null)
        let beyond = try MCPView.page(items, limit: 2, offset: 10)
        XCTAssertEqual(beyond["items"], .array([]))
        XCTAssertThrowsError(try MCPView.page(items, limit: 0, offset: 0))
        XCTAssertThrowsError(try MCPView.page(items, limit: 101, offset: 0))
        XCTAssertThrowsError(try MCPView.page(items, limit: 1, offset: -1))
    }

    // MARK: 本机密钥

    func testAccessKeyFormat() {
        let token = MCPAccessKey.generate()
        XCTAssertEqual(token.count, 43)
        XCTAssertTrue(MCPAccessKey.isValid(token))
        XCTAssertNotEqual(token, MCPAccessKey.generate())
        XCTAssertFalse(MCPAccessKey.isValid("short"))
        let masked = MCPAccessKey.masked(token)
        XCTAssertEqual(masked.count, 16)
        XCTAssertTrue(masked.hasPrefix(String(token.prefix(4))))
        XCTAssertTrue(masked.hasSuffix(String(token.suffix(4))))
        XCTAssertFalse(masked.contains(token))
        XCTAssertFalse(MCPAccessKey.isValid(String(repeating: "+", count: 43)))
        let config = MCPAccessKey.clientConfig(port: 42682, token: token)
        XCTAssertTrue(config.contains("http://127.0.0.1:42682/mcp"))
        XCTAssertTrue(config.contains("Bearer \(token)"))
    }

    func testStartedAtAndCompletedAt() throws {
        XCTAssertNoThrow(try BiandanService.mcpStartedAt("2026-11-21T09:00"))
        XCTAssertNoThrow(try BiandanService.mcpStartedAt("2026-11-21T09:00:30"))
        XCTAssertThrowsError(try BiandanService.mcpStartedAt("2026-11-21 09:00"))
        XCTAssertThrowsError(try BiandanService.mcpStartedAt("2026-02-30T09:00"))
        let completed = try XCTUnwrap(try BiandanService.mcpCompletedAt("2026-11-21T18:30"))
        XCTAssertEqual(completed.0.iso, "2026-11-21")
        XCTAssertEqual(completed.1.hour, 18)
        XCTAssertNil(try BiandanService.mcpCompletedAt(nil))
        XCTAssertThrowsError(try BiandanService.mcpCompletedAt("2026-11-21T18:30:00"))
    }
}
