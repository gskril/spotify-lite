import SwiftUI
import AppKit

/// Repairs the rare AppKit restoration state where SwiftUI attaches live scene
/// content to a 0×0 window instead of presenting a new main window.
struct WindowPresentationGuard: NSViewRepresentable {
    func makeNSView(context: Context) -> PresentationProbeView {
        PresentationProbeView()
    }

    func updateNSView(_ nsView: PresentationProbeView, context: Context) {
        nsView.presentHostingWindowIfNeeded()
    }
}

final class PresentationProbeView: NSView {
    private var hasPresented = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        presentHostingWindowIfNeeded()
    }

    func presentHostingWindowIfNeeded() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.isReleasedWhenClosed = false
            window.isRestorable = false
            window.minSize = NSSize(width: 760, height: 580)
            WindowPlacement.ensureUsable(window)
            guard !self.hasPresented || !window.isVisible else { return }
            self.hasPresented = true
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

enum WindowPlacement {
    @MainActor
    static func ensureUsable(_ window: NSWindow) {
        let hasUsefulSize = window.frame.width >= 760 && window.frame.height >= 580
        let intersectsDisplay = NSScreen.screens.contains { screen in
            let intersection = screen.visibleFrame.intersection(window.frame)
            return intersection.width >= 160 && intersection.height >= 120
        }
        guard hasUsefulSize, intersectsDisplay, window.isOnActiveSpace else {
            let screenFrame = (NSScreen.screens.first ?? NSScreen.main)?.visibleFrame
                ?? NSRect(x: 0, y: 0, width: 1120, height: 720)
            let width = min(1120, screenFrame.width)
            let height = min(720, screenFrame.height)
            window.setFrame(
                NSRect(
                    x: screenFrame.midX - width / 2,
                    y: screenFrame.midY - height / 2,
                    width: width,
                    height: height
                ),
                display: true
            )
            return
        }
    }
}
