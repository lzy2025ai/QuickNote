import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 笔记列表

struct NoteListView: View {
    @EnvironmentObject var store: Store
    let scope: SidebarItem
    @Binding var detail: Detail?
    /// 新建笔记后滚动到它
    var revealID: UUID?
    let onCreate: () -> Void

    private var title: String {
        switch scope {
        case .all: return "全部笔记"
        case .inbox: return "收件箱"
        case .clipboard: return "剪贴板"
        case .project(let id): return store.project(id)?.name ?? "项目"
        case .tag(let t): return "#" + t
        }
    }

    private var showsProject: Bool {
        if case .project = scope { return false }
        return true
    }

    var body: some View {
        let notes = store.notes(for: scope)
        ScrollViewReader { proxy in
            List(selection: $detail) {
                ForEach(notes) { note in
                    NoteRow(note: note, showProject: showsProject)
                        .tag(Detail.note(note.id))
                        .contextMenu { NoteContextMenu(note: note) }
                }
            }
            .listStyle(.inset)
            .onDeleteCommand {
                if case .note(let id) = detail { store.deleteNote(id) }
            }
            .overlay {
                if notes.isEmpty {
                    EmptyStateView(title: "没有笔记", systemImage: "note.text", description: "按 ⌘N 新建一条")
                }
            }
            .onChange(of: revealID) { id in
                guard let id else { return }
                withAnimation { proxy.scrollTo(id, anchor: .top) }
            }
        }
        .navigationTitle(title)
        .navigationSubtitle("\(notes.count) 条笔记")
        .toolbar {
            ToolbarItem {
                Button(action: onCreate) {
                    Label("新建笔记", systemImage: "square.and.pencil")
                }
                .help("新建笔记（⌘N）")
            }
        }
    }
}

struct NoteContextMenu: View {
    @EnvironmentObject var store: Store
    let note: Note

    var body: some View {
        Button(note.pinned ? "取消置顶" : "置顶") {
            store.mutateNote(note.id) { $0.pinned.toggle() }
        }
        Menu("移动到") {
            Button("收件箱") { store.mutateNote(note.id) { $0.projectID = nil } }
            Divider()
            ForEach(store.projects) { p in
                Button(p.name) { store.mutateNote(note.id) { $0.projectID = p.id } }
            }
        }
        Divider()
        Button("拷贝全部内容") { Pasteboard.copy(note.plainText) }
        Button("拷贝为 Markdown") {
            Pasteboard.copy(MarkdownExporter.markdown(for: note, projectName: store.project(note.projectID)?.name))
        }
        Button("导出为 Markdown…") { MarkdownExporter.exportNote(note, store: store) }
        Divider()
        Button("删除", role: .destructive) { store.deleteNote(note.id) }
    }
}

/// 仿“备忘录”的行样式：标题一行，日期 + 摘要一行，必要时再显示项目 / 标签
struct NoteRow: View {
    @EnvironmentObject var store: Store
    let note: Note
    var showProject = false
    var query: String = ""

