import Foundation

/// 乐观更新：写入云端前先在内存快照里改好，界面立即生效。
extension DataSnapshot {
    mutating func editOccurrence(_ id2: String, _ body: (inout Occurrence) -> Void) {
        guard let index = occurrences.firstIndex(where: { $0.id2 == id2 }) else { return }
        body(&occurrences[index])
        let updated = occurrences[index]
        if var siblings = occurrencesByTask[updated.id1],
           let position = siblings.firstIndex(where: { $0.id2 == id2 }) {
            siblings[position] = updated
            occurrencesByTask[updated.id1] = siblings
        }
    }

    mutating func editTask(_ id1: String, _ body: (inout TaskDef) -> Void) {
        guard var task = tasks[id1] else { return }
        body(&task)
        tasks[id1] = task
    }
}
