import SwiftUI
import NavCore

struct ContentView: View {
    @EnvironmentObject var store: MapStore
    @EnvironmentObject var nav: NavigationController
    @EnvironmentObject var hub: SensorHub
    @EnvironmentObject var model: MapModel
    @EnvironmentObject var settings: AppSettings

    @State private var showSearch = false
    @State private var showSettings = false
    @State private var didCenter = false

    var body: some View {
        ZStack {
            MapScreen()

            VStack(spacing: 8) {
                topArea
                Spacer()
                bottomArea
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 6)

            sideButtons
        }
        .sheet(isPresented: $showSearch) {
            SearchSheet { r in pick(r) }
                .environmentObject(store)
                .environmentObject(model)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environmentObject(store)
                .environmentObject(settings)
                .environmentObject(hub)
                .environmentObject(nav)
        }
        .onReceive(store.$engine) { nav.engine = $0 }
        .onChange(of: settings.saveLog) { hub.saveLog = $0 }
        .onChange(of: settings.voiceOn) { nav.speaker.enabled = $0 }
        .onChange(of: nav.phase) { phase in phaseChanged(phase) }
        .onChange(of: nav.vehicle) { v in
            if !didCenter, let v = v {
                didCenter = true
                var cam = model.camera
                cam.center = v
                cam.zoom = 15
                model.camera = cam
            }
        }
        .onAppear {
            hub.saveLog = settings.saveLog
            nav.speaker.enabled = settings.voiceOn
        }
    }

    // MARK: верх

    @ViewBuilder
    private var topArea: some View {
        if nav.phase == .navigating, let r = nav.route, let st = nav.track,
           st.nextManeuver < r.maneuvers.count {
            ManeuverBanner(maneuver: r.maneuvers[st.nextManeuver], distance: st.distanceToNext)
        } else {
            HStack(spacing: 10) {
                Button { showSearch = true } label: {
                    HStack {
                        Image(systemName: "magnifyingglass")
                        Text("Куди їдемо?")
                        Spacer()
                    }
                    .foregroundColor(.secondary)
                    .padding(12)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                Button { showSettings = true } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 20))
                        .frame(width: 46, height: 46)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
            }
        }
        HStack(alignment: .top) {
            gpsChip
            Spacer()
        }
        if settings.showGPSPanel {
            HStack {
                gpsPanel
                Spacer()
            }
        }
        if let n = nav.notice {
            Text(n)
                .font(.callout.weight(.semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
        }
    }

    private var gpsColor: Color {
        if nav.source == .sensors { return .orange }
        switch hub.state {
        case .ok: return .green
        case .waiting: return .gray
        case .poor: return .orange
        case .lost: return .red
        }
    }

    private var gpsText: String {
        if nav.source == .sensors {
            return nav.phase == .navigating ? "Без GPS: їду за маршрутом" : "Без GPS: за датчиками"
        }
        return hub.state.title
    }

    private var gpsChip: some View {
        Menu {
            Button {
                hub.forceSensors.toggle()
            } label: {
                Label(hub.forceSensors ? "Знову вірити GPS" : "Не вірити GPS (тільки датчики)",
                      systemImage: hub.forceSensors ? "location.fill" : "location.slash.fill")
            }
            Button {
                settings.showGPSPanel.toggle()
            } label: {
                Label(settings.showGPSPanel ? "Сховати дані GPS" : "Показати дані GPS",
                      systemImage: "waveform.path.ecg")
            }
        } label: {
            HStack(spacing: 8) {
                Circle().fill(gpsColor).frame(width: 12, height: 12)
                VStack(alignment: .leading, spacing: 0) {
                    Text(gpsText).font(.footnote.weight(.semibold))
                    if !hub.state.detail.isEmpty && nav.source != .sensors {
                        Text(hub.state.detail).font(.caption2)
                    }
                }
            }
            .foregroundColor(.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.regularMaterial, in: Capsule())
        }
    }

    private var gpsPanel: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(String(format: "Швидкість %.0f км/год", hub.speedKmh))
            Text(String(format: "Точність %.0f м", hub.accuracyM))
            Text(String(format: "Поворот %.0f °/с, тряска %.2f g", hub.turnRate, hub.motionG))
            Text("Стрибків GPS: \(hub.jumpCount)")
        }
        .font(.caption.monospacedDigit())
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: боковые кнопки

