import AppKit
import Combine
import SwiftUI

enum StorageLocation: String, CaseIterable, Identifiable {
    case local, icloud
    var id: String { rawValue }
    var title: String {
        switch self {
        case .local: return "仅本机"
        case .icloud: return "iCloud 云盘（多台 Mac 同步）"
        }
    }
}

enum Paths {
    static let appSupport: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("QuickNote", isDirectory: true)

    static var iCloudDrive: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
    }

    static var iCloudAvailable: Bool {
        FileManager.default.fileExists(atPath: iCloudDrive.path)
    }

    static func dataDirectory(for location: StorageLocation) -> URL {
        switch location {
        case .local: return appSupport
        case .icloud: return iCloudDrive.appendingPathComponent("QuickNote", isDirectory: true)
        }
    }

    static var clipImages: URL { appSupport.appendingPathComponent("ClipImages", isDirectory: true) }
    static var clipsFile: URL { appSupport.appendingPathComponent("clips.json") }
}

enum StoreError: LocalizedError {
    case iCloudUnavailable
    var errorDescription: String? {
        "没有找到 iCloud 云盘。请在 系统设置 › Apple ID › iCloud 中打开“iCloud 云盘”。"
    }
}

/// 笔记 / 项目 / 标签 / 附件 → 数据目录（本机或 iCloud 云盘）的 data.json + Attachments/
/// 剪贴板历史 → 始终在本机 ~/Library/Application Support/QuickNote/clips.json + ClipImages/
final class Store: ObservableObject {
    @Published var projects: [Project] = []
    @Published var notes: [Note] = []
    @Published var clips: [ClipItem] = []
    @Published private(set) var dataDirectory: URL
    @Published private(set) var syncStatus = ""

    private var deleted: [String: Date] = [:]
    /// 最近一次读到 / 写入的文件内容和修改时间，用来判断文件是否被其他 Mac 改过
    private var lastFileData: Data?
    private var lastModDate: Date?
    private var cancellables = Set<AnyCancellable>()
    private var syncTimer: Timer?
    /// 编码和写文件放在后台串行队列，避免卡住输入
    private let ioQueue = DispatchQueue(label: "QuickNote.io", qos: .utility)

    var dataFile: URL { dataDirectory.appendingPathComponent("data.json") }
    var attachmentsDirectory: URL { dataDirectory.appendingPathComponent("Attachments", isDirectory: true) }
    var isICloud: Bool { dataDirectory.path.hasPrefix(Paths.iCloudDrive.path) }

