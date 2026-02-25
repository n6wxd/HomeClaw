---
description: |
  Control HomeKit smart home accessories via homekit-cli.
  Use when the user asks to control lights, locks, thermostats, fans, blinds,
  scenes, or check device/sensor status.
  Examples: "turn off the stairs lights", "lock the front door", "what's the temperature",
  "run the movie scene", "close the blinds", "is the garage door open"
---

# HomeKit Control

## Golden Rule: Device Map First

**Before your first HomeKit action in a session, read `memory/homekit-device-map.json`.**

This cached device map has every device's UUID, name, display_name, aliases, room, zone, semantic type, controllable characteristics, and last-known state. Use it to resolve what the user means before acting.

**Refresh the cache** periodically or when devices may have changed:
```bash
homekit-cli device-map --json > memory/homekit-device-map.json
```

## Resolving What the User Means

1. Match user's words against `name`, `display_name`, `aliases`, and `room` from the cached map
2. If ambiguous, prefer the device in the most likely room (main living areas > basement > outdoor)
3. If still ambiguous, ask
4. **Use UUIDs for control when names collide** — `display_name` is for reading, UUIDs are for `set` commands
5. Many devices share names (12 "Overhead" lights!) — always verify room context
6. **If no match found, refresh the cache first** — devices may have been added/renamed since last snapshot:
   ```bash
   homekit-cli device-map --json > memory/homekit-device-map.json
   ```
   Then retry the match. Only tell the user "device not found" if it's still missing after refresh.

## Commands

```bash
# Discovery
homekit-cli device-map --json          # Full device tree (save to memory/)
homekit-cli search "<query>" --json    # Search by name/room/category
homekit-cli get "<name-or-uuid>" --json # Full detail on one device
homekit-cli list --room "Kitchen" --json # All devices in a room

# Control — use UUID when name is ambiguous
homekit-cli set "<name-or-uuid>" power true           # On/off
homekit-cli set "<name-or-uuid>" brightness 50        # Lights (0-100)
homekit-cli set "<name-or-uuid>" target_temperature 72 # Thermostat
homekit-cli set "<name-or-uuid>" target_heating_cooling auto  # HVAC: off/heat/cool/auto
homekit-cli set "<name-or-uuid>" lock_target_state locked     # Locks: locked/unlocked
homekit-cli set "<name-or-uuid>" target_position 100          # Blinds (0=closed, 100=open)

# Scenes
homekit-cli scenes --json              # List all scenes
homekit-cli trigger "<scene-name>"     # Run a scene
```

## Device Categories

| Category | Controls | Key Characteristics |
|----------|----------|-------------------|
| `lighting` | Lights | `power`, `brightness`, `hue`, `saturation`, `color_temperature` |
| `power` | Switches, smart plugs | `power` only — no dimming |
| `climate` | HVAC, fans | `target_temperature`, `target_heating_cooling`, `active`, `rotation_speed` |
| `door_lock` | Locks | `lock_target_state` (locked/unlocked) |
| `window_covering` | Blinds, shades | `target_position` (0-100) |
| `sensor` | Temp, humidity, motion, contact, leak | Read-only |
| `security` | Cameras, garage door | `target_door_state` (open/closed) for garage |

## Important Notes

- Many "lights" are Lutron/Caseta switches (`semantic_type: power`) — only `power`, no `brightness`
- Temperature values come back formatted: `"71°F"`. Set with plain numbers.
- `--json` on read commands gives parseable output. Always use it when processing results.
- Unreachable devices show `nil` for all state values.
- Socket is at `/tmp/homekit-bridge.sock` — if CLI fails, check that HomeClaw.app is running.

## Batch Operations

For "turn off all lights" or "lock all doors", read the cached device map, filter by semantic_type, then loop with UUIDs:

```bash
python3 -c "
import json
d = json.load(open('memory/homekit-device-map.json'))
for home in d.get('homes', []):
    for zone in home.get('zones', []):
        for room in zone.get('rooms', []):
            for dev in room.get('devices', []):
                if dev['semantic_type'] == 'lighting' and dev.get('reachable'):
                    print(dev['id'], dev.get('display_name', dev['name']), dev['state_summary'])
"
```

Then `homekit-cli set "<uuid>" power false` for each.
