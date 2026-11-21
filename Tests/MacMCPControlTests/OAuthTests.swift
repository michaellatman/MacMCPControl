import XCTest
import CryptoKit
@testable import MacMCPControl

func isolatedOAuth() -> OAuthManager {
    OAuthManager(load: { OAuthState(signingKey: OAuthState.freshKey(), grants: [:]) }, save: { _ in })
}

let testVerifier = String(repeating: "a", count: 43)
let testChallenge = Data(SHA256.hash(data: Data(testVerifier.utf8))).base64EncodedString()
    .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")

final class OAuthTests: XCTestCase {
    func code(_ manager: OAuthManager, client: String = "test") throws -> String {
        try XCTUnwrap(manager.issueAuthorizationCode(clientId: client, redirectUri: "https://example.com/callback", scope: "mcp:tools", sessionName: nil, codeChallenge: testChallenge, codeChallengeMethod: "S256"))
    }

    func authorize(_ manager: OAuthManager) throws -> (token: String, refreshToken: String, expiresIn: Int, scope: String) {
        try XCTUnwrap(manager.exchangeCode(code: code(manager), clientId: "test", redirectUri: "https://example.com/callback", codeVerifier: testVerifier))
    }

    func testRevokedAccessCannotReturnAfterReauthorization() throws {
        let manager = isolatedOAuth()
        let first = try authorize(manager)
        XCTAssertTrue(manager.validateBearer(first.token))
        try manager.revokeSession(XCTUnwrap(manager.listSessions().first).id)
        XCTAssertFalse(manager.validateBearer(first.token))
        let second = try authorize(manager)
        XCTAssertTrue(manager.validateBearer(second.token))
        XCTAssertFalse(manager.validateBearer(first.token))
        XCTAssertNil(manager.introspect(token: first.token))
        XCTAssertNil(try manager.exchangeRefreshToken(refreshToken: first.refreshToken, clientId: "test"))
    }

    func testRevokeAllInvalidatesCodesAndTokens() throws {
        let manager = isolatedOAuth()
        let first = try authorize(manager)
        let pending = try code(manager)
        try manager.revokeAllRefreshTokens()
        XCTAssertFalse(manager.validateBearer(first.token))
        XCTAssertNil(try manager.exchangeRefreshToken(refreshToken: first.refreshToken, clientId: "test"))
        XCTAssertNil(try manager.exchangeCode(code: pending, clientId: "test", redirectUri: "https://example.com/callback", codeVerifier: testVerifier))
    }

    func testCodeIsBoundToClientCallbackAndVerifierAndIsSingleUse() throws {
        let manager = isolatedOAuth()
        for (client, redirect, verifier) in [("other", "https://example.com/callback", testVerifier), ("test", "https://evil.example/callback", testVerifier), ("test", "https://example.com/callback", String(repeating: "b", count: 43))] {
            XCTAssertNil(try manager.exchangeCode(code: try code(manager), clientId: client, redirectUri: redirect, codeVerifier: verifier))
        }
        let pending = try code(manager)
        let result = try XCTUnwrap(manager.exchangeCode(code: pending, clientId: "test", redirectUri: "https://example.com/callback", codeVerifier: testVerifier))
        XCTAssertNil(try manager.exchangeCode(code: pending, clientId: "test", redirectUri: "https://example.com/callback", codeVerifier: testVerifier))
        XCTAssertNil(try manager.exchangeRefreshToken(refreshToken: result.refreshToken, clientId: "other"))
        XCTAssertNotNil(try manager.exchangeRefreshToken(refreshToken: result.refreshToken, clientId: "test"))
        XCTAssertFalse(manager.validateBearer(result.refreshToken))
        XCTAssertFalse(manager.validateBearer(result.token + "tampered"))
    }

    func testOnlyS256AndKnownScopeAreAccepted() {
        let manager = isolatedOAuth()
        for (challenge, method) in [(nil, nil), (testVerifier, "plain"), ("", "S256"), ("short", "S256")] as [(String?, String?)] {
            XCTAssertNil(manager.issueAuthorizationCode(clientId: "test", redirectUri: "https://example.com/callback", scope: "mcp:tools", sessionName: nil, codeChallenge: challenge, codeChallengeMethod: method))
        }
        XCTAssertNil(manager.issueAuthorizationCode(clientId: "test", redirectUri: "https://example.com/callback", scope: "read-only", sessionName: nil, codeChallenge: testChallenge, codeChallengeMethod: "S256"))
    }

    func testRevocationSurvivesRestartAndReauthorization() throws {
        var state = OAuthState(signingKey: OAuthState.freshKey(), grants: [:])
        func makeManager() -> OAuthManager {
            OAuthManager(load: { state }, save: { state = $0 })
        }
        let manager = makeManager()
        let first = try authorize(manager)
        let reloaded = makeManager()
        try reloaded.prepare()
        XCTAssertTrue(reloaded.validateBearer(first.token))
        try manager.revokeSession(XCTUnwrap(manager.listSessions().first).id)
        let restarted = makeManager()
        _ = try authorize(restarted)
        XCTAssertFalse(restarted.validateBearer(first.token))
        let reloadedAgain = makeManager()
        try reloadedAgain.prepare()
        XCTAssertFalse(reloadedAgain.validateBearer(first.token))
    }

