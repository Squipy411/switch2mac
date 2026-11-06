# switch2mac

Native Mac builds of Nintendo Switch 2 games on Apple silicon, made from **your own dump** on your own Mac.

switch2mac is a fork of [nxnative](https://github.com/seedds/nxnative), carried forward for Switch 2: NVN2 graphics on Metal, Switch 2 mesh and task shaders, movies, many shader translator fixes, and the performance work that took the first game from 20 to about 58 fps. It is not an emulator: the game's own ARM64 code runs directly on the Mac, rewritten so its system calls land in a native runtime, and every shader is translated to Metal ahead of time.

**Mario Kart World 1.0.0** is the first game built and tuned this way. The kit is laid out for more: each game is a folder under [`games/`](games), and [docs/porting.md](docs/porting.md) explains how to bring up the next one, with everything learned so far. You can follow it yourself in Terminal, or hand it to an AI coding assistant ([AGENTS.md](AGENTS.md)).

| Game | Version | Status | On an M1 Max |
|---|---|---|---|
| Mario Kart World | 1.0.0 | Plays start to finish: menus, Grand Prix, free roam, traffic, movies | ~58 fps in races (Performance mode), 2560x1440 |
| Mario Kart World | later updates | **Untested** | — |
| Your game? | | [docs/porting.md](docs/porting.md) | |

> This repository holds no game content. You need a dump of a game you own; what the build makes from it must not be shared. See [LEGAL.md](LEGAL.md).

## Switch Mac library

The [Switch Mac launcher](launcher/README.md) provides a native library, per-game settings, save backups, and a guided build with separate workspace and app destinations. Finished game apps launch directly from Finder on compatible Apple silicon Macs.

## What you get (Mario Kart World)

`Mario Kart World.app`: a normal, double-clickable Mac app that carries everything it needs (it keeps working after you delete the build folder).

- Opens straight into the game, windowed or full screen.
- **Key 1**: the performance overlay (top right). Compact (FPS + resolution) → detailed (30-second FPS graph, GPU time, frame time, CPU, memory, the game's frame pacing) → off.
- **Key 2**: the settings panel (Esc closes it). Display, Performance and Controls; the overlay and full screen change at once, the rest at the next launch.
- Controllers (Xbox, PlayStation, Switch Pro and others macOS recognises) and the keyboard.
- Saves in `~/Library/Application Support/nxnative/0400C3F00006E000/save`, the log in `~/Library/Logs/nxnative/0400C3F00006E000.log`.

## What you need

- A Mac with Apple silicon and **macOS 26 or later** (the runtime draws with Metal 4, new in macOS 26). The app is built for the macOS version of the Mac that builds it (tested: M1 Max, 64 GB, macOS 26.6; reported working: M4 Pro, 24 GB, macOS 26.5). The game uses about 13-16 GB of memory.
- **Xcode** with the Metal toolchain (Xcode → Settings → Components), and its command line tools.
- **.NET 10 SDK** ([dot.net](https://dot.net)): the shader translator runs on it.
- **Python 3.12 or newer** (python.org or Homebrew).
- About 50 GB free disk space during the build (the game image is 22 GB; on the same APFS disk the app shares it instead of copying it).
- Your dump of Mario Kart World 1.0.0: a folder with `exefs/` (main, main.npdm, sdk, subsdk0, rtld) and `romfs/`, or `base/exefs` and `base/romfs`. Already extracted, as dump tools write it: switch2mac needs no keys and decrypts nothing.

## Build it

```bash
git clone https://github.com/azmasm/switch2mac.git
```

```bash
cd switch2mac
```

```bash
./switch2mac.py setup
```

```bash
./switch2mac.py build "/path/to/your/dump"
```

```bash
./switch2mac.py install
```

`setup` makes a Python environment in `.venv` and checks Xcode, Metal and .NET. `build` does everything else, writing only into `./work`:

1. **Game files**: the code modules and one RomFS image (dump-tool leftovers such as `.listing` files are left out).
2. **Code**: rewrites the game's modules so they run on the Mac.
3. **Shaders**: takes the shaders from the game's archives and the ones it builds at run time from the dump, lowers them, translates them to Metal and compiles them. The long step: 10-20 minutes the first time, using every core.
4. **Host** (the native runtime) and **app**.

`install` moves the app to `/Applications`, replacing an older one.

### The first start waits

After every install macOS scans the new 22 GB app before it lets it run: **1-3 minutes with no window and no Dock icon**. Wait; do not open it a second time. Later starts are immediate. The app is signed ad hoc (not notarized), so the very first time macOS may ask: right-click the app → Open.

### First start: a short "preparing" screen

The first launch is complete: about 320 of the game's shaders (among them all its mesh shaders for roads and ground) are not in its shader archives because the game builds them while it runs, and `build` takes them straight out of your dump (listed in `games/<game>/runtime_shaders.tsv`).

The repository also carries a **shared pipeline list** (the game profile's `pso_manifest.tsv`): the ~12,000 shaders and Metal pipelines met while playing Grand Prix, free roam and the menus. The app builds them all behind a progress screen before the first frame, once; later starts take about 10 seconds. Without it every new place stutters the first time. Places nobody has recorded yet can still stutter once.

If something still looks missing after a while (a shader the list does not cover, e.g. in a mode not tested), the app saves it; then:

```bash
./switch2mac.py refresh
```

```bash
./switch2mac.py install
```

## Settings (key 2)

| Setting | Default | What it does |
|---|---|---|
| Performance overlay | Compact | Same as key 1 |
| Display mode | Window | Window or full screen |
| Console mode | Docked | What the game is told |
| Upscaling | Standard | MetalFX for the final picture on large screens |
| Performance mode | On | Skips one environment-reflection update (~4 ms a frame); off = full reflections, a few fps lower |
| Encode thread | On | Encodes GPU work on its own thread (~10 fps) |
| Frame buffering, Metal 4 pipelines, Pipeline prebuild | tested defaults | Advanced |
| Rumble, strength, cutoff | On | Controller rumble |

## Controls

Controllers map by position (right button = A, bottom = B, top = X, left = Y; Nintendo pads by label). Keyboard: WASD left stick, arrow keys D-pad, J K U I = A B X Y, Q E = L R, Z C = ZL ZR, Return = +, Tab = −, F / G stick presses, 1 overlay, 2 settings, ⌃⌘F full screen, ⌘Q quit. The mouse is the touchscreen.

## Other game versions

Only 1.0.0 is tested. `build` checks the dump's build ID and stops on any other version, because the profile ([`nxnative/dm/games/0400C3F00006E000/game.tsv`](nxnative/dm/games/0400C3F00006E000/game.tsv)) names the exact modules and build IDs it rewrites. To try an update, see [games/mario-kart-world/README.md](games/mario-kart-world/README.md#other-versions); expect new problems.

## Problems

- The log: `~/Library/Logs/nxnative/0400C3F00006E000.log` (`.prev.log` is the run before). Lines with `[RED]` are things the runtime does not handle.
- Stutter in a new place: a pipeline the shared list lacks, built once (then share it: see Contributing). Anything still missing: `refresh` (above).
- Known issues: [games/mario-kart-world/README.md](games/mario-kart-world/README.md#known-issues).
- When you report a problem, attach the log and a screenshot, never game files, shader dumps or the app.

## How it works

The runtime is [nxnative](https://github.com/seedds/nxnative): it loads the game's modules into memory, rewrites their system calls and SDK functions into calls to native code (file system, audio, input, threads, time), and implements NVN2, the Switch 2 graphics API, on Metal. Switch 2 shaders (NVIDIA Ampere code) are lowered to Maxwell code by `nx2_lower`, translated by a modified Ryujinx shader translator into Metal Shading Language, and compiled into Metal libraries; Switch 2 mesh and task shaders become Metal object and mesh shaders. The story of getting Mario Kart World from a black screen to 58 fps: [docs/mario-kart-world.md](docs/mario-kart-world.md).

## Repository layout

| Path | What |
|---|---|
| `switch2mac.py` | setup, build, run, refresh, install |
| `games/<game>/` | one folder per game: `game.json` (title ID, name, version), the app's settings (`launcher.py`, `env.txt`), the run-time shader list (`runtime_shaders.tsv`) and notes |
| `tools/` | the shared pipeline list helper (`pipelines.py`), porting helpers: run-time shader finder, NSO disassembly helper, pass tracer, performance summary |
| `nxnative/` | the runtime and tools: nxnative with switch2mac's Switch 2 changes (upstream's iOS app sources are kept because the shader tools share them) |
| `nxnative/dm/games/<title ID>/` | the game profile: build IDs, memory layout, shader tables |
| `docs/` | [porting.md](docs/porting.md) (bringing up a game), [mario-kart-world.md](docs/mario-kart-world.md) (how the first port was made) |
| `AGENTS.md` | notes for AI coding assistants |
| `CHANGELOG.md` | what changed, release by release |

## Contributing

**No code needed: share your pipelines.** After playing places the list may lack (other courses, modes, battle), run `./tools/pipelines.py new` and attach the file it writes (`pipelines-<title ID>.tsv`) to an issue or pull request. It holds shader keys and render settings only, no game data or personal information. Maintainers add it with `./tools/pipelines.py merge <file>`. The idea comes from [MacNativeGames](https://github.com/ly05010419/MacNativeGames)' shared shader list, by ly05010419.

Other improvements are welcome too: speed-ups, fixes, testing on other Macs, game updates and new games. Open an issue with the log and screenshots, or a pull request. Give speed-ups an off switch and check that the picture is unchanged. Never attach game files, shader dumps, Metal libraries, saves or built apps.

## Licences and credits

MIT, except `nxnative/dm/gfx/tools/nx2_lower/` (GPL-3.0-or-later) and the third-party code in `nxnative/dm/third_party/`. Built on nxnative by seedds, the Switch 2 patch series by potentialad9091, Eglantine's shader lowering and Ryujinx's shader translator; the shared pipeline list and the overlay / settings panel design follow MacNativeGames by ly05010419. Details: [NOTICE.md](NOTICE.md), [LEGAL.md](LEGAL.md).
