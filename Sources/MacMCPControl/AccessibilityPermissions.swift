import Foundation
@preconcurrency import ApplicationServices

class AccessibilityPermissions {
    static func checkAndRequestPermissions() -> Bool {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options: NSDictionary = [promptKey: true]
        let accessEnabled = AXIsProcessTrustedWithOptions(options)

        if accessEnabled {
            LogStore.shared.log("Accessibility permissions granted.")
        } else {
            LogStore.shared.log("Accessibility permissions not granted.", level: .warning)
            LogStore.shared.log("Open System Settings > Privacy & Security > Accessibility and enable \"Mac MCP Control\".", level: .warning)
        }

        return accessEnabled
    }

    static func isAccessibilityEnabled() -> Bool {
        return AXIsProcessTrusted()
    }
}
