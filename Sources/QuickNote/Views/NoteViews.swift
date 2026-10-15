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
        let pinned = notes.filter(\.pinned)
        let others = notes.filter { !$0.pinned }
        ScrollViewReader { proxy in
            List(selection: $detail) {
                // 与“备忘录”一样：有置顶时分成“置顶”和“笔记”两组
                if pinned.isEmpty {
                    rows(others)
                } else {
                    Section("置顶") { rows(pinned) }
                    if !others.isEmpty {
                        Section("笔记") { rows(others) }
                    }
                }
            }
            .listStyle(.inset)
            .animation(Motion.standard, value: notes.map(\.id))
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
                withAnimation(Motion.standard) { proxy.scrollTo(id, anchor: .top) }
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

    private func rows(_ notes: [Note]) -> some View {
        ForEach(notes) { note in
            NoteRow(note: note, showProject: showsProject)
                .tag(Detail.note(note.id))
                .contextMenu { NoteContextMenu(note: note) }
        }
    }
}

struct NoteContextMenu: View {
    @EnvironmentObject var store: Store
    let note: Note

    var body: some View {
        Button(note.pinned ? "取消置顶" : "置顶") {
            withAnimation(Motion.standard) {
                store.mutateNote(note.id) { $0.pinned.toggle() }
            }
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

/// 仿“备忘录”的行：标题一行；日期 + 摘要一行；需要时再加一行项目 / 标签
struct NoteRow: View {
    @EnvironmentObject var store: Store
    let note: Note
    var showProject = false
    var query: String = ""

    var body: some View {
        let terms = SearchText.terms(query)
        let preview = terms.isEmpty ? note.preview : SearchText.snippet(note.preview, terms: terms)
        let project = showProject ? store.project(note.projectID) : nil

        VStack(alignment: .leading, spacing: 2) {
            Text(SearchText.highlight(note.displayTitle, terms: terms))
                .font(Typography.rowTitle)
                .lineLimit(1)

            HStack(spacing: 6) {
                Text(RelativeDate.short(note.updatedAt))
                    .foregroundStyle(.primary)
                Text(preview.isEmpty ? AttributedString("无更多内容") : SearchText.highlight(preview, terms: terms))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .font(Typography.rowDetail)

            if project != nil || !note.tags.isEmpty || !note.attachments.isEmpty {
                HStack(spacing: 8) {
                    if let project {
                        Label {
                            Text(project.name)
                        } icon: {
                            Image(systemName: project.icon).foregroundStyle(project.tint)
                        }
                    }
                    if !note.attachments.isEmpty {
                        Image(systemName: "photo")
                    }
                    if !note.tags.isEmpty {
                        Text(note.tags.map { "#" + $0 }.joined(separator: " "))
                    }
                }
                .font(Typography.meta)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.top, 1)
            }
        }
        .padding(.vertical, Metrics.rowVerticalPadding)
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

/// 编辑器只改本地草稿，停止输入 0.4 秒后再整体写回（切换笔记 / 关闭时立即写回）。
/// 输入时不会每个按键都刷新整个窗口，也不会打断输入法。
struct NoteEditorView: View {
    @EnvironmentObject var store: Store
    let noteID: UUID
    let autoFocusTitle: Bool
    let onAutoFocused: () -> Void

    @State private var draft: Note
    @State private var commitWork: DispatchWorkItem?
    @State private var confirmDelete = false
    @State private var dropTargeted = false
    @FocusState private var titleFocused: Bool

    /// 直接用笔记初始化草稿，切换笔记时第一帧就有内容，不会闪白
    init(note: Note, autoFocusTitle: Bool = false, onAutoFocused: @escaping () -> Void = {}) {
        noteID = note.id
        self.autoFocusTitle = autoFocusTitle
        self.onAutoFocused = onAutoFocused
        _draft = State(initialValue: note)
    }

    private var note: Binding<Note> {
        Binding(
            get: { draft },
            set: { newValue in
                draft = newValue
                scheduleCommit()
            }
        )
    }

    var body: some View {
        editor
            .onReceive(store.$notes) { syncFromStore($0) }
            .onAppear {
                guard autoFocusTitle else { return }
                DispatchQueue.main.async {
                    titleFocused = true
                    onAutoFocused()
                }
            }
            .onDisappear { commitNow() }
    }

    /// 笔记在别处被修改（列表右键、iCloud 同步）且当前没有未提交的输入时，更新草稿
    private func syncFromStore(_ notes: [Note]) {
        guard commitWork == nil, let stored = notes.first(where: { $0.id == noteID }), stored != draft else { return }
        draft = stored
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
        store.updateNote(draft)
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text(metaLine)
                    .font(Typography.meta)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 2)

                TextField("标题", text: note.title)
                    .textFieldStyle(.plain)
                    .font(Typography.editorTitle)
                    .focused($titleFocused)

                TagsEditor(tags: note.tags, suggestions: store.allTags.map(\.name))

                FieldsEditor(fields: note.fields)
                    .padding(.top, 2)

                if !draft.attachments.isEmpty {
                    AttachmentsView(attachments: draft.attachments) { name in
                        note.wrappedValue.attachments.removeAll { $0 == name }
                        commitNow()
                        store.deleteAttachmentFile(name)
                    }
                }
            }
            .padding(.horizontal, Metrics.editorInset)
            .padding(.top, 12)
            .padding(.bottom, 4)

            NoteTextView(text: note.content, placeholder: "开始记录…")
        }
        .frame(maxWidth: Metrics.readableWidth)
        .frame(maxWidth: .infinity)
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

    private var metaLine: String {
        var parts = [draft.updatedAt.formatted(date: .long, time: .shortened)]
        if let p = store.project(draft.projectID) { parts.append(p.name) }
        return parts.joined(separator: " · ")
    }

    /// 工具栏只放常用的：所属项目、添加图片、分享；置顶和删除收进“更多”
    @ToolbarContentBuilder
    private var editorToolbar: some ToolbarContent {
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
                Label("移动到项目", systemImage: "folder")
            }
            .help("移动到项目")

            Menu {
                Button("选择图片…") { pickImages() }
                Button("粘贴剪贴板中的图片") {
                    if let png = Pasteboard.imagePNGData(), let name = store.importAttachment(pngData: png) {
                        note.wrappedValue.attachments.append(name)
                        commitNow()
                    }
                }
            } label: {
                Label("添加图片", systemImage: "photo")
            }
            .help("添加图片（也可以直接拖进来）")

            Menu {
                Button("拷贝全部内容") { Pasteboard.copy(draft.plainText) }
                Button("拷贝为 Markdown") {
                    Pasteboard.copy(MarkdownExporter.markdown(for: draft, projectName: store.project(draft.projectID)?.name))
                }
                Divider()
                Button("导出为 Markdown 文件…") {
                    commitNow()
                    MarkdownExporter.exportNote(draft, store: store)
                }
            } label: {
                Label("分享", systemImage: "square.and.arrow.up")
            }
            .help("拷贝 / 导出")

            Menu {
                Button(draft.pinned ? "取消置顶" : "置顶") {
                    withAnimation(Motion.standard) {
                        note.wrappedValue.pinned.toggle()
                        commitNow()
                    }
                }
                Divider()
                Button("删除笔记…", role: .destructive) { confirmDelete = true }
            } label: {
                Label("更多", systemImage: "ellipsis.circle")
            }
            .help("更多")
        }
    }

    private func addAttachment(fileURL: URL) {
        guard let name = store.importAttachment(fileURL: fileURL) else { return }
        withAnimation(Motion.standard) { note.wrappedValue.attachments.append(name) }
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

// MARK: - 标签：标题下方一行，强调色文字，无多余装饰

struct TagsEditor: View {
    @Binding var tags: [String]
    let suggestions: [String]
    @State private var input = ""

    private var available: [String] {
        suggestions.filter { !tags.contains($0) }
    }

    var body: some View {
        HStack(spacing: 10) {
            ForEach(tags, id: \.self) { tag in
                TagChip(name: tag) {
                    withAnimation(Motion.quick) { tags.removeAll { $0 == tag } }
                }
            }
            TextField(tags.isEmpty ? "添加标签" : "", text: $input)
                .textFieldStyle(.plain)
                .foregroundStyle(.secondary)
                .frame(minWidth: 60, maxWidth: 140)
                .onSubmit(commit)
            if !available.isEmpty {
                Menu {
                    ForEach(available, id: \.self) { t in
                        Button("#" + t) { withAnimation(Motion.quick) { tags.append(t) } }
                    }
                } label: {
                    Image(systemName: "chevron.down")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .foregroundStyle(.tertiary)
                .help("选择已有标签")
            }
            Spacer(minLength: 0)
        }
        .font(.callout)
    }

    /// 支持一次输入多个，用逗号或空格分隔
    private func commit() {
        var result = tags
        for part in input.components(separatedBy: CharacterSet(charactersIn: ",，、 ")) {
            let t = Store.normalizeTag(part)
            if !t.isEmpty && !result.contains(t) { result.append(t) }
        }
        withAnimation(Motion.quick) { tags = result }
        input = ""
    }
}

struct TagChip: View {
    let name: String
    let onRemove: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 3) {
            Text("#" + name)
                .foregroundStyle(Color.accentColor)
            // 删除按钮常驻占位，只切换透明度，悬停时不挤动布局
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .opacity(hovering ? 1 : 0)
            .help("移除标签")
        }
        .onHover { h in withAnimation(Motion.quick) { hovering = h } }
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
                        .frame(width: 104, height: 78)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
                        .onTapGesture(count: 2) { NSWorkspace.shared.open(url) }
                        .help("双击用“预览”打开")
                        .contextMenu {
                            Button("打开") { NSWorkspace.shared.open(url) }
                            Button("拷贝图片") { Pasteboard.copyImage(at: url) }
                            Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                            Divider()
                            Button("移除", role: .destructive) { withAnimation(Motion.standard) { onRemove(name) } }
                        }
                }
            }
        }
        .frame(height: 78)
    }
}

