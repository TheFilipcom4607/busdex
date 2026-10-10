import SwiftUI

/// Every number in the book, Flighty-passport style: a period to look at, the headline
/// totals, when and where you catch, your top models and lines, and the records.
struct StatsSheet: View {
    let sightings: [Sighting]
    let onOpen: (BookRoute) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var period: StatsPeriod = .all
    @State private var tab: TopTab = .models
    @State private var month: Date?
    @State private var share: StatsShare?
    private let catalog = Fleet.catalog

    enum TopTab: CaseIterable {
        case models, places, depots, vehicles

        var label: String {
            switch self {
            case .models: String(localized: "MODELS")
            case .places: String(localized: "PLACES")
            case .depots: String(localized: "DEPOTS")
            case .vehicles: String(localized: "VEHICLES")
            }
        }
    }

    var body: some View {
        let records = sightings.map(\.record)
        let periods = StatsPeriod.available(records.map(\.date), calendar: .current)
        let s = PeriodStats(records, period: period, catalog: catalog)

        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                TopBar {
                    Button { dismiss() } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.left").font(.system(size: 12, weight: .bold))
                            Mono("ME", size: 12, weight: 600, color: Palette.ink)
                        }
                    }
                    .buttonStyle(.plain)
                } trailing: {
                    if let share {
                        ShareLink(item: Image(uiImage: share.image), subject: Text(share.title), message: Text(share.message),
                                  preview: SharePreview(share.title, image: Image(uiImage: share.image))) {
                            Mono("SHARE", size: 12, weight: 600, color: Palette.yellow)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    ScreenTitle(text: String(localized: "Your stats"), size: 34)
                    if let first = records.map(\.date).min() {
                        Mono("SINCE \(Self.dayMonthYear(first)) · \(PeriodStats(records, period: .all, catalog: catalog).daysOut) DAYS OUT",
                             size: 11, color: Palette.sub)
                    }
                }
                .padding(.top, 16)
                .padding(.horizontal, 22)

                periodPicker(periods)
                    .padding(.top, 16)

                HeroCard(stats: s, isAll: period == .all)
                    .padding(.top, 14)
                    .padding(.horizontal, 22)

                section(String(localized: "ACTIVITY"),
                        trailing: s.records.bestStreak.map { String(localized: "\($0.days)-DAY BEST STREAK") })
                CalendarCard(perDay: PeriodStats.perDay(records), month: shownMonth(records),
                             range: monthRange(records), onMonth: { month = $0 })
                    .padding(.horizontal, 22)

                if s.catches > 0 {
                    section(String(localized: "WHEN YOU CATCH"))
                    WhenCard(hours: s.hours, weekdays: s.weekdays)
                        .padding(.horizontal, 22)

                    section(String(localized: "YOUR TOP"))
                    topTabs
                    TopList(rows: topRows(s, tab: tab))
                        .padding(.horizontal, 22)

                    if !s.topLines.isEmpty {
                        section(String(localized: "LINES"), trailing: String(localized: "\(s.lines) IN ALL"))
                        LinesGrid(lines: s.topLines)
                            .padding(.horizontal, 22)
                    }

                    if !s.operators.isEmpty {
                        section(String(localized: "WHO RUNS WHAT YOU CATCH"))
                        OperatorsCard(operators: s.operators, depots: s.depots, catalog: catalog)
                            .padding(.horizontal, 22)
                    }

                    section(String(localized: "RECORDS"))
                    RecordsView(records: s.records, sightings: sightings, catalog: catalog, onOpen: onOpen)
                        .padding(.horizontal, 22)

                    if let share {
                        ShareLink(item: Image(uiImage: share.image), subject: Text(share.title), message: Text(share.message),
                                  preview: SharePreview(share.title, image: Image(uiImage: share.image))) {
                            HStack(spacing: 8) {
                                Image(systemName: "square.and.arrow.up").font(.system(size: 14, weight: .bold))
                                Mono(Self.shareLabel(period), size: 13, weight: 700, spacing: 0.1, color: Palette.bg)
                            }
                            .foregroundStyle(Palette.bg)
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                            .background(Palette.yellow, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .padding(.top, 28)
                        .padding(.horizontal, 22)
                    }
                }
            }
            .padding(.bottom, 40)
            .fitScrollWidth()
        }
        .scrollIndicators(.hidden)
        .foregroundStyle(Palette.ink)
        .presentationDetents([.large])
        .presentationBackground(Palette.bg)
        .onChange(of: period) { month = nil }
        // Render the card up front so SHARE opens instantly.
        .task(id: period) {
            share = StatsShare.make(stats: s, period: period, sightings: sightings, catalog: catalog)
        }
    }

    // MARK: Pieces

    private func periodPicker(_ periods: [StatsPeriod]) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(periods, id: \.self) { p in
                    Pill(text: Self.label(p), on: p == period) {
                        withAnimation(.snappy) { period = p }
                    }
                }
            }
            .padding(.horizontal, 22)
        }
        .scrollIndicators(.hidden)
    }

    private var topTabs: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(TopTab.allCases, id: \.self) { t in
                    Pill(text: t.label, on: t == tab) { withAnimation(.snappy) { tab = t } }
                }
            }
            .padding(.horizontal, 22)
        }
        .scrollIndicators(.hidden)
        .padding(.bottom, 10)
    }

    private func section(_ title: String, trailing: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline) {
            SectionLabel(text: title)
            Spacer()
            if let trailing { Mono(trailing, size: 10.5, weight: 600, color: Palette.yellow) }
        }
        .padding(.top, 28)
        .padding(.bottom, 10)
        .padding(.horizontal, 22)
    }

    private func topRows(_ s: PeriodStats, tab: TopTab) -> [TopList.Row] {
        switch tab {
        case .models:
            return s.topModels.map { m in
                let model = catalog.model(id: m.modelId)
                return TopList.Row(name: model?.name ?? m.modelId, count: m.catches,
                                   sub: model.map { String(localized: "\(m.owned) OF \($0.fleet)") } ?? "",
                                   color: model.map { $0.tier.bar } ?? Palette.sub,
                                   open: { onOpen(.model(m.modelId)) })
            }
        case .places:
            return s.topPlaces.map { TopList.Row(name: $0.name, count: $0.count, sub: String(localized: "CATCHES"), color: Palette.ink) }
        case .depots:
            return s.topDepots.map { TopList.Row(name: $0.name, count: $0.count, sub: String(localized: "VEHICLES"), color: Palette.ink) }
        case .vehicles:
            return s.topVehicles.map { v in
                let model = catalog.model(id: v.modelId)
                return TopList.Row(name: "#\(FleetNumber.label(v.number)) \(model?.name ?? "")", count: v.times,
                                   sub: v.times == 1 ? String(localized: "SEEN ONCE") : String(localized: "SEEN \(v.times)×"),
                                   color: model.map { $0.tier.bar } ?? Palette.sub,
                                   open: { onOpen(.vehicle(modelId: v.modelId, number: v.number)) })
            }
        }
    }

    // MARK: Months

    private func monthStart(_ date: Date) -> Date {
        Calendar.current.dateInterval(of: .month, for: date)?.start ?? date
    }

    /// The month the calendar opens on: the period's own, else the latest with a catch.
    private func shownMonth(_ records: [SightingRecord]) -> Date {
        if let month { return month }
        let cal = Calendar.current
        if case .month(let y, let m) = period, let d = cal.date(from: DateComponents(year: y, month: m, day: 1)) { return d }
        let inPeriod = records.filter { period.contains($0.date, calendar: cal) }.map(\.date)
        return monthStart(inPeriod.max() ?? .now)
    }

    private func monthRange(_ records: [SightingRecord]) -> ClosedRange<Date> {
        let now = monthStart(.now)
        let first = records.map(\.date).min().map(monthStart) ?? now
        return min(first, now)...now
    }

    // MARK: Words

    static func label(_ p: StatsPeriod) -> String {
        switch p {
        case .all: return String(localized: "ALL TIME")
        case .year(let y): return String(y)
        case .month(let y, let m):
            let name = monthName(m)
            return y == Calendar.current.component(.year, from: .now) ? name : "\(name) \(y)"
        }
    }

    static func monthName(_ m: Int) -> String {
        var cal = Calendar.current
        cal.locale = .app
        return cal.standaloneMonthSymbols[m - 1].uppercased(with: .app)
    }

    private static func shareLabel(_ p: StatsPeriod) -> String {
        p == .all ? String(localized: "SHARE YOUR STATS") : String(localized: "SHARE YOUR \(label(p))")
    }

    static func dayMonthYear(_ d: Date) -> String {
        d.formatted(.dateTime.day().month(.abbreviated).year().locale(.app)).uppercased(with: .app)
    }

    static func dayMonth(_ d: Date) -> String {
        d.formatted(.dateTime.day().month(.abbreviated).locale(.app)).uppercased(with: .app)
    }
}

