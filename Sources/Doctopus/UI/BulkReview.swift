import SwiftUI

/// Each kind of arrival starts on its single-document defaults; the outcome is counted before approving.
struct BulkReview: View {
    @Environment(AppModel.self) private var model
    let rows: [DocumentRow]
    @State private var newArrivals = BulkReview.new
    @State private var inLibrary = BulkReview.found
    @State private var suggested: [DocumentRef: String] = [:]
    @State private var confirmingDiscard = false

    private enum Preset: Hashable { case defaults, allNew, allInLibrary, custom }

    private var library: Library? {
        let ids = Set(rows.map(\.library))
        return ids.count == 1 ? ids.first.flatMap(model.library) : nil
    }

    private func rows(_ arrival: Arrival) -> [DocumentRow] { rows.filter { Arrival($0) == arrival } }
    private var present: [Arrival] { Arrival.allCases.filter { !rows($0).isEmpty } }
    private var mixed: Bool { present.count > 1 }

    private func treatment(_ arrival: Arrival) -> Binding<ReviewTreatment> {
        arrival == .new ? $newArrivals : $inLibrary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if mixed { presetPicker }
            ForEach(present, id: \.self) { arrival in
                GroupTreatment(arrival: arrival, count: rows(arrival).count, treatment: treatment(arrival))
            }
            Divider()
            outcome
            Spacer(minLength: 0)
            actions
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: rows.map(\.id)) { await loadSuggestions() }
        .confirmationDialog("Discard what was generated for \(rows.count) documents?",
                            isPresented: $confirmingDiscard) {
            Button("Discard", role: .destructive) { model.discardGeneratedInfo(rows) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Titles, correspondents, types, languages, summaries and dates that were worked out are cleared, with rule tags and pending suggestions. Your own edits and the files themselves are kept.")
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("\(rows.count) documents selected").font(.headline)
            Spacer()
            ForEach(present, id: \.self) { arrival in
                ArrivalBadge(arrival: arrival, count: rows(arrival).count)
            }
        }
    }

