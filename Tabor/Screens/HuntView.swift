import CoreLocation
import MapKit
import SwiftData
import SwiftUI

/// The raw values are what's saved, so they stay as they were when the chips were renamed.
enum HuntFilter: String, CaseIterable {
    case uncaught = "ALL UNCAUGHT"
    case newModels = "NEW MODELS"
    /// Vehicles already in your book too, for when you just want to see what's running.
    case everything = "EVERYTHING"

    var name: String {
        switch self {
        // Keys of their own: the chips need shorter words than the book and stats (in Polish
        // "NIEZŁAPANE · NOWE MODELE · WSZYSTKIE" doesn't fit next to FILTR). "Missing" (NIE MASZ),
        // not "new": testers took NEW MODELS for models new to the city (#54).
        case .uncaught: String(localized: "hunt.filter.uncaught", defaultValue: "UNCAUGHT")
        case .newModels: String(localized: "hunt.filter.missing", defaultValue: "MISSING")
        case .everything: String(localized: "hunt.filter.all", defaultValue: "ALL")
        }
    }
}

/// HUNT: every bus and tram running near you that isn't in your book yet, live (or, in the
/// ALL view, everything running).
/// Two rules on the map: a vehicle on its own is a tag with its line, vehicles that would
/// overlap become one bubble with their count; filled means a model you're missing, outlined
/// a model you already have. Colour is always rarity.
/// A filter (rarities, models) narrows it to what you're after, anywhere in the city.
struct HuntView: View {
    @Query private var sightings: [Sighting]
    @Environment(Router.self) private var router
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("huntFilter") private var filter: HuntFilter = .uncaught
    /// Rarities and models picked in the filter sheet; empty shows everything.
    @AppStorage("huntTargets") private var targets = HuntTargets()
    @State private var showFilters = false
    /// The search field in the header is open (#31): a fleet number or a line.
    @State private var searching = false
    @State private var query = ""
    @FocusState private var queryFocused: Bool
    /// A vehicle picked from the search: on the map and selected whatever the filters say.
    @State private var focusId: String?
    /// Satellite photos (with street names) instead of the plain dark map.
    @AppStorage("huntSatellite") private var satellite = false

    private let live = LiveFleetService.shared
    private let location = LocationService.shared
    private let routes = RoutesUpdater.shared
    private let track = TrackService.shared
    private let catalog = Fleet.catalog

    @State private var position: MapCameraPosition = .region(Self.warsaw)
    /// Opened on the default 3 km view around you, once there was a fix to open it on.
    @State private var centered = false
    @State private var pins: [WantedPin] = []
    /// Each vehicle placed on its route, when it could be, as of the last refresh.
    @State private var matches: [String: RouteMatch] = [:]
    /// Where pins sit on the map: slid along their route to where they probably are now, since
    /// every fix is some seconds old. Distances and sorting stay on the fix itself.
    @State private var nowCoordinates: [String: CLLocationCoordinate2D] = [:]
    /// Moves on while a vehicle is selected, so its pin creeps along between polls.
    @State private var tick = Date()
    @State private var selectedId: String?
    /// The map keeps the selected vehicle in view as it drives, until you move the map yourself.
    @State private var following = false
    /// A small bubble you tapped: its vehicles, listed so you can pick one.
    @State private var openGroup: [String]?
    /// What the map is showing: pins cover it, however far you zoom out.
    @State private var mapRegion: MKCoordinateRegion?
    /// The map's rotation, for your dot and the pins' arrows. Not state of this view: it changes
    /// every frame of a turn, and redrawing the whole map that often made the compass lag (#52).
    @State private var turn = MapTurn()
    /// The map turned the way you're facing, centred on you (the second tap on 3 KM).
    /// Anything else that moves the map ends it.
    @State private var facing = false
    private var mapCenter: CLLocationCoordinate2D? { mapRegion?.center }

