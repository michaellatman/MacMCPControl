import Foundation
import CryptoKit
import Security

struct OAuthCodeRecord {
    let clientId: String
    let redirectUri: String
    let scope: String
    let expiresAt: Date
    let codeChallenge: String?
    let codeChallengeMethod: String?
    let sessionName: String?
}

struct OAuthTokenRecord {
    let clientId: String
    let scope: String
    let expiresAt: Date
    var sessionName: String?
    var lastUsedAt: Date?
}

struct OAuthRefreshTokenInfo {
    let token: String
    let clientId: String
    let scope: String
    let expiresAt: Date
    let sessionName: String?
    let lastUsedAt: Date?
}

final class OAuthManager {
    private var codes: [String: OAuthCodeRecord] = [:]
    private var refreshTokens: [String: OAuthTokenRecord] = [:]
    private var revokedClientIds: Set<String> = []
    private var lastUsedSaveFloorByClientId: [String: Date] = [:]
    private var signingKey: SymmetricKey
    private let tokenQueue = DispatchQueue(label: "mac.mcp.oauth.tokens")

    private let codeTtl: TimeInterval = 5 * 60
    private let tokenTtl: TimeInterval = 60 * 60
    private let refreshTokenTtl: TimeInterval = 30 * 24 * 60 * 60

    init() {
        signingKey = OAuthKeyStore.loadOrCreateKey()
        refreshTokens = OAuthTokenStore.load()
        revokedClientIds = RevokedClientStore.load()
    }

    // Must be called while holding tokenQueue (i.e. from tokenQueue.sync).
    @discardableResult
    private func pruneRefreshTokensLocked(now: Date = Date()) -> Bool {
        let beforeCount = refreshTokens.count
        refreshTokens = refreshTokens.filter { token, record in
            record.expiresAt >= now && !revokedClientIds.contains(record.clientId)
        }
        if refreshTokens.count != beforeCount {
            OAuthTokenStore.save(refreshTokens)
            return true
        }
        return false
    }

    func issueAuthorizationCode(
        clientId: String,
        redirectUri: String,
        scope: String,
        sessionName: String?,
        codeChallenge: String?,
        codeChallengeMethod: String?
    ) -> String {
        return tokenQueue.sync {
            let code = "code_\(UUID().uuidString)"
            let record = OAuthCodeRecord(
                clientId: clientId,
                redirectUri: redirectUri,
                scope: scope,
                expiresAt: Date().addingTimeInterval(codeTtl),
                codeChallenge: codeChallenge,
                codeChallengeMethod: codeChallengeMethod,
                sessionName: sessionName
            )
            codes[code] = record
            return code
        }
    }

    func exchangeCode(
        code: String,
        clientId: String,
        redirectUri: String,
        codeVerifier: String?
    ) -> (token: String, refreshToken: String, expiresIn: Int, scope: String)? {
        return tokenQueue.sync {
            guard let record = codes[code] else {
                return nil
            }

            codes.removeValue(forKey: code)

            if record.clientId != clientId || record.redirectUri != redirectUri || record.expiresAt < Date() {
                return nil
            }

            if let challenge = record.codeChallenge {
                guard let verifier = codeVerifier else {
                    return nil
                }
                let method = record.codeChallengeMethod ?? "plain"
                if !verifyCodeChallenge(challenge: challenge, verifier: verifier, method: method) {
                    return nil
                }
            }

            // Remove from revoked list since they're reauthorizing
            if revokedClientIds.contains(clientId) {
                revokedClientIds.remove(clientId)
                RevokedClientStore.save(revokedClientIds)
            }

            let token = issueAccessToken(clientId: clientId, scope: record.scope)
            let refreshToken = issueRefreshToken(clientId: clientId, scope: record.scope, sessionName: record.sessionName)
            return (token, refreshToken, Int(tokenTtl), record.scope)
        }
    }

