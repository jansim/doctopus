import SwiftUI
import AppKit

/// The Intelligence and Rules panes of Settings, and the rule editor.
extension UITest {
    static func intelligencePaneDraws(_ model: AppModel, snapshots: String?) async {
        let before = model.settings.llmBackend
        defer { model.settings.llmBackend = before }
        for backend in LLMBackend.allCases {
            model.settings.llmBackend = backend
            let (window, host) = host(IntelligenceSettings().environment(model),
                                      size: NSSize(width: 620, height: 470))
            defer { window.orderOut(nil) }
            try? await Task.sleep(for: .seconds(1))
            if let dir = snapshots { snapshot(host, to: dir + "/intelligence-\(backend.rawValue).png") }
            Check.that("the \(backend.label) settings pane draws", inkedRows(host) > 20,
                       "\(inkedRows(host)) rows with ink")
        }
    }

    static func ruleEditorDraws(_ model: AppModel, snapshots: String?) async {
        guard let library = model.library,
              let rule = (try? await library.store.rules())?.first else {
            Check.that("the rule editor draws", false, "no rule to edit"); return
        }
        var full = rule
        full.requiresAll = true
        full.conditions.append(RuleCondition(field: .filename, pattern: "credit note", negated: true))
        full.conditions.append(RuleCondition(field: .correspondent, pattern: "acme", mode: .fuzzy))
        full.actions = RuleActionKind.allCases.map {
            RuleAction(kind: $0, value: rule.action($0) ?? $0.placeholder)
        }

        for (label, subject) in [("one condition", rule), ("every condition and action", full)] {
            let editor = RuleEditor(rule: subject, library: library) { _ in }
            let (window, host) = host(editor.environment(model), size: NSSize(width: 580, height: 600))
            defer { window.orderOut(nil) }
            try? await Task.sleep(for: .seconds(1))
            if let dir = snapshots {
                snapshot(host, to: dir + "/rule-editor-\(subject.conditions.count).png")
            }
            Check.that("the rule editor draws a rule with \(label)", inkedRows(host) > 20,
                       "\(inkedRows(host)) rows with ink")
        }
    }

    static func rulesPaneDraws(_ model: AppModel, snapshots: String?) async {
        let (window, host) = host(RulesSettings().environment(model),
                                  size: NSSize(width: 620, height: 470))
        defer { window.orderOut(nil) }
        try? await Task.sleep(for: .seconds(1))
        if let dir = snapshots { snapshot(host, to: dir + "/rules-pane.png") }
        Check.that("the rules pane draws", inkedRows(host) > 20, "\(inkedRows(host)) rows with ink")

        let rules = (try? await model.library?.store.rules()) ?? []
        Check.that("every rule says what it looks for and what it does",
                   !rules.isEmpty && rules.allSatisfy {
                       $0.conditionSummary != "—" && !$0.actionSummary.isEmpty
                   })

        if let rule = rules.first {
            model.editRule(rule.id)
            let taken = await settle({ model.ruleToEdit == nil }, timeout: 5)
            Check.that("the rules pane opens a rule asked for from a conflict", taken)
        }
        model.editRule(-1)
        let dropped = await settle({ model.ruleToEdit == nil }, timeout: 5)
        Check.that("the rules pane drops a request for a rule that has gone", dropped)
    }
}
