import Foundation

/// 从 holiday-cn（数据来自国务院办公厅放假安排通知）补充内置数据之后年份的调休。
/// 换算后的翻转日缓存在 `~/Library/Application Support/BiandanMac/holidays/makeup-<年>.json`。
actor HolidayUpdater {
    static let shared = HolidayUpdater()
    static let sourcePattern = "https://raw.githubusercontent.com/NateScarlet/holiday-cn/master/%d.json"

    struct CachedYear: Codable, Equatable, Sendable {
        var year: Int
        /// 翻转日，`YYYY-MM-DD`。
        var days: [String]
        /// 数据依据的国务院通知链接。
        var papers: [String]
        var fetchedAt: Date

        var dates: Set<LocalDate> { Set(days.compactMap { LocalDate(iso: $0) }) }
    }

    enum Outcome: Equatable, Sendable {
        case upToDate(lastYear: Int)
        case updated(lastYear: Int, added: [Int])
        case notPublished(year: Int)
        case failed(String)
    }

    struct ParseError: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private let directory: URL?

    init(directory: URL? = HolidayUpdater.defaultDirectory()) {
        self.directory = directory
    }

    static func defaultDirectory() -> URL? {
        return AppPaths.supportDirectory()?.appendingPathComponent("holidays", isDirectory: true)
    }

    /// 读取本地缓存并安装，返回覆盖末年。启动时同步调用，不访问网络。
    @discardableResult
    static func loadCache(directory: URL? = defaultDirectory()) -> Int {
        guard let directory,
              let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        else { return ChinaMakeup.lastYear }
        var years: [Int: Set<LocalDate>] = [:]
        for file in files where file.lastPathComponent.hasPrefix("makeup-") && file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file), data.count <= 262_144,
                  let cached = try? JSONDecoder().decode(CachedYear.self, from: data) else { continue }
            years[cached.year] = cached.dates
        }
        return ChinaMakeup.install(years)
    }

    /// 补充到「今年 + 1」为止。某一年还没发布（404）时停止，不算失败。
    func checkForUpdates(now: Date = Date()) async -> Outcome {
        let target = Calendar(identifier: .gregorian).component(.year, from: now) + 1
        var added: [Int] = []
        while ChinaMakeup.lastYear < target {
            let year = ChinaMakeup.lastYear + 1
            do {
                guard let cached = try await fetch(year: year) else {
                    return added.isEmpty ? .notPublished(year: year) : .updated(lastYear: ChinaMakeup.lastYear, added: added)
                }
                save(cached)
                ChinaMakeup.install([year: cached.dates])
                added.append(year)
            } catch {
                return .failed(error.localizedDescription)
            }
        }
        return added.isEmpty ? .upToDate(lastYear: ChinaMakeup.lastYear) : .updated(lastYear: ChinaMakeup.lastYear, added: added)
    }

    private func fetch(year: Int) async throws -> CachedYear? {
        guard let url = URL(string: String(format: Self.sourcePattern, year)) else { return nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(from: url)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { return nil }
        guard status == 200 else { throw ParseError(message: "调休数据服务返回 HTTP \(status)") }
        guard data.count <= 262_144 else { throw ParseError(message: "调休数据过大") }
        return try Self.parse(data, year: year)
    }

    private func save(_ cached: CachedYear) {
        guard let directory else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(cached) else { return }
        try? data.write(to: directory.appendingPathComponent("makeup-\(cached.year).json"), options: .atomic)
    }

    /// 解析 holiday-cn 的年度 JSON，换算成翻转日。
    static func parse(_ data: Data, year: Int, now: Date = Date()) throws -> CachedYear {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ParseError(message: "调休数据格式不对")
        }
        guard (root["year"] as? Int) == year else { throw ParseError(message: "调休数据年份不符") }
        guard let items = root["days"] as? [[String: Any]], !items.isEmpty else {
            throw ParseError(message: "\(year) 年调休数据为空")
        }
        var entries: [(date: LocalDate, isOffDay: Bool)] = []
        for item in items {
            guard let text = item["date"] as? String, let date = LocalDate(iso: text), date.year == year,
                  let off = item["isOffDay"] as? Bool else {
                throw ParseError(message: "\(year) 年调休数据里有无效日期")
            }
            entries.append((date, off))
        }
        let flips = ChinaMakeup.flipDays(year: year, entries: entries)
        let papers = (root["papers"] as? [String] ?? []).filter { $0.hasPrefix("https://www.gov.cn/") }
        return CachedYear(year: year, days: flips.map(\.iso).sorted(), papers: papers, fetchedAt: now)
    }
}
