import CoreLocation
import MapKit
import SwiftData
import SwiftUI

enum HuntFilter: String, CaseIterable {
    case all = "ALL UNCAUGHT"
    case newModels = "NEW MODELS"
}

/// HUNT: every bus and tram running near you that isn't in your book yet, live.
/// Two rules on the map: a vehicle on its own is a tag with its line, vehicles that would
/// overlap become one bubble with their count; filled means a model new to you, outlined
/// a model you already have. Colour is always rarity.
struct HuntView: View {
    @Query private var sightings: [Sighting]
    @Environment(Router.self) private var router
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("huntFilter") private var filter: HuntFilter = .all

    private let live = LiveFleetService.shared
    private let location = LocationService.shared
    private let catalog = Fleet.catalog

    @State private var position: MapCameraPosition = .region(Self.warsaw)
    /// Opened on the default 3 km view around you, once there was a fix to open it on.
    @State private var centered = false
    @State private var pins: [WantedPin] = []
    @State private var selectedId: String?
    /// A small bubble you tapped: its vehicles, listed so you can pick one.
    @State private var openGroup: [String]?
    /// What the map is showing: pins cover it, however far you zoom out.
    @State private var mapRegion: MKCoordinateRegion?
    /// The map's rotation, so direction arrows keep pointing the right way on the ground.
    @State private var mapHeading: Double = 0
    private var mapCenter: CLLocationCoordinate2D? { mapRegion?.center }

