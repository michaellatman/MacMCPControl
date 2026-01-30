import Foundation
import Swifter

struct PendingAuthRequestInfo: Identifiable, Hashable {
    let id: String
    let clientId: String
    let redirectUri: String
    let scope: String
    let source: String
    let confirmCode: String
    let codeChallengeMethod: String?
    let createdAt: Date
}

private struct PendingAuthRequest {
    let id: String
    let clientId: String
    let redirectUri: String
    let state: String
    let scope: String
    let source: String
    let pollToken: String
    let confirmCode: String
    var sessionName: String?
    let codeChallenge: String?
    let codeChallengeMethod: String?
    let createdAt: Date
    var decision: PendingAuthDecision
}

private enum PendingAuthDecision: Equatable {
    case pending
    case approved(code: String)
    case denied
}

final class McpServerManager {
    typealias StatsUpdateHandler = @Sendable (Int, Int) -> Void
    private let settingsManager: SettingsManager
    private let actionExecutor = ActionExecutor()
    private let oauthManager = OAuthManager()
    private let server = HttpServer()
    private var activeSessions: Set<String> = []
    private var sessionLastSeen: [String: Date] = [:]
    private let sessionTtl: TimeInterval = 5 * 60
    private let statsQueue = DispatchQueue(label: "mac.mcp.stats")
    private var isRunning = false
    private var pendingAuthRequests: [String: PendingAuthRequest] = [:]
    private var registeredClients: Set<String> = []
    private var lastExternalBaseUrl: String?
    private let authQueue = DispatchQueue(label: "mac.mcp.oauth.flow")
    private let pendingAuthTtl: TimeInterval = 10 * 60
    var onStatsUpdate: StatsUpdateHandler?
    var onAuthRequest: (@Sendable (PendingAuthRequestInfo) -> Void)?

    init(settingsManager: SettingsManager) {
        self.settingsManager = settingsManager
    }

    func start() {
        if isRunning {
            return
        }

        server.GET["/.well-known/oauth-authorization-server"] = { [weak self] request in
            guard let self else {
                return .internalServerError
            }
            self.logRequest(request)
            return self.handleAuthServerMetadata(request)
        }

        server.GET["/.well-known/oauth-protected-resource"] = { [weak self] request in
            guard let self else {
                return .internalServerError
            }
            self.logRequest(request)
            return self.handleProtectedResourceMetadata(request)
        }

        server.GET["/.well-known/oauth-protected-resource/mcp"] = { [weak self] request in
            guard let self else {
                return .internalServerError
            }
            self.logRequest(request)
            return self.handleProtectedResourceMetadata(request)
        }

        server.GET["/oauth/authorize"] = { [weak self] request in
            guard let self else {
                return .internalServerError
            }
            self.logRequest(request)
            return self.handleAuthorize(request)
        }

        server.GET["/oauth/approve"] = { [weak self] request in
            guard let self else {
                return .internalServerError
            }
            self.logRequest(request)
            return self.handleApprovePage(request)
        }

        server.GET["/oauth/pending"] = { [weak self] request in
            guard let self else {
                return .internalServerError
            }
            self.logRequest(request)
            return self.handlePendingAuth(request)
        }

        server.POST["/oauth/token"] = { [weak self] request in
            guard let self else {
                return .internalServerError
            }
            self.logRequest(request)
            return self.handleToken(request)
        }

        server.POST["/oauth/register"] = { [weak self] request in
            guard let self else {
                return .internalServerError
            }
            self.logRequest(request)
            return self.handleRegister(request)
        }

        server.POST["/oauth/introspect"] = { [weak self] request in
            guard let self else {
                return .internalServerError
            }
            self.logRequest(request)
            return self.handleIntrospect(request)
        }

        server.POST["/mcp"] = { [weak self] request in
            guard let self else {
                return .internalServerError
            }
            self.logRequest(request)
            return self.handlePost(request)
        }

        server.GET["/mcp"] = { [weak self] request in
            guard let self else {
                return .internalServerError
            }
            self.logRequest(request)
            return self.handleStream(request)
        }

        server.DELETE["/mcp"] = { [weak self] request in
            guard let self else {
                return .internalServerError
            }
            self.logRequest(request)
            return self.handleDelete(request)
        }

        do {
            try server.start(UInt16(settingsManager.mcpPort))
            isRunning = true
            LogStore.shared.log("MCP server listening on http://localhost:\(settingsManager.mcpPort)/mcp")
        } catch {
            LogStore.shared.log("Failed to start MCP server: \(error)", level: .error)
        }
    }

    func stop() {
        if isRunning {
            server.stop()
            isRunning = false
        }
    }

    func restart() {
        stop()
        start()
    }

