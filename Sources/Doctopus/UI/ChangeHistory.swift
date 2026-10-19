import SwiftUI

/// One change, as the inspector's History and the library's Change History
/// show it, with a way to revert it where there is one.
struct HistoryEventRow: View {
    let event: HistoryEvent
    /// The library's folder, which moves are shown relative to.
    let root: String
    /// Which document it happened to, for the library-wide list.
    var showsDocument = false
    let revert: @MainActor () async -> Void

    @State private var reverting = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: event.action.icon)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(event.action.label).font(.caption).fontWeight(.medium)
                    Text(event.at.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption2).foregroundStyle(.tertiary)
                    if event.reverted {
                        Text("Reverted").font(.caption2).foregroundStyle(.orange)
                    }
                }
                if showsDocument {
                    Text(event.docID == nil ? "Library" : event.filename ?? "A document no longer in the library")
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                if let move = event.move(relativeTo: root) {
                    Text(move).font(.caption2).foregroundStyle(.secondary)
                } else if let note = event.detail?.nilIfBlank {
                    Text(note).font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(event.action == .edited ? 8 : 2)
                }
            }
            .strikethrough(event.reverted, color: .secondary)
            Spacer(minLength: 0)
            if event.revert != nil {
                Button {
                    reverting = true
                    Task {
                        await revert()
                        reverting = false
                    }
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .disabled(reverting)
                .help("Revert this change")
            }
        }
        .contextMenu {
            if event.revert != nil {
                Button("Revert") { Task { await revert() } }
            }
        }
    }
}

/// View › Change History: every change to the library, newest first.
struct ChangeHistorySheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var events: [HistoryEvent] = []
    @State private var limit = ChangeHistorySheet.page
    @State private var loaded = false

    private static let page = 200

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Change History").font(.headline)
            Text("Every change to \(model.library?.displayName ?? "this library"), newest first. "
                 + "Reverting one is a change of its own, which can be reverted in turn. "
                 + "What brought a document into the library cannot be reverted: that would delete it.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            List {
                ForEach(events) { event in
                    HistoryEventRow(event: event, root: model.library?.root.path ?? "",
                                    showsDocument: true) {
                        await model.revert(event)
                        await load()
                    }
                }
                if events.count >= limit {
                    Button("Show More") {
                        limit += Self.page
                        Task { await load() }
                    }
                    .buttonStyle(.link).font(.caption)
                }
            }
            .overlay {
                if loaded && events.isEmpty {
                    ContentUnavailableView("No Changes Yet", systemImage: "clock.arrow.circlepath")
                }
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 560, height: 520)
        .task { await load() }
    }

    private func load() async {
        events = await model.changeLog(limit: limit)
        loaded = true
    }
}
