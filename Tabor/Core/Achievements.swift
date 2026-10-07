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
    /// The vehicles behind it: what earned it, or, not earned yet, the closest so far. Empty for
    /// badges that just count (Collector) or aren't about particular vehicles.
    public let proof: [Proof]
    /// What's still to find, for badges that need one of each from a known list (every district,
    /// every operator, every model at a depot). Empty once earned.
    public let missing: [Missing]

    /// Something a badge still needs: a district, an operator, or a model (which opens its page).
    public struct Missing: Hashable, Sendable {
        public let label: String
        public let modelId: String?

        public init(_ label: String, modelId: String? = nil) {
            self.label = label
            self.modelId = modelId
        }
    }

    /// One vehicle behind a badge, with why it counts ("21 YEARS OLD", "LINE 16").
    public struct Proof: Hashable, Sendable {
        public let modelId: String
        public let number: Int
        public let note: String?

        public init(modelId: String, number: Int, note: String? = nil) {
            self.modelId = modelId
            self.number = number
            self.note = note
        }
    }

    public init(id: String, title: String, detail: String, symbol: String, progress: Int, goal: Int,
                level: Int? = nil, levels: Int = 1, secret: Bool = false, steps: [String] = [], proof: [Proof] = [],
                missing: [Missing] = []) {
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
        // A secret keeps its vehicles to itself until it's earned.
        self.proof = secret && !(goal > 0 && (level ?? (progress >= goal ? 1 : 0)) > 0) ? [] : proof
        self.missing = missing
    }

    public var earned: Bool { level > 0 }
    public var maxed: Bool { level >= levels }
    public var tiered: Bool { levels > 1 }
    /// What the level reached asks for: a tiered badge at level 1 of Collector is "10 different
    /// vehicles", not the next level's "100". Not earned yet, it's the first goal.
    public var reached: String { tiered && level > 0 && level <= steps.count ? steps[level - 1] : detail }
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
            collector(c), fleetShare(c), lines(c), photographer(c), specialLivery(c),
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
            weather(c, id: "snow", title: String(localized: "Snow spotter"), detail: String(localized: "A catch while it's snowing"), symbol: "snowflake") {
                $0.weatherCode.map(Weather.isSnow) ?? false
            },
            weather(c, id: "rain", title: String(localized: "Rain or shine"), detail: String(localized: "A catch in the rain"), symbol: "cloud.rain.fill") {
                $0.weatherCode.map(Weather.isRain) ?? false
            },
            weather(c, id: "heatwave", title: String(localized: "Heatwave"), detail: String(localized: "A catch at 30 °C or hotter"), symbol: "sun.max.fill") {
                ($0.temperature ?? -.infinity) >= 30
            },
            weather(c, id: "deep-freeze", title: String(localized: "Deep freeze"), detail: String(localized: "A catch at −10 °C or colder"), symbol: "thermometer.snowflake") {
                ($0.temperature ?? .infinity) <= -10
            },
            weather(c, id: "storm", title: String(localized: "Storm chaser"), detail: String(localized: "A catch during a thunderstorm"), symbol: "cloud.bolt.fill", secret: true) {
                $0.weatherCode.map(Weather.isStorm) ?? false
            },
            // Secrets
            onDate(c, id: "christmas", title: String(localized: "Christmas spirit"), detail: String(localized: "A catch on Christmas Day"), symbol: "gift.fill", month: 12, day: 25),
            onDate(c, id: "new-year", title: String(localized: "Happy New Year"), detail: String(localized: "A catch on New Year's Day"), symbol: "sparkles", month: 1, day: 1),
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

        /// Each vehicle once, keeping the first note it came with.
        func proof(_ sightings: [SightingRecord], note: (SightingRecord) -> String? = { _ in nil }) -> [Achievement.Proof] {
            var seen = Set<String>()
            return sightings.compactMap { s in
                seen.insert("\(s.modelId)#\(s.number)").inserted ? Achievement.Proof(modelId: s.modelId, number: s.number, note: note(s)) : nil
            }
        }
        func has(_ m: VehicleModel) -> Bool { !(owned[m.id] ?? []).isEmpty }
        func year(_ d: Date) -> Int { calendar.component(.year, from: d) }
    }

    /// A badge with levels: `value` against rising thresholds.
    static func tiered(id: String, title: String, symbol: String, value: Int, thresholds: [Int],
                       proof: [Achievement.Proof] = [], detail: (Int) -> String) -> Achievement {
        let level = thresholds.filter { value >= $0 }.count
        let goal = thresholds[min(level, thresholds.count - 1)]
        return Achievement(id: id, title: title, detail: detail(goal), symbol: symbol, progress: value,
                           goal: goal, level: level, levels: thresholds.count, steps: thresholds.map(detail), proof: proof)
    }

    // MARK: Collecting

    static func collector(_ c: Context) -> Achievement {
        tiered(id: "collector", title: String(localized: "Collector"), symbol: "books.vertical.fill", value: c.stats.caught,
               thresholds: [10, 100, 500, 1000]) { String(localized: "\(thousands($0)) different vehicles") }
    }

    static func fleetShare(_ c: Context) -> Achievement? {
        let total = c.catalog.totalFleet
        guard total > 0 else { return nil }
        let percents = [1, 10, 25, 50]
        let thresholds = percents.map { max(1, Int((Double(total) * Double($0) / 100).rounded(.up))) }
        return tiered(id: "fleet-share", title: String(localized: "Fleet share"), symbol: "chart.pie.fill",
                      value: c.stats.fleetCaught(catalog: c.catalog), thresholds: thresholds) { goal in
            String(localized: "\(percents[thresholds.firstIndex(of: goal) ?? 0])% of Warsaw's fleet")
        }
    }

    static func lines(_ c: Context) -> Achievement {
        let lines = Set(c.sightings.compactMap { $0.line?.trimmingCharacters(in: .whitespaces).uppercased() }
            .filter { !$0.isEmpty })
        return tiered(id: "lines", title: String(localized: "Line hopper"), symbol: "signpost.right.and.left.fill", value: lines.count,
                      thresholds: [10, 50, 100, 200]) { String(localized: "Caught on \($0) different lines") }
    }

    /// A coupled tram's second car shares the first one's photo, so it's not another shot.
    static func photographer(_ c: Context) -> Achievement {
        tiered(id: "photographer", title: String(localized: "Photographer"), symbol: "camera.aperture",
               value: c.sightings.filter { $0.hasSticker && $0.pairedWith == nil }.count, thresholds: [10, 50, 200]) {
            String(localized: "\($0) catches with a cut-out sticker")
        }
    }

    /// Vehicles caught in a paint of their own, unlike the rest of their model (so not the
    /// suburban blue). Hidden until the fleet file lists some.
    static func specialLivery(_ c: Context) -> Achievement? {
        let special = { (m: VehicleModel, n: Int) in m.livery(of: n).flatMap { $0.special ? $0 : nil } }
        guard c.catalog.models.contains(where: { m in (m.liveries ?? [:]).keys.contains { Int($0).flatMap { special(m, $0) } != nil } })
        else { return nil }
        let painted = c.stats.vehicles.compactMap { v in
            c.catalog.model(id: v.modelId).flatMap { special($0, v.number) }.map { Achievement.Proof(modelId: v.modelId, number: v.number, note: $0.name) }
        }.sorted { $0.number < $1.number }
        return tiered(id: "special-livery", title: String(localized: "Dressed up"), symbol: "paintbrush.fill",
                      value: painted.count, thresholds: [1, 3], proof: painted) {
            $0 == 1 ? String(localized: "A vehicle in a special livery") : String(localized: "\($0) vehicles in a special livery")
        }
    }

    // MARK: Rarity

    static func unicorn(_ c: Context) -> Achievement? {
        let singles = c.catalog.models.filter { $0.regular && $0.fleet == 1 }
        guard !singles.isEmpty else { return nil }
        return Achievement(id: "unicorn", title: String(localized: "Unicorn"), detail: String(localized: "The only vehicle of its kind in Warsaw"),
                           symbol: "wand.and.stars", progress: singles.contains(where: c.has) ? 1 : 0, goal: 1,
                           proof: c.proof(c.sightings.filter { s in singles.contains { $0.id == s.modelId } }))
    }

    /// One of every model in a tier.
    static func tierSet(_ c: Context, _ tier: Tier, id: String, symbol: String) -> Achievement? {
        let models = c.catalog.models.filter { $0.tier == tier }
        guard !models.isEmpty else { return nil }
        let n = models.count
        let (title, detail) = switch tier {
        case .legendary: (String(localized: "All \(n) legendary"), String(localized: "One of every LEGENDARY model"))
        case .gold: (String(localized: "All \(n) gold"), String(localized: "One of every GOLD model"))
        default: (String(localized: "All \(n) rare"), String(localized: "One of every RARE model"))
        }
        // One vehicle per model: the lowest number you have of it.
        let proof = models.compactMap { m in (c.owned[m.id]?.min()).map { Achievement.Proof(modelId: m.id, number: $0) } }
        return Achievement(id: id, title: title, detail: detail,
                           symbol: symbol, progress: models.filter(c.has).count, goal: n, proof: proof)
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
        return Achievement(id: "full-batch", title: String(localized: "Full batch"),
                           detail: best.map { String(localized: "Every vehicle of one delivery. Closest: \($0.label)") } ?? String(localized: "Every vehicle of one delivery batch"),
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
        return Achievement(id: "model-complete", title: String(localized: "Complete set"),
                           detail: best.map { String(localized: "Every vehicle of one model. Closest: \($0.name)") } ?? String(localized: "Every vehicle of one model"),
                           symbol: "checkmark.seal.fill", progress: best?.have ?? 0, goal: best?.size ?? 1)
    }

    static func rainbowDay(_ c: Context) -> Achievement {
        let wanted: Set<Tier> = [.legendary, .gold, .rare, .common]
        let score = { (day: [SightingRecord]) in Set(day.compactMap { c.model($0)?.tier }).intersection(wanted).count }
        let bestDay = c.byDay.values.max { score($0) < score($1) } ?? []
        // The day's first of each colour, rarest first.
        let proof = Tier.allCases.filter(wanted.contains).compactMap { tier in
            bestDay.sorted { $0.date < $1.date }.first { c.model($0)?.tier == tier }
                .map { Achievement.Proof(modelId: $0.modelId, number: $0.number, note: tier.name) }
        }
        return Achievement(id: "rainbow-day", title: String(localized: "Rainbow day"), detail: String(localized: "A LEGENDARY, GOLD, RARE and COMMON in one day"),
                           symbol: "rainbow", progress: score(bestDay), goal: wanted.count, proof: proof)
    }

    // MARK: Days out

    /// A coupled tram is one tram out on the street, so its second car doesn't add one.
    static func tramDay(_ c: Context) -> Achievement {
        let trams = { (day: [SightingRecord]) in
            c.proof(day.filter { c.model($0)?.kind == .tram && $0.pairedWith == nil }.sorted { $0.date < $1.date })
        }
        let best = c.byDay.values.map(trams).max { $0.count < $1.count } ?? []
        return Achievement(id: "trams-day", title: String(localized: "Tram day"), detail: String(localized: "\(tramsInADay) different trams in one day"),
                           symbol: "tram.fill", progress: best.count, goal: tramsInADay, proof: best)
    }

    /// Meteorological seasons: winter is December to February.
    static func fourSeasons(_ c: Context) -> Achievement {
        let season = { (s: SightingRecord) in c.calendar.component(.month, from: s.date) % 12 / 3 }
        let names = [String(localized: "WINTER"), String(localized: "SPRING"), String(localized: "SUMMER"), String(localized: "AUTUMN")]
        // The first catch of each season.
        let firsts = Dictionary(grouping: c.sightings, by: season).compactMap { ($0.key, $0.value.min { $0.date < $1.date }!) }
            .sorted { $0.0 < $1.0 }
        let proof = firsts.map { Achievement.Proof(modelId: $0.1.modelId, number: $0.1.number, note: names[$0.0]) }
        return Achievement(id: "four-seasons", title: String(localized: "Four seasons"), detail: String(localized: "A catch in winter, spring, summer and autumn"),
                           symbol: "leaf.fill", progress: firsts.count, goal: 4, proof: proof)
    }

    static func oldFriend(_ c: Context) -> Achievement {
        let most = c.stats.vehicles.map(\.timesSeen).max() ?? 0
        let proof = c.stats.vehicles.filter { $0.timesSeen == most && most > 1 }
            .map { Achievement.Proof(modelId: $0.modelId, number: $0.number, note: String(localized: "SEEN \($0.timesSeen)×")) }
        return Achievement(id: "old-friend", title: String(localized: "Old friend"), detail: String(localized: "The same vehicle seen 10 times"), symbol: "heart.fill",
                           progress: most, goal: 10, proof: proof)
    }

    static func freshOffTheLine(_ c: Context) -> Achievement {
        let fresh = c.sightings.filter { s in
            c.model(s)?.batch(containing: s.number)?.year == c.year(s.date)
        }
        return Achievement(id: "fresh", title: String(localized: "Fresh off the line"), detail: String(localized: "A vehicle delivered the year you caught it"),
                           symbol: "shippingbox.fill", progress: fresh.isEmpty ? 0 : 1, goal: 1,
                           proof: c.proof(fresh) { String(localized: "BUILT \(String(c.year($0.date)))") })
    }

    static func veteran(_ c: Context) -> Achievement {
        let ages = c.sightings.compactMap { s -> (SightingRecord, Int)? in
            guard let m = c.model(s), m.regular, let y = m.batch(containing: s.number)?.year else { return nil }
            return (s, c.year(s.date) - y)
        }.sorted { $0.1 > $1.1 }
        let oldest = ages.first?.1 ?? 0
        // Every one old enough, or, until then, the oldest so far.
        let shown = oldest >= 20 ? ages.filter { $0.1 >= 20 } : Array(ages.prefix(1))
        let age = Dictionary(shown.map { ("\($0.0.modelId)#\($0.0.number)", $0.1) }) { a, b in max(a, b) }
        return Achievement(id: "veteran", title: String(localized: "Veteran"), detail: String(localized: "A vehicle still in service at 20 years old"),
                           symbol: "medal.fill", progress: max(oldest, 0), goal: 20,
                           proof: c.proof(shown.map(\.0)) { String(localized: "\(age["\($0.modelId)#\($0.number)"] ?? 0) YEARS OLD") })
    }

    /// Each vehicle counts for its own batch's operator: Urbino 18 CNGs run for MZA and
    /// ReloBus, and #9925 is ReloBus's (#35). Older fleet files fall back to the model's main one.
    static func allOperators(_ c: Context) -> Achievement? {
        let regular = c.catalog.models.filter { $0.regular }
        let all = Set(regular.flatMap { m in m.batches.compactMap { $0.operator ?? m.operators.first } })
        guard !all.isEmpty else { return nil }
        let op = { (s: SightingRecord) -> String? in
            guard let m = c.model(s), m.regular else { return nil }
            return m.batch(containing: s.number)?.operator ?? m.operators.first
        }
        // Your first catch from each operator.
        var first: [String: SightingRecord] = [:]
        for s in c.sightings.sorted(by: { $0.date < $1.date }) {
            if let o = op(s), first[o] == nil { first[o] = s }
        }
        let proof = first.sorted { $0.key < $1.key }
            .map { o, s in Achievement.Proof(modelId: s.modelId, number: s.number, note: o.uppercased()) }
        return Achievement(id: "all-operators", title: String(localized: "Every operator"), detail: String(localized: "A vehicle from all \(all.count) operators"),
                           symbol: "person.3.fill", progress: first.count, goal: all.count, proof: proof,
                           missing: all.subtracting(first.keys).sorted(by: plOrder).map { Achievement.Missing($0) })
    }

    // MARK: Places

    /// By the catch's coordinates: the geocoder's name is usually a neighbourhood ("Grochów"),
    /// so it's only the fallback, for catches without them or in a sliver between two outlines.
    static func everyDistrict(_ c: Context) -> Achievement {
        let byDistrict = Dictionary(grouping: c.sightings.sorted { $0.date < $1.date }) { s in
            let named = s.district.flatMap(district(of:))
            guard let lat = s.latitude, let lon = s.longitude else { return named }
            return Districts.at(lat, lon) ?? (Geo.inWarsaw(lat, lon) ? named : nil)
        }
        let proof = byDistrict.compactMap { d, ss in d.map { Achievement.Proof(modelId: ss[0].modelId, number: ss[0].number, note: $0.uppercased()) } }
            .sorted { ($0.note ?? "") < ($1.note ?? "") }
        return Achievement(id: "every-district", title: String(localized: "Every district"), detail: String(localized: "A catch in all \(districts.count) districts of Warsaw"),
                           symbol: "map.fill", progress: proof.count, goal: districts.count, proof: proof,
                           missing: districts.filter { byDistrict[$0] == nil }.map { Achievement.Missing($0) })
    }

    /// Two catches on the same day at least 15 km apart.
    static func explorer(_ c: Context) -> Achievement {
        var best = 0.0
        var pair: (SightingRecord, SightingRecord)?
        for day in c.byDay.values {
            let placed = day.filter { $0.latitude != nil && $0.longitude != nil }.sorted { $0.date < $1.date }
            for i in placed.indices {
                for j in placed.indices where j > i {
                    let d = Geo.km((placed[i].latitude!, placed[i].longitude!), (placed[j].latitude!, placed[j].longitude!))
                    if d > best { (best, pair) = (d, (placed[i], placed[j])) }
                }
            }
        }
        let proof = pair.map { a, b in
            [Achievement.Proof(modelId: a.modelId, number: a.number, note: a.district?.uppercased()),
             Achievement.Proof(modelId: b.modelId, number: b.number, note: String(localized: "\(Int(best)) KM LATER"))]
        } ?? []
        return Achievement(id: "explorer", title: String(localized: "Explorer"), detail: String(localized: "Two catches 15 km apart on the same day"),
                           symbol: "location.north.line.fill", progress: Int(best), goal: 15, proof: proof)
    }

    static func suburbanite(_ c: Context) -> Achievement {
        let outside = c.sightings.filter { s in
            guard let lat = s.latitude, let lon = s.longitude else { return false }
            return !Geo.inWarsaw(lat, lon)
        }
        return Achievement(id: "suburbanite", title: String(localized: "Suburbanite"), detail: String(localized: "A catch outside Warsaw"),
                           symbol: "house.and.flag.fill", progress: outside.isEmpty ? 0 : 1, goal: 1,
                           proof: c.proof(outside) { $0.district?.uppercased() })
    }

    static func busyStreet(_ c: Context) -> Achievement {
        let line = { (s: SightingRecord) in s.line?.trimmingCharacters(in: .whitespaces).uppercased() }
        let perStreet = Dictionary(grouping: c.sightings.filter { $0.street != nil && $0.line != nil }.sorted { $0.date < $1.date }) {
            $0.street!.lowercased()
        }
        let busiest = perStreet.values.max { Set($0.compactMap(line)).count < Set($1.compactMap(line)).count } ?? []
        // A vehicle per line, on the street with the most of them.
        var lines = Set<String>()
        let proof = busiest.filter { s in line(s).map { lines.insert($0).inserted } ?? false }
            .map { Achievement.Proof(modelId: $0.modelId, number: $0.number, note: String(localized: "LINE \(line($0) ?? "")")) }
        return Achievement(id: "busy-street", title: String(localized: "Busy street"), detail: String(localized: "5 different lines caught on one street"),
                           symbol: "road.lanes", progress: lines.count, goal: 5, proof: proof)
    }

    // MARK: Weather

    static func weather(_ c: Context, id: String, title: String, detail: String, symbol: String, secret: Bool = false,
                        _ match: (SightingRecord) -> Bool) -> Achievement {
        let hits = c.sightings.filter(match)
        return Achievement(id: id, title: title, detail: detail, symbol: symbol,
                           progress: hits.isEmpty ? 0 : 1, goal: 1, secret: secret,
                           proof: c.proof(hits) { $0.temperature.map { "\(Int($0.rounded())) °C" } })
    }

    // MARK: Secrets

    static func onDate(_ c: Context, id: String, title: String, detail: String, symbol: String, month: Int, day: Int) -> Achievement {
        let hits = c.sightings.filter {
            let d = c.calendar.dateComponents([.month, .day], from: $0.date)
            return d.month == month && d.day == day
        }
        return Achievement(id: id, title: title, detail: detail, symbol: symbol, progress: hits.isEmpty ? 0 : 1, goal: 1, secret: true,
                           proof: c.proof(hits) { String(c.year($0.date)) })
    }

    /// A catch on the date of your very first one, a year or more later.
    static func anniversary(_ c: Context) -> Achievement {
        var hits: [SightingRecord] = []
        if let first = c.sightings.map(\.date).min() {
            let f = c.calendar.dateComponents([.year, .month, .day], from: first)
            hits = c.sightings.filter {
                let d = c.calendar.dateComponents([.year, .month, .day], from: $0.date)
                return d.month == f.month && d.day == f.day && (d.year ?? 0) > (f.year ?? 0)
            }
        }
        return Achievement(id: "anniversary", title: String(localized: "Anniversary"), detail: String(localized: "A catch one year to the day after your first"),
                           symbol: "birthday.cake.fill", progress: hits.isEmpty ? 0 : 1, goal: 1, secret: true,
                           proof: c.proof(hits) { String(c.year($0.date)) })
    }

    /// Two back-to-back fleet numbers of the same model. A coupled tram's two cars are often
    /// back to back, so a car added as the other's second car doesn't make a pair with it.
    static func twins(_ c: Context) -> Achievement {
        let caught = Dictionary(grouping: c.sightings) { "\($0.modelId)#\($0.number)" }
        let apart = { (id: String, n: Int, other: Int) in
            caught["\(id)#\(n)"]?.contains { $0.pairedWith != other } ?? false
        }
        let pairs = c.owned.flatMap { id, nums in
            nums.filter { nums.contains($0 + 1) && apart(id, $0, $0 + 1) && apart(id, $0 + 1, $0) }.sorted().flatMap { n in
                [Achievement.Proof(modelId: id, number: n), Achievement.Proof(modelId: id, number: n + 1)]
            }
        }
        var seen = Set<Achievement.Proof>()
        return Achievement(id: "twins", title: String(localized: "Twins"), detail: String(localized: "Two back-to-back fleet numbers of the same model"),
                           symbol: "person.2.fill", progress: pairs.isEmpty ? 0 : 1, goal: 1, secret: true,
                           proof: pairs.filter { seen.insert($0).inserted })
    }

    static func roundNumber(_ c: Context) -> Achievement {
        let hits = c.sightings.filter { $0.number > 0 && $0.number % 100 == 0 }
        return Achievement(id: "round-number", title: String(localized: "Round number"), detail: String(localized: "A fleet number ending in 00"),
                           symbol: "circle.circle.fill", progress: hits.isEmpty ? 0 : 1, goal: 1, secret: true, proof: c.proof(hits))
    }

    static func palindrome(_ c: Context) -> Achievement {
        let hits = c.sightings.filter { $0.number >= 100 && isPalindrome($0.number) }
        return Achievement(id: "palindrome", title: String(localized: "Palindrome"), detail: String(localized: "A fleet number that reads the same backwards"),
                           symbol: "arrow.left.arrow.right", progress: hits.isEmpty ? 0 : 1, goal: 1, secret: true, proof: c.proof(hits))
    }

    /// A bus and a tram carrying the same fleet number.
    static func doubleLife(_ c: Context) -> Achievement {
        var byKind: [VehicleKind: Set<Int>] = [:]
        for s in c.sightings {
            if let kind = c.model(s)?.kind { byKind[kind, default: []].insert(s.number) }
        }
        let shared = (byKind[.bus] ?? []).intersection(byKind[.tram] ?? [])
        return Achievement(id: "double-life", title: String(localized: "Double life"), detail: String(localized: "A bus and a tram with the same number"),
                           symbol: "theatermasks.fill", progress: shared.isEmpty ? 0 : 1, goal: 1, secret: true,
                           proof: c.proof(c.sightings.filter { shared.contains($0.number) }.sorted { $0.number < $1.number }) { c.model($0)?.kind.name })
    }

    static func dejaVu(_ c: Context) -> Achievement {
        let twice = c.byDay.values.flatMap { day in
            Dictionary(grouping: day) { "\($0.modelId)#\($0.number)" }.values.filter { $0.count > 1 }.map { $0[0] }
        }
        return Achievement(id: "deja-vu", title: String(localized: "Déjà vu"), detail: String(localized: "The same vehicle twice in one day"),
                           symbol: "arrow.triangle.2.circlepath", progress: twice.isEmpty ? 0 : 1, goal: 1, secret: true,
                           proof: c.proof(twice.sorted { $0.date < $1.date }))
    }

    // MARK: Depots

    /// One badge per depot: a vehicle of every model based there, caught from that depot's batches.
    static func depots(_ c: Context) -> [Achievement] {
        c.catalog.depots.compactMap { d in
            let atDepot = { (b: Batch) in b.depotCode == d.code && b.depotName == d.name }
            let models = c.catalog.models.filter { m in m.regular && m.kind == d.kind && m.batches.contains(where: atDepot) }
            guard !models.isEmpty else { return nil }
            let caught = { (m: VehicleModel) in
                let mine = c.owned[m.id] ?? []
                return m.batches.contains { atDepot($0) && $0.numbers.contains(where: mine.contains) }
            }
            let have = models.filter(caught).count
            return Achievement(id: "depot-\(d.kind.rawValue)-\(d.code)-\(d.name)",
                               title: d.code.isEmpty ? d.name : "\(d.code) \(d.name)",
                               detail: d.kind == .tram ? String(localized: "Every tram model at the depot")
                                   : String(localized: "Every bus model at the depot"),
                               symbol: d.kind == .tram ? "tram.fill.tunnel" : "bus.doubledecker.fill",
                               progress: have, goal: models.count,
                               missing: models.filter { !caught($0) }.sorted { ($0.name, $0.firstYear ?? 0) < ($1.name, $1.firstYear ?? 0) }.map { m in
                                   // Two Conecto Gs share R-2 Kleszczowa: their years tell them apart.
                                   let twin = models.filter { $0.name == m.name }.count > 1
                                   return Achievement.Missing(twin ? [m.name, m.yearsDisplay].compactMap { $0 }.joined(separator: " ") : m.name,
                                                              modelId: m.id)
                               })
        }
    }

    // MARK: Helpers

    /// Polish alphabetical order, so "Średnicki" comes after "ReloBus", not after "Z".
    static func plOrder(_ a: String, _ b: String) -> Bool {
        a.compare(b, locale: Locale(identifier: "pl_PL")) == .orderedAscending
    }

    /// "1,000" (the separator comes from the string catalog, not the device's region, so
    /// it matches the language the badge is written in).
    static func thousands(_ n: Int) -> String {
        let sep = String(localized: "thousands.separator", defaultValue: ",", comment: "Digit group separator in badge goals, e.g. 1,000")
        return n >= 1000 ? "\(n / 1000)\(sep)\(String(format: "%03d", n % 1000))" : String(n)
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

/// Which of Warsaw's districts a point is in, from their outlines (Districts.swift, generated).
public enum Districts {
    private struct Shape {
        let name: String
        let ring: [(latitude: Double, longitude: Double)]
        let lat: ClosedRange<Double>, lon: ClosedRange<Double>
    }

    private static let shapes: [Shape] = encoded.map { name, polyline in
        let ring = Polyline.decode(polyline)
        return Shape(name: name, ring: ring,
                     lat: ring.map(\.latitude).min()!...ring.map(\.latitude).max()!,
                     lon: ring.map(\.longitude).min()!...ring.map(\.longitude).max()!)
    }

    /// nil outside the city, and in the few-metre slivers simplifying leaves between neighbours.
    public static func at(_ lat: Double, _ lon: Double) -> String? {
        shapes.first { s in
            guard s.lat.contains(lat), s.lon.contains(lon) else { return false }
            // Ray casting: an odd number of edge crossings to the east means inside.
            var inside = false
            var j = s.ring.count - 1
            for i in s.ring.indices {
                let a = s.ring[i], b = s.ring[j]
                if (a.latitude > lat) != (b.latitude > lat),
                   lon < (b.longitude - a.longitude) * (lat - a.latitude) / (b.latitude - a.latitude) + a.longitude {
                    inside.toggle()
                }
                j = i
            }
            return inside
        }?.name
    }
}
