import CoreLocation
import PhotosUI
import SwiftData
import SwiftUI

/// Everything the reveal screen needs about a fresh catch.
struct CatchDraft: Identifiable {
    let id = UUID()
    var photo: Data
    var number: Int?
    var modelId: String?
    var line: String?
    /// True when the user picked the model themselves — saved as a manual assignment.
    var modelPickedByHand = false
    /// Now for camera shots; the photo's own EXIF date for imports.
    var date = Date()
    /// Camera shots get saved to Photos; imports already live there.
    var fromCamera: Bool
    var geotag: Task<Geotag?, Never>?
    /// Die-cut PNG, generated in the background while the reveal plays.
    var sticker: Task<Data?, Never>?
}

struct CatchView: View {
    @Query private var sightings: [Sighting]
    @Query private var manual: [ManualAssignment]
    @AppStorage("saveToGallery") private var saveToGallery = true
    @AppStorage("geotag") private var geotag = true

    @State private var camera = CameraModel()
    @State private var mode: CatchMode = .auto
    @State private var draft: CatchDraft?
    @State private var flash = false
    @State private var capturing = false
    @State private var pickerItem: PhotosPickerItem?
    @State private var focusPoint: CGPoint?
    @State private var shutterDown = false
    @Environment(\.scenePhase) private var scenePhase

    private let catalog = Fleet.catalog

