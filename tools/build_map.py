#!/usr/bin/env python3
"""Собирает файлы карты (graph.bin, areas.bin, search.bin, manifest.json)
из OSM-данных в текстовом формате OPL. Формат файлов: docs/FORMAT.md.
Только стандартная библиотека Python.

Использование: build_map.py вход.opl папка_вывода
"""
import sys, os, re, math, struct, json, hashlib, time
from array import array

assert sys.byteorder == 'little'
assert array('I').itemsize == 4 and array('i').itemsize == 4

E7 = 10_000_000
R_EARTH = 6371000.0
M_PER_DEG = R_EARTH * math.pi / 180.0
NONE32 = 0xFFFFFFFF
CELL = 100_000  # 0.01 градуса

HW_CLS = {
    'motorway': 0, 'motorway_link': 0, 'trunk': 1, 'trunk_link': 1,
    'primary': 2, 'primary_link': 2, 'secondary': 3, 'secondary_link': 3,
    'tertiary': 4, 'tertiary_link': 4, 'unclassified': 5, 'road': 5,
    'residential': 6, 'living_street': 7, 'service': 8,
}
DEF_SPEED = [110, 90, 70, 60, 50, 40, 30, 10, 15]

KEEP_KEYS = {
    'highway', 'name', 'name:uk', 'ref', 'oneway', 'junction', 'maxspeed',
    'access', 'motor_vehicle', 'vehicle', 'service', 'bridge', 'tunnel',
    'natural', 'waterway', 'landuse', 'leisure', 'type', 'place',
    'amenity', 'shop', 'tourism',
}

_unesc = re.compile(r'%([0-9a-fA-F]*)%')


def unesc(s):
    if '%' not in s:
        return s
    return _unesc.sub(lambda m: chr(int(m.group(1), 16)), s)


def parse_tags(field, keep=KEEP_KEYS):
    tags = {}
    if not field:
        return tags
    for kv in field.split(','):
        k, _, v = kv.partition('=')
        k = unesc(k)
        if k in keep:
            tags[k] = unesc(v)
    return tags


def e7(v):
    return int(round(v * E7))


# ---------------------------------------------------------------- чтение OPL

def read_opl(path):
    nodes = {}        # id -> (lat7, lon7)
    named = []        # (lat7, lon7, tags) именованные точки
    ways = {}         # id -> (список узлов, теги)
    rels = []         # (теги, [(тип, id, роль)])
    t0 = time.time()
    with open(path, encoding='utf-8') as f:
        for line in f:
            c = line[:1]
            if c == 'n':
                parts = line.rstrip('\n').split(' ')
                x = y = None
                tf = None
                for p in parts[1:]:
                    ch = p[:1]
                    if ch == 'x':
                        x = p[1:]
                    elif ch == 'y':
                        y = p[1:]
                    elif ch == 'T':
                        tf = p[1:]
                if not x or not y:
                    continue
                lat, lon = e7(float(y)), e7(float(x))
                nid = int(parts[0][1:])
                nodes[nid] = (lat, lon)
                if tf and 'name' in tf:
                    tags = parse_tags(tf)
                    if tags.get('name:uk') or tags.get('name'):
                        named.append((lat, lon, tags))
            elif c == 'w':
                parts = line.rstrip('\n').split(' ')
                wid = int(parts[0][1:])
                tf = None
                nl = []
                for p in parts[1:]:
                    ch = p[:1]
                    if ch == 'T':
                        tf = p[1:]
                    elif ch == 'N':
                        nl = [int(s[1:]) for s in p[1:].split(',') if s]
                ways[wid] = (nl, parse_tags(tf))
            elif c == 'r':
                parts = line.rstrip('\n').split(' ')
                tf = None
                members = []
                for p in parts[1:]:
                    ch = p[:1]
                    if ch == 'T':
                        tf = p[1:]
                    elif ch == 'M':
                        for m in p[1:].split(','):
                            if not m:
                                continue
                            ref, _, role = m.partition('@')
                            members.append((ref[0], int(ref[1:]), unesc(role)))
                tags = parse_tags(tf)
                if tags.get('type') == 'multipolygon':
                    rels.append((tags, members))
    print(f'прочитано: узлов {len(nodes)}, путей {len(ways)}, отношений {len(rels)}, '
          f'именованных точек {len(named)} за {time.time()-t0:.1f} с', flush=True)
    return nodes, named, ways, rels


