# AOPet — macOS pet overlay for Agent Orchestrator

A small native macOS companion that sits on top of your other windows and
reflects the state of the AI agents Agent Orchestrator (AO) is running. One
pet per project: as sessions move through `working → pr_open → merged`, the
pet's animation changes; when an agent needs your attention it bounces, flashes
or shows a thought bubble.

Inspired by Codex Pets.

## Requirements

- macOS 13 (Ventura) or newer
- Swift 5.9+ toolchain (Command Line Tools is enough to build and run)
- Full Xcode is required only to run the XCTest suite (`swift test`). Without
  Xcode you can run the embedded self-test instead — see below.
- Agent Orchestrator running locally with the dashboard on `http://localhost:3001`

## Build

```bash
cd apps/pet-mac

# Library + executable
swift build

# Optimized release build
swift build -c release
```

The built binary lives at `.build/debug/AOPet` (or `.build/release/AOPet`).

To produce a `.app` bundle for distribution use `xcodebuild` with a generated
`xcodeproj` (`swift package generate-xcodeproj`) or wrap the binary yourself.

## Run

```bash
swift run AOPet
```

The pet windows appear immediately. They will stay empty until either:

- the AO dashboard is reachable on `http://localhost:3001` (steady-state
  polling discovers projects with sessions), **or**
- the notifier-pet plugin connects to AOPet's socket at
  `~/.agent-orchestrator/pet.sock` and pushes events. AOPet itself owns
  (binds and listens on) that socket — see "Event reactions" below.

If both sources are unavailable the app will not crash — it logs the failure
once per category and keeps trying in the background. Bring either source up
and the pet recovers without restart.

## Test

The canonical test target is XCTest:

```bash
swift test
```

This requires full Xcode (XCTest framework). On a machine with only Command
Line Tools, run the equivalent assertions via the embedded self-test instead:

```bash
swift run AOPet --self-test
```

Both paths cover:

- JSON decoding of `/api/sessions` and the socket envelope (including unknown
  enum values and missing optional fields)
- The state aggregator (worst-state picker, project grouping, project-name
  fallback)
- Sprite loader (frame counts, wrap-around indexing, missing sets)

## What it does

### State sources

Two concurrent inputs drive the pet:

| Source       | Cadence    | Used for                          |
| ------------ | ---------- | --------------------------------- |
| HTTP poll    | 5s         | Steady-state mood per project     |
| Unix socket  | event-driven | One-shot reactions + bubbles    |

#### Steady state — `GET http://localhost:3001/api/sessions`

The dashboard returns a JSON object with a `sessions` array (each carrying
`id`, `projectId`, `status`, `activity`) and an `orchestrators` array (each
carrying `projectId` and `projectName`). AOPet groups sessions by `projectId`,
picks the highest-priority mood for each project, and renders one window per
project that has at least one session.

State → mood mapping (worst wins):

| Trigger                                          | Mood       | Visual                          |
| ------------------------------------------------ | ---------- | ------------------------------- |
| any session `waiting_input` / `needs_input`      | `alert`    | Wide eyes + red clock bubble    |
| any session `ci_failed`/`stuck`/`blocked`/`errored` | `sad`   | Frown + red exclamation         |
| any session `pr_open`/`approved`/`mergeable`     | `happy`    | Smile + green checkmark         |
| any session actively working                     | `working`  | Walking / typing animation      |
| all sessions idle/done/merged/unknown            | `sleeping` | Closed eyes + floating Z        |
| no sessions for project                          | (hidden)   | Window removed                  |

Future status / activity values not in the contract decode as `unknown` and
fall through to `sleeping` rather than crashing.

#### Event reactions — `~/.agent-orchestrator/pet.sock`

AOPet binds and listens on `~/.agent-orchestrator/pet.sock` on launch
(creating `~/.agent-orchestrator/` if needed and unlinking any stale file
at the path). The companion notifier plugin (`packages/plugins/notifier-pet`,
owned by a parallel work stream) connects as a client and writes one JSON
envelope per line:

```json
{
  "v": 1,
  "kind": "event",
  "event": {
    "id": "evt_abc",
    "type": "pr_merged",
    "priority": "urgent | action | warning | info",
    "sessionId": "ses_…",
    "projectId": "proj_…",
    "timestamp": "2026-05-07T10:00:00Z",
    "message": "PR #42 merged",
    "data": { "...": "..." }
  },
  "actions": [
    { "label": "Open PR", "action": "open:https://github.com/x/y/pull/42" }
  ]
}
```

Wire-contract notes:

- Lines are `\n`-delimited; the listener splits on `0x0A` and decodes one
  envelope per line. Empty lines are skipped.
- Only `kind == "event"` envelopes are surfaced; other kinds are silently
  ignored to leave room for future framing.