    func testRefreshRotationAndReplayAcrossRestarts() throws {
        var saved = OAuthState(signingKey: OAuthState.freshKey(), grants: [:])
        func manager() -> OAuthManager {
            OAuthManager(load: { saved }, save: { saved = $0 })
        }
        let initial = manager()
        let first = try authorize(initial)
        let grant = try XCTUnwrap(initial.listSessions().first)
        let other = try authorize(initial)
        let rotated = try XCTUnwrap(initial.exchangeRefreshToken(refreshToken: first.refreshToken, clientId: "test"))
        XCTAssertNotEqual(first.refreshToken, rotated.refreshToken)
        try initial.renameSession(grant.id, sessionName: "Laptop")
        let restarted = manager()
        try restarted.prepare()
        let renamed = try XCTUnwrap(restarted.listSessions().first { $0.id == grant.id })
        XCTAssertEqual(renamed.sessionName, "Laptop")
        XCTAssertEqual(renamed.expiresAt, grant.expiresAt)
        let next = try XCTUnwrap(restarted.exchangeRefreshToken(refreshToken: rotated.refreshToken, clientId: "test"))
        XCTAssertNil(try restarted.exchangeRefreshToken(refreshToken: first.refreshToken, clientId: "wrong-client"))
        XCTAssertTrue(restarted.validateBearer(next.token))
        XCTAssertNil(try restarted.exchangeRefreshToken(refreshToken: first.refreshToken, clientId: "test"))
        let afterReplay = manager()
        try afterReplay.prepare()
        XCTAssertFalse(afterReplay.validateBearer(next.token))
        XCTAssertNil(try afterReplay.exchangeRefreshToken(refreshToken: next.refreshToken, clientId: "test"))
        XCTAssertTrue(afterReplay.validateBearer(other.token))
    }

    func testFailedWritesCanBeRetriedWithoutIssuingOrRestoringAccess() throws {
        var saved = OAuthState(signingKey: OAuthState.freshKey(), grants: [:])
        var locked = true
        let manager = OAuthManager(load: { saved }, save: {
            if locked { throw OAuthStorageError.keychain(errSecInteractionNotAllowed) }
            saved = $0
        })
        let pending = try code(manager)
        func exchange() throws -> OAuthTokens? {
            try manager.exchangeCode(code: pending, clientId: "test", redirectUri: "https://example.com/callback", codeVerifier: testVerifier)
        }
        XCTAssertThrowsError(try exchange())
        XCTAssertTrue(saved.grants.isEmpty)
        locked = false
        let first = try XCTUnwrap(exchange())
        let id = try XCTUnwrap(manager.listSessions().first).id
        locked = true
        XCTAssertThrowsError(try manager.exchangeRefreshToken(refreshToken: first.refreshToken, clientId: "test"))
        locked = false
        let rotated = try XCTUnwrap(manager.exchangeRefreshToken(refreshToken: first.refreshToken, clientId: "test"))
        locked = true
        XCTAssertThrowsError(try manager.revokeSession(id))
        XCTAssertFalse(manager.validateBearer(rotated.token))
        XCTAssertThrowsError(try manager.exchangeRefreshToken(refreshToken: rotated.refreshToken, clientId: "test"))
        locked = false
        try manager.revokeSession(id)
        XCTAssertTrue(saved.grants.isEmpty)
        let oldKey = saved.signingKey
        _ = try authorize(manager)
        locked = true
        XCTAssertThrowsError(try manager.revokeAllRefreshTokens())
        locked = false
        try manager.prepare()
        XCTAssertNotEqual(saved.signingKey, oldKey)
        XCTAssertTrue(saved.grants.isEmpty)
    }

    func testLegacyMigrationPreservesGrantAndChecksKeychainBeforeDeletingFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var source = OAuthState(signingKey: OAuthState.freshKey(), grants: [:])
        let manager = OAuthManager(load: { source }, save: { source = $0 })
        let tokens = try authorize(manager)
        let grant = try XCTUnwrap(manager.listSessions().first)
        let row: [String: Any] = ["token": tokens.refreshToken, "grantId": grant.id, "scope": grant.scope,
                                  "clientId": grant.clientId, "expiresAt": grant.expiresAt.timeIntervalSince1970]
        let file = directory.appendingPathComponent("refresh_tokens.json")
        try JSONSerialization.data(withJSONObject: [row]).write(to: file)
        func read(_ account: String) -> Data? { account == "oauth_signing_key" ? source.signingKey : nil }
        let failure = OAuthStorageError.keychain(errSecInteractionNotAllowed)
        XCTAssertThrowsError(try OAuthStateStore.load(read: { _ in throw failure }, save: { _ in XCTFail() }, legacyDirectory: directory))
        XCTAssertThrowsError(try OAuthStateStore.load(read: read, save: { _ in throw failure }, legacyDirectory: directory))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        let state = try OAuthStateStore.load(read: read, save: { _ in }, legacyDirectory: directory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        let migrated = OAuthManager(load: { state }, save: { _ in })
        XCTAssertNotNil(try migrated.exchangeRefreshToken(refreshToken: tokens.refreshToken, clientId: "test"))
    }

    func testRedirectSchemes() {
        for url in ["https://example.com/callback", "http://127.0.0.1:8080/callback", "http://[::1]:8080/callback", "com.example.app:/callback"] {
            XCTAssertTrue(OAuthPolicy.validRedirect(url), url)
        }
        for url in ["javascript:alert(1)", "data:text/html,hi", "file:///etc/passwd", "http://example.com/callback", "https://user:pass@example.com/callback", "https://example.com/callback#fragment", "/relative"] {
            XCTAssertFalse(OAuthPolicy.validRedirect(url), url)
        }
    }
}