    private func handleDelete(_ request: HttpRequest) -> HttpResponse {
        guard isAuthorized(request) else {
            return unauthorizedResponse(request, reason: "missing or invalid bearer token")
        }

        if let sessionHeader = headerValue(request, name: "mcp-session-id") {
            statsQueue.async { [weak self] in
                guard let self else { return }
                self.activeSessions.remove(sessionHeader)
                self.sessionLastSeen.removeValue(forKey: sessionHeader)
                self.emitStatsUpdate()
            }
        }
        return .raw(204, "No Content", [:], { _ in })
    }

    private func handleStream(_ request: HttpRequest) -> HttpResponse {
        guard isAuthorized(request) else {
            return unauthorizedResponse(request, reason: "missing or invalid bearer token")
        }

        guard let sessionHeader = headerValue(request, name: "mcp-session-id"), !sessionHeader.isEmpty else {
            return jsonRpcError(id: nil, message: "Missing MCP session id")
        }

        if !isSessionActive(sessionHeader) {
            return jsonRpcError(id: nil, message: "Invalid MCP session id")
        }

        noteSessionSeen(sessionHeader)

        let headers = [
            "Content-Type": "text/event-stream",
            "Cache-Control": "no-cache",
            "Connection": "keep-alive"
        ]

        return .raw(200, "OK", headers, { writer in
            try writer.write([UInt8](":ok\n\n".utf8))
            while true {
                Thread.sleep(forTimeInterval: 15.0)
                try writer.write([UInt8](":keepalive\n\n".utf8))
            }
        })
    }

    private func handlePost(_ request: HttpRequest) -> HttpResponse {
        guard let json = parseJson(request.body) else {
            return jsonRpcError(id: nil, message: "Invalid JSON")
        }

        guard let method = json["method"] as? String else {
            return jsonRpcError(id: json["id"], message: "Missing method")
        }

        guard isAuthorized(request) else {
            return unauthorizedResponse(request, reason: "missing or invalid bearer token")
        }

        let requestId = json["id"]
        let params = json["params"] as? [String: Any]

        if method == "initialize" {
            return handleInitialize(requestId: requestId)
        }

        if method == "notifications/initialized" {
            return .raw(204, "No Content", [:], { _ in })
        }

        guard let sessionHeader = headerValue(request, name: "mcp-session-id") else {
            return jsonRpcError(id: requestId, message: "Missing MCP session id")
        }

        if !isSessionActive(sessionHeader) {
            return jsonRpcError(id: requestId, message: "Invalid MCP session id")
        }

        noteSessionSeen(sessionHeader)

        switch method {
        case "tools/list":
            return handleToolsList(requestId: requestId)
        case "tools/call":
            return handleToolsCall(requestId: requestId, params: params)
        default:
            return jsonRpcError(id: requestId, message: "Unknown method: \(method)")
        }
    }

    private func handleInitialize(requestId: Any?) -> HttpResponse {
        let newSessionId = "mcp_\(UUID().uuidString)"
        registerSession(newSessionId)

        let result: [String: Any] = [
            "protocolVersion": "2025-03-26",
            "serverInfo": [
                "name": "mac-mcp-control",
                "version": "0.1.0"
            ],
            "capabilities": [
                "tools": [
                    "listChanged": false
                ]
            ]
        ]

        return jsonRpcResponse(
            id: requestId,
            result: result,
            headers: ["mcp-session-id": newSessionId]
        )
    }

