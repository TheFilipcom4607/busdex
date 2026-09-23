import SwiftData
import SwiftUI

struct VehicleView: View {
    let modelId: String
    let number: Int
    @Query(sort: \Sighting.date, order: .reverse) private var sightings: [Sighting]
    @Environment(\.dismiss) private var dismiss
    @State private var share: CatchShare?

    var body: some View {
        let model = Fleet.catalog.model(id: modelId)
        let mine = sightings.filter { $0.number == number && $0.modelId == modelId }
        let first = mine.last
        let batch = model?.batch(containing: number)

        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                TopBar {
                    Button { dismiss() } label: {
                        Mono("← \((model?.name ?? "BACK").uppercased())", size: 12, spacing: 0.16)
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                } trailing: {
                    if let share {
                        ShareLink(item: Image(uiImage: share.image), subject: Text(share.title), message: Text(share.message),
                                  preview: SharePreview(share.title, image: Image(uiImage: share.image))) {
                            Mono("SHARE", size: 12)
                        }
                    }
                }

                HStack(alignment: .bottom, spacing: 12) {
                    Text(String(number))
                        .font(TaborFont.mono(58, 700))
                        .em(0.01, size: 58)
                        .lineLimit(1)
                        .fixedSize()
                    VStack(alignment: .leading, spacing: 0) {
                        Text(model?.name ?? "Unknown model")
                            .font(TaborFont.grotesk(14, 600))
                            .lineLimit(1)
                        Mono(batch?.depotDisplay ?? model?.operators.first?.uppercased() ?? "", size: 11, color: Palette.sub)
                            .lineLimit(1)
                    }
                    .padding(.bottom, 6)
                }
                .padding(.top, 16)
                .padding(.horizontal, 22)

                CatchPhoto(file: mine.first(where: { $0.photoFile != nil })?.photoFile, maxPixel: 1200,
                           placeholder: "NO PHOTO YET")
                    .frame(height: 150)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Palette.hairline))
                    .padding(.top, 16)
                    .padding(.horizontal, 22)

