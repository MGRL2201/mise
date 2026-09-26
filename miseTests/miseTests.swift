import Testing
@testable import mise

@MainActor
struct miseTests {
    @Test func appTitle() {
        #expect(ContentView.title == "mise")
    }
}
