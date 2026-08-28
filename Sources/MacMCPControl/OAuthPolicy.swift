import Foundation

struct RegisteredOAuthClient: Codable {
    let redirectUris: [String]
    let createdAt: Date
}

enum OAuthPolicy {
    static func validVerifier(_ value: String) -> Bool {
        (43...128).contains(value.utf8.count) && value.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [45, 46, 95, 126].contains($0)
        }
    }

    static func validChallenge(_ value: String?, method: String?) -> Bool {
        guard method == "S256", let value, value.utf8.count == 43 else { return false }
        return value.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [45, 95].contains($0)
        }
    }

    static func validRedirect(_ value: String) -> Bool {
        guard value.utf8.count <= 2048,
              !value.contains(where: { $0.isWhitespace || $0.isNewline }),
              let url = URLComponents(string: value), let scheme = url.scheme?.lowercased(),
              url.fragment == nil, url.user == nil, url.password == nil else { return false }
        if scheme == "https" { return url.host?.isEmpty == false }
        if scheme == "http" { return ["127.0.0.1", "[::1]", "localhost"].contains(url.host?.lowercased() ?? "") }
        // Native clients must use an app-specific reverse-DNS scheme, never javascript/data/file.
        return scheme.contains(".") && !url.path.isEmpty
    }
}
