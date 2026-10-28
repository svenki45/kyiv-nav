import SwiftUI
import MapKit

struct ContentView: View {
    @EnvironmentObject var hub: SensorHub

    @State private var region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 50.4501, longitude: 30.5234),
        span: MKCoordinateSpan(latitudeDelta: 0.1, longitudeDelta: 0.1)
    )

    var body: some View {
        ZStack(alignment: .bottom) {
            Map(coordinateRegion: $region, showsUserLocation: true)
                .ignoresSafeArea()

            VStack(spacing: 10) {
                statusCard
                dataCard
                ShareLink(item: hub.logURL) {
                    Label("Отправить лог поездки", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
        }
        .onChange(of: hub.coordinate?.latitude) { _ in
            if let c = hub.coordinate {
                region.center = c
            }
        }
    }

    private var statusColor: Color {
        switch hub.state {
        case .ok: return .green
        case .waiting: return .gray
        case .poor: return .orange
        case .lost: return .red
        }
    }

    private var statusCard: some View {
        HStack(spacing: 12) {
            Circle().fill(statusColor).frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(hub.state.title).font(.headline)
                if !hub.state.detail.isEmpty {
                    Text(hub.state.detail).font(.caption)
                }
            }
            Spacer()
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private var dataCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            row("Скорость (GPS)", String(format: "%.0f км/ч", hub.speedKmh))
            row("Точность GPS", String(format: "%.0f м", hub.accuracyM))
            row("Направление (компас)", String(format: "%.0f°", hub.headingDeg))
            row("Тряска/ускорение", String(format: "%.2f g", hub.motionG))
            row("Поворот", String(format: "%.0f °/с", hub.turnRate))
            row("Скачков GPS", "\(hub.jumpCount)")
            row("Записей в логе", "\(hub.logRows)")
        }
        .font(.callout)
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private func row(_ name: String, _ value: String) -> some View {
        HStack {
            Text(name)
            Spacer()
            Text(value).monospacedDigit()
        }
    }
}
