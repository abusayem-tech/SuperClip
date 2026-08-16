import AppKit

enum MenubarIcon {
    /// Guaranteed-visible menubar glyph — SF Symbols can fail silently on some builds.
    static func make() -> NSImage {
        drawnIcon()
    }

    private static func drawnIcon() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.labelColor.setStroke()
        NSColor.labelColor.setFill()

        let board = NSBezierPath(roundedRect: NSRect(x: 3, y: 2, width: 12, height: 14), xRadius: 2, yRadius: 2)
        board.lineWidth = 1.6
        board.stroke()

        let clip = NSBezierPath()
        clip.move(to: NSPoint(x: 6, y: 15))
        clip.line(to: NSPoint(x: 6, y: 12))
        clip.line(to: NSPoint(x: 12, y: 12))
        clip.line(to: NSPoint(x: 12, y: 15))
        clip.close()
        clip.fill()

        image.unlockFocus()
        image.isTemplate = true
        return image
    }
}
