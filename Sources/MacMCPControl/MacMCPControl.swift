import AppKit
import Foundation

/// Menubar UI runner.
@MainActor
final class MacMCPControlMenubar: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var statusMenuItem: NSMenuItem?
    private var mcpMenuItem: NSMenuItem?
    private var ngrokMenuItem: NSMenuItem?
    private var connectedClientsMenuItem: NSMenuItem?
    private var authorizedSessionsMenuItem: NSMenuItem?
    private var copyNgrokMenuItem: NSMenuItem?
    private var settingsWindow: SettingsWindow?
    private var onboardingWindow: OnboardingWindow?
    private var currentNgrokUrl: String?
    private var statsTimer: Timer?

    private let settingsManager = SettingsManager()
    private lazy var mcpServerManager = McpServerManager(settingsManager: settingsManager)
    private let ngrokManager = NgrokManager()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        setupMenuBar()

        print("=== Mac MCP Control Starting (menubar) ===")
        _ = AccessibilityPermissions.checkAndRequestPermissions()
        handleStartup()
    }

    private func handleStartup() {
        if !settingsManager.acceptedTerms || !AccessibilityPermissions.isAccessibilityEnabled() {
            showOnboardingWindow()
            return
        }

        if settingsManager.hasValidSettings() {
            startServices()
        } else {
            showSettingsWindow()
        }
    }

    @objc private func showOnboardingWindow() {
        if onboardingWindow == nil {
            onboardingWindow = OnboardingWindow(settingsManager: settingsManager, onContinue: { [weak self] in
                self?.handleStartup()
            })
        }
        NSApp.activate(ignoringOtherApps: true)
        onboardingWindow?.show()
    }

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem?.button {
            let image = createMenuBarIcon()
            image.isTemplate = true
            button.image = image
        }

        let menu = NSMenu()
        let statusEntry = NSMenuItem(title: "Status: Starting…", action: nil, keyEquivalent: "")
        let mcpItem = NSMenuItem(title: "MCP: —", action: nil, keyEquivalent: "")
        let ngrokItem = NSMenuItem(title: "Ngrok: —", action: nil, keyEquivalent: "")
        let connectedClientsItem = NSMenuItem(title: "Connected clients: 0", action: nil, keyEquivalent: "")
        let authorizedSessionsItem = NSMenuItem(title: "Authorized sessions: 0", action: nil, keyEquivalent: "")
        statusMenuItem = statusEntry
        mcpMenuItem = mcpItem
        ngrokMenuItem = ngrokItem
        connectedClientsMenuItem = connectedClientsItem
        authorizedSessionsMenuItem = authorizedSessionsItem

        menu.addItem(statusEntry)
        menu.addItem(mcpItem)
        menu.addItem(ngrokItem)
        menu.addItem(connectedClientsItem)
        menu.addItem(authorizedSessionsItem)
        let copyNgrokItem = NSMenuItem(title: "Copy Ngrok URL", action: #selector(copyNgrokUrl), keyEquivalent: "c")
        copyNgrokItem.target = self
        copyNgrokItem.isEnabled = false
        copyNgrokMenuItem = copyNgrokItem
        menu.addItem(copyNgrokItem)
        menu.addItem(NSMenuItem.separator())
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(showSettingsWindow), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let quitItem = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.target = NSApp
        menu.addItem(quitItem)

        self.statusItem?.menu = menu
    }

    @objc private func showSettingsWindow() {
        if settingsWindow == nil {
            settingsWindow = SettingsWindow(settingsManager: settingsManager, onSave: { [weak self] in
                self?.restartServices()
            })
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.show()
    }

    private func startServices() {
        mcpServerManager.onStatsUpdate = { [weak self] connected, authorized in
            Task { @MainActor in
                self?.updateStats(connectedClients: connected, authorizedSessions: authorized)
            }
        }
        mcpServerManager.start()
        updateMcpStatus()

        if settingsManager.ngrokEnabled {
            ngrokManager.onUpdate = { [weak self] url in
                self?.updateNgrokStatus(url)
            }
            ngrokManager.start(port: settingsManager.mcpPort, authToken: settingsManager.ngrokAuthToken)
            updateNgrokStatus(ngrokManager.publicUrl)
        } else {
            updateNgrokStatus(nil)
        }

        updateStatus("Running")
        refreshStats()
        statsTimer?.invalidate()
        statsTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true, block: { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                self?.refreshStats()
            }
        })
    }

    private func restartServices() {
        ngrokManager.stop()
        mcpServerManager.restart()
        startServices()
    }

    private func refreshStats() {
        let snapshot = mcpServerManager.statsSnapshot()
        updateStats(connectedClients: snapshot.connectedClients, authorizedSessions: snapshot.authorizedSessions)
    }

    private func updateStatus(_ status: String) {
        print("Status: \(status)")
        statusMenuItem?.title = "Status: \(status)"
    }

    private func updateMcpStatus() {
        let localUrl = "http://localhost:\(settingsManager.mcpPort)/mcp"
        mcpMenuItem?.title = "MCP: \(localUrl)"
    }

    private func updateNgrokStatus(_ url: String?) {
        currentNgrokUrl = url
        if let url {
            ngrokMenuItem?.title = "Ngrok: \(url)/mcp"
            copyNgrokMenuItem?.isEnabled = true
        } else {
            ngrokMenuItem?.title = "Ngrok: —"
            copyNgrokMenuItem?.isEnabled = false
        }
    }

    private func updateStats(connectedClients: Int, authorizedSessions: Int) {
        connectedClientsMenuItem?.title = "Connected clients: \(connectedClients)"
        authorizedSessionsMenuItem?.title = "Authorized sessions: \(authorizedSessions)"
    }

    @objc private func copyNgrokUrl() {
        guard let url = currentNgrokUrl else {
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("\(url)/mcp", forType: .string)
    }
    private func createMenuBarIcon() -> NSImage {
        let image = NSImage(systemSymbolName: "rectangle.and.cursor.arrow", accessibilityDescription: "MCP")
        return image ?? NSImage()
    }
}

@main
struct MacMCPControlMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = MacMCPControlMenubar()
        app.delegate = delegate
        app.run()
    }
}
