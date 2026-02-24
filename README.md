# HomeClaw

Control your Apple HomeKit smart home from AI assistants, the terminal, and automation tools.

HomeClaw exposes your HomeKit accessories through three interfaces: an **MCP server** for AI assistants like Claude, a **command-line tool** for scripting, and a **Claude Code plugin** for natural language control. It runs as a lightweight macOS menu bar app.

## Why HomeClaw?

Apple HomeKit has no public API, no CLI, and no way to integrate with AI assistants or automation pipelines. HomeClaw bridges that gap by running a signed macOS app that talks to HomeKit on your behalf and exposes a clean API surface.

- Ask Claude to "turn off all the lights" or "set the thermostat to 72"
- Script your smart home from the terminal
- Build automations that go beyond what the Home app offers
- Search and control devices by name, room, category, or semantic type

## Architecture

```
Claude / AI Assistant
    │
    ▼
homekit-mcp (SwiftUI menu bar app)
    ├── MCP HTTP server (port 9090, bearer token auth)
    ├── Menu bar UI + Settings window
    └── Unix socket client
          │
          ▼  /tmp/homekit-bridge.sock
          │
HomeKitHelper (Mac Catalyst, headless)
    ├── HMHomeManager (Apple HomeKit framework)
    └── Unix socket server
```

**Why two processes?** Apple's `HMHomeManager` requires a UIKit/Catalyst app with the HomeKit entitlement and a valid provisioning profile. Plain Swift CLI/SPM apps cannot access HomeKit. The main app handles MCP, UI, and the CLI; the helper handles HomeKit. They communicate over a Unix domain socket with JSON newline-delimited messages.

## Quick Start

### Prerequisites

- macOS 26 (Tahoe) or later
- Xcode 26+ with Swift 6.2
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`
- Node.js 20+ (for the MCP server wrapper)
- **Apple Developer account** with HomeKit capability enabled

### Setup

```bash
git clone https://github.com/omarshahine/HomeClaw.git
cd HomeClaw

# Configure your Apple Developer Team ID (one-time setup)
echo "HOMEKIT_TEAM_ID=YOUR_TEAM_ID" > .env.local

# Generate the HomeKitHelper Xcode project
cd Sources/HomeKitHelper && xcodegen && cd ../..

# Install Node.js dependencies
npm install

# Build everything and install
scripts/build.sh --release --install
```

Find your Team ID at [developer.apple.com/account](https://developer.apple.com/account) under Membership Details.

Launch from `/Applications` or: `open "/Applications/HomeKit Bridge.app"`

On first launch, grant HomeKit access when prompted. The menu bar icon appears -- click it to see your connected homes.

> **Note:** Apple restricts the HomeKit entitlement to development signing and App Store distribution. The `--notarize` flag produces a Developer ID build where HomeKit access is non-functional. For full HomeKit support, use the default development build.

## MCP Tools

The HTTP MCP server (port 9090, bearer token auth) exposes nine tools:

| Tool | Description |
|------|-------------|
| `list_homes` | List all HomeKit homes with room and accessory counts |
| `list_accessories` | List accessories with current state, filterable by home and room |
| `get_accessory` | Full details of a specific accessory including all services and characteristics |
| `control_accessory` | Set a characteristic value (power, brightness, temperature, lock state, etc.) |
| `list_rooms` | List all rooms and their accessories |
| `list_scenes` | List all scenes with type and action counts |
| `trigger_scene` | Execute a scene by name or UUID |
| `search_accessories` | Search by name, room, category, manufacturer, or aliases |
| `device_map` | LLM-optimized device map organized by home/zone/room with semantic types, aliases, and state summaries |

### Connecting an MCP Client

```bash
TOKEN=$(security find-generic-password -s com.shahine.homekit-bridge.auth -a mcp-bearer-token -w)
curl -X POST http://localhost:9090/mcp \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}'
```

## CLI

The `homekit-cli` command-line tool communicates directly over the Unix domain socket. All read commands support `--json` for machine-readable output.

```bash
# List accessories
homekit-cli list
homekit-cli list --room "Kitchen"
homekit-cli list --category thermostat

