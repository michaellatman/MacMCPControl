import AppKit

@MainActor
func sessionStorageAlert(_ error: Error, title: String) -> NSAlert {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = title
    alert.informativeText = "\(error.localizedDescription) Keep the app open until the change is saved."
    alert.addButton(withTitle: "Retry")
    alert.addButton(withTitle: "Cancel")
    return alert
}
