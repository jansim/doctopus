import Foundation

/// Works out what applying a rule to a document that is already filed would
/// change — the steps Apply to Existing takes, without taking them. A rule that
/// matches but would leave everything as it is has nothing to point out.
struct RuleCheck: Sendable {

    /// What the actions compare against. The text is left out on purpose: it
    /// only decides whether a rule matches, never what matching would change.
    struct Document: Sendable {
        var path: String
        var correspondent: String?
        var docType: String?
        var date: Date
        var title: String?
        var language: String?
        var tags: [String]
    }

    var root: URL

    func changes(_ rule: Rule, for doc: Document) -> [RuleMatch.Change] {
        let router = Router(rules: [], threshold: 1, derivedTemplate: "",
                            root: root, deriveWhenNoRule: false)
        let url = URL(fileURLWithPath: doc.path)
        let correspondent = rule.setCorrespondent ?? doc.correspondent
        let docType = rule.setDocType ?? doc.docType
        var changes: [RuleMatch.Change] = []

        if let template = rule.destination {
            let folder = router.expand(template, correspondent: correspondent,
                                       docType: docType, date: doc.date)
            if router.isInsideLibrary(folder),
               folder.standardizedFileURL != url.deletingLastPathComponent().standardizedFileURL {
                changes.append(.move(to: display(folder)))
            }
        }

        if let template = rule.rename {
            let name = Naming.render(template, Naming.Context(
                date: doc.date, correspondent: correspondent, title: doc.title, docType: docType,
                language: doc.language, counter: nil,
                originalStem: url.deletingPathExtension().lastPathComponent, ext: url.pathExtension))
            if name != url.lastPathComponent { changes.append(.rename(to: name)) }
        }

        // A nested tag is assigned by its last segment, so that is what the
        // document already carrying it looks like.
        let have = Set(doc.tags.map { $0.lowercased() })
        let missing = rule.tagNames.filter { name in
            let leaf = name.split(separator: "/").last
                .map { $0.trimmingCharacters(in: .whitespaces) } ?? name
            return !have.contains(leaf.lowercased())
        }
        if !missing.isEmpty { changes.append(.addTags(missing)) }

        if let value = rule.setCorrespondent, !Self.same(value, doc.correspondent) {
            changes.append(.setCorrespondent(value))
        }
        if let value = rule.setDocType, !Self.same(value, doc.docType) {
            changes.append(.setDocType(value))
        }
        return changes
    }

    private static func same(_ a: String, _ b: String?) -> Bool {
        a.caseInsensitiveCompare(b ?? "") == .orderedSame
    }

    private func display(_ folder: URL) -> String {
        let path = Store.canonical(folder.standardizedFileURL.path)
        let rootPath = Store.canonical(root.standardizedFileURL.path)
        guard path.hasPrefix(rootPath + "/") else { return root.lastPathComponent }
        return String(path.dropFirst(rootPath.count + 1))
    }
}