    func exchangeRefreshToken(
        refreshToken: String,
        clientId: String
    ) -> (token: String, expiresIn: Int, scope: String)? {
        return tokenQueue.sync {
            // Keep storage consistent and ensure revoked clients can't mint new access tokens.
            _ = pruneRefreshTokensLocked()

            guard let record = decodeToken(refreshToken, expectedKind: "refresh", key: signingKey) else {
                return nil
            }

            if revokedClientIds.contains(record.clientId) || revokedClientIds.contains(clientId) {
                return nil
            }

            // This is a concrete "use" of the session.
            touchClientLocked(record.clientId, now: Date())

            guard let stored = refreshTokens[refreshToken] else {
                return nil
            }

            if stored.clientId != clientId || stored.scope != record.scope {
                return nil
            }

            if record.expiresAt < Date() {
                refreshTokens.removeValue(forKey: refreshToken)
                OAuthTokenStore.save(refreshTokens)
                return nil
            }

            let token = issueAccessToken(clientId: record.clientId, scope: record.scope)
            return (token, Int(tokenTtl), record.scope)
        }
    }

    func introspect(token: String) -> OAuthTokenRecord? {
        return tokenQueue.sync {
            guard let record = decodeToken(token, expectedKind: "access", key: signingKey) else {
                return nil
            }
            if record.expiresAt < Date() {
                return nil
            }
            if revokedClientIds.contains(record.clientId) {
                return nil
            }
            return record
        }
    }

    func validateBearer(_ token: String) -> Bool {
        return tokenQueue.sync {
            guard let record = decodeToken(token, expectedKind: "access", key: signingKey) else {
                return false
            }
            if record.expiresAt < Date() {
                return false
            }
            guard !revokedClientIds.contains(record.clientId) else {
                return false
            }
            touchClientLocked(record.clientId, now: Date())
            return true
        }
    }

    func authorizedSessionCount() -> Int {
        return tokenQueue.sync {
            _ = pruneRefreshTokensLocked()
            return refreshTokens.count
        }
    }

    func listRefreshTokens() -> [OAuthRefreshTokenInfo] {
        return tokenQueue.sync {
            _ = pruneRefreshTokensLocked()
            let infos = refreshTokens.map { token, record in
                OAuthRefreshTokenInfo(
                    token: token,
                    clientId: record.clientId,
                    scope: record.scope,
                    expiresAt: record.expiresAt,
                    sessionName: record.sessionName,
                    lastUsedAt: record.lastUsedAt
                )
            }
            return infos.sorted { $0.expiresAt < $1.expiresAt }
        }
    }

    func renameRefreshToken(_ token: String, sessionName: String?) {
        tokenQueue.sync {
            guard var record = refreshTokens[token] else {
                return
            }
            let trimmed = sessionName?.trimmingCharacters(in: .whitespacesAndNewlines)
            record.sessionName = (trimmed?.isEmpty == false) ? trimmed : nil
            refreshTokens[token] = record
            OAuthTokenStore.save(refreshTokens)
        }
    }

    func revokeRefreshToken(_ token: String) {
        tokenQueue.sync {
            guard let record = refreshTokens[token] else {
                refreshTokens.removeValue(forKey: token)
                OAuthTokenStore.save(refreshTokens)
                return
            }

            // Revocation is per-client (used to invalidate existing access tokens), so remove all refresh tokens
            // for that client and prevent refresh-token exchanges until they reauthorize.
            revokedClientIds.insert(record.clientId)
            RevokedClientStore.save(revokedClientIds)
            lastUsedSaveFloorByClientId.removeValue(forKey: record.clientId)
            refreshTokens = refreshTokens.filter { _, value in
                value.clientId != record.clientId
            }
            OAuthTokenStore.save(refreshTokens)
        }
    }

    func revokeAllRefreshTokens() {
        tokenQueue.sync {
            // Regenerate signing key to invalidate ALL existing tokens immediately
            signingKey = OAuthKeyStore.regenerateKey()
            refreshTokens.removeAll()
            revokedClientIds.removeAll()
            lastUsedSaveFloorByClientId.removeAll()
            OAuthTokenStore.save(refreshTokens)
            RevokedClientStore.save(revokedClientIds)
        }
    }

