#!/usr/bin/env python3
"""Reuse only EV1 components from a hash-verified build of the pinned source."""
import hashlib
import json
from pathlib import Path, PurePosixPath
import sys
import zipfile

artifact, destination, expected = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
manifest = json.loads((artifact / 'build-manifest.json').read_text())
ipa = artifact / 'Spotify-9.1.78-Performance-EV1.ipa'
if manifest['eevee_commit'] != expected or manifest['spotify'] != '9.1.78' or manifest['flex']:
    raise ValueError('Cached build does not match pinned companion')
with ipa.open('rb') as stream:
    digest = hashlib.file_digest(stream, 'sha256').hexdigest()
if digest != manifest['sha256']:
    raise ValueError('Cached IPA checksum mismatch')
with zipfile.ZipFile(ipa) as archive:
    names = archive.namelist()
    for component in ('EeveeSpotify.dylib', 'EeveeSwiftProtobuf.framework', 'EeveeSpotify.bundle'):
        roots = {str(PurePosixPath(*PurePosixPath(n).parts[:PurePosixPath(n).parts.index(component) + 1]))
                 for n in names if component in PurePosixPath(n).parts}
        if len(roots) != 1:
            raise ValueError('Expected one ' + component)
        root = roots.pop()
        files = [n for n in names if n == root or n.startswith(root + '/')]
        for name in files:
            relative = PurePosixPath(component) / PurePosixPath(name).relative_to(root)
            if '..' in relative.parts:
                raise ValueError('Unsafe archive path')
            target = destination.joinpath(*relative.parts)
            if name.endswith('/'):
                target.mkdir(parents=True, exist_ok=True)
            else:
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(archive.read(name))
                target.chmod((archive.getinfo(name).external_attr >> 16) & 0o777 or 0o644)
(destination / '.source-commit').write_text(expected + '\n')
print('Reused verified EV1 components at ' + expected)
