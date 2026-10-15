import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    let settings = AppSettings.shared
    let store = Store(location: AppSettings.shared.storageLocation)
    private var clipboard: ClipboardMonitor!
    private var window: NSWindow!
    private var settingsWindow: NSWindow?
    private var statusItem: NSStatusItem!
    private lazy var capture: QuickCaptureController = {
        let controller = QuickCaptureController(store: store)
        controller.isMainWindowVisible = { [weak self] in self?.window.isVisible ?? false }
        controller.onOpenNote = { [weak self] id in
            self?.showWindow()
            NotificationCenter.default.post(name: .qnOpenNote, object: id)
        }
        return controller
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(settings.showDockIcon ? .regular : .accessory)
        buildMainMenu()
        buildWindow()
        buildStatusItem()

        HotKeyManager.shared.handlers = [
            HotKeyAction.quickCapture.rawValue: { [weak self] in self?.quickCapture() },
            HotKeyAction.toggleWindow.rawValue: { [weak self] in self?.toggleWindow() },
            HotKeyAction.showClipboard.rawValue: { [weak self] in self?.toggleClipboard() },
        ]
        settings.applyHotKeys()

        clipboard = ClipboardMonitor(store: store, settings: settings)
        clipboard.start()

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(hideWindow), name: .qnHideWindow, object: nil)
        nc.addObserver(self, selector: #selector(dockIconChanged), name: .qnDockIconChanged, object: nil)

        showWindow()
        // 启动时有快捷键冲突，直接打开设置提醒用户
        if !settings.hotKeyErrors.isEmpty { openSettings() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        store.saveNow()
    }

    // MARK: - Window

    private func buildWindow() {
        let root = ContentView()
            .environmentObject(store)
            .environmentObject(settings)
        let hosting = NSHostingController(rootView: root)
        hosting.sizingOptions = []

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1040, height: 660),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = hosting
        window.title = "随手记"
        // 隐藏标题栏，让纸面一直铺到顶部，红绿灯浮在侧栏上
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.backgroundColor = Palette.paperNS
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace]
        window.minSize = NSSize(width: 900, height: 560)
        window.setContentSize(NSSize(width: 1240, height: 780))
        window.center()
        window.setFrameAutosaveName("QuickNoteMainWindow")
    }

    private var isFrontmost: Bool {
        window.isVisible && NSApp.isActive && window.isKeyWindow
    }

    @objc func toggleWindow() {
        isFrontmost ? hideWindow() : showWindow()
    }

    @objc func toggleClipboard() {
        if isFrontmost {
            hideWindow()
        } else {
            showClipboard()
        }
    }

    @objc func showClipboard() {
        showWindow()
        NotificationCenter.default.post(name: .qnShowClipboard, object: nil)
    }

    /// 每次显示 / 隐藏递增，用来让被打断的隐藏动画不再收尾
    private var transitionID = 0

    @objc func showWindow() {
        transitionID += 1
        let wasOnScreen = window.isVisible && !NSApp.isHidden && window.alphaValue > 0.99
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        if wasOnScreen {
            window.makeKeyAndOrderFront(nil)
            return
        }
        // 轻微淡入
        window.alphaValue = 0
        window.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.window.animator().alphaValue = 1
        }
        // 呼出后如果没有正在编辑的地方，直接把光标放进搜索框，马上就能打字
        DispatchQueue.main.async {
            if self.window.firstResponder === self.window {
                NotificationCenter.default.post(name: .qnFocusSearch, object: nil)
            }
        }
    }

    @objc func hideWindow() {
        transitionID += 1
        let id = transitionID
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            self.window.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.transitionID == id else { return }
            self.window.orderOut(nil)
            self.window.alphaValue = 1
            // 把焦点还给之前的应用
            NSApp.hide(nil)
        })
    }

    @objc private func dockIconChanged() {
        NSApp.setActivationPolicy(settings.showDockIcon ? .regular : .accessory)
        DispatchQueue.main.async { self.showWindow() }
    }

    @objc func openSettings() {
        if settingsWindow == nil {
            // 系统设置窗口样式：工具栏里的图标标签，切换时窗口自动调整高度
            let tabs = NSTabViewController()
            tabs.tabStyle = .toolbar
            for page in SettingsPage.allCases {
                let hosting = NSHostingController(
                    rootView: page.view
                        .frame(width: page.size.width, height: page.size.height)
                        .environmentObject(settings)
                        .environmentObject(store)
                )
                hosting.preferredContentSize = page.size
                let item = NSTabViewItem(viewController: hosting)
                item.label = page.title
                item.image = NSImage(systemSymbolName: page.symbol, accessibilityDescription: page.title)
                tabs.addTabViewItem(item)
            }
            let w = NSWindow(contentViewController: tabs)
            w.styleMask = [.titled, .closable]
            w.toolbarStyle = .preference
            w.isReleasedWhenClosed = false
            settingsWindow = w
            w.center()
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func newNote() {
        showWindow()
        NotificationCenter.default.post(name: .qnNewNote, object: nil)
    }

    @objc func newProject() {
        showWindow()
        NotificationCenter.default.post(name: .qnNewProject, object: nil)
    }

    @objc func focusSearch() {
        showWindow()
        NotificationCenter.default.post(name: .qnFocusSearch, object: nil)
    }

    @objc func quickCapture() {
        capture.toggle()
    }

    @objc func toggleSidebar() {
        NotificationCenter.default.post(name: .qnToggleSidebar, object: nil)
    }

    @objc func exportAll() {
        MarkdownExporter.exportNotes(store.notes, title: "随手记导出", store: store)
    }

    // MARK: - Status bar

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "note.text", accessibilityDescription: "随手记")

        let menu = NSMenu()
        menu.addItem(item("随手记一笔", #selector(quickCapture)))
        menu.addItem(item("显示 / 隐藏窗口", #selector(toggleWindow)))
        menu.addItem(item("剪贴板历史", #selector(showClipboard)))
        menu.addItem(item("新建笔记", #selector(newNote)))
        menu.addItem(item("搜索…", #selector(focusSearch)))
        menu.addItem(.separator())
        menu.addItem(item("导出全部笔记为 Markdown…", #selector(exportAll)))
        menu.addItem(item("设置…", #selector(openSettings)))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出 随手记", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private func item(_ title: String, _ action: Selector, key: String = "", modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.keyEquivalentModifierMask = modifiers
        i.target = self
        return i
    }

    // MARK: - Main menu（没有它，⌘C / ⌘V 等编辑快捷键不会生效）

    private func buildMainMenu() {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "关于 随手记", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""))
        appMenu.addItem(.separator())
        appMenu.addItem(item("设置…", #selector(openSettings), key: ","))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "隐藏 随手记", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        appMenu.addItem(NSMenuItem(title: "退出 随手记", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        addSubmenu(appMenu, to: main)

        let fileMenu = NSMenu(title: "文件")
        fileMenu.addItem(item("新建笔记", #selector(newNote), key: "n"))
        fileMenu.addItem(item("随手记一笔…", #selector(quickCapture)))
        fileMenu.addItem(item("新建项目…", #selector(newProject), key: "n", modifiers: [.command, .shift]))
        fileMenu.addItem(item("搜索", #selector(focusSearch), key: "f"))
        fileMenu.addItem(item("剪贴板历史", #selector(showClipboard), key: "y", modifiers: [.command, .shift]))
        fileMenu.addItem(.separator())
        fileMenu.addItem(item("导出全部笔记为 Markdown…", #selector(exportAll), key: "e", modifiers: [.command, .shift]))
        fileMenu.addItem(.separator())
        fileMenu.addItem(NSMenuItem(title: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        addSubmenu(fileMenu, to: main)

        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(NSMenuItem(title: "撤销", action: Selector(("undo:")), keyEquivalent: "z"))
        let redo = NSMenuItem(title: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redo)
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        addSubmenu(editMenu, to: main)

        let viewMenu = NSMenu(title: "显示")
        viewMenu.addItem(item("显示 / 隐藏侧栏", #selector(toggleSidebar), key: "s", modifiers: [.command, .control]))
        addSubmenu(viewMenu, to: main)

        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(NSMenuItem(title: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        addSubmenu(windowMenu, to: main)
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = main
    }

    private func addSubmenu(_ submenu: NSMenu, to menu: NSMenu) {
        let holder = NSMenuItem()
        holder.submenu = submenu
        menu.addItem(holder)
    }
}