    var body: some View {
        let stats = sightings.stats
        let match = camera.reading.map { catalog.match(number: $0, kind: mode.kind, manual: manual.map) }

        VStack(spacing: 0) {
            ZStack {
                viewfinder
                LinearGradient(stops: [
                    .init(color: Color(hex: 0x060709, opacity: 0.78), location: 0),
                    .init(color: Color(hex: 0x060709, opacity: 0.05), location: 0.22),
                    .init(color: .clear, location: 0.45),
                    .init(color: Color(hex: 0x060709, opacity: 0.6), location: 1),
                ], startPoint: .top, endPoint: .bottom)
                .allowsHitTesting(false)

                VStack(spacing: 0) {
                    HStack {
                        Mono("SPOTTING", size: 12, spacing: 0.16, color: .white.opacity(0.75))
                        Spacer()
                        HStack(spacing: 6) {
                            ForEach(CatchMode.allCases, id: \.self) { m in
                                Button {
                                    guard m != mode else { return }
                                    Haptics.shared.tick()
                                    withAnimation(.snappy) { mode = m }
                                    camera.mode = m
                                } label: {
                                    Mono(m.rawValue, size: 12, weight: m == mode ? 600 : 400, spacing: 0.1,
                                         color: m == mode ? Palette.bg : .white.opacity(0.8))
                                        .padding(.vertical, 6)
                                        .padding(.horizontal, 11)
                                        .background {
                                            if m == mode { Capsule().fill(Palette.yellow) }
                                            else { Capsule().fill(.ultraThinMaterial).overlay(Capsule().fill(Color(hex: 0x0A0C0E, opacity: 0.4))) }
                                        }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(.top, 10)
                    .padding(.horizontal, 22)

                    Mono(hint(match), size: 11, spacing: 0.12, color: .white.opacity(0.7))
                        .padding(.vertical, 5)
                        .padding(.horizontal, 10)
                        .background(.ultraThinMaterial.opacity(0.6), in: Capsule())
                        .padding(.top, 12)
                        .contentTransition(.opacity)
                        .animation(.easeInOut, value: hint(match))

                    ViewfinderBrackets(locked: camera.reading != nil)
                        .opacity(camera.status == .running ? 1 : 0)
                        .frame(height: 210)
                        .padding(.horizontal, 20)
                        .padding(.top, 60)
                        .allowsHitTesting(false)

                    Spacer()

                    readChip(match: match, stats: stats)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 18)
                }

                if let p = focusPoint {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Palette.yellow, lineWidth: 1.5)
                        .frame(width: 64, height: 64)
                        .position(p)
                        .transition(.scale(scale: 1.4).combined(with: .opacity))
                        .allowsHitTesting(false)
                }

                Color.white.opacity(flash ? 0.85 : 0).allowsHitTesting(false)
            }
            .clipped()

            controls(stats: stats)
        }
        .background(Palette.bg)
        .task {
            await camera.start()
            // Ask for location now, while spotting — never in the middle of a reveal.
            if geotag { LocationService.shared.requestPermission() }
        }
        .onDisappear { camera.stop() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, draft == nil { Task { await camera.start() } }
            if phase == .background { camera.stop() }
        }
        .onChange(of: camera.reading) { _, n in
            guard let n else { return }
            let m = catalog.match(number: n, kind: mode.kind, manual: manual.map)
            let isNew = m.suggested.map { stats.vehicle(number: n, modelId: $0.id) == nil } ?? false
            Haptics.shared.numberLocked(isNew: isNew)
        }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) { await begin(with: data, live: nil, fromCamera: false) }
                pickerItem = nil
            }
        }
        .fullScreenCover(item: $draft, onDismiss: {
            camera.resetReading()
            Task { await camera.start() }
        }) { d in
            RevealView(draft: d)
        }
    }

    // MARK: - Pieces

    @ViewBuilder private var viewfinder: some View {
        switch camera.status {
        case .running:
            CameraPreview(session: camera.session) { devicePoint in
                camera.focus(at: devicePoint)
            }
            .simultaneousGesture(SpatialTapGesture().onEnded { e in
                Haptics.shared.tick()
                withAnimation(.spring(response: 0.3)) { focusPoint = e.location }
                Task {
                    try? await Task.sleep(for: .seconds(0.9))
                    withAnimation(.easeOut) { focusPoint = nil }
                }
            })
        case .idle:
            Color.black
        case .denied, .unavailable:
            ZStack {
                Color(hex: 0x0E1013)
                VStack(spacing: 14) {
                    Image(systemName: camera.status == .denied ? "camera.badge.ellipsis" : "camera.metering.unknown")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(Palette.faint)
                    Mono(camera.status == .denied ? "CAMERA ACCESS IS OFF" : "NO CAMERA ON THIS DEVICE",
                         size: 11, color: Palette.sub)
                    if camera.status == .denied {
                        Button("Open Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                        }
                        .font(TaborFont.grotesk(14, 600))
                        .tint(Palette.yellow)
                    }
                    PhotosPicker(selection: $pickerItem, matching: .images) {
                        Mono("IMPORT A PHOTO INSTEAD", size: 11, weight: 600, color: Palette.bg)
                            .padding(.vertical, 9)
                            .padding(.horizontal, 14)
                            .background(Palette.yellow, in: Capsule())
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func readChip(match: ModelMatch?, stats: CollectionStats) -> some View {
        if let n = camera.reading {
            let model = match?.suggested
            let isNew = model.map { stats.vehicle(number: n, modelId: $0.id) == nil } ?? true
            VStack(alignment: .leading, spacing: 8) {
                Button { Task { await shoot() } } label: {
                HStack(spacing: 9) {
                    Mono("READ", size: 9.5, weight: 700, spacing: 0.14, color: Palette.bg)
                        .phaseAnimator([0.55, 1]) { v, p in v.opacity(p) } animation: { _ in .easeInOut(duration: 0.9) }
                    Text(String(n))
                        .font(TaborFont.mono(18, 700))
                        .em(0.04, size: 18)
                        .contentTransition(.numericText())
                    Rectangle().fill(Palette.bg.opacity(0.25)).frame(width: 1, height: 16)
                    Text(model?.name ?? "Unknown model")
                        .font(TaborFont.grotesk(12.5, 600))
                        .lineLimit(1)
                    if model != nil, isNew {
                        Mono("NEW", size: 9.5, weight: 700, spacing: 0.1, color: Palette.yellow)
                            .padding(.vertical, 3)
                            .padding(.horizontal, 6)
                            .background(Palette.bg, in: RoundedRectangle(cornerRadius: 4))
                    }
                }
                .foregroundStyle(Palette.bg)
                .padding(.vertical, 8)
                .padding(.horizontal, 11)
                .background(Palette.yellow.opacity(0.94), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .shadow(color: .black.opacity(0.45), radius: 11, y: 8)
                }
                .buttonStyle(StickerPressStyle())

                Mono(chipCaption(match), size: 10, color: .white.opacity(0.6))
                    .padding(.leading, 4)
            }
            .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity),
                                    removal: .opacity))
            .id(n)
            .animation(.spring(response: 0.45, dampingFraction: 0.72), value: n)
        }
    }

    private func controls(stats: CollectionStats) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                toggleChip("SAVE TO GALLERY", on: $saveToGallery)
                toggleChip("GEOTAG", on: $geotag)
            }
            .padding(.top, 12)

            HStack {
                PhotosPicker(selection: $pickerItem, matching: .images) {
                    VStack(spacing: 1) {
                        Text(stats.caught.grouped)
                            .font(TaborFont.mono(11, 700))
                            .foregroundStyle(Palette.ink)
                            .contentTransition(.numericText())
                        Image(systemName: "photo.on.rectangle")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Palette.faint)
                    }
                    .frame(width: 46, height: 46)
                    .background(Palette.thumb, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(Color.white.opacity(0.18)))
                }
                .accessibilityLabel("Import a photo")

                Spacer()

                // Shutter
                Button {
                    Task { await shoot() }
                } label: {
                    ZStack {
                        Circle().stroke(camera.reading != nil ? Palette.yellow : .white.opacity(0.92), lineWidth: 4)
                            .frame(width: 74, height: 74)
                        Circle().fill(Palette.red)
                            .frame(width: 56, height: 56)
                            .scaleEffect(shutterDown ? 0.86 : 1)
                    }
                    .animation(.spring(response: 0.25, dampingFraction: 0.5), value: shutterDown)
                    .animation(.easeInOut(duration: 0.25), value: camera.reading != nil)
                }
                .buttonStyle(ShutterStyle(pressed: $shutterDown))
                .disabled(capturing || camera.status != .running)
                .accessibilityLabel("Catch")

                Spacer()

                Button {
                    Haptics.shared.tick()
                    camera.toggleTorch()
                } label: {
                    Image(systemName: camera.torchOn ? "flashlight.on.fill" : "flashlight.off.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(camera.torchOn ? Palette.yellow : .white.opacity(0.65))
                        .frame(width: 46, height: 46)
                        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .opacity(camera.hasTorch ? 1 : 0.35)
                .disabled(!camera.hasTorch)
                .accessibilityLabel("Torch")
            }
            .padding(.horizontal, 34)
            .padding(.top, 14)
            .padding(.bottom, 10)
        }
        .background(Palette.bg)
    }

    private func toggleChip(_ label: String, on: Binding<Bool>) -> some View {
        Button {
            Haptics.shared.tick()
            withAnimation(.snappy) { on.wrappedValue.toggle() }
        } label: {
            HStack(spacing: 5) {
                if on.wrappedValue {
                    Image(systemName: "checkmark").font(.system(size: 9, weight: .heavy))
                        .transition(.scale.combined(with: .opacity))
                }
                Mono(label, size: 10.5, weight: on.wrappedValue ? 600 : 400,
                     color: on.wrappedValue ? Palette.green : Palette.dim)
            }
            .foregroundStyle(Palette.green)
                .padding(.vertical, 5)
                .padding(.horizontal, 10)
                .background(on.wrappedValue ? Palette.green.opacity(0.12) : .clear, in: Capsule())
                .overlay(Capsule().stroke(on.wrappedValue ? Palette.green.opacity(0.3) : Color.white.opacity(0.12)))
        }
        .buttonStyle(.plain)
    }

    private func hint(_ match: ModelMatch?) -> String {
        switch camera.status {
        case .running: break
        case .idle: return "WAKING THE CAMERA"
        default: return "IMPORT A SHOT TO CATCH IT"
        }
        guard camera.reading != nil else { return "GET THE WHOLE VEHICLE IN FRAME" }
        return "GOT IT — HIT THE SHUTTER"
    }

    private func chipCaption(_ match: ModelMatch?) -> String {
        switch match {
        case .ambiguous(let ms): "ALSO A \(ms.dropFirst().first?.kind.rawValue ?? "") NUMBER · FIX IT AFTER THE SHOT"
        case .unknown, nil: "NOT IN THE ZTM DATABASE · PICK THE MODEL AFTER"
        case .certain(let m):
            [m.kind.rawValue, m.batch(containing: camera.reading ?? 0)?.year.map { "BUILT \($0)" }, "TAP TO CATCH"]
                .compactMap { $0 }.joined(separator: " · ")
        }
    }

    // MARK: - Actions

    private func shoot() async {
        capturing = true
        defer { capturing = false }
        Haptics.shared.shutter()
        withAnimation(.easeOut(duration: 0.06)) { flash = true }
        let live = camera.reading
        let data = await camera.capture()
        withAnimation(.easeOut(duration: 0.35)) { flash = false }
        guard let data else { Haptics.shared.nope(); return }
        await begin(with: data, live: live, fromCamera: true)
    }

    private func begin(with data: Data, live: Int?, fromCamera: Bool) async {
        // Start cutting the sticker immediately; it finishes while the reveal builds up.
        let sticker = Task.detached(priority: .userInitiated) {
            StickerMaker.sticker(from: data).flatMap(StickerMaker.pngData)
        }
        var number = live
        if number == nil { number = await TextReader.bestNumber(in: data, mode: mode) }
        var d = CatchDraft(photo: data, number: number, fromCamera: fromCamera, sticker: sticker)
        if let n = number { d.modelId = catalog.match(number: n, kind: mode.kind, manual: manual.map).suggested?.id }
        if fromCamera {
            if geotag { d.geotag = Task { await LocationService.shared.geotag() } }
        } else {
            let meta = PhotoStore.metadata(data)
            if let date = meta.date { d.date = date }
            if geotag, let lat = meta.latitude, let lon = meta.longitude {
                d.geotag = Task { await LocationService.shared.geotag(CLLocation(latitude: lat, longitude: lon)) }
            }
        }
        camera.stop()
        draft = d
    }
}

/// Reports press state so the shutter can squish the moment a finger lands.
private struct ShutterStyle: ButtonStyle {
    @Binding var pressed: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { _, down in pressed = down }
    }
}

/// Corner brackets + thirds, tightening and turning yellow once a number locks.
struct ViewfinderBrackets: View {
    var locked: Bool

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let inset: CGFloat = locked ? 8 : 0
            let color: Color = locked ? Palette.yellow : .white.opacity(0.85)
            ZStack {
                ForEach(0..<4, id: \.self) { i in
                    Corner()
                        .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .frame(width: 22, height: 22)
                        .rotationEffect(.degrees(Double(i) * 90))
                        .position(x: i == 0 || i == 3 ? 11 + inset : w - 11 - inset,
                                  y: i < 2 ? 11 + inset : h - 11 - inset)
                }
                ForEach([1.0 / 3, 2.0 / 3], id: \.self) { f in
                    Rectangle().fill(.white.opacity(locked ? 0 : 0.14))
                        .frame(width: 1, height: h * 0.84)
                        .position(x: w * f, y: h / 2)
                }
            }
            .animation(.spring(response: 0.4, dampingFraction: 0.6), value: locked)
        }
    }

    private struct Corner: Shape {
        func path(in r: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: r.minX, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
            return p
        }
    }
}
