# Switch Mac

Switch Mac is a native SwiftUI library and build interface for Apple silicon. It builds supported games from files you supply and opens the resulting Mac apps from internal or external storage.

## Get started

1. Use Apple silicon and macOS 26 or later for the library. Install Xcode with the Metal Toolchain to build games.
2. In this checkout, run `./launcher/setup-build-tools.sh --with-nx2apple`. Use `./launcher/setup-build-tools.sh` for the Switch2Mac backend alone. The setup uses Python 3.12 or later, a pinned NX2Apple revision, and the local .NET 10 runtime. NX2Apple also uses `glslangValidator`, `spirv-cross`, and `zstd` for its builds.
3. Run `./launcher/build.sh`. Drag `launcher/build/Switch2Mac.app` to Applications and open it. Use Build Tools in Settings to locate your checkout if it lives outside the default project folder.
4. Open Build Game to pick your own game files, a build workspace, and a destination for the game app.

The launcher uses native search, navigation, and inspector controls. Drop a built game app into the library, select a title for graphics and controller options, and use Locate to reconnect a moved app. The save tools open or back up the game's current saves. Choosing artwork changes the library icon. To embed an icon in the Finder app, use Export Portable App on a compatible original build.

## Game input and storage

| Backend | Accepted input |
|---|---|
| Switch 2 · Switch2Mac | Mario Kart World 1.0.0 with `exefs/` and `romfs/`, optionally under `base/` |
| Switch 1 · NX2Apple | Supported NSP/XCI/NSZ/XCZ packages with your own `prod.keys`, or a supported extracted game |
| Switch 2 · NX2Apple | Profiled `.nup` or an extracted tree that keeps the backend's `base/`, `updates/`, and `dlc/` layout |

Update and DLC compatibility depends on the backend, title and version. Switch2Mac's Mario Kart World profile builds the base version.

The workspace stores extraction, compiled shaders and logs. The destination stores the finished app. Put the workspace on an APFS volume with sufficient space. A first Switch2Mac build can need about 50 GB. A different destination volume needs room for a full copy of the finished bundle. When copying a game to another drive, move the entire `.app` and keep its internal layout intact.

## Standalone play

Open a finished native game app from Finder. A compatible portable export includes its runtime, icon, modules, shaders and game files. It can launch without Switch Mac, Python, or Xcode on a compatible Apple silicon Mac. The bundle's deployment target and shader chain determine which macOS versions it supports. Local builds use ad-hoc signing.

On the same Mac, the library and portable game app use the title's settings and save folders under `~/Library/Application Support/nxnative/<TITLE-ID>/`. Moving the app to another Mac creates or uses that Mac's own settings and saves. Use the save tools to copy progress separately.

For the M2 Air performance runtime, see [the runtime source notes](../tools/performance/README.md).
