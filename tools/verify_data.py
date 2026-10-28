#!/usr/bin/env python3
"""Читает готовые файлы карты отдельным кодом (не build_map.py) и проверяет их.
Использование: verify_data.py папка_с_файлами [expected.json]
С expected.json — сверяет маршруты. Без него — общая проверка и статистика."""
import sys, os, struct, json, heapq, math

E7 = 1e7


class Graph:
    def __init__(self, path):
        d = open(path, 'rb').read()
        self.d = d
        assert d[:4] == b'KGPH', 'неверный заголовок'
        (ver, self.N, self.S, self.A, self.P, self.nameCount, self.blobSize) = struct.unpack_from('<IIIIIII', d, 4)
        assert ver == 1
        self.minLat, self.minLon, self.cell, self.cols, self.rows = struct.unpack_from('<iiiII', d, 32)
        (self.oNodes, self.oFirst, self.oArcs, self.oSegs, self.oShapes, self.oNameOff, self.oBlob,
         self.oL0, self.oL1, self.oL2) = struct.unpack_from('<10I', d, 52)

    def node(self, i):
        return struct.unpack_from('<ii', self.d, self.oNodes + 8 * i)

    def first(self, i):
        return struct.unpack_from('<I', self.d, self.oFirst + 4 * i)[0]

    def arc(self, k):
        return struct.unpack_from('<I', self.d, self.oArcs + 4 * k)[0]

    def seg(self, s):
        u, v, nm, off, ln, tm, cnt, cls, fl = struct.unpack_from('<IIIIffHBB', self.d, self.oSegs + 28 * s)
        return dict(u=u, v=v, name=nm, off=off, len=ln, time=tm, cnt=cnt, cls=cls, flags=fl)

    def name(self, i):
        if i == 0xFFFFFFFF:
            return None
        a, b = struct.unpack_from('<II', self.d, self.oNameOff + 4 * i)
        return self.d[self.oBlob + a:self.oBlob + b].decode('utf-8')

    def find_node(self, lat, lon):
        li, lo = round(lat * E7), round(lon * E7)
        for i in range(self.N):
            if self.node(i) == (li, lo):
                return i
        return None

    def route(self, a, b):
        dist = {a: (0.0, 0.0, None, None)}
        pq = [(0.0, a)]
        while pq:
            d, u = heapq.heappop(pq)
            if u == b:
                break
            if d > dist[u][0]:
                continue
            for k in range(self.first(u), self.first(u + 1)):
                x = self.arc(k)
                s = self.seg(x & 0x7FFFFFFF)
                v = s['u'] if x & 0x80000000 else s['v']
                nd = d + s['time']
                if v not in dist or nd < dist[v][0] - 1e-9:
                    dist[v] = (nd, dist[u][1] + s['len'], u, self.name(s['name']))
                    heapq.heappush(pq, (nd, v))
        if b not in dist:
            return None
        names, cur = [], b
        while cur != a:
            _, _, prev, nm = dist[cur]
            names.append(nm)
            cur = prev
        names.reverse()
        merged = [n for i, n in enumerate(names) if i == 0 or names[i - 1] != n]
        return dist[b][0], dist[b][1], merged


def check_index(g, level_off, name):
    n = g.cols * g.rows
    starts = struct.unpack_from(f'<{n+1}I', g.d, level_off)
    assert starts[0] == 0
    assert all(starts[i] <= starts[i + 1] for i in range(n)), f'{name}: cellStart не по возрастанию'
    total = starts[n]
    ids = struct.unpack_from(f'<{total}I', g.d, level_off + 4 * (n + 1)) if total else ()
    assert all(i < g.S for i in ids), f'{name}: id вне диапазона'
    return total


def main():
    folder = sys.argv[1]
    g = Graph(os.path.join(folder, 'graph.bin'))
    print(f'graph: узлов {g.N}, сегментов {g.S}, дуг {g.A}, сетка {g.cols}x{g.rows}')
    for i, off in enumerate((g.oL0, g.oL1, g.oL2)):
        print(f'  индекс уровня {i}: записей {check_index(g, off, "L%d" % i)}')
    # дуги ссылаются на существующие сегменты и узлы
    bad = 0
    step = max(1, g.A // 200000)
    for k in range(0, g.A, step):
        x = g.arc(k)
        if (x & 0x7FFFFFFF) >= g.S:
            bad += 1
    assert bad == 0, 'дуги ссылаются на несуществующие сегменты'

    a = open(os.path.join(folder, 'areas.bin'), 'rb').read()
    assert a[:4] == b'KARE'
    feats, rings, pts = struct.unpack_from('<III', a, 8)
    print(f'areas: объектов {feats}, колец {rings}, точек {pts}')
    s = open(os.path.join(folder, 'search.bin'), 'rb').read()
    assert s[:4] == b'KSRC'
    cnt, scount = struct.unpack_from('<II', s, 8)
    oe, oso, osb = struct.unpack_from('<3I', s, 16)
    print(f'search: записей {cnt}, строк {scount}')
    # проверка строк
    offs = struct.unpack_from(f'<{scount+1}I', s, oso)
    first = s[osb + offs[0]:osb + offs[1]].decode('utf-8') if scount else ''
    print('  первая строка:', first)

    if len(sys.argv) > 2:
        exp = json.load(open(sys.argv[2], encoding='utf-8'))
        ok = True
        for q in exp['queries']:
            u = g.find_node(*q['from'])
            v = g.find_node(*q['to'])
            assert u is not None and v is not None, q['label']
            r = g.route(u, v)
            assert r is not None, q['label']
            t, l, names = r
            good = abs(t - q['timeS']) < 0.5 and abs(l - q['lengthM']) < 1.0 and names == q['streets']
            print(('ОК  ' if good else 'ОШИБКА '), q['label'], round(t, 2), round(l, 1), names)
            ok &= good
        assert g.A == exp['segmentsRoutable'], f'дуг {g.A}, ожидалось {exp["segmentsRoutable"]}'
        print('число дуг совпало:', g.A)
        assert ok, 'маршруты не совпали'
        print('ВСЁ СОВПАЛО')


if __name__ == '__main__':
    main()