// MARK: - Bits

private struct Pill: View {
    let text: String
    let on: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Mono(text, size: 11, weight: 600, spacing: 0.08, color: on ? Palette.bg : Palette.sub)
                .padding(.vertical, 8)
                .padding(.horizontal, 13)
                .background(on ? Palette.ink : Palette.chip, in: Capsule())
                .overlay(Capsule().stroke(on ? Palette.ink : Palette.hairline))
        }
        .buttonStyle(.plain)
    }
}

private struct Card<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Palette.hairline))
    }
}

/// A fleet number on its tier's colour, like the book's tags.
struct TierNumber: View {
    let number: Int
    let tier: Tier
    var size: CGFloat = 11

    var body: some View {
        Text(FleetNumber.label(number))
            .font(TaborFont.mono(size, 700))
            .foregroundStyle(tier == .legendary ? Palette.ink : Palette.bg)
            .padding(.horizontal, size * 0.5)
            .padding(.vertical, size * 0.1)
            .background(tier == .common ? Palette.paper : tier.color, in: RoundedRectangle(cornerRadius: 4))
    }
}

/// "3.0%", one decimal under 10% so the first few hundred catches visibly move it.
func fleetShareText(_ v: Double, signed: Bool = false) -> String {
    let pct = FloatingPointFormatStyle<Double>.Percent().locale(.app)
    let text: String
    if v <= 0 { text = 0.0.formatted(pct.precision(.fractionLength(0))) }
    else if v < 0.001 { text = "<" + 0.001.formatted(pct.precision(.fractionLength(1))) }
    else if v < 0.1 { text = v.formatted(pct.precision(.fractionLength(1))) }
    else { text = v.formatted(pct.precision(.fractionLength(0))) }
    return signed && v > 0 ? "+" + text : text
}

