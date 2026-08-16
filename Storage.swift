import Foundation
import SQLite3

final class Storage {
    static let shared = Storage()

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "dev.nasimulhasan.superclip.storage")
    private let fm = FileManager.default

    var supportDirectory: URL {
        let url = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("SuperClip", isDirectory: true)
        try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    var imagesDirectory: URL {
        let url = supportDirectory.appendingPathComponent("images", isDirectory: true)
        try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private var dbURL: URL {
        supportDirectory.appendingPathComponent("history.db")
    }

    private init() {
        open()
        migrate()
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    // MARK: - Open / schema

    private func open() {
        if sqlite3_open(dbURL.path, &db) != SQLITE_OK {
            assertionFailure("Failed to open SuperClip database")
        }
        exec("PRAGMA journal_mode=WAL;")
        exec("PRAGMA foreign_keys=ON;")
    }

    private func migrate() {
        exec("""
        CREATE TABLE IF NOT EXISTS items (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          type TEXT NOT NULL,
          text_content TEXT,
          html_content TEXT,
          rtf_content BLOB,
          url TEXT,
          file_paths TEXT,
          image_path TEXT,
          content_hash TEXT NOT NULL,
          source_app TEXT,
          source_bundle_id TEXT,
          is_pinned INTEGER NOT NULL DEFAULT 0,
          is_snippet INTEGER NOT NULL DEFAULT 0,
          title TEXT,
          created_at REAL NOT NULL,
          updated_at REAL NOT NULL
        );
        """)
        exec("CREATE INDEX IF NOT EXISTS idx_items_created_at ON items(created_at);")
        exec("CREATE INDEX IF NOT EXISTS idx_items_hash ON items(content_hash);")
        exec("CREATE INDEX IF NOT EXISTS idx_items_type ON items(type);")
        exec("CREATE INDEX IF NOT EXISTS idx_items_pinned ON items(is_pinned);")
        exec("CREATE INDEX IF NOT EXISTS idx_items_snippet ON items(is_snippet);")
    }

    // MARK: - Insert / update

    @discardableResult
    func insert(_ payload: CapturedPayload) -> ClipboardItem? {
        queue.sync {
            var imageRel: String?
            if let data = payload.imageData {
                let name = UUID().uuidString + ".png"
                let url = imagesDirectory.appendingPathComponent(name)
                do {
                    try data.write(to: url, options: .atomic)
                    imageRel = "images/\(name)"
                } catch {
                    return nil
                }
            }

            let now = Date().timeIntervalSince1970
            let pathsJSON = encodePaths(payload.filePaths)
            let sql = """
            INSERT INTO items (
              type, text_content, html_content, rtf_content, url, file_paths, image_path,
              content_hash, source_app, source_bundle_id, is_pinned, is_snippet, title,
              created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, 0, NULL, ?, ?);
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }

            bindText(stmt, 1, payload.type.rawValue)
            bindText(stmt, 2, payload.textContent)
            bindText(stmt, 3, payload.htmlContent)
            bindBlob(stmt, 4, payload.rtfContent)
            bindText(stmt, 5, payload.url)
            bindText(stmt, 6, pathsJSON)
            bindText(stmt, 7, imageRel)
            bindText(stmt, 8, payload.contentHash)
            bindText(stmt, 9, payload.sourceApp)
            bindText(stmt, 10, payload.sourceBundleId)
            sqlite3_bind_double(stmt, 11, now)
            sqlite3_bind_double(stmt, 12, now)

            guard sqlite3_step(stmt) == SQLITE_DONE else {
                if let imageRel {
                    try? fm.removeItem(at: supportDirectory.appendingPathComponent(imageRel))
                }
                return nil
            }
            let id = sqlite3_last_insert_rowid(db)
            return fetchItem(id: id)
        }
    }

    @discardableResult
    func updateLatestText(_ payload: CapturedPayload, id: Int64) -> ClipboardItem? {
        queue.sync {
            let now = Date().timeIntervalSince1970
            let sql = """
            UPDATE items SET
              text_content = ?, html_content = ?, rtf_content = ?, url = ?,
              content_hash = ?, type = ?, updated_at = ?, created_at = ?
            WHERE id = ?;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, payload.textContent)
            bindText(stmt, 2, payload.htmlContent)
            bindBlob(stmt, 3, payload.rtfContent)
            bindText(stmt, 4, payload.url)
            bindText(stmt, 5, payload.contentHash)
            bindText(stmt, 6, payload.type.rawValue)
            sqlite3_bind_double(stmt, 7, now)
            sqlite3_bind_double(stmt, 8, now)
            sqlite3_bind_int64(stmt, 9, id)
            guard sqlite3_step(stmt) == SQLITE_DONE else { return nil }
            return fetchItem(id: id)
        }
    }

    func latestItem() -> ClipboardItem? {
        queue.sync {
            fetchOne("SELECT * FROM items ORDER BY created_at DESC, id DESC LIMIT 1;")
        }
    }

    // MARK: - Query

    func item(id: Int64) -> ClipboardItem? {
        queue.sync { fetchItem(id: id) }
    }

    func items(
        filter: QuickFilter,
        search: String,
        limit: Int = 500
    ) -> [ClipboardItem] {
        queue.sync {
            // Skip html/rtf blobs so opening the panel stays instant.
            var sql = """
            SELECT id, type, substr(text_content, 1, 400), NULL, NULL, url, file_paths,
                   image_path, content_hash, source_app, source_bundle_id, is_pinned,
                   is_snippet, title, created_at, updated_at
            FROM items WHERE 1=1
            """
            var args: [Any] = []

            switch filter {
            case .all:
                break
            case .text:
                sql += " AND type IN ('text','richText')"
            case .image:
                sql += " AND type = 'image'"
            case .url:
                sql += " AND type = 'url'"
            case .files:
                sql += " AND type = 'file'"
            case .pinned:
                sql += " AND (is_pinned = 1 OR is_snippet = 1)"
            }

            let trimmed = search.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                sql += " AND (IFNULL(text_content,'') LIKE ? OR IFNULL(url,'') LIKE ? OR IFNULL(title,'') LIKE ? OR IFNULL(file_paths,'') LIKE ?)"
                let pattern = "%\(trimmed)%"
                args.append(contentsOf: [pattern, pattern, pattern, pattern])
            }

            sql += " ORDER BY created_at DESC, id DESC LIMIT \(limit);"

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            for (i, arg) in args.enumerated() {
                if let s = arg as? String {
                    bindText(stmt, Int32(i + 1), s)
                }
            }

            var results: [ClipboardItem] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let item = rowToItem(stmt) { results.append(item) }
            }
            return results
        }
    }

    func itemCount() -> Int {
        queue.sync {
            Int(scalarInt("SELECT COUNT(*) FROM items;"))
        }
    }

    // MARK: - Pin / snippet / delete

    func setPinned(id: Int64, pinned: Bool) {
        queue.sync {
            exec("UPDATE items SET is_pinned = \(pinned ? 1 : 0) WHERE id = \(id);")
        }
    }

    func saveAsSnippet(id: Int64, title: String?) {
        queue.sync {
            let sql = "UPDATE items SET is_snippet = 1, is_pinned = 1, title = ? WHERE id = ?;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, title)
            sqlite3_bind_int64(stmt, 2, id)
            _ = sqlite3_step(stmt)
        }
    }

    func setSnippetTitle(id: Int64, title: String?) {
        queue.sync {
            let sql = "UPDATE items SET title = ? WHERE id = ?;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, title)
            sqlite3_bind_int64(stmt, 2, id)
            _ = sqlite3_step(stmt)
        }
    }

    func delete(id: Int64) {
        queue.sync {
            if let item = fetchItem(id: id), let rel = item.imagePath {
                try? fm.removeItem(at: supportDirectory.appendingPathComponent(rel))
            }
            exec("DELETE FROM items WHERE id = \(id);")
        }
    }

    // MARK: - Clear / prune

    /// Clears unpinned non-snippet history, deletes image files, VACUUMs.
    func clearHistory() {
        queue.sync {
            let paths = imagePaths(where: "is_pinned = 0 AND is_snippet = 0")
            exec("DELETE FROM items WHERE is_pinned = 0 AND is_snippet = 0;")
            removeImageFiles(paths)
            vacuum()
        }
    }

    /// Clears everything including pins/snippets.
    func clearEverything() {
        queue.sync {
            exec("DELETE FROM items;")
            if let contents = try? fm.contentsOfDirectory(
                at: imagesDirectory,
                includingPropertiesForKeys: nil
            ) {
                for url in contents { try? fm.removeItem(at: url) }
            }
            vacuum()
        }
    }

    func prune(retentionDays: Int, maxStorageMB: Int) {
        queue.sync {
            let cutoff = Date().addingTimeInterval(-TimeInterval(retentionDays) * 86_400)
                .timeIntervalSince1970
            let expiredPaths = imagePaths(
                where: "is_pinned = 0 AND is_snippet = 0 AND created_at < \(cutoff)"
            )
            exec("""
            DELETE FROM items
            WHERE is_pinned = 0 AND is_snippet = 0 AND created_at < \(cutoff);
            """)
            removeImageFiles(expiredPaths)

            let maxBytes = Int64(maxStorageMB) * 1_048_576
            while directorySize() > maxBytes {
                guard let victim = fetchOne("""
                SELECT * FROM items
                WHERE is_pinned = 0 AND is_snippet = 0
                ORDER BY created_at ASC, id ASC LIMIT 1;
                """) else { break }
                if let rel = victim.imagePath {
                    try? fm.removeItem(at: supportDirectory.appendingPathComponent(rel))
                }
                exec("DELETE FROM items WHERE id = \(victim.id);")
            }
            unlinkOrphanImages()
        }
    }

    func stats(maxStorageMB: Int) -> StorageStats {
        queue.sync {
            StorageStats(
                usedBytes: directorySize(),
                itemCount: Int(scalarInt("SELECT COUNT(*) FROM items;")),
                imageCount: Int(scalarInt("SELECT COUNT(*) FROM items WHERE type = 'image';")),
                maxBytes: Int64(maxStorageMB) * 1_048_576
            )
        }
    }

    // MARK: - Internals

    private func vacuum() {
        exec("VACUUM;")
    }

    private func unlinkOrphanImages() {
        guard let files = try? fm.contentsOfDirectory(
            at: imagesDirectory,
            includingPropertiesForKeys: nil
        ) else { return }
        let used = Set(imagePaths(where: "image_path IS NOT NULL").map {
            ($0 as NSString).lastPathComponent
        })
        for file in files where !used.contains(file.lastPathComponent) {
            try? fm.removeItem(at: file)
        }
    }

    private func imagePaths(where clause: String) -> [String] {
        var stmt: OpaquePointer?
        let sql = "SELECT image_path FROM items WHERE \(clause) AND image_path IS NOT NULL;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var paths: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let c = sqlite3_column_text(stmt, 0) {
                paths.append(String(cString: c))
            }
        }
        return paths
    }

    private func removeImageFiles(_ relativePaths: [String]) {
        for rel in relativePaths {
            try? fm.removeItem(at: supportDirectory.appendingPathComponent(rel))
        }
    }

    private func directorySize() -> Int64 {
        var total: Int64 = 0
        let urls = [dbURL, supportDirectory.appendingPathComponent("history.db-wal"),
                    supportDirectory.appendingPathComponent("history.db-shm")]
        for url in urls {
            if let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
               let size = values.fileSize {
                total += Int64(size)
            }
        }
        if let files = try? fm.contentsOfDirectory(
            at: imagesDirectory,
            includingPropertiesForKeys: [.fileSizeKey]
        ) {
            for file in files {
                if let values = try? file.resourceValues(forKeys: [.fileSizeKey]),
                   let size = values.fileSize {
                    total += Int64(size)
                }
            }
        }
        return total
    }

    private func fetchItem(id: Int64) -> ClipboardItem? {
        fetchOne("SELECT * FROM items WHERE id = \(id) LIMIT 1;")
    }

    private func fetchOne(_ sql: String) -> ClipboardItem? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return rowToItem(stmt)
    }

    private func rowToItem(_ stmt: OpaquePointer?) -> ClipboardItem? {
        guard let stmt else { return nil }
        let id = sqlite3_column_int64(stmt, 0)
        guard let typeC = sqlite3_column_text(stmt, 1),
              let type = ItemType(rawValue: String(cString: typeC)) else { return nil }

        func text(_ col: Int32) -> String? {
            guard let c = sqlite3_column_text(stmt, col) else { return nil }
            return String(cString: c)
        }
        func blob(_ col: Int32) -> Data? {
            guard let ptr = sqlite3_column_blob(stmt, col) else { return nil }
            let len = Int(sqlite3_column_bytes(stmt, col))
            return Data(bytes: ptr, count: len)
        }

        return ClipboardItem(
            id: id,
            type: type,
            textContent: text(2),
            htmlContent: text(3),
            rtfContent: blob(4),
            url: text(5),
            filePaths: decodePaths(text(6)),
            imagePath: text(7),
            contentHash: text(8) ?? "",
            sourceApp: text(9),
            sourceBundleId: text(10),
            isPinned: sqlite3_column_int(stmt, 11) != 0,
            isSnippet: sqlite3_column_int(stmt, 12) != 0,
            title: text(13),
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 14)),
            updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 15))
        )
    }

    private func encodePaths(_ paths: [String]) -> String? {
        guard !paths.isEmpty,
              let data = try? JSONEncoder().encode(paths),
              let s = String(data: data, encoding: .utf8) else { return nil }
        return s
    }

    private func decodePaths(_ json: String?) -> [String] {
        guard let json, let data = json.data(using: .utf8),
              let paths = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return paths
    }

    private func scalarInt(_ sql: String) -> Int64 {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return sqlite3_column_int64(stmt, 0)
    }

    private func exec(_ sql: String) {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            if let err {
                sqlite3_free(err)
            }
        }
    }

    private func bindText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let value {
            sqlite3_bind_text(stmt, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private func bindBlob(_ stmt: OpaquePointer?, _ index: Int32, _ value: Data?) {
        guard let value else {
            sqlite3_bind_null(stmt, index)
            return
        }
        _ = value.withUnsafeBytes { buffer in
            sqlite3_bind_blob(
                stmt,
                index,
                buffer.baseAddress,
                Int32(value.count),
                unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            )
        }
    }

    func absoluteImageURL(for item: ClipboardItem) -> URL? {
        guard let rel = item.imagePath else { return nil }
        return supportDirectory.appendingPathComponent(rel)
    }
}
