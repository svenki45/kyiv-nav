import SwiftUI
import NavCore

struct MapTheme {
    let land: Color
    let water: Color
    let forest: Color
    let park: Color
    let casing: Color
    let roadFill: [Color]       // по классам дорог 0...8
    let text: Color
    let halo: Color
    let routeCasing: Color
    let routeFill: Color

    static let light = MapTheme(
        land: Color(red: 0.94, green: 0.93, blue: 0.90),
        water: Color(red: 0.62, green: 0.79, blue: 0.93),
        forest: Color(red: 0.78, green: 0.88, blue: 0.74),
        park: Color(red: 0.82, green: 0.91, blue: 0.78),
        casing: Color(red: 0.70, green: 0.69, blue: 0.67),
        roadFill: [
            Color(red: 0.99, green: 0.66, blue: 0.30),
            Color(red: 1.00, green: 0.75, blue: 0.38),
            Color(red: 1.00, green: 0.85, blue: 0.47),
            Color(red: 1.00, green: 0.93, blue: 0.62),
            Color(red: 1.00, green: 1.00, blue: 1.00),
            Color(red: 1.00, green: 1.00, blue: 1.00),
            Color(red: 1.00, green: 1.00, blue: 1.00),
            Color(red: 0.97, green: 0.97, blue: 0.95),
            Color(red: 0.97, green: 0.97, blue: 0.95)
        ],
        text: Color(red: 0.15, green: 0.15, blue: 0.18),
        halo: Color(white: 1.0, opacity: 0.85),
        routeCasing: Color(red: 0.05, green: 0.25, blue: 0.62),
        routeFill: Color(red: 0.20, green: 0.55, blue: 1.00)
    )

    static let dark = MapTheme(
        land: Color(red: 0.10, green: 0.11, blue: 0.13),
        water: Color(red: 0.09, green: 0.18, blue: 0.29),
        forest: Color(red: 0.11, green: 0.17, blue: 0.13),
        park: Color(red: 0.13, green: 0.20, blue: 0.14),
        casing: Color(red: 0.04, green: 0.04, blue: 0.06),
        roadFill: [
            Color(red: 0.72, green: 0.46, blue: 0.20),
            Color(red: 0.66, green: 0.52, blue: 0.26),
            Color(red: 0.55, green: 0.50, blue: 0.30),
            Color(red: 0.45, green: 0.45, blue: 0.40),
            Color(red: 0.34, green: 0.35, blue: 0.40),
            Color(red: 0.32, green: 0.33, blue: 0.38),
            Color(red: 0.30, green: 0.31, blue: 0.36),
            Color(red: 0.26, green: 0.27, blue: 0.31),
            Color(red: 0.24, green: 0.25, blue: 0.29)
        ],
        text: Color(red: 0.88, green: 0.89, blue: 0.92),
        halo: Color(red: 0.10, green: 0.11, blue: 0.13, opacity: 0.85),
        routeCasing: Color(red: 0.10, green: 0.30, blue: 0.70),
        routeFill: Color(red: 0.30, green: 0.65, blue: 1.00)
    )
}

struct VehicleMarker {
    var coord: Coord
    var bearing: Double
    var accuracy: Double
    var sensorsOnly: Bool
}

struct RenderInput {
    var camera: Camera
    var anchor: CGPoint
    var engine: MapEngine?
    var route: [Coord]
    var vehicle: VehicleMarker?
    var pin: Coord?
    var dark: Bool
    var streetNames: Bool
}

enum MapRenderer {

    static func draw(_ ctx: inout GraphicsContext, size: CGSize, input: RenderInput) {
        let theme = input.dark ? MapTheme.dark : MapTheme.light
        ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(theme.land))
        let proj = Projector(camera: input.camera, origin: input.anchor)
        let z = input.camera.zoom
        let sizeScale = min(max(pow(1.38, z - 14), 0.3), 3.4)