// MARK: - Hero

private struct HeroCard: View {
    let stats: PeriodStats
    let isAll: Bool

    var body: some View {
        let s = stats
        Card(padding: 18) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.catches.formatted())
                            .font(TaborFont.grotesk(76, 500))
                            .em(-0.04, size: 76)
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                            .contentTransition(.numericText())
                        Mono("CATCHES", size: 10.5, weight: 500, spacing: 0.12, color: Palette.sub)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(fleetShareText(s.fleetShare, signed: !isAll))
                            .font(TaborFont.mono(26, 700))
                            .foregroundStyle(Palette.yellow)
                            .contentTransition(.numericText())
                        Mono("OF WARSAW'S FLEET", size: 10, weight: 500, spacing: 0.1, color: Palette.sub)
                    }
                    .padding(.bottom, 4)
                }
                tiles
                if s.buses + s.trams > 0 { split }
            }
        }
    }

    private var tiles: some View {
        let s = stats
        let items: [(String, String)] = [
            (s.newVehicles.formatted(), isAll ? String(localized: "VEHICLES") : String(localized: "NEW VEHICLES")),
            (isAll ? s.models.formatted() : s.newModels.formatted(), isAll ? String(localized: "MODELS") : String(localized: "NEW MODELS")),
            (s.daysOut.formatted(), String(localized: "DAYS OUT")),
            (s.lines.formatted(), String(localized: "LINES")),
            (s.depots.formatted(), String(localized: "DEPOTS")),
            ((s.records.bestStreak?.days ?? 0).formatted(), String(localized: "BEST STREAK")),
        ]
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 1), count: 3), spacing: 1) {
            ForEach(items.indices, id: \.self) { i in
                VStack(alignment: .leading, spacing: 3) {
                    Text(items[i].0)
                        .font(TaborFont.mono(20, 700))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .contentTransition(.numericText())
                    Mono(items[i].1, size: 9, spacing: 0.1, color: Palette.sub)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 12)
                .padding(.horizontal, 10)
                .background(Palette.card)
            }
        }
        .background(Palette.hairline)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// Buses against trams, like Flighty's domestic / international bar.
    private var split: some View {
        VStack(spacing: 8) {
            GeometryReader { geo in
                let total = Double(stats.buses + stats.trams)
                HStack(spacing: 2) {
                    if stats.buses > 0 {
                        Rectangle().fill(Palette.ink).frame(width: max(4, (geo.size.width - 2) * Double(stats.buses) / total))
                    }
                    if stats.trams > 0 { Rectangle().fill(Palette.radar) }
                }
                .clipShape(Capsule())
            }
            .frame(height: 8)
            HStack {
                Mono("● \(stats.buses) BUSES", size: 10, spacing: 0.08, color: Palette.ink)
                Spacer()
                Mono("\(stats.trams) TRAMS ●", size: 10, spacing: 0.08, color: Palette.radar)
            }
        }
    }
}

// MARK: - Calendar

private struct CalendarCard: View {
    let perDay: [Date: Int]
    let month: Date
    let range: ClosedRange<Date>
    let onMonth: (Date) -> Void