    // Must be called while holding tokenQueue.
    private func touchClientLocked(_ clientId: String, now: Date) {
        // Update all stored refresh tokens for this client (Sessions UI reads from refreshTokens).
        let tokensForClient = refreshTokens
            .filter { _, record in record.clientId == clientId }
            .map(\.key)

        guard !tokensForClient.isEmpty else {
            return
        }

        for token in tokensForClient {
            guard var record = refreshTokens[token] else { continue }
            record.lastUsedAt = now
            refreshTokens[token] = record
        }

        // Avoid writing to disk on every tool call.
        if let floor = lastUsedSaveFloorByClientId[clientId], now.timeIntervalSince(floor) < 30 {
            return
        }
        lastUsedSaveFloorByClientId[clientId] = now
        OAuthTokenStore.save(refreshTokens)
    }

    private func issueAccessToken(clientId: String, scope: String) -> String {
        let expiresAt = Date().addingTimeInterval(tokenTtl)
        return signToken(
            kind: "access",
            clientId: clientId,
            scope: scope,
            expiresAt: expiresAt,
            key: signingKey
        )
    }

    private func issueRefreshToken(clientId: String, scope: String, sessionName: String?) -> String {
        let expiresAt = Date().addingTimeInterval(refreshTokenTtl)
        let token = signToken(
            kind: "refresh",
            clientId: clientId,
            scope: scope,
            expiresAt: expiresAt,
            key: signingKey
        )
        refreshTokens[token] = OAuthTokenRecord(
            clientId: clientId,
            scope: scope,
            expiresAt: expiresAt,
            sessionName: sessionName,
            lastUsedAt: nil
        )
        OAuthTokenStore.save(refreshTokens)
        return token
    }

    private func signToken(kind: String, clientId: String, scope: String, expiresAt: Date, key: SymmetricKey) -> String {
        let header: [String: Any] = ["alg": "HS256", "typ": "JWT"]
        let issuedAt = Date()
        let payload: [String: Any] = [
            "kind": kind,
            "client_id": clientId,
            "scope": scope,
            "iat": Int(issuedAt.timeIntervalSince1970),
            "jti": UUID().uuidString,
            "exp": Int(expiresAt.timeIntervalSince1970)
        ]

        guard
            let headerData = try? JSONSerialization.data(withJSONObject: header, options: []),
            let payloadData = try? JSONSerialization.data(withJSONObject: payload, options: [])
        else {
            return ""
        }

        let headerPart = base64UrlEncode(headerData)
        let payloadPart = base64UrlEncode(payloadData)
        let signingInput = "\(headerPart).\(payloadPart)"
        let signature = HMAC<SHA256>.authenticationCode(for: Data(signingInput.utf8), using: key)
        let signaturePart = base64UrlEncode(Data(signature))
        return "\(signingInput).\(signaturePart)"
    }

    private func decodeToken(_ token: String, expectedKind: String, key: SymmetricKey) -> OAuthTokenRecord? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else {
            return nil
        }

        let signingInput = "\(parts[0]).\(parts[1])"
        guard let signature = base64UrlDecode(String(parts[2])) else {
            return nil
        }

        let expectedSignature = HMAC<SHA256>.authenticationCode(for: Data(signingInput.utf8), using: key)
        guard Data(expectedSignature) == signature else {
            return nil
        }

        guard let payloadData = base64UrlDecode(String(parts[1])) else {
            return nil
        }

        guard
            let payload = try? JSONSerialization.jsonObject(with: payloadData, options: []),
            let payloadDict = payload as? [String: Any],
            let kind = payloadDict["kind"] as? String,
            let clientId = payloadDict["client_id"] as? String,
            let scope = payloadDict["scope"] as? String,
            let exp = payloadDict["exp"] as? Int
        else {
            return nil
        }

        guard kind == expectedKind else {
            return nil
        }

