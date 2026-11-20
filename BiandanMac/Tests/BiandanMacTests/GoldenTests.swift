import XCTest
@testable import BiandanMac

/// 用 Tools/gen_golden.py 从 Python 参考实现生成的黄金用例，逐项核对 Swift 移植。
final class GoldenTests: XCTestCase {
    private static let golden: [String: Any] = {
        guard let url = Bundle.module.url(forResource: "golden", withExtension: "json", subdirectory: "Fixtures"),
              let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return object
    }()

    private func cases(_ key: String, file: StaticString = #filePath, line: UInt = #line) -> [[String: Any]] {
        let list = Self.golden[key] as? [[String: Any]] ?? []
        XCTAssertFalse(list.isEmpty, "黄金用例 \(key) 为空，请先运行 python3 Tools/gen_golden.py", file: file, line: line)
        return list
    }

    // MARK: - 业务 ID

    func testOccurrenceIDs() {
        for item in cases("occurrence_ids") {
            let task = item["task_id"] as! String
            let start = item["start"] as! String
            XCTAssertEqual(BusinessID.occurrenceID(taskID: task, startDate: start), item["id"] as? String, "\(task):\(start)")
        }
    }

    // MARK: - taskContent

    func testContentDecode() {
        for item in cases("content_decode") {
            let raw = item["raw"] as! String
            let decoded = TaskContent.decode(raw)
            XCTAssertEqual(decoded.remark, item["remark"] as? String, raw)
            XCTAssertEqual(decoded.subtasks, item["subtasks"] as? [String] ?? [], raw)
            XCTAssertEqual(decoded.attachments, item["attachments"] as? [String] ?? [], raw)
        }
    }

    func testContentEncode() {
        for item in cases("content_encode") {
            let content = TaskContent(remark: item["remark"] as! String,
                                      subtasks: item["subtasks"] as! [String],
                                      attachments: item["attachments"] as! [String])
            // 写出的格式与原生 JSON.stringify 一致（无空格）。
            XCTAssertEqual(content.encoded(), item["js"] as? String)
            // Python 版写出的带空格格式也能正确读回。
            XCTAssertEqual(TaskContent.decode(item["python"] as! String), content)
            XCTAssertEqual(TaskContent.decode(content.encoded()), content)
        }
    }

    // MARK: - 重复规则

    private func rule(from dict: [String: Any]) -> RepeatRule {
        let mode = LoopSet.allCases.first { $0 != .none && $0.modeName == dict["mode"] as? String } ?? .none
        let unit = (dict["unit"] as? String).flatMap { name in LoopUnitKind.allCases.first { $0.modeName == name } }
        let filter = (dict["day_filter"] as? String).flatMap { name in DayFilter.allCases.first { $0.modeName == name } }
        return RepeatRule(mode: mode, unit: unit, interval: dict["interval"] as? Int, dates: dict["dates"] as? [String],
                          dayFilter: filter, durationDays: dict["duration_days"] as? Int)
    }

    func testRuleEncoding() {
        for item in cases("rules") {
            let input = item["rule"] as! [String: Any]
            let label = String(describing: input)
            if let expected = item["encoded"] as? [String: Any] {
                do {
                    let encoded = try rule(from: input).encode()
                    XCTAssertEqual(encoded.loopSet, expected["loopSet"] as? Int, label)
                    XCTAssertEqual(encoded.loopUnit, expected["loopUnit"] as? Int, label)
                    XCTAssertEqual(encoded.loopBaseNumber, expected["loopBaseNumber"] as? Int, label)
                    XCTAssertEqual(encoded.loopDate, expected["loopDate"] as? String, label)
                    XCTAssertEqual(encoded.duration, expected["duration"] as? Int, label)
                } catch {
                    XCTFail("\(label): \(error)")
                }
            } else {
                XCTAssertThrowsError(try rule(from: input).encode(), label)
            }
        }
    }

    private func task(from row: [String: Any]) -> TaskDef {
        guard case .object(let attributes) = JSONValue(any: row) else {
            fatalError("row 不是对象")
        }
        return TaskDef(record: RawRecord(kind: .task, cloudID: "golden", version: 1, createdTime: nil,
                                         editedTime: nil, attributes: attributes))
    }

    func testRecurrenceWindows() {
        for item in cases("recurrence") {
            let name = item["name"] as! String
            let input = RecurrenceInput(task: task(from: item["row"] as! [String: Any]))
            let fromDate = (item["from_date"] as? String).flatMap { LocalDate(iso: $0) }
            let weekStart = item["week_start"] as? Int ?? 0
            let makeup = item["china_makeup"] as? Bool ?? false
            let allowEmpty = item["allow_empty"] as? Bool ?? false
            let run = {
                try Recurrence.windows(input, weekStart: weekStart, chinaMakeup: makeup,
                                       fromDate: fromDate, allowEmpty: allowEmpty)
            }
            if let expected = item["windows"] as? [[String: Any]] {
                do {
                    let actual = try run().map { [$0.start.iso, $0.end.iso, $0.validStartTime, $0.validEndTime] }
                    let want = expected.map { window in
                        ["startTime", "endTime", "validStartTime", "validEndTime"].map { window[$0] as? String ?? "" }
                    }
                    XCTAssertEqual(actual.count, want.count, "\(name) 实例数")
                    XCTAssertEqual(actual, want, name)
                } catch {
                    XCTFail("\(name): \(error)")
                }
            } else {
                XCTAssertThrowsError(try run(), name)
            }
        }
    }

    // MARK: - 进度

    func testOccurrenceProgress() {
        for item in cases("progress") {
            let unit = item["unitTimeNumber"] as! Int
            let count = item["completedCount"] as! Int
            let finish = item["isFinish"] as! Int
            let occurrence = Occurrence(record: RawRecord(
                kind: .showTask, cloudID: "o", version: 1, createdTime: nil, editedTime: nil,
                attributes: ["id2": .int(1), "id1": .int(1), "completedCount": .int(Int64(count)),
                             "isFinish": .int(Int64(finish)), "recentFinishedTime": .string("2026-11-20 10:00:00")]
            ))
            let progress = occurrence.progress(goal: TaskGoal(unitTimeNumber: unit))
            let label = "unit=\(unit) count=\(count)"
            XCTAssertEqual(progress.completedCount, item["completed_count"] as? Int, label)
            XCTAssertEqual(progress.targetCount, item["target_count"] as? Int, label)
            XCTAssertEqual(progress.completedSubtaskIndices, item["completed_subtask_indices"] as? [Int], label)
            XCTAssertEqual(occurrence.status.rawValue, item["status"] as? String, label)
        }
    }

    // MARK: - 授权编码

    func testFormEncoding() {
        for item in cases("form") {
            let pairs = (item["pairs"] as! [[String]]).map { ($0[0], $0[1]) }
            XCTAssertEqual(HTTPTransport.formEncode(pairs), item["encoded"] as? String)
        }
    }

    func testPKCEChallenge() {
        for item in cases("pkce") {
            XCTAssertEqual(PKCE.challenge(for: item["verifier"] as! String), item["challenge"] as? String)
        }
    }
}
