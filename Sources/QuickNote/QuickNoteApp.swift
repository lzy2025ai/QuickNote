import AppKit
import ImageIO
import UniformTypeIdentifiers

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
    /// 本 App 自己复制的内容带上这个标记，剪贴板历史据此跳过（不再看当前前台是哪个 App，
    /// 否则在本 App 前台时用微信等工具截图，截图也会被当成“自己复制的”而漏记）
    static let ownMarker = NSPasteboard.PasteboardType("com.local.quicknote.own")

    static func markOwn(_ pb: NSPasteboard = .general) {
        pb.addTypes([ownMarker], owner: nil)
        pb.setData(Data(), forType: ownMarker)
    }

    static func copy(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        markOwn(pb)
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
        markOwn(pb)
    }

    /// 有实际内容的文字（只有空白不算）
    static func meaningfulText(_ pb: NSPasteboard = .general) -> String? {
        guard let text = pb.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    /// 剪贴板里的文件 URL（访达里复制的文件、部分截图工具放的临时文件）
    static func fileURLs(_ pb: NSPasteboard = .general) -> [URL] {
        (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    /// 是否是图片文件：看扩展名，没有扩展名时看文件内容（微信等工具的临时文件可能没有扩展名）
    static func isImageFile(_ url: URL) -> Bool {
        if let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image) { return true }
        if let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType, type.conforms(to: .image) { return true }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
        return CGImageSourceGetType(source) != nil && CGImageSourceGetCount(source) > 0
    }

    /// 读取剪贴板中的图片，统一转成 PNG。
    /// 除了 PNG / TIFF，也认 JPEG、HEIC、GIF 等任何图片格式（微信、QQ 截图放的格式不一定是 PNG）
    static func imagePNGData(_ pb: NSPasteboard = .general) -> Data? {
        if let png = pb.data(forType: .png) { return png }
        for type in pb.types ?? [] {
            guard let ut = UTType(type.rawValue), ut.conforms(to: .image),
                  let data = pb.data(forType: type) else { continue }
            if let png = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]) { return png }
            if let png = NSImage(data: data)?.pngData { return png }
        }
        return NSImage(pasteboard: pb)?.pngData
    }

    /// 诊断用：列出剪贴板里现在有哪些格式
    static func describe(_ pb: NSPasteboard = .general) -> String {
        let types = pb.types ?? []
        if types.isEmpty { return "剪贴板是空的。" }
        var lines = types.map { type -> String in
            let size = pb.data(forType: type)?.count
            return "• \(type.rawValue)" + (size.map { "（\(ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file))）" } ?? "")
        }
        let urls = fileURLs(pb)
        if !urls.isEmpty { lines.append("文件：" + urls.map(\.path).joined(separator: "，")) }
        lines.append(imagePNGData(pb) != nil ? "→ 能识别出图片" : "→ 识别不出图片")
        return lines.joined(separator: "\n")
    }
}