    init(location: StorageLocation) {
        var dir = Paths.dataDirectory(for: location)
        if location == .icloud && !Paths.iCloudAvailable { dir = Paths.appSupport }
        dataDirectory = dir

        let fm = FileManager.default
        for d in [Paths.appSupport, Paths.clipImages, dir, dir.appendingPathComponent("Attachments", isDirectory: true)] {
            try? fm.createDirectory(at: d, withIntermediateDirectories: true)
        }

        loadData()
        loadClips()

        Publishers.CombineLatest($projects, $notes)
            .dropFirst()
            .debounce(for: .milliseconds(600), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.saveData() }
            .store(in: &cancellables)

        $clips
            .dropFirst()
            .debounce(for: .seconds(1), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.saveClips() }
            .store(in: &cancellables)

        // 每 3 秒检查一次数据文件是否被其他 Mac（经 iCloud）修改
        let t = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            self?.checkExternalChanges(thenSave: true)
        }
        RunLoop.main.add(t, forMode: .common)
        syncTimer = t
    }

    // MARK: - Notes data persistence & sync

    private var snapshot: SyncData {
        SyncData(projects: projects, notes: Store.sortedForStorage(notes), deleted: deleted)
    }

    private static func sortedForStorage(_ notes: [Note]) -> [Note] {
        notes.sorted { a, b in
            a.createdAt != b.createdAt ? a.createdAt > b.createdAt : a.id.uuidString < b.id.uuidString
        }
    }

    private func loadData() {
        guard let data = readDataFile() else { return }
        if let d = decode(data) {
            projects = d.projects
            notes = d.notes
            deleted = d.deleted
            lastFileData = data
            lastModDate = Store.modificationDate(dataFile)
        } else {
            // 解析失败时备份原文件，避免覆盖掉用户数据
            let backup = dataDirectory.appendingPathComponent("data-corrupted-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.copyItem(at: dataFile, to: backup)
        }
    }

    func saveData() {
        saveData(checkRemote: true)
    }

    /// 退出前同步写入
    func saveNow() {
        guard !isAwaitingDownload, let data = Store.encode(snapshot), data != lastFileData else { return }
        try? Store.coordinatedWrite(data, to: dataFile)
        lastFileData = data
        let clipData = Store.encode(ClipData(clips: clips))
        try? clipData?.write(to: Paths.clipsFile, options: .atomic)
    }

    private func saveData(checkRemote: Bool) {
        // iCloud 上的文件还没下载到本机时不能写，否则会覆盖云端数据
        guard !isAwaitingDownload else { return }
        if checkRemote { checkExternalChanges(thenSave: false) }
        let snap = snapshot
        let url = dataFile
        let iCloud = isICloud
        ioQueue.async { [weak self] in
            guard let data = Store.encode(snap) else { return }
            DispatchQueue.main.async {
                guard let self, data != self.lastFileData, url == self.dataFile else { return }
                self.lastFileData = data
                self.ioQueue.async {
                    do {
                        try Store.coordinatedWrite(data, to: url)
                        let mod = Store.modificationDate(url)
                        DispatchQueue.main.async {
                            self.lastModDate = mod
                            if iCloud { self.syncStatus = "已同步 · " + Date().formatted(date: .omitted, time: .shortened) }
                        }
                    } catch {
                        DispatchQueue.main.async {
                            self.lastFileData = nil
                            self.syncStatus = "保存失败：\(error.localizedDescription)"
                        }
                    }
                }
            }
        }
    }

    private func checkExternalChanges(thenSave: Bool) {
        guard FileManager.default.fileExists(atPath: dataFile.path) else {
            requestDownloadIfNeeded()
            return
        }
        let mod = Store.modificationDate(dataFile)
        guard mod != lastModDate else { return }
        lastModDate = mod
        guard let data = Store.coordinatedRead(dataFile), data != lastFileData, let remote = decode(data) else { return }
        lastFileData = data
        apply(Store.merge(local: snapshot, remote: remote))
        if isICloud { syncStatus = "已同步 · " + Date().formatted(date: .omitted, time: .shortened) }
        if thenSave { saveData(checkRemote: false) }
    }

    private func apply(_ merged: SyncData) {
        if projects != merged.projects { projects = merged.projects }
        if Set(notes) != Set(merged.notes) { notes = merged.notes }
        deleted = merged.deleted
    }

    /// 两份数据合并：同一条笔记取修改时间较新的；删除记录晚于修改时间的视为已删除。
    static func merge(local: SyncData, remote: SyncData) -> SyncData {
        let cutoff = Date().addingTimeInterval(-90 * 24 * 3600)
        let deleted = local.deleted
            .merging(remote.deleted) { max($0, $1) }
            .filter { $0.value > cutoff }

        func alive(_ id: UUID, _ updated: Date) -> Bool {
            guard let d = deleted[id.uuidString] else { return true }
            return updated > d
        }

        var notesByID: [UUID: Note] = [:]
        for n in remote.notes + local.notes {
            if let existing = notesByID[n.id], existing.updatedAt >= n.updatedAt { continue }
            notesByID[n.id] = n
        }
        let notes = notesByID.values.filter { alive($0.id, $0.updatedAt) }

        var projectsByID: [UUID: Project] = [:]
        for p in remote.projects + local.projects {
            if let existing = projectsByID[p.id], existing.updatedAt >= p.updatedAt { continue }
            projectsByID[p.id] = p
        }
        var order: [UUID] = remote.projects.map(\.id)
        for p in local.projects where !order.contains(p.id) { order.append(p.id) }
        let projects = order.compactMap { projectsByID[$0] }.filter { alive($0.id, $0.updatedAt) }

        return SyncData(projects: projects, notes: sortedForStorage(notes), deleted: deleted)
    }

    /// 切换存储位置（本机 ↔ iCloud）。旧位置的文件保留作为备份。
    func moveStorage(to location: StorageLocation) throws {
        if location == .icloud && !Paths.iCloudAvailable { throw StoreError.iCloudUnavailable }
        let newDir = Paths.dataDirectory(for: location)
        guard newDir.standardizedFileURL != dataDirectory.standardizedFileURL else { return }

        let fm = FileManager.default
        let newAttachments = newDir.appendingPathComponent("Attachments", isDirectory: true)
        try fm.createDirectory(at: newAttachments, withIntermediateDirectories: true)
        let files = (try? fm.contentsOfDirectory(at: attachmentsDirectory, includingPropertiesForKeys: nil)) ?? []
        for file in files {
            let dest = newAttachments.appendingPathComponent(file.lastPathComponent)
            if !fm.fileExists(atPath: dest.path) { try? fm.copyItem(at: file, to: dest) }
        }

        let local = snapshot
        dataDirectory = newDir
        lastFileData = nil
        lastModDate = nil
        var merged = local
        // 新位置已有数据（比如另一台 Mac 已经开启同步）时合并，而不是覆盖
        if let data = readDataFile(), let remote = decode(data) {
            merged = Store.merge(local: local, remote: remote)
            lastFileData = data
            lastModDate = Store.modificationDate(dataFile)
        }
        apply(merged)
        saveData(checkRemote: false)
    }

    // MARK: File helpers

    private var downloadPlaceholder: URL { dataDirectory.appendingPathComponent(".data.json.icloud") }

    private var isAwaitingDownload: Bool {
        isICloud
            && !FileManager.default.fileExists(atPath: dataFile.path)
            && FileManager.default.fileExists(atPath: downloadPlaceholder.path)
    }

    private func requestDownloadIfNeeded() {
        guard isAwaitingDownload else { return }
        try? FileManager.default.startDownloadingUbiquitousItem(at: dataFile)
        syncStatus = "正在从 iCloud 下载…"
    }

    private func readDataFile() -> Data? {
        guard FileManager.default.fileExists(atPath: dataFile.path) else {
            requestDownloadIfNeeded()
            return nil
        }
        return Store.coordinatedRead(dataFile)
    }

    private static func modificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    private static func coordinatedRead(_ url: URL) -> Data? {
        var result: Data?
        var error: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &error) { u in
            result = try? Data(contentsOf: u)
        }
        return result
    }

    private static func coordinatedWrite(_ data: Data, to url: URL) throws {
        var coordError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordError) { u in
            do { try data.write(to: u, options: .atomic) } catch { writeError = error }
        }
        if let e = coordError ?? writeError { throw e }
    }

    private static func encode<T: Encodable>(_ value: T) -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(value)
    }

    private func decode(_ data: Data) -> SyncData? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SyncData.self, from: data)
    }

    // MARK: - Clips persistence (local only)

    private func loadClips() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: Paths.clipsFile),
           let d = try? decoder.decode(ClipData.self, from: data) {
            clips = d.clips
            return
        }
        // 旧版本把剪贴板存在 data.json 里，迁移出来
        let legacy = Paths.appSupport.appendingPathComponent("data.json")
        if let data = try? Data(contentsOf: legacy),
           let d = try? decoder.decode(ClipData.self, from: data), !d.clips.isEmpty {
            clips = d.clips
            saveClips()
        }
    }

    func saveClips() {
        let snapshot = ClipData(clips: clips)
        ioQueue.async {
            guard let data = Store.encode(snapshot) else { return }
            try? data.write(to: Paths.clipsFile, options: .atomic)
        }
    }

    // MARK: - Projects

    @discardableResult
    func addProject(name: String, icon: String, color: String? = nil) -> Project {
        let p = Project(name: name, icon: icon, color: color)
        projects.append(p)
        return p
    }

    func updateProject(_ project: Project) {
        guard let i = projects.firstIndex(where: { $0.id == project.id }) else { return }
        var p = project
        p.updatedAt = Date()
        projects[i] = p
    }

    func moveProjects(from source: IndexSet, to destination: Int) {
        projects.move(fromOffsets: source, toOffset: destination)
    }

    /// 删除项目，其中的笔记移回收件箱
    func deleteProject(_ id: UUID) {
        deleted[id.uuidString] = Date()
        projects.removeAll { $0.id == id }
        let now = Date()
        for i in notes.indices where notes[i].projectID == id {
            notes[i].projectID = nil
            notes[i].updatedAt = now
        }
    }

    func project(_ id: UUID?) -> Project? {
        guard let id else { return nil }
        return projects.first { $0.id == id }
    }

    func noteCount(_ scope: SidebarItem) -> Int {
        switch scope {
        case .all: return notes.count
        case .inbox: return notes.lazy.filter { $0.projectID == nil }.count
        case .clipboard: return clips.count
        case .project(let id): return notes.lazy.filter { $0.projectID == id }.count
        case .tag(let tag): return notes.lazy.filter { $0.hasTag(tag) }.count
        }
    }

    // MARK: - Notes

    func notes(for scope: SidebarItem) -> [Note] {
        let list: [Note]
        switch scope {
        case .all: list = notes
        case .inbox: list = notes.filter { $0.projectID == nil }
        case .project(let id): list = notes.filter { $0.projectID == id }
        case .tag(let tag): list = notes.filter { $0.hasTag(tag) }
        case .clipboard: list = []
        }
        return list.sorted(by: Note.ordering)
    }

    @discardableResult
    func addNote(projectID: UUID?, title: String = "", content: String = "", tags: [String] = [], attachments: [String] = []) -> Note {
        let n = Note(projectID: projectID, title: title, content: content, tags: tags, attachments: attachments)
        notes.insert(n, at: 0)
        return n
    }

    func deleteNote(_ id: UUID) {
        guard let note = notes.first(where: { $0.id == id }) else { return }
        deleted[id.uuidString] = Date()
        notes.removeAll { $0.id == id }
        // 正文里的图片只在没有别的笔记引用时才删除
        let stillUsed = Set(notes.flatMap { $0.attachments + $0.inlineImages })
        for name in note.attachments + note.inlineImages where !stillUsed.contains(name) {
            try? FileManager.default.removeItem(at: attachmentURL(name))
        }
    }

    func mutateNote(_ id: UUID, _ change: (inout Note) -> Void) {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return }
        change(&notes[i])
        notes[i].updatedAt = Date()
    }

    /// 编辑器提交整条笔记；内容没变时不触发更新
    func updateNote(_ note: Note) {
        guard let i = notes.firstIndex(where: { $0.id == note.id }) else { return }
        var n = note
        n.updatedAt = notes[i].updatedAt
        guard notes[i] != n else { return }
        n.updatedAt = Date()
        notes[i] = n
    }

    // MARK: - Attachments

    func attachmentURL(_ name: String) -> URL {
        attachmentsDirectory.appendingPathComponent(name)
    }

    /// 把图片复制进附件目录，返回文件名
    func importAttachment(fileURL: URL) -> String? {
        let ext = fileURL.pathExtension.isEmpty ? "png" : fileURL.pathExtension.lowercased()
        let name = UUID().uuidString + "." + ext
        do {
            try FileManager.default.createDirectory(at: attachmentsDirectory, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: fileURL, to: attachmentURL(name))
            return name
        } catch {
            NSLog("QuickNote: import attachment failed: \(error)")
            return nil
        }
    }

    func importAttachment(pngData: Data) -> String? {
        let name = UUID().uuidString + ".png"
        do {
            try FileManager.default.createDirectory(at: attachmentsDirectory, withIntermediateDirectories: true)
            try pngData.write(to: attachmentURL(name))
            return name
        } catch {
            NSLog("QuickNote: import attachment failed: \(error)")
            return nil
        }
    }

    func deleteAttachmentFile(_ name: String) {
        try? FileManager.default.removeItem(at: attachmentURL(name))
    }

    // MARK: - Tags

    var allTags: [(name: String, count: Int)] {
        var counts: [String: Int] = [:]
        for n in notes {
            for t in n.allTags { counts[t, default: 0] += 1 }
        }
        return counts
            .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
            .map { (name: $0.key, count: $0.value) }
    }

    static func normalizeTag(_ raw: String) -> String {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while t.hasPrefix("#") || t.hasPrefix("＃") { t.removeFirst() }
        return t.trimmingCharacters(in: .whitespaces)
    }

    func renameTag(_ old: String, to newName: String) {
        let new = Store.normalizeTag(newName)
        guard !new.isEmpty, new != old else { return }
        let now = Date()
        for i in notes.indices where notes[i].hasTag(old) {
            var result: [String] = []
            for t in notes[i].tags.map({ $0 == old ? new : $0 }) where !result.contains(t) { result.append(t) }
            notes[i].tags = result
            notes[i].content = Note.replacingInlineTag(old, with: new, in: notes[i].content)
            notes[i].updatedAt = now
        }
    }

    func deleteTag(_ tag: String) {
        let now = Date()
        for i in notes.indices where notes[i].hasTag(tag) {
            notes[i].tags.removeAll { $0 == tag }
            notes[i].content = Note.replacingInlineTag(tag, with: nil, in: notes[i].content)
            notes[i].updatedAt = now
        }
    }

    // MARK: - Clipboard

    var sortedClips: [ClipItem] {
        clips.sorted { a, b in
            if a.pinned != b.pinned { return a.pinned }
            return a.createdAt > b.createdAt
        }
    }

    func clipImageURL(_ clip: ClipItem) -> URL? {
        clip.imageFile.map { Paths.clipImages.appendingPathComponent($0) }
    }

    func addTextClip(_ text: String, source: String?, limit: Int) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if let i = clips.firstIndex(where: { !$0.isImage && $0.text == text }) {
            // 重复内容：挪到最前面，不重复记录
            var item = clips.remove(at: i)
            item.createdAt = Date()
            item.sourceApp = source ?? item.sourceApp
            clips.insert(item, at: 0)
        } else {
            clips.insert(ClipItem(text: text, sourceApp: source), at: 0)
        }
        trimClips(limit: limit)
    }

    func addImageClip(png: Data, hash: String, width: Int, height: Int, source: String?, limit: Int, ocr: Bool) {
        if let i = clips.firstIndex(where: { $0.imageHash == hash }) {
            var item = clips.remove(at: i)
            item.createdAt = Date()
            clips.insert(item, at: 0)
            return
        }
        let id = UUID()
        let name = id.uuidString + ".png"
        let url = Paths.clipImages.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: Paths.clipImages, withIntermediateDirectories: true)
            try png.write(to: url)
        } catch {
            return
        }
        clips.insert(ClipItem(id: id, kind: .image, text: "", imageFile: name, imageHash: hash,
                              imageWidth: width, imageHeight: height, sourceApp: source), at: 0)
        trimClips(limit: limit)

        if ocr {
            TextRecognizer.recognize(url) { [weak self] text in
                guard let self, let i = self.clips.firstIndex(where: { $0.id == id }) else { return }
                self.clips[i].text = text
            }
        }
    }

    private func trimClips(limit: Int) {
        var unpinned = 0
        var removed: [ClipItem] = []
        clips = clips.filter { c in
            if c.pinned { return true }
            unpinned += 1
            if unpinned <= max(limit, 10) { return true }
            removed.append(c)
            return false
        }
        removed.forEach(removeClipFile)
    }

    private func removeClipFile(_ clip: ClipItem) {
        if let url = clipImageURL(clip) { try? FileManager.default.removeItem(at: url) }
    }

    func toggleClipPin(_ id: UUID) {
        guard let i = clips.firstIndex(where: { $0.id == id }) else { return }
        clips[i].pinned.toggle()
    }

    func deleteClip(_ id: UUID) {
        guard let clip = clips.first(where: { $0.id == id }) else { return }
        clips.removeAll { $0.id == id }
        removeClipFile(clip)
    }

    func clearClips(keepPinned: Bool = true) {
        let removed = clips.filter { !keepPinned || !$0.pinned }
        clips = keepPinned ? clips.filter(\.pinned) : []
        removed.forEach(removeClipFile)
    }

    func copyClip(_ clip: ClipItem) {
        if clip.isImage, let url = clipImageURL(clip) {
            Pasteboard.copyImage(at: url)
        } else {
            Pasteboard.copy(clip.text)
        }
    }

    @discardableResult
    func saveClipAsNote(_ clip: ClipItem, projectID: UUID?) -> Note {
        if clip.isImage, let url = clipImageURL(clip) {
            let name = UUID().uuidString + ".png"
            try? FileManager.default.createDirectory(at: attachmentsDirectory, withIntermediateDirectories: true)
            try? FileManager.default.copyItem(at: url, to: attachmentURL(name))
            let title = "图片 " + clip.createdAt.formatted(date: .abbreviated, time: .shortened)
            return addNote(projectID: projectID, title: title, content: clip.text, attachments: [name])
        }
        let firstLine = clip.text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return addNote(projectID: projectID, title: String(firstLine.prefix(40)), content: clip.text)
    }

    // MARK: - Search

    /// 支持多个关键词（空格分隔）；以 # 开头的词只匹配标签
    func searchNotes(_ query: String) -> [Note] {
        let terms = SearchText.terms(query)
        guard !terms.isEmpty else { return [] }
        return notes.filter { n in
            let hay = n.searchableText + "\n" + (project(n.projectID)?.name ?? "")
            return terms.allSatisfy { term in
                if term.count > 1, term.hasPrefix("#") || term.hasPrefix("＃") {
                    let t = String(term.dropFirst())
                    return n.allTags.contains { $0.localizedCaseInsensitiveContains(t) }
                }
                return hay.localizedCaseInsensitiveContains(term)
            }
        }.sorted(by: Note.ordering)
    }

    func searchClips(_ query: String) -> [ClipItem] {
        let terms = SearchText.terms(query).filter { !$0.hasPrefix("#") }
        guard !terms.isEmpty else { return [] }
        return sortedClips.filter { c in
            let hay = c.text + "\n" + (c.sourceApp ?? "")
            return terms.allSatisfy { hay.localizedCaseInsensitiveContains($0) }
        }
    }
}

