#!/usr/bin/env python3
"""TGA 产物统计断言: 亮像素占比 / 指定点采样。
用法: python3 tga_stats.py out.tga [--min-lit 40] [--probe x,y,r,g,b,tol]"""
import sys

def read_tga(path):
    d = open(path, 'rb').read()
    assert d[2] == 2, '仅支持未压缩 24bit TGA'
    w = d[12] | (d[13] << 8); h = d[14] | (d[15] << 8)
    i = 18
    return w, h, d[i:]

def main():
    path = sys.argv[1]
    args = sys.argv[2:]
    w, h, px = read_tga(path)
    lit = sum(1 for j in range(0, len(px)-2, 3) if px[j]+px[j+1]+px[j+2] > 40)
    pct = 100.0 * lit / (w*h)
    print(f'{path}: {w}x{h}, lit={pct:.1f}%')
    if '--min-lit' in args:
        need = float(args[args.index('--min-lit')+1])
        assert pct >= need, f'lit {pct:.1f}% < 下限 {need}%'
    ok = True
    while '--probe' in args:
        i = args.index('--probe')
        x, y, r, g, b, tol = map(int, args[i+1].split(','))
        args = args[:i] + args[i+7:]
        j = (y*w + x) * 3
        br, bg, bb = px[j+2], px[j+1], px[j]
        good = abs(br-r) <= tol and abs(bg-g) <= tol and abs(bb-b) <= tol
        print(f'  probe({x},{y}) = ({br},{bg},{bb}) vs ({r},{g},{b})±{tol}: {"OK" if good else "FAIL"}')
        ok &= good
    if not ok: sys.exit(1)

if __name__ == '__main__':
    main()
