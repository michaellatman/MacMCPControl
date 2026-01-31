# Repository Guidelines

## Project Structure & Module Organization
- Swift Package Manager project. Entry points and app code live under `Sources/MacMCPControl/`.
- App resources (icons, ngrok binary, etc.) are in `Sources/MacMCPControl/Resources/`.
- Build artifacts and the local app bundle may appear at repo root as `MacMCPControl.app`.
- CI workflow lives in `.github/workflows/release.yml` (build, sign, and publish releases).
- No dedicated `Tests/` directory currently exists.

## Build, Test, and Development Commands
- `./scripts/build.sh` — builds a release binary and assembles/signs `MacMCPControl.app`.
- `./scripts/build-app.sh` — helper for assembling the app bundle (used by CI).
- `swift build -c release` — compiles the Swift package (used in CI).

Example:
```bash
./scripts/build.sh
open MacMCPControl.app
```

## Coding Style & Naming Conventions
- Language: Swift (Swift tools version set in `Package.swift`).
- Follow standard Swift formatting: 4-space indentation, PascalCase types, camelCase members.
- Keep SwiftUI views in `Sources/MacMCPControl/` with descriptive names (e.g., `ApprovalPromptView.swift`).
- No formatter or linter is configured; keep changes minimal and consistent with nearby code.

## Testing Guidelines
- No automated tests are currently configured.
- When adding tests, place them under a new `Tests/` directory and document how to run them.
- Prefer small, deterministic tests for security-sensitive code (OAuth, token handling).

## Commit & Pull Request Guidelines
- Commit messages are short, imperative, and descriptive (e.g., “Add releases link to README”).
- Keep commits focused; avoid mixing formatting-only edits with logic changes.
- PRs should include a clear summary, and screenshots for UI changes.

## Security & Configuration Notes
- Never commit certificates or private keys. Use GitHub secrets:
  - `APPLE_CERTIFICATE_KEY_BASE64`
  - `APPLE_CERTIFICATE_CER_BASE64`
  - `APPLE_SIGNING_IDENTITY`
- OAuth approval is in-app; browser pages should not grant access directly.
