import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var appState: AppState?

    func applicationWillTerminate(_ notification: Notification) {
        // Best-effort cleanup so we don't leave an ngrok tunnel/process running after quit.
        Task { @MainActor in
            appState?.stopServices()
        }
    }
}

