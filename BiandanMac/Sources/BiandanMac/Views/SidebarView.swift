import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let counts = model.counts

        List(selection: $model.sidebarSelection) {
            Section("视图") {
                ForEach(SidebarItem.views, id: \.self) { item in
                    NavigationLink(value: item) {
                        Label(item.title, systemImage: item.systemImage)
                    }
                    .badge(badge(for: item, counts: counts))
                }
            }

            Section {
                ForEach(model.snapshot.lists) { list in
                    NavigationLink(value: SidebarItem.list(list.id3)) {
                        Label {
                            Text(list.displayName)
                        } icon: {
                            Circle().fill(list.swatch).frame(width: 10, height: 10)
                        }
                    }
                    .badge(counts.perList[list.id3] ?? 0)
                    // 把任务卡片拖到待办单上即可移动。
                    .dropDestination(for: String.self) { identifiers, _ in
                        for identifier in identifiers {
                            if let item = model.snapshot.item(occurrenceID: identifier), item.task.id3 != list.id3 {
                                Task { await model.moveTask(item.task.id1, to: list.id3) }
                            }
                        }
                        return !identifiers.isEmpty
                    }
                    .themedContextMenu { close in
                        ListContextMenu(list: list, close: close).environment(model)
                    }
                    // ForEach 会按待办单编号（String）给行加隐式标签，外层的拖放和右键菜单又盖住了
                    // NavigationLink 自带的标签，导致选中值变成 nil、内容区回退到「全部待办」。这里显式标注。
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
                NavigationLink(value: SidebarItem.habits) {
                    Label(SidebarItem.habits.title, systemImage: SidebarItem.habits.systemImage)
                }
                .badge(model.habitSummaries.filter(\.needsCheckIn).count)
                NavigationLink(value: SidebarItem.focus) {
                    Label(SidebarItem.focus.title, systemImage: SidebarItem.focus.systemImage)
                }
                .badge(counts.focusThisWeek)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top) { AccountCard().padding(.horizontal, 10).padding(.top, 6) }
        .safeAreaInset(edge: .bottom) { SyncStatusBar().padding(10) }
        .navigationSplitViewColumnWidth(min: 210, ideal: 232, max: 300)
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
