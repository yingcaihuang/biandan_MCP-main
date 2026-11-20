import Foundation

// MARK: - 专注记录（tomato），对应 Python create_focus / update_focus / delete_focus

extension BiandanService {
    /// 补记一条专注。主键是开始时间的毫秒数；重试同一笔补记时只核对、不重复新建。
    func createFocus(_ input: FocusInput) async throws -> (String, ChangeSet) {
        try await run {
            guard let minutes = FocusCodec.validMinutes(input.minutes) else {
                throw ServiceError("专注时长应在 1–1440 分钟之间。")
            }
            guard input.goodCount >= 0, input.badCount >= 0 else {
                throw ServiceError("好番茄和坏番茄数不能是负数。")
            }
            let identifier = FocusCodec.identifier(startedAt: input.startedAt)
            guard BusinessID.isValid(identifier), let numeric = Int64(identifier) else {
                throw ServiceError("开始时间无效。")
            }
            if let link = input.link {
                guard BusinessID.isValid(link.occurrenceID) else { throw ServiceError("关联的执行实例 ID 无效。") }
                _ = try await require(.showTask, link.occurrenceID)
            }
            let ended = input.startedAt.addingTimeInterval(Double(minutes) * 60)
            let log = FocusCodec.createLog(title: input.title, link: input.link, endTime: FocusCodec.endTimeText(ended))
            let expected: JSONObject = [
                "time": .int(numeric),
                "date": .string(LocalDate.today(input.startedAt).iso),
                "minutes": .of(minutes),
                "goodCount": .of(input.goodCount),
                "badCount": .of(input.badCount),
                "log": .string(log),
            ]
            let existing = try await find(.tomato, identifier, required: false)
            if let existing {
                let current = existing.attributes ?? [:]
                let same = expected.allSatisfy { AttributeMatch.matches(current[$0.key], $0.value, key: $0.key) }
                guard same else {
                    throw ServiceError("这个开始时间已经有一条专注记录，请换一个开始时间。")
                }
            }
            do {
                try await ensureRecord(.tomato, identifier, expected: expected, existing: existing)
            } catch {
                throw ServiceError(error.localizedDescription, mayHaveWritten: true, recovery: "请用同样的开始时间重试。")
            }
            return identifier
        }
    }

    /// 修改标题、好坏番茄数。标题写在 `log.eventTitle`，保留 `log` 里的其他键。
    func updateFocus(_ focusID: String, title: String? = nil, goodCount: Int? = nil,
                     badCount: Int? = nil) async throws -> ChangeSet {
        try await run {
            guard title != nil || goodCount != nil || badCount != nil else {
                throw ServiceError("没有要修改的内容。")
            }
            if let goodCount, goodCount < 0 { throw ServiceError("好番茄数不能是负数。") }
            if let badCount, badCount < 0 { throw ServiceError("坏番茄数不能是负数。") }
            let row = try await fresh(try await require(.tomato, focusID))
            var changes: JSONObject = [:]
            if let goodCount { changes["goodCount"] = .of(goodCount) }
            if let badCount { changes["badCount"] = .of(badCount) }
            if let title {
                let original = row.attributes?.string("log")
                let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
                if FocusLog(raw: original).eventTitle != trimmed || FocusLog(raw: original).object.isEmpty {
                    changes["log"] = .string(FocusCodec.updatedLog(original: original, title: trimmed))
                }
            }
            try await patch(row, changes)
        }.1
    }

    /// 删除专注记录；已不存在时视为成功。
    func deleteFocus(_ focusID: String) async throws -> ChangeSet {
        try await run {
            if let record = try await find(.tomato, focusID, required: false) {
                try await deleteRecord(record)
            }
        }.1
    }
}
