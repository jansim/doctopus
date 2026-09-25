import Foundation

/// Snapshots of the index, kept inside the library container.
///
/// The documents survive the index, but nothing else does: tags beyond Finder
/// tags, fields, notes, correspondents, reviews and history live only in
/// `index.sqlite`. A snapshot is only taken of an index that passes SQLite's
/// own check, so a damaged one never pushes the last good copies out.
extension Store {
    struct Backup: Sendable, Hashable, Identifiable {
        var url: URL
        var date: Date
        var id: URL { url }
    }

    enum BackupOutcome: Sendable {
        case made(Backup)
        case notDue
        /// The index failed its check: no snapshot was taken, and none pruned.
        case damaged(String)
    }

    static let backupsKept = 7
    static let backupEvery: TimeInterval = 24 * 3600
    private static let backupPrefix = "index-"
    private static let beforeRestorePrefix = "before-restore-"

    nonisolated var backupsDirectory: URL { Self.backupsDirectory(in: containerURL) }

    nonisolated static func backupsDirectory(in container: URL) -> URL {
        container.appendingPathComponent("backups", isDirectory: true)
    }

    /// Newest first. Copies set aside by a restore are listed too.
    nonisolated func backups() -> [Backup] { Self.backups(in: containerURL) }

    nonisolated static func backups(in container: URL) -> [Backup] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: backupsDirectory(in: container), includingPropertiesForKeys: nil)) ?? []
        return urls.compactMap { url in
            let name = url.deletingPathExtension().lastPathComponent
            guard url.pathExtension == "sqlite" else { return nil }
            let stamp = name.hasPrefix(Self.backupPrefix) ? name.dropFirst(Self.backupPrefix.count)
                : name.hasPrefix(Self.beforeRestorePrefix) ? name.dropFirst(Self.beforeRestorePrefix.count)
                : nil
            guard let stamp, let date = Self.stampFormat.date(from: String(stamp)) else { return nil }
            return Backup(url: url, date: date)
        }
        .sorted { $0.date > $1.date }
    }

    /// Nil when SQLite finds nothing wrong.
    func integrityProblem() throws -> String? {
        let findings = try db.map("PRAGMA quick_check") { $0.string(0) }
        return findings == ["ok"] ? nil : findings.prefix(3).joined(separator: "; ")
    }

    func backUpIfDue(now: Date = Date()) throws -> BackupOutcome {
        let scheduled = backups().filter { $0.url.lastPathComponent.hasPrefix(Self.backupPrefix) }
        if let last = scheduled.first, now.timeIntervalSince(last.date) < Self.backupEvery,
           last.date <= now {
            return .notDue
        }
        return try backUp(now: now)
    }

    func backUp(now: Date = Date()) throws -> BackupOutcome {
        if let problem = try integrityProblem() { return .damaged(problem) }
        let backup = try snapshot(named: Self.backupPrefix, at: now)
        prune()
        return .made(backup)
    }

    /// Puts the index back as it was in `backup`. The index as it is now is
    /// kept first, so a restore can itself be taken back. The library has to
    /// be reopened afterwards: every cache above the database is stale.
    @discardableResult
    func restore(from backup: Backup, now: Date = Date()) throws -> Backup {
        let current = try snapshot(named: Self.beforeRestorePrefix, at: now)
        try db.restore(from: backup.url.path)
        fieldCache = nil
        ruleMatchCache = RuleMatchCache()
        return current
    }

    /// Whether an error opening the index says its file is damaged, rather
    /// than unreachable or from a newer build.
    nonisolated static func isDamage(_ error: Error) -> Bool {
        guard let error = error as? Database.Error else { return false }
        let text = error.description.lowercased()
        return ["malformed", "not a database", "corrupt"].contains { text.contains($0) }
    }

    /// For an index too damaged to open, when there is no connection to
    /// restore through: the damaged files are moved aside, never deleted, and
    /// the backup copied into their place.
    nonisolated static func replaceUnopenableIndex(in container: URL, with backup: Backup,
                                                   now: Date = Date()) throws {
        let fm = FileManager.default
        let aside = backupsDirectory(in: container)
            .appendingPathComponent("damaged-" + stampFormat.string(from: now), isDirectory: true)
        try fm.createDirectory(at: aside, withIntermediateDirectories: true)
        for suffix in ["", "-wal", "-shm"] {
            let file = container.appendingPathComponent("index.sqlite" + suffix)
            if fm.fileExists(atPath: file.path) {
                try fm.moveItem(at: file, to: aside.appendingPathComponent(file.lastPathComponent))
            }
        }
        try fm.copyItem(at: backup.url, to: container.appendingPathComponent("index.sqlite"))
    }

    private func snapshot(named prefix: String, at date: Date) throws -> Backup {
        let fm = FileManager.default
        try fm.createDirectory(at: backupsDirectory, withIntermediateDirectories: true)
        let url = backupsDirectory.appendingPathComponent(prefix + Self.stampFormat.string(from: date) + ".sqlite")
        // Written aside and moved in, so a half-written file never looks like a backup.
        let partial = backupsDirectory.appendingPathComponent(".partial-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: partial) }
        try db.backup(to: partial.path)
        if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
        try fm.moveItem(at: partial, to: url)
        return Backup(url: url, date: date)
    }

    /// Only scheduled snapshots are pruned. What a restore set aside stays
    /// until somebody deletes it.
    private func prune() {
        let scheduled = backups().filter { $0.url.lastPathComponent.hasPrefix(Self.backupPrefix) }
        for old in scheduled.dropFirst(Self.backupsKept) {
            try? FileManager.default.removeItem(at: old.url)
        }
    }

    private static let stampFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HHmmss'Z'"
        return f
    }()
}