    var body: some View {
        let terms = SearchText.terms(query)
        let preview = terms.isEmpty ? note.preview : SearchText.snippet(note.preview, terms: terms)
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                if note.pinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                }
                Text(SearchText.highlight(note.displayTitle, terms: terms))
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
            }
            HStack(spacing: 6) {
                Text(RelativeDate.short(note.updatedAt))
                    .foregroundStyle(Color.primary.opacity(0.75))
                Text(preview.isEmpty ? AttributedString("无更多内容") : SearchText.highlight(preview, terms: terms))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .font(.system(size: 12))

            let project = showProject ? store.project(note.projectID) : nil
            if project != nil || !note.tags.isEmpty || !note.attachments.isEmpty {
                HStack(spacing: 8) {
                    if let project {
                        HStack(spacing: 3) {
                            Image(systemName: project.icon).foregroundStyle(project.tint)
                            Text(project.name)
                        }
                    }
                    if !note.attachments.isEmpty {
                        Image(systemName: "paperclip")
                    }
                    if !note.tags.isEmpty {
                        Text(note.tags.map { "#" + $0 }.joined(separator: " "))
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
    }
}

enum RelativeDate {
    /// 今天显示时间，昨天显示“昨天”，一周内显示星期，再早显示日期
    static func short(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
        if cal.isDateInYesterday(date) { return "昨天" }
        if let days = cal.dateComponents([.day], from: cal.startOfDay(for: date), to: cal.startOfDay(for: Date())).day,
           days < 7 {
            return date.formatted(.dateTime.weekday(.wide))
        }
        return date.formatted(.dateTime.year().month(.defaultDigits).day())
    }
}

struct EmptyStateView: View {
    let title: String
    let systemImage: String
    var description: String?

    var body: some View {
        if #available(macOS 14.0, *) {
            ContentUnavailableView(title, systemImage: systemImage, description: description.map { Text($0) })
        } else {
            VStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(.tertiary)
                Text(title).font(.title3).foregroundStyle(.secondary)
                if let description {
                    Text(description).font(.callout).foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - 编辑器

/// 编辑器只改本地草稿，停止输入 0.4 秒后再整体写回数据（以及切换笔记 / 关闭时立即写回）。
/// 这样输入时不会每个按键都触发整个窗口刷新，也不会打断输入法。
struct NoteEditorView: View {
    @EnvironmentObject var store: Store
    let noteID: UUID
    var autoFocusTitle = false
    var onAutoFocused: () -> Void = {}

    @State private var draft: Note?
    @State private var commitWork: DispatchWorkItem?
    @State private var confirmDelete = false
    @State private var dropTargeted = false
    @FocusState private var titleFocused: Bool

    var body: some View {
        Group {
            if draft != nil {
                editor
            } else {
                Color.clear
            }
        }
        .onAppear { syncFromStore(store.notes) }
        .onReceive(store.$notes) { syncFromStore($0) }
        .onDisappear { commitNow() }
    }

    private var note: Binding<Note> {
        Binding(
            get: { draft ?? Note() },
            set: { newValue in
                draft = newValue
                scheduleCommit()
            }
        )
    }

    /// 首次加载，或笔记在别处被修改（列表右键、iCloud 同步）时更新草稿
    private func syncFromStore(_ notes: [Note]) {
        guard let stored = notes.first(where: { $0.id == noteID }) else { return }
        let isFirstLoad = draft == nil
        if isFirstLoad || (commitWork == nil && stored != draft) {
            draft = stored
        }
        if isFirstLoad && autoFocusTitle {
            DispatchQueue.main.async {
                titleFocused = true
                onAutoFocused()
            }
        }
    }

    private func scheduleCommit() {
        commitWork?.cancel()
        let work = DispatchWorkItem { commitNow() }
        commitWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func commitNow() {
        commitWork?.cancel()
        commitWork = nil
        if let draft { store.updateNote(draft) }
    }

    private var editor: some View {
        let n = note.wrappedValue
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Text(metaLine(n))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)

                TextField("标题", text: note.title)
                    .textFieldStyle(.plain)
                    .font(.system(size: 22, weight: .bold))
                    .focused($titleFocused)

                TagsEditor(tags: note.tags, suggestions: store.allTags.map(\.name))

                FieldsEditor(fields: note.fields)

                if !n.attachments.isEmpty {
                    AttachmentsView(attachments: n.attachments) { name in
                        note.wrappedValue.attachments.removeAll { $0 == name }
                        commitNow()
                        store.deleteAttachmentFile(name)
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 14)
            .padding(.bottom, 6)

            NoteTextView(text: note.content, placeholder: "开始记录…")
        }
        .background(Color(nsColor: .textBackgroundColor))
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6]))
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image) else { return }
                    DispatchQueue.main.async { addAttachment(fileURL: url) }
                }
            }
            return true
        }
        .toolbar { editorToolbar }
        .alert("删除这条笔记？", isPresented: $confirmDelete) {
            Button("删除", role: .destructive) {
                commitWork?.cancel()
                commitWork = nil
                store.deleteNote(noteID)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("删除后无法恢复。")
        }
    }

    private func metaLine(_ n: Note) -> String {
        var parts = [n.updatedAt.formatted(date: .long, time: .shortened)]
        if let p = store.project(n.projectID) { parts.append(p.name) }
        return parts.joined(separator: " · ")
    }

    @ToolbarContentBuilder
    private var editorToolbar: some ToolbarContent {
        let n = note.wrappedValue
        let project = store.project(n.projectID)
        ToolbarItemGroup {
            Menu {
                Picker("移动到", selection: note.projectID) {
                    Label("收件箱", systemImage: "tray").tag(UUID?.none)
                    ForEach(store.projects) { p in
                        Label(p.name, systemImage: p.icon).tag(Optional(p.id))
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Label(project?.name ?? "收件箱", systemImage: project?.icon ?? "tray")
            }
            .help("移动到项目")

            Button {
                note.wrappedValue.pinned.toggle()
                commitNow()
            } label: {
                Label(n.pinned ? "取消置顶" : "置顶", systemImage: n.pinned ? "pin.slash" : "pin")
            }
            .help(n.pinned ? "取消置顶" : "置顶")

            Menu {
                Button("选择图片…") { pickImages() }
                Button("粘贴剪贴板中的图片") {
                    if let png = Pasteboard.imagePNGData(), let name = store.importAttachment(pngData: png) {
                        note.wrappedValue.attachments.append(name)
                        commitNow()
                    }
                }
            } label: {
                Label("添加图片", systemImage: "photo.badge.plus")
            }
            .help("添加图片（也可以直接拖进来）")

            Menu {
                Button("拷贝全部内容") { Pasteboard.copy(n.plainText) }
                Button("拷贝为 Markdown") {
                    Pasteboard.copy(MarkdownExporter.markdown(for: n, projectName: project?.name))
                }
                Divider()
                Button("导出为 Markdown 文件…") {
                    commitNow()
                    MarkdownExporter.exportNote(n, store: store)
                }
            } label: {
                Label("分享", systemImage: "square.and.arrow.up")
            }
            .help("拷贝 / 导出")

            Button {
                confirmDelete = true
            } label: {
                Label("删除", systemImage: "trash")
            }
            .help("删除笔记")
        }
    }

    private func addAttachment(fileURL: URL) {
        guard let name = store.importAttachment(fileURL: fileURL) else { return }
        note.wrappedValue.attachments.append(name)
        commitNow()
    }

    private func pickImages() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        panel.urls.forEach(addAttachment)
    }
}

