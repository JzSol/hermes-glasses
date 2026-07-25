//
// NavigationMapView.swift
//
// The route, on the phone. Navigation has always run on the lens; this is
// screen 4f - the same route drawn with MapKit, under the same dark HUD
// banner the glasses show, so a passenger (or a tester without glasses on)
// can see what Hermes is saying.
//
// Two things it adds beyond mirroring the lens:
//   * Search. Speaking a destination is fine when you know the name; when
//     you don't, or when the name is ambiguous, picking from a list is
//     better - and you can see which one you chose before setting off.
//   * Heading. The glasses have no compass, so the phone's is the only one
//     available: it orients the map and drives the direction cue.
//

import MapKit
import SwiftUI

struct NavigationMapView: View {
    let hermesVM: HermesSessionViewModel

    @State private var camera: MapCameraPosition = .userLocation(
        followsHeading: true, fallback: .automatic
    )
    @State private var search = PlaceSearch()
    @State private var mode: TransportMode = .walking
    @State private var resolving = false
    @State private var resolveFailed: String?
    @FocusState private var searchFocused: Bool
    @Environment(\.dismiss) private var dismiss

    private var route: NavigationController.RouteSnapshot? {
        hermesVM.activeRoute
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            searchBar
            mapArea
            footer
        }
        .background(HermesTheme.canvas.ignoresSafeArea())
        .tint(HermesTheme.accent)
        .onChange(of: hermesVM.activeRoute?.mode) { _, _ in syncModeFromRoute() }
        .onAppear(perform: syncModeFromRoute)
        .alert(
            "Couldn't find that place",
            isPresented: Binding(
                get: { resolveFailed != nil },
                set: { if !$0 { resolveFailed = nil } }
            )
        ) {
            Button("OK", role: .cancel) { resolveFailed = nil }
        } message: {
            Text("\(resolveFailed ?? "That place") couldn't be resolved to a location. Try a nearby landmark instead.")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 9) {
            HermesLockup(height: 16)
            Spacer(minLength: 4)
            HermesStatusPill(
                text: pillText,
                dot: route == nil ? nil : HermesTheme.online,
                tinted: route != nil || hermesVM.routeIsBuilding
            )
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    /// Reflects the running route, so the control never lies about the mode.
    private func syncModeFromRoute() {
        if let route, route.mode != mode { mode = route.mode }
    }

    private var pillText: String {
        if route != nil { return "On lens" }
        return hermesVM.routeIsBuilding ? "Routing…" : "No route"
    }

    // MARK: - Search

    private var searchBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.secondary)

                TextField("Search for a place", text: $search.query)
                    .font(.system(size: 16))
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .focused($searchFocused)

