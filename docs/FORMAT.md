# Формат файлов карты (версия 1)

Все числа little-endian. Координаты: `Int32`, градусы × 10^7 (e7). Сетка: ячейки `cellSize` (e7), по умолчанию 100000 = 0.01°.

## graph.bin — дорожный граф + индекс для отрисовки

Заголовок 128 байт:

| смещение | тип | поле |
|---|---|---|
| 0 | 4 байта | `KGPH` |
| 4 | UInt32 | версия (1) |
| 8 | UInt32 | nodeCount |
| 12 | UInt32 | segCount |
| 16 | UInt32 | arcCount |
| 20 | UInt32 | shapePointCount |
| 24 | UInt32 | nameCount |
| 28 | UInt32 | nameBlobSize |
| 32 | Int32 | minLat |
| 36 | Int32 | minLon |
| 40 | Int32 | cellSize |
| 44 | UInt32 | cols |
| 48 | UInt32 | rows |
| 52 | UInt32 | offNodes |
| 56 | UInt32 | offArcFirst |
| 60 | UInt32 | offArcs |
| 64 | UInt32 | offSegs |
| 68 | UInt32 | offShapes |
| 72 | UInt32 | offNameOffsets |
| 76 | UInt32 | offNameBlob |
| 80 | UInt32 | offLevel0 |
| 84 | UInt32 | offLevel1 |
| 88 | UInt32 | offLevel2 |

Секции:

- nodes: `nodeCount × (lat Int32, lon Int32)` — перекрёстки и концы дорог.
- arcFirst: `(nodeCount+1) × UInt32` — начало списка выходящих дуг узла.
- arcs: `arcCount × UInt32` — бит 31 = ехать от `v` к `u` (против направления геометрии); младшие 31 бита = номер сегмента.
- segs: `segCount × 28 байт`:
  `u UInt32 @0, v UInt32 @4, nameId UInt32 @8 (0xFFFFFFFF = нет), shapeOff UInt32 @12, lengthM Float32 @16, timeS Float32 @20, shapeCount UInt16 @24, cls UInt8 @26, flags UInt8 @27`.
  Геометрия сегмента: точка `u`, затем `shapeCount` промежуточных точек из shapes[shapeOff…], затем точка `v`.
  `cls`: 0 motorway, 1 trunk, 2 primary, 3 secondary, 4 tertiary, 5 unclassified, 6 residential, 7 living_street, 8 service.
  `flags`: бит0 — можно ехать u→v, бит1 — можно ехать v→u, бит2 — кольцо, бит3 — мост/тоннель.
- shapes: `shapePointCount × (lat Int32, lon Int32)`.
- nameOffsets: `(nameCount+1) × UInt32`; nameBlob: UTF-8.
- Level0/1/2 — индекс сегментов по ячейкам для отрисовки (L0: cls ≤ 2, L1: cls ≤ 5, L2: все):
  `cellStart: (cols*rows+1) × UInt32`, затем `ids: cellStart[last] × UInt32`. Ячейка `(row, col)` = `row*cols + col`, `col = (lon-minLon)/cellSize`, `row = (lat-minLat)/cellSize`.

## areas.bin — вода, леса, парки, реки

Заголовок 64 байта: `KARE`, версия, featCount @8, ringCount @12, pointCount @16, minLat @20, minLon @24, cellSize @28, cols @32, rows @36, offFeats @40, offRings @44, offPoints @48, offCellStart @52, offIds @56.

- feats: `32 байта`: `kind UInt8 @0` (0 вода, 1 лес, 2 парк, 3 река-линия, 4 канал-линия), `minZoom UInt8 @1`, `ringStart UInt32 @4`, `ringCount UInt32 @8`, `minLat,minLon,maxLat,maxLon Int32 @12..@27`.
- rings: `(pointStart UInt32, pointCount UInt32)`.
- points: `(lat Int32, lon Int32)`.
- сетка: `cellStart (cols*rows+1) × UInt32`, `ids`.

## search.bin — поиск и подписи

Заголовок 64 байта: `KSRC`, версия, count @8, stringCount @12, offEntries @16, offStrOffsets @20, offStrBlob @24, strBlobSize @28.

- entries: `20 байт`: `kind UInt8 @0` (0 улица, 1 населённый пункт, 2 место), `sub UInt8 @1`, `lat Int32 @4`, `lon Int32 @8`, `nameIdx UInt32 @12`, `extraIdx UInt32 @16` (0xFFFFFFFF = нет; для улицы — название ближайшего населённого пункта).
  Для kind=1: sub 0 город, 1 городок, 2 село, 3 район, 4 хутор. Для kind=2: sub 1 еда, 2 магазин, 3 АЗС, 4 здоровье, 5 отель/туризм, 6 банк, 7 другое.
- stringOffsets `(stringCount+1) × UInt32`, strBlob UTF-8.

## manifest.json

`{"version":1,"built":"...","files":[{"name":"graph.bin","size":N,"sha256":"..."},...]}`
