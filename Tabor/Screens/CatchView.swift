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
    /// Screen-sized copy of the photo; decoding the full-res shot on every frame of the
    /// reveal's animations would stutter on device.
    var preview: UIImage?
    /// Debug-mode record for this shot (nil when debug mode is off).
    var debug: DebugRecord?
}

struct CatchView: View {
    @Query private var sightings: [Sighting]
    @Query private var manual: [ManualAssignment]
    @AppStorage("saveToGallery") private var saveToGallery = true
    @AppStorage("geotag") private var geotag = true
    @AppStorage(DebugRecord.enabledKey) private var debugMode = false

    private let camera = CameraModel.shared
    @State private var mode: CatchMode = .auto
    @State private var draft: CatchDraft?
    @State private var flash = false
    @State private var capturing = false
    @State private var pickerItem: PhotosPickerItem?
    @State private var focusPoint: CGPoint?
    @State private var shutterDown = false
    /// Sticking a catch jumps to the Book tab while the reveal is still up; the cover's
    /// dismissal must not wake the camera behind a screen that's gone.
    @State private var visible = false
    /// The viewfinder and the brackets inside it (screen coordinates): shots are cropped to
    /// the brackets, so what you framed is what gets saved.
    @State private var finderFrame: CGRect = .zero
    @State private var bracketGlobal: CGRect = .zero
    /// Brief confirmation in the hint pill ("GEOTAG OFF").
    @State private var toast: String?
    @State private var toastTask: Task<Void, Never>?
    @Namespace private var modePill
    /// Zoom when the current pinch started.
    @State private var pinchStart: CGFloat?
    @Environment(\.scenePhase) private var scenePhase

    private let catalog = Fleet.catalog

    var body: some View {
        let stats = sightings.stats
        let match = camera.reading.map { catalog.match(number: $0, preferring: mode.kind, manual: manual.map) }

        ZStack {
            // Full bleed: the camera runs up under the Dynamic Island, like the Camera app.
            viewfinder
                .overlay {
                    if let p = focusPoint {
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Palette.yellow, lineWidth: 1.5)
                            .frame(width: 64, height: 64)
                            .position(p)
                            .transition(.scale(scale: 1.4).combined(with: .opacity))
                            .allowsHitTesting(false)
                    }
                }
                .clipped()
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { finderFrame = $0 }
                .ignoresSafeArea(edges: .top)

            LinearGradient(stops: [
                .init(color: Color(hex: 0x060709, opacity: 0.8), location: 0),
                .init(color: Color(hex: 0x060709, opacity: 0.05), location: 0.24),
                .init(color: .clear, location: 0.5),
                .init(color: Color(hex: 0x060709, opacity: 0.35), location: 0.72),
                .init(color: Color(hex: 0x060709, opacity: 0.88), location: 1),
            ], startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea(edges: .top)
            .allowsHitTesting(false)

            VStack(spacing: 0) {
                topBar
                    .padding(.top, 6)
                    .padding(.horizontal, 20)

                hintPill(match)
                    .padding(.top, 14)

                Spacer(minLength: 12)

                // A 3:2 landscape frame, like a photo: the shot is cropped to it.
                ViewfinderBrackets(locked: camera.reading != nil)
                    .opacity(camera.status == .running ? 1 : 0)
                    .aspectRatio(3 / 2, contentMode: .fit)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { bracketGlobal = $0 }
                    .padding(.horizontal, 20)
                    .allowsHitTesting(false)

                Spacer(minLength: 12)

                // Fixed slot, so the brackets don't jump when a number locks.
                readChip(match: match, stats: stats)
                    .frame(maxWidth: .infinity, maxHeight: 78, alignment: .bottomLeading)
                    .padding(.horizontal, 20)

                controls
                    .padding(.top, 16)
                    .padding(.bottom, 16)
            }

            Color.white.opacity(flash ? 0.85 : 0)
                .ignoresSafeArea(edges: .top)
                .allowsHitTesting(false)
        }
        .background(Color.black.ignoresSafeArea())
        .onAppear { visible = true }
        .task {
            camera.mode = mode
            await camera.start()
            // Ask for location now, while spotting — never in the middle of a reveal.
            if geotag { LocationService.shared.requestPermission() }
        }
        .onDisappear {
            visible = false
            camera.stop()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, draft == nil, visible { Task { await camera.start() } }
            if phase == .background { camera.stop() }
        }
        .onChange(of: camera.reading) { _, n in
            guard let n else { return }
            let m = catalog.match(number: n, preferring: mode.kind, manual: manual.map)
            let isNew = m.suggested.map { stats.vehicle(number: n, modelId: $0.id) == nil } ?? false
            Haptics.shared.numberLocked(isNew: isNew)
        }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task {
                capturing = true
                defer { capturing = false }
                if let data = try? await item.loadTransferable(type: Data.self) {
                    await begin(with: data, live: nil, fromCamera: false)
                } else {
                    Haptics.shared.nope()
                    DebugRecord.begin(source: "import", mode: mode)?.update { $0.error = "couldn't load the picked photo" }
                }
                pickerItem = nil
            }
        }
        .fullScreenCover(item: $draft, onDismiss: {
            camera.resetReading()
            if visible { Task { await camera.start() } }
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
                withAnimation(.spring(response: 0.3)) { focusPoint = e.location }
                Task {
                    try? await Task.sleep(for: .seconds(0.9))
                    withAnimation(.easeOut) { focusPoint = nil }
                }
            })
            .simultaneousGesture(MagnifyGesture()
                .onChanged { v in
                    let start = pinchStart ?? camera.zoom
                    if pinchStart == nil { pinchStart = start }
                    let before = camera.zoom
                    camera.setZoom(start * v.magnification, smooth: false)
                    // Click as the zoom crosses onto another lens.
                    if camera.zoomStops.contains(where: { (before - $0) * (camera.zoom - $0) < 0 }) { Haptics.shared.tick() }
                }
                .onEnded { _ in pinchStart = nil })
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

