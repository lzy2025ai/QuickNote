import Foundation
import Carbon

/// 新建笔记时自动生成的标题
enum NoteTitleStyle: String, CaseIterable, Identifiable {
    case dateTime, projectDate, empty
    var id: String { rawValue }
    var title: String {
        switch self {
        case .dateTime: return "日期时间（如“10月15日 19:40”）"
        case .projectDate: return "项目名 + 日期时间（如“乐享户外 · 10月15日 19:40”）"
        case .empty: return "留空（列表里显示正文第一行）"
        }
    }
}

final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let defaults = UserDefaults.standard

    @Published private(set) var hotKeys: [HotKeyAction: HotKeyCombo] = [:]
    @Published var hotKeyErrors: [HotKeyAction: String] = [:]

    @Published var clipboardEnabled: Bool { didSet { defaults.set(clipboardEnabled, forKey: "clipboardEnabled") } }
    @Published var recordImages: Bool { didSet { defaults.set(recordImages, forKey: "recordImages") } }
    @Published var ocrEnabled: Bool { didSet { defaults.set(ocrEnabled, forKey: "ocrEnabled") } }
    @Published var clipLimit: Int { didSet { defaults.set(clipLimit, forKey: "clipLimit") } }
    @Published var hideAfterCopy: Bool { didSet { defaults.set(hideAfterCopy, forKey: "hideAfterCopy") } }
    @Published var showDockIcon: Bool {
        didSet {
            defaults.set(showDockIcon, forKey: "showDockIcon")
            NotificationCenter.default.post(name: .qnDockIconChanged, object: nil)
        }
    }
    @Published private(set) var storageLocation: StorageLocation
    @Published var noteTitleStyle: NoteTitleStyle {
        didSet { defaults.set(noteTitleStyle.rawValue, forKey: "noteTitleStyle") }
    }

    private init() {
        defaults.register(defaults: [
            "clipboardEnabled": true,
            "recordImages": true,
            "ocrEnabled": true,
            "clipLimit": 300,
            "hideAfterCopy": true,
            "showDockIcon": true,
            "storageLocation": StorageLocation.local.rawValue,
            "noteTitleStyle": NoteTitleStyle.dateTime.rawValue,
        ])
        clipboardEnabled = defaults.bool(forKey: "clipboardEnabled")
        recordImages = defaults.bool(forKey: "recordImages")
        ocrEnabled = defaults.bool(forKey: "ocrEnabled")
        clipLimit = defaults.integer(forKey: "clipLimit")
        hideAfterCopy = defaults.bool(forKey: "hideAfterCopy")
        showDockIcon = defaults.bool(forKey: "showDockIcon")
        storageLocation = StorageLocation(rawValue: defaults.string(forKey: "storageLocation") ?? "") ?? .local
        noteTitleStyle = NoteTitleStyle(rawValue: defaults.string(forKey: "noteTitleStyle") ?? "") ?? .dateTime

        for action in HotKeyAction.allCases {
            if let data = defaults.data(forKey: action.defaultsKey),
               let combo = try? JSONDecoder().decode(HotKeyCombo.self, from: data) {
                hotKeys[action] = combo
            } else if defaults.string(forKey: action.defaultsKey) == "none" {
                continue // 用户主动清除了
            } else {
                hotKeys[action] = action.defaultCombo
            }
        }
    }

    func defaultNoteTitle(projectName: String?, date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "M月d日 HH:mm"
        let stamp = formatter.string(from: date)
        switch noteTitleStyle {
        case .dateTime: return stamp
        case .projectDate: return projectName.map { "\($0) · \(stamp)" } ?? stamp
        case .empty: return ""
        }
    }

    func setStorageLocation(_ location: StorageLocation) {
        storageLocation = location
        defaults.set(location.rawValue, forKey: "storageLocation")
    }

    // MARK: - Hot keys

    /// 启动时注册全部快捷键
    func applyHotKeys() {
        for action in HotKeyAction.allCases {
            guard let combo = hotKeys[action] else {
                HotKeyManager.shared.unregister(id: action.rawValue)
                continue
            }
            if HotKeyManager.shared.register(combo, id: action.rawValue) != noErr {
                hotKeyErrors[action] = "\(combo.display) 注册失败，可能已被其他应用占用，请换一个。"
            } else if HotKeyManager.systemShortcutConflict(combo) {
                hotKeyErrors[action] = "\(combo.display) 与系统快捷键冲突，可能无法触发，建议换一个。"
            } else {
                hotKeyErrors[action] = nil
            }
        }
    }

    /// 修改快捷键；有冲突时不生效并返回原因（同时写入 hotKeyErrors）。传 nil 表示清除。
    @discardableResult
    func setHotKey(_ combo: HotKeyCombo?, for action: HotKeyAction) -> String? {
        guard let combo else {
            HotKeyManager.shared.unregister(id: action.rawValue)
            hotKeys[action] = nil
            defaults.set("none", forKey: action.defaultsKey)
            hotKeyErrors[action] = nil
            return nil
        }

        if let other = HotKeyAction.allCases.first(where: { $0 != action && hotKeys[$0] == combo }) {
            return fail(action, "\(combo.display) 已经用于“\(other.title)”")
        }
        if HotKeyManager.systemShortcutConflict(combo) {
            return fail(action, "\(combo.display) 已被系统快捷键占用（如 Spotlight、输入法切换、截图）。请换一个，或先在 系统设置 › 键盘 › 键盘快捷键 中关闭它。")
        }
        if HotKeyManager.shared.register(combo, id: action.rawValue) != noErr {
            return fail(action, "\(combo.display) 已被其他应用占用，请换一个。")
        }

        hotKeys[action] = combo
        if let data = try? JSONEncoder().encode(combo) {
            defaults.set(data, forKey: action.defaultsKey)
        }
        hotKeyErrors[action] = nil
        return nil
    }

    func resetHotKey(_ action: HotKeyAction) {
        setHotKey(action.defaultCombo, for: action)
    }

    private func fail(_ action: HotKeyAction, _ message: String) -> String {
        // 恢复原来的快捷键
        if let old = hotKeys[action] {
            _ = HotKeyManager.shared.register(old, id: action.rawValue)
        }
        hotKeyErrors[action] = message
        return message
    }
}
