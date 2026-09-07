import Foundation

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
    var id: Int64
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

    var url: URL { URL(fileURLWithPath: path) }
    var displayTitle: String { title?.nilIfBlank ?? filename }
    var savings: Double? {
        guard let o = originalSize, o > 0, size < o else { return nil }
        return 1.0 - Double(size) / Double(o)
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
    var aliases: [String] = []
}

struct Tag: Identifiable, Hashable, Sendable {
    var id: Int64
    var name: String
    var color: Int64
    var mirrors: Bool
    var folder: String?
    var count: Int = 0
}

struct Facet: Identifiable, Hashable, Sendable {
    var id: String { value }
    var value: String
    var count: Int
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
    case tag(Int64)
    case correspondent(String)
    case docType(String)
    case language(String)
    case untagged
    case needsReview

    var isQueue: Bool { if case .queue = self { return true }; return false }
}

enum SortField: String, CaseIterable, Sendable {
    case added = "Added"
    case docDate = "Document Date"
    case name = "Name"
    case size = "Size"
    case relevance = "Relevance"

    var column: String {
        switch self {
        case .added: return "d.created_at"
        case .docDate: return "COALESCE(m.doc_date, d.created_at)"
        case .name: return "d.filename COLLATE NOCASE"
        case .size: return "d.size"
        case .relevance: return "rank"
        }
    }
}

extension String {
    var nilIfBlank: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