# Control devices
homekit-cli set "Living Room Light" brightness 75
homekit-cli set "Front Door Lock" lock_target_state locked
homekit-cli set "Thermostat" target_temperature 72

# Get detailed device info
homekit-cli get "Kitchen Light" --json

# Search across all homes
homekit-cli search "bedroom" --category lightbulb

# Scenes
homekit-cli scenes
homekit-cli trigger "Good Night"

# LLM-optimized device map
homekit-cli device-map

# Status and configuration
homekit-cli status
homekit-cli config --default-home "Main House"
homekit-cli config --filter-mode allowlist
homekit-cli config --list-devices

# Token management
homekit-cli token
homekit-cli token --rotate
```

## Claude Code Plugin

HomeClaw ships as a Claude Code plugin with a comprehensive HomeKit skill. Install it and Claude can control your smart home through natural language:

```bash
# Inside Claude Code
/plugin marketplace add ~/GitHub/HomeClaw
/plugin install homekit-bridge@homekit-bridge
```

Then just ask:

> "Turn on the kitchen lights and set them to 50% brightness"
> "Lock all the doors"
> "What's the thermostat set to?"
> "Run the movie time scene"
> "Which lights are on in the living room?"

The plugin includes a Node.js stdio MCP server that wraps `homekit-cli` for Claude Code integration.

## Supported Accessories

HomeClaw supports the full range of HomeKit accessory categories:

| Category | Controllable Characteristics |
|----------|------------------------------|
| **Lights** | power, brightness (0-100), hue (0-360), saturation (0-100), color temperature (140-500 mireds) |
| **Thermostats** | target temperature, HVAC mode (off/heat/cool/auto), target humidity |
| **Locks** | lock/unlock (accepts `locked`, `unlocked`, `0`, `1`) |
| **Doors & Garage Doors** | open/close, obstruction detection (read-only) |
| **Fans** | active, rotation speed, rotation direction, swing mode |
| **Window Coverings** | target position (0-100%) |
| **Switches & Outlets** | power on/off |
| **Sensors** | motion, contact, temperature, humidity, light level, battery (all read-only) |
| **Scenes** | trigger by name or UUID |

## Menu Bar App

The menu bar provides at-a-glance status and quick actions:

- **HomeKit connection status** -- shows home names (green), or error states with reasons
- **MCP server port** display
- **Copy auth token** to clipboard (one click, with confirmation feedback)
- **Restart helper** -- manual restart when things go wrong, with auto-restart tracking
- **Settings** link and **Quit**

## Settings

Four configuration tabs accessible from the menu bar:

| Tab | Features |
|-----|----------|
| **General** | Launch at Login toggle, app version display |
| **Server** | MCP port (editable), endpoint URL, bearer token reveal/copy/rotate |
| **HomeKit** | Connection status, home list with accessory and room counts, active home selector |
| **Devices** | Filter mode (all/allowlist), per-device toggles grouped by room, search, bulk select/deselect |

## Device Filtering

Control which accessories are exposed to MCP clients and the CLI:

- **All mode** (default) -- every accessory is available
- **Allowlist mode** -- only selected accessories are exposed
- Configure via the Devices settings tab (grouped by room with search) or CLI:

```bash
homekit-cli config --filter-mode allowlist
homekit-cli config --allow-accessories "uuid1,uuid2,uuid3"
homekit-cli config --list-devices  # shows allowed/filtered status
```

Config stored at `~/.config/homekit-bridge/config.json`.

## Authentication

- **Bearer token** stored in macOS Keychain (`com.shahine.homekit-bridge.auth`)
- Auto-generated on first launch
- Rotatable from Settings UI or CLI (`homekit-cli token --rotate`)
- Required for all MCP HTTP requests via `Authorization: Bearer <TOKEN>` header

## Helper Process Management

The HomeKitHelper runs as a background process with automatic lifecycle management:

- **Health monitoring** -- polls every 30 seconds with 5-second timeout
- **Auto-restart** -- up to 5 restarts per 15-minute window (budget resets automatically)
- **State reporting** -- menu bar shows: starting, connected (with home names), helper down, or HomeKit unavailable (with reason)
- **Manual restart** -- button appears in menu bar when helper is down, even after auto-restarts are exhausted
- **Diagnostics** -- clear error states for missing entitlements, TCC permissions, or iCloud issues

## Building

The build script requires your Apple Developer Team ID, provided via `.env.local`, `--team-id`, or the `HOMEKIT_TEAM_ID` environment variable:

```bash
# Full release build + install to /Applications
scripts/build.sh --release --install