    private var sideButtons: some View {
        HStack {
            Spacer()
            VStack(spacing: 10) {
                if abs(model.camera.bearing) > 1 && abs(model.camera.bearing - 360) > 1 {
                    roundButton("location.north.fill") {
                        var cam = model.camera
                        cam.bearing = 0
                        model.camera = cam
                    }
                }
                roundButton("plus") { zoom(by: 1) }
                roundButton("minus") { zoom(by: -1) }
                roundButton(model.follow ? "location.fill" : "location") { recenter() }
            }
            .padding(.trailing, 12)
        }
    }

    private func roundButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 46, height: 46)
                .background(.regularMaterial, in: Circle())
        }
        .buttonStyle(.plain)
    }

    private func zoom(by d: Double) {
        var cam = model.camera
        cam.zoom = min(max(cam.zoom + d, Camera.minZoom), Camera.maxZoom)
        model.camera = cam
    }

    private func recenter() {
        guard let v = nav.vehicle else { return }
        model.follow = true
        var cam = model.camera
        cam.center = v
        if cam.zoom < 14 { cam.zoom = 15.5 }
        if settings.rotateMap && nav.phase == .navigating { cam.bearing = nav.vehicleBearing }
        model.camera = cam
    }

    // MARK: низ

    @ViewBuilder
    private var bottomArea: some View {
        if store.engine == nil {
            noMapCard
        } else {
            switch nav.phase {
            case .navigating:
                navigatingBar
            case .arrived:
                arrivedCard
            case .preview:
                previewCard
            case .browsing:
                if nav.isRouting {
                    card {
                        HStack {
                            ProgressView()
                            Text("Будую маршрут…").padding(.leading, 8)
                            Spacer()
                        }
                    }
                } else if let err = nav.routeError {
                    card {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(err).font(.callout)
                            Button("Закрити") { nav.routeError = nil; nav.destination = nil }
                        }
                    }
                } else if let pin = model.pin {
                    pinCard(pin)
                }
            }
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(14)
            .frame(maxWidth: .infinity)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
    }

    private var noMapCard: some View {
        card {
            VStack(alignment: .leading, spacing: 10) {
                switch store.status {
                case .downloading(let p, let text):
                    Text("Завантажую карту").font(.headline)
                    ProgressView(value: p)
                    Text(text).font(.caption)
                case .loading, .verifying, .checking:
                    HStack {
                        ProgressView()
                        Text("Готую карту…").padding(.leading, 8)
                    }
                case .failed(let t):
                    Text("Карта не завантажилась").font(.headline)
                    Text(t).font(.callout)
                    Button("Відкрити налаштування") { showSettings = true }
                        .buttonStyle(.borderedProminent)
                default:
                    Text("Потрібна офлайн-карта").font(.headline)
                    Text("Завантажте карту Києва та області один раз — далі навігатор працює без інтернету.")
                        .font(.callout)
                    Button {
                        store.download()
                        showSettings = true
                    } label: {
                        Label("Завантажити карту", systemImage: "arrow.down.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private func pinCard(_ pin: Coord) -> some View {
        card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.pinName ?? "Обрана точка").font(.headline)
                        Text(String(format: "%.5f, %.5f", pin.lat, pin.lon))
                            .font(.caption).foregroundColor(.secondary)
                    }
                    Spacer()
                    Button {
                        model.pin = nil
                        model.pinName = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill").font(.title2).foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                Button {
                    nav.setDestination(name: model.pinName ?? "Обрана точка", coord: pin)
                } label: {
                    Label("Маршрут сюди", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private var previewCard: some View {
        card {
            VStack(alignment: .leading, spacing: 10) {
                Text(nav.destination?.name ?? "Маршрут").font(.headline)
                if let r = nav.route {
                    HStack(spacing: 18) {
                        Label(Format.distance(r.distanceM), systemImage: "arrow.triangle.swap")
                        Label(Format.duration(r.timeS), systemImage: "clock")
                    }
                    .font(.title3.weight(.semibold))
                }
                HStack(spacing: 10) {
                    Button {
                        nav.stop()
                        model.pin = nil
                    } label: {
                        Text("Скасувати").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    Button {
                        nav.startNavigation()
                    } label: {
                        Text("Поїхали").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                }
            }
        }
    }

    private var navigatingBar: some View {
        card {
            VStack(spacing: 10) {
                if nav.source == .sensors {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                        Text("GPS немає або йому не можна вірити. Їду за маршрутом приблизно.")
                            .font(.footnote)
                        Spacer()
                    }
                }
                HStack {
                    stat(nav.track.map { Format.distance($0.remaining) } ?? "—", "залишилось")
                    Spacer()
                    stat(nav.track.map { Format.duration($0.remainingTime) } ?? "—", "часу")
                    Spacer()
                    stat(etaText, "прибуття")
                    Spacer()
                    stat(String(format: "%.0f", nav.speedMS * 3.6), "км/год")
                }
                Button(role: .destructive) {
                    nav.stop()
                    model.pin = nil
                    model.follow = false
                } label: {
                    Text("Завершити").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var arrivedCard: some View {
        card {
            VStack(spacing: 10) {
                Text("Ви прибули").font(.title2.weight(.bold))
                Text(nav.destination?.name ?? "").foregroundColor(.secondary)
                Button {
                    nav.stop()
                    model.pin = nil
                    model.follow = false
                } label: {
                    Text("Готово").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func stat(_ value: String, _ caption: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.title3.weight(.bold)).monospacedDigit()
            Text(caption).font(.caption2).foregroundColor(.secondary)
        }
    }

    private var etaText: String {
        guard let st = nav.track else { return "—" }
        let d = Date().addingTimeInterval(st.remainingTime)
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: d)
    }

    // MARK: действия

    private func pick(_ r: SearchResult) {
        model.pin = r.coord
        model.pinName = r.name
        model.follow = false
        var cam = model.camera
        cam.center = r.coord
        cam.zoom = max(cam.zoom, 14)
        model.camera = cam
        nav.setDestination(name: r.name, coord: r.coord)
    }

    private func phaseChanged(_ phase: NavPhase) {
        switch phase {
        case .preview:
            fitRoute()
        case .navigating:
            model.follow = true
            var cam = model.camera
            if let v = nav.vehicle { cam.center = v }
            cam.zoom = 16.5
            if settings.rotateMap { cam.bearing = nav.vehicleBearing }
            model.camera = cam
        case .browsing:
            var cam = model.camera
            cam.bearing = 0
            model.camera = cam
        case .arrived:
            break
        }
    }

    private func fitRoute() {
        guard let r = nav.route, !r.coords.isEmpty else { return }
        var minLat = 90.0, maxLat = -90.0, minLon = 180.0, maxLon = -180.0
        for c in r.coords {
            minLat = min(minLat, c.lat); maxLat = max(maxLat, c.lat)
            minLon = min(minLon, c.lon); maxLon = max(maxLon, c.lon)
        }
        let center = Coord(lat: (minLat + maxLat) / 2, lon: (minLon + maxLon) / 2)
        let screen = UIScreen.main.bounds.size
        let lonSpan = max(maxLon - minLon, 0.0005)
        let latSpan = max(maxLat - minLat, 0.0005)
        let zLon = log2(Double(screen.width) * 0.75 * 360 / (256 * lonSpan))
        let zLat = log2(Double(screen.height) * 0.42 * 360 * cos(center.lat * Double.pi / 180) / (256 * latSpan))
        var cam = model.camera
        cam.center = center
        cam.zoom = min(max(min(zLon, zLat), Camera.minZoom), 17)
        cam.bearing = 0
        model.follow = false
        model.camera = cam
    }
}

struct ManeuverBanner: View {
    let maneuver: Maneuver
    let distance: Double

    private var symbol: String {
        switch maneuver.kind {
        case .depart: return "arrow.up"
        case .slightLeft: return "arrow.up.left"
        case .left: return "arrow.turn.up.left"
        case .sharpLeft: return "arrow.turn.down.left"
        case .slightRight: return "arrow.up.right"
        case .right: return "arrow.turn.up.right"
        case .sharpRight: return "arrow.turn.down.right"
        case .uTurn: return "arrow.uturn.down"
        case .roundabout: return "arrow.triangle.2.circlepath"
        case .arrive: return "flag.checkered"
        }
    }

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 40, weight: .bold))
                .frame(width: 54)
            VStack(alignment: .leading, spacing: 2) {
                Text(Format.distance(distance))
                    .font(.system(size: 30, weight: .bold))
                    .monospacedDigit()
                Text(maneuver.text)
                    .font(.callout)
                    .lineLimit(2)
            }
            Spacer()
        }
        .foregroundColor(.white)
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(Color(red: 0.04, green: 0.27, blue: 0.58), in: RoundedRectangle(cornerRadius: 18))
    }
}
