import SwiftUI
import MapKit

/// Picks a place for a location reminder by searching Apple Maps.
// ponytail: search only, no "Current Location": that needs NSLocationWhenInUseUsageDescription + a
// CLLocationManager permission flow. MKLocalSearch needs no permission; EventKit does the geofencing.
struct LocationSearchView: View {
    @Binding var location: LocationReminder?
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [MKMapItem] = []
    @State private var errorMessage: String?

    var body: some View {
        List {
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.secondary)
            }
            ForEach(results, id: \.self) { item in
                Button {
                    let coordinate = item.location.coordinate
                    location = LocationReminder(title: item.name ?? query, latitude: coordinate.latitude,
                                                longitude: coordinate.longitude, radius: 100, leaving: location?.leaving ?? false)
                    dismiss()
                } label: {
                    VStack(alignment: .leading) {
                        Text(item.name ?? "")
                        if let address = item.address?.shortAddress {
                            Text(address).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Location")
        .searchable(text: $query, prompt: "Search for a place")
        .onSubmit(of: .search) {
            Task {
                let request = MKLocalSearch.Request()
                request.naturalLanguageQuery = query
                do {
                    results = try await MKLocalSearch(request: request).start().mapItems
                    errorMessage = results.isEmpty ? "No places found." : nil
                } catch {
                    results = []
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}
