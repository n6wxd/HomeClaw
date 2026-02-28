# HomeClaw Architecture

HomeClaw is a Mac Catalyst application that exposes Apple HomeKit smart home accessories through four client interfaces: a macOS menu bar, a CLI tool, an MCP server for Claude, and an OpenClaw plugin. It uses a single-process design where the Catalyst app holds the only direct HomeKit connection, and all external clients communicate over a Unix domain socket.

---

## System Overview

```
                         ┌─────────────────────────────────────────────────────────────┐
                         │                    HomeClaw.app (Mac Catalyst)              │
                         │                                                             │
  ┌──────────────┐       │  ┌──────────────┐    ┌───────────────┐   ┌──────────────┐   │
  │ macOSBridge  │◄─────►│  │ HomeClawApp  │───►│HomeKitManager │──►│ HMHomeManager│   │
  │   .bundle    │iOS2Mac│  │(UIAppDelegate│    │  (@MainActor) │   │  (HomeKit    │   │
  │              │Mac2iOS│  │  + Mac2iOS)  │    │   singleton   │   │   framework) │   │
  │ NSStatusItem │       │  └──────────────┘    └───────┬───────┘   └──────────────┘   │
  │  + NSMenu    │       │                              │                              │
  └──────────────┘       │                   ┌──────────┼─────────┐                    │
                         │                   ▼          ▼         ▼                    │
                         │       ┌──────────────┐    ┌───────┐ ┌────────────┐          │
                         │       │Characteristic│    │Device │ │  HomeEvent │          │
                         │       │   Cache      │    │  Map  │ │   Logger   │          │
                         │       └──────────────┘    └───────┘ └────────────┘          │
                         │                                                             │
                         │  ┌──────────────────────────────────────────────────────┐   │
                         │  │              SocketServer (GCD)                      │   │
                         │  │         /tmp/homeclaw.sock (JSON-newline)            │   │
                         │  └────────────────────┬─────────────────────────────────┘   │
                         └───────────────────────┼─────────────────────────────────────┘
                                                 │
                    ┌────────────────────────────┼────────────────────────────┐
                    │                            │                            │
                    ▼                            ▼                            ▼
           ┌──────────────┐            ┌──────────────┐            ┌──────────────────┐
           │ homeclaw-cli │            │  mcp-server  │            │ OpenClaw Plugin  │
           │  (Swift CLI) │            │  (Node.js    │            │  (invokes CLI)   │
           │              │            │   stdio MCP) │            │                  │
           └──────┬───────┘            └──────┬───────┘            └──────────────────┘
                  │                           │
                  ▼                           ▼
           Terminal / Scripts          Claude Desktop /
                                       Claude Code
```

### Why Mac Catalyst?

`HMHomeManager` requires a UIKit/Catalyst process with the `com.apple.developer.homekit` entitlement. By building the entire app as Catalyst:

- HomeKit access is **direct** (no IPC to a helper process)
- Code signing is **unified** (single archive for App Store)
- The macOS menu bar is provided by a **plugin bundle** (`macOSBridge.bundle`) loaded at runtime

---

## Filesystem Tree

