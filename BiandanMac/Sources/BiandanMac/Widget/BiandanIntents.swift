import AppIntents
import Foundation

// MARK: - 快捷指令（App Intents）
//
// 都在主程序里执行，和界面上的操作走同一套逻辑：添加日程用快速添加（可以走 AI），完成可以 ⌘Z 撤销，
// 识别剪贴板弹出确认卡片，打开日程和点通知一样定位。被快捷指令拉起时先等启动、读完凭据再执行。
// 编译时由 Tools/build_app.sh 生成 Metadata.appintents，系统才认得这些指令。

struct BiandanIntentError: Error, CustomLocalizedStringResourceConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var localizedStringResource: LocalizedStringResource { "\(message)" }
}

@MainActor
enum IntentSupport {
    /// 等 AppModel 建好、读完凭据。没登录时报错。
    static func model() async throws -> AppModel {
        var waited = 0
        while AppModel.current == nil, waited < 100 {
            try await Task.sleep(for: .milliseconds(100))
            waited += 1
        }
        guard let model = AppModel.current else { throw BiandanIntentError("便单还没启动好，请稍后再试。") }
        if model.authState == .checking {
            Task { await model.bootstrap() }
            waited = 0
            while model.authState == .checking, waited < 150 {
                try await Task.sleep(for: .milliseconds(100))
                waited += 1
            }
        }
        guard model.authState == .signedIn else { throw BiandanIntentError("便单还没登录，请先打开便单登录。") }
        return model
    }

    /// 「今天 14:30」「明天」「11月28日」「无日期」。
    nonisolated static func when(_ day: LocalDate?, _ time: LocalTime?, today: LocalDate) -> String {
        guard let day else { return "无日期" }
        let name: String
        switch today.days(to: day) {
        case 0: name = "今天"
        case 1: name = "明天"
        case 2: name = "后天"
        case -1: name = "昨天"
        default: name = "\(day.month)月\(day.day)日"
        }
        return time.map { name + " " + $0.shortText } ?? name
    }

    /// 有具体时刻的才返回开始时刻（全天的返回 nil）。
    static func clock(_ item: OccurrenceItem) -> LocalTime? {
        MenuBarAgenda.slot(item) != nil ? item.occurrence.startClock : nil
    }

    static func title(_ item: OccurrenceItem) -> String {
        let title = item.task.taskTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "（无标题）" : title
    }

    /// 今天没完成的（不含逾期），按开始日期、时刻排。
    static func todayItems(_ model: AppModel) -> [OccurrenceItem] {
        let today = model.today
        return sorted(model.snapshot.items(OccurrenceQuery())
            .filter { $0.occurrence.overlaps(today, today) && !$0.isOverdue(today: today) })
    }

    static func sorted(_ items: [OccurrenceItem]) -> [OccurrenceItem] {
        items.sorted {
            let a = ($0.occurrence.startDate?.iso ?? "", clock($0)?.shortText ?? "", $0.id)
            let b = ($1.occurrence.startDate?.iso ?? "", clock($1)?.shortText ?? "", $1.id)
            return a < b
        }
    }
}

// MARK: - 日程（执行实例）

struct ScheduleEntity: AppEntity, Identifiable {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "日程"
    static let defaultQuery = ScheduleQuery()

    let id: String
    let title: String
    /// 「今天 14:30 · 工作」
    let detail: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(detail)")
    }

    @MainActor
    init(_ item: OccurrenceItem, model: AppModel) {
        id = item.id
        title = IntentSupport.title(item)
        let list = model.snapshot.lists.first { $0.id3 == item.task.id3 }?.displayName ?? "未分类"
        let day = item.task.undated ? nil : item.occurrence.startDate
        var parts = [IntentSupport.when(day, IntentSupport.clock(item), today: model.today), list]
        if item.status != .pending { parts.append(item.status.title) }
        detail = parts.joined(separator: " · ")
    }
}

struct ScheduleQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [ScheduleEntity] {
        let model = try await IntentSupport.model()
        return identifiers.compactMap { model.snapshot.item(occurrenceID: $0) }.map { ScheduleEntity($0, model: model) }
    }

    /// 选日程时先列出逾期和今天没完成的。
    @MainActor
    func suggestedEntities() async throws -> [ScheduleEntity] {
        let model = try await IntentSupport.model()
        let today = model.today
        let overdue = IntentSupport.sorted(model.snapshot.items(OccurrenceQuery()).filter { $0.isOverdue(today: today) })
        return (overdue + IntentSupport.todayItems(model)).prefix(50).map { ScheduleEntity($0, model: model) }
    }

    /// 按标题搜：没完成的，逾期、今后 30 天和无日期的。
    @MainActor
    func entities(matching string: String) async throws -> [ScheduleEntity] {
        let model = try await IntentSupport.model()
        let needle = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let horizon = model.today.adding(days: 30)
        var query = OccurrenceQuery()
        query.includeUndated = true
        let found = model.snapshot.items(query).filter { item in
            if !item.task.undated, let start = item.occurrence.startDate, start > horizon { return false }
            return needle.isEmpty || item.task.taskTitle.lowercased().contains(needle)
        }
        return IntentSupport.sorted(found).prefix(50).map { ScheduleEntity($0, model: model) }
    }
}

// MARK: - 指令

struct AddScheduleIntent: AppIntent {
    static let title: LocalizedStringResource = "添加日程"
    static let description = IntentDescription("用一句话在便单里新建日程，日期、时刻、分类按快速添加的规则识别（设置里开了 AI 时先交给 AI 整理）。")

