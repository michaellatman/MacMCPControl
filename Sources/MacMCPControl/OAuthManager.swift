import Foundation
import CryptoKit

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
    let grantId: String
    let clientId: String
    let scope: String
    let expiresAt: Date
}

typealias OAuthTokens = (token: String, refreshToken: String, expiresIn: Int, scope: String)

final class OAuthManager {
    private var codes: [String: OAuthCodeRecord] = [:]
    private let tokenQueue = DispatchQueue(label: "mac.mcp.oauth.tokens")
    private let codeTtl: TimeInterval = 5 * 60
    private let tokenTtl: TimeInterval = 60 * 60
    private let refreshTokenTtl: TimeInterval = 30 * 24 * 60 * 60
    private let load: () throws -> OAuthState
    private let save: (OAuthState) throws -> Void
    private var state: OAuthState?
    private var unsavedRevocation = false

    init(load: @escaping () throws -> OAuthState = OAuthStateStore.load,
         save: @escaping (OAuthState) throws -> Void = OAuthStateStore.save) {
        self.load = load
        self.save = save
    }

    func prepare() throws {
        try tokenQueue.sync { _ = try currentState() }
    }

    // All state access is serialized by tokenQueue.
    private func currentState() throws -> OAuthState {
        if let state {
            if unsavedRevocation {
                try save(state)
                unsavedRevocation = false
            }
            return state
        }
        let loaded = try load()
        state = loaded
        return loaded
    }

    private func commit(_ next: OAuthState) throws {
        try save(next)
        state = next
    }

    // Deny access immediately even if the Keychain is locked. Retry the write
    // before issuing credentials or reporting a subsequent revocation as complete.
    private func commitRevocation(_ next: OAuthState) throws {
        state = next
        unsavedRevocation = true
        try save(next)
        unsavedRevocation = false
    }

