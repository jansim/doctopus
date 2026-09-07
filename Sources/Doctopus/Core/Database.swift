import Foundation
import SQLite3

/// Thin, allocation-conscious wrapper over the system SQLite3 C API.
///
/// Deliberately dependency-free: the system library already ships with FTS5,
/// WAL and the `unicode61` tokenizer, which is everything the index needs.
/// Not thread-safe on its own — always reached through `Store`.
final class Database {
    enum Error: Swift.Error, CustomStringConvertible {
        case open(String)
        case sql(String, String)
        var description: String {
            switch self {
            case .open(let m): return "sqlite open failed: \(m)"
            case .sql(let q, let m): return "sqlite error: \(m) — while running: \(q)"
            }
        }
    }

    private let handle: OpaquePointer
    private var cache: [String: OpaquePointer] = [:]

    static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(path: String) throws {
        var h: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(path, &h, flags, nil) == SQLITE_OK, let h else {
            let msg = h.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            throw Error.open(msg)
        }
        handle = h
        sqlite3_busy_timeout(handle, 5_000)
        // Pragmas tuned for a local single-writer index: durability is nice to
        // have but the disk is the source of truth, so we can trade fsyncs for speed.
        for pragma in [
            "PRAGMA journal_mode=WAL",
            "PRAGMA synchronous=NORMAL",
            "PRAGMA foreign_keys=ON",
            "PRAGMA temp_store=MEMORY",
            "PRAGMA cache_size=-16000",   // 16 MB page cache
            "PRAGMA mmap_size=268435456", // 256 MB
        ] { try exec(pragma) }
    }

    deinit {
        for (_, stmt) in cache { sqlite3_finalize(stmt) }
        sqlite3_close_v2(handle)
    }

    var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(handle) }
    var changes: Int32 { sqlite3_changes(handle) }

    func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(handle, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw Error.sql(sql, msg)
        }
    }

    /// Returns a cached, reset prepared statement for `sql`.
    private func statement(_ sql: String) throws -> OpaquePointer {
        if let s = cache[sql] {
            sqlite3_reset(s)
            sqlite3_clear_bindings(s)
            return s
        }
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &s, nil) == SQLITE_OK, let s else {
            throw Error.sql(sql, String(cString: sqlite3_errmsg(handle)))
        }
        cache[sql] = s
        return s
    }

    @discardableResult
    func run(_ sql: String, _ args: [Value] = []) throws -> Int64 {
        let s = try statement(sql)
        bind(s, args)
        let rc = sqlite3_step(s)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
            throw Error.sql(sql, String(cString: sqlite3_errmsg(handle)))
        }
        sqlite3_reset(s)
        return lastInsertRowID
    }

    /// Streams rows through `body`. The `Row` is only valid inside the closure.
    func query(_ sql: String, _ args: [Value] = [], _ body: (Row) throws -> Void) throws {
        let s = try statement(sql)
        bind(s, args)
        defer { sqlite3_reset(s) }
        while true {
            let rc = sqlite3_step(s)
            if rc == SQLITE_ROW { try body(Row(s)) }
            else if rc == SQLITE_DONE { return }
            else { throw Error.sql(sql, String(cString: sqlite3_errmsg(handle))) }
        }
    }

    func map<T>(_ sql: String, _ args: [Value] = [], _ body: (Row) throws -> T) throws -> [T] {
        var out: [T] = []
        try query(sql, args) { out.append(try body($0)) }
        return out
    }

    func first<T>(_ sql: String, _ args: [Value] = [], _ body: (Row) throws -> T) throws -> T? {
        var out: T?
        try query(sql, args) { row in if out == nil { out = try body(row) } }
        return out
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try exec("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try exec("COMMIT")
            return result
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    // MARK: - Binding

    enum Value {
        case int(Int64)
        case double(Double)
        case text(String)
        case blob(Data)
        case null
    }

    private func bind(_ s: OpaquePointer, _ args: [Value]) {
        for (i, v) in args.enumerated() {
            let idx = Int32(i + 1)
            switch v {
            case .int(let n): sqlite3_bind_int64(s, idx, n)
            case .double(let d): sqlite3_bind_double(s, idx, d)
            case .text(let t): sqlite3_bind_text(s, idx, t, -1, Database.transient)
            case .blob(let d):
                if d.isEmpty { sqlite3_bind_zeroblob(s, idx, 0) }
                else { _ = d.withUnsafeBytes { sqlite3_bind_blob(s, idx, $0.baseAddress, Int32(d.count), Database.transient) } }
            case .null: sqlite3_bind_null(s, idx)
            }
        }
    }

    struct Row {
        private let s: OpaquePointer
        init(_ s: OpaquePointer) { self.s = s }

        func int(_ i: Int32) -> Int64 { sqlite3_column_int64(s, i) }
        func double(_ i: Int32) -> Double { sqlite3_column_double(s, i) }
        func bool(_ i: Int32) -> Bool { sqlite3_column_int64(s, i) != 0 }
        func string(_ i: Int32) -> String {
            guard let c = sqlite3_column_text(s, i) else { return "" }
            return String(cString: c)
        }
        func stringOrNil(_ i: Int32) -> String? {
            sqlite3_column_type(s, i) == SQLITE_NULL ? nil : string(i)
        }
        func intOrNil(_ i: Int32) -> Int64? {
            sqlite3_column_type(s, i) == SQLITE_NULL ? nil : int(i)
        }
        func doubleOrNil(_ i: Int32) -> Double? {
            sqlite3_column_type(s, i) == SQLITE_NULL ? nil : double(i)
        }
        func date(_ i: Int32) -> Date? {
            guard sqlite3_column_type(s, i) != SQLITE_NULL else { return nil }
            return Date(timeIntervalSince1970: double(i))
        }
    }
}

extension Database.Value: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral {
    init(stringLiteral value: String) { self = .text(value) }
    init(integerLiteral value: Int64) { self = .int(value) }
}

extension Database.Value {
    static func text(_ s: String?) -> Database.Value { s.map { .text($0) } ?? .null }
    static func int(_ n: Int64?) -> Database.Value { n.map { .int($0) } ?? .null }
    static func int(_ n: Int) -> Database.Value { .int(Int64(n)) }
    static func double(_ d: Double?) -> Database.Value { d.map { .double($0) } ?? .null }
    static func bool(_ b: Bool) -> Database.Value { .int(b ? 1 : 0) }
    static func date(_ d: Date?) -> Database.Value { d.map { .double($0.timeIntervalSince1970) } ?? .null }
}