// MARK: - 标签

struct TagsEditor: View {
    @Binding var tags: [String]
    let suggestions: [String]
    @State private var input = ""

    private var available: [String] {
        suggestions.filter { !tags.contains($0) }
    }

    var body: some View {
        HStack(spacing: 6) {
            Menu {
                if available.isEmpty {
                    Text("还没有其他标签")
                } else {
                    ForEach(available, id: \.self) { t in
                        Button("#" + t) { tags.append(t) }
                    }
                }
            } label: {
                Image(systemName: "tag")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("选择已有标签")

            ForEach(tags, id: \.self) { tag in
                TagChip(name: tag) { tags.removeAll { $0 == tag } }
            }
            TextField(tags.isEmpty ? "添加标签" : "", text: $input)
                .textFieldStyle(.plain)
                .frame(minWidth: 60, maxWidth: 140)
                .onSubmit(commit)
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
    }

    /// 支持一次输入多个，用逗号或空格分隔
    private func commit() {
        for part in input.components(separatedBy: CharacterSet(charactersIn: ",，、 ")) {
            let t = Store.normalizeTag(part)
            if !t.isEmpty && !tags.contains(t) { tags.append(t) }
        }
        input = ""
    }
}

struct TagChip: View {
    let name: String
    let onRemove: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 2) {
            Text("#" + name)
            if hovering {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(Color.accentColor)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(Capsule().fill(Color.accentColor.opacity(0.12)))
        .onHover { hovering = $0 }
    }
}

// MARK: - 图片附件

struct AttachmentsView: View {
    @EnvironmentObject var store: Store
    let attachments: [String]
    let onRemove: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments, id: \.self) { name in
                    let url = store.attachmentURL(name)
                    ThumbnailView(url: url)
                        .frame(width: 96, height: 72)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.08)))
                        .onTapGesture(count: 2) { NSWorkspace.shared.open(url) }
                        .help("双击用“预览”打开")
                        .contextMenu {
                            Button("打开") { NSWorkspace.shared.open(url) }
                            Button("拷贝图片") { Pasteboard.copyImage(at: url) }
                            Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                            Divider()
                            Button("移除", role: .destructive) { onRemove(name) }
                        }
                }
            }
        }
        .frame(height: 72)
    }
}

// MARK: - 结构化字段：类似“通讯录”卡片，每行 字段名 + 内容，悬停时出现拷贝 / 删除

struct FieldsEditor: View {
    @Binding var fields: [NoteField]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !fields.isEmpty {
                VStack(spacing: 0) {
                    ForEach($fields) { $field in
                        FieldRow(field: $field) {
                            let id = field.id
                            fields.removeAll { $0.id == id }
                        }
                        if field.id != fields.last?.id {
                            Divider().padding(.leading, 12)
                        }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.035)))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.07)))
            }

            HStack(spacing: 14) {
                Button {
                    fields.append(NoteField())
                } label: {
                    Label("添加字段", systemImage: "plus")
                }
                Menu {
                    ForEach(FieldTemplate.allCases, id: \.self) { t in
                        Button(t.rawValue) {
                            let existing = Set(fields.map(\.key))
                            fields += t.keys.filter { !existing.contains($0) }.map { NoteField(key: $0) }
                        }
                    }
                } label: {
                    Label("字段模板", systemImage: "list.bullet.rectangle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            .buttonStyle(.borderless)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
    }
}

private struct FieldRow: View {
    @Binding var field: NoteField
    let onDelete: () -> Void
    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        HStack(spacing: 10) {
            TextField("字段", text: $field.key)
                .textFieldStyle(.plain)
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)
            TextField("内容", text: $field.value)
                .textFieldStyle(.plain)
            // 按钮常驻占位，只切换透明度，悬停时不会挤动布局
            HStack(spacing: 8) {
                Button {
                    Pasteboard.copy(field.value)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                }
                .help("拷贝内容")
                Button(action: onDelete) {
                    Image(systemName: "minus.circle")
                }
                .help("删除字段")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .opacity(hovering || copied ? 1 : 0)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}
