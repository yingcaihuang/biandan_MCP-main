import XCTest
@testable import BiandanMac

/// 推送给远程 biandan-api 的日程快照。testLivePush 默认跳过：BIANDAN_LIVE_PUSH=1 时用本机数据库的副本实际推一次。
final class SchedulePushTests: XCTestCase {
    private func record(_ kind: RecordKind, _ cloudID: String, _ attributes: JSONObject) -> RawRecord {
        RawRecord(kind: kind, cloudID: cloudID, version: 1, createdTime: nil, editedTime: nil, attributes: attributes)
    }

    private func task(_ id: String, title: String, list: String = "1", start: String, end: String,
                      from: String = "00:00:00", to: String = "23:59:00", undated: Bool = false,
                      content: String = "", important: Bool = false) -> RawRecord {
        record(.task, "t\(id)", [
            "id1": .string(id), "taskTitle": .string(title), "taskContent": .string(content), "id3": .string(list),
            "startTime": .string(start), "endTime": .string(end), "haveNoTime": .int(undated ? 1 : 0),
            "isLoop": .int(0), "loopSet": .int(0), "validStartTime": .string(from), "validEndTime": .string(to),
            "unitTimeNumber": .int(1), "isImportant": .int(important ? 1 : 0),
        ])
    }

    private func occurrence(_ id: String, start: String, end: String, from: String = "00:00:00",
                            to: String = "23:59:00", done: Bool = false) -> RawRecord {
        record(.showTask, "o\(id)", [
            "id1": .string(id), "id2": .string("o" + id), "startTime": .string(start), "endTime": .string(end),
            "validStartTime": .string(from), "validEndTime": .string(to),
            "completedCount": .int(done ? 1 : 0), "isFinish": .int(done ? 1 : 0),
            "recentFinishedTime": .string(done ? start + " 08:00:00" : ""),
        ])
    }

    /// d 全天；b 15:00–15:30（工作分类、重要、有备注）；c 无日期；a 已完成。
    private func snapshot() -> DataSnapshot {
        DataSnapshot(lists: [
            record(.favorites, "f1", ["id3": .string("1001"), "favoritesName": .string("工作"), "favoritesColor": .int(101)]),
        ], tasks: [
            task("d", title: "开会", start: "2026-11-22", end: "2026-11-22"),
            task("b", title: "面试", list: "1001", start: "2026-11-23", end: "2026-11-23", from: "15:00:00",
                 to: "15:30:00", content: "[\"带简历\",\"打印\"]", important: true),
            task("c", title: "读书", start: "1970-01-01", end: "2100-12-31", undated: true),
            task("a", title: "已完成", start: "2026-11-20", end: "2026-11-20"),
        ], occurrences: [
            occurrence("d", start: "2026-11-22", end: "2026-11-22"),
            occurrence("b", start: "2026-11-23", end: "2026-11-23", from: "15:00:00", to: "15:30:00"),
            occurrence("c", start: "1970-01-01", end: "2100-12-31"),
            occurrence("a", start: "2026-11-20", end: "2026-11-20", done: true),
        ], focus: [], lastPulledAt: nil)
    }

    private func build(_ sources: [String: SchedulePayload.Source] = [:]) -> SchedulePayload {
        SchedulePayload.build(snapshot: snapshot(), sources: sources,
                              timeZone: TimeZone(identifier: "Asia/Shanghai")!, device: "test")
    }

    func testBuildPayload() throws {
        let payload = build(["b": .init(kind: "caldav", name: "公司日历")])
        XCTAssertEqual(payload.timezone, "Asia/Shanghai")
        XCTAssertEqual(payload.items.map(\.occurrenceID), ["oa", "ob", "oc", "od"], "按实例 ID 固定排序")

        let lists = Dictionary(uniqueKeysWithValues: payload.lists.map { ($0.id, $0) })
        XCTAssertEqual(lists["1"]?.name, "未分类")
        XCTAssertEqual(lists["1"]?.isDefault, true)
        XCTAssertEqual(lists["1"]?.color, "#B9B09C")
        XCTAssertEqual(lists["1001"]?.name, "工作")
        XCTAssertEqual(lists["1001"]?.color, "#E5483A")
        XCTAssertEqual(lists["1001"]?.order, 1)

        let items = Dictionary(uniqueKeysWithValues: payload.items.map { ($0.occurrenceID, $0) })
        let done = try XCTUnwrap(items["oa"])
        XCTAssertEqual(done.status, "completed")
        XCTAssertEqual(done.completedAt, "2026-11-20 08:00:00")

        let timed = try XCTUnwrap(items["ob"])
        XCTAssertEqual(timed.listID, "1001")
        XCTAssertFalse(timed.allDay)
        XCTAssertEqual(timed.startDate, "2026-11-23")
        XCTAssertEqual(timed.startTime, "15:00")
        XCTAssertEqual(timed.endTime, "15:30")
        XCTAssertEqual(timed.remark, "带简历")
        XCTAssertEqual(timed.subtasks, ["打印"])
        XCTAssertTrue(timed.important)
        XCTAssertEqual(timed.source, .init(kind: "caldav", name: "公司日历"))

        let undated = try XCTUnwrap(items["oc"])
        XCTAssertTrue(undated.undated)
        XCTAssertNil(undated.startDate)
        XCTAssertNil(undated.endDate)

        let allDay = try XCTUnwrap(items["od"])
        XCTAssertTrue(allDay.allDay)
        XCTAssertNil(allDay.startTime)
        XCTAssertEqual(allDay.source, .biandan)

        // 没有值的字段不出现在 JSON 里；键名是下划线风格。
        let json = try XCTUnwrap(String(data: payload.encoded(), encoding: .utf8))
        XCTAssertTrue(json.contains("\"format\":\"biandan-schedule\""))
        XCTAssertTrue(json.contains("\"occurrence_id\":\"ob\""))
        XCTAssertTrue(json.contains("\"start_time\":\"15:00\""))
        XCTAssertFalse(json.contains("null"))
        XCTAssertFalse(json.contains("generated_at"))
    }

