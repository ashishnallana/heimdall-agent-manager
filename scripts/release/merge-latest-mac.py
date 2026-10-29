#!/usr/bin/env python3
"""Merge the per-arch latest-mac.yml files into the one electron-updater reads (F14).

Each macOS build job writes its own latest-mac.yml listing only its zip/dmg.
electron-updater's MacUpdater reads one latest-mac.yml and picks the entry whose
URL names arm64 on Apple silicon and one without it on Intel, so the release
needs both arches' `files` entries in one document.

usage: merge-latest-mac.py <base.yml> <other.yml>...   (merged YAML on stdout)

The base keeps its top-level fields (version, path, sha512, releaseDate); pass
the x64 file first so the legacy single-file fields point at the Intel zip.
Only the flat shape electron-builder writes is accepted (no YAML library on the
release runner is assumed); anything else fails loudly.
"""
import sys


def split(text: str, name: str):
    """(top-level lines before files:, file entry lines, top-level lines after)."""
    head, files, tail = [], [], []
    section = head
    for line in text.splitlines():
        if not line.strip():
            continue
        if line == 'files:':
            section = files
            continue
        if line.startswith(' '):
            if section is not files:
                raise SystemExit(f'{name}: unexpected indented line outside files: {line!r}')
            files.append(line)
            continue
        if section is files:
            section = tail
        section.append(line)
    if not files or not files[0].lstrip().startswith('- url: '):
        raise SystemExit(f'{name}: no files: entries')
    return head, files, tail


def field(lines, key: str, name: str) -> str:
    for line in lines:
        if line.startswith(f'{key}: '):
            return line[len(key) + 2:]
    raise SystemExit(f'{name}: missing {key}')


def merge(texts):
    base_head, files, base_tail = split(texts[0][1], texts[0][0])
    version = field(base_head, 'version', texts[0][0])
    urls = {l.strip() for l in files if l.lstrip().startswith('- url: ')}
    for name, text in texts[1:]:
        head, more, _ = split(text, name)
        if field(head, 'version', name) != version:
            raise SystemExit(f'{name}: version {field(head, "version", name)} != {version}')
        clash = urls & {l.strip() for l in more if l.lstrip().startswith('- url: ')}
        if clash:
            raise SystemExit(f'{name}: duplicate file entries {sorted(clash)}')
        files += more
    return '\n'.join(base_head + ['files:'] + files + base_tail) + '\n'


def main(argv):
    if len(argv) < 3:
        print(__doc__.strip().splitlines()[4], file=sys.stderr)
        return 2
    texts = []
    for name in argv[1:]:
        with open(name, encoding='utf-8') as f:
            texts.append((name, f.read()))
    sys.stdout.write(merge(texts))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