```
HomeClaw/
├── Sources/
│   ├── homeclaw/                          # Main Catalyst app
│   │   ├── App/
│   │   │   └── HomeClawApp.swift          # @main UIApplicationDelegate, scene delegates
│   │   ├── Bridge/
│   │   │   └── BridgeProtocols.swift      # Mac2iOS + iOS2Mac @objc protocols
│   │   ├── HomeKit/
│   │   │   ├── HomeKitManager.swift       # @MainActor singleton, HMHomeManager wrapper
│   │   │   ├── SocketServer.swift         # Unix domain socket server (GCD)
│   │   │   ├── AccessoryModel.swift       # HMAccessory → [String:Any] serialization
│   │   │   ├── CharacteristicMapper.swift # UUID→name mapping, value formatting/parsing
│   │   │   ├── CharacteristicCache.swift  # In-memory + JSON-persisted value cache
│   │   │   ├── DeviceMap.swift            # LLM-optimized device tree builder
│   │   │   └── HomeEventLogger.swift      # JSONL event log + webhook delivery
│   │   ├── Views/
│   │   │   ├── SettingsView.swift         # SwiftUI settings (5 tabs)
│   │   │   └── IntegrationsSettingsView.swift  # CLI/MCP/plugin installer UI
│   │   ├── Shared/
│   │   │   ├── AppConfig.swift            # Bundle ID, socket path, constants
│   │   │   ├── AppLogger.swift            # os.Logger categories
│   │   │   └── HomeClawConfig.swift       # Persistent JSON config (singleton)
│   │   ├── MCP/_disabled/                 # Preserved HTTP MCP server (not compiled)
│   │   └── Shared/_disabled/             # Preserved KeychainManager (not compiled)
│   │
│   ├── macOSBridge/                       # AppKit plugin bundle
│   │   ├── MacOSController.swift          # NSStatusItem + NSMenu + iOS2Mac
│   │   └── Info.plist                     # NSPrincipalClass: MacOSController
│   │
│   └── homeclaw-cli/                      # CLI tool (ArgumentParser)
│       ├── main.swift                     # Entry point (SIGPIPE handling)
│       ├── HomeKitCLI.swift               # Root ParsableCommand
│       ├── SocketClient.swift             # Unix socket client + AnyCodable
│       ├── JSONHelper.swift               # Pretty-print JSON utility
│       └── Commands/
│           ├── ListCommand.swift          # list [--room] [--category] [--json]
│           ├── GetCommand.swift           # get <name|uuid>
│           ├── SetCommand.swift           # set <name> <characteristic> <value>
│           ├── SearchCommand.swift         # search <query> [--category]
│           ├── ScenesCommand.swift        # scenes / trigger <name|uuid>
│           ├── StatusCommand.swift        # HomeClaw connection status
│           ├── ConfigCommand.swift        # View/update config + webhook settings
│           ├── DeviceMapCommand.swift     # Device map (text/json/md/agent formats)
│           ├── EventsCommand.swift        # Recent events [--limit] [--type] [--since]
│           └── _disabled/
│               └── TokenCommand.swift     # Bearer token management (disabled)
│
├── mcp-server/                            # Node.js stdio MCP server
│   ├── server.js                          # MCP SDK server, 7 tool registrations
│   ├── build.mjs                          # esbuild bundler config
│   ├── dist/server.js                     # Built bundle (esbuild output)
│   └── package.json
│
├── lib/                                   # Shared Node.js modules
│   ├── schemas.js                         # MCP tool input schemas (Zod)
│   ├── handlers/
│   │   └── homekit.js                     # Tool call → socket command dispatch
│   └── socket-client.js                   # Node.js Unix socket client
│
├── openclaw/                              # OpenClaw plugin
│   ├── openclaw.plugin.json               # Plugin manifest
│   ├── src/index.ts                       # Plugin entry point
│   ├── skills/homekit/SKILL.md            # LLM skill definition
│   └── package.json
│
├── .claude-plugin/                        # Claude Code plugin
│   ├── plugin.json                        # MCP server definition (stdio)
│   └── marketplace.json                   # Marketplace listing metadata
│
├── skills/homeclaw/SKILL.md               # Claude Code skill definition
│
├── Resources/
│   ├── Info.plist                          # LSUIElement, HomeKit usage, scenes
│   ├── HomeClaw.entitlements              # HomeKit + App Group entitlements
│   ├── homeclaw-cli.entitlements          # App Group only
│   ├── PrivacyInfo.xcprivacy              # Privacy manifest (no tracking)
│   └── Assets.xcassets/                   # App icons
│
├── scripts/
│   ├── build.sh                           # xcodegen + xcodebuild + install
│   ├── archive.sh                         # Archive for TestFlight / App Store
│   └── bump-version.sh                    # Multi-file version bump + git tag
│
├── project.yml                            # XcodeGen project definition
├── Package.swift                          # SPM (CLI-only, for CI)
├── package.json                           # npm workspaces root
├── ExportOptions.plist                    # App Store export config
├── .github/workflows/tests.yml            # CI: SPM build + MCP build
└── CLAUDE.md                              # Claude Code project instructions
```

