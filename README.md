# Mac MCP Control

A native macOS menubar app that hosts a local MCP (Model Context Protocol) server, allowing AI assistants to control your Mac with your permission.

> **Disclaimer:** Remote control of your Mac carries inherent risks. By using this software, you accept full responsibility for actions taken with it. The author is not liable for damages, data loss, or security incidents.

## Features

- **Native SwiftUI menubar app** - Runs quietly in your menu bar
- **MCP server** - Exposes computer-use tools over HTTP
- **OAuth 2.0 authentication** - Secure authorization flow for clients
- **Session management** - View, revoke, and manage authorized sessions
- **Optional ngrok tunnel** - Expose your Mac to the internet with a public URL (ngrok bundled)
- **Permissions management** - Guided onboarding for Accessibility and Screen Recording permissions
- **Auto-save settings** - Changes apply immediately
- **Persistent sessions** - Sessions and revocations survive app restarts

### Computer Use Capabilities

- Mouse control (move, click, drag, scroll)
- Keyboard input (typing, key combinations)
- Screenshots (full screen capture)
- Shell command execution
- AppleScript via `osascript` (through shell commands)

## Requirements

- macOS 14.0 or later
- Xcode Command Line Tools (for building from source)

## Installation

### Releases

Download the latest build from the [Releases page](https://github.com/michaellatman/MacMCPControl/releases).

### Building from Source

```bash
# Clone the repository
git clone https://github.com/yourusername/mac-mcp-control.git
cd mac-mcp-control

# Build and create app bundle
./scripts/build.sh

# The app will be at ./MacMCPControl.app
open MacMCPControl.app
```

## First Launch

On first launch, the app guides you through:

1. **Accessibility Permission** - Required for mouse/keyboard control
   - Drag the app icon into System Settings > Privacy & Security > Accessibility

2. **Screen Recording Permission** - Required for screenshots
   - Drag the app icon into System Settings > Privacy & Security > Screen Recording
   - Click "Reopen App" after granting permission

3. **Terms Acceptance** - Acknowledge the risks of remote Mac control

After completing onboarding, the MCP server starts automatically.

## Configuration

Access Settings from the menubar icon (or Cmd+,):

### Settings Tab
- **Device Name** - Identifier for your Mac (defaults to computer name)
- **MCP Port** - Local server port (default: 7519)
- **Enable ngrok tunnel** - Toggle public URL access
- **Ngrok Token** - Optional auth token for ngrok features

### Sessions Tab
- View all authorized client sessions
- Revoke individual sessions or all sessions
- Sessions persist across app restarts

### Logs Tab
- View real-time server logs
- Copy logs for debugging
- Clear log history

## MCP Endpoints

### Local Access
```
http://localhost:7519/mcp
```

### Public Access (with ngrok enabled)
```
https://<subdomain>.ngrok.app/mcp
```

### OAuth Discovery
- `/.well-known/oauth-authorization-server`
- `/.well-known/oauth-protected-resource`

## Security

- OAuth 2.0 with PKCE for secure authorization
- Authorization approval happens in-app (browser pages cannot grant access)
- Session revocation immediately invalidates access
- Revoking all sessions regenerates signing keys
- All session data persisted securely

## Menu Bar

The menubar shows:
- Server status
- Local MCP URL
- Ngrok URL (when connected, with copy button)
- Authorized session count

## License

See `LICENSE`.
