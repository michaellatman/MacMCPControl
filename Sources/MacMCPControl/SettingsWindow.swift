import AppKit
import Foundation

@MainActor
class SettingsWindow: NSObject, NSWindowDelegate {
    private let settingsManager: SettingsManager
    private let onSave: () -> Void
    private var window: NSWindow?

    private var deviceNameField: NSTextField?
    private var mcpPortField: NSTextField?
    private var ngrokEnabledButton: NSButton?
    private var ngrokTokenField: NSTextField?

    init(settingsManager: SettingsManager, onSave: @escaping () -> Void) {
        self.settingsManager = settingsManager
        self.onSave = onSave
        super.init()
    }

    func show() {
        if window != nil {
            window?.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Mac MCP Control Settings"
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self

        let contentView = NSView(frame: window.contentView!.bounds)
        contentView.wantsLayer = true

        var yPos: CGFloat = 290

        let deviceNameLabel = NSTextField(labelWithString: "Device Name:")
        deviceNameLabel.frame = NSRect(x: 20, y: yPos, width: 100, height: 20)
        contentView.addSubview(deviceNameLabel)

        let deviceNameField = NSTextField(frame: NSRect(x: 130, y: yPos, width: 350, height: 24))
        deviceNameField.stringValue = settingsManager.deviceName
        deviceNameField.placeholderString = "Michael's Mac"
        contentView.addSubview(deviceNameField)
        self.deviceNameField = deviceNameField

        yPos -= 40

        let mcpPortLabel = NSTextField(labelWithString: "MCP Port:")
        mcpPortLabel.frame = NSRect(x: 20, y: yPos, width: 100, height: 20)
        contentView.addSubview(mcpPortLabel)

        let mcpPortField = NSTextField(frame: NSRect(x: 130, y: yPos, width: 120, height: 24))
        mcpPortField.stringValue = String(settingsManager.mcpPort)
        mcpPortField.placeholderString = "7519"
        contentView.addSubview(mcpPortField)
        self.mcpPortField = mcpPortField

        yPos -= 40

        let ngrokEnabledButton = NSButton(checkboxWithTitle: "Enable ngrok tunnel", target: nil, action: nil)
        ngrokEnabledButton.frame = NSRect(x: 20, y: yPos, width: 200, height: 24)
        ngrokEnabledButton.state = settingsManager.ngrokEnabled ? .on : .off
        contentView.addSubview(ngrokEnabledButton)
        self.ngrokEnabledButton = ngrokEnabledButton

        yPos -= 40

        let ngrokTokenLabel = NSTextField(labelWithString: "Ngrok Token:")
        ngrokTokenLabel.frame = NSRect(x: 20, y: yPos, width: 100, height: 20)
        contentView.addSubview(ngrokTokenLabel)

        let ngrokTokenField = NSTextField(frame: NSRect(x: 130, y: yPos, width: 360, height: 24))
        ngrokTokenField.stringValue = settingsManager.ngrokAuthToken
        ngrokTokenField.placeholderString = "Optional ngrok authtoken"
        contentView.addSubview(ngrokTokenField)
        self.ngrokTokenField = ngrokTokenField

        yPos -= 60

        let saveButton = NSButton(frame: NSRect(x: 380, y: yPos, width: 100, height: 32))
        saveButton.title = "Save"
        saveButton.bezelStyle = .rounded
        saveButton.target = self
        saveButton.action = #selector(saveSettings)
        contentView.addSubview(saveButton)

        let cancelButton = NSButton(frame: NSRect(x: 270, y: yPos, width: 100, height: 32))
        cancelButton.title = "Cancel"
        cancelButton.bezelStyle = .rounded
        cancelButton.target = self
        cancelButton.action = #selector(closeWindow)
        contentView.addSubview(cancelButton)

        window.contentView = contentView
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }

    @objc private func saveSettings() {
        if let deviceName = deviceNameField?.stringValue, !deviceName.isEmpty {
            settingsManager.deviceName = deviceName
        }

        if let portString = mcpPortField?.stringValue,
           let port = Int(portString),
           port > 0 {
            settingsManager.mcpPort = port
        }

        if let ngrokEnabledButton {
            settingsManager.ngrokEnabled = ngrokEnabledButton.state == .on
        }

        if let token = ngrokTokenField?.stringValue {
            settingsManager.ngrokAuthToken = token
        }

        onSave()
        closeWindow()
    }

    @objc private func closeWindow() {
        window?.performClose(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}