---

## Component Deep Dives

### 1. HomeClawApp — Application Lifecycle

```
Launch
  │
  ├─► Set activation policy to .accessory (no dock icon)
  ├─► Initialize HomeKitManager.shared
  ├─► Start SocketServer.shared
  ├─► Load macOSBridge.bundle via NSBundle
  │     └─► Instantiate NSPrincipalClass (MacOSController)
  │         └─► Sets iOSBridge = self (HomeClawApp as Mac2iOS)
  │
  ├─► Register for notifications:
  │     .homeKitStatusDidChange  ──► macOSController.updateStatus()
  │     .homeKitMenuDataDidChange ──► macOSController.updateMenuData()
  │
  └─► Scene configuration:
        "Settings" role ──► SettingsSceneDelegate ──► UIHostingController(SettingsView)
        "Default"  role ──► HeadlessSceneDelegate  ──► (no visible window)
```

The app uses `settingsRequested` as a static flag to prevent UIKit scene restoration from auto-showing the Settings window on launch. Settings are opened on demand via the menu bar or programmatically.

### 2. Bridge Protocols — Catalyst ↔ AppKit Communication

The macOSBridge bundle is pure AppKit and cannot import UIKit. Communication crosses the framework boundary via two `@objc` protocols:

```
┌──────────────────────────┐          ┌──────────────────────────┐
│     macOSBridge.bundle   │          │    HomeClaw Catalyst     │
│    (AppKit, NSObject)    │          │    (UIKit, Catalyst)     │
│                          │          │                          │
│  MacOSController         │          │  HomeClawApp             │
│    implements iOS2Mac ◄──┼──────────┼── calls iOS2Mac methods  │
│                          │          │                          │
│    calls Mac2iOS methods─┼──────────┼─► implements Mac2iOS     │
│                          │          │                          │
└──────────────────────────┘          └──────────────────────────┘

Mac2iOS (Catalyst exposes to bridge):
  ├── isLaunchAtLoginEnabled: Bool
  ├── setLaunchAtLogin(_:)
  ├── refreshData()
  ├── openSettings()
  ├── quitApp()
  ├── controlAccessory(id:, characteristic:, value:, completion:)
  ├── triggerScene(id:, completion:)
  └── selectHome(id:)

iOS2Mac (Bridge exposes to Catalyst):
  ├── init(), iOSBridge: Mac2iOS
  ├── updateStatus(isReady:, homeCount:, accessoryCount:)
  ├── updateMenuData(_: [[String:Any]])
  ├── showError(_:)
  └── flashError(_:)
```

### 3. HomeKitManager — The Core

`HomeKitManager` is the central hub. It wraps Apple's `HMHomeManager` with async/await, manages the characteristic cache, and pushes updates to the menu bar.

```
                    ┌──────────────────────────────────┐
                    │        HomeKitManager            │
                    │        (@MainActor)              │
                    │                                  │
  API calls ───────►│  listHomes()                     │
  (from Socket     ││  listRooms(homeID:)              │
   Server or       ││  listAccessories(homeID:,roomID:)│──────► AccessoryModel
   Mac2iOS)        ││  getAccessory(id:)               │         (serialization)
                   ││  controlAccessory(id:,char:,val:)│
                   ││  listScenes(homeID:)             │──────► CharacteristicMapper
                   ││  triggerScene(id:)               │         (name mapping,
                   ││  searchAccessories(query:)       │          value parsing)
                   ││  deviceMap()                     │
                    │                                  │──────► CharacteristicCache
                    │  warmCache()                     │         (read/write values)
                    │  filterAccessories()             │
                    │  buildMenuData()                 │──────► HomeClawConfig
                    │  scheduleMenuDataPush()          │         (filtering, prefs)
                    │                                  │
                    │  HMHomeManagerDelegate           │──────► HomeEventLogger
                    │    homeManagerDidUpdateHomes()   │         (event recording)
                    │                                  │
                    │  HMAccessoryDelegate             │──────► DeviceMap
                    │    didUpdateValueFor()           │         (LLM device tree)
                    └──────────────────────────────────┘

  Readiness pattern:
  ┌─────────┐   homeManagerDidUpdateHomes   ┌─────────┐   warmCache()   ┌─────────┐
  │  Init   │ ─────────────────────────────►│ Update  │ ──────────────► │  Ready  │
  │         │   (CheckedContinuation)       │ homes   │                 │         │
  └─────────┘                               └─────────┘                 └─────────┘
                                                │
                                                ├── Register HMAccessoryDelegate on all accessories
                                                ├── Post .homeKitStatusDidChange
                                                └── scheduleMenuDataPush()
```

