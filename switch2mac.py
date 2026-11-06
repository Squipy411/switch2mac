#!/usr/bin/env python3
"""switch2mac: build a native Mac app of a Switch 2 game from your own dump.

  ./switch2mac.py setup                       Python packages into .venv (once)
  ./switch2mac.py build <dump folder>         the whole build: game files, code, shaders, host, app
  ./switch2mac.py refresh                     take in the shaders the app saved while you played, and pack the app again
  ./switch2mac.py install                     move the finished app to /Applications (replacing the old one)
  ./switch2mac.py run [VAR=value ...]         run the build straight from ./work with a log in work/logs (for porting and debugging: docs/porting.md)

The dump folder holds exefs/ (main, main.npdm, sdk, ...) and romfs/, or base/exefs and base/romfs.
Everything the build writes goes to ./work (--work names another folder). Nothing of the game is in this repository.
Each supported game has a folder in games/ (game.json names it); its profile is nxnative/dm/games/<title ID>.
"""
import argparse, datetime, hashlib, json, os, re, shutil, struct, subprocess, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
NX = ROOT / 'nxnative'
VENV = ROOT / '.venv'
GAMES = {g['title_id']: dict(g, dir=p.parent) for p in sorted((ROOT / 'games').glob('*/game.json')) for g in [json.loads(p.read_text())]}
SKIP = {'.listing', '.DS_Store'}   # a dump tool's FTP listings and Finder's files: never game files


def say(msg): print(f'\n== {msg}', flush=True)


def run(cmd, env=None, cwd=None):
    print('$', ' '.join(str(c) for c in cmd), flush=True)
    r = subprocess.run([str(c) for c in cmd], env=env, cwd=cwd)
    if r.returncode: sys.exit(f'\nstopped: {Path(str(cmd[0])).name} failed ({r.returncode})')


def py():
    p = VENV / 'bin/python'
    if not p.exists(): sys.exit('run ./switch2mac.py setup first')
    return p


def env():
    e = dict(os.environ, PATH=f'{VENV / "bin"}:{os.environ["PATH"]}', DMSH_BORDER_EMU='0', DM_ALLOW_OTHER_METAL='1')
    if 'DOTNET_ROOT' not in e:
        for d in ('/usr/local/share/dotnet', '/opt/homebrew/opt/dotnet/libexec', str(Path.home() / '.dotnet')):
            if Path(d, 'dotnet').exists(): e['DOTNET_ROOT'] = d; break
    return e


def macos():   # this Mac's macOS as major.minor (e.g. 26.5): the app is built for the Mac that builds it, like its Metal shaders
    v = subprocess.run(['sw_vers', '-productVersion'], capture_output=True, text=True).stdout.strip().split('.')
    return f'{v[0]}.{v[1] if len(v) > 1 else 0}'


def setup(a):
    say('Python packages (.venv)')
    if not VENV.exists(): run([sys.executable, '-m', 'venv', VENV])
    run([py(), '-m', 'pip', 'install', '-q', '-r', ROOT / 'requirements.txt'])
    say('checks')
    for tool, why in (('xcrun', 'Xcode'), ('clang++', 'Xcode command line tools')):
        print(f'  {tool}: {"ok" if shutil.which(tool) else "MISSING (" + why + ")"}')
    r = subprocess.run(['xcrun', '-sdk', 'macosx', 'metal', '--version'], capture_output=True, text=True)
    print(f'  Metal compiler: {"ok" if r.returncode == 0 else "MISSING (Xcode → Settings → Components → Metal Toolchain)"}')
    print(f'  .NET: {"ok (" + env()["DOTNET_ROOT"] + ")" if "DOTNET_ROOT" in env() else "MISSING (.NET 10 SDK from dot.net)"}')
    v = macos()
    print(f'  macOS {v}: ' + ('ok (the app is built for this version and later)' if int(v.split('.')[0]) >= 26 else 'TOO OLD (macOS 26 or later is needed: the runtime draws with Metal 4)'))


