#!/usr/bin/env python3
"""Cache expensive Icon Composer output; merge only icon metadata into the current plist."""
import hashlib
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys

mode, work, app = sys.argv[1], Path(sys.argv[2]), sys.argv[3]
root = Path(__file__).resolve().parents[1]
folder = work / app
car, info = folder / 'Assets.car', folder / 'Info.plist'
key_file = work / '.icon-cache-key'
if mode == 'restore':
    digest = hashlib.sha256(b'app-icons-cache-v1')
    digest.update(car.read_bytes())
    for path in sorted((root / 'icons').rglob('*')) + [root / 'scripts/car-tool.m', root / 'scripts/app-icons.sh']:
        if path.is_file():
            digest.update(str(path.relative_to(root)).encode())
            digest.update(path.read_bytes())
    digest.update(subprocess.check_output(['xcodebuild', '-version']))
    key_file.write_text(digest.hexdigest())
cache = root / '.build-cache/app-icons' / key_file.read_text()

def hashes(directory):
    return {str(p.relative_to(directory)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in directory.rglob('*') if p.is_file() and p.name != 'checksums.json'}

if mode == 'restore':
    if not (cache / 'checksums.json').is_file():
        sys.exit(1)
    if hashes(cache) != json.loads((cache / 'checksums.json').read_text()):
        raise ValueError('Icon cache checksum mismatch')
    subprocess.run(['xcrun', 'assetutil', '-Z', str(cache / 'Assets.car')], check=True, stdout=subprocess.DEVNULL)
    current = plistlib.loads(info.read_bytes())
    alternates = plistlib.loads((cache / 'alternates.plist').read_bytes())
    for key, value in alternates.items():
        current.setdefault(key, {})['CFBundleAlternateIcons'] = value
    info.write_bytes(plistlib.dumps(current, fmt=plistlib.FMT_BINARY))
    shutil.copyfile(cache / 'Assets.car', car)
    shutil.copytree(cache / 'SGAppIconPreviews', folder / 'SGAppIconPreviews', dirs_exist_ok=True)
    print('Reused alternate icons for the same source assets, artwork and Xcode')
elif mode == 'save':
    cache.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(car, cache / 'Assets.car')
    shutil.copytree(folder / 'SGAppIconPreviews', cache / 'SGAppIconPreviews', dirs_exist_ok=True)
    current = plistlib.loads(info.read_bytes())
    alternates = {key: current[key]['CFBundleAlternateIcons'] for key in ('CFBundleIcons', 'CFBundleIcons~ipad')}
    (cache / 'alternates.plist').write_bytes(plistlib.dumps(alternates))
    (cache / 'checksums.json').write_text(json.dumps(hashes(cache), sort_keys=True))
else:
    raise ValueError('Unknown cache mode')
