import AppKit
import Foundation

@main
enum SuperClipMain {
    private static let delegate = AppDelegate()

    static func main() {
        let app = NSApplication.shared
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, PanelDelegate, PreferencesDelegate,
    PasteboardMonitorDelegate, NSPopoverDelegate
{
    private var statusItem: NSStatusItem!
    private let statusItemAutosaveName = "SuperClip"
    private let popover = NSPopover()
    private let panel = PanelController()
    private let monitor = PasteboardMonitor()
    private var config = Config.load()
    private var prefs: PreferencesController?
    private var cleanupTimer: Timer?
    private var flashWorkItem: DispatchWorkItem?
    private var lastItem: ClipboardItem?
    /// Keeps App Nap / automatic termination from quitting this agent app.
    private var runActivity: NSObjectProtocol?

    @objc func applicationDidFinishLaunching(_ notification: Notification) {
        let bootLog = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/SuperClip/launch.log")
        try? "didFinishLaunching \(Date())\n".write(to: bootLog, atomically: true, encoding: .utf8)

        ProcessInfo.processInfo.disableAutomaticTermination("SuperClip clipboard monitor")
        ProcessInfo.processInfo.disableSuddenTermination()
        runActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
            reason: "Monitoring the clipboard"
        )

        forceStatusItemAllowed()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.autosaveName = statusItemAutosaveName
        forceStatusItemAllowed()
        statusItem.isVisible = true
        configureStatusItemButton()

        panel.delegate = self
        popover.contentViewController = panel
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        _ = panel.view

        monitor.delegate = self
        monitor.updateConfig(config)
        monitor.start()

        lastItem = Storage.shared.latestItem()
        renderStatus()
        startCleanupTimer()

        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.runCleanup()
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )

        DispatchQueue.main.async { [weak self] in
            self?.ensureStatusItemVisible(attempt: 0)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.logStatusItemPlacement()
        }

        if FileManager.default.fileExists(
            atPath: Storage.shared.supportDirectory.appendingPathComponent("selftest.flag").path
        ) {
            try? FileManager.default.removeItem(
                at: Storage.shared.supportDirectory.appendingPathComponent("selftest.flag")
            )
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.showPanel()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    self?.hidePanel()
                    let url = Storage.shared.supportDirectory.appendingPathComponent("selftest.ok")
                    try? "ok \(Date())\n".write(to: url, atomically: true, encoding: .utf8)
                }
            }
        }
    }

    private func logStatusItemPlacement() {
        let button = statusItem.button
        let window = button?.window
        let screen = NSScreen.main
        var lines = [
            "launched \(Date())",
            "isVisible=\(statusItem.isVisible)",
            "length=\(statusItem.length)",
            "title=\"\(button?.title ?? "nil")\"",
            "hasImage=\(button?.image != nil)",
            "buttonFrame=\(button?.frame ?? .zero)",
            "windowFrame=\(window?.frame ?? .zero)",
        ]
        if let screen {
            lines.append("screenFrame=\(screen.frame)")
            lines.append("visibleFrame=\(screen.visibleFrame)")
            if #available(macOS 12.0, *) {
                lines.append("safeAreaTop=\(screen.safeAreaInsets.top)")
            }
        }
        if let window, let screen {
            let offScreen = !screen.frame.intersects(window.frame)
            lines.append("offScreen=\(offScreen)")
        }
        let text = lines.joined(separator: "\n") + "\n"
        let url = Storage.shared.supportDirectory.appendingPathComponent("launch.log")
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    @objc private func handleWake() {
        monitor.pollNow()
        runCleanup()
    }

    private func startCleanupTimer() {
        cleanupTimer?.invalidate()
        let day: TimeInterval = 86_400
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: day, repeats: true) { [weak self] _ in
            self?.runCleanup()
        }
        cleanupTimer?.tolerance = day * 0.2
        if let cleanupTimer {
            RunLoop.main.add(cleanupTimer, forMode: .common)
        }
    }

    private func runCleanup() {
        Storage.shared.prune(
            retentionDays: config.retentionDays,
            maxStorageMB: config.maxStorageMB
        )
        DispatchQueue.main.async { [weak self] in
            self?.renderStatus()
            self?.panel.noteDataChanged()
            self?.prefs?.refreshStats()
        }
    }

    // MARK: - Status item

    private func configureStatusItemButton() {
        guard let button = statusItem.button else { return }
        button.image = MenubarIcon.make()
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.title = ""
        button.toolTip = "SuperClip — click for clipboard history"
        button.target = self
        button.action = #selector(togglePanel)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.appearsDisabled = false
    }

    private func forceStatusItemAllowed() {
        let name = statusItemAutosaveName
        let visibleKeys = [
            "NSStatusItem Visible \(name)",
            "NSStatusItem VisibleCC \(name)",
        ]
        let suites: [UserDefaults] = [
            .standard,
            UserDefaults(suiteName: "com.apple.controlcenter"),
            UserDefaults(suiteName: UserDefaults.globalDomain),
        ].compactMap { $0 }
        for defaults in suites {
            for key in visibleKeys {
                defaults.set(true, forKey: key)
            }
            defaults.set(520.0, forKey: "NSStatusItem Preferred Position \(name)")
            defaults.synchronize()
        }
    }

    private func statusItemIsOnMenuBar() -> Bool {
        guard let window = statusItem.button?.window else { return false }
        let frame = window.frame
        guard frame.width > 8, frame.height > 8, frame.minX >= 0 else { return false }
        if let screen = window.screen ?? NSScreen.main {
            return frame.minY >= screen.visibleFrame.maxY - 12
        }
        return frame.minY > 200
    }

    private func recreateStatusItem() {
        NSStatusBar.system.removeStatusItem(statusItem)
        forceStatusItemAllowed()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.autosaveName = statusItemAutosaveName
        statusItem.isVisible = true
        configureStatusItemButton()
    }

    private func ensureStatusItemVisible(attempt: Int) {
        statusItem.isVisible = true
        configureStatusItemButton()
        if statusItemIsOnMenuBar() {
            logStatusItemPlacement()
            return
        }
        if attempt == 2 || attempt == 4 {
            recreateStatusItem()
        }
        guard attempt < 8 else {
            logStatusItemPlacement()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.ensureStatusItemVisible(attempt: attempt + 1)
        }
    }

    @objc private func togglePanel() {
        if popover.isShown {
            hidePanel()
            if NSApp.currentEvent?.type == .rightMouseUp {
                showContextMenu()
            }
            return
        }
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu()
            return
        }
        showPanel()
    }

    private func showPanel() {
        guard let button = statusItem.button else { return }
        panel.prepareForDisplay()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func hidePanel() {
        popover.performClose(nil)
    }

    func popoverDidClose(_ notification: Notification) {}

    private func showContextMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Clear History…", action: #selector(clearHistory), keyEquivalent: "")
        menu.addItem(
            withTitle: "Clear Everything…", action: #selector(clearEverything), keyEquivalent: ""
        )
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Open Storage Folder", action: #selector(openStorage), keyEquivalent: ""
        )
        menu.addItem(withTitle: "Preferences…", action: #selector(openPreferences), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit SuperClip", action: #selector(quit), keyEquivalent: "q")
        menu.items.forEach { $0.target = self }

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    private func renderStatus() {
        configureStatusItemButton()
        statusItem.isVisible = true
    }

    private func flashStatus() {
        guard let button = statusItem.button else { return }
        flashWorkItem?.cancel()
        let previous = button.title
        button.appearsDisabled = true
        let work = DispatchWorkItem { [weak self, weak button] in
            button?.appearsDisabled = false
            self?.renderStatus()
            if button?.title != previous { /* restored via renderStatus */ }
        }
        flashWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    // MARK: - Monitor

    func pasteboardMonitor(_ monitor: PasteboardMonitor, didCapture item: ClipboardItem) {
        lastItem = item
        renderStatus()
        flashStatus()
        panel.noteDataChanged()
        prefs?.refreshStats()
        // Enforce size cap opportunistically after large image captures.
        Storage.shared.prune(
            retentionDays: config.retentionDays,
            maxStorageMB: config.maxStorageMB
        )
    }

    func pasteboardMonitor(_ monitor: PasteboardMonitor, didUpdate item: ClipboardItem) {
        lastItem = item
        renderStatus()
        panel.noteDataChanged()
    }

    // MARK: - Panel

    func panelDidCopyItem() {
        hidePanel()
    }

    func panelDidRequestClose() {
        hidePanel()
    }

    func panelDidChangeData() {
        lastItem = Storage.shared.latestItem()
        renderStatus()
        prefs?.refreshStats()
    }

    func panelDidRequestClearHistory() { clearHistory() }
    func panelDidRequestClearEverything() { clearEverything() }

    // MARK: - Menu actions

    @objc private func clearHistory() {
        let alert = NSAlert()
        alert.messageText = "Clear clipboard history?"
        alert.informativeText =
            "Deletes unpinned history and image files, vacuums storage, and clears the system pasteboard. Pins and snippets are kept. Disk space is freed immediately."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Clear History")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Storage.shared.clearHistory()
        PasteboardWriter.clearSystemPasteboard()
        lastItem = Storage.shared.latestItem()
        renderStatus()
        panel.reload()
        prefs?.refreshStats()
    }

    @objc private func clearEverything() {
        let alert = NSAlert()
        alert.messageText = "Clear everything?"
        alert.informativeText =
            "Deletes all history including pins and snippets, wipes stored images, vacuums storage, and clears the system pasteboard. This cannot be undone."
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Clear Everything")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Storage.shared.clearEverything()
        PasteboardWriter.clearSystemPasteboard()
        lastItem = nil
        renderStatus()
        panel.reload()
        prefs?.refreshStats()
    }

    @objc private func openStorage() {
        NSWorkspace.shared.open(Storage.shared.supportDirectory)
    }

    @objc private func openPreferences() {
        if prefs == nil {
            let controller = PreferencesController(config: config)
            controller.prefsDelegate = self
            prefs = controller
        } else {
            prefs?.updateConfig(config)
        }
        prefs?.showWindow(nil)
        prefs?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        prefs?.refreshStats()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Preferences

    func preferencesDidChange(_ config: Config) {
        self.config = config
        monitor.updateConfig(config)
        renderStatus()
        runCleanup()
    }

    func preferencesDidRequestPurge() {
        runCleanup()
    }

    func preferencesDidRequestClearHistory() {
        clearHistory()
    }

    func preferencesDidRequestClearEverything() {
        clearEverything()
    }
}
