import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// "TABOR" in the share sheet (#34): hands the photo to the app, which catches it like one
/// picked from the library. Nothing to choose here, so it's a card that goes by itself.
final class ShareViewController: UIViewController {
    private let state = ShareState()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        let card = UIHostingController(rootView: ShareCard(state: state) { [weak self] in self?.finish() })
        card.view.backgroundColor = .clear
        addChild(card)
        card.view.frame = view.bounds
        card.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(card.view)
        card.didMove(toParent: self)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        Task { await hand() }
    }

    private func hand() async {
        guard let data = await loadPhoto() else { return state.phase = .failed }
        guard (try? ShareInbox.save(data.bytes, fileExtension: data.ext)) != nil else { return state.phase = .failed }
        if await openApp() {
            finish()
        } else {
            // Couldn't open it from here: it's waiting in TABOR the next time you open it.
            state.phase = .saved
        }
    }

    /// The photo's own file, so its EXIF date and place come along; the bare data if the
    /// sharing app only offers that.
    private func loadPhoto() async -> (bytes: Data, ext: String)? {
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        guard let provider = items.flatMap({ $0.attachments ?? [] })
            .first(where: { $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) })
        else { return nil }
        let file: (Data, String)? = await withCheckedContinuation { done in
            provider.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) { url, _ in
                done.resume(returning: url.flatMap { u in (try? Data(contentsOf: u)).map { ($0, u.pathExtension) } })
            }
        }
        if let file { return (file.0, file.1) }
        return await withCheckedContinuation { done in
            provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                done.resume(returning: data.map { ($0, "jpg") })
            }
        }
    }

    /// Extensions get no `UIApplication.shared`, but the app object is up the responder chain.
    @MainActor private func openApp() async -> Bool {
        var responder: UIResponder? = self
        while let r = responder {
            if let app = r as? UIApplication { return await app.open(ShareInbox.url) }
            responder = r.next
        }
        return false
    }

    private func finish() {
        extensionContext?.completeRequest(returningItems: nil)
    }
}

@Observable
final class ShareState {
    enum Phase { case sending, saved, failed }
    var phase = Phase.sending
}

private struct ShareCard: View {
    let state: ShareState
    let done: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            VStack(alignment: .leading, spacing: 10) {
                Text("TABOR")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .kerning(2)
                    .foregroundStyle(Color(white: 0.55))
                switch state.phase {
                case .sending:
                    HStack(spacing: 10) {
                        ProgressView().tint(.white)
                        Text("Sending to TABOR…")
                    }
                case .saved:
                    Text("It's waiting in TABOR. Open the app to catch it.")
                case .failed:
                    Text("This photo couldn't be opened. Try saving it to Photos first.")
                }
                if state.phase != .sending {
                    Button(action: done) {
                        Text("Done")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.black)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                            .background(Color(red: 1, green: 0.81, blue: 0), in: RoundedRectangle(cornerRadius: 14))
                    }
                    .padding(.top, 6)
                }
            }
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(Color(white: 0.97))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
            .background(Color(red: 0.08, green: 0.086, blue: 0.1), in: RoundedRectangle(cornerRadius: 22))
            .padding(16)
        }
        .preferredColorScheme(.dark)
        .animation(.snappy, value: state.phase)
    }
}
