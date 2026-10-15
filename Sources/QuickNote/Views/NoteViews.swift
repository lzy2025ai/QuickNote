import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct NoteListView: View {
    @EnvironmentObject var store: Store
    let scope: SidebarItem
    @Binding var detail: Detail?
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

    var body: some View {
        let notes = store.notes(for: scope)
        ScrollViewReader { proxy in
            List(selection: $detail) {
                ForEach(notes) { note in
                    NoteRow(note: note, showProject: true)
                        .tag(Detail.note(note.id))
                        .contextMenu { NoteContextMenu(note: note) }
                }
            }
            .onDeleteCommand {
                if case .note(let id) = detail { store.deleteNote(id) }
            }
            .overlay {
                if notes.isEmpty {
                    VStack(spacing: 8) {
                        Text("还没有笔记").foregroundStyle(.secondary)
                        Button("新建笔记", action: onCreate)
                    }
                }
            }
            // 选中项变化（比如新建笔记）时滚动到它，避免被遮住
            .onChange(of: detail) { newValue in
                if case .note(let id)? = newValue {
                    withAnimation { proxy.scrollTo(id) }
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                ColumnHeader(title: title, count: notes.count) {
                    Button {
                        MarkdownExporter.exportNotes(notes, title: title, store: store)
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .buttonStyle(.borderless)
                    .help("把这些笔记导出为 Markdown")
                    .disabled(notes.isEmpty)

                    Button(action: onCreate) {
                        Image(systemName: "square.and.pencil")
                    }
                    .buttonStyle(.borderless)
                    .help("新建笔记 (⌘N)")
                }
            }
        }
    }
}

struct ColumnHeader<Trailing: View>: View {
    let title: String
    let count: Int
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 10) {
            Text(title).font(.headline).lineLimit(1)
            Text("\(count)").font(.caption).foregroundStyle(.secondary)
            Spacer()
            trailing
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}

struct NoteContextMenu: View {
    @EnvironmentObject var store: Store
    let note: Note

    var body: some View {
        Button(note.pinned ? "取消置顶" : "置顶") {
            store.mutateNote(note.id) { $0.pinned.toggle() }
        }
        Button("复制全部内容") { Pasteboard.copy(note.plainText) }
        Button("复制为 Markdown") {
            Pasteboard.copy(MarkdownExporter.markdown(for: note, projectName: store.project(note.projectID)?.name))
        }
        Button("导出为 Markdown…") { MarkdownExporter.exportNote(note, store: store) }
        Menu("移动到") {
            Button("收件箱") { store.mutateNote(note.id) { $0.projectID = nil } }
            Divider()
            ForEach(store.projects) { p in
                Button(p.name) { store.mutateNote(note.id) { $0.projectID = p.id } }
            }
        }
        Divider()
        Button("删除", role: .destructive) { store.deleteNote(note.id) }
    }
}

struct NoteRow: View {
    @EnvironmentObject var store: Store
    let note: Note
    var showProject = false
    var query: String = ""

    var body: some View {
        let terms = SearchText.terms(query)
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                if note.pinned {
                    Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.orange)
                }
                Text(SearchText.highlight(note.displayTitle, terms: terms))
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                if !note.attachments.isEmpty {
                    Image(systemName: "paperclip").font(.caption2).foregroundStyle(.secondary)
                }
            }
            let preview = terms.isEmpty ? note.preview : SearchText.snippet(note.preview, terms: terms)
            if !preview.isEmpty {
                Text(SearchText.highlight(preview, terms: terms))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            HStack(spacing: 6) {
                Text(note.updatedAt.formatted(date: .abbreviated, time: .shortened))
                    .foregroundStyle(.tertiary)
                if showProject {
                    if let p = store.project(note.projectID) {
                        Label {
                            Text(p.name).foregroundStyle(.tertiary)
                        } icon: {
                            Image(systemName: p.icon).foregroundStyle(p.tint.opacity(0.8))
                        }
                    }
                }
                if !note.tags.isEmpty {
                    Text(note.tags.map { "#" + $0 }.joined(separator: " "))
                        .foregroundStyle(Color.accentColor.opacity(0.8))
                        .lineLimit(1)
                }
            }
            .font(.caption2)
            .labelStyle(.titleAndIcon)
        }
        .padding(.vertical, 3)
    }
}

