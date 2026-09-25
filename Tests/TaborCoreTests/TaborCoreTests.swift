import Foundation
import Testing
@testable import TaborCore

private let catalog: FleetCatalog = {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Tabor/Resources/fleet.json")
    return try! FleetCatalog(json: Data(contentsOf: url))
}()

private func sampleModel() -> VehicleModel {
    VehicleModel(id: "test", name: "Yutong U12", make: "Yutong", kind: .bus, operators: ["MZA"],
                 fleet: 6, firstYear: 2024, lastYear: 2026, batches: [
                     Batch(year: 2026, depotCode: "R-1", depotName: "Woronicza", numbers: [1940, 1941, 1942]),
                     Batch(year: 2024, depotCode: "R-1", depotName: "Woronicza", numbers: [1974, 1975, 1976]),
                 ])
}

// MARK: - Data

@Test func fleetJsonIsTheZtmSnapshot() {
    #expect(catalog.models.count > 40)
    #expect(catalog.totalFleet > 2500)
    #expect(Set(catalog.models.map(\.id)).count == catalog.models.count)
    #expect(catalog.models.allSatisfy { $0.fleet == $0.numbers.count })
}

@Test func tierThresholdsMatchPrototype() {
    #expect(Tier.of(fleet: 4) == .legendary)
    #expect(Tier.of(fleet: 12) == .legendary)
    #expect(Tier.of(fleet: 48) == .gold)
    #expect(Tier.of(fleet: 49) == .rare)
    #expect(Tier.of(fleet: 80) == .rare)
    #expect(Tier.of(fleet: 186) == .common)
}

@Test func vintageStockIsItsOwnTierAndOutsideTheFleet() {
    let vintage = catalog.models.filter(\.vintage)
    #expect(vintage.contains { $0.id == "tram-falkenried-a" })
    #expect(vintage.allSatisfy { $0.tier == .vintage })
    // The 112N prototype still runs on regular lines: a real legendary, not vintage.
    #expect(catalog.model(id: "tram-konstal-112n")?.tier == .legendary)
    let all = catalog.models.reduce(0) { $0 + $1.fleet }
    #expect(catalog.totalFleet == all - vintage.reduce(0) { $0 + $1.fleet })
    let stats = CollectionStats(sightings: [SightingRecord(number: 43, modelId: "tram-falkenried-a", date: .now)])
    #expect(stats.fleetShare(catalog: catalog) == 0)
}

// MARK: - Lookup

@Test func knownVehiclesResolve() {
    // Cross-checked against api.zbiorkom.live: 3/8592 → Solaris Urbino 18, 2013, MZA.
    let m = catalog.match(number: 8592, kind: .bus).suggested
    #expect(m?.name == "Solaris Urbino 18")
    #expect(m?.batch(containing: 8592)?.year == 2013)
}

@Test func numberOnBothBusAndTramIsAmbiguousInAuto() {
    guard case .ambiguous(let ms) = catalog.match(number: 1411) else {
        Issue.record("expected ambiguous"); return
    }
    #expect(Set(ms.map(\.kind)) == [.bus, .tram])
    #expect(catalog.match(number: 1411, kind: .tram).suggested?.kind == .tram)
}

@Test func unknownNumber() {
    #expect(catalog.match(number: 99_999) == .unknown)
}

@Test func manualAssignmentWins() {
    let tram = catalog.models.first { $0.kind == .tram }!
    #expect(catalog.match(number: 8592, manual: [8592: tram.id]) == .certain(tram))
}

// MARK: - OCR

