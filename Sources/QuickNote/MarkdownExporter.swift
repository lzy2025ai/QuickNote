import AppKit
import UniformTypeIdentifiers

/// 导出为 Markdown：带 YAML 头（项目、标签、时间），字段转为表格，图片附件复制到 assets/
enum MarkdownExporter {
    static func markdown(for note: Note, projectName: String?, assetsFolder: String = "assets") -> String {
        var lines = ["---", "title: \(yamlQuote(note.displayTitle))"]
        if let projectName { lines.append("project: \(yamlQuote(projectName))") }
        if !note.tags.isEmpty {
            lines.append("tags: [" + note.tags.map(yamlQuote).joined(separator: ", ") + "]")
        }
        lines.append("created: \(iso(note.createdAt))")
        lines.append("updated: \(iso(note.updatedAt))")
        if note.pinned { lines.append("pinned: true") }
        lines += ["---", "", "# \(note.displayTitle)", ""]

        let fields = note.fields.filter { !$0.key.isEmpty || !$0.value.isEmpty }
        if !fields.isEmpty {
            lines += ["| 字段 | 内容 |", "| --- | --- |"]
            for f in fields { lines.append("| \(cell(f.key)) | \(cell(f.value)) |") }
            lines.append("")
        }
        if !note.content.isEmpty {
            lines += [note.content, ""]
        }
        for a in note.attachments {
            lines.append("![](\(assetsFolder)/\(a))")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - 单条笔记

    static func exportNote(_ note: Note, store: Store) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = fileName(note.displayTitle) + ".md"
        panel.canCreateDirectories = true
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try write(note, to: url, store: store)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            showError(error)
        }
    }

    // MARK: - 多条笔记（按项目分文件夹）

    static func exportNotes(_ notes: [Note], title: String, store: Store) {
        guard !notes.isEmpty else {
            showMessage("没有可导出的笔记")
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "导出到这里"
        panel.message = "选择导出位置，将创建“\(title)”文件夹"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let base = panel.url else { return }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HHmm"
        let root = uniqueURL(base.appendingPathComponent("\(fileName(title)) \(formatter.string(from: Date()))"))
        do {
            let fm = FileManager.default
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            let groups = Dictionary(grouping: notes) { $0.projectID }
            for (projectID, groupNotes) in groups {
                let folderName = fileName(store.project(projectID)?.name ?? "收件箱")
                let folder = root.appendingPathComponent(folderName, isDirectory: true)
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                for note in groupNotes.sorted(by: Note.ordering) {
                    let url = uniqueURL(folder.appendingPathComponent(fileName(note.displayTitle) + ".md"))
                    try write(note, to: url, store: store)
                }
            }
            NSWorkspace.shared.activateFileViewerSelecting([root])
        } catch {
            showError(error)
        }
    }

    // MARK: - Helpers

    private static func write(_ note: Note, to url: URL, store: Store) throws {
        let md = markdown(for: note, projectName: store.project(note.projectID)?.name)
        try md.write(to: url, atomically: true, encoding: .utf8)
        guard !note.attachments.isEmpty else { return }
        let assets = url.deletingLastPathComponent().appendingPathComponent("assets", isDirectory: true)
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        for name in note.attachments {
            let dest = assets.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: dest.path) {
                try? FileManager.default.copyItem(at: store.attachmentURL(name), to: dest)
            }
        }
    }

    static func fileName(_ raw: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t")
        let cleaned = raw.components(separatedBy: invalid).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        return cleaned.isEmpty ? "无标题" : String(cleaned.prefix(60))
    }

    private static func uniqueURL(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let ext = url.pathExtension
        let base = url.deletingPathExtension()
        var i = 2
        while true {
            var candidate = URL(fileURLWithPath: base.path + " \(i)")
            if !ext.isEmpty { candidate.appendPathExtension(ext) }
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            i += 1
        }
    }

    private static func yamlQuote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func cell(_ s: String) -> String {
        s.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: "<br>")
    }

    private static func iso(_ d: Date) -> String {
        ISO8601DateFormatter().string(from: d)
    }

    private static func showError(_ error: Error) {
        showMessage("导出失败：\(error.localizedDescription)")
    }

    private static func showMessage(_ text: String) {
        let alert = NSAlert()
        alert.messageText = text
        alert.runModal()
    }
}
