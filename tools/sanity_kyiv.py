#!/usr/bin/env python3
"""Проверка настоящей карты: есть ли Киев, строится ли маршрут, находится ли поиск.
Использование: sanity_kyiv.py папка_с_файлами"""
import sys, os, struct, math, heapq, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from verify_data import Graph

E7 = 1e7


def nearest_node(g, lat, lon, step=1):
    la, lo = round(lat * E7), round(lon * E7)
    best, bi = None, None
    c = math.cos(math.radians(lat))
    for i in range(0, g.N, step):
        a, b = g.node(i)
        d = (a - la) ** 2 + ((b - lo) * c) ** 2
        if best is None or d < best:
            best, bi = d, i
    return bi, math.sqrt(best) / E7 * 111195


def main():
    folder = sys.argv[1]
    t0 = time.time()
    g = Graph(os.path.join(folder, 'graph.bin'))
    print(f'graph: узлов {g.N}, сегментов {g.S}, дуг {g.A}, ячеек {g.cols}x{g.rows}')
    print(f'границы: lat {g.minLat/E7:.3f}..{(g.minLat+g.rows*g.cell)/E7:.3f}, '
          f'lon {g.minLon/E7:.3f}..{(g.minLon+g.cols*g.cell)/E7:.3f}')
    # классы
    cnt = [0] * 9
    flags = {'fwd_only': 0, 'both': 0, 'none': 0}
    for s in range(g.S):
        sg = g.seg(s)
        cnt[sg['cls']] += 1
        f = sg['flags'] & 3
        flags['both' if f == 3 else ('none' if f == 0 else 'fwd_only')] += 1
    print('сегментов по классам (motorway..service):', cnt)
    print('направления:', flags)

    # связность: объединяем узлы, соединённые дугами (в любую сторону)
    parent = list(range(g.N))

    def find(x):
        while parent[x] != x:
            parent[x] = parent[parent[x]]
            x = parent[x]
        return x

    for u in range(g.N):
        for k in range(g.first(u), g.first(u + 1)):
            x = g.arc(k)
            sg = g.seg(x & 0x7FFFFFFF)
            v = sg['u'] if x & 0x80000000 else sg['v']
            ru, rv = find(u), find(v)
            if ru != rv:
                parent[ru] = rv
    sizes = {}
    for i in range(g.N):
        r = find(i)
        sizes[r] = sizes.get(r, 0) + 1
    big = sorted(sizes.values(), reverse=True)
    giant = max(sizes, key=sizes.get)
    print(f'компонент связности: {len(sizes)}, крупнейшие: {big[:5]}, '
          f'доля главной: {sizes[giant]/g.N:.1%}')
    isolated = sum(1 for i in range(g.N) if g.first(i) == g.first(i + 1))
    print(f'узлов без выходящих дуг: {isolated}')

    def nearest_in_giant(lat, lon):
        la, lo = round(lat * E7), round(lon * E7)
        c = math.cos(math.radians(lat))
        best, bi = None, None
        for i in range(g.N):
            if find(i) != giant or g.first(i) == g.first(i + 1):
                continue
            a, b = g.node(i)
            d = (a - la) ** 2 + ((b - lo) * c) ** 2
            if best is None or d < best:
                best, bi = d, i
        return bi, math.sqrt(best) / E7 * 111195

    points = {
        'Майдан Независимости': (50.4501, 30.5234),
        'Бориспольский аэропорт': (50.3450, 30.8947),
        'Белая Церковь': (49.8000, 30.1167),
        'Вышгород': (50.5833, 30.4833),
    }
    nodes = {}
    for name, (la, lo) in points.items():
        i0, d0 = nearest_node(g, la, lo)
        i, d = nearest_in_giant(la, lo)
        nodes[name] = i
        print(f'{name}: ближайший узел в {d0:.0f} м, в главной сети в {d:.0f} м '
              f'(в главной сети: {find(i0) == giant})')

    def route(a, b):
        dist = {a: (0.0, 0.0, None, None)}
        pq = [(0.0, a)]
        while pq:
            d, u = heapq.heappop(pq)
            if u == b:
                break
            if d > dist[u][0]:
                continue
            for k in range(g.first(u), g.first(u + 1)):
                x = g.arc(k)
                s = g.seg(x & 0x7FFFFFFF)
                v = s['u'] if x & 0x80000000 else s['v']
                nd = d + s['time']
                if v not in dist or nd < dist[v][0] - 1e-9:
                    dist[v] = (nd, dist[u][1] + s['len'], u, g.name(s['name']))
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

    for a, b in [('Майдан Независимости', 'Бориспольский аэропорт'),
                 ('Майдан Независимости', 'Вышгород'),
                 ('Майдан Независимости', 'Белая Церковь')]:
        t1 = time.time()
        r = route(nodes[a], nodes[b])
        if r is None:
            print(f'{a} -> {b}: МАРШРУТА НЕТ')
        else:
            t, l, names = r
            print(f'{a} -> {b}: {l/1000:.1f} км, {t/60:.0f} мин, улиц в маршруте {len(names)}, '
                  f'вычислено за {time.time()-t1:.1f} с')
            print('   начало:', names[:4], ' конец:', names[-3:])

    # поиск
    s = open(os.path.join(folder, 'search.bin'), 'rb').read()
    cnt_e, scount = struct.unpack_from('<II', s, 8)
    oe, oso, osb = struct.unpack_from('<3I', s, 16)
    offs = struct.unpack_from(f'<{scount+1}I', s, oso)

    def string(i):
        return s[osb + offs[i]:osb + offs[i + 1]].decode('utf-8')

    kinds = {0: 0, 1: 0, 2: 0}
    want = {'хрещатик': None, 'київ': None, 'бориспіль': None, 'сільпо': 0, 'атб': 0}
    for i in range(cnt_e):
        k, sub, _, la, lo, ni, ex = struct.unpack_from('<BBHiiII', s, oe + 20 * i)
        kinds[k] += 1
        nm = string(ni).lower()
        for w in list(want):
            if nm == w or (w in ('сільпо', 'атб') and w in nm):
                if want[w] is None:
                    print(f'найдено «{w}»: {string(ni)} ({la/E7:.4f}, {lo/E7:.4f}) вид {k}')
                    want[w] = 1
                elif isinstance(want[w], int):
                    want[w] += 1
    print('в поиске: улиц %d, нас. пунктов %d, мест %d' % (kinds[0], kinds[1], kinds[2]))
    print('«сільпо»/«атб» (число мест):', want['сільпо'], want['атб'])
    a = open(os.path.join(folder, 'areas.bin'), 'rb').read()
    feats, rings, pts = struct.unpack_from('<III', a, 8)
    kc = {}
    for i in range(feats):
        k = a[struct.unpack_from('<I', a, 40)[0] + 32 * i]
        kc[k] = kc.get(k, 0) + 1
    print(f'области: объектов {feats}, колец {rings}, точек {pts}, по видам {kc}')
    print(f'проверка заняла {time.time()-t0:.0f} с')


if __name__ == '__main__':
    main()
