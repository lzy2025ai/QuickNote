import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// 打开笔记时要定位、闪一下的位置
enum RevealTarget: Equatable {
    case tag(String)
    case text(String)
}

/// ⌘V 粘贴进正文的图片
enum PastedImage {
    case file(URL)
    case png(Data)

    /// 剪贴板里是图片（截图、图片文件）时返回；有文字时按普通粘贴处理
    static func read(from pb: NSPasteboard) -> [PastedImage]? {
        let urls = Pasteboard.fileURLs(pb)
        if !urls.isEmpty {
            let images = urls.filter(Pasteboard.isImageFile)
            if !images.isEmpty { return images.map { .file($0) } }
        }
        if Pasteboard.meaningfulText(pb) != nil { return nil }
        if let png = Pasteboard.imagePNGData(pb) { return [.png(png)] }
        return nil
    }
}

/// 原生 NSTextView 正文编辑器，支持 Markdown 实时渲染。
/// - 外部数据刷新时只在内容确实不同、且输入法没有在组字时才写回，避免吞字；
/// - 输入法组字过程中不做样式渲染，组字结束后再渲染；
/// - 输入 “/”（中文输入法下是 “、”）弹出命令菜单；列表回车自动续行；点方框勾选待办；
/// - ⌘V 粘贴图片，图片直接显示在正文里；#标签 高亮显示。
struct NoteTextView: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String = ""
    var fontSize: CGFloat = 15
    var reveal: RevealTarget?
    var attachmentURL: (String) -> URL = { URL(fileURLWithPath: $0) }
    var importImages: ([PastedImage]) -> [String] = { _ in [] }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        // 显式搭建 TextKit 1 文本栈，以便自己绘制分隔线、方框、图片
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
        textView.textContainerInset = NSSize(width: Metrics.textViewInset, height: 14)
        textView.insertionPointColor = Palette.sealNS
        textView.linkTextAttributes = [
            .foregroundColor: Palette.sealNS,
            .cursor: NSCursor.pointingHand,
        ]

        let coordinator = context.coordinator
        coordinator.textView = textView
        textView.placeholder = NSAttributedString(
            string: placeholder,
            attributes: coordinator.markdown.baseAttributes.merging([.foregroundColor: Palette.faintNS]) { $1 }
        )
        textView.onPasteImages = { [weak coordinator] images in coordinator?.insertImages(images) ?? false }
        textView.typingAttributes = coordinator.markdown.baseAttributes
        textView.string = text
        coordinator.restyle()
        if let reveal {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { coordinator.reveal(reveal) }
        }
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
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.slashMenu.close()
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NoteTextView
        weak var textView: MarkdownTextView?
        let markdown: MarkdownStyler
        let slashMenu = SlashMenuController()
        /// 刚输入的 “/” 的位置，等文字真正插入后再弹菜单
        private var pendingSlash: Int?
        /// 当前命令菜单对应的 “/” 位置
        private var slashStart: Int?
        /// 刚敲完 “---”，文字插入后自动换到下一行
        private var pendingRuleBreak = false

        init(_ parent: NoteTextView) {
            self.parent = parent
            self.markdown = MarkdownStyler(fontSize: parent.fontSize)
            super.init()
            markdown.imageURL = { [weak self] name in self?.parent.attachmentURL(name) }
            slashMenu.onPick = { [weak self] command in self?.apply(command) }
        }

        // MARK: 文字变化

        func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
            guard let s = replacementString, !textView.hasMarkedText() else { return true }
            let ns = textView.string as NSString
            if s == "/" || s == "、" {
                let previous: unichar? = range.location > 0 ? ns.character(at: range.location - 1) : nil
                // 只在行首或空白后触发，避免影响网址、日期里的斜杠
                if previous == nil || [10, 32, 9, 0x3000].contains(previous!) {
                    pendingSlash = range.location
                }
            } else if ["-", "*", "_"].contains(s), range.length == 0 {
                // 在行尾敲出 “---” 时，自动换到下一行
                let lineRange = ns.lineRange(for: NSRange(location: range.location, length: 0))
                var lineEnd = NSMaxRange(lineRange)
                if lineEnd > lineRange.location, ns.character(at: lineEnd - 1) == 10 { lineEnd -= 1 }
                let before = ns.substring(with: NSRange(location: lineRange.location, length: range.location - lineRange.location))
                if range.location == lineEnd, before == String(repeating: s, count: 2) {
                    pendingRuleBreak = true
                }
            }
            return true
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            if pendingRuleBreak {
                pendingRuleBreak = false
                textView.insertText("\n", replacementRange: textView.selectedRange())
                return // insertText 会再触发一次 textDidChange
            }
            parent.text = textView.string
            restyle()
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
            textView.typingAttributes = markdown.baseAttributes
            textView.needsDisplay = true
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
            if selector == #selector(NSResponder.deleteBackward(_:)), let range = imageLineToDelete(in: textView) {
                // 图片整行一起删，不会删出半截 Markdown
                textView.insertText("", replacementRange: range)
                return true
            }
            return false
        }

        /// 光标在图片行末尾，或紧跟在图片行后面的行首时，退格删除整张图片
        private func imageLineToDelete(in textView: NSTextView) -> NSRange? {
            let ns = textView.string as NSString
            let selection = textView.selectedRange()
            guard selection.length == 0, selection.location > 0 else { return nil }
            func imageLine(containing location: Int) -> NSRange? {
                let lineRange = ns.lineRange(for: NSRange(location: location, length: 0))
                let line = ns.substring(with: lineRange).trimmingCharacters(in: .newlines)
                let range = NSRange(location: 0, length: (line as NSString).length)
                return Note.inlineImageRegex.firstMatch(in: line, range: range) != nil ? lineRange : nil
            }
            let lineStart = ns.lineRange(for: NSRange(location: selection.location, length: 0)).location
            if selection.location > lineStart { return imageLine(containing: selection.location) }
            return imageLine(containing: selection.location - 1)
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

        // MARK: 粘贴图片

        /// 图片存进附件目录，正文里各占一行；返回 false 时按普通粘贴处理
        func insertImages(_ images: [PastedImage]) -> Bool {
            guard let textView else { return false }
            let names = parent.importImages(images)
            guard !names.isEmpty else { return false }
            let ns = textView.string as NSString
            let selection = textView.selectedRange()
            let atLineStart = selection.location == 0 || ns.character(at: selection.location - 1) == 10
            var insertion = names.map { "![](\($0))" }.joined(separator: "\n") + "\n"
            if !atLineStart { insertion = "\n" + insertion }
            textView.insertText(insertion, replacementRange: selection)
            textView.scrollRangeToVisible(textView.selectedRange())
            return true
        }

        // MARK: 定位

        func reveal(_ target: RevealTarget) {
            guard let textView, let layoutManager = textView.layoutManager, let container = textView.textContainer else { return }
            let ns = textView.string as NSString
            let full = NSRange(location: 0, length: ns.length)
            var found: NSRange?
            switch target {
            case .tag(let tag):
                found = Note.inlineTagRegex.matches(in: textView.string, range: full)
                    .first { ns.substring(with: $0.range(at: 1)) == tag }?.range
            case .text(let term):
                let r = ns.range(of: term, options: [.caseInsensitive, .diacriticInsensitive])
                if r.location != NSNotFound { found = r }
            }
            guard let range = found else { return }
            layoutManager.ensureLayout(for: container)
            textView.setSelectedRange(NSRange(location: NSMaxRange(range), length: 0))
            textView.scrollRangeToVisible(range)
            textView.showFindIndicator(for: range)
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
    }
}

