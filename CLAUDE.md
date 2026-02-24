# HomeKit Bridge

HomeKit Bridge exposes Apple HomeKit accessories via an MCP (Model Context Protocol) HTTP server and a CLI tool. It uses a split-process architecture to work around Apple's framework restrictions.

## Architecture

```
homekit-mcp (SPM, SwiftUI menu bar app)
  ├── MCP HTTP server (port 9090, bearer token auth)
  ├── Menu bar UI + Settings window
  └── Unix socket client
        │
        ▼ /tmp/homekit-bridge.sock (JSON newline-delimited)
        │
HomeKitHelper (Mac Catalyst UIKit app, headless)
  ├── HMHomeManager (requires @MainActor)
  ├── HomeKit device discovery & control
  └── Unix socket server (GCD-based)
```

**Why two processes?** `HMHomeManager` requires a UIKit/Catalyst app with the HomeKit entitlement and a valid provisioning profile. Plain Swift CLI/SPM apps cannot access HomeKit. The main app (`homekit-mcp`) handles MCP and UI; the helper (`HomeKitHelper`) handles HomeKit.

## Project Structure

```
Sources/
  homekit-mcp/           # Main app (SPM executable)
    App/                 # SwiftUI app entry, AppDelegate
    MCP/                 # MCP server, HTTP handler, tool definitions
    HomeKit/             # HomeKitClient (socket client to helper)
    Views/               # MenuBarView, SettingsView
    Shared/              # AppConfig, KeychainManager, Logger
  homekit-cli/           # CLI tool (SPM executable)
    Commands/            # list, get, set, search, scenes, status, config, token
    SocketClient.swift   # Direct socket communication
  HomeKitHelper/         # Catalyst helper app (Xcode project via XcodeGen)
    HomeKitManager.swift # HMHomeManager wrapper (@MainActor)
    HelperSocketServer.swift  # Unix socket server (GCD)
    CharacteristicMapper.swift # HomeKit type mappings
    AccessoryModel.swift      # JSON serialization models
Resources/               # Info.plist, entitlements, app icons
scripts/build.sh         # Build & install script
mcp-server/              # Node.js stdio MCP server (wraps homekit-cli)
openclaw/                # HomeClaw — OpenClaw plugin for Claude Code
  openclaw.plugin.json   # Plugin manifest (configurable binDir)
  src/index.ts           # Plugin entry point
  skills/homekit/        # HomeKit skill definition
```

## Build System

Three build systems:
- **SPM** (`swift build`): Builds `homekit-mcp` and `homekit-cli`
- **Xcode** (`xcodebuild`): Builds `HomeKitHelper` as Mac Catalyst app
- **npm** (esbuild): Builds `mcp-server` Node.js MCP server

The `scripts/build.sh` orchestrates SPM + Xcode, assembles the `.app` bundle, and code-signs:

```bash
scripts/build.sh --release --install   # Full build + install to /Applications
scripts/build.sh --debug               # Debug build only
scripts/build.sh --skip-helper         # Skip Catalyst build (faster iteration)
npm run build:mcp                      # Build Node.js MCP server only
```

**npm workspaces**: Root `package.json` defines workspaces for `openclaw` and `mcp-server`. Run `npm install` from the project root.

### XcodeGen

HomeKitHelper uses XcodeGen (`project.yml`) to generate its `.xcodeproj`. The generated `.xcodeproj` is gitignored — regenerate after cloning:
```bash
cd Sources/HomeKitHelper && xcodegen
```

### Development Workflow

```bash
# Build and run from build dir (no install)
scripts/build.sh --debug
open .build/app/HomeKit\ Bridge.app

# Iterate on SPM code only (skip slow Catalyst build)
scripts/build.sh --debug --skip-helper

# Test MCP endpoint (requires running app with valid token)
TOKEN=$(security find-generic-password -s com.shahine.homekit-bridge.auth -a mcp-bearer-token -w 2>/dev/null)
curl -X POST http://localhost:9090/mcp \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}'
```

## Critical: Entitlements

The HomeKit entitlement **must** be in `Sources/HomeKitHelper/HomeKitHelper.entitlements`:
```xml
<key>com.apple.developer.homekit</key>
<true/>
```

**Do NOT remove this.** The build script re-signs the helper with this file (`codesign --entitlements`), completely replacing whatever Xcode applied. The provisioning profile defines what's *allowed*; the entitlements file defines what's *requested*. Without it, `HMHomeManager` silently returns zero homes.

Verify with: `codesign -d --entitlements - "/Applications/HomeKit Bridge.app/Contents/Helpers/HomeKitHelper.app"`

## Key Configuration

| Setting | Location | Default |
|---------|----------|---------|
| MCP port | UserDefaults `mcpServerPort` | 9090 |
| Bearer token | Keychain `com.shahine.homekit-bridge.auth` | Auto-generated |
| Device filter | `~/.config/homekit-bridge/config.json` | `"accessoryFilterMode": "all"` |
| Default home | `~/.config/homekit-bridge/config.json` | First home |
| Socket path | Hardcoded | `/tmp/homekit-bridge.sock` |

## MCP Tools

Tools are defined in `Sources/homekit-mcp/MCP/ToolHandlers.swift`. Eight tools cover home/room/accessory listing, accessory control, scene management, and search. New tools: add to `allTools` array and `handleToolCall` switch.

## Concurrency Model

- **HomeKitHelper**: `HomeKitManager` is `@MainActor` (required by `HMHomeManager`). Socket server uses GCD with semaphore+ResponseBox to bridge to MainActor.
- **homekit-mcp**: `MCPServer` is an `actor`. SwiftUI views use `@State` + `Task` for async data loading.
- Swift 6 strict concurrency is enabled (`SWIFT_STRICT_CONCURRENCY: complete`).

## Debugging

```bash
# Check if helper is running and HomeKit is ready
echo '{"command":"status"}' | nc -U /tmp/homekit-bridge.sock

# Check entitlements on installed app
codesign -d --entitlements - "/Applications/HomeKit Bridge.app/Contents/Helpers/HomeKitHelper.app"

# Check TCC (privacy) permissions
sqlite3 ~/Library/Application\ Support/com.apple.TCC/TCC.db \
  "SELECT client, auth_value FROM access WHERE service = 'kTCCServiceWillow'"

# View HomeKitHelper logs
log show --predicate 'process == "HomeKitHelper"' --last 10m --style compact
```

If status shows `ready: false` with 0 homes:
1. Verify HomeKit entitlement is embedded (codesign check above)
2. Verify TCC permission granted (auth_value=2)
3. Verify iCloud is signed in with HomeKit data
4. Restart the app after rebuilding

## Code Style

- Swift 6 with strict concurrency
- `@MainActor` for all HomeKit API interactions
- `actor` for MCP server isolation
- `os.Logger` via `AppLogger` (main app) and `HelperLogger` (helper)
- JSON communication over Unix domain sockets (newline-delimited)

## CI

GitHub Actions (`.github/workflows/tests.yml`) runs on `macos-26`:
- Builds `homekit-mcp` and `homekit-cli` via SPM
- Builds `mcp-server` (Node.js) on ubuntu-latest
- HomeKitHelper is NOT built in CI (requires signing identity + provisioning)
