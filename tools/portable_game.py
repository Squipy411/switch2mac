#!/usr/bin/env python3
"""Build a locally signed, relocatable app from an existing native game bundle."""
from __future__ import annotations

import argparse
import ctypes
import errno
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import struct
import sys
import tempfile

SCHEMA = 1
MKW_TITLE = "0400C3F00006E000"
MKW_BUILD = "9e244438c3d8ef1c703a6a85ef99c4f0"
MKW_CHAIN = "223f10d34f97"
MKW_PROFILE = {
    "id": "mkw-m2-air",
    "name": "M2 Air performance",
    "sceneResolution": [704, 396],
    "defaults": {
        "DM_RT": "0",
        "DM_OPMODE": "0",
        "DM_PRESENT_SNAP": "1",
        "DM_PRESENT_SNAP_CROP": "1",
        "DM_RT_PERIOD_STABLE": "1",
        "DM_NVN_BATCH_LAYER_CLEARS": "1",
        "DM_MKW_FAST_REFLECTIONS": "1",
        "DM_NVN_IDENTITY_VIEWS": "1",
        "DM_PRESENT_UPSCALE": "off",
        "DM_UPSCALER": "game",
        "DM_PSO_MTL4": "1",
        "DM_NVN_ENC_THREAD": "1",
        "DM_PSO_PREBUILD": "1",
        "DM_PSO_PREPARE": "1",
    },
}
ROOT = Path(__file__).resolve().parent
PLIST = "Contents/Info.plist"
RESOURCES = "Contents/Resources"
LAUNCHER = "switch2mac-portable"


def run(*args: str | Path) -> None:
    subprocess.run([str(arg) for arg in args], check=True, stdout=sys.stderr)


def clone(source: Path, destination: Path) -> None:
    libc = ctypes.CDLL(None, use_errno=True)
    clonefile = libc.clonefile
    clonefile.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint32]
    clonefile.restype = ctypes.c_int
    if clonefile(os.fsencode(source), os.fsencode(destination), 3) == 0:
        return
    code = ctypes.get_errno()
    if code in (errno.EXDEV, errno.ENOTSUP, errno.EOPNOTSUPP, errno.ENOSYS):
        raise ValueError("Packaging requires an APFS clone on the same volume as the source app. "
                         "Create the app there, then move it to its final location.") from None
    raise OSError(code, os.strerror(code), str(source), None, str(destination))


def publish_stage(source: Path, destination: Path) -> None:
    libc = ctypes.CDLL(None, use_errno=True)
    rename = libc.renamex_np
    rename.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
    rename.restype = ctypes.c_int
    # RENAME_EXCL refuses to replace any destination that appeared while signing.
    if rename(os.fsencode(source), os.fsencode(destination), 4):
        code = ctypes.get_errno()
        raise OSError(code, os.strerror(code), str(destination))


