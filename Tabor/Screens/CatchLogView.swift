import SwiftData
import SwiftUI

/// ME's look at the diary: your last few catches, newest first, and the way into all of them.
struct CatchLogSection: View {
    let sightings: [Sighting]
    @Environment(Router.self) private var router
    @State private var showAll = false

    static let preview = 3

    var body: some View {
        let marks = CatchLog.marks(sightings.map(\.record))
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                SectionLabel(text: String(localized: "CATCH LOG"))
                Spacer()
                Button {
                    showAll = true
                } label: { Mono("FULL LOG", size: 10.5, color: Palette.yellow) }
                .buttonStyle(.plain)
            }
            .padding(.bottom, 4)
            // `sightings` comes newest first.
            ForEach(Array(sightings.prefix(Self.preview).enumerated()), id: \.element.id) { i, s in
                CatchLogRow(sighting: s, mark: marks[i], showsDay: true) {
                    router.openVehicle(modelId: s.modelId, number: s.number)
                }
            }
        }
        .sheet(isPresented: $showAll) {
            CatchLogSheet(sightings: sightings) { s in
                showAll = false
                router.openVehicle(modelId: s.modelId, number: s.number)
            }
        }
    }
}

/// Every catch, by day, newest first. A row opens its vehicle's page.
struct CatchLogSheet: View {
    let sightings: [Sighting]
    let onOpen: (Sighting) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let records = sightings.map(\.record)
        let marks = CatchLog.marks(records)
        let days = CatchLog.days(records.map(\.date))
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                TopBar {
                    Mono("ME", size: 12, spacing: 0.16)
                } trailing: {
                    Button { dismiss() } label: { Mono("DONE", size: 12) }
                        .buttonStyle(.plain)
                }
                VStack(alignment: .leading, spacing: 4) {
                    ScreenTitle(text: String(localized: "Catch log"))
                    Mono("\(sightings.count) IN ALL", size: 11, color: Palette.sub)
                }
                .padding(.top, 16)
                .padding(.horizontal, 22)
                .padding(.bottom, 8)

                ForEach(days, id: \.day) { day in
                    Section {
                        ForEach(day.indices, id: \.self) { i in
                            CatchLogRow(sighting: sightings[i], mark: marks[i], showsDay: false) { onOpen(sightings[i]) }
                                .padding(.horizontal, 22)
                        }
                    } header: {
                        SectionLabel(text: Self.dayName(day.day))
                            .padding(.top, 14)
                            .padding(.bottom, 6)
                            .padding(.horizontal, 22)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Palette.bg)
                    }
                }
            }
            .padding(.bottom, 30)
        }
        .scrollIndicators(.hidden)
        .foregroundStyle(Palette.ink)
        .presentationDetents([.large])
        .presentationBackground(Palette.bg)
    }

    static func dayName(_ day: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(day) { return String(localized: "TODAY") }
        if cal.isDateInYesterday(day) { return String(localized: "YESTERDAY") }
        let sameYear = cal.component(.year, from: day) == cal.component(.year, from: .now)
        return (sameYear ? dayMonth : dayMonthYear).string(from: day).uppercased()
    }

    private static let dayMonth: DateFormatter = {
        let f = DateFormatter()
        f.locale = .app
        f.setLocalizedDateFormatFromTemplate("EEEEdMMMM")
        return f
    }()

    private static let dayMonthYear: DateFormatter = {
        let f = DateFormatter()
        f.locale = .app
        f.setLocalizedDateFormatFromTemplate("dMMMMyyyy")
        return f
    }()
}

/// One catch: when, what, where, and whether it was a first.
private struct CatchLogRow: View {
    let sighting: Sighting
    let mark: CatchLog.Mark
    /// On ME the rows aren't under a day's heading, so they say the day too.
    let showsDay: Bool
    let onOpen: () -> Void

    var body: some View {
        let s = sighting
        let model = Fleet.catalog.model(id: s.modelId)
        Button(action: onOpen) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Mono(time(s.date), size: 11, weight: 600, color: Palette.sub)
                        Text(model?.name ?? s.modelId)
                            .font(TaborFont.grotesk(14.5, 600))
                            .lineLimit(1)
                    }
                    HStack(spacing: 8) {
                        Mono(details(s), size: 10.5, spacing: 0.05, color: Palette.dim)
                            .lineLimit(1)
                        switch mark {
                        case .newModel:
                            Mono("NEW MODEL", size: 9.5, weight: 700, spacing: 0.1, color: model?.tier.color ?? Palette.yellow)
                        case .newVehicle:
                            Mono("NEW", size: 9.5, weight: 700, spacing: 0.1, color: Palette.yellow)
                        case .again:
                            EmptyView()
                        }
                    }
                }
                Spacer(minLength: 0)
                picture(s)
                    .frame(width: 58, height: 40)
            }
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func picture(_ s: Sighting) -> some View {
        if let sticker = s.stickerFile, let img = PhotoStore.thumbnail(sticker, maxPixel: 200) {
            Image(uiImage: img).resizable().scaledToFit()
        } else if s.photoFile != nil {
            CatchPhoto(file: s.photoFile, maxPixel: 200)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }

    private func time(_ date: Date) -> String {
        let t = date.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(.app))
        guard showsDay else { return t }
        let cal = Calendar.current
        if cal.isDateInToday(date) { return t }
        return date.formatted(Date.FormatStyle().day().month(.abbreviated).locale(.app)).uppercased()
    }

    private func details(_ s: Sighting) -> String {
        var parts = ["#\(s.number)"]
        if let p = s.pairedWith { parts.append(String(localized: "COUPLED WITH #\(String(p))")) }
        if let line = s.line { parts.append(String(localized: "LINE \(line)")) }
        if let place = s.district ?? s.street { parts.append(place.uppercased()) }
        return parts.joined(separator: " · ")
    }
}
