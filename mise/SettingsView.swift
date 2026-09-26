import SwiftUI

/// Kept as its own view (rather than folded into PlaceholderView) because
/// later issues add real sections here (theming, Face ID lock, backup...).
struct SettingsView: View {
    var body: some View {
        Form {
            Text("No settings yet")
        }
        .navigationTitle("Settings")
    }
}
