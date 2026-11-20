import XCTest
@testable import BiandanMac

final class CoreTests: XCTestCase {
    func testLocalDateBasics() {
        let today = LocalDate(iso: "2026-11-20")!
        XCTAssertEqual(today.weekday, 5)          // 周五
        XCTAssertEqual(today.pythonWeekday, 4)
        XCTAssertEqual(LocalDate(daysSinceEpoch: 0).iso, "1970-01-01")
        for offset in stride(from: -80_000, through: 80_000, by: 997) {
            let day = LocalDate(daysSinceEpoch: offset)
            XCTAssertEqual(day.daysSinceEpoch, offset)
            XCTAssertEqual(LocalDate(iso: day.iso), day)
            XCTAssertEqual(day.adding(days: 1).weekday, floorMod(day.weekday + 1, 7))
        }
        XCTAssertEqual(LocalDate(iso: "2026-01-31")!.adding(months: 1).iso, "2026-02-28")
        XCTAssertEqual(LocalDate(iso: "2024-02-28")!.adding(days: 1).iso, "2024-02-29")
        XCTAssertEqual(today.lastOfMonth.iso, "2026-11-30")
        XCTAssertNil(LocalDate(iso: "2026-2-01"))
        XCTAssertNil(LocalDate(iso: "2026-02-30"))
        XCTAssertNil(LocalDate(iso: nil))
    }

    func testLocalTime() {
        XCTAssertEqual(LocalTime(text: "09:30")?.text, "09:30:00")
        XCTAssertEqual(LocalTime(text: "23:59:59")?.shortText, "23:59")
        XCTAssertNil(LocalTime(text: "24:00"))
        XCTAssertNil(LocalTime(text: "9:30"))
    }

    func testFloorArithmetic() {
        XCTAssertEqual(floorMod(-1, 7), 6)
        XCTAssertEqual(floorDiv(-1, 100), -1)
        XCTAssertEqual(floorDiv(305, 100), 3)
    }

    func testLunarHeader() {
        // 与截图「2026/11/20 丙午十月十二」一致。
        XCTAssertEqual(LunarCalendar.headerText(for: LocalDate(iso: "2026-11-20")!), "丙午十月十二")
        XCTAssertEqual(LunarCalendar.headerText(for: LocalDate(iso: "2026-02-17")!), "丙午正月初一")
        XCTAssertEqual(LunarCalendar.headerText(for: LocalDate(iso: "2025-01-29")!), "乙巳正月初一")
        XCTAssertEqual(LunarCalendar.dayName(10), "初十")
        XCTAssertEqual(LunarCalendar.dayName(21), "廿一")
    }

    func testBusinessID() {
        XCTAssertTrue(BusinessID.isValid("1"))
        XCTAssertTrue(BusinessID.isValid("9007199254740991"))
        XCTAssertFalse(BusinessID.isValid("9007199254740992"))
        XCTAssertFalse(BusinessID.isValid("0"))
        XCTAssertFalse(BusinessID.isValid("01"))
        XCTAssertFalse(BusinessID.isValid("-1"))
    }

    func testListColor() {
        let color = ListColor(raw: 305)
        XCTAssertEqual(color.sortIndex, 3)
        XCTAssertEqual(color.colorIndex, 5)
        XCTAssertEqual(ListColor(sortIndex: 3, colorIndex: 22).raw, 322)
        XCTAssertEqual(ListColor(sortIndex: 2, colorIndex: 22).raw, 222)
        XCTAssertEqual(ListColor.palette.count, 25)
    }

