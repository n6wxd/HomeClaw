# HomeKit Bridge

Control your HomeKit smart home from the command line, via MCP, or through Claude Code. Lights, locks, thermostats, scenes -- all accessible without opening the Home app.

## How It Works

HomeKit Bridge uses a split-process architecture to work around Apple's HomeKit framework requirements:

```
┌─────────────────────────────────────────────────────┐
│                   HomeKit Bridge.app                  │
│                                                       │
│  ┌──────────────┐    Unix Socket    ┌──────────────┐ │
│  │  homekit-mcp  │◄────────────────►│ HomeKitHelper │ │
│  │  (Swift/SPM)  │  /tmp/homekit-   │  (Catalyst)   │ │
│  │               │  bridge.sock     │               │ │
│  │  MCP Server   │                  │  HomeKit API  │ │
│  │  Menu Bar UI  │                  │  (Real HMHome │ │
│  │  Auth/Config  │                  │   Manager)    │ │
│  └──────┬───────┘                  └──────────────┘ │
│         │                                            │
└─────────┼────────────────────────────────────────────┘
          │ HTTP :9090
          │
    ┌─────┴──────┐         ┌──────────────┐
    │ MCP Client │         │  homekit-cli  │
    │ (Claude,   │         │  (Terminal)   │
    │  etc.)     │         │              │
    └────────────┘         └──────────────┘
                                  │
                           Unix Socket
                         /tmp/homekit-bridge.sock
```

**Why two processes?** Apple's HomeKit framework (`HMHomeManager`) requires a UIKit/Catalyst application with a valid provisioning profile and the HomeKit entitlement. A plain Swift command-line tool can't access HomeKit. So `HomeKitHelper` is a headless Mac Catalyst app that talks to HomeKit, while `homekit-mcp` is the SPM-built main app that handles MCP, the menu bar, and configuration. They communicate over a Unix domain socket.

## Quick Start

```bash
git clone https://github.com/omarshahine/HomeKitBridge.git
cd HomeKitBridge
scripts/build.sh --install
```

This builds everything, assembles the app bundle, code-signs it, copies it to `/Applications`, and symlinks `homekit-cli` to `/usr/local/bin`.

Launch from `/Applications` or: `open "/Applications/HomeKit Bridge.app"`

## Components

| Component | What It Does | Built With |
|-----------|-------------|------------|
| **homekit-mcp** | Menu bar app, MCP HTTP server, auth, config | Swift 6.2, SPM, SwiftNIO, MCP Swift SDK |
| **homekit-cli** | Terminal interface to HomeKit accessories | Swift 6.2, SPM, ArgumentParser |
| **HomeKitHelper** | Headless Catalyst app that talks to HomeKit API | Xcode, Mac Catalyst, XcodeGen |
| **MCP Server (Node)** | Stdio MCP server for Claude Code plugin | Node.js, @modelcontextprotocol/sdk |
| **HomeClaw** | OpenClaw plugin for HomeKit control | TypeScript |

## MCP Tools

The HTTP MCP server (port 9090) exposes these tools:

| Tool | Description |
|------|-------------|
| `list_homes` | List all HomeKit homes with room and accessory counts |
| `list_accessories` | List accessories with current state, filter by home or room |
| `get_accessory` | Full details of a specific accessory (services, characteristics) |
| `control_accessory` | Set a characteristic value (power, brightness, temperature, etc.) |
| `list_rooms` | List all rooms and their accessories |
| `list_scenes` | List all scenes (action sets) |
| `trigger_scene` | Execute a scene by UUID or name |
| `search_accessories` | Fuzzy search by name, room, or category |

## CLI Usage

```bash
# Check if HomeKit Bridge is running
homekit-cli status

# List all accessories
homekit-cli list
homekit-cli list --room "Living Room"
homekit-cli list --category thermostat

# Get details on a specific accessory
homekit-cli get "Front Door Lock"
homekit-cli get <uuid>

# Control accessories
homekit-cli set "Living Room Lights" power true
homekit-cli set "Thermostat" target_temperature 72

# Scenes
homekit-cli scenes
homekit-cli trigger "Good Night"

# Search
homekit-cli search "bedroom light"

# Configuration
homekit-cli config
homekit-cli config --default-home "My Home"
homekit-cli config --filter-mode allowlist
homekit-cli config --list-devices
```

## Configuration

Config file: `~/.config/homekit-bridge/config.json`

```json
{
  "default_home_id": "<uuid>",
  "accessory_filter_mode": "all",
  "allowed_accessory_ids": ["<uuid>", "<uuid>"]
}
```

- **default_home_id** -- Set a default home so you don't need to specify `home_id` on every call
- **accessory_filter_mode** -- `"all"` exposes everything, `"allowlist"` restricts to specific devices
- **allowed_accessory_ids** -- When in allowlist mode, only these accessories are visible via MCP and CLI

Use `homekit-cli config --list-devices` to see all accessories with their UUIDs and allowed status.

## Building

```bash
# Full build (release, with HomeKitHelper)
scripts/build.sh

# Debug build
scripts/build.sh --debug

# Skip HomeKitHelper (faster iteration on homekit-mcp)
scripts/build.sh --skip-helper

# Build and install to /Applications
scripts/build.sh --install

# Clean first
scripts/build.sh --clean --install
```

The build script handles: SPM compilation, Catalyst xcodebuild, app bundle assembly, inner-to-outer code signing, and optional install.

### Version Bumping

All version sources are updated with a single command:

```bash
scripts/bump-version.sh 0.2.0
```

This updates AppConfig.swift, both Info.plists, all package.json files, and the Claude plugin manifest.

## Requirements

- macOS 26 (Tahoe) / iOS 18+
- Xcode 26 with Swift 6.2
- Node.js 20+ (for MCP server build)
- Apple Developer account (for HomeKit entitlement provisioning)
- XcodeGen (`brew install xcodegen`) for HomeKitHelper project generation

## Authentication

The MCP HTTP server uses bearer token authentication. On first launch, a token is generated and stored in the macOS Keychain. The token is displayed in the Settings panel (accessible from the menu bar icon) for configuring MCP clients.

## Claude Code Plugin

HomeKit Bridge includes a Claude Code plugin (`homekit-bridge`) that provides:

- **MCP Server** -- Stdio-based MCP server wrapping `homekit-cli` for Claude Code integration
- **HomeKit Skill** -- Natural language interface for controlling your smart home

Install via:
```
/plugin install homekit-bridge@<marketplace>
```

## License

[MIT](LICENSE)
