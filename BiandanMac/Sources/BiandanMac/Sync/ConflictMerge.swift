import Foundation

/// 409（版本已变化）后的三方合并：用户看到的旧值 base、云端最新值 latest、要写入的值 desired。
/// - 云端没动这个字段：保留我们的改动，重试。
/// - 云端已经改成同样的值：不用再写。
/// - 云端把同一个字段改成了别的值：冲突，以云端为准。
enum ConflictMerge {
    /// 409 后最多重试几次。
    static let maxRetries = 3

    struct Resolution: Equatable {
        /// 还需要写入的字段。
        var remaining: JSONObject
        /// 被其他设备改成了不同值的字段。
        var conflicts: [String]
    }

    static func resolve(base: JSONObject, latest: JSONObject, desired: JSONObject) -> Resolution {
        var remaining: JSONObject = [:]
        var conflicts: [String] = []
        for (key, value) in desired {
            let now = latest[key]
            if AttributeMatch.matches(now, value, key: key) { continue }
            let untouched: Bool
            if let old = base[key] {
                untouched = AttributeMatch.matches(now, old, key: key)
            } else {
                untouched = now == nil || now == .null
            }
            if untouched {
                remaining[key] = value
            } else {
                conflicts.append(key)
            }
        }
        return Resolution(remaining: remaining, conflicts: conflicts.sorted())
    }

    /// 字段的中文名，用于冲突提示；同类字段合并成一个名字。
    static func label(_ key: String) -> String {
        switch key {
        case "taskTitle": return "标题"
        case "taskContent": return "备注或子任务"
        case "isImportant": return "重要"
        case "isUrgency": return "紧急"
        case "isCollectible": return "收藏"
        case "id3": return "待办单"
        case "startTime", "endTime", "haveNoTime": return "日期"
        case "validStartTime", "validEndTime": return "时刻"
        case "isRemind", "remindDate", "remindTime": return "提醒"
        case "location", "latitude", "longitude": return "地点"
        case "unitTimeNumber": return "完成目标"
        case "completedCount", "isFinish", "recentFinishedTime": return "进度"
        case "isLoop", "loopSet", "loopBaseNumber", "loopUnit", "loopDate", "duration": return "重复规则"
        case "favoritesName": return "名称"
        case "favoritesColor": return "颜色或排序"
        case "goodCount", "badCount": return "番茄数"
        case "log": return "专注标题"
        default: return key
        }
    }

    static func message(kind: RecordKind, conflicts: [String]) -> String {
        var seen = Set<String>()
        let names = conflicts.map(label).filter { seen.insert($0).inserted }
        return "这条\(kind.title)已被其他设备修改（\(names.joined(separator: "、"))），已以云端为准，请确认后再改。"
    }
}
