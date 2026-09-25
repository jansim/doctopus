import SwiftUI
import AppKit

struct FilingOption: Identifiable, Hashable {
    enum Kind { case current, rule, suggested, alias, similar, chosen }
    var id: String { path }
    var path: String
    var kind: Kind
    var reason: String?
}

struct FilingEditor: View {
    enum Mode {
        case review
        case sheet(dismiss: () -> Void)
    }

    @Environment(AppModel.self) private var model
    let detail: DocumentDetail
    let mode: Mode
    var version: KeptVersion?
    /// Pending rule matches, reviewed together with the folder: a rule's move is one of the folders.
    var ruleMatches: [RuleMatch] = []

    @State private var primary: String
    @State private var secondaries: Set<String>
    @State private var chosen: [FilingOption] = []
    /// Set once the folder is picked by hand, so a rule match arriving late does not override it.
    @State private var touched = false
    @State private var choices = RuleMatchChoices()

    init(detail: DocumentDetail, mode: Mode, version: KeptVersion? = nil, ruleMatches: [RuleMatch] = []) {
        self.detail = detail
        self.mode = mode
        self.version = version
        self.ruleMatches = ruleMatches
        if case .review = mode {
            _primary = State(initialValue: detail.defaultFolder)
        } else {
            _primary = State(initialValue: detail.row.directory)
        }
        _secondaries = State(initialValue: Set(detail.folderAliases.map {
            ($0 as NSString).deletingLastPathComponent }))
    }

    private var row: DocumentRow { detail.row }
    private var arrival: Arrival { Arrival(row) }
    /// A rule's folder comes first: the rule is what the user asked for.
    /// Rules that disagree on it leave the pick to the user.
    private var startingPrimary: String {
        if case .review = mode { return (folderConflict ? nil : ruleFolders.first?.path) ?? detail.defaultFolder }
        return row.directory
    }
    private var conflicts: [RuleMatch.Conflict] { RuleMatch.conflicts(among: ruleMatches) }
    private var folderConflict: Bool { conflicts.contains { $0.kind == .moveFile } }
    /// Picking the folder by hand settles which rule's move wins; the ticks settle the rest.
    private func isSettled(_ conflict: RuleMatch.Conflict) -> Bool {
        conflict.kind == .moveFile ? touched : choices.isSettled(conflict)
    }
    private var unsettled: Bool { !conflicts.allSatisfy(isSettled) }
    private var ruleFolders: [(match: RuleMatch, path: String)] {
        ruleMatches.compactMap { match in
            match.moveTarget.flatMap { rulePath($0) }.map { (match: match, path: $0) }
        }
    }
    private var rewrites: Bool {
        guard let version else { return false }
        return (version == .optimized) != detail.isOptimized
    }
    private var library: Library? { model.library }
    private var existingSecondaries: Set<String> {
        Set(detail.folderAliases.map { ($0 as NSString).deletingLastPathComponent })
    }
    private var changed: Bool { primary != row.directory || secondaries != existingSecondaries }

    private func rulePath(_ folder: String) -> String? {
        guard let library else { return nil }
        let url = library.root.appendingPathComponent(folder, isDirectory: true)
        // A move to the top level is shown by the library's own name.
        if folder == library.root.lastPathComponent, !FileManager.default.fileExists(atPath: url.path) {
            return library.root.path
        }
        return Store.canonical(url.standardizedFileURL.path)
    }

    /// A rule's move is taken exactly when its folder is where the file will live.
    private func ruleDecision(for match: RuleMatch) -> RuleDecision {
        let accepted = (match.changes + match.inEffect).filter { change in
            if case .move(let folder) = change { return rulePath(folder) == primary }
            return choices.isAccepted(change, of: match.ruleID)
        }
        return RuleDecision(match: match, accepted: Set(accepted))
    }

