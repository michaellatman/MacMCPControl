import SwiftUI
import CoreGraphics

// Custom button style that properly shows disabled state
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .fontWeight(.semibold)
            .foregroundColor(.white)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isEnabled ? Color.accentColor : Color.gray)
            )
            .opacity(configuration.isPressed ? 0.8 : 1.0)
            .opacity(isEnabled ? 1.0 : 0.6)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(.primary)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.gray.opacity(0.3), lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.7 : 1.0)
    }
}

struct OnboardingView: View {
    let settingsManager: SettingsManager
    let onContinue: () -> Void
    let onQuit: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var termsAccepted = false
    @State private var accessibilityGranted = false
    @State private var screenRecordingGranted = false
    @State private var pollTimer: Timer?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 8) {
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 48))
                    .foregroundStyle(.linearGradient(
                        colors: [.blue, .purple],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))

                Text("Mac MCP Control")
                    .font(.largeTitle)
                    .fontWeight(.bold)

                Text("Securely control your Mac with AI")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .padding(.top, 32)
            .padding(.bottom, 24)

            Divider()
                .padding(.horizontal, 32)

            // Steps
            ScrollView {
                VStack(spacing: 24) {
                    // Step 1: Accessibility
                    AccessibilityCard(
                        stepNumber: 1,
                        isGranted: accessibilityGranted,
                        openAction: openAccessibilitySettings,
                        refreshAction: refreshAccessibilityStatus
                    )

                    // Step 2: Screen Recording
                    ScreenRecordingCard(
                        stepNumber: 2,
                        isGranted: screenRecordingGranted,
                        openAction: openScreenRecordingSettings,
                        refreshAction: refreshScreenRecordingStatus
                    )

                    // Step 3: Terms
                    TermsCard(
                        stepNumber: 3,
                        isAccepted: $termsAccepted
                    )
                }
                .padding(24)
            }

            Divider()

            // Footer buttons
            HStack {
                Button("Quit") {
                    onQuit()
                }
                .buttonStyle(SecondaryButtonStyle())
                .keyboardShortcut("q", modifiers: .command)

                Spacer()

                Button("Start Server") {
                    settingsManager.acceptedTerms = true
                    dismiss()
                    onContinue()
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!canContinue)
                .keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
        .frame(width: 560, height: 720)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            refreshAllStatuses()
            startPolling()
        }
        .onDisappear {
            stopPolling()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshAllStatuses()
        }
    }

    private var canContinue: Bool {
        termsAccepted && accessibilityGranted && screenRecordingGranted
    }

    private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        refreshAccessibilityStatus()
    }

    private func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
        refreshScreenRecordingStatus()
    }

    private func refreshAccessibilityStatus() {
        accessibilityGranted = AccessibilityPermissions.isAccessibilityEnabled()
    }

    private func refreshScreenRecordingStatus() {
        screenRecordingGranted = ScreenRecordingPermissions.isScreenRecordingEnabled()
    }

    private func refreshAllStatuses() {
        refreshAccessibilityStatus()
        refreshScreenRecordingStatus()
    }

    private func startPolling() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            DispatchQueue.main.async {
                refreshAllStatuses()
            }
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }
}

struct AccessibilityCard: View {
    let stepNumber: Int
    let isGranted: Bool
    let openAction: () -> Void
    let refreshAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 16) {
                // Step indicator
                ZStack {
                    Circle()
                        .fill(isGranted ? Color.green : Color.blue.opacity(0.15))
                        .frame(width: 44, height: 44)

                    if isGranted {
                        Image(systemName: "checkmark")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundColor(.white)
                    } else {
                        Text("\(stepNumber)")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundColor(.blue)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Image(systemName: "hand.tap")
                            .foregroundColor(isGranted ? .green : .primary)
                        Text("Accessibility")
                            .font(.headline)
                    }

                    Text("Required to control mouse, keyboard, and interact with apps")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                StatusBadge(isGranted: isGranted)
            }

            if !isGranted {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Drag the app icon below into the Accessibility list in System Settings:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.leading, 60)

                    HStack(spacing: 16) {
                        // Draggable app icon
                        DraggableAppIcon()

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Drag this icon to System Settings")
                                .font(.caption)
                                .fontWeight(.medium)

                            Text("Drop it in the Accessibility list")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }

                        Spacer()
                    }
                    .padding(.leading, 60)

                    HStack(spacing: 8) {
                        Button("Open Accessibility Settings") {
                            openAction()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Button {
                            refreshAction()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.borderless)
                        .help("Refresh status")

                        Spacer()

                        Button("Reopen App") {
                            relaunchApp()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Restart the app after granting permission")
                    }
                    .padding(.leading, 60)
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isGranted ? Color.green.opacity(0.3) : Color.gray.opacity(0.2), lineWidth: 1)
        )
    }

    private func relaunchApp() {
        let url = URL(fileURLWithPath: Bundle.main.resourcePath!)
        let path = url.deletingLastPathComponent().deletingLastPathComponent().absoluteString
        let task = Process()
        task.launchPath = "/usr/bin/open"
        task.arguments = [path]
        task.launch()
        NSApp.terminate(nil)
    }
}

