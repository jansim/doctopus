import SwiftUI

/// Where a group of settings is kept. Settings follow the front window, which
/// the window chrome does not say, and a pane like Intelligence mixes both, so
/// every section says.
enum SettingsScope { case library, app }

struct ScopeBadge: View {
    @Environment(AppModel.self) private var model
    let scope: SettingsScope

    var body: some View {
        let (title, icon, help): (String, String, String) = switch scope {
        case .library: (model.library?.displayName ?? "This library", "folder",
                        "Kept in this library's folder and travels with it. Other libraries have their own.")
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
