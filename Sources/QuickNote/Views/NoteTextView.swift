import AppKit
import SwiftUI

/// 原生 NSTextView 正文编辑器。
/// 与 SwiftUI TextEditor 的区别：外部数据刷新时只在内容确实不同、且输入法没有正在组字（marked text）时才写回，
/// 避免中文输入被打断或吞字；同时获得系统的查找栏、撤销、拼写检查等行为。
struct NoteTextView: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String = ""
    var font: NSFont = .systemFont(ofSize: 14)

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        let textView = scrollView.documentView as! NSTextView
        textView.delegate = context.coordinator
        textView.string = text
        textView.font = font
        textView.textColor = .labelColor
        textView.drawsBackground = false
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.textContainerInset = NSSize(width: Metrics.textViewInset, height: 8)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        textView.defaultParagraphStyle = paragraph
        textView.typingAttributes[.paragraphStyle] = paragraph
        context.coordinator.textView = textView
        context.coordinator.updatePlaceholder()
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? NSTextView else { return }
        // 只有外部真的改了内容（如 iCloud 同步）才写回；组字过程中绝不覆盖
        if textView.string != text && !textView.hasMarkedText() {
            textView.string = text
            textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        }
        context.coordinator.updatePlaceholder()
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NoteTextView
        weak var textView: NSTextView?
        private var placeholderField: NSTextField?

        init(_ parent: NoteTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            updatePlaceholder()
        }

        func updatePlaceholder() {
            guard let textView else { return }
            if placeholderField == nil, !parent.placeholder.isEmpty {
                let field = NSTextField(labelWithString: parent.placeholder)
                field.font = parent.font
                field.textColor = .placeholderTextColor
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
