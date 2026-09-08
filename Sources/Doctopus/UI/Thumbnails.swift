import SwiftUI
import AppKit
import QuickLookThumbnailing

/// Shared thumbnail cache.
///
/// `QLThumbnailGenerator` is not cheap, and a scrolling table or a gallery of a
/// few hundred documents would otherwise ask for the same page repeatedly.
/// Entries are keyed by path, size class and modification time, so an edited
/// document re-renders while an untouched one never does.
@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()

    enum SizeClass: Int, Sendable {
        case row      // list view
        case gallery
        case large    // inspector

        var points: CGSize {
            switch self {
            case .row: return CGSize(width: 32, height: 42)
            case .gallery: return CGSize(width: 160, height: 208)
            case .large: return CGSize(width: 108, height: 140)
            }
        }
    }

    private struct Key: Hashable {
        var path: String
        var size: Int
        var mtime: TimeInterval
    }

    private var cache: [Key: NSImage] = [:]
    private var order: [Key] = []
    private var inFlight: [Key: Task<NSImage?, Never>] = [:]
    private let limit = 600

    func cached(_ url: URL, _ size: SizeClass, mtime: Date) -> NSImage? {
        cache[Key(path: url.path, size: size.rawValue, mtime: mtime.timeIntervalSince1970)]
    }

    func thumbnail(for url: URL, size: SizeClass, mtime: Date) async -> NSImage? {
        let key = Key(path: url.path, size: size.rawValue, mtime: mtime.timeIntervalSince1970)
        if let hit = cache[key] { return hit }
        if let running = inFlight[key] { return await running.value }

        let points = size.points
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let task = Task<NSImage?, Never> {
            // `.all` prefers a rendered page and falls back to the file's icon
            // only when there is nothing to render. Asking for `.icon` — as the
            // list rows used to — always returns the generic document badge,
            // never the page itself.
            let request = QLThumbnailGenerator.Request(
                fileAt: url, size: points, scale: scale,
                representationTypes: .all)
            guard let rep = try? await QLThumbnailGenerator.shared
                .generateBestRepresentation(for: request) else { return nil }
            return rep.nsImage
        }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil
        if let image { store(key, image) }
        return image
    }

    private func store(_ key: Key, _ image: NSImage) {
        if cache[key] == nil { order.append(key) }
        cache[key] = image
        // Plain FIFO eviction: recency tracking is not worth the bookkeeping
        // for a cache this small.
        while order.count > limit {
            cache.removeValue(forKey: order.removeFirst())
        }
    }
}

/// Async thumbnail with a document-shaped placeholder, used at every size.
struct Thumbnail: View {
    let url: URL
    let mtime: Date
    var size: ThumbnailCache.SizeClass = .row
    var width: CGFloat
    var height: CGFloat
    var cornerRadius: CGFloat = 3
    var showsShadow = false

    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(.quaternary.opacity(0.6))
                    .overlay {
                        Image(systemName: "doc")
                            .font(.system(size: min(width, height) * 0.4, weight: .light))
                            .foregroundStyle(.tertiary)
                    }
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        // The rendered page is fitted inside the frame, so without this the
        // letterboxed bands either side of it are dead to the mouse and a
        // click near the edge of a thumbnail does nothing at all.
        .contentShape(RoundedRectangle(cornerRadius: cornerRadius))
        .shadow(color: showsShadow ? .black.opacity(0.18) : .clear, radius: 3, y: 1)
        .task(id: "\(url.path)#\(mtime.timeIntervalSince1970)") {
            image = ThumbnailCache.shared.cached(url, size, mtime: mtime)
            if image == nil {
                image = await ThumbnailCache.shared.thumbnail(for: url, size: size, mtime: mtime)
            }
        }
    }
}
