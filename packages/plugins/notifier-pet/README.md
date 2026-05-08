# notifier-pet

Bridges AO orchestrator events to a separate macOS pet overlay app (AOPet) over a local Unix socket.
Each event is delivered as one newline-terminated JSON line on a fresh connection — no pooling.

## Setup

```yaml
defaults:
  notifiers:
    - desktop
    - pet

notifiers:
  pet:
    plugin: pet
    # All fields below are optional.
    socketPath: ~/.agent-orchestrator/pet.sock
    enabled: true
    autoLaunch: true
    # appPath: /Applications/AOPet.app/Contents/MacOS/AOPet
```

When `autoLaunch` is enabled (the default) and you are running on macOS,
the plugin attempts to start the AOPet binary the first time it is
instantiated (i.e. once per `ao start`). If the binary isn't found,
the notifier still writes to the socket — if AOPet starts later it will
receive new events normally.

## Config options

| Option | Default | Description |
|--------|---------|-------------|
| `socketPath` | `~/.agent-orchestrator/pet.sock` | Unix socket the AOPet app listens on. Leading `~` is expanded. |
| `enabled` | `true` | When `false`, the plugin is a no-op (no socket writes, no auto-launch). |
| `autoLaunch` | `true` | When `false`, the plugin never spawns AOPet — manage it yourself. |
| `appPath` | (none) | Explicit path to the AOPet binary. Highest priority during resolution. |

## AOPet binary resolution (macOS only)

When `autoLaunch` is on, the plugin searches in this order and uses the
first **existing, executable file** it finds:

1. `appPath` from config
2. `AOPET_PATH` environment variable
3. `/Applications/AOPet.app/Contents/MacOS/AOPet`
4. `~/Applications/AOPet.app/Contents/MacOS/AOPet`
5. `/usr/local/bin/AOPet`
6. `<cwd>/apps/pet-mac/.build/release/AOPet`
7. `<cwd>/apps/pet-mac/.build/debug/AOPet`

A best-effort PID lockfile at `~/.agent-orchestrator/aopet.pid` lets
subsequent `ao start` invocations skip launch when an AOPet from an
earlier run is still alive.

Auto-launch is **macOS-only** — on other platforms the launch path is
skipped silently. The notifier itself still works on any platform if
something is listening on the configured socket.

## Wire format

One newline-terminated JSON line per event:

```json
{
  "v": 1,
  "kind": "event",
  "event": {
    "id": "...",
    "type": "session.spawned",
    "priority": "urgent|action|warning|info",
    "sessionId": "...",
    "projectId": "...",
    "timestamp": "ISO8601",
    "message": "...",
    "data": {}
  },
  "actions": [{ "label": "Open PR", "action": "https://..." }]
}
```

The `actions` array is omitted entirely for plain `notify()` calls.
For `notifyWithActions`, each action's `action` string prefers
`callbackEndpoint` over `url` so the pet app always has a single
unambiguous target to fire.

## Failure behavior

The notifier is best-effort and never throws or blocks the orchestrator:

- Missing socket / `ECONNREFUSED` / write errors log a single warning per
  process the first time and are otherwise silenced.
- AOPet launch failures (binary not found, spawn error) log a single
  warning and continue; the orchestrator runs normally.
