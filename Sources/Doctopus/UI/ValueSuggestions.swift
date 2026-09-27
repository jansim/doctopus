import SwiftUI

/// The values already in use, offered while a field is typed into, so the
/// correspondent a model spelled one way is picked again rather than typed a
/// second way.
enum ValueSuggestions {
    static let limit = 8

    /// None while the text is still `current`, which would open the list on
    /// every click into a filled-in field.
    static func matches(_ candidates: [String], for text: String, current: String = "") -> [String] {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, text != current, !candidates.contains(query) else { return [] }
        var starting: [String] = [], containing: [String] = []
        for candidate in candidates {
            if candidate.range(of: query, options: [.caseInsensitive, .diacriticInsensitive, .anchored]) != nil {
                starting.append(candidate)
            } else if candidate.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
                containing.append(candidate)
            }
        }
        return Array((starting + containing).prefix(limit))
    }
}

extension View {
    func valueSuggestions(_ candidates: [String], for text: String, current: String = "") -> some View {
        textInputSuggestions {
            ForEach(ValueSuggestions.matches(candidates, for: text, current: current), id: \.self) { value in
                Text(value).textInputCompletion(value)
            }
        }
    }
}