extension NSAttributedString.Key {
    /// 分隔线（值无意义）
    static let qnRule = NSAttributedString.Key("qn.rule")
    /// 待办方框 “- [ ]”，值为是否已勾选
    static let qnTask = NSAttributedString.Key("qn.task")
    /// 无序列表的 “-”
    static let qnBullet = NSAttributedString.Key("qn.bullet")
    /// 引用段落（含换行，连续几行画成一条竖线）
    static let qnQuote = NSAttributedString.Key("qn.quote")
    /// 正文里的 #标签
    static let qnTag = NSAttributedString.Key("qn.tag")
    /// 正文里的图片，值为 InlineImage
    static let qnImage = NSAttributedString.Key("qn.image")
}

/// 正文里一张图片的位置和显示尺寸
final class InlineImage: NSObject {
    let url: URL
    let size: NSSize

    init(url: URL, size: NSSize) {
        self.url = url
        self.size = size
    }

    static let maxWidth: CGFloat = 460
    static let maxHeight: CGFloat = 360
    private static var sizeCache: [String: NSSize] = [:]

    /// 读图片头信息得到显示尺寸（按 DPI 换算成点，再等比缩到上限以内）
    static func displaySize(for url: URL) -> NSSize {
        if let cached = sizeCache[url.path] { return cached }
        var size = NSSize(width: maxWidth, height: 200)
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           var w = props[kCGImagePropertyPixelWidth] as? CGFloat,
           var h = props[kCGImagePropertyPixelHeight] as? CGFloat, w > 0, h > 0 {
            if let orientation = props[kCGImagePropertyOrientation] as? Int, orientation >= 5 { swap(&w, &h) }
            let dpi = (props[kCGImagePropertyDPIWidth] as? CGFloat) ?? 72
            let scale = dpi > 0 ? 72 / dpi : 1
            w *= scale
            h *= scale
            let fit = min(1, maxWidth / w, maxHeight / h)
            size = NSSize(width: (w * fit).rounded(), height: (h * fit).rounded())
            sizeCache[url.path] = size
        }
        return size
    }
}

