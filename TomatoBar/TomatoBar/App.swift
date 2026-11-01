import SwiftUI

@main
struct TBApp: App {
    @NSApplicationDelegateAdaptor(TBStatusItem.self) var appDelegate
    var body: some Scene { Settings { EmptyView() } }
}

@MainActor
final class TBStatusItem: NSObject, NSApplicationDelegate {
    private let popover = NSPopover()
    private var statusBarItem: NSStatusItem?
    private var store: FocusStore!
    private var timer: TBTimer!
    private let navigation = FocusNavigation()
    private var mainWindow: FocusWindowController?
    private let hotKey = TBHotKey()
    private var shuttingDown = false
    private var appliedPreferences: FocusPreferences?
    private var appliedType: FocusType?
    #if DEBUG
    private var debugTransitions: [String] = []
    private var lastState: TBFocusState = .idle
    #endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: "local.shijie.FocusBar").filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        #if DEBUG
        let isolated = ProcessInfo.processInfo.environment["FOCUSBAR_DATA_DIR"] != nil
        #else
        let isolated = false
        #endif
        if let other = others.first, !isolated {
            other.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            NSApp.terminate(nil)
            return
        }
        NSApp.setActivationPolicy(.regular)
        #if DEBUG
        let directory = ProcessInfo.processInfo.environment["FOCUSBAR_DATA_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let directory, ProcessInfo.processInfo.environment["FOCUSBAR_FIXTURE"] == "1" { seedPreviewData(directory: directory) }
        store = FocusStore(directory: directory)
        #else
        store = FocusStore()
        #endif
        if let icon = NSImage(named: "FocusBar") { NSApp.applicationIconImage = icon }
        timer = TBTimer(store: store)
        #if DEBUG
        if isolated { timer.suppressAlerts = true }
        #endif
        mainWindow = FocusWindowController(store: store, timer: timer, navigation: navigation)
        statusBarItem = NSStatusBar.system.statusItem(withLength: 116)
        statusBarItem?.autosaveName = "FocusBar.Progress"
        if let button = statusBarItem?.button {
            button.target = self
            button.action = #selector(togglePopover(_:))
        }
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: TBPopoverView(timer: timer, store: store, openWindow: { [weak self] in self?.showMainWindow() }))
        timer.onUpdate = { [weak self] in self?.render() }
        timer.onOpen = { [weak self] in self?.showMainWindow() }
        store.onPreferencesChanged = { [weak self] in
            self?.applyPreferences()
        }
        hotKey.action = { [weak self] in self?.timer.startStop() }
        applyPreferences()
        render()
        if store.preferences.showWindowAtLaunch { showMainWindow() }
        #if DEBUG
        runDebugScenario()
        #endif
    }

    private func applyPreferences() {
        let preferences = store.preferences
        if appliedPreferences?.hotKeyEnabled != preferences.hotKeyEnabled {
            hotKey.unregister()
            timer.hotKeyAvailable = preferences.hotKeyEnabled && hotKey.register()
        }
        if appliedPreferences?.appearance != preferences.appearance {
            switch preferences.appearance {
            case "light": NSApp.appearance = NSAppearance(named: .aqua)
            case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
            default: NSApp.appearance = nil
            }
        }
        let type = store.selectedType
        if appliedType?.id != type.id || appliedType?.minutes != type.minutes { timer.settingsChanged() }
        appliedType = type
        appliedPreferences = preferences
        render()
    }

    private func render() {
        guard let timer, let store, let button = statusBarItem?.button else { return }
        let preferences = store.preferences
        statusBarItem?.length = preferences.menuWidth + 40 + (preferences.menuTime ? 46 : 0)
        button.image = TBProgressImage.make(progress: timer.progress, state: timer.state, width: preferences.menuWidth, style: preferences.menuStyle)
        button.imagePosition = preferences.menuTime ? .imageLeft : .imageOnly
        button.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        button.title = preferences.menuTime ? timer.timeLeftString : ""
        let summary = "专注条 · \(timer.currentName) · \(timer.state.label) · 剩余 \(timer.timeLeftString) · 已完成 \(Int(timer.progress * 100))%"
        button.toolTip = summary
        button.setAccessibilityLabel(summary)
        button.setAccessibilityValue("\(Int(timer.progress * 100))%")
        #if DEBUG
        if lastState != timer.state { debugTransitions.append(timer.state.rawValue); lastState = timer.state }
        writeDebugState()
        #endif
    }

    func showMainWindow() {
        popover.performClose(nil)
        mainWindow?.present()
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    @objc func togglePopover(_ sender: AnyObject?) {
        guard let button = statusBarItem?.button else { return }
        if popover.isShown { popover.performClose(sender) }
        else {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !shuttingDown, let timer else { return .terminateNow }
        if timer.prepareToQuit() { shuttingDown = true; return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "专注记录尚未保存成功"
        alert.informativeText = "建议取消退出，检查磁盘空间或数据目录后重试。强行退出可能丢失未保存的时间。"
        alert.addButton(withTitle: "取消退出")
        alert.addButton(withTitle: "仍然退出")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateCancel : .terminateNow
    }
    func applicationWillTerminate(_ notification: Notification) {
        hotKey.unregister()
        timer?.shutdown()
    }

    #if DEBUG
    private func seedPreviewData(directory: URL) {
        guard !FileManager.default.fileExists(atPath: directory.appendingPathComponent("focus-data.json").path) else { return }
        var document = FocusDocument()
        let calendar = Calendar.current
        for day in 0..<14 {
            for index in 0..<3 {
                let type = document.types[index]
                let startDay = calendar.date(byAdding: .day, value: -day, to: calendar.startOfDay(for: Date()))!
                let start = calendar.date(byAdding: .hour, value: 8 + index * 2, to: startDay)!
                let seconds = Double((15 + (day + index) % 4 * 10) * 60)
                guard start.addingTimeInterval(seconds) < Date() else { continue }
                document.history.append(FocusRecord(typeID: type.id, typeName: type.name, symbol: type.symbol,
                    title: ["推进产品方案", "阅读与摘记", "梳理一个问题"][index], plannedSeconds: seconds,
                    startedAt: start, endedAt: start.addingTimeInterval(seconds), outcome: .completed,
                    segments: [.init(start: start, end: start.addingTimeInterval(seconds), seconds: seconds)]))
            }
        }
        if let repository = try? FocusRepository(directory: directory) { try? repository.save(document) }
    }

    private func runDebugScenario() {
        let environment = ProcessInfo.processInfo.environment
        if let seconds = environment["FOCUSBAR_TEST_SECONDS"].flatMap(Double.init), seconds > 0 {
            timer.suppressAlerts = true
            timer.start(seconds: min(60, seconds))
        }
        if environment["FOCUSBAR_FLOW_TEST"] == "1" {
            _ = store.saveType(id: nil, name: "写作测试", symbol: "pencil", minutes: 30)
            if let type = store.availableTypes.last { store.select(type.id) }
            timer.draftTitle = "隔离验证：提前结束仍保存"
            timer.start(seconds: 60)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in self?.timer.startStop() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) { [weak self] in
                guard let self else { return }
                _ = self.timer.end()
                if let type = self.store.availableTypes.last {
                    _ = self.store.saveType(id: type.id, name: "写作改名", symbol: "pencil", minutes: 40)
                    self.store.archive(self.store.types.last!)
                }
                self.store.select(FocusType.defaults[1].id)
                self.timer.draftTitle = "隔离验证：阅读完成"
                self.timer.start(seconds: 3)
            }
        }
        if environment["FOCUSBAR_STYLE_TEST"] == "1" {
            timer.suppressAlerts = true
            timer.start(seconds: 30)
            for (index, style) in MenuBarStyle.allCases.enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(index + 1)) { [weak self] in
                    guard let self else { return }
                    self.store.setPreferences { $0.menuStyle = style }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.timer.pause() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.5) { [weak self] in
                self?.store.setPreferences { $0.menuStyle = .segmented }
            }
        }
        if environment["FOCUSBAR_AUTOTEST"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.timer.startStop() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.timer.startStop() }
        }
        if let seconds = environment["FOCUSBAR_EXIT_AFTER"].flatMap(Double.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { NSApp.terminate(nil) }
        }
        if let page = environment["FOCUSBAR_PAGE"], let target = FocusPage.allCases.first(where: { $0.rawValue == page }) { navigation.page = target }
        if environment["FOCUSBAR_TYPE_EDITOR"] == "1", environment["FOCUSBAR_DATA_DIR"] != nil {
            mainWindow?.window?.contentViewController = NSHostingController(rootView: FocusTypeEditor(store: store, original: nil))
            mainWindow?.window?.setContentSize(NSSize(width: 548, height: 530))
        }
        if environment["FOCUSBAR_UI_TEST"] == "1" {
            for (index, page) in FocusPage.allCases.enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(index + 1)) { [weak self] in self?.navigation.page = page }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in self?.mainWindow?.close() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 7) { [weak self] in self?.showMainWindow() }
        }
        if let directory = environment["FOCUSBAR_PREVIEW_DIR"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.exportPreviews(directory: directory) }
        }
        if environment["FOCUSBAR_RESTORE_FIXTURE"] == "1", store.document.active == nil {
            let type = store.selectedType
            let date = Date().addingTimeInterval(-120)
            let record = FocusRecord(typeID: type.id, typeName: type.name, symbol: type.symbol,
                title: "恢复验证", plannedSeconds: 1500, startedAt: date,
                segments: [.init(start: date, end: date.addingTimeInterval(60), seconds: 60)])
            _ = store.transaction { $0.active = record }
        }
        if let path = environment["FOCUSBAR_WINDOW_IMAGE"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.captureMainWindow(path: path) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.writeDebugState() }
    }

    private func captureMainWindow(path: String) {
        guard let view = mainWindow?.window?.contentView else { return }
        view.layoutSubtreeIfNeeded()
        if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
    }

    private func exportPreviews(directory: String) {
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for (name, scheme) in [("light", ColorScheme.light), ("dark", .dark)] {
            for page in FocusPage.allCases {
                let nav = FocusNavigation()
                nav.page = page
                let root = FocusMainView(store: store, timer: timer, navigation: nav)
                    .environment(\.colorScheme, scheme).frame(width: 1080, height: 760)
                    .background(scheme == .dark ? Color(nsColor: .init(calibratedWhite: 0.1, alpha: 1)) : Color.white)
                let host = NSHostingView(rootView: root)
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 760), styleMask: [.borderless], backing: .buffered, defer: false)
                window.contentView = host
                window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                window.orderFront(nil)
                host.layoutSubtreeIfNeeded()
                host.displayIfNeeded()
                if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: rep)
                    if let png = rep.representation(using: .png, properties: [:]) {
                        try? png.write(to: output.appendingPathComponent("\(page.id)-\(name).png"))
                    }
                }
                window.orderOut(nil)
            }
        }
    }

    private func writeDebugState() {
        guard let path = ProcessInfo.processInfo.environment["FOCUSBAR_STATE_FILE"] else { return }
        let data: [String: Any] = ["state": timer.state.rawValue, "remaining": timer.session.remaining,
            "progress": timer.progress, "hotKey": timer.hotKeyAvailable, "transitions": debugTransitions,
            "historyCount": store.history.count, "totalSeconds": store.history.reduce(0) { $0 + $1.seconds },
            "page": navigation.page.rawValue, "windowVisible": mainWindow?.window?.isVisible ?? false,
            "error": store.errorMessage, "recovery": timer.recoveryMessage,
            "actualSeconds": timer.activeRecord?.seconds ?? 0, "readOnly": store.readOnly,
            "menuStyle": store.preferences.menuStyle.rawValue, "sessionGeneration": timer.session.generation,
            "sessionID": timer.activeRecord?.id.uuidString ?? "", "plannedSeconds": timer.session.duration]
        if let json = try? JSONSerialization.data(withJSONObject: data, options: .sortedKeys) {
            try? json.write(to: URL(fileURLWithPath: path), options: .atomic)
            if let line = String(data: json, encoding: .utf8)?.appending("\n").data(using: .utf8) {
                let url = URL(fileURLWithPath: path + ".jsonl")
                if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
                if let handle = try? FileHandle(forWritingTo: url) { _ = try? handle.seekToEnd(); try? handle.write(contentsOf: line); try? handle.close() }
            }
        }
    }
    #endif
}
