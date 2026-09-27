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

    @Test func contrastRatioBlackWhiteIsMax() {
        let black = Color.Resolved(red: 0, green: 0, blue: 0)
        let white = Color.Resolved(red: 1, green: 1, blue: 1)
        #expect(abs(Palette.Variant.contrastRatio(black, white) - 21) < 0.01)
    }

    @Test func contrastRatioSameColorIsOne() {
        let gray = Color.Resolved(red: 0.5, green: 0.5, blue: 0.5)
        #expect(abs(Palette.Variant.contrastRatio(gray, gray) - 1) < 0.001)
    }

    @Test func contrastWarningsFlagLowContrastPairs() {
        var variant = Palette.default.light
        variant.background = variant.text // now identical: ratio 1:1, well below 4.5
        let warnings = variant.contrastWarnings
        #expect(warnings.contains { $0.pair == "Text/Background" })
    }

    @Test func contrastWarningsEmptyForDefaultPalette() {
        // Default light/dark variants are designed with strong contrast.
        #expect(Palette.default.light.contrastWarnings.isEmpty)
        #expect(Palette.default.dark.contrastWarnings.isEmpty)
    }
}
