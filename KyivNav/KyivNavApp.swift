import SwiftUI

@main
struct KyivNavApp: App {
    @StateObject private var settings: AppSettings
    @StateObject private var hub: SensorHub
    @StateObject private var store: MapStore
    @StateObject private var nav: NavigationController
    @StateObject private var model = MapModel()

    init() {
        let s = AppSettings()
        let h = SensorHub()
        _settings = StateObject(wrappedValue: s)
        _hub = StateObject(wrappedValue: h)
        _store = StateObject(wrappedValue: MapStore())
        _nav = StateObject(wrappedValue: NavigationController(hub: h, settings: s))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(settings)
                .environmentObject(hub)
                .environmentObject(store)
                .environmentObject(nav)
                .environmentObject(model)
                .preferredColorScheme(settings.colorScheme)
        }
    }
}
