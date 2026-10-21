"""Thin arm64 Mach-O parsing and strong initializer dependency insertion."""
import struct

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

