#!/usr/bin/env python3
"""Local build supervisor. No shell commands, uploads, game downloads or runtime tuning.
NX2Apple integration follows its documented CLI/progress contract. See the preserved
license and backend provenance in Licenses/NX2Apple-MIT.txt and THIRD-PARTY.md.
"""
import argparse, ctypes, fcntl, hashlib, importlib.util, json, os, plistlib, re, selectors, shutil, signal, struct, subprocess, sys, tempfile, time
from pathlib import Path

ACTIVE = {'starting', 'running', 'cancelling'}
SWITCH1_ARCHIVES = {'.nsp', '.xci', '.nsz', '.xcz'}
SWITCH2_CONTAINERS = {'.nup'}
GIB = 1024 ** 3
TOOL_PATH = '/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin'

def read(path):
    return json.loads(Path(path).read_text())

def write(path, value):
    path = Path(path); path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_suffix('.tmp')
    with open(temp, 'w', encoding='utf-8') as f:
        os.chmod(temp, 0o600); json.dump(value, f, ensure_ascii=False, allow_nan=False)
    os.replace(temp, path)

def alive(pid):
    try: os.kill(int(pid), 0); return True
    except (OSError, ValueError, TypeError): return False

def nx2apple_script(backend):
    # NX2Apple's working tree keeps the engine as a separately synced checkout.
    for candidate in (Path(backend) / 'scripts' / 'build_ipa_from_nsp.py',
                      Path(backend) / 'engine' / 'scripts' / 'build_ipa_from_nsp.py'):
        if candidate.is_file(): return candidate
    return None

def archives(folder):
    return sorted(p for p in folder.iterdir() if not p.name.startswith('.') and p.suffix.lower() in SWITCH1_ARCHIVES and p.is_file()) if folder.is_dir() else []

def volume(path, expected_uuid=None, writable=False):
    """Check the mounted volume before creating anything at its destination."""
    path = Path(path).resolve()
    mounted = Path('/Volumes') / path.parts[2] if len(path.parts) > 2 and path.parts[1] == 'Volumes' else None
    if mounted and not os.path.ismount(mounted):
        raise ValueError(f'Reconnect {mounted.name} before using {path.name}.')
    ancestor = path
    while not ancestor.exists(): ancestor = ancestor.parent
    if not ancestor.is_dir(): ancestor = ancestor.parent
    line = subprocess.check_output(['/bin/df', '-P', str(ancestor)], text=True, timeout=10).splitlines()[-1]
    match = re.fullmatch(r'(.*?)\s+\d+\s+\d+\s+-?\d+\s+\d+%\s+(.+)', line)
    if not match: raise ValueError(f'Could not identify the mounted volume for {path.name}.')
    device, mount = match.groups()
    info = {}
    if device.startswith('/dev/'):
        result = subprocess.run(['/usr/sbin/diskutil', 'info', '-plist', device], capture_output=True, timeout=10)
        if result.returncode == 0: info = plistlib.loads(result.stdout)
    uuid = info.get('VolumeUUID', '').upper()
    if expected_uuid and uuid != expected_uuid.upper():
        raise ValueError(f'The volume at {mount} differs from the one selected. Reconnect the original drive or choose the destination again.')
    if writable and (info.get('FilesystemType') not in ('apfs', 'hfs') or not info.get('WritableVolume') or not os.access(ancestor, os.W_OK)):
        raise ValueError(f'Choose a writable APFS or Mac OS Extended folder for {path.name}. This volume cannot store the build safely.')
    return path, ancestor.stat().st_dev, uuid

def verify_volumes(volumes):
    for path, device, _ in volumes:
        try:
            if path.stat().st_dev == device: continue
        except OSError:
            pass
        raise ValueError(f'{path.name} became unavailable. Reconnect its original drive and retry to reuse the build files.')

def read_at(path, size):
    try:
        with path.open('rb') as f: return f.read(size)
    except OSError as error:
        raise ValueError(f'Could not read {path.name}. Reconnect its drive or select another file.') from error

def program_id(exefs):
    npdm = read_at(exefs / 'main.npdm', 1024 * 1024)
    if len(npdm) < 0x78 or npdm[:4] != b'META': raise ValueError('The extracted ExeFS is missing valid main.npdm metadata.')
    offset, size = struct.unpack_from('<II', npdm, 0x70)
    if size < 0x18 or offset + 0x18 > len(npdm) or npdm[offset:offset+4] != b'ACI0':
        raise ValueError('The extracted ExeFS has invalid ACI0 program metadata.')
    return f'{struct.unpack_from("<Q", npdm, offset + 0x10)[0]:016X}'