    private var presetPicker: some View {
        HStack(spacing: 8) {
            Text("Treat them").font(.caption).foregroundStyle(.secondary)
            Picker("Treat them", selection: Binding(get: { preset }, set: { apply($0) })) {
                Text("Each by its default").tag(Preset.defaults)
                Text("All like new").tag(Preset.allNew)
                Text("All like already in library").tag(Preset.allInLibrary)
                if preset == .custom { Text("Custom").tag(Preset.custom) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
        }
    }

    private static let new = ReviewTreatment.default(fromOutside: true)
    private static let found = ReviewTreatment.default(fromOutside: false)

    private var preset: Preset {
        let (new, found) = (Self.new, Self.found)
        switch (newArrivals, inLibrary) {
        case (new, found): return .defaults
        case (new, new): return .allNew
        case (found, found): return .allInLibrary
        default: return .custom
        }
    }

    private func apply(_ preset: Preset) {
        let (new, found) = (Self.new, Self.found)
        switch preset {
        case .defaults: newArrivals = new; inLibrary = found
        case .allNew: newArrivals = new; inLibrary = new
        case .allInLibrary: newArrivals = found; inLibrary = found
        case .custom: break
        }
    }

    private struct Outcome: Identifiable {
        var id: String { label }
        var label: String
        var icon: String
        var counts: [Arrival: Int]
    }

    private var outcomes: [Outcome] {
        var moves: [Arrival: Int] = [:], stays: [Arrival: Int] = [:]
        var optimized: [Arrival: Int] = [:], original: [Arrival: Int] = [:], asIs: [Arrival: Int] = [:]
        for arrival in present {
            let group = rows(arrival)
            let t = treatment(arrival).wrappedValue
            let moving = t.move ? group.filter { suggested[$0.id] != nil }.count : 0
            moves[arrival] = moving
            stays[arrival] = group.count - moving
            switch t.version {
            case .optimized: optimized[arrival] = group.count
            case .original: original[arrival] = group.count
            case nil: asIs[arrival] = group.count
            }
        }
        return [
            Outcome(label: "Filed in their best suggestion", icon: "sparkles", counts: moves),
            Outcome(label: "Stay where they are", icon: "folder", counts: stays),
            Outcome(label: "Optimized, where it saves space", icon: "arrow.down.circle", counts: optimized),
            Outcome(label: "Original kept", icon: "doc", counts: original),
            Outcome(label: "File left as it is", icon: "lock.doc", counts: asIs),
        ].filter { $0.counts.values.contains { $0 > 0 } }
    }

    private var outcome: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("APPROVING")
                .font(.caption2.weight(.semibold)).foregroundStyle(.secondary).kerning(0.5)
            ForEach(outcomes) { line in
                HStack(spacing: 6) {
                    Image(systemName: line.icon).foregroundStyle(.secondary).frame(width: 16)
                    ForEach(present, id: \.self) { arrival in
                        if let n = line.counts[arrival], n > 0 {
                            Text("\(n)")
                                .font(.caption.monospacedDigit().weight(.semibold))
                                .foregroundStyle(arrival.tint)
                                .frame(minWidth: 18)
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .background(arrival.tint.opacity(0.15), in: Capsule())
                                .help("\(n) \(arrival == .new ? "new" : "already in library")")
                        }
                    }
                    Text(line.label).font(.callout)
                }
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button("Approve \(rows.count)") {
                model.approve(rows, newArrivals: newArrivals, alreadyInLibrary: inLibrary)
            }
            .buttonStyle(.borderedProminent)
            .tint(mixed ? Color.accentColor : (present.first?.tint ?? Color.accentColor))
            .keyboardShortcut(.return, modifiers: [.command])
            .help("⌘↩")
            if let library, let rootNode = library.folders.first {
                Menu("Move All To") {
                    Button("\(library.displayName) (top level)") { moveAll(to: rootNode.path) }
                    FolderMenuItems(nodes: rootNode.children) { moveAll(to: $0) }
                }
                .fixedSize()
            }
            Spacer()
            Button("Discard Generated Info…", role: .destructive) { confirmingDiscard = true }
        }
    }

    private func moveAll(to path: String) {
        model.move(rows, to: URL(fileURLWithPath: path, isDirectory: true))
    }

    private func loadSuggestions() async {
        var found: [DocumentRef: String] = [:]
        for row in rows {
            if let folder = await model.suggestedFolder(for: row) { found[row.id] = folder }
            if Task.isCancelled { return }
        }
        suggested = found
    }
}

private struct GroupTreatment: View {
    let arrival: Arrival
    let count: Int
    @Binding var treatment: ReviewTreatment

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 1.5).fill(arrival.tint).frame(width: 3)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    Image(systemName: arrival.icon).foregroundStyle(arrival.tint)
                    Text("\(count) \(arrival == .new ? "new" : "already in library")")
                        .font(.callout.weight(.semibold))
                }
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                    GridRow {
                        Text("Folder").font(.caption).foregroundStyle(.secondary)
                        Picker("Folder", selection: $treatment.move) {
                            Text("Best suggestion").tag(true)
                            Text("Where they are").tag(false)
                        }
                        .pickerStyle(.segmented).labelsHidden().controlSize(.small).fixedSize()
                    }
                    GridRow {
                        Text("Version").font(.caption).foregroundStyle(.secondary)
                        versionPicker
                    }
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .help(arrival.help)
    }

    private var versionPicker: some View {
        Picker("Version", selection: $treatment.version) {
            Text("Optimized").tag(KeptVersion?.some(.optimized))
            Text("Original").tag(KeptVersion?.some(.original))
            Text("As they are").tag(KeptVersion?.none)
        }
        .pickerStyle(.segmented).labelsHidden().controlSize(.small).fixedSize()
    }
}