def dump_dirs(d):
    d = Path(d).expanduser().resolve()
    for base in (d, d / 'base'):
        if (base / 'exefs/main').is_file() and (base / 'romfs').is_dir(): return base / 'exefs', base / 'romfs'
    sys.exit(f'no exefs/main and romfs/ in {d} (or in {d}/base)')


def title_and_build(exefs):
    npdm = (exefs / 'main.npdm').read_bytes()
    aci = struct.unpack_from('<I', npdm, 0x70)[0]   # ACI0 offset in the META header
    tid = f'{struct.unpack_from("<Q", npdm, aci + 0x10)[0]:016X}'
    sys.path.insert(0, str(NX / 'dm/tools')); import nso
    return tid, nso.read(exefs / 'main').build_id[:16].hex()


def check_version(tid, bid):
    if tid not in GAMES: sys.exit(f'title {tid} is not supported yet (this repository has: {", ".join(g["name"] + " " + t for t, g in GAMES.items())}).\n'
                                  'Adding a game: docs/porting.md')
    rows = [l.split('\t') for l in (NX / f'dm/games/{tid}/game.tsv').read_text().splitlines() if l.startswith('build\t')]
    known = {c.split('=', 1)[1]: r[2] for r in rows for c in r[3:] if c.startswith('main=')}
    if bid in known:
        print(f'  {GAMES[tid]["name"]} {known[bid]} (main {bid}): tested')
        return
    sys.exit(f'main build ID {bid} is not a version this profile knows ({", ".join(known.values())}).\n'
             f'This version is UNTESTED: its build line (game.tsv) and module list must be added first (see {GAMES[tid]["dir"].relative_to(ROOT)}/README.md, "Other versions").')


def stage(romfs, out):
    """Keep the staging tree stable so an unchanged RomFS image can be reused."""
    romfs = romfs.resolve(strict=True)
    if out.is_symlink() or out.resolve().is_relative_to(romfs) or romfs.is_relative_to(out.resolve()):
        raise ValueError('RomFS source and staging folders must be separate.')
    out.mkdir(parents=True, exist_ok=True)
    count = changed = 0

    def remove(path):
        if path.is_dir() and not path.is_symlink():
            shutil.rmtree(path)
        else:
            path.unlink()

    def walk_error(error):
        raise error

    for root, directories, files in os.walk(romfs, onerror=walk_error):
        source = Path(root)
        dest = out / source.relative_to(romfs)
        directories[:] = [name for name in directories if not (source / name).is_symlink()]
        files = [name for name in files if name not in SKIP]
        keep = set(directories).union(files)
        for old in dest.iterdir():
            if old.name not in keep:
                remove(old)
                changed += 1
        for name in directories:
            folder = dest / name
            if folder.is_symlink() or (folder.exists() and not folder.is_dir()):
                remove(folder)
                changed += 1
            folder.mkdir(exist_ok=True)
        for name in files:
            link = dest / name
            target = source / name
            if not (link.is_symlink() and os.readlink(link) == str(target)):
                if link.is_symlink() or link.exists():
                    remove(link)
                link.symlink_to(target)
                changed += 1
            count += 1
    print(f'  {count:,} game files linked ({changed:,} staging entries changed)')


def paths(a):
    w = Path(a.work).resolve()
    return w, w / 'extract', w / 'build', w / 'shader', w / 'cache/metal_shader_cache'


def profile(w, tid):   # a fresh copy of the repo's profile in work/profile: the shader split rewrites its tables, the repo stays as it is
    prof = w / 'profile' / tid
    if prof.exists(): shutil.rmtree(prof)
    shutil.copytree(NX / f'dm/games/{tid}', prof)
    return prof


