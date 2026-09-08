import SwiftUI

/// Picks the icon for one value of a field — the symbol beside “Invoice” in the
/// sidebar, as distinct from the field's own icon.
///
/// The grid is a curated set rather than every SF Symbol: the useful ones for
/// filing documents are a small, stable list, and the field below takes any
/// symbol name for anything not in it.
struct IconPicker: View {
    let title: String
    let current: String
    let fallback: String
    let onPick: (String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var filter = ""
    @State private var custom = ""

    private var symbols: [String] {
        guard let needle = filter.nilIfBlank?.lowercased() else { return IconPicker.catalog }
        return IconPicker.catalog.filter { $0.contains(needle) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Icon for “\(title)”").font(.headline)

            TextField("Filter", text: $filter)
                .textFieldStyle(.roundedBorder)

            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(34), spacing: 4), count: 9), spacing: 4) {
                    ForEach(symbols, id: \.self) { symbol in
                        Button { pick(symbol) } label: {
                            Image(systemName: symbol)
                                .font(.system(size: 15))
                                .frame(width: 30, height: 30)
                                .background(symbol == current ? Color.accentColor.opacity(0.25) : .clear,
                                            in: RoundedRectangle(cornerRadius: 5))
                        }
                        .buttonStyle(.plain)
                        .help(symbol)
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(height: 220)

            HStack(spacing: 6) {
                TextField("Any SF Symbol name", text: $custom)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { if valid(custom) { pick(custom) } }
                if !custom.isEmpty {
                    Image(systemName: valid(custom) ? custom : "questionmark")
                        .foregroundStyle(valid(custom) ? .primary : .tertiary)
                        .frame(width: 20)
                }
                Button("Use") { pick(custom) }.disabled(!valid(custom))
            }

            HStack {
                Button("Reset to Default") { onPick(nil); dismiss() }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 380)
    }

    private func valid(_ name: String) -> Bool {
        guard let clean = name.nilIfBlank else { return false }
        return NSImage(systemSymbolName: clean, accessibilityDescription: nil) != nil
    }

    private func pick(_ symbol: String) {
        onPick(symbol)
        dismiss()
    }

    /// Symbols that come up when filing paper.
    static let catalog: [String] = [
        "doc", "doc.text", "doc.richtext", "doc.plaintext", "doc.on.doc", "doc.text.magnifyingglass",
        "newspaper", "book", "book.closed", "text.document", "list.bullet.rectangle",
        "banknote", "eurosign.circle", "dollarsign.circle", "creditcard", "wallet.bifold",
        "chart.line.uptrend.xyaxis", "chart.pie", "percent", "receipt", "cart",
        "building.columns", "building.2", "house", "storefront", "briefcase", "case",
        "person.crop.circle", "person.2", "figure.2.and.child.holdinghands", "graduationcap",
        "stethoscope", "cross.case", "pills", "heart.text.square",
        "car", "airplane", "train.side.front.car", "bicycle", "fuelpump",
        "bolt", "flame", "drop", "leaf", "wifi", "phone", "envelope", "paperplane",
        "shield", "lock", "key", "checkmark.seal", "rosette", "signature", "hammer",
        "wrench.and.screwdriver", "gearshape", "scalemass", "calendar", "clock",
        "paperclip", "tray", "archivebox", "folder", "tag", "bookmark", "flag",
        "star", "pin", "camera", "photo", "map", "globe", "ticket", "gift",
    ]
}
