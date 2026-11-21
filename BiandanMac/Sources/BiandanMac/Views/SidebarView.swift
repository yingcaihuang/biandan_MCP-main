import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let counts = model.counts
        let conflictCount = model.scheduleConflicts.count

        List(selection: $model.sidebarSelection) {
            Section("视图") {
                // 每一行都显式标注 .tag(SidebarItem)：List(selection:) 只按行标签写回选中值，
                // 写死的行没有隐式标签，NavigationLink(value:) 也不会代劳，否则侧栏高亮了但选中值是 nil。
                ForEach(SidebarItem.views, id: \.self) { item in
                    if item == .conflicts {
                        conflictRow(conflictCount)
                    } else {
                        Label(item.title, systemImage: item.systemImage)
                            .badge(badge(for: item, counts: counts))
                            .sidebarDrop(item, model: model)
                            .tag(item)
                    }
                }
            }

            Section {
                ForEach(model.snapshot.lists) { list in
                    Label {
                        Text(list.displayName)
                    } icon: {
                        Circle().fill(list.swatch).frame(width: 10, height: 10)
                    }
                    .badge(counts.perList[list.id3] ?? 0)
                    // 把任务卡片拖到待办单上即可移动（多选时整批移动）。
                    .sidebarDrop(.list(list.id3), model: model)
                    .themedContextMenu { close in
                        ListContextMenu(list: list, close: close).environment(model)
                    }
                    // ForEach 按分类编号（String）给行加隐式标签，与选中值类型不符，必须显式标注。
                    .tag(SidebarItem.list(list.id3))
                }
                .onMove { source, destination in
                    var ordered = model.snapshot.lists
                    ordered.move(fromOffsets: source, toOffset: destination)
                    Task { await model.reorderLists(ordered) }
                }
            } header: {
                HStack {
                    Text("分类")
                    Spacer()
                    Button {
                        model.listEditor = ListEditorRequest(list: nil)
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.borderless)
                    .help("新建分类")
                    .disabled(model.authState != .signedIn)
                }
            }

            Section("记录") {
                Label(SidebarItem.habits.title, systemImage: SidebarItem.habits.systemImage)
                    .badge(model.habitSummaries.filter(\.needsCheckIn).count)
                    .tag(SidebarItem.habits)
                Label(SidebarItem.focus.title, systemImage: SidebarItem.focus.systemImage)
                    .badge(counts.focusThisWeek)
                    .tag(SidebarItem.focus)
                Label(SidebarItem.stats.title, systemImage: SidebarItem.stats.systemImage)
                    .tag(SidebarItem.stats)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top) { AccountCard().padding(.horizontal, 10).padding(.top, 6) }
        .safeAreaInset(edge: .bottom) { SyncStatusBar().padding(10) }
        .navigationSplitViewColumnWidth(min: 210, ideal: 232, max: 300)
    }

    /// 日程冲突：有冲突时图标和数字变红。
    private func conflictRow(_ count: Int) -> some View {
        let icon = count > 0 ? AnyShapeStyle(Theme.overdue) : AnyShapeStyle(.tint)
        let number: Text? = count > 0 ? Text(verbatim: "\(count)").foregroundColor(Theme.overdue).bold() : nil
        return Label {
            Text(SidebarItem.conflicts.title)
        } icon: {
            Image(systemName: SidebarItem.conflicts.systemImage)
                .foregroundStyle(icon)
        }
        .badge(number)
        .help(count > 0 ? "近 30 天有 \(count) 处日程时间重叠" : "近 30 天没有日程冲突")
        .tag(SidebarItem.conflicts)
    }

    private func badge(for item: SidebarItem, counts: SidebarCounts) -> Int {
        switch item {
        case .today: return counts.today
        case .next7: return counts.next7Days
        case .all: return counts.allPending
        case .undated: return counts.undated
        case .collected: return counts.collected
        case .important: return counts.important
        default: return 0
        }
    }
}

struct SyncStatusBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 6) {
            switch model.syncStatus {
            case .syncing(let message):
                ProgressView().controlSize(.mini)
                Text(message).lineLimit(1)
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.overdue)
                Text(message).lineLimit(2).help(message)
            case .idle where model.isSavingInBackground:
                ProgressView().controlSize(.mini)
                Text(verbatim: "正在保存 \(model.backgroundOperations) 项更改…").lineLimit(1)
            case .idle:
                Circle().fill(Color(hex: 0x34C759)).frame(width: 8, height: 8)
                if let last = model.lastSyncedAt {
                    Text("已同步 · ") + Text(last, format: .dateTime.hour().minute())
                } else {
                    Text("尚未同步")
                }
            }
            Spacer(minLength: 0)
            Button {
                Task { await model.syncNow() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(model.syncStatus.isSyncing)
            .help("立即同步（⌘R）")
        }
        .font(.system(size: 11.5))
        .foregroundStyle(Theme.subtext)
        if !model.snapshot.warnings.isEmpty {
            Label("\(model.snapshot.warnings.count) 个数据问题", systemImage: "exclamationmark.bubble")
                .font(.system(size: 11))
                .foregroundStyle(Theme.overdue)
                .help(model.snapshot.warnings.joined(separator: "\n"))
        }
        }
    }
}
