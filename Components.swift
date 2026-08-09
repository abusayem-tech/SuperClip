import AppKit

final class HistoryRowView: NSTableCellView {
    var onTogglePin: (() -> Void)?
    var item: ClipboardItem?

    private let thumb = NSImageView()
    private let preview = NSTextField.plain(font: Theme.body, color: Theme.ink)
    private let meta = NSTextField.plain(font: Theme.caption, color: Theme.faint)
    private let pinButton = NSButton()
    private let badge = NSTextField.plain(font: Theme.caption, color: Theme.primary)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        thumb.imageScaling = .scaleProportionallyUpOrDown
        thumb.wantsLayer = true
        thumb.layer?.cornerRadius = 4
        thumb.layer?.masksToBounds = true
        thumb.translatesAutoresizingMaskIntoConstraints = false

        preview.maximumNumberOfLines = 2
        preview.cell?.wraps = true
        preview.cell?.truncatesLastVisibleLine = true
        preview.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        pinButton.bezelStyle = .inline
        pinButton.isBordered = false
        pinButton.imagePosition = .imageOnly
        pinButton.target = self
        pinButton.action = #selector(pinClicked)
        pinButton.translatesAutoresizingMaskIntoConstraints = false
        pinButton.setContentHuggingPriority(.required, for: .horizontal)

        badge.setContentHuggingPriority(.required, for: .horizontal)

        let textStack = NSStackView(views: [preview, meta])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        textStack.translatesAutoresizingMaskIntoConstraints = false

        let rightStack = NSStackView(views: [badge, pinButton])
        rightStack.orientation = .vertical
        rightStack.alignment = .trailing
        rightStack.spacing = 4
        rightStack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(thumb)
        addSubview(textStack)
        addSubview(rightStack)

        NSLayoutConstraint.activate([
            thumb.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            thumb.centerYAnchor.constraint(equalTo: centerYAnchor),
            thumb.widthAnchor.constraint(equalToConstant: Theme.thumbnailHeight),
            thumb.heightAnchor.constraint(equalToConstant: Theme.thumbnailHeight),

            textStack.leadingAnchor.constraint(equalTo: thumb.trailingAnchor, constant: 8),
            textStack.trailingAnchor.constraint(equalTo: rightStack.leadingAnchor, constant: -8),
            textStack.centerYAnchor.constraint(equalTo: centerYAnchor),

            rightStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            rightStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            rightStack.widthAnchor.constraint(equalToConstant: 36),

            heightAnchor.constraint(greaterThanOrEqualToConstant: 56),
        ])
    }

    func configure(_ item: ClipboardItem) {
        self.item = item
        preview.stringValue = Format.truncate(item.previewText)
        var metaParts = [Format.relativeTime(item.createdAt), item.type.displayName]
        if let app = item.sourceApp, !app.isEmpty { metaParts.append(app) }
        meta.stringValue = metaParts.joined(separator: " · ")

        if item.isSnippet {
            badge.stringValue = "Snippet"
            badge.isHidden = false
        } else {
            badge.stringValue = ""
            badge.isHidden = true
        }

        let pinName = item.isPinned || item.isSnippet ? "star.fill" : "star"
        pinButton.image = NSImage(systemSymbolName: pinName, accessibilityDescription: "Pin")
        pinButton.contentTintColor = (item.isPinned || item.isSnippet) ? Theme.primary : Theme.faint

        thumb.image = thumbnail(for: item)
    }

    private func thumbnail(for item: ClipboardItem) -> NSImage? {
        switch item.type {
        case .image:
            if let url = Storage.shared.absoluteImageURL(for: item),
               let image = NSImage(contentsOf: url) {
                return resized(image, maxHeight: Theme.thumbnailHeight)
            }
            return NSImage(systemSymbolName: "photo", accessibilityDescription: nil)
        case .url:
            return NSImage(systemSymbolName: "link", accessibilityDescription: nil)
        case .file:
            return NSImage(systemSymbolName: "doc", accessibilityDescription: nil)
        case .richText:
            return NSImage(systemSymbolName: "doc.richtext", accessibilityDescription: nil)
        case .text:
            return NSImage(systemSymbolName: "text.alignleft", accessibilityDescription: nil)
        }
    }

    private func resized(_ image: NSImage, maxHeight: CGFloat) -> NSImage {
        let size = image.size
        guard size.height > 0 else { return image }
        let scale = maxHeight / size.height
        let newSize = NSSize(width: max(1, size.width * scale), height: maxHeight)
        let result = NSImage(size: newSize)
        result.lockFocus()
        image.draw(
            in: NSRect(origin: .zero, size: newSize),
            from: NSRect(origin: .zero, size: size),
            operation: .copy,
            fraction: 1
        )
        result.unlockFocus()
        return result
    }

    @objc private func pinClicked() {
        onTogglePin?()
    }
}

final class EmptyStateView: NSView {
    private let label = NSTextField.plain(font: Theme.body, color: Theme.dim, align: .center)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.stringValue =
            "Copy anything — it shows up here.\n⌘F to search. Pin or Save as Snippet to keep forever."
        label.maximumNumberOfLines = 0
        label.cell?.wraps = true
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