    private var topBar: some View {
        HStack(spacing: 8) {
            Mono("SPOTTING", size: 12, spacing: 0.16, color: .white.opacity(0.8))
            if debugMode {
                Mono("DEBUG", size: 9.5, weight: 700, spacing: 0.1, color: .white)
                    .padding(.vertical, 3)
                    .padding(.horizontal, 6)
                    .background(Palette.red, in: RoundedRectangle(cornerRadius: 4))
            }
            Spacer()
            // One segmented control with a highlight that slides between modes.
            HStack(spacing: 0) {
                ForEach(CatchMode.allCases, id: \.self) { m in
                    let on = m == mode
                    Button {
                        guard !on else { return }
                        Haptics.shared.tick()
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) { mode = m }
                        camera.mode = m
                    } label: {
                        Mono(m.rawValue, size: 11.5, weight: 600, spacing: 0.1,
                             color: on ? Palette.bg : .white.opacity(0.72))
                            .padding(.vertical, 7)
                            .padding(.horizontal, 12)
                            .background {
                                if on { Capsule().fill(Palette.yellow).matchedGeometryEffect(id: "mode", in: modePill) }
                            }
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .padding(3)
            .glass(Capsule())
        }
    }

    private func hintPill(_ match: ModelMatch?) -> some View {
        let locked = camera.reading != nil && toast == nil
        let text = toast ?? hint(match)
        return HStack(spacing: 7) {
            Circle()
                .fill(locked ? Palette.yellow : .white)
                .frame(width: 5, height: 5)
                .shadow(color: locked ? Palette.yellow : .clear, radius: 4)
                .phaseAnimator([0.35, 1]) { v, p in v.opacity(locked ? 1 : p) } animation: { _ in .easeInOut(duration: 0.8) }
            Text(text)
                .font(TaborFont.mono(10.5, 500))
                .em(0.12, size: 10.5)
                .foregroundStyle(.white.opacity(0.85))
                .contentTransition(.opacity)
        }
        .padding(.vertical, 6)
        .padding(.leading, 10)
        .padding(.trailing, 12)
        .glass(Capsule())
        .animation(.easeInOut(duration: 0.2), value: text)
    }

    private var controls: some View {
        VStack(spacing: 16) {
            HStack {
                settingToggle($geotag, name: "GEOTAG", on: "location.fill", off: "location.slash.fill")
                Spacer()
                if camera.status == .running, camera.zoomStops.count > 1 { zoomBar }
                Spacer()
                settingToggle($saveToGallery, name: "SAVE TO PHOTOS", on: "photo.badge.arrow.down.fill", off: "photo.badge.arrow.down")
            }

            HStack {
                PhotosPicker(selection: $pickerItem, matching: .images) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: 50, height: 50)
                        .glass(Circle())
                }
                .buttonStyle(StickerPressStyle())
                .disabled(capturing)
                .accessibilityLabel("Import a photo")

                Spacer()

                // Shutter
                Button {
                    Task { await shoot() }
                } label: {
                    let locked = camera.reading != nil
                    ZStack {
                        Circle().stroke(locked ? Palette.yellow : .white.opacity(0.92), lineWidth: 4)
                            .frame(width: 76, height: 76)
                            .shadow(color: Palette.yellow.opacity(locked ? 0.55 : 0), radius: 12)
                        Circle().fill(Palette.red)
                            .frame(width: 60, height: 60)
                            .scaleEffect(shutterDown ? 0.86 : 1)
                    }
                    .animation(.spring(response: 0.25, dampingFraction: 0.5), value: shutterDown)
                    .animation(.easeInOut(duration: 0.25), value: locked)
                }
                .buttonStyle(ShutterStyle(pressed: $shutterDown))
                .disabled(capturing || camera.status != .running)
                .opacity(camera.status == .running ? 1 : 0.4)
                .accessibilityLabel("Catch")

                Spacer()

                Button {
                    Haptics.shared.tick()
                    camera.toggleTorch()
                } label: {
                    Image(systemName: camera.torchOn ? "flashlight.on.fill" : "flashlight.off.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(camera.torchOn ? Palette.bg : .white.opacity(0.85))
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 50, height: 50)
                        .background(Palette.yellow.opacity(camera.torchOn ? 1 : 0), in: Circle())
                        .glass(Circle())
                }
                .buttonStyle(.plain)
                .opacity(camera.hasTorch ? 1 : 0.35)
                .disabled(!camera.hasTorch)
                .accessibilityLabel("Torch")
            }
        }
        .padding(.horizontal, 28)
    }

