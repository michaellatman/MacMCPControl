import AppKit
import SwiftUI

@MainActor
final class ApprovalPanelPresenter {
    private final class WindowDelegate: NSObject, NSWindowDelegate {
        private let onClose: () -> Void

        init(onClose: @escaping () -> Void) {
            self.onClose = onClose
        }

        func windowWillClose(_ notification: Notification) {
            onClose()
        }
    }

    private var panel: NSPanel?
    private var delegate: WindowDelegate?

    private func screenForMouseLocation() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        // NSEvent.mouseLocation is in global screen coordinates.
        return NSScreen.screens.first(where: { $0.frame.contains(mouse) })
    }

    private func centerPanel(_ panel: NSPanel) {
        let targetScreen = NSApp.keyWindow?.screen ?? screenForMouseLocation() ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen = targetScreen else { return }

        let visible = screen.visibleFrame
        var frame = panel.frame
        frame.origin.x = visible.origin.x + (visible.size.width - frame.size.width) / 2.0
        frame.origin.y = visible.origin.y + (visible.size.height - frame.size.height) / 2.0
        panel.setFrame(frame, display: false)
    }

    func present(
        request: PendingAuthRequestInfo,
        onApprove: @escaping (String?) -> Void,
        onDeny: @escaping () -> Void
    ) {
        dismiss()

        let root = ApprovalPromptView(
            request: request,
            onApprove: { name in
                self.dismiss()
                onApprove(name)
            },
            onDeny: {
                self.dismiss()
                onDeny()
            }
        )

        let hosting = NSHostingController(rootView: root)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Approve Access"
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.contentViewController = hosting
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        centerPanel(panel)

        // If the user closes the window, treat it as deny.
        let delegate = WindowDelegate { [weak self] in
            self?.panel = nil
            self?.delegate = nil
            onDeny()
        }
        panel.delegate = delegate

        self.panel = panel
        self.delegate = delegate

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func dismiss() {
        if let panel {
            panel.orderOut(nil)
            self.panel = nil
        }
        delegate = nil
    }
}
