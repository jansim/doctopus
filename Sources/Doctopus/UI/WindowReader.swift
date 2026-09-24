import SwiftUI
import AppKit

/// Hands a model the `NSWindow` its panes ended up in, which SwiftUI keeps to
/// itself: the workspace needs to know which window is in front, to bring one
/// forward, and to hear when one closes.
struct WindowReader: NSViewRepresentable {
    let model: AppModel

    func makeNSView(context: Context) -> Probe { Probe(model: model) }
    func updateNSView(_ view: Probe, context: Context) {}

    final class Probe: NSView {
        private weak var model: AppModel?
        private var observers: [NSObjectProtocol] = []

        init(model: AppModel) {
            self.model = model
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { return nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopObserving()
            guard let window, let model else { return }
            model.window = window
            if window.isKeyWindow { Workspace.shared.current = model }
            let center = NotificationCenter.default
            observers = [
                center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window,
                                   queue: .main) { [weak model] _ in
                    MainActor.assumeIsolated {
                        if let model { Workspace.shared.current = model }
                    }
                },
                center.addObserver(forName: NSWindow.willCloseNotification, object: window,
                                   queue: .main) { [weak self, weak model] _ in
                    MainActor.assumeIsolated {
                        self?.stopObserving()
                        model?.windowClosed()
                    }
                },
            ]
        }

        private func stopObserving() {
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers = []
        }
    }
}
