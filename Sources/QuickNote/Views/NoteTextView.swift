import AppKit
import SwiftUI

/// 原生 NSTextView 正文编辑器，支持 Markdown 实时渲染（符号淡淡地留在原处）。
/// - 外部数据刷新时只在内容确实不同、且输入法没有在组字时才写回，避免吞字；
/// - 输入法组字过程中不做样式渲染，组字结束后再渲染；
/// - 输入 “/”（中文输入法下是 “、”）弹出命令菜单；列表回车自动续行；点 [ ] 勾选待办。
struct NoteTextView: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String = ""
    var fontSize: CGFloat = 15

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        // 显式搭建 TextKit 1 文本栈，以便自己绘制分隔线
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)

        let textView = MarkdownTextView(frame: .zero, textContainer: container)
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        textView.delegate = context.coordinator
        textView.drawsBackground = false
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.textContainerInset = NSSize(width: Metrics.textViewInset, height: 6)
        textView.insertionPointColor = Palette.sealNS
        textView.linkTextAttributes = [
            .foregroundColor: Palette.sealNS,
            .cursor: NSCursor.pointingHand,
        ]

        let coordinator = context.coordinator
        coordinator.textView = textView
        textView.typingAttributes = coordinator.markdown.baseAttributes
        textView.string = text
        coordinator.restyle()
        coordinator.updatePlaceholder()
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? NSTextView else { return }
        // 只有外部真的改了内容（如 iCloud 同步）才写回；组字过程中绝不覆盖
        if textView.string != text && !textView.hasMarkedText() {
            textView.string = text
            textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            context.coordinator.restyle()
        }
        context.coordinator.updatePlaceholder()
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.slashMenu.close()
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NoteTextView
        weak var textView: MarkdownTextView?
        let markdown: MarkdownStyler
        let slashMenu = SlashMenuController()
        private var placeholderField: NSTextField?
        /// 刚输入的 “/” 的位置，等文字真正插入后再弹菜单
        private var pendingSlash: Int?
        /// 当前命令菜单对应的 “/” 位置
        private var slashStart: Int?

        init(_ parent: NoteTextView) {
            self.parent = parent
            self.markdown = MarkdownStyler(fontSize: parent.fontSize)
            super.init()
            slashMenu.onPick = { [weak self] command in self?.apply(command) }
        }

        // MARK: 文字变化

        func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
            if let s = replacementString, s == "/" || s == "、", !textView.hasMarkedText() {
                let ns = textView.string as NSString
                let previous: unichar? = range.location > 0 ? ns.character(at: range.location - 1) : nil
                // 只在行首或空白后触发，避免影响网址、日期里的斜杠
                if previous == nil || [10, 32, 9, 0x3000].contains(previous!) {
                    pendingSlash = range.location
                }
            }
            return true
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            restyle()
            updatePlaceholder()
            if let start = pendingSlash {
                pendingSlash = nil
                slashStart = start
                updateSlashMenu()
            } else if slashStart != nil {
                updateSlashMenu()
            }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            if slashStart != nil { updateSlashMenu() }
        }

        func restyle() {
            guard let textView, !textView.hasMarkedText(), let storage = textView.textStorage else { return }
            textView.ruleRanges = markdown.apply(to: storage)
            textView.typingAttributes = markdown.baseAttributes
            // 改样式会打断光标闪烁，换行后光标会“消失”一下；这里重新显示光标
            textView.updateInsertionPointStateAndRestartTimer(true)
        }

        // MARK: 按键

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if slashMenu.isVisible {
                switch selector {
                case #selector(NSResponder.moveUp(_:)):
                    slashMenu.moveSelection(-1)
                    return true
                case #selector(NSResponder.moveDown(_:)):
                    slashMenu.moveSelection(1)
                    return true
                case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
                    if let command = slashMenu.selectedCommand { apply(command) }
                    return true
                case #selector(NSResponder.cancelOperation(_:)):
                    closeSlashMenu()
                    return true
                default:
                    break
                }
            }
            if selector == #selector(NSResponder.insertNewline(_:)) {
                return continueList(in: textView)
            }
            return false
        }

        /// 列表、待办、有序列表、引用：回车自动续上前缀；空项再回车结束列表
        private func continueList(in textView: NSTextView) -> Bool {
            let ns = textView.string as NSString
            let selection = textView.selectedRange()
            guard selection.length == 0 else { return false }
            let lineRange = ns.lineRange(for: NSRange(location: selection.location, length: 0))
            var line = ns.substring(with: lineRange)
            if line.hasSuffix("\n") { line.removeLast() }
            guard let match = MarkdownStyler.listPrefix.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) else {
                return false
            }
            let prefixLength = match.range.length
            // 光标在前缀里面时按普通回车处理
            guard selection.location - lineRange.location >= prefixLength else { return false }
            let content = (line as NSString).substring(from: prefixLength)
            if content.trimmingCharacters(in: .whitespaces).isEmpty {
                textView.insertText("", replacementRange: NSRange(location: lineRange.location, length: prefixLength))
                return true
            }
            let indent = (line as NSString).substring(with: match.range(at: 1))
            let marker = (line as NSString).substring(with: match.range(at: 2))
            var next: String
            if marker.contains("[") {
                next = String(marker.prefix(1)) + " [ ] "
            } else if let number = Int(marker.trimmingCharacters(in: CharacterSet(charactersIn: ". "))) {
                next = "\(number + 1). "
            } else {
                next = marker
            }
            next = indent + next
            textView.insertText("\n" + next, replacementRange: selection)
            return true
        }

        // MARK: “/” 命令菜单

        private func updateSlashMenu() {
            guard let textView, let start = slashStart else { return }
            let ns = textView.string as NSString
            let caret = textView.selectedRange().location
            guard start < ns.length, caret > start, caret - start <= 16,
                  ["/", "、"].contains(ns.substring(with: NSRange(location: start, length: 1))) else {
                closeSlashMenu()
                return
            }
            let query = ns.substring(with: NSRange(location: start + 1, length: caret - start - 1))
            if query.contains(where: { $0.isNewline || $0 == " " }) {
                closeSlashMenu()
                return
            }
            guard slashMenu.filter(query) else {
                closeSlashMenu()
                return
            }
            if let window = textView.window {
                let rect = textView.firstRect(forCharacterRange: NSRange(location: start, length: 1), actualRange: nil)
                slashMenu.show(below: rect, in: window)
            }
        }

        private func closeSlashMenu() {
            slashStart = nil
            slashMenu.close()
        }

        private func apply(_ command: SlashCommand) {
            guard let textView, let start = slashStart else { return }
            let ns = textView.string as NSString
            let caret = min(textView.selectedRange().location, ns.length)
            let range = NSRange(location: start, length: max(caret - start, 0))
            let atLineStart = start == 0 || ns.character(at: start - 1) == 10
            var insertion = command.text()
            if command.isBlock && !atLineStart {
                insertion = "\n" + insertion
            }
            closeSlashMenu()
            textView.insertText(insertion, replacementRange: range)
            if command.caretBack > 0 {
                let location = textView.selectedRange().location - command.caretBack
                textView.setSelectedRange(NSRange(location: max(location, 0), length: 0))
            }
        }

        // MARK: 占位文字

        func updatePlaceholder() {
            guard let textView else { return }
            if placeholderField == nil, !parent.placeholder.isEmpty {
                let field = NSTextField(labelWithString: parent.placeholder)
                field.font = markdown.baseFont
                field.textColor = Palette.faintNS
                field.translatesAutoresizingMaskIntoConstraints = false
                textView.addSubview(field)
                let inset = textView.textContainerInset
                let padding = textView.textContainer?.lineFragmentPadding ?? 5
                NSLayoutConstraint.activate([
                    field.leadingAnchor.constraint(equalTo: textView.leadingAnchor, constant: inset.width + padding),
                    field.topAnchor.constraint(equalTo: textView.topAnchor, constant: inset.height),
                ])
                placeholderField = field
            }
            placeholderField?.isHidden = !textView.string.isEmpty || textView.hasMarkedText()
        }
    }
}

