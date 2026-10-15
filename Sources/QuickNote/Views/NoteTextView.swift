import AppKit
import SwiftUI

/// 原生 NSTextView 正文编辑器，支持 Markdown 实时渲染（符号淡淡地留在原处）。
/// - 外部数据刷新时只在内容确实不同、且输入法没有在组字时才写回，避免吞字；
/// - 输入法组字过程中不做样式渲染，组字结束后再渲染。
struct NoteTextView: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String = ""
    var fontSize: CGFloat = 15

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        let textView = scrollView.documentView as! NSTextView
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

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NoteTextView
        weak var textView: NSTextView?
        let markdown: MarkdownStyler
        private var placeholderField: NSTextField?

        init(_ parent: NoteTextView) {
            self.parent = parent
            self.markdown = MarkdownStyler(fontSize: parent.fontSize)
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            restyle()
            updatePlaceholder()
        }

        func restyle() {
            guard let textView, !textView.hasMarkedText(), let storage = textView.textStorage else { return }
            markdown.apply(to: storage)
            textView.typingAttributes = markdown.baseAttributes
        }

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

    private static let heading = regex(#"^(#{1,6})[ \t]+(.+)$"#)
    private static let rule = regex(#"^ {0,3}([-*_])(?: *\1){2,} *$"#)
    private static let task = regex(#"^(\s*[-*+] \[([ xX])\] )(.*)$"#)
    private static let bullet = regex(#"^(\s*)([-*+]|\d+\.)( )(?!\[[ xX]\] )"#)
    private static let quote = regex(#"^(>+ ?)(.*)$"#)
    private static let bold = regex(#"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#)
    private static let italic = regex(#"(?<![*\w])\*(?=[^\s*])([^*\n]+?)(?<=[^\s*])\*(?![*\w])"#)
    private static let code = regex(#"`([^`\n]+)`"#)
    private static let link = regex(#"\[([^\]\n]+)\]\(([^)\s]+)\)"#)

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

        each(Self.heading) { m in
            let level = m.range(at: 1).length
            let size: CGFloat = [0, 22, 19, 17, 16, 15, 15][level]
            storage.addAttributes([.font: Fonts.song(size, bold: true), .foregroundColor: Palette.inkNS], range: m.range)
            storage.addAttributes(faint, range: NSRange(location: m.range.location, length: m.range(at: 1).length))
        }
        each(Self.rule) { m in
            storage.addAttributes([.foregroundColor: Palette.faintNS, .kern: 4], range: m.range)
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
    }
}
