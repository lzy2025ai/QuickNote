import AppKit
import SwiftUI

/// 随手记一笔：快捷键呼出的浮动便笺。回车存下，⌘回车存下并打开，Tab 换项目，Esc 收起。
final class QuickCaptureController: NSObject, NSWindowDelegate {
    private let store: Store
    private let model = CaptureModel()
    private var panel: CapturePanel?
    private var monitor: Any?
    /// 呼出前本 App 不在前台：收起时把焦点还给之前的应用
    private var restoreFocusOnClose = false
    private var closing = false

    var isMainWindowVisible: () -> Bool = { false }
    var onOpenNote: (UUID) -> Void = { _ in }

    private static let lastProjectKey = "capture.lastProject"
    private static let size = NSSize(width: 600, height: 336)

    init(store: Store) {
        self.store = store
        super.init()
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    func toggle() {
        isVisible ? close() : show()
    }

    func show() {
        closing = false
        restoreFocusOnClose = !(NSApp.isActive && isMainWindowVisible())
        prepareModel()
        let panel = self.panel ?? makePanel()
        self.panel = panel

        // 出现在鼠标所在屏幕的中上部
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            let origin = NSPoint(x: visible.midX - Self.size.width / 2, y: visible.maxY - visible.height * 0.28 - Self.size.height)
            panel.setFrame(NSRect(origin: origin, size: Self.size), display: false)
        }

        NSApp.activate(ignoringOtherApps: true)
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        panel.invalidateShadow()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
        model.focusTick += 1
        installKeyMonitor()
    }

    func close(openingNote: Bool = false) {
        guard let panel, panel.isVisible, !closing else { return }
        closing = true
        removeKeyMonitor()
        let restore = restoreFocusOnClose && !openingNote
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            panel.orderOut(nil)
            panel.alphaValue = 1
            self?.closing = false
            if restore { NSApp.hide(nil) }
        })
    }

    func windowDidResignKey(_ notification: Notification) {
        // 点到别处就收起（保存提示期间除外）
        if model.savedTo == nil { close() }
    }

    // MARK: 内部

    private func prepareModel() {
        model.text = ""
        model.savedTo = nil
        model.attached = false
        model.projects = store.projects
        let lastID = UserDefaults.standard.string(forKey: Self.lastProjectKey).flatMap(UUID.init(uuidString:))
        model.projectIndex = lastID.flatMap { id in store.projects.firstIndex { $0.id == id }.map { $0 + 1 } } ?? 0
        // 两分钟内复制的文字，提示可以一并附上
        if let clip = store.sortedClips.first(where: { !$0.pinned }),
           !clip.isImage, Date().timeIntervalSince(clip.createdAt) < 120 {
            model.suggestion = clip.text
        } else {
            model.suggestion = nil
        }
    }

    private func makePanel() -> CapturePanel {
        let panel = CapturePanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self
        let view = CaptureView(model: model, onSave: { [weak self] open in self?.save(open: open) })
        panel.contentView = NSHostingView(rootView: view)
        return panel
    }

    private func installKeyMonitor() {
        removeKeyMonitor()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let panel = self.panel, event.window === panel else { return event }
            // 中文输入法正在组字时，回车 / Tab / Esc 交给输入法（确认拼音、取消组字）
            if let textView = panel.firstResponder as? NSTextView, textView.hasMarkedText() { return event }
            let flags = event.modifierFlags.intersection([.command, .option, .shift, .control])
            switch event.keyCode {
            case 53: // Esc
                self.close()
                return nil
            case 48: // Tab：换项目
                self.model.cycleProject(backwards: flags.contains(.shift))
                return nil
            case 36, 76: // 回车
                if flags.contains(.option) || flags.contains(.shift) { return event } // 换行
                self.save(open: flags.contains(.command))
                return nil
            default:
                return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func save(open: Bool) {
        let raw = model.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty || model.attached else { return }
        var lines = raw.components(separatedBy: .newlines)
        let title = lines.isEmpty ? "" : lines.removeFirst().trimmingCharacters(in: .whitespaces)
        var content = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if model.attached, let suggestion = model.suggestion {
            content += (content.isEmpty ? "" : "\n\n") + suggestion
        }
        let project = model.selectedProject
        let note = store.addNote(projectID: project?.id, title: title.isEmpty ? "随手一记" : title, content: content)
        UserDefaults.standard.set(project?.id.uuidString, forKey: Self.lastProjectKey)

        if open {
            close(openingNote: true)
            onOpenNote(note.id)
        } else {
            withAnimation(Motion.standard) { model.savedTo = project?.name ?? "收件箱" }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in self?.close() }
        }
    }
}

