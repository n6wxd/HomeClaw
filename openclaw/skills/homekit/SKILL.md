---
description: |
  Control HomeKit smart home accessories via the homekit-cli command-line tool.
  Also includes reference data for accessory categories, characteristics, and value formats.
  This skill should be used when the user wants to:
  - Turn lights on or off, set brightness, or change color temperature
  - Lock or unlock doors
  - Set thermostat temperature or HVAC mode
  - Run a HomeKit scene like "Good Morning" or "Movie Time"
  - Check which devices are on, off, or unreachable
  - List accessories in a room or search by name
  - Check HomeKit Bridge status or configure default home
  - Look up characteristic names, value types, ranges, or enum mappings
  Example triggers: "turn on the kitchen lights", "lock all doors",
  "set the thermostat to 72", "run the goodnight scene", "what lights are on",
  "list devices in the living room", "is the HomeKit bridge running",
  "what characteristics does a thermostat have", "what are the lock state values"
---

# HomeKit Smart Home Control

HomeKit Bridge exposes Apple HomeKit accessories via the `homekit-cli` command-line tool. The CLI communicates with the HomeKit Bridge app over a Unix domain socket at `/tmp/homekit-bridge.sock`.

## CLI Commands

The `homekit-cli` binary is the primary interface. Read commands support `--json` for raw JSON output suitable for parsing.

| Command | Arguments | Description |
|---------|-----------|-------------|
| `status` | `[--json]` | Show HomeKit Bridge status (connectivity, home/accessory counts, MCP port) |
| `list` | `[--room NAME] [--category TYPE] [--json]` | List HomeKit accessories with optional filters. Returns enriched results with `semantic_type`, `display_name`, `manufacturer`, `zone`. |
| `get` | `<name-or-uuid> [--json]` | Get detailed info about an accessory (all services and characteristics) |
| `set` | `<name-or-uuid> <characteristic> <value>` | Set a characteristic on an accessory |
| `search` | `<query> [--category TYPE] [--json]` | Search by name, room, category, semantic type, manufacturer, or aliases (e.g., "kitchen light") |
| `scenes` | `[--json]` | List all HomeKit scenes |
| `trigger` | `<scene-name-or-uuid>` | Trigger a HomeKit scene |
| `device-map` | `[--json]` | Show LLM-optimized device map with semantic types, aliases, and zone hierarchy |
| `config` | `[--default-home NAME] [--clear] [--filter-mode MODE] [--allow-accessories IDS] [--list-devices] [--json]` | View or update configuration |
| `token` | `[--rotate]` | Show or rotate the MCP bearer token |

### Output Formats

**Human-readable** (default): Compact text output for terminal use.

```bash
homekit-cli list --room "Kitchen"
# + Kitchen Light [lightbulb] in Kitchen — power=true, brightness=75
# + Kitchen Outlet [outlet] in Kitchen — power=false

homekit-cli get "Kitchen Light"
# Kitchen Light
#   Category:  lightbulb
#   Room:      Kitchen
#   Reachable: Yes
#   [Lightbulb]
#     power: true (writable)
#     brightness: 75 (writable)

homekit-cli set "Kitchen Light" brightness 50
# Set Kitchen Light.brightness = 50

homekit-cli search thermostat
# Found 2 result(s):
#   Nest Thermostat [thermostat] in Hallway
#   Ecobee [thermostat] in Living Room

homekit-cli scenes
#   Good Morning [builtin] — 5 action(s)
#   Movie Time [user] — 3 action(s)

homekit-cli status
# HomeKit Bridge v?
#   HomeKit:     Connected
#   Homes:       2
#   Accessories: 192
#   MCP Server:  http://127.0.0.1:9090/mcp
#   CLI Socket:  /tmp/homekit-bridge.sock
```

**JSON** (`--json`): Raw JSON for scripting and parsing. Returns the full response data from the socket.

## Common Workflows

### Turn on a light

```bash
# Find the light
homekit-cli search "kitchen light"

# Turn it on (by name or UUID)
homekit-cli set "Kitchen Light" power true
```

### Set brightness

```bash
homekit-cli set "Kitchen Light" brightness 50
```

### Lock all doors

```bash
# Find all locks
homekit-cli search lock --category lock

# Lock each one
homekit-cli set "Front Door" lock_target_state locked
homekit-cli set "Back Door" lock_target_state locked
```

### Check temperature

```bash
# Find thermostats
homekit-cli search thermostat --category thermostat

# Get detailed readings
homekit-cli get "Nest Thermostat"
# Look for current_temperature in the output
```

### Set thermostat

```bash
# Set target temperature (in user's configured unit)
homekit-cli set "Nest Thermostat" target_temperature 72

# Set mode
homekit-cli set "Nest Thermostat" target_heating_cooling auto
```

### Run a scene

```bash
# List available scenes
homekit-cli scenes

# Trigger by name
homekit-cli trigger "Movie Time"
```

