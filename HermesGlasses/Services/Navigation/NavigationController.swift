//
// NavigationController.swift
//
// Owns one active navigation session. Resolves the destination with MapKit,
// computes a route + turn steps, tracks the user with CoreLocation, and pushes
// a self-recentering Mapbox map to the lens as they move. Best-effort: any
// failure ends cleanly with a spoken notice.
//

import CoreLocation
import Foundation
import MapKit

@MainActor
final class NavigationController: NSObject {
    /// Everything the in-app map screen (design 4f) needs. `onShow` carries
    /// only what fits on the lens; this carries the geometry too, so the
    /// phone can draw the same route with MapKit.
    struct RouteSnapshot: Equatable {
        let destination: String
        let step: String
        let eta: String
        let remaining: String
        let user: MapCoordinate
        let destinationCoord: MapCoordinate?
        let polyline: [MapCoordinate]
        /// Degrees clockwise from true north the phone is facing, or nil
        /// before the first compass reading. The glasses have no compass,
        /// so this is the only heading the app ever gets.
        let mode: TransportMode
        let heading: Double?
        /// Where the destination lies relative to that facing, in
        /// (-180, 180]. Nil until both heading and destination are known.
        let relativeBearing: Double?
    }

    var onShow: ((_ mapURL: String?, _ title: String, _ step: String, _ eta: String, _ mode: TransportMode) -> Void)?
    /// Emitted with every rendered frame, alongside `onShow`.
    var onRoute: ((RouteSnapshot) -> Void)?
    var onSpeak: ((String) -> Void)?
    var onNotice: ((String) -> Void)?
    var onEnd: (() -> Void)?
    var onDebug: ((String) -> Void)?

    private(set) var isActive = false

    private let manager = CLLocationManager()
    private var route: MKRoute?
    private var destinationName = ""
    private var destinationCoord: MapCoordinate?
    /// Kept so the mode can be switched without re-resolving the place.
    private var destinationPlacemark: MKPlacemark?
    private(set) var mode: TransportMode = .walking
    /// Routes started by voice confirm out loud; routes started by tapping
    /// the map do not - you were already looking at the screen.
    private var speaksAloud = true
    private var routeCoords: [MapCoordinate] = []
    private var currentStepIndex = 0

    // Refresh throttle (Global Constraints): >= 15 m moved AND >= 4 s elapsed.
    private var lastSentAt: Date?
    private var lastSentCoord: CLLocation?
    private static let minMoveMeters: CLLocationDistance = 15
    private static let minInterval: TimeInterval = 4
    private static let arrivalMeters: CLLocationDistance = 25
    private static let mapZoom: Double = 16
    /// Repaint on turn only past this many degrees (hand-shake is smaller).
    private static let minTurnDegrees: Double = 20

    // One-time "no Mapbox token" notice latch.
    private var noticedNoToken = false

