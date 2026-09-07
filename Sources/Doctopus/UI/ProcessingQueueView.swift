import SwiftUI

/// Recently filed items with confidence badges, the rule that fired, and an
/// Approved / Needs Review toggle.
struct ProcessingQueueView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.queue.isEmpty {
                ContentUnavailableView("Nothing processed yet", systemImage: "clock.arrow.circlepath",
                                       description: Text("Imports, scans, moves and optimizations appear here as they happen."))
            } else {
                List {
                    ForEach(grouped, id: \.0) { day, entries in
                        Section(day) {
                            ForEach(entries) { entry in
                                QueueRow(entry: entry)
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private var header: some View {
        HStack {
            let pending = model.queue.filter { !$0.approved }.count
            if pending > 0 {
                Label("\(pending) awaiting review", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout.weight(.medium))
            } else {
                Label("All caught up", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.callout.weight(.medium))
            }
            Spacer()
            Button("Approve All") { model.approveAll() }
                .disabled(pending == 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private var grouped: [(String, [ProcessingEntry])] {
        let cal = Calendar.current
        var order: [String] = []
        var buckets: [String: [ProcessingEntry]] = [:]
        for entry in model.queue {
            let key: String
            if cal.isDateInToday(entry.at) { key = "Today" }
            else if cal.isDateInYesterday(entry.at) { key = "Yesterday" }
            else { key = entry.at.formatted(date: .abbreviated, time: .omitted) }
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(entry)
        }
        return order.map { ($0, buckets[$0] ?? []) }
    }
}

private struct QueueRow: View {
    @Environment(AppModel.self) private var model
    let entry: ProcessingEntry

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .frame(width: 18)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.filename)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Badge(entry.action.capitalized, tint: tint)
                    if let c = entry.confidence { ConfidenceBadge(value: c) }
                    if let rule = entry.rule, rule != "none" {
                        Text(rule == "derived" ? "derived path" : rule)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                }
                if let detail = entry.detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                if let to = entry.toPath {
                    HStack(spacing: 4) {
                        if let from = entry.fromPath, from != to {
                            Text(shorten(from)).font(.caption2).foregroundStyle(.tertiary)
                            Image(systemName: "arrow.right").font(.system(size: 7))
                                .foregroundStyle(.tertiary)
                        }
                        Text(shorten(to)).font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 4) {
                Text(entry.at, style: .time)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                Toggle(isOn: Binding(
                    get: { entry.approved },
                    set: { model.setApproved(entry, $0) })) {
                    Text(entry.approved ? "Approved" : "Needs Review")
                        .font(.caption2)
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .help(entry.approved ? "Approved" : "Needs review")
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Show in List") { model.revealQueueEntry(entry) }
            if let to = entry.toPath {
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: to)])
                }
            }
            if entry.fromPath != nil, entry.action == "routed" {
                Button("Undo Move") { undo() }
            }
        }
    }

    private func undo() {
        guard let from = entry.fromPath else { return }
        let destination = URL(fileURLWithPath: from).deletingLastPathComponent()
        Task {
            guard let path = try? await model.store.documentPath(entry.docID) else { return }
            let row = DocumentRow(id: entry.docID, path: path, directory: "", filename: "", ext: "",
                                  size: 0, createdAt: .now, mtime: .now, ocrState: .done,
                                  approved: true, missing: false)
            model.move([row], to: destination)
        }
    }

    private func shorten(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let p = path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path[...]
        return (String(p) as NSString).deletingLastPathComponent
    }

    private var icon: String {
        switch entry.action {
        case "routed": return "arrow.triangle.branch"
        case "optimized": return "arrow.down.circle"
        case "renamed": return "character.cursor.ibeam"
        case "moved": return "folder"
        case "imported": return "tray.and.arrow.down"
        default: return "doc.text.magnifyingglass"
        }
    }

    private var tint: Color {
        if !entry.approved { return .orange }
        switch entry.action {
        case "routed": return .blue
        case "optimized": return .green
        case "renamed", "moved": return .purple
        default: return .secondary
        }
    }
}