@Test func digitTokens() {
    #expect(NumberExtractor.digitTokens("8465").map(\.value) == [8465])
    #expect(NumberExtractor.digitTokens("Nr 1974 linia 119").map(\.value) == [1974, 119])
    #expect(NumberExtractor.digitTokens("123456 20:15 3.1415").isEmpty)
    #expect(NumberExtractor.digitTokens("WI 5814N").isEmpty)
    #expect(NumberExtractor.digitTokens("-WX 2043F").isEmpty)
    // OCR dropped the plate's trailing letter (seen on device: "IX 2021" for "WX 2021F").
    #expect(NumberExtractor.digitTokens("IX 2021").isEmpty)
    #expect(NumberExtractor.digitTokens("WX-2021").isEmpty)
    #expect(NumberExtractor.digitTokens("NR 1974").map(\.value) == [1974])
    #expect(NumberExtractor.digitTokens("LINIA 119").map(\.value) == [119])
}

@Test func extractorPrefersDatabaseHits() {
    let obs = [
        TextObservation(text: "0000", confidence: 1, height: 0.1),
        TextObservation(text: "8592", confidence: 0.8, height: 0.05),
    ]
    #expect(NumberExtractor.best(in: obs, mode: .auto, catalog: catalog) == 8592)
}

@Test func extractorIgnoresUnknownShortNumbers() {
    // A line number on its own must not be read as a fleet number.
    let obs = [TextObservation(text: "705", confidence: 1, height: 0.2)]
    let got = NumberExtractor.best(in: obs, mode: .bus, catalog: catalog)
    #expect(got == nil || catalog.isKnown(number: got!, kind: .bus))
}

@Test func modeIsAPreferenceNotAFilter() {
    // Seen on device: Yutong 1971 shot in TRAM mode, plate "WX 2021F" read as "IX 2021".
    let obs = [
        TextObservation(text: "192 KRASNOWOLA", confidence: 1, height: 0.05),
        TextObservation(text: "1971", confidence: 1, height: 0.02),
        TextObservation(text: "IX 2021", confidence: 1, height: 0.02),
    ]
    #expect(NumberExtractor.best(in: obs, mode: .tram, catalog: catalog) == 1971)
    #expect(catalog.match(number: 1971, kind: .tram) == .unknown)
    #expect(catalog.match(number: 1971, preferring: .tram).suggested?.id == "bus-yutong-u12-b")
}

@Test func preservedBusesOutsideZtmAreVintage() {
    // KMKM's Solaris Urbino 15 #8731 isn't in the ZTM database.
    let m = catalog.match(number: 8731, kind: .bus).suggested
    #expect(m?.name == "Solaris Urbino 15" && m?.tier == .vintage)
    // A club Jelcz shares 1983 with a Yutong: the regular bus is suggested first.
    #expect(catalog.match(number: 1983, kind: .bus).suggested?.id == "bus-yutong-u12-b")
    // Club-owned 105Na sets are split from the regular 105Na.
    #expect(catalog.match(number: 1001, kind: .tram).suggested?.id == "tram-konstal-105n-vintage")
}

@Test func voterNeedsAgreement() {
    var v = NumberVoter(window: 5, needed: 3)
    #expect(v.push(1974) == nil)
    #expect(v.push(1979) == nil)
    #expect(v.push(1974) == nil)
    #expect(v.push(1974) == 1974)
}

// MARK: - Collection

@Test func streakCountsConsecutiveDays() {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "Europe/Warsaw")!
    let now = cal.date(from: DateComponents(year: 2026, month: 9, day: 22, hour: 12))!
    func d(_ back: Int) -> Date { cal.date(byAdding: .day, value: -back, to: now)! }
    #expect(Streak.days([d(0), d(1), d(2), d(4)], now: now, calendar: cal) == 3)
    #expect(Streak.days([d(1), d(2)], now: now, calendar: cal) == 2)
    #expect(Streak.days([d(2)], now: now, calendar: cal) == 0)
    #expect(Streak.days([], now: now, calendar: cal) == 0)
}

@Test func collectionDedupesAndRanksRarest() {
    let now = Date()
    let common = catalog.models.max { $0.fleet < $1.fleet }!
    let rare = catalog.models.min { $0.fleet < $1.fleet }!
    let stats = CollectionStats(sightings: [
        SightingRecord(number: common.numbers[0], modelId: common.id, date: now),
        SightingRecord(number: common.numbers[0], modelId: common.id, date: now.addingTimeInterval(60)),
        SightingRecord(number: rare.numbers[0], modelId: rare.id, date: now),
    ])
    #expect(stats.caught == 2)
    #expect(stats.vehicle(number: common.numbers[0], modelId: common.id)?.timesSeen == 2)
    #expect(stats.rarest(catalog: catalog, limit: 1).first?.modelId == rare.id)
}

