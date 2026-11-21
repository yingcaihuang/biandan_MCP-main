import Foundation

/// 华为同步接口客户端，对应 Python `BiandanCloud`。
/// 业务请求由本机直连 `driveapis.cloud.huawei.com.cn`，访问令牌来自 TokenProvider。
struct SyncAPIClient: Sendable {
    static let baseURL = "https://driveapis.cloud.huawei.com.cn/sync/v1/rongqi"
    static let appVersion = "16.3.0.001"
    static let recordFields = "kind,id,attributes,createdTime,editedTime,version"
    static let listFields = "nextCursor,records(\(recordFields))"
    /// 单表最多翻页次数，与 Python `records()` 一致。
    static let maxPages = 200

    let tokens: TokenProvider

    init(tokens: TokenProvider) {
        self.tokens = tokens
    }

    // MARK: - 底层请求

    static func traceID() -> String {
        let ms = Int64(Date().timeIntervalSince1970 * 1000)
        return String(format: "07200_02_%lld_%08d", ms, Int.random(in: 0..<100_000_000))
    }

    /// 路径段编码，对应 Python `quote(record_id, safe='')`。
    static func pathEscape(_ text: String) -> String {
        var out = ""
        for byte in text.utf8 {
            switch byte {
            case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"),
                 UInt8(ascii: "-"), UInt8(ascii: "."), UInt8(ascii: "_"), UInt8(ascii: "~"):
                out.append(Character(UnicodeScalar(byte)))
            default:
                out += String(format: "%%%02X", byte)
            }
        }
        return out
    }

    static func recordPath(_ kind: RecordKind, _ recordID: String? = nil) throws -> String {
        let path = "/kinds/\(kind.rawValue)/record"
        guard let recordID else { return path }
        guard !recordID.isEmpty, recordID != ".", recordID != ".." else {
            throw CloudError("需要有效的云记录 ID")
        }
        return path + "/" + pathEscape(recordID)
    }

    func request(_ method: String, _ path: String, params: [(String, String)] = [],
                 attributes: JSONObject? = nil) async throws -> JSONObject {
        var headers = [
            "Accept": "application/json",
            "x-hw-sync-env": "dataSync2DP",
            "x-hw-app-version": Self.appVersion,
            "x-hw-trace-id": Self.traceID(),
        ]
        var body: Data?
        if let attributes {
            headers["Content-Type"] = "application/json"
            body = try JSONValue.object(["attributes": .object(attributes)]).serialized()
        }
        let query = params.isEmpty ? "" : "?" + HTTPTransport.formEncode(params)
        guard let url = URL(string: Self.baseURL + path + query) else {
            throw CloudError("无效的请求地址")
        }
        let trace = headers["x-hw-trace-id"] ?? ""
        let label = "\(method) \(path)" + (params.contains { $0.0 == "cursor" } ? " (cursor)" : "")
        do {
            let token = try await tokens.accessToken()
            headers["Authorization"] = "Bearer \(token)"
            let result: JSONObject
            do {
                result = try await HTTPTransport.requestJSON(method: method, url: url, headers: headers, body: body)
            } catch let error as CloudError where error.status == 401 {
                // 只重试这一次被拒的请求；业务操作的其他写入可能已经生效。
                SyncDiagnostics.log("\(label) trace=\(trace) → 401，换新令牌后重试")
                let fresh = try await tokens.accessToken(rejected: token)
                headers["Authorization"] = "Bearer \(fresh)"
                result = try await HTTPTransport.requestJSON(method: method, url: url, headers: headers, body: body)
            }
            SyncDiagnostics.log("\(label) trace=\(trace) → OK  " + SyncDiagnostics.summarize(result))
            return result
        } catch {
            SyncDiagnostics.log("\(label) trace=\(trace) → 失败：\(error.localizedDescription)")
            throw error
        }
    }

    // MARK: - 读取

    /// 验证已授权账号可以访问便单容器。
    func check() async throws {
        _ = try await request("GET", "/about")
    }

    struct Page: Sendable {
        var records: [RawRecord]
        var nextCursor: String?
    }