    func testContentHashIgnoresGeneratedAt() {
        var first = build()
        let second = build()
        XCTAssertEqual(first.contentHash(), second.contentHash())
        first.generatedAt = "2026-11-24T10:00:00+08:00"
        XCTAssertEqual(first.contentHash(), second.contentHash(), "生成时间不算进哈希")
        let moved = build(["d": .init(kind: "file", name: "a.ics")])
        XCTAssertNotEqual(moved.contentHash(), second.contentHash(), "来源变了哈希要变")
    }

    func testKeyValidation() {
        XCTAssertTrue(SchedulePushKeyStore.isValid("bdp_" + String(repeating: "aZ9-_", count: 8) + "abc"))
        XCTAssertFalse(SchedulePushKeyStore.isValid("bdr_" + String(repeating: "a", count: 43)), "读取密钥不能用来推送")
        XCTAssertFalse(SchedulePushKeyStore.isValid("bdp_" + String(repeating: "a", count: 42)))
        XCTAssertFalse(SchedulePushKeyStore.isValid("bdp_" + String(repeating: "a", count: 42) + "="))
    }

    func testSourceMapSkipsAbandonedLinks() throws {
        let store = try LocalStore()
        let source = ImportSource(id: "s1", kind: .caldav, name: "公司日历", listID: "1", address: "https://example.com/cal",
                                  createdAt: Date(), lastSyncAt: nil, lastCount: 0, enabled: true)
        try store.saveImportSource(source)
        try store.saveImportLink(ImportLink(sourceID: "s1", key: "k1", taskID: "t1", fingerprint: "f", startDay: nil, abandoned: false))
        try store.saveImportLink(ImportLink(sourceID: "s1", key: "k2", taskID: "t2", fingerprint: "f", startDay: nil, abandoned: true))
        let map = SchedulePayload.sourceMap(store: store)
        XCTAssertEqual(map["t1"], .init(kind: "caldav", name: "公司日历"))
        XCTAssertNil(map["t2"])
    }

    // MARK: - 实推（默认跳过）

    /// BIANDAN_LIVE_PUSH=1：复制本机数据库，按 App 的逻辑生成快照，用 ~/.biandan-api/push-mac.key 推到公网，
    /// 再用 read-esp32.key 查询核对条数。只打印数量，不打印标题。
    func testLivePush() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["BIANDAN_LIVE_PUSH"] == "1", "设置 BIANDAN_LIVE_PUSH=1 才实际推送")
        let endpoint = ProcessInfo.processInfo.environment["BIANDAN_API_ENDPOINT"] ?? SchedulePusher.defaultEndpoint
        let home = FileManager.default.homeDirectoryForCurrentUser
        func key(_ name: String) throws -> String {
            let text = try String(contentsOf: home.appendingPathComponent(".biandan-api/\(name).key"), encoding: .ascii)
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let pushKey = try key("push-mac"), readKey = try key("read-esp32")
        XCTAssertTrue(SchedulePushKeyStore.isValid(pushKey))

        // 只读副本：不碰正在运行的便单的数据库。
        let source = try LocalStore.defaultURL()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("biandan-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for suffix in ["", "-wal", "-shm"] {
            let from = URL(fileURLWithPath: source.path + suffix)
            if FileManager.default.fileExists(atPath: from.path) {
                try FileManager.default.copyItem(at: from, to: URL(fileURLWithPath: dir.appendingPathComponent("biandan.sqlite").path + suffix))
            }
        }
        let store = try LocalStore(url: dir.appendingPathComponent("biandan.sqlite"))
        let snapshot = try store.loadSnapshot()
        var payload = SchedulePayload.build(snapshot: snapshot, sources: SchedulePayload.sourceMap(store: store),
                                            timeZone: .current, device: "BiandanMac live-test")
        payload.generatedAt = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withInternetDateTime])

        func post(_ path: String, _ token: String, _ body: Data) async throws -> (Int, [String: Any]) {
            var request = URLRequest(url: URL(string: endpoint + path)!, timeoutInterval: 20)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.httpBody = body
            let (data, response) = try await URLSession.shared.data(for: request)
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            return ((response as? HTTPURLResponse)?.statusCode ?? 0, object)
        }

        let (code, pushed) = try await post("/v1/push", pushKey, payload.encoded())
        XCTAssertEqual(code, 200, "推送：\(pushed["error"] ?? "")")
        XCTAssertEqual(pushed["items"] as? Int, payload.items.count)

        let (readCode, all) = try await post("/v1/schedule", readKey, Data(#"{"limit":2000}"#.utf8))
        XCTAssertEqual(readCode, 200)
        XCTAssertEqual(all["total"] as? Int, payload.items.count, "服务端查到的条数和推送的一致")
        XCTAssertEqual(all["version"] as? String, pushed["version"] as? String)

        var byKind: [String: Int] = [:]
        for item in payload.items { byKind[item.source.kind, default: 0] += 1 }
        let groups = (all["groups"] as? [[String: Any]] ?? []).map { "\($0["id"] ?? "")=\($0["total"] ?? 0)" }
        print("实推：\(payload.lists.count) 个分类，\(payload.items.count) 条日程，来源 \(byKind.sorted { $0.key < $1.key })，"
              + "changed=\(pushed["changed"] ?? "")，版本 \(pushed["version"] ?? "")，分组 \(groups.joined(separator: " "))")
    }
}
