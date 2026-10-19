import Foundation

extension Indexer {
    struct RuleApplyResult: Sendable {
        var matched = 0
        var moved = 0
        var renamed = 0
        var tagged = 0
        var metadataUpdated = 0
        var failures: [String] = []
    }

    /// A rule, saved or still a draft, applied on request to the documents
    /// already in the library — all but its outliers, or the one named.
    func applyRule(_ rule: Rule, onlyTo docID: Int64? = nil) async -> RuleApplyResult {
        var result = RuleApplyResult()
        let router = Router(rules: [rule], derivedTemplate: "", root: store.root,
                            deriveWhenNoRule: false)
        for doc in (try? await store.ruleTargets(for: rule, onlyTo: docID)) ?? [] where rule.matches(doc.subject) {
            result.matched += 1
            var url = URL(fileURLWithPath: doc.path)
            var patch = Store.MetadataPatch(docID: doc.id)
            patch.correspondent = rule.setCorrespondent
            patch.docType = rule.setDocType
            let tagNames = rule.tagNames
            let setsMetadata = patch.correspondent != nil || patch.docType != nil
            // What the rule writes to the index is one change; a move or rename
            // it makes is logged as its own, as every move is.
            do {
                try await store.change(doc: doc.id, "Applied rule “\(rule.name)”") { [patch] store in
                    for tag in tagNames {
                        if let tagID = try? store.tagID(named: tag) {
                            try? store.assign(tag: tagID, to: patch.docID, auto: true)
                        }
                    }
                    if setsMetadata { try store.storeMetadata(patch) }
                }
                if !tagNames.isEmpty { result.tagged += 1 }
                if setsMetadata { result.metadataUpdated += 1 }
            } catch { result.failures.append("“\(url.lastPathComponent)”: \(error.localizedDescription)") }

            let correspondent = rule.setCorrespondent ?? doc.subject.correspondent
            let docType = rule.setDocType ?? doc.subject.docType
            let date = doc.docDate ?? doc.created
            if let template = rule.destination {
                let folder = router.expand(template, correspondent: correspondent, docType: docType, date: date)
                if router.isInsideLibrary(folder),
                   url.deletingLastPathComponent().standardizedFileURL != folder.standardizedFileURL {
                    do {
                        url = try await relocate(doc.id, from: url, into: folder, named: url.lastPathComponent,
                                                 action: .routed, detail: "Applied rule “\(rule.name)”",
                                                 rule: rule.name)
                        result.moved += 1
                    } catch { result.failures.append("“\(url.lastPathComponent)”: \(error.localizedDescription)") }
                }
            }
            if let template = rule.rename {
                let name = Naming.render(template, Naming.Context(
                    date: date, correspondent: correspondent, title: doc.title, docType: docType,
                    language: doc.language, counter: nil,
                    originalStem: url.deletingPathExtension().lastPathComponent, ext: url.pathExtension,
                    options: settings.namingOptions))
                if name != url.lastPathComponent {
                    do {
                        try await relocate(doc.id, from: url, into: url.deletingLastPathComponent(), named: name,
                                           action: .renamed, detail: name, rule: rule.name)
                        result.renamed += 1
                    } catch { result.failures.append("“\(url.lastPathComponent)”: \(error.localizedDescription)") }
                }
            }
        }
        onDataChanged()
        return result
    }
}
