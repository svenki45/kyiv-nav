import Foundation

public enum AreaKind: UInt8 {
    case water = 0
    case forest = 1
    case park = 2
    case river = 3
    case canal = 4
}

public struct AreaFeature {
    public var id: Int
    public var kind: AreaKind
    public var minZoom: Int
    public var ringStart: Int
    public var ringCount: Int
}

/// Вода, леса, парки и реки (файл areas.bin).
public final class AreaData {
    let f: MappedFile
    public let featCount: Int
    public let ringCount: Int
    public let pointCount: Int
    let minLatE7: Int, minLonE7: Int, cellE7: Int, cols: Int, rows: Int
    let oFeats: Int, oRings: Int, oPoints: Int, oCellStart: Int, oIds: Int

    public init(path: String) throws {
        f = try MappedFile(path: path)
        if !f.hasMagic("KARE") || f.u32(4) != 1 { throw NavError.badFile(path) }
        featCount = Int(f.u32(8))
        ringCount = Int(f.u32(12))
        pointCount = Int(f.u32(16))
        minLatE7 = Int(f.i32(20))
        minLonE7 = Int(f.i32(24))
        cellE7 = Int(f.i32(28))
        cols = Int(f.u32(32))
        rows = Int(f.u32(36))
        oFeats = Int(f.u32(40))
        oRings = Int(f.u32(44))
        oPoints = Int(f.u32(48))
        oCellStart = Int(f.u32(52))
        oIds = Int(f.u32(56))
        if cellE7 <= 0 || oIds > f.size { throw NavError.badFile(path) }
    }

    public func feature(_ i: Int) -> AreaFeature {
        let o = oFeats + 32 * i
        return AreaFeature(id: i, kind: AreaKind(rawValue: f.u8(o)) ?? .water, minZoom: Int(f.u8(o + 1)),
                           ringStart: Int(f.u32(o + 4)), ringCount: Int(f.u32(o + 8)))
    }

    public func ring(_ ringIndex: Int) -> (start: Int, count: Int) {
        let o = oRings + 8 * ringIndex
        return (Int(f.u32(o)), Int(f.u32(o + 4)))
    }

    public func point(_ idx: Int) -> Coord {
        let o = oPoints + 8 * idx
        return Coord(lat: Double(f.i32(o)) / 1e7, lon: Double(f.i32(o + 4)) / 1e7)
    }

    /// Номера объектов в прямоугольнике (без повторов).
    public func features(minLat: Double, minLon: Double, maxLat: Double, maxLon: Double, marker: VisitMarker) -> [Int] {
        let r0 = max(Int((minLat * 1e7 - Double(minLatE7)) / Double(cellE7)), 0)
        let r1 = min(Int((maxLat * 1e7 - Double(minLatE7)) / Double(cellE7)), rows - 1)
        let c0 = max(Int((minLon * 1e7 - Double(minLonE7)) / Double(cellE7)), 0)
        let c1 = min(Int((maxLon * 1e7 - Double(minLonE7)) / Double(cellE7)), cols - 1)
        var out: [Int] = []
        if r0 > r1 || c0 > c1 { return out }
        marker.begin()
        for r in r0...r1 {
            for c in c0...c1 {
                let cell = r * cols + c
                let a = Int(f.u32(oCellStart + 4 * cell))
                let b = Int(f.u32(oCellStart + 4 * cell + 4))
                if a >= b { continue }
                for k in a..<b {
                    let id = Int(f.u32(oIds + 4 * k))
                    if marker.visit(id) { out.append(id) }
                }
            }
        }
        return out
    }
}
