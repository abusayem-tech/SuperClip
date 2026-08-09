import AppKit

protocol PreferencesDelegate: AnyObject {
    func preferencesDidChange(_ config: Config)
    func preferencesDidRequestPurge()
    func preferencesDidRequestClearHistory()
    func preferencesDidRequestClearEverything()
}

final class PreferencesController: NSWindowController, NSWindowDelegate {
    weak var prefsDelegate: PreferencesDelegate?

    private var config: Config
    private let retentionField = NSTextField()
    private let maxStorageField = NSTextField()
    private let excludeField = NSTextField()
    private let mergeField = NSTextField()
    private let modePopUp = NSPopUpButton()
    private let usedLabel = NSTextField.plain(font: Theme.body, color: Theme.ink)
    private let countsLabel = NSTextField.plain(font: Theme.caption, color: Theme.dim)
    private let meter = NSProgressIndicator()

    init(config: Config) {
        self.config = config
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 460),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "SuperClip Preferences"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.center()
        buildUI()
        loadValues()
        refreshStats()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }

        func labeled(_ title: String, field: NSView) -> NSStackView {
            let label = NSTextField.plain(title, font: Theme.label, color: Theme.dim)
            let stack = NSStackView(views: [label, field])
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 4
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: 380).isActive = true
            return stack
        }

        for field in [retentionField, maxStorageField, mergeField] {
            field.font = Theme.body
            field.isEditable = true
            field.isBordered = true
            field.bezelStyle = .roundedBezel
        }
        excludeField.font = Theme.body
        excludeField.isEditable = true
        excludeField.isBordered = true
        excludeField.bezelStyle = .roundedBezel
        excludeField.placeholderString = "com.1password.1password, com.apple.keychainaccess"

        modePopUp.removeAllItems()
        for mode in MenubarMode.allCases {
            modePopUp.addItem(withTitle: mode.displayName)
            modePopUp.lastItem?.representedObject = mode.rawValue
        }

        meter.isIndeterminate = false
        meter.minValue = 0
        meter.maxValue = 1
        meter.style = .bar
        meter.translatesAutoresizingMaskIntoConstraints = false
        meter.heightAnchor.constraint(equalToConstant: 12).isActive = true
        meter.widthAnchor.constraint(equalToConstant: 380).isActive = true

        let healthTitle = NSTextField.plain("Storage health", font: Theme.title, color: Theme.ink)
        let settingsTitle = NSTextField.plain("Settings", font: Theme.title, color: Theme.ink)
        let loginTip = NSTextField.plain(
            "Launch at login: System Settings → General → Login Items → + → SuperClip.app",
            font: Theme.caption,
            color: Theme.faint
        )
        loginTip.maximumNumberOfLines = 3
        loginTip.preferredMaxLayoutWidth = 380

        let purgeBtn = NSButton(title: "Purge expired now", target: self, action: #selector(purge))
        let clearHistBtn = NSButton(
            title: "Clear History…", target: self, action: #selector(clearHistory)
        )
        let clearAllBtn = NSButton(
            title: "Clear Everything…", target: self, action: #selector(clearEverything)
        )
        for b in [purgeBtn, clearHistBtn, clearAllBtn] {
            b.bezelStyle = .rounded
        }
        clearAllBtn.contentTintColor = Theme.danger

        let buttons = NSStackView(views: [purgeBtn, clearHistBtn, clearAllBtn])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let saveBtn = NSButton(title: "Save", target: self, action: #selector(save))
        saveBtn.bezelStyle = .rounded
        saveBtn.keyEquivalent = "\r"

        let stack = NSStackView(views: [
            settingsTitle,
            labeled("Retention days", field: retentionField),
            labeled("Max storage (MB)", field: maxStorageField),
            labeled("Exclude app bundle IDs (comma-separated)", field: excludeField),
            labeled("Merge consecutive text window (ms)", field: mergeField),
            labeled("Menubar preview", field: modePopUp),
            loginTip,
            NSView.divider(),
            healthTitle,
            usedLabel,
            countsLabel,
            meter,
            buttons,
            saveBtn,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
        ])
    }

    private func loadValues() {
        retentionField.stringValue = "\(config.retentionDays)"
        maxStorageField.stringValue = "\(config.maxStorageMB)"
        excludeField.stringValue = config.excludeApps.joined(separator: ", ")
        mergeField.stringValue = "\(config.mergeTextWindowMs)"
        if let idx = MenubarMode.allCases.firstIndex(of: config.menubarMode) {
            modePopUp.selectItem(at: idx)
        }
    }

    func refreshStats() {
        let stats = Storage.shared.stats(maxStorageMB: config.maxStorageMB)
        usedLabel.stringValue =
            "\(Format.bytesString(stats.usedBytes)) used of \(config.maxStorageMB) MB"
        countsLabel.stringValue =
            "\(stats.itemCount) items · \(stats.imageCount) images"
        meter.doubleValue = stats.fraction
    }

    func updateConfig(_ config: Config) {
        self.config = config
        loadValues()
        refreshStats()
    }

    @objc private func save() {
        var next = config
        next.retentionDays = max(1, Int(retentionField.stringValue) ?? config.retentionDays)
        next.maxStorageMB = max(10, Int(maxStorageField.stringValue) ?? config.maxStorageMB)
        next.mergeTextWindowMs = max(0, Int(mergeField.stringValue) ?? config.mergeTextWindowMs)
        next.excludeApps = excludeField.stringValue
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if let raw = modePopUp.selectedItem?.representedObject as? String,
           let mode = MenubarMode(rawValue: raw)
        {
            next.menubarMode = mode
        }
        do {
            try next.save()
            config = next
            prefsDelegate?.preferencesDidChange(next)
            refreshStats()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not save preferences"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    @objc private func purge() {
        prefsDelegate?.preferencesDidRequestPurge()
        refreshStats()
    }

    @objc private func clearHistory() {
        prefsDelegate?.preferencesDidRequestClearHistory()
        refreshStats()
    }

    @objc private func clearEverything() {
        prefsDelegate?.preferencesDidRequestClearEverything()
        refreshStats()
    }
}
