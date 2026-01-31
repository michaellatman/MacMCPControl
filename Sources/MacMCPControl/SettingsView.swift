import SwiftUI
import AppKit
import Combine

// MARK: - Settings View

struct SettingsView: View {
    let settingsManager: SettingsManager
    let mcpServerManager: McpServerManager
    let onSave: () -> Void
    let onCancel: () -> Void
    let onRestartOnboarding: () -> Void

    @EnvironmentObject var appState: AppState
    @Environment(\.dismissWindow) private var dismissWindow

    @State private var deviceName: String = ""
    @State private var mcpPort: String = ""
    @State private var ngrokEnabled: Bool = false
    @State private var ngrokToken: String = ""
    @State private var showRestartOnboardingAlert = false

    @State private var selectedTab = 0
    @State private var restartDebounceTask: Task<Void, Never>?
    @State private var lastAppliedDeviceName: String = ""
    @State private var lastAppliedPort: Int = 0
    @State private var didLoadSettings: Bool = false

    var body: some View {
        TabView(selection: $selectedTab) {
            settingsTab
                .tabItem {
                    Label("Settings", systemImage: "gear")
                }
                .tag(0)

            sessionsTab
                .tabItem {
                    Label("Sessions", systemImage: "person.2")
                }
                .tag(1)

            logsTab
                .tabItem {
                    Label("Logs", systemImage: "doc.text")
                }
                .tag(2)
        }
        .frame(width: 700, height: 520)
        .onAppear {
            loadSettings()
        }
        .onDisappear {
            restartDebounceTask?.cancel()
            restartDebounceTask = nil
        }
        .onChange(of: deviceName) { _ in
            guard didLoadSettings else { return }
            saveSettings()
            requestServiceRestartIfNeeded()
        }
        .onChange(of: mcpPort) { _ in
            guard didLoadSettings else { return }
            saveSettings()
            requestServiceRestartIfNeeded()
        }
        .onChange(of: ngrokEnabled) { _ in
            guard didLoadSettings else { return }
            saveSettings()
            // Apply immediately so the public URL state stays in sync.
            applyServiceRestartNow()
        }
        .onChange(of: ngrokToken) { _ in saveSettings() }
        .background(
            Button("") {
                appState.stopServices()
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
            .hidden()
        )
        .alert("Restart onboarding?", isPresented: $showRestartOnboardingAlert) {
            Button("Restart", role: .destructive) {
                closeSettingsWindow()
                onRestartOnboarding()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will stop the server and require permissions + terms again.")
        }
    }

    private var settingsTab: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Server URLs Section
                    ServerUrlsSection(
                        mcpPort: settingsManager.mcpPort,
                        ngrokUrl: appState.ngrokUrl,
                        ngrokConnecting: appState.ngrokConnecting
                    )

                    Divider()

                    PermissionsStatusSection()

                    Divider()

                    ServerSettingsSection(
                        deviceName: $deviceName,
                        mcpPort: $mcpPort,
                        ngrokEnabled: $ngrokEnabled,
                        ngrokToken: $ngrokToken
                    )
                }
                .padding(20)
            }

            Divider()

