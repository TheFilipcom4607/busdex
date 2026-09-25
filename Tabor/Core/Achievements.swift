import Foundation

/// A collection goal with its progress, e.g. "Line hopper · level 2 · 57/100".
public struct Achievement: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    /// What the next level (or the only one) asks for.
    public let detail: String
    /// SF Symbol name.
    public let symbol: String
    /// Progress toward `goal`: the next level's target, or the last one once maxed.
    public let progress: Int
    public let goal: Int
    /// Levels reached, 0...levels. Single goals have one level.
    public let level: Int
    public let levels: Int
    /// Secret badges stay a "?" until earned.
    public let secret: Bool
    /// Tiered badges: what each level asks for, e.g. ["10 different vehicles", "100 different vehicles", …].
    public let steps: [String]

    public init(id: String, title: String, detail: String, symbol: String, progress: Int, goal: Int,
                level: Int? = nil, levels: Int = 1, secret: Bool = false, steps: [String] = []) {
        self.id = id
        self.title = title
        self.detail = detail
        self.symbol = symbol
        self.progress = progress
        self.goal = goal
        self.level = level ?? (goal > 0 && progress >= goal ? 1 : 0)
        self.levels = levels
        self.secret = secret
        self.steps = steps
    }

    public var earned: Bool { level > 0 }
    public var maxed: Bool { level >= levels }
    public var tiered: Bool { levels > 1 }
    public var fraction: Double { maxed ? 1 : goal > 0 ? min(Double(progress) / Double(goal), 1) : 0 }
    public var isDepot: Bool { id.hasPrefix("depot-") }

    /// Medal for a level: tiered badges go bronze → silver → gold → platinum; single goals are gold.
    public static func medal(level: Int, of levels: Int) -> Medal {
        guard level > 0 else { return .none }
        guard levels > 1 else { return .gold }
        let ladder: [Medal] = levels >= 4 ? [.bronze, .silver, .gold, .platinum] : [.bronze, .silver, .gold]
        return ladder[min(level, ladder.count) - 1]
    }

    public var medal: Medal { Self.medal(level: level, of: levels) }
}

public enum Medal: String, Sendable {
    case none, bronze, silver, gold, platinum
}

/// WMO weather codes as returned by Open-Meteo.
public enum Weather {
    public static func isSnow(_ code: Int) -> Bool { (71...77).contains(code) || (85...86).contains(code) }
    public static func isRain(_ code: Int) -> Bool { (51...67).contains(code) || (80...82).contains(code) }
    public static func isStorm(_ code: Int) -> Bool { (95...99).contains(code) }
}

public enum Achievements {
    /// Warsaw's 18 districts (dzielnice).
    public static let districts = [
        "Bemowo", "Białołęka", "Bielany", "Mokotów", "Ochota", "Praga-Południe", "Praga-Północ",
        "Rembertów", "Śródmieście", "Targówek", "Ursus", "Ursynów", "Wawer", "Wesoła", "Wilanów",
        "Włochy", "Wola", "Żoliborz",
    ]
    public static let tramsInADay = 10