    /// One button per lens, like the Camera app: the active one shows the exact zoom.
    private var zoomBar: some View {
        let stops = camera.zoomStops
        let active = stops.last { camera.zoom >= $0 - 0.05 } ?? stops.first!
        return HStack(spacing: 8) {
            ForEach(stops, id: \.self) { s in
                let on = s == active
                Button {
                    guard abs(camera.zoom - s) > 0.01 else { return }
                    Haptics.shared.tick()
                    camera.setZoom(s, smooth: true)
                } label: {
                    Text(on ? Self.zoomLabel(camera.zoom) + "×" : Self.zoomLabel(s))
                        .font(TaborFont.mono(on ? 12 : 11, on ? 700 : 500))
                        .foregroundStyle(on ? Palette.bg : .white.opacity(0.8))
                        .frame(minWidth: on ? 44 : 34, minHeight: on ? 34 : 30)
                        .padding(.horizontal, on ? 4 : 0)
                        .background(on ? Palette.yellow : Color.clear, in: Capsule())
                        .contentTransition(.numericText())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Zoom \(Self.zoomLabel(s)) times")
            }
        }
        .padding(3)
        .glass(Capsule())
        .animation(.snappy(duration: 0.2), value: active)
    }

    /// "0.5", "1", "2.4", "5".
    static func zoomLabel(_ z: CGFloat) -> String {
        let r = (z * 10).rounded() / 10
        return r == r.rounded() ? String(Int(r)) : String(format: "%.1f", r)
    }

    /// Icon toggle for a capture setting; the hint pill confirms which way it went.
    private func settingToggle(_ value: Binding<Bool>, name: String, on: String, off: String) -> some View {
        let isOn = value.wrappedValue
        return Button {
            Haptics.shared.tick()
            value.wrappedValue.toggle()
            showToast("\(name) \(value.wrappedValue ? "ON" : "OFF")")
        } label: {
            Image(systemName: isOn ? on : off)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isOn ? Palette.green : .white.opacity(0.5))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 36, height: 36)
                .glass(Circle())
                .overlay(Circle().stroke(Palette.green.opacity(isOn ? 0.35 : 0)))
                .frame(width: 50)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name.capitalized)
        .accessibilityValue(isOn ? "On" : "Off")
    }

    private func showToast(_ text: String) {
        toastTask?.cancel()
        toast = text
        toastTask = Task {
            try? await Task.sleep(for: .seconds(1.4))
            guard !Task.isCancelled else { return }
            toast = nil
        }
    }

    private func hint(_ match: ModelMatch?) -> String {
        // The full-res read (and tile pass) can take a second or two on device.
        if capturing { return "READING THE NUMBER…" }
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
        case .ambiguous(let ms): "ALSO A \(ms.dropFirst().first?.name.uppercased() ?? "") · FIX IT AFTER THE SHOT"
        case .unknown, nil: "NOT IN THE ZTM DATABASE · PICK THE MODEL AFTER"
        case .certain(let m) where mode.kind != nil && m.kind != mode.kind:
            "A \(m.kind.rawValue) NUMBER · YOU'RE IN \(mode.rawValue) MODE"
        case .certain(let m):
            [m.vintage ? "VINTAGE" : nil, m.kind.rawValue, m.batch(containing: camera.reading ?? 0)?.year.map { "BUILT \($0)" }, "TAP TO CATCH"]
                .compactMap { $0 }.joined(separator: " · ")
        }
    }

    // MARK: - Actions

    private func shoot() async {
        guard !capturing else { return }
        capturing = true
        defer { capturing = false }
        Haptics.shared.shutter()
        withAnimation(.easeOut(duration: 0.06)) { flash = true }
        let live = camera.reading
        let frame = camera.lastFrame
        let data = await camera.capture()
        withAnimation(.easeOut(duration: 0.35)) { flash = false }
        let record = DebugRecord.begin(source: "camera", mode: mode)
        let angle = Double(camera.captureAngle), torch = camera.torchOn
        record?.update {
            $0.liveReading = live
            $0.liveFrame = DebugRecord.obs(frame)
            $0.captureAngle = angle
            $0.torch = torch
        }
        guard var data else {
            let why = camera.lastCaptureError ?? "unknown"
            record?.update { $0.error = "capture failed: \(why)" }
            Haptics.shared.nope()
            return
        }
        // Held upright: keep only what's inside the brackets (plus a little breathing room).
        // Held sideways the whole landscape frame is already what you meant.
        if angle == 90, bracketGlobal.width > 0, finderFrame.width > 0 {
            let size = finderFrame.size
            let brackets = bracketGlobal.offsetBy(dx: -finderFrame.minX, dy: -finderFrame.minY)
            let frame = brackets.insetBy(dx: -brackets.width * 0.04, dy: -brackets.height * 0.04)
            let full = data
            if let cropped = await Task.detached(priority: .userInitiated, operation: {
                PhotoStore.crop(full, viewSize: size, frame: frame)
            }).value {
                data = cropped
                record?.attach(original: full)
                record?.update { $0.crop = "brackets \(frame.integral) in \(size.width)×\(size.height) viewfinder" }
            }
        }
        await begin(with: data, live: live, fromCamera: true, record: record)
    }

    private func begin(with data: Data, live: Int?, fromCamera: Bool, record: DebugRecord? = nil) async {
        let record = record ?? DebugRecord.begin(source: fromCamera ? "camera" : "import", mode: mode)
        record?.attach(photo: data)
        // Start cutting the sticker immediately; it finishes while the reveal builds up.
        let sticker = Task.detached(priority: .userInitiated) {
            let start = Date()
            let result = StickerMaker.make(from: data)
            let png = (try? result.get()).flatMap(StickerMaker.pngData)
            if let record {
                let ms = Int(Date().timeIntervalSince(start) * 1000)
                let failure: String? = switch result {
                case .failure(let f): f.description
                case .success: png == nil ? "PNG encoding failed" : nil
                }
                record.update { $0.sticker = .init(ok: png != nil, durationMs: ms, failure: failure) }
                if let png { record.attach(sticker: png) }
            }
            return png
        }
        var number = live
        if number == nil {
            let report = await TextReader.read(data, mode: mode)
            number = report.number
            record?.update { $0.ocr = DebugRecord.ocr(report) }
        } else if let record {
            // Live lock skipped the still read; run it anyway in the background to compare.
            let mode = mode
            Task.detached(priority: .utility) {
                let report = await TextReader.read(data, mode: mode)
                record.update { $0.stillCheck = DebugRecord.ocr(report) }
            }
        }
        let preview = await Task.detached(priority: .userInitiated) {
            PhotoStore.downsample(data, maxPixel: 900).map(UIImage.init(cgImage:))
        }.value
        var d = CatchDraft(photo: data, number: number, fromCamera: fromCamera, sticker: sticker, preview: preview,
                           debug: record)
        if let n = number {
            let match = catalog.match(number: n, preferring: mode.kind, manual: manual.map)
            d.modelId = match.suggested?.id
            let described = DebugRecord.describe(match), suggested = d.modelId
            record?.update {
                $0.match = described
                $0.suggestedModel = suggested
            }
        }
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

extension View {
    /// Frosted dark glass for controls floating over the live camera.
    func glass<S: Shape>(_ shape: S) -> some View {
        background(.ultraThinMaterial, in: shape)
            .background(Color(hex: 0x0A0C0E, opacity: 0.35), in: shape)
            .overlay(shape.stroke(Color.white.opacity(0.1), lineWidth: 1))
            .environment(\.colorScheme, .dark)
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