def nso_id(path):
    header = read_at(path, 0x60)
    if len(header) < 0x60 or header[:4] != b'NSO0': raise ValueError(f'{path.name} is not a valid extracted NSO module.')
    return header[0x40:0x50].hex()

def switch2_profile(backend, exefs):
    title = program_id(exefs)
    paths = [backend / root / 'dm/games' / title / 'game.tsv' for root in ('engines/switch2mac', 'nxnative')]
    table = next((p for p in paths if p.is_file()), None)
    if table is None: raise ValueError(f'This Switch2Mac engine has no profile for title {title}.')
    rows = [line.split('\t') for line in table.read_text().splitlines()]
    known = [row for row in rows if row[0] == 'build' and len(row) >= 4]
    current = {'main': nso_id(exefs / 'main')}
    mismatch = None
    for row in known:
        modules = dict(field.split('=', 1) for field in row[3:] if '=' in field)
        if modules.get('main', '').lower() != current['main']: continue
        for name in modules:
            if not re.fullmatch(r'(main|sdk|rtld|subsdk\d+)', name): continue
            if name not in current: current[name] = nso_id(exefs / name)
            if current[name] != modules[name].lower():
                mismatch = f'The extracted {name} build ID differs from the supported {row[2]} profile.'
                break
        else:
            marker = next((row[1] for row in rows if row[0] == 'romfs_marker' and len(row) > 1), '')
            if marker and not (exefs.parent / 'romfs' / marker).is_file():
                raise ValueError(f'The extracted RomFS is missing {marker}, a required asset for this profile.')
            return title
    if mismatch: raise ValueError(mismatch)
    raise ValueError(f'This dump is not a supported version of {title}. Use the matching base game version for this engine.')

def package_header(path):
    head = read_at(path, 0x104)
    ext = path.suffix.lower()
    if ext in ('.nsp', '.nsz') and head[:4] == b'PFS0': return
    if ext in ('.xci', '.xcz') and head[0x100:0x104] == b'HEAD': return
    raise ValueError(f'{path.name} is incomplete or does not match its package format.')

def archive_stage_name(path):
    extension = path.suffix.lower()
    if extension in ('.nsz', '.xcz'):
        # NX2Apple gives nsz the resolved path. nsz takes its output basename from that path and compares its suffix case-sensitively.
        original = path.resolve()
        if original.suffix != extension:
            raise ValueError(f'Rename the original {path.name} with a lowercase {extension} extension before building.')
        return original.name
    return path.stem + extension

def extract_layout(source):
    if (source / 'base/exefs/main.npdm').is_file(): return source / 'base'
    if (source / 'exefs/main.npdm').is_file(): return source
    return None

def dump_layout(source, base):
    title = program_id(base / 'exefs')
    nso_id(base / 'exefs/main')
    if int(title, 16) & 0xfff: raise ValueError('The extracted folder does not contain a base game title.')
    if base == source and ((source / 'updates').exists() or (source / 'dlc').exists()):
        raise ValueError('To include extracted updates or DLC, place the base ExeFS and RomFS inside base/ alongside updates/ and dlc/.')
    versions = set()
    for update in sorted((source / 'updates').glob('*')):
        if update.name.startswith('.'): continue
        if not update.is_dir() or not re.fullmatch(r'[0-9]+', update.name) or int(update.name) in versions or int(update.name) == 0:
            raise ValueError('Extracted updates must be in distinct updates/<decimal version>/ folders.')
        versions.add(int(update.name))
        if program_id(update / 'exefs') != title or not (update / 'romfs').is_dir():
            raise ValueError(f'Update {update.name} needs matching ExeFS and the full patched RomFS.')
        nso_id(update / 'exefs/main')
    if not (base / 'romfs').is_dir() and not versions:
        raise ValueError('Add a base RomFS or a supported update with its full patched RomFS.')
    dlc_titles = set()
    for dlc in sorted((source / 'dlc').glob('*')):
        if dlc.name.startswith('.'): continue
        if not re.fullmatch(r'[0-9a-fA-F]{16}', dlc.name) or not 0 < int(dlc.name, 16) - int(title, 16) - 0x1000 <= 2000 or dlc.name.lower() in dlc_titles:
            raise ValueError(f'{dlc.name} is not a distinct DLC title for this base game.')
        dlc_titles.add(dlc.name.lower())
        roms = list(p for p in dlc.glob('*/romfs') if p.is_dir()) or ([dlc / 'romfs'] if (dlc / 'romfs').is_dir() else [])
        if len(roms) != 1: raise ValueError(f'DLC {dlc.name} must contain one RomFS folder.')
    return title

