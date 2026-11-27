import Foundation

// MARK: - 错误

/// 工具调用失败，对应 Python `ToolError`：错误信息加上可选的附加字段（operation_id、recovery 等）。
struct MCPToolError: Error, LocalizedError, Sendable {
    let message: String
    var details: JSONObject

    init(_ message: String, details: JSONObject = [:]) {
        self.message = message
        self.details = details
    }

    var errorDescription: String? { message }
}

fileprivate extension JSONValue {
    var mcpObject: JSONObject? {
        if case .object(let value) = self { return value }
        return nil
    }

    var mcpArray: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    var mcpString: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var mcpNumber: Double? {
        switch self {
        case .int(let value): return Double(value)
        case .double(let value): return value
        default: return nil
        }
    }

    /// 对应 Python `len(value)`：字符串按 Unicode 码点计数。
    var mcpLength: Int? {
        switch self {
        case .array(let value): return value.count
        case .string(let value): return value.unicodeScalars.count
        case .object(let value): return value.count
        default: return nil
        }
    }
}

// MARK: - 工具清单

/// 由 Python 版生成的工具清单，对应 Python `TOOLS` / `HELP_EXAMPLES` / `PREVIEW_EXAMPLES`。
struct MCPSchema: Sendable {
    struct HelpEntry: Sendable {
        let example: JSONValue
        let note: String
    }

    let serverVersion: String
    /// 保持 Python 的工具顺序，tools/list 原样返回。
    let tools: [JSONValue]
    let toolByName: [String: JSONObject]
    let help: [String: HelpEntry]
    let preview: JSONObject
    /// 每个工具顶层参数的原始顺序（Swift 字典不保序）。
    let propertyOrder: [String: [String]]

    static let shared: MCPSchema = {
        do {
            return try MCPSchema(text: MCPSchemaSource.json)
        } catch {
            preconditionFailure("MCP 工具清单无法解析：\(error)")
        }
    }()

    init(text: String) throws {
        guard let root = JSONValue.parseObject(text) else {
            throw MCPToolError("工具清单不是 JSON 对象。")
        }
        guard let version = root["server_version"]?.mcpString, let tools = root["tools"]?.mcpArray else {
            throw MCPToolError("工具清单缺少 server_version 或 tools。")
        }
        var byName: [String: JSONObject] = [:]
        for tool in tools {
            guard let object = tool.mcpObject, let name = object["name"]?.mcpString,
                  object["inputSchema"]?.mcpObject != nil else {
                throw MCPToolError("工具清单里有格式不正确的工具。")
            }
            byName[name] = object
        }
        var help: [String: HelpEntry] = [:]
        for (name, entry) in root["help"]?.mcpObject ?? [:] {
            guard let pair = entry.mcpArray, pair.count == 2, let note = pair[1].mcpString else {
                throw MCPToolError("工具 \(name) 的帮助示例格式不正确。")
            }
            help[name] = HelpEntry(example: pair[0], note: note)
        }
        var order: [String: [String]] = [:]
        for (name, keys) in root["order"]?.mcpObject ?? [:] {
            order[name] = (keys.mcpArray ?? []).compactMap { $0.mcpString }
        }
        serverVersion = version
        self.tools = tools
        toolByName = byName
        self.help = help
        preview = root["preview"]?.mcpObject ?? [:]
        propertyOrder = order
    }

    func inputSchema(_ name: String) -> JSONObject? {
        toolByName[name]?["inputSchema"]?.mcpObject
    }
}

// MARK: - 参数校验

/// 对应 Python `validate`：只检查类型、enum、最小/最大值、数组长度和多余/缺少的字段。
/// 与 Python 一致，不检查 allOf 里的组合约束（由各工具自己的业务校验负责）。
enum MCPValidator {
    static func validate(_ value: JSONValue, _ schema: JSONObject, _ label: String) throws {
        let type = schema["type"]?.mcpString ?? ""
        let matches: Bool
        switch (type, value) {
        case ("number", .int):
            matches = true
        case ("number", .double(let number)):
            matches = number.isFinite
        case ("object", .object), ("string", .string), ("boolean", .bool), ("integer", .int), ("array", .array):
            matches = true
        default:
            matches = false
        }
        guard matches else {
            throw MCPToolError(type == "number" ? "\(label) must be a finite number." : "\(label) must be of type \(type).")
        }
        if let options = schema["enum"]?.mcpArray, !options.contains(value) {
            throw MCPToolError("\(label) has an invalid value.")
        }
        if let number = value.mcpNumber {
            if let minimum = schema["minimum"]?.mcpNumber, number < minimum {
                throw MCPToolError("\(label) is out of range.")
            }
            if let maximum = schema["maximum"]?.mcpNumber, number > maximum {
                throw MCPToolError("\(label) is out of range.")
            }
        }
        if let length = value.mcpLength {
            if let limit = schema["maxItems"]?.mcpNumber, Double(length) > limit {
                throw MCPToolError("\(label) exceeds the allowed length.")
            }
            if let limit = schema["minItems"]?.mcpNumber, Double(length) < limit {
                throw MCPToolError("\(label) must not be empty.")
            }
        }
        if let properties = schema["properties"]?.mcpObject, case .object(let object) = value {
            let required = Set((schema["required"]?.mcpArray ?? []).compactMap { $0.mcpString })
            guard Set(object.keys).isSubset(of: properties.keys), required.isSubset(of: object.keys) else {
                throw MCPToolError("\(label) contains unknown fields or is missing required fields.")
            }
            for key in object.keys.sorted() {
                try validate(object[key] ?? .null, properties[key]?.mcpObject ?? [:], key)
            }
        }
        if let items = schema["items"]?.mcpObject, case .array(let array) = value {
            for (index, item) in array.enumerated() {
                try validate(item, items, "\(label)[\(index)]")
            }
        }
    }
}

