import SwiftUI

struct ContentView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var settings: AppSettings

    @State private var showSidebar = true
    @State private var selection: SidebarItem? = .all
    @State private var detail: Detail?
    @State private var searchText = ""
    /// 实际用于搜索的关键词：停止输入 0.15 秒后才更新，避免每个按键都全量搜索
    @State private var query = ""
    @State private var showNewProject = false
    /// 刚新建的笔记：列表滚动到它，编辑器自动聚焦标题（只生效一次）
    @State private var justCreatedID: UUID?
    @FocusState private var searchFocused: Bool

    private var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// 切换左侧栏时清空搜索和右侧详情
    private var sidebarSelection: Binding<SidebarItem?> {
        Binding(
            get: { selection },
            set: { newValue in
                withAnimation(Motion.quick) {
                    selection = newValue
                    detail = nil
                    searchText = ""
                    query = ""
                }
            }
        )
    }

    var body: some View {
        HStack(spacing: 0) {
            if showSidebar {
                SidebarView(selection: sidebarSelection, showNewProject: $showNewProject)
                    .frame(width: Metrics.sidebarWidth)
                    .overlay(alignment: .trailing) { Rectangle().fill(Palette.line).frame(width: 1) }
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
            listColumn
                .frame(width: Metrics.listWidth)
                .background(Palette.list)
                .overlay(alignment: .trailing) { Rectangle().fill(Palette.line).frame(width: 1) }
            detailColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Palette.paper)
        }
        .ignoresSafeArea()
        .frame(minWidth: 900, minHeight: 560)
        .tint(Palette.seal)
        .task(id: searchText) {
            if searchText.isEmpty {
                query = ""
                return
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            query = searchText
        }
        .sheet(isPresented: $showNewProject) {
            ProjectEditSheet(project: nil) { created in
                sidebarSelection.wrappedValue = .project(created.id)
            }
            .environmentObject(store)
        }
        .onReceive(NotificationCenter.default.publisher(for: .qnNewNote)) { _ in createNote() }
        .onReceive(NotificationCenter.default.publisher(for: .qnNewProject)) { _ in showNewProject = true }
        .onReceive(NotificationCenter.default.publisher(for: .qnFocusSearch)) { _ in searchFocused = true }
        .onReceive(NotificationCenter.default.publisher(for: .qnToggleSidebar)) { _ in
            withAnimation(Motion.standard) { showSidebar.toggle() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .qnShowClipboard)) { _ in
            sidebarSelection.wrappedValue = .clipboard
            if let first = store.sortedClips.first { detail = .clip(first.id) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .qnOpenNote)) { note in
            if let id = note.object as? UUID, let n = store.notes.first(where: { $0.id == id }) {
                openNote(n)
            }
        }
    }

    // MARK: 中间栏

    private var listColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: showSidebar ? 18 : Metrics.titlebarHeight)
            header
                .padding(.horizontal, 20)
                .padding(.bottom, 14)
            SearchPill(text: $searchText, focused: $searchFocused)
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            content
        }
    }

    private var header: some View {
        let info = headerInfo
        return HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 9) {
                    if let color = info.color {
                        RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
                    }
                    Text(info.title)
                        .font(.song(20, bold: true))
                        .tracking(1)
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                }
                Text(info.subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
            }
            Spacer()
            if info.canCreate {
                Button(action: createNote) {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Palette.onButton)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(Palette.button))
                        .shadow(color: Palette.shadow.opacity(2), radius: 5, y: 3)
                }
                .buttonStyle(.plain)
                .help("新建笔记（⌘N）")
            }
        }
    }

    private var headerInfo: (title: String, subtitle: String, color: Color?, canCreate: Bool) {
        if isSearching {
            let count = store.searchNotes(query).count + store.searchClips(query).count
            return ("搜索结果", "\(count) 条", nil, false)
        }
        switch selection ?? .all {
        case .all:
            return ("全部笔记", noteSubtitle(.all), nil, true)
        case .inbox:
            return ("收件箱", noteSubtitle(.inbox), nil, true)
        case .clipboard:
            let today = store.clips.filter { Calendar.current.isDateInToday($0.createdAt) }.count
            return ("剪贴板", settings.clipboardEnabled ? "自动记录中 · 今日 \(today) 条" : "已暂停记录", nil, false)
        case .project(let id):
            let p = store.project(id)
            return (p?.name ?? "项目", noteSubtitle(.project(id)), p?.tint ?? Palette.seal, true)
        case .tag(let t):
            return ("#" + t, noteSubtitle(.tag(t)), nil, true)
        }
    }

    private func noteSubtitle(_ scope: SidebarItem) -> String {
        let notes = store.notes(for: scope)
        guard let latest = notes.map(\.updatedAt).max() else { return "还没有笔记" }
        return "\(notes.count) 则笔记 · 更新于" + RelativeDate.short(latest)
    }

    @ViewBuilder
    private var content: some View {
        if isSearching {
            SearchResultsView(query: query, detail: $detail)
        } else if selection == .clipboard {
            ClipListView(detail: $detail)
        } else {
            NoteListView(scope: selection ?? .all, detail: $detail, revealID: justCreatedID)
        }
    }

    // MARK: 右侧

    @ViewBuilder
    private var detailColumn: some View {
        if case .note(let id)? = detail, let note = store.notes.first(where: { $0.id == id }) {
            NoteEditorView(note: note, autoFocusTitle: id == justCreatedID, onAutoFocused: { justCreatedID = nil })
                .id(id)
                .transition(.opacity)
        } else if case .clip(let id)? = detail, store.clips.contains(where: { $0.id == id }) {
            ClipDetailView(clipID: id, onSavedAsNote: openNote)
                .id(id)
                .transition(.opacity)
        } else {
            EmptyStateView(title: "选一则笔记，或新建一则", detail: "⌘N 新建　⌘F 搜索\n⌥Space 随手记一笔")
        }
    }

    private func createNote() {
        searchText = ""
        query = ""
        var projectID: UUID?
        var tags: [String] = []
        switch selection {
        case .project(let id)?: projectID = id
        case .tag(let t)?: tags = [t]
        case .clipboard?, nil: selection = .all
        default: break
        }
        let title = settings.defaultNoteTitle(projectName: store.project(projectID)?.name)
        let note = store.addNote(projectID: projectID, title: title, tags: tags)
        justCreatedID = note.id
        withAnimation(Motion.quick) { detail = .note(note.id) }
    }

    private func openNote(_ note: Note) {
        justCreatedID = nil
        searchText = ""
        query = ""
        selection = note.projectID.map { .project($0) } ?? .inbox
        detail = .note(note.id)
    }
}

/// 中间栏顶部的搜索框，⌘F 聚焦，Esc 清空
struct SearchPill: View {
    @Binding var text: String
    var focused: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Palette.muted)
            TextField("搜索笔记、剪贴板、#标签", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(Palette.ink)
                .focused(focused)
                .onExitCommand { text = "" }
            if text.isEmpty {
                Text("⌘F")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.muted)
            } else {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Palette.muted)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(Capsule().fill(Palette.field))
    }
}

enum RelativeDate {
    /// 今天显示时间，昨天显示“昨天”，一周内显示星期，再早显示日期
    static func short(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "今日 " + ChineseDate.time(date) }
        if cal.isDateInYesterday(date) { return "昨天" }
        if let days = cal.dateComponents([.day], from: cal.startOfDay(for: date), to: cal.startOfDay(for: Date())).day,
           days < 7 {
            return ChineseDate.weekday(date)
        }
        return ChineseDate.month(date) + "\(cal.component(.day, from: date))日"
    }
}
