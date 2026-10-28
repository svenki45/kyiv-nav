import Foundation

public struct Coord: Equatable, Hashable, Codable {
    public var lat: Double
    public var lon: Double
    public init(lat: Double, lon: Double) {
        self.lat = lat
        self.lon = lon
    }
}

public enum Geo {
    public static let metersPerDegree = 6371000.0 * Double.pi / 180.0

    /// Расстояние в метрах (так же считает сборщик карты).
    public static func distance(_ a: Coord, _ b: Coord) -> Double {
        let dy = (b.lat - a.lat) * metersPerDegree
        let dx = (b.lon - a.lon) * metersPerDegree * cos((a.lat + b.lat) / 2 * Double.pi / 180)
        return (dx * dx + dy * dy).squareRoot()
    }

    /// Направление от a к b в градусах: 0 — север, 90 — восток.
    public static func bearing(from a: Coord, to b: Coord) -> Double {
        let dy = b.lat - a.lat
        let dx = (b.lon - a.lon) * cos((a.lat + b.lat) / 2 * Double.pi / 180)
        var deg = atan2(dx, dy) * 180 / Double.pi
        if deg < 0 { deg += 360 }
        return deg
    }

    /// Поворот от направления `from` к `to`, от -180 до 180. Плюс — вправо.
    public static func angleDiff(_ from: Double, _ to: Double) -> Double {
        var d = (to - from).truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 }
        if d <= -180 { d += 360 }
        return d
    }

    public static func destination(from a: Coord, bearing: Double, meters: Double) -> Coord {
        let rad = bearing * Double.pi / 180
        let dy = cos(rad) * meters / metersPerDegree
        let dx = sin(rad) * meters / (metersPerDegree * cos(a.lat * Double.pi / 180))
        return Coord(lat: a.lat + dy, lon: a.lon + dx)
    }

    /// Проекция точки p на отрезок ab: доля t (0...1), расстояние и ближайшая точка.
    public static func project(_ p: Coord, _ a: Coord, _ b: Coord) -> (t: Double, dist: Double, point: Coord) {
        let c = cos(a.lat * Double.pi / 180)
        let bx = (b.lon - a.lon) * metersPerDegree * c
        let by = (b.lat - a.lat) * metersPerDegree
        let px = (p.lon - a.lon) * metersPerDegree * c
        let py = (p.lat - a.lat) * metersPerDegree
        let l2 = bx * bx + by * by
        var t = 0.0
        if l2 > 0 {
            t = (px * bx + py * by) / l2
            if t < 0 { t = 0 }
            if t > 1 { t = 1 }
        }
        let qx = bx * t
        let qy = by * t
        let dist = ((px - qx) * (px - qx) + (py - qy) * (py - qy)).squareRoot()
        let point = Coord(lat: a.lat + (b.lat - a.lat) * t, lon: a.lon + (b.lon - a.lon) * t)
        return (t, dist, point)
    }
}

public enum NavError: Error {
    case cannotOpen(String)
    case badFile(String)
}
