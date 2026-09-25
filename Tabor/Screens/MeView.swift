import MapKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct MeView: View {
    @Query(sort: \Sighting.date, order: .reverse) private var sightings: [Sighting]
    @Environment(Router.self) private var router
    @State private var showSettings = false
    @State private var showMap = false
    private let catalog = Fleet.catalog

    var body: some View {
        let stats = sightings.stats
        let trophies = stats.rarest(catalog: catalog, limit: 3)

        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                TopBar {
                    Mono("ME", size: 12, spacing: 0.16)
                } trailing: {
                    Button {
                        showSettings = true
                    } label: { Mono("SETTINGS", size: 12) }
                    .buttonStyle(.plain)
                }

                VStack(alignment: .leading, spacing: 4) {
                    ScreenTitle(text: "Trophy shelf")
                    Mono(trophies.isEmpty ? "NOTHING ON THE SHELF YET"
                         : "YOUR \(trophies.count) RAREST OF \(stats.caught)",
                         size: 11, color: Palette.sub)
                }
                .padding(.top, 16)
                .padding(.horizontal, 22)

                TrophyShelf(trophies: trophies, sightings: sightings)
                    .padding(.top, 20)
                    .padding(.horizontal, 22)

                StatsStrip(items: [
                    (stats.caught.grouped, "CAUGHT", Palette.ink),
                    (percent(stats.fleetShare(catalog: catalog)), "OF FLEET", Palette.yellow),
                    ("\(Streak.days(sightings.map(\.date)))", "DAY STREAK", Palette.ink),
                    (depotsTouched(stats), "DEPOTS", Palette.ink),
                ])
                .padding(.top, 18)
                .padding(.horizontal, 22)

                BadgeShelf(badges: Achievements.evaluate(sightings.map(\.record), catalog: catalog))
                    .padding(.top, 18)
                    .padding(.horizontal, 22)

                HStack(alignment: .firstTextBaseline) {
                    SectionLabel(text: "WHERE YOU SPOT")
                    Spacer()
                    Button {
                        showMap = true
                    } label: { Mono("OPEN MAP", size: 10.5, color: Palette.yellow) }
                    .buttonStyle(.plain)
                }
                .padding(.top, 16)
                .padding(.bottom, 9)
                .padding(.horizontal, 22)

                SpotMap(sightings: sightings, interactive: false)
                    .frame(height: 190)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.white.opacity(0.06)))
                    .onTapGesture {
                        showMap = true
                    }
                    .padding(.horizontal, 22)
                mapCaption
                    .padding(.horizontal, 22)
                    .padding(.top, 8)
                    .padding(.bottom, 22)
            }
        }
        .scrollIndicators(.hidden)
        .taborScreen()
        .sheet(isPresented: $showSettings) { SettingsSheet() }
        .fullScreenCover(isPresented: $showMap) {
            ZStack(alignment: .topLeading) {
                SpotMap(sightings: sightings, interactive: true).ignoresSafeArea()
                Button {
                    showMap = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Palette.ink)
                        .frame(width: 44, height: 44)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .padding(.leading, 18)
                .padding(.top, 8)
            }
            .preferredColorScheme(.dark)
        }
    }

    private var mapCaption: some View {
        let geotagged = sightings.filter { $0.latitude != nil }
        let patch = Dictionary(grouping: geotagged.compactMap(\.district), by: { $0 })
            .max { $0.value.count < $1.value.count }?.key
        return HStack {
            Mono(patch.map { "\($0.uppercased()) IS YOUR PATCH" } ?? "GEOTAG A CATCH TO START YOUR MAP",
                 size: 9.5, color: Palette.sub)
            Spacer()
            Mono("\(geotagged.count) PINS", size: 9.5, color: Palette.faint)
        }
        .padding(.horizontal, 4)
    }

    private func percent(_ v: Double) -> String {
        if v > 0, v < 0.01 { return "<1%" }
        return "\(Int((v * 100).rounded()))%"
    }

    /// Depots whose vehicles you've caught, out of all depots in the snapshot.
    private func depotsTouched(_ stats: CollectionStats) -> String {
        var hit = Set<String>()
        for v in stats.vehicles {
            if let b = catalog.model(id: v.modelId)?.batch(containing: v.number) {
                hit.insert(b.depotCode + b.depotName)
            }
        }
        return "\(hit.count)/\(catalog.depots.count)"
    }
}

// MARK: - Trophy shelf

private struct TrophyShelf: View {
    let trophies: [OwnedVehicle]
    let sightings: [Sighting]
    @Environment(Router.self) private var router
    private let catalog = Fleet.catalog