    var body: some View {
        var cal = Calendar.current
        cal.locale = .app
        let days = cal.range(of: .day, in: .month, for: month)?.count ?? 30
        let lead = (cal.component(.weekday, from: month) - cal.firstWeekday + 7) % 7
        let best = max(perDay.values.max() ?? 1, 1)
        let symbols = cal.veryShortStandaloneWeekdaySymbols
        let order = (0..<7).map { (cal.firstWeekday - 1 + $0) % 7 }
        let dates = (0..<days).compactMap { cal.date(byAdding: .day, value: $0, to: month) }
        let monthTotal = dates.reduce(0) { $0 + (perDay[$1] ?? 0) }
        let monthDays = dates.filter { (perDay[$0] ?? 0) > 0 }.count

        return Card {
            VStack(spacing: 12) {
                HStack {
                    arrow("chevron.left", to: cal.date(byAdding: .month, value: -1, to: month))
                    Spacer()
                    Mono(month.formatted(.dateTime.month(.wide).year().locale(.app)).uppercased(with: .app),
                         size: 12, weight: 600, spacing: 0.1, color: Palette.ink)
                    Spacer()
                    arrow("chevron.right", to: cal.date(byAdding: .month, value: 1, to: month))
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: 7), spacing: 5) {
                    ForEach(order, id: \.self) { i in
                        Mono(symbols[i].uppercased(with: .app), size: 9.5, color: Palette.dim)
                    }
                    ForEach(0..<lead, id: \.self) { _ in Color.clear.frame(height: 36) }
                    ForEach(dates, id: \.self) { d in
                        cell(d, count: perDay[d] ?? 0, best: best, cal: cal)
                    }
                }
                HStack {
                    Mono(monthDays == 1 ? String(localized: "\(monthTotal) CATCHES · 1 DAY") : String(localized: "\(monthTotal) CATCHES · \(monthDays) DAYS"),
                         size: 10, color: Palette.sub)
                    Spacer()
                    legend
                }
            }
        }
    }

    private func arrow(_ symbol: String, to target: Date?) -> some View {
        let ok = target.map { range.contains($0) } ?? false
        return Button {
            if let target { withAnimation(.snappy) { onMonth(target) } }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(ok ? Palette.sub : Palette.ghost)
                .frame(width: 36, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!ok)
    }

    /// Four shades of yellow, relative to your busiest day.
    static func level(_ count: Int, best: Int) -> Int {
        count == 0 ? 0 : min(4, max(1, Int((Double(count) / Double(best) * 4).rounded(.up))))
    }

    static func fill(_ level: Int) -> Color {
        switch level {
        case 0: Palette.thumb
        case 4: Palette.yellow
        default: Palette.yellow.opacity(0.25 * Double(level))
        }
    }

    private func cell(_ d: Date, count: Int, best: Int, cal: Calendar) -> some View {
        let level = Self.level(count, best: best)
        return Text(String(cal.component(.day, from: d)))
            .font(TaborFont.mono(11, 600))
            .foregroundStyle(level >= 3 ? Palette.bg : count > 0 ? Palette.ink : Palette.faint)
            .frame(maxWidth: .infinity)
            .frame(height: 36)
            .background(Self.fill(level), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                if cal.isDateInToday(d) {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Palette.ink, lineWidth: 1.5)
                }
            }
    }

    private var legend: some View {
        HStack(spacing: 3) {
            Mono("LESS", size: 9, color: Palette.dim).padding(.trailing, 2)
            ForEach(0..<5, id: \.self) { l in
                RoundedRectangle(cornerRadius: 3).fill(Self.fill(l)).frame(width: 10, height: 10)
            }
            Mono("MORE", size: 9, color: Palette.dim).padding(.leading, 2)
        }
    }
}

// MARK: - When

private struct WhenCard: View {
    let hours: [Int]
    let weekdays: [Int]