    private static let warsaw = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 52.2297, longitude: 21.0122),
        span: MKCoordinateSpan(latitudeDelta: 0.06, longitudeDelta: 0.06))
    /// Kilometres from the centre past which the feed has nothing (the suburban lines end
    /// about 40 km out): further than this, you're not in Warsaw.
    private static let feedReach = 50.0

    var body: some View {
        // Read once: the stored filter is decoded from a string on every read.
        let picked = targets
        let shown = pins.filter { pin in
            let wanted = switch filter {
            case .uncaught: pin.kind != .caught
            case .newModels: pin.kind == .newModel
            case .everything: true
            }
            // A line from the search shows all of it, like the search counted (#37).
            return ((wanted || picked.line != nil) && picked.matches(pin)) || pin.id == focusId
        }
        let selected = shown.first { $0.id == selectedId }

        ZStack(alignment: .top) {
            map(onMap(shown))
                .ignoresSafeArea()

            LinearGradient(colors: [Palette.bg.opacity(0.85), Palette.bg.opacity(0)], startPoint: .top, endPoint: .bottom)
                .frame(height: picked.isEmpty ? 150 : 196)
                .ignoresSafeArea(edges: .top)
                .allowsHitTesting(false)

            VStack(spacing: 12) {
                header
                filterBar
                if !picked.isEmpty {
                    targetChips
                        .padding(.top, -4)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                Spacer()
                HStack(spacing: 8) {
                    Spacer()
                    if let selected, !following {
                        followButton(selected)
                            .transition(.scale(scale: 0.8, anchor: .trailing).combined(with: .opacity))
                    }
                    if here != nil, offDefaultView || facing || location.hasHeading {
                        locationButton
                            .transition(.scale(scale: 0.8, anchor: .trailing).combined(with: .opacity))
                    }
                    mapStyleButton
                }
                .padding(.horizontal, 14)
                bottomCard(shown: shown, selected: selected)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
            }
            .animation(.snappy, value: offDefaultView)
            .animation(.snappy, value: facing)
            .animation(.snappy, value: following)
            .animation(.snappy, value: picked)
        }
        .background(Palette.bg.ignoresSafeArea())
        .foregroundStyle(Palette.ink)
        .sheet(isPresented: $showFilters) {
            HuntFilterSheet(targets: $targets, running: cityWide(), withCaught: filter == .everything, hasFix: hasFix)
        }
        // The tab stays alive behind the others once opened, so it comes back at once: the
        // fast polling and the refreshes only run while it's the one on screen.
        .onChange(of: onScreen, initial: true) { _, on in
            guard on else {
                location.stopHeading("hunt")
                return live.stop("hunt")
            }
            live.start("hunt")
            location.startHeading("hunt")
            routes.prepare()
            centerOnceOnYou()
            // Models a fleet update dropped can't match anything; don't leave them as ghost chips.
            let known = targets.models.filter { catalog.model(id: $0) != nil }
            if known != targets.models { targets.models = known }
            recompute(animated: false)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, onScreen { live.start("hunt") }
            if phase == .background { live.stop("hunt") }
        }
        .onChange(of: live.snapshot?.fetched, initial: true) { recompute(animated: true) }
        // MapKit follows you on its own while facing; whatever ends facing leaves the map
        // where it is rather than letting it keep turning.
        .onChange(of: facing) { _, on in
            guard !on, position.followsUserLocation, let camera = turn.camera else { return }
            position = .camera(camera)
        }
        .onChange(of: location.latest) {
            centerOnceOnYou()
            live.locationMoved()
            recompute(animated: false)
        }
        .onChange(of: sightings.count) { recompute(animated: false) }
        .onChange(of: routes.book?.feed) { recompute(animated: false) }
        .task(id: onScreen ? selectedId : nil) { await creep() }
        .onChange(of: picked) {
            selectedId = nil
            openGroup = nil
            recompute(animated: false)
        }
        // A searched vehicle stays on the map only while it's the one selected.
        .onChange(of: selectedId) { if selectedId != focusId { focusId = nil } }
        // Caught vehicles are only fetched for the ALL view.
        .onChange(of: filter) { recompute(animated: false) }
        // SHOW ON MAP in the book: go to where that model is running, not the 3 km around you.
        .onChange(of: router.huntModel, initial: true) { _, id in
            guard let id else { return }
            router.huntModel = nil
            centered = true
            selectedId = nil
            fit(cityWide().filter { $0.model.id == id && targets.matches($0) })
        }
    }

    /// A city-wide (filtered) hunt only gets pins around where you're looking, with a screen's
    /// margin all round, so a broad filter doesn't hand the map a thousand annotations.
    private func onMap(_ shown: [WantedPin]) -> [WantedPin] {
        guard targets.isCityWide, let r = mapRegion else { return shown }
        return shown.filter { p in
            p.id == selectedId || (abs(p.vehicle.latitude - r.center.latitude) < r.span.latitudeDelta
                                   && abs(p.vehicle.longitude - r.center.longitude) < r.span.longitudeDelta)
        }
    }

    // MARK: - Map

    private func map(_ shown: [WantedPin]) -> some View {
        // Picked on the map itself: follow it, above the card that opens.
        let selection = Binding<String?>(get: { selectedId }, set: { id in
            selectedId = id
            if let pin = shown.first(where: { $0.id == id }) { follow(pin) }
        })
        let selectedPin = shown.first { $0.id == selectedId }
        let now = selectedPin.flatMap(creeping)
        return Map(position: $position, interactionModes: .all, selection: selection) {
            if let pin = selectedPin {
                // Its recent path, fading out behind it: along the streets once it's on its route.
                let fixes = live.trails.trail(pin.id)
                let path = now.map { $0.trail(fixes).map(CLLocationCoordinate2D.init) }
                    ?? fixes.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) } + [pin.coordinate]
                // MapKit won't draw a gradient along a line: fade it one segment at a time.
                ForEach(0..<max(0, path.count - 1), id: \.self) { i in
                    MapPolyline(coordinates: [path[i], path[i + 1]])
                        .stroke(pin.accent.opacity(0.25 + 0.75 * Double(i + 1) / Double(path.count - 1)),
                                style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                }
                // Where it goes next: a dotted line along its route to the next few stops,
                // fainter the further ahead, and lighter than the solid trail behind it since
                // it's a forecast. Stops are white beads, as on a transit map, so they don't
                // read as more of the dots.
                if let now {
                    let ahead = now.upcoming(stops: 4)
                    let legs = legs(of: now, to: ahead.stops)
                    ForEach(legs.indices, id: \.self) { i in
                        MapPolyline(coordinates: legs[i])
                            .stroke(pin.accent.opacity(Self.aheadOpacity(i)),
                                    style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round, dash: [0.01, 5.5]))
                    }
                    // On the line rather than at the platform, a few metres off it.
                    ForEach(Array(ahead.stops.enumerated()), id: \.offset) { i, stop in
                        Annotation(stop.name, coordinate: CLLocationCoordinate2D(now.shape.coordinate(at: stop.along)),
                                   anchor: .center) {
                            // The last stop of its run: a square, like a line's end on a transit map.
                            let terminus = now.end != nil && stop == now.shape.stops.last
                            RoundedRectangle(cornerRadius: terminus ? 2 : 3.5, style: .continuous)
                                .fill(Palette.ink)
                                .overlay(RoundedRectangle(cornerRadius: terminus ? 2 : 3.5, style: .continuous)
                                    .strokeBorder(Palette.bg, lineWidth: 1.5))
                                .frame(width: terminus ? 9 : 7, height: terminus ? 9 : 7)
                                .opacity(terminus ? 1 : Self.aheadOpacity(i))
                                .accessibilityHidden(true)
                        }
                        .annotationTitles(.hidden)
                    }
                }
            }
            // Drawn here rather than MapKit's own dot, which only shows which way you face
            // while the map follows your heading.
            UserAnnotation(anchor: .center) { _ in YouDot(turn: turn) }
            // Rarest on top: SwiftUI draws later annotations above earlier ones.
            ForEach(groups(shown).reversed()) { g in
                if g.pins.count == 1 {
                    Annotation(g.lead.model.name, coordinate: mapCoordinate(g.lead, selected: now), anchor: .bottom) {
                        WantedPinView(pin: g.lead, selected: g.id == selectedId,
                                      travel: live.trails.heading(g.lead.id), turn: turn)
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
        .mapStyle(satellite
                  ? .hybrid(elevation: .flat, pointsOfInterest: .excludingAll, showsTraffic: false)
                  : .standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll, showsTraffic: false))
        .mapControls {}
        .environment(\.colorScheme, .dark)
        .onMapCameraChange(frequency: .continuous) { ctx in turn.update(ctx.camera) }
        .onMapCameraChange(frequency: .onEnd) { ctx in
            // Moved by hand: leave the map where it was put. Moves made in code don't count, nor
            // does zooming while facing (MapKit keeps following).
            if position.positionedByUser {
                following = false
                facing = false
            }
            // Only turned, as the facing map does several times a second: nothing the pins
            // depend on changed, and redoing them each time made it lag (#52).
            guard turn.moved(ctx.camera) else { return }
            mapRegion = ctx.region
            recompute(animated: false)
        }
        .onChange(of: selectedId) { _, id in
            if id != nil { facing = false }
            guard let id else {
                following = false
                return
            }
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

    /// Where the map centres to keep a vehicle in view at the current zoom. The card opens over
    /// the bottom of the map, its top edge a little below the middle, so the vehicle sits in
    /// the open part above it. North-up, so latitude runs up the screen.
    private func region(showing coordinate: CLLocationCoordinate2D) -> MKCoordinateRegion? {
        guard let span = mapRegion?.span else { return nil }
        return MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: coordinate.latitude - span.latitudeDelta * 0.15,
                                                                 longitude: coordinate.longitude),
                                  span: span)
    }

    /// Glide to a vehicle, keeping the zoom, and keep it in view from now on.
    private func follow(_ pin: WantedPin) {
        following = true
        guard let region = region(showing: pin.coordinate) else { return }
        withAnimation(.easeInOut(duration: 0.5)) { position = .region(region) }
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

    @ViewBuilder
    private var header: some View {
        if searching {
            searchField
        } else {
            titleRow
        }
    }

    private var titleRow: some View {
        HStack(spacing: 8) {
            Mono("HUNT", size: 12, spacing: 0.16, color: .white.opacity(0.85))
            Spacer()
            Button {
                Haptics.shared.tick()
                withAnimation(.snappy) {
                    searching = true
                    selectedId = nil
                    openGroup = nil
                }
                queryFocused = true
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 10.5, weight: .bold))
                    Mono("SEARCH", size: 10.5, weight: 600, spacing: 0.1, color: .white.opacity(0.85))
                }
                .foregroundStyle(.white.opacity(0.85))
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
                .glass(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Search for a fleet number or a line")
            HStack(spacing: 6) {
                let isLive = live.status == .live
                Circle().fill(statusColor).frame(width: 6, height: 6)
                    .shadow(color: statusColor, radius: isLive ? 4 : 0)
                    // Breathes while the feed is live, like the camera's hint dot.
                    .phaseAnimator([0.35, 1]) { v, p in v.opacity(isLive ? p : 1) } animation: { _ in .easeInOut(duration: 0.9) }
                Mono(statusText, size: 10.5, weight: 600, spacing: 0.1, color: .white.opacity(0.85))
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .glass(Capsule())
        }
        .padding(.top, 6)
        .padding(.horizontal, 20)
    }

    /// Replaces the title row while searching: the field, and Cancel to close it.
    private var searchField: some View {
        HStack(spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white.opacity(0.6))
                TextField("", text: $query, prompt: Text("Fleet number or line").foregroundStyle(.white.opacity(0.45)))
                    .font(TaborFont.mono(14, 600))
                    .foregroundStyle(Palette.ink)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .focused($queryFocused)
                    .onSubmit(pickTopResult)
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear the search")
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .glass(Capsule())
            Button("Cancel") { endSearch() }
                .font(TaborFont.grotesk(15, 600))
                .foregroundStyle(Palette.radar)
        }
        .padding(.top, 2)
        .padding(.horizontal, 20)
        .transition(.opacity)
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
                    // A chip never wraps: a long translation shrinks a touch instead.
                    Mono(f.name, size: 11, weight: 600, spacing: 0.1, color: on ? Palette.bg : .white.opacity(0.75))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .padding(.vertical, 7)
                        .padding(.horizontal, 12)
                        .background(on ? Palette.ink : .clear, in: Capsule())
                        .glass(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
            Spacer(minLength: 0)
            filterButton
        }
        .padding(.horizontal, 20)
    }

    /// Opens the filter sheet; lit, with the number of picks, while a filter is on.
    private var filterButton: some View {
        let on = !targets.isEmpty
        return Button {
            Haptics.shared.tick()
            showFilters = true
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.system(size: 11, weight: .bold))
                Mono(on ? "\(targets.count)" : "FILTER", size: 11, weight: 600, spacing: 0.1,
                     color: on ? Palette.bg : .white.opacity(0.75))
                    .contentTransition(.numericText())
            }
            .foregroundStyle(on ? Palette.bg : .white.opacity(0.75))
            .padding(.vertical, 7)
            .padding(.horizontal, 11)
            .background(on ? Palette.radar : .clear, in: Capsule())
            .glass(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(on ? "Filter, \(targets.count) picked" : "Filter")
    }

    /// What the filter is set to, one removable chip each.
    private var targetChips: some View {
        let picked = targets
        return ScrollView(.horizontal) {
            HStack(spacing: 6) {
                if let kind = picked.kind {
                    targetChip(kind == .bus ? String(localized: "BUSES ONLY") : String(localized: "TRAMS ONLY"), color: Palette.ink) { targets.kind = nil }
                }
                ForEach(Tier.allCases.filter { picked.tiers.contains($0) }, id: \.self) { t in
                    targetChip(t.name, color: t.mapColor) { targets.tiers.subtract([t]) }
                }
                ForEach(picked.models.compactMap(catalog.model(id:)).sorted { $0.name < $1.name }) { m in
                    targetChip(m.name.uppercased(), color: m.tier.mapColor) { targets.models.subtract([m.id]) }
                }
                if let line = picked.line {
                    targetChip(String(localized: "LINE \(line)"), color: Palette.ink) { targets.line = nil }
                }
                ForEach(picked.lengths.sorted(), id: \.self) { l in
                    targetChip(l.name, color: Palette.ink) { targets.lengths.remove(l) }
                }
                ForEach(ModelSpecs.Drive.allCases.filter { picked.drives.contains($0) }, id: \.self) { d in
                    targetChip(d.name, color: Palette.ink) { targets.drives.remove(d) }
                }
                ForEach(ModelSpecs.Floor.allCases.filter { picked.floors.contains($0) }, id: \.self) { f in
                    targetChip(f.name.uppercased(), color: Palette.ink) { targets.floors.remove(f) }
                }
            }
            .padding(.horizontal, 20)
        }
        .scrollIndicators(.hidden)
    }

    private func targetChip(_ text: String, color: Color, remove: @escaping () -> Void) -> some View {
        Button {
            Haptics.shared.tick()
            withAnimation(.snappy) { remove() }
        } label: {
            HStack(spacing: 6) {
                Mono(text, size: 10.5, weight: 600, spacing: 0.08, color: color)
                    .lineLimit(1)
                Image(systemName: "xmark")
                    .font(.system(size: 8.5, weight: .heavy))
                    .foregroundStyle(color.opacity(0.7))
            }
            .padding(.vertical, 6)
            .padding(.leading, 11)
            .padding(.trailing, 9)
            .glass(Capsule())
            .overlay(Capsule().stroke(color.opacity(0.45)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Remove \(text.capitalized) from the filter")
    }

    /// Like Apple Maps' arrow: away from the 3 km around you, it goes back there; on it, it
    /// turns the map the way you're facing; facing, it turns it back to north.
    private var locationButton: some View {
        let away = !facing && offDefaultView
        return Button {
            if facing || away { return resetView() }
            Haptics.shared.tick()
            following = false
            facing = true
            turnToFacing()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: facing ? "location.north.line.fill" : away ? "location" : "location.fill")
                    .font(.system(size: 10.5, weight: .bold))
                    .contentTransition(.symbolEffect(.replace))
                Mono("3 KM", size: 11, weight: 600, spacing: 0.1, color: Palette.radar)
            }
            .foregroundStyle(Palette.radar)
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .glass(Capsule())
            .overlay(Capsule().fill(Palette.radar.opacity(facing ? 0.16 : 0)).allowsHitTesting(false))
            .shadow(color: .black.opacity(0.35), radius: 8, y: 4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(facing ? "Turn the map back to north"
                            : away ? "Back to 3 kilometres around you" : "Turn the map the way you're facing")
    }

    /// Back to following the selected vehicle: shown once you've moved the map away from it.
    private func followButton(_ pin: WantedPin) -> some View {
        Button {
            Haptics.shared.tick()
            follow(pin)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "scope")
                    .font(.system(size: 10.5, weight: .bold))
                Mono("FOLLOW", size: 11, weight: 600, spacing: 0.1, color: Palette.radar)
            }
            .foregroundStyle(Palette.radar)
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .glass(Capsule())
            .shadow(color: .black.opacity(0.35), radius: 8, y: 4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Follow #\(pin.vehicle.number) on the map")
    }

    /// Flips between the plain map and satellite; shows the one you'd switch to.
    private var mapStyleButton: some View {
        Button {
            Haptics.shared.tick()
            satellite.toggle()
        } label: {
            Image(systemName: satellite ? "map.fill" : "globe.europe.africa.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 36, height: 36)
                .glass(Circle())
                .shadow(color: .black.opacity(0.35), radius: 8, y: 4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(satellite ? "Show the map" : "Show satellite")
    }

    /// The default view: you in the middle, the 3 km the list covers around you.
    private func defaultRegion() -> MKCoordinateRegion? {
        guard let here = location.recent(maxAge: 300)?.coordinate ?? mapCenter else { return nil }
        return MKCoordinateRegion(center: here, latitudinalMeters: Wanted.radius * 2, longitudinalMeters: Wanted.radius * 2)
    }

    /// Zoomed in or out from the default, or panned (or walked) away from its centre.
    private var offDefaultView: Bool {
        guard let region = mapRegion, let here else { return false }
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

    /// Facing: you in the middle, the map turned the way the phone points. MapKit's own
    /// following, which turns the map smoothly without redrawing HUNT; moving the camera
    /// ourselves on each compass reading juddered and lagged (#52). It starts a few streets
    /// across rather than at 3 km, but pinching keeps it following.
    private func turnToFacing() {
        withAnimation(.easeInOut(duration: 0.5)) { position = .userLocation(followsHeading: true, fallback: position) }
    }

    private func resetView() {
        guard let region = defaultRegion() else { return }
        Haptics.shared.tick()
        following = false
        facing = false
        withAnimation(.easeInOut(duration: 0.7)) { position = .region(region) }
    }

    @ViewBuilder
    private func bottomCard(shown: [WantedPin], selected: WantedPin?) -> some View {
        Group {
            if searching {
                searchCard(HuntSearch.results(for: query, snapshot: live.snapshot, catalog: catalog))
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if let selected {
                let stats = sightings.stats
                PinCard(pin: selected, owned: stats.ownedCount(modelId: selected.model.id),
                        mine: stats.vehicle(number: selected.vehicle.number, modelId: selected.model.id),
                        showDistance: hasFix, motion: motion(of: selected),
                        nextStops: creeping(selected)?.upcoming(stops: 3).stops.map(\.name) ?? [],
                        ending: creeping(selected)?.ending(within: 3),
                        track: trackButton(selected),
                        onOpen: {
                            if selected.kind == .caught {
                                router.openVehicle(modelId: selected.model.id, number: selected.vehicle.number)
                            } else {
                                router.openModel(selected.model.id)
                            }
                        },
                        onCatch: { withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { router.tab = .catchTab } },
                        onClose: { withAnimation(.snappy) { selectedId = nil } })
                .id(selected.id)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if let ids = openGroup {
                let members = ids.compactMap { id in shown.first { $0.id == id } }
                groupList(members)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if let empty = emptyState(shown: shown) {
                empty
            } else {
                wantedList(listed(shown))
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: selectedId)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: openGroup)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: searching)
    }

    // MARK: - Search

    /// What the search found: lines running now, then the vehicles with that number.
    private func searchCard(_ results: HuntSearch.Results) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                SectionLabel(text: String(localized: "SEARCH"))
                Text("Type a fleet number to find that vehicle, or a line to see everything running on it.")
                    .font(TaborFont.grotesk(14))
                    .foregroundStyle(Palette.sub)
                    .lineSpacing(2)
                    .padding(.top, 6)
            } else if results.isEmpty {
                SectionLabel(text: String(localized: "NOTHING FOUND"))
                Text("No line “\(query)” is running right now, and no vehicle has that number.")
                    .font(TaborFont.grotesk(14))
                    .foregroundStyle(Palette.sub)
                    .lineSpacing(2)
                    .padding(.top, 6)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(results.lines, id: \.self) { l in lineRow(l) }
                        ForEach(results.vehicles, id: \.self) { v in searchedVehicleRow(v) }
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
                .scrollIndicators(.hidden)
                .frame(maxHeight: 4.5 * Self.rowHeight)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .huntCard()
    }

    private func lineRow(_ l: HuntSearch.Line) -> some View {
        Button { pickLine(l) } label: {
            HStack(spacing: 10) {
                Image(systemName: l.kind == .bus ? "bus.fill" : "tram.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Palette.radar)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "Line \(l.line)"))
                        .font(TaborFont.grotesk(14.5, 600))
                    Mono(String(localized: "\(l.count) OUT NOW"), size: 10.5, color: Palette.sub)
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

    private func searchedVehicleRow(_ v: HuntSearch.Vehicle) -> some View {
        let mine = sightings.contains { $0.number == v.number && $0.modelId == v.model.id }
        let accent = v.model.tier.mapColor
        return Button { pickVehicle(v) } label: {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(mine ? .clear : accent)
                    .strokeBorder(accent, lineWidth: 1.5)
                    .frame(width: 5, height: 30)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Mono("#\(v.number)" as String, size: 12, weight: 700, spacing: 0.04, color: Palette.ink)
                            .fixedSize()
                        Text(v.model.name)
                            .font(TaborFont.grotesk(14.5, 600))
                            .lineLimit(1)
                    }
                    Mono(searchedSubtitle(v, mine: mine), size: 10.5, color: v.live == nil ? Palette.faint : Palette.sub)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: v.live == nil ? "book.closed" : "location.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(v.live == nil ? Palette.faint : Palette.radar)
            }
            .frame(height: Self.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// "LINE 523 · 2.1 KM · IN YOUR BOOK", or "NOT OUT NOW · OPEN IN BOOK".
    private func searchedSubtitle(_ v: HuntSearch.Vehicle, mine: Bool) -> String {
        guard let live = v.live else { return String(localized: "NOT OUT NOW · OPEN IN BOOK") }
        let user = here
        let distance = user.map { Geo.km(($0.latitude, $0.longitude), (live.latitude, live.longitude)) * 1000 }
        return [live.line.isEmpty ? nil : String(localized: "LINE \(live.line)"), distance.map(HuntDistance.text),
                mine ? String(localized: "IN YOUR BOOK") : nil]
            .compactMap { $0 }.joined(separator: " · ")
    }

    /// Return on the keyboard: the answer, when there's only one; a list stays up to pick from.
    private func pickTopResult() {
        let r = HuntSearch.results(for: query, snapshot: live.snapshot, catalog: catalog)
        switch (r.lines.count, r.vehicles.count) {
        case (1, 0): pickLine(r.lines[0])
        case (0, 1): pickVehicle(r.vehicles[0])
        default: break
        }
    }

    /// Everything on that line, across the city, through the filter (so it shows as a chip).
    /// It replaces other picks: a line with LEGENDARY still on would usually show nothing.
    private func pickLine(_ l: HuntSearch.Line) {
        Haptics.shared.detent()
        endSearch()
        withAnimation(.snappy) { targets = HuntTargets(line: l.line) }
        // The map only draws pins around where you're looking: go to where the line is.
        fit(cityWide())
    }

    /// Frames these vehicles in the open part of the map above the card.
    private func fit(_ pins: [WantedPin]) {
        guard !pins.isEmpty else { return }
        let lats = pins.map(\.vehicle.latitude), lons = pins.map(\.vehicle.longitude)
        // The open part runs from under the header (a fifth of the way down) to the card's top
        // edge (about 60%): the pins get that band, a little inside it, and its middle is
        // nearly a tenth of the map above the map's own centre.
        let latSpan = max((lats.max()! - lats.min()!) * 2.8, 0.02)
        let span = MKCoordinateSpan(latitudeDelta: latSpan, longitudeDelta: max((lons.max()! - lons.min()!) * 1.25, 0.01))
        let center = CLLocationCoordinate2D(latitude: (lats.max()! + lats.min()!) / 2 - latSpan * 0.09,
                                            longitude: (lons.max()! + lons.min()!) / 2)
        following = false
        facing = false
        withAnimation(.easeInOut(duration: 0.7)) { position = .region(MKCoordinateRegion(center: center, span: span)) }
    }

    /// Running: fly to it and open its card. Not out: its page in the book.
    private func pickVehicle(_ v: HuntSearch.Vehicle) {
        Haptics.shared.detent()
        endSearch()
        guard let live = v.live else {
            return router.openVehicle(modelId: v.model.id, number: v.number)
        }
        let id = "\(live.kind.rawValue)#\(live.number)"
        focusId = id
        recompute(animated: false)
        if let pin = pins.first(where: { $0.id == id }) { select(pin) }
    }

    private func endSearch() {
        queryFocused = false
        withAnimation(.snappy) { searching = false }
        query = ""
    }

    /// A vehicle from the search as a pin, wherever it is and whether or not you've caught it.
    private func searchedPin(_ id: String, in snapshot: LiveSnapshot) -> WantedPin? {
        guard let v = snapshot.vehicles.first(where: { "\($0.kind.rawValue)#\($0.number)" == id }) else { return nil }
        let user = here
        return Wanted.pins(snapshot: LiveSnapshot(vehicles: [v], fetched: snapshot.fetched), catalog: catalog,
                           caught: sightings.stats, lat: v.latitude, lon: v.longitude, within: 10,
                           from: user.map { ($0.latitude, $0.longitude) }, includeCaught: true)
            .first
    }

    /// The vehicles in a tapped bubble; picking one opens its card (and ✕ on that card
    /// comes back here).
    private func groupList(_ members: [WantedPin]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                SectionLabel(text: String(localized: "\(members.count) HERE"))
                Spacer()
                CloseButton { withAnimation(.snappy) { openGroup = nil } }
            }
            pinList(members, visibleRows: 4.5) { pin in
                withAnimation(.snappy) { selectedId = pin.id }
                follow(pin)
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
                        Mono(pin.model.tier.name, size: 9.5, weight: 700, spacing: 0.12, color: pin.accent)
                            .fixedSize()
                        Text(pin.model.name)
                            .font(TaborFont.grotesk(14.5, 600))
                            .lineLimit(1)
                    }
                    Mono(pin.subtitle(showDistance: false), size: 10.5, color: Palette.sub)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if hasFix {
                    VStack(alignment: .trailing, spacing: 3) {
                        Mono(HuntDistance.text(pin.distance), size: 11, weight: 700, spacing: 0.04, color: Palette.ink)
                        if let m = motion(of: pin) {
                            Mono(m.short, size: 8.5, weight: 700, spacing: 0.1, color: m.color)
                        }
                    }
                    .fixedSize()
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Palette.faint)
                }
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

    /// Unfiltered: what's within 3 km, most wanted first. Filtered: every match in the city,
    /// nearest first (to you, or to the map's centre without a fix) — you're after something
    /// specific, so how far it is matters most.
    private func listed(_ shown: [WantedPin]) -> [WantedPin] {
        guard targets.isCityWide else { return nearYou(shown) }
        return shown.sorted { $0.distance < $1.distance }
    }

    /// "UNCAUGHT NEARBY", or "MISSING TRAM MODELS NEARBY" with trams picked.
    private var nearbyTitle: String {
        switch (filter, targets.kind) {
        case (.newModels, nil): String(localized: "MISSING MODELS NEARBY")
        case (.newModels, .bus): String(localized: "MISSING BUS MODELS NEARBY")
        case (.newModels, .tram): String(localized: "MISSING TRAM MODELS NEARBY")
        case (.uncaught, nil): String(localized: "UNCAUGHT NEARBY")
        case (.uncaught, .bus): String(localized: "UNCAUGHT BUSES NEARBY")
        case (.uncaught, .tram): String(localized: "UNCAUGHT TRAMS NEARBY")
        case (.everything, nil): String(localized: "ALL NEARBY")
        case (.everything, .bus): String(localized: "BUSES NEARBY")
        case (.everything, .tram): String(localized: "TRAMS NEARBY")
        }
    }

    private func wantedList(_ near: [WantedPin]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                // One line even with the count beside it on a 390 pt phone ("BRAKUJĄCE MODELE TRAMWAJÓW").
                SectionLabel(text: targets.isCityWide ? String(localized: "MATCHING YOUR FILTER") : nearbyTitle)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Spacer()
                Mono(targets.isCityWide ? "\(near.count) OUT NOW" : hasFix ? "\(near.count) WITHIN 3 KM" : "AROUND THE MAP CENTRE",
                     size: 9.5, color: Palette.faint)
            }
            if filter != .newModels {
                HStack(spacing: 12) {
                    LegendSwatch(filled: true, text: String(localized: "MODEL YOU DON'T HAVE"))
                    LegendSwatch(filled: false, text: String(localized: "MODEL YOU HAVE"))
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
            return MessageCard(icon: "key.fill", title: String(localized: "Live positions are off"),
                               text: String(localized: "HUNT needs a free dane.um.warszawa.pl key. Add yours in ME › Settings › Live data."))
        case .error(let why) where live.fresh(maxAge: 120) == nil:
            return MessageCard(icon: "antenna.radiowaves.left.and.right.slash", title: String(localized: "The city's feed is down"),
                               text: String(localized: "\(why) Trying again every 10 seconds."))
        case .idle, .loading:
            if live.snapshot == nil {
                return MessageCard(icon: "dot.radiowaves.left.and.right", title: String(localized: "Finding what's running…"), text: nil)
            }
        default: break
        }
        if location.isDenied, mapCenter == nil {
            return MessageCard(icon: "location.slash.fill", title: String(localized: "Location is off"),
                               text: String(localized: "Turn it on to see what's running around you — or pan the map to look anywhere."),
                               action: (String(localized: "Open Settings"), {
                                   if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                               }))
        }
        if targets.isCityWide {
            guard shown.isEmpty else { return nil }
            return MessageCard(icon: "line.3.horizontal.decrease.circle", title: String(localized: "Nothing out that matches"),
                               text: targets.line == nil && filter == .newModels
                                   ? String(localized: "None of it is a model you're missing. Switch to UNCAUGHT, or widen the filter.")
                                   : targets.line != nil || filter == .everything
                                   ? String(localized: "Nothing on your filter is running right now. It shows up here the moment one is.")
                                   : String(localized: "Nothing on your filter that you haven't caught is running right now. It shows up here the moment one is."),
                               action: (String(localized: "Clear the filter"), { withAnimation(.snappy) { targets = HuntTargets() } }))
        }
        if nearYou(shown).isEmpty {
            // Nothing of the kind running here at all, caught or not: say that, rather than that
            // you've caught everything around you (what a tester in Bydgoszcz was told, #38).
            // Your actual position, even outside Warsaw: that's the case to explain.
            let around = location.recent(maxAge: 300)?.coordinate ?? mapCenter
            let running = around.map { a in
                live.snapshot?.nearby(lat: a.latitude, lon: a.longitude, within: Wanted.radius)
                    .contains { targets.kind == nil || $0.vehicle.kind == targets.kind } ?? true
            } ?? true
            if !running, let around {
                let center = Self.warsaw.center
                if Geo.km((around.latitude, around.longitude), (center.latitude, center.longitude)) > Self.feedReach {
                    return MessageCard(icon: "map", title: String(localized: "Nothing runs near you"),
                                       text: String(localized: "TABOR follows Warsaw's buses and trams. Pan over to Warsaw, or pick a filter to hunt across the whole city."),
                                       action: (String(localized: "Show Warsaw"), {
                                           following = false
                                           facing = false
                                           withAnimation(.easeInOut(duration: 0.7)) { position = .region(Self.warsaw) }
                                       }))
                }
                let title = switch targets.kind {
                case nil: String(localized: "Nothing within 3 km")
                case .bus: String(localized: "No buses within 3 km")
                case .tram: String(localized: "No trams within 3 km")
                }
                return MessageCard(icon: "location.magnifyingglass", title: title, text: String(localized: "Nothing running within 3 km right now."))
            }
            let title = switch (filter, targets.kind) {
            case (.newModels, nil): String(localized: "No models you're missing within 3 km")
            case (.newModels, .bus): String(localized: "No bus models you're missing within 3 km")
            case (.newModels, .tram): String(localized: "No tram models you're missing within 3 km")
            case (.uncaught, nil): String(localized: "No uncaught vehicles within 3 km")
            case (.uncaught, .bus): String(localized: "No uncaught buses within 3 km")
            case (.uncaught, .tram): String(localized: "No uncaught trams within 3 km")
            case (.everything, nil): String(localized: "Nothing within 3 km")
            case (.everything, .bus): String(localized: "No buses within 3 km")
            case (.everything, .tram): String(localized: "No trams within 3 km")
            }
            let text = switch (filter, targets.kind) {
            case (.newModels, _): String(localized: "Everything running around here is a model you have. Switch to UNCAUGHT for more of them.")
            case (.everything, _): String(localized: "Nothing running within 3 km right now.")
            case (.uncaught, nil): String(localized: "Every vehicle running around here is already in your book.")
            case (.uncaught, .bus): String(localized: "Every bus running around here is already in your book.")
            case (.uncaught, .tram): String(localized: "Every tram running around here is already in your book.")
            }
            return MessageCard(icon: "checkmark.seal.fill", title: title, text: text)
        }
        return nil
    }

    // MARK: - State

    private var hasFix: Bool { here != nil }

    /// Where you are, when it's somewhere the feed covers. From further away (a tester in
    /// Bydgoszcz), HUNT works as it does without a fix: around where you're looking, with
    /// distances from there, rather than measuring 230 km to every bus.
    private var here: CLLocationCoordinate2D? {
        guard let c = location.recent(maxAge: 300)?.coordinate else { return nil }
        let center = Self.warsaw.center
        return Geo.km((c.latitude, c.longitude), (center.latitude, center.longitude)) <= Self.feedReach ? c : nil
    }

    private var statusColor: Color {
        switch live.status {
        case .live: Palette.green
        case .loading, .idle: Palette.yellow
        case .noKey, .error: Palette.red
        }
    }

    private var statusText: String {
        switch live.status {
        case .noKey: String(localized: "NO KEY")
        case .idle, .loading: String(localized: "CONNECTING")
        case .error: live.fresh(maxAge: 120) == nil ? String(localized: "OFFLINE") : String(localized: "RETRYING")
        case .live: String(localized: "LIVE")
        }
    }

    /// Every uncaught vehicle out right now, anywhere (caught ones too in the ALL view);
    /// distances from you when there's a fix.
    private func cityWide() -> [WantedPin] {
        guard let snapshot = live.snapshot else { return [] }
        let user = here
        let from = user ?? mapCenter ?? Self.warsaw.center
        if let line = targets.line {
            return Wanted.onLine(line, snapshot: snapshot, catalog: catalog, caught: sightings.stats,
                                 lat: from.latitude, lon: from.longitude, from: user.map { ($0.latitude, $0.longitude) })
        }
        return Wanted.anywhere(snapshot: snapshot, catalog: catalog, caught: sightings.stats,
                               lat: from.latitude, lon: from.longitude,
                               from: user.map { ($0.latitude, $0.longitude) }, includeCaught: filter == .everything)
    }

    private var onScreen: Bool { router.tab == .hunt }

    private func recompute(animated: Bool) {
        guard onScreen else { return }
        let user = here
        guard let snapshot = live.snapshot, let center = mapCenter ?? user else { return }
        // Half the visible diagonal, and never less than the 3 km the list needs.
        let visible = mapRegion.map { r in
            Geo.km((r.center.latitude - r.span.latitudeDelta / 2, r.center.longitude - r.span.longitudeDelta / 2),
                   (r.center.latitude + r.span.latitudeDelta / 2, r.center.longitude + r.span.longitudeDelta / 2)) * 500
        } ?? 0
        // Filtered down to what you're after: look across the whole city, not just the view.
        let picked = targets
        let filtered = picked.isCityWide
        var next = filtered
            ? cityWide().filter { picked.matches($0) }
            : Wanted.pins(snapshot: snapshot, catalog: catalog, caught: sightings.stats,
                          lat: center.latitude, lon: center.longitude, within: max(Wanted.radius, visible),
                          from: user.map { ($0.latitude, $0.longitude) }, includeCaught: filter == .everything)
        // Panned away from you: make sure what's around you still feeds the list.
        if !filtered, let user, Geo.km((user.latitude, user.longitude), (center.latitude, center.longitude)) * 1000 > visible {
            let ids = Set(next.map(\.id))
            next += Wanted.pins(snapshot: snapshot, catalog: catalog, caught: sightings.stats,
                                lat: user.latitude, lon: user.longitude, from: (user.latitude, user.longitude),
                                includeCaught: filter == .everything)
                .filter { !ids.contains($0.id) }
        }
        // The vehicle picked from the search, wherever it is and whether or not you have it.
        if let focusId, !next.contains(where: { $0.id == focusId }), let pin = searchedPin(focusId, in: snapshot) {
            next.append(pin)
        }
        // Only what the map can show gets placed on its route: it's the costly part.
        var placed: [String: RouteMatch] = [:]
        var coordinates: [String: CLLocationCoordinate2D] = [:]
        if let book = routes.book {
            let now = Date()
            let region = mapRegion
            for pin in next where region.map({ r in
                abs(pin.vehicle.latitude - r.center.latitude) < r.span.latitudeDelta
                    && abs(pin.vehicle.longitude - r.center.longitude) < r.span.longitudeDelta
            }) ?? true {
                guard let m = Self.match(pin, book: book, trails: live.trails) else { continue }
                placed[pin.id] = m
                let ahead = m.advanced(by: now.timeIntervalSince(pin.vehicle.time), stopped: live.trails.isStopped(pin.id))
                coordinates[pin.id] = CLLocationCoordinate2D(ahead.coordinate)
            }
        }
        matches = placed
        // Vehicles glide to where they are now rather than jumping.
        if animated {
            withAnimation(.easeInOut(duration: 1.2)) {
                pins = next
                nowCoordinates = coordinates
                tick = Date()
            }
        } else {
            pins = next
            nowCoordinates = coordinates
        }
        if let selectedId, !next.contains(where: { $0.id == selectedId }) { self.selectedId = nil }
        // Following the selected vehicle and it's leaving the open part above the card: catch up,
        // keeping the zoom. Not after you've moved the map yourself.
        if following, let selectedId, let pin = next.first(where: { $0.id == selectedId }), let region = mapRegion,
           let target = self.region(showing: pin.coordinate),
           abs(target.center.latitude - region.center.latitude) > region.span.latitudeDelta * 0.2
            || abs(target.center.longitude - region.center.longitude) > region.span.longitudeDelta * 0.3 {
            withAnimation(.easeInOut(duration: 1.2)) { position = .region(target) }
        }
    }

    /// The straight-line guess from its trail, checked against its route when there is one:
    /// heading for you but turning off first isn't coming your way.
    private func motion(of pin: WantedPin) -> Motion? {
        guard let here else { return nil }
        let guess = live.trails.motion(pin.id, lat: here.latitude, lon: here.longitude)
        guard let match = routeMatch(pin) else { return guess }
        return match.motion(fallback: guess, lat: here.latitude, lon: here.longitude)
    }

    private func routeMatch(_ pin: WantedPin) -> RouteMatch? {
        if let m = matches[pin.id] { return m }
        guard let book = routes.book else { return nil }
        return Self.match(pin, book: book, trails: live.trails)
    }

    private static func match(_ pin: WantedPin, book: RouteBook, trails: LiveTrails) -> RouteMatch? {
        let v = pin.vehicle
        guard !v.line.isEmpty else { return nil }
        return book.match(line: v.line, kind: v.kind, trail: trails.trail(pin.id),
                          position: LiveTrails.Point(latitude: v.latitude, longitude: v.longitude, time: v.time))
    }

    /// Where it probably is right now: its route match slid forward by the fix's age.
    private func advanced(_ pin: WantedPin, at date: Date) -> RouteMatch? {
        routeMatch(pin)?.advanced(by: date.timeIntervalSince(pin.vehicle.time), stopped: live.trails.isStopped(pin.id))
    }

    /// TRACK on the card. It only works while the vehicle is coming your way (it counts down to
    /// your stop); otherwise it's greyed out and says why, so the button never just goes missing.
    private func trackButton(_ pin: WantedPin) -> PinCard.Track {
        if track.isTracking(pin) { return PinCard.Track(state: .on) { track.stop() } }
        guard track.enabled else {
            return PinCard.Track(state: .off(String(localized: "Live Activities are off for TABOR. Turn them on in Settings › TABOR to track it.")))
        }
        guard let here else {
            return PinCard.Track(state: .off(String(localized: "TRACK counts down to your stop, so it needs your location.")))
        }
        let motion = motion(of: pin)
        guard motion == .approaching, let m = creeping(pin) ?? routeMatch(pin),
              let plan = TrackPlan.make(match: m, lat: here.latitude, lon: here.longitude) else {
            return PinCard.Track(state: .off(motion == nil
                ? String(localized: "Still watching which way it goes. TRACK works once it's coming your way.")
                : String(localized: "TRACK works once it's coming your way: it counts down to your stop.")))
        }
        return PinCard.Track(state: .ready) { track.start(pin, plan: plan, sightings: sightings) }
    }

    /// The selected vehicle, moved on to the last tick.
    private func creeping(_ pin: WantedPin) -> RouteMatch? { advanced(pin, at: tick) }

    /// Moves the selected pin along its route between polls, but only in steps you'd see: a few
    /// points on screen at the current zoom, so zoomed out it hardly ticks at all. Each step is
    /// a short glide rather than non-stop animation, which would keep the map redrawing at full
    /// frame rate, and a stopped vehicle (or one already at its next stop) doesn't tick.
    private func creep() async {
        while !Task.isCancelled, let id = selectedId {
            var wait = 2.0
            if let pin = pins.first(where: { $0.id == id }), let now = creeping(pin), now.speed >= 0.5,
               !live.trails.isStopped(id), let region = mapRegion {
                // Metres per screen point, across a phone-width map.
                let perPoint = region.span.longitudeDelta * 111_320 * cos(region.center.latitude * .pi / 180) / 400
                wait = min(max(Self.creepStep * perPoint / now.speed, 1), 10)
                try? await Task.sleep(for: .seconds(wait))
                guard !Task.isCancelled, let later = advanced(pin, at: Date()), later.along - now.along > 1 else { continue }
                withAnimation(.easeInOut(duration: 0.4)) { tick = Date() }
                continue
            }
            try? await Task.sleep(for: .seconds(wait))
        }
    }

    /// Screen points a creeping pin moves per step.
    private static let creepStep = 4.0

    private func mapCoordinate(_ pin: WantedPin, selected now: RouteMatch?) -> CLLocationCoordinate2D {
        if pin.id == selectedId, let now { return CLLocationCoordinate2D(now.coordinate) }
        return nowCoordinates[pin.id] ?? pin.coordinate
    }

    /// Leg by leg, the route ahead fades.
    private static func aheadOpacity(_ leg: Int) -> Double { max(0.35, 0.95 - 0.2 * Double(leg)) }

    /// The path ahead cut at each stop, so each leg can fade a little more.
    private func legs(of match: RouteMatch, to stops: [RouteStop]) -> [[CLLocationCoordinate2D]] {
        var from = match.along
        return stops.map { stop in
            defer { from = stop.along }
            return match.shape.path(from: from, to: stop.along).map(CLLocationCoordinate2D.init)
        }.filter { $0.count >= 2 }
    }

    /// From the list: select the pin and fly to it.
    private func select(_ pin: WantedPin) {
        withAnimation(.snappy) { selectedId = pin.id }
        following = true
        withAnimation(.easeInOut(duration: 0.6)) {
            position = .camera(MapCamera(centerCoordinate: pin.coordinate, distance: 1800))
        }
    }
}

// MARK: - Pieces

private extension CLLocationCoordinate2D {
    init(_ c: (latitude: Double, longitude: Double)) { self.init(latitude: c.latitude, longitude: c.longitude) }
}

private extension WantedPin {
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: vehicle.latitude, longitude: vehicle.longitude) }

    var accent: Color { model.tier.mapColor }

    func subtitle(showDistance: Bool, showKind: Bool = true) -> String {
        [showKind ? vehicle.kind.name : nil, "#\(vehicle.number)", vehicle.line.isEmpty ? nil : String(localized: "LINE \(vehicle.line)"),
         showDistance ? HuntDistance.text(distance) : nil]
            .compactMap { $0 }.joined(separator: " · ")
    }
}

enum HuntDistance {
    /// "400 M", "1.2 KM" ("1,2 KM" in Polish).
    static func text(_ metres: Double) -> String {
        metres < 1000 ? "\(Int((metres / 50).rounded()) * 50) M"
            : "\((metres / 1000).formatted(FloatingPointFormatStyle<Double>(locale: .app).precision(.fractionLength(1)))) KM"
    }
}

/// A missing model: a tier-coloured tag with the line it's running on.
/// Up close: a tag with the line. Filled for a model new to you, outlined for one you have.
private struct WantedPinView: View {
    let pin: WantedPin
    let selected: Bool
    /// Direction of travel (degrees from north), once the vehicle has been seen moving.
    var travel: Double? = nil
    /// The map's rotation, read here so a turning map redraws only the pins.
    let turn: MapTurn
    private var filled: Bool { pin.kind == .newModel }
    /// On screen, 0 = up.
    private var heading: Double? { travel.map { $0 - turn.coarse } }

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
            .foregroundStyle(filled ? pin.model.tier.onMapColor : pin.accent)
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
        .accessibilityLabel("\(pin.model.tier.name.lowercased()) \(pin.model.name), line \(pin.vehicle.line)")
        .accessibilityAddTraits(.isButton)
    }
}

@Observable
private final class MapTurn {
    /// Degrees clockwise from north.
    private(set) var heading: Double = 0
    /// The same in 5° steps, for the pins' arrows (eight of them, 45° apart): a smooth turn
    /// would otherwise redraw every pin on every frame.
    private(set) var coarse: Double = 0
    /// Where the camera is now, to leave the map there when facing ends.
    @ObservationIgnored private(set) var camera: MapCamera?
    /// Where it last came to rest.
    @ObservationIgnored private var settled: MapCamera?

    func update(_ camera: MapCamera) {
        self.camera = camera
        if camera.heading != heading { heading = camera.heading }
        let step = (camera.heading / 5).rounded() * 5
        if step != coarse { coarse = step }
    }

    /// Whether the camera came to rest somewhere new, rather than only turning on the spot.
    func moved(_ camera: MapCamera) -> Bool {
        defer { settled = camera }
        guard let settled else { return true }
        let a = settled.centerCoordinate, b = camera.centerCoordinate
        return Geo.km((a.latitude, a.longitude), (b.latitude, b.longitude)) > 0.01
            || abs(camera.distance / settled.distance - 1) > 0.01
    }
}

/// You on the map: Apple's blue dot, with a beam the way the phone points. Like Apple Maps,
/// the beam widens when the compass isn't sure.
private struct YouDot: View {
    let turn: MapTurn
    private static let blue = Color(uiColor: .systemBlue)

    var body: some View {
        ZStack {
            if let heading = LocationService.shared.heading {
                Beam(spread: min(max(heading.accuracy, 20), 60))
                    .fill(RadialGradient(colors: [Self.blue.opacity(0.6), Self.blue.opacity(0)],
                                         center: .center, startRadius: 6, endRadius: 46))
                    .rotationEffect(.degrees(heading.degrees - turn.heading))
            }
            Circle().fill(.white).frame(width: 20, height: 20)
                .shadow(color: .black.opacity(0.35), radius: 3)
            Circle().fill(Self.blue).frame(width: 14, height: 14)
        }
        .frame(width: 92, height: 92)
        .allowsHitTesting(false)
        .accessibilityLabel("You")
    }

    private struct Beam: Shape {
        /// Half the beam's angle, in degrees.
        var spread: Double

        func path(in rect: CGRect) -> Path {
            let c = CGPoint(x: rect.midX, y: rect.midY)
            var p = Path()
            p.move(to: c)
            p.addArc(center: c, radius: rect.width / 2, startAngle: .degrees(-90 - spread), endAngle: .degrees(-90 + spread), clockwise: false)
            p.closeSubpath()
            return p
        }
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
            .foregroundStyle(filled ? group.lead.model.tier.onMapColor : accent)
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
    /// This very vehicle in your book, in the ALL view.
    let mine: OwnedVehicle?
    let showDistance: Bool
    /// Which way it's going relative to you; nil until it's been seen moving.
    let motion: Motion?
    /// Its next stops, when it's been placed on its route.
    let nextStops: [String]
    /// Its route ends within those stops, or it's at the last one.
    let ending: (end: RouteEnd, arrived: Bool)?
    /// Follow it on the Lock Screen (#42).
    let track: Track
    let onOpen: () -> Void
    /// Why TRACK is greyed out, shown for a few seconds after tapping it.
    @State private var trackHint: String?

    struct Track {
        enum State: Equatable {
            case ready
            /// Already followed: the button stops it.
            case on
            /// Can't be tracked now, and why.
            case off(String)
        }

        let state: State
        var action: () -> Void = {}
    }
    /// Off to the camera to catch it.
    let onCatch: () -> Void
    let onClose: () -> Void

    /// Where it goes next, in one line: its next stops, and how its route ends once that's
    /// among them. The last stop coming up next, or reached, is said in words.
    private var routeLine: (label: String?, symbol: String?, text: Text)? {
        if let ending, ending.arrived {
            return (nil, ending.end.symbol, Text(ending.end.arrivedText))
        }
        guard !nextStops.isEmpty else { return nil }
        let next = String(localized: "NEXT")
        if let ending, nextStops.count == 1 {
            return (next, nil, Text(ending.end.comingText))
        }
        var text = Text(nextStops.joined(separator: " · "))
        if let ending {
            text = text + Text(" ") + Text(Image(systemName: ending.end.symbol)).foregroundStyle(Palette.sub)
        }
        return (next, nil, text)
    }

    private var motionLine: (text: String, color: Color) {
        motion.map { (text: $0.text, color: $0.color) } ?? (text: String(localized: "WATCHING WHICH WAY IT GOES…"), color: Palette.faint)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                KindTag(kind: pin.vehicle.kind)
                TierPill(tier: pin.model.tier, fleet: pin.model.fleet)
                Spacer()
                CloseButton(action: onClose)
            }
            Text(pin.model.name)
                .font(TaborFont.grotesk(24, 700))
                .em(-0.03, size: 24)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Mono(pin.subtitle(showDistance: showDistance, showKind: false), size: 11, weight: 600, color: Palette.routeInk)
                    .lineLimit(1)
                Spacer(minLength: 4)
                SeenAgo(time: pin.vehicle.time)
            }
            if showDistance {
                HStack(spacing: 6) {
                    Circle().fill(motionLine.color).frame(width: 6, height: 6)
                    Mono(motionLine.text, size: 11, weight: 600, color: motionLine.color)
                        .lineLimit(1)
                        .contentTransition(.opacity)
                }
                .animation(.easeInOut(duration: 0.3), value: motionLine.text)
            }
            if let route = routeLine {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    if let label = route.label {
                        Mono(label, size: 10, weight: 700, spacing: 0.12, color: pin.accent)
                    } else if let symbol = route.symbol {
                        Image(systemName: symbol)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(pin.accent)
                    }
                    route.text
                        .font(TaborFont.grotesk(13, 500))
                        .foregroundStyle(Palette.routeInk)
                        .lineLimit(1)
                        .contentTransition(.opacity)
                }
                .animation(.easeInOut(duration: 0.3), value: nextStops)
                .accessibilityElement(children: .combine)
            }
            Group {
                if let mine {
                    Text("In your book since \(mine.firstSeen.formatted(.dateTime.day().month())) · seen \(mine.timesSeen)×")
                } else if pin.kind == .newModel {
                    Text("Not in your book yet — catching it opens a new page.")
                } else {
                    Text("You have \(owned) of \(pin.model.fleet). This one isn't among them.")
                }
            }
                .font(TaborFont.grotesk(13))
                .foregroundStyle(pin.kind == .newModel ? Palette.greenInk : Palette.sub)
            HStack(spacing: 8) {
                Button(action: onOpen) {
                    HStack(spacing: 6) {
                        Image(systemName: AppTab.book.symbol)
                            .font(.system(size: 11, weight: .bold))
                        Mono("BOOK", size: 12, weight: 700, spacing: 0.12, color: Palette.ink)
                    }
                    .foregroundStyle(Palette.ink)
                    .padding(.vertical, 13)
                    .padding(.horizontal, 12)
                    .background(Palette.chip, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(Color.white.opacity(0.1)))
                }
                .buttonStyle(StickerPressStyle())
                .accessibilityLabel("Open \(pin.model.name) in the book")
                trackButton
                Button(action: onCatch) {
                    HStack(spacing: 7) {
                        Image(systemName: AppTab.catchTab.symbol)
                            .font(.system(size: 13, weight: .bold))
                        Mono("CATCH IT", size: 12, weight: 700, spacing: 0.12, color: pin.model.tier.onMapColor)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .foregroundStyle(pin.model.tier.onMapColor)
                    .frame(maxWidth: .infinity)
                    .padding(13)
                    .background(pin.accent, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                }
                .buttonStyle(StickerPressStyle())
                .accessibilityLabel("Open the camera to catch it")
            }
            .padding(.top, 2)
            if let trackHint {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Image(systemName: "bell.slash").font(.system(size: 11, weight: .semibold))
                    Text(trackHint).font(TaborFont.grotesk(12.5)).fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(Palette.sub)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(16)
        .huntCard(radius: 20, stroke: pin.accent.opacity(0.35))
        .task(id: trackHint) {
            guard trackHint != nil else { return }
            try? await Task.sleep(for: .seconds(4))
            withAnimation(.snappy) { trackHint = nil }
        }
        // Coming your way now: whatever held it back no longer does.
        .onChange(of: track.state) { if track.state == .ready { trackHint = nil } }
    }

    private var trackButton: some View {
        let on = track.state == .on
        let off: String? = if case .off(let why) = track.state { why } else { nil }
        let ink = on ? Palette.bg : off != nil ? Palette.faint : Palette.radar
        return Button {
            if let off {
                Haptics.shared.nope()
                withAnimation(.snappy) { trackHint = off }
            } else {
                Haptics.shared.tick()
                track.action()
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: on ? "bell.fill" : "bell")
                    .font(.system(size: 11, weight: .bold))
                Mono(on ? "TRACKING" : "TRACK", size: 12, weight: 700, spacing: 0.12, color: ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(ink)
            .padding(.vertical, 13)
            .padding(.horizontal, 11)
            .background(on ? Palette.radar : Palette.chip, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(off != nil ? Color.white.opacity(0.08) : Palette.radar.opacity(0.4)))
        }
        .buttonStyle(StickerPressStyle())
        // Ahead of CATCH IT, which stretches: "OBSERWUJESZ" wrapped in two otherwise. The
        // buttons' padding is tight enough that "ZŁAP GO" still fits beside it.
        .layoutPriority(1)
        .accessibilityLabel(on ? String(localized: "Stop tracking it on the Lock Screen")
                            : off ?? String(localized: "Track it on the Lock Screen until it reaches you"))
        .animation(.snappy, value: track.state)
    }
}

/// How old the position on the map is: the city's feed lags a few seconds behind, and a
/// vehicle that's stopped reporting sits still at its last fix.
private struct SeenAgo: View {
    let time: Date
    /// Past this, the pin may well be somewhere else by now.
    static let stale: TimeInterval = 60

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let age = max(0, ctx.date.timeIntervalSince(time))
            let seconds = Int(age)
            Mono(age < Self.stale ? "\(seconds) S AGO" : "\(seconds / 60) MIN AGO",
                 size: 10, weight: 600, spacing: 0.08, color: age < Self.stale ? Palette.sub : Palette.faint)
                .lineLimit(1)
                .fixedSize()
        }
    }
}

private extension RouteEnd {
    /// The last stop, coming up next.
    var comingText: String {
        switch self {
        case .depot(let stop): String(localized: "\(stop), then into the depot")
        case .turnsBack(let stop): String(localized: "\(stop), where it turns back")
        case .ends(let stop): String(localized: "\(stop), where its run ends")
        }
    }

    /// At the last stop.
    var arrivedText: String {
        switch self {
        case .depot(let stop): String(localized: "Pulling into \(stop)")
        case .turnsBack(let stop): String(localized: "Turning back at \(stop)")
        case .ends(let stop): String(localized: "End of its run at \(stop)")
        }
    }

    var symbol: String {
        switch self {
        case .depot: "house.fill"
        case .turnsBack: "arrow.uturn.backward"
        case .ends: "flag.checkered"
        }
    }
}

private extension Motion {
    /// On the card.
    var text: String {
        switch self {
        case .approaching: String(localized: "COMING YOUR WAY")
        case .passing: String(localized: "GOING PAST")
        case .leaving: String(localized: "MOVING AWAY")
        case .stopped: String(localized: "STOPPED")
        case .turnsOff: String(localized: "TURNS OFF BEFORE YOU")
        }
    }

    /// Under the distance in a list row.
    var short: String {
        switch self {
        case .approaching: String(localized: "COMING", comment: "Short: vehicle heading towards you")
        case .passing: String(localized: "PASSING", comment: "Short: vehicle going past you")
        case .leaving: String(localized: "AWAY", comment: "Short: vehicle moving away from you")
        case .stopped: String(localized: "STOPPED")
        case .turnsOff: String(localized: "TURNS OFF", comment: "Short: vehicle heading your way, but its route turns before reaching you")
        }
    }

    var color: Color {
        switch self {
        case .approaching: Palette.green
        case .passing, .stopped: Palette.yellow
        case .leaving: Palette.sub
        case .turnsOff: Palette.faint
        }
    }
}

/// The small ✕ on HUNT's cards, with a finger-sized target around it.
private struct CloseButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Palette.sub)
                .frame(width: 30, height: 30)
                .background(Palette.chip, in: Circle())
                .padding(7)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(-7)
        .accessibilityLabel("Close")
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