    var body: some View {
        if trophies.isEmpty {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5, 5]))
                .foregroundStyle(Color.white.opacity(0.14))
                .frame(height: 180)
                .overlay(
                    VStack(spacing: 8) {
                        Image(systemName: "trophy")
                            .font(.system(size: 26, weight: .light))
                            .foregroundStyle(Palette.faint)
                        Mono("YOUR RAREST CATCHES LIVE HERE", size: 10.5, color: Palette.faint)
                    }
                )
        } else if trophies.count == 1 {
            trophy(trophies[0], big: true, tilt: -1.4)
                .frame(maxWidth: 280)
                .frame(maxWidth: .infinity)
        } else {
            HStack(alignment: .bottom, spacing: 11) {
                trophy(trophies[0], big: true, tilt: -1.4)
                    .frame(maxWidth: .infinity)
                VStack(spacing: 10) {
                    if trophies.count > 1 { trophy(trophies[1], big: false, tilt: 1.2) }
                    if trophies.count > 2 { trophy(trophies[2], big: false, tilt: -0.8) }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func trophy(_ v: OwnedVehicle, big: Bool, tilt: Double) -> some View {
        let model = catalog.model(id: v.modelId)
        let tier = model?.tier ?? .common
        let ink = tier == .gold ? Palette.goldInk : (tier == .common ? Palette.stickerSub : tier.color)
        return VStack(spacing: big ? 8 : 6) {
            Button {
                router.openVehicle(modelId: v.modelId, number: v.number)
            } label: {
                DieCut(number: v.number,
                       sticker: sightings.sticker(number: v.number, modelId: v.modelId),
                       photo: sightings.photo(number: v.number, modelId: v.modelId),
                       height: big ? 150 : 70, tagSize: big ? 15 : 11, maxPixel: big ? 900 : 420) {
                    Mono("/\(model?.fleet ?? 0)", size: big ? 10 : 8.5, weight: 700, spacing: 0, color: ink)
                }
            }
            .buttonStyle(StickerPressStyle(tilt: tilt))
            // The shelf ledge, with the model name engraved underneath.
            Capsule().fill(Palette.track).frame(height: 3)
            if big {
                Mono((model?.name ?? "").uppercased(), size: 9, color: Palette.faint).lineLimit(1)
            }
        }
    }
}

/// Stickers squish, flatten their tilt and give a soft haptic when pressed.
/// A ButtonStyle (not a drag gesture) so it never fights the scroll view.
struct StickerPressStyle: ButtonStyle {
    var tilt: Double = 0

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .rotationEffect(.degrees(configuration.isPressed ? 0 : tilt))
            .animation(.spring(response: 0.28, dampingFraction: 0.55), value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { _, down in
                if down { Haptics.shared.press() }
            }
    }
}

// MARK: - Badges

private struct BadgeShelf: View {
    let badges: [Achievement]
    @State private var showAll = false
    private static let collapsed = 6

    var body: some View {
        // Earned first, then whatever's closest to done.
        let sorted = badges.enumerated().sorted { a, b in
            if a.element.earned != b.element.earned { return a.element.earned }
            if a.element.fraction != b.element.fraction { return a.element.fraction > b.element.fraction }
            return a.offset < b.offset
        }.map(\.element)
        let shown = showAll ? sorted : Array(sorted.prefix(Self.collapsed))

        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                SectionLabel(text: "BADGES")
                Spacer()
                Mono("\(badges.filter(\.earned).count) OF \(badges.count) EARNED", size: 10.5, color: Palette.faint)
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 9), GridItem(.flexible())], spacing: 9) {
                ForEach(shown) { BadgeTile(badge: $0) }
            }
            if badges.count > Self.collapsed {
                Button {
                    Haptics.shared.tick()
                    withAnimation(.snappy) { showAll.toggle() }
                } label: {
                    Mono(showAll ? "SHOW FEWER" : "SHOW ALL \(badges.count)", size: 10.5, color: Palette.yellow)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct BadgeTile: View {
    let badge: Achievement

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(badge.earned ? Palette.yellow : Palette.dim)
                Spacer()
                if badge.earned {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Palette.yellow)
                } else {
                    Mono("\(badge.progress)/\(badge.goal)", size: 10, weight: 700, spacing: 0, color: Palette.sub)
                }
            }
            Text(badge.title)
                .font(TaborFont.grotesk(13.5, 600))
                .foregroundStyle(badge.earned ? Palette.ink : Palette.routeInk)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(badge.detail)
                .font(TaborFont.grotesk(11))
                .foregroundStyle(Palette.sub)
                .lineLimit(2, reservesSpace: true)
            ProgressBar(fraction: badge.fraction, color: badge.earned ? Palette.yellow : Palette.dim, height: 3)
        }
        .padding(12)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(badge.earned ? Palette.yellow.opacity(0.45) : Color.white.opacity(0.06)))
        .accessibilityElement(children: .combine)
        .accessibilityValue(badge.earned ? "Earned" : "\(badge.progress) of \(badge.goal)")
    }

    private var symbol: String {
        switch badge.kind {
        case .batch: "square.stack.3d.up.fill"
        case .legendary: "crown.fill"
        case .districts: "map.fill"
        case .tramDay: "tram.fill"
        case .lines: "signpost.right.and.left.fill"
        case .depot: "building.2.fill"
        }
    }
}