    func issueAuthorizationCode(
        clientId: String,
        redirectUri: String,
        scope: String,
        sessionName: String?,
        codeChallenge: String?,
        codeChallengeMethod: String?
    ) -> String? {
        return tokenQueue.sync {
            guard OAuthPolicy.validChallenge(codeChallenge, method: codeChallengeMethod), scope == "mcp:tools" else { return nil }
            codes = codes.filter { $0.value.expiresAt >= Date() }
            guard codes.count < 64 else { return nil }
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

    func exchangeCode(code: String, clientId: String, redirectUri: String,
                      codeVerifier: String?) throws -> OAuthTokens? {
        try tokenQueue.sync {
            guard let record = codes[code], record.clientId == clientId,
                  record.redirectUri == redirectUri, record.expiresAt >= Date(),
                  let challenge = record.codeChallenge, let verifier = codeVerifier,
                  OAuthPolicy.validVerifier(verifier), record.codeChallengeMethod == "S256",
                  sha256Base64Url(verifier) == challenge else { return nil }
            let state = try currentState()
            let grant = OAuthGrant(id: UUID().uuidString, clientId: clientId, scope: record.scope,
                                   expiresAt: Date().addingTimeInterval(refreshTokenTtl),
                                   sessionName: record.sessionName, lastUsedAt: nil, refreshDigest: Data())
            let tokens = try issueTokens(for: grant, in: state)
            codes.removeValue(forKey: code)
            return tokens
        }
    }

    func exchangeRefreshToken(refreshToken: String, clientId: String) throws -> OAuthTokens? {
        try tokenQueue.sync {
            var state = try currentState()
            let key = SymmetricKey(data: state.signingKey)
            guard let record = decodeToken(refreshToken, expectedKind: "refresh", key: key),
                  record.clientId == clientId, record.expiresAt >= Date(),
                  var grant = state.grants[record.grantId],
                  grant.clientId == clientId, grant.scope == record.scope,
                  grant.expiresAt >= Date() else { return nil }
            guard grant.refreshDigest == OAuthGrant.digest(refreshToken) else {
                state.grants.removeValue(forKey: record.grantId)
                try commitRevocation(state)
                return nil
            }
            grant.lastUsedAt = Date()
            return try issueTokens(for: grant, in: state)
        }
    }

    private func issueTokens(for grant: OAuthGrant, in state: OAuthState) throws -> OAuthTokens {
        let key = SymmetricKey(data: state.signingKey)
        let refresh = try signToken(kind: "refresh", clientId: grant.clientId, scope: grant.scope,
                                    expiresAt: grant.expiresAt, key: key, grantId: grant.id)
        let access = try signToken(kind: "access", clientId: grant.clientId, scope: grant.scope,
                                   expiresAt: Date().addingTimeInterval(tokenTtl), key: key, grantId: grant.id)
        var next = state
        next.grants = next.grants.filter { $0.value.expiresAt >= Date() }
        var updated = grant
        updated.refreshDigest = OAuthGrant.digest(refresh)
        next.grants[grant.id] = updated
        try commit(next)
        return (access, refresh, Int(tokenTtl), grant.scope)
    }

    private func accessRecord(_ token: String) -> OAuthTokenRecord? {
        guard let state, let record = decodeToken(token, expectedKind: "access", key: SymmetricKey(data: state.signingKey)),
              record.expiresAt >= Date(), let grant = state.grants[record.grantId],
              grant.clientId == record.clientId, record.scope == "mcp:tools",
              grant.scope == record.scope, grant.expiresAt >= Date() else { return nil }
        return record
    }

    func introspect(token: String) -> OAuthTokenRecord? {
        tokenQueue.sync { accessRecord(token) }
    }

    func validateBearer(_ token: String) -> Bool {
        tokenQueue.sync {
            guard let record = accessRecord(token),
                  var state, var grant = state.grants[record.grantId] else { return false }
            let now = Date()
            if now.timeIntervalSince(grant.lastUsedAt ?? .distantPast) >= 30 {
                grant.lastUsedAt = now
                state.grants[grant.id] = grant
                do {
                    try commit(state)
                    unsavedRevocation = false
                } catch {
                    LogStore.shared.log("Could not save OAuth activity: \(error.localizedDescription)", level: .error)
                }
            }
            return true
        }
    }

    func authorizedSessionCount() -> Int {
        tokenQueue.sync {
            if unsavedRevocation {
                do {
                    _ = try currentState()
                } catch {
                    LogStore.shared.log("OAuth revocation is still unsaved: \(error.localizedDescription)", level: .error)
                }
            }
            return state?.grants.values.filter { $0.expiresAt >= Date() }.count ?? 0
        }
    }

    func listSessions() -> [OAuthGrant] {
        tokenQueue.sync {
            guard let state else { return [] }
            return state.grants.values.filter { $0.expiresAt >= Date() }.sorted { $0.expiresAt < $1.expiresAt }
        }
    }

    func renameSession(_ id: String, sessionName: String?) throws {
        try tokenQueue.sync {
            var state = try currentState()
            guard var grant = state.grants[id] else { return }
            grant.sessionName = sessionName?.trimmingCharacters(in: .whitespacesAndNewlines)
            if grant.sessionName?.isEmpty == true { grant.sessionName = nil }
            state.grants[id] = grant
            try commit(state)
        }
    }

    func revokeSession(_ id: String) throws {
        try tokenQueue.sync {
            var state = try currentState()
            guard let client = state.grants[id]?.clientId else { return }
            codes = codes.filter { $0.value.clientId != client }
            state.grants = state.grants.filter { $0.value.clientId != client }
            try commitRevocation(state)
        }
    }

    func revokeAllRefreshTokens() throws {
        try tokenQueue.sync {
            _ = try currentState()
            codes.removeAll()
            try commitRevocation(OAuthState(signingKey: OAuthState.freshKey(), grants: [:]))
        }
    }

    private func signToken(kind: String, clientId: String, scope: String, expiresAt: Date, key: SymmetricKey, grantId: String) throws -> String {
        let header: [String: Any] = ["alg": "HS256", "typ": "JWT"]
        let issuedAt = Date()
        let payload: [String: Any] = [
            "kind": kind,
            "grant_id": grantId,
            "client_id": clientId,
            "scope": scope,
            "iat": Int(issuedAt.timeIntervalSince1970),
            "jti": UUID().uuidString,
            "exp": Int(expiresAt.timeIntervalSince1970)
        ]

        let headerData = try JSONSerialization.data(withJSONObject: header)
        let payloadData = try JSONSerialization.data(withJSONObject: payload)

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

        guard HMAC<SHA256>.isValidAuthenticationCode(signature, authenticating: Data(signingInput.utf8), using: key) else {
            return nil
        }

        guard let payloadData = base64UrlDecode(String(parts[1])) else {
            return nil
        }

        guard
            let payload = try? JSONSerialization.jsonObject(with: payloadData, options: []),
            let payloadDict = payload as? [String: Any],
            let kind = payloadDict["kind"] as? String,
            let grantId = payloadDict["grant_id"] as? String,
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
        return OAuthTokenRecord(grantId: grantId, clientId: clientId, scope: scope, expiresAt: expiresAt)
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