def runtime_shaders(tid, w):
    """Shaders the game assembles while it runs are not in its usual shader containers, but their parts are in its files. games/<game>/runtime_shaders.tsv says where each
    one's control section and code are (file + offset, as positions only: no game data), and its key, sha256(control + code), checks what is read. They go to work/runtime
    as <key>.ctl / <key>.code, the way the app saves shaders it meets (refresh), so the first launch already has them."""
    import zstandard
    table = GAMES[tid]['dir'] / 'runtime_shaders.tsv'
    out = w / 'runtime'; out.mkdir(exist_ok=True)
    if not table.exists(): return None
    rows = [l.rstrip('\n').split('\t') for l in table.open() if l.strip() and not l.startswith('#')]
    blobs, bad = {}, 0
    def blob(name):
        if name not in blobs:
            if name == 'main': blobs[name] = (w / 'shader/main.img').read_bytes()
            else:
                b = (w / 'input/romfs' / name).read_bytes()
                blobs[name] = zstandard.ZstdDecompressor().stream_reader(b).read(1 << 31) if name.endswith('.zs') else b
        return blobs[name]
    for key, cf, co, kf, ko, n in rows:
        ctl = blob(cf)[int(co, 16):int(co, 16) + 0xd8]; code = blob(kf)[int(ko, 16):int(ko, 16) + int(n)]
        if hashlib.sha256(ctl + code).hexdigest()[:16] != key: bad += 1; continue
        (out / f'{key}.ctl').write_bytes(ctl); (out / f'{key}.code').write_bytes(code)
    print(f'  {len(rows) - bad} of {len(rows)} run-time shaders taken from the dump' + (f' ({bad} did not match: another game version?)' if bad else ''))
    return out


def shaders(a, tid, w, sh, cache, e):
    prof = profile(w, tid); tools = NX / 'dm/gfx/tools'
    e.update(DM_GAMES_DIR=str(w / 'profile'), DM_GAMES_FIRST='1')   # every tool (and the host build) takes the work copy
    lower = tools / 'nx2_lower/nx2_lower'
    if not lower.exists():
        say('the shader lowering tool (nx2_lower)')
        run(['clang++', '-std=c++20', '-O2', '-w', '-Wno-c++11-narrowing', '-I.', 'nx2_lower.cpp', '-o', 'nx2_lower'], cwd=tools / 'nx2_lower')
    e = dict(e, DM_GAME=tid)
    run([py(), NX / 'dm/tools/nso.py', w / 'extract/ExeFS/main', sh / 'main.img'], env=e)
    say('shaders: split (with the run-time shaders listed for this game' + (', and those the app saved while you played)' if (w / 'captures').is_dir() and any((w / 'captures').iterdir()) else ')'))
    rt = runtime_shaders(tid, w)
    caps = [str(p) for p in (rt, w / 'captures') if p and p.is_dir() and any(p.iterdir())]
    e = dict(e, NX2_DUMPS=':'.join(caps))
    run([py(), tools / 'nx2_split.py', w / 'input/romfs', sh / 'main.img', sh / 'pkg', prof / 'shader_map.tsv', prof / 'shader_facts.tsv', prof / 'shader_pairs.tsv', sh / 'rejects.tsv'], env=e)
    say('shaders: Metal libraries (the long step: 10-20 minutes the first time, all cores)')
    run([py(), tools / 'own_compilers.py', sh / 'pkg', cache], env=e)
    chain = re.search(r'"([0-9a-f]{12})"', (NX / 'dm/gfx/nvn/dmsh_chain.h').read_text())[1]   # the translator chain version names the library folder
    lib = cache / f'b-{chain}'
    run([py(), tools / 'nx2_res.py', prof / 'shader_map.tsv', sh / 'pkg', sh / 'pkg/cs_layout.tsv', sh / 'res'], env=e)
    run([py(), tools / 'nx2_reflect.py', lib, sh / 'pkg/cs_layout.tsv', sh / 'res'], env=e)
    return lib


