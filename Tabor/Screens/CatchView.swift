import AVKit
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
    /// The line the live feed filled in; re-filled after a correction unless you changed it.
    var autoLine: String?
    /// Models that share the number when nothing could tell them apart: the reveal asks which
    /// one it is instead of guessing (#66). Picking one from here isn't a manual assignment.
    var choices: [VehicleModel] = []
    /// True when the user picked the model themselves — saved as a manual assignment.
    var modelPickedByHand = false
    /// Now for camera shots; the photo's own EXIF date for imports.
    var date = Date()
    /// Camera shots get saved to Photos; imports already live there.
    var fromCamera: Bool
    var geotag: Task<Geotag?, Never>?
    /// Die-cut sticker, generated in the background while the reveal plays.
    var sticker: Task<StickerCut?, Never>?
    /// Screen-sized copy of the photo; decoding the full-res shot on every frame of the
    /// reveal's animations would stutter on device.
    var preview: UIImage?
    /// Debug-mode record for this shot (nil when debug mode is off).
    var debug: DebugRecord?
    /// A coupled tram's other car, added as a catch of its own when this one is stuck.
    var partner: Int?
    /// Numbers to offer for the other car, likeliest first.
    var partnerSuggestions: [CoupledSet.Suggestion] = []
    /// Live vehicles around you at the shutter (fresh camera shots only).
    var nearby: [NearbyVehicle] = []
    /// Every number read in the photo, best first.
    var photoNumbers: Task<[Int], Never>?
    /// The whole read of the photo: where each number is written, for other vehicles in it.
    var photoRead: Task<TextReader.Report, Never>?
    /// Other vehicles read in the photo, offered on the reveal (`AlsoInShot`).
    var alsoInShot: [AlsoInShot.Vehicle] = []
    /// Numbers of those you added: each becomes a catch of its own.
    var alsoAdded: [Int] = []
    /// The camera's mode at the shutter: a works car's code is only asked for outside BUS.
    var mode: CatchMode = .auto
}

struct CatchView: View {
    @Query private var sightings: [Sighting]
    @Query private var manual: [ManualAssignment]
    @AppStorage("saveToGallery") private var saveToGallery = true
    @AppStorage("geotag") private var geotag = true
    @AppStorage(DebugRecord.enabledKey) private var debugMode = false
    @AppStorage(CatchControlTip.seenKey) private var controlTipSeen = false
    @State private var showControlHowTo = false

    private let camera = CameraModel.shared
    private let live = LiveFleetService.shared
    @State private var mode: CatchMode = .auto
    @State private var draft: CatchDraft?
    @State private var flash = false
    @State private var capturing = false
    /// The shot being read, held still in the brackets until the reveal opens: the live
    /// preview carrying on looked like the shutter hadn't fired.
    @State private var frozen: UIImage?
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
    @Environment(Router.self) private var router

    private let catalog = Fleet.catalog

