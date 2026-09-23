import Foundation

typealias LibraryID = String

/// Composite document identity: a row id is only unique within one library, so
/// everything above `Store` addresses documents by `(library, doc)`.
struct DocumentRef: Hashable, Codable, Sendable {
    var library: LibraryID
    var doc: Int64
}

struct TagRef: Hashable, Codable, Sendable {
    var library: LibraryID
    var tag: Int64
}

enum OCRState: Int64, Sendable {
    case pending = 0, done = 1, failed = 2, skipped = 3

    var label: String {
        switch self {
        case .pending: return "Pending"
        case .done: return "Indexed"
        case .failed: return "Failed"
        case .skipped: return "Skipped"
        }
    }
}

struct DocumentRow: Identifiable, Hashable, Sendable {
    var doc: Int64
    var library: LibraryID = ""
    var id: DocumentRef { DocumentRef(library: library, doc: doc) }
    var path: String
    var directory: String
    var filename: String
    var ext: String
    var size: Int64
    var originalSize: Int64?
    var createdAt: Date
    var mtime: Date
    var ocrState: OCRState
    var pageCount: Int?
    var approved: Bool
    var missing: Bool

    var title: String?
    var correspondent: String?
    var docType: String?
    var language: String?
    var docDate: Date?
    var summary: String?
    var snippet: String?

    var values: [String: String] = [:]

    var isAliasHere = false

    var queue: QueueInfo?

    var tags: [Tag] = []
    var finderTags: [String] = []

    var url: URL { URL(fileURLWithPath: path) }
    var displayTitle: String { title?.nilIfBlank ?? filename }
    var savings: Double? {
        guard let o = originalSize, o > 0, size < o else { return nil }
        return 1.0 - Double(size) / Double(o)
    }
}

struct QueueInfo: Hashable, Sendable {
    var entryID: Int64
    var at: Date
    var action: String
    var detail: String?
    var confidence: Double?
    var rule: String?
    var approved: Bool

    var icon: String { DocumentAction.icon(action) }
}

enum DocumentAction {
    static func icon(_ action: String) -> String {
        switch action {
        case "routed": return "arrow.triangle.branch"
        case "optimized": return "arrow.down.circle"
        case "renamed": return "character.cursor.ibeam"
        case "moved": return "folder"
        case "promoted": return "arrow.up.doc"
        case "unfiled": return "folder.badge.minus"
        case "imported": return "tray.and.arrow.down"
        case "analyzed": return "sparkles"
        case "edited": return "pencil"
        default: return "doc.text.magnifyingglass"
        }
    }

    static func label(_ action: String) -> String {
        switch action {
        case "routed": return "Filed"
        case "optimized": return "Optimized"
        case "renamed": return "Renamed"
        case "moved": return "Moved"
        case "promoted": return "Kept elsewhere"
        case "unfiled": return "Unfiled"
        case "imported": return "Imported"
        case "analyzed": return "Analyzed"
        case "indexed": return "Indexed"
        case "edited": return "Edited by hand"
        default: return action.capitalized
        }
    }
}

struct DocumentDetail: Sendable {
    var row: DocumentRow
    var hash: String?
    var originalFileURL: URL?
    var intent: String?
    var dateSource: String?
    var metadataSource: String?
    var metadataConfidence: Double?
    var amount: String?
    var ocrConfidence: Double?
    var ocrWords: Int?
    var ocrSource: String?
    var text: String = ""
    var tags: [Tag] = []
    var tagSuggestions: [TagSuggestion] = []
    var pathSuggestions: [PathSuggestion] = []
    var similarFolders: [PathSuggestion] = []
    var similarDocuments: [DocumentRow] = []
    var aliases: [String] = []
    var folderAliases: [String] = []
    var history: [HistoryEvent] = []
    var notes: [Note] = []
    var dateCandidates: [DateCandidate] = []
}

struct PathSuggestion: Identifiable, Hashable, Sendable {
    var id: String { path }
    var path: String
    var confidence: Double
    var source: String
    var explanation: String?
}

struct Field: Identifiable, Hashable, Sendable {
    var fieldID: Int64
    var key: String
    var name: String
    var builtinColumn: String?
    var icon: String
    var showInSidebar: Bool
    var showInList: Bool
    var position: Int64
    var enabled: Bool
    var type: FieldType = .string
    var extraData: String?
    var library: LibraryID = ""

    var options: [String] {
        guard type == .select, let extraData, let data = extraData.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(FieldOptions.self, from: data)
        else { return [] }
        return decoded.options
    }

    var id: String { key }

    var isBuiltin: Bool { builtinColumn != nil }
}

struct Entity: Identifiable, Hashable, Sendable {
    var entityID: Int64
    var fieldKey: String
    var name: String
    var icon: String?
    var color: Int64 = 0
    var match: String?
    var matchMode: MatchMode = .anyWord
    var matchInsensitive: Bool = true
    var count: Int = 0
    var library: LibraryID = ""

    var id: String { "\(library)#\(fieldKey)#\(entityID)" }
}

struct FieldOptions: Codable, Sendable, Hashable {
    var options: [String] = []
}