enum SearchText {
    static func terms(_ query: String) -> [String] {
        query.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// 截取命中词附近的一段文字作为预览
    static func snippet(_ text: String, terms: [String], radius: Int = 30) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        guard let r = terms.lazy.compactMap({ flat.range(of: $0, options: .caseInsensitive) }).first else {
            return String(flat.prefix(radius * 3))
        }
        let start = flat.index(r.lowerBound, offsetBy: -radius, limitedBy: flat.startIndex) ?? flat.startIndex
        let end = flat.index(r.upperBound, offsetBy: radius * 2, limitedBy: flat.endIndex) ?? flat.endIndex
        return (start > flat.startIndex ? "…" : "") + flat[start..<end] + (end < flat.endIndex ? "…" : "")
    }

    static func highlight(_ text: String, terms: [String]) -> AttributedString {
        var a = AttributedString(text)
        for raw in terms {
            let term = raw.hasPrefix("#") && raw.count > 1 ? String(raw.dropFirst()) : raw
            guard !term.isEmpty else { continue }
            var lower = a.startIndex
            while lower < a.endIndex, let r = a[lower...].range(of: term, options: .caseInsensitive) {
                a[r][AttributeScopes.SwiftUIAttributes.BackgroundColorAttribute.self] = Color.yellow.opacity(0.45)
                lower = r.upperBound
            }
        }
        return a
    }
}
