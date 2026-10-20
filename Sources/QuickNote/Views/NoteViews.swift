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
    @FocusState private var focused: Bool
    @State private var pendingDelete: Note?

    private var showsProject: Bool {
        if case .project = scope { return false }
        return true
    }

    var body: some View {
        let notes = store.notes(for: scope)
        let pinned = notes.filter(\.pinned)
        let others = notes.filter { !$0.pinned }
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if !pinned.isEmpty {
                        SectionLabel("置顶").padding(.horizontal, 12).padding(.vertical, 6)
                        rows(pinned)
                        if !others.isEmpty {
                            SectionLabel("笔记").padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 6)
                        }
                    }
                    rows(others)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 16)
                .animation(Motion.standard, value: notes.map(\.id))
            }
            .overlay {
                if notes.isEmpty {
                    EmptyStateView(title: "还没有笔记", detail: "按 ⌘N 新建一则")
                }
            }
            .focusable()
            .focused($focused)
            .hideFocusRing()
            .onMoveCommand { direction in
                move(direction, in: pinned + others, proxy: proxy)
            }
            .onDeleteCommand {
                if case .note(let id) = detail { pendingDelete = store.notes.first { $0.id == id } }
            }
            .confirmNoteDelete($pendingDelete) { note in
                // 删除后选中相邻的一则，键盘可以继续操作
                let ordered = pinned + others
                if let index = ordered.firstIndex(where: { $0.id == note.id }) {
                    let neighbor = index + 1 < ordered.count ? ordered[index + 1] : (index > 0 ? ordered[index - 1] : nil)
                    detail = neighbor.map { .note($0.id) }
                }
                store.deleteNote(note.id)
            }
            .onChange(of: revealID) { id in
                guard let id else { return }
                withAnimation(Motion.standard) { proxy.scrollTo(id, anchor: .top) }
            }
        }
    }

    private func rows(_ notes: [Note]) -> some View {
        ForEach(notes) { note in
            NoteRow(note: note, selected: detail == .note(note.id), showProject: showsProject)
                .id(note.id)
                .contentShape(Rectangle())
                .onTapGesture {
                    detail = .note(note.id)
                    focused = true
                }
                .contextMenu { NoteContextMenu(note: note) { pendingDelete = $0 } }
        }
    }

    /// 方向键在列表里上下移动
    private func move(_ direction: MoveCommandDirection, in notes: [Note], proxy: ScrollViewProxy) {
        guard !notes.isEmpty else { return }
        let index = notes.firstIndex { detail == .note($0.id) }
        let next: Int
        switch direction {
        case .up: next = max((index ?? 0) - 1, 0)
        case .down: next = min((index ?? -1) + 1, notes.count - 1)
        default: return
        }
        detail = .note(notes[next].id)
        proxy.scrollTo(notes[next].id)
    }
}

struct NoteContextMenu: View {
    @EnvironmentObject var store: Store
    let note: Note
    /// 删除交给外层弹确认框
    let onDelete: (Note) -> Void

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
        Button("删除…", role: .destructive) { onDelete(note) }
    }
}

extension View {
    /// 删除笔记前的确认框
    func confirmNoteDelete(_ pending: Binding<Note?>, perform: @escaping (Note) -> Void) -> some View {
        alert(
            "删除这则笔记？",
            isPresented: Binding(get: { pending.wrappedValue != nil }, set: { if !$0 { pending.wrappedValue = nil } }),
            presenting: pending.wrappedValue
        ) { note in
            Button("删除", role: .destructive) { perform(note) }
            Button("取消", role: .cancel) {}
        } message: { note in
            Text("「\(note.displayTitle)」删除后无法恢复。")
        }
    }
}

/// 列表行：左侧大号日期，右侧标题、摘要、标签
struct NoteRow: View {
    @EnvironmentObject var store: Store
    let note: Note
    var selected = false
    var showProject = false
    var query: String = ""
    @State private var hovering = false

