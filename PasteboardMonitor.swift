import AppKit
import Foundation

protocol PasteboardMonitorDelegate: AnyObject {
    func pasteboardMonitor(_ monitor: PasteboardMonitor, didCapture item: ClipboardItem)
    func pasteboardMonitor(_ monitor: PasteboardMonitor, didUpdate item: ClipboardItem)
}

final class PasteboardMonitor {
    weak var delegate: PasteboardMonitorDelegate?

    private var timer: Timer?
    private var lastChangeCount: Int = -1
    private var lastHash: String?
    private var lastHashAt: Date = .distantPast
    private var config: Config
    private let storage: Storage
    private var isCapturing = false

    init(storage: Storage = .shared, config: Config = .load()) {
        self.storage = storage
        self.config = config
    }

    func updateConfig(_ config: Config) {
        self.config = config
        restart()
    }

    func start() {
        lastChangeCount = NSPasteboard.general.changeCount
        restart()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func pollNow() {
        checkPasteboard()
    }

    private func restart() {
        timer?.invalidate()
        let interval = max(0.2, Double(config.pollIntervalMs) / 1000.0)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.checkPasteboard()
        }
        timer?.tolerance = min(0.1, interval * 0.2)
        if let timer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func checkPasteboard() {
        let pb = NSPasteboard.general
        let count = pb.changeCount
        guard count != lastChangeCount else { return }
        lastChangeCount = count
        guard !isCapturing else { return }
        isCapturing = true
        defer { isCapturing = false }

        guard let payload = capture(from: pb) else { return }

        if let bundle = payload.sourceBundleId,
           config.excludeApps.contains(where: { $0.caseInsensitiveCompare(bundle) == .orderedSame }) {
            return
        }

        let now = Date()
        if payload.contentHash == lastHash, now.timeIntervalSince(lastHashAt) < 2 {
            return
        }

        if let latest = storage.latestItem(), latest.contentHash == payload.contentHash {
            lastHash = payload.contentHash
            lastHashAt = now
            return
        }

        // Merge consecutive plain/rich text from the same app within the window.
        if shouldMerge(payload, into: storage.latestItem()) {
            if let latest = storage.latestItem(),
               let updated = storage.updateLatestText(payload, id: latest.id) {
                lastHash = payload.contentHash
                lastHashAt = now
                delegate?.pasteboardMonitor(self, didUpdate: updated)
                return
            }
        }

        guard let item = storage.insert(payload) else { return }
        lastHash = payload.contentHash
        lastHashAt = now
        delegate?.pasteboardMonitor(self, didCapture: item)
    }

    private func shouldMerge(_ payload: CapturedPayload, into latest: ClipboardItem?) -> Bool {
        guard let latest else { return false }
        guard config.mergeTextWindowMs > 0 else { return false }
        let window = TimeInterval(config.mergeTextWindowMs) / 1000.0
        guard Date().timeIntervalSince(latest.updatedAt) <= window else { return false }
        guard payload.type == .text || payload.type == .richText || payload.type == .url else {
            return false
        }
        guard latest.type == .text || latest.type == .richText || latest.type == .url else {
            return false
        }
        if let a = payload.sourceBundleId, let b = latest.sourceBundleId, a != b {
            return false
        }
        guard let newText = payload.textContent, let oldText = latest.textContent else {
            return false
        }
        // Extends previous, or previous extends new (selection shrink), or short replace.
        if newText.hasPrefix(oldText) || oldText.hasPrefix(newText) { return true }
        if newText.count <= 64, oldText.count <= 64 { return true }
        return false
    }

    private func capture(from pb: NSPasteboard) -> CapturedPayload? {
        let app = NSWorkspace.shared.frontmostApplication
        let sourceApp = app?.localizedName
        let bundleId = app?.bundleIdentifier

        // File URLs before images — Finder copies often include an icon image too.
        if let paths = readFilePaths(from: pb), !paths.isEmpty {
            let joined = paths.joined(separator: "\n")
            let hash = Format.sha256Hex(Data(joined.utf8))
            return CapturedPayload(
                type: .file,
                textContent: paths.map { URL(fileURLWithPath: $0).lastPathComponent }
                    .joined(separator: ", "),
                htmlContent: nil,
                rtfContent: nil,
                url: nil,
                filePaths: paths,
                imageData: nil,
                contentHash: hash,
                sourceApp: sourceApp,
                sourceBundleId: bundleId
            )
        }

        if let imageData = readImageData(from: pb) {
            let hash = Format.sha256Hex(imageData)
            return CapturedPayload(
                type: .image,
                textContent: nil,
                htmlContent: nil,
                rtfContent: nil,
                url: nil,
                filePaths: [],
                imageData: imageData,
                contentHash: hash,
                sourceApp: sourceApp,
                sourceBundleId: bundleId
            )
        }

        let rtf = pb.data(forType: .rtf)
        let html = pb.string(forType: .html)
        let string = pb.string(forType: .string)
        let urlString = readURL(from: pb) ?? string.flatMap { looksLikeURL($0) ? $0 : nil }

        if let urlString, looksLikeURL(urlString), rtf == nil {
            let hash = Format.sha256Hex(Data(urlString.utf8))
            return CapturedPayload(
                type: .url,
                textContent: urlString,
                htmlContent: html,
                rtfContent: nil,
                url: urlString,
                filePaths: [],
                imageData: nil,
                contentHash: hash,
                sourceApp: sourceApp,
                sourceBundleId: bundleId
            )
        }

        if rtf != nil || html != nil {
            let plain = string ?? ""
            var hashData = Data()
            if let rtf { hashData.append(rtf) }
            if let html { hashData.append(Data(html.utf8)) }
            hashData.append(Data(plain.utf8))
            return CapturedPayload(
                type: .richText,
                textContent: plain.isEmpty ? nil : plain,
                htmlContent: html,
                rtfContent: rtf,
                url: urlString,
                filePaths: [],
                imageData: nil,
                contentHash: Format.sha256Hex(hashData),
                sourceApp: sourceApp,
                sourceBundleId: bundleId
            )
        }

        if let string, !string.isEmpty {
            return CapturedPayload(
                type: .text,
                textContent: string,
                htmlContent: nil,
                rtfContent: nil,
                url: nil,
                filePaths: [],
                imageData: nil,
                contentHash: Format.sha256Hex(Data(string.utf8)),
                sourceApp: sourceApp,
                sourceBundleId: bundleId
            )
        }

        return nil
    }

    private func readImageData(from pb: NSPasteboard) -> Data? {
        // Prefer PNG; convert TIFF when needed.
        if let png = pb.data(forType: .png), !png.isEmpty {
            return png
        }
        if let tiff = pb.data(forType: .tiff), !tiff.isEmpty {
            if let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                return png
            }
        }
        // Some apps put images as NSImage pasteboard contents.
        if let image = NSImage(pasteboard: pb),
           let tiff = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            // Avoid treating file icons / tiny placeholder as images when files are present.
            if pb.readObjects(forClasses: [NSURL.self], options: [
                .urlReadingFileURLsOnly: true
            ]) != nil {
                let urls = pb.readObjects(forClasses: [NSURL.self], options: [
                    .urlReadingFileURLsOnly: true
                ]) as? [URL]
                if let urls, !urls.isEmpty { return nil }
            }
            return png
        }
        return nil
    }

    private func readFilePaths(from pb: NSPasteboard) -> [String]? {
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true
        ]) as? [URL], !urls.isEmpty {
            return urls.map(\.path)
        }
        if let items = pb.propertyList(forType: .fileURL) as? String {
            if let url = URL(string: items), url.isFileURL { return [url.path] }
        }
        // Legacy filenames pasteboard type
        if let names = pb.propertyList(forType: NSPasteboard.PasteboardType("NSFilenamesPboardType"))
            as? [String], !names.isEmpty {
            return names
        }
        return nil
    }

    private func readURL(from pb: NSPasteboard) -> String? {
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
           let first = urls.first, !first.isFileURL {
            return first.absoluteString
        }
        if let s = pb.string(forType: .URL) { return s }
        return nil
    }

    private func looksLikeURL(_ string: String) -> Bool {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(where: \.isNewline), trimmed.count < 2048 else { return false }
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() else {
            return false
        }
        return ["http", "https", "ftp", "mailto"].contains(scheme)
    }
}

