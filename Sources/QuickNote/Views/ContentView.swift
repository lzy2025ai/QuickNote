import SwiftUI

struct ContentView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var settings: AppSettings

    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var selection: SidebarItem? = .all
    @State private var detail: Detail?
    @State private var searchText = ""
    @State private var showNewProject = false
    /// 刚新建的笔记：列表滚动到它，编辑器自动聚焦标题（只生效一次）
    @State private var justCreatedID: UUID?

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// 切换左侧栏时清空搜索和右侧详情
    private var sidebarSelection: Binding<SidebarItem?> {
        Binding(
            get: { selection },
            set: { newValue in
                selection = newValue
                detail = nil
                searchText = ""
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
            SearchResultsView(query: searchText, detail: $detail)
        } else if selection == .clipboard {
            ClipListView(detail: $detail)
        } else {
            NoteListView(scope: selection ?? .all, detail: $detail, revealID: justCreatedID, onCreate: createNote)
        }
    }

    @ViewBuilder
    private var detailColumn: some View {
        switch detail {
        case .note(let id)? where store.notes.contains(where: { $0.id == id }):
            NoteEditorView(noteID: id, autoFocusTitle: id == justCreatedID, onAutoFocused: { justCreatedID = nil })
                .id(id)
        case .clip(let id)? where store.clips.contains(where: { $0.id == id }):
            ClipDetailView(clipID: id, onSavedAsNote: openNote)
        default:
            EmptyStateView(title: "未选择笔记", systemImage: "square.and.pencil", description: "⌘N 新建笔记 · ⌘F 搜索 · ⇧⌘N 新建项目")
        }
    }

    private func createNote() {
        searchText = ""
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
        selection = note.projectID.map { .project($0) } ?? .inbox
        detail = .note(note.id)
    }
}