def nx2_profile(script, title):
    if not (script.parent.parent / 'dm/games' / title / 'game.tsv').is_file():
        raise ValueError(f'This NX2Apple engine has no native profile for title {title}.')

def input_plan(job):
    source, backend = Path(job['source']), Path(job['backend'])
    if not source.exists(): raise ValueError('The game files are unavailable. Reconnect their drive or choose them again.')
    base = extract_layout(source)
    addons = [Path(p) for p in job.get('updates', []) + job.get('dlc', [])]
    if job.get('engine', 'switch2mac') == 'switch2mac':
        if job['system'] != 'Switch 2' or not (backend / 'switch2mac.py').is_file():
            raise ValueError('Choose an installed Switch2Mac engine for Switch 2.')
        if not base or not (base / 'romfs').is_dir():
            raise ValueError('Switch2Mac needs the base game extracted to exefs/ and romfs/.')
        if addons or any((source / name).exists() for name in ('updates', 'dlc')):
            raise ValueError('This Switch2Mac build uses the supported base version. Select its base/ folder without updates or DLC.')
        switch2_profile(backend, base / 'exefs')
        return 'switch2mac', [base]

    script = nx2apple_script(backend)
    if job.get('engine') != 'nx2apple' or not script: raise ValueError('Choose an installed NX2Apple engine.')
    if source.is_dir():
        nups = sorted(p for p in source.iterdir() if not p.name.startswith('.') and p.suffix.lower() in SWITCH2_CONTAINERS and p.is_file())
        packages = [p for root in (source, source / 'base', source / 'updates', source / 'dlc') for p in archives(root)]
    else:
        nups = [source] if source.suffix.lower() in SWITCH2_CONTAINERS else []
        packages = [source] if source.suffix.lower() in SWITCH1_ARCHIVES else []
    if sum(bool(group) for group in (base, nups, packages)) > 1:
        raise ValueError('Choose one input format. The selected folder mixes extracted game files and packages.')
    if base:
        if addons: raise ValueError('Place extracted updates and DLC inside the selected game folder.')
        title = dump_layout(source, base)
        if title.startswith('04') != (job['system'] == 'Switch 2'):
            raise ValueError(f'Title {title} does not match {job["system"]}. Choose the matching platform.')
        nx2_profile(script, title)
        return ('dump' if base != source else 'bare-dump'), [source]
    if nups:
        if job['system'] != 'Switch 2' or len(nups) != 1 or addons:
            raise ValueError('Choose one Switch 2 NUP containing the base game and any updates or DLC.')
        sys.path.insert(0, str(script.parent))
        import pack_nup
        try:
            package = pack_nup.Nup(nups[0])
            try: title = pack_nup.scan(package)[0]
            finally: package.close()
        except pack_nup.Error as error:
            raise ValueError(f'Cannot read the NUP: {error}') from error
        nx2_profile(script, f'{title:016X}')
        return 'nup', nups
    if not packages or job['system'] != 'Switch 1':
        raise ValueError('Choose a Switch 1 package or a Switch 2 NUP or extracted game folder matching the selected system.')
    keys = Path(job.get('keys') or '/nonexistent')
    key_text = read_at(keys, 1024 * 1024)
    if not re.search(rb'(?im)^\s*header_key\s*=\s*[0-9a-f]{64}\s*$', key_text):
        raise ValueError('Choose your own valid prod.keys with a header key for Switch 1 archives.')
    packages = list(dict.fromkeys(p.absolute() for p in packages + addons))
    names = set()
    for p in packages:
        if p.suffix.lower() not in SWITCH1_ARCHIVES: raise ValueError(f'{p.name} is not a supported Switch 1 package.')
        name = archive_stage_name(p).casefold()
        if name in names: raise ValueError(f'Two selected packages have the same name: {p.name}. Give them distinct names first.')
        names.add(name)
        package_header(p)
    return 'archives', packages

