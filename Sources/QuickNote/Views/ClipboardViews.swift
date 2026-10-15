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
        VStack(spacing: 0) {
            ColumnHeader(title: "剪贴板历史", count: clips.count) {
                Toggle("记录", isOn: $settings.clipboardEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .help("暂停 / 恢复记录剪贴板")
                Button {
                    confirmClear = true
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("清空历史（保留置顶）")
            }
            Picker("", selection: $filter) {
                ForEach(ClipFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            Divider()
            List(selection: $detail) {
                ForEach(clips) { clip in
                    ClipRow(clip: clip).tag(Detail.clip(clip.id))
                }
            }
            .contextMenu(forSelectionType: Detail.self) { items in
                if let clip = clip(from: items) {
                    Button("复制") { copy(clip) }
                    Button(clip.pinned ? "取消置顶" : "置顶") { store.toggleClipPin(clip.id) }
                    Divider()
                    Button("删除", role: .destructive) { store.deleteClip(clip.id) }
                }
            } primaryAction: { items in
                // 双击 / 回车：复制
                if let clip = clip(from: items) { copy(clip) }
            }
            .onDeleteCommand {
                if case .clip(let id) = detail { store.deleteClip(id) }
            }
            .overlay {
                if clips.isEmpty {
                    Text(settings.clipboardEnabled ? "复制点什么，就会自动出现在这里" : "剪贴板记录已暂停")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .alert("清空剪贴板历史？", isPresented: $confirmClear) {
            Button("清空", role: .destructive) { store.clearClips(keepPinned: true) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("置顶的条目会保留。")
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
        HStack(alignment: .top, spacing: 8) {
            if clip.isImage, let url = store.clipImageURL(clip) {
                ThumbnailView(url: url, maxPixel: 200)
                    .frame(width: 64, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .top, spacing: 4) {
                    if clip.pinned {
                        Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.orange)
                    }
                    if clip.isImage {
                        let ocr = terms.isEmpty ? clip.text.replacingOccurrences(of: "\n", with: " ") : SearchText.snippet(clip.text, terms: terms)
                        Text(ocr.isEmpty ? AttributedString("图片 \(clip.imageWidth ?? 0)×\(clip.imageHeight ?? 0)") : SearchText.highlight(ocr, terms: terms))
                            .font(.system(size: 12))
                            .foregroundStyle(ocr.isEmpty ? Color.secondary : Color.primary)
                            .lineLimit(2)
                    } else {
                        let text = terms.isEmpty
                            ? clip.text.trimmingCharacters(in: .whitespacesAndNewlines)
                            : SearchText.snippet(clip.text, terms: terms)
                        Text(SearchText.highlight(text, terms: terms))
                            .font(.system(size: 12))
                            .lineLimit(3)
                    }
                }
                HStack(spacing: 6) {
                    Text(clip.createdAt.formatted(date: .abbreviated, time: .shortened))
                    if let app = clip.sourceApp { Text("· \(app)") }
                    if !clip.isImage { Text("· \(clip.text.count) 字") }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 3)
    }
}

struct ClipDetailView: View {
    @EnvironmentObject var store: Store
    let clipID: UUID
    let onSavedAsNote: (Note) -> Void
    @State private var copied = false

    var body: some View {
        if let clip = store.clips.first(where: { $0.id == clipID }) {
            VStack(alignment: .leading, spacing: 0) {
                toolbar(clip)
                Divider()
                if clip.isImage, let url = store.clipImageURL(clip) {
                    imageBody(clip, url: url)
                } else {
                    ScrollView {
                        Text(clip.text)
                            .font(.system(size: 13))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                    }
                }
                Divider()
                HStack {
                    Text(clip.createdAt.formatted(date: .complete, time: .standard))
                    if let app = clip.sourceApp { Text("来自 \(app)") }
                    Spacer()
                    if clip.isImage {
                        Text("\(clip.imageWidth ?? 0) × \(clip.imageHeight ?? 0)")
                    } else {
                        Text("\(clip.text.count) 字")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
            }
        }
    }

    private func toolbar(_ clip: ClipItem) -> some View {
        HStack(spacing: 12) {
            Button {
                store.copyClip(clip)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
            } label: {
                Label(copied ? "已复制" : (clip.isImage ? "复制图片" : "复制"),
                      systemImage: copied ? "checkmark" : "doc.on.doc")
            }

            if clip.isImage && !clip.text.isEmpty {
                Button {
                    Pasteboard.copy(clip.text)
                } label: {
                    Label("复制识别的文字", systemImage: "text.viewfinder")
                }
            }

            Menu {
                Button("收件箱") { onSavedAsNote(store.saveClipAsNote(clip, projectID: nil)) }
                Divider()
                ForEach(store.projects) { p in
                    Button(p.name) { onSavedAsNote(store.saveClipAsNote(clip, projectID: p.id)) }
                }
            } label: {
                Label("存为笔记", systemImage: "square.and.arrow.down")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            if clip.isImage, let url = store.clipImageURL(clip) {
                Button {
                    saveImage(url)
                } label: {
                    Label("另存为…", systemImage: "square.and.arrow.up")
                }
            }

            Spacer()

            Button {
                store.toggleClipPin(clip.id)
            } label: {
                Image(systemName: clip.pinned ? "pin.fill" : "pin")
            }
            .help(clip.pinned ? "取消置顶" : "置顶（不会被自动清理）")

            Button {
                store.deleteClip(clip.id)
            } label: {
                Image(systemName: "trash")
            }
            .help("删除")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 16)
        .frame(height: 38)
    }

    private func imageBody(_ clip: ClipItem, url: URL) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ThumbnailView(url: url, maxPixel: 2400)
                    .frame(maxWidth: .infinity, maxHeight: 520)
                    .onTapGesture(count: 2) { NSWorkspace.shared.open(url) }
                    .help("双击用“预览”打开")
                if !clip.text.isEmpty {
                    Text("识别到的文字").font(.caption).foregroundStyle(.secondary)
                    Text(clip.text)
                        .font(.system(size: 12))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(16)
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
        VStack(spacing: 0) {
            ColumnHeader(title: "搜索结果", count: notes.count + clips.count) { EmptyView() }
            Divider()
            List(selection: $detail) {
                if !notes.isEmpty {
                    Section("笔记 · \(notes.count)") {
                        ForEach(notes) { n in
                            NoteRow(note: n, showProject: true, query: query)
                                .tag(Detail.note(n.id))
                                .contextMenu { NoteContextMenu(note: n) }
                        }
                    }
                }
                if !clips.isEmpty {
                    Section("剪贴板 · \(clips.count)") {
                        ForEach(clips) { c in
                            ClipRow(clip: c, query: query).tag(Detail.clip(c.id))
                        }
                    }
                }
            }
            .overlay {
                if notes.isEmpty && clips.isEmpty {
                    Text("没有找到“\(query)”").foregroundStyle(.secondary)
                }
            }
        }
    }
}