    /// Every badge, earned or not: collection goals first, then the rest, then one per depot.
    public static func evaluate(_ sightings: [SightingRecord], catalog: FleetCatalog,
                                calendar: Calendar = .current) -> [Achievement] {
        let c = Context(sightings: sightings, catalog: catalog, calendar: calendar)
        let all: [Achievement?] = [
            // Collecting
            collector(c), fleetShare(c), lines(c), photographer(c),
            // Rarity
            unicorn(c), tierSet(c, .legendary, id: "legendary-all", symbol: "crown.fill"),
            tierSet(c, .gold, id: "gold-set", symbol: "star.circle.fill"),
            tierSet(c, .rare, id: "rare-set", symbol: "diamond.fill"),
            fullBatch(c), modelComplete(c), rainbowDay(c),
            // Days out
            tramDay(c), fourSeasons(c), oldFriend(c), freshOffTheLine(c), veteran(c), allOperators(c),
            // Places
            everyDistrict(c), explorer(c), suburbanite(c), busyStreet(c),
            // Weather
            weather(c, id: "snow", title: "Snow spotter", detail: "A catch while it's snowing", symbol: "snowflake") {
                $0.weatherCode.map(Weather.isSnow) ?? false
            },
            weather(c, id: "rain", title: "Rain or shine", detail: "A catch in the rain", symbol: "cloud.rain.fill") {
                $0.weatherCode.map(Weather.isRain) ?? false
            },
            weather(c, id: "heatwave", title: "Heatwave", detail: "A catch at 30 °C or hotter", symbol: "sun.max.fill") {
                ($0.temperature ?? -.infinity) >= 30
            },
            weather(c, id: "deep-freeze", title: "Deep freeze", detail: "A catch at −10 °C or colder", symbol: "thermometer.snowflake") {
                ($0.temperature ?? .infinity) <= -10
            },
            weather(c, id: "storm", title: "Storm chaser", detail: "A catch during a thunderstorm", symbol: "cloud.bolt.fill", secret: true) {
                $0.weatherCode.map(Weather.isStorm) ?? false
            },
            // Secrets
            onDate(c, id: "christmas", title: "Christmas spirit", detail: "A catch on Christmas Day", symbol: "gift.fill", month: 12, day: 25),
            onDate(c, id: "new-year", title: "Happy New Year", detail: "A catch on New Year's Day", symbol: "sparkles", month: 1, day: 1),
            anniversary(c), twins(c), roundNumber(c), palindrome(c), doubleLife(c), dejaVu(c),
        ]
        return all.compactMap { $0 } + depots(c)
    }

    /// Everything the rules share, worked out once.
    struct Context {
        let sightings: [SightingRecord]
        let catalog: FleetCatalog
        let calendar: Calendar
        let stats: CollectionStats
        /// Numbers caught per model id.
        let owned: [String: Set<Int>]
        let byDay: [Date: [SightingRecord]]

        init(sightings: [SightingRecord], catalog: FleetCatalog, calendar: Calendar) {
            self.sightings = sightings
            self.catalog = catalog
            self.calendar = calendar
            stats = CollectionStats(sightings: sightings)
            owned = Dictionary(grouping: sightings, by: \.modelId).mapValues { Set($0.map(\.number)) }
            byDay = Dictionary(grouping: sightings) { calendar.startOfDay(for: $0.date) }
        }

        func model(_ s: SightingRecord) -> VehicleModel? { catalog.model(id: s.modelId) }
        func has(_ m: VehicleModel) -> Bool { !(owned[m.id] ?? []).isEmpty }
        func year(_ d: Date) -> Int { calendar.component(.year, from: d) }
    }

    /// A badge with levels: `value` against rising thresholds.
    static func tiered(id: String, title: String, symbol: String, value: Int, thresholds: [Int],
                       detail: (Int) -> String) -> Achievement {
        let level = thresholds.filter { value >= $0 }.count
        let goal = thresholds[min(level, thresholds.count - 1)]
        return Achievement(id: id, title: title, detail: detail(goal), symbol: symbol, progress: value,
                           goal: goal, level: level, levels: thresholds.count, steps: thresholds.map(detail))
    }

    // MARK: Collecting

    static func collector(_ c: Context) -> Achievement {
        tiered(id: "collector", title: "Collector", symbol: "books.vertical.fill", value: c.stats.caught,
               thresholds: [10, 100, 500, 1000]) { "\(thousands($0)) different vehicles" }
    }

