#!/usr/bin/env python3
"""Validate final builder manifests against exact payload bytes before upload/promotion.

Accept only the flat electron-builder YAML shape; no runtime YAML dependency.
An unsigned SHA-512 is an integrity check, not publisher authentication.
"""
import argparse
import base64
import hashlib
import json
from pathlib import Path
import re


def scalar(value):
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
        return value[1:-1]
    return value


def parse_manifest(text):
    result, entries = {}, []
    current = None
    files = False
    in_files = False
    for line in text.splitlines():
        if not line.strip():
            continue
        if line == 'files:':
            if files:
                raise ValueError('duplicate files')
            files = True
            in_files = True
            continue
        if line.startswith('  - url: '):
            if not in_files:
                raise ValueError('file outside files')
            current = {'url': scalar(line[9:])}
            entries.append(current)
            continue
        if line.startswith('    '):
            match = re.fullmatch(r'    (sha512|size|blockMapSize): (.+)', line)
            if not current or not match or match[1] in current:
                raise ValueError('malformed file entry')
            current[match[1]] = scalar(match[2])
            continue
        match = re.fullmatch(r'(version|path|sha512|releaseDate): (.+)', line)
        if not match or match[1] in result:
            raise ValueError('malformed or duplicate metadata field')
        current = None
        in_files = False
        result[match[1]] = scalar(match[2])
    if not entries or any(key not in result for key in ('version', 'path', 'sha512', 'releaseDate')):
        raise ValueError('incomplete manifest')
    result['files'] = entries
    return result


def validate(directory, version, platform, arches, assets=None):
    if not re.fullmatch(r'\d+\.\d+\.\d+', version):
        raise ValueError('desktop channel supports numeric versions only')
    directory = Path(directory)
    manifest_name = 'latest-mac.yml' if platform == 'mac' else 'latest.yml'
    manifest = parse_manifest((directory / manifest_name).read_text(encoding='utf-8'))
    if manifest['version'] != version:
        raise ValueError('manifest version mismatch')
    names = [entry['url'] for entry in manifest['files']]
    if len(names) != len(set(names)):
        raise ValueError('duplicate payload URL')
    suffix = 'zip' if platform == 'mac' else 'exe'
    required = {f'Ninjy-{version}-{arch}.{suffix}' for arch in arches}
    if not required <= set(names):
        raise ValueError('missing advertised architecture payload')
    if assets is not None:
        published = {asset['name'] for asset in assets['assets']}
        if platform == 'mac':
            for arch in ('arm64', 'x64'):
                if any(f'Ninjy-{version}-{arch}.{ext}' in published for ext in ('dmg', 'pkg', 'zip')):
                    required.add(f'Ninjy-{version}-{arch}.zip')
        if not required <= set(names):
            raise ValueError('advertised architecture missing from manifest')
        if not {manifest_name, *required, *(name + '.blockmap' for name in required)} <= published:
            raise ValueError('incomplete published payload set')
    payload_entries = [entry for entry in manifest['files'] if entry['url'].endswith('.' + suffix)]
    if set(entry['url'] for entry in payload_entries) != required:
        raise ValueError('unexpected architecture or payload')
    for entry in manifest['files']:
        name = entry['url']
        allowed = rf'Ninjy-{re.escape(version)}-(arm64|x64)\.(zip|dmg)' if platform == 'mac' else rf'Ninjy-{re.escape(version)}-x64\.exe'
        if not re.fullmatch(allowed, name):
            raise ValueError('unsafe or incompatible payload URL')
        if 'sha512' not in entry or 'size' not in entry or not re.fullmatch(r'[1-9][0-9]*', entry['size']):
            raise ValueError('missing digest or size')
        try:
            digest = base64.b64decode(entry['sha512'], validate=True)
        except Exception as error:
            raise ValueError('invalid SHA-512 encoding') from error
        if len(digest) != 64:
            raise ValueError('invalid SHA-512 length')
        # DMGs are manual media and may be stapled after builder's metadata was
        # generated. Only ZIP/NSIS payloads are selected by the pinned updater.
        if name not in required:
            continue
        payload = directory / name
        blockmap = directory / (name + '.blockmap')
        if payload.is_symlink() or not payload.is_file() or blockmap.is_symlink() or not blockmap.is_file() or not blockmap.stat().st_size:
            raise ValueError('missing payload or blockmap')
        if payload.stat().st_size != int(entry['size']):
            raise ValueError('payload size mismatch')
        hasher = hashlib.sha512()
        with payload.open('rb') as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b''):
                hasher.update(chunk)
        if hasher.digest() != digest:
            raise ValueError('payload checksum mismatch')
    legacy = next((entry for entry in payload_entries if entry['url'] == manifest['path']), None)
    if not legacy or legacy['sha512'] != manifest['sha512']:
        raise ValueError('legacy fields do not match update payload')
    return required


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory')
    parser.add_argument('--version', required=True)
    parser.add_argument('--platform', choices=('mac', 'windows'), required=True)
    parser.add_argument('--arch', action='append', required=True)
    parser.add_argument('--assets')
    args = parser.parse_args()
    assets = json.loads(Path(args.assets).read_text()) if args.assets else None
    validated = validate(args.directory, args.version, args.platform, args.arch, assets)
    print('Validated desktop update payloads: ' + ', '.join(sorted(validated)))


if __name__ == '__main__':
    main()
