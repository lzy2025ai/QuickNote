import AppKit
import Carbon

enum HotKeyAction: UInt32, CaseIterable, Identifiable {
    case quickCapture = 3
    case toggleWindow = 1
    case showClipboard = 2

    var id: UInt32 { rawValue }

    var title: String {
        switch self {
        case .quickCapture: return "随手记一笔（快速记录）"
        case .toggleWindow: return "打开 / 隐藏主窗口"
        case .showClipboard: return "打开剪贴板历史"
        }
    }

    var defaultsKey: String { "hotkey.\(rawValue)" }

    var defaultCombo: HotKeyCombo? {
        switch self {
        case .quickCapture: return HotKeyCombo(keyCode: 49, modifiers: UInt32(optionKey))                // ⌥Space
        case .toggleWindow: return HotKeyCombo(keyCode: 49, modifiers: UInt32(controlKey | optionKey))   // ⌃⌥Space
        case .showClipboard: return HotKeyCombo(keyCode: 9, modifiers: UInt32(controlKey | optionKey))   // ⌃⌥V
        }
    }
}

struct HotKeyCombo: Codable, Equatable {
    var keyCode: UInt32
    /// Carbon 修饰键（cmdKey / optionKey / controlKey / shiftKey）
    var modifiers: UInt32
    /// 不在内置表中的按键，录制时记下的字符
    var keyLabel: String?

    var display: String {
        HotKeyManager.modifierSymbols(modifiers) + (HotKeyManager.keyNames[UInt16(keyCode)] ?? keyLabel ?? "?")
    }

    static func == (a: HotKeyCombo, b: HotKeyCombo) -> Bool {
        a.keyCode == b.keyCode && a.modifiers == b.modifiers
    }

    /// 设置页里提供的推荐组合
    static let presets: [HotKeyCombo] = [
        HotKeyCombo(keyCode: 49, modifiers: UInt32(optionKey)),                        // ⌥Space
        HotKeyCombo(keyCode: 49, modifiers: UInt32(controlKey | optionKey)),           // ⌃⌥Space
        HotKeyCombo(keyCode: 45, modifiers: UInt32(controlKey | optionKey)),           // ⌃⌥N
        HotKeyCombo(keyCode: 38, modifiers: UInt32(optionKey | cmdKey)),               // ⌥⌘J
        HotKeyCombo(keyCode: 40, modifiers: UInt32(controlKey | optionKey)),           // ⌃⌥K
        HotKeyCombo(keyCode: 9, modifiers: UInt32(controlKey | optionKey)),            // ⌃⌥V
        HotKeyCombo(keyCode: 9, modifiers: UInt32(shiftKey | optionKey | cmdKey)),     // ⇧⌥⌘V
        HotKeyCombo(keyCode: 8, modifiers: UInt32(controlKey | optionKey)),            // ⌃⌥C
    ]
}

/// 基于 Carbon RegisterEventHotKey 的全局快捷键，不需要“辅助功能”权限。
final class HotKeyManager {
    static let shared = HotKeyManager()

    var handlers: [UInt32: @MainActor () -> Void] = [:]

    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var handlerRef: EventHandlerRef?

    func register(_ combo: HotKeyCombo, id: UInt32) -> OSStatus {
        unregister(id: id)
        installHandlerIfNeeded()
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x514E_5445), id: id) // "QNTE"
        let status = RegisterEventHotKey(combo.keyCode, combo.modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref { refs[id] = ref }
        return status
    }

    func unregister(id: UInt32) {
        if let ref = refs.removeValue(forKey: id) {
            UnregisterEventHotKey(ref)
        }
    }

    func unregisterAll() {
        for id in Array(refs.keys) { unregister(id: id) }
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
            )
            guard status == noErr else { return status }
            let id = hotKeyID.id
            Task { @MainActor in HotKeyManager.shared.handlers[id]?() }
            return noErr
        }, 1, &spec, nil, &handlerRef)
    }

    // MARK: - 冲突检测

    /// 是否与系统快捷键（Spotlight、输入法切换、截图、调度中心等，且处于启用状态）冲突
    static func systemShortcutConflict(_ combo: HotKeyCombo) -> Bool {
        var unmanaged: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&unmanaged) == noErr,
              let cfArray = unmanaged?.takeRetainedValue(),
              let array = (cfArray as NSArray) as? [[String: Any]] else { return false }
        let carbonMask = UInt32(cmdKey | shiftKey | optionKey | controlKey)
        let cocoaMask = NSEvent.ModifierFlags([.command, .shift, .option, .control]).rawValue
        let cocoa = cocoaFlags(combo.modifiers).rawValue
        for item in array {
            guard (item[kHISymbolicHotKeyEnabled as String] as? Bool) == true,
                  let code = (item[kHISymbolicHotKeyCode as String] as? NSNumber)?.uint32Value,
                  let mods = (item[kHISymbolicHotKeyModifiers as String] as? NSNumber)?.uintValue,
                  code == combo.keyCode else { continue }
            if UInt32(truncatingIfNeeded: mods) & carbonMask == combo.modifiers || mods & cocoaMask == cocoa {
                return true
            }
        }
        return false
    }

    // MARK: - 转换与显示

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        if flags.contains(.option) { m |= UInt32(optionKey) }
        if flags.contains(.control) { m |= UInt32(controlKey) }
        if flags.contains(.shift) { m |= UInt32(shiftKey) }
        return m
    }

    static func cocoaFlags(_ carbon: UInt32) -> NSEvent.ModifierFlags {
        var f: NSEvent.ModifierFlags = []
        if carbon & UInt32(cmdKey) != 0 { f.insert(.command) }
        if carbon & UInt32(optionKey) != 0 { f.insert(.option) }
        if carbon & UInt32(controlKey) != 0 { f.insert(.control) }
        if carbon & UInt32(shiftKey) != 0 { f.insert(.shift) }
        return f
    }

    static func modifierSymbols(_ carbon: UInt32) -> String {
        var s = ""
        if carbon & UInt32(controlKey) != 0 { s += "⌃" }
        if carbon & UInt32(optionKey) != 0 { s += "⌥" }
        if carbon & UInt32(shiftKey) != 0 { s += "⇧" }
        if carbon & UInt32(cmdKey) != 0 { s += "⌘" }
        return s
    }

    /// 美式键盘布局下的按键名称
    static let keyNames: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7",
        27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P",
        37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N",
        46: "M", 47: ".", 50: "`",
        49: "Space", 36: "↩", 48: "⇥", 51: "⌫", 53: "Esc", 117: "⌦",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]
}