// MARK: - 帮助

/// 对应 Python `tool_help`。
enum MCPHelp {
    static func help(_ tool: String?, schema: MCPSchema) throws -> JSONObject {
        guard let tool else {
            return [
                "用法": .string(#"传 {"tool":"工具名"} 查看该操作的参数和一条示例。"#),
                "常见流程": .array([
                    "查今天：local_today → list_occurrences",
                    "找任务或清单：search_tasks / list_lists",
                    "新建：create_task；编辑：update_task / move_task / reschedule_task",
                    "完成：list_occurrences 取 occurrence_id → complete_occurrence / complete_subtask",
                    "循环与习惯：create_task 传 repeat_rule，可设 habit=true；update_recurrence 预览修改",
                    "整理：create_list / update_list / delete_list；批量操作用 batch_add_tasks / batch_update_tasks",
                    "查询专注：list_focus；补记：create_focus",
                ].map { JSONValue.string($0) }),
            ]
        }
        var short = tool.trimmingCharacters(in: .whitespacesAndNewlines)
        if short.hasPrefix("biandan_") { short.removeFirst("biandan_".count) }
        let name = "biandan_" + short
        guard let entry = schema.help[short], let input = schema.inputSchema(name) else {
            throw MCPToolError("工具名未知。省略 tool 查看常见流程，或用 tools/list 查看准确名称。")
        }
        let properties = input["properties"]?.mcpObject ?? [:]
        let requiredValues = input["required"]?.mcpArray ?? []
        let required = Set(requiredValues.compactMap { $0.mcpString })
        let order = schema.propertyOrder[name] ?? properties.keys.sorted()
        var descriptions: JSONObject = [:]
        for (key, field) in properties {
            if let text = field.mcpObject?["description"]?.mcpString, !text.isEmpty {
                descriptions[key] = .string(text)
            }
        }
        var result: JSONObject = [
            "工具": .string(name),
            "必填": .array(requiredValues),
            "可选": .array(order.filter { !required.contains($0) }.map { JSONValue.string($0) }),
            "示例": entry.example,
            "说明": .string(entry.note),
            "参数说明": .object(descriptions),
        ]
        for key in ["location", "repeat_rule"] {
            if let nested = properties[key]?.mcpObject?["properties"]?.mcpObject {
                result["\(key) 字段"] = .object(nested.compactMapValues { $0.mcpObject?["description"] })
            }
        }
        if let example = schema.preview[short] {
            result["预览返回示例"] = example
        }
        return result
    }
}

// MARK: - 串行锁

/// 访问云端的工具调用逐个执行，避免多个客户端的多记录修改交错（对应 Python HTTP 模式的全局锁）。
actor MCPSerialGate {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters.append(continuation)
        }
    }

    func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

// MARK: - JSON-RPC 分发

/// 对应 Python `StdioServer.respond` 的无状态（HTTP）模式加上 `run_http.dispatch` 的加锁规则。
final class MCPDispatcher: Sendable {
    /// 执行一个业务工具（help、local_today 之外的工具）。参数已通过 schema 校验。
    typealias Runner = @Sendable (String, JSONObject) async throws -> JSONObject

    /// 对应 Python `HTTP_VERSIONS`（HTTP 模式不支持 2024-11-05）。
    static let httpVersions = ["2025-11-25", "2025-06-18", "2025-03-26"]
    /// 这些版本的客户端不认识 structuredContent。
    static let legacyVersions: Set<String> = ["2024-11-05", "2025-03-26"]
    static let localTools: Set<String> = ["biandan_help", "biandan_local_today"]
    static let signInAction = "在便单 App 中重新登录华为账号后重试。"

    let schema: MCPSchema
    private let runner: Runner
    private let gate = MCPSerialGate()

    init(schema: MCPSchema = .shared, runner: @escaping Runner) {
        self.schema = schema
        self.runner = runner
    }

    /// HTTP 层入口。返回 nil 表示通知（HTTP 回 202）。
    func handle(_ message: JSONValue, version: String) async -> JSONObject? {
        guard Self.needsGate(message) else {
            return await respond(message, version: version)
        }
        await gate.acquire()
        let response = await respond(message, version: version)
        await gate.release()
        return response
    }

