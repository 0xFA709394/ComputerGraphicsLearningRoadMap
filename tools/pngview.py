#!/usr/bin/env python3
"""PNG → ASCII 亮度图(纯标准库)。
本仓库 headless 验证方法论的核心工具: 无屏环境下"看"渲染结果。
用法: python3 pngview.py image.png [cols rows]"""
import sys, zlib, struct

def read_png(path):
    d = open(path, 'rb').read()
    assert d[:8] == b'\x89PNG\r\n\x1a\n', 'not png'
    pos, w, h, bit, ct = 8, 0, 0, 0, 0
    idat = b''
    while pos < len(d):
        ln, typ = struct.unpack('>I4s', d[pos:pos+8]); pos += 8
        chunk = d[pos:pos+ln]; pos += ln + 4
        if typ == b'IHDR': w, h, bit, ct = struct.unpack('>IIBB', chunk[:10])
        elif typ == b'IDAT': idat += chunk
        elif typ == b'IEND': break
    assert bit == 8, f'bit={bit}'
    ch = {0: 1, 2: 3, 4: 2, 6: 4}[ct]
    raw = zlib.decompress(idat)
    stride = w * ch
    out = bytearray(); prev = bytearray(stride); p = 0
    for y in range(h):
        f = raw[p]; p += 1
        row = bytearray(raw[p:p+stride]); p += stride
        if f == 1:
            for i in range(ch, stride): row[i] = (row[i] + row[i-ch]) & 255
        elif f == 2:
            for i in range(stride): row[i] = (row[i] + prev[i]) & 255
        elif f == 3:
            for i in range(stride):
                a = row[i-ch] if i >= ch else 0
                row[i] = (row[i] + ((a + prev[i]) >> 1)) & 255
        elif f == 4:
            for i in range(stride):
                a = row[i-ch] if i >= ch else 0
                b = prev[i]; c = prev[i-ch] if i >= ch else 0
                pa, pb, pc = abs(b-c), abs(a-c), abs(a+b-2*c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                row[i] = (row[i] + pr) & 255
        out += row; prev = row
    return w, h, ch, out

def main():
    path = sys.argv[1]
    cols = int(sys.argv[2]) if len(sys.argv) > 2 else 96
    rows = int(sys.argv[3]) if len(sys.argv) > 3 else 34
    w, h, ch, px = read_png(path)
    chars = ' .:-=+*#%@'
    print(f'{w}x{h} ch={ch}')
    for r in range(rows):
        line = ''
        for c in range(cols):
            x, y = int(c*w/cols), int(r*h/rows)
            i = (y*w + x) * ch
            lum = (px[i]*299 + px[i+1]*587 + px[i+2]*114) // 1000
            line += chars[min(9, lum*10//256)]
        print(line)

if __name__ == '__main__':
    main()
