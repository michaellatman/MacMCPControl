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
}

struct OAuthTokenRecord {
    let clientId: String
    let scope: String
    let expiresAt: Date
}

final class OAuthManager {
    private var codes: [String: OAuthCodeRecord] = [:]
    private var refreshTokens: [String: OAuthTokenRecord] = [:]
    private let signingKey: SymmetricKey
    private let tokenQueue = DispatchQueue(label: "mac.mcp.oauth.tokens")

    private let codeTtl: TimeInterval = 5 * 60
    private let tokenTtl: TimeInterval = 60 * 60
    private let refreshTokenTtl: TimeInterval = 30 * 24 * 60 * 60

    init() {
        signingKey = OAuthKeyStore.loadOrCreateKey()
        refreshTokens = OAuthTokenStore.load()
    }

    func issueAuthorizationCode(
        clientId: String,
        redirectUri: String,
        scope: String,
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
                codeChallengeMethod: codeChallengeMethod
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

            let token = issueAccessToken(clientId: clientId, scope: record.scope)
            let refreshToken = issueRefreshToken(clientId: clientId, scope: record.scope)
            return (token, refreshToken, Int(tokenTtl), record.scope)
        }
    }

    func exchangeRefreshToken(
        refreshToken: String,
        clientId: String
    ) -> (token: String, expiresIn: Int, scope: String)? {
        return tokenQueue.sync {
            guard let record = decodeToken(refreshToken, expectedKind: "refresh") else {
                return nil
            }

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
        return decodeToken(token, expectedKind: "access")
    }

    func validateBearer(_ token: String) -> Bool {
        return introspect(token: token) != nil
    }

    func authorizedSessionCount() -> Int {
        return tokenQueue.sync {
            let now = Date()
            refreshTokens = refreshTokens.filter { $0.value.expiresAt >= now }
            OAuthTokenStore.save(refreshTokens)
            return refreshTokens.count
        }
    }

    private func issueAccessToken(clientId: String, scope: String) -> String {
        let expiresAt = Date().addingTimeInterval(tokenTtl)
        return signToken(
            kind: "access",
            clientId: clientId,
            scope: scope,
            expiresAt: expiresAt
        )
    }

    private func issueRefreshToken(clientId: String, scope: String) -> String {
        let expiresAt = Date().addingTimeInterval(refreshTokenTtl)
        let token = signToken(
            kind: "refresh",
            clientId: clientId,
            scope: scope,
            expiresAt: expiresAt
        )
        refreshTokens[token] = OAuthTokenRecord(clientId: clientId, scope: scope, expiresAt: expiresAt)
        OAuthTokenStore.save(refreshTokens)
        return token
    }

    private func signToken(kind: String, clientId: String, scope: String, expiresAt: Date) -> String {
        let header: [String: Any] = ["alg": "HS256", "typ": "JWT"]
        let payload: [String: Any] = [
            "kind": kind,
            "client_id": clientId,
            "scope": scope,
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
        let signature = HMAC<SHA256>.authenticationCode(for: Data(signingInput.utf8), using: signingKey)
        let signaturePart = base64UrlEncode(Data(signature))
        return "\(signingInput).\(signaturePart)"
    }

    private func decodeToken(_ token: String, expectedKind: String) -> OAuthTokenRecord? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else {
            return nil
        }

        let signingInput = "\(parts[0]).\(parts[1])"
        guard let signature = base64UrlDecode(String(parts[2])) else {
            return nil
        }

        let expectedSignature = HMAC<SHA256>.authenticationCode(for: Data(signingInput.utf8), using: signingKey)
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
                expiresAt: Date(timeIntervalSince1970: entry.expiresAt)
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
                expiresAt: record.expiresAt.timeIntervalSince1970
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

        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            let fallback = SymmetricKey(size: .bits256)
            return fallback
        }

        let keyData = Data(bytes)
        let encoded = Data(keyData.base64EncodedString().utf8)
        createKeyDirectoryIfNeeded()
        try? encoded.write(to: url, options: [.atomic])
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