    private static let warsaw = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 52.2297, longitude: 21.0122),
        span: MKCoordinateSpan(latitudeDelta: 0.06, longitudeDelta: 0.06))

    var body: some View {
        let shown = pins.filter { filter == .all || $0.kind == .newModel }
        let selected = shown.first { $0.id == selectedId }

        ZStack(alignment: .top) {
            map(shown)
                .ignoresSafeArea()

            LinearGradient(colors: [Palette.bg.opacity(0.85), Palette.bg.opacity(0)], startPoint: .top, endPoint: .bottom)
                .frame(height: 150)
                .ignoresSafeArea(edges: .top)
                .allowsHitTesting(false)

            VStack(spacing: 12) {
                header
                filterBar
                Spacer()
                bottomCard(shown: shown, selected: selected)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
            }
        }
        .background(Palette.bg.ignoresSafeArea())
        .foregroundStyle(Palette.ink)
        .onAppear {
            live.start("hunt")
            centerOnceOnYou()
        }
        .onDisappear { live.stop("hunt") }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { live.start("hunt") }
            if phase == .background { live.stop("hunt") }
        }
        .onChange(of: live.snapshot?.fetched, initial: true) { recompute(animated: true) }
        .onChange(of: location.latest) {
            centerOnceOnYou()
            live.locationMoved()
            recompute(animated: false)
        }
        .onChange(of: sightings.count) { recompute(animated: false) }
    }

    // MARK: - Map

    private func map(_ shown: [WantedPin]) -> some View {
        // Picked on the map itself: make sure the card that opens doesn't cover it.
        let selection = Binding<String?>(get: { selectedId }, set: { id in
            selectedId = id
            if let pin = shown.first(where: { $0.id == id }) { keepClearOfCard(pin) }
        })
        return Map(position: $position, interactionModes: .all, selection: selection) {
            // The selected vehicle's recent path, fading out behind it.
            if let pin = shown.first(where: { $0.id == selectedId }) {
                let trail = live.trails.trail(pin.id).map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
                // MapKit won't draw a gradient along a line: fade it one segment at a time.
                let path = trail + [pin.coordinate]
                ForEach(0..<max(0, path.count - 1), id: \.self) { i in
                    MapPolyline(coordinates: [path[i], path[i + 1]])
                        .stroke(pin.accent.opacity(0.25 + 0.75 * Double(i + 1) / Double(path.count - 1)),
                                style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                }
            }
            UserAnnotation()
            // Rarest on top: SwiftUI draws later annotations above earlier ones.
            ForEach(groups(shown).reversed()) { g in
                if g.pins.count == 1 {
                    Annotation(g.lead.model.name, coordinate: g.lead.coordinate, anchor: .bottom) {
                        WantedPinView(pin: g.lead, selected: g.id == selectedId,
                                      heading: live.trails.heading(g.lead.id).map { $0 - mapHeading })
                    }
                    .tag(g.id)
                    .annotationTitles(.hidden)
                } else {
                    Annotation("\(g.pins.count) vehicles", coordinate: CLLocationCoordinate2D(latitude: g.latitude, longitude: g.longitude),
                               anchor: .center) {
                        GroupBubble(group: g)
                    }
                    .tag(g.id)
                    .annotationTitles(.hidden)
                }
            }
        }
        .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll, showsTraffic: false))
        .mapControls {}
        .environment(\.colorScheme, .dark)
        .onMapCameraChange(frequency: .continuous) { ctx in mapHeading = ctx.camera.heading }
        .onMapCameraChange(frequency: .onEnd) { ctx in
            mapRegion = ctx.region
            recompute(animated: false)
        }
        .onChange(of: selectedId) { _, id in
            guard let id else { return }
            Haptics.shared.tick()
            guard id.hasPrefix("group:"), let g = groups(shown).first(where: { $0.id == id }) else {
                // Picked from the open list: keep it, so closing the card goes back to it.
                if openGroup?.contains(id) != true { openGroup = nil }
                return
            }
            selectedId = nil
            // A few vehicles, or already zoomed in (a pętla, a stop): list them to pick from.
            // A big crowd further out: zoom in until it comes apart.
            if g.pins.count <= 6 || (mapRegion?.span.longitudeDelta ?? 1) < 0.02 {
                withAnimation(.snappy) { openGroup = g.pins.map(\.id) }
            } else {
                zoom(into: g)
            }
        }
    }

    /// Vehicles merged only where their tags would really sit on top of each other (a
    /// square is roughly a tenth of the screen wide, a bit under a tag). The selected one
    /// stands alone.
    private func groups(_ shown: [WantedPin]) -> [PinGroup] {
        let rest = shown.filter { $0.id != selectedId }
        let lone = shown.filter { $0.id == selectedId }.map { PinGroup(lead: $0, pins: [$0]) }
        guard let region = mapRegion else { return lone + rest.map { PinGroup(lead: $0, pins: [$0]) } }
        // Squares snap to powers of two, so a nudge of the map (or a tap) doesn't redraw
        // every group; they only change when you really zoom.
        let cell = pow(2, (log2(region.span.longitudeDelta / 10)).rounded())
        // A fixed reference latitude too, for the same reason.
        return Wanted.group(rest, cellLon: cell, latitude: 52.23) + lone
    }

    /// The card opens over the bottom of the map; a vehicle picked down there glides up into
    /// the open part instead of hiding behind the card it just opened.
    private func keepClearOfCard(_ pin: WantedPin) {
        // North-up only: rotated, latitude no longer runs up the screen.
        guard let region = mapRegion, mapHeading < 1 || mapHeading > 359 else { return }
        let span = region.span.latitudeDelta
        // The card's top edge sits a little below the middle of the screen.
        guard pin.vehicle.latitude < region.center.latitude - span * 0.05 else { return }
        let center = CLLocationCoordinate2D(latitude: pin.vehicle.latitude - span * 0.15,
                                            longitude: region.center.longitude)
        withAnimation(.easeInOut(duration: 0.5)) { position = .region(MKCoordinateRegion(center: center, span: region.span)) }
    }

    private func zoom(into g: PinGroup) {
        let lats = g.pins.map(\.vehicle.latitude), lons = g.pins.map(\.vehicle.longitude)
        let current = mapRegion?.span ?? Self.warsaw.span
        // Fit the group with room to spare, and always at least a few times closer.
        let span = MKCoordinateSpan(
            latitudeDelta: min(current.latitudeDelta / 3, max((lats.max()! - lats.min()!) * 2.5, 0.002)),
            longitudeDelta: min(current.longitudeDelta / 3, max((lons.max()! - lons.min()!) * 2.5, 0.002)))
        let center = CLLocationCoordinate2D(latitude: (lats.max()! + lats.min()!) / 2, longitude: (lons.max()! + lons.min()!) / 2)
        withAnimation(.easeInOut(duration: 0.6)) { position = .region(MKCoordinateRegion(center: center, span: span)) }
    }

    // MARK: - Chrome

    private var header: some View {
        HStack(spacing: 8) {
            Mono("HUNT", size: 12, spacing: 0.16, color: .white.opacity(0.85))
            Spacer()
            HStack(spacing: 6) {
                Circle().fill(statusColor).frame(width: 6, height: 6)
                    .shadow(color: statusColor, radius: live.status == .live ? 4 : 0)
                Mono(statusText, size: 10.5, weight: 600, spacing: 0.1, color: .white.opacity(0.85))
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .glass(Capsule())
        }
        .padding(.top, 6)
        .padding(.horizontal, 20)
    }

    private var filterBar: some View {
        HStack(spacing: 7) {
            ForEach(HuntFilter.allCases, id: \.self) { f in
                let on = f == filter
                Button {
                    guard !on else { return }
                    Haptics.shared.tick()
                    withAnimation(.snappy) {
                        filter = f
                        selectedId = nil
                        openGroup = nil
                    }
                } label: {
                    Mono(f.rawValue, size: 11, weight: 600, spacing: 0.1, color: on ? Palette.bg : .white.opacity(0.75))
                        .padding(.vertical, 7)
                        .padding(.horizontal, 12)
                        .background(on ? Palette.ink : .clear, in: Capsule())
                        .glass(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
            Spacer()
            if offDefaultView {
                Button(action: resetView) {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 10.5, weight: .bold))
                        Mono("3 KM", size: 11, weight: 600, spacing: 0.1, color: Palette.radar)
                    }
                    .foregroundStyle(Palette.radar)
                    .padding(.vertical, 7)
                    .padding(.horizontal, 11)
                    .glass(Capsule())
                }
                .buttonStyle(.plain)
                .transition(.scale(scale: 0.8).combined(with: .opacity))
                .accessibilityLabel("Back to 3 kilometres around you")
            }
        }
        .padding(.horizontal, 20)
        .animation(.snappy, value: offDefaultView)
    }

    /// The default view: you in the middle, the 3 km the list covers around you.
    private func defaultRegion() -> MKCoordinateRegion? {
        guard let here = location.recent(maxAge: 300)?.coordinate ?? mapCenter else { return nil }
        return MKCoordinateRegion(center: here, latitudinalMeters: Wanted.radius * 2, longitudinalMeters: Wanted.radius * 2)
    }

    /// Zoomed in or out from the default, or panned (or walked) away from its centre.
    private var offDefaultView: Bool {
        guard let region = mapRegion, let here = location.recent(maxAge: 300)?.coordinate else { return false }
        // Width, not height: on a tall phone screen the region fits the 6 km across.
        let across = Geo.km((region.center.latitude, region.center.longitude - region.span.longitudeDelta / 2),
                            (region.center.latitude, region.center.longitude + region.span.longitudeDelta / 2)) * 1000
        let zoom = across / (Wanted.radius * 2)
        if zoom < 0.6 || zoom > 1.6 { return true }
        return Geo.km((here.latitude, here.longitude), (region.center.latitude, region.center.longitude)) > 0.5
    }

    private func centerOnceOnYou() {
        guard !centered, let region = defaultRegion(), location.recent(maxAge: 300) != nil else { return }
        centered = true
        position = .region(region)
    }

    private func resetView() {
        guard let region = defaultRegion() else { return }
        Haptics.shared.tick()
        withAnimation(.easeInOut(duration: 0.7)) { position = .region(region) }
    }

    @ViewBuilder
    private func bottomCard(shown: [WantedPin], selected: WantedPin?) -> some View {
        Group {
            if let selected {
                PinCard(pin: selected, owned: sightings.stats.ownedCount(modelId: selected.model.id),
                        showDistance: hasFix, motion: motion(of: selected)) {
                    router.openModel(selected.model.id)
                } onClose: {
                    withAnimation(.snappy) { selectedId = nil }
                }
                .id(selected.id)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if let ids = openGroup {
                let members = ids.compactMap { id in shown.first { $0.id == id } }
                groupList(members)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if let empty = emptyState(shown: shown) {
                empty
            } else {
                wantedList(nearYou(shown))
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: selectedId)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: openGroup)
    }

    /// The vehicles in a tapped bubble; picking one opens its card (and ✕ on that card
    /// comes back here).
    private func groupList(_ members: [WantedPin]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                SectionLabel(text: "\(members.count) HERE")
                Spacer()
                Button {
                    withAnimation(.snappy) { openGroup = nil }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Palette.sub)
                        .frame(width: 28, height: 28)
                        .background(Palette.chip, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
            }
            pinList(members, visibleRows: 4.5) { pin in
                withAnimation(.snappy) { selectedId = pin.id }
                keepClearOfCard(pin)
            }
        }
        .padding(14)
        .huntCard()
    }

    private static let rowHeight: CGFloat = 50

    /// Rows that fit their content; past `visibleRows` the list scrolls, with the half row
    /// peeking out to say so.
    private func pinList(_ pins: [WantedPin], visibleRows: CGFloat, action: @escaping (WantedPin) -> Void) -> some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(pins) { pin in pinRow(pin) { action(pin) } }
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollIndicators(.hidden)
        .frame(height: min(CGFloat(pins.count), visibleRows) * Self.rowHeight)
    }

    private func pinRow(_ pin: WantedPin, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(pin.kind == .newModel ? pin.accent : .clear)
                    .strokeBorder(pin.accent, lineWidth: 1.5)
                    .frame(width: 5, height: 30)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Mono(pin.model.tier.rawValue, size: 9.5, weight: 700, spacing: 0.12, color: pin.accent)
                            .fixedSize()
                        Text(pin.model.name)
                            .font(TaborFont.grotesk(14.5, 600))
                            .lineLimit(1)
                    }
                    Mono(pin.subtitle(showDistance: hasFix), size: 10.5, color: Palette.sub)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.faint)
            }
            .frame(height: Self.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The list sticks to what's actually near you, even with all of Warsaw on the map.
    private func nearYou(_ shown: [WantedPin]) -> [WantedPin] {
        hasFix ? shown.filter { $0.distance <= Wanted.radius } : shown
    }

    private func wantedList(_ near: [WantedPin]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                SectionLabel(text: filter == .newModels ? "NEW MODELS NEARBY" : "UNCAUGHT NEARBY")
                Spacer()
                Mono(hasFix ? "\(near.count) WITHIN 3 KM" : "AROUND THE MAP CENTRE", size: 9.5, color: Palette.faint)
            }
            if filter == .all {
                HStack(spacing: 12) {
                    LegendSwatch(filled: true, text: "NEW MODEL")
                    LegendSwatch(filled: false, text: "MODEL YOU HAVE")
                    Spacer()
                }
                .padding(.top, 2)
            }
            Spacer().frame(height: 6)
            pinList(near, visibleRows: 3.5) { select($0) }
        }
        .padding(14)
        .huntCard()
    }

    /// Why there's nothing to hunt, when there isn't.
    private func emptyState(shown: [WantedPin]) -> MessageCard? {
        switch live.status {
        case .noKey:
            return MessageCard(icon: "key.fill", title: "Live positions are off",
                               text: "HUNT needs a free api.um.warszawa.pl key. Add yours in Me › Settings › Live data.")
        case .error(let why) where live.fresh(maxAge: 120) == nil:
            return MessageCard(icon: "antenna.radiowaves.left.and.right.slash", title: "The city's feed is down",
                               text: "\(why) Trying again every 15 seconds.")
        case .idle, .loading:
            if live.snapshot == nil {
                return MessageCard(icon: "dot.radiowaves.left.and.right", title: "Finding what's running…", text: nil)
            }
        default: break
        }
        if location.isDenied, mapCenter == nil {
            return MessageCard(icon: "location.slash.fill", title: "Location is off",
                               text: "Turn it on to see what's running around you — or pan the map to look anywhere.",
                               action: ("Open Settings", {
                                   if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                               }))
        }
        if nearYou(shown).isEmpty {
            return MessageCard(icon: "checkmark.seal.fill",
                               title: filter == .newModels ? "No new models within 3 km" : "Nothing uncaught within 3 km",
                               text: filter == .newModels ? "Everything running around here is a model you have. Switch to ALL UNCAUGHT for more of them."
                                   : "Every vehicle running around here is already in your book.")
        }
        return nil
    }

    // MARK: - State

    private var hasFix: Bool { location.recent(maxAge: 300) != nil }

    private var statusColor: Color {
        switch live.status {
        case .live: Palette.green
        case .loading, .idle: Palette.yellow
        case .noKey, .error: Palette.red
        }
    }

    private var statusText: String {
        switch live.status {
        case .noKey: "NO KEY"
        case .idle, .loading: "CONNECTING"
        case .error: live.fresh(maxAge: 120) == nil ? "OFFLINE" : "RETRYING"
        case .live: "LIVE"
        }
    }

    private func recompute(animated: Bool) {
        let user = location.recent(maxAge: 300)?.coordinate
        guard let snapshot = live.snapshot, let center = mapCenter ?? user else { return }
        // Half the visible diagonal, and never less than the 3 km the list needs.
        let visible = mapRegion.map { r in
            Geo.km((r.center.latitude - r.span.latitudeDelta / 2, r.center.longitude - r.span.longitudeDelta / 2),
                   (r.center.latitude + r.span.latitudeDelta / 2, r.center.longitude + r.span.longitudeDelta / 2)) * 500
        } ?? 0
        var next = Wanted.pins(snapshot: snapshot, catalog: catalog, caught: sightings.stats,
                               lat: center.latitude, lon: center.longitude, within: max(Wanted.radius, visible),
                               from: user.map { ($0.latitude, $0.longitude) })
        // Panned away from you: make sure what's around you still feeds the list.
        if let user, Geo.km((user.latitude, user.longitude), (center.latitude, center.longitude)) * 1000 > visible {
            let ids = Set(next.map(\.id))
            next += Wanted.pins(snapshot: snapshot, catalog: catalog, caught: sightings.stats,
                                lat: user.latitude, lon: user.longitude, from: (user.latitude, user.longitude))
                .filter { !ids.contains($0.id) }
        }
        // Vehicles glide to where they are now rather than jumping.
        if animated {
            withAnimation(.easeInOut(duration: 1.2)) { pins = next }
        } else {
            pins = next
        }
        if let selectedId, !next.contains(where: { $0.id == selectedId }) { self.selectedId = nil }
        // The selected vehicle drove off the edge: follow it, keeping the zoom.
        if let selectedId, let pin = next.first(where: { $0.id == selectedId }), let region = mapRegion,
           abs(pin.vehicle.latitude - region.center.latitude) > region.span.latitudeDelta * 0.3
            || abs(pin.vehicle.longitude - region.center.longitude) > region.span.longitudeDelta * 0.4 {
            withAnimation(.easeInOut(duration: 1.2)) {
                position = .region(MKCoordinateRegion(center: pin.coordinate, span: region.span))
            }
        }
    }

    private func motion(of pin: WantedPin) -> Motion? {
        guard let here = location.recent(maxAge: 300)?.coordinate else { return nil }
        return live.trails.motion(pin.id, lat: here.latitude, lon: here.longitude)
    }

    /// From the list: select the pin and fly to it.
    private func select(_ pin: WantedPin) {
        withAnimation(.snappy) { selectedId = pin.id }
        withAnimation(.easeInOut(duration: 0.6)) {
            position = .camera(MapCamera(centerCoordinate: pin.coordinate, distance: 1800))
        }
    }
}