### List accessories by room

```bash
homekit-cli list --room "Living Room"
```

### Switch active home

```bash
# View current config (shows active home)
homekit-cli config

# Set active home
homekit-cli config --default-home "My Home"

# Reset to primary home
homekit-cli config --clear

# Show all devices with filter status
homekit-cli config --list-devices
```

### Get the device map

```bash
# Human-readable tree view
homekit-cli device-map

# Full JSON with semantic types, aliases, and state
homekit-cli device-map --json
```

The device map returns devices organized by home/zone/room with:
- `semantic_type`: Functional classification (`lighting`, `climate`, `security`, etc.)
- `display_name`: Room-prefixed name when duplicates exist
- `aliases`: Search terms like "kitchen light", "overhead in kitchen"
- `controllable`: Writable characteristics (e.g., `["power", "brightness"]`)
- `state_summary`: One-line state: "on 75%", "72°F heating", "locked"

**Use `device-map` first** when you need to understand the device landscape. It identifies switches that actually control lights (Lutron/Caseta) and resolves name collisions.

### Scripting with JSON

```bash
# Get all lights that are on
homekit-cli list --category lightbulb --json | python3 -c "
import json, sys
data = json.load(sys.stdin)
lights = [a for a in data if a.get('state',{}).get('power')=='true']
for l in lights:
    print(f\"{l['room']:20s} {l['name']} — brightness: {l['state'].get('brightness','?')}%\")
"
```

## Direct Socket Fallback

If `homekit-cli` is not available, you can talk directly to the HomeKit Bridge helper over the Unix socket.

**Pattern**: Send a JSON command with newline delimiter via `nc`, save to a temp file, then parse:

```bash
echo '{"command":"<COMMAND>","args":{<ARGS>}}' | nc -U /tmp/homekit-bridge.sock > /tmp/hk-result.json 2>/dev/null
python3 -c "import json; d=json.load(open('/tmp/hk-result.json')); print(json.dumps(d['data'], indent=2))"
```

### Socket Commands

| Command | Args | Description |
|---------|------|-------------|
| `status` | — | Bridge connectivity, home count, accessory count, cache info |
| `list_homes` | — | List all homes with room and accessory counts. Shows `is_selected` for active home. |
| `list_accessories` | `room?` | List accessories in active home (filtered by config) |
| `list_all_accessories` | — | List all accessories (ignores filter config) |
| `get_accessory` | `id` (required) | Full detail with all services and characteristics |
| `control` | `id`, `characteristic`, `value` (all required) | Set a characteristic value |
| `search` | `query` (required), `category?` | Search by name, room, category, semantic type, manufacturer, or aliases |
| `device_map` | — | LLM-optimized device map with semantic types, aliases, and zone hierarchy |
| `list_rooms` | — | List rooms and their accessories |
| `list_scenes` | — | List all scenes |
| `trigger_scene` | `id` (required) | Execute a scene by UUID or name |
| `get_config` | — | Current config plus home list and accessory counts |
| `set_config` | `default_home_id?`, `accessory_filter_mode?`, `allowed_accessory_ids?`, `temperature_unit?` | Update config. `default_home_id` sets the active home. |
| `refresh_cache` | — | Force-refresh the accessory characteristic cache |

## Error Handling

| Error | Cause | Resolution |
|-------|-------|------------|
| "HomeKit Bridge is not running" | App not launched or socket missing | Launch HomeKit Bridge.app |
| "Connection failed" | Socket exists but app not responding | Restart the app |
| 0 homes / `ready: false` | Missing entitlement or iCloud not signed in | Check codesign entitlements and iCloud |
| "Accessory not found" | Wrong UUID or name | Use `search` to find the correct identifier |
| "Characteristic not writable" | Trying to set a read-only characteristic | Check the writable column in the characteristics tables below |
| Values show `"nil"` | Accessory is unreachable or bridge hasn't synced | Check `reachable` field; unreachable devices return `nil` for all state values |

## Configuration

Config file: `~/.config/homekit-bridge/config.json`

| Setting | Values | Default |
|---------|--------|---------|
| `default_home_id` | Home name or UUID | Primary home |
| `accessory_filter_mode` | `all`, `allowlist` | `all` |
| `allowed_accessory_ids` | Array of UUIDs | `[]` |
| `temperature_unit` | `fahrenheit`, `celsius`, `auto` | `auto` (uses system locale) |

Use `homekit-cli config` to view and modify settings. The `--list-devices` flag shows all accessories with their allowed/filtered status. When `temperature_unit` changes, the characteristic cache is automatically invalidated and refreshed.

---

## Accessory Categories

Categories are mapped from Apple's `HMAccessoryCategoryType` constants. Homebridge devices that don't map to a known category will show the raw UUID string.