# ------------------------------------------------------------------- дороги

def seg_length(pts):
    total = 0.0
    for i in range(len(pts) - 1):
        a1, o1 = pts[i]
        a2, o2 = pts[i + 1]
        dy = (a2 - a1) / E7 * M_PER_DEG
        dx = (o2 - o1) / E7 * M_PER_DEG * math.cos(math.radians((a1 + a2) / 2 / E7))
        total += math.hypot(dx, dy)
    return total


def parse_speed(tags, cls, hw):
    spd = float(DEF_SPEED[cls])
    ms = tags.get('maxspeed')
    if ms:
        m = re.match(r'\s*(\d+)', ms)
        if m:
            spd = float(m.group(1)) * 0.85
    if hw.endswith('_link'):
        spd = min(spd, 40.0)
    return max(spd, 5.0)


def direction_flags(tags, hw):
    """бит0 — вперёд, бит1 — назад"""
    ow = tags.get('oneway')
    if ow in ('yes', '1', 'true'):
        fb = 1
    elif ow == '-1':
        fb = 2
    elif ow == 'no':
        fb = 3
    elif tags.get('junction') in ('roundabout', 'circular'):
        fb = 1
    elif hw in ('motorway', 'motorway_link'):
        fb = 1
    else:
        fb = 3
    return fb


def is_routable(tags):
    if tags.get('access') in ('no', 'private') and tags.get('motor_vehicle') not in ('yes', 'permissive', 'destination'):
        return False
    if tags.get('motor_vehicle') in ('no', 'private'):
        return False
    if tags.get('vehicle') in ('no', 'private'):
        return False
    if tags.get('service') in ('driveway', 'parking_aisle', 'drive-through', 'emergency_access'):
        return False
    return True


def build_graph(nodes, ways):
    t0 = time.time()
    prepared = []
    use = {}
    endpoints = set()
    for wid, (nl, tags) in ways.items():
        hw = tags.get('highway')
        if hw not in HW_CLS:
            continue
        cl = []
        prev = None
        for nid in nl:
            if nid != prev and nid in nodes:
                cl.append(nid)
            prev = nid
        if len(cl) < 2:
            continue
        for nid in cl:
            use[nid] = use.get(nid, 0) + 1
        endpoints.add(cl[0])
        endpoints.add(cl[-1])
        prepared.append((cl, tags, hw))
    junction = {nid for nid, c in use.items() if c >= 2} | endpoints

    node_index = {}
    node_coords = array('i')
    names = []
    name_idx = {}
    shapes = array('i')
    S_u, S_v, S_name = array('I'), array('I'), array('I')
    S_off, S_shapecnt = array('I'), array('H')
    S_len, S_time = array('f'), array('f')
    S_cls, S_flags = array('B'), array('B')
    seg_pts = []  # bbox для индекса: (minlat, minlon, maxlat, maxlon)

    def nix(nid):
        i = node_index.get(nid)
        if i is None:
            i = len(node_index)
            node_index[nid] = i
            la, lo = nodes[nid]
            node_coords.append(la)
            node_coords.append(lo)
        return i

    for cl, tags, hw in prepared:
        cls = HW_CLS[hw]
        spd = parse_speed(tags, cls, hw)
        fb = direction_flags(tags, hw)
        routable = is_routable(tags)
        flags = (fb if routable else 0)
        if tags.get('junction') in ('roundabout', 'circular'):
            flags |= 4
        if tags.get('bridge') or tags.get('tunnel'):
            flags |= 8
        nm = tags.get('name:uk') or tags.get('name') or tags.get('ref')
        if nm:
            ni = name_idx.get(nm)
            if ni is None:
                ni = len(names)
                name_idx[nm] = ni
                names.append(nm)
        else:
            ni = NONE32
        start = 0
        for i in range(1, len(cl)):
            if cl[i] in junction:
                chain = cl[start:i + 1]
                pts = [nodes[n] for n in chain]
                length = seg_length(pts)
                u = nix(chain[0])
                v = nix(chain[-1])
                off = len(shapes) // 2
                inner = pts[1:-1]
                for la, lo in inner:
                    shapes.append(la)
                    shapes.append(lo)
                S_u.append(u); S_v.append(v); S_name.append(ni)
                S_off.append(off); S_shapecnt.append(min(len(inner), 65535))
                S_len.append(length)
                S_time.append(length / (spd / 3.6) + (0.0 if cls == 0 else 2.0))
                S_cls.append(cls); S_flags.append(flags)
                seg_pts.append((min(p[0] for p in pts), min(p[1] for p in pts),
                                max(p[0] for p in pts), max(p[1] for p in pts)))
                start = i
    N = len(node_index)
    S = len(S_u)
    print(f'граф: узлов {N}, сегментов {S}, точек формы {len(shapes)//2}, названий {len(names)} '
          f'за {time.time()-t0:.1f} с', flush=True)
    return dict(N=N, S=S, node_coords=node_coords, shapes=shapes, names=names,
                S_u=S_u, S_v=S_v, S_name=S_name, S_off=S_off, S_shapecnt=S_shapecnt,
                S_len=S_len, S_time=S_time, S_cls=S_cls, S_flags=S_flags, seg_bbox=seg_pts)