                if !search.query.isEmpty {
                    Button {
                        search.clear()
                        searchFocused = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }

                // Walking vs driving changes the route, so it belongs beside
                // the search, not buried in Settings.
                Picker("Mode", selection: $mode) {
                    Image(systemName: "figure.walk").tag(TransportMode.walking)
                    Image(systemName: "car.fill").tag(TransportMode.driving)
                }
                .pickerStyle(.segmented)
                .frame(width: 96)
                .onChange(of: mode) { _, newMode in
                    // Changing it mid-route re-routes rather than only
                    // affecting the next search.
                    if route != nil { hermesVM.setTransportMode(newMode) }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                HermesTheme.card,
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )

            if !search.results.isEmpty {
                resultsList
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    private var resultsList: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(Array(search.results.enumerated()), id: \.offset) { index, result in
                    if index > 0 { HermesDivider() }
                    Button {
                        start(result)
                    } label: {
                        HStack(spacing: 12) {
                            HermesIconTile(systemName: "mappin", size: 30)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(result.title)
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                if !result.subtitle.isEmpty {
                                    Text(result.subtitle)
                                        .font(.system(size: 12))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer(minLength: 8)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxHeight: 240)
        .scrollBounceBehavior(.basedOnSize)
        .background(
            HermesTheme.card,
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
    }

    private func start(_ completion: MKLocalSearchCompletion) {
        resolving = true
        // Dismiss immediately: the tap is the commitment. Waiting for the
        // resolve left the list covering the map - and the header - while
        // the route was already being drawn underneath it.
        search.clear()
        searchFocused = false
        Task {
            defer { resolving = false }
            guard let place = await search.resolve(completion) else {
                resolveFailed = completion.title
                return
            }
            hermesVM.startNavigation(to: place, mode: mode)
        }
    }

    // MARK: - Map + HUD banner

    private var mapArea: some View {
        Map(position: $camera) {
            UserAnnotation()

            if let route {
                if route.polyline.count > 1 {
                    MapPolyline(coordinates: route.polyline.map(Self.coordinate))
                        .stroke(
                            HermesTheme.accent,
                            style: StrokeStyle(
                                lineWidth: 7, lineCap: .round, lineJoin: .round
                            )
                        )
                }
                if let destination = route.destinationCoord {
                    Marker(route.destination, systemImage: "mappin",
                           coordinate: Self.coordinate(destination))
                        .tint(HermesTheme.accent)
                }
            }
        }
        // Flat, POI-free, with a thin cream wash: the route and the user
        // are the only things that should read at a glance while walking.
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
        .mapControls {
            MapUserLocationButton()
            MapCompass()
        }
        // Bias suggestions to what's on screen, so "Blue Bottle" means the
        // one near you rather than one on another continent.
        .onMapCameraChange(frequency: .onEnd) { context in
            search.focus(on: context.region.center)
        }
        .overlay {
            HermesTheme.canvas.opacity(0.14).allowsHitTesting(false)
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(alignment: .top) {
            banner
                .padding(12)
        }
        .padding(.horizontal, 16)
    }

    /// Mirrors the lens banner: same wording, same order, so the phone and
    /// the glasses never disagree about the next step.
    private var banner: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(HermesTheme.accent.opacity(0.25))
                .frame(width: 36, height: 36)
                .overlay {
                    Image(systemName: bannerSymbol)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(HermesTheme.accentLight)
                }

            VStack(alignment: .leading, spacing: 2) {
                Text(bannerTitle)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(HermesTheme.cream)
                    .lineLimit(1)
                Text(detailLine)
                    .font(.system(size: 12))
                    .foregroundStyle(HermesTheme.cream.opacity(0.6))
                    .lineLimit(2)
            }

            Spacer(minLength: 4)

            if route != nil {
                Text("HUD")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(HermesTheme.cream.opacity(0.45))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            HermesTheme.ink.opacity(0.92),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
    }

    /// The arrow points where the destination actually is relative to the
    /// way the phone is facing - the one thing a map can't tell you while
    /// you stand still deciding which way to set off.
    private var bannerSymbol: String {
        guard let route else {
            return hermesVM.routeIsBuilding ? "arrow.triangle.turn.up.right.diamond" : "location.slash"
        }
        guard let relative = route.relativeBearing else { return "location.north.fill" }
        return Bearing.direction(relative: relative).systemImage
    }

    private var bannerTitle: String {
        if let route { return "Head to \(route.destination)" }
        return hermesVM.routeIsBuilding ? "Finding a route…" : "No route running"
    }

    private var detailLine: String {
        guard let route else {
            if hermesVM.routeIsBuilding {
                return "Waiting for your first GPS fix."
            }
            return "Search above, or say \u{201C}take me to…\u{201D} in a session."
        }
        var parts = ["\(route.eta) · \(route.remaining)"]
        if let relative = route.relativeBearing {
            parts.append(Bearing.direction(relative: relative).label)
        }
        parts.append(route.step)
        return parts.joined(separator: " · ")
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            Button {
                dismiss()
            } label: {
                Text("Ask a question")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(HermesTheme.ink)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(HermesTheme.card, in: Capsule())
                    .shadow(color: .black.opacity(0.06), radius: 3, y: 1)
            }
            .buttonStyle(.plain)

            if route != nil {
                HermesDestructiveButton(title: "End route") {
                    hermesVM.endNavigation()
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 16)
    }

    private static func coordinate(_ point: MapCoordinate) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: point.lat, longitude: point.lon)
    }
}
