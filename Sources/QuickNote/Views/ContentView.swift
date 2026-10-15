import SwiftUI

struct ContentView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var settings: AppSettings

    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    /// 刚新建的笔记：编辑器打开时自动聚焦并选中标题，直接输入即可替换默认标题
    @State private var justCreatedID: UUID?
    @State private var selection: SidebarItem? = .all
    @State private var detail: Detail?
    @State private var searchText = ""
    @State private var showNewProject = false
    @FocusState private var searchFocused: Bool

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
            SidebarView(
                selection: sidebarSelection,
                searchText: $searchText,
                searchFocused: $searchFocused,
                showNewProject: $showNewProject
            )
            .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 300)
            .modifier(HideSidebarToggle())
        } content: {
            contentColumn
                .navigationSplitViewColumnWidth(min: 260, ideal: 310, max: 450)
        } detail: {
            detailColumn
        }
        .frame(minWidth: 860, minHeight: 500)
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
            NoteListView(scope: selection ?? .all, detail: $detail, onCreate: createNote)
        }
    }

    @ViewBuilder
    private var detailColumn: some View {
        switch detail {
        case .note(let id)? where store.notes.contains(where: { $0.id == id }):
            NoteEditorView(noteID: id, autoFocusTitle: id == justCreatedID).id(id)
        case .clip(let id)? where store.clips.contains(where: { $0.id == id }):
            ClipDetailView(clipID: id, onSavedAsNote: openNote)
        default:
            VStack(spacing: 10) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(.tertiary)
                Text("选择或新建一条笔记").foregroundStyle(.secondary)
                Text("⌘N 新建笔记 · ⌘F 搜索 · ⇧⌘N 新建项目 · ⇧⌘Y 剪贴板")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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

/// 去掉系统自动加在标题栏上的“收起侧栏”按钮（macOS 14+；改用菜单 显示 › 显示 / 隐藏侧栏 ⌃⌘S）
private struct HideSidebarToggle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content.toolbar(removing: .sidebarToggle)
        } else {
            content
        }
    }
}