def valid_app(path):
    try:
        p = Path(path)
        with open(p / 'Contents/Info.plist', 'rb') as f: info = plistlib.load(f)
        exe = info.get('CFBundleExecutable', '')
        if not isinstance(exe, str) or not exe or '/' in exe: return False
        executable = p / 'Contents/MacOS' / exe
        return executable.is_file() and os.access(executable, os.X_OK)
    except (OSError, ValueError, AttributeError, plistlib.InvalidFileException): return False

def environment(job):
    env = dict(os.environ)
    work = Path(job['directory']); temp = work / 'temp'
    # Use the existing SDK/package caches across jobs, instead of restoring dependencies for every title.
    env.update(PYTHONUNBUFFERED='1', TMPDIR=str(temp) + '/', WORK=str(temp), DOTNET_NOLOGO='1', DOTNET_CLI_TELEMETRY_OPTOUT='1')
    paths = [str(Path(job['python']).parent), str(Path.home() / '.dotnet'), '/usr/local/share/dotnet', TOOL_PATH]
    env['PATH'] = ':'.join(paths)
    if not env.get('DOTNET_ROOT'):
        for root in (str(Path.home() / '.dotnet'), '/usr/local/share/dotnet', '/opt/homebrew/opt/dotnet/libexec'):
            if Path(root, 'dotnet').exists(): env['DOTNET_ROOT'] = root; break
    return env

def toolchain(job, plan):
    if sys.version_info < (3, 12) or not os.access(job['python'], os.X_OK):
        raise ValueError('This build requires its configured Python 3.12 or newer. Check Build Tools in Settings.')
    env = environment(job)
    # TMPDIR points at the eventual workspace for the compiler. Preflight uses the current system temp.
    env.pop('TMPDIR', None)
    tools = ['xcrun', 'make', 'dotnet', 'clang++']
    modules = ['lz4', 'capstone', 'fontTools']
    if plan[0] != 'switch2mac':
        tools += ['zstd', 'glslangValidator', 'xcodebuild']
        if sys.version_info < (3, 14): modules += ['backports.zstd']
        if any(p.suffix.lower() in ('.nsz', '.xcz') for p in plan[1]):
            if not any(shutil.which(name, path=env['PATH']) for name in ('nsz', 'nsz-cli-macos-arm64')):
                modules += ['nsz']
    for module in modules:
        try: found = importlib.util.find_spec(module)
        except ModuleNotFoundError: found = None
        if found is None: raise ValueError(f'Build Python is missing {module}. Run the selected engine’s setup first.')
    missing = [name for name in tools if not shutil.which(name, path=env['PATH'])]
    if missing: raise ValueError(f'Install the missing build tools: {", ".join(missing)}.')
    arch = subprocess.check_output(['/usr/sbin/sysctl', '-n', 'hw.optional.arm64'], text=True, timeout=10).strip()
    if arch != '1' or os.uname().machine != 'arm64': raise ValueError('Native builds require Apple silicon and an arm64 Python environment.')
    sdks = subprocess.check_output(['dotnet', '--list-sdks'], env=env, text=True, timeout=15)
    if not re.search(r'^10\.', sdks, re.M): raise ValueError('Install the .NET 10 SDK required by this engine.')
    if subprocess.run(['xcrun', '-sdk', 'macosx', 'metal', '--version'], env=env, capture_output=True, timeout=30).returncode:
        raise ValueError('Install the Metal Toolchain in Xcode Settings, then select that Xcode for command-line tools.')

def fingerprint_tree(base):
    h = hashlib.sha256()
    size = 0
    for root in (base / 'exefs', base / 'romfs'):
        for directory, children, files in os.walk(root, onerror=raise_walk_error):
            children.sort()
            file_names = set(files)
            for name in [*children, *sorted(files)]:
                if name in ('.listing', '.DS_Store'): continue
                path = Path(directory) / name
                st = path.stat()
                h.update(os.fsencode(path.relative_to(base)) + b'\0')
                h.update(str((st.st_mode, st.st_dev, st.st_ino, st.st_size, st.st_mtime_ns, st.st_ctime_ns)).encode())
                if name in file_names: size += st.st_size
    return h.hexdigest(), size

def raise_walk_error(error):
    raise error

