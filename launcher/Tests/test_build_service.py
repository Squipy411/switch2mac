import importlib.util
import plistlib
from pathlib import Path
import struct
import sys
import tempfile
import unittest
from unittest.mock import patch


SERVICE = Path(__file__).resolve().parents[1] / 'Resources/Builder/build_service.py'
spec = importlib.util.spec_from_file_location('build_service', SERVICE)
service = importlib.util.module_from_spec(spec)
spec.loader.exec_module(service)


def extracted(folder, title):
    exefs = folder / 'exefs'
    exefs.mkdir(parents=True)
    (folder / 'romfs').mkdir()
    npdm = bytearray(0x98)
    npdm[:4], npdm[0x80:0x84] = b'META', b'ACI0'
    struct.pack_into('<II', npdm, 0x70, 0x80, 0x18)
    struct.pack_into('<Q', npdm, 0x90, title)
    (exefs / 'main.npdm').write_bytes(npdm)
    (exefs / 'main').write_bytes(b'NSO0' + b'\0' * 0x5c)


def app(folder):
    exe = folder / 'Contents/MacOS/fixture'
    exe.parent.mkdir(parents=True)
    exe.write_text('#!/bin/sh\nexit 0\n')
    exe.chmod(0o755)
    (folder / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleExecutable': exe.name}))


class BuildServiceTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.backend = self.root / 'engine'
        self.workspace = self.root / 'workspace'
        self.workspace.mkdir()
        self.script = self.backend / 'scripts/build_ipa_from_nsp.py'
        self.script.parent.mkdir(parents=True)
        self.script.touch()
        self.keys = self.root / 'prod.keys'
        self.keys.write_text('header_key = ' + '0' * 64)

    def job(self, source):
        return dict(system='Switch 1', engine='nx2apple', backend=str(self.backend), source=str(source),
                    python=sys.executable, directory=str(self.workspace), keys=str(self.keys),
                    name='Fixture', app_path=str(self.root / 'Fixture.app'), publish_app=True)

    def test_single_archive_is_staged_and_exact_addons_are_kept(self):
        base = self.root / 'base.NSP'
        update = self.root / 'update.nsz'
        for package in (base, update): package.write_bytes(b'PFS0' + b'\0' * 32)
        job = self.job(base)
        job['updates'] = [str(update)]
        plan = service.input_plan(job)
        first = service.command(job, plan)
        second = service.command(job, plan)
        self.assertEqual(first, second)
        staged = Path(first[3])
        self.assertEqual({p.name: p.resolve() for p in staged.iterdir()}, {'base.nsp': base, 'update.nsz': update})
        self.assertEqual(first[first.index('-k') + 1], str(self.keys))
        self.assertEqual(first[first.index('-o') + 1], str(self.workspace / 'work/Fixture.app'))

    def test_grouped_archive_folders_preserve_content(self):
        source = self.root / 'game'
        packages = [source / 'base/a.xci', source / 'updates/b.nsp', source / 'dlc/c.nsz']
        for p in packages:
            p.parent.mkdir(parents=True)
            p.write_bytes(b'\0' * 0x100 + b'HEAD' if p.suffix == '.xci' else b'PFS0' + b'\0' * 32)
        self.assertEqual(set(service.input_plan(self.job(source))[1]), set(packages))

    def test_incomplete_archive_fails_preflight(self):
        source = self.root / 'partial.nsp'
        source.write_bytes(b'partial')
        with self.assertRaisesRegex(ValueError, 'incomplete'):
            service.input_plan(self.job(source))

    def test_compressed_archive_uses_the_resolved_source_name(self):
        actual = self.root / 'original [0100000000000000].nsz'
        actual.write_bytes(b'PFS0' + b'\0' * 32)
        alias = self.root / 'game.nsz'
        alias.symlink_to(actual)
        job = self.job(alias)
        command = service.command(job, service.input_plan(job))
        self.assertTrue((Path(command[3]) / actual.name).is_symlink())
        uppercase = self.root / 'second.NSZ'
        uppercase.write_bytes(b'PFS0' + b'\0' * 32)
        with self.assertRaisesRegex(ValueError, 'lowercase'):
            service.input_plan(self.job(uppercase))

    def test_switch2_dump_preserves_update_and_dlc(self):
        title = 0x040074A01BF12000
        source = self.root / 'game'
        extracted(source / 'base', title)
        extracted(source / 'updates/458752', title)
        (source / 'dlc/040074a01bf13001/0/romfs').mkdir(parents=True)
        profile = self.backend / f'dm/games/{title:016X}/game.tsv'
        profile.parent.mkdir(parents=True)
        profile.touch()
        job = self.job(source)
        job.update(system='Switch 2', keys='')
        plan = service.input_plan(job)
        self.assertEqual(plan, ('dump', [source]))
        command = service.command(job, plan)
        self.assertEqual(Path(command[3]), source)
        self.assertNotIn('-k', command)

    def test_validated_delivery_reuses_and_replaces_atomically(self):
        product = self.workspace / 'work/Fixture.app'
        destination = self.root / 'Fixture.app'
        app(product)
        job = self.job(self.root / 'game')
        cancel = self.root / 'cancel.request'
        volumes = [service.volume(product), service.volume(destination.parent)]
        self.assertEqual(service.publish(job, product, volumes, cancel), destination)
        initial_inode = destination.stat().st_ino
        self.assertEqual(service.publish(job, product, volumes, cancel).stat().st_ino, initial_inode)
        (product / 'Contents/marker').write_text('new fixture')
        product.touch()
        self.assertNotEqual(service.publish(job, product, volumes, cancel).stat().st_ino, initial_inode)
        self.assertEqual((destination / 'Contents/marker').read_text(), 'new fixture')

    def test_unrelated_existing_app_remains_unmodified(self):
        destination = self.root / 'Fixture.app'
        app(destination)
        inode = destination.stat().st_ino
        with self.assertRaisesRegex(ValueError, 'already exists'):
            service.delivery_owner(self.workspace, destination)
        self.assertEqual(destination.stat().st_ino, inode)

    def test_cancel_before_preflight_keeps_internal_status(self):
        activity = self.root / 'activity'
        activity.mkdir()
        job = self.job(self.root / 'missing.nsp')
        job['state_directory'] = str(activity)
        manifest = activity / 'job.json'
        service.write(manifest, job)
        (activity / 'cancel.request').touch()
        with patch.object(service, 'validate', side_effect=AssertionError('cancel must precede preflight')):
            self.assertEqual(service.run_job(manifest), 1)
        self.assertEqual(service.read(activity / 'status.json')['state'], 'cancelled')

    def test_compiler_output_is_delivered_with_activity_off_the_workspace(self):
        source = self.root / 'game.nsp'
        source.write_bytes(b'PFS0' + b'\0' * 32)
        activity = self.root / 'activity'
        activity.mkdir()
        self.script.write_text('''\
import plistlib, sys
from pathlib import Path
source = Path(sys.argv[1])
assert (source / 'game.nsp').is_symlink()
app = Path(sys.argv[sys.argv.index('-o') + 1])
exe = app / 'Contents/MacOS/fixture'
exe.parent.mkdir(parents=True)
exe.write_text('#!/bin/sh\\nexit 0\\n')
exe.chmod(0o755)
(app / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleExecutable': exe.name}))
print('{"ev":"stage","name":"fixture compiler"}', flush=True)
''')
        job = self.job(source)
        job['state_directory'] = str(activity)
        manifest = activity / 'job.json'
        service.write(manifest, job)
        with patch.object(service, 'toolchain'), patch.object(service, 'available_space'):
            self.assertEqual(service.run_job(manifest), 0, service.read(activity / 'status.json'))
        status = service.read(activity / 'status.json')
        self.assertEqual(status['state'], 'completed')
        self.assertEqual(status['workspace'], str(self.workspace))
        self.assertTrue(service.valid_app(status['app_path']))
        self.assertIn('fixture compiler', (activity / 'build.log').read_text())


if __name__ == '__main__':
    unittest.main()
