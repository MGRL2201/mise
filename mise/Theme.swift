import SwiftUI

/// User palette: one `Variant` per system appearance (SPEC §5 Theming).
struct Palette: Codable, Equatable {
    var light: Variant
    var dark: Variant

    struct Variant: Codable, Equatable {
        var accent, background, surface, text: Color.Resolved
        /// Keyed by `Destination.rawValue`; a missing module falls back to accent.
        var modules: [String: Color.Resolved] = [:]

        subscript(module destination: Destination) -> Color.Resolved {
            get { modules[destination.rawValue] ?? accent }
            set { modules[destination.rawValue] = newValue }
        }
    }

    func variant(for scheme: ColorScheme) -> Variant {
        scheme == .dark ? dark : light
    }

    /// Close to the stock iOS look, so the app "follows the system" out of the box.
    static let `default` = Palette(
        light: Variant(
            accent: .init(0x007AFF), background: .init(0xF2F2F7), surface: .init(0xFFFFFF),
            text: .init(0x000000),
            modules: ["today": .init(0xFF9500), "tasks": .init(0x007AFF), "calendar": .init(0xFF3B30),
                      "money": .init(0x34C759), "notes": .init(0xFFCC00), "news": .init(0xFF2D55)]),
        dark: Variant(
            accent: .init(0x0A84FF), background: .init(0x000000), surface: .init(0x1C1C1E),
            text: .init(0xFFFFFF),
            modules: ["today": .init(0xFF9F0A), "tasks": .init(0x0A84FF), "calendar": .init(0xFF453A),
                      "money": .init(0x30D158), "notes": .init(0xFFD60A), "news": .init(0xFF375F)]))

    static let presets: [(name: String, palette: Palette)] = [
        ("Ocean", Palette(
            light: Variant(accent: .init(0x0077B6), background: .init(0xE6F4F9), surface: .init(0xFFFFFF),
                           text: .init(0x03273A)),
            dark: Variant(accent: .init(0x48CAE4), background: .init(0x03141F), surface: .init(0x0B2A3C),
                          text: .init(0xE0F4FA)))),
        ("Forest", Palette(
            light: Variant(accent: .init(0x2D6A4F), background: .init(0xEEF4EA), surface: .init(0xFFFFFF),
                           text: .init(0x1B2E22)),
            dark: Variant(accent: .init(0x74C69D), background: .init(0x0E1A12), surface: .init(0x1B2E22),
                          text: .init(0xE3F1E6)))),
    ]
}

private extension Color.Resolved {
    init(_ hex: UInt32) {
        self.init(red: Float(hex >> 16 & 0xFF) / 255, green: Float(hex >> 8 & 0xFF) / 255,
                  blue: Float(hex & 0xFF) / 255)
    }
}

/// Owns the palette; persisted as JSON in UserDefaults so edits survive relaunch.
@Observable final class ThemeStore {
    private static let key = "theme.palette"
    @ObservationIgnored private let defaults: UserDefaults

    var palette: Palette {
        didSet { defaults.set(try? JSONEncoder().encode(palette), forKey: Self.key) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        palette = defaults.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode(Palette.self, from: $0) } ?? .default
    }

    func reset() { palette = .default }
}

extension EnvironmentValues {
    /// The variant for the current color scheme, published by `ThemeRoot`.
    @Entry var theme = Palette.default.light
}

/// Applied once at the app root: resolves the variant, sets tint and text color.
struct ThemeRoot: ViewModifier {
    @Environment(ThemeStore.self) private var store
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let variant = store.palette.variant(for: scheme)
        content
            .environment(\.theme, variant)
            .tint(Color(variant.accent))
            .foregroundStyle(Color(variant.text))
    }
}

extension View {
    /// Palette background behind a screen; call on each screen root.
    func themedBackground() -> some View { modifier(ThemedBackground()) }
}

private struct ThemedBackground: ViewModifier {
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .scrollContentBackground(.hidden)
            .background(Color(theme.background))
    }
}

/// Destination label whose icon uses the module's palette color.
struct DestinationLabel: View {
    let destination: Destination
    @Environment(\.theme) private var theme

    var body: some View {
        Label {
            Text(destination.title)
        } icon: {
            Image(systemName: destination.systemImage)
                .foregroundStyle(Color(theme[module: destination]))
        }
    }
}
