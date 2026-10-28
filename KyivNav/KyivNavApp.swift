import SwiftUI

@main
struct KyivNavApp: App {
    @StateObject private var hub = SensorHub()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(hub)
        }
    }
}
