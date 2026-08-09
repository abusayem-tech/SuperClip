import AppKit

enum Theme {
    static let panelWidth: CGFloat = 360
    static let panelHeight: CGFloat = 480
    static let gutter: CGFloat = 12
    static let thumbnailHeight: CGFloat = 48

    static let title = NSFont.systemFont(ofSize: 13, weight: .semibold)
    static let body = NSFont.systemFont(ofSize: 12, weight: .regular)
    static let label = NSFont.systemFont(ofSize: 12, weight: .medium)
    static let caption = NSFont.systemFont(ofSize: 10, weight: .medium)
    static let eyebrow = NSFont.systemFont(ofSize: 10, weight: .semibold)

    static let ink = NSColor.labelColor
    static let dim = NSColor.secondaryLabelColor
    static let faint = NSColor.tertiaryLabelColor
    static let hairline = NSColor.separatorColor
    static let selected = NSColor.selectedContentBackgroundColor

    static let primary = dynamic(light: hex("#0F766E"), dark: hex("#2DD4BF"))
    static let danger = NSColor.systemRed

    static let row = dynamic(
        light: NSColor.black.withAlphaComponent(0.03),
        dark: NSColor.white.withAlphaComponent(0.06)
    )
    static let rowHover = dynamic(
        light: NSColor.black.withAlphaComponent(0.06),
        dark: NSColor.white.withAlphaComponent(0.1)
    )

    static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }

    static func hex(_ string: String) -> NSColor {
        var s = string.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6, let value = UInt32(s, radix: 16) else { return .systemTeal }
        return NSColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }
}

extension NSTextField {
    static func plain(
        _ text: String = "",
        font: NSFont,
        color: NSColor,
        align: NSTextAlignment = .left
    ) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = font
        field.textColor = color
        field.alignment = align
        field.lineBreakMode = .byTruncatingTail
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }
}

extension NSView {
    static func spacer(height: CGFloat) -> NSView {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.heightAnchor.constraint(equalToConstant: height).isActive = true
        return v
    }

    static func divider() -> NSView {
        let v = NSBox()
        v.boxType = .separator
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }
}