        let expiresAt = Date(timeIntervalSince1970: TimeInterval(exp))
        return OAuthTokenRecord(clientId: clientId, scope: scope, expiresAt: expiresAt)
    }

    private func base64UrlEncode(_ data: Data) -> String {
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func base64UrlDecode(_ value: String) -> Data? {
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        let padding = 4 - (base64.count % 4)
        if padding < 4 {
            base64.append(String(repeating: "=", count: padding))
        }

        return Data(base64Encoded: base64)
    }

    private func verifyCodeChallenge(challenge: String, verifier: String, method: String) -> Bool {
        switch method {
        case "S256":
            return sha256Base64Url(verifier) == challenge
        case "plain":
            return verifier == challenge
        default:
            return false
        }
    }

    private func sha256Base64Url(_ input: String) -> String {
        let data = Data(input.utf8)
        let digest = SHA256.hash(data: data)
        let encoded = Data(digest).base64EncodedString()
        return encoded
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

enum OAuthTokenStore {
    private struct PersistedToken: Codable {
        let token: String
        let clientId: String
        let scope: String
        let expiresAt: TimeInterval
        let sessionName: String?
        let lastUsedAt: TimeInterval?
    }

    static func load() -> [String: OAuthTokenRecord] {
        guard let data = try? Data(contentsOf: storeUrl()) else {
            return [:]
        }
        guard let decoded = try? JSONDecoder().decode([PersistedToken].self, from: data) else {
            return [:]
        }
        var tokens: [String: OAuthTokenRecord] = [:]
        for entry in decoded {
            tokens[entry.token] = OAuthTokenRecord(
                clientId: entry.clientId,
                scope: entry.scope,
                expiresAt: Date(timeIntervalSince1970: entry.expiresAt),
                sessionName: entry.sessionName,
                lastUsedAt: entry.lastUsedAt.map { Date(timeIntervalSince1970: $0) }
            )
        }
        return tokens
    }

    static func save(_ tokens: [String: OAuthTokenRecord]) {
        let payload = tokens.map { token, record in
            PersistedToken(
                token: token,
                clientId: record.clientId,
                scope: record.scope,
                expiresAt: record.expiresAt.timeIntervalSince1970,
                sessionName: record.sessionName,
                lastUsedAt: record.lastUsedAt?.timeIntervalSince1970
            )
        }
        guard let data = try? JSONEncoder().encode(payload) else {
            return
        }
        createDirectoryIfNeeded()
        try? data.write(to: storeUrl(), options: [.atomic])
    }

    private static func storeUrl() -> URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return root
            .appendingPathComponent("MacMCPControl", isDirectory: true)
            .appendingPathComponent("refresh_tokens.json")
    }

    private static func createDirectoryIfNeeded() {
        let url = storeUrl().deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}

enum OAuthKeyStore {
    static func loadOrCreateKey() -> SymmetricKey {
        let url = keyUrl()
        if let data = try? Data(contentsOf: url),
           let keyData = Data(base64Encoded: data) {
            return SymmetricKey(data: keyData)
        }

        return generateAndSaveKey()
    }

    static func regenerateKey() -> SymmetricKey {
        return generateAndSaveKey()
    }

    private static func generateAndSaveKey() -> SymmetricKey {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            let fallback = SymmetricKey(size: .bits256)
            return fallback
        }

        let keyData = Data(bytes)
        let encoded = Data(keyData.base64EncodedString().utf8)
        createKeyDirectoryIfNeeded()
        try? encoded.write(to: keyUrl(), options: [.atomic])
        return SymmetricKey(data: keyData)
    }

    private static func keyUrl() -> URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return root
            .appendingPathComponent("MacMCPControl", isDirectory: true)
            .appendingPathComponent("oauth_signing_key")
    }

    private static func createKeyDirectoryIfNeeded() {
        let url = keyUrl().deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}

enum RevokedClientStore {
    static func load() -> Set<String> {
        guard let data = try? Data(contentsOf: storeUrl()) else {
            return []
        }
        guard let decoded = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return Set(decoded)
    }

    static func save(_ clientIds: Set<String>) {
        let payload = Array(clientIds)
        guard let data = try? JSONEncoder().encode(payload) else {
            return
        }
        createDirectoryIfNeeded()
        try? data.write(to: storeUrl(), options: [.atomic])
    }

    private static func storeUrl() -> URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return root
            .appendingPathComponent("MacMCPControl", isDirectory: true)
            .appendingPathComponent("revoked_clients.json")
    }

    private static func createDirectoryIfNeeded() {
        let url = storeUrl().deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}