def grid_index(bboxes, ids_filter, minLat, minLon, cols, rows):
    """bboxes: список (minlat,minlon,maxlat,maxlon) по номеру. Возвращает (cellStart, ids)."""
    cells = [None] * (cols * rows)
    for i, (a, b, c, d) in enumerate(bboxes):
        if not ids_filter(i):
            continue
        r0 = max((a - minLat) // CELL, 0)
        r1 = min((c - minLat) // CELL, rows - 1)
        c0 = max((b - minLon) // CELL, 0)
        c1 = min((d - minLon) // CELL, cols - 1)
        for r in range(r0, r1 + 1):
            base = r * cols
            for cc in range(c0, c1 + 1):
                lst = cells[base + cc]
                if lst is None:
                    lst = cells[base + cc] = array('I')
                lst.append(i)
    start = array('I', [0]) * (cols * rows + 1)
    total = 0
    ids = array('I')
    for k in range(cols * rows):
        start[k] = total
        lst = cells[k]
        if lst is not None:
            ids.extend(lst)
            total += len(lst)
    start[cols * rows] = total
    return start, ids


def write_graph(g, path):
    N, S = g['N'], g['S']
    nc = g['node_coords']
    la = nc[0::2]
    lo = nc[1::2]
    minLat, maxLat = min(la), max(la)
    minLon, maxLon = min(lo), max(lo)
    # сетка шире на ячейку со всех сторон не нужна; сдвигаем начало вниз до границы ячейки
    minLat -= minLat % CELL
    minLon -= minLon % CELL
    rows = (maxLat - minLat) // CELL + 1
    cols = (maxLon - minLon) // CELL + 1

    # дуги
    S_u, S_v, S_flags = g['S_u'], g['S_v'], g['S_flags']
    deg = [0] * (N + 1)
    for s in range(S):
        f = S_flags[s]
        if f & 1:
            deg[S_u[s]] += 1
        if f & 2:
            deg[S_v[s]] += 1
    first = array('I', [0]) * (N + 1)
    tot = 0
    for i in range(N):
        first[i] = tot
        tot += deg[i]
    first[N] = tot
    arcs = array('I', [0]) * tot
    pos = list(first)
    for s in range(S):
        f = S_flags[s]
        if f & 1:
            arcs[pos[S_u[s]]] = s
            pos[S_u[s]] += 1
        if f & 2:
            arcs[pos[S_v[s]]] = s | 0x80000000
            pos[S_v[s]] += 1

    # сегменты
    segb = bytearray()
    pk = struct.Struct('<IIIIffHBB')
    for s in range(S):
        segb += pk.pack(S_u[s], S_v[s], g['S_name'][s], g['S_off'][s], g['S_len'][s],
                        g['S_time'][s], g['S_shapecnt'][s], g['S_cls'][s], S_flags[s])

    # названия
    nameoff = array('I', [0])
    blob = bytearray()
    for nm in g['names']:
        blob += nm.encode('utf-8')
        nameoff.append(len(blob))

    cls = g['S_cls']
    levels = []
    for flt in (lambda i: cls[i] <= 2, lambda i: cls[i] <= 5, lambda i: True):
        levels.append(grid_index(g['seg_bbox'], flt, minLat, minLon, cols, rows))

    sections = [nc.tobytes(), first.tobytes(), arcs.tobytes(), bytes(segb), g['shapes'].tobytes(),
                nameoff.tobytes(), bytes(blob)]
    for st, ids in levels:
        sections.append(st.tobytes() + ids.tobytes())
    HEADER = 128
    offs = []
    cur = HEADER
    for sec in sections:
        offs.append(cur)
        cur += len(sec)
        cur += (-cur) % 8
    header = bytearray(HEADER)
    struct.pack_into('<4sIIIIIII', header, 0, b'KGPH', 1, N, S, len(arcs), len(g['shapes']) // 2,
                     len(g['names']), len(blob))
    struct.pack_into('<iiiII', header, 32, minLat, minLon, CELL, cols, rows)
    struct.pack_into('<10I', header, 52, *offs)
    with open(path, 'wb') as f:
        f.write(header)
        cur = HEADER
        for sec in sections:
            f.write(sec)
            pad = (-(cur + len(sec))) % 8
            f.write(b'\0' * pad)
            cur += len(sec) + pad
    print(f'graph.bin: {os.path.getsize(path)/1e6:.1f} МБ, сетка {cols}x{rows}', flush=True)
    return minLat, minLon, maxLat, maxLon


# ------------------------------------------------------------------ области

def area_kind(tags):
    if tags.get('highway'):
        return None
    if tags.get('natural') == 'water' or tags.get('waterway') == 'riverbank' \
            or tags.get('landuse') in ('reservoir', 'basin'):
        return 0
    if tags.get('natural') == 'wood' or tags.get('landuse') == 'forest':
        return 1
    if tags.get('leisure') in ('park', 'garden') or \
            tags.get('landuse') in ('grass', 'recreation_ground', 'village_green'):
        return 2
    return None


MIN_SIDE = {0: 0.0004, 1: 0.0008, 2: 0.0005}


def assemble_rings(way_lists):
    rings = []
    remaining = [list(w) for w in way_lists if len(w) >= 2]
    while remaining:
        ring = remaining.pop()
        while ring[0] != ring[-1]:
            found = False
            for i, w in enumerate(remaining):
                if w[0] == ring[-1]:
                    ring.extend(w[1:])
                elif w[-1] == ring[-1]:
                    ring.extend(reversed(w[:-1]))
                elif w[-1] == ring[0]:
                    ring = w[:-1] + ring
                elif w[0] == ring[0]:
                    ring = list(reversed(w[1:])) + ring
                else:
                    continue
                remaining.pop(i)
                found = True
                break
            if not found:
                break
        if ring[0] != ring[-1] and len(ring) >= 3:
            ring.append(ring[0])
        if len(ring) >= 4:
            rings.append(ring)
    return rings


def dp_simplify(pts, tol):
    """Дуглас-Пекер для открытой ломаной в e7 (с поправкой долготы)."""
    n = len(pts)
    if n <= 2:
        return pts
    c = math.cos(math.radians(pts[0][0] / E7))
    xs = [p[1] * c for p in pts]
    ys = [p[0] for p in pts]
    keep = [False] * n
    keep[0] = keep[-1] = True
    stack = [(0, n - 1)]
    while stack:
        i, j = stack.pop()
        if j <= i + 1:
            continue
        x1, y1, x2, y2 = xs[i], ys[i], xs[j], ys[j]
        dx, dy = x2 - x1, y2 - y1
        l2 = dx * dx + dy * dy
        dmax = -1.0
        k = -1
        for m in range(i + 1, j):
            if l2 == 0:
                d = math.hypot(xs[m] - x1, ys[m] - y1)
            else:
                t = ((xs[m] - x1) * dx + (ys[m] - y1) * dy) / l2
                t = 0.0 if t < 0 else (1.0 if t > 1 else t)
                d = math.hypot(xs[m] - (x1 + t * dx), ys[m] - (y1 + t * dy))
            if d > dmax:
                dmax, k = d, m
        if dmax > tol:
            keep[k] = True
            stack.append((i, k))
            stack.append((k, j))
    return [pts[i] for i in range(n) if keep[i]]


def simplify_ring(pts, tol):
    if len(pts) <= 5:
        return pts
    far = max(range(1, len(pts) - 1), key=lambda i: (pts[i][0] - pts[0][0]) ** 2 + (pts[i][1] - pts[0][1]) ** 2)
    left = dp_simplify(pts[:far + 1], tol)
    right = dp_simplify(pts[far:], tol)
    out = left + right[1:]
    return out if len(out) >= 4 else pts


def min_zoom_for(side_deg):
    side_deg = max(side_deg, 1e-6)
    z = math.ceil(math.log2(5.625 / side_deg))
    return int(min(max(z, 5), 17))


def build_areas(nodes, ways, rels):
    t0 = time.time()
    feats = []  # (kind, minZoom, [rings(list of (lat,lon))], bbox)
    TOL = 300  # ~3 м

    def add_poly(kind, rings_ids):
        rings = []
        for rid in rings_ids:
            pts = [nodes[n] for n in rid if n in nodes]
            if len(pts) >= 4:
                rings.append(pts)
        if not rings:
            return
        allp = [p for r in rings for p in r]
        a = min(p[0] for p in allp); b = min(p[1] for p in allp)
        c = max(p[0] for p in allp); d = max(p[1] for p in allp)
        side = max((c - a), (d - b) * math.cos(math.radians((a + c) / 2 / E7))) / E7
        if side < MIN_SIDE[kind]:
            return
        mz = min_zoom_for(side)
        rings = [simplify_ring(r, TOL) for r in rings]
        feats.append((kind, mz, rings, (a, b, c, d)))

    in_rel_outer = set()
    for tags, members in rels:
        kind = area_kind(tags)
        if kind is None:
            continue
        if len(members) > 4000:
            continue
        outer = [ways[i][0] for (t, i, r) in members if t == 'w' and r in ('outer', '') and i in ways]
        inner = [ways[i][0] for (t, i, r) in members if t == 'w' and r == 'inner' and i in ways]
        for t, i, r in members:
            if t == 'w' and r in ('outer', ''):
                in_rel_outer.add(i)
        rings_ids = assemble_rings(outer) + assemble_rings(inner)
        add_poly(kind, rings_ids)

    lines = []
    for wid, (nl, tags) in ways.items():
        if wid in in_rel_outer:
            continue
        kind = area_kind(tags)
        if kind is not None and len(nl) >= 4 and nl[0] == nl[-1]:
            add_poly(kind, [nl])
            continue
        ww = tags.get('waterway')
        if ww in ('river', 'canal') and len(nl) >= 2:
            pts = [nodes[n] for n in nl if n in nodes]
            if len(pts) >= 2:
                pts = dp_simplify(pts, TOL)
                a = min(p[0] for p in pts); b = min(p[1] for p in pts)
                c = max(p[0] for p in pts); d = max(p[1] for p in pts)
                lines.append((3 if ww == 'river' else 4, 9 if ww == 'river' else 13, [pts], (a, b, c, d)))
    feats.extend(lines)
    print(f'области: {len(feats)} объектов за {time.time()-t0:.1f} с', flush=True)
    return feats


def write_areas(feats, path, minLat, minLon, maxLat, maxLon):
    # своя сетка: объекты могут выходить за границы дорожной сетки
    if feats:
        minLat = min(f[3][0] for f in feats)
        minLon = min(f[3][1] for f in feats)
        maxLat = max(f[3][2] for f in feats)
        maxLon = max(f[3][3] for f in feats)
    minLat -= minLat % CELL
    minLon -= minLon % CELL
    rows = (maxLat - minLat) // CELL + 1
    cols = (maxLon - minLon) // CELL + 1
    featb = bytearray()
    ringb = array('I')
    pts = array('i')
    ring_count = 0
    for kind, mz, rings, (a, b, c, d) in feats:
        featb += struct.pack('<BBHIIiiii4x', kind, mz, 0, ring_count, len(rings), a, b, c, d)
        for r in rings:
            ringb.append(len(pts) // 2)
            ringb.append(len(r))
            for la, lo in r:
                pts.append(la)
                pts.append(lo)
            ring_count += 1
    bboxes = [f[3] for f in feats]
    start, ids = grid_index(bboxes, lambda i: True, minLat, minLon, cols, rows)
    HEADER = 64
    secs = [bytes(featb), ringb.tobytes(), pts.tobytes(), start.tobytes(), ids.tobytes()]
    offs = []
    cur = HEADER
    for s in secs:
        offs.append(cur)
        cur += len(s)
        cur += (-cur) % 8
    header = bytearray(HEADER)
    struct.pack_into('<4sIIII', header, 0, b'KARE', 1, len(feats), ring_count, len(pts) // 2)
    struct.pack_into('<iiiII', header, 20, minLat, minLon, CELL, cols, rows)
    struct.pack_into('<5I', header, 40, *offs)
    with open(path, 'wb') as f:
        f.write(header)
        cur = HEADER
        for s in secs:
            f.write(s)
            pad = (-(cur + len(s))) % 8
            f.write(b'\0' * pad)
            cur += len(s) + pad
    print(f'areas.bin: {os.path.getsize(path)/1e6:.1f} МБ', flush=True)


# -------------------------------------------------------------------- поиск

PLACE_KIND = {'city': 0, 'town': 1, 'village': 2, 'suburb': 3, 'neighbourhood': 3,
              'quarter': 3, 'hamlet': 4}


def poi_sub(tags):
    am = tags.get('amenity')
    if am in ('restaurant', 'cafe', 'fast_food', 'bar', 'pub', 'food_court'):
        return 1
    if tags.get('shop'):
        return 2
    if am == 'fuel':
        return 3
    if am in ('hospital', 'clinic', 'pharmacy', 'dentist', 'doctors'):
        return 4
    if tags.get('tourism') or am in ('theatre', 'cinema'):
        return 5
    if am in ('bank', 'atm'):
        return 6
    if am in ('bench', 'waste_basket', 'parking_space', 'bicycle_parking', 'recycling',
              'vending_machine', 'shelter', 'toilets', 'post_box'):
        return None
    return 7 if am else None


def build_search(named, g, minLat, minLon, path):
    t0 = time.time()
    strings = []
    sidx = {}

    def sx(s):
        i = sidx.get(s)
        if i is None:
            i = len(strings)
            sidx[s] = i
            strings.append(s)
        return i

    entries = []  # (kind, sub, lat, lon, nameIdx, extraIdx)
    places = []
    for lat, lon, tags in named:
        nm = tags.get('name:uk') or tags.get('name')
        pk = PLACE_KIND.get(tags.get('place', ''))
        if pk is not None:
            places.append((lat, lon, pk, nm))
            entries.append([1, pk, lat, lon, sx(nm), NONE32])
            continue
        sub = poi_sub(tags)
        if sub is not None:
            entries.append([2, sub, lat, lon, sx(nm), NONE32])

    # сетка населённых пунктов для подписи улиц
    PC = 1_000_000
    pgrid = {}
    for lat, lon, pk, nm in places:
        if pk == 3:
            continue
        pgrid.setdefault((lat // PC, lon // PC), []).append((lat, lon, nm))

    def nearest_place(lat, lon):
        cy, cx = lat // PC, lon // PC
        cl = math.cos(math.radians(lat / E7))
        for rad in (1, 2):
            best, bd = None, None
            for dy in range(-rad, rad + 1):
                for dx in range(-rad, rad + 1):
                    for plat, plon, nm in pgrid.get((cy + dy, cx + dx), ()):
                        d = (plat - lat) ** 2 + ((plon - lon) * cl) ** 2
                        if bd is None or d < bd:
                            best, bd = nm, d
            if best is not None:
                return best
        return None

    # улицы: одна запись на (название, ячейка 0.05°)
    nc, shapes = g['node_coords'], g['shapes']
    groups = {}
    for s in range(g['S']):
        ni = g['S_name'][s]
        if ni == NONE32:
            continue
        nm = g['names'][ni]
        # середина сегмента: средняя из точек u, v и формы
        u, v = g['S_u'][s], g['S_v'][s]
        la = (nc[2 * u] + nc[2 * v]) // 2
        lo = (nc[2 * u + 1] + nc[2 * v + 1]) // 2
        key = (nm, la // 500_000, lo // 500_000)
        groups.setdefault(key, []).append((la, lo))
    for (nm, _, _), mids in groups.items():
        mla = sum(m[0] for m in mids) // len(mids)
        mlo = sum(m[1] for m in mids) // len(mids)
        best = min(mids, key=lambda m: (m[0] - mla) ** 2 + (m[1] - mlo) ** 2)
        loc = nearest_place(best[0], best[1])
        entries.append([0, 0, best[0], best[1], sx(nm), sx(loc) if loc else NONE32])

    soff = array('I', [0])
    blob = bytearray()
    for s in strings:
        blob += s.encode('utf-8')
        soff.append(len(blob))
    eb = bytearray()
    for k, sub, la, lo, ni, ex in entries:
        eb += struct.pack('<BBHiiII', k, sub, 0, la, lo, ni, ex)
    HEADER = 64
    secs = [bytes(eb), soff.tobytes(), bytes(blob)]
    offs = []
    cur = HEADER
    for s in secs:
        offs.append(cur)
        cur += len(s)
        cur += (-cur) % 8
    header = bytearray(HEADER)
    struct.pack_into('<4sIII', header, 0, b'KSRC', 1, len(entries), len(strings))
    struct.pack_into('<3I', header, 16, *offs)
    struct.pack_into('<I', header, 28, len(blob))
    with open(path, 'wb') as f:
        f.write(header)
        cur = HEADER
        for s in secs:
            f.write(s)
            pad = (-(cur + len(s))) % 8
            f.write(b'\0' * pad)
            cur += len(s) + pad
    n_street = sum(1 for e in entries if e[0] == 0)
    print(f'search.bin: {os.path.getsize(path)/1e6:.1f} МБ, записей {len(entries)} '
          f'(улиц {n_street}, мест/нас. пунктов {len(entries)-n_street}) за {time.time()-t0:.1f} с', flush=True)


# --------------------------------------------------------------------- main

def sha256(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(1 << 20), b''):
            h.update(chunk)
    return h.hexdigest()


def main():
    if len(sys.argv) != 3:
        print(__doc__)
        sys.exit(2)
    src, out = sys.argv[1], sys.argv[2]
    os.makedirs(out, exist_ok=True)
    nodes, named, ways, rels = read_opl(src)
    g = build_graph(nodes, ways)
    if g['S'] == 0:
        print('нет дорог — нечего собирать')
        sys.exit(1)
    minLat, minLon, maxLat, maxLon = write_graph(g, os.path.join(out, 'graph.bin'))
    feats = build_areas(nodes, ways, rels)
    write_areas(feats, os.path.join(out, 'areas.bin'), minLat, minLon, maxLat, maxLon)
    build_search(named, g, minLat, minLon, os.path.join(out, 'search.bin'))
    files = []
    for name in ('graph.bin', 'areas.bin', 'search.bin'):
        p = os.path.join(out, name)
        files.append({'name': name, 'size': os.path.getsize(p), 'sha256': sha256(p)})
    manifest = {
        'version': 1,
        'built': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
        'bbox': [minLat / E7, minLon / E7, maxLat / E7, maxLon / E7],
        'files': files,
    }
    with open(os.path.join(out, 'manifest.json'), 'w') as f:
        json.dump(manifest, f, ensure_ascii=False, indent=1)
    print('готово')


if __name__ == '__main__':
    main()