def checked_tree(app: Path) -> dict:
    if not app.is_dir() or app.suffix.lower() != ".app":
        raise ValueError(f"Expected an existing .app bundle: {app}")
    for directory, dirs, files in os.walk(app, followlinks=False):
        for name in dirs + files:
            path = Path(directory) / name
            if path.is_symlink():
                raise ValueError(f"Bundle contains a symbolic link: {path.relative_to(app)}")
            if not (path.is_dir() or path.is_file()):
                raise ValueError(f"Bundle contains a special file: {path.relative_to(app)}")
    info = plistlib.loads((app / PLIST).read_bytes())
    title = info.get("DMTitleID", "").upper()
    if not re.fullmatch(r"[0-9A-F]{16}", title):
        raise ValueError("The source is missing a valid DMTitleID.")
    resources = app / RESOURCES
    dm = resources / "dm"
    modules = info.get("DMModuleFiles")
    if not isinstance(modules, list) or not modules:
        raise ValueError("The source is missing its native module inventory.")
    for name in modules:
        if not isinstance(name, str) or Path(name).name != name or name in (".", "..") or not (dm / name).is_file():
            raise ValueError(f"Native module is missing or invalid: {name}")
    if (dm / "programs.tsv").is_file():
        raise ValueError("This packer supports single-program native game apps.")
    host = app / "Contents/MacOS/dmhost"
    if not host.is_file() or not os.access(host, os.X_OK):
        raise ValueError("The native dmhost executable is missing.")
    if not (resources / "romfs.img").is_file() or not (resources / "msl").is_dir():
        raise ValueError("The app needs a bundled RomFS image and shader directory.")
    with (resources / "romfs.img").open("rb") as image:
        header = image.read(32)
        if len(header) != 32:
            raise ValueError("The app has a truncated RomFS image.")
        magic, index_offset, index_size, entry_count = struct.unpack("<8sQQQ", header)
        size = os.fstat(image.fileno()).st_size
        if (magic != b"DMROMFS1" or not 32 <= index_offset <= size or index_size != size - index_offset or
                not 0 < entry_count <= min(0xffffffff, index_size // 24)):
            raise ValueError("The app has an unreadable RomFS image index.")
    chain = info.get("DMChain")
    if chain:
        if not isinstance(chain, str) or not re.fullmatch(r"[0-9a-f]{12}", chain):
            raise ValueError("The app has an invalid shader chain.")
        libraries = resources / "msl" / f"b-{chain}"
        if not libraries.with_suffix(".img").is_file() and not any(p.is_file() for p in libraries.glob("*.metallib")):
            raise ValueError(f"The app is missing its Metal libraries for chain {chain}.")
    return info


def manifest(info: dict) -> dict:
    return {
        "schemaVersion": SCHEMA,
        "titleID": info["DMTitleID"].upper(),
        "name": info.get("CFBundleDisplayName") or info.get("CFBundleName") or info["DMTitleID"],
        "bundleIdentifier": info.get("CFBundleIdentifier", ""),
    }


def verified_performance_module(source: Path, module: Path, info: dict) -> None:
    dm = source / RESOURCES / "dm"
    old_module = dm / "main.patched.bin"
    build_id = re.search(r"^# BUILD_ID\s+([0-9a-f]{32})$", (dm / "main.fixups.tsv").read_text(), re.M)
    if info["DMTitleID"].upper() != MKW_TITLE or info.get("DMChain") != MKW_CHAIN or not build_id or build_id[1] != MKW_BUILD:
        raise ValueError("The supplied performance module is for the verified Mario Kart World 1.0.0 build and shader chain only.")
    offsets = (0xC101D8, 0xC10300)
    if not module.is_file() or module.stat().st_size != old_module.stat().st_size:
        raise ValueError("The performance module size does not match this app.")
    changed = set()
    with old_module.open("rb") as original, module.open("rb") as candidate:
        for block in range(0, old_module.stat().st_size, 1 << 20):
            a, b = original.read(1 << 20), candidate.read(1 << 20)
            if a != b:
                changed.update(block + i for i, (old, new) in enumerate(zip(a, b)) if old != new)
                if any(not any(offset <= pos < offset + 4 for offset in offsets) for pos in changed):
                    raise ValueError("The performance module changes bytes outside the two scene-height instructions.")
        for offset in offsets:
            original.seek(offset)
            candidate.seek(offset)
            old_word = int.from_bytes(original.read(4), "little")
            new_word = int.from_bytes(candidate.read(4), "little")
            if old_word != 0x1A95B11A or new_word != 0x5280319A:
                raise ValueError(f"Unexpected original or performance height instruction at 0x{offset:x}.")


def copy_small_file(source: Path, target: Path) -> None:
    if not source.is_file() or source.is_symlink():
        raise ValueError(f"Expected a regular file: {source}")
    temporary = target.with_name(target.name + ".new")
    shutil.copyfile(source, temporary)
    os.chmod(temporary, source.stat().st_mode & 0o777)
    os.replace(temporary, target)


def install_icon(source: Path, resources: Path, info: dict) -> None:
    target = resources / "AppIcon.icns"
    if source.suffix.lower() == ".icns":
        copy_small_file(source, target)
    elif source.suffix.lower() == ".png":
        with tempfile.TemporaryDirectory(prefix="icon-", dir=resources.parent) as temp:
            iconset = Path(temp) / "AppIcon.iconset"
            iconset.mkdir()
            for side in (16, 32, 128, 256, 512):
                for scale in (1, 2):
                    suffix = "@2x" if scale == 2 else ""
                    size = str(side * scale)
                    run("/usr/bin/sips", "-z", size, size, source, "--out", iconset / f"icon_{side}x{side}{suffix}.png")
            run("/usr/bin/iconutil", "-c", "icns", "-o", target, iconset)
    else:
        raise ValueError("The icon must be an .icns or a square .png.")
    info["CFBundleIconFile"] = target.name


def install_bootstrap(staged: Path, info: dict, result: dict | None = None) -> dict:
    """Add the standalone launcher to an assembled bundle before signing."""
    result = manifest(info) if result is None else result
    result["sourceBundleIdentifier"] = result["bundleIdentifier"]
    result["bundleIdentifier"] = "org.switch2mac.portable." + result["titleID"].lower()
    resources = staged / RESOURCES
    binaries = staged / "Contents/MacOS"
    if result["titleID"] == MKW_TITLE and not info.get("CFBundleIconFile"):
        with tempfile.TemporaryDirectory(prefix="racing-icon-", dir=staged.parent) as temp:
            default_icon = Path(temp) / "Racing.png"
            run("/usr/bin/xcrun", "swift", ROOT / "portable_launcher/racing_icon.swift", default_icon)
            install_icon(default_icon, resources, info)
    previous = info.get("CFBundleExecutable")
    if isinstance(previous, str) and Path(previous).name == previous and previous not in ("", ".", "..", "dmhost", LAUNCHER):
        (binaries / previous).unlink(missing_ok=True)
    info["CFBundleExecutable"] = LAUNCHER
    info["CFBundleIdentifier"] = result["bundleIdentifier"]
    info["DMTitleID"] = result["titleID"]
    info["Switch2MacPortable"] = True
    if result.get("performanceProfile"):
        info["LSSupportsGameMode"] = True
    (staged / PLIST).write_bytes(plistlib.dumps(info, fmt=plistlib.FMT_BINARY))
    (resources / "portable.json").write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    run("/usr/bin/xcrun", "clang", "-fobjc-arc", "-O2", "-Wall", "-Wextra",
        "-mmacosx-version-min=26.0", "-framework", "Cocoa",
        ROOT / "portable_launcher/launcher.m", "-o", binaries / LAUNCHER)
    return result


def pack(args: argparse.Namespace) -> dict:
    if sys.platform != "darwin":
        raise ValueError("Portable game bundles are built on macOS.")
    source = args.source.expanduser().resolve(strict=True)
    requested_output = args.output.expanduser().absolute()
    output = requested_output.parent.resolve() / requested_output.name
    if output.suffix.lower() != ".app" or output.exists() or output.is_symlink():
        raise ValueError("Choose a new output path ending in .app.")
    if source in output.parents:
        raise ValueError("Choose an output path outside the source app.")
    info = checked_tree(source)
    already_portable = info.get("Switch2MacPortable") is True
    if already_portable:
        if args.runtime or args.performance_module:
            raise ValueError("Choose the original native app when replacing its runtime or performance module.")
        result = json.loads((source / RESOURCES / "portable.json").read_text(encoding="utf-8"))
        if not isinstance(result, dict) or result.get("schemaVersion") != SCHEMA or result.get("titleID") != info["DMTitleID"]:
            raise ValueError("The portable app has an invalid manifest.")
    else:
        result = manifest(info)
    if args.runtime:
        if not args.runtime.is_file() or not 0 < args.runtime.stat().st_size < 256 * 1024 * 1024:
            raise ValueError("The replacement runtime must be a native executable smaller than 256 MB.")
        run("/usr/bin/lipo", "-verify_arch", "arm64", args.runtime)
        runtime_bytes = args.runtime.read_bytes()
        chain = info.get("DMChain")
        if chain and chain.encode("ascii") not in runtime_bytes:
            raise ValueError("The replacement runtime does not match the app’s shader chain.")
        result["capabilities"] = {"preferredPlayerOneController": b"DM_PAD_PLAYER1\x00" in runtime_bytes}
    if args.performance_module:
        if not args.runtime:
            raise ValueError("The performance module also needs the matching tested --runtime.")
        verified_performance_module(source, args.performance_module, info)
        result["performanceProfile"] = MKW_PROFILE
    output.parent.mkdir(parents=True, exist_ok=True)
    if source.stat().st_dev != output.parent.stat().st_dev:
        raise ValueError("Pack on the source app’s APFS volume, then move the finished app.")
    with tempfile.TemporaryDirectory(prefix=".portable-game-", dir=output.parent) as temp:
        staged = Path(temp) / output.name
        print("Cloning the existing app on APFS…", file=sys.stderr, flush=True)
        clone(source, staged)
        resources = staged / RESOURCES
        binaries = staged / "Contents/MacOS"
        if args.runtime:
            copy_small_file(args.runtime, binaries / "dmhost")
        if args.performance_module:
            clone(resources / "dm", resources / "dm-performance")
            copy_small_file(args.performance_module, resources / "dm-performance/main.patched.bin")
        if args.icon:
            install_icon(args.icon, resources, info)
        if already_portable:
            (staged / PLIST).write_bytes(plistlib.dumps(info, fmt=plistlib.FMT_BINARY))
        else:
            install_bootstrap(staged, info, result)
        print("Signing and verifying the complete bundle…", file=sys.stderr, flush=True)
        run("/usr/bin/codesign", "--force", "--sign", "-", "--timestamp=none", binaries / "dmhost")
        run("/usr/bin/codesign", "--force", "--sign", "-", "--timestamp=none", staged)
        run("/usr/bin/codesign", "--verify", "--deep", "--strict", staged)
        run(binaries / LAUNCHER, "--check")
        publish_stage(staged, output)
    return {**result, "appPath": str(output)}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    make = commands.add_parser("pack", help="clone, package, sign and verify an existing native game")
    for arg in ("source", "output"):
        make.add_argument(f"--{arg}", type=Path, required=True)
    for arg in ("runtime", "performance-module", "icon"):
        make.add_argument(f"--{arg}", type=Path)
    inspect = commands.add_parser("inspect", help="check a native app and print its portable metadata")
    inspect.add_argument("app", type=Path)
    args = parser.parse_args()
    try:
        if args.command == "pack":
            result = pack(args)
        else:
            app = args.app.expanduser().resolve(strict=True)
            info = checked_tree(app)
            metadata = app / RESOURCES / "portable.json"
            result = json.loads(metadata.read_text()) if info.get("Switch2MacPortable") else manifest(info)
            result = {**result, "appPath": str(app), "portable": info.get("Switch2MacPortable", False)}
        print(json.dumps(result, ensure_ascii=False))
        return 0
    except (OSError, ValueError, subprocess.CalledProcessError, plistlib.InvalidFileException) as error:
        print(f"Portable game: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