final class CapturePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class CaptureModel: ObservableObject {
    @Published var text = ""
    @Published var projects: [Project] = []
    /// 0 = 收件箱，其余为 projects 的下标 + 1
    @Published var projectIndex = 0
    @Published var suggestion: String?
    @Published var attached = false
    @Published var savedTo: String?
    @Published var focusTick = 0

    var selectedProject: Project? {
        projectIndex == 0 ? nil : projects[safe: projectIndex - 1]
    }

    func cycleProject(backwards: Bool) {
        let count = projects.count + 1
        projectIndex = (projectIndex + (backwards ? count - 1 : 1)) % count
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

struct CaptureView: View {
    @ObservedObject var model: CaptureModel
    let onSave: (Bool) -> Void
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Palette.paper)
            if let savedTo = model.savedTo {
                saved(savedTo)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            } else {
                editor
                    .transition(.opacity)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.black.opacity(0.08)))
        .frame(width: 600, height: 336)
        .onAppear { focused = true }
        .onChange(of: model.focusTick) { _ in focused = true }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .lastTextBaseline, spacing: 10) {
                Text(ChineseDate.day(Date()))
                    .font(.numeral(40, weight: .regular))
                    .foregroundStyle(Palette.ink)
                Text(ChineseDate.month(Date()) + " · " + ChineseDate.time(Date()))
                    .font(.system(size: 12))
                    .tracking(2)
                    .foregroundStyle(Palette.muted)
                Spacer()
                AppMark(size: 26)
            }
            .padding(.horizontal, 28)
            .padding(.top, 20)

            TextField("随手记一笔…", text: $model.text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.song(20))
                .foregroundStyle(Palette.ink)
                .lineLimit(1...4)
                .lineSpacing(6)
                .focused($focused)
                .padding(.horizontal, 28)
                .padding(.top, 14)

            Spacer(minLength: 10)

            if let suggestion = model.suggestion {
                HStack(spacing: 10) {
                    Text(model.attached ? "已附上" : "刚刚复制")
                        .font(.system(size: 11))
                        .tracking(2)
                        .foregroundStyle(model.attached ? Palette.seal : Palette.muted)
                    Text(suggestion.replacingOccurrences(of: "\n", with: " "))
                        .font(.system(size: 12.5))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Button(model.attached ? "移除" : "附上") {
                        withAnimation(Motion.quick) { model.attached.toggle() }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.tag)
                }
                .padding(.horizontal, 12)
                .frame(height: 36)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.field))
                .padding(.horizontal, 28)
            }

            projectPicker
                .padding(.horizontal, 28)
                .padding(.vertical, 14)

            keyHints
        }
    }

    private var projectPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Text("存到")
                    .font(.system(size: 11))
                    .tracking(2)
                    .foregroundStyle(Palette.muted)
                    .padding(.trailing, 4)
                projectChip(index: 0, title: "收件箱", project: nil)
                ForEach(Array(model.projects.enumerated()), id: \.element.id) { offset, p in
                    projectChip(index: offset + 1, title: p.name, project: p)
                }
            }
        }
    }

    private func projectChip(index: Int, title: String, project: Project?) -> some View {
        let selected = model.projectIndex == index
        return Button {
            withAnimation(Motion.quick) { model.projectIndex = index }
        } label: {
            HStack(spacing: 6) {
                if let project {
                    ProjectSeal(project: project, size: 20)
                } else {
                    Image(systemName: "tray")
                        .font(.system(size: 11))
                        .frame(width: 20, height: 20)
                }
                Text(title).font(.system(size: 13))
            }
            .foregroundStyle(selected ? Palette.onButton : Palette.ink)
            .padding(.leading, 4)
            .padding(.trailing, 10)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(selected ? Palette.button : Color.clear))
        }
        .buttonStyle(.plain)
    }

    private var keyHints: some View {
        HStack(spacing: 18) {
            hint("⏎", "存下")
            hint("⇥", "换项目")
            hint("⌘⏎", "存下并打开")
            hint("⌥⏎", "换行")
            Spacer()
            hint("esc", "收起")
        }
        .font(.system(size: 11.5))
        .foregroundStyle(Palette.ink2)
        .padding(.horizontal, 28)
        .frame(height: 40)
        .background(Palette.list)
        .overlay(alignment: .top) { Rectangle().fill(Palette.line).frame(height: 1) }
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 6) {
            Text(key)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 4).fill(Palette.paper))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Palette.line))
            Text(label)
        }
    }

    private func saved(_ name: String) -> some View {
        VStack(spacing: 12) {
            AppMark(size: 40)
            HStack(spacing: 4) {
                Text("已存入")
                Text(name).fontWeight(.bold)
            }
            .font(.song(18))
            .foregroundStyle(Palette.ink)
        }
    }
}
