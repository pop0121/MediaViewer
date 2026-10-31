import AppKit
import SwiftUI

/// Keeps the point at the vertical center of the grid stable when its cell
/// density changes. The content height changes by roughly the same factor as
/// the item pitch, so preserving the center as a fraction of content height
/// avoids jumping to the top after a density step.
struct GridScrollCenterKeeper: NSViewRepresentable {
    let density: Double

    func makeNSView(context: Context) -> ProbeView {
        ProbeView(density: density)
    }

    func updateNSView(_ nsView: ProbeView, context: Context) {
        nsView.update(density: density)
    }

    final class ProbeView: NSView {
        private var lastDensity: Double
        private var pendingRestore: DispatchWorkItem?

        init(density: Double) {
            self.lastDensity = density
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                pendingRestore?.cancel()
            }
        }

        func update(density: Double) {
            guard abs(density - lastDensity) > 0.0001 else { return }
            lastDensity = density

            guard let scrollView = enclosingScrollView,
                  let documentView = scrollView.documentView else { return }
            let clipView = scrollView.contentView
            let oldHeight = documentView.bounds.height
            guard oldHeight > 1, clipView.bounds.height > 1 else { return }
            let oldCenter = clipView.bounds.origin.y + clipView.bounds.height / 2
            let centerFraction = oldCenter / oldHeight

            pendingRestore?.cancel()
            // Wait for LazyVGrid to lay out the new cell width/row height.
            let work = DispatchWorkItem { [weak self, weak scrollView, weak clipView, weak documentView] in
                guard self != nil,
                      let scrollView,
                      let clipView,
                      let documentView else { return }
                let newHeight = documentView.bounds.height
                guard newHeight > 1, abs(newHeight - oldHeight) > 0.5 else { return }
                let targetCenter = centerFraction * newHeight
                let maxY = max(newHeight - clipView.bounds.height, 0)
                let targetY = min(max(targetCenter - clipView.bounds.height / 2, 0), maxY)
                clipView.scroll(to: NSPoint(x: clipView.bounds.origin.x, y: targetY))
                scrollView.reflectScrolledClipView(clipView)
            }
            pendingRestore = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02, execute: work)
        }
    }
}