    var body: some View {
        var cal = Calendar.current
        cal.locale = .app
        let peakHour = hours.indices.max { hours[$0] < hours[$1] } ?? 0
        let peakDay = weekdays.max() ?? 0
        let order = (0..<7).map { (cal.firstWeekday - 1 + $0) % 7 }
        let topDays = order.filter { weekdays[$0] == peakDay && peakDay > 0 }
            .map { cal.standaloneWeekdaySymbols[$0] }

        return Card {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    header(String(localized: "Your hour: \(Self.hourName(peakHour))"),
                           String(localized: "\(hours[peakHour]) CATCHES"))
                    HStack(alignment: .bottom, spacing: 3) {
                        ForEach(0..<24, id: \.self) { h in
                            RoundedRectangle(cornerRadius: 2)
                                .fill(h == peakHour ? Palette.yellow : hours[h] > 0 ? Palette.sub : Palette.track)
                                .frame(height: max(3, 64 * Double(hours[h]) / Double(max(hours[peakHour], 1))))
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .frame(height: 64, alignment: .bottom)
                    HStack {
                        ForEach(["00", "06", "12", "18", "23"], id: \.self) { t in
                            Mono(t, size: 9, color: Palette.dim)
                            if t != "23" { Spacer() }
                        }
                    }
                }
                Rectangle().fill(Palette.hairline).frame(height: 1)
                VStack(alignment: .leading, spacing: 8) {
                    header(topDays.count == 1 ? String(localized: "Your day: \(topDays[0])")
                           : String(localized: "Your days: \(topDays.joined(separator: ", "))"),
                           topDays.count == 1 ? String(localized: "\(peakDay) CATCHES") : String(localized: "\(peakDay) EACH"))
                    HStack(alignment: .bottom, spacing: 8) {
                        ForEach(order, id: \.self) { i in
                            VStack(spacing: 5) {
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(weekdays[i] == peakDay && peakDay > 0 ? Palette.yellow : weekdays[i] > 0 ? Palette.sub : Palette.track)
                                    .frame(height: max(3, 50 * Double(weekdays[i]) / Double(max(peakDay, 1))))
                                Mono(cal.veryShortStandaloneWeekdaySymbols[i].uppercased(with: .app), size: 9.5, color: Palette.sub)
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .frame(height: 70, alignment: .bottom)
                }
            }
        }
    }

    private func header(_ title: String, _ trailing: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(TaborFont.grotesk(20, 500))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer()
            Mono(trailing, size: 10, color: Palette.sub)
        }
    }

    /// "4 PM" or "16", as the phone writes hours.
    static func hourName(_ h: Int) -> String {
        let d = Calendar.current.date(bySettingHour: h, minute: 0, second: 0, of: .now) ?? .now
        return d.formatted(.dateTime.hour().locale(.app))
    }
}

// MARK: - Top lists

private struct TopList: View {
    struct Row {
        let name: String
        let count: Int
        let sub: String
        let color: Color
        var open: (() -> Void)? = nil
    }

    let rows: [Row]

    var body: some View {
        let top = max(rows.first?.count ?? 1, 1)
        Card(padding: 0) {
            VStack(spacing: 0) {
                ForEach(rows.indices, id: \.self) { i in
                    let r = rows[i]
                    if let open = r.open {
                        Button(action: open) { row(r, rank: i + 1, top: top) }
                            .buttonStyle(.plain)
                    } else {
                        row(r, rank: i + 1, top: top)
                    }
                    if i < rows.count - 1 { Rectangle().fill(Palette.hairline).frame(height: 1).padding(.horizontal, 16) }
                }
            }
        }
        .animation(.snappy, value: rows.map(\.name))
    }

    private func row(_ r: Row, rank: Int, top: Int) -> some View {
        VStack(spacing: 7) {
            HStack(spacing: 10) {
                Mono("\(rank)", size: 11, color: Palette.dim).frame(width: 14, alignment: .leading)
                Circle().fill(r.color).frame(width: 8, height: 8)
                Text(r.name)
                    .font(TaborFont.grotesk(15, 500))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(r.count.formatted()).font(TaborFont.mono(13, 700))
            }
            HStack(spacing: 10) {
                ProgressBar(fraction: Double(r.count) / Double(top), color: r.color, height: 4)
                Mono(r.sub, size: 9.5, color: Palette.sub)
                    .frame(width: 96, alignment: .trailing)
                    .lineLimit(1)
            }
            .padding(.leading, 24)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
        .contentShape(Rectangle())
    }
}

private struct LinesGrid: View {
    let lines: [RankedItem]

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
            ForEach(lines.prefix(6), id: \.name) { l in
                // Warsaw's tram lines are 1–79; everything else is a bus.
                let tram = Int(l.name).map { $0 < 100 } ?? false
                // No stack spacing: HStack's even split left a 3-digit line too little room on
                // 390 pt phones and wrapped it onto two rows (#71). The number never wraps; the
                // count shrinks first.
                HStack(spacing: 0) {
                    Text(l.name)
                        .font(TaborFont.mono(14, 700))
                        .lineLimit(1)
                        .fixedSize()
                        .foregroundStyle(Palette.bg)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(tram ? Palette.radar : Palette.ink, in: RoundedRectangle(cornerRadius: 6))
                    Spacer(minLength: 6)
                    Mono("×\(l.count)", size: 12, weight: 600, color: Palette.sub)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
                .padding(12)
                .background(Palette.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Palette.hairline))
            }
        }
    }
}

private struct OperatorsCard: View {
    let operators: [RankedItem]
    let depots: Int
    let catalog: FleetCatalog

    private static let colors = [Palette.ink, Palette.radar, Palette.green, Palette.violet, Palette.brass, Palette.red]

    var body: some View {
        let total = Double(operators.reduce(0) { $0 + $1.count })
        let allOperators = Set(catalog.models.flatMap { $0.batches.compactMap(\.operator) }).count
        Card {
            VStack(alignment: .leading, spacing: 12) {
                GeometryReader { geo in
                    let width = geo.size.width - 2 * Double(operators.count - 1)
                    HStack(spacing: 2) {
                        ForEach(operators.indices, id: \.self) { i in
                            Rectangle().fill(color(i))
                                .frame(width: max(3, width * Double(operators[i].count) / total))
                        }
                    }
                    .clipShape(Capsule())
                }
                .frame(height: 10)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible())], alignment: .leading, spacing: 8) {
                    ForEach(operators.indices, id: \.self) { i in
                        HStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 2).fill(color(i)).frame(width: 8, height: 8)
                            Mono(operators[i].name.uppercased(with: .app), size: 10.5, color: Palette.ink).lineLimit(1)
                            Spacer(minLength: 2)
                            Mono("\(operators[i].count)", size: 10.5, color: Palette.sub)
                        }
                    }
                }
                Rectangle().fill(Palette.hairline).frame(height: 1)
                Mono("\(operators.count) OF \(allOperators) OPERATORS · \(depots) OF \(catalog.depots.count) DEPOTS",
                     size: 10, color: Palette.sub)
            }
        }
    }

    private func color(_ i: Int) -> Color { Self.colors[i % Self.colors.count] }
}

