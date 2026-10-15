import SwiftUI

struct ContentView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var settings: AppSettings

    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var selection: SidebarItem? = .all
    @State private var detail: Detail?
    @State private var searchText = ""
    /// 实际用于搜索的关键词：停止输入 0.15 秒后才更新，避免每个按键都全量搜索
    @State private var query = ""
    @State private var showNewProject = false
    /// 刚新建的笔记：列表滚动到它，编辑器自动聚焦标题（只生效一次）
    @State private var justCreatedID: UUID?

    private var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// 切换左侧栏时清空搜索和右侧详情
    private var sidebarSelection: Binding<SidebarItem?> {
        Binding(
            get: { selection },
            set: { newValue in
                selection = newValue
                detail = nil
                searchText = ""
                query = ""
            }
        )
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(selection: sidebarSelection, showNewProject: $showNewProject)
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 320)
        } content: {
            contentColumn
                .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 480)
        } detail: {
            detailColumn
        }
        // 系统搜索框，放在工具栏右侧（与“备忘录”“邮件”一致），⌘F 聚焦
        .searchable(text: $searchText, placement: .toolbar, prompt: "搜索笔记、剪贴板、#标签")
        .task(id: searchText) {
            if searchText.isEmpty {
                query = ""
                return
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            query = searchText
        }
        .frame(minWidth: 900, minHeight: 540)
        .sheet(isPresented: $showNewProject) {
            ProjectEditSheet(project: nil) { created in
                sidebarSelection.wrappedValue = .project(created.id)
            }
            .environmentObject(store)
        }
        .onReceive(NotificationCenter.default.publisher(for: .qnNewNote)) { _ in createNote() }
        .onReceive(NotificationCenter.default.publisher(for: .qnNewProject)) { _ in showNewProject = true }
        .onReceive(NotificationCenter.default.publisher(for: .qnToggleSidebar)) { _ in
            withAnimation { columnVisibility = columnVisibility == .all ? .doubleColumn : .all }
        }
        .onReceive(NotificationCenter.default.publisher(for: .qnShowClipboard)) { _ in
            sidebarSelection.wrappedValue = .clipboard
            if let first = store.sortedClips.first { detail = .clip(first.id) }
        }
    }

    @ViewBuilder
    private var contentColumn: some View {
        if isSearching {
            SearchResultsView(query: query, detail: $detail)
        } else if selection == .clipboard {
            ClipListView(detail: $detail)
        } else {
            NoteListView(scope: selection ?? .all, detail: $detail, revealID: justCreatedID, onCreate: createNote)
        }
    }

    @ViewBuilder
    private var detailColumn: some View {
        if case .note(let id)? = detail, let note = store.notes.first(where: { $0.id == id }) {
            NoteEditorView(note: note, autoFocusTitle: id == justCreatedID, onAutoFocused: { justCreatedID = nil })
                .id(id)
        } else if case .clip(let id)? = detail, store.clips.contains(where: { $0.id == id }) {
            ClipDetailView(clipID: id, onSavedAsNote: openNote)
        } else {
            EmptyStateView(title: "未选择笔记", systemImage: "square.and.pencil", description: "⌘N 新建笔记 · ⌘F 搜索 · ⇧⌘N 新建项目")
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
        detail = .note(note.id)
    }

    private func openNote(_ note: Note) {
        justCreatedID = nil
        searchText = ""
        query = ""
        selection = note.projectID.map { .project($0) } ?? .inbox
        detail = .note(note.id)
    }
}
