#!/usr/bin/env python3
"""最小 AXML(二进制 XML) 解码器：把 APK 里的 res/xx.xml 还原成普通 XML 文本。"""
import struct, sys, zipfile

RES_STRING_POOL = 0x0001
RES_XML = 0x0003
RES_XML_START_NS = 0x0100
RES_XML_END_NS = 0x0101
RES_XML_START_ELEMENT = 0x0102
RES_XML_END_ELEMENT = 0x0103
RES_XML_RESOURCE_MAP = 0x0180


def parse_string_pool(buf, off):
    # header: type,headerSize,size (8) then stringCount, styleCount, flags, stringsStart, stylesStart
    _, hsize, size = struct.unpack('<HHI', buf[off:off + 8])
    cnt, style_cnt, flags, str_start, style_start = struct.unpack('<IIIII', buf[off + 8:off + 28])
    utf8 = (flags & (1 << 8)) != 0
    offsets = struct.unpack('<%dI' % cnt, buf[off + 28:off + 28 + 4 * cnt])
    base = off + str_start
    out = []
    for o in offsets:
        p = base + o
        if utf8:
            # u16len (maybe 2 bytes), u8len, bytes, 0
            n = buf[p]
            if n & 0x80:
                n = ((n & 0x7f) << 8) | buf[p + 1]
                p += 2
            else:
                p += 1
            m = buf[p]
            if m & 0x80:
                m = ((m & 0x7f) << 8) | buf[p + 1]
                p += 2
            else:
                p += 1
            out.append(buf[p:p + m].decode('utf-8', 'replace'))
        else:
            n = struct.unpack('<H', buf[p:p + 2])[0]
            p += 2
            if n & 0x8000:
                n = ((n & 0x7fff) << 16) | struct.unpack('<H', buf[p:p + 2])[0]
                p += 2
            out.append(buf[p:p + 2 * n].decode('utf-16-le', 'replace'))
    return out


def fmt_value(dtype, data, strings):
    if dtype == 0x03:
        return strings[data] if data < len(strings) else ''
    if dtype == 0x10:
        return str(data if data < 0x80000000 else data - 0x100000000)
    if dtype == 0x11:
        return hex(data)
    if dtype == 0x12:
        return 'true' if data else 'false'
    if dtype == 0x04:
        return repr(struct.unpack('<f', struct.pack('<I', data))[0])
    if dtype == 0x1c:
        return '#%08x' % data
    return str(data)


def decode(buf):
    strings = []
    res_map = []
    lines = []
    off = 0
    depth = 0
    while off + 8 <= len(buf):
        ctype, hsize, size = struct.unpack('<HHI', buf[off:off + 8])
        if size == 0:
            break
        if ctype == RES_XML:
            off += hsize          # 容器头，跳过继续解析子块
            continue
        if ctype == RES_STRING_POOL:
            strings = parse_string_pool(buf, off)
        elif ctype == RES_XML_RESOURCE_MAP:
            n = (size - hsize) // 4
            res_map = list(struct.unpack('<%dI' % n, buf[off + hsize:off + hsize + 4 * n]))
        elif ctype == RES_XML_START_ELEMENT:
            p = off + hsize            # hsize 已含 lineNumber/comment
            ns, name = struct.unpack('<II', buf[p:p + 8])
            attr_start, attr_size, attr_count = struct.unpack('<HHH', buf[p + 8:p + 14])
            attrs = []
            for i in range(attr_count):
                a = p + attr_start + i * attr_size
                ans, aname, araw = struct.unpack('<III', buf[a:a + 12])
                tsize, res0, dtype = struct.unpack('<HBB', buf[a + 12:a + 16])
                data = struct.unpack('<I', buf[a + 16:a + 20])[0]
                nm = strings[aname] if aname < len(strings) else '?'
                attrs.append((nm, fmt_value(dtype, data, strings)))
            name_s = strings[name] if name < len(strings) else '?'
            pad = '  ' * depth
            lines.append('%s<%s%s>' % (pad, name_s,
                         ''.join(' %s="%s"' % (k, v) for k, v in attrs) if attrs else ''))
            depth += 1
        elif ctype == RES_XML_END_ELEMENT:
            depth = max(0, depth - 1)
            p = off + hsize
            name = struct.unpack('<I', buf[p + 4:p + 8])[0]
            name_s = strings[name] if name < len(strings) else '?'
            lines.append('%s</%s>' % ('  ' * depth, name_s))
        off += size
    return '\n'.join(lines)


if __name__ == '__main__':
    apk, entry = sys.argv[1], sys.argv[2]
    with zipfile.ZipFile(apk) as z:
        buf = z.read(entry)
    print(decode(buf))