| Category | Description |
|----------|-------------|
| `lightbulb` | Lights, bulbs, LED strips |
| `switch` | Generic on/off switches |
| `outlet` | Smart plugs and outlets |
| `fan` | Ceiling fans, standing fans |
| `thermostat` | HVAC thermostats |
| `lock` | Door locks |
| `door` | Door sensors/controllers |
| `garage_door` | Garage door openers |
| `window` | Window actuators |
| `window_covering` | Blinds, shades, curtains |
| `sensor` | Temperature, humidity, motion, contact sensors |
| `security_system` | Home security systems |
| `programmable_switch` | Buttons, remote controls |
| `air_purifier` | Air purifiers and filters |
| `camera` | IP cameras |
| `doorbell` | Video doorbells |
| `speaker` | Speakers, cameras with audio (UniFi Protect cameras show as speaker) |
| `valve` | Water valves, sprinkler controllers (Water Shutoff, Eve Aqua) |
| `bridge` | HomeKit bridges (Homebridge, Hue Bridge, etc.) |
| `range_extender` | Network range extenders |

## Characteristics by Category

### Lightbulb
| Characteristic | Type | Range | Writable |
|---------------|------|-------|----------|
| `power` | boolean | true/false | Yes |
| `brightness` | integer | 0-100 | Yes |
| `hue` | float | 0-360 | Yes |
| `saturation` | float | 0-100 | Yes |
| `color_temperature` | integer | 140-500 (mireds) | Yes |

### Thermostat
| Characteristic | Type | Range | Writable |
|---------------|------|-------|----------|
| `current_temperature` | string | Formatted with unit, e.g. `"71°F"` | No |
| `target_temperature` | string | Formatted with unit, e.g. `"70°F"`. Set with plain number in user's unit. | Yes |
| `current_heating_cooling` | enum | 0-3 | No |
| `target_heating_cooling` | enum | 0-3 | Yes |
| `temperature_units` | enum | 0=Celsius, 1=Fahrenheit | No |
| `current_humidity` | float | 0-100 | No |
| `target_humidity` | float | 0-100 | Yes |

> **Note**: Temperature values are returned as formatted strings with the user's preferred unit (e.g., `"71°F"` or `"22°C"`). This applies to all `current_temperature` readings across all accessory types (thermostats, sensors, leak detectors, etc.).

### Lock
| Characteristic | Type | Range | Writable |
|---------------|------|-------|----------|
| `lock_current_state` | enum | 0-3 | No |
| `lock_target_state` | enum | 0-1 | Yes |

### Door / Garage Door
| Characteristic | Type | Range | Writable |
|---------------|------|-------|----------|
| `current_door_state` | enum | 0-4 | No |
| `target_door_state` | enum | 0-1 | Yes |
| `obstruction_detected` | boolean | true/false | No |

### Fan
| Characteristic | Type | Range | Writable |
|---------------|------|-------|----------|
| `active` | boolean | true/false | Yes |
| `rotation_speed` | float | 0-100 | Yes |
| `rotation_direction` | enum | 0=clockwise, 1=counter | Yes |
| `swing_mode` | enum | 0=disabled, 1=enabled | Yes |
| `current_fan_state` | enum | 0-2 | No |
| `target_fan_state` | enum | 0=manual, 1=auto | Yes |

### Window Covering
| Characteristic | Type | Range | Writable |
|---------------|------|-------|----------|
| `current_position` | integer | 0-100 | No |
| `target_position` | integer | 0-100 | Yes |
| `position_state` | enum | 0=decreasing, 1=increasing, 2=stopped | No |

### Sensor (common)
| Characteristic | Type | Range | Writable |
|---------------|------|-------|----------|
| `motion_detected` | boolean | true/false | No |
| `contact_state` | enum | 0=detected, 1=not detected | No |
| `current_temperature` | float | varies | No |
| `current_humidity` | float | 0-100 | No |
| `current_light_level` | float | 0.0001-100000 (lux) | No |
| `battery_level` | integer | 0-100 | No |
| `low_battery` | boolean | true/false | No |
| `charging_state` | enum | 0-2 | No |

## Enum Value Mappings

### Heating/Cooling State
| Value | Name | Writable as |
|-------|------|-------------|
| 0 | Off | `off` or `0` |
| 1 | Heat | `heat` or `1` |
| 2 | Cool | `cool` or `2` |
| 3 | Auto | `auto` or `3` |

### Lock State
| Value | Name | Writable as |
|-------|------|-------------|
| 0 | Unsecured | `unlocked`, `unsecured`, or `0` |
| 1 | Secured | `locked`, `secured`, or `1` |
| 2 | Jammed | (read-only) |
| 3 | Unknown | (read-only) |

### Door State
| Value | Name | Writable as |
|-------|------|-------------|
| 0 | Open | `open` or `0` |
| 1 | Closed | `closed` or `1` |
| 2 | Opening | (read-only) |
| 3 | Closing | (read-only) |
| 4 | Stopped | (read-only) |
