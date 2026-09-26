import Testing
import Foundation
import SwiftUI
@testable import mise

@MainActor
struct ThemeTests {
    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: UUID().uuidString)!
    }

    /// Color.Resolved decodes with ~1e-7 float drift (sRGB <-> linear), so
    /// compare at 8-bit precision via its "#RRGGBBAA" description.
    private func hexes(_ palette: Palette) -> [String] {
        [palette.light, palette.dark].flatMap { variant in
            [variant.accent, variant.background, variant.surface, variant.text].map(\.description)
                + variant.modules.sorted { $0.key < $1.key }.map { "\($0.key)\($0.value)" }
        }
    }

    @Test func paletteJSONRoundTrip() throws {
        let palette = Palette.presets[0].palette
        let data = try JSONEncoder().encode(palette)
        #expect(hexes(try JSONDecoder().decode(Palette.self, from: data)) == hexes(palette))
    }

    @Test func storePersistsAndReloads() {
        let defaults = freshDefaults()
        let ocean = Palette.presets[0].palette
        #expect(ocean != .default)

        ThemeStore(defaults: defaults).palette = ocean
        #expect(hexes(ThemeStore(defaults: defaults).palette) == hexes(ocean))
    }

    @Test func resetRestoresDefault() {
        let defaults = freshDefaults()
        let store = ThemeStore(defaults: defaults)
        store.palette = Palette.presets[0].palette
        store.reset()
        #expect(store.palette == .default)
        #expect(hexes(ThemeStore(defaults: defaults).palette) == hexes(.default))
    }
}