**Cache warming**: On `homeManagerDidUpdateHomes`, the manager reads "interesting" characteristic values (power, brightness, temperature, lock state, etc.) from all filtered, reachable accessories. The `HMAccessoryDelegate` then updates cached values in real-time as characteristics change.

**Menu data push**: After cache warm or any value change, `scheduleMenuDataPush()` coalesces updates (100ms debounce) and sends serialized menu data to the macOSBridge via `iOS2Mac.updateMenuData()`.

### 4. SocketServer — External Client Gateway

The socket server bridges GCD-based socket I/O to `@MainActor` HomeKit calls.

```
  Client (CLI/MCP)                     SocketServer                     HomeKitManager
       │                                   │                                  │
       │──── connect() ───────────────────►│                                  │
       │──── {"command":"list_accessories",│                                  │
       │      "args":{"home_id":"..."}}───►│                                  │
       │                                   │                                  │
       │                                   │── DispatchQueue.global ──┐       │
       │                                   │                          │       │
       │                                   │   ┌─ResponseBox──────┐   │       │
       │                                   │   │ semaphore.wait() │   │       │
       │                                   │   └────────┬─────────┘   │       │
       │                                   │            │             │       │
       │                                   │   Task { @MainActor     ─┼──────►│
       │                                   │     let result = await   │       │
       │                                   │       manager.list...()  │◄──────│
       │                                   │     box.result = result  │       │
       │                                   │     semaphore.signal()   │       │
       │                                   │   }                      │       │
       │                                   │            │             │       │
       │                                   │   ┌────────▼──────────┐  │       │
       │                                   │   │ semaphore resumed │  │       │
       │                                   │   │ read box.result   │  │       │
       │                                   │   └───────────────────┘  │       │
       │                                   │◄─────────────────────────┘       │
       │◄── {"success":true,"data":[...]}──│                                  │
       │                                   │                                  │
```

**Socket protocol**: Newline-delimited JSON over Unix domain socket at `/tmp/homeclaw.sock` (or App Group container path).

**Commands** (25+):

| Category | Commands |
|----------|----------|
| Discovery | `status`, `list_homes`, `list_rooms`, `list_accessories`, `list_all_accessories`, `get_accessory`, `search`, `device_map` |
| Control | `control`, `trigger_scene`, `list_scenes` |
| Cache | `refresh_cache` |
| Config | `get_config`, `set_config` |
| Events | `events`, `event_log_stats`, `set_event_log`, `purge_events` |
| Webhooks | `set_webhook`, `list_triggers`, `add_trigger`, `remove_trigger` |

### 5. macOSBridge — Menu Bar UI

The macOSBridge bundle renders the system menu bar and handles user interactions.

```
NSStatusItem (menu bar icon)
  └── NSMenu
        ├── [Home Selector]              (if multiple homes)
        │     ├── ✓ Home 1
        │     └──   Home 2
        ├── ─────────────────
        ├── Scenes
        │     ├── Good Morning           (SF Symbol per scene type)
        │     ├── Good Night
        │     └── ...
        ├── ─────────────────
        ├── Living Room                  (per-room section)
        │     ├── 💡 All Lights  On/Off  (room light toggle)
        │     ├── Ceiling Light     ●/○  (toggle + brightness submenu)
        │     │     ├── 25%
        │     │     ├── 50%
        │     │     ├── 75%
        │     │     └── 100%
        │     ├── Thermostat    72°F     (status-only, non-interactive)
        │     └── Door Lock    Locked    (status-only)
        ├── Bedroom
        │     └── ...
        ├── ─────────────────
        ├── ✓ Launch at Login
        ├── Settings...
        └── Quit HomeClaw
```

