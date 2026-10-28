import SwiftUI
import NavCore

/// Что сейчас показывает карта: центр, масштаб и поворот.
struct Camera {
    var center: Coord
    /// Масштаб как в веб-картах: 0 — весь мир на 256 пунктов.
    var zoom: Double
    /// Куда направлен «верх» экрана, градусы (0 — на север).
    var bearing: Double

    static let minZoom = 6.0
    static let maxZoom = 19.0

    static let kyiv = Camera(center: Coord(lat: 50.4501, lon: 30.5234), zoom: 12, bearing: 0)
}

/// Переводит координаты в точки экрана и обратно.
struct Projector {
    let latC: Double
    let lonC: Double
    let kx: Double      // пунктов на градус долготы
    let ky: Double      // пунктов на градус широты
    let cosB: Double
    let sinB: Double
    let origin: CGPoint
    let pointsPerMeter: Double

    init(camera: Camera, origin: CGPoint) {
        latC = camera.center.lat
        lonC = camera.center.lon
        let world = 256.0 * pow(2.0, camera.zoom)
        kx = world / 360.0
        ky = kx / cos(latC * Double.pi / 180)
        let b = camera.bearing * Double.pi / 180
        cosB = cos(b)
        sinB = sin(b)
        self.origin = origin
        pointsPerMeter = ky / Geo.metersPerDegree
    }

    @inline(__always)
    func point(lat: Double, lon: Double) -> CGPoint {
        let dx = (lon - lonC) * kx
        let dy = -(lat - latC) * ky
        return CGPoint(x: origin.x + dx * cosB + dy * sinB,
                       y: origin.y - dx * sinB + dy * cosB)
    }

    func point(_ c: Coord) -> CGPoint {
        return point(lat: c.lat, lon: c.lon)
    }

    func coord(at p: CGPoint) -> Coord {
        let sx = Double(p.x - origin.x)
        let sy = Double(p.y - origin.y)
        let dx = cosB * sx - sinB * sy
        let dy = sinB * sx + cosB * sy
        return Coord(lat: latC - dy / ky, lon: lonC + dx / kx)
    }

    /// Прямоугольник в градусах, покрывающий экран (с запасом).
    func bounds(size: CGSize, margin: CGFloat = 40) -> (minLat: Double, minLon: Double, maxLat: Double, maxLon: Double) {
        let corners = [CGPoint(x: -margin, y: -margin),
                       CGPoint(x: size.width + margin, y: -margin),
                       CGPoint(x: size.width + margin, y: size.height + margin),
                       CGPoint(x: -margin, y: size.height + margin)]
        var minLat = 90.0, maxLat = -90.0, minLon = 180.0, maxLon = -180.0
        for p in corners {
            let c = coord(at: p)
            minLat = min(minLat, c.lat)
            maxLat = max(maxLat, c.lat)
            minLon = min(minLon, c.lon)
            maxLon = max(maxLon, c.lon)
        }
        return (minLat, minLon, maxLat, maxLon)
    }
}