    private var options: [FilingOption] {
        let here = detail.pathSuggestions.first { $0.path == row.directory }
        var out: [FilingOption] = [FilingOption(
            path: row.directory, kind: .current,
            reason: here.map { "Where it is now — \($0.explanation ?? $0.source)" } ?? "Where it is now")]
        out += ruleFolders.map {
            FilingOption(path: $0.path, kind: .rule, reason: "Rule “\($0.match.ruleName)”")
        }
        out += detail.pathSuggestions.map {
            FilingOption(path: $0.path, kind: .suggested, reason: $0.explanation)
        }
        out += existingSecondaries.sorted().map {
            FilingOption(path: $0, kind: .alias, reason: "Already filed here as an alias")
        }
        out += detail.similarFolders.map { FilingOption(path: $0.path, kind: .similar, reason: $0.explanation) }
        out += chosen
        var seen = Set<String>()
        return out.filter { seen.insert($0.path).inserted }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Text("FILE IN")
                    .font(.caption2.weight(.semibold)).foregroundStyle(.secondary).kerning(0.5)
                Spacer()
                Text("Lives here").frame(width: 66)
                    .help("The one folder the file itself is kept in")
                Text("Also here").frame(width: 66)
                    .help("Also file it in these folders as a Finder alias — nothing is copied")
            }
            .font(.caption2).foregroundStyle(.secondary)
            .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 4)

            ScrollView {
                VStack(spacing: 1) {
                    ForEach(options) { option in
                        FilingRow(option: option,
                                  label: displayPath(option.path),
                                  tint: tint,
                                  isPrimary: primary == option.path,
                                  isSecondary: Binding(
                                    get: { secondaries.contains(option.path) && primary != option.path },
                                    set: { on in
                                        if on { secondaries.insert(option.path) } else { secondaries.remove(option.path) }
                                    }),
                                  choosePrimary: {
                                      primary = option.path
                                      secondaries.remove(option.path)
                                      touched = true
                                  })
                    }
                    otherFolderMenu
                        .padding(.horizontal, 8).padding(.top, 4)
                }
                .padding(.horizontal, 4)
            }

            if case .review = mode, !ruleMatches.isEmpty {
                Divider()
                rulesSection
            }
            Divider()
            footer
                .padding(.horizontal, 12).padding(.vertical, 8)
        }
        .onAppear(perform: adoptRuleFolder)
        .onChange(of: ruleFolders.first?.path) { adoptRuleFolder() }
    }

    /// Rule matches load after the detail, so their folder is taken up when it arrives.
    private func adoptRuleFolder() {
        guard case .review = mode, !touched, !folderConflict,
              let path = ruleFolders.first?.path, primary != path else { return }
        primary = path
        secondaries.remove(path)
    }

    /// What each rule would do besides moving it, ticked on by default. Where
    /// rules disagree, one has to be picked before Accept.
    private var rulesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(conflicts) { conflict in
                let settled = isSettled(conflict)
                Label {
                    Text(conflict.summary + (settled ? "." : conflict.kind == .moveFile
                                             ? " — pick the folder above." : " — tick one."))
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: settled ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.purple)
            }
            ForEach(ruleMatches) { match in
                let decision = ruleDecision(for: match)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        RuleMatchBadge(size: 14, muted: decision.accepted.isEmpty,
                                       conflicting: conflicts.contains { $0.options.contains { $0.ruleID == match.ruleID } })
                        Text(match.ruleName).font(.callout.weight(.semibold)).lineLimit(1)
                        if let target = match.moveTarget {
                            Text(decision.accepted.contains(.move(to: target))
                                 ? "files it in \(target)" : "wants it in \(target)")
                                .font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.head)
                        }
                        Spacer(minLength: 4)
                        if decision.isPartial {
                            Text(decision.accepted.isEmpty ? "Left out" : "Partly")
                                .font(.caption2).foregroundStyle(.secondary)
                                .help("Accepting marks this document as an outlier for “\(match.ruleName)”, so the rule stops pointing out what was left")
                        }
                    }
                    ForEach((match.changes + match.inEffect).filter { $0.kind != .moveFile }, id: \.self) { change in
                        Toggle(isOn: Binding(
                            get: { choices.isAccepted(change, of: match.ruleID) },
                            set: { choices.set($0, change, of: match.ruleID, conflicts: conflicts) })) {
                            Label {
                                Text(change.label + (match.inEffect.contains(change) ? " (in effect)" : ""))
                                    .lineLimit(1).truncationMode(.middle)
                            } icon: {
                                Image(systemName: change.icon)
                            }
                            .font(.caption)
                        }
                        .toggleStyle(.checkbox)
                        .padding(.leading, 20)
                    }
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.purple.opacity(0.05))
    }

    @ViewBuilder
    private var otherFolderMenu: some View {
        if let library {
            Menu {
                if let rootNode = library.folders.first {
                    Button("\(library.displayName) (top level)") { choose(rootNode.path) }
                    FolderMenuItems(nodes: rootNode.children) { choose($0) }
                }
                Divider()
                Button("New Folder…") { newFolder(in: library) }
                Button("Choose in Finder…") { pick(in: library) }
            } label: {
                Label("Other Folder…", systemImage: "folder.badge.plus")
                    .font(.callout)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var tint: Color {
        if case .review = mode { return arrival.tint }
        return .accentColor
    }

    private func choose(_ path: String) {
        if !options.contains(where: { $0.path == path }) {
            chosen.append(FilingOption(path: path, kind: .chosen, reason: "Chosen by you"))
        }
        primary = path
        secondaries.remove(path)
        touched = true
    }

    private func newFolder(in library: Library) {
        guard let typed = TextPrompt.ask(
            title: "New Folder",
            message: "A folder inside \(library.displayName). Use / for folders within folders, like Finances/Utilities. It is created when you apply.",
            initial: "", confirm: "Add") else { return }
        // Only plain names: no way out of the library, and not into its index.
        let parts = typed.split(separator: "/")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != "." && $0 != ".." && !$0.hasSuffix(".doctopus") }
        guard !parts.isEmpty else { return }
        let url = parts.reduce(library.root) { $0.appendingPathComponent($1, isDirectory: true) }
        choose(url.path)
    }

    private func pick(in library: Library) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: primary)
        panel.prompt = "File Here"
        panel.message = "Choose a folder inside \(library.displayName)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let path = Store.canonical(url.standardizedFileURL.path)
        guard library.owns(path: path), !FileScanner.isInsideLibraryContainer(url) else {
            model.errorMessage = "“\(url.lastPathComponent)” is outside \(library.displayName). A document can only be filed within its own library."
            return
        }
        choose(path)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            switch mode {
            case .review:
                Text(plan)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if primary != startingPrimary || secondaries != existingSecondaries || !choices.declined.isEmpty {
                    Button("Revert") {
                        primary = startingPrimary
                        secondaries = existingSecondaries
                        choices = RuleMatchChoices()
                        touched = false
                    }
                }
                Button(reviewTitle) { accept() }
                    .keyboardShortcut(.return, modifiers: [.command])
                    .buttonStyle(.borderedProminent)
                    .tint(arrival.tint)
                    .disabled(unsettled || (!changed && !rewrites && row.approved && ruleMatches.isEmpty))
                    .help("\(plan) (⌘↩)")
            case .sheet(let dismiss):
                Text("The file lives in one folder. Tick others to file it there too, as a Finder alias — nothing is copied.")
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("File") {
                    apply(approve: false, advance: false)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!changed)
            }
        }
    }

    /// One word for finishing the review, whatever it takes; the plan says what that is.
    private var reviewTitle: String {
        if row.approved, !changed, ruleMatches.isEmpty, rewrites {
            return version == .optimized ? "Optimize" : "Restore Original"
        }
        return "Accept"
    }

    /// What Accept will do, in the order it happens.
    private var plan: String {
        if unsettled { return "The matching rules disagree — choose between them first." }
        var steps: [String] = []
        if primary != row.directory { steps.append("move to \(displayPath(primary))") }
        let adding = secondaries.subtracting(existingSecondaries).count
        let dropping = existingSecondaries.subtracting(secondaries).count
        if adding > 0 { steps.append("also file in \(adding) more folder\(adding == 1 ? "" : "s")") }
        if dropping > 0 { steps.append("remove \(dropping) alias\(dropping == 1 ? "" : "es")") }
        for match in ruleMatches {
            let decision = ruleDecision(for: match)
            let others = decision.toApply.filter { $0.kind != .moveFile }
            if !others.isEmpty {
                steps.append(others.count == 1 ? others.first!.label.lowercasedFirst
                             : "apply \(others.count) changes from “\(match.ruleName)”")
            }
            if decision.isPartial { steps.append("leave the rest of “\(match.ruleName)” out") }
        }
        if rewrites { steps.append(version == .optimized ? "optimize" : "restore the original") }
        if !row.approved || !ruleMatches.isEmpty { steps.append("approve") }
        guard let first = steps.first else { return "Nothing to change." }
        steps[0] = first.prefix(1).uppercased() + first.dropFirst()
        return steps.joined(separator: " · ")
    }

    private func accept() {
        touched = true
        model.accept(row, in: URL(fileURLWithPath: primary, isDirectory: true), alsoIn: secondaries,
                     rules: ruleMatches.map(ruleDecision(for:)), version: version,
                     advance: model.selection.isQueueMode)
    }

    private func apply(approve: Bool, advance: Bool) {
        model.file(row, in: URL(fileURLWithPath: primary, isDirectory: true), alsoIn: secondaries,
                   approve: approve, version: version,
                   advance: advance && model.selection.isQueueMode)
    }

    private func displayPath(_ path: String) -> String {
        guard let library else { return path }
        let root = library.root.path
        if path == root { return "\(library.displayName) (top level)" }
        if path.hasPrefix(root + "/") { return String(path.dropFirst(root.count + 1)) }
        return path
    }
}