/// 自己绘制 Markdown 分隔线；点击 [ ] 勾选待办
final class MarkdownTextView: NSTextView {
    var ruleRanges: [NSRange] = [] {
        didSet { if ruleRanges != oldValue { needsDisplay = true } }
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let layoutManager, let textContainer else { return }
        let length = (string as NSString).length
        let origin = textContainerOrigin
        let padding = textContainer.lineFragmentPadding
        Palette.faintNS.setFill()
        for range in ruleRanges where NSMaxRange(range) <= length {
            let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            guard glyphs.length > 0 else { continue }
            let line = layoutManager.lineFragmentUsedRect(forGlyphAt: glyphs.location, effectiveRange: nil)
            let y = (origin.y + line.midY).rounded(.down) + 0.5
            NSRect(x: origin.x + padding, y: y, width: textContainer.size.width - padding * 2, height: 1).fill()
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if toggleTask(at: point) { return }
        super.mouseDown(with: event)
    }

    /// 点在 “[ ]” 上时切换勾选状态（可撤销）
    private func toggleTask(at point: NSPoint) -> Bool {
        let ns = string as NSString
        guard ns.length > 0 else { return false }
        let index = characterIndexForInsertion(at: point)
        let lineRange = ns.lineRange(for: NSRange(location: min(index, ns.length - 1), length: 0))
        let line = ns.substring(with: lineRange)
        guard let match = MarkdownStyler.taskBox.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) else {
            return false
        }
        let box = NSRange(location: lineRange.location + match.range(at: 1).location, length: 3) // “[ ]”
        guard index >= box.location, index <= NSMaxRange(box) else { return false }
        let markRange = NSRange(location: box.location + 1, length: 1)
        let checked = ns.substring(with: markRange).lowercased() == "x"
        let replacement = checked ? " " : "x"
        if shouldChangeText(in: markRange, replacementString: replacement) {
            replaceCharacters(in: markRange, with: replacement)
            didChangeText()
        }
        return true
    }
}

