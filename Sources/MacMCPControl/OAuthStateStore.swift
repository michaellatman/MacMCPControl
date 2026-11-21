import CryptoKit
import Foundation
import Security

struct OAuthGrant: Codable, Identifiable {
    let id: String
    let clientId: String
    let scope: String
    let expiresAt: Date
    var sessionName: String?
    var lastUsedAt: Date?
    var refreshDigest: Data

    static func digest(_ token: String) -> Data {
        Data(SHA256.hash(data: Data(token.utf8)))
    }
}

struct OAuthState: Codable {
    var signingKey: Data
    var grants: [String: OAuthGrant]

    static func freshKey() -> Data {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    }
}

enum OAuthStorageError: LocalizedError {
    case keychain(OSStatus)
    case invalidData

    var errorDescription: String? {
        switch self {
        case .keychain(let status):
            return "Keychain access failed (\(status)). Unlock your login Keychain and retry."
        case .invalidData:
            return "The saved OAuth credentials could not be read."
        }
    }
}

enum OAuthStateStore {
    // Keep the original account so a superseded refresh-token list cannot be loaded again.
    private static let account = "refresh_tokens"

    static func load() throws -> OAuthState {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacMCPControl")
        return try load(read: KeychainStore.load, save: save, legacyDirectory: directory)
    }

    static func load(read: (String) throws -> Data?, save: (OAuthState) throws -> Void,
                     legacyDirectory: URL) throws -> OAuthState {
        let files = ["refresh_tokens.json", "revoked_clients.json", "oauth_signing_key"]
        func removeLegacyFiles() throws {
            for name in files {
                do {
                    try FileManager.default.removeItem(at: legacyDirectory.appendingPathComponent(name))
                } catch CocoaError.fileNoSuchFile {
                    continue
                }
            }
        }
        func legacyFile(_ name: String) throws -> Data? {
            do {
                return try Data(contentsOf: legacyDirectory.appendingPathComponent(name))
            } catch CocoaError.fileReadNoSuchFile {
                return nil
            }
        }
        let data = try read(account)
        if let data, let state = try? JSONDecoder().decode(OAuthState.self, from: data) {
            guard state.signingKey.count == 32 else { throw OAuthStorageError.invalidData }
            try removeLegacyFiles()
            return state
        }

        // Import the previous release's tokens and deny list before accepting any requests.
        let tokenData = try data ?? legacyFile("refresh_tokens.json")
        let tokens = try tokenData.map { try JSONDecoder().decode([LegacyToken].self, from: $0) } ?? []
        let deniedData = try read("revoked_clients") ?? legacyFile("revoked_clients.json")
        let denied = try deniedData.map { try JSONDecoder().decode(Set<String>.self, from: $0) } ?? []
        var key = try read("oauth_signing_key")
        if key == nil, let legacyKey = try legacyFile("oauth_signing_key") {
            guard let decoded = Data(base64Encoded: legacyKey) else { throw OAuthStorageError.invalidData }
            key = decoded
        }
        let signingKey = key ?? OAuthState.freshKey()
        guard signingKey.count == 32 else { throw OAuthStorageError.invalidData }
        var grants: [String: OAuthGrant] = [:]
        for token in tokens where !denied.contains(token.clientId) {
            let expiresAt = Date(timeIntervalSince1970: token.expiresAt)
            guard let id = token.grantId, expiresAt > Date(), key != nil else { continue }
            grants[id] = OAuthGrant(id: id, clientId: token.clientId, scope: token.scope,
                                    expiresAt: expiresAt, sessionName: token.sessionName,
                                    lastUsedAt: token.lastUsedAt.map(Date.init(timeIntervalSince1970:)),
                                    refreshDigest: OAuthGrant.digest(token.token))
        }
        let state = OAuthState(signingKey: signingKey, grants: grants)
        try save(state)
        try removeLegacyFiles()
        return state
    }

    static func save(_ state: OAuthState) throws {
        try KeychainStore.save(account, data: JSONEncoder().encode(state))
    }

    private struct LegacyToken: Decodable {
        let token: String
        let grantId: String?
        let clientId: String
        let scope: String
        let expiresAt: TimeInterval
        let sessionName: String?
        let lastUsedAt: TimeInterval?
    }
}

private enum KeychainStore {
    static func load(_ account: String) throws -> Data? {
        var query = query(for: account)
        query[kSecReturnData as String] = true
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw OAuthStorageError.keychain(status) }
        guard let data = item as? Data else { throw OAuthStorageError.invalidData }
        return data
    }

    static func save(_ account: String, data: Data) throws {
        var query = query(for: account)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(query as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw OAuthStorageError.keychain(status) }
    }

    private static func query(for account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "MacMCPControl",
         kSecAttrAccount as String: account]
    }
}