    func listPage(_ kind: RecordKind, cursor: String? = nil, pageSize: Int = 100) async throws -> Page {
        guard (1...100).contains(pageSize) else { throw CloudError("单页数量必须在 1–100 之间") }
        var params = [("fields", Self.listFields), ("pageSize", String(pageSize))]
        if let cursor, !cursor.isEmpty { params.append(("cursor", cursor)) }
        let result = try await request("GET", try Self.recordPath(kind), params: params)
        let rowsValue = result["records"] ?? result["recordList"]
        guard case .array(let rows)? = rowsValue else {
            throw CloudError("列表响应里没有预期的 records")
        }
        var records: [RawRecord] = []
        records.reserveCapacity(rows.count)
        for row in rows {
            var record = try RawRecord.normalize(row, kind: kind)
            if record.attributes == nil {
                // 列表只返回 ID 时逐条读取详情。
                record = try await get(kind, record.cloudID)
            }
            records.append(record)
        }
        let next: String?
        switch result["nextCursor"] {
        case .string(let text)?: next = text.isEmpty ? nil : text
        case nil, .null?: next = nil
        default: throw CloudError("\(kind.rawValue) 返回了无效的分页游标")
        }
        return Page(records: records, nextCursor: next)
    }

    /// 拉取一张表的全部记录。游标重复或超过页数上限时抛错，不返回不完整的数据。
    func listAll(_ kind: RecordKind, progress: (@Sendable (Int) -> Void)? = nil) async throws -> [RawRecord] {
        var cursor: String?
        var seen = Set<String>()
        var all: [RawRecord] = []
        for _ in 0..<Self.maxPages {
            try Task.checkCancellation()
            let page = try await listPage(kind, cursor: cursor, pageSize: 100)
            all += page.records
            progress?(all.count)
            guard let next = page.nextCursor else { return all }
            guard seen.insert(next).inserted else {
                throw CloudError("\(kind.rawValue) 的分页游标重复，结果不完整，已停止")
            }
            cursor = next
        }
        throw CloudError("\(kind.rawValue) 页数过多，已在使用不完整数据前停止")
    }

    func get(_ kind: RecordKind, _ recordID: String) async throws -> RawRecord {
        let result = try await request("GET", try Self.recordPath(kind, recordID),
                                       params: [("fields", Self.recordFields)])
        var row: JSONValue = .object(result)
        if let wrapped = result["record"] {
            row = wrapped
        } else if case .array(let list)? = result["records"], list.count == 1 {
            row = list[0]
        }
        let record = try RawRecord.normalize(row, kind: kind)
        guard record.cloudID == recordID, record.version != nil, record.attributes != nil else {
            throw CloudError("详情响应缺少预期的 ID、version 或 attributes")
        }
        // version 必须是整数，与 Python `type(...) is int` 一致。
        if case .object(let object) = row, case .int? = object["version"] {} else {
            throw CloudError("详情响应的 version 不是整数")
        }
        return record
    }

    // MARK: - 写入（P4 起使用）

    func create(_ kind: RecordKind, attributes: JSONObject) async throws -> JSONObject {
        guard !attributes.isEmpty else { throw CloudError("新增需要非空的 attributes") }
        return try await request("POST", try Self.recordPath(kind),
                                 params: [("fields", Self.recordFields)], attributes: attributes)
    }

    /// 先读取最新版本并核对 baseversion，再以完整 attributes 合并改动后 PATCH。
    func update(_ kind: RecordKind, _ recordID: String, baseVersion: Int, changes: JSONObject,
                reparent: Bool = false) async throws -> JSONObject {
        let immutable: Set<String> = reparent && kind == .showTask ? ["id2"] : ["id1", "id2"]
        guard !changes.isEmpty, immutable.isDisjoint(with: changes.keys),
              !(kind == .favorites && changes["id3"] != nil),
              !(kind == .tomato && changes["time"] != nil) else {
            throw CloudError("修改内容不能为空，也不能包含记录标识字段")
        }
        let current = try await get(kind, recordID)
        guard current.version == baseVersion else {
            throw CloudError("记录版本已变化，请重新读取后再修改", status: 409)
        }
        let merged = (current.attributes ?? [:]).merging(changes) { _, new in new }
        return try await request("PATCH", try Self.recordPath(kind, recordID),
                                 params: [("baseversion", String(baseVersion))], attributes: merged)
    }

    func delete(_ kind: RecordKind, _ recordID: String, baseVersion: Int) async throws {
        let current = try await get(kind, recordID)
        guard current.version == baseVersion else {
            throw CloudError("记录版本已变化，请重新读取后再删除", status: 409)
        }
        if kind == .favorites, current.attributes?.identifier("id3") == TodoList.defaultID {
            throw CloudError("「未分类」不能删除")
        }
        _ = try await request("DELETE", try Self.recordPath(kind, recordID),
                              params: [("baseversion", String(baseVersion))])
    }
}
