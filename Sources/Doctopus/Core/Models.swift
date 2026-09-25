import Foundation

typealias LibraryID = String


/// Where a document's text came from, as stored with it.
enum TextSource {
    /// A PDF that needs a password to open, so no text could be read.
    static let locked = "locked"
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
    /// Only unique within its library, which is all a window ever shows.
    var id: Int64 { doc }
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
    /// Imported or scanned; only filled in for the review queues and the detail.
    var fromOutside = false

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
    var action: EventAction
    var detail: String?
    var rule: String?
    var approved: Bool
}

enum DocumentOrigin: Sendable {
    case scanned
    case imported(from: String)
    case inLibrary
}

/// What an `events` row records. The raw values are what the index stores.
enum EventAction: String, Sendable {
    case added, imported, indexed, analyzed, optimized, aliased, unfiled, moved, renamed, routed, promoted, edited
    case revertedOptimization = "reverted_optimization"

    init(stored: String) { self = EventAction(rawValue: stored) ?? .indexed }

    /// What Edit › Undo can take back.
    static let undoable: [EventAction] = [.moved, .renamed, .routed, .promoted, .unfiled, .aliased]

    var icon: String {
        switch self {
        case .added: return "plus.circle"
        case .routed: return "arrow.triangle.branch"
        case .optimized: return "arrow.down.circle"
        case .renamed: return "character.cursor.ibeam"
        case .moved: return "folder"
        case .promoted: return "arrow.up.doc"
        case .unfiled: return "folder.badge.minus"
        case .imported: return "tray.and.arrow.down"
        case .analyzed: return "sparkles"
        case .edited: return "pencil"
        case .indexed, .aliased, .revertedOptimization: return "doc.text.magnifyingglass"
        }
    }

    var label: String {
        switch self {
        case .routed: return "Filed"
        case .promoted: return "Kept elsewhere"
        case .edited: return "Edited by hand"
        case .revertedOptimization: return "Reverted"
        default: return rawValue.capitalized
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
    var amount: String?
    var ocrWords: Int?
    var ocrSource: String?
    var text: String = ""
    var tags: [Tag] = []
    var tagSuggestions: [TagSuggestion] = []
    var pathSuggestions: [PathSuggestion] = []
    var arrivalDirectory: String?
    var similarFolders: [PathSuggestion] = []
    var similarDocuments: [DocumentRow] = []
    var aliases: [String] = []
    var folderAliases: [String] = []
    var history: [HistoryEvent] = []
    var note: String = ""
    var dateCandidates: [DateCandidate] = []
}

struct PathSuggestion: Identifiable, Hashable, Sendable {
    var id: String { path }
    var path: String
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

    var id: String { "\(fieldKey)#\(entityID)" }
}

struct FieldOptions: Codable, Sendable, Hashable {
    var options: [String] = []
}

struct Tag: Identifiable, Hashable, Sendable {
    var tagID: Int64
    var name: String
    var color: Int64
    /// An SF Symbol; nil draws `Tag.defaultIcon`.
    var icon: String?
    var count: Int = 0
    var parentID: Int64?
    var depth: Int = 0
    var implied: Bool = false

    var id: Int64 { tagID }

    static let maxDepth = 5
    static let defaultIcon = "tag"

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
    var action: EventAction
    var detail: String?
    var rule: String?
    var fromPath: String?
    var toPath: String?
    var approved: Bool
    var filename: String
    var missing: Bool
}

struct HistoryEvent: Identifiable, Hashable, Sendable {
    var id: Int64
    var at: Date
    var action: EventAction
    var detail: String?
    var rule: String?
    var fromPath: String?
    var toPath: String?

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
    case reviewed
    case folder(String)
    case tag(Int64)
    case finderTag(String)
    case field(String, String)
    case savedView(id: Int64, query: String)
    case untagged
    case needsReview
    case deleted
    /// The documents marked as outliers for one rule.
    case outliers(rule: Int64)

    var isQueueMode: Bool { self == .reviewed || self == .needsReview }
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

    /// The path with the user's home directory shown as `~`.
    var abbreviatingHome: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if self == home { return "~" }
        return hasPrefix(home + "/") ? "~" + dropFirst(home.count) : self
    }
}

/// `metadata.source` is written as `backend[:model][:vN]`. Read it back only
/// through here, so adding a component never breaks a prefix match elsewhere.
enum MetadataSource: Equatable {
    /// Bump whenever the default prompt template changes, so
    /// `is:stale-analysis` can find the documents answered under an older one.
    static let promptVersion = 5

    case onDevice(model: String?)
    case remote(model: String?, vision: Bool)
    case heuristics

    init(_ raw: String) {
        var parts = raw.split(separator: ":").map(String.init)
        let backend = parts.isEmpty ? "" : parts.removeFirst()
        if let last = parts.last, last.hasPrefix("v"), last.dropFirst().allSatisfy(\.isNumber) {
            parts.removeLast()
        }
        let model = parts.joined(separator: ":").nilIfBlank
        switch backend {
        case "llm": self = .onDevice(model: model)
        case "remote": self = .remote(model: model, vision: false)
        case "vlm": self = .remote(model: model, vision: true)
        default: self = .heuristics
        }
    }

    var model: String? {
        switch self {
        case .onDevice(let m), .remote(let m, _): return m
        case .heuristics: return nil
        }
    }

    var label: String {
        switch self {
        case .onDevice: return "On-device model"
        case .remote(_, let vision): return vision ? "API vision model" : "API model"
        case .heuristics: return "Heuristics"
        }
    }

    var inlineLabel: String {
        switch self {
        case .onDevice: return "on-device model"
        case .remote(_, let vision): return vision ? "API vision model" : "API model"
        case .heuristics: return "heuristics"
        }
    }

    var detailedLabel: String {
        guard let model else { return label }
        return "\(label) (\(model))"
    }
}

/// Shared by both backends: asking them different questions would make their
/// answers incomparable.

struct TrainingDoc: Sendable {
    var id: Int64
    var text: String
    var correspondent: String?
    var docType: String?
    var tags: [String]
}