    @Parameter(title: "内容", description: "例如「明天下午3点和产品开会 @工作 #重要」",
               inputOptions: String.IntentInputOptions(multiline: false))
    var text: String

    static var parameterSummary: some ParameterSummary { Summary("添加日程：\(\.$text)") }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<ScheduleEntity?> & ProvidesDialog {
        let model = try await IntentSupport.model()
        let content = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { throw BiandanIntentError("日程内容是空的。") }
        var preset = NewTaskPreset()
        preset.date = model.today
        guard let outcome = await model.quickAddInput(content, preset: preset) else {
            throw BiandanIntentError("没认出日程标题。")
        }
        guard await model.createTask(outcome.input) else {
            throw BiandanIntentError(model.operationError ?? "添加失败。")
        }
        let input = outcome.input
        var line = "已添加：\(input.title)（\(IntentSupport.when(input.startDate, input.startTime, today: model.today))）"
        if let note = outcome.note { line += "。" + note }
        let entity = model.selectedOccurrenceID.flatMap { model.snapshot.item(occurrenceID: $0) }
            .map { ScheduleEntity($0, model: model) }
        return .result(value: entity, dialog: "\(line)")
    }
}

struct TodayScheduleIntent: AppIntent {
    static let title: LocalizedStringResource = "今天还有什么"
    static let description = IntentDescription("列出今天还没完成的日程，以及有几项逾期。")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[ScheduleEntity]> & ProvidesDialog {
        let model = try await IntentSupport.model()
        let items = IntentSupport.todayItems(model)
        let overdue = model.snapshot.counts(today: model.today).overdue
        var lines: [String] = []
        if items.isEmpty {
            lines.append("今天没有待办了。")
        } else {
            lines.append("今天还有 \(items.count) 项：")
            for item in items.prefix(5) {
                lines.append((IntentSupport.clock(item).map { $0.shortText + " " } ?? "") + IntentSupport.title(item))
            }
            if items.count > 5 { lines.append("还有 \(items.count - 5) 项…") }
        }
        if overdue > 0 { lines.append("另有 \(overdue) 项逾期。") }
        let text = lines.joined(separator: "\n")
        return .result(value: items.map { ScheduleEntity($0, model: model) }, dialog: "\(text)")
    }
}

struct CompleteScheduleIntent: AppIntent {
    static let title: LocalizedStringResource = "完成日程"
    static let description = IntentDescription("把一条日程标记为完成（重复日程只完成这一次），可以在便单里 ⌘Z 撤销。")

    @Parameter(title: "日程")
    var schedule: ScheduleEntity

    static var parameterSummary: some ParameterSummary { Summary("完成 \(\.$schedule)") }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let model = try await IntentSupport.model()
        guard let item = model.snapshot.item(occurrenceID: schedule.id) else {
            throw BiandanIntentError("找不到这条日程，可能已经被删除。")
        }
        let title = IntentSupport.title(item)
        guard item.status == .pending else { return .result(dialog: "「\(title)」已经是\(item.status.title)了。") }
        await model.toggleCompletion(item)
        guard model.snapshot.item(occurrenceID: item.id)?.status == .completed else {
            throw BiandanIntentError(model.operationError ?? "没能完成「\(title)」。")
        }
        return .result(dialog: "已完成「\(title)」。")
    }
}

struct CaptureClipboardIntent: AppIntent {
    static let title: LocalizedStringResource = "识别剪贴板里的日程"
    static let description = IntentDescription("识别剪贴板里的文字或图片，弹出确认卡片，勾选后添加到便单。")

    @MainActor
    func perform() async throws -> some IntentResult {
        let model = try await IntentSupport.model()
        ScheduleCaptureFlow.fromClipboard(model: model, anchor: FloatingBallController.shared.frame)
        return .result()
    }
}

struct OpenScheduleIntent: OpenIntent {
    static let title: LocalizedStringResource = "在便单里打开日程"
    static let description = IntentDescription("打开便单主窗口，选中这条日程并显示详情。")

    @Parameter(title: "日程")
    var target: ScheduleEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        let model = try await IntentSupport.model()
        guard model.snapshot.item(occurrenceID: target.id) != nil else {
            throw BiandanIntentError("找不到这条日程，可能已经被删除。")
        }
        model.revealOccurrence(target.id)
        return .result()
    }
}

struct BiandanShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: AddScheduleIntent(),
                    phrases: ["用\(.applicationName)添加日程", "在\(.applicationName)里记一下"],
                    shortTitle: "添加日程", systemImageName: "plus.circle")
        AppShortcut(intent: TodayScheduleIntent(),
                    phrases: ["\(.applicationName)今天还有什么", "看看\(.applicationName)今天的日程"],
                    shortTitle: "今天还有什么", systemImageName: "sun.max")
        AppShortcut(intent: CompleteScheduleIntent(),
                    phrases: ["在\(.applicationName)里完成日程"],
                    shortTitle: "完成日程", systemImageName: "checkmark.circle")
        AppShortcut(intent: CaptureClipboardIntent(),
                    phrases: ["用\(.applicationName)识别剪贴板"],
                    shortTitle: "识别剪贴板", systemImageName: "doc.on.clipboard")
        AppShortcut(intent: OpenScheduleIntent(),
                    phrases: ["在\(.applicationName)里打开日程"],
                    shortTitle: "打开日程", systemImageName: "arrow.up.forward.app")
    }
}