// MARK: - 结构化字段：类似“通讯录”卡片，字段名在左、内容在右，悬停时出现拷贝 / 删除

struct FieldsEditor: View {
    @Binding var fields: [NoteField]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !fields.isEmpty {
                VStack(spacing: 0) {
                    ForEach($fields) { $field in
                        FieldRow(field: $field) {
                            let id = field.id
                            withAnimation(Motion.standard) { fields.removeAll { $0.id == id } }
                        }
                        if field.id != fields.last?.id {
                            Divider().padding(.leading, 12)
                        }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.03)))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.07)))
            }
            FieldActions(fields: $fields)
        }
    }
}

/// “添加字段 / 字段模板”两个轻量入口
struct FieldActions: View {
    @Binding var fields: [NoteField]

    var body: some View {
        HStack(spacing: 14) {
            Button {
                withAnimation(Motion.standard) { fields.append(NoteField()) }
            } label: {
                Label("添加字段", systemImage: "plus")
            }
            Menu {
                ForEach(FieldTemplate.allCases, id: \.self) { t in
                    Button(t.rawValue) {
                        let existing = Set(fields.map(\.key))
                        withAnimation(Motion.standard) {
                            fields += t.keys.filter { !existing.contains($0) }.map { NoteField(key: $0) }
                        }
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
        .font(Typography.meta)
        .foregroundStyle(.secondary)
    }
}

private struct FieldRow: View {
    @Binding var field: NoteField
    let onDelete: () -> Void
    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        HStack(spacing: 12) {
            TextField("字段", text: $field.key)
                .textFieldStyle(.plain)
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .leading)
            TextField("内容", text: $field.value)
                .textFieldStyle(.plain)
            // 按钮常驻占位，只切换透明度，悬停时不会挤动布局
            HStack(spacing: 10) {
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
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onHover { h in withAnimation(Motion.quick) { hovering = h } }
    }
}