    private func handleToolsList(requestId: Any?) -> HttpResponse {
        let actionTypes = [
            "mouse_move",
            "left_click",
            "left_click_drag",
            "right_click",
            "middle_click",
            "double_click",
            "screenshot",
            "key",
            "type",
            "cursor_position",
            "wait",
            "shell",
            "scroll"
        ]

        let actionSchema: [String: Any] = [
            "type": "object",
            "properties": [
                "type": ["type": "string", "enum": actionTypes],
                "action": ["type": "string", "enum": actionTypes],
                "text": ["type": "string"],
                "keys": [
                    "type": "array",
                    "items": ["type": "string"]
                ],
                "coordinate": [
                    "type": "array",
                    "items": ["type": "integer"],
                    "minItems": 2,
                    "maxItems": 2
                ],
                "duration": ["type": "number"],
                "command": ["type": "string", "description": "Shell command to execute. To run AppleScript, use osascript (e.g. osascript -e 'tell application \"System Events\" to keystroke \"a\" using command down')."],
                "direction": ["type": "string", "enum": ["up", "down", "left", "right"]],
                "amount": ["type": "integer"]
            ],
            "anyOf": [
                ["required": ["action"]],
                ["required": ["type"]]
            ]
        ]

        let tools: [[String: Any]] = [
            [
                "name": "computer",
                "description": "Run multiple computer actions in order: type, wait, click, etc, and optionally take a screenshot (must be last). To run AppleScript, use the shell action with osascript (e.g. command: \"osascript -e 'tell application \\\"System Events\\\" to keystroke \\\"a\\\" using command down'\").",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "actions": [
                            "type": "array",
                            "items": actionSchema
                        ]
                    ],
                    "required": ["actions"]
                ]
            ],
            [
                "name": "local_computer_status",
                "description": "Get status for the currently running local computer client.",
                "inputSchema": [
                    "type": "object",
                    "properties": [:],
                    "required": []
                ]
            ]
        ]

        return jsonRpcResponse(id: requestId, result: ["tools": tools])
    }

    private func handleToolsCall(requestId: Any?, params: [String: Any]?) -> HttpResponse {
        guard let params else {
            return jsonRpcError(id: requestId, message: "Missing params")
        }

        guard let name = params["name"] as? String else {
            return jsonRpcError(id: requestId, message: "Missing tool name")
        }

        let arguments = params["arguments"] as? [String: Any] ?? [:]

        switch name {
        case "computer":
            return handleComputerTool(requestId: requestId, arguments: arguments)
        case "local_computer_status":
            return handleStatusTool(requestId: requestId)
        default:
            return jsonRpcError(id: requestId, message: "Unknown tool: \(name)")
        }
    }

    private func handleComputerTool(requestId: Any?, arguments: [String: Any]) -> HttpResponse {
        guard let actions = arguments["actions"] as? [[String: Any]] else {
            return jsonRpcError(id: requestId, message: "Missing actions")
        }

        var actionsExecuted = 0
        var screenshot: [String: Any]? = nil
        var cursorPosition: [String: Any]? = nil
        var shellOutput: [String: Any]? = nil

        for (index, action) in actions.enumerated() {
            let actionType = (action["action"] as? String) ?? (action["type"] as? String)
            guard let actionType else {
                let keys = action.keys.sorted().joined(separator: ", ")
                return jsonRpcError(id: requestId, message: "Action #\(index) missing action type. Keys: \(keys)")
            }

            do {
                let result = try actionExecutor.execute(actionType: actionType, params: action)
                actionsExecuted += 1

                if let screenshotData = result["base64_image"] as? String {
                    screenshot = [
                        "mimeType": "image/png",
                        "base64Data": screenshotData
                    ]
                }

                if actionType == "cursor_position",
                   let x = result["x"] as? Int,
                   let y = result["y"] as? Int {
                    cursorPosition = ["x": x, "y": y]
                }

                if actionType == "shell" {
                    shellOutput = [
                        "success": result["success"] as? Bool ?? false,
                        "exitCode": result["exitCode"] as? Int ?? 1,
                        "stdout": result["stdout"] as? String ?? "",
                        "stderr": result["stderr"] as? String ?? ""
                    ]
                }
            } catch {
                let message = error.localizedDescription
                return jsonRpcToolError(id: requestId, message: message)
            }
        }

        var content: [[String: Any]] = [
            [
                "type": "text",
                "text": "Executed \(actionsExecuted) action(s)."
            ]
        ]

        if let cursorPosition {
            content.append([
                "type": "text",
                "text": "Cursor position: (\(cursorPosition["x"] ?? 0), \(cursorPosition["y"] ?? 0))"
            ])
        }

        if let shellOutput {
            content.append([
                "type": "text",
                "text": "Shell output (exit \(shellOutput["exitCode"] ?? 1), success=\(shellOutput["success"] ?? false)):\n<stdout>\(shellOutput["stdout"] ?? "")</stdout>\n<stderr>\(shellOutput["stderr"] ?? "")</stderr>"
            ])
        }

        if let screenshot {
            content.append([
                "type": "image",
                "data": screenshot["base64Data"] ?? "",
                "mimeType": screenshot["mimeType"] ?? "image/png"
            ])
        }

        return jsonRpcResponse(id: requestId, result: ["content": content])
    }

    private func handleStatusTool(requestId: Any?) -> HttpResponse {
        let localComputerId = settingsManager.localComputerId ?? generateAndStoreLocalComputerId()
        let text = "Local computer ready: \(settingsManager.deviceName) (localComputerId=\(localComputerId))."

        return jsonRpcResponse(id: requestId, result: [
            "content": [
                [
                    "type": "text",
                    "text": text
                ]
            ]
        ])
    }

    private func generateAndStoreLocalComputerId() -> String {
        let newId = "lc_\(UUID().uuidString.prefix(8))"
        settingsManager.localComputerId = newId
        return newId
    }

    private func registerSession(_ sessionId: String) {
        statsQueue.async { [weak self] in
            guard let self else { return }
            self.activeSessions.insert(sessionId)
            self.sessionLastSeen[sessionId] = Date()
            self.emitStatsUpdate()
        }
    }

    private func noteSessionSeen(_ sessionId: String) {
        statsQueue.async { [weak self] in
            guard let self else { return }
            self.sessionLastSeen[sessionId] = Date()
            self.emitStatsUpdate()
        }
    }

    private func isSessionActive(_ sessionId: String) -> Bool {
        return statsQueue.sync {
            let now = Date()
            sessionLastSeen = sessionLastSeen.filter { now.timeIntervalSince($0.value) <= sessionTtl }
            activeSessions = Set(sessionLastSeen.keys)
            return activeSessions.contains(sessionId)
        }
    }

    func statsSnapshot() -> (connectedClients: Int, authorizedSessions: Int) {
        return statsQueue.sync {
            return computeSnapshotLocked()
        }
    }

    func listAuthorizedSessions() -> [OAuthRefreshTokenInfo] {
        return oauthManager.listRefreshTokens()
    }

    func revokeAuthorizedSession(_ token: String) {
        oauthManager.revokeRefreshToken(token)
        emitStatsUpdate()
    }

    func revokeAllAuthorizedSessions() {
        oauthManager.revokeAllRefreshTokens()
        emitStatsUpdate()
    }

    private func emitStatsUpdate() {
        let snapshot = computeSnapshotLocked()
        notifyStatsUpdate(connected: snapshot.connectedClients, authorized: snapshot.authorizedSessions)
    }

    private func computeSnapshotLocked() -> (connectedClients: Int, authorizedSessions: Int) {
        let now = Date()
        sessionLastSeen = sessionLastSeen.filter { now.timeIntervalSince($0.value) <= sessionTtl }
        activeSessions = Set(sessionLastSeen.keys)
        let connected = activeSessions.count
        let authorized = oauthManager.authorizedSessionCount()
        return (connected, authorized)
    }

    private func notifyStatsUpdate(connected: Int, authorized: Int) {
        let handler = onStatsUpdate
        DispatchQueue.main.async {
            handler?(connected, authorized)
        }
    }

    private func handleAuthServerMetadata(_ request: HttpRequest) -> HttpResponse {
        // Use the request base URL (supports ngrok via X-Forwarded-* headers) so remote clients don't
        // get directed to localhost on their own machine.
        let issuer = baseUrl(for: request)
        let metadata: [String: Any] = [
            "issuer": issuer,
            "authorization_endpoint": "\(issuer)/oauth/authorize",
            "token_endpoint": "\(issuer)/oauth/token",
            "registration_endpoint": "\(issuer)/oauth/register",
            "introspection_endpoint": "\(issuer)/oauth/introspect",
            "response_types_supported": ["code"],
            "grant_types_supported": ["authorization_code"],
            "token_endpoint_auth_methods_supported": ["none"],
            "scopes_supported": ["mcp:tools"],
            "code_challenge_methods_supported": ["plain", "S256"]
        ]

        return jsonResponse(metadata)
    }

    private func handleProtectedResourceMetadata(_ request: HttpRequest) -> HttpResponse {
        let resourceBase = baseUrl(for: request)
        let resource = "\(resourceBase)/mcp"
        let metadata: [String: Any] = [
            "resource": resource,
            "authorization_servers": [resourceBase]
        ]
        return jsonResponse(metadata)
    }

    private func handleAuthorize(_ request: HttpRequest) -> HttpResponse {
        let query = queryParamsDict(request.queryParams)
        let responseType = query["response_type"] ?? ""
        let clientId = query["client_id"] ?? ""
        let redirectUri = decodeQueryValue(query["redirect_uri"] ?? "")
        let state = decodeQueryValue(query["state"] ?? "")
        let scope = decodeQueryValue(query["scope"] ?? "mcp:tools")
        let codeChallenge = decodeQueryValue(query["code_challenge"] ?? "")
        let codeChallengeMethod = query["code_challenge_method"]

        if responseType != "code" || clientId.isEmpty || redirectUri.isEmpty {
            return jsonResponse(["error": "invalid_request", "error_description": "Missing parameters"])
        }

        // We intentionally allow any redirect URI, but we surface it in the approval UI so the user can
        // validate they're approving the right callback destination.
        guard isValidRedirectUri(redirectUri) else {
            LogStore.shared.log("OAuth authorize error: invalid redirect_uri=\(redirectUri)", level: .warning)
            return jsonResponse(["error": "invalid_request", "error_description": "invalid redirect_uri"])
        }

        let requestId = "auth_\(UUID().uuidString)"
        let pollToken = "poll_\(UUID().uuidString)"
        let confirmCode = String(format: "%06d", Int.random(in: 0..<1_000_000))
        // For UX only; don't trust forwarded headers here.
        let source = request.address ?? (headerValue(request, name: "host") ?? "unknown")
        let now = Date()
        authQueue.sync {
            prunePendingAuthRequestsLocked(now: now)
            pendingAuthRequests[requestId] = PendingAuthRequest(
                id: requestId,
                clientId: clientId,
                redirectUri: redirectUri,
                state: state,
                scope: scope,
                source: source,
                pollToken: pollToken,
                confirmCode: confirmCode,
                sessionName: nil,
                codeChallenge: codeChallenge,
                codeChallengeMethod: codeChallengeMethod,
                createdAt: now,
                decision: .pending
            )
        }

        let info = PendingAuthRequestInfo(
            id: requestId,
            clientId: clientId,
            redirectUri: redirectUri,
            scope: scope,
            source: source,
            confirmCode: confirmCode,
            codeChallengeMethod: codeChallengeMethod,
            createdAt: now
        )
        let handler = onAuthRequest
        DispatchQueue.main.async {
            handler?(info)
        }

        // Use the request base URL so this works both locally and via ngrok/public hosts.
        let approvalUrl = "\(baseUrl(for: request))/oauth/approve?request_id=\(requestId)"
        return .raw(302, "Found", ["Location": approvalUrl], { _ in })
    }

    private func handleApprovePage(_ request: HttpRequest) -> HttpResponse {
        let query = queryParamsDict(request.queryParams)
        let requestId = query["request_id"] ?? ""
        guard let pending = authQueue.sync(execute: { pendingAuthRequests[requestId] }) else {
            return .raw(404, "Not Found", nil, { _ in })
        }

        let requestIdJs = escapeHtml(requestId)
        let pollTokenJs = escapeHtml(pending.pollToken)
        let confirmCodeEsc = escapeHtml(pending.confirmCode)
        let clientIdEsc = escapeHtml(pending.clientId)
        let redirectEsc = escapeHtml(pending.redirectUri)
        let scopeEsc = escapeHtml(pending.scope)
        let sourceEsc = escapeHtml(pending.source)

        let html = """
        <html>
          <head>
            <title>Approve In App</title>
            <style>
              body { font-family: -apple-system, Helvetica, Arial, sans-serif; padding: 24px; }
              .box { border: 1px solid #ddd; padding: 16px; border-radius: 8px; max-width: 520px; }
              .meta { color: #444; font-size: 13px; margin-top: 8px; }
              .code { font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, monospace; font-size: 24px; letter-spacing: 2px; background: #f4f4f4; border-radius: 8px; padding: 10px 12px; display: inline-block; }
              code { word-break: break-all; }
            </style>
          </head>
          <body>
            <div class="box">
              <h2>Approve In Mac MCP Control</h2>
              <p>This request can only be approved inside the Mac MCP Control app.</p>
              <p><strong>Confirm code</strong>: <span class="code">\(confirmCodeEsc)</span></p>
              <p><strong>Client</strong>: <code>\(clientIdEsc)</code></p>
              <p><strong>Redirect</strong>: <code>\(redirectEsc)</code></p>
              <p><strong>Scope</strong>: <code>\(scopeEsc)</code></p>
              <p><strong>Request from</strong>: <code>\(sourceEsc)</code></p>
              <div class="meta">Open the Mac MCP Control app to approve/deny. This page will continue automatically.</div>
            </div>
            <script>
              const requestId = "\(requestIdJs)";
              const pollToken = "\(pollTokenJs)";
              async function poll() {
                try {
                  const res = await fetch(`/oauth/pending?request_id=${encodeURIComponent(requestId)}&poll_token=${encodeURIComponent(pollToken)}`, { cache: "no-store" });
                  const body = await res.json();
                  if (body && body.status && body.status !== "pending" && body.redirect) {
                    window.location = body.redirect;
                    return;
                  }
                } catch (e) {
                  // ignore
                }
                setTimeout(poll, 500);
              }
              poll();
            </script>
          </body>
        </html>
        """

        return .raw(200, "OK", ["Content-Type": "text/html"], { writer in
            try writer.write(html.data(using: .utf8) ?? Data())
        })
    }

    private func handlePendingAuth(_ request: HttpRequest) -> HttpResponse {
        let query = queryParamsDict(request.queryParams)
        let requestId = query["request_id"] ?? ""
        let pollToken = query["poll_token"] ?? ""

        guard !requestId.isEmpty else {
            return jsonResponse(["status": "invalid_request"], headers: ["Cache-Control": "no-store"])
        }

        guard let pending = authQueue.sync(execute: { pendingAuthRequests[requestId] }) else {
            return jsonResponse(["status": "unknown_request"], headers: ["Cache-Control": "no-store"])
        }

        if Date().timeIntervalSince(pending.createdAt) > pendingAuthTtl {
            authQueue.sync { () -> Void in
                pendingAuthRequests.removeValue(forKey: requestId)
            }
            return jsonResponse(["status": "expired"], headers: ["Cache-Control": "no-store"])
        }

        guard !pollToken.isEmpty, pollToken == pending.pollToken else {
            return jsonResponse(["status": "forbidden"], headers: ["Cache-Control": "no-store"])
        }

        switch pending.decision {
        case .pending:
            return jsonResponse(["status": "pending"], headers: ["Cache-Control": "no-store"])
        case .approved(let code):
            let redirect = buildRedirect(redirectUri: pending.redirectUri, state: pending.state, code: code, error: nil)
            authQueue.sync { () -> Void in
                pendingAuthRequests.removeValue(forKey: requestId)
            }
            return jsonResponse([
                "status": "approved",
                "redirect": redirect
            ], headers: ["Cache-Control": "no-store"])
        case .denied:
            let redirect = buildRedirect(redirectUri: pending.redirectUri, state: pending.state, code: nil, error: "access_denied")
            authQueue.sync { () -> Void in
                pendingAuthRequests.removeValue(forKey: requestId)
            }
            return jsonResponse([
                "status": "denied",
                "redirect": redirect
            ], headers: ["Cache-Control": "no-store"])
        }
    }

    private func buildRedirect(redirectUri: String, state: String, code: String?, error: String?) -> String {
        guard let redirectUrl = URL(string: redirectUri) else {
            return redirectUri
        }

        var components = URLComponents(url: redirectUrl, resolvingAgainstBaseURL: false)
        var items = components?.queryItems ?? []

        if let code {
            items.append(URLQueryItem(name: "code", value: code))
        }
        if let error {
            items.append(URLQueryItem(name: "error", value: error))
        }
        if !state.isEmpty {
            items.append(URLQueryItem(name: "state", value: state))
        }

        components?.queryItems = items
        return components?.url?.absoluteString ?? redirectUri
    }

    func resolveAuthRequest(requestId: String, approve: Bool, sessionName: String?) {
        let pending: PendingAuthRequest? = authQueue.sync {
            pendingAuthRequests[requestId]
        }
        guard let pending else { return }

        if Date().timeIntervalSince(pending.createdAt) > pendingAuthTtl {
            authQueue.sync { () -> Void in
                pendingAuthRequests.removeValue(forKey: requestId)
            }
            return
        }

        if approve {
            let code = oauthManager.issueAuthorizationCode(
                clientId: pending.clientId,
                redirectUri: pending.redirectUri,
                scope: pending.scope,
                sessionName: sessionName,
                codeChallenge: pending.codeChallenge,
                codeChallengeMethod: pending.codeChallengeMethod
            )
            authQueue.sync {
                guard var current = pendingAuthRequests[requestId], current.decision == .pending else { return }
                current.decision = .approved(code: code)
                current.sessionName = sessionName
                pendingAuthRequests[requestId] = current
            }
        } else {
            authQueue.sync {
                guard var current = pendingAuthRequests[requestId], current.decision == .pending else { return }
                current.decision = .denied
                pendingAuthRequests[requestId] = current
            }
        }
    }

    // Must be called while holding authQueue.
    private func prunePendingAuthRequestsLocked(now: Date) {
        pendingAuthRequests = pendingAuthRequests.filter { _, value in
            now.timeIntervalSince(value.createdAt) <= pendingAuthTtl
        }
    }

    func renameAuthorizedSession(_ token: String, sessionName: String?) {
        oauthManager.renameRefreshToken(token, sessionName: sessionName)
        emitStatsUpdate()
    }

    private func handleToken(_ request: HttpRequest) -> HttpResponse {
        guard let params = parseFormBody(request.body) else {
            return jsonResponse(["error": "invalid_request", "error_description": "Invalid body"])
        }

        let grantType = params["grant_type"] ?? ""
        let code = params["code"] ?? ""
        let clientId = params["client_id"] ?? ""
        let redirectUri = params["redirect_uri"] ?? ""
        let refreshToken = params["refresh_token"] ?? ""
        let codeVerifier = params["code_verifier"]

        LogStore.shared.log("OAuth token request grant_type=\(grantType) client_id=\(clientId) has_code=\(!code.isEmpty) has_verifier=\(codeVerifier != nil) redirect_uri=\(redirectUri)")

        if clientId.isEmpty {
            LogStore.shared.log("OAuth token error: missing client_id", level: .warning)
            return jsonResponse(["error": "invalid_request", "error_description": "Missing client_id"])
        }

        if grantType == "authorization_code" && (code.isEmpty || redirectUri.isEmpty) {
            LogStore.shared.log("OAuth token error: missing parameters", level: .warning)
            return jsonResponse(["error": "invalid_request", "error_description": "Missing parameters"])
        }

        if !registeredClients.contains(clientId) {
            LogStore.shared.log("OAuth token: unknown client_id \(clientId), allowing and registering dynamically")
            registeredClients.insert(clientId)
        }

        if grantType == "authorization_code" {
            guard let result = oauthManager.exchangeCode(
                code: code,
                clientId: clientId,
                redirectUri: redirectUri,
                codeVerifier: codeVerifier
            ) else {
                LogStore.shared.log("OAuth token error: invalid grant for client_id=\(clientId)", level: .warning)
                return jsonResponse(["error": "invalid_grant", "error_description": "Invalid code"])
            }

            let response: [String: Any] = [
                "access_token": result.token,
                "accessToken": result.token,
                "refresh_token": result.refreshToken,
                "token_type": "Bearer",
                "expires_in": result.expiresIn,
                "scope": result.scope
            ]
            LogStore.shared.log("Issued OAuth token for client=\(clientId) scope=\"\(result.scope)\" keys=\(response.keys.sorted())")
            emitStatsUpdate()
            return jsonResponse(response)
        }

        if grantType == "refresh_token" {
            if refreshToken.isEmpty {
                LogStore.shared.log("OAuth token error: missing refresh_token", level: .warning)
                return jsonResponse(["error": "invalid_request", "error_description": "Missing refresh_token"])
            }

            guard let result = oauthManager.exchangeRefreshToken(refreshToken: refreshToken, clientId: clientId) else {
                LogStore.shared.log("OAuth token error: invalid refresh_token for client_id=\(clientId)", level: .warning)
                return jsonResponse(["error": "invalid_grant", "error_description": "Invalid refresh_token"])
            }

            let response: [String: Any] = [
                "access_token": result.token,
                "accessToken": result.token,
                "token_type": "Bearer",
                "expires_in": result.expiresIn,
                "scope": result.scope
            ]
            LogStore.shared.log("Issued OAuth refresh token for client=\(clientId) scope=\"\(result.scope)\" keys=\(response.keys.sorted())")
            emitStatsUpdate()
            return jsonResponse(response)
        }

        LogStore.shared.log("OAuth token error: unsupported grant_type \(grantType)", level: .warning)
        return jsonResponse(["error": "unsupported_grant_type", "error_description": "Unsupported grant_type"])
    }

    private func handleRegister(_ request: HttpRequest) -> HttpResponse {
        guard let json = parseJson(request.body) else {
            return jsonResponse(["error": "invalid_request", "error_description": "Invalid JSON"])
        }

        let clientId = "client_\(UUID().uuidString)"
        registeredClients.insert(clientId)

        let response: [String: Any] = [
            "client_id": clientId,
            "token_endpoint_auth_method": "none",
            "redirect_uris": json["redirect_uris"] ?? [],
            "grant_types": json["grant_types"] ?? ["authorization_code"],
            "response_types": json["response_types"] ?? ["code"]
        ]

        return jsonResponse(response)
    }

    private func handleIntrospect(_ request: HttpRequest) -> HttpResponse {
        guard let params = parseFormBody(request.body) else {
            return jsonResponse(["active": false])
        }

        let token = params["token"] ?? ""
        guard let record = oauthManager.introspect(token: token) else {
            return jsonResponse(["active": false])
        }

        let response: [String: Any] = [
            "active": true,
            "client_id": record.clientId,
            "scope": record.scope,
            "exp": Int(record.expiresAt.timeIntervalSince1970),
            "token_type": "Bearer"
        ]

        return jsonResponse(response)
    }

    private func isAuthorized(_ request: HttpRequest) -> Bool {
        guard let authHeader = headerValue(request, name: "authorization") else {
            return false
        }

        guard authHeader.lowercased().hasPrefix("bearer ") else {
            return false
        }

        let token = String(authHeader.dropFirst("bearer ".count))
        return oauthManager.validateBearer(token)
    }

    private func unauthorizedResponse(_ request: HttpRequest, reason: String) -> HttpResponse {
        LogStore.shared.log("HTTP 401 Unauthorized: \(reason)", level: .warning)
        let base = baseUrl(for: request)
        let resource = "\(base)/mcp"
        let authServer = base
        let resourceMetadata = "\(authServer)/.well-known/oauth-protected-resource/mcp"
        let headerValue = "Bearer realm=\"mac-mcp-control\", resource=\"\(resource)\", authorization_uri=\"\(authServer)/oauth/authorize\", resource_metadata=\"\(resourceMetadata)\""
        return .raw(401, "Unauthorized", ["WWW-Authenticate": headerValue], { _ in })
    }

    private func headerValue(_ request: HttpRequest, name: String) -> String? {
        let lower = name.lowercased()
        for (key, value) in request.headers {
            if key.lowercased() == lower {
                return value
            }
        }
        return nil
    }

    private func parseJson(_ body: [UInt8]) -> [String: Any]? {
        guard let data = Data(bytes: body, count: body.count) as Data? else {
            return nil
        }

        guard let json = try? JSONSerialization.jsonObject(with: data, options: []) else {
            return nil
        }

        return json as? [String: Any]
    }

    private func parseFormBody(_ body: [UInt8]) -> [String: String]? {
        guard let data = String(bytes: body, encoding: .utf8) else {
            return nil
        }

        var result: [String: String] = [:]
        for pair in data.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            if parts.count == 2 {
                let key = String(parts[0]).removingPercentEncoding ?? ""
                let value = String(parts[1]).removingPercentEncoding ?? ""
                result[key] = value
            }
        }

        return result
    }

    private func queryParamsDict(_ params: [(String, String)]) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in params {
            result[key] = value
        }
        return result
    }

    private func baseUrl(for request: HttpRequest) -> String {
        let hostHeader = headerValue(request, name: "x-forwarded-host") ?? headerValue(request, name: "host")
        let scheme = headerValue(request, name: "x-forwarded-proto") ?? "http"
        if let hostHeader, !hostHeader.isEmpty {
            let url = "\(scheme)://\(hostHeader)"
            if !isLocalHostHeader(hostHeader) {
                lastExternalBaseUrl = url
            }
            return url
        }
        return "http://localhost:\(settingsManager.mcpPort)"
    }

    private func localBaseUrl() -> String {
        return "http://localhost:\(settingsManager.mcpPort)"
    }

    private func isLocalHostHeader(_ hostHeader: String) -> Bool {
        let host = hostHeader.split(separator: ":").first.map(String.init) ?? hostHeader
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }

    private func isLocalRequest(_ request: HttpRequest) -> Bool {
        // Never trust Host/X-Forwarded-* here; require an actual loopback socket peer.
        guard let address = request.address else {
            return false
        }
        return isLoopbackPeerAddress(address)
    }

    private func isLoopbackPeerAddress(_ address: String) -> Bool {
        // Swifter formats this as "<ip>:<port>" (e.g. "127.0.0.1:12345").
        let host = address.split(separator: ":").first.map(String.init) ?? address
        return host == "127.0.0.1" || host == "::1" || host == "localhost"
    }

    private func isValidRedirectUri(_ redirectUri: String) -> Bool {
        guard let url = URL(string: redirectUri) else {
            return false
        }
        // Require a scheme so the user sees an unambiguous destination.
        guard let scheme = url.scheme, !scheme.isEmpty else {
            return false
        }
        return true
    }

    private func decodeQueryValue(_ value: String) -> String {
        return value.removingPercentEncoding ?? value
    }

    private func escapeHtml(_ value: String) -> String {
        var escaped = value
        escaped = escaped.replacingOccurrences(of: "&", with: "&amp;")
        escaped = escaped.replacingOccurrences(of: "<", with: "&lt;")
        escaped = escaped.replacingOccurrences(of: ">", with: "&gt;")
        escaped = escaped.replacingOccurrences(of: "\"", with: "&quot;")
        escaped = escaped.replacingOccurrences(of: "'", with: "&#39;")
        return escaped
    }

    private func logRequest(_ request: HttpRequest) {
        let query = request.queryParams.map { "\($0.0)=\($0.1)" }.joined(separator: "&")
        let pathWithQuery = query.isEmpty ? request.path : "\(request.path)?\(query)"
        var headers = request.headers
        for key in headers.keys {
            if key.lowercased() == "authorization" {
                headers[key] = "[redacted]"
            }
        }
        let bodySize = request.body.count
        let address = request.address ?? "unknown"
        LogStore.shared.log("HTTP \(request.method) \(pathWithQuery) from \(address) headers=\(headers) bodyBytes=\(bodySize)")
    }

    private func jsonRpcResponse(id: Any?, result: [String: Any], headers: [String: String] = [:]) -> HttpResponse {
        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id ?? 0,
            "result": result
        ]

        return jsonResponse(payload, headers: headers)
    }

    private func jsonRpcError(id: Any?, message: String) -> HttpResponse {
        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id ?? 0,
            "error": [
                "code": -32602,
                "message": message
            ]
        ]

        return jsonResponse(payload)
    }

    private func jsonRpcToolError(id: Any?, message: String) -> HttpResponse {
        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id ?? 0,
            "result": [
                "content": [
                    [
                        "type": "text",
                        "text": message
                    ]
                ],
                "isError": true
            ]
        ]

        return jsonResponse(payload)
    }

    private func jsonResponse(_ payload: [String: Any], headers: [String: String] = [:]) -> HttpResponse {
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: []) else {
            return .internalServerError
        }

        var responseHeaders = ["Content-Type": "application/json"]
        for (key, value) in headers {
            responseHeaders[key] = value
        }

        return .raw(200, "OK", responseHeaders, { writer in
            try writer.write(data)
        })
    }
}
