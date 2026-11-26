import Foundation

// MARK: - 主程序和小组件共用
//
// 这个文件同时编进主程序和小组件扩展（Widget/project.yml 引用它），所以只能用 Foundation。
// 小组件在沙盒里读不到主程序的数据库：主程序在数据变化后把今天起 3 天的待办写成 widget.json，
// 放在 App Group 共享目录里，小组件只读这一份。App Group 和链接的 scheme 写在两边的 Info.plist 里
// （BiandanAppGroup、BiandanURLScheme），正式版和开发版各用各的，互不干扰。

/// 主程序写给小组件的数据。
struct WidgetSnapshot: Codable, Equatable, Sendable {
    struct Item: Codable, Equatable, Sendable, Identifiable {
        /// 执行实例 ID（点小组件时用它定位）。跨天日程每天各列一条，ID 相同。
        var id: String
        var title: String
        /// 这一条属于哪一天，yyyy-MM-dd。
        var day: String
        /// 有具体时刻的才有；全天、没写时刻的为 nil。
        var start: Date?
        var end: Date?
        /// Quadrant.rawValue：0 重要且紧急、1 重要不紧急、2 不重要但紧急、3 都不。
        var quadrant: Int
        var list: String

        var allDay: Bool { start == nil }
    }

    static let currentVersion = 1

    var version = WidgetSnapshot.currentVersion
    var generatedAt: Date
    var signedIn: Bool
    /// 写入时的逾期数（主程序没运行时不会变）。
    var overdue: Int
    var items: [Item]

    static let empty = WidgetSnapshot(generatedAt: .distantPast, signedIn: false, overdue: 0, items: [])

    /// 某一天的待办：全天的在前，其余按开始时刻。
    func items(on day: String) -> [Item] {
        items.filter { $0.day == day }.sorted(by: WidgetSnapshot.order)
    }

    static func order(_ a: Item, _ b: Item) -> Bool {
        switch (a.start, b.start) {
        case (nil, nil): return a.title == b.title ? a.id < b.id : a.title < b.title
        case (nil, _): return true
        case (_, nil): return false
        case let (x?, y?): return x == y ? a.id < b.id : x < y
        }
    }
}

enum WidgetShared {
    static let groupKey = "BiandanAppGroup"
    static let schemeKey = "BiandanURLScheme"
    static let fileName = "widget.json"
    /// 小组件的 kind，刷新时按它找。
    static let kind = "biandan.today"

    static var appGroup: String? {
        let value = Bundle.main.object(forInfoDictionaryKey: groupKey) as? String
        return value?.isEmpty == false ? value : nil
    }

    static var scheme: String {
        let value = Bundle.main.object(forInfoDictionaryKey: schemeKey) as? String
        return value?.isEmpty == false ? value! : "biandan"
    }

    /// 共享目录里的 widget.json；没配置 App Group（swift run、测试）时为 nil。
    static func fileURL(group: String? = appGroup) -> URL? {
        guard let group,
              let base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else { return nil }
        return base.appendingPathComponent(fileName)
    }

    static func encode(_ snapshot: WidgetSnapshot) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(snapshot)
    }

    static func decode(_ data: Data) throws -> WidgetSnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(WidgetSnapshot.self, from: data)
    }

    static func load(group: String? = appGroup) -> WidgetSnapshot? {
        guard let url = fileURL(group: group), let data = try? Data(contentsOf: url) else { return nil }
        return try? decode(data)
    }

    static func dayString(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    // MARK: 链接：biandan://open、biandan://occurrence/<实例 ID>

    enum Link: Equatable, Sendable {
        case open
        case occurrence(String)
    }

    static func url(_ link: Link, scheme: String = scheme) -> URL {
        var parts = URLComponents()
        parts.scheme = scheme
        switch link {
        case .open:
            parts.host = "open"
        case .occurrence(let id):
            parts.host = "occurrence"
            parts.path = "/" + id
        }
        return parts.url ?? URL(string: scheme + "://open")!
    }

    /// 解析便单的链接；scheme 不对或格式不认识时为 nil。
    static func parse(_ url: URL, scheme: String = scheme) -> Link? {
        guard url.scheme?.lowercased() == scheme.lowercased(),
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        switch parts.host?.lowercased() {
        case "open", nil, "":
            return .open
        case "occurrence":
            let id = parts.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return id.isEmpty ? .open : .occurrence(id)
        default:
            return nil
        }
    }
}
