import Foundation

/// A Mustache subset: `{{#name}}…{{/name}}` if set, `{{^name}}…{{/name}}` if not; a tag alone
/// on its line takes the line with it. Never fails, so a user's edit cannot break rendering.
enum PromptTemplate {
    static func render(_ template: String, flags: Set<String>) -> String {
        var rest = Substring(dropStandaloneLines(template))
        var out = ""
        var sections: [(name: Substring, shown: Bool)] = []

        while let open = rest.range(of: "{{") {
            if sections.allSatisfy(\.shown) { out += rest[..<open.lowerBound] }
            guard let close = rest[open.upperBound...].range(of: "}}") else {
                rest = rest[open.lowerBound...]
                break
            }
            let tag = rest[open.upperBound..<close.lowerBound]
            rest = rest[close.upperBound...]
            switch tag.first {
            case "#", "^":
                let name = tag.dropFirst()
                let set = flags.contains(String(name))
                sections.append((name, tag.first == "#" ? set : !set))
            case "/":
                if let i = sections.lastIndex(where: { $0.name == tag.dropFirst() }) {
                    sections.removeSubrange(i...)
                }
            default:
                if sections.allSatisfy(\.shown) { out += "{{\(tag)}}" }
            }
        }
        if sections.allSatisfy(\.shown) { out += rest }
        return out
    }

    private static let standaloneTag = try! NSRegularExpression(
        pattern: #"^[ \t]*(\{\{[#^/][A-Za-z]+\}\})[ \t]*(\r?\n|$)"#,
        options: [.anchorsMatchLines])

    private static func dropStandaloneLines(_ template: String) -> String {
        let whole = NSRange(template.startIndex..., in: template)
        return standaloneTag.stringByReplacingMatches(in: template, range: whole, withTemplate: "$1")
    }
}