def validate(job):
    if job['system'] not in ('Switch 1', 'Switch 2'): raise ValueError('Choose Switch 1 or Switch 2.')
    directory = Path(job['directory']).resolve()
    if job.get('workspace_root') and not directory.is_relative_to(Path(job['workspace_root']).resolve()):
        raise ValueError('The build workspace points outside the selected folder. Choose another workspace.')
    planned_destination = Path(job['app_path']).parent if job.get('publish_app') else directory
    work_volume = volume(directory, job.get('build_volume_uuid'), writable=True)
    destination_volume = volume(planned_destination, job.get('output_volume_uuid'), writable=True)
    source_path = Path(job['source'])
    source = source_path.resolve()
    for target in (directory, planned_destination.resolve()):
        if source.is_dir() and target.is_relative_to(source): raise ValueError('Choose a build and app location outside the game dump.')
    selected = job.get('input_volume_uuids', {})
    source_volume = volume(source, selected.get(str(source_path), job.get('source_volume_uuid')))
    selected_files = [volume(p, selected.get(p)) for p in job.get('updates', []) + job.get('dlc', [])]
    if job.get('keys'):
        selected_files.append(volume(job['keys'], selected.get(job['keys'], job.get('keys_volume_uuid'))))
    plan = input_plan(job)
    toolchain(job, plan)
    directory.mkdir(parents=True, exist_ok=True)
    planned_destination.mkdir(parents=True, exist_ok=True)
    (directory / 'temp').mkdir(exist_ok=True)
    volumes = [work_volume, destination_volume, source_volume, *selected_files]
    watched = [*plan[1], Path(job['backend']), Path(job['python'])]
    if (base := extract_layout(source)):
        watched += [path for path in (base / 'romfs', base / 'exefs') if path.is_dir()]
    for path in watched:
        if path.stat().st_dev not in {d for _, d, _ in volumes}: volumes.append(volume(path))
    verify_volumes(volumes)
    return plan, volumes