                LazyVGrid(columns: [GridItem(.flexible(), spacing: 9), GridItem(.flexible())], spacing: 9) {
                    StatTile(label: "VEHICLE AGE", value: age(batch?.year), valueSize: 20,
                             caption: batch?.year.map { "built \($0)" } ?? "year unknown")
                    StatTile(label: "FIRST SEEN", value: first.map { Self.dayMonth.string(from: $0.date).uppercased() } ?? "—",
                             valueSize: 20, caption: first.map(place) ?? "not caught yet")
                }
                .padding(.top, 16)
                .padding(.horizontal, 22)

                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 0) {
                        Mono("TIMES SEEN", size: 10, spacing: 0.12)
                        Text("\(mine.count)").font(TaborFont.mono(20, 700)).padding(.vertical, 3)
                    }
                    Spacer()
                    if let model {
                        let ownedOfModel = sightings.stats.ownedCount(modelId: model.id)
                        Text("\(ownedOfModel) of \(model.fleet) \(model.name)\nin your book")
                            .font(TaborFont.grotesk(11.5))
                            .foregroundStyle(Palette.sub)
                            .multilineTextAlignment(.trailing)
                            .lineSpacing(2)
                    }
                }
                .padding(.vertical, 12)
                .padding(.horizontal, 14)
                .background(Palette.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.white.opacity(0.06)))
                .padding(.top, 9)
                .padding(.horizontal, 22)

                let lines = orderedLines(mine)
                if !lines.isEmpty {
                    SectionLabel(text: "SEEN ON LINES")
                        .padding(.top, 18)
                        .padding(.bottom, 9)
                        .padding(.horizontal, 22)
                    FlowRow(spacing: 7) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                            Text(line)
                                .font(TaborFont.mono(12, 600))
                                .padding(.vertical, 6)
                                .padding(.horizontal, 10)
                                .foregroundStyle(i == 0 ? Color.white : Palette.routeInk)
                                .background(i == 0 ? Palette.red : Palette.track, in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                    .padding(.horizontal, 22)
                }

                SectionLabel(text: "YOUR SIGHTINGS")
                    .padding(.top, 18)
                    .padding(.bottom, 10)
                    .padding(.horizontal, 22)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(mine.enumerated()), id: \.element.id) { i, s in
                        HStack(alignment: .top, spacing: 12) {
                            VStack(spacing: 3) {
                                Circle().fill(i == 0 ? Palette.yellow : Palette.dim).frame(width: 9, height: 9)
                                Rectangle().fill(Color.white.opacity(0.12)).frame(width: 1, height: 26)
                            }
                            .padding(.top, 4)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(Self.stamp.string(from: s.date))
                                    .font(TaborFont.grotesk(13.5, 600))
                                Mono(logLine(s, isFirst: i == mine.count - 1), size: 11, spacing: 0.05, color: Palette.sub)
                            }
                            .padding(.bottom, 10)
                        }
                    }
                    HStack(alignment: .top, spacing: 12) {
                        Circle().stroke(Color.white.opacity(0.25)).frame(width: 9, height: 9).padding(.top, 4)
                        Mono(mine.isEmpty ? "NOT CAUGHT YET — GO FIND IT" : "NOTHING ELSE YET — GO FIND IT AGAIN",
                             size: 11.5, spacing: 0.05, color: Palette.faint)
                    }
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 30)
            }
        }
        .scrollIndicators(.hidden)
        .taborScreen()
        // Render the share card up front so SHARE opens instantly.
        .task(id: mine.first?.id) {
            guard let latest = mine.first else { return share = nil }
            share = CatchShare.make(number: number, model: model, sighting: latest,
                                    sticker: sightings.sticker(number: number, modelId: modelId),
                                    photo: sightings.photo(number: number, modelId: modelId),
                                    owned: sightings.stats.ownedCount(modelId: modelId))
        }
    }

    private func age(_ year: Int?) -> String {
        guard let year else { return "—" }
        let y = Calendar.current.component(.year, from: .now) - year
        return y <= 0 ? "NEW" : "\(y)y"
    }

    private func place(_ s: Sighting) -> String {
        [s.street, s.line.map { "line \($0)" }].compactMap { $0 }.joined(separator: ", ").nonEmpty ?? "location off"
    }

    private func logLine(_ s: Sighting, isFirst: Bool) -> String {
        var parts = [String]()
        if let street = s.street { parts.append(street.uppercased()) }
        if let line = s.line { parts.append("LINE \(line)") }
        parts.append(isFirst ? "CAUGHT" : "SEEN AGAIN")
        return parts.joined(separator: " · ")
    }

    /// Most recent line first, no repeats.
    private func orderedLines(_ list: [Sighting]) -> [String] {
        var seen = Set<String>()
        return list.compactMap(\.line).filter { seen.insert($0).inserted }
    }

    static let dayMonth: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d MMM"
        return f
    }()

    static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d MMM yyyy · HH:mm"
        return f
    }()
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

/// Wrapping row of chips.
struct FlowRow: Layout {
    var spacing: CGFloat = 7

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0,
                      height: rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for i in row.items {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [(items: [Int], width: CGFloat, height: CGFloat)] {
        var rows: [(items: [Int], width: CGFloat, height: CGFloat)] = []
        var cur: (items: [Int], width: CGFloat, height: CGFloat) = ([], 0, 0)
        for (i, v) in subviews.enumerated() {
            let s = v.sizeThatFits(.unspecified)
            let needed = cur.items.isEmpty ? s.width : cur.width + spacing + s.width
            if needed > width, !cur.items.isEmpty {
                rows.append(cur)
                cur = ([i], s.width, s.height)
            } else {
                cur = (cur.items + [i], needed, max(cur.height, s.height))
            }
        }
        if !cur.items.isEmpty { rows.append(cur) }
        return rows
    }
}
