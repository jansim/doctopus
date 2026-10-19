import SwiftUI
import AppKit

/// A date control that only reports a day once it is finished with. Typing a
/// date piece by piece would otherwise save, re-file and possibly rename the
/// document after every digit, so keyboard edits stay a draft until Return or
/// the field losing focus. A click in the calendar or on the stepper picks a
/// whole day and goes through at once.
struct DayField: NSViewRepresentable {
    let date: Date
    let onCommit: (Date) -> Void

    func makeNSView(context: Context) -> Field {
        let field = Field()
        field.show(date)
        return field
    }

    func updateNSView(_ field: Field, context: Context) {
        field.onCommit = onCommit
        field.show(date)
    }

    final class Field: NSDatePicker {
        var onCommit: ((Date) -> Void)?
        /// The day last handed in by the model, so a reload that brings back
        /// the same value does not throw away a draft or flash an old day
        /// while a commit is still on its way.
        private var shown: Date?
        /// Nil until the model has handed in a day: the picker's own starting
        /// value, 1 January 2001, must never be taken for an edit.
        private var committed: Date?
        /// Set while a keystroke is being handled, so the change it makes
        /// stays a draft.
        private var typing = false

        override init(frame: NSRect) {
            super.init(frame: frame)
            datePickerStyle = .textField
            datePickerElements = .yearMonthDay
            presentsCalendarOverlay = true
            isBezeled = true
            drawsBackground = true
            // The days are stored on this clock. On the local one, picking
            // 4 March east of Greenwich hands back an instant that is still
            // 3 March in UTC, and the day is saved one off.
            calendar = DayDate.calendar
            timeZone = DayDate.calendar.timeZone
            target = self
            action = #selector(changed)
        }

        required init?(coder: NSCoder) { return nil }

        func show(_ date: Date) {
            let day = DayDate.startOfDay(date)
            guard day != shown else { return }
            shown = day
            guard !isDirty else { return }
            dateValue = day
            committed = day
        }

        private var isDirty: Bool { committed.map { DayDate.startOfDay(dateValue) != $0 } ?? false }

        private func commit() {
            guard isDirty else { return }
            let day = DayDate.startOfDay(dateValue)
            committed = day
            onCommit?(day)
        }

        @objc private func changed() {
            if !typing, NSApp.currentEvent?.type != .keyDown { commit() }
        }

        override func keyDown(with event: NSEvent) {
            switch event.keyCode {
            case 36, 76: commit()                    // Return, Enter
            case 53:                                 // Escape
                if let committed { dateValue = committed }
            default:
                typing = true
                defer { typing = false }
                super.keyDown(with: event)
            }
        }

        override func resignFirstResponder() -> Bool {
            let resigned = super.resignFirstResponder()
            if resigned { commit() }
            return resigned
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil { commit() }
            super.viewWillMove(toWindow: newWindow)
        }
    }
}