        if let e = input.engine {
            let b = proj.bounds(size: size)
            drawAreas(&ctx, e, proj, b, z, sizeScale, theme)
            var labelRects: [CGRect] = []
            drawRoads(&ctx, e, proj, b, z, sizeScale, theme, input.streetNames, &labelRects)
            drawPlaces(&ctx, e, proj, b, z, theme, size, &labelRects)
        }

        if input.route.count > 1 {
            var path = Path()
            for (i, c) in input.route.enumerated() {
                let p = proj.point(c)
                if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
            let w = max(5.0, 7.0 * sizeScale)
            let style = { (lw: CGFloat) in StrokeStyle(lineWidth: lw, lineCap: .round, lineJoin: .round) }
            ctx.stroke(path, with: .color(theme.routeCasing), style: style(w + 3))
            ctx.stroke(path, with: .color(theme.routeFill), style: style(w))
        }

        if let pin = input.pin {
            let p = proj.point(pin)
            var stem = Path()
            stem.move(to: p)
            stem.addLine(to: CGPoint(x: p.x, y: p.y - 14))
            ctx.stroke(stem, with: .color(.red), style: StrokeStyle(lineWidth: 3, lineCap: .round))
            let head = CGRect(x: p.x - 10, y: p.y - 34, width: 20, height: 20)
            ctx.fill(Path(ellipseIn: head), with: .color(.red))
            ctx.fill(Path(ellipseIn: head.insetBy(dx: 6, dy: 6)), with: .color(.white))
        }

        if let v = input.vehicle {
            let p = proj.point(v.coord)
            let accPts = v.accuracy * proj.pointsPerMeter
            let tint: Color = v.sensorsOnly ? .orange : Color(red: 0.10, green: 0.45, blue: 1.0)
            if accPts > 14 && accPts < 400 {
                let r = CGRect(x: p.x - accPts, y: p.y - accPts, width: accPts * 2, height: accPts * 2)
                ctx.fill(Path(ellipseIn: r), with: .color(tint.opacity(0.14)))
            }
            let ring = CGRect(x: p.x - 17, y: p.y - 17, width: 34, height: 34)
            ctx.fill(Path(ellipseIn: ring), with: .color(.white))
            let rot = (v.bearing - input.camera.bearing) * Double.pi / 180
            var arrow = Path()
            let pts: [(Double, Double)] = [(0, -13), (10, 11), (0, 5), (-10, 11)]
            for (i, q) in pts.enumerated() {
                let x = q.0 * cos(rot) - q.1 * sin(rot)
                let y = q.0 * sin(rot) + q.1 * cos(rot)
                let pt = CGPoint(x: p.x + x, y: p.y + y)
                if i == 0 { arrow.move(to: pt) } else { arrow.addLine(to: pt) }
            }
            arrow.closeSubpath()
            ctx.fill(arrow, with: .color(tint))
        }
    }

    // MARK: области

    static func drawAreas(_ ctx: inout GraphicsContext, _ e: MapEngine, _ proj: Projector,
                          _ b: (minLat: Double, minLon: Double, maxLat: Double, maxLon: Double),
                          _ z: Double, _ sizeScale: Double, _ theme: MapTheme) {
        let ids = e.areas.features(minLat: b.minLat, minLon: b.minLon, maxLat: b.maxLat, maxLon: b.maxLon,
                                   marker: e.areaVisit)
        if ids.isEmpty { return }
        let zi = Int(z.rounded(.down))
        var feats: [AreaFeature] = []
        feats.reserveCapacity(ids.count)
        for id in ids {
            let f = e.areas.feature(id)
            if f.minZoom <= zi { feats.append(f) }
        }
        // леса, потом парки, потом вода, потом реки
        let order: [AreaKind] = [.forest, .park, .water]
        for kind in order {
            let color: Color = kind == .forest ? theme.forest : (kind == .park ? theme.park : theme.water)
            for f in feats where f.kind == kind {
                var path = Path()
                for r in f.ringStart..<(f.ringStart + f.ringCount) {
                    let ring = e.areas.ring(r)
                    if ring.count < 3 { continue }
                    for k in 0..<ring.count {
                        let c = e.areas.point(ring.start + k)
                        let p = proj.point(c)
                        if k == 0 { path.move(to: p) } else { path.addLine(to: p) }
                    }
                    path.closeSubpath()
                }
                ctx.fill(path, with: .color(color), style: FillStyle(eoFill: true))
            }
        }
        for f in feats where f.kind == .river || f.kind == .canal {
            var path = Path()
            for r in f.ringStart..<(f.ringStart + f.ringCount) {
                let ring = e.areas.ring(r)
                for k in 0..<ring.count {
                    let c = e.areas.point(ring.start + k)
                    let p = proj.point(c)
                    if k == 0 { path.move(to: p) } else { path.addLine(to: p) }
                }
            }
            let w = (f.kind == .river ? 3.2 : 2.0) * max(sizeScale, 0.5)
            ctx.stroke(path, with: .color(theme.water), style: StrokeStyle(lineWidth: w, lineCap: .round, lineJoin: .round))
        }
    }