// MARK: - Records

private struct RecordsView: View {
    let records: StatsRecords
    let sightings: [Sighting]
    let catalog: FleetCatalog
    let onOpen: (BookRoute) -> Void

    struct Item: Identifiable {
        let id: String
        let label: String
        let value: String
        let detail: String
        let foot: String
        var open: BookRoute? = nil
    }

    var body: some View {
        VStack(spacing: 10) {
            if let r = records.rarest, let model = catalog.model(id: r.modelId) {
                let owned = Set(sightings.filter { $0.modelId == r.modelId }.map(\.number)).count
                wide(String(localized: "RAREST"), number: r.number, model: model,
                     detail: String(localized: "\(model.tier.name) · \(owned) OF \(model.fleet)"), detailColor: model.tier.bar)
            }
            if let m = records.mostSeen, let model = catalog.model(id: m.modelId) {
                wide(String(localized: "MOST SEEN"), number: m.number, model: model,
                     detail: String(localized: "SEEN \(m.times)×"), detailColor: Palette.sub)
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible())], spacing: 10) {
                ForEach(items) { item in
                    // A plain view when there's nothing to open: a disabled button would grey it out.
                    if let route = item.open {
                        Button { onOpen(route) } label: { tile(item) }
                            .buttonStyle(.plain)
                    } else {
                        tile(item)
                    }
                }
            }
        }
    }

    private var items: [Item] {
        let r = records
        let temp = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0...1)).locale(.app)
        var out: [Item] = []
        func name(_ s: SightingRecord) -> String { "#\(FleetNumber.label(s.number)) \(catalog.model(id: s.modelId)?.name ?? "")" }
        func route(_ s: SightingRecord) -> BookRoute { .vehicle(modelId: s.modelId, number: s.number) }
        if let day = r.busiestDay {
            out.append(Item(id: "busiest", label: String(localized: "BUSIEST DAY"), value: r.busiestCount.formatted(),
                            detail: String(localized: "catches on \(day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).locale(.app)))"),
                            foot: r.busiestTies.first.map { String(localized: "AND AGAIN ON \(StatsSheet.dayMonth($0))") } ?? ""))
        }
        if let run = r.bestStreak {
            let current = Streak.days(sightings.map(\.date))
            out.append(Item(id: "streak", label: String(localized: "BEST STREAK"),
                            value: run.days == 1 ? String(localized: "1 day") : String(localized: "\(run.days) days"),
                            detail: run.days == 1 ? StatsSheet.dayMonth(run.start).capitalized(with: .app)
                                : "\(StatsSheet.dayMonth(run.start).capitalized(with: .app)) – \(StatsSheet.dayMonth(run.end).capitalized(with: .app))",
                            foot: String(localized: "NOW: \(current)")))
        }
        if let o = r.oldest {
            out.append(Item(id: "oldest", label: String(localized: "OLDEST"), value: String(o.year), detail: name(o.record),
                            foot: footer(o.record), open: route(o.record)))
        }
        if let n = r.newest, n.record != r.oldest?.record {
            out.append(Item(id: "newest", label: String(localized: "NEWEST"), value: String(n.year), detail: name(n.record),
                            foot: footer(n.record), open: route(n.record)))
        }
        if let c = r.coldest, let t = c.temperature {
            out.append(Item(id: "coldest", label: String(localized: "COLDEST"), value: t.formatted(temp) + "°", detail: name(c),
                            foot: when(c), open: route(c)))
        }
        if let w = r.warmest, let t = w.temperature, w != r.coldest {
            out.append(Item(id: "warmest", label: String(localized: "WARMEST"), value: t.formatted(temp) + "°", detail: name(w),
                            foot: when(w), open: route(w)))
        }
        if let f = r.first {
            out.append(Item(id: "first", label: String(localized: "FIRST CATCH"),
                            value: f.date.formatted(.dateTime.hour().minute().locale(.app)), detail: name(f),
                            foot: [StatsSheet.dayMonth(f.date), f.district?.uppercased(with: .app)].compactMap { $0 }.joined(separator: " · "),
                            open: route(f)))
        }
        if let age = r.averageAge {
            let years = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(1)).locale(.app)
            out.append(Item(id: "age", label: String(localized: "AVERAGE AGE"),
                            value: String(localized: "\(age.formatted(years)) yrs"),
                            detail: String(localized: "of what you've caught"),
                            foot: r.fleetAverageAge.map { String(localized: "WARSAW: \($0.formatted(years))") } ?? ""))
        }
        return out
    }

    private func when(_ s: SightingRecord) -> String {
        "\(StatsSheet.dayMonth(s.date)) · \(s.date.formatted(.dateTime.hour().minute().locale(.app)))"
    }

    /// Who runs it and where it lives: "MZA · WORONICZA".
    private func footer(_ s: SightingRecord) -> String {
        guard let b = catalog.model(id: s.modelId)?.batch(containing: s.number) else { return "" }
        return [b.operator, b.depotName.isEmpty ? nil : b.depotName].compactMap { $0?.uppercased(with: .app) }.joined(separator: " · ")
    }

    private func tile(_ item: Item) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Mono(item.label, size: 9.5, weight: 500, spacing: 0.12, color: Palette.sub)
            Text(item.value)
                .font(TaborFont.mono(24, 700))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(item.detail)
                .font(TaborFont.grotesk(12.5))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Mono(item.foot, size: 9.5, color: Palette.sub).lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, minHeight: 118, alignment: .topLeading)
        .padding(14)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Palette.hairline))
    }

    private func wide(_ label: String, number: Int, model: VehicleModel, detail: String, detailColor: Color) -> some View {
        Button { onOpen(.vehicle(modelId: model.id, number: number)) } label: {
            HStack(spacing: 14) {
                StickerArt(number: number, modelId: model.id, sightings: sightings)
                    .frame(width: 112, height: 80)
                VStack(alignment: .leading, spacing: 4) {
                    Mono(label, size: 10.5, weight: 500, spacing: 0.12, color: Palette.sub)
                    Text(model.name).font(TaborFont.grotesk(17, 500)).lineLimit(1).minimumScaleFactor(0.8)
                    HStack(spacing: 6) {
                        TierNumber(number: number, tier: model.tier)
                        Mono(detail, size: 10, weight: 600, color: detailColor).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 14)
            .padding(.horizontal, 16)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Palette.hairline))
        }
        .buttonStyle(.plain)
    }
}

