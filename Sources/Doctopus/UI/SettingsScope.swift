import SwiftUI

/// Where a group of settings is kept — the same split as `LibrarySettings` and
/// `AppWideSettings`. With only one library open there is no picker to hint
/// at it, and a pane like Intelligence mixes both, so every section says.
enum SettingsScope {
    /// Stored in the library, travels with its folder; each library has its own.
    case library
    /// Stored in each library, but every edit goes to all the open ones.
    case openLibraries
    /// Stored on this Mac, shared by every library, never written into one.
    case app
}

struct ScopeBadge: View {
    @Environment(AppModel.self) private var model
    let scope: SettingsScope

    var body: some View {
        Group {
            switch scope {
            case .library:
                Label(model.settingsLibrary?.displayName ?? "This library", systemImage: "folder")
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.12), in: Capsule())
                    .help("Kept in this library's folder and travels with it. Other libraries have their own.")
            case .openLibraries:
                Label("Open libraries", systemImage: "square.stack")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
                    .help("Each library keeps its own copy, and a change here is made in every open library at once.")
            case .app:
                Label("All libraries", systemImage: "desktopcomputer")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
                    .help("Kept on this Mac and shared by every library. Never stored inside a library's folder.")
            }
        }
        .font(.caption.weight(.regular))
        .labelStyle(.titleAndIcon)
        .lineLimit(1)
        .textCase(nil)
    }
}

struct ScopedHeader: View {
    let title: String
    let scope: SettingsScope

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            ScopeBadge(scope: scope)
        }
    }
}

extension Section where Parent == ScopedHeader, Content: View, Footer == EmptyView {
    init(_ title: String, scope: SettingsScope, @ViewBuilder content: () -> Content) {
        self.init(content: content) { ScopedHeader(title: title, scope: scope) }
    }
}
