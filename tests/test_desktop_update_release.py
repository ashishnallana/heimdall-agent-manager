import base64
import hashlib
import importlib.util
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('desktop_validator', ROOT / 'scripts/release/validate-desktop-updates.py')
validator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(validator)
merge_spec = importlib.util.spec_from_file_location('mac_merge', ROOT / 'scripts/release/merge-latest-mac.py')
mac_merge = importlib.util.module_from_spec(merge_spec)
merge_spec.loader.exec_module(mac_merge)


class DesktopUpdateReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)

    def fixture(self, platform='mac', arch='arm64', version='1.2.4'):
        name = f'Ninjy-{version}-{arch}.{"zip" if platform == "mac" else "exe"}'
        data = b'final signed payload fixture'
        digest = base64.b64encode(hashlib.sha512(data).digest()).decode()
        (self.directory / name).write_bytes(data)
        (self.directory / (name + '.blockmap')).write_bytes(b'blockmap fixture')
        text = f'version: {version}\nfiles:\n  - url: {name}\n    sha512: {digest}\n    size: {len(data)}\npath: {name}\nsha512: {digest}\nreleaseDate: \'2026-11-01T00:00:00Z\'\n'
        manifest = self.directory / ('latest-mac.yml' if platform == 'mac' else 'latest.yml')
        manifest.write_text(text)
        return name, manifest, text

    def test_final_payload_digest_size_architecture_and_legacy_fields(self):
        for platform, arch in [('mac', 'arm64'), ('windows', 'x64')]:
            name, _, _ = self.fixture(platform, arch)
            self.assertEqual(validator.validate(self.directory, '1.2.4', platform, [arch]), {name})

    def test_missing_blockmap_payload_and_mismatched_final_bytes(self):
        name, manifest, text = self.fixture()
        (self.directory / (name + '.blockmap')).unlink()
        with self.assertRaisesRegex(ValueError, 'missing payload or blockmap'):
            validator.validate(self.directory, '1.2.4', 'mac', ['arm64'])
        (self.directory / (name + '.blockmap')).write_bytes(b'map')
        (self.directory / name).write_bytes(b'x' * len(b'final signed payload fixture'))
        with self.assertRaisesRegex(ValueError, 'checksum'):
            validator.validate(self.directory, '1.2.4', 'mac', ['arm64'])
        (self.directory / name).write_bytes(b'truncated')
        with self.assertRaisesRegex(ValueError, 'size'):
            validator.validate(self.directory, '1.2.4', 'mac', ['arm64'])

    def test_mixed_versions_suffixes_duplicates_and_unsafe_paths_fail(self):
        _, manifest, text = self.fixture()
        for broken in [text.replace('version: 1.2.4', 'version: 1.2.5'),
                       text.replace('Ninjy-1.2.4-arm64.zip', '../Ninjy-1.2.4-arm64.zip'),
                       text.replace('files:\n', 'files:\nfiles:\n'),
                       text + text[text.index('  - url: '):text.index('path: ')],
                       text.replace('path: Ninjy-1.2.4-arm64.zip', 'path: wrong.zip')]:
            manifest.write_text(broken)
            with self.assertRaises(ValueError):
                validator.validate(self.directory, '1.2.4', 'mac', ['arm64'])
        with self.assertRaisesRegex(ValueError, 'numeric'):
            validator.validate(self.directory, '1.2.4-beta.1', 'mac', ['arm64'])

    def test_missing_advertised_intel_arch_and_promotion_assets_fail(self):
        name, _, _ = self.fixture()
        with self.assertRaisesRegex(ValueError, 'missing advertised'):
            validator.validate(self.directory, '1.2.4', 'mac', ['arm64', 'x64'])
        assets = {'assets': [{'name': n} for n in ['latest-mac.yml', name, name + '.blockmap']]}
        validator.validate(self.directory, '1.2.4', 'mac', ['arm64'], assets)
        assets['assets'].append({'name': 'Ninjy-1.2.4-x64.dmg'})
        with self.assertRaisesRegex(ValueError, 'advertised architecture'):
            validator.validate(self.directory, '1.2.4', 'mac', ['arm64'], assets)
        assets['assets'] = [{'name': name}]
        with self.assertRaisesRegex(ValueError, 'incomplete published'):
            validator.validate(self.directory, '1.2.4', 'mac', ['arm64'], assets)

    def test_merge_checks_all_inputs_for_duplicates_and_versions(self):
        _, _, arm = self.fixture()
        intel = arm.replace('arm64', 'x64')
        merged = mac_merge.merge([('intel', intel), ('arm', arm)])
        self.assertEqual(len(validator.parse_manifest(merged)['files']), 2)
        for inputs in [[('intel', intel), ('arm', arm), ('arm-again', arm)],
                       [('arm', arm), ('wrong', intel.replace('version: 1.2.4', 'version: 1.2.5'))]]:
            with self.assertRaises(SystemExit):
                mac_merge.merge(inputs)


if __name__ == '__main__':
    unittest.main()
