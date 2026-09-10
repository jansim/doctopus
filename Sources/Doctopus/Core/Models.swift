import Foundation

/// Stable identifier for an open library, taken from its `meta.json`. Survives
/// the library folder being moved or renamed.
typealias LibraryID = String

/// Composite document identity: a row id is only unique within one library, so
/// everything above `Store` addresses documents by `(library, doc)`.
struct DocumentRef: Hashable, Codable, Sendable {
    var library: LibraryID
    var doc: Int64
}

/// Composite tag identity. Tags are per-library — two libraries can both have
/// an "invoice" tag and they are not the same tag.
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

/// Row of the center pane. Kept flat and value-typed so list diffing is cheap.
struct DocumentRow: Identifiable, Hashable, Sendable {
    /// Row id within its library's database — only unique per library.
    var doc: Int64
    /// Which library the row came from. Stamped by `AppModel`; the `Store`
    /// leaves it empty.
    var library: LibraryID = ""
    /// Cross-library identity, used everywhere a row could be from any library.
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

    // Denormalized metadata, joined in the list query.
    var title: String?
    var correspondent: String?
    var docType: String?
    var language: String?
    var docDate: Date?
    var summary: String?
    var snippet: String?

    /// Every enabled field's value, keyed by field key. Built-ins are copied in
    /// from their columns so the UI never has to care where a value lives.
    var values: [String: String] = [:]

    /// True when this document's master file lives elsewhere and it is only
    /// present in the folder being viewed through a Finder alias.
    var isAliasHere = false

    /// Populated only in queue mode: the most recent pipeline event.
    var queue: QueueInfo?

    /// Doctopus's own tags, and the Finder's. Loaded alongside the list query
    /// so both can be shown as columns.
    var tags: [Tag] = []
    var finderTags: [String] = []

    var url: URL { URL(fileURLWithPath: path) }
    var displayTitle: String { title?.nilIfBlank ?? filename }
    var savings: Double? {
        guard let o = originalSize, o > 0, size < o else { return nil }
        return 1.0 - Double(size) / Double(o)
    }
}

/// The latest processing event for a document, shown in queue mode.
struct QueueInfo: Hashable, Sendable {
    var entryID: Int64
    var at: Date
    var action: String
    var detail: String?
    var confidence: Double?
    var rule: String?
    var approved: Bool

    var icon: String {
        switch action {
        case "routed": return "arrow.triangle.branch"
        case "optimized": return "arrow.down.circle"
        case "renamed": return "character.cursor.ibeam"
        case "moved": return "folder"
        case "imported": return "tray.and.arrow.down"
        case "analyzed": return "sparkles"
        default: return "doc.text.magnifyingglass"
        }
    }
}

struct DocumentDetail: Sendable {
    var row: DocumentRow
    var hash: String?
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
    /// Tags the model proposed for this document that nobody has accepted
    /// or discarded yet.
    var tagSuggestions: [TagSuggestion] = []
    var aliases: [String] = []
}

/// A configurable document attribute. Built-ins map to a `metadata` column;
/// user-defined ones live in `field_values`. Both are renameable and can be
/// shown or hidden per surface.
struct Field: Identifiable, Hashable, Sendable {
    /// Row id within its library's database.
    var fieldID: Int64
    var key: String
    var name: String
    var builtinColumn: String?
    var icon: String
    var showInSidebar: Bool
    var showInList: Bool
    var position: Int64
    var enabled: Bool
    /// Which library this field belongs to. Stamped by `AppModel`.
    var library: LibraryID = ""

    /// Field keys are unique within a library, and the merged list `AppModel`
    /// hands the views is deduplicated by key — a "Correspondent" column shows
    /// correspondents from every open library, so it is one field there.
    var id: String { key }

    var isBuiltin: Bool { builtinColumn != nil }
}

struct Tag: Identifiable, Hashable, Sendable {
    /// Row id within its library's database.
    var tagID: Int64
    var name: String
    var color: Int64
    var mirrors: Bool
    var folder: String?
    var count: Int = 0
    /// Which library this tag belongs to. Stamped by `AppModel`.
    var library: LibraryID = ""

    var id: TagRef { TagRef(library: library, tag: tagID) }
}

/// A tag the model proposed for a document but that has not been accepted
/// (turned into a real `Tag` assignment) or discarded yet. Unlike `Tag`,
/// it carries no id of its own — it is just a name until someone acts on it.
struct TagSuggestion: Identifiable, Hashable, Sendable {
    var id: String { name }
    var name: String
}

struct Facet: Identifiable, Hashable, Sendable {
    var id: String { value }
    var value: String
    var count: Int
    /// Set when this particular value has been given its own icon; otherwise
    /// the field's icon stands in.
    var icon: String?
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

struct Rule: Identifiable, Hashable, Sendable {
    var id: Int64
    var name: String
    var pattern: String
    var field: String
    var destination: String
    var tagNames: String?
    var weight: Double
    var enabled: Bool
    var priority: Int64
}

/// A node in the physical directory tree shown in the sidebar.
struct FolderNode: Identifiable, Hashable, Sendable {
    var id: String { path }
    var path: String
    var name: String
    var children: [FolderNode]
    var count: Int          // documents directly inside
    var deepCount: Int      // documents in this subtree
    var isRoot: Bool = false
}

/// What the center pane is currently listing.
enum Selection: Hashable, Sendable {
    case all
    case inbox
    case queue
    case folder(String)
    /// A Doctopus tag. Tag ids are per-library, so the library is part of the
    /// selection.
    case tag(TagRef)
    /// One of the Finder's own tags, by name. Matched across every open library.
    case finderTag(String)
    /// A field value facet: (field key, value). Matched across every open library.
    case field(String, String)
    case untagged
    case needsReview

    /// Both queue selections render the browser with its review affordances —
    /// Needs Review is simply the queue filtered to undecided entries.
    var isQueueMode: Bool { self == .queue || self == .needsReview }
}

/// How the center pane presents results.
enum ViewMode: String, CaseIterable, Sendable, Codable {
    case list = "List"
    case gallery = "Gallery"

    var icon: String { self == .list ? "list.bullet" : "square.grid.2x2" }
}

enum SortField: Hashable, Sendable {
    case added, docDate, name, size, relevance
    /// A configured field column. Where its values live decides the SQL, so
    /// that is resolved by the query rather than here.
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
        // What the Document column actually shows.
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