// MARK: - Stats strip

private struct StatsStrip: View {
    let items: [(String, String, Color)]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                VStack(spacing: 3) {
                    Text(item.0)
                        .font(TaborFont.mono(18, 700))
                        .foregroundStyle(item.2)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Mono(item.1, size: 8.5, color: Palette.dim)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .padding(.horizontal, 6)
                .overlay(alignment: .leading) {
                    if i > 0 { Rectangle().fill(Color.white.opacity(0.06)).frame(width: 1) }
                }
            }
        }
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.white.opacity(0.06)))
    }
}

// MARK: - Map

struct SpotMap: View {
    let sightings: [Sighting]
    let interactive: Bool
    private static let warsaw = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 52.2297, longitude: 21.0122),
        span: MKCoordinateSpan(latitudeDelta: 0.22, longitudeDelta: 0.22))

    var body: some View {
        let pins = sightings.filter { $0.latitude != nil && $0.longitude != nil }
        Map(initialPosition: pins.isEmpty ? .region(Self.warsaw) : .automatic,
            interactionModes: interactive ? .all : []) {
            ForEach(pins) { s in
                let tier = Fleet.catalog.model(id: s.modelId)?.tier ?? .common
                Annotation("", coordinate: CLLocationCoordinate2D(latitude: s.latitude!, longitude: s.longitude!)) {
                    ZStack {
                        Circle().fill(pinColor(tier).opacity(0.28)).frame(width: 22, height: 22).blur(radius: 4)
                        Circle().fill(pinColor(tier)).frame(width: 7, height: 7)
                            .overlay(Circle().stroke(Palette.bg.opacity(0.8), lineWidth: 2))
                    }
                }
                .annotationTitles(.hidden)
            }
        }
        .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll, showsTraffic: false))
        .environment(\.colorScheme, .dark)
    }

    private func pinColor(_ t: Tier) -> Color {
        t == .legendary || t == .rare || t == .vintage ? t.color : Palette.yellow
    }
}

// MARK: - Settings