/// 轻量 Markdown 样式：标题、加粗、斜体、列表、待办、引用、分隔线、行内代码、链接
final class MarkdownStyler {
    let baseFont: NSFont
    let baseAttributes: [NSAttributedString.Key: Any]
    private let fontSize: CGFloat

    init(fontSize: CGFloat) {
        self.fontSize = fontSize
        baseFont = Fonts.song(fontSize)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = 1.55
        paragraph.paragraphSpacing = 6
        baseAttributes = [
            .font: baseFont,
            .foregroundColor: Palette.ink2NS,
            .paragraphStyle: paragraph,
        ]
    }

    private static func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
    }

    /// 列表前缀：缩进 + 标记（待办 / 无序 / 有序 / 引用）
    static let listPrefix = regex(#"^(\s*)([-*+] \[[ xX]\] |[-*+] |\d+\. |> )"#)
    static let taskBox = regex(#"^\s*[-*+] (\[[ xX]\]) "#)

    private static let heading = regex(#"^(#{1,6})[ \t]+(.+)$"#)
    private static let rule = regex(#"^ {0,3}([-*_])(?: *\1){2,} *$"#)
    private static let task = regex(#"^(\s*[-*+] \[([ xX])\] )(.*)$"#)
    private static let bullet = regex(#"^(\s*)([-*+]|\d+\.)( )(?!\[[ xX]\] )"#)
    private static let quote = regex(#"^(>+ ?)(.*)$"#)
    private static let bold = regex(#"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#)
    private static let italic = regex(#"(?<![*\w])\*(?=[^\s*])([^*\n]+?)(?<=[^\s*])\*(?![*\w])"#)
    private static let code = regex(#"`([^`\n]+)`"#)
    private static let link = regex(#"\[([^\]\n]+)\]\(([^)\s]+)\)"#)

    /// 渲染样式，返回需要画成横线的分隔线范围
    @discardableResult
    func apply(to storage: NSTextStorage) -> [NSRange] {
        let text = storage.string as NSString
        let full = NSRange(location: 0, length: text.length)
        var rules: [NSRange] = []
        storage.beginEditing()
        storage.setAttributes(baseAttributes, range: full)

        func each(_ re: NSRegularExpression, _ body: (NSTextCheckingResult) -> Void) {
            re.enumerateMatches(in: storage.string, options: [], range: full) { match, _, _ in
                if let match { body(match) }
            }
        }
        let faint: [NSAttributedString.Key: Any] = [.foregroundColor: Palette.faintNS]

        each(Self.heading) { m in
            let level = m.range(at: 1).length
            let size: CGFloat = [0, 22, 19, 17, 16, 15, 15][level]
            storage.addAttributes([.font: Fonts.song(size, bold: true), .foregroundColor: Palette.inkNS], range: m.range)
            storage.addAttributes(faint, range: NSRange(location: m.range.location, length: m.range(at: 1).length))
        }
        each(Self.rule) { m in
            // 符号隐藏，由 MarkdownTextView 画一条横线
            storage.addAttributes([.foregroundColor: NSColor.clear], range: m.range)
            rules.append(m.range)
        }
        each(Self.task) { m in
            storage.addAttributes(faint, range: m.range(at: 1))
            if text.substring(with: m.range(at: 2)).lowercased() == "x" {
                storage.addAttributes([
                    .foregroundColor: Palette.mutedNS,
                    .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                    .strikethroughColor: Palette.faintNS,
                ], range: m.range(at: 3))
            }
        }
        each(Self.bullet) { m in
            storage.addAttributes([.foregroundColor: Palette.sealNS], range: m.range(at: 2))
        }
        each(Self.quote) { m in
            storage.addAttributes([.foregroundColor: Palette.sealNS], range: m.range(at: 1))
            storage.addAttributes([.foregroundColor: Palette.mutedNS], range: m.range(at: 2))
        }
        each(Self.bold) { m in
            storage.addAttributes([.font: Fonts.song(fontSize, bold: true), .foregroundColor: Palette.inkNS], range: m.range(at: 2))
            let marker = m.range(at: 1).length
            storage.addAttributes(faint, range: NSRange(location: m.range.location, length: marker))
            storage.addAttributes(faint, range: NSRange(location: NSMaxRange(m.range) - marker, length: marker))
        }
        each(Self.italic) { m in
            storage.addAttributes([.obliqueness: 0.15], range: m.range(at: 1))
            storage.addAttributes(faint, range: NSRange(location: m.range.location, length: 1))
            storage.addAttributes(faint, range: NSRange(location: NSMaxRange(m.range) - 1, length: 1))
        }
        each(Self.code) { m in
            storage.addAttributes([
                .font: NSFont.monospacedSystemFont(ofSize: fontSize - 2, weight: .regular),
                .backgroundColor: Palette.fieldNS,
                .foregroundColor: Palette.inkNS,
            ], range: m.range)
        }
        each(Self.link) { m in
            let urlString = text.substring(with: m.range(at: 2))
            if let url = URL(string: urlString) {
                storage.addAttributes([.link: url], range: m.range(at: 1))
            }
            storage.addAttributes(faint, range: NSRange(location: m.range.location, length: 1))
            storage.addAttributes(faint, range: NSRange(location: NSMaxRange(m.range(at: 1)), length: NSMaxRange(m.range) - NSMaxRange(m.range(at: 1))))
        }
        storage.endEditing()
        return rules
    }
}
