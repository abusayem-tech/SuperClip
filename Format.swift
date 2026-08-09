import CommonCrypto
import Foundation

struct Config: Codable, Equatable {
    var retentionDays: Int
    var maxStorageMB: Int
    var excludeApps: [String]
    var menubarMode: MenubarMode
    var pollIntervalMs: Int
    var mergeTextWindowMs: Int

    static let `default` = Config(
        retentionDays: 30,
        maxStorageMB: 500,
        excludeApps: [],
        menubarMode: .iconOnly,
        pollIntervalMs: 500,
        mergeTextWindowMs: 1500
    )

    static var path: URL {
        if let override = ProcessInfo.processInfo.environment["SUPERCLIP_CONFIG"] {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/superclip/config.json")
    }

    static func load() -> Config {
        let url = path
        guard FileManager.default.fileExists(atPath: url.path) else {
            let cfg = Config.default
            try? cfg.save()
            return cfg
        }
        do {
            let data = try Data(contentsOf: url)
            var decoded = try JSONDecoder().decode(Config.self, from: data)
            decoded.retentionDays = max(1, decoded.retentionDays)
            decoded.maxStorageMB = max(10, decoded.maxStorageMB)
            decoded.pollIntervalMs = max(200, decoded.pollIntervalMs)
            decoded.mergeTextWindowMs = max(0, decoded.mergeTextWindowMs)
            return decoded
        } catch {
            return .default
        }
    }

    func save() throws {
        let url = Config.path
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }
}

enum Format {
    static func relativeTime(_ date: Date, now: Date = Date()) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 45 { return "just now" }
        if seconds < 3600 { return "\(max(1, seconds / 60))m ago" }
        if seconds < 86_400 { return "\(seconds / 3600)h ago" }
        let calendar = Calendar.current
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        if seconds < 86_400 * 7 { return "\(seconds / 86_400)d ago" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    static func truncate(_ text: String, lines: Int = 2, maxChars: Int = 160) -> String {
        let collapsed = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var result = ""
        var lineCount = 0
        for (index, char) in collapsed.enumerated() {
            if index >= maxChars {
                result += "…"
                break
            }
            if char == "\n" {
                lineCount += 1
                if lineCount >= lines {
                    result += "…"
                    break
                }
            }
            result.append(char)
        }
        return result
    }

    static func bytesString(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        return formatter.string(fromByteCount: bytes)
    }

    static func sha256Hex(_ data: Data) -> String {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { buffer in
            _ = CC_SHA256(buffer.baseAddress, CC_LONG(data.count), &digest)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