struct ScreenRecordingCard: View {
    let stepNumber: Int
    let isGranted: Bool
    let openAction: () -> Void
    let refreshAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 16) {
                // Step indicator
                ZStack {
                    Circle()
                        .fill(isGranted ? Color.green : Color.blue.opacity(0.15))
                        .frame(width: 44, height: 44)

                    if isGranted {
                        Image(systemName: "checkmark")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundColor(.white)
                    } else {
                        Text("\(stepNumber)")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundColor(.blue)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Image(systemName: "rectangle.dashed.badge.record")
                            .foregroundColor(isGranted ? .green : .primary)
                        Text("Screen Recording")
                            .font(.headline)
                    }

                    Text("Required to capture screenshots for AI vision")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                StatusBadge(isGranted: isGranted)
            }

            if !isGranted {
                VStack(alignment: .leading, spacing: 12) {
                    Text("This app may not appear automatically in Screen Recording settings. Drag the app icon below into the System Settings list:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.leading, 60)

                    HStack(spacing: 16) {
                        // Draggable app icon
                        DraggableAppIcon()

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Drag this icon to System Settings")
                                .font(.caption)
                                .fontWeight(.medium)

                            Text("Drop it in the Screen Recording list")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }

                        Spacer()
                    }
                    .padding(.leading, 60)

                    HStack(spacing: 8) {
                        Button("Open Screen Recording Settings") {
                            openAction()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Button {
                            refreshAction()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.borderless)
                        .help("Refresh status")

                        Spacer()

                        Button("Reopen App") {
                            relaunchApp()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Restart the app after granting permission")
                    }
                    .padding(.leading, 60)
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isGranted ? Color.green.opacity(0.3) : Color.gray.opacity(0.2), lineWidth: 1)
        )
    }

    private func relaunchApp() {
        let url = URL(fileURLWithPath: Bundle.main.resourcePath!)
        let path = url.deletingLastPathComponent().deletingLastPathComponent().absoluteString
        let task = Process()
        task.launchPath = "/usr/bin/open"
        task.arguments = [path]
        task.launch()
        NSApp.terminate(nil)
    }
}

struct DraggableAppIcon: View {
    var body: some View {
        AppIconView()
            .frame(width: 48, height: 48)
            .onDrag {
                if let appURL = Bundle.main.bundleURL as URL? {
                    return NSItemProvider(object: appURL as NSURL)
                }
                return NSItemProvider()
            }
            .help("Drag to Screen Recording settings")
    }
}

struct AppIconView: View {
    var body: some View {
        if let appIcon = NSApp.applicationIconImage {
            Image(nsImage: appIcon)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: "app.fill")
                .font(.system(size: 32))
                .foregroundColor(.accentColor)
        }
    }
}

struct StatusBadge: View {
    let isGranted: Bool

    var body: some View {
        Text(isGranted ? "Granted" : "Required")
            .font(.caption)
            .fontWeight(.medium)
            .foregroundColor(isGranted ? .green : .orange)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(isGranted ? Color.green.opacity(0.15) : Color.orange.opacity(0.15))
            )
    }
}

struct TermsCard: View {
    let stepNumber: Int
    @Binding var isAccepted: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(isAccepted ? Color.green : Color.blue.opacity(0.15))
                        .frame(width: 44, height: 44)

                    if isAccepted {
                        Image(systemName: "checkmark")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundColor(.white)
                    } else {
                        Text("\(stepNumber)")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundColor(.blue)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Image(systemName: "doc.text")
                            .foregroundColor(isAccepted ? .green : .primary)
                        Text("Terms & Acknowledgment")
                            .font(.headline)
                    }

                    Text("Please review and accept the terms")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                StatusBadge(isGranted: isAccepted)
            }

            Text("Remote control of your Mac carries inherent risks. By proceeding, you accept full responsibility for actions taken with this software. The author is not liable for damages, data loss, or security incidents.")
                .font(.callout)
                .foregroundColor(.secondary)
                .padding(.leading, 60)

            Toggle(isOn: $isAccepted) {
                Text("I understand the risks and agree to the terms")
                    .font(.callout)
            }
            .toggleStyle(.checkbox)
            .padding(.leading, 60)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isAccepted ? Color.green.opacity(0.3) : Color.gray.opacity(0.2), lineWidth: 1)
        )
    }
}