    static func needsGate(_ message: JSONValue) -> Bool {
        guard case .object(let object) = message, object["method"] == .string("tools/call") else { return false }
        guard case .object(let params)? = object["params"], case .string(let name)? = params["name"] else { return true }
        return !localTools.contains(name)
    }

    func respond(_ message: JSONValue, version: String) async -> JSONObject? {
        guard case .object(let object) = message, object["jsonrpc"] == .string("2.0"),
              case .string(let method)? = object["method"] else {
            return Self.rpcError(.null, -32600, "Invalid Request")
        }
        if let identifier = object["id"] {
            switch identifier {
            case .int, .string: break
            default: return Self.rpcError(.null, -32600, "Invalid Request")
            }
        }
        // 通知：无状态模式下 notifications/initialized 也无需处理。
        guard let requestID = object["id"] else { return nil }
        let params: JSONObject
        switch object["params"] {
        case nil: params = [:]
        case .object(let value)?: params = value
        default: return Self.rpcError(requestID, -32602, "Invalid params")
        }
        let result: JSONObject
        switch method {
        case "initialize":
            guard case .string(let requested)? = params["protocolVersion"] else {
                return Self.rpcError(requestID, -32602, "Invalid initialization")
            }
            let negotiated = Self.httpVersions.contains(requested) ? requested : Self.httpVersions[0]
            result = [
                "protocolVersion": .string(negotiated),
                "capabilities": .object(["tools": .object(["listChanged": .bool(false)])]),
                "serverInfo": .object(["name": .string("biandan"), "version": .string(schema.serverVersion)]),
                "instructions": .string("Call biandan_help with a tool name for concise usage. "
                    + "Use task_id for task operations and occurrence_id for completion. "
                    + "Dates use the local calendar of the computer running this server."),
            ]
        case "ping":
            result = [:]
        case "tools/list":
            result = ["tools": .array(schema.tools)]
        case "tools/call":
            guard case .string(let name)? = params["name"], schema.toolByName[name] != nil else {
                return Self.rpcError(requestID, -32602, "Unknown Biandan tool")
            }
            var content: JSONObject
            do {
                let value = try await callTool(name, params["arguments"] ?? .object([:]))
                content = Self.content(value, isError: false)
            } catch {
                content = Self.content(Self.failure(error), isError: true)
            }
            if name == "biandan_help" || Self.legacyVersions.contains(version) {
                content["structuredContent"] = nil
            }
            result = content
        default:
            return Self.rpcError(requestID, -32601, "Method not found")
        }
        return ["jsonrpc": .string("2.0"), "id": requestID, "result": .object(result)]
    }

    /// 对应 Python `call_tool`。
    func callTool(_ name: String, _ arguments: JSONValue) async throws -> JSONObject {
        guard let input = schema.inputSchema(name) else { throw MCPToolError("Unknown Biandan tool.") }
        try MCPValidator.validate(arguments, input, "arguments")
        guard case .object(let object) = arguments else { throw MCPToolError("arguments must be of type object.") }
        switch name {
        case "biandan_help":
            return try MCPHelp.help(object["tool"]?.mcpString, schema: schema)
        case "biandan_local_today":
            return ["date": .string(LocalDate.today().iso)]
        default:
            return try await runner(name, object)
        }
    }

    // MARK: 结果与错误

    /// 对应 Python `result_content`。
    static func content(_ result: JSONObject, isError: Bool) -> JSONObject {
        let text = JSONValue.object(result).serializedString()
        return [
            "content": .array([.object(["type": .string("text"), "text": .string(text)])]),
            "structuredContent": .object(result),
            "isError": .bool(isError),
        ]
    }

    /// 对应 Python `tool_failure`。
    static func failure(_ error: Error) -> JSONObject {
        if let failure = error as? MCPCallFailure {
            return Self.failure(failure.underlying)
        }
        if let failure = error as? MCPToolError {
            var result = failure.details
            result["error"] = .string(failure.message)
            return result
        }
        if let failure = error as? ServiceError {
            var result: JSONObject = ["error": .string(failure.message)]
            if failure.mayHaveWritten { result["may_have_written"] = .bool(true) }
            if let recovery = failure.recovery { result["recovery"] = .string(recovery) }
            if failure.signInRequired { result["action"] = .string(signInAction) }
            return result
        }
        if let failure = error as? OperationFailure {
            // 从原始错误取附加信息（may_have_written、recovery 等）。
            var result = Self.failure(failure.source)
            if failure.needsSignIn { result["action"] = .string(signInAction) }
            return result
        }
        if let auth = error as? AuthError, auth == .reauthorizationRequired || auth == .notSignedIn {
            return ["error": .string(auth.localizedDescription), "action": .string(signInAction)]
        }
        return ["error": .string(error.localizedDescription)]
    }

    static func rpcError(_ id: JSONValue, _ code: Int, _ message: String) -> JSONObject {
        ["jsonrpc": .string("2.0"), "id": id,
         "error": .object(["code": .int(Int64(code)), "message": .string(message)])]
    }
}