**Accessory behavior classification** determines interactivity:

```swift
enum AccessoryBehavior {
    case toggle(isOn: Bool)     // lights, switches, fans, outlets, window coverings
    case statusOnly(text: String) // thermostats, locks, doors, sensors, sprinklers
}
```

**Optimistic updates**: When a user toggles an accessory, the menu patches `menuData` immediately and rebuilds the menu before the HomeKit callback arrives. This makes the UI feel instant.

**Hidden categories**: Bridges and range extenders are automatically hidden from the menu to reduce clutter.

### 6. CLI Tool — Command Structure

```
homeclaw-cli
  ├── status          (default)   Show connection status
  ├── list            List accessories [--room] [--category] [--json]
  ├── get <name>      Get accessory detail by name or UUID
  ├── set <name> <char> <val>     Set a characteristic value
  ├── search <query>  Search accessories [--category]
  ├── scenes          List all scenes
  │   └── trigger <name>          Execute a scene
  ├── config          View/update configuration
  │   ├── --default-home <id>
  │   ├── --filter-mode <all|allowlist>
  │   ├── --set-webhook-url <url>
  │   └── --list-devices          Show all with allowed status
  ├── device-map      LLM-optimized device map
  │   ├── --format text|json|md|agent
  │   └── --output <file>
  └── events          Recent events [--limit] [--type] [--since]
```

All commands go through `SocketClient.send()` which connects to the Unix socket, sends a JSON command, and reads the JSON response.

### 7. MCP Server — Claude Integration

```
Claude Desktop / Claude Code
  │
  │  stdio (stdin/stdout)
  ▼
┌──────────────────────────────────────┐
│          mcp-server (Node.js)        │
│                                      │
│  @modelcontextprotocol/sdk Server    │
│                                      │
│  7 Tools:                            │
│  ├── homekit_status                  │
│  ├── homekit_accessories             │──► lib/handlers/homekit.js
│  │     actions: list,get,search,     │      │
│  │              control              │      │
│  ├── homekit_rooms                   │      ▼
│  ├── homekit_scenes                  │    lib/socket-client.js
│  │     actions: list, trigger        │      │
│  ├── homekit_device_map              │      │  Unix socket
│  ├── homekit_config                  │      │  JSON-newline
│  │     actions: get, set             │      ▼
│  └── homekit_events                  │    HomeClaw SocketServer
│                                      │
│  Tool schemas: lib/schemas.js (Zod)  │
└──────────────────────────────────────┘
```

The MCP server is bundled as a single file (`mcp-server/dist/server.js`) built by esbuild. It communicates with the HomeClaw app over the same Unix socket used by the CLI.

---

## Data Flow

### Request/Response Flow (all external clients)

```
                    ┌──────────────────────────────────────────────────┐
                    │              Request Path                        │
                    │                                                  │
  CLI ─────────┐    │   ┌────────┐   ┌────────────┐   ┌────────────┐   │
               ├───►│──►│ Socket │──►│  Command   │──►│ HomeKit    │   │
  MCP Server ──┘    │   │ Client │   │  Dispatch  │   │ Manager    │   │
                    │   └────────┘   │ (switch on │   │ (async     │   │
                    │                │  command)  │   │  calls to  │   │
                    │                └────────────┘   │  HMHome-   │   │
                    │                                 │  Manager)  │   │
                    │              Response Path      └─────┬──────┘   │
                    │                                       │          │
                    │   ┌────────┐   ┌────────────┐         │          │
               ◄────┼───│ Socket │◄──│ Accessory  │◄────────┘          │
                    │   │ Client │   │ Model      │                    │
                    │   └────────┘   │ (serialize)│                    │
                    │                └────────────┘                    │
                    └──────────────────────────────────────────────────┘
```

### Real-Time Update Flow

