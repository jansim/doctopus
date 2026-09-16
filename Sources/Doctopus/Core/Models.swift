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
    /// Folders the router suggested for this document, best first.
    var pathSuggestions: [PathSuggestion] = []
    /// Folders where documents like this one already are.
    var similarFolders: [PathSuggestion] = []
    var aliases: [String] = []
    /// The subset of `aliases` someone filed by hand, as opposed to the ones a
    /// mirrored tag keeps — the document's secondary places.
    var folderAliases: [String] = []
    /// Everything that has happened to this document, newest first.
    var history: [HistoryEvent] = []
    /// What anyone has written about it, newest first.
    var notes: [Note] = []
    /// Every date the extractor found, best first — including the ones it did
    /// not pick, which is what makes correcting a date a click.
    var dateCandidates: [DateCandidate] = []
}

/// A folder the router thought a document could be filed in.
struct PathSuggestion: Identifiable, Hashable, Sendable {
    var id: String { path }
    /// Absolute path of the folder.
    var path: String
    var confidence: Double
    /// The rule that suggested it, or "derived".
    var source: String
    var explanation: String?
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
    /// What this field holds. Decides which typed column of `field_values`
    /// carries the comparable form, and how the inspector offers to edit it.
    var type: FieldType = .string
    /// Type-specific configuration, as JSON — the options of a `select`, so far.
    var extraData: String?
    /// Which library this field belongs to. Stamped by `AppModel`.
    var library: LibraryID = ""

    /// The choices a `select` field offers, in order.
    var options: [String] {
        guard type == .select, let extraData, let data = extraData.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(FieldOptions.self, from: data)
        else { return [] }
        return decoded.options
    }

    /// Field keys are unique within a library, and the merged list `AppModel`
    /// hands the views is deduplicated by key — a "Correspondent" column shows
    /// correspondents from every open library, so it is one field there.
    var id: String { key }

    var isBuiltin: Bool { builtinColumn != nil }
}

/// One value of a taxonomy field — a correspondent, a document type — as a row
/// rather than as a string repeated across every document that has it.
///
/// This is what makes renaming one thing instead of thousands, merging two
/// spellings possible at all, an icon survive a rename, and a value able to
/// identify itself: "anything mentioning DE12 3456 is from this bank" is how
/// most classification gets done without a model anywhere near it.
struct Entity: Identifiable, Hashable, Sendable {
    var entityID: Int64
    /// The field this is a value of, by key: `correspondent`, `doc_type`.
    var fieldKey: String
    var name: String
    var icon: String?
    var color: Int64 = 0
    /// A pattern that identifies this value in a document's text, read the
    /// same way a routing rule's pattern is.
    var match: String?
    var matchMode: MatchMode = .anyWord
    var matchInsensitive: Bool = true
    var count: Int = 0
    /// Which library this belongs to. Stamped by `AppModel`.
    var library: LibraryID = ""

    var id: String { "\(library)#\(fieldKey)#\(entityID)" }
}

/// The `extra_data` JSON of a `select` field.
struct FieldOptions: Codable, Sendable, Hashable {
    var options: [String] = []
}

struct Tag: Identifiable, Hashable, Sendable {
    /// Row id within its library's database.
    var tagID: Int64
    var name: String
    var color: Int64
    var mirrors: Bool
    var folder: String?
    var count: Int = 0
    /// The tag this one sits under, if any. Assigning a child attaches every
    /// ancestor too, so "Finances" finds what is filed under
    /// "Finances / Invoices" without anyone tagging both.
    var parentID: Int64?
    /// How deep this tag sits, with a root at zero. Filled in by `tags()`,
    /// which knows the whole shape.
    var depth: Int = 0
    /// Which library this tag belongs to. Stamped by `AppModel`.
    var library: LibraryID = ""

    var id: TagRef { TagRef(library: library, tag: tagID) }

    /// Tags nest, but not without limit. Paperless settled on five and nobody
    /// has ever asked for a sixth.
    static let maxDepth = 5
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
    /// For a taxonomy value, the pattern that identifies it in a document's
    /// text. Nil for everything else, which has nowhere to keep one.
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

/// Something a person wrote about a document that the schema has nowhere else
/// to put. Indexed into the search table with the document's own text.
struct Note: Identifiable, Hashable, Sendable {
    var id: Int64
    var body: String
    var createdAt: Date
    var updatedAt: Date?

    var edited: Bool { updatedAt != nil }
}

/// One thing that happened to a document, straight from the append-only
/// `events` table. The queue shows a bounded slice of the same data with an
/// approval state attached; this is the whole record, and it is never trimmed.
struct HistoryEvent: Identifiable, Hashable, Sendable {
    var id: Int64
    var at: Date
    var action: String
    var detail: String?
    var confidence: Double?
    var rule: String?
    /// Absolute paths, when the event was a move or a rename.
    var fromPath: String?
    var toPath: String?

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

    var label: String {
        switch action {
        case "routed": return "Filed"
        case "optimized": return "Optimized"
        case "renamed": return "Renamed"
        case "moved": return "Moved"
        case "imported": return "Imported"
        case "analyzed": return "Analyzed"
        case "indexed": return "Indexed"
        default: return action.capitalized
        }
    }

    /// "Inbox → Finances/Invoices/2026", when the event moved the file.
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
    /// How the pattern is read. Said out loud rather than guessed from whether
    /// the pattern happens to contain a bracket.
    var mode: MatchMode = .anyWord
    var caseInsensitive: Bool = true
    var setCorrespondent: String?
    var setDocType: String?
    var setFields: String?
}

/// A pinned, saved search query with custom sort and presentation.
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
    case savedView(id: Int64, query: String)
    case untagged
    case needsReview
    /// Documents moved to the Trash: the row is kept so the file can be put
    /// back with everything that was ever on it.
    case deleted

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