    func testGoalAndFlags() {
        XCTAssertEqual(TaskGoal(subtaskCount: 3).raw, 700)
        XCTAssertEqual(TaskGoal(subtaskCount: 0).raw, 1)
        XCTAssertEqual(TaskGoal(unitTimeNumber: 0), .count(1))
        XCTAssertEqual(TaskGoal(unitTimeNumber: 500).targetCount, 2)
        XCTAssertTrue(TaskGoal(unitTimeNumber: 500).includes(subtask: 2))
        XCTAssertFalse(TaskGoal(unitTimeNumber: 500).includes(subtask: 1))
        XCTAssertEqual(OccurrenceProgress(completedCount: 500, goal: .checklist(mask: 7)).completedSubtaskIndices, [0, 2])

        let flags = RemindFlags(rawValue: 3)
        XCTAssertTrue(flags.contains(.time))
        XCTAssertTrue(flags.contains(.location))

        let unit = LoopUnit(raw: 201)
        XCTAssertEqual(unit.unit, .week)
        XCTAssertEqual(unit.filter, .workdays)
        XCTAssertEqual(LoopUnit(raw: 7).unit, nil)
        XCTAssertEqual(LoopKind(raw: 5), .habit)
    }

    func testFocusLog() {
        let log = FocusLog(raw: #"{"eventId":123,"eventTitle":"写方案","eventType":4,"endTime":"Thu Nov 19 2026","extra":true}"#)
        XCTAssertEqual(log.eventID, "123")
        XCTAssertEqual(log.eventTitle, "写方案")
        XCTAssertEqual(log.eventType, 4)
        XCTAssertEqual(log.object["extra"], .bool(true))
        XCTAssertNil(FocusLog(raw: #"{"eventId":-1}"#).eventID)
        let plain = FocusLog(raw: "Thu Nov 19 2026 15:25:00 GMT+0800")
        XCTAssertEqual(plain.endTime, "Thu Nov 19 2026 15:25:00 GMT+0800")
        XCTAssertNil(FocusLog(raw: "").plainText)
    }

    func testJSONValueKeepsTypes() throws {
        let value = try JSONValue.parse(Data(#"{"a":1,"b":true,"c":1.5,"d":"1","e":null,"f":[0]}"#.utf8))
        guard case .object(let object) = value else { return XCTFail("不是对象") }
        XCTAssertEqual(object["a"], .int(1))
        XCTAssertEqual(object["b"], .bool(true))
        XCTAssertEqual(object["c"], .double(1.5))
        XCTAssertEqual(object["d"]?.identifierString, "1")
        XCTAssertEqual(object["e"], .null)
        XCTAssertEqual(object["f"], .array([.int(0)]))
        let roundTrip = try JSONValue.parse(value.serialized())
        XCTAssertEqual(roundTrip, value)
    }

    func testNormalizeRecord() throws {
        let wrapped = JSONValue(any: ["recordID": "abc", "version": 3,
                                      "fields": ["id1": ["value": 12], "taskTitle": ["value": "x"]]] as [String: Any])
        let record = try RawRecord.normalize(wrapped, kind: .task)
        XCTAssertEqual(record.cloudID, "abc")
        XCTAssertEqual(record.version, 3)
        XCTAssertEqual(record.attributes?["id1"], .int(12))
        XCTAssertEqual(record.businessID, "12")

        let idOnly = try RawRecord.normalize(JSONValue(any: ["id": "r1"] as [String: Any]), kind: .showTask)
        XCTAssertNil(idOnly.attributes)
        XCTAssertThrowsError(try RawRecord.normalize(JSONValue(any: ["version": 1] as [String: Any]), kind: .task))
    }

    func testTaskDefDefaultsAndNormalization() {
        let task = TaskDef(record: RawRecord(kind: .task, cloudID: "c", version: 1, createdTime: nil, editedTime: nil,
                                             attributes: ["id1": .string("42"), "id3": .int(0), "taskTitle": .string("t")]))
        XCTAssertEqual(task.id1, "42")
        XCTAssertEqual(task.id3, TodoList.defaultID)
        XCTAssertEqual(task.unitTimeNumber, 1)
        XCTAssertEqual(task.validStartTime, "00:00:00")
        XCTAssertEqual(task.validEndTime, "23:59:59")
        XCTAssertFalse(task.hasCoordinate)
        XCTAssertFalse(task.isRepeating)
    }
}
