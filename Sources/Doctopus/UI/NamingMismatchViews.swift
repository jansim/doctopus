import SwiftUI

/// A filename the naming template would not give, pointed out in the
/// inspector the way a rule match is, in orange rather than purple.
struct NamingMismatchSection: View {
    @Environment(AppModel.self) private var model
    let row: DocumentRow

    var body: some View {
        if let mismatch = model.namingMismatch(for: row) {
            Section2("Naming") {
                NamingMismatchCard(mismatch: mismatch, row: row)
            }
        }
    }
}

struct NamingMismatchCard: View {
    @Environment(AppModel.self) private var model
    let mismatch: NamingMismatch
    let row: DocumentRow

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            VStack(alignment: .leading, spacing: 5) {
                MismatchCardHeader(kind: .naming, title: "Name differs from the template",
                                   suppressed: mismatch.suppressed)
                Label {
                    Text("Rename to \(mismatch.expected)")
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: Mismatch.naming.symbol)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .opacity(mismatch.suppressed ? 0.6 : 1)

            HStack(spacing: 8) {
                if mismatch.suppressed {
                    Button("Stop Suppressing") { model.setNamingSuppressed(false, for: row) }
                        .help("Point out that this name differs from the template again")
                } else {
                    Button("Rename") { model.renameToTemplate(row) }
                        .buttonStyle(.borderedProminent)
                        .tint(Mismatch.naming.tint)
                        .help("Rename the file to “\(mismatch.expected)”")
                    Button("Suppress") { model.setNamingSuppressed(true, for: row) }
                        .help("Keep this name: the template leaves it alone and stops pointing it out")
                }
            }
            .controlSize(.small)
        }
        .mismatchCard(.naming, suppressed: mismatch.suppressed)
    }

    static func help(_ mismatch: NamingMismatch) -> String {
        "Name differs from the naming template\nRename to \(mismatch.expected)"
    }
}
