import Foundation

public struct Segment {
    public var u: Int
    public var v: Int
    public var nameId: UInt32
    public var shapeOff: Int
    public var shapeCount: Int
    public var lengthM: Float
    public var timeS: Float
    public var cls: UInt8
    public var flags: UInt8

    public var canForward: Bool { return flags & 1 != 0 }
    public var canReverse: Bool { return flags & 2 != 0 }
    public var isRoundabout: Bool { return flags & 4 != 0 }
    public var isRoutable: Bool { return flags & 3 != 0 }
}

/// Геометрия сегмента: точки и накопленные расстояния (в метрах, приведены к lengthM).
public struct SegmentProfile {
    public var points: [Coord]
    public var cum: [Double]
    public var length: Double

    public func point(at along: Double) -> Coord {
        if points.count == 1 { return points[0] }
        let a = min(max(along, 0), length)
        var i = 1
        while i < cum.count - 1 && cum[i] < a { i += 1 }
        let d0 = cum[i - 1]
        let d1 = cum[i]
        let t = d1 > d0 ? (a - d0) / (d1 - d0) : 0
        return Coord(lat: points[i - 1].lat + (points[i].lat - points[i - 1].lat) * t,
                     lon: points[i - 1].lon + (points[i].lon - points[i - 1].lon) * t)
    }

    /// Точки от along `a` до along `b` (a может быть больше b — тогда в обратную сторону).
    public func cut(from a: Double, to b: Double) -> [Coord] {
        let lo = min(a, b)
        let hi = max(a, b)
        var out: [Coord] = [point(at: lo)]
        for i in 0..<points.count where cum[i] > lo + 0.01 && cum[i] < hi - 0.01 {
            out.append(points[i])
        }
        out.append(point(at: hi))
        if a > b { out.reverse() }
        return out
    }
}

public final class GraphData {
    let f: MappedFile
    public let nodeCount: Int
    public let segCount: Int
    public let arcCount: Int
    public let shapeCount: Int
    public let nameCount: Int
    public let minLatE7: Int
    public let minLonE7: Int
    public let cellE7: Int
    public let cols: Int
    public let rows: Int
    let oNodes: Int, oFirst: Int, oArcs: Int, oSegs: Int, oShapes: Int, oNameOff: Int, oBlob: Int
    let oLevels: [Int]

    public init(path: String) throws {
        f = try MappedFile(path: path)
        if !f.hasMagic("KGPH") || f.u32(4) != 1 { throw NavError.badFile(path) }
        nodeCount = Int(f.u32(8))
        segCount = Int(f.u32(12))
        arcCount = Int(f.u32(16))
        shapeCount = Int(f.u32(20))
        nameCount = Int(f.u32(24))
        minLatE7 = Int(f.i32(32))
        minLonE7 = Int(f.i32(36))
        cellE7 = Int(f.i32(40))
        cols = Int(f.u32(44))
        rows = Int(f.u32(48))
        oNodes = Int(f.u32(52))
        oFirst = Int(f.u32(56))
        oArcs = Int(f.u32(60))
        oSegs = Int(f.u32(64))
        oShapes = Int(f.u32(68))
        oNameOff = Int(f.u32(72))
        oBlob = Int(f.u32(76))
        oLevels = [Int(f.u32(80)), Int(f.u32(84)), Int(f.u32(88))]
        let need = oLevels[2] + 4 * (cols * rows + 1)
        if need > f.size || cellE7 <= 0 { throw NavError.badFile(path) }
    }

    // MARK: узлы и дуги

    @inline(__always) public func nodeLatE7(_ i: Int) -> Int32 { return f.i32(oNodes + 8 * i) }
    @inline(__always) public func nodeLonE7(_ i: Int) -> Int32 { return f.i32(oNodes + 8 * i + 4) }

    public func node(_ i: Int) -> Coord {
        return Coord(lat: Double(nodeLatE7(i)) / 1e7, lon: Double(nodeLonE7(i)) / 1e7)
    }

