import SwiftUI
import AppKit

// MARK: - App State

@MainActor
final class AppState: ObservableObject {
    @Published var status: String = "Starting…"
    @Published var mcpUrl: String = "-"
    @Published var ngrokUrl: String?
    @Published var ngrokConnecting: Bool = false
    @Published var authorizedSessions: Int = 0
    @Published var needsOnboarding: Bool = false
    @Published var needsSettings: Bool = false
    @Published var hasStarted: Bool = false

    let settingsManager = SettingsManager()
    lazy var mcpServerManager = McpServerManager(settingsManager: settingsManager)
    let ngrokManager = NgrokManager()

    private var statsTimer: Timer?
    private var pendingApprovalQueue: [PendingAuthRequestInfo] = []
    private var isShowingApprovalPrompt = false
    private let approvalPresenter = ApprovalPanelPresenter()

    func handleStartup() {
        guard !hasStarted else { return }
        hasStarted = true

        LogStore.shared.log("Mac MCP Control starting.")

        let hasAccessibility = AccessibilityPermissions.isAccessibilityEnabled()
        let hasScreenRecording = ScreenRecordingPermissions.isScreenRecordingEnabled()
        let hasTerms = settingsManager.acceptedTerms

        LogStore.shared.log("Permissions check - Accessibility: \(hasAccessibility), ScreenRecording: \(hasScreenRecording), Terms: \(hasTerms)")

        // If any permission is missing, reset acceptedTerms to force full onboarding
        if !hasAccessibility || !hasScreenRecording {
            settingsManager.acceptedTerms = false
            needsOnboarding = true
            LogStore.shared.log("Missing permissions - showing onboarding")
            return
        }

        // All permissions granted, check if terms accepted
        if !hasTerms {
            needsOnboarding = true
            LogStore.shared.log("Terms not accepted - showing onboarding")
            return
        }

        // Everything is good, start services
        LogStore.shared.log("All checks passed - starting services")
        if settingsManager.hasValidSettings() {
            startServices()
        } else {
            needsSettings = true
        }
    }

    func startServices() {
        mcpServerManager.onStatsUpdate = { [weak self] _, authorized in
            Task { @MainActor in
                self?.authorizedSessions = authorized
            }
        }
        mcpServerManager.onAuthRequest = { [weak self] request in
            Task { @MainActor in
                self?.enqueueApprovalPrompt(request)
            }
        }
        mcpServerManager.start()
        mcpUrl = "http://localhost:\(settingsManager.mcpPort)/mcp"

        if settingsManager.ngrokEnabled {
            ngrokConnecting = true
            ngrokUrl = nil
            ngrokManager.onUpdate = { [weak self] url in
                Task { @MainActor in
                    self?.ngrokUrl = url
                    self?.ngrokConnecting = (url == nil && self?.settingsManager.ngrokEnabled == true)
                }
            }
            ngrokManager.start(port: settingsManager.mcpPort, authToken: settingsManager.ngrokAuthToken)
        } else {
            ngrokConnecting = false
            ngrokManager.stop()
            ngrokUrl = nil
        }

        status = "Running"
        LogStore.shared.log("Status: Running")
        refreshStats()

        statsTimer?.invalidate()
        statsTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshStats()
            }
        }
    }

    func restartServices() {
        // Centralize restart so we don't accidentally double-start the MCP server.
        stopServices()
        startServices()
    }

    func stopServices() {
        statsTimer?.invalidate()
        statsTimer = nil
        ngrokManager.stop()
        mcpServerManager.onAuthRequest = nil
        mcpServerManager.stop()
        status = "Stopped"
        ngrokUrl = nil
        LogStore.shared.log("Status: Stopped")
    }

    func restartOnboarding() {
        needsSettings = false
        stopServices()
        resetToDefaults()
        needsOnboarding = true
    }

    func resetToDefaults() {
        // Reset all settings to defaults
        settingsManager.acceptedTerms = false
        settingsManager.deviceName = Host.current().localizedName ?? "My Mac"
        settingsManager.mcpPort = 7519
        settingsManager.ngrokEnabled = false
        settingsManager.ngrokAuthToken = ""

        // Revoke all sessions
        mcpServerManager.revokeAllAuthorizedSessions()

        // Reset state
        ngrokUrl = nil
        ngrokConnecting = false
        authorizedSessions = 0

        LogStore.shared.log("Reset all settings to defaults")
    }

    func onOnboardingComplete() {
        needsOnboarding = false
        hasStarted = false
        handleStartup()
        needsSettings = !settingsManager.hasValidSettings()
    }

    private func refreshStats() {
        let snapshot = mcpServerManager.statsSnapshot()
        authorizedSessions = snapshot.authorizedSessions
    }

    func copyNgrokUrl() {
        guard let url = ngrokUrl else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("\(url)/mcp", forType: .string)
    }

    private func enqueueApprovalPrompt(_ request: PendingAuthRequestInfo) {
        pendingApprovalQueue.append(request)
        showNextApprovalPromptIfNeeded()
    }

    private func showNextApprovalPromptIfNeeded() {
        guard !isShowingApprovalPrompt, let next = pendingApprovalQueue.first else {
            return
        }
        isShowingApprovalPrompt = true
        pendingApprovalQueue.removeFirst()
        approvalPresenter.present(
            request: next,
            onApprove: { [weak self] sessionName in
                guard let self else { return }
                self.mcpServerManager.resolveAuthRequest(
                    requestId: next.id,
                    approve: true,
                    sessionName: sessionName
                )
                self.isShowingApprovalPrompt = false
                self.showNextApprovalPromptIfNeeded()
            },
            onDeny: { [weak self] in
                guard let self else { return }
                self.mcpServerManager.resolveAuthRequest(
                    requestId: next.id,
                    approve: false,
                    sessionName: nil
                )
                self.isShowingApprovalPrompt = false
                self.showNextApprovalPromptIfNeeded()
            }
        )
    }
}

