import AppKit

@main
enum QuickNoteMain {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}

extension Notification.Name {
    static let qnNewNote = Notification.Name("qn.newNote")
    static let qnNewProject = Notification.Name("qn.newProject")
    static let qnFocusSearch = Notification.Name("qn.focusSearch")
    static let qnShowClipboard = Notification.Name("qn.showClipboard")
    static let qnToggleSidebar = Notification.Name("qn.toggleSidebar")
    static let qnOpenNote = Notification.Name("qn.openNote")
    static let qnHideWindow = Notification.Name("qn.hideWindow")
    static let qnDockIconChanged = Notification.Name("qn.dockIconChanged")
}

/// 版本号（来自 Info.plist，由 build.sh 写入）
enum AppVersion {
    static var short: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    static var commit: String {
        Bundle.main.object(forInfoDictionaryKey: "QNCommit") as? String ?? "dev"
    }

    /// 侧栏底部显示：v1.0.42
    static var display: String { "v" + short }

    /// 悬停提示：版本 1.0.42 · 提交 abc1234
    static var detail: String { "版本 \(short) · 提交 \(commit)" }
}

enum Pasteboard {
    static func copy(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    static func copyImage(at url: URL) {
        let item = NSPasteboardItem()
        if let data = try? Data(contentsOf: url) {
            if url.pathExtension.lowercased() == "png" {
                item.setData(data, forType: .png)
            }
            if let tiff = NSImage(data: data)?.tiffRepresentation {
                item.setData(tiff, forType: .tiff)
            }
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([item])
    }

    /// 读取剪贴板中的图片（PNG 数据）
    static func imagePNGData() -> Data? {
        let pb = NSPasteboard.general
        if let png = pb.data(forType: .png) { return png }
        return NSImage(pasteboard: pb)?.pngData
    }
}