    // Session generation, guards a stale start() continuation from
    // resurrecting a session that stop()/a newer start() has superseded.
    private var generation = 0
    /// Latest compass reading, degrees clockwise from true north.
    private var currentHeading: Double?
    /// Latest fix, so the map can be repainted on demand (refreshDisplay).
    private var lastLocation: CLLocation?
    /// When true, keep tracking/advancing but don't push frames to the lens
    /// (an answer is temporarily overlaying the map).
    var displaySuppressed = false

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }

    /// Start from a name, resolving it with MapKit. This is the voice path
    /// ("take me to Blue Bottle").
    func start(destination: String, mode: TransportMode) {
        begin(destinationName: destination, placemark: nil, mode: mode, announce: true)
    }

    /// Start from a place the user already picked out of search results.
    /// Skips resolution entirely, so "Blue Bottle" goes to the one they
    /// tapped rather than whichever the geocoder likes best.
    func start(place: MKMapItem, mode: TransportMode, announce: Bool = false) {
        begin(
            destinationName: place.name ?? "your destination",
            placemark: place.placemark,
            mode: mode,
            announce: announce
        )
    }

    /// Swap walking for driving (or back) on the running route. Re-routes to
    /// the same place rather than making the user say it again.
    func setMode(_ newMode: TransportMode) {
        guard isActive, newMode != mode, let placemark = destinationPlacemark else {
            return
        }
        begin(
            destinationName: destinationName, placemark: placemark,
            mode: newMode, announce: speaksAloud
        )
    }

    private func begin(
        destinationName: String, placemark: MKPlacemark?, mode: TransportMode,
        announce: Bool
    ) {
        stop()  // clear any prior session
        generation += 1
        let gen = generation
        self.destinationName = destinationName
        self.mode = mode
        self.speaksAloud = announce
        isActive = true
        manager.requestWhenInUseAuthorization()
        // BEFORE routing, not after: MKMapItem.forCurrentLocation() needs a
        // fix to already exist, and nothing else turns location on when the
        // map screen is used without a voice session.
        manager.startUpdatingLocation()
        if CLLocationManager.headingAvailable() {
            manager.startUpdatingHeading()
        }

        Task { @MainActor in
            do {
                // `??` takes an autoclosure, which can't be async - so the
                // "already resolved" case is spelled out.
                let resolved: MKPlacemark
                if let placemark {
                    resolved = placemark
                } else {
                    resolved = try await resolve(destinationName)
                }
                let route = try await route(to: resolved, mode: mode)
                guard isActive, gen == generation else { return }
                self.route = route
                self.routeCoords = Self.coords(of: route.polyline)
                self.destinationCoord = resolved.location.map {
                    MapCoordinate(lat: $0.coordinate.latitude, lon: $0.coordinate.longitude)
                }
                self.destinationPlacemark = resolved
                self.currentStepIndex = 0
                if announce {
                    onSpeak?("Navigating to \(destinationName), \(NavigationFormat.eta(seconds: route.expectedTravelTime)).")
                }
                // Paint immediately from the fix we already have, rather than
                // waiting for the next location update to arrive.
                if let here = lastLocation ?? manager.location {
                    lastLocation = here
                    renderFrame(for: here)
                }
            } catch {
                guard isActive, gen == generation else { return }
                onDebug?("Navigation failed: \(error.localizedDescription)")
                onNotice?("I couldn't find a route to \(destinationName).")
                end()
            }
        }
    }

    func stop() {
        guard isActive else { return }
        end()
    }

    private func end() {
        manager.stopUpdatingLocation()
        manager.stopUpdatingHeading()
        currentHeading = nil
        isActive = false
        route = nil
        routeCoords = []
        destinationCoord = nil
        destinationPlacemark = nil
        lastSentAt = nil
        lastSentCoord = nil
        lastLocation = nil
        displaySuppressed = false
        noticedNoToken = false
        onEnd?()
    }

    // MARK: - MapKit

    private func resolve(_ query: String) async throws -> MKPlacemark {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        if let here = manager.location {
            request.region = MKCoordinateRegion(
                center: here.coordinate,
                latitudinalMeters: 50_000, longitudinalMeters: 50_000
            )
        }
        let response = try await MKLocalSearch(request: request).start()
        guard let item = response.mapItems.first else {
            throw NavError.notFound
        }
        return MKPlacemark(coordinate: item.placemark.coordinate)
    }

    private func route(to placemark: MKPlacemark, mode: TransportMode) async throws -> MKRoute {
        let request = MKDirections.Request()
        request.source = MKMapItem.forCurrentLocation()
        request.destination = MKMapItem(placemark: placemark)
        request.transportType = (mode == .driving) ? .automobile : .walking
        let response = try await MKDirections(request: request).calculate()
        guard let route = response.routes.first else { throw NavError.noRoute }
        return route
    }

    private static func coords(of polyline: MKPolyline) -> [MapCoordinate] {
        var pts = [CLLocationCoordinate2D](
            repeating: kCLLocationCoordinate2DInvalid, count: polyline.pointCount
        )
        polyline.getCoordinates(&pts, range: NSRange(location: 0, length: polyline.pointCount))
        return pts.map { MapCoordinate(lat: $0.latitude, lon: $0.longitude) }
    }

    // MARK: - Per-update rendering

    private func handle(location: CLLocation) {
        // Recorded before the route guard: fixes arrive while the route is
        // still being computed, and the first frame (and every heading
        // repaint) needs one to exist.
        lastLocation = location
        guard isActive, route != nil else { return }

        // Arrival check (runs even while an answer overlays the map).
        if let dest = destinationCoord {
            let destLoc = CLLocation(latitude: dest.lat, longitude: dest.lon)
            if location.distance(from: destLoc) <= Self.arrivalMeters {
                if speaksAloud { onSpeak?("You've arrived at \(destinationName).") }
                onShow?(nil, destinationName, "Arrived", "0 min", mode)
                end()
                return
            }
        }

        // While an answer overlays the map, keep advancing steps but don't
        // paint - refreshDisplay() repaints when the overlay ends.
        if displaySuppressed {
            advanceStep(near: location)
            return
        }

        // Throttle re-sends against the Bluetooth budget.
        let now = Date()
        if let lastAt = lastSentAt, let lastCoord = lastSentCoord {
            let waited = now.timeIntervalSince(lastAt) >= Self.minInterval
            let moved  = location.distance(from: lastCoord) >= Self.minMoveMeters
            if !(waited && moved) { return }
        }
        lastSentAt = now
        lastSentCoord = location

        advanceStep(near: location)
        renderFrame(for: location)
    }

    /// Re-emit the current navigation frame immediately (bypassing the
    /// throttle) - used to restore the map after an answer overlay ends.
    /// A new compass reading. Heading changes far faster than position, so
    /// it only repaints when the user has actually turned meaningfully -
    /// the lens send throttle would otherwise be saturated by hand-shake.
    private func handle(heading: Double) {
        let previous = currentHeading
        currentHeading = heading
        guard isActive, !displaySuppressed, let location = lastLocation else { return }
        let turned = previous.map {
            abs(Bearing.relative(bearing: heading, heading: $0)) >= Self.minTurnDegrees
        } ?? true
        guard turned else { return }
        renderFrame(for: location)
    }

    func refreshDisplay() {
        guard isActive, let location = lastLocation else { return }
        lastSentAt = Date()
        lastSentCoord = location
        renderFrame(for: location)
    }

    /// Build the map + step text for `location` and push it to the lens.
    private func renderFrame(for location: CLLocation) {
        guard let route else { return }
        let step = route.steps.indices.contains(currentStepIndex)
            ? route.steps[currentStepIndex] : nil
        let instruction = step?.instructions.isEmpty == false
            ? step!.instructions : "Continue"
        let stepDistance = step.map { NavigationFormat.distance(meters: $0.distance) } ?? ""
        var stepText = stepDistance.isEmpty ? instruction : "\(instruction) - \(stepDistance)"

        let user = MapCoordinate(lat: location.coordinate.latitude,
                                 lon: location.coordinate.longitude)
        let mapURL = MapCredentials.loadToken().map { token in
            MapboxStaticMap.url(
                token: token,
                center: user,
                zoom: Self.mapZoom,
                size: 600,
                user: user,
                destination: destinationCoord,
                route: routeCoords,
                // Turn the lens map with the wearer. A north-up map on a
                // heads-up display is a puzzle; a heading-up one is a glance.
                bearing: currentHeading
            )
        }
        if mapURL == nil, !noticedNoToken {
            noticedNoToken = true
            onNotice?("Add a Mapbox token in Settings to see the map.")
        }
        let eta = NavigationFormat.eta(seconds: route.expectedTravelTime)
        onShow?(mapURL, destinationName, stepText, eta, mode)
        let relativeBearing = currentHeading.flatMap { heading -> Double? in
            guard let destinationCoord else { return nil }
            return Bearing.relative(
                bearing: Bearing.initial(from: user, to: destinationCoord),
                heading: heading
            )
        }
        // The compass has to be legible on a text-only lens too - the map
        // image needs a Mapbox token, and rotating it is invisible without
        // one. This line changes as you turn, token or not.
        if let relativeBearing {
            stepText += " · \(destinationName) is \(Bearing.direction(relative: relativeBearing).label)"
        }
        onRoute?(RouteSnapshot(
            destination: destinationName,
            step: stepText,
            eta: eta,
            remaining: NavigationFormat.distance(meters: route.distance),
            user: user,
            destinationCoord: destinationCoord,
            polyline: routeCoords,
            mode: mode,
            heading: currentHeading,
            relativeBearing: relativeBearing
        ))
    }

    /// Advance to the nearest not-yet-passed step by distance to its end point.
    private func advanceStep(near location: CLLocation) {
        guard let route else { return }
        while currentStepIndex < route.steps.count - 1 {
            let step = route.steps[currentStepIndex]
            guard step.polyline.pointCount > 0 else { currentStepIndex += 1; continue }
            let ends = Self.coords(of: step.polyline)
            guard let last = ends.last else { break }
            let endLoc = CLLocation(latitude: last.lat, longitude: last.lon)
            if location.distance(from: endLoc) <= Self.arrivalMeters {
                currentStepIndex += 1
            } else {
                break
            }
        }
    }

    private enum NavError: LocalizedError {
        case notFound, noRoute
        var errorDescription: String? {
            switch self {
            case .notFound: return "Place not found"
            case .noRoute: return "No route found"
            }
        }
    }
}

extension NavigationController: CLLocationManagerDelegate {
    nonisolated func locationManager(
        _ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]
    ) {
        guard let latest = locations.last else { return }
        Task { @MainActor in self.handle(location: latest) }
    }

    nonisolated func locationManager(
        _ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading
    ) {
        // Negative trueHeading means the reading is invalid (uncalibrated
        // compass); magneticHeading is the usable fallback.
        let degrees = newHeading.trueHeading >= 0
            ? newHeading.trueHeading : newHeading.magneticHeading
        guard degrees >= 0 else { return }
        Task { @MainActor in self.handle(heading: degrees) }
    }

    nonisolated func locationManager(
        _ manager: CLLocationManager, didFailWithError error: Error
    ) {
        Task { @MainActor in self.onDebug?("Location error: \(error.localizedDescription)") }
    }
}