def host_and_app(a, tid, w, lib, e):
    g = GAMES[tid]; prof = w / 'profile' / tid
    say('host (the native runtime)')
    run(['make', '-C', NX / 'dm/host', f'GAME={tid}', f'MACOS_MIN={macos()}', 'dmhost'], env=e)   # for this Mac's macOS, not nxnative's fixed 26.6
    font = w / 'build/font'
    if not (font / 'nintendo_ext.ttf').exists():
        font.mkdir(parents=True, exist_ok=True); run([py(), NX / 'dm/tools/make_ext_font.py', font / 'nintendo_ext.ttf'], env=e)
    say('app')
    run([py(), g['dir'] / 'launcher.py', NX, w / 'build/patched', w / 'build/launcher.json'], env=e)
    app = w / f'{g["name"]}.app'
    run([py(), NX / 'dm/mac/pack_app.py', app, '--host', NX / 'dm/host/dmhost', '--patched', w / 'build/patched', '--romfs', w / 'extract/RomFS.img',
         '--msl', lib, '--tables', prof, '--font', font, '--env-file', g['dir'] / 'env.txt', '--settings', w / 'build/launcher.json', '--launcher-window', 'off',
         '--portable-bootstrap', ROOT / 'tools/portable_game.py',
         '--title-id', tid, '--name', g['name'], '--version', g['version'], '--lang', 'en-US', '--marker', g['marker']], env=e)
    (w / 'title.txt').write_text(tid)
    print(f'\ndone: {app}\nnext: ./switch2mac.py install')


def build(a):
    e = env(); w, ex, b, sh, cache = paths(a)
    if 'DOTNET_ROOT' not in e: sys.exit('.NET is missing: run ./switch2mac.py setup for the checks')
    exefs, romfs = dump_dirs(a.dump)
    say('the dump'); tid, bid = title_and_build(exefs); check_version(tid, bid)
    for d in (ex / 'ExeFS', b, sh): d.mkdir(parents=True, exist_ok=True)
    say('game files: code modules and the RomFS image (a few minutes; reused when unchanged)')
    for f in exefs.iterdir():
        if f.is_file() and f.name not in SKIP: run(['cp', '-c', f, ex / 'ExeFS' / f.name])
    stage(romfs, w / 'input/romfs')
    run([py(), NX / 'dm/tools/romfs_image.py', '--reuse', w / 'input/romfs', ex / 'RomFS.img'], env=e)
    say('code: rewrite the game modules for the Mac')
    mods = subprocess.run([py(), NX / 'dm/games/game.py', tid, 'modules'], capture_output=True, text=True, check=True).stdout.split()
    for m in mods: run([py(), NX / 'dm/tools/patch_nso.py', ex / 'ExeFS' / m, b / 'patched', m], env=e)
    lib = shaders(a, tid, w, sh, cache, e)
    host_and_app(a, tid, w, lib, e)


def refresh(a):
    e = env(); w, ex, b, sh, cache = paths(a)
    tf = w / 'title.txt'
    if not tf.exists(): sys.exit('no finished build in ' + str(w) + ': run build first')
    tid = tf.read_text().strip()
    caps = w / 'captures'; caps.mkdir(exist_ok=True); new = []
    for saved in (Path.home() / f'Library/Application Support/nxnative/{tid}/shdump', w / 'run/shdump'):   # the installed app's captures, and run's
        got = [p for p in saved.glob('*') if p.is_file() and not (caps / p.name).exists()] if saved.is_dir() else []
        for p in got: shutil.copy2(p, caps / p.name)
        print(f'{len(got)} new files from {saved}'); new += got
    print(f'{sum(1 for _ in caps.glob("*.ctl"))} shaders captured in all')
    if not new and not a.force: sys.exit('nothing new to build in (play the game a while first, or --force)')
    lib = shaders(a, tid, w, sh, cache, e)
    host_and_app(a, tid, w, lib, e)


def install(a):
    w = paths(a)[0]; tf = w / 'title.txt'
    if not tf.exists(): sys.exit('no finished build: run build first')
    g = GAMES[tf.read_text().strip()]; app = w / f'{g["name"]}.app'; dst = Path('/Applications') / app.name
    if subprocess.run(['pgrep', '-f', f'{dst}/Contents/MacOS'], capture_output=True).returncode == 0: sys.exit(f'{g["name"]} is running: quit it first')
    if dst.exists(): shutil.rmtree(dst)
    shutil.move(str(app), dst); Path(str(app) + '.key').unlink(missing_ok=True)
    print(f'installed: {dst}\nThe first start after each install waits 1-3 minutes while macOS scans the app (no window, no Dock icon yet): wait, do not open it twice.')


