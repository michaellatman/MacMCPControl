import Foundation
@preconcurrency import ApplicationServices

class AccessibilityPermissions {
    static func checkAndRequestPermissions() -> Bool {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options: NSDictionary = [promptKey: true]
        let accessEnabled = AXIsProcessTrustedWithOptions(options)

        if accessEnabled {
            print("✓ Accessibility permissions granted")
        } else {
            print("⚠️  Accessibility permissions not granted")
            print("   Please grant accessibility permissions in System Preferences:")
            print("   System Preferences > Security & Privacy > Privacy > Accessibility")
            print("   Add 'Mac MCP Control' to the list and enable it")
        }

        return accessEnabled
    }

    static func isAccessibilityEnabled() -> Bool {
        return AXIsProcessTrusted()
    }
}
