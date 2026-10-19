"""Validate EV1 preservation and establish an explicit initializer dependency.

The official kit/patcher stays intact. After patching, add a strong Mach-O
dependency from spotifyglass to the existing EV1 dylib. This makes EEVEE set the
raw lyricsSource key before Chroma constructors inspect it, independent of the
main executable's otherwise unspecified ordering between sibling dylibs.
"""
import argparse
import json
from pathlib import Path
import plistlib
import struct
import zipfile

DYLIBS = {0xC, 0x80000018, 0x8000001F, 0x80000023}


def macho(data):
    if len(data) < 32 or struct.unpack_from('<I', data)[0] != 0xFEEDFACF:
        raise ValueError('Expected a thin 64-bit Mach-O')
    count, size = struct.unpack_from('<II', data, 16)
    end = 32 + size
    if end > len(data):
        raise ValueError('Truncated load commands')
    off, libs, sections = 32, [], []
    for _ in range(count):
        cmd, length = struct.unpack_from('<II', data, off)
        if length < 8 or off + length > end:
            raise ValueError('Invalid load command')
        if cmd in DYLIBS:
            nameoff = struct.unpack_from('<I', data, off + 8)[0]
            if not 8 <= nameoff < length:
                raise ValueError('Invalid dylib name offset')
            name = data[off + nameoff:off + length].split(b'\0')[0].decode()
            libs.append((cmd, name))
        if cmd == 0x19:
            nsects = struct.unpack_from('<I', data, off + 64)[0]
            if 72 + 80 * nsects > length:
                raise ValueError('Truncated segment sections')
            for i in range(nsects):
                pos = off + 72 + i * 80
                name = data[pos:pos + 16].split(b'\0')[0].decode()
                segment = data[pos + 16:pos + 32].split(b'\0')[0].decode()
                nbytes, offset = struct.unpack_from('<QI', data, pos + 40)
                flags = struct.unpack_from('<I', data, pos + 64)[0]
                # Zero-fill sections have no on-disk contents.
                if offset and (flags & 0xFF) not in (1, 0xC, 0x12):
                    if offset + nbytes > len(data):
                        raise ValueError('Truncated section contents')
                    sections.append((offset, nbytes, segment, name))
        off += length
    if off != end:
        raise ValueError('Load-command count/size mismatch')
    return count, size, libs, sections


def add_dependency(data, dependency):
    count, size, libs, sections = macho(data)
    if not any(segment == '__TEXT' and name == '__text' for _, _, segment, name in sections):
        raise ValueError('No executable text section')
    existing = [cmd for cmd, name in libs if name == dependency]
    if existing:
        if 0xC not in existing:
            raise ValueError('EEVEE dependency must be a strong LC_LOAD_DYLIB')
        return data
    name = dependency.encode() + b'\0'
    length = (24 + len(name) + 7) & ~7
    start = 32 + size
    first = min((offset for offset, _, _, _ in sections), default=len(data))
    if start + length > first or any(data[start:start + length]):
        raise ValueError('No header padding for explicit EEVEE initializer dependency')
    command = struct.pack('<6I', 0xC, length, 24, 2, 0, 0) + name
    command = command.ljust(length, b'\0')
    result = bytearray(data)
    result[start:start + length] = command
    struct.pack_into('<II', result, 16, count + 1, size + length)
    # Only Mach-O header padding changes; executable sections remain identical.
    for offset, nbytes, _, _ in sections:
        if result[offset:offset + nbytes] != data[offset:offset + nbytes]:
            raise ValueError('Unexpected section modification')
    return bytes(result)


def host(z):
    names = z.namelist()
    if len(names) != len(set(names)):
        raise ValueError('Duplicate ZIP entries')
    candidates = [n for n in names if n.startswith('Payload/') and
                  n.endswith('.app/Info.plist') and n.count('/') == 2]
    if len(candidates) != 1:
        raise ValueError('Expected exactly one host app')
    info = plistlib.loads(z.read(candidates[0]))
    return candidates[0][:-len('Info.plist')], info


def chain(before_path, after_path, output_path):
    with zipfile.ZipFile(before_path) as before, zipfile.ZipFile(after_path) as after:
        app, info = host(before)
        out_app, out_info = host(after)
        version = info['CFBundleShortVersionString']
        if app != out_app or out_info['CFBundleShortVersionString'] != version:
            raise ValueError('Host app/version changed during patching')
        exe = app + info['CFBundleExecutable']
        before_loads = macho(before.read(exe))[2]
        loads = macho(after.read(exe))[2]
        for entry in before_loads:
            if entry not in loads:
                raise ValueError('An existing dependency was removed')
        deps = [name for _, name in before_loads if name.endswith('/EeveeSpotify.dylib')]
        if len(deps) != 1:
            raise ValueError('EV1 is not injected exactly once')
        dependency = deps[0]
        if any('spotifyglass' in name.lower() for name in before.namelist()):
            raise ValueError('Stage-one input already contains spoti.pw')
        protected = [n for n in before.namelist() if
                     'EeveeSpotify.dylib' in n or 'EeveeSwiftProtobuf.framework/' in n
                     or 'EeveeSpotify.bundle/' in n]
        if not any(n.endswith('/EeveeSpotify.dylib') for n in protected):
            raise ValueError('EV1 dylib missing')
        if not any('EeveeSwiftProtobuf.framework/' in n for n in protected):
            raise ValueError('EV1 protobuf framework missing')
        if not any('EeveeSpotify.bundle/' in n for n in protected):
            raise ValueError('EV1 resource bundle missing')
        for name in protected:
            if name not in after.namelist() or before.read(name) != after.read(name):
                raise ValueError('EEVEE content was lost or changed: ' + name)
        dylib = app + 'Frameworks/spotifyglass.dylib'
        original = after.read(dylib)
        fixed = add_dependency(original, dependency)
        output = Path(output_path)
        with zipfile.ZipFile(output, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=6) as z:
            for entry in after.infolist():
                z.writestr(entry, fixed if entry.filename == dylib else after.read(entry))
        # Verify the bytes actually written, rather than only the in-memory edit.
        with zipfile.ZipFile(output) as z:
            if (0xC, dependency) not in macho(z.read(dylib))[2]:
                raise ValueError('Final IPA has no strong initializer dependency')
            for name in protected:
                if before.read(name) != z.read(name):
                    raise ValueError('Final EV1 preservation failed: ' + name)
        report = {'spotify': version, 'dependency': dependency,
                  'eevee_files_preserved': len(protected),
                  'official_chroma_sections_unchanged': True,
                  'runtime_verified': False}
        output.with_suffix('.json').write_text(json.dumps(report, indent=2), encoding='utf-8')
        print(json.dumps(report, indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('ev1')
    parser.add_argument('patched')
    parser.add_argument('output')
    args = parser.parse_args()
    chain(args.ev1, args.patched, args.output)