@Test func revealHintTalksAboutTheBatch() {
    let m = sampleModel()
    #expect(RevealHint.text(model: m, number: 1975, owned: [1974, 1975], isNewVehicle: true, timesSeen: 1)
        == "One more — 1976 — and the 2024 batch is done.")
    #expect(RevealHint.text(model: m, number: 1974, owned: [1974], isNewVehicle: false, timesSeen: 3)
        .contains("#3"))
    #expect(RevealHint.text(model: m, number: 1942, owned: Set(m.numbers), isNewVehicle: true, timesSeen: 1)
        .contains("Model complete"))
}

@Test func ordinals() {
    #expect(Ordinal.string(1) == "1st")
    #expect(Ordinal.string(12) == "12th")
    #expect(Ordinal.string(23) == "23rd")
}

// MARK: - Achievements

private func badge(_ id: String, _ sightings: [SightingRecord]) -> Achievement {
    Achievements.evaluate(sightings, catalog: catalog).first { $0.id == id }!
}

@Test func fullBatchBadge() {
    let m = catalog.models.first { !$0.vintage && $0.batches.contains { $0.numbers.count == 2 } }!
    let b = m.batches.first { $0.numbers.count == 2 }!
    let half = badge("full-batch", [SightingRecord(number: b.numbers[0], modelId: m.id, date: .now)])
    #expect(!half.earned && half.progress >= 1)
    let full = badge("full-batch", b.numbers.map { SightingRecord(number: $0, modelId: m.id, date: .now) })
    #expect(full.earned)
    #expect(badge("full-batch", []).progress == 0)
}

@Test func legendaryBadgeNeedsOneOfEach() {
    let legendary = catalog.models.filter { $0.tier == .legendary }
    #expect(legendary.count >= 5)
    let all = legendary.map { SightingRecord(number: $0.numbers[0], modelId: $0.id, date: .now) }
    #expect(badge("legendary-all", all).earned)
    #expect(badge("legendary-all", all.dropLast()).progress == legendary.count - 1)
    #expect(badge("legendary-all", all).title == "All \(legendary.count) legendary")
}

@Test func districtNamesFromTheGeocoder() {
    #expect(Achievements.district(of: "Mokotów") == "Mokotów")
    #expect(Achievements.district(of: "Stary Mokotów") == "Mokotów")
    #expect(Achievements.district(of: "Praga Południe") == "Praga-Południe")
    #expect(Achievements.district(of: "Śródmieście Północne") == "Śródmieście")
    #expect(Achievements.district(of: "Ursynów") == "Ursynów")
    #expect(Achievements.district(of: "Muranów") == nil)
    let all = Achievements.districts.enumerated().map { i, d in
        SightingRecord(number: i, modelId: "x", date: .now, district: d)
    }
    #expect(badge("every-district", all).earned)
    #expect(badge("every-district", all + all).progress == 18)
    #expect(badge("every-district", Array(all.prefix(3))).progress == 3)
}

@Test func tramDayCountsDistinctTramsOnOneDay() {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "Europe/Warsaw")!
    let noon = cal.date(from: DateComponents(year: 2026, month: 9, day: 22, hour: 12))!
    let tram = catalog.models.filter { $0.kind == .tram }.max { $0.fleet < $1.fleet }!
    let bus = catalog.models.first { $0.kind == .bus }!
    var day = tram.numbers.prefix(9).map { SightingRecord(number: $0, modelId: tram.id, date: noon) }
    day.append(SightingRecord(number: tram.numbers[0], modelId: tram.id, date: noon.addingTimeInterval(60)))
    day.append(SightingRecord(number: bus.numbers[0], modelId: bus.id, date: noon))
    day.append(SightingRecord(number: tram.numbers[9], modelId: tram.id, date: noon.addingTimeInterval(86_400)))
    let nine = Achievements.evaluate(day, catalog: catalog, calendar: cal).first { $0.id == "trams-day" }!
    #expect(nine.progress == 9 && !nine.earned)
    day.append(SightingRecord(number: tram.numbers[10], modelId: tram.id, date: noon.addingTimeInterval(3600)))
    #expect(Achievements.evaluate(day, catalog: catalog, calendar: cal).first { $0.id == "trams-day" }!.earned)
}

