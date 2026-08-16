import AppKit
import ImageIO

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

        let token = item.id
        thumb.image = ThumbnailCache.image(for: item) { [weak self] image in
            guard self?.item?.id == token else { return }
            self?.thumb.image = image
        }
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

enum ThumbnailCache {
    private static let images = NSCache<NSString, NSImage>()
    private static let queue = DispatchQueue(
        label: "dev.nasimulhasan.superclip.thumbs",
        qos: .userInitiated
    )

    static func image(for item: ClipboardItem, completion: @escaping (NSImage) -> Void) -> NSImage? {
        switch item.type {
        case .image:
            if let rel = item.imagePath, let cached = images.object(forKey: rel as NSString) {
                return cached
            }
            let placeholder = NSImage(systemSymbolName: "photo", accessibilityDescription: nil)
            guard let rel = item.imagePath,
                  let url = Storage.shared.absoluteImageURL(for: item)
            else {
                return placeholder
            }
            queue.async {
                guard let thumb = makeThumbnail(at: url) else { return }
                images.setObject(thumb, forKey: rel as NSString)
                DispatchQueue.main.async { completion(thumb) }
            }
            return placeholder
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

    private static func makeThumbnail(at url: URL) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let maxPixel = Theme.thumbnailHeight * 2
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        return NSImage(
            cgImage: cg,
            size: NSSize(width: CGFloat(cg.width) / 2, height: CGFloat(cg.height) / 2)
        )
    }
}

final class StatMeterView: NSView {
    private let iconView = NSImageView()
    private let nameLabel = NSTextField.plain(font: Theme.eyebrow, color: Theme.dim, align: .center)
    private let valueLabel = NSTextField.plain(
        font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium),
        color: Theme.ink,
        align: .center
    )

    init(title: String, symbols: [String]) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        nameLabel.stringValue = title
        iconView.image = Self.symbolImage(symbols, title: title)
        iconView.imageScaling = .scaleProportionallyDown
        iconView.contentTintColor = Theme.ink
        iconView.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        valueLabel.translatesAutoresizingMaskIntoConstraints = false
        valueLabel.maximumNumberOfLines = 2
        valueLabel.cell?.wraps = false
        valueLabel.lineBreakMode = .byClipping
        valueLabel.alignment = .center
        nameLabel.alignment = .center
        addSubview(iconView)
        addSubview(nameLabel)
        addSubview(valueLabel)
        NSLayoutConstraint.activate([
            iconView.topAnchor.constraint(equalTo: topAnchor),
            iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconView.heightAnchor.constraint(equalToConstant: 14),
            iconView.widthAnchor.constraint(equalToConstant: 14),
            nameLabel.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 2),
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            nameLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            valueLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 1),
            valueLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            valueLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            valueLabel.bottomAnchor.constraint(equalTo: bottomAnchor),
            valueLabel.heightAnchor.constraint(equalToConstant: 28),
        ])
        setAccessibilityLabel(title)
        setAccessibilityRole(.staticText)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setValue(_ text: String) {
        valueLabel.stringValue = text
    }

    private static func symbolImage(_ names: [String], title: String) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        for name in names {
            if let image = NSImage(systemSymbolName: name, accessibilityDescription: title)?
                .withSymbolConfiguration(config)
            {
                return image
            }
        }
        return NSImage(systemSymbolName: "questionmark.square", accessibilityDescription: title)
            ?? NSImage()
    }
}

final class StatsBarView: NSView {
    private let sampler = SystemStats()
    private let meters: [StatMeterView]
    private let netMeter: StatMeterView
    private let memMeter: StatMeterView
    private let cpuMeter: StatMeterView
    private let diskMeter: StatMeterView
    private let gpuMeter: StatMeterView
    private let ipLabel = NSTextField.plain(
        font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
        color: Theme.ink,
        align: .left
    )
    private let copyIPButton = NSButton()
    private var displayedIP = ""
    private var publicIP: String?
    private var lastPublicIPAt: TimeInterval = 0
    private var timer: Timer?

