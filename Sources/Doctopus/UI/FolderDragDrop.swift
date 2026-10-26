import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// An internal folder move carries no file URL, so other windows cannot
/// accidentally import the folder as a set of new documents.
struct FolderDragItem: Codable, Sendable {
    let path: String

    var provider: NSItemProvider {
        guard let data = try? JSONEncoder().encode(self) else { return NSItemProvider() }
        return NSItemProvider(item: data as NSData, typeIdentifier: UTType.doctopusFolder.identifier)
    }
}

extension View {
    @ViewBuilder
    func folderDragSource(path: String, enabled: Bool) -> some View {
        if enabled {
            onDrag { FolderDragItem(path: path).provider }
        } else {
            self
        }
    }
}

@MainActor
enum FolderRuleConfirmation {
    static func ask(_ rules: [Rule], folderName: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = rules.count == 1
            ? "Update the rule that files into “\(folderName)”?"
            : "Update the \(rules.count) rules that file into “\(folderName)”?"
        alert.informativeText = rules.map { "“\($0.name)” → \($0.destination ?? "")" }
            .joined(separator: "\n")
        alert.addButton(withTitle: rules.count == 1 ? "Update Rule" : "Update Rules")
        alert.addButton(withTitle: "Leave As They Are")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
