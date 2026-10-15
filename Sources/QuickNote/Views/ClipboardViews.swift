import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 剪贴板：按天分组的流水时间线

struct ClipListView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var settings: AppSettings
    @Binding var detail: Detail?
    @State private var confirmClear = false
    @State private var filter: ClipFilter = .all
    @FocusState private var focused: Bool

    enum ClipFilter: String, CaseIterable {
        case all = "全部", text = "文字", image = "图片"
    }

    private struct DayGroup: Identifiable {
        let id: String
        let title: String
        let clips: [ClipItem]
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
        let groups = dayGroups(clips.filter { !$0.pinned })

        VStack(spacing: 0) {
            controls
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if !pinned.isEmpty {
                            header("置顶")
                            ForEach(pinned) { clip in timelineRow(clip) }
                        }
                        ForEach(groups) { group in
                            header(group.title)
                            ForEach(group.clips) { clip in timelineRow(clip) }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                    .animation(Motion.standard, value: clips.map(\.id))
                }
                .overlay {
                    if clips.isEmpty {
                        if settings.clipboardEnabled {
                            EmptyStateView(title: "还没有记录", detail: "复制的文字和图片会自动出现在这里")
                        } else {
                            EmptyStateView(title: "已暂停记录", detail: "在右上角菜单中恢复")
                        }
                    }
                }
                .focusable()
                .focused($focused)
                .hideFocusRing()
                .onMoveCommand { direction in
                    move(direction, in: pinned + groups.flatMap(\.clips), proxy: proxy)
                }
                .onDeleteCommand {
                    if case .clip(let id) = detail { store.deleteClip(id) }
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

    /// 类型筛选用文字标签，选中的加粗并在下方点一笔朱砂；右侧是“记录中 / 已暂停”开关和“清空”
    private var controls: some View {
        HStack(alignment: .firstTextBaseline, spacing: 18) {
            ForEach(ClipFilter.allCases, id: \.self) { f in
                FilterTab(title: f.rawValue, selected: filter == f) {
                    withAnimation(Motion.quick) { filter = f }
                }
            }
            Spacer()
            Button {
                withAnimation(Motion.quick) { settings.clipboardEnabled.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Circle()
                        .fill(settings.clipboardEnabled ? Palette.saved : Palette.faint)
                        .frame(width: 6, height: 6)
                    Text(settings.clipboardEnabled ? "记录中" : "已暂停")
                }
            }
            .buttonStyle(.plain)
            .help(settings.clipboardEnabled ? "点击暂停自动记录" : "点击恢复自动记录")
            Button("清空") { confirmClear = true }
                .buttonStyle(.plain)
                .help("清空历史（保留置顶）")
        }
        .font(.system(size: 12.5))
        .foregroundStyle(Palette.muted)
        .padding(.horizontal, 22)
        .padding(.bottom, 6)
    }

    private func header(_ title: String) -> some View {
        Text(title)
            .font(.song(13))
            .tracking(4)
            .foregroundStyle(Palette.muted)
            .padding(.leading, 76)
            .padding(.top, 14)
            .padding(.bottom, 8)
    }

    private func timelineRow(_ clip: ClipItem) -> some View {
        let selected = detail == .clip(clip.id)
        return HStack(alignment: .top, spacing: 12) {
            Text(ChineseDate.time(clip.createdAt))
                .font(.numeral(15, weight: .semibold))
                .foregroundStyle(selected ? Palette.ink : Palette.ink2)
                .frame(width: 44, alignment: .trailing)
                .padding(.top, 11)
            // 时间轴：竖线 + 节点
            VStack(spacing: 0) {
                Rectangle().fill(Palette.line).frame(width: 1, height: 14)
                Circle()
                    .fill(selected ? Palette.seal : Palette.faint)
                    .frame(width: selected ? 9 : 7, height: selected ? 9 : 7)
                Rectangle().fill(Palette.line).frame(width: 1).frame(maxHeight: .infinity)
            }
            .frame(width: 12)
            ClipCard(clip: clip, selected: selected)
                .padding(.bottom, 10)
        }
        .id(clip.id)
        .contentShape(Rectangle())
        .onTapGesture {
            detail = .clip(clip.id)
            focused = true
        }
        .simultaneousGesture(TapGesture(count: 2).onEnded { copy(clip) })
        .contextMenu {
            Button("拷贝") { copy(clip) }
            Button(clip.pinned ? "取消置顶" : "置顶") {
                withAnimation(Motion.standard) { store.toggleClipPin(clip.id) }
            }
            Divider()
            Button("删除", role: .destructive) { store.deleteClip(clip.id) }
        }
    }

    private func dayGroups(_ clips: [ClipItem]) -> [DayGroup] {
        let cal = Calendar.current
        var result: [DayGroup] = []
        for clip in clips {
            let day = cal.startOfDay(for: clip.createdAt)
            let key = "\(day.timeIntervalSince1970)"
            if result.last?.id == key {
                let last = result.removeLast()
                result.append(DayGroup(id: key, title: last.title, clips: last.clips + [clip]))
            } else {
                result.append(DayGroup(id: key, title: ChineseDate.dayHeader(clip.createdAt), clips: [clip]))
            }
        }
        return result
    }

    private func move(_ direction: MoveCommandDirection, in clips: [ClipItem], proxy: ScrollViewProxy) {
        guard !clips.isEmpty else { return }
        let index = clips.firstIndex { detail == .clip($0.id) }
        let next: Int
        switch direction {
        case .up: next = max((index ?? 0) - 1, 0)
        case .down: next = min((index ?? -1) + 1, clips.count - 1)
        default: return
        }
        detail = .clip(clips[next].id)
        proxy.scrollTo(clips[next].id)
    }

    private func copy(_ clip: ClipItem) {
        store.copyClip(clip)
        if settings.hideAfterCopy {
            NotificationCenter.default.post(name: .qnHideWindow, object: nil)
        }
    }
}

/// 时间线上的一条：文字是纸条，图片是夹在本子里的照片
struct ClipCard: View {
    @EnvironmentObject var store: Store
    let clip: ClipItem
    var selected = false
    var query: String = ""
    @State private var hovering = false

    var body: some View {
        let terms = SearchText.terms(query)
        VStack(alignment: .leading, spacing: 6) {
            if clip.isImage, let url = store.clipImageURL(clip) {
                VStack(alignment: .leading, spacing: 8) {
                    PhotoPrint(url: url, width: 168, height: 112, tilt: -1.2)
                        .padding(.vertical, 4)
                    if !clip.text.isEmpty {
                        Text(SearchText.highlight(SearchText.snippet(clip.text.replacingOccurrences(of: "\n", with: " "), terms: terms, radius: 40), terms: terms))
                            .font(.system(size: 12.5))
                            .foregroundStyle(Palette.ink2)
                            .lineLimit(2)
                    }
                }
            } else {
                let text = terms.isEmpty
                    ? clip.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    : SearchText.snippet(clip.text, terms: terms)
                Text(SearchText.highlight(text, terms: terms))
                    .font(.system(size: 13.5))
                    .foregroundStyle(Palette.ink)
                    .lineSpacing(3)
                    .lineLimit(3)
            }
            HStack(spacing: 8) {
                if clip.pinned {
                    Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(Palette.seal)
                }
                if let app = clip.sourceApp { Text("来自 \(app)") }
                if clip.isImage {
                    Text(verbatim: "\(clip.imageWidth ?? 0) × \(clip.imageHeight ?? 0)")
                } else {
                    Text(verbatim: "\(clip.text.count) 字")
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(Palette.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(selected || hovering ? Palette.paper : Color.clear)
                .shadow(color: selected ? Palette.shadow : .clear, radius: 8, y: 3)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(selected ? Palette.seal : Color.clear, lineWidth: 1.2)
        )
        .onHover { h in withAnimation(Motion.quick) { hovering = h } }
    }
}

// MARK: - 剪贴详情

struct ClipDetailView: View {
    @EnvironmentObject var store: Store
    let clipID: UUID
    let onSavedAsNote: (Note) -> Void
    @State private var copied = false

    var body: some View {
        if let clip = store.clips.first(where: { $0.id == clipID }) {
            VStack(alignment: .leading, spacing: 0) {
                Color.clear.frame(height: Metrics.titlebarHeight + 12)
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        HStack(alignment: .lastTextBaseline, spacing: 12) {
                            Text(ChineseDate.time(clip.createdAt))
                                .font(.numeral(56, weight: .regular))
                                .foregroundStyle(Palette.ink)
                            Text(ChineseDate.dayHeader(clip.createdAt))
                                .font(.song(14))
                                .tracking(3)
                                .foregroundStyle(Palette.muted)
                        }
                        Rectangle().fill(Palette.ink).frame(height: 1).opacity(0.85)

                        if clip.isImage, let url = store.clipImageURL(clip) {
                            ThumbnailView(url: url, maxPixel: 2400)
                                .frame(maxWidth: .infinity, maxHeight: 420)
                                .padding(8)
                                .background(Color.white)
                                .shadow(color: Palette.shadow, radius: 10, y: 4)
                                .onTapGesture(count: 2) { NSWorkspace.shared.open(url) }
                                .help("双击用“预览”打开")
                            if !clip.text.isEmpty {
                                SectionLabel("识别出的文字")
                                Text(clip.text)
                                    .font(.song(14))
                                    .lineSpacing(5)
                                    .foregroundStyle(Palette.ink2)
                                    .textSelection(.enabled)
                            }
                        } else {
                            Text(clip.text)
                                .font(.song(17))
                                .lineSpacing(8)
                                .foregroundStyle(Palette.ink)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        actions(clip)
                            .padding(.top, 6)
                    }
                    .padding(.horizontal, Metrics.editorInset)
                    .padding(.bottom, 24)
                    .frame(maxWidth: Metrics.readableWidth, alignment: .leading)
                }
                HStack {
                    if let app = clip.sourceApp { Text("来自 \(app)") }
                    Spacer()
                    Text("密码等敏感内容不会被记录")
                }
                .font(.system(size: 11))
                .tracking(1)
                .foregroundStyle(Palette.muted)
                .padding(.horizontal, Metrics.editorInset)
                .frame(height: 38)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(Palette.paper)
        }
    }

    private func actions(_ clip: ClipItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                store.copyClip(clip)
                withAnimation(Motion.quick) { copied = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    withAnimation(Motion.quick) { copied = false }
                }
            } label: {
                HStack {
                    Text(copied ? "已拷贝" : (clip.isImage ? "拷贝图片" : "拷贝"))
                    Spacer()
                    Text("双击条目也可拷贝").font(.system(size: 11)).opacity(0.7)
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Palette.onButton)
                .padding(.horizontal, 14)
                .frame(height: 38)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.button))
            }
            .buttonStyle(.plain)

            HStack(spacing: 8) {
                Menu {
                    Button("收件箱") { onSavedAsNote(store.saveClipAsNote(clip, projectID: nil)) }
                    Divider()
                    ForEach(store.projects) { p in
                        Button(p.name) { onSavedAsNote(store.saveClipAsNote(clip, projectID: p.id)) }
                    }
                } label: {
                    Text("存为笔记…")
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.ink)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .tint(Palette.ink)
                .padding(.horizontal, 14)
                .frame(height: 38)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.field))

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
                    Image(systemName: "ellipsis")
                        .foregroundStyle(Palette.ink)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .tint(Palette.ink)
                .frame(width: 44, height: 38)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.field))
                .help("更多")
            }
        }
        .frame(maxWidth: 360)
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