    override init(frame frameRect: NSRect) {
        netMeter = StatMeterView(title: "NET", symbols: ["arrow.up.arrow.down"])
        memMeter = StatMeterView(title: "MEM", symbols: ["memorychip", "memorychip.fill"])
        cpuMeter = StatMeterView(title: "CPU", symbols: ["cpu", "cpu.fill"])
        diskMeter = StatMeterView(title: "DISK", symbols: ["internaldrive", "externaldrive"])
        gpuMeter = StatMeterView(
            title: "GPU",
            symbols: [
                "gpu",
                "gpu.fill",
                "rectangle.3.group.fill",
                "square.3.layers.3d",
                "cube.fill",
                "display",
            ]
        )
        meters = [netMeter, memMeter, cpuMeter, diskMeter, gpuMeter]
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        netMeter.toolTip = "Live download / upload (Mbps)"
        memMeter.toolTip = "Memory usage"
        cpuMeter.toolTip = "CPU usage"
        diskMeter.toolTip = "Disk storage usage"
        gpuMeter.toolTip = "GPU usage"

        let meterRow = NSView()
        meterRow.translatesAutoresizingMaskIntoConstraints = false
        var previous: NSView?
        for meter in meters {
            meterRow.addSubview(meter)
            NSLayoutConstraint.activate([
                meter.topAnchor.constraint(equalTo: meterRow.topAnchor),
                meter.bottomAnchor.constraint(equalTo: meterRow.bottomAnchor),
            ])
            if let previous {
                meter.leadingAnchor.constraint(equalTo: previous.trailingAnchor).isActive = true
                meter.widthAnchor.constraint(equalTo: previous.widthAnchor).isActive = true
            } else {
                meter.leadingAnchor.constraint(equalTo: meterRow.leadingAnchor).isActive = true
            }
            previous = meter
        }
        meters.last?.trailingAnchor.constraint(equalTo: meterRow.trailingAnchor).isActive = true

        let ipTitle = NSTextField.plain(font: Theme.eyebrow, color: Theme.dim, align: .center)
        ipTitle.stringValue = "IP"
        ipLabel.alignment = .center
        ipLabel.lineBreakMode = .byClipping
        ipLabel.setContentHuggingPriority(.required, for: .horizontal)
        ipLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let copyConfig = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        copyIPButton.image = NSImage(
            systemSymbolName: "doc.on.doc",
            accessibilityDescription: "Copy IP"
        )?.withSymbolConfiguration(copyConfig)
        copyIPButton.imagePosition = .imageOnly
        copyIPButton.isBordered = false
        copyIPButton.bezelStyle = .shadowlessSquare
        copyIPButton.target = self
        copyIPButton.action = #selector(copyIP)
        copyIPButton.toolTip = "Copy IP address"
        copyIPButton.contentTintColor = Theme.ink
        copyIPButton.focusRingType = .none
        copyIPButton.translatesAutoresizingMaskIntoConstraints = false

        let ipCluster = NSStackView(views: [ipTitle, ipLabel, copyIPButton])
        ipCluster.orientation = .horizontal
        ipCluster.alignment = .centerY
        ipCluster.spacing = 8
        ipCluster.translatesAutoresizingMaskIntoConstraints = false

        let ipRow = NSView()
        ipRow.translatesAutoresizingMaskIntoConstraints = false
        ipRow.addSubview(ipCluster)
        NSLayoutConstraint.activate([
            ipCluster.centerXAnchor.constraint(equalTo: ipRow.centerXAnchor),
            ipCluster.centerYAnchor.constraint(equalTo: ipRow.centerYAnchor),
            ipCluster.leadingAnchor.constraint(greaterThanOrEqualTo: ipRow.leadingAnchor),
            ipCluster.trailingAnchor.constraint(lessThanOrEqualTo: ipRow.trailingAnchor),
            copyIPButton.widthAnchor.constraint(equalToConstant: 18),
            copyIPButton.heightAnchor.constraint(equalToConstant: 18),
        ])

        addSubview(meterRow)
        addSubview(ipRow)
        NSLayoutConstraint.activate([
            meterRow.leadingAnchor.constraint(equalTo: leadingAnchor),
            meterRow.trailingAnchor.constraint(equalTo: trailingAnchor),
            meterRow.topAnchor.constraint(equalTo: topAnchor),
            ipRow.leadingAnchor.constraint(equalTo: leadingAnchor),
            ipRow.trailingAnchor.constraint(equalTo: trailingAnchor),
            ipRow.topAnchor.constraint(equalTo: meterRow.bottomAnchor, constant: 6),
            ipRow.bottomAnchor.constraint(equalTo: bottomAnchor),
            ipRow.heightAnchor.constraint(equalToConstant: 18),
        ])
    }

    func start() {
        apply(sampler.snapshot())
        timer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.apply(self.sampler.snapshot())
        }
        timer.tolerance = 0.05
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func apply(_ snap: SystemSnapshot) {
        netMeter.setValue(
            "↓\(Format.compactRate(snap.networkDownBytesPerSec))\n↑\(Format.compactRate(snap.networkUpBytesPerSec))"
        )
        memMeter.setValue(Format.percent(snap.memoryPercent))
        cpuMeter.setValue(Format.percent(snap.cpuPercent))
        diskMeter.setValue(Format.percent(snap.diskPercent))
        gpuMeter.setValue(Format.percent(snap.gpuPercent))
        refreshPublicIPIfNeeded()
        displayedIP = publicIP ?? snap.localIPv4
        ipLabel.stringValue = displayedIP
        ipLabel.toolTip = publicIP == nil
            ? "This Mac’s current IPv4 address"
            : "Public IP. Local: \(snap.localIPv4)"
    }

    private func refreshPublicIPIfNeeded() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastPublicIPAt > 30 else { return }
        lastPublicIPAt = now
        guard let url = URL(string: "https://api.ipify.org") else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 4
        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            guard let data,
                  let text = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty,
                  text.count <= 45
            else { return }
            DispatchQueue.main.async {
                self?.publicIP = text
            }
        }.resume()
    }

    @objc private func copyIP() {
        guard !displayedIP.isEmpty, displayedIP != "—" else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(displayedIP, forType: .string)
        copyIPButton.toolTip = "Copied"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.copyIPButton.toolTip = "Copy IP address"
        }
    }
}
