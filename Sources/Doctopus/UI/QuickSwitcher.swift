import SwiftUI

struct QuickSwitcherSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var selectedIndex = 0

    private var results: [GlobalSearchResult] {
        model.globalSearch(text: query)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                TextField("Jump to document, tag, correspondent, folder…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(14)

            Divider()

            if results.isEmpty {
                VStack(spacing: 8) {
                    Text(query.isEmpty ? "Type to search across documents, tags, correspondents, folders and smart folders" : "No matching objects found")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .frame(height: 240)
            } else {
                List(selection: Binding(
                    get: { results.indices.contains(selectedIndex) ? results[selectedIndex].id : nil },
                    set: { id in
                        if let idx = results.firstIndex(where: { $0.id == id }) {
                            selectedIndex = idx
                        }
                    }
                )) {
                    ForEach(Array(results.enumerated()), id: \.element.id) { index, item in
                        HStack(spacing: 10) {
                            Image(systemName: item.icon)
                                .font(.body)
                                .frame(width: 20)
                                .foregroundStyle(item.category == .tag ? Color.accentColor : Color.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title)
                                    .font(.body.weight(.medium))
                                    .lineLimit(1)
                                if let subtitle = item.subtitle {
                                    Text(subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer()
                            Text(item.category.rawValue)
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.12), in: Capsule())
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            activate(item)
                        }
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
                .frame(height: 320)
            }
        }
        .frame(width: 580)
        .onSubmit {
            if results.indices.contains(selectedIndex) {
                activate(results[selectedIndex])
            }
        }
        .onKeyPress(.downArrow) {
            if selectedIndex < results.count - 1 { selectedIndex += 1 }
            return .handled
        }
        .onKeyPress(.upArrow) {
            if selectedIndex > 0 { selectedIndex -= 1 }
            return .handled
        }
    }

    private func activate(_ item: GlobalSearchResult) {
        switch item.category {
        case .document:
            if let document = item.document {
                model.selection = .all
                model.selectedIDs = [document]
            }
        case .tag:
            if let tagRef = item.tagRef {
                model.selection = .tag(tagRef)
            }
        case .correspondent, .docType:
            if let key = item.fieldKey {
                model.selection = .field(key, item.title)
            }
        case .folder:
            if let path = item.path {
                model.selection = .folder(path)
            }
        case .savedView:
            if let sv = model.savedViews.first(where: { $0.id == item.savedViewID }) {
                model.selectSavedView(sv)
            }
        }
        dismiss()
    }
}
