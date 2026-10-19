import SwiftUI
import AppKit

/// Finished actions said as toasts.
extension UITest {
    static func finishedActionsAreToasts(_ model: AppModel, snapshots: String?) async {
        model.errorMessage = nil
        model.dismissNotice()
        let size = NSSize(width: 620, height: 200)
        let (window, host) = host(Color(nsColor: .windowBackgroundColor)
                                    .frame(width: size.width, height: size.height)
                                    .noticeOverlay(model)
                                    .environment(model), size: size)
        defer { window.orderOut(nil) }
        let blank = inkedRows(host)

        model.optimize(model.documents)
        let toasted = await settle({ model.notice != nil }, timeout: 20)
        try? await Task.sleep(for: .seconds(0.6))
        if let dir = snapshots { snapshot(host, to: dir + "/toast.png") }
        Check.that("a finished action reports as a toast", toasted && model.errorMessage == nil,
                   model.notice?.text ?? model.errorMessage ?? "nothing")
        Check.that("the toast draws", inkedRows(host) > blank + 10, "\(inkedRows(host)) rows with ink")
        let gone = await settle({ model.notice == nil }, timeout: 10)
        Check.that("the toast dismisses itself", gone)

        let backend = model.settings.llmBackend
        model.settings.llmBackend = .off
        defer { model.settings.llmBackend = backend }
        try? await Task.sleep(for: .seconds(0.5))
        model.analyze(Array(model.documents.prefix(1)))
        let alerted = await settle({ model.errorMessage != nil }, timeout: 10)
        Check.that("a failed action is still an alert", alerted && model.notice == nil,
                   model.errorMessage ?? model.notice?.text ?? "nothing")
        model.errorMessage = nil
    }
}
