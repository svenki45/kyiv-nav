#!/usr/bin/env python3
"""Делает маленький выдуманный город (tools/testdata/test.opl) и ожидаемые ответы
для проверки маршрутов (tools/testdata/expected.json). Ответы считаются
отдельным, простым способом — независимо от build_map.py."""
import json, math, heapq, os, sys

E7 = 1e7
LAT0, LON0 = 50.4500, 30.5200
DLAT, DLON = 0.002, 0.003
ROWS, COLS = 6, 6
M_PER_DEG = 6371000.0 * math.pi / 180.0


def esc(s):
    out = []
    for ch in s:
        if ch in ' ,=%@\n\t' or ord(ch) < 32:
            out.append('%%%x%%' % ord(ch))
        else:
            out.append(ch)
    return ''.join(out)


def tagstr(tags):
    return ','.join(f'{esc(k)}={esc(v)}' for k, v in tags.items())


def nid(r, c):
    return 1000 + r * 10 + c


def coord(r, c):
    return (round(LAT0 + r * DLAT, 7), round(LON0 + c * DLON, 7))


def seg_len(pts):
    t = 0.0
    for (a1, o1), (a2, o2) in zip(pts, pts[1:]):
        # как в build_map.py, но на e7-целых
        a1, o1, a2, o2 = (int(round(v * E7)) for v in (a1, o1, a2, o2))
        dy = (a2 - a1) / E7 * M_PER_DEG
        dx = (o2 - o1) / E7 * M_PER_DEG * math.cos(math.radians((a1 + a2) / 2 / E7))
        t += math.hypot(dx, dy)
    return t


