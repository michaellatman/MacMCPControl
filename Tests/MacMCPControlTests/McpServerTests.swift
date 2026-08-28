import XCTest
import Swifter
@testable import MacMCPControl

final class McpServerTests: XCTestCase {
    var manager: McpServerManager!
    var oauth: OAuthManager!
    var settings: SettingsManager!
    var suite: String!

    override func setUp() {
        suite = "MacMCPControlTests.\(UUID().uuidString)"
        settings = SettingsManager(defaults: UserDefaults(suiteName: suite)!)
        oauth = isolatedOAuth()
        manager = McpServerManager(settingsManager: settings, oauthManager: oauth)
        manager.configureRoutes()
    }

    override func tearDown() {
        manager.stop()
        UserDefaults.standard.removePersistentDomain(forName: suite)
    }

    func request(_ method: String, _ path: String, query: [String: String] = [:], body: String = "", headers: [String: String] = [:]) -> HttpResponse {
        let req = HttpRequest()
        req.method = method; req.path = path; req.queryParams = query.map { ($0.key, $0.value) }
        req.body = Array(body.utf8); req.headers = ["host": "localhost:\(settings.mcpPort)"].merging(headers) { _, new in new }
        let (_, handler) = manager.server.dispatch(req)
        return handler(req)
    }

    final class Writer: HttpResponseBodyWriter {
        var data = Data()
        func write(_ file: String.File) throws { XCTFail("Unexpected file response") }
        func write(_ value: [UInt8]) throws { data.append(contentsOf: value) }
        func write(_ value: ArraySlice<UInt8>) throws { data.append(contentsOf: value) }
        func write(_ value: NSData) throws { data.append(value as Data) }
        func write(_ value: Data) throws { data.append(value) }
    }

    func body(_ response: HttpResponse) throws -> String {
        let writer = Writer()
        if case .raw(_, _, _, let write) = response { try write?(writer) }
        return String(decoding: writer.data, as: UTF8.self)
    }

