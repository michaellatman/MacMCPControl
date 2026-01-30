import Foundation
import CoreGraphics

class ScreenRecordingPermissions {
    static func checkAndRequestPermissions() -> Bool {
        let accessEnabled = CGPreflightScreenCaptureAccess()
        if accessEnabled {
            LogStore.shared.log("Screen recording permissions granted.")
        } else {
            LogStore.shared.log("Screen recording permissions not granted.", level: .warning)
            LogStore.shared.log("Open System Settings > Privacy & Security > Screen Recording and enable \"Mac MCP Control\".", level: .warning)
            _ = CGRequestScreenCaptureAccess()
        }
        return accessEnabled
    }

    static func isScreenRecordingEnabled() -> Bool {
        return CGPreflightScreenCaptureAccess()
    }
}
