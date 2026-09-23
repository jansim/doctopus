import SwiftUI

/// Where a group of settings is kept. With one library open there is no picker
/// to hint at it, and a pane like Intelligence mixes both, so every section says.
enum SettingsScope { case library, openLibraries, app }

struct ScopeBadge: View {
    @Environment(AppModel.self) private var model
    let scope: SettingsScope

    var body: some View {
        let (title, icon, help): (String, String, String) = switch scope {
        case .library: (model.settingsLibrary?.displayName ?? "This library", "folder",
                        "Kept in this library's folder and travels with it. Other libraries have their own.")
        case .openLibraries: ("Open libraries", "square.stack",
                              "Each library keeps its own copy, and a change here is made in every open library at once.")
        case .app: ("All libraries", "desktopcomputer",
                    "Kept on this Mac and shared by every library. Never stored inside a library's folder.")
        }
        let tint: Color = scope == .library ? .accentColor : .secondary
        Label(title, systemImage: icon)
            .font(.caption.weight(.regular)).labelStyle(.titleAndIcon).lineLimit(1).textCase(nil)
            .foregroundStyle(tint)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(tint.opacity(0.12), in: Capsule())
            .help(help)
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