    static func fleetShare(_ c: Context) -> Achievement? {
        let total = c.catalog.totalFleet
        guard total > 0 else { return nil }
        let percents = [1, 10, 25, 50]
        let thresholds = percents.map { max(1, Int((Double(total) * Double($0) / 100).rounded(.up))) }
        return tiered(id: "fleet-share", title: "Fleet share", symbol: "chart.pie.fill",
                      value: c.stats.fleetCaught(catalog: c.catalog), thresholds: thresholds) { goal in
            "\(percents[thresholds.firstIndex(of: goal) ?? 0])% of Warsaw's fleet"
        }
    }

    static func lines(_ c: Context) -> Achievement {
        let lines = Set(c.sightings.compactMap { $0.line?.trimmingCharacters(in: .whitespaces).uppercased() }
            .filter { !$0.isEmpty })
        return tiered(id: "lines", title: "Line hopper", symbol: "signpost.right.and.left.fill", value: lines.count,
                      thresholds: [10, 50, 100, 200]) { "Caught on \($0) different lines" }
    }

    static func photographer(_ c: Context) -> Achievement {
        tiered(id: "photographer", title: "Photographer", symbol: "camera.aperture",
               value: c.sightings.filter(\.hasSticker).count, thresholds: [10, 50, 200]) {
            "\($0) catches with a cut-out sticker"
        }
    }

    // MARK: Rarity

    static func unicorn(_ c: Context) -> Achievement? {
        let singles = c.catalog.models.filter { $0.regular && $0.fleet == 1 }
        guard !singles.isEmpty else { return nil }
        return Achievement(id: "unicorn", title: "Unicorn", detail: "The only vehicle of its kind in Warsaw",
                           symbol: "wand.and.stars", progress: singles.contains(where: c.has) ? 1 : 0, goal: 1)
    }

    /// One of every model in a tier.
    static func tierSet(_ c: Context, _ tier: Tier, id: String, symbol: String) -> Achievement? {
        let models = c.catalog.models.filter { $0.tier == tier }
        guard !models.isEmpty else { return nil }
        return Achievement(id: id, title: "All \(models.count) \(tier.rawValue.lowercased())", detail: "One of every \(tier.rawValue) model",
                           symbol: symbol, progress: models.filter(c.has).count, goal: models.count)
    }

    /// Closest delivery batch to completion (at least two vehicles, so it's a real batch).
    static func fullBatch(_ c: Context) -> Achievement {
        var best: (have: Int, size: Int, label: String)?
        for m in c.catalog.models {
            let mine = c.owned[m.id] ?? []
            for b in m.batches where b.numbers.count >= 2 {
                let have = b.numbers.filter(mine.contains).count
                guard have > 0 else { continue }
                if best.map({ have * $0.size > $0.have * b.numbers.count }) ?? true {
                    best = (have, b.numbers.count, [b.year.map(String.init), m.name].compactMap { $0 }.joined(separator: " "))
                }
            }
        }
        return Achievement(id: "full-batch", title: "Full batch",
                           detail: best.map { "Every vehicle of one delivery. Closest: \($0.label)" } ?? "Every vehicle of one delivery batch",
                           symbol: "square.stack.3d.up.fill", progress: best?.have ?? 0, goal: best?.size ?? 1)
    }

    /// Every vehicle of one model (two or more of them; a single is the Unicorn).
    static func modelComplete(_ c: Context) -> Achievement {
        var best: (have: Int, size: Int, name: String)?
        for m in c.catalog.models where m.regular && m.fleet >= 2 {
            let have = m.numbers.filter((c.owned[m.id] ?? []).contains).count
            guard have > 0 else { continue }
            if best.map({ have * $0.size > $0.have * m.fleet }) ?? true { best = (have, m.fleet, m.name) }
        }
        return Achievement(id: "model-complete", title: "Complete set",
                           detail: best.map { "Every vehicle of one model. Closest: \($0.name)" } ?? "Every vehicle of one model",
                           symbol: "checkmark.seal.fill", progress: best?.have ?? 0, goal: best?.size ?? 1)
    }

