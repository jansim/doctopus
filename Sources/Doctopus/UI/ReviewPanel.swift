import SwiftUI
import AppKit

/// Filing is two decisions per candidate folder: the one folder the file lives
/// in (moved there on apply), and any others it appears in as a Finder alias.
struct ReviewPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.selectedIDs.count == 1, let detail = model.detail,
               model.selectedIDs.contains(detail.row.id) {
                DocumentReview(detail: detail)
                    .id(detail.row.id)
            } else if model.selectedIDs.count > 1 {
                BulkReview(rows: model.selectedRows)
                    .id(model.selectedIDs)
            } else {
                ContentUnavailableView {
                    Label("Nothing selected", systemImage: "checklist")
                } description: {
                    Text("Select a document above to check what was worked out and choose where it lives.")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}

/// Green for a document Doctopus brought in, blue for one already in the library.
enum Arrival: CaseIterable {
    case new, inLibrary

    init(_ row: DocumentRow) { self = row.fromOutside ? .new : .inLibrary }

    var tint: Color { self == .new ? .green : .blue }
    var label: String { self == .new ? "New" : "Already in library" }
    var icon: String { self == .new ? "tray.and.arrow.down.fill" : "books.vertical.fill" }
    var help: String {
        self == .new
            ? "Imported or scanned: approving files it in its best suggestion and keeps it optimized"
            : "Found in the library: approving leaves it where it is, as it is, unless you pick otherwise"
    }
}

struct ArrivalBadge: View {
    let arrival: Arrival
    var count: Int?

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: arrival.icon)
            if let count { Text("\(count)").monospacedDigit().fontWeight(.semibold) }
            Text(arrival.label)
        }
        .font(.caption2.weight(.medium))
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(arrival.tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
        .foregroundStyle(arrival.tint)
        .help(arrival.help)
    }
}

private struct DocumentReview: View {
    @Environment(AppModel.self) private var model
    let detail: DocumentDetail
    @State private var version: KeptVersion
    private var row: DocumentRow { detail.row }
    private var arrival: Arrival { Arrival(row) }