    var body: some View {
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

            Color.black.opacity(frozen == nil ? 0 : 0.6)
                .ignoresSafeArea()
                .allowsHitTesting(false)

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

                hintPill
                    .padding(.top, 14)

                Spacer(minLength: 12)

                // A 3:2 landscape frame, like a photo: the shot is cropped to it.
                ViewfinderBrackets()
                    .opacity(camera.status == .running ? 1 : 0)
                    .overlay { frozenShot }
                    .aspectRatio(3 / 2, contentMode: .fit)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { bracketGlobal = $0 }
                    .padding(.horizontal, 20)
                    .allowsHitTesting(false)

                Spacer(minLength: 12)

                // Fixed slot, so the brackets don't jump when the tip comes and goes.
                controlTip
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
        .onAppear {
            visible = true
            Haptics.shared.warmUp()
        }
        .task {
            camera.mode = mode
            live.start("camera")
            await camera.start()
            // Ask for location now, while spotting — never in the middle of a reveal.
            if geotag { LocationService.shared.requestPermission() }
        }
        .onDisappear {
            visible = false
            camera.stop()
            live.stop("camera")
        }
        // The volume buttons (and Camera Control) fire the shutter, as in the Camera app:
        // quicker than finding the button on screen with a bus pulling away. The system
        // only hands them over while the camera runs, so volume works as usual elsewhere.
        .onCameraCaptureEvent(isEnabled: draft == nil && camera.status == .running) { event in
            switch event.phase {
            case .began: shutterDown = true
            case .ended:
                shutterDown = false
                Task { await shoot() }
            default: shutterDown = false
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, visible { live.start("camera") }
            if phase == .active, draft == nil, visible { Task { await camera.start() } }
            if phase == .background {
                camera.stop()
                live.stop("camera")
            }
        }
        .onChange(of: LocationService.shared.latest) { live.locationMoved() }
        // A photo shared from another app (Photos, Lightroom…): caught like an imported one.
        .onChange(of: router.sharedPhotos, initial: true) { takeShared() }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            // The picker is still sliding away; a reveal presented under it comes out laid out
            // with no safe area (header under the status bar), for as long as it's up.
            let pickerGone = ContinuousClock.now + .milliseconds(600)
            Task {
                capturing = true
                defer { capturing = false }
                if let data = try? await item.loadTransferable(type: Data.self) {
                    await begin(with: data, fromCamera: false, presentAfter: pickerGone)
                } else {
                    Haptics.shared.nope()
                    DebugRecord.begin(source: "import", mode: mode)?.update { $0.error = "couldn't load the picked photo" }
                }
                pickerItem = nil
            }
        }
        .sheet(isPresented: $showControlHowTo) { CatchControlHowTo() }
        .fullScreenCover(item: $draft, onDismiss: {
            frozen = nil
            if visible { Task { await camera.start() } }
            // Shared while this reveal was up.
            takeShared()
        }) { d in
            RevealView(draft: d)
                .windowControlsClearance()
        }
    }

    // MARK: - Pieces