def available_space(job, plan):
    folder = Path(job['directory']); free = shutil.disk_usage(folder).free
    needed = 5 * GIB; source_key = None
    if plan[0] == 'switch2mac':
        source_key, size = romfs_source_key(job, plan[1][0])
        image = romfs_identity(folder)
        try: unchanged = image is not None and read(folder / 'romfs-source.json') == {'source': source_key, 'image': image}
        except (OSError, ValueError): unchanged = False
        needed = max(5 * GIB, size // 4) if unchanged else max(10 * GIB, size + 8 * GIB)
    if free < needed: raise ValueError(f'The selected build drive has {free / GIB:.1f} GiB free. This build needs about {needed / GIB:.1f} GiB.')
    return source_key

def file_identity(path):
    st = path.stat()
    return st.st_dev, st.st_ino, st.st_size, st.st_mtime_ns, st.st_ctime_ns

def romfs_identity(folder):
    image = folder / 'work/extract/RomFS.img'
    try:
        current = list(file_identity(image))
        if read(image.with_suffix('.img.inputs.json')).get('image') == current: return current
    except (OSError, ValueError): pass
    return None

def romfs_source_key(job, base):
    key, size = fingerprint_tree(base)
    backend = Path(job['backend'])
    for root in ('engines/switch2mac', 'nxnative'):
        packer = backend / root / 'dm/tools/romfs_image.py'
        if packer.is_file():
            key = hashlib.sha256(key.encode() + packer.read_bytes()).hexdigest()
            break
    return key, size

def command(job, plan):
    backend = Path(job['backend']); directory = Path(job['directory']); work = directory / 'work'
    kind, inputs = plan
    if kind == 'switch2mac':
        return [job['python'], '-u', str(backend / 'switch2mac.py'), '--work', str(work), 'build', str(inputs[0])]
    source = inputs[0]
    if kind in ('archives', 'bare-dump'):
        # The NX2Apple CLI accepts a folder or a NUP, never a direct NSP/XCI file.
        key = hashlib.sha256(b'\0'.join(os.fsencode(p) for p in sorted(inputs))).hexdigest()[:16]
        stage = directory / f'input-{key}'; stage.mkdir(exist_ok=True)
        for p in inputs:
            target = stage / ('base' if kind == 'bare-dump' else archive_stage_name(p))
            desired = p.resolve()
            if target.is_symlink() and target.resolve() == desired: continue
            if target.exists() or target.is_symlink(): raise ValueError(f'Build input staging is occupied: {target.name}.')
            target.symlink_to(desired)
        source = stage
    script = nx2apple_script(backend)
    if script is None: raise ValueError('NX2Apple build script is missing. Sync the engine first.')
    product = work / (job['name'] + '.app') if job.get('publish_app') else Path(job['app_path'])
    args = [job['python'], '-u', str(script), str(source),
            '--platform', 'mac-app', '--progress', 'json', '--work-dir', str(work), '-o', str(product), '--app-name', job['name']]
    if kind == 'archives': args += ['-k', job['keys']]
    # Explicit choice, never silently bypass a backend's tested compiler check.
    if job.get('allow_other_metal'): args += ['--allow-other-metal']
    return args

def progress(line, state):
    try: e = json.loads(line)
    except (ValueError, TypeError): e = {}
    if isinstance(e, dict) and e.get('ev') in ('stage', 'stage_start', 'progress', 'stage_end'):
        if e.get('name'): state['stage'] = e['name']
        state['fraction'] = e.get('frac') if isinstance(e.get('frac'), (int, float)) else None
        state['stage_number'] = e.get('k')
        state['message'] = ' · '.join(str(e[k]) for k in ('step', 'note', 'summary') if e.get(k))
        if e.get('done') is not None:
            state['message'] = f"{e['done']:,}" + (f" / {e['total']:,}" if e.get('total') else '') + (' ' + str(e.get('unit', '')))
    elif line.startswith('== '): state.update(stage=line.strip('= \n'), fraction=None, message='')
    elif '.metal:' in line or '.metal.pre-' in line: state['stage'] = 'Compiling shaders'
    elif line.startswith('[RED]') or 'error:' in line.lower(): state['last_error'] = line.strip()[-500:]

def terminate_group(proc):
    try: os.killpg(proc.pid, signal.SIGTERM)
    except ProcessLookupError: return
    try: proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        try: os.killpg(proc.pid, signal.SIGKILL)
        except ProcessLookupError: pass
        proc.wait()

def delivery_record(directory, destination):
    key = hashlib.sha256(os.fsencode(destination)).hexdigest()[:16]
    return directory / f'delivery-{key}.json'

def delivery_owner(directory, destination):
    if destination.is_symlink(): raise ValueError('Choose a destination without an app alias or symbolic link at the same name.')
    if not destination.exists(): return None
    try: previous = read(delivery_record(directory, destination))
    except (OSError, ValueError): previous = {}
    inode = destination.stat().st_ino
    for item in (previous.get('current'), previous.get('pending')):
        if item and item.get('destination') == str(destination) and item.get('inode') == inode: return item
    raise ValueError(f'{destination.name} already exists there. Use a different app name or destination folder.')

def rename_delivery(source, destination, replace):
    # Atomic exchange on macOS retains the previous app until the new one is in place.
    rename = ctypes.CDLL(None, use_errno=True).renamex_np
    rename.argtypes = (ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint)
    rename.restype = ctypes.c_int
    rename_swap, rename_excl = 0x2, 0x4  # <sys/stdio.h>
    if rename(os.fsencode(source), os.fsencode(destination), rename_swap if replace else rename_excl):
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error), destination)

def product_app(job, plan):
    work = Path(job['directory']) / 'work'
    if plan[0] == 'switch2mac':
        title = program_id(plan[1][0] / 'exefs')
        for path in sorted(work.glob('*.app')):
            try:
                info = plistlib.loads((path / 'Contents/Info.plist').read_bytes())
                if str(info.get('DMTitleID', '')).upper() == title and valid_app(path): return path
            except (OSError, plistlib.InvalidFileException): continue
        raise ValueError('The compiler finished without a complete Mac app for this title.')
    return work / (job['name'] + '.app') if job.get('publish_app') else Path(job['app_path'])

