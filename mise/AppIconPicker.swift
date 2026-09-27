import SwiftUI

struct AppIconOption {
    let name: String
    let key: String

    var preview: String { "IconPreview-\(key)" }
    var alternateName: String? { key == "Latte" ? nil : "AppIcon-\(key)" }

    static let all: [AppIconOption] = [
        .init(name: "Latte", key: "Latte"),
        .init(name: "Espresso", key: "Espresso"),
        .init(name: "Mocha", key: "Mocha"),
        .init(name: "Caramel", key: "Caramel"),
        .init(name: "Cappuccino", key: "Cappuccino"),
        .init(name: "Cold brew", key: "ColdBrew"),
        .init(name: "Sky", key: "Sky"),
        .init(name: "Aqua", key: "Aqua"),
        .init(name: "Lagoon", key: "Lagoon"),
        .init(name: "Deep sea", key: "DeepSea"),
        .init(name: "Seafoam", key: "Seafoam"),
        .init(name: "Dusk", key: "Dusk"),
        .init(name: "Glass", key: "Glass"),
    ]
}

#if os(iOS)
struct AppIconPicker: View {
    @State private var current = UIApplication.shared.alternateIconName
    @State private var error: String?

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 88))], spacing: 20) {
                ForEach(AppIconOption.all, id: \.key) { option in
                    let isCurrent = option.alternateName == current
                    Button {
                        Task { await select(option) }
                    } label: {
                        VStack {
                            Image(option.preview)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 72, height: 72)
                                .clipShape(.rect(cornerRadius: 16))
                                .overlay(alignment: .bottomTrailing) {
                                    if isCurrent {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.title3)
                                            .foregroundStyle(.white, .tint)
                                            .offset(x: 6, y: 6)
                                    }
                                }
                            Text(option.name).font(.caption)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(option.name)
                    .accessibilityAddTraits(isCurrent ? .isSelected : [])
                }
            }
            .padding()
        }
        .navigationTitle("App icon")
        .themedBackground()
        .alert("Couldn't change icon", isPresented: Binding { error != nil } set: { if !$0 { error = nil } }) {
        } message: {
            Text(error ?? "")
        }
    }

    private func select(_ option: AppIconOption) async {
        guard option.alternateName != current else { return }
        do {
            try await UIApplication.shared.setAlternateIconName(option.alternateName)
            current = UIApplication.shared.alternateIconName
        } catch {
            self.error = error.localizedDescription
        }
    }
}
#endif