            HStack {
                Button("Restore Defaults") {
                    restoreDefaults()
                }

                Spacer()

                Button("Restart Onboarding") {
                    showRestartOnboardingAlert = true
                }
            }
            .padding()
        }
    }

    private func restoreDefaults() {
        deviceName = Host.current().localizedName ?? "My Mac"
        mcpPort = "7519"
        ngrokEnabled = false
        ngrokToken = ""
        saveSettings()
        applyServiceRestartNow()
    }

    private var logsTab: some View {
        LogsTabView()
    }

    private var sessionsTab: some View {
        SessionsTabView(mcpServerManager: mcpServerManager)
    }

    private func loadSettings() {
        deviceName = settingsManager.deviceName
        mcpPort = String(settingsManager.mcpPort)
        ngrokEnabled = settingsManager.ngrokEnabled
        ngrokToken = settingsManager.ngrokAuthToken

        // Keep a baseline so we only restart when server-relevant settings actually change.
        lastAppliedDeviceName = settingsManager.deviceName
        lastAppliedPort = settingsManager.mcpPort
        didLoadSettings = true
    }

    private func saveSettings() {
        if !deviceName.isEmpty {
            settingsManager.deviceName = deviceName
        }
        if let port = Int(mcpPort), port > 0 {
            settingsManager.mcpPort = port
        }
        settingsManager.ngrokEnabled = ngrokEnabled
        settingsManager.ngrokAuthToken = ngrokToken
    }

    private func applyServiceRestartNow() {
        restartDebounceTask?.cancel()
        restartDebounceTask = nil
        onSave()
        lastAppliedDeviceName = settingsManager.deviceName
        lastAppliedPort = settingsManager.mcpPort
    }

    private func closeSettingsWindow() {
        dismissWindow(id: "settings")
        // Fallback for cases where the SwiftUI dismiss handler doesn't close the window.
        for window in NSApp.windows where window.title.contains("Settings") {
            window.close()
        }
    }

    private func requestServiceRestartIfNeeded() {
        let currentDeviceName = settingsManager.deviceName
        let currentPort = settingsManager.mcpPort
        guard currentDeviceName != lastAppliedDeviceName || currentPort != lastAppliedPort else {
            return
        }

        restartDebounceTask?.cancel()
        restartDebounceTask = Task { [currentDeviceName, currentPort] in
            // Avoid restarting on every keystroke while editing.
            try? await Task.sleep(nanoseconds: 600_000_000)
            await MainActor.run {
                guard settingsManager.deviceName == currentDeviceName,
                      settingsManager.mcpPort == currentPort
                else {
                    return
                }
                onSave()
                lastAppliedDeviceName = currentDeviceName
                lastAppliedPort = currentPort
            }
        }
    }
}

// MARK: - Server URLs Section

struct ServerUrlsSection: View {
    let mcpPort: Int
    let ngrokUrl: String?
    let ngrokConnecting: Bool
    @State private var showPublicUrl = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Server URLs")
                .font(.headline)

            VStack(spacing: 8) {
                UrlRow(
                    label: "Local MCP",
                    url: "http://localhost:\(mcpPort)/mcp"
                )

                if let ngrokUrl = ngrokUrl {
                    UrlRow(
                        label: "Public URL",
                        url: "\(ngrokUrl)/mcp",
                        isSensitive: true,
                        reveal: $showPublicUrl
                    )
                } else {
                    HStack {
                        Text("Public URL:")
                            .foregroundColor(.secondary)
                        if ngrokConnecting {
                            ProgressView()
                                .controlSize(.small)
                                .padding(.trailing, 4)
                            Text("Connecting...")
                                .foregroundColor(.blue)
                        } else {
                            Text("Not connected")
                                .foregroundColor(.orange)
                        }
                        Spacer()
                    }
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(nsColor: .controlBackgroundColor))
                    )
                }
            }
        }
    }
}

struct UrlRow: View {
    let label: String
    let url: String
    var isSensitive: Bool = false
    var reveal: Binding<Bool> = .constant(true)

    var body: some View {
        HStack {
            Text("\(label):")
                .foregroundColor(.secondary)

            Text(displayUrl)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)

            Spacer()

            if isSensitive {
                Button(reveal.wrappedValue ? "Hide" : "Reveal") {
                    reveal.wrappedValue.toggle()
                }
                .buttonStyle(.bordered)
            }

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy URL")
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    private var displayUrl: String {
        guard isSensitive, !reveal.wrappedValue else { return url }
        guard let components = URLComponents(string: url), let host = components.host else {
            return "<redacted>"
        }
        let maskedHost = host.split(separator: ".").map { _ in "***" }.joined(separator: ".")
        var redacted = components
        redacted.host = maskedHost
        return redacted.string ?? "<redacted>"
    }
}

// MARK: - Permissions Status Section

struct PermissionsStatusSection: View {
    @State private var accessibilityGranted = false
    @State private var screenRecordingGranted = false
    @State private var pollTimer: Timer?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Permissions")
                .font(.headline)

            HStack(spacing: 16) {
                PermissionStatusCard(
                    title: "Accessibility",
                    icon: "hand.tap",
                    isGranted: accessibilityGranted,
                    openAction: {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                            NSWorkspace.shared.open(url)
                        }
                        refreshStatuses()
                    }
                )

