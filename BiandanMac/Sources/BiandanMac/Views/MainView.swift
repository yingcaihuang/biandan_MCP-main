import SwiftUI

/// 主窗口：侧栏 / 内容区 / 检查器 三栏。
struct MainView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
        } detail: {
            ContentArea()
                .inspector(isPresented: $model.showInspector) {
                    InspectorView()
                        .inspectorColumnWidth(min: 320, ideal: 372, max: 480)
                }
        }
        .onAppear { model.undoManager = undoManager }
        .background(WindowLevelSetter(floating: model.pinMainWindow))
        .background(MainKeyMonitor(model: model))
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "搜索标题、备注、子任务")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                PomodoroToolbarButton()
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.pinMainWindow.toggle()
                } label: {
                    Image(systemName: model.pinMainWindow ? "pin.fill" : "pin")
                        .foregroundStyle(model.pinMainWindow ? Theme.accent : Color.primary)
                }
                .help(model.pinMainWindow ? "取消置顶" : "窗口置顶（浮动在其他窗口之上）")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.showInspector.toggle()
                } label: {
                    Image(systemName: "sidebar.trailing")
                }
                .help("显示或隐藏检查器（⌥⌘I）")
            }
        }
        .sheet(item: $model.newTaskPreset) { preset in
            NewTaskSheet(preset: preset).environment(model)
        }
        .sheet(item: $model.deleteRequest) { item in
            DeleteTaskSheet(item: item).environment(model)
        }
        .sheet(item: $model.listEditor) { request in
            ListEditorSheet(request: request).environment(model)
        }
        .sheet(item: $model.listDeleteRequest) { list in
            ListDeleteSheet(list: list).environment(model)
        }
        .sheet(isPresented: $model.signOutRequested) {
            SignOutSheet().environment(model)
        }
        .sheet(item: $model.recurrenceRequest) { task in
            RecurrenceSheet(task: task).environment(model)
        }
        .sheet(item: $model.focusEditor) { request in
            FocusEditorSheet(request: request).environment(model)
        }
        .sheet(item: $model.focusDeleteRequest) { record in
            FocusDeleteSheet(record: record).environment(model)
        }
        .sheet(isPresented: $model.batchDeleteRequested) {
            BatchDeleteSheet().environment(model)
        }
    }
}

struct ContentArea: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let item = model.sidebarSelection ?? .all
        VStack(spacing: 0) {
            ContentHeader(item: item)
            // 问候卡片与今日完成率在所有任务视图顶部显示（统计始终是今天），记录页不显示。
            if !item.isRecordPage {
                TodaySummaryCard(item: item)
            }
            if !item.isRecordPage {
                QuickAddBar()
            }
            Group {
                if item == .focus {
                    FocusListView()
                } else if item == .habits {
                    HabitListView()
                } else if item == .stats {
                    StatsView()
                } else if item == .conflicts {
                    ConflictListView()
                } else {
                    switch model.effectiveMode {
                    case .list: OccurrenceListView(item: item)
                    case .quadrant: QuadrantView()
                    case .calendar: CalendarView()
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // 冲突只算一次，卡片按实例 ID 取角标数据。
            .environment(\.conflictIndex, model.conflictIndex)
        }
        .background(Theme.background)
        .overlay(alignment: .bottom) {
            VStack(spacing: 8) {
                if !model.multiSelection.isEmpty {
                    BatchActionBar()
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                OperationBanner()
            }
            .animation(.easeInOut(duration: 0.2), value: model.multiSelection.isEmpty)
        }
    }
}

struct ContentHeader: View {
    @Environment(AppModel.self) private var model
    let item: SidebarItem

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            Text(model.title(for: item))
                .font(.system(size: 26, weight: .heavy))
                .lineLimit(1)
            HStack(alignment: .lastTextBaseline, spacing: 6) {
                dateText
                Text(LunarCalendar.headerText(for: model.today) + "·" + LocalDate.weekdayNames[model.today.weekday])
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(hex: 0x3B372F))
            }
            Spacer(minLength: 8)
            if !item.isRecordPage {
                ThemedSegmented(selection: Binding(get: { model.effectiveMode }, set: { model.setMode($0) }),
                                options: ContentMode.allCases.map { ThemeOption(value: $0, title: $0.title) },
                                glass: true)
                    .help("切换视图（⌘1 – ⌘3）")

                if model.effectiveMode == .quadrant {
                    ThemedSegmented(selection: Binding(get: { model.quadrantRange },
                                                       set: { model.quadrantRange = $0 }),
                                    options: QuadrantRange.allCases.map { ThemeOption(value: $0, title: $0.title) },
                                    glass: true)
                        .help("四象限显示的时间范围")
                }
            }
            Button {
                model.newTaskPreset = model.makeNewTaskPreset()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Theme.accent))
            }
            .buttonStyle(.plain)
            .help("新建任务（⌘N）")
        }
        .padding(.horizontal, 22)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    private var dateText: some View {
        let today = model.today
        let slash = Text("/").foregroundStyle(Theme.accent)
        return (Text(String(today.year)) + slash + Text(String(format: "%02d", today.month))
                + slash + Text(String(format: "%02d", today.day)))
            .font(.system(size: 20, weight: .heavy))
    }
}