```
  HomeKit Device Change (physical or Siri)
       │
       ▼
  HMAccessoryDelegate.didUpdateValueFor(characteristic:)
       │
       ├──► CharacteristicCache.setValue()
       │      └──► Persist to ~/Library/Application Support/HomeClaw/cache.json
       │
       ├──► HomeEventLogger.logEvent(.characteristic_change, ...)
       │      ├──► Append to events.jsonl
       │      └──► Evaluate webhook triggers
       │             └──► POST to webhook URL (if trigger matches)
       │
       └──► scheduleMenuDataPush()  (100ms debounce)
              └──► buildMenuData()
                     └──► iOS2Mac.updateMenuData()
                            └──► MacOSController rebuilds NSMenu
```

### Configuration Flow

```
  ┌─────────────────────────────────────────────────────────────────┐
  │   ~/Library/Application Support/HomeClaw/config.json            │
  │                                                                 │
  │   {                                                             │
  │     "defaultHomeID": "...",                                     │
  │     "accessoryFilterMode": "all" | "allowlist",                 │
  │     "allowedAccessoryIDs": ["..."],                             │
  │     "temperatureUnit": "fahrenheit" | "celsius",                │
  │     "webhookConfig": { "url": "...", "bearerToken": "..." },    │
  │     "eventLogConfig": { "enabled": true, "maxSize": 5242880 },  │
  │     "webhookTriggers": [{ "name": "...", "events": [...] }]     │
  │   }                                                             │
  └───────────────┬───────────────────────┬─────────────────────────┘
                  │                       │
    Read at startup by:          Modified by:
    ├── HomeKitManager           ├── SettingsView (SwiftUI)
    │   (filtering, home         ├── CLI: homeclaw-cli config --set-...
    │    selection)               └── Socket: set_config command
    ├── CharacteristicMapper
    │   (temperature unit)
    ├── HomeEventLogger
    │   (log settings, webhooks)
    └── SocketServer
        (get_config response)
```

---

## Code Interdependencies

### Swift Module Dependency Graph

```
                          ┌───────────────────┐
                          │   HomeClawApp     │
                          │   (entry point)   │
                          └─────────┬─────────┘
                                    │
              ┌─────────────────────┼──────────────────────┐
              │                     │                      │
              ▼                     ▼                      ▼
   ┌──────────────────┐  ┌──────────────────┐  ┌──────────────────┐
   │  HomeKitManager  │  │   SocketServer   │  │  macOSBridge     │
   │  (singleton)     │  │   (singleton)    │  │  (plugin bundle) │
   └────────┬─────────┘  └────────┬─────────┘  └──────────────────┘
            │                     │                      ▲
            │    ┌────────────────┘                      │
            │    │  (SocketServer calls                  │
            │    │   HomeKitManager methods)             │
            │    │                                       │
            ▼    ▼                                       │
   ┌──────────────────┐                          BridgeProtocols
   │  AccessoryModel  │                          (Mac2iOS, iOS2Mac)
   └────────┬─────────┘
            │
            ▼
   ┌──────────────────┐     ┌──────────────────┐
   │ Characteristic   │     │ Characteristic   │
   │    Mapper        │     │    Cache         │
   └──────────────────┘     └──────────────────┘
            │                        │
            └────────┬───────────────┘
                     ▼
            ┌──────────────────┐
            │  HomeClawConfig  │
            │  (singleton)     │
            └──────────────────┘
                     │
                     ▼
            ┌──────────────────┐     ┌──────────────────┐
            │    AppConfig     │     │    AppLogger     │
            │ (static consts)  │     │ (static loggers) │
            └──────────────────┘     └──────────────────┘
```

### Node.js Module Dependency Graph

```
  mcp-server/server.js
       │
       ├──► lib/schemas.js          (Zod tool input schemas)
       ├──► lib/handlers/homekit.js (tool call dispatch)
       │         │
       │         └──► lib/socket-client.js  (Unix socket I/O)
       │
       └──► @modelcontextprotocol/sdk  (MCP protocol)
```

### Cross-Component Dependencies