// MARK: - 搜索结果

struct SearchResultsView: View {
    @EnvironmentObject var store: Store
    let query: String
    @Binding var detail: Detail?

    var body: some View {
        let notes = store.searchNotes(query)
        let clips = store.searchClips(query)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                if !notes.isEmpty {
                    SectionLabel("笔记 · \(notes.count)").padding(.horizontal, 12).padding(.vertical, 6)
                    ForEach(notes) { n in
                        NoteRow(note: n, selected: detail == .note(n.id), showProject: true, query: query)
                            .contentShape(Rectangle())
                            .onTapGesture { detail = .note(n.id) }
                            .contextMenu { NoteContextMenu(note: n) }
                    }
                }
                if !clips.isEmpty {
                    SectionLabel("剪贴板 · \(clips.count)").padding(.horizontal, 12).padding(.top, 14).padding(.bottom, 6)
                    ForEach(clips) { c in
                        ClipCard(clip: c, selected: detail == .clip(c.id), query: query)
                            .contentShape(Rectangle())
                            .onTapGesture { detail = .clip(c.id) }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 16)
        }
        .overlay {
            if notes.isEmpty && clips.isEmpty {
                EmptyStateView(title: "没有找到", detail: "换个关键词试试，或用 #标签 搜索")
            }
        }
    }
}

/// 文字筛选标签：选中加粗，下方一笔朱砂
private struct FilterTab: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Text(title)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Palette.ink : Palette.muted)
                Capsule()
                    .fill(selected ? Palette.seal : Color.clear)
                    .frame(width: 14, height: 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