struct SettingsSheet: View {
    @AppStorage(Haptics.enabledKey) private var haptics = true
    @AppStorage("saveToGallery") private var saveToGallery = true
    @AppStorage("geotag") private var geotag = true
    @AppStorage(DebugRecord.enabledKey) private var debugMode = false
    @State private var debugCount = DebugRecord.count
    @State private var exportURL: URL?
    @State private var exporting = false
    @State private var confirmDelete = false
    @State private var confirmWipe = false
    @AppStorage(FleetUpdater.enabledKey) private var fleetUpdates = true
    @State private var fleetStatus: String?
    @State private var checkingFleet = false
    @State private var backingUp = false
    @State private var importing = false
    @State private var backupMessage: String?
    @Query private var allSightings: [Sighting]
    @Query private var manual: [ManualAssignment]
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle("Haptics", isOn: $haptics)
                        .onChange(of: haptics) { _, on in if on { Haptics.shared.completed() } }
                    Toggle("Save catches to Photos", isOn: $saveToGallery)
                    Toggle("Geotag catches", isOn: $geotag)
                }
                Section {
                    Toggle("Debug mode", isOn: $debugMode)
                    if debugMode {
                        NavigationLink("Haptics lab") { HapticsLab() }
                    }
                    if debugMode || debugCount > 0 {
                        LabeledContent("Logged shots", value: "\(debugCount)")
                        Button(exporting ? "Zipping…" : "Share as ZIP") {
                            exporting = true
                            Task {
                                exportURL = await Task.detached { DebugRecord.exportZip() }.value
                                exporting = false
                            }
                        }
                        .disabled(debugCount == 0 || exporting)
                        Button("Delete debug data", role: .destructive) { confirmDelete = true }
                            .disabled(debugCount == 0)
                    }
                    if debugMode {
                        Button("Delete all catches", role: .destructive) { confirmWipe = true }
                            .disabled(allSightings.isEmpty)
                    }
                } header: {
                    Text("Debug")
                } footer: {
                    Text("Saves every shot — failed reads and retakes included — with what the OCR and sticker cutter saw. Also in Files › On My iPhone › TABOR › Debug.")
                }
                Section {
                    LabeledContent("iCloud sync", value: FileManager.default.ubiquityIdentityToken == nil ? "Off" : "On")
                    Button(backingUp ? "Packing…" : "Export catches") { exportBackup() }
                        .disabled(allSightings.isEmpty || backingUp)
                    Button("Import a backup…") { importing = true }
                        .disabled(backingUp)
                } header: {
                    Text("Backup")
                } footer: {
                    Text("Signed in to iCloud, your sightings sync to your other devices and come back after a reinstall. Photos and stickers stay on this phone — export a ZIP to keep those too. Importing only adds what's missing.")
                }
                Section {
                    if Fleet.catalog.models.isEmpty {
                        Text("Fleet data couldn't be loaded. Check for an update, or reinstall TABOR.")
                            .foregroundStyle(Palette.red)
                    }
                    LabeledContent("Vehicles", value: Fleet.catalog.totalFleet.grouped)
                    LabeledContent("Models", value: "\(Fleet.catalog.models.count)")
                    Toggle("Download fleet updates", isOn: $fleetUpdates)
                    Button(checkingFleet ? "Checking…" : "Check now") { checkFleet() }
                        .disabled(checkingFleet)
                } header: {
                    Text("Fleet data")
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        if let fleetStatus { Text(fleetStatus).foregroundStyle(Palette.yellow) }
                        Text(Fleet.catalog.source)
                        Text("New deliveries show up without an app update: TABOR checks GitHub for a fresher ZTM snapshot once a day.")
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .tint(Palette.yellow)
        .presentationDetents([.medium, .large])
        .onAppear { debugCount = DebugRecord.count }
        .sheet(item: $exportURL) { url in ShareSheet(items: [url]) }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.zip]) { result in
            if case .success(let url) = result { importBackup(url) }
        }
        .alert("Backup", isPresented: Binding(get: { backupMessage != nil }, set: { if !$0 { backupMessage = nil } })) {
            Button("OK") {}
        } message: {
            Text(backupMessage ?? "")
        }
        .confirmationDialog("Delete all \(allSightings.count) catches?", isPresented: $confirmWipe, titleVisibility: .visible) {
            Button("Delete everything in the book", role: .destructive) { wipeBook() }
        } message: {
            Text("Every sighting, photo, sticker and hand-picked model goes. Shots already saved to your Photos stay. This can't be undone.")
        }
        .confirmationDialog("Delete all debug data?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete \(debugCount) shots", role: .destructive) {
                DebugRecord.deleteAll()
                debugCount = 0
            }
        }
    }
}

/// Plays every haptic moment on demand, for tuning on a real phone.
struct HapticsLab: View {
    var body: some View {
        List {
            Section {
                ForEach(Haptics.shared.labMoments, id: \.name) { m in
                    Button(m.name, action: m.play)
                }
            } footer: {
                Text("Tap each one a few times. Tell Claude which feel wrong and what they remind you of — too buzzy, too weak, too long, late, like a phone ringing…")
            }
        }
        .navigationTitle("Haptics lab")
        .navigationBarTitleDisplayMode(.inline)
    }
}

extension SettingsSheet {
    /// Debug: start the book from scratch.
    func wipeBook() {
        try? context.delete(model: Sighting.self)
        try? context.delete(model: ManualAssignment.self)
        try? context.save()
        PhotoStore.deleteAll()
        Haptics.shared.nope()
    }
}

extension SettingsSheet {
    func exportBackup() {
        backingUp = true
        let manifest = BackupService.manifest(sightings: allSightings, manual: manual)
        Task {
            let result = await Task.detached { Result { try BackupService.export(manifest) } }.value
            backingUp = false
            switch result {
            case .success(let url): exportURL = url
            case .failure(let error): backupMessage = "Couldn't export: \(error.localizedDescription)"
            }
        }
    }

    func importBackup(_ url: URL) {
        backingUp = true
        Task {
            // Unzipping and writing photos happens off the main thread; inserting records on it.
            let result = await Task.detached { Result { try BackupService.read(url) } }.value
            backingUp = false
            do {
                let added = try context.restore(try result.get(), into: allSightings, manual: manual)
                Haptics.shared.completed()
                backupMessage = added == 0 ? "Everything in that backup is already in your book."
                    : "Added \(added) sighting\(added == 1 ? "" : "s") to your book."
            } catch {
                backupMessage = "Couldn't import: \(error.localizedDescription)"
            }
        }
    }

    func checkFleet() {
        checkingFleet = true
        Task {
            let outcome = await FleetUpdater.check()
            checkingFleet = false
            switch outcome {
            case .downloaded(let fetched): fleetStatus = "Snapshot from \(fetched) downloaded — it's used next time you open TABOR."
            case .upToDate: fleetStatus = "You have the latest fleet data."
            case .failed(let why): fleetStatus = "Couldn't check: \(why)"
            }
        }
    }
}

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}

/// UIKit share sheet, for files that only exist once a button is tapped.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
