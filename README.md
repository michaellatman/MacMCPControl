# Mac MCP Control

A native macOS menubar app that hosts a local MCP server and exposes computer-use tools over a public ngrok URL.

## Features

- Native macOS menubar app
- Local MCP server over HTTP (JSON response mode)
- OAuth demo flow (required for MCP requests)
- Localhost-only OAuth redirect URIs
- Optional ngrok tunnel for public access
- Supports computer use actions:
  - Mouse control (move, click, drag)
  - Keyboard input
  - Screenshots
  - Shell command execution
  - AppleScript execution

## Prerequisites

- macOS 13.0 or later
- Xcode Command Line Tools
- ngrok installed (optional, for public URL)

## Building

```bash
swift build
```

## Running

### Menubar Mode

```bash
.build/debug/MacMCPControl
```

## First Launch Setup

On first launch, the app will:

1) Walk you through granting Accessibility permissions
2) Require you to accept the Terms & Risk Acknowledgment

You must complete both steps before the MCP server starts.

## Configuration

Use the Settings menu option (⌘,) when running in menubar mode:

- **Device Name**: Name shown in status tool
- **MCP Port**: Local HTTP port (default 7519)
- **Enable ngrok tunnel**: Toggle public URL
- **Ngrok Token**: Optional authtoken for ngrok

The menubar shows the MCP URL and ngrok public URL (if enabled).

## MCP Endpoint

- Local: `http://localhost:<MCP Port>/mcp`
- Public (ngrok): `https://<ngrok-subdomain>.ngrok.app/mcp`

OAuth metadata:

- `/.well-known/oauth-authorization-server`
- `/.well-known/oauth-protected-resource`

OAuth redirect URI must be localhost (loopback only).

## Tools

- `computer`
- `open_computer_fullscreen`
- `local_computer_status`

## Troubleshooting

### ngrok not found

Install ngrok and ensure it is on your PATH.

### Permission Errors

macOS requires Accessibility permissions for mouse and keyboard control:

1. System Settings > Privacy & Security > Accessibility
2. Add **Mac MCP Control** to the list and enable it

## License

See `LICENSE`.
