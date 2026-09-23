import SwiftUI
import AppKit

/// Original vs optimized, side by side; an unoptimized file is previewed on a throwaway copy.
struct VersionPicker: View {
    @Environment(AppModel.self) private var model
    let detail: DocumentDetail
    @Binding var version: KeptVersion

    @State private var preview: OptimizationPreview?
    @State private var trying: Bool

    init(detail: DocumentDetail, version: Binding<KeptVersion>) {
        self.detail = detail
        _version = version
        _trying = State(initialValue: !detail.isOptimized)
    }

    private var row: DocumentRow { detail.row }
    private var arrival: Arrival { Arrival(row) }

    static func applies(to detail: DocumentDetail) -> Bool {
        if detail.isOptimized { return detail.originalFileURL != nil }
        return detail.row.ext.lowercased() == "pdf"
    }

    private var originalURL: URL? { detail.isOptimized ? detail.originalFileURL : row.url }
    private var optimizedURL: URL? { detail.isOptimized ? row.url : preview?.url }
    private var originalSize: Int64? { detail.isOptimized ? row.originalSize : row.size }
    private var optimizedSize: Int64? { detail.isOptimized ? row.size : preview?.newSize }
    private var nothingToGain: Bool { !detail.isOptimized && !trying && preview == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("VERSION")
                    .font(.caption2.weight(.semibold)).foregroundStyle(.secondary).kerning(0.5)
                Spacer()
                Picker("Version", selection: $version) {
                    Text("Original").tag(KeptVersion.original)
                    Text("Optimized").tag(KeptVersion.optimized)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
                .disabled(nothingToGain)
                Button {
                    compare()
                } label: {
                    Image(systemName: "rectangle.split.2x1")
                }
                .buttonStyle(.borderless)
                .disabled(originalURL == nil || optimizedURL == nil)
                .help("Compare the two in Quick Look — the arrow keys flip between them")
            }
            HStack(spacing: 8) {
                card(.original, url: originalURL, size: originalSize, note: nil)
                card(.optimized, url: optimizedURL, size: optimizedSize, note: optimizedNote)
            }
            Text(explanation)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .task(id: row.id) { await tryOptimizing() }
        .onDisappear { preview?.discard() }
    }

    private func card(_ kind: KeptVersion, url: URL?, size: Int64?, note: String?) -> some View {
        let chosen = version == kind
        return HStack(spacing: 8) {
            ZStack {
                if let url {
                    Thumbnail(url: url, mtime: row.mtime, size: .row,
                              width: 30, height: 39, cornerRadius: 2)
                } else if kind == .optimized, trying {
                    ProgressView().controlSize(.small).frame(width: 30, height: 39)
                } else {
                    Image(systemName: "doc").foregroundStyle(.tertiary).frame(width: 30, height: 39)
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 3) {
                    Text(kind == .original ? "Original" : "Optimized")
                        .font(.caption.weight(chosen ? .semibold : .regular))
                    if chosen {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption2).foregroundStyle(arrival.tint)
                    }
                }
                Text(size.map(ByteFormat.string) ?? " ")
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                if let note {
                    Text(note).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if let url {
                Button {
                    QuickLookController.shared.toggle(urls: [url])
                } label: {
                    Image(systemName: "eye").font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Quick Look the \(kind == .original ? "original" : "optimized") file")
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 6)
                .fill(chosen ? arrival.tint.opacity(0.12) : Color.primary.opacity(0.03))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(chosen ? arrival.tint.opacity(0.7) : Color.primary.opacity(0.1),
                              lineWidth: chosen ? 1.5 : 1)
        }
        .contentShape(Rectangle())
        .onTapGesture { if url != nil { version = kind } }
        .opacity(url == nil && !(kind == .optimized && trying) ? 0.6 : 1)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(kind == .original ? "Keep the original" : "Keep the optimized file")
    }

    private var optimizedNote: String? {
        if trying { return "Trying on a copy…" }
        guard let original = originalSize, let optimized = optimizedSize, original > 0 else {
            return nothingToGain ? "Nothing to gain" : nil
        }
        let saving = 1 - Double(optimized) / Double(original)
        return "\(Int((saving * 100).rounded()))% smaller"
    }

    private var explanation: String {
        if nothingToGain { return "This file is already compact, so it is kept as it is." }
        switch (version, detail.isOptimized, row.fromOutside) {
        case (.optimized, true, true):
            return "Approving keeps the optimized file and deletes the original."
        case (.optimized, true, false):
            return "Stays optimized. The original is kept, so it can still be reverted."
        case (.optimized, false, true):
            return "Approving optimizes the file."
        case (.optimized, false, false):
            return "Approving optimizes the file. The original is kept, so it can be reverted."
        case (.original, true, _):
            return "Approving puts the original back in place of the optimized file."
        case (.original, false, _):
            return "The file is kept exactly as it is."
        }
    }

    private func compare() {
        guard let originalURL, let optimizedURL else { return }
        QuickLookController.shared.toggle(urls: [originalURL, optimizedURL],
                                          startingAt: version == .original ? originalURL : optimizedURL)
    }

    private func tryOptimizing() async {
        guard !detail.isOptimized, preview == nil else { return }
        trying = true
        // Debounced, so arrowing through the list doesn't optimize every row passed.
        try? await Task.sleep(for: .milliseconds(350))
        guard !Task.isCancelled else { trying = false; return }
        let result = await model.optimizationPreview(of: row)
        trying = false
        guard !Task.isCancelled else {
            result?.discard()
            return
        }
        preview = result
        if result == nil { version = .original }
    }
}