                PermissionStatusCard(
                    title: "Screen Recording",
                    icon: "rectangle.dashed.badge.record",
                    isGranted: screenRecordingGranted,
                    openAction: {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                            NSWorkspace.shared.open(url)
                        }
                        refreshStatuses()
                    }
                )
            }
        }
        .onAppear {
            refreshStatuses()
            startPolling()
        }
        .onDisappear {
            stopPolling()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshStatuses()
        }
    }

    private func refreshStatuses() {
        accessibilityGranted = AccessibilityPermissions.isAccessibilityEnabled()
        screenRecordingGranted = ScreenRecordingPermissions.isScreenRecordingEnabled()
    }

    private func startPolling() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            DispatchQueue.main.async {
                refreshStatuses()
            }
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }
}

struct PermissionStatusCard: View {
    let title: String
    let icon: String
    let isGranted: Bool
    let openAction: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(isGranted ? .green : .orange)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)

                Text(isGranted ? "Granted" : "Not Granted")
                    .font(.caption)
                    .foregroundColor(isGranted ? .green : .orange)
            }

            Spacer()

            if !isGranted {
                Button("Grant") {
                    openAction()
                }
                .controlSize(.small)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isGranted ? Color.green.opacity(0.3) : Color.orange.opacity(0.3), lineWidth: 1)
        )
    }
}

// MARK: - Server Settings Section

struct ServerSettingsSection: View {
    @Binding var deviceName: String
    @Binding var mcpPort: String
    @Binding var ngrokEnabled: Bool
    @Binding var ngrokToken: String

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Server Configuration")
                .font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    Text("Device Name:")
                        .frame(width: 100, alignment: .trailing)
                    TextField("My Mac", text: $deviceName)
                        .textFieldStyle(.roundedBorder)
                }

                GridRow {
                    Text("MCP Port:")
                        .frame(width: 100, alignment: .trailing)
                    TextField("7519", text: $mcpPort)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                }

                GridRow {
                    Text("")
                        .frame(width: 100)
                    Toggle("Enable ngrok tunnel (public URL)", isOn: $ngrokEnabled)
                }

                GridRow {
                    Text("Ngrok Token:")
                        .frame(width: 100, alignment: .trailing)
                    TextField("Optional ngrok auth token", text: $ngrokToken)
                        .textFieldStyle(.roundedBorder)
                        .disabled(!ngrokEnabled)
                }
            }
        }
    }
}

// MARK: - Logs Tab

struct LogsTabView: View {
    @State private var logText: String = ""
    @State private var showClearAlert = false
    @State private var keepScrolledToBottom = true

    var body: some View {
        VStack(spacing: 12) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        Text(logText)
                            .font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .padding(8)

                        // Scroll target for pinning the view to the bottom.
                        Color.clear
                            .frame(height: 1)
                            .id("logBottom")
                    }
                }
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                )
                .onChange(of: logText) { _ in
                    guard keepScrolledToBottom else { return }
                    // If "Keep scrolled to bottom" is enabled, always pin to the bottom even if the user
                    // previously scrolled up (they can disable the toggle to browse history).
                    DispatchQueue.main.async {
                        withAnimation(nil) {
                            proxy.scrollTo("logBottom", anchor: .bottom)
                        }
                    }
                }
                .onChange(of: keepScrolledToBottom) { enabled in
                    if enabled {
                        DispatchQueue.main.async {
                            withAnimation(nil) {
                                proxy.scrollTo("logBottom", anchor: .bottom)
                            }
                        }
                    }
                }
                .onAppear {
                    if keepScrolledToBottom {
                        DispatchQueue.main.async {
                            withAnimation(nil) {
                                proxy.scrollTo("logBottom", anchor: .bottom)
                            }
                        }
                    }
                }
            }

            HStack(spacing: 12) {
                Toggle("Keep scrolled to bottom", isOn: $keepScrolledToBottom)

                Button("Clear Logs") {
                    showClearAlert = true
                }

                Button("Copy Logs") {
                    copyLogs()
                }

                Spacer()

                Button("Refresh") {
                    refreshLogs()
                }
            }
        }
        .padding()
        .onAppear {
            refreshLogs()
        }
        .onReceive(NotificationCenter.default.publisher(for: LogStore.didUpdateNotification).receive(on: DispatchQueue.main)) { _ in
            refreshLogs()
        }
        .alert("Clear all logs?", isPresented: $showClearAlert) {
            Button("Clear", role: .destructive) {
                LogStore.shared.clear()
                refreshLogs()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently delete all log entries.")
        }
    }

    private func refreshLogs() {
        logText = LogStore.shared.snapshot()
    }

    private func copyLogs() {
        let logs = LogStore.shared.snapshot()
        if logs.isEmpty { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(logs, forType: .string)
    }
}

