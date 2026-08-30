# mcp-home

House MCP server (stdio, newline JSON-RPC): lights, Pixel Clock alarms and
timers, media keys, launching desktop apps, shutting down the PC, and mari
activity commands.

Moved out of `ada/back/mcp/home` so any MCP client can use the same tools.
Ada still owns `listen` and `control_browser` itself.

## Tools

| Tool | Description |
|------|-------------|
| `desk_light` | Govee desk light |
| `pc_light_color` | PC light color |
| `alarm__create` | Create a Pixel Clock alarm, then open the alarms page |
| `alarm__list` | Next scheduled alarm |
| `alarm__update` | Update an alarm |
| `alarm__delete` | Delete an alarm |
| `alarm__show` | Open Clock alarms |
| `alarm__snooze` | Snooze ringing alarm |
| `timer__create` | Start a Pixel Clock timer, then open the timers page |
| `timer__dismiss` | Dismiss a timer |
| `timer__show` | Open Clock timers |
| `media_control` | playerctl + system volume |
| `current_time` | Local date/time |
| `run_application` | Launch a desktop app via `~/launch.sh` |
| `shutdown` | Run `~/shutdown.sh` (desk light off, then `sudo poweroff`) |
| `run_activity_command` | Run a mari activity command (if YAML is present) |

## Env

- `ADA_ACTIVITY_DIR` — directory of mari activity YAML (default `/workspace/mari/activity`)
- `HOME` — used to find `~/launch.sh`

Depends on `/workspace/agl-common` for Govee and Pixel Clock implementations.

## Run

```bash
cd /workspace/mcp-home && bun install
bun /workspace/mcp-home/server.coffee
```

Ada's back spawns this as Angela MCP `home` (`prefix: false`).
