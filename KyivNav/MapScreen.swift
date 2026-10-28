import SwiftUI
import NavCore

/// Положение камеры и режим «следовать за машиной».
final class MapModel: ObservableObject {
    @Published var camera: Camera = .kyiv
    @Published var follow: Bool = false
    @Published var pin: Coord?
    @Published var pinName: String?
}

/// Карта на весь экран: рисует и принимает жесты.
struct MapScreen: View {
    @EnvironmentObject var store: MapStore
    @EnvironmentObject var nav: NavigationController
    @EnvironmentObject var model: MapModel
    @EnvironmentObject var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme

    @State private var startCamera: Camera?
    @State private var pinchBase: Double?
    @State private var rotationBase: Double?

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let anchor = CGPoint(x: size.width / 2, y: size.height * (model.follow ? 0.66 : 0.5))
            let input = RenderInput(
                camera: model.camera,
                anchor: anchor,
                engine: store.engine,
                route: nav.route?.coords ?? [],
                vehicle: nav.vehicle.map {
                    VehicleMarker(coord: $0, bearing: nav.vehicleBearing, accuracy: nav.vehicleAccuracy,
                                  sensorsOnly: nav.source == .sensors)
                },
                pin: model.pin,
                dark: colorScheme == .dark,
                streetNames: settings.showStreetNames)
            Canvas { context, canvasSize in
                MapRenderer.draw(&context, size: canvasSize, input: input)
            }
            .contentShape(Rectangle())
            .gesture(dragGesture(size: size, anchor: anchor))
            .simultaneousGesture(pinchGesture())
            .simultaneousGesture(rotateGesture())
            .simultaneousGesture(SpatialTapGesture().onEnded { value in
                let proj = Projector(camera: model.camera, origin: anchor)
                let c = proj.coord(at: value.location)
                model.pin = c
                model.pinName = nil
            })
        }
        .ignoresSafeArea()
        .onChange(of: nav.vehicle) { _ in followVehicle() }
        .onChange(of: nav.vehicleBearing) { _ in followVehicle() }
    }

    // MARK: следование

    private func followVehicle() {
        guard model.follow, let v = nav.vehicle else { return }
        var cam = model.camera
        cam.center = v
        if settings.rotateMap && nav.phase == .navigating {
            cam.bearing = nav.vehicleBearing
        }
        model.camera = cam
    }

    // MARK: жесты

    private func dragGesture(size: CGSize, anchor: CGPoint) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                if startCamera == nil {
                    startCamera = model.camera
                    model.follow = false
                }
                guard let base = startCamera else { return }
                let proj = Projector(camera: base, origin: anchor)
                let target = CGPoint(x: anchor.x - value.translation.width,
                                     y: anchor.y - value.translation.height)
                var cam = model.camera
                cam.center = proj.coord(at: target)
                model.camera = cam
            }
            .onEnded { _ in startCamera = nil }
    }

    private func pinchGesture() -> some Gesture {
        MagnificationGesture()
            .onChanged { scale in
                if pinchBase == nil { pinchBase = model.camera.zoom }
                guard let base = pinchBase, scale > 0 else { return }
                var cam = model.camera
                cam.zoom = min(max(base + log2(Double(scale)), Camera.minZoom), Camera.maxZoom)
                model.camera = cam
            }
            .onEnded { _ in pinchBase = nil }
    }

    private func rotateGesture() -> some Gesture {
        RotationGesture()
            .onChanged { angle in
                if rotationBase == nil {
                    rotationBase = model.camera.bearing
                    model.follow = false
                }
                guard let base = rotationBase else { return }
                var cam = model.camera
                var b = (base - angle.degrees).truncatingRemainder(dividingBy: 360)
                if b < 0 { b += 360 }
                cam.bearing = b
                model.camera = cam
            }
            .onEnded { _ in rotationBase = nil }
    }
}