// MARK: - Pieces

private extension WantedPin {
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: vehicle.latitude, longitude: vehicle.longitude) }

    var accent: Color { model.tier.mapColor }

    func subtitle(showDistance: Bool, showKind: Bool = true) -> String {
        [showKind ? vehicle.kind.rawValue : nil, "#\(vehicle.number)", vehicle.line.isEmpty ? nil : "LINE \(vehicle.line)",
         showDistance ? HuntDistance.text(distance) : nil]
            .compactMap { $0 }.joined(separator: " · ")
    }
}

enum HuntDistance {
    /// "400 M", "1.2 KM".
    static func text(_ metres: Double) -> String {
        metres < 1000 ? "\(Int((metres / 50).rounded()) * 50) M" : String(format: "%.1f KM", metres / 1000)
    }
}

/// A missing model: a tier-coloured tag with the line it's running on.
/// Up close: a tag with the line. Filled for a model new to you, outlined for one you have.
private struct WantedPinView: View {
    let pin: WantedPin
    let selected: Bool
    /// Screen direction of travel (0 = up), once the vehicle has been seen moving.
    var heading: Double? = nil
    private var filled: Bool { pin.kind == .newModel }

    /// Screen angle (0 = up, clockwise) to the nearest of eight arrows.
    static func arrow(_ degrees: Double) -> String {
        let names = ["arrow.up", "arrow.up.right", "arrow.right", "arrow.down.right",
                     "arrow.down", "arrow.down.left", "arrow.left", "arrow.up.left"]
        let d = (degrees.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        return names[Int((d / 45).rounded()) % 8]
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Image(systemName: pin.vehicle.kind == .tram ? "tram.fill" : "bus.fill")
                    .font(.system(size: 9.5, weight: .bold))
                Text(pin.vehicle.line.isEmpty ? String(pin.vehicle.number) : pin.vehicle.line)
                    .font(TaborFont.mono(12.5, 700))
                    .lineLimit(1)
                    .fixedSize()
                if let heading {
                    // One of eight arrows rather than a rotated one: MapKit doesn't re-apply
                    // transforms inside an annotation, so a rotation sticks at its first angle.
                    Image(systemName: Self.arrow(heading))
                        .font(.system(size: 10, weight: .heavy))
                        .accessibilityHidden(true)
                }
            }
            .foregroundStyle(filled ? (pin.model.tier == .legendary ? Palette.ink : Palette.bg) : pin.accent)
            .padding(.vertical, 4)
            .padding(.horizontal, 7)
            .background(filled ? pin.accent : Palette.bg.opacity(0.88), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(selected ? .white : (filled ? Palette.bg.opacity(0.6) : pin.accent), lineWidth: selected ? 2 : 1.5))
            Triangle()
                .fill(selected ? .white : pin.accent)
                .frame(width: 9, height: 5)
        }
        .shadow(color: pin.accent.opacity(filled ? 0.55 : 0.25), radius: selected ? 10 : 6)
        .scaleEffect(selected ? 1.18 : 1, anchor: .bottom)
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: selected)
        .accessibilityLabel("\(pin.model.tier.rawValue.lowercased()) \(pin.model.name), line \(pin.vehicle.line)")
        .accessibilityAddTraits(.isButton)
    }
}