@Test func linesBadgeCountsDistinctLines() {
    let s = (1...50).map { SightingRecord(number: $0, modelId: "x", date: .now, line: String($0)) }
    #expect(badge("lines", s).level == 2 && badge("lines", s).goal == 100)
    let dupes = [SightingRecord(number: 1, modelId: "x", date: .now, line: "n14"),
                 SightingRecord(number: 2, modelId: "x", date: .now, line: " N14 "),
                 SightingRecord(number: 3, modelId: "x", date: .now, line: "")]
    #expect(badge("lines", dupes).progress == 1 && !badge("lines", dupes).earned)
}

@Test func depotBadgeNeedsEveryModelFromThatDepot() {
    let depots = Achievements.evaluate([], catalog: catalog).filter(\.isDepot)
    #expect(!depots.isEmpty)
    let r4 = depots.first { $0.id == "depot-BUS-R-4-Stalowa" }!
    #expect(r4.title == "R-4 Stalowa" && r4.goal > 1 && r4.progress == 0)
    let atR4 = catalog.models.compactMap { m -> SightingRecord? in
        guard !m.vintage, m.kind == .bus,
              let b = m.batches.first(where: { $0.depotCode == "R-4" && $0.depotName == "Stalowa" }) else { return nil }
        return SightingRecord(number: b.numbers[0], modelId: m.id, date: .now)
    }
    #expect(badge("depot-BUS-R-4-Stalowa", atR4).earned)
    // The same models caught from another depot don't count.
    #expect(badge("depot-TRAM-R-4-Żoliborz", atR4).progress == 0)
}

// MARK: - Fleet updates

private func fleet(_ fetched: String?) -> FleetCatalog {
    FleetCatalog(data: FleetData(source: "", fetched: fetched, models: [sampleModel()], depots: []))
}

@Test func downloadedFleetOnlyWinsWhileNewer() {
    let bundled = fleet("2026-09-22")
    #expect(FleetCatalog.preferred(bundled: bundled, downloaded: fleet("2026-09-29"))?.fetched == "2026-09-29")
    #expect(FleetCatalog.preferred(bundled: bundled, downloaded: fleet("2026-09-01"))?.fetched == "2026-09-22")
    #expect(FleetCatalog.preferred(bundled: bundled, downloaded: nil)?.fetched == "2026-09-22")
    #expect(FleetCatalog.preferred(bundled: nil, downloaded: fleet("2026-09-01"))?.fetched == "2026-09-01")
    #expect(FleetCatalog.preferred(bundled: nil, downloaded: nil) == nil)
    #expect(!fleet(nil).isNewer(than: bundled))
}

@Test func validationRejectsBrokenFleetFiles() throws {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Tabor/Resources/fleet.json")
    #expect(FleetCatalog.validated(json: try Data(contentsOf: url)) != nil)
    #expect(FleetCatalog.validated(json: Data("<html>404</html>".utf8)) == nil)
    #expect(FleetCatalog.validated(json: Data(#"{"source":"","fetched":"2026-01-01","models":[],"depots":[]}"#.utf8)) == nil)
    #expect(FleetCatalog.empty.models.isEmpty && FleetCatalog.empty.totalFleet == 0)
}

// MARK: - Backup