def run_game(a):
    """The build straight from ./work, without packing an app: the way to try a new game or a fix. Output goes to the terminal and work/logs/run-<time>.log;
    VAR=value arguments add host switches (docs/porting.md lists the useful ones). work/run/ctl.txt is the host's control file (DM_CTL): write a command
    line into it while the game runs (shot, passdump, texraw, memdump, ...). Shaders the game meets that the build lacks are saved to work/run/shdump."""
    w = paths(a)[0]; tf = w / 'title.txt'
    if not tf.exists(): sys.exit('no finished build: run build first')
    tid = tf.read_text().strip(); g = GAMES[tid]; r = w / 'run'
    for d in ('save', 'temp', 'shdump'): (r / d).mkdir(parents=True, exist_ok=True)
    (r / 'ctl.txt').write_text(''); (w / 'logs').mkdir(exist_ok=True)
    e = dict(os.environ, DM_ROOT=str(w), DM_ROMFS=str(w / 'extract/RomFS.img'), DM_SAVE=str(r / 'save'), DM_TEMP=str(r / 'temp'), DM_NVN_SHDUMP=str(r / 'shdump'),
             DM_MSL_DIR=str(w / 'cache/metal_shader_cache'), DM_FONT_DIR=str(w / 'build/font'), DM_NVN_SHMAP=str(w / 'profile' / tid / 'shader_map.tsv'),
             DM_GAMES_DIR=str(w / 'profile'), DM_GAMES_FIRST='1', DM_LANG='en-US', DM_WINDOW='1', DM_AUDIO='1', DM_CTL=str(r / 'ctl.txt'))
    envf = g['dir'] / 'env.txt'
    for l in (envf.read_text().splitlines() if envf.exists() else []):
        if '=' in l and not l.startswith('#'): k, v = l.split('=', 1); e.setdefault(k.strip(), v.strip())
    for kv in a.vars:
        if '=' not in kv: sys.exit(f'{kv}: expected VAR=value')
        k, v = kv.split('=', 1); e[k] = v
    cmd = [str(NX / 'dm/host/dmhost'), str(w / 'build/patched')]
    log = w / 'logs' / f'run-{datetime.datetime.now():%Y%m%d-%H%M%S}.log'
    print(' '.join(f'{k}={e[k]}' for k in sorted(e) if k.startswith('DM_')) + ' ' + ' '.join(cmd))
    if a.print: return
    print(f'log: {log}', flush=True)
    with log.open('w') as f:
        p = subprocess.Popen(cmd, env=e, cwd=r, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, errors='replace')
        for line in p.stdout: sys.stdout.write(line); f.write(line)
    sys.exit(p.wait())


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--work', default=str(ROOT / 'work'), help='build folder (default ./work)')
    sub = ap.add_subparsers(dest='cmd', required=True)
    sub.add_parser('setup'); bp = sub.add_parser('build'); bp.add_argument('dump')
    rp = sub.add_parser('refresh'); rp.add_argument('--force', action='store_true', help='rebuild even with no new shaders')
    sub.add_parser('install')
    gp = sub.add_parser('run'); gp.add_argument('vars', nargs='*', help='host switches, VAR=value'); gp.add_argument('--print', action='store_true', help='show the command only')
    a = ap.parse_args()
    if a.cmd != 'setup' and Path(sys.prefix).resolve() != VENV.resolve():   # run inside .venv
        os.execv(py(), [str(py()), __file__] + sys.argv[1:])
    {'setup': setup, 'build': build, 'refresh': refresh, 'install': install, 'run': run_game}[a.cmd](a)


if __name__ == '__main__':
    main()