/// Vehicles too close to tell apart at this zoom: their count, in the rarest one's colour,
/// filled if any of them is a model new to you.
private struct GroupBubble: View {
    let group: PinGroup

    var body: some View {
        let filled = group.hasNewModel
        let accent = group.lead.accent
        let size = min(38, 22 + sqrt(CGFloat(group.pins.count)) * 2.5)
        Text("\(group.pins.count)")
            .font(TaborFont.mono(group.pins.count > 99 ? 11 : 12.5, 700))
            .foregroundStyle(filled ? (group.lead.model.tier == .legendary ? Palette.ink : Palette.bg) : accent)
            .frame(width: size, height: size)
            .background(filled ? accent : Palette.bg.opacity(0.88), in: Circle())
            .overlay(Circle().strokeBorder(filled ? Palette.bg.opacity(0.6) : accent, lineWidth: 1.5))
            .shadow(color: accent.opacity(filled ? 0.55 : 0.25), radius: 6)
            .accessibilityLabel("\(group.pins.count) vehicles here, zoom in")
            .accessibilityAddTraits(.isButton)
    }
}

private struct LegendSwatch: View {
    let filled: Bool
    let text: String

    var body: some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 3)
                .fill(filled ? Palette.routeInk : .clear)
                .strokeBorder(Palette.routeInk, lineWidth: 1.5)
                .frame(width: 12, height: 9)
            Mono(text, size: 9.5, color: Palette.faint)
        }
    }
}

