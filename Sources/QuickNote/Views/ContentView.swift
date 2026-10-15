import SwiftUI

struct ContentView: View {
    @EnvironmentObject var store: Store

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
        NavigationSplitView {
            SidebarView(
                selection: sidebarSelection,
                searchText: $searchText,
                searchFocused: $searchFocused,
                showNewProject: $showNewProject
            )
            .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 300)
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
            NoteEditorView(noteID: id).id(id)
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
        let note = store.addNote(projectID: projectID, tags: tags)
        detail = .note(note.id)
    }

    private func openNote(_ note: Note) {
        searchText = ""
        selection = note.projectID.map { .project($0) } ?? .inbox
        detail = .note(note.id)
    }
}