    var body: some View {
        let terms = SearchText.terms(query)
        let preview = terms.isEmpty ? note.preview : SearchText.snippet(note.preview, terms: terms)
        let project = showProject ? store.project(note.projectID) : nil
        let hasImages = !note.attachments.isEmpty || !note.inlineImages.isEmpty

        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 2) {
                Text(ChineseDate.day(note.updatedAt))
                    .font(.numeral(28, weight: .semibold))
                    .foregroundStyle(selected ? Palette.seal : Palette.ink2)
                Text(ChineseDate.month(note.updatedAt))
                    .font(.system(size: 10))
                    .tracking(1)
                    .foregroundStyle(Palette.muted)
            }
            .frame(width: 36)

            VStack(alignment: .leading, spacing: 4) {
                Text(SearchText.highlight(note.displayTitle, terms: terms))
                    .font(Typography.rowTitle)
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                if !preview.isEmpty {
                    Text(SearchText.highlight(preview, terms: terms))
                        .font(Typography.rowDetail)
                        .foregroundStyle(Palette.ink2)
                        .lineSpacing(2)
                        .lineLimit(2)
                }
                if project != nil || !note.allTags.isEmpty || hasImages {
                    HStack(spacing: 8) {
                        if let project {
                            HStack(spacing: 4) {
                                RoundedRectangle(cornerRadius: 1.5).fill(project.tint).frame(width: 7, height: 7)
                                Text(project.name).foregroundStyle(Palette.muted)
                            }
                        }
                        if hasImages {
                            Image(systemName: "photo").foregroundStyle(Palette.muted)
                        }
                        if !note.allTags.isEmpty {
                            Text(note.allTags.map { "#" + $0 }.joined(separator: " · "))
                                .foregroundStyle(Palette.tag)
                        }
                    }
                    .font(.system(size: 11.5))
                    .lineLimit(1)
                    .padding(.top, 1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(selected ? Palette.paper : (hovering ? Palette.paper.opacity(0.45) : Color.clear))
                .shadow(color: selected ? Palette.shadow : .clear, radius: 8, y: 3)
        )
        .onHover { h in withAnimation(Motion.quick) { hovering = h } }
    }
}

struct EmptyStateView: View {
    let title: String
    var detail: String?

