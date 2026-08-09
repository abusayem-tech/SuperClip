import Foundation

enum ItemType: String, CaseIterable {
    case text
    case url
    case richText
    case image
    case file

    var displayName: String {
        switch self {
        case .text: return "Text"
        case .url: return "URL"
        case .richText: return "Rich Text"
        case .image: return "Image"
        case .file: return "File"
        }
    }
}

enum QuickFilter: Int, CaseIterable {
    case all = 0
    case text
    case image
    case url
    case files
    case pinned

    var title: String {
        switch self {
        case .all: return "All"
        case .text: return "Text"
        case .image: return "Image"
        case .url: return "URL"
        case .files: return "Files"
        case .pinned: return "Pinned"
        }
    }
}

enum MenubarMode: String, CaseIterable, Codable {
    case iconOnly
    case lastText
    case count

    var displayName: String {
        switch self {
        case .iconOnly: return "Icon only"
        case .lastText: return "Last text"
        case .count: return "Item count"
        }
    }
}

enum CopyAsFormat {
    case plainText
    case rtf
    case markdownLink
}

struct ClipboardItem: Equatable {
    var id: Int64
    var type: ItemType
    var textContent: String?
    var htmlContent: String?
    var rtfContent: Data?
    var url: String?
    var filePaths: [String]
    var imagePath: String?
    var contentHash: String
    var sourceApp: String?
    var sourceBundleId: String?
    var isPinned: Bool
    var isSnippet: Bool
    var title: String?
    var createdAt: Date
    var updatedAt: Date

    var previewText: String {
        if let title, !title.isEmpty, isSnippet { return title }
        switch type {
        case .image:
            return "Image"
        case .file:
            if filePaths.isEmpty { return "File" }
            let names = filePaths.map { URL(fileURLWithPath: $0).lastPathComponent }
            if names.count == 1 { return names[0] }
            return "\(names[0]) +\(names.count - 1)"
        case .url:
            return url ?? textContent ?? "URL"
        case .text, .richText:
            let raw = textContent?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return raw.isEmpty ? type.displayName : raw
        }
    }

    var menubarPreview: String {
        let raw = previewText.replacingOccurrences(of: "\n", with: " ")
        if raw.count <= 20 { return raw }
        return String(raw.prefix(19)) + "…"
    }
}

struct StorageStats {
    var usedBytes: Int64
    var itemCount: Int
    var imageCount: Int
    var maxBytes: Int64

    var usedMB: Double { Double(usedBytes) / 1_048_576 }
    var maxMB: Double { Double(maxBytes) / 1_048_576 }
    var fraction: Double {
        guard maxBytes > 0 else { return 0 }
        return min(1, Double(usedBytes) / Double(maxBytes))
    }
}

/// Draft captured from the pasteboard before persistence.
struct CapturedPayload {
    var type: ItemType
    var textContent: String?
    var htmlContent: String?
    var rtfContent: Data?
    var url: String?
    var filePaths: [String]
    var imageData: Data?
    var contentHash: String
    var sourceApp: String?
    var sourceBundleId: String?
}
