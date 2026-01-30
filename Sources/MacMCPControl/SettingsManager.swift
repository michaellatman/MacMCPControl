import Foundation

class SettingsManager {
    private let defaults = UserDefaults.standard

    private enum Keys {
        static let deviceName = "deviceName"
        static let localComputerId = "localComputerId"
        static let mcpPort = "mcpPort"
        static let ngrokEnabled = "ngrokEnabled"
        static let ngrokAuthToken = "ngrokAuthToken"
        static let acceptedTerms = "acceptedTerms"
    }

    var deviceName: String {
        get { defaults.string(forKey: Keys.deviceName) ?? Host.current().localizedName ?? "My Mac" }
        set { defaults.set(newValue, forKey: Keys.deviceName) }
    }

    var mcpPort: Int {
        get {
            let value = defaults.integer(forKey: Keys.mcpPort)
            return value == 0 ? 7519 : value
        }
        set { defaults.set(newValue, forKey: Keys.mcpPort) }
    }

    var ngrokEnabled: Bool {
        get {
            if defaults.object(forKey: Keys.ngrokEnabled) == nil {
                return false
            }
            return defaults.bool(forKey: Keys.ngrokEnabled)
        }
        set { defaults.set(newValue, forKey: Keys.ngrokEnabled) }
    }

    var ngrokAuthToken: String {
        get { defaults.string(forKey: Keys.ngrokAuthToken) ?? "" }
        set { defaults.set(newValue, forKey: Keys.ngrokAuthToken) }
    }

    var localComputerId: String? {
        get { defaults.string(forKey: Keys.localComputerId) }
        set { defaults.set(newValue, forKey: Keys.localComputerId) }
    }

    var acceptedTerms: Bool {
        get { defaults.bool(forKey: Keys.acceptedTerms) }
        set { defaults.set(newValue, forKey: Keys.acceptedTerms) }
    }

    func hasValidSettings() -> Bool {
        return !deviceName.isEmpty
    }
}
