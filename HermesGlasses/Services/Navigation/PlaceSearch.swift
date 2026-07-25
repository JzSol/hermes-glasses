//
// PlaceSearch.swift
//
// As-you-type place lookup for the map screen, so a route can be started by
// tapping instead of only by saying "take me to…". Speaking a destination
// works well when you know the name; searching wins when you don't, or when
// the name is ambiguous and you want to see which one you're picking.
//
// Two stages, as MapKit intends: MKLocalSearchCompleter for suggestions
// (cheap, fires per keystroke) and MKLocalSearch to turn the chosen
// suggestion into a real MKMapItem with coordinates. The route is then
// started from that item, so it goes exactly where the user pointed rather
// than wherever a second geocode of the same string happens to land.
//

import Foundation
import MapKit
import Observation

@MainActor
@Observable
final class PlaceSearch: NSObject {
    /// What the user has typed. Assigning drives the completer.
    var query: String = "" {
        didSet {
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed != completer.queryFragment else { return }
            if trimmed.isEmpty {
                results = []
                completer.cancel()
            } else {
                completer.queryFragment = trimmed
            }
        }
    }

    private(set) var results: [MKLocalSearchCompletion] = []
    private(set) var isSearching = false

    @ObservationIgnored private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        // Addresses and points of interest, not query autocompletions like
        // "coffee near me" that can't be resolved to one place.
        completer.resultTypes = [.address, .pointOfInterest]
    }

    /// Bias results towards where the user actually is. Without this a
    /// search for "Blue Bottle" can return one on another continent.
    func focus(on coordinate: CLLocationCoordinate2D) {
        completer.region = MKCoordinateRegion(
            center: coordinate,
            latitudinalMeters: 30_000, longitudinalMeters: 30_000
        )
    }

    func clear() {
        query = ""
        results = []
    }

    /// Turn a suggestion into a real place. Nil if MapKit can't resolve it.
    func resolve(_ completion: MKLocalSearchCompletion) async -> MKMapItem? {
        isSearching = true
        defer { isSearching = false }
        let request = MKLocalSearch.Request(completion: completion)
        return try? await MKLocalSearch(request: request).start().mapItems.first
    }
}

extension PlaceSearch: MKLocalSearchCompleterDelegate {
    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let found = completer.results
        Task { @MainActor in
            // cancel() does not guarantee no further callbacks, so a batch
            // in flight when the user picks a result would otherwise
            // repopulate the list they just dismissed.
            guard !self.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return }
            self.results = Array(found.prefix(6))
        }
    }

    nonisolated func completer(
        _ completer: MKLocalSearchCompleter, didFailWithError error: Error
    ) {
        // A failed keystroke is not worth surfacing - the next one usually
        // succeeds, and an error banner per character would be unusable.
        Task { @MainActor in self.results = [] }
    }
}