def main():
    out = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'testdata')
    os.makedirs(out, exist_ok=True)

    nodes = {}
    for r in range(ROWS):
        for c in range(COLS):
            nodes[nid(r, c)] = coord(r, c)
    # кривая диагональ: промежуточные узлы
    diag_mid = [(9001, (LAT0 + 0.003, LON0 + 0.004)), (9002, (LAT0 + 0.007, LON0 + 0.011))]
    for i, p in diag_mid:
        nodes[i] = p
    nodes[9100] = (LAT0 + 3 * DLAT + 0.001, LON0 + 3 * DLON)  # тупик

    ways = []  # (id, [узлы], теги)
    # горизонтальные улицы
    for r in range(ROWS):
        tags = {'highway': 'residential', 'name': f'Вулиця Рядна {r}'}
        if r == 2:
            tags = {'highway': 'primary', 'name': 'Проспект Тестовий', 'maxspeed': '60'}
        if r == 4:
            tags['oneway'] = 'yes'  # только на восток
        ways.append((2000 + r, [nid(r, c) for c in range(COLS)], tags))
    # вертикальные улицы
    for c in range(COLS):
        tags = {'highway': 'residential', 'name': f'Вулиця Колонна {c}'}
        if c == 5:
            tags = {'highway': 'tertiary', 'name': 'Бульвар Східний'}
        ways.append((3000 + c, [nid(r, c) for r in range(ROWS)], tags))
    # диагональ
    ways.append((4001, [nid(0, 0), 9001, 9002, nid(5, 5)],
                 {'highway': 'secondary', 'name': 'Діагональна, швидка', 'maxspeed': '60'}))
    # тупик
    ways.append((4002, [nid(3, 3), 9100], {'highway': 'residential', 'name': 'Глухий провулок'}))
    # закрытый проезд (service private)
    ways.append((4003, [nid(1, 1), nid(1, 2)],
                 {'highway': 'service', 'access': 'private', 'name': 'Приватний проїзд'}))

    # вода
    base = 7000
    wl = [(50.4550, 30.5400), (50.4550, 30.5480), (50.4580, 30.5480), (50.4580, 30.5400)]
    for i, p in enumerate(wl):
        nodes[base + 1 + i] = p
    ways.append((6000, [base + 1, base + 2, base + 3, base + 4, base + 1],
                 {'natural': 'water', 'name': 'Озеро Тестове'}))
    # мультиполигон: два внешних куска и остров
    mp = [(50.4600, 30.5200), (50.4600, 30.5300), (50.4660, 30.5300), (50.4660, 30.5200)]
    for i, p in enumerate(mp):
        nodes[7100 + i] = p
    ways.append((6200, [7100, 7101, 7102], {}))
    ways.append((6201, [7102, 7103, 7100], {}))
    isl = [(50.4620, 30.5230), (50.4620, 30.5260), (50.4640, 30.5260), (50.4640, 30.5230)]
    for i, p in enumerate(isl):
        nodes[7200 + i] = p
    ways.append((6202, [7200, 7201, 7202, 7203, 7200], {}))
    # река
    for i, p in enumerate([(50.4520, 30.5100), (50.4580, 30.5150), (50.4640, 30.5120)]):
        nodes[7300 + i] = p
    ways.append((6300, [7300, 7301, 7302], {'waterway': 'river', 'name': 'Річка Тестова'}))
    # лес
    for i, p in enumerate([(50.4400, 30.5400), (50.4400, 30.5500), (50.4440, 30.5500), (50.4440, 30.5400)]):
        nodes[7400 + i] = p
    ways.append((6400, [7400, 7401, 7402, 7403, 7400], {'natural': 'wood'}))

    # точки с названиями
    named = [
        (9500, coord(2, 2), {'place': 'city', 'name': 'Тестоград'}),
        (9501, (50.4700, 30.5800), {'place': 'village', 'name': 'Мале Село'}),
        (9502, coord(3, 4), {'amenity': 'cafe', 'name': 'Кафе Тест'}),
        (9503, coord(1, 3), {'amenity': 'fuel', 'name': 'АЗС Швидка'}),
    ]
    for i, p, t in named:
        nodes[i] = p

    # ------- OPL
    lines = []
    for i in sorted(nodes):
        la, lo = nodes[i]
        tg = ''
        for nid_, p, t in named:
            if nid_ == i:
                tg = tagstr(t)
        lines.append(f'n{i} v1 dV c1 t2020-01-01T00:00:00Z i1 uТест%20користувач T{tg} x{lo} y{la}')
    for wid, nl, tags in ways:
        lines.append(f'w{wid} v1 dV c1 t2020-01-01T00:00:00Z i1 uTest T{tagstr(tags)} N' +
                     ','.join(f'n{n}' for n in nl))
    lines.append('r8000 v1 dV c1 t2020-01-01T00:00:00Z i1 uTest Ttype=multipolygon,natural=water M'
                 'w6200@outer,w6201@outer,w6202@inner')
    with open(os.path.join(out, 'test.opl'), 'w', encoding='utf-8') as f:
        f.write('\n'.join(lines) + '\n')

    # ------- независимая модель графа (сегменты между перекрёстками)
    junction = {nid(r, c) for r in range(ROWS) for c in range(COLS)} | {9001 - 9001 + nid(0, 0), nid(5, 5), 9100}
    cls_of = {'primary': 2, 'secondary': 3, 'tertiary': 4, 'residential': 6, 'service': 8}
    dflt = [110, 90, 70, 60, 50, 40, 30, 10, 15]
    edges = {}  # u -> [(v, time, length, name)]
    for wid, nl, tags in ways:
        hw = tags.get('highway')
        if hw is None:
            continue
        cls = cls_of[hw]
        spd = dflt[cls]
        if 'maxspeed' in tags:
            spd = int(tags['maxspeed']) * 0.85
        routable = not (tags.get('access') == 'private')
        if not routable:
            continue
        fb = 1 if tags.get('oneway') == 'yes' else 3
        start = 0
        for i in range(1, len(nl)):
            if nl[i] in junction:
                chain = nl[start:i + 1]
                length = seg_len([nodes[n] for n in chain])
                t = length / (spd / 3.6) + 2.0
                u, v = chain[0], chain[-1]
                if fb & 1:
                    edges.setdefault(u, []).append((v, t, length, tags['name']))
                if fb & 2:
                    edges.setdefault(v, []).append((u, t, length, tags['name']))
                start = i

    def dijkstra(src, dst):
        dist = {src: (0.0, 0.0, None, None)}
        pq = [(0.0, src)]
        while pq:
            d, u = heapq.heappop(pq)
            if u == dst:
                break
            if d > dist[u][0]:
                continue
            for v, t, l, nm in edges.get(u, []):
                nd = d + t
                if v not in dist or nd < dist[v][0] - 1e-9:
                    dist[v] = (nd, dist[u][1] + l, u, nm)
                    heapq.heappush(pq, (nd, v))
        if dst not in dist:
            return None
        names = []
        cur = dst
        while cur != src:
            _, _, prev, nm = dist[cur]
            names.append(nm)
            cur = prev
        names.reverse()
        merged = [n for i, n in enumerate(names) if i == 0 or names[i - 1] != n]
        return dist[dst][0], dist[dst][1], merged

    queries = []
    for label, a, b in [
        ('диагональ', nid(0, 0), nid(5, 5)),
        ('поперёк сетки', nid(0, 1), nid(5, 4)),
        ('против односторонней', nid(4, 5), nid(4, 0)),
        ('по односторонней', nid(4, 0), nid(4, 5)),
        ('по проспекту', nid(2, 0), nid(2, 5)),
        ('рядом', nid(1, 1), nid(1, 2)),
    ]:
        res = dijkstra(a, b)
        assert res is not None, label
        t, l, names = res
        queries.append({
            'label': label,
            'from': list(nodes[a]), 'to': list(nodes[b]),
            'timeS': round(t, 3), 'lengthM': round(l, 3), 'streets': names,
        })
    exp = {
        'queries': queries,
        'segmentsRoutable': sum(len(v) for v in edges.values()),
        'names': {'city': 'Тестоград', 'cafe': 'Кафе Тест'},
    }
    with open(os.path.join(out, 'expected.json'), 'w', encoding='utf-8') as f:
        json.dump(exp, f, ensure_ascii=False, indent=1)
    print('тестовые данные готовы:', len(nodes), 'узлов,', len(ways), 'путей')
    for q in queries:
        print(q['label'], q['timeS'], q['lengthM'], q['streets'])


if __name__ == '__main__':
    main()