// MARK: - Sessions Tab

struct SessionsTabView: View {
    let mcpServerManager: McpServerManager

    @State private var sessions: [SessionInfo] = []
    @State private var selectedSessions: Set<String> = []
    @State private var refreshTask: Task<Void, Never>?
    @State private var isShowingRenameSheet = false
    @State private var renameToken: String?
    @State private var renameText: String = ""

    struct SessionInfo: Identifiable {
        let id: String
        let token: String
        let clientId: String
        let scope: String
        let expiresAt: Date
        let sessionName: String?
        let lastUsedAt: Date?
    }

    var body: some View {
        VStack(spacing: 16) {
            if sessions.isEmpty {
                emptyState
            } else {
                sessionsList
            }

            HStack(spacing: 12) {
                Button("Rename…") {
                    renameSelected()
                }
                .disabled(selectedSessions.count != 1)

                Button("Revoke Selected") {
                    revokeSelected()
                }
                .disabled(selectedSessions.isEmpty)

                Button("Revoke All") {
                    revokeAll()
                }
                .disabled(sessions.isEmpty)

                Spacer()

                Button("Refresh") {
                    refreshSessions()
                }
            }
        }
        .padding()
        .onAppear {
            refreshSessions()
            startLiveRefresh()
        }
        .onDisappear {
            refreshTask?.cancel()
            refreshTask = nil
        }
        .sheet(isPresented: $isShowingRenameSheet) {
            RenameSessionSheet(
                name: $renameText,
                onSave: {
                    guard let token = renameToken else { return }
                    mcpServerManager.renameAuthorizedSession(token, sessionName: renameText)
                    isShowingRenameSheet = false
                    refreshSessions()
                }
            )
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "person.crop.circle.badge.checkmark")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text("No Active Sessions")
                .font(.title2)
                .fontWeight(.medium)

            Text("When clients authenticate with this server,\ntheir sessions will appear here.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var sessionsList: some View {
        List(sessions, selection: $selectedSessions) { session in
            SessionRow(session: session)
        }
        .listStyle(.bordered)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func refreshSessions() {
        sessions = mcpServerManager.listAuthorizedSessions().map { session in
            SessionInfo(
                id: session.token,
                token: session.token,
                clientId: session.clientId,
                scope: session.scope,
                expiresAt: session.expiresAt,
                sessionName: session.sessionName,
                lastUsedAt: session.lastUsedAt
            )
        }
    }

    private func startLiveRefresh() {
        refreshTask?.cancel()
        refreshTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await MainActor.run {
                    refreshSessions()
                }
            }
        }
    }

    private func renameSelected() {
        guard selectedSessions.count == 1, let token = selectedSessions.first else {
            return
        }
        guard let session = sessions.first(where: { $0.token == token }) else {
            return
        }
        renameToken = token
        renameText = session.sessionName ?? ""
        isShowingRenameSheet = true
    }

    private func revokeSelected() {
        for sessionId in selectedSessions {
            mcpServerManager.revokeAuthorizedSession(sessionId)
        }
        selectedSessions.removeAll()
        refreshSessions()
    }

    private func revokeAll() {
        mcpServerManager.revokeAllAuthorizedSessions()
        selectedSessions.removeAll()
        refreshSessions()
    }
}

private struct RenameSessionSheet: View {
    @Binding var name: String
    let onSave: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename Session")
                .font(.headline)

            TextField("Optional name", text: $name)
                .textFieldStyle(.roundedBorder)

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                Spacer()
                Button("Save") {
                    onSave()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 420)
    }
}

struct SessionRow: View {
    let session: SessionsTabView.SessionInfo

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: "person.circle.fill")
                .font(.title2)
                .foregroundColor(.accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(session.sessionName ?? session.clientId)
                    .font(.headline)

                if let name = session.sessionName, !name.isEmpty {
                    Text(session.clientId)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Text(session.scope.isEmpty ? "No specific scope" : session.scope)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text("Last used")
                    .font(.caption2)
                    .foregroundColor(.secondary)

                Text(session.lastUsedAt?.formatted(date: .abbreviated, time: .shortened) ?? "Never")
                    .font(.caption)

                Text("Expires")
                    .font(.caption2)
                    .foregroundColor(.secondary)

                Text(session.expiresAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
            }
        }
        .padding(.vertical, 4)
    }
}