/// A vehicle's sticker, or its photo on white card stock, or an empty slot.
private struct StickerArt: View {
    let number: Int
    let modelId: String
    let sightings: [Sighting]

    var body: some View {
        let sticker = sightings.sticker(number: number, modelId: modelId)
        let photo = sightings.photo(number: number, modelId: modelId)
        if let sticker, let img = PhotoStore.thumbnail(sticker, maxPixel: 400) {
            Image(uiImage: img).resizable().scaledToFit()
                .shadow(color: .black.opacity(0.5), radius: 3, y: 3)
        } else if photo != nil {
            CatchPhoto(file: photo, maxPixel: 400)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .padding(4)
                .background(Palette.paper, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        } else {
            EmptySlot(label: FleetNumber.label(number))
        }
    }
}

// MARK: - Share card

/// The period as a story-sized card: the headline number over a pile of your rarest stickers.
struct StatsShare {
    let image: UIImage
    let title: String
    let message: String

    @MainActor
    static func make(stats: PeriodStats, period: StatsPeriod, sightings: [Sighting], catalog: FleetCatalog) -> StatsShare? {
        guard stats.catches > 0 else { return nil }
        let rarestOwned = stats.records.rarest.map { r in Set(sightings.filter { $0.modelId == r.modelId }.map(\.number)).count } ?? 0
        let card = StatsShareCard(stats: stats, period: period, stickers: stickers(stats: stats, period: period, sightings: sightings, catalog: catalog),
                                  rarestOwned: rarestOwned, catalog: catalog)
        let renderer = ImageRenderer(content: card)
        renderer.scale = 3 // 360×640 pt → 1080×1920 px, a story.
        guard let image = renderer.uiImage else { return nil }
        let title = StatsShareCard.heading(period)
        let message = String(localized: "\(stats.catches) buses and trams caught, \(fleetShareText(stats.fleetShare, signed: period != .all)) of Warsaw's fleet 🚌 — TABOR")
        return StatsShare(image: image, title: title, message: message)
    }

    /// Up to five stickers from the period, rarest model first.
    @MainActor
    private static func stickers(stats: PeriodStats, period: StatsPeriod, sightings: [Sighting], catalog: FleetCatalog) -> [(Int, Tier, UIImage)] {
        var seen = Set<String>()
        var vehicles: [(sighting: Sighting, model: VehicleModel)] = []
        for s in sightings where s.pairedWith == nil && period.contains(s.date, calendar: .current) {
            guard seen.insert("\(s.modelId)#\(s.number)").inserted, let model = catalog.model(id: s.modelId) else { continue }
            vehicles.append((s, model))
        }
        vehicles.sort { a, b in
            a.model.fleet != b.model.fleet ? a.model.fleet < b.model.fleet : a.sighting.date < b.sighting.date
        }
        var out: [(Int, Tier, UIImage)] = []
        for (s, model) in vehicles {
            guard let file = sightings.sticker(number: s.number, modelId: s.modelId),
                  let img = PhotoStore.thumbnail(file, maxPixel: 700) else { continue }
            out.append((s.number, model.tier, img))
            if out.count == 5 { break }
        }
        return out
    }
}

private struct StatsShareCard: View {
    let stats: PeriodStats
    let period: StatsPeriod
    let stickers: [(Int, Tier, UIImage)]
    /// How many of the rarest catch's model are in the book.
    let rarestOwned: Int
    let catalog: FleetCatalog

