import Foundation

// MARK: - 统计 → 导入同步：按时间范围汇总同步日志

struct ImportSyncBucket: Identifiable, Hashable, Sendable {
    let start: LocalDate
    var successes = 0
    var failures = 0
    var added = 0
    var updated = 0
    var removed = 0

    var id: LocalDate { start }
}

struct ImportSourceStatsRow: Identifiable, Hashable, Sendable {
    let id: String
    var name: String
    var syncs = 0
    var failures = 0
    var added = 0
    var lastAt: Date?

    var successRate: Double? { syncs > 0 ? Double(syncs - failures) / Double(syncs) : nil }
}

struct ImportSyncSummary {
    var start: LocalDate
    var end: LocalDate
    var buckets: [ImportSyncBucket]
    var syncs = 0
    var successes = 0
    var failures = 0
    var fetched = 0
    /// 新增，含便单里删掉后重建的。
    var added = 0
    var updated = 0
    var removed = 0
    var writeFailed = 0
    /// 修改来源设置的次数（不算同步）。
    var edits = 0
    var averageMs: Double?
    var p95Ms: Double?
    var sources: [ImportSourceStatsRow] = []
    var triggers: [AIUsageCount] = []
    var errors: [AIUsageCount] = []
    /// 范围内失败的同步，最新的在前，最多 10 条。
    var recentFailures: [ImportSyncLog] = []

    var successRate: Double? { syncs > 0 ? Double(successes) / Double(syncs) : nil }
}

enum ImportSyncStats {
    static func summary(_ logs: [ImportSyncLog], range: StatsRange, today: LocalDate, weekStart: Int,
                        calendar: Calendar = .current) -> ImportSyncSummary {
        let end = today
        var start = today.adding(days: -(range.rawValue - 1))
        if range.bucketDays == 7 {
            start = start.adding(days: -floorMod(start.weekday - weekStart, 7))
        }
        var buckets: [ImportSyncBucket] = []
        var day = start
        while day <= end {
            buckets.append(ImportSyncBucket(start: day))
            day = day.adding(days: range.bucketDays)
        }
        var summary = ImportSyncSummary(start: start, end: end, buckets: buckets)
        let startDate = start.date(calendar: calendar)
        var durations: [Double] = []
        var sources: [String: ImportSourceStatsRow] = [:]
        var triggers: [ImportSyncTrigger: Int] = [:]
        var errors: [String: Int] = [:]
        var failures: [ImportSyncLog] = []

        for log in logs {
            let local = LocalDate.today(log.startedAt, calendar: calendar)
            guard local >= start, local <= end else { continue }
            if log.trigger == .edited {
                summary.edits += 1
                continue
            }
            let offset = calendar.dateComponents([.day], from: startDate, to: local.date(calendar: calendar)).day ?? 0
            let index = min(max(offset / range.bucketDays, 0), summary.buckets.count - 1)
            var row = sources[log.sourceID] ?? ImportSourceStatsRow(id: log.sourceID, name: log.sourceName)
            row.syncs += 1
            if row.lastAt.map({ log.startedAt > $0 }) ?? true {
                row.lastAt = log.startedAt
                row.name = log.sourceName
            }
            summary.syncs += 1
            triggers[log.trigger, default: 0] += 1
            if log.ok {
                summary.successes += 1
                summary.buckets[index].successes += 1
                durations.append(Double(log.durationMs))
            } else {
                summary.failures += 1
                summary.buckets[index].failures += 1
                row.failures += 1
                errors[errorKind(log.message), default: 0] += 1
                failures.append(log)
            }
            summary.fetched += log.fetched
            summary.added += log.added
            summary.updated += log.updated
            summary.removed += log.removed
            summary.writeFailed += log.failed
            summary.buckets[index].added += log.added
            summary.buckets[index].updated += log.updated
            summary.buckets[index].removed += log.removed
            row.added += log.added
            sources[log.sourceID] = row
        }

        let sorted = durations.sorted()
        if !sorted.isEmpty {
            summary.averageMs = sorted.reduce(0, +) / Double(sorted.count)
            summary.p95Ms = AIUsageStats.percentile(sorted, 0.95)
        }
        summary.sources = sources.values.sorted { $0.syncs == $1.syncs ? $0.name < $1.name : $0.syncs > $1.syncs }
        let order: [ImportSyncTrigger] = [.automatic, .manual, .added]
        summary.triggers = order.compactMap { trigger in
            guard let count = triggers[trigger], count > 0 else { return nil }
            return AIUsageCount(id: trigger.rawValue, title: trigger.title, count: count)
        }
        summary.errors = errors.map { AIUsageCount(id: $0.key, title: $0.key, count: $0.value) }
            .sorted { $0.count == $1.count ? $0.title < $1.title : $0.count > $1.count }
        summary.recentFailures = Array(failures.sorted { $0.startedAt > $1.startedAt }.prefix(10))
        return summary
    }

    /// 失败原因归类（日志里错误信息后面可能跟着「；退避 / 暂停」说明，只看第一段）。
    static func errorKind(_ message: String) -> String {
        let first = message.components(separatedBy: "；").first ?? message
        if first.contains("用户名或密码") { return "账户或密码不对" }
        if first.contains("日历访问权限") || first.contains("没有权限") { return "没有权限" }
        if first.contains("钥匙串") { return "钥匙串" }
        if first.contains("网络错误") { return "网络错误" }
        if first.contains("没找到 CalDAV") || first.contains("HTTP 404") || first.contains("已经不存在") {
            return "地址或日历不存在"
        }
        if first.contains("别的站点") { return "重定向被拦截" }
        if first.contains("看不懂") || first.contains("不是日历") || first.contains("太大") { return "返回内容无法读取" }
        if let range = first.range(of: #"HTTP \d{3}"#, options: .regularExpression) {
            return "服务器错误（" + String(first[range]) + "）"
        }
        if first.contains("分类") { return "便单写入失败" }
        return "其他"
    }

    /// 同步结果趋势：成功 / 失败次数。
    static func outcomePoints(_ buckets: [ImportSyncBucket], calendar: Calendar = .current) -> [AIChartPoint] {
        var points: [AIChartPoint] = []
        for bucket in buckets {
            let date = bucket.start.date(calendar: calendar)
            points.append(AIChartPoint(id: bucket.start.iso + "-ok", date: date, series: "成功",
                                       value: Double(bucket.successes)))
            points.append(AIChartPoint(id: bucket.start.iso + "-fail", date: date, series: "失败",
                                       value: Double(bucket.failures)))
        }
        return points
    }

    /// 写入便单的条数趋势：新增 / 更新 / 放弃。
    static func changePoints(_ buckets: [ImportSyncBucket], calendar: Calendar = .current) -> [AIChartPoint] {
        var points: [AIChartPoint] = []
        for bucket in buckets {
            let date = bucket.start.date(calendar: calendar)
            points.append(AIChartPoint(id: bucket.start.iso + "-add", date: date, series: "新增",
                                       value: Double(bucket.added)))
            points.append(AIChartPoint(id: bucket.start.iso + "-upd", date: date, series: "更新",
                                       value: Double(bucket.updated)))
            points.append(AIChartPoint(id: bucket.start.iso + "-rm", date: date, series: "放弃",
                                       value: Double(bucket.removed)))
        }
        return points
    }

    static func durationText(_ ms: Double?) -> String {
        guard let ms else { return "—" }
        return ms < 1000 ? "\(Int(ms.rounded())) 毫秒" : String(format: "%.1f 秒", ms / 1000)
    }
}