    static func rainbowDay(_ c: Context) -> Achievement {
        let wanted: Set<Tier> = [.legendary, .gold, .rare, .common]
        let best = c.byDay.values.map { day in Set(day.compactMap { c.model($0)?.tier }).intersection(wanted).count }.max() ?? 0
        return Achievement(id: "rainbow-day", title: "Rainbow day", detail: "A LEGENDARY, GOLD, RARE and COMMON in one day",
                           symbol: "rainbow", progress: best, goal: wanted.count)
    }

    // MARK: Days out

    static func tramDay(_ c: Context) -> Achievement {
        let best = c.byDay.values.map { day in
            Set(day.filter { c.model($0)?.kind == .tram }.map { "\($0.modelId)#\($0.number)" }).count
        }.max() ?? 0
        return Achievement(id: "trams-day", title: "Tram day", detail: "\(tramsInADay) different trams in one day",
                           symbol: "tram.fill", progress: best, goal: tramsInADay)
    }

    /// Meteorological seasons: winter is December to February.
    static func fourSeasons(_ c: Context) -> Achievement {
        let seasons = Set(c.sightings.map { c.calendar.component(.month, from: $0.date) % 12 / 3 })
        return Achievement(id: "four-seasons", title: "Four seasons", detail: "A catch in winter, spring, summer and autumn",
                           symbol: "leaf.fill", progress: seasons.count, goal: 4)
    }

    static func oldFriend(_ c: Context) -> Achievement {
        Achievement(id: "old-friend", title: "Old friend", detail: "The same vehicle seen 10 times", symbol: "heart.fill",
                    progress: c.stats.vehicles.map(\.timesSeen).max() ?? 0, goal: 10)
    }

    static func freshOffTheLine(_ c: Context) -> Achievement {
        let hit = c.sightings.contains { s in
            c.model(s)?.batch(containing: s.number)?.year == c.year(s.date)
        }
        return Achievement(id: "fresh", title: "Fresh off the line", detail: "A vehicle delivered the year you caught it",
                           symbol: "shippingbox.fill", progress: hit ? 1 : 0, goal: 1)
    }

    static func veteran(_ c: Context) -> Achievement {
        let oldest = c.sightings.compactMap { s -> Int? in
            guard let m = c.model(s), m.regular, let y = m.batch(containing: s.number)?.year else { return nil }
            return c.year(s.date) - y
        }.max() ?? 0
        return Achievement(id: "veteran", title: "Veteran", detail: "A vehicle still in service at 20 years old",
                           symbol: "medal.fill", progress: max(oldest, 0), goal: 20)
    }

    /// Operators are counted by each model's main one: a model shared by several
    /// operators doesn't tick them all off.
    static func allOperators(_ c: Context) -> Achievement? {
        let regular = c.catalog.models.filter { $0.regular }
        let all = Set(regular.compactMap(\.operators.first))
        guard !all.isEmpty else { return nil }
        let have = Set(regular.filter(c.has).compactMap(\.operators.first))
        return Achievement(id: "all-operators", title: "Every operator", detail: "A vehicle from all \(all.count) operators",
                           symbol: "person.3.fill", progress: have.count, goal: all.count)
    }

    // MARK: Places

    static func everyDistrict(_ c: Context) -> Achievement {
        let found = Set(c.sightings.compactMap { $0.district.flatMap(district(of:)) })
        return Achievement(id: "every-district", title: "Every district", detail: "A catch in all \(districts.count) districts of Warsaw",
                           symbol: "map.fill", progress: found.count, goal: districts.count)
    }

    /// Two catches on the same day at least 15 km apart.
    static func explorer(_ c: Context) -> Achievement {
        var best = 0.0
        for day in c.byDay.values {
            let points = day.compactMap { s in s.latitude.flatMap { lat in s.longitude.map { (lat, $0) } } }
            for i in points.indices {
                for j in points.indices where j > i {
                    best = max(best, Geo.km(points[i], points[j]))
                }
            }
        }
        return Achievement(id: "explorer", title: "Explorer", detail: "Two catches 15 km apart on the same day",
                           symbol: "location.north.line.fill", progress: Int(best), goal: 15)
    }

