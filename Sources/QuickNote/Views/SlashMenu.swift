import AppKit
import SwiftUI

/// “/” 命令：插入常用的 Markdown 格式
struct SlashCommand: Identifiable {
    let id: String
    let title: String
    let icon: String
    /// 右侧淡淡显示的 Markdown 写法
    let hint: String
    /// 拼音、英文等检索词
    let keywords: [String]
    /// 需要单独成行的格式（标题、列表等）
    let isBlock: Bool
    /// 插入后光标往回移的字符数（比如加粗把光标放在两组 ** 中间）
    let caretBack: Int
    let text: () -> String

    func matches(_ query: String) -> Bool {
        let q = query.lowercased()
        if q.isEmpty { return true }
        return title.contains(q) || keywords.contains { $0.hasPrefix(q) || $0.contains(q) }
    }

    static let all: [SlashCommand] = [
        SlashCommand(id: "todo", title: "待办", icon: "checkmark.square", hint: "- [ ]",
                     keywords: ["todo", "daiban", "db", "renwu", "rw", "task"], isBlock: true, caretBack: 0) { "- [ ] " },
        SlashCommand(id: "h1", title: "大标题", icon: "textformat.size.larger", hint: "#",
                     keywords: ["h1", "biaoti", "bt", "title", "dabiaoti"], isBlock: true, caretBack: 0) { "# " },
        SlashCommand(id: "h2", title: "中标题", icon: "textformat.size", hint: "##",
                     keywords: ["h2", "biaoti", "bt", "zhongbiaoti"], isBlock: true, caretBack: 0) { "## " },
        SlashCommand(id: "h3", title: "小标题", icon: "textformat.size.smaller", hint: "###",
                     keywords: ["h3", "biaoti", "bt", "xiaobiaoti"], isBlock: true, caretBack: 0) { "### " },
        SlashCommand(id: "ul", title: "无序列表", icon: "list.bullet", hint: "-",
                     keywords: ["list", "ul", "liebiao", "lb", "wuxu"], isBlock: true, caretBack: 0) { "- " },
        SlashCommand(id: "ol", title: "有序列表", icon: "list.number", hint: "1.",
                     keywords: ["ol", "number", "youxu", "yx", "liebiao"], isBlock: true, caretBack: 0) { "1. " },
        SlashCommand(id: "quote", title: "引用", icon: "text.quote", hint: ">",
                     keywords: ["quote", "yinyong", "yy"], isBlock: true, caretBack: 0) { "> " },
        SlashCommand(id: "hr", title: "分隔线", icon: "minus", hint: "---",
                     keywords: ["hr", "line", "divider", "fengexian", "fgx", "fenge"], isBlock: true, caretBack: 0) { "---\n" },
        SlashCommand(id: "code", title: "代码块", icon: "chevron.left.forwardslash.chevron.right", hint: "```",
                     keywords: ["code", "daima", "dm"], isBlock: true, caretBack: 4) { "```\n\n```" },
        SlashCommand(id: "bold", title: "加粗", icon: "bold", hint: "**",
                     keywords: ["bold", "jiacu", "jc", "cu"], isBlock: false, caretBack: 2) { "****" },
        SlashCommand(id: "link", title: "链接", icon: "link", hint: "[]()",
                     keywords: ["link", "url", "lianjie", "lj"], isBlock: false, caretBack: 3) { "[]()" },
        SlashCommand(id: "date", title: "今天日期", icon: "calendar", hint: "日期",
                     keywords: ["date", "today", "riqi", "rq", "jintian", "jt"], isBlock: false, caretBack: 0) {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            return f.string(from: Date())
        },
    ]
}

final class SlashMenuModel: ObservableObject {
    @Published var items: [SlashCommand] = SlashCommand.all
    @Published var selected = 0
}

/// 跟在光标下方的小浮层；不抢键盘焦点，上下键 / 回车 / Esc 由正文编辑器转交过来
final class SlashMenuController {
    let model = SlashMenuModel()
    var onPick: (SlashCommand) -> Void = { _ in }
    private var panel: NSPanel?

    private static let width: CGFloat = 248
    private static let rowHeight: CGFloat = 34

    var isVisible: Bool { panel?.isVisible ?? false }

    var selectedCommand: SlashCommand? {
        model.items.indices.contains(model.selected) ? model.items[model.selected] : nil
    }

    /// 按输入过滤；没有匹配项时返回 false
    func filter(_ query: String) -> Bool {
        let items = SlashCommand.all.filter { $0.matches(query) }
        model.items = items
        model.selected = 0
        return !items.isEmpty
    }

    func moveSelection(_ delta: Int) {
        guard !model.items.isEmpty else { return }
        model.selected = (model.selected + delta + model.items.count) % model.items.count
    }

    /// 显示在 rect（屏幕坐标，“/” 所在位置）下方；下方放不下时显示在上方
    func show(below rect: NSRect, in parent: NSWindow) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let height = CGFloat(min(model.items.count, 8)) * Self.rowHeight + 12
        var origin = NSPoint(x: rect.minX - 8, y: rect.minY - height - 6)
        if let screen = parent.screen?.visibleFrame, origin.y < screen.minY {
            origin.y = rect.maxY + 6
        }
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: Self.width, height: height)), display: true)
        if panel.parent == nil { parent.addChildWindow(panel, ordered: .above) }
        panel.orderFront(nil)
        panel.invalidateShadow()
    }

    func close() {
        guard let panel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.contentView = NSHostingView(rootView: SlashMenuView(model: model) { [weak self] command in
            self?.onPick(command)
        })
        return panel
    }
}

struct SlashMenuView: View {
    @ObservedObject var model: SlashMenuModel
    let onPick: (SlashCommand) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                        row(item, selected: index == model.selected)
                            .id(item.id)
                            .onTapGesture { onPick(item) }
                            .onHover { if $0 { model.selected = index } }
                    }
                }
                .padding(6)
            }
            .onChange(of: model.selected) { index in
                if model.items.indices.contains(index) { proxy.scrollTo(model.items[index].id) }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Palette.paper)
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.line))
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func row(_ item: SlashCommand, selected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(selected ? Palette.seal : Palette.muted)
                .frame(width: 20)
            Text(item.title)
                .font(.system(size: 13))
                .foregroundStyle(Palette.ink)
            Spacer()
            Text(item.hint)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Palette.faint)
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(selected ? Palette.field : Color.clear))
        .contentShape(Rectangle())
    }
}