```
  ┌─────────────┐      socket       ┌──────────────┐
  │ homeclaw-cli│──────────────────►│ HomeClaw.app │
  │ (Swift)     │  (SocketClient)   │(SocketServer)│
  └─────────────┘                   └──────────────┘
                                          ▲
  ┌─────────────┐      socket       ┌─────┴────────┐
  │ mcp-server  │──────────────────►│ HomeClaw.app │
  │ (Node.js)   │ (socket-client)   │(SocketServer)│
  └─────────────┘                   └──────────────┘
                                           ▲
  ┌─────────────┐    homeclaw-cli    ┌─────┴────────┐
  │ OpenClaw    │───────────────────►│ HomeClaw.app │
  │ (TypeScript)│  (child process)   │(SocketServer)│
  └─────────────┘                    └──────────────┘
```

---

## Build System

### Dual Build System

```
┌──────────────────────────────────────────────────────────────────┐
│                        scripts/build.sh                          │
│                                                                  │
│  1. xcodegen generate         ──► HomeClaw.xcodeproj             │
│  2. npm run build:mcp         ──► mcp-server/dist/server.js      │
│  3. xcodebuild                ──► Build 3 targets:               │
│       │                             ├── HomeClaw (Catalyst)      │
│       │                             ├── macOSBridge.bundle       │
│       │                             └── homeclaw-cli             │
│  4. (optional) install        ──► /Applications/HomeClaw.app     │
│       └── symlink CLI         ──► /usr/local/bin/homeclaw-cli    │
└──────────────────────────────────────────────────────────────────┘
```

### XcodeGen Targets (project.yml)

```
┌────────────────────┬────────────┬────────────────────────────────────┐
│ Target             │ Platform   │ Notes                              │
├────────────────────┼────────────┼────────────────────────────────────┤
│ HomeClaw           │ Catalyst   │ iOS platform + SUPPORTS_MACCATALYST│
│                    │ (UIKit)    │ HomeKit entitlement, App Group     │
│                    │            │ Depends on macOSBridge + CLI       │
├────────────────────┼────────────┼────────────────────────────────────┤
│ macOSBridge        │ macOS 15   │ AppKit bundle, NSPrincipalClass    │
│                    │ (AppKit)   │ Sources: macOSBridge + Bridge/     │
├────────────────────┼────────────┼────────────────────────────────────┤
│ homeclaw-cli       │ macOS 15   │ Command-line tool                  │
│                    │            │ swift-argument-parser dependency   │
└────────────────────┴────────────┴────────────────────────────────────┘
```

### App Bundle Layout (post-build)

```
HomeClaw.app/
  Contents/
    MacOS/
      HomeClaw                    # Catalyst executable
      homeclaw-cli                # CLI binary (copied by post-build script)
    PlugIns/
      macOSBridge.bundle/         # AppKit menu bar plugin
    Resources/
      mcp-server.js              # Bundled MCP server (copied by post-build script)
      openclaw/                   # OpenClaw plugin files (copied by post-build script)
        openclaw.plugin.json
        skills/homekit/SKILL.md
```

### CI Pipeline (.github/workflows/tests.yml)

```
  macos-26 runner
       │
       ├── Verify HomeKit entitlement in Resources/HomeClaw.entitlements
       ├── swift build (homeclaw-cli only via Package.swift)
       └── npm ci && npm run build:mcp (MCP server)

  Note: The Catalyst app is NOT built in CI (requires signing identity)
```

---

## Concurrency Model

```
┌────────────────────────────────────────────────────────────────┐
│                     Thread Architecture                        │
│                                                                │
│  Main Thread (@MainActor)                                      │
│  ├── HomeKitManager  ◄── HMHomeManager requires main thread    │
│  ├── HomeClawApp     ◄── UIApplicationDelegate                 │
│  ├── HomeEventLogger ◄── File I/O serialized on main           │
│  └── MacOSController ◄── NSStatusItem requires main thread     │
│                                                                │
│  GCD Global Queue                                              │
│  ├── SocketServer accept loop (DispatchSourceRead)             │
│  └── Per-client handler threads                                │
│        └── ResponseBox + DispatchSemaphore                     │
│              └── Task { @MainActor ... }  ──► main thread      │
│                    └── signal semaphore when done              │
│                                                                │
│  HomeClawConfig: @unchecked Sendable (thread-safe via design)  │
│  CharacteristicCache: @unchecked Sendable (similar)            │
│                                                                │
│  Swift 6 strict concurrency: SWIFT_STRICT_CONCURRENCY=complete │
└────────────────────────────────────────────────────────────────┘
```