# Override team ID on the command line
scripts/build.sh --release --install --team-id ABCDE12345

# Debug build (faster)
scripts/build.sh --debug

# Skip HomeKitHelper for fast SPM-only iteration
scripts/build.sh --debug --skip-helper

# Full build with Apple notarization (HomeKit won't work — see note below)
scripts/build.sh --notarize --install

# Clean build artifacts first
scripts/build.sh --clean
```

The build script handles: SPM compilation, Catalyst xcodebuild with automatic signing, app bundle assembly, code signing, optional notarization, and install.

### Version Bumping

All version sources are updated with a single command:

```bash
scripts/bump-version.sh 0.2.0
```

This updates `AppConfig.swift`, both Info.plists, all `package.json` files, the Claude plugin manifest, and the marketplace metadata.

## Project Structure

```
Sources/
  homekit-mcp/             Main app (SPM executable)
    App/                   SwiftUI entry, AppDelegate, HelperManager
    MCP/                   MCP server, HTTP handler, tool definitions
    HomeKit/               HomeKitClient (socket client to helper)
    Views/                 MenuBarView, SettingsView
    Shared/                AppConfig, KeychainManager, Logger
  homekit-cli/             CLI tool (SPM executable)
    Commands/              list, get, set, search, scenes, status, config, token
    SocketClient.swift     Direct socket communication
  HomeKitHelper/           Catalyst helper app (Xcode project via XcodeGen)
    HomeKitManager.swift   HMHomeManager wrapper (@MainActor)
    HelperSocketServer.swift   Unix socket server (GCD)
    CharacteristicMapper.swift HomeKit type mappings
    AccessoryModel.swift       JSON serialization models
Resources/                 Info.plist, entitlements, app icons
scripts/
  build.sh                 Build, sign, notarize, and install
  bump-version.sh          Update version across all 9 files
mcp-server/                Node.js stdio MCP server (wraps homekit-cli)
openclaw/                  Claude Code plugin (HomeClaw)
  skills/homekit/          HomeKit skill with full characteristic reference
```

## Debugging

```bash
# Check if helper is running and HomeKit is ready
echo '{"command":"status"}' | nc -U /tmp/homekit-bridge.sock

# Verify HomeKit entitlement on installed app
codesign -d --entitlements - "/Applications/HomeKit Bridge.app/Contents/Helpers/HomeKitHelper.app"

# View HomeKitHelper logs
log show --predicate 'process == "HomeKitHelper"' --last 10m --style compact

# Check TCC (privacy) permissions
sqlite3 ~/Library/Application\ Support/com.apple.TCC/TCC.db \
  "SELECT client, auth_value FROM access WHERE service = 'kTCCServiceWillow'"
```

| Symptom | Cause | Fix |
|---------|-------|-----|
| 0 homes, `ready: false` | Missing HomeKit entitlement | Verify with `codesign -d --entitlements` |
| All characteristic values `nil` | Accessory unreachable | Check device power and network |
| Helper won't start | TCC permission not granted | Re-grant in System Settings > Privacy |
| "HomeKit Unavailable" in menu | iCloud not signed in | Sign into iCloud with HomeKit data |

## Tech Stack

- **Swift 6** with strict concurrency (`@MainActor`, `actor` isolation)
- **SwiftUI** for menu bar and settings UI
- **Mac Catalyst** for HomeKit framework access
- **[MCP Swift SDK](https://github.com/modelcontextprotocol/swift-sdk)** for the HTTP MCP server
- **[Swift Argument Parser](https://github.com/apple/swift-argument-parser)** for CLI
- **Node.js** + **[@modelcontextprotocol/sdk](https://github.com/modelcontextprotocol/typescript-sdk)** for stdio MCP wrapper
- **XcodeGen** for HomeKitHelper project generation
- **GCD** + Unix domain sockets for IPC

## License

[MIT](LICENSE) -- Copyright (c) 2025 Omar Shahine
