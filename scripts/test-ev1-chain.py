import importlib.util
from pathlib import Path
import plistlib
import struct
import tempfile
import zipfile

spec = importlib.util.spec_from_file_location('chain', Path(__file__).with_name('ev1-chain.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def binary(dependencies=(), padding=True):
    segment = bytearray(152)
    struct.pack_into('<II', segment, 0, 0x19, 152)
    segment[8:14] = b'__TEXT'
    struct.pack_into('<I', segment, 64, 1)
    segment[72:78] = b'__text'
    segment[88:94] = b'__TEXT'
    struct.pack_into('<QI', segment, 112, 16, 512)
    commands = [segment]
    for dependency in dependencies:
        name = dependency.encode() + b'\0'
        size = (24 + len(name) + 7) & ~7
        commands.append((struct.pack('<6I', 0xC, size, 24, 2, 0, 0) + name).ljust(size, b'\0'))
    size = sum(map(len, commands))
    result = bytearray(1024)
    struct.pack_into('<8I', result, 0, 0xFEEDFACF, 0x100000C, 0, 6, len(commands), size, 0, 0)
    result[32:32 + size] = b''.join(commands)
    result[512:528] = b'official-code!!!?'
    if not padding:
        result[32 + size] = 1
    return bytes(result)


dependency = '@executable_path/Frameworks/EeveeSpotify.dylib'
original = binary()
fixed = module.add_dependency(original, dependency)
assert module.macho(fixed)[2] == [(0xC, dependency)]
assert fixed[512:] == original[512:]
assert module.add_dependency(fixed, dependency) == fixed
try:
    module.add_dependency(binary(padding=False), dependency)
    raise AssertionError('overwrote occupied header padding')
except ValueError:
    pass

with tempfile.TemporaryDirectory() as temp:
    temp = Path(temp)
    app = 'Payload/Spotify.app/'
    info = plistlib.dumps({'CFBundleExecutable': 'Spotify', 'CFBundleShortVersionString': '9.1.90'})
    contents = {app + 'Info.plist': info, app + 'Spotify': binary([dependency]),
                app + 'Frameworks/EeveeSpotify.dylib': b'EV1-data',
                app + 'Frameworks/EeveeSwiftProtobuf.framework/EeveeSwiftProtobuf': b'protobuf',
                app + 'EeveeSpotify.bundle/resource': b'resource'}
    for filename, entries in [('ev1.ipa', contents), ('patched.ipa', {
        **contents, app + 'Spotify': binary([dependency, '@rpath/spotifyglass.dylib']),
        app + 'Frameworks/spotifyglass.dylib': original})]:
        with zipfile.ZipFile(temp / filename, 'w') as z:
            for name, data in entries.items():
                z.writestr(name, data)
    module.chain(temp / 'ev1.ipa', temp / 'patched.ipa', temp / 'combined.ipa')
    # Lost EEVEE resources must fail closed.
    with zipfile.ZipFile(temp / 'bad.ipa', 'w') as z:
        for name, data in contents.items():
            if not name.endswith('/resource'):
                z.writestr(name, data)
        z.writestr(app + 'Frameworks/spotifyglass.dylib', original)
    try:
        module.chain(temp / 'ev1.ipa', temp / 'bad.ipa', temp / 'bad-out.ipa')
        raise AssertionError('accepted lost EV1 resources')
    except ValueError:
        pass
print('PASS: initializer dependency, unchanged code sections, archive preservation, rejection of missing resources')
