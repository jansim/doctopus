import Foundation

/// Report of a library sanity check.
struct VerificationReport: Sendable {
    struct Issue: Sendable, Identifiable {
        enum Severity: String, Sendable { case error, warning, info }
        var id = UUID()
        var severity: Severity
        var title: String
        var detail: String?
    }
    var issues: [Issue] = []
    var isClean: Bool { issues.isEmpty }
    var errorsCount: Int { issues.filter { $0.severity == .error }.count }
    var warningsCount: Int { issues.filter { $0.severity == .warning }.count }
    var infoCount: Int { issues.filter { $0.severity == .info }.count }
}

enum LibraryVerifier {
    static func verify(library root: URL) async throws -> VerificationReport {
        let container = root.appendingPathComponent("library.doctopus")
        let store = try Store(directory: container)
        return try await verify(store: store)
    }

    static func verify(store: Store) async throws -> VerificationReport {
        var report = VerificationReport()
        let fm = FileManager.default

        // 1. Missing files on disk & hash mismatches & empty OCR text
        let allDocs = try await store.verificationDocumentInfos()
        for doc in allDocs {
            if !fm.fileExists(atPath: doc.path) {
                report.issues.append(VerificationReport.Issue(
                    severity: .error,
                    title: "Missing file on disk",
                    detail: "\(doc.filename) (id #\(doc.id)) is in the database but missing on disk at \(doc.path)."
                ))
            } else {
                // Checksum / hash mismatch
                if let storedHash = doc.hash,
                   let currentHash = FileScanner.hash(URL(fileURLWithPath: doc.path)),
                   storedHash != currentHash {
                    report.issues.append(VerificationReport.Issue(
                        severity: .warning,
                        title: "Checksum mismatch",
                        detail: "\(doc.filename) was modified on disk outside Doctopus (hash \(storedHash.prefix(8))… vs \(currentHash.prefix(8))…)."
                    ))
                }
            }

            // OCR done but empty text
            if doc.ocrState == .done {
                let text = (try? await store.ocrText(doc.id)) ?? ""
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    report.issues.append(VerificationReport.Issue(
                        severity: .warning,
                        title: "Empty extracted text",
                        detail: "\(doc.filename) has OCR marked as done, but its indexed text is empty."
                    ))
                }
            }
        }

        // 2. Files on disk not in DB
        let scanned = FileScanner.scan(root: store.root)
        let indexedPaths = Set(allDocs.map { Store.canonical($0.path) })
        for file in scanned {
            let path = Store.canonical(file.url.path)
            if !indexedPaths.contains(path) {
                report.issues.append(VerificationReport.Issue(
                    severity: .warning,
                    title: "Unindexed file on disk",
                    detail: "\(file.url.lastPathComponent) exists on disk but is not indexed in the database."
                ))
            }
        }

        // 3. Broken or dangling aliases
        let aliases = try await store.allAliasRecords()
        for alias in aliases {
            if !fm.fileExists(atPath: alias.path) {
                report.issues.append(VerificationReport.Issue(
                    severity: .warning,
                    title: "Broken alias",
                    detail: "Alias at \(alias.path) does not exist on disk."
                ))
            }
        }

        // 4. Orphaned suggestions
        let orphanedSuggestions = try await store.orphanedSuggestionsCount()
        if orphanedSuggestions > 0 {
            report.issues.append(VerificationReport.Issue(
                severity: .info,
                title: "Orphaned suggestions",
                detail: "\(orphanedSuggestions) tag suggestion(s) belong to deleted documents."
            ))
        }

        // 5. Orphaned value icons
        let orphanedIcons = try await store.orphanedIconsCount()
        if orphanedIcons > 0 {
            report.issues.append(VerificationReport.Issue(
                severity: .info,
                title: "Orphaned value icons",
                detail: "\(orphanedIcons) custom icon(s) belong to removed fields."
            ))
        }

        // 6. Orphaned FTS index rows
        let orphanedFTS = try await store.orphanedFTSCount()
        if orphanedFTS > 0 {
            report.issues.append(VerificationReport.Issue(
                severity: .error,
                title: "Orphaned search rows",
                detail: "\(orphanedFTS) search index entry(ies) have no corresponding document."
            ))
        }

        return report
    }
}
