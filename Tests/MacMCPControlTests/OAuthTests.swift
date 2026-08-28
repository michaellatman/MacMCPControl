import XCTest
import CryptoKit
@testable import MacMCPControl

func isolatedOAuth() -> OAuthManager {
    OAuthManager(signingKey: SymmetricKey(size: .bits256), refreshTokens: [:], revokedClientIds: [],
                 saveTokens: { _ in }, saveRevokedClients: { _ in }, rotateKey: { SymmetricKey(size: .bits256) })
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
        manager.revokeRefreshToken(first.refreshToken)
        XCTAssertFalse(manager.validateBearer(first.token))
        let second = try authorize(manager)
        XCTAssertTrue(manager.validateBearer(second.token))
        XCTAssertFalse(manager.validateBearer(first.token))
        XCTAssertNil(manager.introspect(token: first.token))
        XCTAssertNil(manager.exchangeRefreshToken(refreshToken: first.refreshToken, clientId: "test"))
    }

    func testRevokeAllInvalidatesCodesAndTokens() throws {
        let manager = isolatedOAuth()
        let first = try authorize(manager)
        let pending = try code(manager)
        manager.revokeAllRefreshTokens()
        XCTAssertFalse(manager.validateBearer(first.token))
        XCTAssertNil(manager.exchangeRefreshToken(refreshToken: first.refreshToken, clientId: "test"))
        XCTAssertNil(manager.exchangeCode(code: pending, clientId: "test", redirectUri: "https://example.com/callback", codeVerifier: testVerifier))
    }

    func testCodeIsBoundToClientCallbackAndVerifierAndIsSingleUse() throws {
        let manager = isolatedOAuth()
        for (client, redirect, verifier) in [("other", "https://example.com/callback", testVerifier), ("test", "https://evil.example/callback", testVerifier), ("test", "https://example.com/callback", String(repeating: "b", count: 43))] {
            XCTAssertNil(manager.exchangeCode(code: try code(manager), clientId: client, redirectUri: redirect, codeVerifier: verifier))
        }
        let pending = try code(manager)
        let result = try XCTUnwrap(manager.exchangeCode(code: pending, clientId: "test", redirectUri: "https://example.com/callback", codeVerifier: testVerifier))
        XCTAssertNil(manager.exchangeCode(code: pending, clientId: "test", redirectUri: "https://example.com/callback", codeVerifier: testVerifier))
        XCTAssertNil(manager.exchangeRefreshToken(refreshToken: result.refreshToken, clientId: "other"))
        XCTAssertNotNil(manager.exchangeRefreshToken(refreshToken: result.refreshToken, clientId: "test"))
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
        let key = SymmetricKey(size: .bits256)
        var tokens: [String: OAuthTokenRecord] = [:]
        var revoked: Set<String> = []
        func makeManager() -> OAuthManager {
            OAuthManager(signingKey: key, refreshTokens: tokens, revokedClientIds: revoked,
                         saveTokens: { tokens = $0 }, saveRevokedClients: { revoked = $0 }, rotateKey: { SymmetricKey(size: .bits256) })
        }
        let manager = makeManager()
        let first = try authorize(manager)
        XCTAssertTrue(makeManager().validateBearer(first.token))
        manager.revokeRefreshToken(first.refreshToken)
        let restarted = makeManager()
        _ = try authorize(restarted)
        XCTAssertFalse(restarted.validateBearer(first.token))
        XCTAssertFalse(makeManager().validateBearer(first.token))
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
