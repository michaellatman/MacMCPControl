# Security Review Report

**Date:** 2026-01-31
**Reviewer:** Claude Code (Automated Security Review)
**Repository:** michaellatman/MacMCPControl
**Commit:** d28706d

---

## Executive Summary

Mac MCP Control is a macOS menubar application that hosts a local MCP (Model Context Protocol) server, enabling AI assistants to control the computer with user approval. This security review identified several findings across authentication, command execution, and configuration management.

The application implements OAuth 2.0 with PKCE for authorization, which is a solid security foundation. However, there are areas for improvement, particularly around the intentional shell command execution feature which represents the highest risk surface.

---

## Findings by Severity

### Critical

#### 1. Arbitrary Shell Command Execution (By Design)
**File:** `Sources/MacMCPControl/ActionExecutor.swift:469-502`
**Severity:** Critical
**Status:** Accepted Risk (Feature)

The `executeShell` function passes user-controlled commands directly to `/bin/zsh -c`:

```swift
let task = Process()
task.executableURL = URL(fileURLWithPath: "/bin/zsh")
task.arguments = ["-c", command]
```

**Risk:** Any authenticated client can execute arbitrary system commands with the user's full privileges.

**Recommendation:** This is an intentional feature of the MCP protocol. Mitigations in place:
- OAuth 2.0 authorization required before access
- User must explicitly approve each client in-app
- Consider adding optional command allowlists or sandboxing for high-security environments

---

### High

#### 2. PKCE "plain" Method Supported
**File:** `Sources/MacMCPControl/OAuthManager.swift:406-414`
**Severity:** High

The PKCE implementation supports the `plain` code challenge method:

```swift
case "plain":
    return verifier == challenge
```

**Risk:** The `plain` method provides no cryptographic protection against authorization code interception attacks, defeating the purpose of PKCE.

**Recommendation:** Remove support for `plain` method and only allow `S256`:
```swift
private func verifyCodeChallenge(challenge: String, verifier: String, method: String) -> Bool {
    guard method == "S256" else { return false }
    return sha256Base64Url(verifier) == challenge
}
```

#### 3. Timing Side-Channel in Token Validation
**File:** `Sources/MacMCPControl/OAuthManager.swift:359`
**Severity:** High

Token signature verification uses standard equality comparison:

```swift
guard Data(expectedSignature) == signature else {
    return nil
}
```

**Risk:** Variable-time comparison may leak information about valid signatures through timing analysis, potentially allowing signature forgery.

**Recommendation:** Use constant-time comparison:
```swift
import CryptoKit
guard Data(expectedSignature).withUnsafeBytes { expected in
    signature.withUnsafeBytes { actual in
        CryptoKit.insecureIsEqual(expected, actual)
    }
} else { return nil }
```

Or use a timing-safe comparison loop.

#### 4. OAuth Signing Key Stored in Plaintext File
**File:** `Sources/MacMCPControl/OAuthManager.swift:504-517`
**Severity:** High

The HMAC signing key is stored as base64 in `~/Library/Application Support/MacMCPControl/oauth_signing_key`:

```swift
try? encoded.write(to: keyUrl(), options: [.atomic])
```

**Risk:** Any process running as the user can read this key and forge valid tokens.

**Recommendation:** Store the signing key in the macOS Keychain instead of a file:
```swift
let query: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: "MacMCPControl",
    kSecAttrAccount as String: "oauth_signing_key",
    kSecValueData as String: keyData
]
SecItemAdd(query as CFDictionary, nil)
```

#### 5. Refresh Tokens Stored in Plaintext
**File:** `Sources/MacMCPControl/OAuthManager.swift:458-474`
**Severity:** High

Refresh tokens (including full JWT strings) are stored in plaintext JSON at `~/Library/Application Support/MacMCPControl/refresh_tokens.json`.

**Risk:** Token theft allows long-term impersonation (30-day validity).

**Recommendation:** Store tokens in macOS Keychain or encrypt at rest with a key from Keychain.

---

### Medium

#### 6. X-Forwarded Header Trust Without Validation
**File:** `Sources/MacMCPControl/McpServerManager.swift:1028-1038`
**Severity:** Medium

The server trusts `X-Forwarded-Host` and `X-Forwarded-Proto` headers for URL construction:

```swift
let hostHeader = headerValue(request, name: "x-forwarded-host") ?? headerValue(request, name: "host")
let scheme = headerValue(request, name: "x-forwarded-proto") ?? "http"
```

**Risk:** When not behind a trusted proxy (ngrok), these headers can be spoofed to manipulate OAuth redirects or metadata endpoints.

**Recommendation:** Only trust forwarded headers when a known proxy (ngrok) is active, or validate against expected patterns.

#### 7. No Rate Limiting on Authentication Endpoints
**File:** `Sources/MacMCPControl/McpServerManager.swift`
**Severity:** Medium

No rate limiting is implemented for:
- `/oauth/authorize` - Authorization requests
- `/oauth/token` - Token exchanges
- `/oauth/pending` - Polling endpoint

**Risk:** Allows brute-force attacks on confirmation codes (6-digit numeric), token guessing, or denial of service.

**Recommendation:** Implement per-IP rate limiting with exponential backoff:
- Max 10 auth requests per minute per IP
- Max 5 failed token exchanges before lockout
- Add CAPTCHA or progressive delays after failures