The key concurrency challenge is bridging the GCD-based socket server to `@MainActor` HomeKit calls. This is solved with a `ResponseBox` pattern:

1. Socket handler receives request on GCD global queue
2. Creates `ResponseBox` with a `DispatchSemaphore`
3. Dispatches `Task { @MainActor in ... }` to call HomeKitManager
4. GCD thread blocks on `semaphore.wait()`
5. MainActor task completes, sets `box.result`, signals semaphore
6. GCD thread resumes, reads result, sends response over socket

---

## Event System

```
  Characteristic Change / Scene Trigger / Control Action
       │
       ▼
  HomeEventLogger.logEvent()
       │
       ├──► Append to events.jsonl
       │    ~/Library/Application Support/HomeClaw/events.jsonl
       │
       ├──► Log rotation (if file > maxSize)
       │    events.jsonl → events.jsonl.1 → events.jsonl.2 → ... (max N backups)
       │
       └──► Evaluate webhook triggers
              │
              ├── Match event type against trigger rules
              ├── Match accessory/scene IDs if specified
              │
              └──► POST to webhook URL
                   ├── Headers: Content-Type: application/json
                   │            Authorization: Bearer <token>
                   ├── Body: { event JSON }
                   │
                   └── Circuit breaker:
                       ├── 5 consecutive failures → open circuit
                       ├── 60 second reset interval
                       └── Half-open: single test request
```

Event types: `characteristic_change`, `homes_updated`, `scene_triggered`, `accessory_controlled`

---

## Persistence

| Data | Location | Format |
|------|----------|--------|
| Configuration | `~/Library/Application Support/HomeClaw/config.json` | JSON |
| Characteristic cache | `~/Library/Application Support/HomeClaw/cache.json` | JSON (SHA256 device hash, 5-min TTL) |
| Event log | `~/Library/Application Support/HomeClaw/events.jsonl` | JSONL (one event per line) |
| Socket | `/tmp/homeclaw.sock` or App Group container | Unix domain socket |

Legacy path `~/.config/homeclaw/` is auto-migrated on first access.

---

## Security & Entitlements

```
HomeClaw.entitlements:
  ├── com.apple.developer.homekit = true
  │     Required for HMHomeManager access.
  │     Only available for App Store distribution on macOS.
  │
  └── com.apple.security.application-groups = ["group.com.shahine.homeclaw"]
        Shared container for socket path between app and CLI.

homeclaw-cli.entitlements:
  └── com.apple.security.application-groups = ["group.com.shahine.homeclaw"]
        CLI needs App Group to discover socket path.

Sandbox behavior:
  ├── Debug builds:   sandbox OFF (direct filesystem access)
  └── Release builds: sandbox ON + APP_STORE compilation condition
```

---

## Key Design Decisions

1. **Single-process Catalyst** — HomeKit requires UIKit + entitlement. Rather than splitting into a daemon + UI, the entire app is Catalyst. This eliminates IPC complexity and simplifies code signing.

2. **Plugin bundle for menu bar** — `NSStatusItem` is AppKit-only. A `.bundle` with `NSPrincipalClass` loaded at runtime bridges the framework gap without requiring a separate process.

3. **Unix socket protocol** — Simple, fast, no authentication needed (local-only). JSON-newline framing is trivially parseable from any language.

4. **Characteristic cache** — HomeKit's `readValue()` is async and slow over Bluetooth. The cache provides instant reads for the menu bar and CLI, with real-time updates via `HMAccessoryDelegate`.

5. **Optimistic menu updates** — The menu bar patches its data model immediately on user action, before HomeKit confirms. This makes toggles feel instant.

6. **LLM-optimized device map** — The `device-map` command produces a structured representation with semantic types, aliases, and natural-language descriptions specifically designed for AI agent consumption.

7. **Webhook circuit breaker** — Prevents a failing webhook endpoint from blocking the event pipeline. Opens after 5 failures, retests after 60 seconds.
