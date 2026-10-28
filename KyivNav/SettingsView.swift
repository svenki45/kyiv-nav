import SwiftUI
import NavCore

struct SettingsView: View {
    @EnvironmentObject var store: MapStore
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var hub: SensorHub
    @Environment(\.dismiss) private var dismiss

    @State private var confirmDelete = false

    var body: some View {
        NavigationStack {
            Form {
                mapSection
                navigationSection
                appearanceSection
                gpsSection
                aboutSection
            }
            .navigationTitle("Налаштування")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
            .confirmationDialog("Видалити карту з телефону?", isPresented: $confirmDelete,
                                titleVisibility: .visible) {
                Button("Видалити", role: .destructive) { store.delete() }
                Button("Скасувати", role: .cancel) {}
            }
        }
    }

    // MARK: карта

    private var mapSection: some View {
        Section {
            switch store.status {
            case .missing:
                Text("Карта Києва та області ще не завантажена. Вона потрібна, щоб навігатор працював без інтернету (приблизно 60 МБ).")
                    .font(.callout)
                Button {
                    store.download()
                } label: {
                    Label("Завантажити карту", systemImage: "arrow.down.circle.fill")
                }
            case .checking:
                HStack {
                    ProgressView()
                    Text("Перевіряю сервер…").padding(.leading, 8)
                }
            case .downloading(let p, let text):
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: p)
                    Text("Завантажую: \(text)").font(.callout)
                }
                Button(role: .destructive) {
                    store.cancel()
                } label: {
                    Text("Скасувати")
                }
            case .verifying:
                HStack {
                    ProgressView()
                    Text("Перевіряю файли…").padding(.leading, 8)
                }
            case .loading:
                HStack {
                    ProgressView()
                    Text("Відкриваю карту…").padding(.leading, 8)
                }
            case .installed(let size):
                Label("Карта встановлена (\(size))", systemImage: "checkmark.circle.fill")
                    .foregroundColor(.green)
                Text("Київ і Київська область. Працює без інтернету.")
                    .font(.callout)
                    .foregroundColor(.secondary)
                Button(role: .destructive) {
                    confirmDelete = true
                } label: {
                    Label("Видалити карту", systemImage: "trash")
                }
            case .failed(let text):
                Label("Помилка", systemImage: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                Text(text).font(.callout)
                Button {
                    store.download()
                } label: {
                    Label("Спробувати ще раз", systemImage: "arrow.clockwise")
                }
                if store.isInstalled {
                    Button {
                        store.loadIfInstalled()
                    } label: {
                        Text("Відкрити наявну карту")
                    }
                }
            }
        } header: {
            Text("Офлайн-карта")
        } footer: {
            Text("Краще завантажувати через Wi-Fi.")
        }
    }

    // MARK: навигация

    private var navigationSection: some View {
        Section {
            Toggle("Голосові підказки", isOn: $settings.voiceOn)
            Toggle("Їхати за датчиками, якщо GPS зник", isOn: $settings.deadReckoning)
            Toggle("Повертати карту за напрямком руху", isOn: $settings.rotateMap)
            Toggle("Не вимикати екран під час навігації", isOn: $settings.keepAwake)
        } header: {
            Text("Навігація")
        } footer: {
            Text("Коли GPS глушать або підміняють, програма продовжує вести по маршруту: тримає останню швидкість, звіряється за поворотами (гіроскоп) і зупиняється разом із вами (вібрація). Це наближений режим, він точний лише поки ви їдете за маршрутом.")
        }
    }

    // MARK: вид

    private var appearanceSection: some View {
        Section {
            Picker("Тема", selection: $settings.appearance) {
                Text("Авто").tag("auto")
                Text("Світла").tag("light")
                Text("Темна").tag("dark")
            }
            .pickerStyle(.segmented)
            Toggle("Назви вулиць на карті", isOn: $settings.showStreetNames)
        } header: {
            Text("Вигляд")
        }
    }

    // MARK: GPS

    private var gpsSection: some View {
        Section {
            Toggle("Показувати панель GPS на карті", isOn: $settings.showGPSPanel)
            Toggle("Записувати журнал поїздки", isOn: $settings.saveLog)
            NavigationLink("Дані GPS і датчиків") {
                DiagnosticsView()
            }
            ShareLink(item: hub.logFileForSharing()) {
                Label("Надіслати журнал поїздки", systemImage: "square.and.arrow.up")
            }
        } header: {
            Text("GPS і датчики")
        } footer: {
            Text("Журнал допомагає налаштувати режим без GPS: у ньому видно, як саме GPS зникає чи бреше.")
        }
    }

    private var aboutSection: some View {
        Section {
            HStack {
                Text("Версія")
                Spacer()
                Text("0.2").foregroundColor(.secondary)
            }
            Text("Дані карти © учасники OpenStreetMap (ODbL).")
                .font(.footnote)
                .foregroundColor(.secondary)
        } header: {
            Text("Про програму")
        }
    }
}

struct DiagnosticsView: View {
    @EnvironmentObject var hub: SensorHub
    @EnvironmentObject var nav: NavigationController

    var body: some View {
        Form {
            Section {
                row("Стан GPS", hub.state.title)
                if !hub.state.detail.isEmpty { Text(hub.state.detail).font(.callout) }
                row("Швидкість (GPS)", String(format: "%.0f км/год", hub.speedKmh))
                row("Точність GPS", String(format: "%.0f м", hub.accuracyM))
                row("Напрямок (компас)", String(format: "%.0f°", hub.headingDeg))
                row("Напрямок (GPS)", hub.courseDeg >= 0 ? String(format: "%.0f°", hub.courseDeg) : "—")
                row("Тряска / прискорення", String(format: "%.3f g", hub.motionG))
                row("Поворот", String(format: "%.0f °/с", hub.turnRate))
                row("Стрибків GPS", "\(hub.jumpCount)")
                row("Записів у журналі", "\(hub.logRows)")
                row("Джерело положення", sourceText)
            }
            Section {
                Toggle("Не вірити GPS (тільки датчики)", isOn: $hub.forceSensors)
            } footer: {
                Text("Увімкніть, якщо GPS показує хибне місце, але програма цього не помічає.")
            }
        }
        .navigationTitle("GPS і датчики")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var sourceText: String {
        switch nav.source {
        case .none: return "немає"
        case .gps: return "GPS"
        case .sensors: return "датчики"
        }
    }

    private func row(_ name: String, _ value: String) -> some View {
        HStack {
            Text(name)
            Spacer()
            Text(value).monospacedDigit().foregroundColor(.secondary)
        }
    }
}