    init(detail: DocumentDetail) {
        self.detail = detail
        _version = State(initialValue: detail.defaultVersion)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(alignment: .top, spacing: 0) {
                GeneratedInfoEditor(detail: detail, version: $version)
                    .frame(minWidth: 250, idealWidth: 330, maxWidth: 400)
                Divider()
                FilingEditor(detail: detail, mode: .review, version: version,
                             ruleMatches: model.pendingRuleMatches(for: row))
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Thumbnail(url: row.url, mtime: row.mtime, size: .row,
                      width: 24, height: 31, cornerRadius: 2)
                .onTapGesture { model.quickLook(startingAt: row) }
                .help("Quick Look")
            VStack(alignment: .leading, spacing: 1) {
                Text(row.displayTitle)
                    .font(.headline)
                    .lineLimit(1).truncationMode(.middle)
                if let queue = row.queue ?? model.documents.first(where: { $0.id == row.id })?.queue,
                   let what = queue.detail {
                    Text(what)
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            ArrivalBadge(arrival: arrival)
            Badge(status.text, tint: status.tint)
                .help(status.help)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .overlay(alignment: .leading) {
            Rectangle().fill(arrival.tint).frame(width: 3)
        }
    }

    /// One status: an approved document is back in review only because a rule would change it.
    private var status: (text: String, tint: Color, help: String) {
        let rules = model.pendingRuleMatches(for: row)
        if !row.approved { return ("Needs review", Color.orange, "Accept to file and approve it") }
        if let rule = rules.first {
            return ("Rule update", Color.purple,
                    "Approved earlier, but “\(rule.ruleName)”\(rules.count > 1 ? " and \(rules.count - 1) more" : "") would still change it")
        }
        return ("Approved", Color.secondary, "Nothing left to review")
    }
}

private struct GeneratedInfoEditor: View {
    @Environment(AppModel.self) private var model
    let detail: DocumentDetail
    @Binding var version: KeptVersion
    @State private var tagInput = ""
    @State private var confirmingDiscard = false
    private var row: DocumentRow { detail.row }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("WORKED OUT")
                    .font(.caption2.weight(.semibold)).foregroundStyle(.secondary).kerning(0.5)
                if let source = detail.metadataSource {
                    Text(sourceLabel(source)).font(.caption2).foregroundStyle(.tertiary)
                    if let c = detail.metadataConfidence { ConfidenceBadge(value: c) }
                }
                Spacer()
                Button("Discard…", role: .destructive) { confirmingDiscard = true }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .help("Throw away what was generated for this document")
                    .disabled(!hasGenerated)
            }
            .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 4)

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    InfoGrid {
                        EditableRow("Title", value: row.title ?? "") {
                            model.editMetadata(row.id, column: "title", value: $0)
                        }
                        ForEach(model.fields) { field in
                            EditableRow(field.name, value: row.values[field.key] ?? "") {
                                model.setFieldValue(row.id, field: field, value: $0)
                            }
                        }
                        InfoRow("Date", alignment: .center) {
                            DatePicker("", selection: Binding(
                                get: { row.docDate ?? row.createdAt },
                                set: { model.setDocumentDate(row.id, $0) }),
                                displayedComponents: .date)
                            .labelsHidden()
                            .datePickerStyle(.compact)
                            .dayResolution()
                        }
                    }
                    if detail.dateCandidates.count > 1 { dateChoices }
                    if let summary = row.summary {
                        Text(summary)
                            .font(.caption).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    tags
                }
                .padding(.horizontal, 12).padding(.bottom, 10)
            }
            if VersionPicker.applies(to: detail) {
                Divider()
                VersionPicker(detail: detail, version: $version)
            }
        }
        .confirmationDialog("Discard what was generated for “\(row.displayTitle)”?",
                            isPresented: $confirmingDiscard) {
            Button("Discard", role: .destructive) { model.discardGeneratedInfo([row]) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The title, correspondent, type, language, summary and date that were worked out are cleared, with the tags rules assigned and every pending suggestion. Your own edits, the extracted text and the file itself are kept — Analyze with Model can fill it in again.")
        }
    }

    private var hasGenerated: Bool {
        detail.metadataSource != nil || !detail.tagSuggestions.isEmpty || !detail.pathSuggestions.isEmpty
            || row.title != nil || row.correspondent != nil || row.docType != nil
    }

    private var dateChoices: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("ALSO FOUND")
                .font(.caption2.weight(.semibold)).foregroundStyle(.secondary).kerning(0.5)
            FlowLayout(spacing: 5) {
                ForEach(detail.dateCandidates) { candidate in
                    let chosen = row.docDate == candidate.date
                    Button {
                        model.setDocumentDate(row.id, candidate.date)
                    } label: {
                        HStack(spacing: 4) {
                            Text(DayDate.display(candidate.date)).font(.caption)
                            Text(candidate.cue ?? candidate.sourceLabel)
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(chosen ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.10),
                                    in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .help(candidate.labelled
                          ? "Labelled “\(candidate.cue ?? "")” \(candidate.sourceLabel)"
                          : "Found \(candidate.sourceLabel)")
                }
            }
        }
    }

    private var tags: some View {
        VStack(alignment: .leading, spacing: 5) {
            FlowLayout(spacing: 4) {
                ForEach(Tag.visible(in: detail.tags), id: \.tag.id) { entry in
                    TagChip(tag: entry.tag, displayName: entry.path, compact: true) {
                        model.removeTag(entry.tag, from: [row])
                    }
                }
                ForEach(detail.tagSuggestions) { suggestion in
                    TagSuggestionChip(
                        suggestion: suggestion, compact: true,
                        onAccept: { model.acceptTagSuggestion(suggestion, for: row) },
                        onDiscard: { model.discardTagSuggestion(suggestion, for: row) })
                }
            }
            TextField("Add tag", text: $tagInput)
                .textFieldStyle(.roundedBorder)
                .font(.caption)
                .onSubmit {
                    guard let name = tagInput.nilIfBlank else { return }
                    model.addTag(name, to: [row])
                    tagInput = ""
                }
        }
    }

    private func sourceLabel(_ s: String) -> String {
        MetadataSource(s).inlineLabel
    }
}

