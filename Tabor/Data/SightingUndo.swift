import SwiftData
import SwiftUI

/// The last deleted sighting, held for a few seconds so UNDO can bring it back. Its row goes
/// at once; its photo and sticker stay on disk until the toast is gone. Lives at the root, so
/// it outlives a vehicle page that closed because its only sighting went.
@MainActor @Observable
final class SightingUndo {
    /// Every field of a `Sighting`, so it comes back exactly as it was, id and weather included.
    struct Snapshot {
        let id: UUID
        let number: Int
        let modelId: String
        let date: Date
        let latitude: Double?
        let longitude: Double?
        let street: String?
        let district: String?
        let line: String?
        let photoFile: String?
        let stickerFile: String?
        let weatherCode: Int?
        let temperature: Double?
        let pairedWith: Int?
        let cover: Bool?

        init(_ s: Sighting) {
            id = s.id
            number = s.number
            modelId = s.modelId
            date = s.date
            latitude = s.latitude
            longitude = s.longitude
            street = s.street
            district = s.district
            line = s.line
            photoFile = s.photoFile
            stickerFile = s.stickerFile
            weatherCode = s.weatherCode
            temperature = s.temperature
            pairedWith = s.pairedWith
            cover = s.cover
        }

        func sighting() -> Sighting {
            let s = Sighting(id: id, number: number, modelId: modelId, date: date, line: line,
                             photoFile: photoFile, stickerFile: stickerFile)
            s.latitude = latitude
            s.longitude = longitude
            s.street = street
            s.district = district
            s.weatherCode = weatherCode
            s.temperature = temperature
            s.pairedWith = pairedWith
            s.cover = cover
            return s
        }
    }

    private(set) var pending: Snapshot?
    /// Its vehicle page closed with it (it was the only sighting): UNDO opens it again.
    private(set) var closedPage = false
    private var expiry: Task<Void, Never>?

    static let seconds = 5.0

    func delete(_ s: Sighting, in context: ModelContext, closingPage: Bool) {
        // A newer delete: the one before it is gone for good.
        finish()
        pending = Snapshot(s)
        closedPage = closingPage
        context.delete(s)
        try? context.save()
        expiry = Task {
            try? await Task.sleep(for: .seconds(Self.seconds))
            guard !Task.isCancelled else { return }
            withAnimation(.snappy) { finish() }
        }
    }

    /// Puts it back; nil if there was nothing to bring back.
    func undo(in context: ModelContext) -> Snapshot? {
        guard let p = pending else { return nil }
        expiry?.cancel()
        expiry = nil
        pending = nil
        context.insert(p.sighting())
        try? context.save()
        return p
    }

    /// Too late to undo (time's up, or the app went to the background): its files go.
    func finish() {
        expiry?.cancel()
        expiry = nil
        guard let p = pending else { return }
        pending = nil
        [p.photoFile, p.stickerFile].compactMap { $0 }.forEach(PhotoStore.delete)
    }
}

/// "Sighting deleted · UNDO", floating over the bottom of the screen.
struct UndoToast: View {
    let onUndo: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Text("Sighting deleted")
                .font(TaborFont.grotesk(14, 500))
                .foregroundStyle(Palette.ink)
            Button(action: onUndo) {
                Mono("UNDO", size: 12, weight: 700, spacing: 0.12, color: Palette.yellow)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Undo deleting the sighting")
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 18)
        .glass(Capsule())
        .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
    }
}
