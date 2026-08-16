import AppKit

protocol PanelDelegate: AnyObject {
    func panelDidCopyItem()
    func panelDidRequestClearHistory()
    func panelDidRequestClearEverything()
    func panelDidChangeData()
    func panelDidRequestClose()
}

final class PanelController: NSViewController, NSSearchFieldDelegate, NSTableViewDataSource,
    NSTableViewDelegate, NSMenuDelegate
{
    weak var delegate: PanelDelegate?

    private var items: [ClipboardItem] = []
    private var filter: QuickFilter = .all
    private var searchText = ""
    private var keyMonitor: Any?

    private let searchField = NSSearchField()
    private let filterControl = NSSegmentedControl(
        labels: QuickFilter.allCases.map(\.title),
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let scrollView = NSScrollView()
    private let tableView = ClickCopyTableView()
    private let emptyState = EmptyStateView()
    private let footer = NSTextField.plain(font: Theme.caption, color: Theme.faint)
    private let statsBar = StatsBarView()
    private var isDirty = true

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: Theme.panelWidth, height: Theme.panelHeight))
        view = root

        searchField.placeholderString = "Search clipboard"
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true
        searchField.translatesAutoresizingMaskIntoConstraints = false

        filterControl.selectedSegment = 0
        filterControl.target = self
        filterControl.action = #selector(filterChanged)
        filterControl.segmentStyle = .rounded
        filterControl.font = Theme.caption
        filterControl.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("item"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.delegate = self
        tableView.dataSource = self
        tableView.rowHeight = 60
        tableView.style = .plain
        tableView.selectionHighlightStyle = .regular
        tableView.allowsEmptySelection = true
        tableView.backgroundColor = .clear
        tableView.menu = makeContextMenu()
        tableView.setDraggingSourceOperationMask(.copy, forLocal: false)
        tableView.onRowActivate = { [weak self] row in
            self?.copyRow(row)
        }
        tableView.doubleAction = #selector(activateSelection)
        tableView.target = self

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        emptyState.translatesAutoresizingMaskIntoConstraints = false
        emptyState.isHidden = true
        footer.translatesAutoresizingMaskIntoConstraints = false

        let clearButton = NSButton(
            title: "Clear History…",
            target: self,
            action: #selector(clearHistoryClicked)
        )
        clearButton.bezelStyle = .inline
        clearButton.font = Theme.caption
        clearButton.contentTintColor = Theme.danger
        clearButton.translatesAutoresizingMaskIntoConstraints = false

        let footerRow = NSStackView(views: [footer, clearButton])
        footerRow.orientation = .horizontal
        footerRow.alignment = .centerY
        footerRow.translatesAutoresizingMaskIntoConstraints = false
        footer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        statsBar.translatesAutoresizingMaskIntoConstraints = false
        let divider = NSView.divider()

        let stack = NSStackView(views: [searchField, filterControl, scrollView, footerRow, divider, statsBar])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(
            top: Theme.gutter, left: Theme.gutter, bottom: Theme.gutter, right: Theme.gutter
        )
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        root.addSubview(emptyState)

        let contentWidth = Theme.panelWidth - Theme.gutter * 2
        preferredContentSize = NSSize(width: Theme.panelWidth, height: Theme.panelHeight)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            searchField.heightAnchor.constraint(equalToConstant: 28),
            searchField.widthAnchor.constraint(equalToConstant: contentWidth),
            filterControl.heightAnchor.constraint(equalToConstant: 24),
            filterControl.widthAnchor.constraint(equalToConstant: contentWidth),
            scrollView.widthAnchor.constraint(equalToConstant: contentWidth),
            emptyState.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            emptyState.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            emptyState.topAnchor.constraint(equalTo: scrollView.topAnchor),
            emptyState.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
            footerRow.heightAnchor.constraint(equalToConstant: 20),
            footerRow.widthAnchor.constraint(equalToConstant: contentWidth),
            divider.widthAnchor.constraint(equalToConstant: contentWidth),
            statsBar.heightAnchor.constraint(equalToConstant: Theme.statsBarHeight),
            statsBar.widthAnchor.constraint(equalToConstant: contentWidth),
        ])
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        DispatchQueue.main.async { [weak self] in
            self?.statsBar.start()
        }
        if !UserDefaults.standard.bool(forKey: "hasSeenFirstRunTip") {
            UserDefaults.standard.set(true, forKey: "hasSeenFirstRunTip")
        }
        if keyMonitor == nil {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                self?.handleKey(event) ?? event
            }
        }
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        statsBar.stop()
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    func noteDataChanged() {
        if view.window?.isVisible == true {
            reload()
        } else {
            isDirty = true
        }
    }

    func prepareForDisplay() {
        if isDirty { reload() }
    }

    func reload() {
        isDirty = false
        items = Storage.shared.items(filter: filter, search: searchText)
        tableView.reloadData()
        let showEmpty = items.isEmpty
        emptyState.isHidden = !showEmpty
        scrollView.alphaValue = showEmpty ? 0.01 : 1
        footer.stringValue = showEmpty ? "" : "\(items.count) item\(items.count == 1 ? "" : "s")"
        if !items.isEmpty, tableView.selectedRow < 0 {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
    }

    func focusSearch() {
        view.window?.makeFirstResponder(searchField)
    }

    // MARK: - Actions

    @objc private func filterChanged() {
        filter = QuickFilter(rawValue: filterControl.selectedSegment) ?? .all
        reload()
    }

    @objc private func activateSelection() {
        copyRow(tableView.selectedRow)
    }

    private func itemForRow(_ row: Int) -> ClipboardItem? {
        guard row >= 0, row < items.count else { return nil }
        return Storage.shared.item(id: items[row].id) ?? items[row]
    }

    private func copyRow(_ row: Int) {
        guard let item = itemForRow(row) else { return }
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        PasteboardWriter.write(item)
        delegate?.panelDidCopyItem()
    }

    @objc private func clearHistoryClicked() {
        delegate?.panelDidRequestClearHistory()
    }

    private func togglePin(at row: Int) {
        guard row >= 0, row < items.count else { return }
        let item = items[row]
        let pinned = !(item.isPinned || item.isSnippet)
        Storage.shared.setPinned(id: item.id, pinned: pinned)
        reload()
        delegate?.panelDidChangeData()
    }

    private func saveSnippet(at row: Int) {
        guard row >= 0, row < items.count else { return }
        let item = items[row]
        let alert = NSAlert()
        alert.messageText = "Save as Snippet"
        alert.informativeText = "Optional label for this snippet:"
        alert.alertStyle = .informational
        let field = NSTextField(
            string: item.title ?? Format.truncate(item.previewText, lines: 1, maxChars: 40)
        )
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let title = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        Storage.shared.saveAsSnippet(id: item.id, title: title.isEmpty ? nil : title)
        reload()
        delegate?.panelDidChangeData()
    }

    private func deleteRow(_ row: Int) {
        guard row >= 0, row < items.count else { return }
        Storage.shared.delete(id: items[row].id)
        reload()
        delegate?.panelDidChangeData()
    }

    private func copyAs(_ format: CopyAsFormat, row: Int) {
        guard let item = itemForRow(row) else { return }
        PasteboardWriter.write(item, format: format)
        delegate?.panelDidCopyItem()
    }

    // MARK: - Keyboard

    private func handleKey(_ event: NSEvent) -> NSEvent? {
        guard view.window?.isVisible == true else { return event }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if flags.contains(.command), event.charactersIgnoringModifiers == "f" {
            focusSearch()
            return nil
        }

        if view.window?.firstResponder is NSTextView || view.window?.firstResponder is NSTextField
            || view.window?.firstResponder is NSText
        {
            if event.keyCode == 53 {
                view.window?.makeFirstResponder(tableView)
                return nil
            }
            return event
        }

        switch event.keyCode {
        case 125:
            moveSelection(1)
            return nil
        case 126:
            moveSelection(-1)
            return nil
        case 36:
            activateSelection()
            return nil
        case 53:
            delegate?.panelDidRequestClose()
            return nil
        default:
            return event
        }
    }

    private func moveSelection(_ delta: Int) {
        guard !items.isEmpty else { return }
        let current = max(0, tableView.selectedRow)
        let next = min(items.count - 1, max(0, current + delta))
        tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        tableView.scrollRowToVisible(next)
    }

    // MARK: - Search

    func controlTextDidChange(_ obj: Notification) {
        searchText = searchField.stringValue
        reload()
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int)
        -> NSView?
    {
        let id = NSUserInterfaceItemIdentifier("HistoryRow")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? HistoryRowView)
            ?? HistoryRowView()
        cell.identifier = id
        cell.configure(items[row])
        cell.onTogglePin = { [weak self] in
            self?.togglePin(at: row)
        }
        return cell
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard let item = itemForRow(row) else { return nil }
        return DragItem(item: item)
    }

    // MARK: - Context menu

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(withTitle: "Copy", action: #selector(ctxCopy), keyEquivalent: "")
        let copyAs = NSMenuItem(title: "Copy as", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.addItem(withTitle: "Plain Text", action: #selector(ctxCopyPlain), keyEquivalent: "")
        submenu.addItem(withTitle: "RTF", action: #selector(ctxCopyRTF), keyEquivalent: "")
        submenu.addItem(
            withTitle: "Markdown Link", action: #selector(ctxCopyMarkdown), keyEquivalent: ""
        )
        copyAs.submenu = submenu
        menu.addItem(copyAs)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Pin / Unpin", action: #selector(ctxPin), keyEquivalent: "")
        menu.addItem(withTitle: "Save as Snippet…", action: #selector(ctxSnippet), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Delete", action: #selector(ctxDelete), keyEquivalent: "")
        menu.items.forEach { $0.target = self }
        submenu.items.forEach { $0.target = self }
        return menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let row = tableView.clickedRow
        if row >= 0 {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
    }

    @objc private func ctxCopy() { activateSelection() }
    @objc private func ctxCopyPlain() { copyAs(.plainText, row: tableView.selectedRow) }
    @objc private func ctxCopyRTF() { copyAs(.rtf, row: tableView.selectedRow) }
    @objc private func ctxCopyMarkdown() { copyAs(.markdownLink, row: tableView.selectedRow) }
    @objc private func ctxPin() { togglePin(at: tableView.selectedRow) }
    @objc private func ctxSnippet() { saveSnippet(at: tableView.selectedRow) }
    @objc private func ctxDelete() { deleteRow(tableView.selectedRow) }
}

final class ClickCopyTableView: NSTableView {
    var onRowActivate: ((Int) -> Void)?

    override func mouseDown(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        let row = self.row(at: local)
        let hit = hitTest(local)
        super.mouseDown(with: event)
        if row >= 0, event.clickCount == 1, !(hit is NSButton) {
            onRowActivate?(row)
        }
    }
}

final class DragItem: NSObject, NSPasteboardWriting {
    let item: ClipboardItem

    init(item: ClipboardItem) {
        self.item = item
    }

    func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        switch item.type {
        case .image: return [.png, .tiff, .fileURL]
        case .file: return [.fileURL]
        case .url: return [.URL, .string]
        case .richText: return [.rtf, .html, .string]
        case .text: return [.string]
        }
    }

    func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        switch type {
        case .string:
            return item.textContent ?? item.url ?? item.previewText
        case .URL:
            return item.url ?? item.textContent
        case .html:
            return item.htmlContent
        case .rtf:
            return item.rtfContent
        case .png:
            if let url = Storage.shared.absoluteImageURL(for: item) {
                return try? Data(contentsOf: url)
            }
            return nil
        case .tiff:
            if let url = Storage.shared.absoluteImageURL(for: item),
               let data = try? Data(contentsOf: url),
               let image = NSImage(data: data)
            {
                return image.tiffRepresentation
            }
            return nil
        case .fileURL:
            if item.type == .image, let url = Storage.shared.absoluteImageURL(for: item) {
                return url.absoluteString
            }
            if let first = item.filePaths.first {
                return URL(fileURLWithPath: first).absoluteString
            }
            return nil
        default:
            return nil
        }
    }
}
