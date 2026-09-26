import Testing
import Foundation
@testable import mise

@MainActor
struct RouteTests {
    @Test func showRouteParsesDestinationHost() {
        let route = Route(url: URL(string: "mise://tasks")!)
        #expect(route == .show(.tasks))
    }

    @Test func newRouteParsesNewPath() {
        let route = Route(url: URL(string: "mise://tasks/new")!)
        #expect(route == .new(.tasks))
    }

    @Test func wrongSchemeReturnsNil() {
        let route = Route(url: URL(string: "https://tasks")!)
        #expect(route == nil)
    }

    @Test func unknownHostReturnsNil() {
        let route = Route(url: URL(string: "mise://bogus")!)
        #expect(route == nil)
    }

    @Test func unknownActionReturnsNil() {
        let route = Route(url: URL(string: "mise://tasks/edit")!)
        #expect(route == nil)
    }
}