- `sessionId`, `projectId`, `timestamp`, and `actions` are optional. Events
  with no `projectId` are broadcast to every visible pet.
- Unknown `priority` values decode as `unknown` and render with the default
  info treatment (small bounce, neutral bubble).

Reaction by priority:

| Priority | Animation | Bubble tint |
| -------- | --------- | ----------- |
| urgent   | flash     | red         |
| action   | jump      | blue        |
| warning  | shake     | orange      |
| info     | bounce    | dark grey   |

### Window behaviour

Each pet window is a borderless `NSWindow` configured as:

- `level = .floating` (always-on-top)
- `collectionBehavior = [.canJoinAllSpaces, .stationary]` (visible across all
  Spaces / mission control)
- `ignoresMouseEvents = false` so right-click and drag work
- `isMovableByWindowBackground = true` — drag the pet to reposition

Windows are auto-tiled in the top-right of the main screen's visible frame
when first created, and per-project positions are persisted to UserDefaults
(`pet.position.<projectId>`) so they reopen where you left them.

### Right-click menu

- **Hide _project_ pet** — closes this pet and remembers the choice
  (`pet.hidden.<projectId>` in UserDefaults). Re-enable by clearing the
  default or running `defaults delete dev.composio.aopet pet.hidden.<id>`.
- **Switch sprite** — cycles through bundled sprite sets (currently only
  `oneko`; drop additional directories under `Resources/sprites/` to add
  variants). Choice persists across launches.
- **Quit AOPet** — terminates the app.

## Project layout

```
apps/pet-mac/
├── Package.swift                 # SwiftPM, macOS 13+, Swift 5.9
├── README.md
├── NOTICE                        # third-party asset attributions
├── scripts/
│   └── generate_sprites.py       # crops oneko.gif → per-mood PNG frames
├── Sources/AOPet/
│   ├── App/                      # main, AppDelegate, embedded self-test
│   ├── Net/                      # HTTP poller, socket listener, one-shot logger
│   ├── State/                    # wire models + aggregator
│   ├── Sprites/                  # sprite loader / SpriteSet
│   ├── Windowing/                # NSWindow, layout, NSView, controller, overlay
│   └── Resources/sprites/oneko/{mood}_{frame}.png
└── Tests/AOPetTests/             # XCTest target (requires Xcode)
```

## Sprites

The bundled cat sprite is **Oneko** (Naoshi Ikeya, 1989), distributed by
[adryd325/oneko.js](https://github.com/adryd325/oneko.js) under the MIT
license. See [`NOTICE`](NOTICE) for full attribution and the upstream
license text.

`scripts/generate_sprites.py` fetches the canonical 256×128 atlas
(`oneko.gif`), crops the named frames per oneko.js's `spriteSets` table,
and writes per-mood PNGs under `Resources/sprites/oneko/`. Re-run it
whenever the upstream atlas changes — there is no build-time fetch.

### State → oneko frame mapping

| AO mood    | Oneko frames                     | Frames | Cadence | Overlay  |
| ---------- | -------------------------------- | ------ | ------- | -------- |
| `working`  | walk-east (`E[0..1]`)            | 2      | 8 fps   | —        |
| `alert`    | scratch-self (`scratchSelf[0..2]`)| 3      | ~6 fps  | —        |
| `happy`    | `idle` ↔ `tired` (subtle blink)  | 2      | 2 fps   | green ✓  |
| `sad`      | `alert` ↔ `idle` (stressed pose) | 2      | ~2.5 fps | red `!` |
| `sleeping` | `sleeping[0..1]` (Z's)           | 2      | 1 fps   | —        |

The oneko sheet does not have a unique pose for "happy" or "sad"; those
moods reuse the closest visual frame and rely on a small badge overlay
drawn over the sprite (`MoodOverlayView`) for disambiguation. See
`scripts/generate_sprites.py` `MOOD_TO_FRAMES` for the source of truth.

The sprite loader upscales the 32×32 source frames to 64×64 with
nearest-neighbor interpolation so the pixel art reads crisply on Retina
displays. Adding a new sprite set is just a directory under
`Resources/sprites/<setName>/` with `{mood}_{frame}.png` files — register
the directory name in `SpriteLoader.availableSets`.

## Graceful degradation

| Source       | If unavailable                          |
| ------------ | --------------------------------------- |
| HTTP polling | Logs `poll.network` once, keeps polling |
| Socket       | Logs `sock.bind`/`sock.listen`/`sock.accept` once on failure, retries with capped backoff (max 30s) |

Each error tag is logged to `os.Logger` exactly once per process. When a
connection recovers, the tag is cleared so a future failure logs again — this
way you'd notice a flapping connection without being spammed by a steady one.
