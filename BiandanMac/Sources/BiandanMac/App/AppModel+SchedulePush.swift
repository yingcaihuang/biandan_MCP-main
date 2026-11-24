import Foundation

extension SchedulePayload {
    /// 任务 ID → 导入来源（CalDAV、订阅、系统日历、文件）。不在表里的任务是在便单里直接建的。
    static func sourceMap(store: LocalStore) -> [String: Source] {
        var map: [String: Source] = [:]
        for source in (try? store.importSources()) ?? [] {
            let tag = Source(kind: source.kind.rawValue, name: source.name)
            for link in (try? store.importLinks(sourceID: source.id)) ?? [] where !link.abandoned {
                map[link.taskID] = tag
            }
        }
        return map
    }
}

extension AppModel {
    func scheduleSourceMap() -> [String: SchedulePayload.Source] {
        SchedulePayload.sourceMap(store: store)
    }
}
