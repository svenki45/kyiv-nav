import SwiftUI
import NavCore

struct SearchSheet: View {
    @EnvironmentObject var store: MapStore
    @EnvironmentObject var model: MapModel
    @Environment(\.dismiss) private var dismiss

    let onPick: (SearchResult) -> Void

    @State private var text = ""
    @State private var results: [SearchResult] = []
    @State private var work: DispatchWorkItem?
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                    TextField("Вулиця, місто або місце", text: $text)
                        .focused($focused)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        .submitLabel(.search)
                    if !text.isEmpty {
                        Button { text = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                        }
                    }
                }
                .padding(10)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal)
                .padding(.vertical, 8)

                if store.engine == nil {
                    Text("Карта ще не завантажена. Відкрийте Налаштування → Карта.")
                        .foregroundColor(.secondary)
                        .padding()
                    Spacer()
                } else if results.isEmpty && text.count >= 2 {
                    Text("Нічого не знайдено")
                        .foregroundColor(.secondary)
                        .padding()
                    Spacer()
                } else {
                    List(results.indices, id: \.self) { i in
                        let r = results[i]
                        Button {
                            onPick(r)
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: icon(r))
                                    .frame(width: 26)
                                    .foregroundColor(.accentColor)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(r.name).foregroundColor(.primary)
                                    if !r.detail.isEmpty {
                                        Text(r.detail).font(.caption).foregroundColor(.secondary)
                                    }
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Пошук")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Закрити") { dismiss() }
                }
            }
            .onAppear { focused = true }
            .onChange(of: text) { _ in scheduleSearch() }
        }
    }

    private func icon(_ r: SearchResult) -> String {
        switch r.kind {
        case .street: return "road.lanes"
        case .place: return "building.2"
        case .poi:
            switch r.sub {
            case 1: return "fork.knife"
            case 2: return "cart"
            case 3: return "fuelpump"
            case 4: return "cross.case"
            case 5: return "bed.double"
            case 6: return "banknote"
            default: return "mappin.circle"
            }
        }
    }

    private func scheduleSearch() {
        work?.cancel()
        guard let e = store.engine else { return }
        let q = text
        if q.trimmingCharacters(in: .whitespaces).count < 2 {
            results = []
            return
        }
        let center = model.camera.center
        let item = DispatchWorkItem {
            let found = e.search.search(q, near: center, limit: 40)
            DispatchQueue.main.async {
                if q == self.text { self.results = found }
            }
        }
        work = item
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.2, execute: item)
    }
}