// MARK: - Main App

@main
struct MacMCPControlApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState: AppState

    init() {
        let state = AppState()
        _appState = StateObject(wrappedValue: state)
        appDelegate.appState = state
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(appState: appState)
        } label: {
            MenuBarLabel(appState: appState)
        }

        Window("Mac MCP Control - Setup", id: "onboarding") {
            OnboardingView(
                settingsManager: appState.settingsManager,
                onContinue: {
                    appState.onOnboardingComplete()
                },
                onQuit: {
                    appState.stopServices()
                    NSApp.terminate(nil)
                }
            )
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Window("Mac MCP Control Settings", id: "settings") {
            SettingsView(
                settingsManager: appState.settingsManager,
                mcpServerManager: appState.mcpServerManager,
                onSave: {
                    appState.restartServices()
                },
                onCancel: {},
                onRestartOnboarding: {
                    appState.restartOnboarding()
                }
            )
            .environmentObject(appState)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}

// MARK: - Menu Bar Content

private struct MenuBarLabel: View {
    @ObservedObject var appState: AppState
    @Environment(\.openWindow) private var openWindow
    @State private var didKickoff = false

    var body: some View {
        Image(systemName: "cursorarrow.rays")
            .task {
                guard !didKickoff else { return }
                didKickoff = true
                // Defer startup until the menu bar item view is mounted; running startup too early can delay
                // MenuBarExtra registration and make the icon appear "missing" on launch.
                appState.handleStartup()
                openRelevantWindowIfNeeded()
            }
            .onChange(of: appState.needsOnboarding) { _ in
                openRelevantWindowIfNeeded()
            }
            .onChange(of: appState.needsSettings) { _ in
                openRelevantWindowIfNeeded()
            }
    }

    private func openRelevantWindowIfNeeded() {
        if appState.needsOnboarding {
            openWindow(id: "onboarding")
            NSApp.activate(ignoringOtherApps: true)
        } else if appState.needsSettings {
            openWindow(id: "settings")
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

struct MenuBarContent: View {
    @ObservedObject var appState: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            Text("Status: \(appState.status)")
            Text("MCP: \(appState.mcpUrl)")
            if let ngrokUrl = appState.ngrokUrl {
                Text("Ngrok: \(ngrokUrl)/mcp")
            } else {
                Text("Ngrok: -")
            }
            Text("Authorized sessions: \(appState.authorizedSessions)")

            if appState.ngrokUrl != nil {
                Button("Copy Ngrok URL") {
                    appState.copyNgrokUrl()
                }
                .keyboardShortcut("c")
            }

            Divider()

            Button("Settings…") {
                openWindow(id: "settings")
                NSApp.activate(ignoringOtherApps: true)
            }
            .keyboardShortcut(",")
            .disabled(appState.needsOnboarding || !appState.settingsManager.acceptedTerms)

            Button("Quit") {
                appState.stopServices()
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }
}