struct NoteEditorView: View {
    @EnvironmentObject var store: Store
    let noteID: UUID
    var autoFocusTitle = false

    @FocusState private var titleFocused: Bool
    @State private var copied = false
    @State private var confirmDelete = false
    @State private var dropTargeted = false

    var body: some View {
        if let note = store.binding(for: noteID) {
            editor(note)
        } else {
            Text("笔记已删除").foregroundStyle(.secondary)
        }
    }

    private func editor(_ note: Binding<Note>) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header(note)
            Divider()

            TextField("标题", text: note.title)
                .textFieldStyle(.plain)
                .font(.system(size: 20, weight: .semibold))
                .focused($titleFocused)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 6)

            TagsEditor(tags: note.tags, suggestions: store.allTags.map(\.name))
                .padding(.horizontal, 16)
                .padding(.bottom, 8)

            FieldsEditor(fields: note.fields)

            AttachmentsView(noteID: noteID, attachments: note.wrappedValue.attachments)

            Divider().padding(.horizontal, 16)

            TextEditor(text: note.content)
                .font(.system(size: 14))
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6]))
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image) else { return }
                    DispatchQueue.main.async { store.addAttachment(fileURL: url, to: noteID) }
                }
            }
            return true
        }
        .onAppear {
            let n = note.wrappedValue
            if autoFocusTitle || (n.title.isEmpty && n.content.isEmpty && n.fields.isEmpty) {
                DispatchQueue.main.async {
                    titleFocused = true
                    // 选中默认标题，直接输入即可替换
                    DispatchQueue.main.async {
                        NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
                    }
                }
            }
        }
        .alert("删除这条笔记？", isPresented: $confirmDelete) {
            Button("删除", role: .destructive) { store.deleteNote(noteID) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("删除后无法恢复。")
        }
    }

    private func header(_ note: Binding<Note>) -> some View {
        HStack(spacing: 12) {
            Picker("", selection: note.projectID) {
                Label("收件箱", systemImage: "tray").tag(UUID?.none)
                Divider()
                ForEach(store.projects) { p in
                    Label(p.name, systemImage: p.icon).tag(Optional(p.id))
                }
            }
            .labelsHidden()
            .frame(maxWidth: 180)
            .help("所属项目")

            Spacer()

            Text("编辑于 " + note.wrappedValue.updatedAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption)
                .foregroundStyle(.tertiary)

            Button {
                note.wrappedValue.pinned.toggle()
            } label: {
                Image(systemName: note.wrappedValue.pinned ? "pin.fill" : "pin")
            }
            .help(note.wrappedValue.pinned ? "取消置顶" : "置顶")

            Menu {
                Button("选择图片…") { pickImages() }
                Button("粘贴剪贴板中的图片") {
                    if let png = Pasteboard.imagePNGData() { store.addAttachment(pngData: png, to: noteID) }
                }
            } label: {
                Image(systemName: "paperclip")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("添加图片（也可以直接把图片拖进来）")

            Menu {
                Button("复制全部内容") {
                    Pasteboard.copy(note.wrappedValue.plainText)
                    flashCopied()
                }
                Button("复制为 Markdown") {
                    let n = note.wrappedValue
                    Pasteboard.copy(MarkdownExporter.markdown(for: n, projectName: store.project(n.projectID)?.name))
                    flashCopied()
                }
                Divider()
                Button("导出为 Markdown 文件…") { MarkdownExporter.exportNote(note.wrappedValue, store: store) }
            } label: {
                Image(systemName: copied ? "checkmark" : "square.and.arrow.up")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("复制 / 导出")

            Button {
                confirmDelete = true
            } label: {
                Image(systemName: "trash")
            }
            .help("删除笔记")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 16)
        .frame(height: 38)
    }

    private func pickImages() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { store.addAttachment(fileURL: url, to: noteID) }
    }

    private func flashCopied() {
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
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
            Image(systemName: "number").font(.caption).foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(tags, id: \.self) { tag in
                        TagChip(name: tag) { tags.removeAll { $0 == tag } }
                    }
                    TextField(tags.isEmpty ? "添加标签，回车确认" : "添加标签", text: $input)
                        .textFieldStyle(.plain)
                        .font(.caption)
                        .frame(width: 110)
                        .onSubmit(commit)
                }
            }
            if !available.isEmpty {
                Menu {
                    ForEach(available, id: \.self) { t in
                        Button("#" + t) { tags.append(t) }
                    }
                } label: {
                    Image(systemName: "chevron.down.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("选择已有标签")
            }
        }
    }

    /// 支持一次输入多个，用逗号或空格分隔
    private func commit() {
        let parts = input.components(separatedBy: CharacterSet(charactersIn: ",，、 "))
        for p in parts {
            let t = Store.normalizeTag(p)
            if !t.isEmpty && !tags.contains(t) { tags.append(t) }
        }
        input = ""
    }
}