def publish(job, product, volumes, cancel):
    directory, destination = Path(job['directory']), Path(job['app_path'])
    old = delivery_owner(directory, destination)
    identity = list(file_identity(product))
    if old and old.get('product') == identity and valid_app(destination): return destination
    same_volume = product.stat().st_dev == destination.parent.stat().st_dev
    if not same_volume:
        bytes_needed = sum(p.stat().st_size for p in product.rglob('*') if p.is_file() and not p.is_symlink())
        free = shutil.disk_usage(destination.parent).free
        if free < bytes_needed:
            raise ValueError(f'The app is built. Its destination needs {bytes_needed / GIB:.1f} GiB, and has {free / GIB:.1f} GiB free. Choose another destination and retry.')
    with tempfile.TemporaryDirectory(prefix='.switch2mac-delivery-', dir=destination.parent) as t:
        stage = Path(t) / destination.name
        argv = ['/bin/cp', '-cRp', str(product), str(stage)] if same_volume else ['/usr/bin/ditto', str(product), str(stage)]
        proc = subprocess.Popen(argv, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        try:
            while proc.poll() is None:
                if cancel.exists(): raise InterruptedError('Build stopped. The built app can be delivered on retry.')
                verify_volumes(volumes)
                time.sleep(0.25)
            if proc.returncode or not valid_app(stage): raise ValueError('The built app could not be copied to its destination. Choose a drive with enough free space and retry.')
        finally:
            if proc.poll() is None: terminate_group(proc)
        verify_volumes(volumes)
        if cancel.exists(): raise InterruptedError('Build stopped. The built app can be delivered on retry.')
        old = delivery_owner(directory, destination)
        record = delivery_record(directory, destination)
        new = {'destination': str(destination), 'inode': stage.stat().st_ino, 'product': identity}
        write(record, {'current': old, 'pending': new})
        rename_delivery(stage, destination, replace=old is not None)
        write(record, {'current': new})
    return destination

def run_job(path):
    path = Path(path).resolve(); job = read(path); directory = Path(job['directory'])
    activity = Path(job.get('state_directory', directory))
    lock = open(activity / 'worker.lock', 'a')
    try: fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        lock.close()
        return 2
    status = activity / 'status.json'; cancel = activity / 'cancel.request'
    state = dict(state='running', stage='Checking files', message='', started=time.time(), updated=time.time(),
                 pid=os.getpid(), child_pid=None, fraction=None, app_path=job['app_path'], workspace=str(directory))
    proc = engine_lock = None
    try:
        write(status, state)
        if cancel.exists(): raise InterruptedError('Build stopped before the compiler started.')
        plan, volumes = validate(job)
        engine_name = job.get('engine', 'switch2mac')
        lock_root = Path.home() / 'Library/Application Support/Switch2Mac/Build Locks'
        lock_root.mkdir(parents=True, exist_ok=True)
        engine_lock = open(lock_root / f'{engine_name}.lock', 'a')
        try: fcntl.flock(engine_lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError: raise ValueError('Another build is using this engine. Wait for it to finish.')
        if plan[0] == 'switch2mac':
            processes = subprocess.run(['/bin/ps', '-Ao', 'command='], capture_output=True, text=True).stdout
            if any('switch2mac.py' in l and (' build ' in l or l.endswith(' build')) for l in processes.splitlines()):
                raise ValueError('A switch2mac build is already running. It will be left untouched. Try again when it finishes.')
        if job.get('publish_app'): delivery_owner(directory, Path(job['app_path']))
        state.update(stage='Checking build space', message='Checking the selected drive and any reusable build files.')
        write(status, state)
        source_key = available_space(job, plan)
        old_image = romfs_identity(directory) if source_key else None
        verify_volumes(volumes)
        if cancel.exists(): raise InterruptedError('Build stopped before the compiler started.')
        argv = command(job, plan)
        state.update(stage='Starting compiler', message='The build continues if you close this window.')
        write(status, state)
        with open(activity / 'build.log', 'ab', buffering=0) as log:
            os.chmod(log.name, 0o600)
            proc = subprocess.Popen(argv, cwd=job['backend'], env=environment(job), stdin=subprocess.DEVNULL,
                                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT, start_new_session=True,
                                    pass_fds=(engine_lock.fileno(),))
            state['child_pid'] = proc.pid; write(status, state)
            with selectors.DefaultSelector() as sel:
                sel.register(proc.stdout, selectors.EVENT_READ)
                pending = ''; last_write = 0
                while sel.get_map():
                    if cancel.exists():
                        state['state'] = 'cancelling'; write(status, state); terminate_group(proc); break
                    for key, _ in sel.select(timeout=0.25):
                        data = os.read(key.fileobj.fileno(), 65536)
                        if not data: sel.unregister(key.fileobj); continue
                        log.write(data); pending += data.decode('utf-8', errors='replace')
                        while '\n' in pending:
                            line, pending = pending.split('\n', 1); progress(line, state)
                        if len(pending) > 65536: pending = pending[-65536:]
                    if time.monotonic() - last_write > 0.5:
                        verify_volumes(volumes)
                        state['updated'] = time.time(); write(status, state); last_write = time.monotonic()
            code = proc.wait()
        verify_volumes(volumes)
        if source_key and (image := romfs_identity(directory)) and image != old_image:
            if romfs_source_key(job, plan[1][0])[0] == source_key:
                write(directory / 'romfs-source.json', {'source': source_key, 'image': image})
        if cancel.exists(): state.update(state='cancelled', stage='Stopped', message='Build files are kept. Retry to reuse available work.')
        elif code != 0: state.update(state='failed', stage='Build stopped', message=state.get('last_error') or f'The compiler exited with code {code}. Open the build log for details.')
        else:
            product = product_app(job, plan)
            if not valid_app(product): raise ValueError('The compiler finished but no complete Mac app was found. Open the build log.')
            if job.get('publish_app'):
                state.update(stage='Saving Mac app', message='Preparing the finished app in the selected destination.', fraction=None, updated=time.time(), child_pid=None)
                write(status, state)
                product = publish(job, product, volumes, cancel)
            state['app_path'] = str(product)
            state.update(state='completed', stage='Ready to play', message='The compiled app is stored on your selected drive.', fraction=1.0)
    except InterruptedError as error:
        state.update(state='cancelled', stage='Stopped', message=str(error))
    except BaseException as error:
        if proc is not None and proc.poll() is None: terminate_group(proc)
        state.update(state='failed', stage='Build stopped', message=str(error)[:700])
    finally:
        state.update(ended=time.time(), updated=time.time(), child_pid=None)
        try: write(status, state)
        finally:
            if proc is not None and proc.stdout: proc.stdout.close()
            if engine_lock is not None: engine_lock.close()
            lock.close()
    return 0 if state['state'] == 'completed' else 1

def check(config):
    env = dict(os.environ, PATH='/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin')
    rows = []
    for name, exe in [('Xcode', 'xcrun'), ('Shader tools', 'spirv-cross'), ('GLSL tools', 'glslangValidator')]:
        rows.append(dict(name=name, ok=shutil.which(exe, path=env['PATH']) is not None))
    rows.append(dict(name='Switch 1 engine', ok=nx2apple_script(config['switch1']) is not None))
    rows.append(dict(name='Switch 2 engine', ok=Path(config['switch2'], 'switch2mac.py').is_file()))
    for name,key in [('Switch 1 Python','switch1_python'),('Switch 2 Python','switch2_python')]: rows.append(dict(name=name, ok=os.access(config[key],os.X_OK)))
    rows.append(dict(name='Metal compiler',ok=subprocess.run(['/usr/bin/xcrun','-sdk','macosx','metal','--version'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL).returncode==0))
    roots = [Path.home()/'.dotnet',Path('/usr/local/share/dotnet'),Path('/opt/homebrew/opt/dotnet/libexec')]
    rows.append(dict(name='.NET',ok=any((p/'dotnet').exists() for p in roots)))
    return rows

def main():
    ap = argparse.ArgumentParser(); ap.add_argument('action', choices=['start', 'run', 'stop', 'check']); ap.add_argument('path'); a = ap.parse_args()
    if a.action == 'run': return run_job(a.path)
    if a.action == 'check': print(json.dumps(check(read(a.path)))); return 0
    path = Path(a.path).resolve(); job = read(path); directory = Path(job.get('state_directory', job['directory']))
    if a.action == 'stop': (directory / 'cancel.request').touch(); return 0
    status = directory / 'status.json'
    if status.exists():
        old = read(status)
        if old['state'] in ACTIVE and alive(old.get('pid')): raise SystemExit('Build is already running.')
    if 'state_directory' not in job: (directory / 'cancel.request').unlink(missing_ok=True)
    with open(directory/'supervisor.log', 'ab') as log:
        proc = subprocess.Popen([sys.executable, str(Path(__file__).resolve()), 'run', str(path)],
             stdin=subprocess.DEVNULL,stdout=log,stderr=log,start_new_session=True)
    print(json.dumps({'pid': proc.pid}))
    return 0

if __name__ == '__main__': sys.exit(main())
