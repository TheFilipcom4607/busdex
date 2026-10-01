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
    let extras = catalog.models.filter { !$0.regular }
    #expect(catalog.totalFleet == all - extras.reduce(0) { $0 + $1.fleet })
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

@Test func lookalikeLettersReadAsDigits() {
    #expect(NumberExtractor.lookalikeTokens("1O23").map(\.value) == [1023])
    #expect(NumberExtractor.lookalikeTokens("Nr I974").map(\.value) == [1974])
    #expect(NumberExtractor.lookalikeTokens("1o7l").isEmpty)
    // Plates, words and two letters in one run stay out.
    #expect(NumberExtractor.lookalikeTokens("WX 2O43").isEmpty)
    #expect(NumberExtractor.lookalikeTokens("WI 5814N").isEmpty)
    #expect(NumberExtractor.lookalikeTokens("SOLARIS").isEmpty)
    #expect(NumberExtractor.lookalikeTokens("IO23").isEmpty)
    // Plain digits are digitTokens' job, not counted twice.
    #expect(NumberExtractor.lookalikeTokens("8592").isEmpty)
}

@Test func extractorCorrectsLookalikesOnlyToKnownNumbers() {
    func read(_ text: String) -> Int? {
        NumberExtractor.best(in: [TextObservation(text: text, confidence: 1, height: 0.05)], mode: .auto, catalog: catalog)
    }
    #expect(read("1O23") == 1023)
    #expect(read("I974") == 1974)
    // 9099 and 1234 aren't in the fleet: a letter is too weak a guess on its own.
    #expect(read("9O99") == nil)
    #expect(read("1Z34") == nil)
    #expect(read("WX 2O43") == nil)
    #expect(read("WI 5814N") == nil)
    #expect(read("SOLARIS") == nil)
    #expect(read("IO23") == nil)
    // The same number read cleanly wins over the lookalike.
    let both = NumberExtractor.candidates(in: [TextObservation(text: "1O23 1023", confidence: 1, height: 0.05)],
                                          mode: .auto, catalog: catalog)
    #expect(both.count == 2 && abs(both[1].score - (both[0].score - 0.5)) < 1e-9)
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

@Test func trialBusIsOnTestAndOutsideTheFleet() {
    // The Irizar ie tram on trial with MZA isn't in the ZTM database.
    let m = catalog.match(number: 959, kind: .bus).suggested
    #expect(m?.name == "Irizar ie tram 12" && m?.tier == .onTest)
    #expect(m?.regular == false && m?.whereToFind?.contains("LINE 106") == true)
    // A single bus, but not a Unicorn or a LEGENDARY: it's only passing through.
    #expect(!catalog.models.filter { $0.tier == .legendary }.contains { $0.id == m?.id })
    #expect(Wanted.huntRank(.onTest) == Tier.legendary.rank)
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

@Test func viewfinderRegionMatchesAspectFill() {
    // A 3:4 upright frame filling a phone screen: the sides are cut off.
    let view = CGSize(width: 402, height: 874), image = CGSize(width: 3024, height: 4032)
    let whole = Viewfinder.region(of: CGRect(origin: .zero, size: view), in: view, imageSize: image)!
    #expect(abs(whole.minY) < 1e-9 && abs(whole.height - 1) < 1e-9)
    #expect(abs(whole.width - 402.0 / (3024 * 874.0 / 4032)) < 1e-9)
    #expect(abs(whole.midX - 0.5) < 1e-9)
    // Brackets in the middle land in the middle, and anything past the edge is clipped.
    let brackets = Viewfinder.region(of: CGRect(x: 20, y: 316, width: 362, height: 241), in: view, imageSize: image)!
    #expect(abs(brackets.midX - 0.5) < 1e-9 && abs(brackets.midY - 436.5 / 874) < 1e-9)
    let spill = Viewfinder.region(of: CGRect(x: -50, y: 800, width: 100, height: 200), in: view, imageSize: image)!
    #expect(spill.maxY == 1)
    #expect(Viewfinder.region(of: CGRect(x: 0, y: 900, width: 10, height: 10), in: view, imageSize: image) == nil)
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
    let m = catalog.models.first { $0.regular && $0.batches.contains { $0.numbers.count == 2 } }!
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
        guard m.regular, m.kind == .bus,
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
    let m = modelId.flatMap(catalog.model(id:)) ?? catalog.models.first { $0.regular }!
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
    let single = catalog.models.first { $0.regular && $0.fleet == 1 }!
    #expect(eval([any(single.id)])["unicorn"]!.earned)
    #expect(!eval([any()])["unicorn"]!.earned)
    let gold = catalog.models.filter { $0.tier == .gold }
    #expect(eval(gold.map { any($0.id) })["gold-set"]!.earned)
    let rainbow = [Tier.legendary, .gold, .rare, .common].map { t in any(catalog.models.first { $0.tier == t }!.id) }
    #expect(eval(rainbow)["rainbow-day"]!.earned)
    #expect(eval(Array(rainbow.prefix(3)))["rainbow-day"]!.progress == 3)
    // The smallest regular model with more than one vehicle, whatever the fleet data holds.
    let small = catalog.models.filter { $0.regular && $0.fleet >= 2 }.min { $0.fleet < $1.fleet }!
    #expect(eval(small.numbers.map { any(small.id, number: $0) })["model-complete"]!.earned)
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
    let m = catalog.models.first { $0.regular && $0.batches.contains { $0.year == 2024 } }!
    let n = m.batches.first { $0.year == 2024 }!.numbers[0]
    #expect(eval([any(m.id, number: n, date: day(2024, 6, 1))])["fresh"]!.earned)
    #expect(!eval([any(m.id, number: n, date: day(2026, 6, 1))])["fresh"]!.earned)
    let old = catalog.models.first { $0.regular && $0.batches.contains { ($0.year ?? 9999) <= 2005 } }!
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

// MARK: - Live fleet

private func fixture(_ name: String) -> Data {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/\(name)")
    return try! Data(contentsOf: url)
}

/// A minute after the fixtures were fetched from api.um.warszawa.pl.
private let fixtureNow = LiveFeed.warsawTime("2026-09-25 19:24:00")!

/// Plac Defilad, and a point `metres` due north of it.
private let here = (lat: 52.2319, lon: 21.0067)
private func north(_ metres: Double) -> (lat: Double, lon: Double) { (here.lat + metres / 111_195, here.lon) }

private func live(_ number: Int, _ kind: VehicleKind = .bus, line: String = "523", metres: Double = 50,
                  at time: Date = fixtureNow) -> LiveVehicle {
    let p = north(metres)
    return LiveVehicle(number: number, kind: kind, line: line, latitude: p.lat, longitude: p.lon, time: time)
}

private func nearby(_ vehicles: [LiveVehicle]) -> [NearbyVehicle] {
    LiveSnapshot(vehicles: vehicles, fetched: fixtureNow).nearby(lat: here.lat, lon: here.lon, within: 1000)
}

@Test func liveFeedParsesTheRealReply() throws {
    let buses = try LiveFeed.parse(fixture("live-buses.json"), kind: .bus, now: fixtureNow)
    let trams = try LiveFeed.parse(fixture("live-trams.json"), kind: .tram, now: fixtureNow)
    // 40 fresh rows each file; the stale ones and "d. 35154" are dropped.
    #expect(buses.count == 40)
    #expect(trams.count == 30)
    let first = try #require(buses.first)
    #expect(first.number == 1000 && first.line == "219" && first.brigade == "1")
    #expect(abs(first.latitude - 52.183973) < 1e-9)
    // "19:23:28" is Warsaw time (CEST, UTC+2).
    #expect(first.time == Date(timeIntervalSince1970: 1_790_357_008))
    #expect(trams.allSatisfy { $0.kind == .tram })
    // Nearly every live number is in the ZTM database.
    let known = (buses + trams).filter { catalog.isKnown(number: $0.number, kind: $0.kind) }
    #expect(known.count >= 60)
}

@Test func liveFeedErrorsAndStaleRows() {
    let error = Data(#"{"result": "Błędna metoda lub parametry wywołania"}"#.utf8)
    #expect(throws: LiveFeed.Failure.message("Błędna metoda lub parametry wywołania")) {
        try LiveFeed.parse(error, kind: .bus)
    }
    #expect(throws: LiveFeed.Failure.malformed) { try LiveFeed.parse(Data("nope".utf8), kind: .bus) }
    let rows = Data(#"""
    {"result":[
    {"Lines":"9","Lon":21.0,"VehicleNumber":"1294","Time":"2026-09-25 19:23:30","Lat":52.2,"Brigade":"1"},
    {"Lines":"9","Lon":21.0,"VehicleNumber":"1296","Time":"2026-09-25 19:20:30","Lat":52.2,"Brigade":"2"},
    {"Lines":"L-8","Lon":"21.0","VehicleNumber":"d. 35154","Time":"2026-09-25 19:23:30","Lat":"52.2","Brigade":"1"}
    ]}
    """#.utf8)
    let parsed = try? LiveFeed.parse(rows, kind: .tram, now: fixtureNow)
    #expect(parsed?.map(\.number) == [1294])
}

@Test func liveFeedParsesTheNewCityService() throws {
    // dane.um.warszawa.pl sends the rows as a bare list, and errors under "message".
    let rows = Data(#"[{"Brigade":"1","Lines":"9","Lat":52.2,"Lon":21.0,"Time":"2026-09-25 19:23:30","VehicleNumber":"1294"}]"#.utf8)
    #expect(try LiveFeed.parse(rows, kind: .tram, now: fixtureNow).map(\.number) == [1294])
    #expect(throws: LiveFeed.Failure.message("Service unavailable")) {
        try LiveFeed.parse(Data(#"{"message":"Service unavailable"}"#.utf8), kind: .tram)
    }
}

@Test func distanceAndNearby() {
    // Plac Defilad → Rondo ONZ is about 700 m.
    let d = Geo.km((52.2319, 21.0067), (52.2330, 20.9965)) * 1000
    #expect(d > 650 && d < 750)
    let snap = LiveSnapshot(vehicles: [live(1, metres: 400), live(2, metres: 100), live(3, metres: 2000)], fetched: fixtureNow)
    #expect(snap.nearby(lat: here.lat, lon: here.lon, within: 500).map(\.vehicle.number) == [2, 1])
    #expect(snap.vehicle(number: 3, kind: .bus)?.number == 3)
    #expect(snap.vehicle(number: 3, kind: .tram) == nil)
}

@Test func nearbyReadGetsBoosted() {
    let (out, adj) = LiveHints.adjust([(8592, 3.0), (4235, 2.5)], nearby: nearby([live(4235)]))
    #expect(adj.boosted == [4235])
    #expect(out.max { $0.score < $1.score }?.number == 4235)
}

@Test func oneDigitRescueFixesTheCoachLogs() {
    // The camera read 1235 and 9215; the vehicles right there were 4235 and 4215.
    for (read, real) in [(1235, 4235), (9215, 4215)] {
        let (out, adj) = LiveHints.adjust([(read, 1.2)], nearby: nearby([live(real, .tram, metres: 60), live(8592, metres: 90)]))
        #expect(adj.rescued == [LiveHints.Rescue(from: read, to: real)])
        #expect(out.max { $0.score < $1.score }?.number == real)
    }
    #expect(LiveHints.oneDigitOff(1235, 4235))
    #expect(!LiveHints.oneDigitOff(1235, 4236))
    #expect(!LiveHints.oneDigitOff(123, 1234))
}

@Test func noRescueWithoutAVehicleRightThere() {
    let (out, adj) = LiveHints.adjust([(1235, 1.2)], nearby: nearby([live(4235, metres: 400)]))
    #expect(adj.rescued.isEmpty && adj.boosted.isEmpty)
    #expect(out.map(\.number) == [1235])
    // Two one-digit neighbours: can't tell which, so no guess.
    let two = LiveHints.adjust([(1235, 1.2)], nearby: nearby([live(4235, metres: 40), live(1285, metres: 60)]))
    #expect(two.adjustment.rescued.isEmpty)
    #expect(LiveHints.adjust([(1235, 1.2)], nearby: []).candidates.count == 1)
}

@Test func nearbyTramSettlesTheAmbiguousNumber() {
    let match = catalog.match(number: 4245)
    guard case .ambiguous = match else { Issue.record("4245 should be a bus and a tram"); return }
    let resolved = LiveHints.resolve(match, number: 4245, nearby: nearby([live(4245, .tram)]), catalog: catalog)
    #expect(resolved == .certain(catalog.model(id: "tram-hrc-140n")!))
    // BUS mode read the tram's number: the tram running past wins.
    let busMode = catalog.match(number: 4245, preferring: .bus)
    #expect(LiveHints.resolve(busMode, number: 4245, nearby: nearby([live(4245, .tram)]), catalog: catalog)
            == .certain(catalog.model(id: "tram-hrc-140n")!))
    // Both kinds nearby, or neither: no change.
    #expect(LiveHints.resolve(match, number: 4245, nearby: nearby([live(4245, .tram), live(4245, .bus)]), catalog: catalog) == match)
    #expect(LiveHints.resolve(match, number: 4245, nearby: [], catalog: catalog) == match)
}

@Test func lineComesFromAFreshReport() {
    let snap = LiveSnapshot(vehicles: [live(4235, .tram, line: "33"), live(8592, line: "523", at: fixtureNow - 600)],
                            fetched: fixtureNow)
    #expect(LiveHints.line(for: 4235, kind: .tram, snapshot: snap, at: fixtureNow + 60) == "33")
    #expect(LiveHints.line(for: 4235, kind: .bus, snapshot: snap, at: fixtureNow) == nil)
    // Last seen ten minutes before the catch: too old to trust.
    #expect(LiveHints.line(for: 8592, kind: .bus, snapshot: snap, at: fixtureNow) == nil)
    #expect(LiveHints.line(for: 4235, kind: .tram, snapshot: snap, at: fixtureNow + 600) == nil)
    #expect(LiveHints.line(for: 4235, kind: .tram, snapshot: nil, at: fixtureNow) == nil)
}

@Test func wantedPinsPutMissingModelsFirst() {
    let urbino18 = catalog.match(number: 8592, kind: .bus).suggested!
    let otherUrbino18 = urbino18.numbers.first { $0 != 8592 }!
    let legendary = catalog.models.first { $0.tier == .legendary && $0.kind == .tram }!
    let hrc = catalog.model(id: "tram-hrc-140n")!
    let caught = CollectionStats(sightings: [SightingRecord(number: 8592, modelId: urbino18.id, date: .now)])
    let snap = LiveSnapshot(vehicles: [
        live(8592, metres: 100),                                     // already caught
        live(otherUrbino18, metres: 200),                            // new vehicle, model owned
        live(hrc.numbers[0], .tram, metres: 900),                    // new common model
        live(legendary.numbers[0], .tram, metres: 1500),             // new legendary model
        live(hrc.numbers[1], .tram, metres: 300),                    // nearer HRC
        live(99_999, metres: 50),                                    // not in the database
        live(hrc.numbers[2], .tram, metres: 5000),                   // too far
    ], fetched: fixtureNow)
    let pins = Wanted.pins(snapshot: snap, catalog: catalog, caught: caught, lat: here.lat, lon: here.lon)
    #expect(pins.map(\.vehicle.number) == [legendary.numbers[0], hrc.numbers[1], hrc.numbers[0], otherUrbino18])
    #expect(pins.map(\.kind) == [.newModel, .newModel, .newModel, .newVehicle])
    #expect(Wanted.pins(snapshot: snap, catalog: catalog, caught: caught, lat: here.lat, lon: here.lon, limit: 2).count == 2)
    // The ALL view: the caught Urbino comes back, ranked with the other one by distance.
    let all = Wanted.pins(snapshot: snap, catalog: catalog, caught: caught, lat: here.lat, lon: here.lon, includeCaught: true)
    #expect(all.map(\.vehicle.number) == [legendary.numbers[0], hrc.numbers[1], hrc.numbers[0], 8592, otherUrbino18])
    #expect(all.map(\.kind) == [.newModel, .newModel, .newModel, .caught, .newVehicle])
}

@Test func crowdedPinsBecomeOneBubbleLedByTheRarest() {
    let hrc = catalog.model(id: "tram-hrc-140n")!
    let legendary = catalog.models.first { $0.tier == .legendary && $0.kind == .tram }!
    // A pętla: three trams within 20 m, and one far away.
    let snap = LiveSnapshot(vehicles: [
        live(hrc.numbers[0], .tram, metres: 100),
        live(hrc.numbers[1], .tram, metres: 110),
        live(legendary.numbers[0], .tram, metres: 120),
        live(hrc.numbers[2], .tram, metres: 2500),
    ], fetched: fixtureNow)
    let pins = Wanted.pins(snapshot: snap, catalog: catalog, caught: CollectionStats(sightings: []),
                           lat: here.lat, lon: here.lon)
    let groups = Wanted.group(pins, cellLon: 0.01, latitude: here.lat)
    #expect(groups.map(\.pins.count).sorted() == [1, 3])
    let crowd = groups.first { $0.pins.count == 3 }!
    #expect(crowd.lead.model.id == legendary.id)
    #expect(crowd.id.hasPrefix("group:"))
    #expect(groups.first { $0.pins.count == 1 }!.id == pins.last!.id)
    // The buses creep along between refreshes: same square, same group id.
    let moved = LiveSnapshot(vehicles: snap.vehicles.map {
        LiveVehicle(number: $0.number, kind: $0.kind, line: $0.line, latitude: $0.latitude + 0.00005,
                    longitude: $0.longitude, time: $0.time)
    }, fetched: fixtureNow)
    let again = Wanted.group(Wanted.pins(snapshot: moved, catalog: catalog, caught: CollectionStats(sightings: []),
                                         lat: here.lat, lon: here.lon), cellLon: 0.01, latitude: here.lat)
    #expect(again.first { $0.pins.count == 3 }?.id == crowd.id)
    // Zoomed right in, nothing shares a square.
    #expect(Wanted.group(pins, cellLon: 0.00005, latitude: here.lat).count == 4)
}

@Test func trailsGiveDirectionAndMotion() {
    var trails = LiveTrails()
    let key = LiveTrails.key(.bus, 8592)
    func at(_ metres: Double, _ seconds: Double) -> LiveVehicle {
        live(8592, metres: metres, at: fixtureNow + seconds)
    }
    // First sighting: nothing to go on yet.
    trails.record([at(600, 0)], now: fixtureNow)
    #expect(trails.heading(key) == nil)
    #expect(trails.motion(key, lat: here.lat, lon: here.lon) == nil)
    // GPS jitter at a stop isn't travel.
    trails.record([at(605, 10)], now: fixtureNow + 10)
    #expect(trails.trail(key).count == 1)
    // Driving south, towards Plac Defilad.
    trails.record([at(450, 25)], now: fixtureNow + 25)
    trails.record([at(300, 40)], now: fixtureNow + 40)
    let h = trails.heading(key)!
    #expect(abs(h - 180) < 1)
    #expect(trails.motion(key, lat: here.lat, lon: here.lon) == .approaching)
    // Standing still (still reporting) for a minute: stopped.
    trails.record([at(302, 70)], now: fixtureNow + 70)
    trails.record([at(301, 100)], now: fixtureNow + 100)
    #expect(trails.motion(key, lat: here.lat, lon: here.lon) == .stopped)
    // Bearings run clockwise from north.
    #expect(Geo.bearing((52.0, 21.0), (52.1, 21.0)) < 1)
    #expect(abs(Geo.bearing((52.0, 21.0), (52.0, 21.1)) - 90) < 1)
    // Gone from the feed for over five minutes: forgotten.
    trails.record([], now: fixtureNow + 500)
    #expect(trails.trail(key).isEmpty)
}

@Test func huntTargetsMatchAnyTierOrModelAndSurviveStorage() {
    let hrc = catalog.model(id: "tram-hrc-140n")!
    let legendary = catalog.models.first { $0.tier == .legendary }!
    let gold = catalog.models.first { $0.tier == .gold }!
    // Nothing picked: everything counts.
    #expect(HuntTargets().matches(hrc))
    #expect(HuntTargets().isEmpty)
    // A tier and a model: either one is enough.
    let targets = HuntTargets(tiers: [.legendary], models: [hrc.id])
    #expect(targets.matches(legendary))
    #expect(targets.matches(hrc))
    #expect(!targets.matches(gold))
    #expect(targets.count == 2)
    // Round-trips through its stored form, in a stable order.
    #expect(targets.rawValue == "tier:LEGENDARY,model:tram-hrc-140n")
    #expect(HuntTargets(rawValue: targets.rawValue) == targets)
    #expect(HuntTargets(rawValue: "") == HuntTargets())
    // Junk from an older or newer version is skipped.
    #expect(HuntTargets(rawValue: "tier:MYTHIC,model:,colour:red,tier:GOLD") == HuntTargets(tiers: [.gold]))
}

@Test func huntTargetsKindNarrowsRatherThanAdds() {
    let hrc = catalog.model(id: "tram-hrc-140n")!
    let bus = catalog.models.first { $0.kind == .bus && $0.regular }!
    // Trams only: every tram counts, no bus does, and it's not a city-wide hunt.
    let trams = HuntTargets(kind: .tram)
    #expect(trams.matches(hrc) && !trams.matches(bus))
    #expect(!trams.isEmpty && !trams.hasPicks && trams.count == 1)
    // With picks, the kind narrows them: a bus model picked under TRAM doesn't match.
    let mixed = HuntTargets(tiers: [hrc.tier], models: [bus.id], kind: .tram)
    #expect(mixed.matches(hrc) && !mixed.matches(bus))
    #expect(mixed.rawValue.hasPrefix("kind:TRAM,"))
    #expect(HuntTargets(rawValue: mixed.rawValue) == mixed)
    #expect(HuntTargets(rawValue: "kind:BOAT") == HuntTargets())
}

// MARK: - Routes

/// A straight street east along one latitude, a point every 0.0005° (about 34 m).
private func street(lat: Double, from lon0: Double, to lon1: Double) -> [(latitude: Double, longitude: Double)] {
    let steps = Int((abs(lon1 - lon0) / 0.0005).rounded())
    return (0...steps).map { (lat, lon0 + (lon1 - lon0) * Double($0) / Double(steps)) }
}

private func shape(_ id: String, trips: Int, _ points: [(latitude: Double, longitude: Double)],
                   stopsEvery: Int = 0) -> RouteShape {
    let bare = RouteShape(id: id, trips: trips, points: points, stops: [])!
    let stops = stopsEvery > 0
        ? stride(from: stopsEvery, to: points.count, by: stopsEvery).map { i in
            RouteStop(name: "\(id)\(i)", latitude: points[i].latitude, longitude: points[i].longitude,
                      along: bare.project((points[i].latitude, points[i].longitude))!.along)
        }
        : []
    return RouteShape(id: id, trips: trips, points: points, stops: stops)!
}

private let routeLat = 52.23
/// East along the street to 21.03.
private let eastbound = shape("east", trips: 100, street(lat: routeLat, from: 21.00, to: 21.03), stopsEvery: 10)
/// The same street the other way.
private let westbound = shape("west", trips: 90, street(lat: routeLat, from: 21.03, to: 21.00))
/// Shares the street with `eastbound` to 21.02, then turns north: fewer trips run it.
private let forkNorth = shape("north", trips: 10, street(lat: routeLat, from: 21.00, to: 21.02)
                                + (1...20).map { (routeLat + 0.0005 * Double($0), 21.02) })

/// A vehicle driving along the street, a fix every 10 s, `metres` apart; the last is its position.
private func drive(from lon0: Double, step: Double, fixes: Int, lat: Double = routeLat)
    -> (trail: [LiveTrails.Point], position: LiveTrails.Point) {
    let points = (0..<fixes).map { i in
        LiveTrails.Point(latitude: lat, longitude: lon0 + step * Double(i), time: fixtureNow + Double(i) * 10)
    }
    return (Array(points.dropLast()), points.last!)
}

@Test func polylineRoundTrips() {
    // Google's own example.
    let decoded = Polyline.decode("_p~iF~ps|U_ulLnnqC_mqNvxq`@")
    #expect(decoded.count == 3)
    #expect(abs(decoded[0].latitude - 38.5) < 1e-9 && abs(decoded[0].longitude + 120.2) < 1e-9)
    #expect(abs(decoded[2].latitude - 43.252) < 1e-9 && abs(decoded[2].longitude + 126.453) < 1e-9)
    #expect(Polyline.encode(decoded) == "_p~iF~ps|U_ulLnnqC_mqNvxq`@")
    let street = street(lat: 52.23, from: 21.0, to: 21.01)
    let back = Polyline.decode(Polyline.encode(street))
    #expect(back.count == street.count)
    #expect(zip(back, street).allSatisfy { abs($0.latitude - $1.latitude) < 1e-5 && abs($0.longitude - $1.longitude) < 1e-5 })
}

@Test func routeMatchPicksTheWayTheTrailRuns() {
    let book = RouteBook(shapes: [RouteBook.key(.bus, "175"): [eastbound, westbound]])
    // Driving west (about 70 m every 10 s): the westbound shape, though fewer trips run it.
    let west = drive(from: 21.015, step: -0.001, fixes: 4)
    let m = book.match(line: "175", kind: .bus, trail: west.trail, position: west.position)
    #expect(m?.shape.id == "west")
    // About 7 m/s along the shape.
    #expect(abs((m?.speed ?? 0) - 6.8) < 0.5)
    let east = drive(from: 21.010, step: 0.001, fixes: 4)
    #expect(book.match(line: "175", kind: .bus, trail: east.trail, position: east.position)?.shape.id == "east")
    // Another line, or the tram with the same number: nothing to match.
    #expect(book.match(line: "176", kind: .bus, trail: east.trail, position: east.position) == nil)
    #expect(book.match(line: "175", kind: .tram, trail: east.trail, position: east.position) == nil)
    // Standing still, it could be facing either way: no guess.
    #expect(book.match(line: "175", kind: .bus, trail: [], position: east.position) == nil)
}

@Test func routeMatchTakesTheUsualWayAtAFork() {
    let book = RouteBook(shapes: [RouteBook.key(.bus, "175"): [forkNorth, eastbound]])
    // On the shared stretch: the way most trips go.
    let shared = drive(from: 21.010, step: 0.001, fixes: 4)
    #expect(book.match(line: "175", kind: .bus, trail: shared.trail, position: shared.position)?.shape.id == "east")
    // Past the fork, heading north: only the fork fits.
    let north = (0..<4).map { i in
        LiveTrails.Point(latitude: routeLat + 0.001 + 0.0008 * Double(i), longitude: 21.02, time: fixtureNow + Double(i) * 10)
    }
    #expect(book.match(line: "175", kind: .bus, trail: Array(north.dropLast()), position: north.last!)?.shape.id == "north")
    // A still bus on a one-way stretch: every fit faces the same way, so it's safe to say.
    #expect(book.match(line: "175", kind: .bus, trail: [], position: shared.position)?.shape.id == "east")
}

@Test func routeMatchRefusesAVehicleGoingTheWrongWayOrOffRoute() {
    let book = RouteBook(shapes: [RouteBook.key(.bus, "175"): [eastbound]])
    // Driving west on an eastbound-only route: a detour, or the feed has the wrong line.
    let west = drive(from: 21.015, step: -0.001, fixes: 4)
    #expect(book.match(line: "175", kind: .bus, trail: west.trail, position: west.position) == nil)
    // A street 150 m north: off the route.
    let off = drive(from: 21.010, step: 0.001, fixes: 4, lat: routeLat + 0.00135)
    #expect(book.match(line: "175", kind: .bus, trail: off.trail, position: off.position) == nil)
}

@Test func routeMatchAdvancesButNotTooFar() {
    let m = RouteMatch(shape: eastbound, along: 100, speed: 10)
    // No further than the next stop (every 10 points, about 340 m), where it would wait.
    let firstStop = eastbound.stops[0].along
    #expect(m.advanced(by: 10).along == 200)
    #expect(m.advanced(by: 40).along == firstStop)
    // Past the stop: capped at 45 s of travel however old the fix is.
    let later = RouteMatch(shape: eastbound, along: firstStop + 20, speed: 5)
    #expect(later.advanced(by: 600).along == firstStop + 20 + 5 * RouteMatch.maxAdvance)
    // Stopped, or no time passed: stays put.
    #expect(m.advanced(by: 30, stopped: true).along == 100)
    #expect(m.advanced(by: -5).along == 100)
    // Never off the end.
    #expect(RouteMatch(shape: westbound, along: westbound.length - 5, speed: 15).advanced(by: 45).along == westbound.length)
}

@Test func routeMatchLaysTheTrailOnTheStreet() {
    // Fixes 20 m north of the street, wobbling: the trail runs on the street itself instead.
    let fixes = (0..<4).map { i in
        LiveTrails.Point(latitude: routeLat + (i % 2 == 0 ? 0.00018 : 0.00005), longitude: 21.010 + 0.001 * Double(i),
                         time: fixtureNow + Double(i) * 10)
    }
    let m = RouteMatch(shape: forkNorth, along: forkNorth.project((routeLat, 21.0145))!.along, speed: 7)
    let trail = m.trail(fixes)
    #expect(trail.allSatisfy { abs($0.latitude - routeLat) < 1e-9 })
    #expect(abs(trail.first!.longitude - 21.010) < 1e-6 && abs(trail.last!.longitude - 21.0145) < 1e-6)
    // Round the corner: the trail turns it with the street rather than cutting across.
    let corner = [LiveTrails.Point(latitude: routeLat, longitude: 21.018, time: fixtureNow)]
    let north = RouteMatch(shape: forkNorth, along: forkNorth.project((routeLat + 0.002, 21.02))!.along, speed: 7)
    #expect(north.trail(corner).contains { abs($0.latitude - routeLat) < 1e-9 && abs($0.longitude - 21.02) < 1e-9 })
    // A fix from before it joined the route (the trip before a loop) is left out.
    let joined = [LiveTrails.Point(latitude: routeLat + 0.003, longitude: 21.009, time: fixtureNow)] + fixes
    #expect(m.trail(joined).allSatisfy { abs($0.latitude - routeLat) < 1e-9 })
    // No fix on the route at all: the raw fixes, then where it is.
    let off = [LiveTrails.Point(latitude: routeLat + 0.003, longitude: 21.009, time: fixtureNow)]
    #expect(m.trail(off).count == 2 && abs(m.trail(off)[0].latitude - (routeLat + 0.003)) < 1e-9)
    // Nothing behind it yet: just where it is.
    #expect(m.trail([]).count == 1)
}

@Test func routeMatchListsTheNextStops() {
    let m = RouteMatch(shape: eastbound, along: eastbound.stops[1].along - 50, speed: 8)
    let next = m.upcoming(stops: 3)
    #expect(next.stops.map(\.name) == ["east20", "east30", "east40"])
    // The path runs from the vehicle to the third of them.
    #expect(abs(next.path.first!.longitude - m.coordinate.longitude) < 1e-9)
    #expect(abs(next.path.last!.longitude - eastbound.stops[3].longitude) < 1e-9)
    // At a stop, it's the one after that comes next.
    #expect(RouteMatch(shape: eastbound, along: eastbound.stops[1].along, speed: 0).upcoming(stops: 1).stops.first?.name == "east30")
}

@Test func routeMatchSaysWhenItTurnsOffBeforeYou() {
    // You stand on the street, 700 m ahead; the bus is heading straight for you.
    let you = (lat: routeLat, lon: 21.025)
    let onStraight = RouteMatch(shape: eastbound, along: eastbound.project((routeLat, 21.015))!.along, speed: 8)
    #expect(onStraight.motion(fallback: .approaching, lat: you.lat, lon: you.lon) == .approaching)
    // Same place, but its route turns north at 21.02, before it reaches you.
    let onFork = RouteMatch(shape: forkNorth, along: forkNorth.project((routeLat, 21.015))!.along, speed: 8)
    #expect(onFork.motion(fallback: .approaching, lat: you.lat, lon: you.lon) == .turnsOff)
    // Its route passes you even though the straight line says otherwise: coming.
    let beside = (lat: routeLat + 0.005, lon: 21.0205)
    #expect(onFork.motion(fallback: .passing, lat: beside.lat, lon: beside.lon) == .approaching)
    // Already past you: the straight-line answer stands.
    let behind = (lat: routeLat + 0.0005, lon: 21.012)
    #expect(onStraight.motion(fallback: .leaving, lat: behind.lat, lon: behind.lon) == .leaving)
    #expect(onStraight.motion(fallback: .stopped, lat: you.lat, lon: you.lon) == .stopped)
}

@Test func routeBookDecodesTheBuiltFile() throws {
    let json = """
    {"feed":"schedule_test","built":"2026-09-28","lines":{"175":{"kind":"BUS","shapes":[
      {"id":"1","trips":3,"path":"\(Polyline.encode(street(lat: routeLat, from: 21.0, to: 21.01)))",
       "stops":[["Centrum",52.23,21.005,342]]}]},
      "9":{"kind":"TRAM","shapes":[]},"X":{"kind":"BOAT","shapes":[]}}}
    """
    let book = try RouteBook(json: Data(json.utf8))
    #expect(book.feed == "schedule_test")
    #expect(book.lineCount == 2)
    let s = book.shapes(line: "175", kind: .bus)
    #expect(s.count == 1 && s[0].stops.first?.name == "Centrum")
    // Metres along agree with the script's (both haversine), within a metre.
    #expect(abs(s[0].project((52.23, 21.005))!.along - 342) < 1.5)
}

@Test func routeMatchKnowsHowItsRouteEnds() {
    // Out east and back west from the same loop: east ends where west starts, so it turns back.
    let book = RouteBook(shapes: [RouteBook.key(.bus, "175"): [eastbound, shape("west", trips: 90, street(lat: routeLat, from: 21.03, to: 21.00), stopsEvery: 10)]])
    let near = drive(from: 21.022, step: 0.001, fixes: 4)
    let m = book.match(line: "175", kind: .bus, trail: near.trail, position: near.position)!
    #expect(m.end == .turnsBack("east60"))
    // Two stops before the end it's among the next three; well before, it isn't.
    #expect(m.ending(within: 3)?.end == .turnsBack("east60") && m.ending(within: 3)?.arrived == false)
    #expect(RouteMatch(shape: eastbound, along: 100, speed: 5, end: m.end).ending(within: 3) == nil)
    // At the last stop, where the shape ends.
    #expect(RouteMatch(shape: eastbound, along: eastbound.length - 5, speed: 5, end: m.end).ending()?.arrived == true)
    // A last stop at the depot, and one nothing starts from.
    let depot = RouteShape(id: "d", trips: 3, points: street(lat: routeLat, from: 21.0, to: 21.01),
                           stops: [RouteStop(name: "Zajezdnia Woronicza", latitude: routeLat, longitude: 21.01, along: 680)])!
    #expect(RouteBook.end(of: depot, among: [depot, eastbound]) == .depot("Zajezdnia Woronicza"))
    #expect(RouteBook.end(of: eastbound, among: [eastbound]) == .ends("east60"))
    let yard = RouteShape(id: "y", trips: 3, points: street(lat: routeLat, from: 21.0, to: 21.01),
                          stops: [RouteStop(name: "R4(Z)", latitude: routeLat, longitude: 21.01, along: 680)])!
    #expect(RouteBook.end(of: yard, among: [yard, eastbound]) == .depot("R4(Z)"))
    // A short working sharing the street with the full route: can't tell which, so no end.
    let short = shape("short", trips: 20, street(lat: routeLat, from: 21.00, to: 21.02), stopsEvery: 10)
    let shared = RouteBook(shapes: [RouteBook.key(.bus, "175"): [eastbound, short]])
    let early = drive(from: 21.012, step: 0.001, fixes: 4)
    #expect(shared.match(line: "175", kind: .bus, trail: early.trail, position: early.position)?.end == nil)
}

// MARK: - Specs and liveries

@Test func fleetJsonCarriesSpecsAndLiveries() {
    let e18 = catalog.model(id: "bus-solaris-urbino-18e")!
    #expect(e18.specs?.drive == .electric)
    #expect(e18.specs?.metres == 18)
    #expect(e18.specs?.floor == .low)
    #expect((e18.specs?.places ?? 0) > (e18.specs?.seats ?? 0))
    // Liveries only where photos confirm one: the grey hybrids, the blue suburban models.
    // #5869 was silver once and the city still says so, but it's red and yellow now.
    #expect(e18.livery(of: 5869) == nil)
    #expect(catalog.model(id: "bus-solaris-urbino-18h")?.livery(of: 8396) == .greyRed)
    #expect(catalog.model(id: "bus-mercus-syn2z")?.liveries?.values.allSatisfy { $0 == "suburbanBlue" } == true)
    // Trams are all electric: the city gives no drive for them.
    #expect(catalog.model(id: "tram-hrc-140n")?.specs?.drive == nil)
}

@Test func unknownSpecValuesAreSkipped() throws {
    let json = #"{"length": 11947, "drive": "steam", "floor": "XX", "seats": 30}"#
    let s = try JSONDecoder().decode(ModelSpecs.self, from: Data(json.utf8))
    #expect(s.drive == nil && s.floor == nil && s.seats == 30)
    #expect(s.metres == 11.9)
}

@Test func specialLiveryBadgeCountsPaintedVehicles() {
    let hybrid = catalog.model(id: "bus-solaris-urbino-18h")!
    let blue = catalog.model(id: "bus-mercus-syn2z")!
    let blueNumber = Int(blue.liveries!.keys.first!)!
    #expect(eval([any(hybrid.id, number: 8398)])["special-livery"]?.level == 0)
    // The suburban blue is a whole model's colour, not a vehicle standing out: no credit.
    #expect(eval([any(blue.id, number: blueNumber)])["special-livery"]?.progress == 0)
    let painted = [8396, 8397].map { any(hybrid.id, number: $0) }
    let badge = eval(painted + painted)["special-livery"]!
    // Each vehicle counts once, however often it's caught.
    #expect(badge.progress == 2 && badge.level == 1)
    #expect(eval(painted + [any(hybrid.id, number: 8399)])["special-livery"]!.maxed)
}

@Test func badgesSayWhichVehiclesEarnedThem() {
    // Veteran: the old one, with its age; the young one doesn't count.
    let old = catalog.models.first { $0.regular && $0.batches.contains { ($0.year ?? 9999) <= 2005 } }!
    let oldBatch = old.batches.first { ($0.year ?? 9999) <= 2005 }!
    let young = catalog.models.first { $0.regular && $0.batches.contains { $0.year == 2024 } }!
    let youngNumber = young.batches.first { $0.year == 2024 }!.numbers[0]
    let vet = eval([any(old.id, number: oldBatch.numbers[0], date: day(2026, 6, 1)), any(young.id, number: youngNumber, date: day(2026, 6, 1))])["veteran"]!
    #expect(vet.proof == [Achievement.Proof(modelId: old.id, number: oldBatch.numbers[0], note: "\(2026 - oldBatch.year!) YEARS OLD")])
    // Not earned yet: the oldest so far, as the closest.
    #expect(eval([any(young.id, number: youngNumber, date: day(2026, 6, 1))])["veteran"]!.proof.map(\.number) == [youngNumber])
    // Dressed up: every painted vehicle once, however often caught.
    let hybrid = catalog.model(id: "bus-solaris-urbino-18h")!
    let painted = eval([any(hybrid.id, number: 8399), any(hybrid.id, number: 8399), any(hybrid.id, number: 8398)])["special-livery"]!
    #expect(painted.proof == [Achievement.Proof(modelId: hybrid.id, number: 8399, note: Livery.greyRed.name)])
    // A secret keeps its vehicles hidden until earned; once earned it names them.
    let m = catalog.models.max { $0.fleet < $1.fleet }!
    let pair = m.numbers.first { m.numbers.contains($0 + 1) }!
    #expect(eval([any(m.id, number: pair)])["twins"]!.proof.isEmpty)
    #expect(eval([any(m.id, number: pair), any(m.id, number: pair + 1)])["twins"]!.proof.map(\.number) == [pair, pair + 1])
    // Counting badges don't list anything.
    #expect(eval([any()])["collector"]!.proof.isEmpty)
}

// MARK: - Sticker subject picking

private func subject(_ label: Int, pixels: Int, x: Double, y: Double, w: Double, h: Double,
                     cover: Double = 0, person: Double = 0) -> Subject {
    Subject(label: label, pixels: pixels, box: CGRect(x: x, y: y, width: w, height: h),
            centroid: CGPoint(x: x + w / 2, y: y + h / 2), numberCover: cover, personShare: person)
}

@Test func stickerKeepsTheObjectTheNumberIsOn() {
    // Head-on bus, with someone nearer the camera who comes out bigger.
    let bus = subject(1, pixels: 3000, x: 0.3, y: 0.3, w: 0.4, h: 0.4, cover: 0.9)
    let person = subject(2, pixels: 5000, x: 0.0, y: 0.0, w: 0.3, h: 1.0, person: 0.95)
    let number = CGRect(x: 0.45, y: 0.35, width: 0.1, height: 0.04)
    let pick = SubjectPicker.rank([bus, person], numberBox: number)
    #expect(pick?.order == [1, 2])
    #expect(pick?.reason == .number)
    // Two buses: the number is on the smaller one.
    let near = subject(3, pixels: 6000, x: 0.0, y: 0.2, w: 0.6, h: 0.6)
    let far = subject(4, pixels: 1500, x: 0.6, y: 0.3, w: 0.3, h: 0.3, cover: 0.7)
    #expect(SubjectPicker.rank([near, far], numberBox: number)?.order.first == 4)
}

@Test func stickerFallsBackToTheOutlineHoldingTheNumber() {
    // The mask missed the digits, but the number sits inside the bus's outline.
    let bus = subject(1, pixels: 2000, x: 0.5, y: 0.2, w: 0.4, h: 0.5, cover: 0.05)
    let car = subject(2, pixels: 4000, x: 0.0, y: 0.5, w: 0.5, h: 0.4)
    let pick = SubjectPicker.rank([car, bus], numberBox: CGRect(x: 0.6, y: 0.3, width: 0.1, height: 0.05))
    #expect(pick?.order.first == 1)
    #expect(pick?.reason == .number)
}

@Test func stickerWithoutANumberSkipsPeopleAndPrefersTheMiddle() {
    let bus = subject(1, pixels: 3000, x: 0.3, y: 0.3, w: 0.4, h: 0.4)
    let person = subject(2, pixels: 5000, x: 0.0, y: 0.0, w: 0.3, h: 1.0, person: 0.9)
    let pick = SubjectPicker.rank([person, bus], numberBox: nil)
    #expect(pick?.order == [1, 2])
    #expect(pick?.reason == .notPerson)
    // A bigger car at the edge loses to the bus in the middle.
    let car = subject(3, pixels: 3600, x: 0.8, y: 0.8, w: 0.2, h: 0.2)
    let central = SubjectPicker.rank([car, bus], numberBox: nil)
    #expect(central?.order == [1, 3])
    #expect(central?.reason == .central)
    // Passengers behind the windows don't make the bus a person.
    let busWithPassengers = subject(4, pixels: 3000, x: 0.3, y: 0.3, w: 0.4, h: 0.4, person: 0.15)
    #expect(SubjectPicker.rank([person, busWithPassengers], numberBox: nil)?.order.first == 4)
}

@Test func stickerOfOnlyPeopleTakesTheBiggest() {
    let small = subject(1, pixels: 1000, x: 0.4, y: 0.4, w: 0.1, h: 0.3, person: 0.9)
    let big = subject(2, pixels: 4000, x: 0.0, y: 0.0, w: 0.3, h: 1.0, person: 0.9)
    let pick = SubjectPicker.rank([small, big], numberBox: nil)
    #expect(pick?.order == [2, 1])
    #expect(pick?.reason == .largest)
    #expect(SubjectPicker.rank([], numberBox: nil) == nil)
    // Crumbs aren't offered as other cut-outs.
    let crumb = subject(3, pixels: 50, x: 0.9, y: 0.9, w: 0.01, h: 0.01)
    #expect(SubjectPicker.rank([big, crumb], numberBox: nil, framePixels: 10_000)?.order == [2])
}

@Test func numberBoxesCarryThroughOCR() {
    let obs = [
        TextObservation(text: "B592", confidence: 0.9, height: 0.05, box: CGRect(x: 0.4, y: 0.3, width: 0.1, height: 0.05)),
        TextObservation(text: "WX 8592", confidence: 0.9, height: 0.02, box: CGRect(x: 0.4, y: 0.8, width: 0.1, height: 0.02)),
        TextObservation(text: "8592", confidence: 0.9, height: 0.03),
    ]
    // The lookalike counts; the plate and the box-less live frame don't.
    #expect(NumberExtractor.boxes(of: 8592, in: obs) == [CGRect(x: 0.4, y: 0.3, width: 0.1, height: 0.05)])
    // A box from the top-right tile, back on the whole photo with the origin flipped.
    let tile = CGRect(x: 0.6, y: 0.6, width: 0.4, height: 0.4)
    let mapped = NumberExtractor.ocrBox(CGRect(x: 0.5, y: 0.5, width: 0.25, height: 0.25), roi: tile)
    #expect(abs(mapped.minX - 0.8) < 1e-9 && abs(mapped.minY - 0.1) < 1e-9)
    #expect(abs(mapped.width - 0.1) < 1e-9 && abs(mapped.height - 0.1) < 1e-9)
}