@Test func backupRoundTripsThroughZip() throws {
    let s = BackupManifest.Sighting(id: UUID(), number: 1974, modelId: "test",
                                    date: Date(timeIntervalSince1970: 1_790_000_000), latitude: 52.2,
                                    longitude: 21.0, street: "Rakowiecka", district: "Mokotów", line: "N14",
                                    photoFile: "a.jpg", stickerFile: "a.png")
    let manifest = BackupManifest(sightings: [s], manual: [.init(number: 1974, modelId: "test")])
    let photo = Data((0..<5000).map { UInt8($0 % 251) })
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("tabor-test-\(UUID()).zip")
    defer { try? FileManager.default.removeItem(at: url) }
    let zip = try ZipWriter(url: url)
    try zip.add(path: BackupManifest.fileName, data: manifest.encoded())
    try zip.add(path: BackupManifest.photosFolder + "a.jpg", data: photo)
    try zip.add(path: BackupManifest.photosFolder + "empty.png", data: Data())
    try zip.finish()

    let reader = try ZipReader(url: url)
    #expect(reader.entries.count == 3)
    let back = try BackupManifest.decode(reader.read(try #require(reader.path(endingWith: BackupManifest.fileName))))
    #expect(back.sightings == [s] && back.manual == manifest.manual)
    #expect(try reader.read("photos/a.jpg") == photo)
    #expect(try reader.read("photos/empty.png").isEmpty)
    #expect(manifest.files == ["a.jpg", "a.png"])
}

@Test func zipReaderRejectsGarbage() {
    #expect(throws: ZipError.notAZip) { try ZipReader(data: Data("not a zip at all, sorry".utf8)) }
}

@Test func crcMatchesZlib() {
    #expect(CRC32.checksum(Data("123456789".utf8)) == 0xCBF4_3926)
}

@Test func importMergeSkipsWhatsAlreadyThere() {
    let a = BackupManifest.Sighting(id: UUID(), number: 1, modelId: "m", date: .now)
    let b = BackupManifest.Sighting(id: UUID(), number: 2, modelId: "m", date: .now)
    let manifest = BackupManifest(sightings: [a, b, a], manual: [.init(number: 1, modelId: "m"), .init(number: 2, modelId: "m")])
    let merged = manifest.merge(existingIds: [a.id], existingManual: [2])
    #expect(merged.sightings == [b])
    #expect(merged.manual == [.init(number: 1, modelId: "m")])
}

// MARK: - More badges

private let cal: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "Europe/Warsaw")!
    return c
}()

private func day(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
    cal.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
}

private func eval(_ s: [SightingRecord]) -> [String: Achievement] {
    Dictionary(uniqueKeysWithValues: Achievements.evaluate(s, catalog: catalog, calendar: cal).map { ($0.id, $0) })
}

private func any(_ modelId: String? = nil, number: Int? = nil, date: Date = day(2026, 5, 5), line: String? = nil,
                 street: String? = nil, lat: Double? = nil, lon: Double? = nil, code: Int? = nil,
                 temp: Double? = nil, sticker: Bool = false) -> SightingRecord {
    let m = modelId.flatMap(catalog.model(id:)) ?? catalog.models.first { !$0.vintage }!
    return SightingRecord(number: number ?? m.numbers[0], modelId: m.id, date: date, line: line, street: street,
                          latitude: lat, longitude: lon, weatherCode: code, temperature: temp, hasSticker: sticker)
}

@Test func badgeIdsAreUnique() {
    let all = Achievements.evaluate([], catalog: catalog)
    #expect(Set(all.map(\.id)).count == all.count)
    #expect(all.count > 40)
    #expect(all.allSatisfy { !$0.earned })
    #expect(all.contains { $0.secret })
}