    static func heading(_ p: StatsPeriod) -> String {
        p == .all ? String(localized: "MY TABOR") : String(localized: "MY \(StatsSheet.label(p))")
    }

    var body: some View {
        let s = stats
        let rarest = s.records.rarest.flatMap { r in catalog.model(id: r.modelId).map { (r, $0) } }
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("TABOR").font(TaborFont.mono(13, 700)).em(0.2, size: 13)
                Spacer()
                Mono(dateLine, size: 10.5, color: Palette.sub)
            }
            VStack(alignment: .leading, spacing: 2) {
                Mono(Self.heading(period), size: 11, weight: 600, spacing: 0.14, color: Palette.yellow)
                Text(s.catches.formatted())
                    .font(TaborFont.grotesk(96, 500))
                    .em(-0.045, size: 96)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                Text("buses and trams caught")
                    .font(TaborFont.grotesk(22))
                    .foregroundStyle(Palette.routeInk)
            }
            .padding(.top, 22)

            pile
                .frame(height: 230)
                .padding(.top, 14)

            Spacer(minLength: 12)

            grid(rarest: rarest?.1)

            if let rarest {
                Mono([String(localized: "RAREST: \(rarest.1.name.uppercased(with: .app))"), rarest.0.line.map { String(localized: "LINE \($0)") }]
                    .compactMap { $0 }.joined(separator: " · "), size: 10, color: Palette.sub)
                    .lineLimit(1)
                    .padding(.top, 14)
            }
        }
        .foregroundStyle(Palette.ink)
        .padding(.horizontal, 24)
        .padding(.top, 28)
        .padding(.bottom, 22)
        .frame(width: 360, height: 640, alignment: .topLeading)
        .background(Palette.bg)
        .environment(\.colorScheme, .dark)
    }

    private var dateLine: String {
        switch period {
        case .all: String(localized: "WARSAW · ALL TIME")
        case .year(let y): String(localized: "WARSAW · \(String(y))")
        case .month(let y, let m):
            String(localized: "WARSAW · \(Calendar.current.date(from: DateComponents(year: y, month: m))?.formatted(.dateTime.month(.abbreviated).year().locale(.app)).uppercased(with: .app) ?? "")")
        }
    }

    /// The rarest in the middle, the others tucked around it.
    private var pile: some View {
        let spots: [(x: Double, y: Double, w: Double, tilt: Double)] = [
            (0, 0, 196, -2), (-92, -62, 150, -7), (92, -66, 146, 6), (-86, 64, 140, 4), (88, 62, 146, -5),
        ]
        return ZStack {
            ForEach(Array(stickers.enumerated()).reversed(), id: \.offset) { i, s in
                let spot = spots[i]
                ZStack(alignment: .bottomTrailing) {
                    Image(uiImage: s.2).resizable().scaledToFit()
                        .frame(width: spot.w, height: spot.w * 0.7)
                        .shadow(color: .black.opacity(0.55), radius: 5, y: 4)
                    if i == 0 { TierNumber(number: s.0, tier: s.1, size: 12).offset(x: -8, y: -4) }
                }
                .rotationEffect(.degrees(spot.tilt))
                .offset(x: spot.x, y: spot.y)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func grid(rarest: VehicleModel?) -> some View {
        let s = stats
        let isAll = period == .all
        var items: [(String, String, Color)] = [
            (s.newVehicles.formatted(), isAll ? String(localized: "VEHICLES") : String(localized: "NEW VEHICLES"), Palette.ink),
            ((isAll ? s.models : s.newModels).formatted(), isAll ? String(localized: "MODELS") : String(localized: "NEW MODELS"), Palette.ink),
            (fleetShareText(s.fleetShare, signed: !isAll), String(localized: "OF THE FLEET"), Palette.yellow),
            (String(localized: "\(s.records.bestStreak?.days ?? 0)d"), String(localized: "BEST STREAK"), Palette.ink),
            (s.topLines.first?.name ?? "–", String(localized: "TOP LINE"), Palette.ink),
        ]
        if let rarest {
            items.append(("\(rarestOwned)/\(rarest.fleet)", rarest.tier.name, rarest.tier.bar))
        } else {
            items.append((s.daysOut.formatted(), String(localized: "DAYS OUT"), Palette.ink))
        }
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 1), count: 3), spacing: 1) {
            ForEach(items.indices, id: \.self) { i in
                VStack(alignment: .leading, spacing: 2) {
                    Text(items[i].0).font(TaborFont.mono(20, 700)).foregroundStyle(items[i].2)
                        .lineLimit(1).minimumScaleFactor(0.6)
                    Mono(items[i].1, size: 9, color: Palette.sub).lineLimit(1).minimumScaleFactor(0.8)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 12)
                .padding(.horizontal, 10)
                .background(Palette.card)
            }
        }
        .background(Color.white.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