    var body: some View {
        VStack(spacing: 8) {
            AppMark(size: 34).opacity(0.85)
            Text(title)
                .font(.song(15, bold: true))
                .foregroundStyle(Palette.ink2)
                .padding(.top, 6)
            if let detail {
                Text(detail)
                    .font(Typography.meta)
                    .foregroundStyle(Palette.muted)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 编辑器

/// 编辑器只改本地草稿，停止输入 0.4 秒后再整体写回（切换笔记 / 关闭时立即写回）。
/// 输入时不会每个按键都刷新整个窗口，也不会打断输入法。
struct NoteEditorView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var settings: AppSettings
    let noteID: UUID
    let autoFocusTitle: Bool
    let reveal: RevealTarget?
    let onAutoFocused: () -> Void

    @State private var draft: Note
    @State private var commitWork: DispatchWorkItem?
    @State private var confirmDelete = false
    @State private var dropTargeted = false
    @FocusState private var titleFocused: Bool

    /// 直接用笔记初始化草稿，切换笔记时第一帧就有内容，不会闪白
    init(note: Note, autoFocusTitle: Bool = false, reveal: RevealTarget? = nil, onAutoFocused: @escaping () -> Void = {}) {
        noteID = note.id
        self.autoFocusTitle = autoFocusTitle
        self.reveal = reveal
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
            .onDisappear {
                if isUntouched {
                    // 新建后什么都没写就离开：像“备忘录”一样直接丢弃，不留空白笔记
                    commitWork?.cancel()
                    commitWork = nil
                    let id = noteID
                    DispatchQueue.main.async { store.deleteNote(id) }
                } else {
                    commitNow()
                }
            }
    }

    /// 只有自动生成的标题（或没有标题），正文、字段、标签、图片都为空
    private var isUntouched: Bool {
        let d = draft
        guard d.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              d.tags.isEmpty, d.attachments.isEmpty,
              d.fields.allSatisfy({ $0.value.trimmingCharacters(in: .whitespaces).isEmpty }) else { return false }
        let title = d.title.trimmingCharacters(in: .whitespaces)
        return title.isEmpty || title == settings.defaultNoteTitle(projectName: store.project(d.projectID)?.name, date: d.createdAt)
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
            actionBar
                .frame(height: Metrics.titlebarHeight + 12)

            VStack(alignment: .leading, spacing: 16) {
                dateBlock
                Rectangle().fill(Palette.ink).frame(height: 1).opacity(0.85)

                TextField("标题", text: note.title)
                    .textFieldStyle(.plain)
                    .font(.song(30, bold: true))
                    .foregroundStyle(Palette.ink)
                    .tracking(1.5)
                    .focused($titleFocused)

                TagsEditor(tags: note.tags, suggestions: store.allTags.map(\.name))

                if !draft.fields.isEmpty {
                    FieldsEditor(fields: note.fields)
                }

                if !draft.attachments.isEmpty {
                    AttachmentsView(attachments: draft.attachments) { name in
                        note.wrappedValue.attachments.removeAll { $0 == name }
                        commitNow()
                        store.deleteAttachmentFile(name)
                    }
                }
            }
            .padding(.horizontal, Metrics.editorInset)
            .padding(.bottom, 8)

            NoteTextView(
                text: note.content,
                placeholder: "写点什么…  输入 / 插入待办、标题、列表，#标签，⌘V 粘贴图片",
                reveal: reveal,
                attachmentURL: { store.attachmentURL($0) },
                importImages: importPastedImages
            )
            .overlay(alignment: .top) {
                // 正文滚动时，顶部文字淡出，不会硬生生切在标签栏下面
                LinearGradient(colors: [Palette.paper, Palette.paper.opacity(0)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 14)
                    .allowsHitTesting(false)
            }

            footer
        }
        .frame(maxWidth: Metrics.readableWidth, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(Palette.paper)
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Palette.seal, style: StrokeStyle(lineWidth: 1.5, dash: [6]))
                    .padding(10)
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
        .alert("删除这则笔记？", isPresented: $confirmDelete) {
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

    /// ⌘V 粘贴的图片：存进附件目录，返回文件名，由正文插入 ![](文件名)
    private func importPastedImages(_ items: [PastedImage]) -> [String] {
        items.compactMap { item in
            switch item {
            case .file(let url): return store.importAttachment(fileURL: url)
            case .png(let data): return store.importAttachment(pngData: data)
            }
        }
    }

    /// 大号日期 + 中文月份星期
    private var dateBlock: some View {
        HStack(alignment: .lastTextBaseline, spacing: 14) {
            Text(ChineseDate.day(draft.createdAt))
                .font(.numeral(64, weight: .regular))
                .foregroundStyle(Palette.ink)
            VStack(alignment: .leading, spacing: 3) {
                Text(ChineseDate.month(draft.createdAt) + " · " + ChineseDate.weekday(draft.createdAt))
                    .font(.song(15))
                    .tracking(3)
                    .foregroundStyle(Palette.ink)
                Text(verbatim: String(Calendar.current.component(.year, from: draft.createdAt)) + " · " + ChineseDate.time(draft.createdAt))
                    .font(.system(size: 11.5))
                    .tracking(2)
                    .foregroundStyle(Palette.muted)
            }
            Spacer()
        }
    }

    /// 右上角：添加图片、分享、更多（紧凑排在右侧）
    private var actionBar: some View {
        HStack(spacing: 4) {
            Spacer()
            IconMenu(systemImage: "photo", help: "添加图片（也可以直接拖进来）") {
                Button("选择图片…") { pickImages() }
                Button("粘贴剪贴板中的图片") {
                    if let png = Pasteboard.imagePNGData(), let name = store.importAttachment(pngData: png) {
                        withAnimation(Motion.standard) { note.wrappedValue.attachments.append(name) }
                        commitNow()
                    }
                }
            }
            IconMenu(systemImage: "square.and.arrow.up", help: "拷贝 / 导出") {
                Button("拷贝全部内容") { Pasteboard.copy(draft.plainText) }
                Button("拷贝为 Markdown") {
                    Pasteboard.copy(MarkdownExporter.markdown(for: draft, projectName: store.project(draft.projectID)?.name))
                }
                Divider()
                Button("导出为 Markdown 文件…") {
                    commitNow()
                    MarkdownExporter.exportNote(draft, store: store)
                }
            }
            IconMenu(systemImage: "ellipsis", help: "更多") {
                Button(draft.pinned ? "取消置顶" : "置顶") {
                    withAnimation(Motion.standard) {
                        note.wrappedValue.pinned.toggle()
                        commitNow()
                    }
                }
                Button("添加字段") {
                    withAnimation(Motion.standard) { note.wrappedValue.fields.append(NoteField()) }
                }
                Menu("字段模板") {
                    ForEach(FieldTemplate.allCases, id: \.self) { t in
                        Button(t.rawValue + "（" + t.keys.joined(separator: "、") + "）") {
                            let existing = Set(draft.fields.map(\.key))
                            withAnimation(Motion.standard) {
                                note.wrappedValue.fields += t.keys.filter { !existing.contains($0) }.map { NoteField(key: $0) }
                            }
                        }
                    }
                }
                Divider()
                Picker("移动到", selection: note.projectID) {
                    Text("收件箱").tag(UUID?.none)
                    ForEach(store.projects) { p in
                        Text(p.name).tag(Optional(p.id))
                    }
                }
                Divider()
                Button("删除这则笔记…", role: .destructive) { confirmDelete = true }
            }
        }
        .padding(.horizontal, Metrics.editorInset - 8)
        .padding(.top, 6)
    }

    /// 右下角一行淡淡的状态：字数 · 保存位置
    private var footer: some View {
        HStack(spacing: 6) {
            Spacer()
            Text(verbatim: String(draft.content.filter { !$0.isWhitespace }.count) + " 字")
            Text("·").foregroundStyle(Palette.faint)
            HStack(spacing: 4) {
                Image(systemName: store.isICloud ? "icloud" : "internaldrive")
                    .font(.system(size: 10))
                Text(commitWork == nil ? "已保存" : "保存中")
            }
            .animation(Motion.quick, value: commitWork == nil)
        }
        .font(.system(size: 11))
        .foregroundStyle(Palette.muted.opacity(0.8))
        .padding(.horizontal, Metrics.editorInset)
        .padding(.bottom, 12)
        .frame(height: 36, alignment: .bottom)
        .help(store.isICloud ? "已保存到 iCloud 云盘" : "已保存在本机")
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

// MARK: - 标签：朱砂色文字，用“·”分隔

struct TagsEditor: View {
    @Binding var tags: [String]
    let suggestions: [String]
    @State private var input = ""

    private var available: [String] {
        suggestions.filter { !tags.contains($0) }
    }

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(tags.enumerated()), id: \.element) { index, tag in
                if index > 0 {
                    Text("·").foregroundStyle(Palette.faint)
                }
                TagChip(name: tag) {
                    withAnimation(Motion.quick) { tags.removeAll { $0 == tag } }
                }
            }
            TextField("＋ 标签", text: $input)
                .textFieldStyle(.plain)
                .foregroundStyle(Palette.muted)
                .frame(minWidth: 60, maxWidth: 140)
                .padding(.leading, tags.isEmpty ? 0 : 6)
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
                .tint(Palette.faint)
                .help("选择已有标签")
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 13))
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
            Text("#" + name).foregroundStyle(Palette.tag)
            // 删除按钮常驻占位，只切换透明度，悬停时不挤动布局
            Button(action: onRemove) {
                Image(systemName: "xmark").font(.system(size: 8, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Palette.muted)
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
            HStack(spacing: 12) {
                ForEach(attachments, id: \.self) { name in
                    let url = store.attachmentURL(name)
                    PhotoPrint(url: url, width: 112, height: 80)
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
            .padding(.vertical, 6)
            .padding(.horizontal, 2)
        }
        .frame(height: 100)
    }
}

/// 像夹在本子里的照片：白边、相角、略带阴影
struct PhotoPrint: View {
    let url: URL
    var width: CGFloat
    var height: CGFloat
    var tilt: Double = 0

    var body: some View {
        ThumbnailView(url: url)
            .frame(width: width - 10, height: height - 10)
            .clipped()
            .padding(5)
            .background(Color.white)
            .overlay(alignment: .topLeading) { PhotoCorner().frame(width: 14, height: 14).offset(x: -2, y: -2) }
            .overlay(alignment: .bottomTrailing) { PhotoCorner().rotationEffect(.degrees(180)).frame(width: 14, height: 14).offset(x: 2, y: 2) }
            .shadow(color: Palette.shadow, radius: 6, y: 3)
            .rotationEffect(.degrees(tilt))
    }
}

private struct PhotoCorner: View {
    var body: some View {
        Path { p in
            p.move(to: .zero)
            p.addLine(to: CGPoint(x: 14, y: 0))
            p.addLine(to: CGPoint(x: 0, y: 14))
            p.closeSubpath()
        }
        .fill(Color(nsColor: .paper(0x8A7E69, 0x5C554A)))
    }
}

// MARK: - 结构化字段：账本样式，字段名 …… 内容，悬停时出现拷贝 / 删除

struct FieldsEditor: View {
    @Binding var fields: [NoteField]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach($fields) { $field in
                FieldRow(field: $field) {
                    let id = field.id
                    withAnimation(Motion.standard) { fields.removeAll { $0.id == id } }
                }
            }
        }
    }
}

private struct FieldRow: View {
    @Binding var field: NoteField
    let onDelete: () -> Void
    @State private var hovering = false
    @State private var copied = false

    /// 电话、编号这类内容用衬线数字显示
    private var isNumeric: Bool {
        !field.value.isEmpty && field.value.allSatisfy { $0.isNumber || " +-()".contains($0) }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            TextField("字段", text: $field.key)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .tracking(2)
                .foregroundStyle(Palette.muted)
                .frame(width: 60, alignment: .leading)
            DottedLeader()
                .frame(minWidth: 24)
            ZStack(alignment: .trailing) {
                // 隐藏文字撑开宽度，让引线一直延伸到内容前
                Text(field.value.isEmpty ? "内容" : field.value)
                    .font(valueFont)
                    .hidden()
                    .padding(.horizontal, 2)
                TextField("内容", text: $field.value)
                    .textFieldStyle(.plain)
                    .font(valueFont)
                    .foregroundStyle(Palette.ink)
                    .multilineTextAlignment(.trailing)
            }
            .fixedSize(horizontal: true, vertical: false)
            .frame(maxWidth: 320, alignment: .trailing)

            // 按钮常驻占位，只切换透明度，悬停时不会挤动布局
            HStack(spacing: 6) {
                Button {
                    Pasteboard.copy(field.value)
                    withAnimation(Motion.quick) { copied = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        withAnimation(Motion.quick) { copied = false }
                    }
                } label: {
                    Text(copied ? "已拷贝" : "拷贝")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.onButton)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Palette.button))
                }
                .buttonStyle(.plain)
                .help("拷贝内容")
                Button(action: onDelete) {
                    Image(systemName: "minus.circle")
                        .foregroundStyle(Palette.muted)
                }
                .buttonStyle(.plain)
                .help("删除字段")
            }
            .opacity(hovering || copied ? 1 : 0)
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onHover { h in withAnimation(Motion.quick) { hovering = h } }
    }

    private var valueFont: Font {
        isNumeric ? .numeral(17, weight: .semibold) : .system(size: 14, weight: .medium)
    }
}

/// 工具栏图标菜单：紧凑、不撑满，图标用墨色而不是强调色
struct IconMenu<Content: View>: View {
    let systemImage: String
    let help: String
    @ViewBuilder let content: () -> Content
    @State private var hovering = false

    var body: some View {
        Menu(content: content) {
            Image(systemName: systemImage)
                .font(.system(size: 14))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .tint(Palette.ink2)
        .frame(width: 32, height: 28)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hovering ? Palette.field : Color.clear))
        .contentShape(Rectangle())
        .onHover { h in withAnimation(Motion.quick) { hovering = h } }
        .help(help)
    }
}

/// 工具栏图标按钮：与 IconMenu 同尺寸、同悬停效果
struct IconButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 14))
                .foregroundStyle(Palette.ink2)
                .frame(width: 32, height: 28)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hovering ? Palette.field : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(Motion.quick) { hovering = h } }
        .help(help)
    }
}
