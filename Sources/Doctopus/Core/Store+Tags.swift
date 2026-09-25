import Foundation

extension Store {

    func tags() throws -> [Tag] {
        let flat = try db.map("""
            SELECT t.id, t.name, t.color, COUNT(dt.doc_id), t.parent_id
            FROM tags t
            LEFT JOIN document_tags dt ON dt.tag_id = t.id
            LEFT JOIN documents d ON d.id = dt.doc_id AND d.missing=0 AND d.deleted_at IS NULL
            GROUP BY t.id ORDER BY t.name COLLATE NOCASE
            """) {
            Tag(tagID: $0.int(0), name: $0.string(1), color: $0.int(2),
                count: Int($0.int(3)), parentID: $0.intOrNil(4))
        }
        return Store.nested(flat)
    }

    nonisolated static func nested(_ tags: [Tag]) -> [Tag] {
        var children: [Int64: [Tag]] = [:]
        var roots: [Tag] = []
        let known = Set(tags.map(\.tagID))
        for tag in tags {
            if let parent = tag.parentID, parent != tag.tagID, known.contains(parent) {
                children[parent, default: []].append(tag)
            } else {
                roots.append(tag)
            }
        }
        var out: [Tag] = []
        var placed = Set<Int64>()
        func walk(_ tag: Tag, depth: Int) {
            guard placed.insert(tag.tagID).inserted else { return }
            var stamped = tag
            stamped.depth = depth
            out.append(stamped)
            for child in children[tag.tagID] ?? [] { walk(child, depth: depth + 1) }
        }
        for root in roots { walk(root, depth: 0) }
        for tag in tags where !placed.contains(tag.tagID) { walk(tag, depth: 0) }
        return out
    }

    func ancestors(of tagID: Int64) throws -> [Int64] {
        var out: [Int64] = []
        var current = tagID
        var guardrail = 0
        while guardrail < Tag.maxDepth + 1 {
            guardrail += 1
            guard let parent = try db.first("SELECT parent_id FROM tags WHERE id=?", [.int(current)],
                                            { $0.intOrNil(0) }) ?? nil else { break }
            guard !out.contains(parent), parent != tagID else { break }
            out.append(parent)
            current = parent
        }
        return out
    }

    @discardableResult
    func setTagParent(_ tagID: Int64, to parentID: Int64?) throws -> Bool {
        guard tagID != parentID else { return false }
        if let parentID {
            if try ancestors(of: parentID).contains(tagID) { return false }
            let above = try ancestors(of: parentID).count + 1
            let below = try depthBelow(tagID)
            guard above + below < Tag.maxDepth else { return false }
        }
        try db.run("UPDATE tags SET parent_id=? WHERE id=?", [.int(parentID), .int(tagID)])
        try reapplyAncestors(of: tagID)
        return true
    }

    private func depthBelow(_ tagID: Int64) throws -> Int {
        let children = try db.map("SELECT id FROM tags WHERE parent_id=?", [.int(tagID)]) { $0.int(0) }
        guard !children.isEmpty else { return 0 }
        var deepest = 0
        for child in children where child != tagID {
            deepest = try max(deepest, depthBelow(child) + 1)
        }
        return deepest
    }

    func reapplyAncestors(of tagID: Int64) throws {
        var subtree = [tagID]
        var frontier = [tagID]
        var depth = 0
        while !frontier.isEmpty, depth <= Tag.maxDepth {
            depth += 1
            var next: [Int64] = []
            for id in frontier {
                next += try db.map("SELECT id FROM tags WHERE parent_id=?", [.int(id)]) { $0.int(0) }
            }
            next.removeAll { subtree.contains($0) }
            subtree += next
            frontier = next
        }
        for id in subtree {
            let above = try ancestors(of: id)
            guard !above.isEmpty else { continue }
            let docs = try documentIDs(withTag: id)
            for doc in docs {
                for parent in above {
                    try db.run("INSERT OR IGNORE INTO document_tags(doc_id, tag_id, auto) VALUES(?,?,1)",
                               [.int(doc), .int(parent)])
                }
            }
            try refreshSearchIndex(docs)
        }
    }

    @discardableResult
    func tagID(named name: String, color: Int64 = 0) throws -> Int64 {
        let segments = name.split(separator: "/")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let leaf = segments.last else { return 0 }
        guard segments.count > 1 else { return try tagID(plain: leaf, color: color) }
        var parent: Int64?
        var id: Int64 = 0
        for segment in segments {
            id = try tagID(plain: segment, color: color)
            if let parent, parent != id { _ = try? setTagParent(id, to: parent) }
            parent = id
        }
        return id
    }

    private func tagID(plain name: String, color: Int64) throws -> Int64 {
        if let id = try db.first("SELECT id FROM tags WHERE name=? COLLATE NOCASE", [.text(name)], { $0.int(0) }) {
            return id
        }
        return try db.run("INSERT INTO tags(name, color) VALUES(?,?)", [.text(name), .int(color)])
    }

    func assign(tag tagID: Int64, to docID: Int64, auto: Bool = false) throws {
        guard tagID > 0 else { return }
        try db.run("INSERT OR IGNORE INTO document_tags(doc_id, tag_id, auto) VALUES(?,?,?)",
                   [.int(docID), .int(tagID), .bool(auto)])
        for parent in try ancestors(of: tagID) {
            try db.run("INSERT OR IGNORE INTO document_tags(doc_id, tag_id, auto) VALUES(?,?,1)",
                       [.int(docID), .int(parent)])
        }
        try refreshSearchIndex(docID)
    }

    func unassign(tag tagID: Int64, from docID: Int64) throws {
        try db.run("DELETE FROM document_tags WHERE doc_id=? AND tag_id=?", [.int(docID), .int(tagID)])
        try refreshSearchIndex(docID)
    }

    func deleteTag(_ id: Int64) throws {
        let affected = try documentIDs(withTag: id)
        try db.run("DELETE FROM tags WHERE id=?", [.int(id)])
        try refreshSearchIndex(affected)
    }

    func tags(for docID: Int64) throws -> [Tag] {
        try db.map("""
            SELECT t.id, t.name, t.color, t.parent_id, dt.auto FROM tags t
            JOIN document_tags dt ON dt.tag_id=t.id WHERE dt.doc_id=?
            ORDER BY t.name COLLATE NOCASE
            """, [.int(docID)]) {
            Tag(tagID: $0.int(0), name: $0.string(1), color: $0.int(2),
                parentID: $0.intOrNil(3), implied: $0.bool(4))
        }
    }

    func recordAlias(docID: Int64, path: String) throws {
        try db.run("INSERT OR REPLACE INTO aliases(doc_id, path, created_at) VALUES(?,?,?)",
                   [.int(docID), .text(relPath(path)), .double(Date().timeIntervalSince1970)])
    }

    func aliases(for docID: Int64) throws -> [(id: Int64, path: String)] {
        try db.map("SELECT id, path FROM aliases WHERE doc_id=?", [.int(docID)]) {
            ($0.int(0), absPath($0.string(1)))
        }
    }

    func deleteAlias(id: Int64) throws {
        try db.run("DELETE FROM aliases WHERE id=?", [.int(id)])
    }
}