private struct Triangle: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

private struct PinCard: View {
    let pin: WantedPin
    let owned: Int
    let showDistance: Bool
    /// Which way it's going relative to you; nil until it's been seen moving.
    let motion: Motion?
    let onOpen: () -> Void
    let onClose: () -> Void

    private var motionLine: (text: String, color: Color) {
        switch motion {
        case .approaching: ("COMING YOUR WAY", Palette.green)
        case .passing: ("GOING PAST", Palette.yellow)
        case .leaving: ("MOVING AWAY", Palette.sub)
        case .stopped: ("STOPPED", Palette.yellow)
        case nil: ("WATCHING WHICH WAY IT GOES…", Palette.faint)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                KindTag(kind: pin.vehicle.kind)
                TierPill(tier: pin.model.tier, fleet: pin.model.fleet)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Palette.sub)
                        .frame(width: 28, height: 28)
                        .background(Palette.chip, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
            }
            Text(pin.model.name)
                .font(TaborFont.grotesk(24, 700))
                .em(-0.03, size: 24)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Mono(pin.subtitle(showDistance: showDistance, showKind: false), size: 11, weight: 600, color: Palette.routeInk)
            if showDistance {
                HStack(spacing: 6) {
                    Circle().fill(motionLine.color).frame(width: 6, height: 6)
                    Mono(motionLine.text, size: 11, weight: 600, color: motionLine.color)
                        .contentTransition(.opacity)
                }
                .animation(.easeInOut(duration: 0.3), value: motionLine.text)
            }
            Text(pin.kind == .newModel ? "Not in your book yet — catching it opens a new page."
                    : "You have \(owned) of \(pin.model.fleet). This one isn't among them.")
                .font(TaborFont.grotesk(13))
                .foregroundStyle(pin.kind == .newModel ? Palette.greenInk : Palette.sub)
            Button(action: onOpen) {
                Mono("OPEN IN BOOK", size: 12, weight: 700, spacing: 0.12, color: Palette.bg)
                    .frame(maxWidth: .infinity)
                    .padding(13)
                    .background(pin.accent, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            }
            .buttonStyle(StickerPressStyle())
            .padding(.top, 2)
        }
        .padding(16)
        .huntCard(radius: 20, stroke: pin.accent.opacity(0.35))
    }
}

private struct MessageCard: View {
    let icon: String
    let title: String
    let text: String?
    var action: (String, () -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Palette.sub)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(TaborFont.grotesk(15, 600))
                if let text {
                    Text(text).font(TaborFont.grotesk(13)).foregroundStyle(Palette.sub)
                }
                if let action {
                    Button(action.0, action: action.1)
                        .font(TaborFont.grotesk(14, 600))
                        .tint(Palette.yellow)
                        .padding(.top, 4)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(15)
        .huntCard()
    }
}

private extension View {
    /// A card floating over the map. Solid: pins and street names showing through the
    /// text made it hard to read.
    func huntCard(radius: CGFloat = 18, stroke: Color = Palette.hairline) -> some View {
        background(Palette.card, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(stroke))
            .shadow(color: .black.opacity(0.45), radius: 16, y: 8)
    }
}
