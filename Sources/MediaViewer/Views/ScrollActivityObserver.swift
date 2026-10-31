import AppKit
import SwiftUI

/// Reports whether the enclosing scroll view is moving fast enough that
/// on-demand thumbnail generation should pause. Uses bounds-change timing so
/// it also works for programmatic scrolling (not just trackpad events).
struct ScrollActivityObserver: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> NSView {
        ProbeView(onChange: onChange)
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    final class ProbeView: NSView {
        /// Points per second above which the user is considered to be flinging.
        private static let fastThreshold: CGFloat = 900
        /// Stop is declared after this much time without a bounds change.
        private static let quietInterval: TimeInterval = 0.12

        private let onChange: (Bool) -> Void
        private var observer: NSObjectProtocol?
        private var quietTimer: Timer?
        private var lastY: CGFloat?
        private var lastChangeTime: CFTimeInterval = 0
        private var isFast = false

        init(onChange: @escaping (Bool) -> Void) {
            self.onChange = onChange
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                detach()
            } else {
                DispatchQueue.main.async { [weak self] in self?.attach() }
            }
        }

        private func attach() {
            guard observer == nil, let scrollView = enclosingScrollView else { return }
            let clipView = scrollView.contentView
            clipView.postsBoundsChangedNotifications = true
            lastY = clipView.bounds.origin.y
            observer = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: clipView,
                queue: .main
            ) { [weak self] _ in
                self?.boundsChanged()
            }
        }

        private func boundsChanged() {
            guard let clipView = enclosingScrollView?.contentView else { return }
            let y = clipView.bounds.origin.y
            let now = CACurrentMediaTime()
            if let lastY {
                let dt = max(now - lastChangeTime, 0.001)
                let velocity = abs(y - lastY) / dt
                if velocity >= Self.fastThreshold {
                    setFast(true)
                }
            }
            lastY = y
            lastChangeTime = now
            scheduleQuietCheck()
        }

        private func scheduleQuietCheck() {
            quietTimer?.invalidate()
            let timer = Timer(timeInterval: Self.quietInterval, repeats: false) { [weak self] _ in
                self?.setFast(false)
            }
            RunLoop.main.add(timer, forMode: .common)
            quietTimer = timer
        }

        private func setFast(_ value: Bool) {
            guard value != isFast else { return }
            isFast = value
            onChange(value)
        }

        private func detach() {
            quietTimer?.invalidate()
            quietTimer = nil
            if let observer {
                NotificationCenter.default.removeObserver(observer)
                self.observer = nil
            }
            lastY = nil
        }

        deinit {
            detach()
        }
    }
}
