import Foundation

enum LogLevel: String {
    case info = "INFO"
    case warning = "WARN"
    case error = "ERROR"
}

final class LogStore: @unchecked Sendable {
    static let shared = LogStore()
    static let didUpdateNotification = Notification.Name("MacMCPControlLogStoreDidUpdate")

    private let queue = DispatchQueue(label: "mac.mcp.logs")
    private var entries: [String] = []
    private let maxEntries = 2000
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    private init() {}

    func log(_ message: String, level: LogLevel = .info) {
        let timestamp = dateFormatter.string(from: Date())
        let line = "[\(level.rawValue)] \(timestamp) \(message)"
        queue.async {
            self.entries.append(line)
            if self.entries.count > self.maxEntries {
                self.entries.removeFirst(self.entries.count - self.maxEntries)
            }
            NotificationCenter.default.post(name: LogStore.didUpdateNotification, object: nil)
        }
        print(line)
    }

    func snapshot() -> String {
        return queue.sync {
            entries.joined(separator: "\n")
        }
    }

    func clear() {
        queue.async {
            self.entries.removeAll()
            NotificationCenter.default.post(name: LogStore.didUpdateNotification, object: nil)
        }
    }
}
