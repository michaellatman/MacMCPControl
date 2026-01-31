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
        let redactedMessage = redactSensitive(message)
        let line = "[\(level.rawValue)] \(timestamp) \(redactedMessage)"
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

    private func redactSensitive(_ message: String) -> String {
        var output = message

        // Redact bearer tokens.
        output = output.replacingOccurrences(
            of: "Bearer\\s+[^\\s]+",
            with: "Bearer [redacted]",
            options: .regularExpression
        )

        // Redact common token fields in logs.
        let tokenFields = "(access_token|refresh_token|token|code|client_secret)"
        output = output.replacingOccurrences(
            of: "\(tokenFields)\\s*[:=]\\s*\"?[A-Za-z0-9._-]+\"?",
            with: "$1:[redacted]",
            options: .regularExpression
        )

        // Redact public URLs (keep localhost visible).
        let pattern = "(https?://)([^\\s/]+)([^\\s]*)"
        if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
            let range = NSRange(output.startIndex..<output.endIndex, in: output)
            let matches = regex.matches(in: output, options: [], range: range)
            for match in matches.reversed() {
                guard match.numberOfRanges >= 3,
                      let hostRange = Range(match.range(at: 2), in: output),
                      let fullRange = Range(match.range(at: 0), in: output),
                      let schemeRange = Range(match.range(at: 1), in: output),
                      let tailRange = Range(match.range(at: 3), in: output)
                else { continue }

                let host = String(output[hostRange])
                if host == "localhost" || host == "127.0.0.1" || host == "::1" {
                    continue
                }
                let scheme = String(output[schemeRange])
                let tail = String(output[tailRange])
                let replacement = "\(scheme)<redacted>\(tail)"
                output.replaceSubrange(fullRange, with: replacement)
            }
        }

        return output
    }
}
