import Foundation

// 所有模型都手写了 init(from:)，新增字段时旧版本的 data.json 也能正常读取。

struct Project: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var icon: String = "folder"
    var createdAt = Date()
    var updatedAt = Date()

    enum CodingKeys: String, CodingKey { case id, name, icon, createdAt, updatedAt }
}

extension Project {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = c.value(.name, default: "未命名")
        icon = c.value(.icon, default: "folder")
        createdAt = c.value(.createdAt, default: Date())
        updatedAt = c.value(.updatedAt, default: createdAt)
    }
}

/// 结构化字段，例如 “电话: 138xxxx”，适合记客户信息。
struct NoteField: Identifiable, Codable, Hashable {
    var id = UUID()
    var key: String = ""
    var value: String = ""
}

struct Note: Identifiable, Codable, Hashable {
    var id = UUID()
    var projectID: UUID?
    var title: String = ""
    var content: String = ""
    var fields: [NoteField] = []
    var tags: [String] = []
    /// 附件文件名，文件位于数据目录的 Attachments/ 下
    var attachments: [String] = []
    var pinned = false
    var createdAt = Date()
    var updatedAt = Date()

    enum CodingKeys: String, CodingKey {
        case id, projectID, title, content, fields, tags, attachments, pinned, createdAt, updatedAt
    }

    var displayTitle: String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { return t }
        let firstLine = content.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return firstLine.isEmpty ? "无标题" : firstLine
    }

    var preview: String {
        let fieldText = fields
            .filter { !$0.value.isEmpty }
            .map { $0.key.isEmpty ? $0.value : "\($0.key): \($0.value)" }
            .joined(separator: "  ")
        let body = content.replacingOccurrences(of: "\n", with: " ")
        return [fieldText, body].filter { !$0.isEmpty }.joined(separator: "  ")
    }

    var searchableText: String {
        ([title, content] + fields.flatMap { [$0.key, $0.value] } + tags.map { "#" + $0 })
            .joined(separator: "\n")
    }

    /// 复制全部时用的纯文本
    var plainText: String {
        var parts: [String] = []
        if !title.isEmpty { parts.append(title) }
        let f = fields.filter { !$0.key.isEmpty || !$0.value.isEmpty }
            .map { "\($0.key)：\($0.value)" }
        if !f.isEmpty { parts.append(f.joined(separator: "\n")) }
        if !content.isEmpty { parts.append(content) }
        if !tags.isEmpty { parts.append(tags.map { "#" + $0 }.joined(separator: " ")) }
        return parts.joined(separator: "\n\n")
    }

    static func ordering(_ a: Note, _ b: Note) -> Bool {
        if a.pinned != b.pinned { return a.pinned }
        return a.updatedAt > b.updatedAt
    }
}

extension Note {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        projectID = try c.decodeIfPresent(UUID.self, forKey: .projectID)
        title = c.value(.title, default: "")
        content = c.value(.content, default: "")
        fields = c.value(.fields, default: [])
        tags = c.value(.tags, default: [])
        attachments = c.value(.attachments, default: [])
        pinned = c.value(.pinned, default: false)
        createdAt = c.value(.createdAt, default: Date())
        updatedAt = c.value(.updatedAt, default: createdAt)
    }
}

enum ClipKind: String, Codable {
    case text, image
}

struct ClipItem: Identifiable, Codable, Hashable {
    var id = UUID()
    var kind: ClipKind = .text
    /// 文本内容；图片条目里存的是 OCR 识别出的文字（用于搜索）
    var text: String
    var imageFile: String?
    var imageHash: String?
    var imageWidth: Int?
    var imageHeight: Int?
    var sourceApp: String?
    var pinned = false
    var createdAt = Date()

    enum CodingKeys: String, CodingKey {
        case id, kind, text, imageFile, imageHash, imageWidth, imageHeight, sourceApp, pinned, createdAt
    }

    var isImage: Bool { kind == .image }
}

extension ClipItem {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        kind = c.value(.kind, default: .text)
        text = c.value(.text, default: "")
        imageFile = try c.decodeIfPresent(String.self, forKey: .imageFile)
        imageHash = try c.decodeIfPresent(String.self, forKey: .imageHash)
        imageWidth = try c.decodeIfPresent(Int.self, forKey: .imageWidth)
        imageHeight = try c.decodeIfPresent(Int.self, forKey: .imageHeight)
        sourceApp = try c.decodeIfPresent(String.self, forKey: .sourceApp)
        pinned = c.value(.pinned, default: false)
        createdAt = c.value(.createdAt, default: Date())
    }
}

/// 会被同步的数据（笔记、项目、标签、删除记录）
struct SyncData: Codable, Equatable {
    var projects: [Project]
    var notes: [Note]
    /// 删除记录（id → 删除时间），用于多台 Mac 合并时识别“已删除”
    var deleted: [String: Date]

    enum CodingKeys: String, CodingKey { case projects, notes, deleted }

    init(projects: [Project], notes: [Note], deleted: [String: Date]) {
        self.projects = projects
        self.notes = notes
        self.deleted = deleted
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        projects = c.value(.projects, default: [])
        notes = c.value(.notes, default: [])
        deleted = c.value(.deleted, default: [:])
    }
}

/// 只保存在本机的剪贴板历史
struct ClipData: Codable {
    var clips: [ClipItem]
}

enum SidebarItem: Hashable {
    case all, inbox, clipboard
    case project(UUID)
    case tag(String)
}

enum Detail: Hashable {
    case note(UUID)
    case clip(UUID)
}

enum FieldTemplate: String, CaseIterable {
    case customer = "客户信息"
    case contact = "联系人"
    case account = "账号信息"

    var keys: [String] {
        switch self {
        case .customer: return ["公司", "联系人", "电话", "邮箱", "地址", "需求"]
        case .contact: return ["姓名", "电话", "微信", "邮箱"]
        case .account: return ["网址", "账号", "备注"]
        }
    }
}

extension KeyedDecodingContainer {
    func value<T: Decodable>(_ key: Key, default fallback: @autoclosure () -> T) -> T {
        if let v = try? decodeIfPresent(T.self, forKey: key) { return v }
        return fallback()
    }
}