    // MARK: дороги

    static func drawRoads(_ ctx: inout GraphicsContext, _ e: MapEngine, _ proj: Projector,
                          _ b: (minLat: Double, minLon: Double, maxLat: Double, maxLon: Double),
                          _ z: Double, _ sizeScale: Double, _ theme: MapTheme, _ labels: Bool,
                          _ labelRects: inout [CGRect]) {
        let level = z < 10 ? 0 : (z < 14 ? 1 : 2)
        let maxCls = z >= 16 ? 8 : (z >= 15 ? 7 : (z >= 14 ? 6 : 5))
        var paths = [Path](repeating: Path(), count: 9)
        var cands: [(seg: Int, a: CGPoint, b: CGPoint, len: CGFloat)] = []
        let wantLabels = labels && z >= 15

        e.graph.forEachSegment(level: level, minLat: b.minLat, minLon: b.minLon,
                               maxLat: b.maxLat, maxLon: b.maxLon, marker: e.visit) { s in
            let cls = Int(e.graph.segmentClass(s))
            if cls > maxCls { return }
            var first = true
            var firstPt = CGPoint.zero
            var lastPt = CGPoint.zero
            e.graph.forEachPointE7(s) { la, lo in
                let p = proj.point(lat: Double(la) / 1e7, lon: Double(lo) / 1e7)
                if first {
                    paths[cls].move(to: p)
                    firstPt = p
                    first = false
                } else {
                    paths[cls].addLine(to: p)
                }
                lastPt = p
            }
            if wantLabels && cls <= 6 && e.graph.segmentNameId(s) != 0xFFFF_FFFF {
                let len = hypot(lastPt.x - firstPt.x, lastPt.y - firstPt.y)
                if len > 70 { cands.append((s, firstPt, lastPt, len)) }
            }
        }

        let base: [CGFloat] = [6.5, 6.0, 5.2, 4.4, 3.8, 3.2, 2.8, 2.2, 1.5]
        let k = CGFloat(sizeScale)
        let casingStyle = { (c: Int) in
            StrokeStyle(lineWidth: base[c] * k + 1.6, lineCap: .round, lineJoin: .round)
        }
        let fillStyle = { (c: Int) in
            StrokeStyle(lineWidth: base[c] * k, lineCap: .round, lineJoin: .round)
        }
        for c in stride(from: 8, through: 0, by: -1) where !paths[c].isEmpty {
            ctx.stroke(paths[c], with: .color(theme.casing), style: casingStyle(c))
        }
        for c in stride(from: 8, through: 0, by: -1) where !paths[c].isEmpty {
            ctx.stroke(paths[c], with: .color(theme.roadFill[c]), style: fillStyle(c))
        }

        if wantLabels && !cands.isEmpty {
            cands.sort { $0.len > $1.len }
            var drawn = 0
            for cnd in cands {
                if drawn >= 45 { break }
                guard let name = e.streetName(e.graph.segmentNameId(cnd.seg)) else { continue }
                let mid = CGPoint(x: (cnd.a.x + cnd.b.x) / 2, y: (cnd.a.y + cnd.b.y) / 2)
                var ang: Double = atan2(Double(cnd.b.y - cnd.a.y), Double(cnd.b.x - cnd.a.x))
                if ang > Double.pi / 2 { ang -= Double.pi }
                if ang < -Double.pi / 2 { ang += Double.pi }
                if let r = drawText(&ctx, name, at: mid, size: 11, weight: .regular, theme: theme,
                                    angle: ang, avoid: labelRects, maxWidth: cnd.len - 8) {
                    labelRects.append(r)
                    drawn += 1
                }
            }
        }
    }

