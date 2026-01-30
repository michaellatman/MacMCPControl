import Foundation

@MainActor
final class NgrokManager {
    private var process: Process?
    private var pollTimer: Timer?
    private(set) var publicUrl: String? = nil
    var onUpdate: ((String?) -> Void)?
    private var didRetry = false
    private var ngrokExecutableUrl: URL?

    func start(port: Int, authToken: String) {
        stop()
        didRetry = false
        ngrokExecutableUrl = resolveNgrokExecutable()

        cleanupExistingNgrok()

        if !authToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            configureAuthToken(authToken)
        }

        let process = Process()
        if let ngrokExecutableUrl {
            process.executableURL = ngrokExecutableUrl
            process.arguments = ["http", String(port), "--log=stdout", "--log-format=json"]
            LogStore.shared.log("Using bundled ngrok at \(ngrokExecutableUrl.path)")
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["ngrok", "http", String(port), "--log=stdout", "--log-format=json"]
            LogStore.shared.log("Using ngrok from PATH")
        }

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let line = String(data: data, encoding: .utf8) else {
                return
            }
            Task { @MainActor in
                self?.handleNgrokLog(line, port: port, authToken: authToken)
            }
        }

        do {
            try process.run()
            self.process = process
            startPolling()
        } catch {
            LogStore.shared.log("Failed to start ngrok: \(error)", level: .error)
        }
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil

        if let process {
            if let handle = process.standardOutput as? Pipe {
                handle.fileHandleForReading.readabilityHandler = nil
            }
            process.terminate()
            self.process = nil
        }

        updatePublicUrl(nil)
    }

    private func configureAuthToken(_ token: String) {
        _ = runNgrok(["config", "add-authtoken", token])
    }

    private func startPolling() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.fetchPublicUrl()
            }
        }
    }

    private func fetchPublicUrl() {
        guard let url = URL(string: "http://127.0.0.1:4040/api/tunnels") else {
            return
        }

        let task = URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let self, let data else {
                return
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tunnels = json["tunnels"] as? [[String: Any]] else {
                return
            }

            let httpsTunnel = tunnels.first { ($0["proto"] as? String) == "https" }
            let urlValue = httpsTunnel?["public_url"] as? String

            Task { @MainActor in
                if urlValue != self.publicUrl {
                    self.updatePublicUrl(urlValue)
                }
            }
        }

        task.resume()
    }

    private func updatePublicUrl(_ url: String?) {
        publicUrl = url
        onUpdate?(url)
    }

    private func cleanupExistingNgrok() {
        _ = runNgrok(["kill"])
        runProcess(["/usr/bin/pkill", "-f", "ngrok"])
    }

    private func handleNgrokLog(_ message: String, port: Int, authToken: String) {
        logNgrok(message)
        if message.contains("ERR_NGROK_334") {
            if !didRetry {
                didRetry = true
                logNgrok("Detected ERR_NGROK_334, stopping ngrok to avoid restart loop. Close the existing endpoint or change the reserved domain.")
                stop()
            }
        }
    }

    private func logNgrok(_ message: String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            LogStore.shared.log("ngrok: \(trimmed)")
        }
    }

    private func runProcess(_ args: [String]) {
        guard let executable = args.first else {
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Array(args.dropFirst())
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            // Ignore cleanup failures.
        }
    }

    private func runNgrok(_ arguments: [String]) -> Process? {
        let process = Process()
        if let ngrokExecutableUrl {
            process.executableURL = ngrokExecutableUrl
            process.arguments = arguments
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["ngrok"] + arguments
        }
        do {
            try process.run()
            process.waitUntilExit()
            return process
        } catch {
            LogStore.shared.log("Failed to run ngrok \(arguments.joined(separator: " ")): \(error)", level: .warning)
            return nil
        }
    }

    private func resolveNgrokExecutable() -> URL? {
        // SwiftPM resources are reliably accessed via Bundle.module.
        if let url = Bundle.module.url(forResource: "ngrok", withExtension: nil) {
            return url
        }
        // Fallback for non-SwiftPM packaging scenarios.
        return Bundle.main.url(forResource: "ngrok", withExtension: nil)
    }
}
