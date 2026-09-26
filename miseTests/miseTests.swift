import Testing
@testable import mise

@MainActor
struct miseTests {
    @Test func appTitle() {
        #expect(ContentView.title == "mise")
    }

    @Test func everyDestinationHasATitleAndSymbol() {
        for destination in Destination.allCases {
            #expect(!destination.title.isEmpty)
            #expect(!destination.systemImage.isEmpty)
        }
    }
}