    func json(_ response: HttpResponse) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(body(response).utf8)) as? [String: Any])
    }

    func register() throws -> String {
        try XCTUnwrap(json(request("POST", "/oauth/register", body: "{\"redirect_uris\":[\"https://example.com/callback\"]}"))["client_id"] as? String)
    }

    func authorizeQuery(_ client: String) -> [String: String] {
        ["response_type": "code", "client_id": client, "redirect_uri": "https://example.com/callback", "code_challenge": testChallenge, "code_challenge_method": "S256"]
    }

    func testRegistrationAndAuthorizeEnforceCallbackAndPKCE() throws {
        let client = try register()
        let valid = authorizeQuery(client)
        XCTAssertEqual(request("GET", "/oauth/authorize", query: valid).statusCode, 302)
        for (key, value) in [("redirect_uri", "https://evil.example/callback"), ("client_id", "unknown"), ("code_challenge_method", "plain"), ("code_challenge", ""), ("scope", "read-only")] {
            var query = valid; query[key] = value
            XCTAssertNotNil(try json(request("GET", "/oauth/authorize", query: query))["error"])
        }
        XCTAssertNotNil(try json(request("POST", "/oauth/register", body: "{\"redirect_uris\":[\"javascript:alert(1)\"]}"))["error"])
    }

    func testRevocationCancelsPendingApprovalDialog() throws {
        let result = request("GET", "/oauth/authorize", query: authorizeQuery(try register()))
        let location = try XCTUnwrap(result.headers()["Location"])
        let id = try XCTUnwrap(URLComponents(string: location)?.queryItems?.first?.value)
        manager.revokeAllAuthorizedSessions()
        manager.resolveAuthRequest(requestId: id, approve: true, sessionName: nil)
        XCTAssertEqual(request("GET", "/oauth/approve", query: ["request_id": id]).statusCode, 404)
        XCTAssertEqual(oauth.authorizedSessionCount(), 0)
    }

    func testFullApprovalExchangeAndShellDefaultOff() throws {
        let client = try register()
        let response = request("GET", "/oauth/authorize", query: authorizeQuery(client))
        let location = try XCTUnwrap(response.headers()["Location"])
        let id = try XCTUnwrap(URLComponents(string: location)?.queryItems?.first?.value)
        let page = try body(request("GET", "/oauth/approve", query: ["request_id": id]))
        let pollToken = try XCTUnwrap(page.components(separatedBy: "const pollToken = \"").last?.components(separatedBy: "\"").first)
        XCTAssertEqual(try json(request("GET", "/oauth/pending", query: ["request_id": id, "poll_token": pollToken]))["status"] as? String, "pending")
        manager.resolveAuthRequest(requestId: id, approve: true, sessionName: "test")
        let redirect = try XCTUnwrap(json(request("GET", "/oauth/pending", query: ["request_id": id, "poll_token": pollToken]))["redirect"] as? String)
        let code = try XCTUnwrap(URLComponents(string: redirect)?.queryItems?.first { $0.name == "code" }?.value)
        let tokens = try json(request("POST", "/oauth/token", body: "grant_type=authorization_code&client_id=\(client)&redirect_uri=https%3A%2F%2Fexample.com%2Fcallback&code=\(code)&code_verifier=\(testVerifier)"))
        let token = try XCTUnwrap(tokens["access_token"] as? String)
        var headers = ["authorization": "Bearer \(token)"]
        let initialized = request("POST", "/mcp", body: "{\"id\":1,\"method\":\"initialize\"}", headers: headers)
        headers["mcp-session-id"] = try XCTUnwrap(initialized.headers()["mcp-session-id"])
        XCTAssertFalse(settings.shellEnabled)
        let shell = request("POST", "/mcp", body: "{\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"computer\",\"arguments\":{\"actions\":[{\"action\":\"shell\",\"command\":\"exit 99\"}]}}}", headers: headers)
        XCTAssertTrue(try body(shell).contains("Shell access is disabled"))
        manager.revokeAllAuthorizedSessions()
        XCTAssertEqual(request("POST", "/mcp", body: "{\"id\":1,\"method\":\"initialize\"}", headers: headers).statusCode, 401)
    }

    func testOriginAndMetadataCannotBePoisoned() throws {
        XCTAssertEqual(request("GET", "/.well-known/oauth-authorization-server", headers: ["host": "evil.example"]).statusCode, 403)
        XCTAssertEqual(request("GET", "/.well-known/oauth-authorization-server", headers: ["origin": "https://evil.example"]).statusCode, 403)
        let metadata = try json(request("GET", "/.well-known/oauth-authorization-server", headers: ["x-forwarded-host": "evil.example", "x-forwarded-proto": "https"]))
        XCTAssertEqual(metadata["issuer"] as? String, "http://localhost:7519")
        manager.setPublicBaseUrl("https://test.ngrok.app")
        XCTAssertEqual(request("GET", "/.well-known/oauth-authorization-server", headers: ["host": "test.ngrok.app", "x-forwarded-proto": "http"]).statusCode, 403)
        let remote = try json(request("GET", "/.well-known/oauth-authorization-server", headers: ["host": "test.ngrok.app", "x-forwarded-proto": "https"]))
        XCTAssertEqual(remote["issuer"] as? String, "https://test.ngrok.app")
    }

    func testApprovalFloodIsBounded() throws {
        let query = authorizeQuery(try register())
        for _ in 0..<10 { XCTAssertEqual(request("GET", "/oauth/authorize", query: query).statusCode, 302) }
        XCTAssertEqual(request("GET", "/oauth/authorize", query: query).statusCode, 429)
    }

    func testClientRegistrationIsBoundedAndRecyclesUnusedEntries() throws {
        var clients: [String: RegisteredOAuthClient] = [:]
        for index in 0..<256 {
            clients["old-\(index)"] = RegisteredOAuthClient(redirectUris: ["https://example.com/callback"], createdAt: Date(timeIntervalSince1970: Double(index)))
        }
        settings.registeredOAuthClients = clients
        manager = McpServerManager(settingsManager: settings, oauthManager: oauth)
        manager.configureRoutes()
        let newClient = try register()
        XCTAssertEqual(settings.registeredOAuthClients.count, 256)
        XCTAssertNil(settings.registeredOAuthClients["old-0"])
        XCTAssertNotNil(settings.registeredOAuthClients[newClient])
        // Registrations survive server restarts, including their exact callback binding.
        manager = McpServerManager(settingsManager: settings, oauthManager: oauth)
        manager.configureRoutes()
        XCTAssertEqual(request("GET", "/oauth/authorize", query: authorizeQuery(newClient)).statusCode, 302)
        for _ in 0..<10 { _ = try register() }
        XCTAssertEqual(request("POST", "/oauth/register", body: "{\"redirect_uris\":[\"https://example.com/callback\"]}").statusCode, 429)
    }

    func testRealHTTPListenerAndUnauthenticatedRequest() async throws {
        let reservation = try Socket.tcpSocketForListen(0, true, 1, "127.0.0.1")
        settings.mcpPort = Int(try reservation.port())
        reservation.close()
        manager.start()
        XCTAssertEqual(manager.server.listenAddressIPv4, "127.0.0.1")
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(settings.mcpPort)/mcp")!)
        request.httpMethod = "POST"
        request.httpBody = Data("{\"id\":1,\"method\":\"initialize\"}".utf8)
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 401)

        let base = "http://127.0.0.1:\(settings.mcpPort)"
        var registration = URLRequest(url: URL(string: base + "/oauth/register")!)
        registration.httpMethod = "POST"
        registration.httpBody = Data("{\"redirect_uris\":[\"https://example.com/callback\"]}".utf8)
        let (registrationData, _) = try await URLSession.shared.data(for: registration)
        let registered = try XCTUnwrap(JSONSerialization.jsonObject(with: registrationData) as? [String: Any])
        let client = try XCTUnwrap(registered["client_id"] as? String)
        var authorize = URLComponents(string: base + "/oauth/authorize")!
        authorize.queryItems = authorizeQuery(client).map { URLQueryItem(name: $0.key, value: $0.value) }
        // URLSession follows the production redirect to the in-app-approval waiting page.
        let (pageData, approvalResponse) = try await URLSession.shared.data(from: authorize.url!)
        let id = try XCTUnwrap(URLComponents(url: approvalResponse.url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value)
        let page = String(decoding: pageData, as: UTF8.self)
        XCTAssertTrue(page.contains("Approve In Mac MCP Control"))
        let pollToken = try XCTUnwrap(page.components(separatedBy: "const pollToken = \"").last?.components(separatedBy: "\"").first)
        manager.resolveAuthRequest(requestId: id, approve: true, sessionName: "HTTP regression")
        let (pollData, _) = try await URLSession.shared.data(from: URL(string: base + "/oauth/pending?request_id=\(id)&poll_token=\(pollToken)")!)
        let polled = try XCTUnwrap(JSONSerialization.jsonObject(with: pollData) as? [String: Any])
        let redirect = try XCTUnwrap(polled["redirect"] as? String)
        let code = try XCTUnwrap(URLComponents(string: redirect)?.queryItems?.first { $0.name == "code" }?.value)
        var tokenRequest = URLRequest(url: URL(string: base + "/oauth/token")!)
        tokenRequest.httpMethod = "POST"
        tokenRequest.httpBody = Data("grant_type=authorization_code&client_id=\(client)&redirect_uri=https%3A%2F%2Fexample.com%2Fcallback&code=\(code)&code_verifier=\(testVerifier)".utf8)
        let (tokenData, _) = try await URLSession.shared.data(for: tokenRequest)
        let tokens = try XCTUnwrap(JSONSerialization.jsonObject(with: tokenData) as? [String: Any])
        let token = try XCTUnwrap(tokens["access_token"] as? String)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (_, authorizedResponse) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((authorizedResponse as? HTTPURLResponse)?.statusCode, 200)
        manager.revokeAllAuthorizedSessions()
        let (_, revokedResponse) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((revokedResponse as? HTTPURLResponse)?.statusCode, 401)
    }
}
