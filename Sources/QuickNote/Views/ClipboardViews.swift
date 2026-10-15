import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ClipListView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var settings: AppSettings
    @Binding var detail: Detail?
    @State private var confirmClear = false
    @State private var filter: ClipFilter = .all

    enum ClipFilter: String, CaseIterable {
        case all = "全部", text = "文本", image = "图片"
    }

    var body: some View {
        let clips = store.sortedClips.filter { c in
            switch filter {
            case .all: return true
            case .text: return !c.isImage
            case .image: return c.isImage
            }
        }
        let pinned = clips.filter(\.pinned)
        let others = clips.filter { !$0.pinned }
        List(selection: $detail) {
            if pinned.isEmpty {
                clipRows(others)
            } else {
                Section("置顶") { clipRows(pinned) }
                if !others.isEmpty {
                    Section("最近") { clipRows(others) }
                }
            }
        }
        .listStyle(.inset)
        .animation(Motion.standard, value: clips.map(\.id))
        .contextMenu(forSelectionType: Detail.self) { items in
            if let clip = clip(from: items) {
                Button("拷贝") { copy(clip) }
                Button(clip.pinned ? "取消置顶" : "置顶") {
                    withAnimation(Motion.standard) { store.toggleClipPin(clip.id) }
                }
                Divider()
                Button("删除", role: .destructive) { store.deleteClip(clip.id) }
            }
        } primaryAction: { items in
            // 双击 / 回车：拷贝
            if let clip = clip(from: items) { copy(clip) }
        }
        .onDeleteCommand {
            if case .clip(let id) = detail { store.deleteClip(id) }
        }
        .overlay {
            if clips.isEmpty {
                if settings.clipboardEnabled {
                    EmptyStateView(title: "暂无记录", systemImage: "list.clipboard", description: "复制的文字和图片会自动出现在这里")
                } else {
                    EmptyStateView(title: "已暂停记录", systemImage: "pause.circle", description: "在右上角菜单中恢复记录")
                }
            }
        }
        .navigationTitle("剪贴板历史")
        .navigationSubtitle(settings.clipboardEnabled ? "\(clips.count) 条" : "已暂停记录")
        .toolbar {
            ToolbarItem {
                Picker("类型", selection: $filter) {
                    ForEach(ClipFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .help("筛选类型")
            }
            ToolbarItem {
                Menu {
                    Toggle("记录剪贴板", isOn: $settings.clipboardEnabled)
                    Divider()
                    Button("清空历史…") { confirmClear = true }
                } label: {
                    Label("更多", systemImage: "ellipsis.circle")
                }
                .help("更多")
            }
        }
        .alert("清空剪贴板历史？", isPresented: $confirmClear) {
            Button("清空", role: .destructive) { store.clearClips(keepPinned: true) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("置顶的条目会保留。")
        }
    }

    private func clipRows(_ clips: [ClipItem]) -> some View {
        ForEach(clips) { clip in
            ClipRow(clip: clip).tag(Detail.clip(clip.id))
        }
    }

    private func clip(from items: Set<Detail>) -> ClipItem? {
        guard case .clip(let id)? = items.first else { return nil }
        return store.clips.first { $0.id == id }
    }

    private func copy(_ clip: ClipItem) {
        store.copyClip(clip)
        if settings.hideAfterCopy {
            NotificationCenter.default.post(name: .qnHideWindow, object: nil)
        }
    }
}

struct ClipRow: View {
    @EnvironmentObject var store: Store
    let clip: ClipItem
    var query: String = ""

    var body: some View {
        let terms = SearchText.terms(query)
        HStack(alignment: .top, spacing: 10) {
            if clip.isImage, let url = store.clipImageURL(clip) {
                ThumbnailView(url: url, maxPixel: 200)
                    .frame(width: 56, height: 42)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(primaryText(terms))
                    .font(Typography.rowDetail)
                    .foregroundStyle(clip.isImage && clip.text.isEmpty ? Color.secondary : Color.primary)
                    .lineLimit(2)
                HStack(spacing: 4) {
                    Text(RelativeDate.short(clip.createdAt))
                    if let app = clip.sourceApp { Text("· \(app)") }
                }
                .font(Typography.meta)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, Metrics.rowVerticalPadding)
    }

    private func primaryText(_ terms: [String]) -> AttributedString {
        if clip.isImage && clip.text.isEmpty {
            return AttributedString("图片 \(clip.imageWidth ?? 0) × \(clip.imageHeight ?? 0)")
        }
        let text = terms.isEmpty
            ? clip.text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
            : SearchText.snippet(clip.text, terms: terms)
        return SearchText.highlight(text, terms: terms)
    }
}

struct ClipDetailView: View {
    @EnvironmentObject var store: Store
    let clipID: UUID
    let onSavedAsNote: (Note) -> Void
    @State private var copied = false

    var body: some View {
        if let clip = store.clips.first(where: { $0.id == clipID }) {
            VStack(spacing: 0) {
                if clip.isImage, let url = store.clipImageURL(clip) {
                    imageBody(clip, url: url)
                } else {
                    ScrollView {
                        Text(clip.text)
                            .font(.system(size: 14))
                            .lineSpacing(4)
                            .textSelection(.enabled)
                            .frame(maxWidth: Metrics.readableWidth, alignment: .leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, Metrics.editorInset)
                            .padding(.vertical, 20)
                    }
                }
                Divider()
                HStack(spacing: 6) {
                    Text(clip.createdAt.formatted(date: .long, time: .standard))
                    if let app = clip.sourceApp { Text("· 来自 \(app)") }
                    Spacer()
                    if clip.isImage {
                        Text("\(clip.imageWidth ?? 0) × \(clip.imageHeight ?? 0)")
                    } else {
                        Text("\(clip.text.count) 字")
                    }
                }
                .font(Typography.meta)
                .foregroundStyle(.secondary)
                .padding(.horizontal, Metrics.editorInset)
                .padding(.vertical, 8)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .toolbar { toolbar(clip) }
        }
    }

    /// 工具栏只放“拷贝”和“存为笔记”，其余收进“更多”
    @ToolbarContentBuilder
    private func toolbar(_ clip: ClipItem) -> some ToolbarContent {
        ToolbarItemGroup {
            Button {
                store.copyClip(clip)
                withAnimation(Motion.quick) { copied = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    withAnimation(Motion.quick) { copied = false }
                }
            } label: {
                Label(copied ? "已拷贝" : "拷贝", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .help(clip.isImage ? "拷贝图片" : "拷贝")

            Menu {
                Button("收件箱") { onSavedAsNote(store.saveClipAsNote(clip, projectID: nil)) }
                Divider()
                ForEach(store.projects) { p in
                    Button(p.name) { onSavedAsNote(store.saveClipAsNote(clip, projectID: p.id)) }
                }
            } label: {
                Label("存为笔记", systemImage: "note.text.badge.plus")
            }
            .help("存为笔记")

            Menu {
                if clip.isImage && !clip.text.isEmpty {
                    Button("拷贝识别出的文字") { Pasteboard.copy(clip.text) }
                }
                if clip.isImage, let url = store.clipImageURL(clip) {
                    Button("存储图片为…") { saveImage(url) }
                }
                Button(clip.pinned ? "取消置顶" : "置顶") {
                    withAnimation(Motion.standard) { store.toggleClipPin(clip.id) }
                }
                Divider()
                Button("删除", role: .destructive) { store.deleteClip(clip.id) }
            } label: {
                Label("更多", systemImage: "ellipsis.circle")
            }
            .help("更多")
        }
    }

    private func imageBody(_ clip: ClipItem, url: URL) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ThumbnailView(url: url, maxPixel: 2400)
                    .frame(maxWidth: .infinity, maxHeight: 520)
                    .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
                    .onTapGesture(count: 2) { NSWorkspace.shared.open(url) }
                    .help("双击用“预览”打开")
                if !clip.text.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("识别出的文字")
                            .font(Typography.meta.weight(.medium))
                            .foregroundStyle(.secondary)
                        Text(clip.text)
                            .font(.callout)
                            .lineSpacing(3)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(maxWidth: Metrics.readableWidth)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Metrics.editorInset)
            .padding(.vertical, 20)
        }
    }

    private func saveImage(_ url: URL) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "剪贴板图片 \(Int(Date().timeIntervalSince1970)).png"
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        try? FileManager.default.removeItem(at: dest)
        try? FileManager.default.copyItem(at: url, to: dest)
    }
}

struct SearchResultsView: View {
    @EnvironmentObject var store: Store
    let query: String
    @Binding var detail: Detail?

    var body: some View {
        let notes = store.searchNotes(query)
        let clips = store.searchClips(query)
        List(selection: $detail) {
            if !notes.isEmpty {
                Section("笔记") {
                    ForEach(notes) { n in
                        NoteRow(note: n, showProject: true, query: query)
                            .tag(Detail.note(n.id))
                            .contextMenu { NoteContextMenu(note: n) }
                    }
                }
            }
            if !clips.isEmpty {
                Section("剪贴板") {
                    ForEach(clips) { c in
                        ClipRow(clip: c, query: query).tag(Detail.clip(c.id))
                    }
                }
            }
        }
        .listStyle(.inset)
        .overlay {
            if notes.isEmpty && clips.isEmpty {
                EmptyStateView(title: "没有结果", systemImage: "magnifyingglass", description: "没有找到“\(query)”")
            }
        }
        .navigationTitle("搜索结果")
        .navigationSubtitle("\(notes.count + clips.count) 条")
    }
}