    // MARK: подписи населённых пунктов

    static func drawPlaces(_ ctx: inout GraphicsContext, _ e: MapEngine, _ proj: Projector,
                           _ b: (minLat: Double, minLon: Double, maxLat: Double, maxLon: Double),
                           _ z: Double, _ theme: MapTheme, _ size: CGSize, _ labelRects: inout [CGRect]) {
        let minZoomForSub: [Double] = [6, 9, 11, 12.5, 13.5]
        var vis: [MapPlace] = []
        for p in e.places {
            if p.lat < b.minLat || p.lat > b.maxLat || p.lon < b.minLon || p.lon > b.maxLon { continue }
            if z < minZoomForSub[min(p.sub, 4)] { continue }
            vis.append(p)
        }
        vis.sort { $0.sub < $1.sub }
        var drawn = 0
        for p in vis {
            if drawn >= 60 { break }
            let pt = proj.point(lat: p.lat, lon: p.lon)
            if pt.x < -20 || pt.x > size.width + 20 || pt.y < -20 || pt.y > size.height + 20 { continue }
            let fs: CGFloat = p.sub == 0 ? 17 : (p.sub == 1 ? 14.5 : (p.sub == 2 ? 12.5 : 11))
            let w: Font.Weight = p.sub <= 1 ? .semibold : .regular
            if let r = drawText(&ctx, p.name, at: pt, size: fs, weight: w, theme: theme,
                                angle: 0, avoid: labelRects, maxWidth: 300) {
                labelRects.append(r)
                drawn += 1
            }
        }
    }

    /// Рисует подпись с обводкой. Возвращает занятый прямоугольник или nil, если места нет.
    static func drawText(_ ctx: inout GraphicsContext, _ s: String, at p: CGPoint, size: CGFloat,
                         weight: Font.Weight, theme: MapTheme, angle: Double,
                         avoid: [CGRect], maxWidth: CGFloat) -> CGRect? {
        let main = ctx.resolve(Text(s).font(.system(size: size, weight: weight)).foregroundColor(theme.text))
        let m = main.measure(in: CGSize(width: 600, height: 60))
        if m.width > maxWidth { return nil }
        let rect = CGRect(x: p.x - m.width / 2 - 2, y: p.y - m.height / 2 - 2,
                          width: m.width + 4, height: m.height + 4)
        // для повёрнутой подписи берём квадрат по большей стороне, чтобы не было наложений
        let box = angle == 0 ? rect : rect.insetBy(dx: -m.height / 2, dy: -m.height / 2)
        for r in avoid where r.intersects(box) { return nil }
        let halo = ctx.resolve(Text(s).font(.system(size: size, weight: weight)).foregroundColor(theme.halo))
        var c = ctx
        c.translateBy(x: p.x, y: p.y)
        if angle != 0 { c.rotate(by: .radians(angle)) }
        for (dx, dy) in [(-1.2, 0.0), (1.2, 0.0), (0.0, -1.2), (0.0, 1.2)] {
            c.draw(halo, at: CGPoint(x: dx, y: dy), anchor: .center)
        }
        c.draw(main, at: .zero, anchor: .center)
        return box
    }
}