#### 8. Dynamic Client Registration Without Restrictions
**File:** `Sources/MacMCPControl/McpServerManager.swift:861-864`
**Severity:** Medium

Unknown client IDs are automatically registered:

```swift
if !registeredClients.contains(clientId) {
    LogStore.shared.log("OAuth token: unknown client_id \(clientId), allowing and registering dynamically")
    registeredClients.insert(clientId)
}
```

**Risk:** Any attacker can register arbitrary clients, potentially overwhelming the system or creating confusion.

**Recommendation:** Require clients to use `/oauth/register` endpoint first, or implement client approval workflow.

#### 9. Weak Redirect URI Validation
**File:** `Sources/MacMCPControl/McpServerManager.swift:1064-1073`
**Severity:** Medium

Redirect URIs only require a scheme to be valid:

```swift
private func isValidRedirectUri(_ redirectUri: String) -> Bool {
    guard let url = URL(string: redirectUri) else { return false }
    guard let scheme = url.scheme, !scheme.isEmpty else { return false }
    return true
}
```

**Risk:** Open redirect vulnerability - attackers can redirect tokens to malicious servers.

**Mitigation:** The approval UI shows the redirect URI. Users must verify manually.

**Recommendation:** Consider maintaining an allowlist of approved redirect patterns, or at minimum warn on suspicious patterns (non-localhost, unusual schemes).

---

### Low

#### 10. Hardcoded Developer Signing Identity
**File:** `scripts/build.sh:59`
**Severity:** Low

```bash
codesign --force --deep --sign "Apple Development: Michael Latman (LS3WA9CYZ5)" "$APP_PATH"
```

**Risk:** Exposes developer identity; script only works for that developer.

**Recommendation:** Use environment variable or CI secret:
```bash
codesign --force --deep --sign "${APPLE_SIGNING_IDENTITY:-}" "$APP_PATH"
```

#### 11. Long Refresh Token Lifetime
**File:** `Sources/MacMCPControl/OAuthManager.swift:42`
**Severity:** Low

```swift
private let refreshTokenTtl: TimeInterval = 30 * 24 * 60 * 60  // 30 days
```

**Risk:** Stolen refresh tokens remain valid for extended period.

**Recommendation:** Consider shorter TTL (7 days) with automatic rotation on use.

#### 12. HTTP Server Without TLS (Localhost)
**File:** `Sources/MacMCPControl/McpServerManager.swift:162`
**Severity:** Low

The MCP server runs on plain HTTP:
```swift
try server.start(UInt16(settingsManager.mcpPort))
```

**Risk:** Local traffic could be intercepted by malware on the same machine.

**Mitigation:** Localhost-only binding limits exposure. Ngrok provides HTTPS for remote access.

**Recommendation:** Consider optional local TLS with self-signed certificate.

---

### Informational

#### 13. No Persistent Audit Logging
**Severity:** Informational

Security events are logged to an in-memory buffer (2000 entries) but not persisted to disk.

**Recommendation:** Consider writing security-relevant events (auth attempts, session revocations, shell commands) to a persistent log file.

#### 14. AGENTS.md File Corruption
**File:** `AGENTS.md:43`
**Severity:** Informational

The file contains corrupted content at the end:
```
*** End Patch"}"}}
```

**Recommendation:** Remove the corrupted line.

#### 15. No Automated Security Testing
**Severity:** Informational

No security-focused tests exist for OAuth flows, token validation, or input sanitization.

**Recommendation:** Add unit tests for:
- Token signature validation with invalid signatures
- PKCE challenge verification
- Redirect URI validation edge cases
- Session expiration and revocation

---

## Positive Security Practices

The codebase implements several security best practices:

1. **OAuth 2.0 with PKCE** - Modern authorization framework with code challenge support
2. **In-App Approval Only** - Browser cannot grant access; requires local app interaction
3. **Confirmation Codes** - Visual verification that approval matches the right request
4. **Session Revocation** - Ability to revoke individual sessions or regenerate all keys
5. **Permission Checks** - Validates Accessibility/Screen Recording permissions before actions
6. **Request Logging** - All HTTP requests logged with authorization headers redacted
7. **Secrets in CI** - Signing certificates stored as GitHub secrets, not in code
8. **Loopback Verification** - `isLocalRequest()` checks actual peer address, not headers
9. **HTML Escaping** - Proper escaping of user content in approval page
10. **Token Expiration** - Access tokens expire in 1 hour with refresh mechanism

---

## Recommendations Summary

| Priority | Action |
|----------|--------|
| High | Remove PKCE "plain" method support |
| High | Use constant-time comparison for signatures |
| High | Move signing key and tokens to Keychain |
| Medium | Add rate limiting to auth endpoints |
| Medium | Validate X-Forwarded headers only when behind proxy |
| Low | Parameterize signing identity in build script |
| Low | Add security-focused unit tests |

---

## Conclusion

Mac MCP Control implements a solid security architecture with OAuth 2.0 authorization and user approval workflows. The primary security consideration is that by design, it grants authenticated clients the ability to execute arbitrary shell commands with user privileges. This is inherent to the MCP computer-control use case.

The findings above represent opportunities to harden the implementation, particularly around cryptographic operations and credential storage. The high-priority items (PKCE plain method, timing attacks, key storage) should be addressed to align with security best practices.