@Test func tieredBadgesClimbLevels() {
    let big = catalog.models.max { $0.fleet < $1.fleet }!
    let caught = big.numbers.prefix(120).map { SightingRecord(number: $0, modelId: big.id, date: .now) }
    let collector = eval(caught)["collector"]!
    #expect(collector.level == 2 && collector.levels == 4 && collector.goal == 500 && collector.medal == .silver)
    #expect(collector.detail == "500 different vehicles")
    #expect(eval(Array(caught.prefix(9)))["collector"]!.level == 0)
    let share = eval(caught)["fleet-share"]!
    #expect(share.level == 1 && share.detail == "10% of Warsaw's fleet")
    #expect(Achievement.medal(level: 4, of: 4) == .platinum)
    #expect(Achievement.medal(level: 1, of: 1) == .gold)
    #expect(Achievement.medal(level: 3, of: 3) == .gold)
}

@Test func rarityBadges() {
    let single = catalog.models.first { !$0.vintage && $0.fleet == 1 }!
    #expect(eval([any(single.id)])["unicorn"]!.earned)
    #expect(!eval([any()])["unicorn"]!.earned)
    let gold = catalog.models.filter { $0.tier == .gold }
    #expect(eval(gold.map { any($0.id) })["gold-set"]!.earned)
    let rainbow = [Tier.legendary, .gold, .rare, .common].map { t in any(catalog.models.first { $0.tier == t }!.id) }
    #expect(eval(rainbow)["rainbow-day"]!.earned)
    #expect(eval(Array(rainbow.prefix(3)))["rainbow-day"]!.progress == 3)
    let pair = catalog.models.first { !$0.vintage && $0.fleet == 2 }!
    #expect(eval(pair.numbers.map { any(pair.id, number: $0) })["model-complete"]!.earned)
}

@Test func calendarBadges() {
    #expect(eval([any(date: day(2026, 12, 25))])["christmas"]!.earned)
    #expect(eval([any(date: day(2027, 1, 1, 0))])["new-year"]!.earned)
    #expect(!eval([any(date: day(2026, 12, 24, 23))])["christmas"]!.earned)
    let seasons = [1, 4, 7, 10].map { any(date: day(2026, $0, 3)) }
    #expect(eval(seasons)["four-seasons"]!.earned)
    #expect(eval([any(date: day(2026, 12, 3)), any(date: day(2026, 2, 3))])["four-seasons"]!.progress == 1)
    #expect(eval([any(date: day(2025, 3, 9)), any(date: day(2026, 3, 9, 8))])["anniversary"]!.earned)
    #expect(!eval([any(date: day(2025, 3, 9)), any(date: day(2025, 3, 9, 18))])["anniversary"]!.earned)
}

@Test func vehicleAgeBadges() {
    let m = catalog.models.first { !$0.vintage && $0.batches.contains { $0.year == 2024 } }!
    let n = m.batches.first { $0.year == 2024 }!.numbers[0]
    #expect(eval([any(m.id, number: n, date: day(2024, 6, 1))])["fresh"]!.earned)
    #expect(!eval([any(m.id, number: n, date: day(2026, 6, 1))])["fresh"]!.earned)
    let old = catalog.models.first { !$0.vintage && $0.batches.contains { ($0.year ?? 9999) <= 2005 } }!
    let on = old.batches.first { ($0.year ?? 9999) <= 2005 }!.numbers[0]
    #expect(eval([any(old.id, number: on, date: day(2026, 6, 1))])["veteran"]!.earned)
}

@Test func numberBadges() {
    #expect(Achievements.isPalindrome(1221) && Achievements.isPalindrome(3113) && !Achievements.isPalindrome(1974))
    let m = catalog.models.max { $0.fleet < $1.fleet }!
    let consecutive = m.numbers.first { m.numbers.contains($0 + 1) }!
    #expect(eval([any(m.id, number: consecutive), any(m.id, number: consecutive + 1)])["twins"]!.earned)
    #expect(!eval([any(m.id, number: consecutive)])["twins"]!.earned)
    if let round = catalog.models.first(where: { $0.numbers.contains { $0 % 100 == 0 } }) {
        #expect(eval([any(round.id, number: round.numbers.first { $0 % 100 == 0 })])["round-number"]!.earned)
    }
    guard case .ambiguous(let both) = catalog.match(number: 1411) else { Issue.record("no shared number"); return }
    #expect(eval(both.map { any($0.id, number: 1411) })["double-life"]!.earned)
    let twice = [any(date: day(2026, 5, 5, 9)), any(date: day(2026, 5, 5, 17))]
    #expect(eval(twice)["deja-vu"]!.earned)
    #expect(!eval([any(date: day(2026, 5, 5)), any(date: day(2026, 5, 6))])["deja-vu"]!.earned)
    #expect(eval(Array(repeating: any(), count: 10))["old-friend"]!.earned)
}

