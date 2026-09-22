import MapKit
import SwiftData
import SwiftUI

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
    @Query private var allSightings: [Sighting]
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
                Section("Fleet data") {
                    LabeledContent("Vehicles", value: Fleet.catalog.totalFleet.grouped)
                    LabeledContent("Models", value: "\(Fleet.catalog.models.count)")
                    Text(Fleet.catalog.source)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
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
