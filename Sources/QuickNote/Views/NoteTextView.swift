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
        textView.bodyFontSize = fontSize
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
            // 组字时不重新渲染，但自绘的分隔线、方框要跟着文字重画
            textView.needsDisplay = true
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
            markdown.apply(to: storage)
            textView.needsDisplay = true
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

extension NSAttributedString.Key {
    /// 分隔线（值无意义）
    static let qnRule = NSAttributedString.Key("qn.rule")
    /// 待办方框 “- [ ]”，值为是否已勾选
    static let qnTask = NSAttributedString.Key("qn.task")
    /// 无序列表的 “-”
    static let qnBullet = NSAttributedString.Key("qn.bullet")
}

/// 把 Markdown 符号画成真正的样式：分隔线、待办方框、列表圆点；点击方框勾选待办。
/// 位置信息挂在文字属性上，输入法组字时随文字一起移动，不会错位。
final class MarkdownTextView: NSTextView {
    var bodyFontSize: CGFloat = 15

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let storage = textStorage, storage.length > 0 else { return }
        let full = NSRange(location: 0, length: storage.length)
        storage.enumerateAttribute(.qnRule, in: full) { value, range, _ in
            if value != nil { drawRule(range) }
        }
        storage.enumerateAttribute(.qnTask, in: full) { value, range, _ in
            if let checked = value as? Bool { drawTask(range, checked: checked) }
        }
        storage.enumerateAttribute(.qnBullet, in: full) { value, range, _ in
            if value != nil { drawBullet(range) }
        }
    }

    /// 字符所在位置：x、文字视觉中线（视图坐标）
    private func anchor(at charIndex: Int) -> (x: CGFloat, midY: CGFloat)? {
        guard let layoutManager else { return nil }
        let glyph = layoutManager.glyphIndexForCharacter(at: charIndex)
        guard glyph < layoutManager.numberOfGlyphs else { return nil }
        let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let location = layoutManager.location(forGlyphAt: glyph)
        let origin = textContainerOrigin
        let baseline = origin.y + fragment.minY + location.y
        return (origin.x + fragment.minX + location.x, baseline - bodyFontSize * 0.36)
    }

    /// 分隔线：两端渐隐的细线，中间一枚朱砂小菱形
    private func drawRule(_ range: NSRange) {
        guard let textContainer, let point = anchor(at: range.location) else { return }
        let padding = textContainer.lineFragmentPadding
        let left = textContainerOrigin.x + padding
        let width = textContainer.size.width - padding * 2
        let centerX = left + width / 2
        let y = point.midY.rounded() + 0.5
        let half = min(width * 0.24, 150)
        let gap: CGFloat = 12
        let ink = Palette.faintNS
        let fade = NSGradient(colors: [ink.withAlphaComponent(0), ink])
        fade?.draw(in: NSRect(x: centerX - half, y: y - 0.5, width: half - gap, height: 1), angle: 0)
        fade?.draw(in: NSRect(x: centerX + gap, y: y - 0.5, width: half - gap, height: 1), angle: 180)

        let d: CGFloat = 3.2
        let diamond = NSBezierPath()
        diamond.move(to: NSPoint(x: centerX, y: y - d))
        diamond.line(to: NSPoint(x: centerX + d, y: y))
        diamond.line(to: NSPoint(x: centerX, y: y + d))
        diamond.line(to: NSPoint(x: centerX - d, y: y))
        diamond.close()
        Palette.sealNS.withAlphaComponent(0.8).setFill()
        diamond.fill()
    }

    /// 待办方框：未完成是描边小方框，完成后是朱砂底白色对勾
    private func drawTask(_ range: NSRange, checked: Bool) {
        // range 是 “- [ ]”，方框画在 “[” 的位置
        guard range.length >= 3, let point = anchor(at: range.location + 2) else { return }
        let size: CGFloat = 14
        let box = NSRect(x: point.x.rounded() + 0.5, y: (point.midY - size / 2).rounded() + 0.5, width: size - 1, height: size - 1)
        let path = NSBezierPath(roundedRect: box, xRadius: 3.5, yRadius: 3.5)
        if checked {
            Palette.sealNS.setFill()
            path.fill()
            let check = NSBezierPath()
            check.move(to: NSPoint(x: box.minX + 3.2, y: box.midY + 0.2))
            check.line(to: NSPoint(x: box.minX + 5.7, y: box.maxY - 3.4))
            check.line(to: NSPoint(x: box.maxX - 3, y: box.minY + 3.6))
            check.lineWidth = 1.6
            check.lineCapStyle = .round
            check.lineJoinStyle = .round
            NSColor.white.setStroke()
            check.stroke()
        } else {
            path.lineWidth = 1.2
            Palette.mutedNS.withAlphaComponent(0.7).setStroke()
            path.stroke()
        }
    }

    /// 无序列表：朱砂小圆点
    private func drawBullet(_ range: NSRange) {
        guard let point = anchor(at: range.location) else { return }
        let d: CGFloat = 5
        let x = point.x + bodyFontSize * 0.12
        Palette.sealNS.setFill()
        NSBezierPath(ovalIn: NSRect(x: x, y: point.midY - d / 2, width: d, height: d)).fill()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if toggleTask(at: point) { return }
        super.mouseDown(with: event)
    }

    /// 点在待办方框上时切换勾选状态（可撤销）
    private func toggleTask(at point: NSPoint) -> Bool {
        let ns = string as NSString
        guard ns.length > 0 else { return false }
        let index = characterIndexForInsertion(at: point)
        let lineRange = ns.lineRange(for: NSRange(location: min(index, ns.length - 1), length: 0))
        let line = ns.substring(with: lineRange)
        guard let match = MarkdownStyler.taskBox.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) else {
            return false
        }
        // “- [ ] ” 整段都算可点击区域
        let prefix = NSRange(location: lineRange.location + match.range(at: 1).location, length: match.range(at: 1).length + 1)
        guard index >= prefix.location, index <= NSMaxRange(prefix) else { return false }
        let markRange = NSRange(location: prefix.location + 3, length: 1)
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
        paragraph.lineHeightMultiple = 1.3
        paragraph.paragraphSpacing = 5
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
    static let taskBox = regex(#"^\s*([-*+] \[[ xX]\]) "#)

    private static let heading = regex(#"^(#{1,6})[ \t]+(.+)$"#)
    private static let rule = regex(#"^ {0,3}([-*_])(?: *\1){2,} *$"#)
    private static let task = regex(#"^\s*(([-*+] )\[([ xX])(\])) (.*)$"#)
    private static let bullet = regex(#"^(\s*)([-*+]|\d+\.)( )(?!\[[ xX]\] )"#)
    private static let quote = regex(#"^(>+ ?)(.*)$"#)
    private static let bold = regex(#"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#)
    private static let italic = regex(#"(?<![*\w])\*(?=[^\s*])([^*\n]+?)(?<=[^\s*])\*(?![*\w])"#)
    private static let code = regex(#"`([^`\n]+)`"#)
    private static let link = regex(#"\[([^\]\n]+)\]\(([^)\s]+)\)"#)

    /// 渲染样式；分隔线、待办、圆点用自定义属性标出，由 MarkdownTextView 绘制
    func apply(to storage: NSTextStorage) {
        let text = storage.string as NSString
        let full = NSRange(location: 0, length: text.length)
        storage.beginEditing()
        storage.setAttributes(baseAttributes, range: full)

        func each(_ re: NSRegularExpression, _ body: (NSTextCheckingResult) -> Void) {
            re.enumerateMatches(in: storage.string, options: [], range: full) { match, _, _ in
                if let match { body(match) }
            }
        }
        let faint: [NSAttributedString.Key: Any] = [.foregroundColor: Palette.faintNS]
        let hidden: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor.clear]

        each(Self.heading) { m in
            let level = m.range(at: 1).length
            let size: CGFloat = [0, 22, 19, 17, 16, 15, 15][level]
            storage.addAttributes([.font: Fonts.song(size, bold: true), .foregroundColor: Palette.inkNS], range: m.range)
            storage.addAttributes(faint, range: NSRange(location: m.range.location, length: m.range(at: 1).length))
        }
        each(Self.rule) { m in
            // 符号隐藏，由 MarkdownTextView 画一条横线
            storage.addAttributes(hidden, range: m.range)
            storage.addAttribute(.qnRule, value: true, range: m.range)
        }
        each(Self.task) { m in
            // “- [ ]” 隐藏后画成方框；“- ” 缩到很窄，方框和文字之间留一点空
            let checked = text.substring(with: m.range(at: 3)).lowercased() == "x"
            storage.addAttributes(hidden, range: m.range(at: 1))
            storage.addAttribute(.qnTask, value: checked, range: m.range(at: 1))
            storage.addAttribute(.font, value: Fonts.song(3) as NSFont, range: m.range(at: 2))
            storage.addAttribute(.kern, value: 5, range: m.range(at: 4))
            if checked {
                storage.addAttributes([
                    .foregroundColor: Palette.mutedNS,
                    .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                    .strikethroughColor: Palette.faintNS,
                ], range: m.range(at: 5))
            }
        }
        each(Self.bullet) { m in
            let marker = m.range(at: 2)
            if marker.length == 1 {
                storage.addAttributes(hidden, range: marker)
                storage.addAttribute(.qnBullet, value: true, range: marker)
            } else {
                storage.addAttributes([.foregroundColor: Palette.sealNS], range: marker)
            }
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
    }
}
