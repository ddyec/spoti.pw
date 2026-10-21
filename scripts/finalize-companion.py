#!/usr/bin/env python3
"""Check the combined source build and establish EV1-before-spoti initialization."""
import importlib.util
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import zipfile

spec = importlib.util.spec_from_file_location('companion_macho', Path(__file__).with_name('companion-macho.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

path = Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory() as temporary, zipfile.ZipFile(path) as original:
    names = original.namelist()
    if len(names) != len(set(names)):
        raise ValueError('Duplicate archive entries')
    infos = [n for n in names if n.startswith('Payload/') and n.endswith('.app/Info.plist') and n.count('/') == 2]
    if len(infos) != 1:
        raise ValueError('Expected one host app')
    app = infos[0][:-10]
    info = plistlib.loads(original.read(infos[0]))
    if info['CFBundleShortVersionString'] != '9.1.78':
        raise ValueError('Expected Spotify 9.1.78')
    loads = module.macho(original.read(app + info['CFBundleExecutable']))[2]
    deps = [name for _, name in loads if name.lower().endswith('/eeveespotify.dylib')]
    if len(deps) != 1:
        raise ValueError('Host must load exactly one EEVEE')
    def one(suffix):
        found = [n for n in names if n.startswith(app) and n.lower().endswith(suffix.lower())]
        if len(found) != 1:
            raise ValueError('Expected exactly one ' + suffix)
        return found[0]
    eevee = one('/EeveeSpotify.dylib')
    glass = one('/spotifyglass.dylib')
    if not any(name.lower().endswith('/spotifyglass.dylib') for _, name in loads):
        raise ValueError('Host does not load spoti.pw')
    if not any('EeveeSwiftProtobuf.framework/' in n for n in names):
        raise ValueError('Missing EEVEE protobuf framework')
    if not any('EeveeSpotify.bundle/' in n for n in names):
        raise ValueError('Missing EEVEE resources')
    if any('flex' in n.lower() and n.endswith('.dylib') for n in names):
        raise ValueError('Performance build must not include FLEX')
    fixed = module.add_dependency(original.read(glass), deps[0])
    binary = Path(temporary) / 'spotifyglass.dylib'
    binary.write_bytes(fixed)
    subprocess.run(['ldid', '-S', str(binary)], check=True)
    fixed = binary.read_bytes()
    if (0xC, deps[0]) not in module.macho(fixed)[2]:
        raise ValueError('Initializer dependency missing after ad-hoc signing')
    output = Path(temporary) / 'combined.ipa'
    with zipfile.ZipFile(output, 'w', compression=zipfile.ZIP_DEFLATED) as destination:
        for item in original.infolist():
            destination.writestr(item, fixed if item.filename == glass else original.read(item))
    with zipfile.ZipFile(output) as checked:
        if checked.testzip():
            raise ValueError('Output archive CRC failure')
        for name in names:
            if name != glass and original.getinfo(name).CRC != checked.getinfo(name).CRC:
                raise ValueError('Unexpected component change: ' + name)
    staging = path.with_suffix('.verified.ipa')
    try:
        shutil.copyfile(output, staging)
        os.replace(staging, path)
    finally:
        staging.unlink(missing_ok=True)
print('PASS: 9.1.78, one EEVEE + spoti.pw, resources, initializer order, no FLEX, valid archive')
