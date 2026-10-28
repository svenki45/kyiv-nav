import XCTest
@testable import NavCore

struct Expected: Decodable {
    struct Q: Decodable {
        let label: String
        let from: [Double]
        let to: [Double]
        let timeS: Double
        let lengthM: Double
        let streets: [String]
    }
    let queries: [Q]
    let segmentsRoutable: Int
}

final class NavCoreTests: XCTestCase {

    static func res(_ name: String, _ ext: String) -> String {
        guard let url = Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Resources") else {
            fatalError("нет файла \(name).\(ext)")
        }
        return url.path
    }

    func loadGraph() throws -> GraphData {
        return try GraphData(path: NavCoreTests.res("graph", "bin"))
    }

    func loadExpected() throws -> Expected {
        let data = try Data(contentsOf: URL(fileURLWithPath: NavCoreTests.res("expected", "json")))
        return try JSONDecoder().decode(Expected.self, from: data)
    }

    func mergedStreets(_ route: Route) -> [String] {
        var out: [String] = []
        for leg in route.legs {
            let n = leg.name ?? "?"
            if out.last != n { out.append(n) }
        }
        return out
    }

    // MARK: файлы

    func testGraphBasics() throws {
        let g = try loadGraph()
        let exp = try loadExpected()
        XCTAssertEqual(g.nodeCount, 37)
        XCTAssertEqual(g.segCount, 63)
        XCTAssertEqual(g.arcCount, exp.segmentsRoutable)
        // у каждого сегмента есть геометрия минимум из двух точек
        for s in 0..<g.segCount {
            XCTAssertGreaterThanOrEqual(g.geometry(s).count, 2)
        }
    }

    func testNamesWithSpacesAndCommas() throws {
        let g = try loadGraph()
        var found = false
        for s in 0..<g.segCount {
            if g.name(g.segment(s).nameId) == "Діагональна, швидка" { found = true }
        }
        XCTAssertTrue(found, "название с запятой не прочиталось")
    }

    // MARK: привязка

    func testSnap() throws {
        let g = try loadGraph()
        let router = Router(graph: g)
        let node = Coord(lat: 50.454, lon: 30.526) // перекрёсток (2,2)
        let on = router.snap(node)
        XCTAssertNotNil(on)
        XCTAssertLessThan(on!.distance, 1.0)
        let shifted = Geo.destination(from: node, bearing: 90, meters: 10)
        let s2 = router.snap(Coord(lat: shifted.lat, lon: shifted.lon + 0.0))
        XCTAssertNotNil(s2)
        XCTAssertLessThan(s2!.distance, 12.0)
        // далеко от дорог — не привязываем
        XCTAssertNil(router.snap(Coord(lat: 49.0, lon: 28.0)))
    }

    // MARK: маршруты

    func testRoutesMatchExpected() throws {
        let g = try loadGraph()
        let exp = try loadExpected()
        let router = Router(graph: g)
        for q in exp.queries {
            let from = Coord(lat: q.from[0], lon: q.from[1])
            let to = Coord(lat: q.to[0], lon: q.to[1])
            guard let r = router.route(from: from, to: to) else {
                XCTFail("нет маршрута: \(q.label)")
                continue
            }
            XCTAssertEqual(r.timeS, q.timeS, accuracy: 1.0, q.label)
            XCTAssertEqual(r.distanceM, q.lengthM, accuracy: 2.0, q.label)
            XCTAssertEqual(mergedStreets(r), q.streets, q.label)
        }
    }

    func testRouteFromMiddleOfSegment() throws {
        let g = try loadGraph()
        let router = Router(graph: g)
        // из середины улицы Рядна 1 в середину Колонна 3
        let a = Coord(lat: 50.452, lon: 30.5235)
        let b = Coord(lat: 50.4565, lon: 30.529)
        guard let r = router.route(from: a, to: b) else { return XCTFail("нет маршрута") }
        XCTAssertGreaterThan(r.distanceM, Geo.distance(a, b) - 1)
        XCTAssertLessThan(r.distanceM, 1200)
        XCTAssertGreaterThanOrEqual(r.maneuvers.count, 2)
        XCTAssertEqual(r.maneuvers.first?.kind, .depart)
        XCTAssertEqual(r.maneuvers.last?.kind, .arrive)
    }

    func testOnewayBlocked() throws {
        let g = try loadGraph()
        let router = Router(graph: g)
        // по односторонней можно напрямую, против — нет
        let w = Coord(lat: 50.458, lon: 30.52)
        let e = Coord(lat: 50.458, lon: 30.535)
        guard let fwd = router.route(from: w, to: e), let back = router.route(from: e, to: w) else {
            return XCTFail("нет маршрута")
        }
        XCTAssertLessThan(fwd.distanceM, 1100)
        XCTAssertGreaterThan(back.distanceM, 1500)
    }

    // MARK: подсказки

    func testManeuvers() throws {
        let g = try loadGraph()
        let exp = try loadExpected()
        let router = Router(graph: g)
        guard let q = exp.queries.first(where: { $0.label == "против односторонней" }) else {
            return XCTFail("нет запроса")
        }
        guard let r = router.route(from: Coord(lat: q.from[0], lon: q.from[1]),
                                   to: Coord(lat: q.to[0], lon: q.to[1])) else { return XCTFail("нет маршрута") }
        let kinds = r.maneuvers.map { $0.kind }
        XCTAssertEqual(kinds, [.depart, .right, .right, .arrive], "\(r.maneuvers.map { $0.text })")
        XCTAssertEqual(r.maneuvers[1].streetName, "Проспект Тестовий")
        XCTAssertEqual(r.maneuvers[2].streetName, "Вулиця Колонна 0")
        var prev = -1.0
        for m in r.maneuvers {
            XCTAssertGreaterThanOrEqual(m.distanceFromStart, prev)
            prev = m.distanceFromStart
        }
        XCTAssertEqual(r.maneuvers.last!.distanceFromStart, r.distanceM, accuracy: 3.0)
    }

    func testSpokenText() {
        let m = Maneuver(kind: .right, coordIndex: 0, distanceFromStart: 0, streetName: "Хрещатик",
                         exitNumber: nil, turnAngle: 90, coord: Coord(lat: 0, lon: 0))
        XCTAssertEqual(m.text, "Поверніть праворуч, Хрещатик")
        XCTAssertEqual(m.spoken(distance: 300), "Через 300 метрів, поверніть праворуч, Хрещатик")
        XCTAssertEqual(Format.distance(1530), "1,5 км")
        XCTAssertEqual(Format.distance(430), "450 м")
    }

    // MARK: слежение

    func testTracker() throws {
        let g = try loadGraph()
        let exp = try loadExpected()
        let router = Router(graph: g)
        let q = exp.queries[1]
        guard let r = router.route(from: Coord(lat: q.from[0], lon: q.from[1]),
                                   to: Coord(lat: q.to[0], lon: q.to[1])) else { return XCTFail("нет маршрута") }
        let tracker = RouteTracker(route: r)
        var prev = -1.0
        for c in r.coords {
            let st = tracker.update(position: c)
            XCTAssertLessThan(st.crossTrack, 1.0)
            XCTAssertGreaterThanOrEqual(st.distanceAlong, prev - 0.01)
            prev = st.distanceAlong
        }
        let end = tracker.update(position: r.coords.last!)
        XCTAssertLessThan(end.remaining, 2.0)
        // 100 м в сторону от диагонали (она идёт на северо-восток, смещаемся на юго-восток)
        let off = Geo.destination(from: r.coords[3], bearing: 135, meters: 100)
        tracker.reset()
        let st = tracker.update(position: off, searchAll: true)
        XCTAssertGreaterThan(st.crossTrack, 50.0)
    }

    // MARK: датчики

    func testTurnDetector() {
        var d = TurnDetector()
        var result: Double? = nil
        for _ in 0..<60 { if let r = d.feed(dt: 0.1, rate: 15) { result = r } }
        XCTAssertNil(result)
        for _ in 0..<15 { if let r = d.feed(dt: 0.1, rate: 0) { result = r } }
        XCTAssertNotNil(result)
        XCTAssertEqual(result ?? 0, 90, accuracy: 5)

        var l = TurnDetector()
        var left: Double? = nil
        for _ in 0..<40 { _ = l.feed(dt: 0.1, rate: -20) }
        for _ in 0..<15 { if let r = l.feed(dt: 0.1, rate: 0) { left = r } }
        XCTAssertEqual(left ?? 0, -80, accuracy: 5)

        // лёгкое покачивание (смена полосы) — не поворот
        var s = TurnDetector()
        var none: Double? = nil
        for _ in 0..<10 { _ = s.feed(dt: 0.1, rate: 8) }
        for _ in 0..<15 { if let r = s.feed(dt: 0.1, rate: 0) { none = r } }
        XCTAssertNil(none)
    }

    func testDeadReckoner() {
        let ms = [
            Maneuver(kind: .depart, coordIndex: 0, distanceFromStart: 0, streetName: nil, exitNumber: nil,
                     turnAngle: 0, coord: Coord(lat: 0, lon: 0)),
            Maneuver(kind: .left, coordIndex: 1, distanceFromStart: 120, streetName: nil, exitNumber: nil,
                     turnAngle: -90, coord: Coord(lat: 0, lon: 0)),
            Maneuver(kind: .right, coordIndex: 2, distanceFromStart: 260, streetName: nil, exitNumber: nil,
                     turnAngle: 90, coord: Coord(lat: 0, lon: 0)),
            Maneuver(kind: .arrive, coordIndex: 3, distanceFromStart: 900, streetName: nil, exitNumber: nil,
                     turnAngle: 0, coord: Coord(lat: 0, lon: 0)),
        ]
        var dr = DeadReckoner(distance: 100, speed: 10, total: 900)
        dr.advance(dt: 5)
        XCTAssertEqual(dr.distance, 150, accuracy: 0.01)
        // правый поворот: левый на 120 м не подходит, берём правый на 260 м
        let idx = dr.sync(turnAngle: 85, maneuvers: ms)
        XCTAssertEqual(idx, 2)
        XCTAssertEqual(dr.distance, 268, accuracy: 0.01)
        // поворот, которого на маршруте нет рядом, ничего не меняет
        var far = DeadReckoner(distance: 600, speed: 10, total: 900)
        XCTAssertNil(far.sync(turnAngle: -85, maneuvers: ms))
        XCTAssertEqual(far.distance, 600, accuracy: 0.01)
    }

    // MARK: области и поиск

    func testAreas() throws {
        let a = try AreaData(path: NavCoreTests.res("areas", "bin"))
        XCTAssertEqual(a.featCount, 4)
        let marker = VisitMarker(count: a.featCount)
        let ids = a.features(minLat: 50.0, minLon: 30.0, maxLat: 51.0, maxLon: 31.0, marker: marker)
        let kinds = Set(ids.map { a.feature($0).kind.rawValue })
        XCTAssertTrue(kinds.contains(AreaKind.water.rawValue))
        XCTAssertTrue(kinds.contains(AreaKind.forest.rawValue))
        XCTAssertTrue(kinds.contains(AreaKind.river.rawValue))
        // мультиполигон: внешнее кольцо + остров
        let mp = ids.map { a.feature($0) }.first { $0.kind == .water && $0.ringCount == 2 }
        XCTAssertNotNil(mp, "озеро с островом не собралось")
    }

    func testSearch() throws {
        let s = try SearchIndex(path: NavCoreTests.res("search", "bin"))
        s.prepare()
        XCTAssertEqual(s.count, 19)
        let city = s.search("тестогр", near: nil)
        XCTAssertEqual(city.first?.name, "Тестоград")
        XCTAssertEqual(city.first?.kind, .place)
        let cafe = s.search("кафе", near: nil)
        XCTAssertEqual(cafe.first?.name, "Кафе Тест")
        XCTAssertEqual(cafe.first?.kind, .poi)
        let street = s.search("колонна 3", near: nil)
        XCTAssertEqual(street.first?.name, "Вулиця Колонна 3")
        XCTAssertEqual(street.first?.detail, "Тестоград")
        XCTAssertTrue(s.search("zzzz", near: nil).isEmpty)
        let places = s.places(minLat: 50.0, minLon: 30.0, maxLat: 51.0, maxLon: 31.0, maxSub: 2, limit: 50)
        XCTAssertEqual(places.count, 2)
    }
}