@Test func placeBadges() {
    // Wilanów to Białołęka is ~20 km.
    let far = [any(date: day(2026, 5, 5, 9), lat: 52.165, lon: 21.09), any(date: day(2026, 5, 5, 17), lat: 52.33, lon: 20.99)]
    #expect(eval(far)["explorer"]!.earned)
    let apart = [any(date: day(2026, 5, 5), lat: 52.165, lon: 21.09), any(date: day(2026, 5, 6), lat: 52.33, lon: 20.99)]
    #expect(!eval(apart)["explorer"]!.earned)
    #expect(Geo.km((52.2297, 21.0122), (50.0647, 19.945)) > 250) // Warsaw → Kraków
    #expect(eval([any(lat: 52.08, lon: 21.02)])["suburbanite"]!.earned) // Piaseczno
    #expect(!eval([any(lat: 52.23, lon: 21.01)])["suburbanite"]!.earned)
    let street = ["105", "112", "119", "N14", "4"].map { any(line: $0, street: "Puławska") }
    #expect(eval(street)["busy-street"]!.earned)
    #expect(eval(street.dropLast() + [any(line: "4", street: "Marszałkowska")])["busy-street"]!.progress == 4)
}

@Test func weatherBadges() {
    let e = eval([any(code: 73, temp: -2), any(code: 63, temp: 12), any(code: 96, temp: 31)])
    #expect(e["snow"]!.earned && e["rain"]!.earned && e["storm"]!.earned && e["heatwave"]!.earned)
    #expect(!e["deep-freeze"]!.earned)
    #expect(eval([any(temp: -10)])["deep-freeze"]!.earned)
    #expect(!eval([any()])["rain"]!.earned)
}

@Test func photographerAndOperators() {
    #expect(eval((0..<10).map { _ in any(sticker: true) })["photographer"]!.level == 1)
    let ops = eval([any()])["all-operators"]!
    #expect(ops.goal > 3 && ops.progress == 1)
}

// MARK: - Weather lookup

@Test func openMeteoPicksTheRightApiAndHour() {
    let now = Date(timeIntervalSince1970: 1_790_000_000)
    let recent = OpenMeteo.url(latitude: 52.229_7, longitude: 21.012_2, date: now.addingTimeInterval(-3600), now: now)
    #expect(recent.host == "api.open-meteo.com")
    #expect(recent.query!.contains("latitude=52.23") && recent.query!.contains("longitude=21.01"))
    let old = OpenMeteo.url(latitude: 52, longitude: 21, date: now.addingTimeInterval(-400 * 86_400), now: now)
    #expect(old.host == "archive-api.open-meteo.com")

    // 14:40 UTC rounds to the 15:00 reading.
    let catchTime = ISO8601DateFormatter().date(from: "2026-01-10T14:40:00Z")!
    let json = Data(#"""
    {"hourly":{"time":["2026-01-10T14:00","2026-01-10T15:00","2026-01-10T16:00"],
    "temperature_2m":[-3.1,-4.5,null],"weather_code":[3,73,null]}}
    """#.utf8)
    #expect(OpenMeteo.reading(from: json, at: catchTime) == .init(code: 73, temperature: -4.5))
    #expect(OpenMeteo.reading(from: json, at: catchTime.addingTimeInterval(3600)) == nil) // nulls
    #expect(OpenMeteo.reading(from: Data("{}".utf8), at: catchTime) == nil)
    #expect(Weather.isSnow(73) && Weather.isRain(61) && Weather.isStorm(95) && !Weather.isRain(3))
}
