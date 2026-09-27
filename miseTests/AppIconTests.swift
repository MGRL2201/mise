import Testing
import Foundation
#if os(iOS)
import UIKit
#endif
@testable import mise

@MainActor
struct AppIconTests {
    @Test func optionsListLatteFirst() {
        #expect(AppIconOption.all.count == 13)
        #expect(AppIconOption.all[0].name == "Latte")
        #expect(AppIconOption.all[0].alternateName == nil)
    }

    #if os(iOS)
    @Test func alternateNamesAreDeclaredInBundle() throws {
        let icons = try #require(Bundle.main.infoDictionary?["CFBundleIcons"] as? [String: Any])
        let alternates = try #require(icons["CFBundleAlternateIcons"] as? [String: Any])
        for name in AppIconOption.all.compactMap(\.alternateName) {
            #expect(alternates[name] != nil, "\(name) missing")
        }
    }

    @Test func previewImagesLoad() {
        for option in AppIconOption.all {
            #expect(UIImage(named: option.preview) != nil, "\(option.preview) missing")
        }
    }
    #endif
}