struct TagChip: View {
    let name: String
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 3) {
            Text("#" + name)
            Button(action: onRemove) {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
        }
        .font(.caption)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.accentColor.opacity(0.15)))
    }
}

// MARK: - 图片附件

struct AttachmentsView: View {
    @EnvironmentObject var store: Store
    let noteID: UUID
    let attachments: [String]

    var body: some View {
        if !attachments.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(attachments, id: \.self) { name in
                        let url = store.attachmentURL(name)
                        ThumbnailView(url: url)
                            .frame(width: 96, height: 72)
                            .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.4)))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                            .onTapGesture(count: 2) { NSWorkspace.shared.open(url) }
                            .help("双击用“预览”打开")
                            .contextMenu {
                                Button("打开") { NSWorkspace.shared.open(url) }
                                Button("复制图片") { Pasteboard.copyImage(at: url) }
                                Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                                Divider()
                                Button("移除", role: .destructive) { store.removeAttachment(name, from: noteID) }
                            }
                    }
                }
                .padding(.horizontal, 16)
            }
            .frame(height: 80)
            .padding(.bottom, 8)
        }
    }
}

// MARK: - 结构化字段：每行一个 “字段名 + 内容”，右侧一键复制

struct FieldsEditor: View {
    @Binding var fields: [NoteField]
    @State private var copiedID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach($fields) { $field in
                HStack(spacing: 6) {
                    TextField("字段", text: $field.key)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                    TextField("内容", text: $field.value)
                        .textFieldStyle(.roundedBorder)
                    Button {
                        Pasteboard.copy(field.value)
                        copiedID = field.id
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                            if copiedID == field.id { copiedID = nil }
                        }
                    } label: {
                        Image(systemName: copiedID == field.id ? "checkmark" : "doc.on.doc")
                    }
                    .help("复制内容")
                    Button {
                        let id = field.id
                        fields.removeAll { $0.id == id }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .help("删除字段")
                }
                .buttonStyle(.borderless)
            }

            HStack(spacing: 14) {
                Button {
                    fields.append(NoteField())
                } label: {
                    Label("添加字段", systemImage: "plus")
                }
                .buttonStyle(.borderless)

                Menu {
                    ForEach(FieldTemplate.allCases, id: \.self) { t in
                        Button(t.rawValue) {
                            let existing = Set(fields.map(\.key))
                            fields += t.keys.filter { !existing.contains($0) }.map { NoteField(key: $0) }
                        }
                    }
                } label: {
                    Label("使用模板", systemImage: "list.bullet.rectangle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }
}