struct Tag: Identifiable, Hashable, Sendable {
    var tagID: Int64
    var name: String
    var color: Int64
    var mirrors: Bool
    var folder: String?
    var count: Int = 0
    var parentID: Int64?
    var depth: Int = 0
    var library: LibraryID = ""
    var implied: Bool = false

    var id: TagRef { TagRef(library: library, tag: tagID) }

    static let maxDepth = 5

    func path(in siblings: [Tag]) -> String {
        var names = [name]
        var current = self
        while let parentID = current.parentID,
              let parent = siblings.first(where: { $0.tagID == parentID }) {
            names.append(parent.name)
            current = parent
        }
        return names.reversed().joined(separator: "/")
    }

    static func visible(in tags: [Tag]) -> [(tag: Tag, path: String)] {
        tags.filter { !$0.implied }.map { ($0, $0.path(in: tags)) }
    }
}

struct TagSuggestion: Identifiable, Hashable, Sendable {
    var id: String { name }
    var name: String
}

struct Facet: Identifiable, Hashable, Sendable {
    var id: String { value }
    var value: String
    var count: Int
    var icon: String?
    var match: String?
}

struct ProcessingEntry: Identifiable, Hashable, Sendable {
    var id: Int64
    var docID: Int64
    var at: Date
    var action: String
    var detail: String?
    var confidence: Double?
    var rule: String?
    var fromPath: String?
    var toPath: String?
    var approved: Bool
    var filename: String
    var missing: Bool
}

struct Note: Identifiable, Hashable, Sendable {
    var id: Int64
    var body: String
    var createdAt: Date
    var updatedAt: Date?

    var edited: Bool { updatedAt != nil }
}

struct HistoryEvent: Identifiable, Hashable, Sendable {
    var id: Int64
    var at: Date
    var action: String
    var detail: String?
    var confidence: Double?
    var rule: String?
    var fromPath: String?
    var toPath: String?

    var icon: String { DocumentAction.icon(action) }
    var label: String { DocumentAction.label(action) }

    func move(relativeTo root: String) -> String? {
        guard let fromPath, let toPath, fromPath != toPath else { return nil }
        func trim(_ p: String) -> String {
            let stripped = p.hasPrefix(root + "/") ? String(p.dropFirst(root.count + 1)) : p
            return (stripped as NSString).deletingLastPathComponent.nilIfBlank ?? stripped
        }
        let from = trim(fromPath), to = trim(toPath)
        return from == to ? nil : "\(from) → \(to)"
    }
}

struct SavedView: Identifiable, Hashable, Sendable {
    var id: Int64
    var name: String
    var icon: String = "line.3.horizontal.decrease.circle"
    var query: String
    var sortKey: String?
    var ascending: Bool = false
    var viewMode: String?
    var position: Int64 = 0
    var library: LibraryID = ""
}

struct FolderNode: Identifiable, Hashable, Sendable {
    var id: String { path }
    var path: String
    var name: String
    var children: [FolderNode]
    var count: Int
    var deepCount: Int
    var isRoot: Bool = false
}

enum Selection: Hashable, Sendable {
    case all
    case queue
    case folder(String)
    case tag(TagRef)
    case finderTag(String)
    case field(String, String)
    case savedView(id: Int64, query: String)
    case untagged
    case needsReview
    case deleted

    var isQueueMode: Bool { self == .queue || self == .needsReview }
}

enum ViewMode: String, CaseIterable, Sendable, Codable {
    case list = "List"
    case gallery = "Gallery"

    var icon: String { self == .list ? "list.bullet" : "square.grid.2x2" }
}

enum SortField: Hashable, Sendable {
    case added, docDate, name, size, relevance
    case field(String)

    static let standard: [SortField] = [.relevance, .added, .docDate, .name, .size]

    var label: String {
        switch self {
        case .added: return "Added"
        case .docDate: return "Document Date"
        case .name: return "Name"
        case .size: return "Size"
        case .relevance: return "Relevance"
        case .field(let key): return key
        }
    }

    /// Stable name for the settings table. The case names would do, except
    /// that `field(_:)` carries a key, so the two are spelled out here rather
    /// than left to a synthesized encoding that a later case could shift.
    var storageKey: String {
        switch self {
        case .added: return "added"
        case .docDate: return "docDate"
        case .name: return "name"
        case .size: return "size"
        case .relevance: return "relevance"
        case .field(let key): return "field:\(key)"
        }
    }

    init?(storageKey: String) {
        if storageKey.hasPrefix("field:") {
            self = .field(String(storageKey.dropFirst("field:".count)))
            return
        }
        guard let match = SortField.standard.first(where: { $0.storageKey == storageKey })
        else { return nil }
        self = match
    }

    var column: String? {
        switch self {
        case .added: return "d.created_at"
        case .docDate: return "COALESCE(m.doc_date, d.created_at)"
        case .name: return "COALESCE(NULLIF(m.title, ''), d.filename) COLLATE NOCASE"
        case .size: return "d.size"
        case .relevance: return "rank"
        case .field: return nil
        }
    }
}

extension String {
    var nilIfBlank: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