/// 把 Markdown 符号画成真正的样式：分隔线、待办方框、列表圆点、引用竖线、标签底色、图片；点击方框勾选待办。
/// 位置信息挂在文字属性上，输入法组字时随文字一起移动，不会错位。
final class MarkdownTextView: NSTextView {
    var bodyFontSize: CGFloat = 15
    var placeholder: NSAttributedString?
    var onPasteImages: (([PastedImage]) -> Bool)?

    // MARK: 组字时也要重画（占位文字、自绘元素）

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        needsDisplay = true
    }

    override func unmarkText() {
        super.unmarkText()
        needsDisplay = true
    }

    // MARK: 粘贴

    /// 在正文里复制、剪切的文字不进剪贴板历史
    override func copy(_ sender: Any?) {
        super.copy(sender)
        Pasteboard.markOwn()
    }

    override func cut(_ sender: Any?) {
        super.cut(sender)
        Pasteboard.markOwn()
    }

    override func paste(_ sender: Any?) {
        if let images = PastedImage.read(from: .general), onPasteImages?(images) == true { return }
        super.paste(sender)
    }

    // 纯文本编辑器默认只在剪贴板里有文字时才启用“粘贴”，剪贴板里只有图片（比如微信截图）时
    // ⌘V 根本不会走到 paste(_:)。这里告诉系统：有图片也可以粘贴。
    override func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(paste(_:)), isEditable, onPasteImages != nil, Pasteboard.hasImage() { return true }
        return super.validateMenuItem(item)
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(paste(_:)), isEditable, onPasteImages != nil, Pasteboard.hasImage() { return true }
        return super.validateUserInterfaceItem(item)
    }

    // MARK: 绘制

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let storage = textStorage else { return }
        if storage.length == 0 {
            drawPlaceholder()
            return
        }
        let full = NSRange(location: 0, length: storage.length)
        storage.enumerateAttribute(.qnTag, in: full) { value, range, _ in
            if value != nil { drawTag(range) }
        }
        storage.enumerateAttribute(.qnQuote, in: full) { value, range, _ in
            if value != nil { drawQuote(range) }
        }
        storage.enumerateAttribute(.qnRule, in: full) { value, range, _ in
            if value != nil { drawRule(range) }
        }
        storage.enumerateAttribute(.qnTask, in: full) { value, range, _ in
            if let checked = value as? Bool { drawTask(range, checked: checked) }
        }
        storage.enumerateAttribute(.qnBullet, in: full) { value, range, _ in
            if value != nil { drawBullet(range) }
        }
        storage.enumerateAttribute(.qnImage, in: full) { value, range, _ in
            if let image = value as? InlineImage { drawImage(image, range: range) }
        }
    }

    private func drawPlaceholder() {
        guard let placeholder, !hasMarkedText(), let textContainer else { return }
        let padding = textContainer.lineFragmentPadding
        let origin = textContainerOrigin
        let rect = NSRect(x: origin.x + padding, y: origin.y, width: textContainer.size.width - padding * 2, height: 200)
        placeholder.draw(with: rect, options: [.usesLineFragmentOrigin])
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

    /// 引用：左侧一条朱砂细竖线，连续几行连成一条
    private func drawQuote(_ range: NSRange) {
        let ns = string as NSString
        var last = NSMaxRange(range) - 1
        while last > range.location, ns.character(at: last) == 10 { last -= 1 }
        guard let first = anchor(at: range.location), let end = anchor(at: last) else { return }
        let top = first.midY - bodyFontSize * 0.68
        let bottom = end.midY + bodyFontSize * 0.68
        let bar = NSRect(x: first.x.rounded() + 1, y: top, width: 2.5, height: bottom - top)
        Palette.sealNS.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: bar, xRadius: 1.25, yRadius: 1.25).fill()
    }

    /// #标签：淡淡的底色
    private func drawTag(_ range: NSRange) {
        guard let layoutManager, let textContainer else { return }
        let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let origin = textContainerOrigin
        let height = bodyFontSize * 1.45
        var index = range.location
        layoutManager.enumerateEnclosingRects(
            forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: textContainer
        ) { rect, _ in
            // 只取水平范围，纵向按这一行文字的中线居中，不受行高影响
            let x = rect.minX + origin.x
            let charIndex = self.characterIndexForInsertion(at: NSPoint(x: x + 1, y: rect.maxY + origin.y - 2))
            index = min(max(charIndex, index), NSMaxRange(range) - 1)
            guard let point = self.anchor(at: index) else { return }
            let pill = NSRect(x: x - 3, y: point.midY - height / 2, width: rect.width + 6, height: height)
            Palette.tagNS.withAlphaComponent(0.1).setFill()
            NSBezierPath(roundedRect: pill, xRadius: 4, yRadius: 4).fill()
        }
    }

    private func imageRect(_ image: InlineImage, range: NSRange) -> NSRect? {
        guard let layoutManager, let textContainer else { return nil }
        let glyph = layoutManager.glyphIndexForCharacter(at: range.location)
        guard glyph < layoutManager.numberOfGlyphs else { return nil }
        let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let origin = textContainerOrigin
        let available = textContainer.size.width - textContainer.lineFragmentPadding * 2
        let scale = min(1, available / max(image.size.width, 1))
        return NSRect(
            x: origin.x + textContainer.lineFragmentPadding,
            y: origin.y + fragment.minY + MarkdownStyler.imagePadding,
            width: (image.size.width * scale).rounded(),
            height: (image.size.height * scale).rounded()
        )
    }

    /// 图片：圆角、细边；选中时描一圈朱砂色
    private func drawImage(_ image: InlineImage, range: NSRange) {
        guard let rect = imageRect(image, range: range), needsToDraw(rect) else { return }
        let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        let maxPixel = Int(max(rect.width, rect.height) * (window?.backingScaleFactor ?? 2))
        if let nsImage = ImageLoader.thumbnail(image.url, maxPixel: maxPixel) {
            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            nsImage.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
                         hints: [.interpolation: NSImageInterpolation.high])
            NSGraphicsContext.restoreGraphicsState()
        } else {
            Palette.fieldNS.setFill()
            path.fill()
        }
        let selected = selectedRanges.map(\.rangeValue).contains { NSIntersectionRange($0, range).length > 0 }
        if selected {
            path.lineWidth = 2
            Palette.sealNS.setStroke()
        } else {
            path.lineWidth = 1
            Palette.lineNS.setStroke()
        }
        path.stroke()
    }

    /// 图片行的行高很高，光标只画一行文字的高度
    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        var r = rect
        if rect.height > bodyFontSize * 3 {
            r.size.height = (bodyFontSize * 1.4).rounded()
            r.origin.y = rect.maxY - r.height - MarkdownStyler.imagePadding
        }
        super.drawInsertionPoint(in: r, color: color, turnedOn: flag)
    }

    // MARK: 点击

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if event.clickCount == 2, let url = image(at: point) {
            NSWorkspace.shared.open(url)
            return
        }
        if toggleTask(at: point) { return }
        super.mouseDown(with: event)
    }

    /// 双击图片用“预览”打开
    private func image(at point: NSPoint) -> URL? {
        guard let storage = textStorage, storage.length > 0 else { return nil }
        let index = min(characterIndexForInsertion(at: point), storage.length - 1)
        for i in [index, max(index - 1, 0)] {
            var range = NSRange()
            if let image = storage.attribute(.qnImage, at: i, effectiveRange: &range) as? InlineImage,
               let rect = imageRect(image, range: range), rect.contains(point) {
                return image.url
            }
        }
        return nil
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

/// 轻量 Markdown 样式：标题、加粗、斜体、列表、待办、引用、分隔线、行内代码、链接、#标签、图片
final class MarkdownStyler {
    let baseFont: NSFont
    let baseAttributes: [NSAttributedString.Key: Any]
    private let baseParagraph: NSParagraphStyle
    private let fontSize: CGFloat
    /// 图片文件名 → 本地路径
    var imageURL: (String) -> URL? = { _ in nil }

    static let imagePadding: CGFloat = 6

    init(fontSize: CGFloat) {
        self.fontSize = fontSize
        baseFont = Fonts.song(fontSize)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = 1.3
        paragraph.paragraphSpacing = 5
        baseParagraph = paragraph
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

    /// 渲染样式；分隔线、待办、圆点等用自定义属性标出，由 MarkdownTextView 绘制
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
            // “> ” 隐藏，左侧画竖线；折行后的文字和首行对齐
            let marker = m.range(at: 1)
            storage.addAttributes(hidden, range: marker)
            storage.addAttributes([.foregroundColor: Palette.mutedNS], range: m.range(at: 2))
            let indent = (text.substring(with: marker) as NSString).size(withAttributes: [.font: baseFont]).width
            let paragraph = baseParagraph.mutableCopy() as! NSMutableParagraphStyle
            paragraph.headIndent = indent
            let lineRange = text.lineRange(for: m.range)
            storage.addAttribute(.paragraphStyle, value: paragraph, range: lineRange)
            storage.addAttribute(.qnQuote, value: true, range: lineRange)
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
        each(Note.inlineTagRegex) { m in
            storage.addAttributes([.foregroundColor: Palette.tagNS, .qnTag: true], range: m.range)
        }
        each(Note.inlineImageRegex) { m in
            // 整行文字隐藏、缩到极小，行高撑到图片高度，由 MarkdownTextView 把图片画在这一行
            let name = text.substring(with: m.range(at: 1))
            guard let url = imageURL(name) else { return }
            let image = InlineImage(url: url, size: InlineImage.displaySize(for: url))
            let paragraph = NSMutableParagraphStyle()
            let height = image.size.height + Self.imagePadding * 2
            paragraph.minimumLineHeight = height
            paragraph.maximumLineHeight = height
            paragraph.paragraphSpacing = 4
            storage.removeAttribute(.link, range: m.range)
            storage.removeAttribute(.qnTag, range: m.range)
            storage.addAttributes([
                .font: NSFont.systemFont(ofSize: 1),
                .foregroundColor: NSColor.clear,
                .qnImage: image,
            ], range: m.range)
            storage.addAttribute(.paragraphStyle, value: paragraph, range: text.lineRange(for: m.range))
        }
        storage.endEditing()
    }
}