    @ViewBuilder private var frozenShot: some View {
        if let frozen {
            Image(uiImage: frozen)
                .resizable()
                .scaledToFill()
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)
                        .padding(18)
                        .background(.black.opacity(0.45), in: Circle())
                }
                .shadow(color: .black.opacity(0.5), radius: 16, y: 8)
                .transition(.scale(scale: 1.04).combined(with: .opacity))
                .accessibilityElement()
                .accessibilityLabel(Text("READING THE NUMBER…"))
        }
    }

    private var noCameraSymbol: String {
        switch camera.status {
        case .denied: "camera.badge.ellipsis"
        case .interrupted: "pause.circle"
        case .failed: "exclamationmark.triangle"
        default: "camera.metering.unknown"
        }
    }

    private var noCameraText: LocalizedStringKey {
        switch camera.status {
        case .denied: "CAMERA ACCESS IS OFF"
        case .interrupted: "CAMERA IN USE ELSEWHERE"
        case .failed: "THE CAMERA STOPPED"
        default: "NO CAMERA ON THIS DEVICE"
        }
    }

    @ViewBuilder private var viewfinder: some View {
        switch camera.status {
        case .running:
            CameraPreview(session: camera.session) { point, devicePoint in
                // Only inside the brackets: a hurried tap that just misses the shutter or a
                // zoom button used to refocus on whatever was behind it and spoil the shot.
                let brackets = bracketGlobal.offsetBy(dx: -finderFrame.minX, dy: -finderFrame.minY)
                guard brackets.contains(point) else { return }
                camera.focus(at: devicePoint)
                withAnimation(.spring(response: 0.3)) { focusPoint = point }
                Task {
                    try? await Task.sleep(for: .seconds(0.9))
                    withAnimation(.easeOut) { focusPoint = nil }
                }
            }
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
        case .denied, .unavailable, .interrupted, .failed:
            ZStack {
                Color(hex: 0x0E1013)
                VStack(spacing: 14) {
                    Image(systemName: noCameraSymbol)
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(Palette.faint)
                    Mono(noCameraText, size: 11, color: Palette.sub)
                    if camera.status == .denied {
                        Button("Open Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                        }
                        .font(TaborFont.grotesk(14, 600))
                        .tint(Palette.yellow)
                    }
                    if camera.status == .failed {
                        Button("Try again") { Task { await camera.retry() } }
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

    @ViewBuilder private var controlTip: some View {
        if !controlTipSeen, sightings.count >= CatchControlTip.afterCatches {
            CatchControlTipCard {
                showControlHowTo = true
                controlTipSeen = true
            } dismiss: {
                withAnimation(.snappy) { controlTipSeen = true }
            }
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
                        Mono(m.name, size: 11.5, weight: 600, spacing: 0.1,
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

    private var hintPill: some View {
        let text = toast ?? hint
        return HStack(spacing: 7) {
            // A symbol effect pulses on the render server; a SwiftUI loop here re-rendered
            // the view every frame for as long as the camera was open.
            Image(systemName: "circle.fill")
                .font(.system(size: 5.5))
                .foregroundStyle(.white)
                .symbolEffect(.pulse)
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
                settingToggle($geotag, name: String(localized: "GEOTAG"), on: "location.fill", off: "location.slash.fill")
                Spacer()
                if camera.status == .running, camera.zoomStops.count > 1 { zoomBar }
                Spacer()
                settingToggle($saveToGallery, name: String(localized: "SAVE TO PHOTOS"), on: "photo.badge.arrow.down.fill", off: "photo.badge.arrow.down")
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
                    ZStack {
                        Circle().stroke(.white.opacity(0.92), lineWidth: 4)
                            .frame(width: 76, height: 76)
                        Circle().fill(Palette.red)
                            .frame(width: 60, height: 60)
                            .scaleEffect(shutterDown ? 0.86 : 1)
                    }
                    .animation(.spring(response: 0.25, dampingFraction: 0.5), value: shutterDown)
                    // Hit in a hurry without looking: a 100 pt target around the 76 pt ring.
                    .contentShape(Circle().inset(by: -12))
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
                        // Taller targets than they look; less below, where the shutter's is.
                        .hitArea(top: 12, bottom: 6, sides: 4)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Zoom \(Self.zoomLabel(s)) times")
            }
        }
        .padding(3)
        .glass(Capsule())
        .animation(.snappy(duration: 0.2), value: active)
        .opacity(camera.controlsFullscreen ? 0 : 1)
        .animation(.easeOut(duration: 0.2), value: camera.controlsFullscreen)
    }

    /// "0.5", "1", "2.4", "5".
    static func zoomLabel(_ z: CGFloat) -> String {
        let r = (z * 10).rounded() / 10
        // "0.5", or "0,5" in Polish, like the system Camera app.
        return r == r.rounded() ? String(Int(r)) : Double(r).formatted(FloatingPointFormatStyle<Double>(locale: .app).precision(.fractionLength(1)))
    }

    /// Icon toggle for a capture setting; the hint pill confirms which way it went.
    private func settingToggle(_ value: Binding<Bool>, name: String, on: String, off: String) -> some View {
        let isOn = value.wrappedValue
        return Button {
            Haptics.shared.tick()
            value.wrappedValue.toggle()
            showToast(value.wrappedValue ? String(localized: "\(name) ON") : String(localized: "\(name) OFF"))
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

    private var hint: String {
        // The full-res read (and tile pass) can take a second or two on device.
        if capturing { return String(localized: "READING THE NUMBER…") }
        switch camera.status {
        case .running: break
        case .idle: return String(localized: "WAKING THE CAMERA")
        case .interrupted: return String(localized: "WAITING FOR THE CAMERA")
        default: return String(localized: "IMPORT A SHOT TO CATCH IT")
        }
        return String(localized: "GET THE WHOLE VEHICLE IN FRAME")
    }

    /// The database match, settled by the live feed when only one kind with that number is
    /// running nearby. A model you picked by hand for this number always wins.
    private func lookup(_ n: Int, nearby: [NearbyVehicle]) -> ModelMatch {
        let m = catalog.match(number: n, preferring: mode.kind, manual: manual.map)
        guard manual.map[n] == nil else { return m }
        return LiveHints.resolve(m, number: n, nearby: nearby, catalog: catalog)
    }

    // MARK: - Actions

    private func shoot() async {
        guard !capturing else { return }
        capturing = true
        defer { capturing = false }
        // The feed polls slowly on this screen; top it up for the next shot if it's aging.
        if live.fresh(maxAge: 20) == nil { Task { await live.refresh() } }
        Haptics.shared.shutter()
        withAnimation(.easeOut(duration: 0.06)) { flash = true }
        let data = await camera.capture()
        withAnimation(.easeOut(duration: 0.35)) { flash = false }
        let record = DebugRecord.begin(source: "camera", mode: mode)
        let angle = Double(camera.captureAngle), torch = camera.torchOn, pressure = camera.pressure
        record?.update {
            $0.captureAngle = angle
            $0.torch = torch
            $0.pressure = pressure
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
        await begin(with: data, fromCamera: true, record: record)
    }

    /// The photo waiting in the share inbox, if any and if nothing else is being caught.
    private func takeShared() {
        guard draft == nil, !capturing, let data = ShareInbox.take() else { return }
        Task {
            capturing = true
            defer { capturing = false }
            await begin(with: data, fromCamera: false, record: DebugRecord.begin(source: "share", mode: mode))
        }
    }

    private func begin(with data: Data, fromCamera: Bool, record: DebugRecord? = nil,
                       presentAfter: ContinuousClock.Instant? = nil) async {
        let preview = await Task.detached(priority: .userInitiated) {
            PhotoStore.downsample(data, maxPixel: 900).map(UIImage.init(cgImage:))
        }.value
        withAnimation(.easeOut(duration: 0.2)) { frozen = preview }
        let record = record ?? DebugRecord.begin(source: fromCamera ? "camera" : "import", mode: mode)
        record?.attach(photo: data)
        // An imported photo could be from anywhere, any day: only fresh shots use the feed.
        let nearby = fromCamera && self.live.fresh() != nil ? self.live.nearby : []
        let mode = mode
        // The read also says where the number is, so the sticker keeps the object it's on.
        let ocr = Task.detached(priority: .userInitiated) {
            await TextReader.read(data, mode: mode, nearby: nearby)
        }
        // Lift the subjects at once (quicker than OCR), then cut once the number's box is known.
        let sticker = Task.detached(priority: .userInitiated) { () -> StickerCut? in
            var spent: TimeInterval = 0
            var start = Date()
            let lifted = StickerMaker.lift(data)
            spent += Date().timeIntervalSince(start)
            var box: CGRect?
            var result: Result<StickerCut, StickerMaker.Failure>
            switch lifted {
            case .failure(let f):
                result = .failure(f)
            case .success(let lift):
                box = await ocr.value.numberBox
                start = Date()
                result = StickerCut.make(lift, numberBox: box)
                spent += Date().timeIntervalSince(start)
            }
            let cut = try? result.get()
            if let record {
                let ms = Int(spent * 1000)
                let failure: String? = if case .failure(let f) = result { f.description } else { nil }
                record.update {
                    $0.sticker = .init(ok: cut != nil, durationMs: ms, failure: failure, pickedBy: cut?.reason.rawValue,
                                       subjects: cut?.order.count, numberBox: box.map(DebugRecord.describe))
                }
                if let png = cut?.png { record.attach(sticker: png) }
            }
            return cut
        }
        var liveInfo = DebugRecord.Live(status: "\(self.live.status)",
                                        snapshotAge: self.live.snapshot.map { Int(Date().timeIntervalSince($0.fetched)) },
                                        nearby: nearby.map { "\($0.vehicle.kind.rawValue) \($0.vehicle.number) · line \($0.vehicle.line) · \(Int($0.distance)) m" })
        let report = await ocr.value
        let number = report.number
        let photoNumbers = report.candidates.sorted { $0.score > $1.score }.map(\.number)
        liveInfo.boosted = report.live.boosted
        liveInfo.rescued = report.live.rescued
        liveInfo.partners = report.live.partners
        record?.update { $0.ocr = DebugRecord.ocr(report) }
        var d = CatchDraft(photo: data, number: number, fromCamera: fromCamera, sticker: sticker, preview: preview,
                           debug: record)
        d.nearby = nearby
        d.mode = mode
        d.photoNumbers = Task { photoNumbers }
        d.photoRead = ocr
        if let n = number {
            let plain = catalog.match(number: n, preferring: mode.kind, manual: manual.map)
            let match = lookup(n, nearby: nearby)
            if match != plain { liveInfo.resolved = "\(DebugRecord.describe(plain)) → \(DebugRecord.describe(match))" }
            // An import never has the feed to settle bus 2021 vs tram 2021, and a guess showed a
            // bus as a tram with full confidence (#66).
            if case .ambiguous(let ms) = match { d.choices = ms }
            let picked = d.choices.isEmpty ? match.suggested : nil
            d.modelId = picked?.id
            if fromCamera, let model = picked {
                let snapshot = self.live.snapshot
                d.line = LiveHints.line(for: n, kind: model.kind, snapshot: snapshot, at: d.date, model: model, nearby: nearby,
                                        catalog: catalog)
                d.autoLine = d.line
                // "set": borrowed from the coupled car the feed reports instead.
                liveInfo.lineSource = d.line == nil ? "none" : snapshot?.vehicle(number: n, kind: model.kind) == nil ? "set" : "live"
            }
            if let model = picked {
                d.partnerSuggestions = CoupledSet.suggestions(for: n, model: model, photoNumbers: photoNumbers, nearby: nearby,
                                                              catalog: catalog)
            }
            let described = DebugRecord.describe(match), suggested = d.modelId
            record?.update {
                $0.match = described
                $0.suggestedModel = suggested
            }
        }
        if fromCamera {
            let info = liveInfo
            record?.update { $0.live = info }
            if geotag { d.geotag = Task { await LocationService.shared.geotag() } }
        } else {
            let meta = PhotoStore.metadata(data)
            if let date = meta.date { d.date = date }
            if geotag, let lat = meta.latitude, let lon = meta.longitude {
                d.geotag = Task { await LocationService.shared.geotag(CLLocation(latitude: lat, longitude: lon)) }
            }
        }
        camera.stop()
        if let presentAfter { try? await Task.sleep(until: presentAfter) }
        draft = d
    }
}

extension View {
    /// Grows the tappable area past what's drawn, without moving anything.
    func hitArea(top: CGFloat, bottom: CGFloat, sides: CGFloat) -> some View {
        padding(EdgeInsets(top: top, leading: sides, bottom: bottom, trailing: sides))
            .contentShape(Rectangle())
            .padding(EdgeInsets(top: -top, leading: -sides, bottom: -bottom, trailing: -sides))
    }

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
            .onChange(of: configuration.isPressed) { _, down in
                pressed = down
                if down { Haptics.shared.warmUp() }
            }
    }
}

/// Corner brackets + thirds.
struct ViewfinderBrackets: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let color: Color = .white.opacity(0.85)
            ZStack {
                ForEach(0..<4, id: \.self) { i in
                    Corner()
                        .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .frame(width: 22, height: 22)
                        .rotationEffect(.degrees(Double(i) * 90))
                        .position(x: i == 0 || i == 3 ? 11 : w - 11, y: i < 2 ? 11 : h - 11)
                }
                ForEach([1.0 / 3, 2.0 / 3], id: \.self) { f in
                    Rectangle().fill(.white.opacity(0.14))
                        .frame(width: 1, height: h * 0.84)
                        .position(x: w * f, y: h / 2)
                }
            }
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