    static func suburbanite(_ c: Context) -> Achievement {
        let hit = c.sightings.contains { s in
            guard let lat = s.latitude, let lon = s.longitude else { return false }
            return !Geo.inWarsaw(lat, lon)
        }
        return Achievement(id: "suburbanite", title: "Suburbanite", detail: "A catch outside Warsaw",
                           symbol: "house.and.flag.fill", progress: hit ? 1 : 0, goal: 1)
    }

    static func busyStreet(_ c: Context) -> Achievement {
        let perStreet = Dictionary(grouping: c.sightings.filter { $0.street != nil && $0.line != nil }) {
            $0.street!.lowercased()
        }.mapValues { Set($0.compactMap { $0.line?.trimmingCharacters(in: .whitespaces).uppercased() }).count }
        return Achievement(id: "busy-street", title: "Busy street", detail: "5 different lines caught on one street",
                           symbol: "road.lanes", progress: perStreet.values.max() ?? 0, goal: 5)
    }

    // MARK: Weather

    static func weather(_ c: Context, id: String, title: String, detail: String, symbol: String, secret: Bool = false,
                        _ match: (SightingRecord) -> Bool) -> Achievement {
        Achievement(id: id, title: title, detail: detail, symbol: symbol,
                    progress: c.sightings.contains(where: match) ? 1 : 0, goal: 1, secret: secret)
    }

    // MARK: Secrets

    static func onDate(_ c: Context, id: String, title: String, detail: String, symbol: String, month: Int, day: Int) -> Achievement {
        let hit = c.sightings.contains {
            let d = c.calendar.dateComponents([.month, .day], from: $0.date)
            return d.month == month && d.day == day
        }
        return Achievement(id: id, title: title, detail: detail, symbol: symbol, progress: hit ? 1 : 0, goal: 1, secret: true)
    }

    /// A catch on the date of your very first one, a year or more later.
    static func anniversary(_ c: Context) -> Achievement {
        var hit = false
        if let first = c.sightings.map(\.date).min() {
            let f = c.calendar.dateComponents([.year, .month, .day], from: first)
            hit = c.sightings.contains {
                let d = c.calendar.dateComponents([.year, .month, .day], from: $0.date)
                return d.month == f.month && d.day == f.day && (d.year ?? 0) > (f.year ?? 0)
            }
        }
        return Achievement(id: "anniversary", title: "Anniversary", detail: "A catch one year to the day after your first",
                           symbol: "birthday.cake.fill", progress: hit ? 1 : 0, goal: 1, secret: true)
    }

    /// Two back-to-back fleet numbers of the same model.
    static func twins(_ c: Context) -> Achievement {
        let hit = c.owned.values.contains { nums in nums.contains { nums.contains($0 + 1) } }
        return Achievement(id: "twins", title: "Twins", detail: "Two back-to-back fleet numbers of the same model",
                           symbol: "person.2.fill", progress: hit ? 1 : 0, goal: 1, secret: true)
    }

    static func roundNumber(_ c: Context) -> Achievement {
        let hit = c.sightings.contains { $0.number > 0 && $0.number % 100 == 0 }
        return Achievement(id: "round-number", title: "Round number", detail: "A fleet number ending in 00",
                           symbol: "circle.circle.fill", progress: hit ? 1 : 0, goal: 1, secret: true)
    }

    static func palindrome(_ c: Context) -> Achievement {
        let hit = c.sightings.contains { $0.number >= 100 && isPalindrome($0.number) }
        return Achievement(id: "palindrome", title: "Palindrome", detail: "A fleet number that reads the same backwards",
                           symbol: "arrow.left.arrow.right", progress: hit ? 1 : 0, goal: 1, secret: true)
    }

