import Foundation

// MARK: - 待同步队列（outbox）

/// 哪些失败可以放进队列稍后重试：连不上服务、超时、408 / 429 / 5xx、续期服务暂时不可用。
/// 业务校验失败、409、404、需要重新登录都不算。
enum OutboxPolicy {
    static func isTransient(_ error: Error) -> Bool {
        switch error {
        case let failure as OperationFailure:
            return failure.transient
        case let service as ServiceError:
            return service.transient
        case let cloud as CloudError:
            if cloud.isNetwork { return true }
            guard let status = cloud.status else { return false }
            return status == 408 || status == 429 || status >= 500
        case let auth as AuthError:
            if case .renewalUnavailable(let status) = auth {
                guard let status else { return true }
                return status == 429 || status >= 500
            }
            return false
        case is URLError:
            return true
        default:
            return false
        }
    }
}

extension ProgressAction: Codable {}

/// 可以安全重放的业务命令：只携带业务 ID 和目标值，重放多次结果相同。
/// 新建任务、删除任务、改重复规则需要先预览再确认，不入队。
enum OutboxCommand: Codable, Sendable, Equatable {
    case completeOccurrence(id: String)
    case changeProgress(id: String, action: ProgressAction, count: Int?)
    case setSubtask(id: String, index: Int, checked: Bool)
    case updateTask(taskID: String, title: String?, remark: String?, important: Bool?, urgent: Bool?, collected: Bool?)
    case moveTask(taskID: String, listID: String)
    case setTimeReminder(taskID: String, date: String?, time: String?, enabled: Bool)
    case setLocation(taskID: String, name: String?, latitude: Double?, longitude: Double?, remind: Bool?)
    case clearLocation(taskID: String)
    case rescheduleTask(taskID: String, start: String, end: String?, startTime: String?, endTime: String?)
    case rescheduleOccurrence(id: String, start: String, startTime: String?, endTime: String?)
    case clearSchedule(taskID: String)
    case editGoal(taskID: String, subtasks: [String]?, targetCount: Int?)
    case updateList(listID: String, name: String?, colorIndex: Int?, sortIndex: Int?)
    case createFocus(FocusInput)
    case updateFocus(id: String, title: String?, goodCount: Int?, badCount: Int?)
    case deleteFocus(id: String)

    /// 命令名，写进 outbox.command 列，便于排查。
    var name: String { String(String(describing: self).prefix { $0 != "(" }) }

    private static func day(_ text: String) throws -> LocalDate {
        guard let value = LocalDate(iso: text) else { throw ServiceError("待同步命令里的日期无效：\(text)") }
        return value
    }

    private static func clock(_ text: String?) -> LocalTime? { text.flatMap { LocalTime(text: $0) } }

    func execute(on s: BiandanService) async throws -> ChangeSet {
        switch self {
        case .completeOccurrence(let id):
            return try await s.completeOccurrence(id).1
        case .changeProgress(let id, let action, let count):
            return try await s.changeProgress(id, action: action, count: count).1
        case .setSubtask(let id, let index, let checked):
            return try await s.setSubtask(id, index: index, checked: checked).1
        case .updateTask(let taskID, let title, let remark, let important, let urgent, let collected):
            return try await s.updateTask(taskID, title: title, remark: remark, important: important,
                                          urgent: urgent, collected: collected)
        case .moveTask(let taskID, let listID):
            return try await s.moveTask(taskID, to: listID)
        case .setTimeReminder(let taskID, let date, let time, let enabled):
            return try await s.setTimeReminder(taskID, date: try date.map(Self.day), time: Self.clock(time), enabled: enabled)
        case .setLocation(let taskID, let name, let latitude, let longitude, let remind):
            return try await s.setLocation(taskID, name: name, latitude: latitude, longitude: longitude, remind: remind)
        case .clearLocation(let taskID):
            return try await s.setLocation(taskID, clear: true)
        case .rescheduleTask(let taskID, let start, let end, let startTime, let endTime):
            return try await s.rescheduleTask(taskID, start: try Self.day(start), end: try end.map(Self.day),
                                              startTime: Self.clock(startTime), endTime: Self.clock(endTime))
        case .rescheduleOccurrence(let id, let start, let startTime, let endTime):
            return try await s.rescheduleOccurrence(id, start: try Self.day(start),
                                                    startTime: Self.clock(startTime), endTime: Self.clock(endTime)).1
        case .clearSchedule(let taskID):
            return try await s.clearSchedule(taskID)
        case .editGoal(let taskID, let subtasks, let targetCount):
            return try await s.editTaskGoal(taskID, subtasks: subtasks, targetCount: targetCount)
        case .updateList(let listID, let name, let colorIndex, let sortIndex):
            return try await s.updateList(listID, name: name, colorIndex: colorIndex, sortIndex: sortIndex)
        case .createFocus(let input):
            return try await s.createFocus(input).1
        case .updateFocus(let id, let title, let goodCount, let badCount):
            return try await s.updateFocus(id, title: title, goodCount: goodCount, badCount: badCount)
        case .deleteFocus(let id):
            return try await s.deleteFocus(id)
        }
    }
}

/// outbox.args_json 的内容。
struct OutboxPayload: Codable, Sendable, Equatable {
    var label: String
    var command: OutboxCommand
}

/// outbox 表的一行。
struct OutboxEntry: Sendable, Equatable {
    static let pending = "pending"
    static let failed = "failed"

    var opID: String
    var command: String
    var argsJSON: String
    var createdAt: String
    var attempts: Int
    var lastError: String?
    var state: String

    var payload: OutboxPayload? {
        try? JSONDecoder().decode(OutboxPayload.self, from: Data(argsJSON.utf8))
    }

    static func make(label: String, command: OutboxCommand, now: Date = Date()) -> OutboxEntry? {
        guard let data = try? JSONEncoder().encode(OutboxPayload(label: label, command: command)),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return OutboxEntry(opID: UUID().uuidString, command: command.name, argsJSON: json,
                           createdAt: ISO8601DateFormatter().string(from: now), attempts: 0,
                           lastError: nil, state: pending)
    }
}