private struct FilingRow: View {
    let option: FilingOption
    let label: String
    let tint: Color
    let isPrimary: Bool
    @Binding var isSecondary: Bool
    let choosePrimary: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(isPrimary ? tint : option.kind == .rule ? Color.purple : Color.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(label)
                        .lineLimit(1).truncationMode(.head)
                        .fontWeight(isPrimary ? .semibold : .regular)
                    if option.kind == .current {
                        Text("current").font(.caption2).foregroundStyle(.secondary)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                }
                if let reason = option.reason {
                    Text(reason).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            Image(systemName: isPrimary ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(isPrimary ? tint : .secondary)
                .frame(width: 66)
                .accessibilityLabel(isPrimary ? "Lives here" : "Make this where it lives")
            Toggle("", isOn: $isSecondary)
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(isPrimary)
                .frame(width: 66)
                .help(isPrimary ? "The file itself lives here" : "Also file it here, as a Finder alias")
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background {
            RoundedRectangle(cornerRadius: 6)
                .fill(isPrimary ? tint.opacity(0.14)
                      : hovering ? Color.primary.opacity(0.05) : .clear)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: choosePrimary)
        .help(option.reason ?? label)
    }

    private var icon: String {
        switch option.kind {
        case .current: return "folder"
        case .rule: return "line.3.horizontal.decrease.circle"
        case .suggested: return "sparkles"
        case .alias: return "arrow.up.forward.square"
        case .similar: return "square.stack"
        case .chosen: return "folder.badge.plus"
        }
    }
}

struct FolderMenuItems: View {
    let nodes: [FolderNode]
    let action: (String) -> Void

    var body: some View {
        ForEach(nodes) { node in
            if node.children.isEmpty {
                Button(node.name) { action(node.path) }
            } else {
                Menu(node.name) {
                    Button("File in “\(node.name)”") { action(node.path) }
                    Divider()
                    AnyView(FolderMenuItems(nodes: node.children, action: action))
                }
            }
        }
    }
}

struct FilingSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let row: DocumentRow
    @State private var detail: DocumentDetail?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Thumbnail(url: row.url, mtime: row.mtime, size: .row,
                          width: 24, height: 31, cornerRadius: 2)
                Text("File “\(row.displayTitle)”").font(.headline).lineLimit(1)
                Spacer()
            }
            .padding(12)
            Divider()
            if let detail {
                FilingEditor(detail: detail, mode: .sheet(dismiss: { dismiss() }))
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 560, height: 400)
        .task { detail = await model.loadDetail(row.id) }
    }
}

private extension String {
    var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() }
}