enum PasteboardWriter {
    static func write(_ item: ClipboardItem, format: CopyAsFormat? = nil) {
        let pb = NSPasteboard.general
        pb.clearContents()

        if let format {
            switch format {
            case .plainText:
                let text = item.textContent ?? item.url ?? item.previewText
                pb.setString(text, forType: .string)
                return
            case .rtf:
                if let rtf = item.rtfContent {
                    pb.setData(rtf, forType: .rtf)
                    if let text = item.textContent { pb.setString(text, forType: .string) }
                    return
                }
                let text = item.textContent ?? item.url ?? item.previewText
                pb.setString(text, forType: .string)
                return
            case .markdownLink:
                let url = item.url ?? item.textContent ?? ""
                let title = item.title ?? item.textContent ?? url
                pb.setString("[\(title)](\(url))", forType: .string)
                return
            }
        }

        switch item.type {
        case .image:
            if let url = Storage.shared.absoluteImageURL(for: item),
               let data = try? Data(contentsOf: url) {
                pb.setData(data, forType: .png)
                if let tiff = NSImage(data: data)?.tiffRepresentation {
                    pb.setData(tiff, forType: .tiff)
                }
            }
        case .file:
            let urls = item.filePaths.map { URL(fileURLWithPath: $0) as NSURL }
            pb.writeObjects(urls)
        case .url:
            if let urlString = item.url ?? item.textContent {
                pb.setString(urlString, forType: .string)
                if let url = URL(string: urlString) {
                    pb.writeObjects([url as NSURL])
                }
            }
        case .richText:
            if let rtf = item.rtfContent { pb.setData(rtf, forType: .rtf) }
            if let html = item.htmlContent { pb.setString(html, forType: .html) }
            if let text = item.textContent { pb.setString(text, forType: .string) }
        case .text:
            if let text = item.textContent { pb.setString(text, forType: .string) }
        }
    }

    static func clearSystemPasteboard() {
        NSPasteboard.general.clearContents()
    }
}