    /// A bus and a tram carrying the same fleet number.
    static func doubleLife(_ c: Context) -> Achievement {
        var byKind: [VehicleKind: Set<Int>] = [:]
        for s in c.sightings {
            if let kind = c.model(s)?.kind { byKind[kind, default: []].insert(s.number) }
        }
        let hit = !(byKind[.bus] ?? []).isDisjoint(with: byKind[.tram] ?? [])
        return Achievement(id: "double-life", title: "Double life", detail: "A bus and a tram with the same number",
                           symbol: "theatermasks.fill", progress: hit ? 1 : 0, goal: 1, secret: true)
    }

    static func dejaVu(_ c: Context) -> Achievement {
        let hit = c.byDay.values.contains { day in
            let keys = day.map { "\($0.modelId)#\($0.number)" }
            return Set(keys).count < keys.count
        }
        return Achievement(id: "deja-vu", title: "Déjà vu", detail: "The same vehicle twice in one day",
                           symbol: "arrow.triangle.2.circlepath", progress: hit ? 1 : 0, goal: 1, secret: true)
    }

    // MARK: Depots

    /// One badge per depot: a vehicle of every model based there, caught from that depot's batches.
    static func depots(_ c: Context) -> [Achievement] {
        c.catalog.depots.compactMap { d in
            let atDepot = { (b: Batch) in b.depotCode == d.code && b.depotName == d.name }
            let models = c.catalog.models.filter { m in m.regular && m.kind == d.kind && m.batches.contains(where: atDepot) }
            guard !models.isEmpty else { return nil }
            let have = models.filter { m in
                let mine = c.owned[m.id] ?? []
                return m.batches.contains { atDepot($0) && $0.numbers.contains(where: mine.contains) }
            }.count
            return Achievement(id: "depot-\(d.kind.rawValue)-\(d.code)-\(d.name)",
                               title: d.code.isEmpty ? d.name : "\(d.code) \(d.name)",
                               detail: "Every \(d.kind.rawValue.lowercased()) model at the depot",
                               symbol: d.kind == .tram ? "tram.fill.tunnel" : "bus.doubledecker.fill",
                               progress: have, goal: models.count)
        }
    }

    // MARK: Helpers

    /// "1,000", the same in every locale.
    static func thousands(_ n: Int) -> String {
        n >= 1000 ? "\(n / 1000),\(String(format: "%03d", n % 1000))" : String(n)
    }

    static func isPalindrome(_ n: Int) -> Bool {
        let s = String(n)
        return s == String(s.reversed())
    }

    /// Maps a geocoder's area name to its district: "Stary Mokotów" → "Mokotów",
    /// "Praga Południe" → "Praga-Południe". Neighbourhood names (e.g. "Muranów") don't map.
    public static func district(of area: String) -> String? {
        func norm(_ s: String) -> String {
            s.replacingOccurrences(of: "-", with: " ").lowercased()
                .split(separator: " ").joined(separator: " ")
        }
        let words = " \(norm(area)) "
        return districts.first { words.contains(" \(norm($0)) ") }
    }
}

/// Just enough geography for the place badges.
public enum Geo {
    /// Great-circle distance in km.
    public static func km(_ a: (Double, Double), _ b: (Double, Double)) -> Double {
        let r = 6371.0, rad = Double.pi / 180
        let dLat = (b.0 - a.0) * rad, dLon = (b.1 - a.1) * rad
        let h = sin(dLat / 2) * sin(dLat / 2) + cos(a.0 * rad) * cos(b.0 * rad) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * r * asin(min(1, sqrt(h)))
    }

    /// Warsaw's bounding box. Anything outside is certainly outside the city (a few
    /// suburbs inside the box don't count, which is fine for a badge).
    public static func inWarsaw(_ lat: Double, _ lon: Double) -> Bool {
        (52.0977...52.3681).contains(lat) && (20.8517...21.2712).contains(lon)
    }
}
