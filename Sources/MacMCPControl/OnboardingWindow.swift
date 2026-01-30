import AppKit
import Foundation

@MainActor
final class OnboardingWindow: NSObject, NSWindowDelegate {
    private let settingsManager: SettingsManager
    private let onContinue: () -> Void
    private var window: NSWindow?

    private var termsCheckbox: NSButton?
    private var accessibilityStatusLabel: NSTextField?
    private var continueButton: NSButton?

    init(settingsManager: SettingsManager, onContinue: @escaping () -> Void) {
        self.settingsManager = settingsManager
        self.onContinue = onContinue
        super.init()
    }

    func show() {
        if window != nil {
            window?.makeKeyAndOrderFront(nil)
            refreshAccessibilityStatus()
            updateContinueState()
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 520),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Mac MCP Control Setup"
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self

        let contentView = NSView(frame: window.contentView!.bounds)
        contentView.wantsLayer = true

        var yPos: CGFloat = 480

        let titleLabel = NSTextField(labelWithString: "Welcome to Mac MCP Control")
        titleLabel.font = NSFont.systemFont(ofSize: 18, weight: .semibold)
        titleLabel.frame = NSRect(x: 20, y: yPos, width: 580, height: 24)
        contentView.addSubview(titleLabel)

        yPos -= 40

        let accessLabel = NSTextField(labelWithString: "Accessibility Permissions")
        accessLabel.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        accessLabel.frame = NSRect(x: 20, y: yPos, width: 580, height: 20)
        contentView.addSubview(accessLabel)

        yPos -= 28

        let accessBody = NSTextField(labelWithString: """
Mac MCP Control needs Accessibility permissions to move the mouse, click, and type on your behalf.
1) Click “Open Accessibility Settings”
2) Enable Mac MCP Control in the list
3) Return here and click “Check Again”
""")
        accessBody.frame = NSRect(x: 20, y: yPos - 60, width: 580, height: 60)
        accessBody.lineBreakMode = .byWordWrapping
        accessBody.maximumNumberOfLines = 0
        contentView.addSubview(accessBody)

        yPos -= 90

        let openSettingsButton = NSButton(frame: NSRect(x: 20, y: yPos, width: 210, height: 30))
        openSettingsButton.title = "Open Accessibility Settings"
        openSettingsButton.bezelStyle = .rounded
        openSettingsButton.target = self
        openSettingsButton.action = #selector(openAccessibilitySettings)
        contentView.addSubview(openSettingsButton)

        let checkAgainButton = NSButton(frame: NSRect(x: 240, y: yPos, width: 120, height: 30))
        checkAgainButton.title = "Check Again"
        checkAgainButton.bezelStyle = .rounded
        checkAgainButton.target = self
        checkAgainButton.action = #selector(checkAccessibility)
        contentView.addSubview(checkAgainButton)

        yPos -= 36

        let statusLabel = NSTextField(labelWithString: "Accessibility: Checking…")
        statusLabel.frame = NSRect(x: 20, y: yPos, width: 580, height: 18)
        contentView.addSubview(statusLabel)
        accessibilityStatusLabel = statusLabel

        yPos -= 48

        let termsLabel = NSTextField(labelWithString: "Terms & Risk Acknowledgment")
        termsLabel.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        termsLabel.frame = NSRect(x: 20, y: yPos, width: 580, height: 20)
        contentView.addSubview(termsLabel)

        yPos -= 24

        let termsBody = NSTextField(labelWithString: """
By using Mac MCP Control you acknowledge that remote control of your Mac is inherently dangerous.
You agree that you are solely responsible for any actions taken with this software and that the author is not liable for any damages, data loss, or security incidents. You understand that despite best efforts to secure the server, risks remain.
""")
        termsBody.frame = NSRect(x: 20, y: yPos - 70, width: 580, height: 70)
        termsBody.lineBreakMode = .byWordWrapping
        termsBody.maximumNumberOfLines = 0
        contentView.addSubview(termsBody)

        yPos -= 92

        let checkbox = NSButton(checkboxWithTitle: "I agree to the terms and understand the risks.", target: self, action: #selector(toggleTerms))
        checkbox.frame = NSRect(x: 20, y: yPos, width: 580, height: 22)
        checkbox.state = settingsManager.acceptedTerms ? .on : .off
        contentView.addSubview(checkbox)
        termsCheckbox = checkbox

        yPos -= 50

        let continueButton = NSButton(frame: NSRect(x: 480, y: yPos, width: 120, height: 32))
        continueButton.title = "Continue"
        continueButton.bezelStyle = .rounded
        continueButton.target = self
        continueButton.action = #selector(continueToApp)
        contentView.addSubview(continueButton)
        self.continueButton = continueButton

        let quitButton = NSButton(frame: NSRect(x: 360, y: yPos, width: 110, height: 32))
        quitButton.title = "Quit"
        quitButton.bezelStyle = .rounded
        quitButton.target = NSApp
        quitButton.action = #selector(NSApplication.terminate(_:))
        contentView.addSubview(quitButton)

        window.contentView = contentView
        window.makeKeyAndOrderFront(nil)
        self.window = window

        _ = AccessibilityPermissions.checkAndRequestPermissions()
        refreshAccessibilityStatus()
        updateContinueState()
    }

    @objc private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func checkAccessibility() {
        refreshAccessibilityStatus()
        updateContinueState()
    }

    @objc private func toggleTerms() {
        updateContinueState()
    }

    @objc private func continueToApp() {
        settingsManager.acceptedTerms = termsCheckbox?.state == .on
        onContinue()
        closeWindow()
    }

    private func refreshAccessibilityStatus() {
        let enabled = AccessibilityPermissions.isAccessibilityEnabled()
        accessibilityStatusLabel?.stringValue = enabled
            ? "Accessibility: Granted"
            : "Accessibility: Not granted"
    }

    private func updateContinueState() {
        let hasTerms = termsCheckbox?.state == .on
        let hasAccess = AccessibilityPermissions.isAccessibilityEnabled()
        continueButton?.isEnabled = hasTerms && hasAccess
    }

    @objc private func closeWindow() {
        window?.performClose(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}