    @inline(__always) public func arcStart(_ node: Int) -> Int { return Int(f.u32(oFirst + 4 * node)) }
    @inline(__always) public func arc(_ k: Int) -> UInt32 { return f.u32(oArcs + 4 * k) }

    // MARK: сегменты

    public func segment(_ s: Int) -> Segment {
        let o = oSegs + 28 * s
        return Segment(u: Int(f.u32(o)), v: Int(f.u32(o + 4)), nameId: f.u32(o + 8),
                       shapeOff: Int(f.u32(o + 12)), shapeCount: Int(f.u16(o + 24)),
                       lengthM: f.f32(o + 16), timeS: f.f32(o + 20),
                       cls: f.u8(o + 26), flags: f.u8(o + 27))
    }

    @inline(__always) public func segmentClass(_ s: Int) -> UInt8 { return f.u8(oSegs + 28 * s + 26) }

    public func shapePoint(_ idx: Int) -> Coord {
        let o = oShapes + 8 * idx
        return Coord(lat: Double(f.i32(o)) / 1e7, lon: Double(f.i32(o + 4)) / 1e7)
    }

    public func geometry(_ s: Int) -> [Coord] {
        let seg = segment(s)
        return geometry(of: seg)
    }

    public func geometry(of seg: Segment) -> [Coord] {
        var pts: [Coord] = [node(seg.u)]
        if seg.shapeCount > 0 {
            for i in 0..<seg.shapeCount { pts.append(shapePoint(seg.shapeOff + i)) }
        }
        pts.append(node(seg.v))
        return pts
    }

    public func profile(_ s: Int) -> SegmentProfile {
        let seg = segment(s)
        let pts = geometry(of: seg)
        var cum: [Double] = [0]
        var total = 0.0
        for i in 1..<pts.count {
            total += Geo.distance(pts[i - 1], pts[i])
            cum.append(total)
        }
        // приводим к длине из файла, чтобы суммы маршрутов совпадали с временем
        let target = Double(seg.lengthM)
        if total > 0 && target > 0 {
            let k = target / total
            for i in 0..<cum.count { cum[i] *= k }
            total = target
        }
        return SegmentProfile(points: pts, cum: cum, length: total)
    }

    public func name(_ id: UInt32) -> String? {
        if id == 0xFFFF_FFFF || Int(id) >= nameCount { return nil }
        let a = Int(f.u32(oNameOff + 4 * Int(id)))
        let b = Int(f.u32(oNameOff + 4 * Int(id) + 4))
        return f.string(oBlob + a, b - a)
    }

    // MARK: сетка

    /// Обходит сегменты уровня (0 — крупные дороги, 1 — средние, 2 — все) в прямоугольнике.
    public func forEachSegment(level: Int, minLat: Double, minLon: Double, maxLat: Double, maxLon: Double,
                               marker: VisitMarker, _ body: (Int) -> Void) {
        let r0 = max(Int((minLat * 1e7 - Double(minLatE7)) / Double(cellE7)), 0)
        let r1 = min(Int((maxLat * 1e7 - Double(minLatE7)) / Double(cellE7)), rows - 1)
        let c0 = max(Int((minLon * 1e7 - Double(minLonE7)) / Double(cellE7)), 0)
        let c1 = min(Int((maxLon * 1e7 - Double(minLonE7)) / Double(cellE7)), cols - 1)
        if r0 > r1 || c0 > c1 { return }
        let lvl = oLevels[level]
        let cells = cols * rows
        let idsBase = lvl + 4 * (cells + 1)
        marker.begin()
        for r in r0...r1 {
            for c in c0...c1 {
                let cell = r * cols + c
                let a = Int(f.u32(lvl + 4 * cell))
                let b = Int(f.u32(lvl + 4 * cell + 4))
                if a >= b { continue }
                for k in a..<b {
                    let s = Int(f.u32(idsBase + 4 * k))
                    if marker.visit(s) { body(s) }
                }
            }
        }
    }
}
