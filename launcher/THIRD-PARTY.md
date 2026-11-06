# Third-party components

## NX2Apple and nxnative

The launcher calls the separately installed NX2Apple/nxnative build script for profiled Switch 1 titles and selected profiled Switch 2 titles. The local checkout is under `.tools/nx2apple`; it is a build-time/runtime dependency and is not copied into this launcher source tree. NX2Apple is MIT licensed. Its full license text is retained at `Licenses/NX2Apple-MIT.txt`.

The launcher supervisor follows the documented command-line interface (`--platform mac-app`, `--progress json`, `--work-dir`, `-o`, and `--app-name`). It does not copy NX2Apple source code. NX2Apple's own third-party licenses remain with its checkout and the synced engine.

## switch2mac

The Switch2Mac backend is the separately checked out upstream repository containing this launcher folder. The launcher invokes its existing `switch2mac.py` build command; it does not copy or vendor that engine.

## Artwork

The launcher ships its own app icon. The portable packer can render an original racing icon or embed artwork supplied by the user. The source release excludes game artwork and extracted assets.
