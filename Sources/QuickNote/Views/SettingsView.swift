import AppKit
import SwiftUI
import ServiceManagement

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("通用", systemImage: "gearshape") }
            HotKeySettings().tabItem { Label("快捷键", systemImage: "keyboard") }
            ClipboardSettings().tabItem { Label("剪贴板", systemImage: "doc.on.clipboard") }
            SyncSettings().tabItem { Label("同步与数据", systemImage: "icloud") }
        }
        .frame(width: 560, height: 480)
    }
}

// MARK: - 通用

private struct GeneralSettings: View {
    @EnvironmentObject var settings: AppSettings
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section {
                Toggle("登录时自动启动", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { enabled in
                        do {
                            if enabled {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                            loginError = nil
                        } catch {
                            loginError = "设置失败：\(error.localizedDescription)（需要以 .app 形式运行）"
                        }
                    }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
                Text("建议开启：App 在后台运行时才能持续记录剪贴板。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Picker("新建笔记的默认标题", selection: $settings.noteTitleStyle) {
                    ForEach(NoteTitleStyle.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.radioGroup)
                Text("新建后标题会自动选中，直接输入就能替换。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("在 Dock 中显示图标", isOn: $settings.showDockIcon)
                Text("关闭后只在菜单栏显示图标，用快捷键唤起。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - 快捷键

private struct HotKeySettings: View {
    var body: some View {
        Form {
            Section {
                ForEach(HotKeyAction.allCases) { action in
                    HotKeyRow(action: action)
                }
            } footer: {
                Text("点击快捷键按钮后按下新的组合（至少包含 ⌘ / ⌥ / ⌃ 之一），Esc 取消。与系统快捷键、其他应用或另一个快捷键冲突时会提示，且不会生效。也可以从右侧菜单里选一个推荐组合。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct HotKeyRow: View {
    @EnvironmentObject var settings: AppSettings
    let action: HotKeyAction

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent(action.title) {
                HStack(spacing: 6) {
                    HotKeyRecorder(action: action)
                    Menu {
                        Section("推荐组合") {
                            ForEach(HotKeyCombo.presets, id: \.display) { combo in
                                Button(presetLabel(combo)) { settings.setHotKey(combo, for: action) }
                            }
                        }
                        Divider()
                        Button("恢复默认（\(action.defaultCombo?.display ?? "无")）") { settings.resetHotKey(action) }
                        Button("清除快捷键") { settings.setHotKey(nil, for: action) }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
            }
            if let error = settings.hotKeyErrors[action] {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private func presetLabel(_ combo: HotKeyCombo) -> String {
        if let other = HotKeyAction.allCases.first(where: { $0 != action && settings.hotKeys[$0] == combo }) {
            return "\(combo.display)（已用于\(other.title)）"
        }
        if HotKeyManager.systemShortcutConflict(combo) {
            return "\(combo.display)（与系统冲突）"
        }
        return combo.display
    }
}

struct HotKeyRecorder: View {
    @EnvironmentObject var settings: AppSettings
    let action: HotKeyAction
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            recording ? stop() : start()
        } label: {
            Text(recording ? "请按下组合键…" : (settings.hotKeys[action]?.display ?? "未设置"))
                .frame(minWidth: 130)
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        recording = true
        // 先注销所有快捷键，否则按下已有组合时会直接触发
        HotKeyManager.shared.unregisterAll()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { // Esc
                stop()
                return nil
            }
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard !flags.intersection([.command, .option, .control]).isEmpty else {
                NSSound.beep()
                return nil
            }
            let combo = HotKeyCombo(
                keyCode: UInt32(event.keyCode),
                modifiers: HotKeyManager.carbonModifiers(from: flags),
                keyLabel: event.charactersIgnoringModifiers?.uppercased()
            )
            finish(with: combo)
            return nil
        }
    }

    private func finish(with combo: HotKeyCombo) {
        removeMonitor()
        recording = false
        settings.applyHotKeys()        // 先恢复全部
        settings.setHotKey(combo, for: action)  // 再尝试设置新的，冲突时会提示并保留原来的
    }

    private func stop() {
        removeMonitor()
        if recording {
            recording = false
            settings.applyHotKeys()
        }
    }

    private func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

// MARK: - 剪贴板

private struct ClipboardSettings: View {
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Toggle("自动记录剪贴板历史", isOn: $settings.clipboardEnabled)
                Toggle("记录图片（截图、拷贝的图片）", isOn: $settings.recordImages)
                    .disabled(!settings.clipboardEnabled)
                Toggle("识别图片中的文字，便于搜索", isOn: $settings.ocrEnabled)
                    .disabled(!settings.clipboardEnabled || !settings.recordImages)
            } footer: {
                Text("App 在后台运行时（窗口隐藏也一样）会自动记录。密码管理器标记为隐藏的内容、在本 App 内复制的内容不会被记录。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Stepper(value: $settings.clipLimit, in: 50...5000, step: 50) {
                    LabeledContent("最多保留（不含置顶）", value: "\(settings.clipLimit) 条")
                }
                Toggle("双击复制后自动隐藏窗口", isOn: $settings.hideAfterCopy)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - 同步与数据

private struct SyncSettings: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var store: Store
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                Picker("笔记存放位置", selection: Binding(
                    get: { settings.storageLocation },
                    set: { change(to: $0) }
                )) {
                    ForEach(StorageLocation.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.radioGroup)

                if !Paths.iCloudAvailable {
                    Label("未检测到 iCloud 云盘：请在 系统设置 › Apple ID › iCloud 中打开“iCloud 云盘”。", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if let error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                if !store.syncStatus.isEmpty {
                    LabeledContent("状态", value: store.syncStatus)
                }
            } footer: {
                Text("选择 iCloud 后，笔记、项目、标签和图片附件保存在 iCloud 云盘的“QuickNote”文件夹，登录同一 Apple ID 的多台 Mac 会自动同步（两边同时修改时保留较新的版本）。剪贴板历史只保存在本机。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("数据目录") {
                    Text(store.dataDirectory.path)
                        .font(.caption)
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                HStack {
                    Button("在访达中显示") {
                        NSWorkspace.shared.activateFileViewerSelecting([store.dataFile])
                    }
                    Button("导出全部笔记为 Markdown…") {
                        MarkdownExporter.exportNotes(store.notes, title: "随手记导出", store: store)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func change(to location: StorageLocation) {
        do {
            try store.moveStorage(to: location)
            settings.setStorageLocation(location)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
