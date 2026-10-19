import SwiftUI
import AppKit

/// Window and pane state that has to survive a relaunch, and the library settings beside it.
extension UITest {
    static func uiStatePersists(_ model: AppModel) async {
        model.collapsedFolders = ["/tmp/one", "/tmp/two"]
        model.listColumns[visibility: "size"] = .hidden

        let folders: [String]? = await settled(model, "sidebar_collapsed_v1")
        Check.that("collapsed folders are persisted", folders?.sorted() == ["/tmp/one", "/tmp/two"],
                   folders?.joined(separator: ", ") ?? "nothing stored")

        let columns: TableColumnCustomization<DocumentRow>? = await settled(model, "list_columns_v1")
        Check.that("column layout is persisted", columns?[visibility: "size"] == .hidden)

        model.setSort(.name, ascending: true)
        let sort: StoredSort? = await settled(model, "list_sort_v1") {
            $0.field == "name" && $0.ascending
        }
        Check.that("sort order is persisted", sort?.field == "name" && sort?.ascending == true,
                   sort.map { "\($0.field) \($0.ascending ? "ascending" : "descending")" } ?? "nothing stored")

        model.viewMode = .gallery
        model.settings.galleryThumbnailSize = 190
        _ = await settle {
            Preferences.appWide.viewMode == .gallery && Preferences.appWide.galleryThumbnailSize == 190
        }
        let stored = Preferences.appWide
        Check.that("view mode and thumbnail size are persisted",
                   stored.viewMode == .gallery && stored.galleryThumbnailSize == 190,
                   "\(stored.viewMode.rawValue) at \(Int(stored.galleryThumbnailSize))")

        let blob = await settledRaw(model, AppSettings.storageKey)
        let appWideKeys = ["remoteAPIKey", "viewMode"].filter { blob?.contains($0) == true }
        Check.that("a library's own copy carries no app-wide settings",
                   blob != nil && appWideKeys.isEmpty,
                   blob == nil ? "nothing stored"
                       : (appWideKeys.isEmpty ? "library keys only" : appWideKeys.joined(separator: ", ")))

        let inLibrary: LibrarySettings? = await settled(model, AppSettings.storageKey)
        Check.that("what the blob holds is the library's own half", inLibrary != nil,
                   inLibrary == nil ? "nothing stored" : "stored")

        let partial = AppWideSettings.decoded(
            from: Data(#"{"viewMode":"Gallery","galleryThumbnailSize":190}"#.utf8))
        Check.that("a blob missing app-wide keys keeps the ones it has",
                   partial.viewMode == .gallery && partial.galleryThumbnailSize == 190
                       && partial.remoteEndpoint == AppWideSettings().remoteEndpoint,
                   "\(partial.viewMode.rawValue) at \(Int(partial.galleryThumbnailSize))")

        let partialLibrary = LibrarySettings.decoded(from: Data(#"{"derivedTemplate":"{type}"}"#.utf8))
        Check.that("a blob missing library keys keeps the ones it has",
                   partialLibrary.derivedTemplate == "{type}"
                       && partialLibrary.namingTemplate == LibrarySettings().namingTemplate,
                   "derived template \(partialLibrary.derivedTemplate)")

        model.viewMode = .list
        model.setSort(.docDate, ascending: false)
    }

    private struct StoredSort: Codable {
        var field: String
        var ascending: Bool
    }

    private static func settled<T: Decodable>(_ model: AppModel, _ key: String,
                                              until: (T) -> Bool = { _ in true }) async -> T? {
        var last: T?
        _ = await settledRaw(model, key) { raw in
            guard let decoded = try? JSONDecoder().decode(T.self, from: Data(raw.utf8)) else { return false }
            last = decoded
            return until(decoded)
        }
        return last
    }

    private static func settledRaw(_ model: AppModel, _ key: String,
                                   until: (String) -> Bool = { _ in true }) async -> String? {
        var last: String?
        for _ in 0..<20 {
            var raw = Preferences.uiState(key)
            if raw == nil, let store = model.library?.store {
                raw = (try? await store.setting(key)) ?? nil
            }
            if let raw {
                last = raw
                if until(raw) { return raw }
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return last
    }
}
