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

    func applicationDidFinishLaunching(_ notification: Notification) {
        ProcessInfo.processInfo.disableAutomaticTermination("SuperClip clipboard monitor")
        ProcessInfo.processInfo.disableSuddenTermination()
        runActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
            reason: "Monitoring the clipboard"
        )

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // No autosaveName: it persists a hidden state that silently keeps the
        // item off the menu bar forever once macOS or the user hides it.
        statusItem.isVisible = true
        if let button = statusItem.button {
            button.image = MenubarIcon.make()
            button.imagePosition = .imageLeading
            button.font = NSFont.systemFont(ofSize: 12, weight: .medium)
            button.toolTip = "SuperClip — click for clipboard history"
            button.target = self
            button.action = #selector(togglePanel)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        panel.delegate = self
        popover.contentViewController = panel
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self

        monitor.delegate = self
        monitor.updateConfig(config)
        monitor.start()

        lastItem = Storage.shared.latestItem()
        renderStatus()
        runCleanup()
        startCleanupTimer()

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )

        // The menu bar can silently swallow an item (full bar, notch, hidden
        // state). Record where it actually landed so problems are diagnosable.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.logStatusItemPlacement()
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
        renderStatus()
        if popover.isShown { panel.reload() }
        prefs?.refreshStats()
    }

    // MARK: - Status item

    @objc private func togglePanel() {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        guard let button = statusItem.button else { return }

        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu()
            return
        }

        monitor.pollNow()
        panel.reload()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
        popover.contentViewController?.view.window?.makeKey()
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
        guard let button = statusItem.button else { return }
        button.title = ""
        button.image = MenubarIcon.make()
        button.imagePosition = .imageLeading
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
        if popover.isShown { panel.reload() }
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
        if popover.isShown { panel.reload() }
    }

    // MARK: - Panel

    func panelDidCopyItem() {
        popover.performClose(nil)
    }

    func panelDidRequestClose() {
        popover.performClose(nil)
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
