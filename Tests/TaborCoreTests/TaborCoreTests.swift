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
    // The stripe and lamp after a Solbus's 2022 read as "/6"; a line and brigade stays out.
    #expect(NumberExtractor.digitTokens("2022/6").map(\.value) == [2022])
    #expect(NumberExtractor.digitTokens("180/6").isEmpty)
    #expect(NumberExtractor.digitTokens("6/2022").isEmpty)
    // A plate's digits read apart from "WGM" (TestFlight: "WGM 02115" offered tram 2115).
    #expect(NumberExtractor.digitTokens("02115").isEmpty)
}

@Test func plateDigitsReadOnTheirOwnAreNotAVehicle() {
    let obs = [
        TextObservation(text: "9833", confidence: 1, height: 0.04),
        TextObservation(text: "WGM", confidence: 1, height: 0.02),
        TextObservation(text: "02115", confidence: 1, height: 0.02),
        TextObservation(text: "O2115", confidence: 1, height: 0.02),
    ]
    #expect(NumberExtractor.candidates(in: obs, mode: .auto, catalog: catalog).map(\.number) == [9833])
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

@Test func lineOnTheDisplayLosesToTheFleetNumber() {
    // Two Urbinos on Krakowskie Przedmieście: the 503's display is the biggest text, and 503
    // is also a 13N tram.
    let obs = [TextObservation(text: "503 NATOLIN PŁN.", confidence: 1, height: 0.05),
               TextObservation(text: "116 WILANÓW", confidence: 1, height: 0.05),
               TextObservation(text: "5918", confidence: 1, height: 0.025),
               TextObservation(text: "5897", confidence: 1, height: 0.022)]
    #expect(NumberExtractor.best(in: obs, mode: .auto, catalog: catalog) == 5918)
    // On its own, a 3-digit fleet number still reads.
    #expect(NumberExtractor.best(in: [TextObservation(text: "503", confidence: 1, height: 0.03)],
                                 mode: .auto, catalog: catalog) == 503)
}

@Test func certainModelLeadsOverABusOrTram() {
    // #2022 (a Solbus, and a 105N2k tram) a little bigger in the frame than #5941.
    let obs = [TextObservation(text: "2022", confidence: 1, height: 0.0416),
               TextObservation(text: "5941", confidence: 1, height: 0.0357)]
    #expect(NumberExtractor.best(in: obs, mode: .auto, catalog: catalog) == 5941)
    // In BUS mode 2022 is just the Solbus.
    #expect(NumberExtractor.best(in: obs, mode: .bus, catalog: catalog) == 2022)
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

@Test func pesa120nFamilyIsSplitByNumber() throws {
    let tramicus = try #require(catalog.model(id: "tram-pesa-120n-tramicus"))
    let swing = try #require(catalog.model(id: "tram-pesa-120n"))
    let duo = try #require(catalog.model(id: "tram-pesa-120naduo"))
    #expect(tramicus.numbers == Array(3101...3115) && tramicus.tier == .gold)
    #expect(swing.numbers == Array(3116...3295) && swing.tier == .common && swing.formerly.isEmpty)
    #expect(duo.numbers == Array(3501...3506) && duo.tier == .legendary)
    #expect(tramicus.formerly == ["tram-pesa-120n"] && duo.formerly == ["tram-pesa-120n"])
    #expect(catalog.match(number: 3503, kind: .tram) == .certain(duo))
}

@Test func catchesFollowASplitModel() {
    // Filed under the family's old id: the Tramicus and the Duo move, Swings stay.
    #expect(catalog.moved(modelId: "tram-pesa-120n", number: 3105) == "tram-pesa-120n-tramicus")
    #expect(catalog.moved(modelId: "tram-pesa-120n", number: 3501) == "tram-pesa-120naduo")
    #expect(catalog.moved(modelId: "tram-pesa-120n", number: 3200) == nil)
    #expect(catalog.moved(modelId: "tram-pesa-120n-tramicus", number: 3105) == nil)
    // A number tied by hand to a model it isn't in, with no split behind it, stays put.
    #expect(catalog.moved(modelId: "bus-solaris-urbino-18", number: 3105) == nil)
    #expect(catalog.moved(modelId: "tram-pesa-120n", number: 99_999) == nil)
    // The 105Ni cars ZTM filed as plain 105Na follow to the 105N2k; a real 105Na stays.
    #expect(catalog.moved(modelId: "tram-konstal-105n", number: 1363) == "tram-alstom-konstal-105n")
    #expect(catalog.moved(modelId: "tram-konstal-105n", number: 1393) == nil)
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

@Test func worksCarsAreTheirOwnTierOutsideTheFleet() {
    // TW's overhead-line measurement car: a 13N, in neither of ZTM's lists.
    let m = catalog.match(number: 388, kind: .tram).suggested
    #expect(m?.id == "tram-works-measuring-konstal-13n" && m?.name == "Konstal 13N overhead line measuring car")
    #expect(m?.tier == .works && m?.namePl == "Konstal 13N wagon pomiarowy sieci trakcyjnej" && m?.code == "Konstal 13N")
    #expect(m?.works == true && m?.vintage == false && m?.regular == false && m?.whereToFind != nil)
    // fleet.json marks them vintage as well, for older apps; the tourist-line 13Ns stay vintage.
    #expect(catalog.model(id: "tram-konstal-13n")?.tier == .vintage)
    #expect(!catalog.models.filter(\.regular).contains { $0.works })
    // Welding car 2112 shares its number with a 105N2k: the passenger car comes first.
    let both = catalog.match(number: 2112, kind: .tram).candidates.map(\.id)
    #expect(both == ["tram-alstom-konstal-105n", "tram-works-welding-gdansk-type-k"])
    // One model per job and type: the transport cars are 13Ns and Ks.
    #expect(catalog.model(id: "tram-works-transport-konstal-13n")?.numbers == [12, 53, 402, 2412])
    #expect(catalog.model(id: "tram-works-transport-gdansk-type-k")?.numbers == [2400, 2407])
    #expect(Wanted.huntRank(.works) == Tier.legendary.rank)
}

@Test func firstWorksCarSaysItOpenedTheBookSection() {
    let m = catalog.model(id: "tram-works-measuring-konstal-13n")!
    let first = RevealHint.text(model: m, number: 388, owned: [388], isNewVehicle: true, timesSeen: 1, firstWorks: true)
    let later = RevealHint.text(model: m, number: 388, owned: [388], isNewVehicle: true, timesSeen: 1)
    #expect(first.contains("first works car") && first.contains("section"))
    #expect(later.hasPrefix("A works car"))
}

@Test func olderAppsDontSeeWorksCars() throws {
    // Builds from before works cars read only "models"; the works cars sit in "worksModels".
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Tabor/Resources/fleet.json")
    let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    let models = json["models"] as! [[String: Any]], works = json["worksModels"] as! [[String: Any]]
    #expect(!models.contains { $0["works"] as? Bool == true })
    #expect(works.count == 8 && works.allSatisfy { $0["works"] as? Bool == true && $0["vintage"] as? Bool == false })
    #expect(catalog.models.filter(\.works).count == 8)
}

@Test func worksOverridesVintageWhenDecoding() throws {
    let json = #"{"id":"w","name":"W","make":"M","kind":"TRAM","operators":[],"fleet":1,"batches":[],"vintage":true,"works":true}"#
    let m = try JSONDecoder().decode(VehicleModel.self, from: Data(json.utf8))
    #expect(m.works && !m.vintage && m.tier == .works)
}

@Test func preservedBusesOutsideZtmAreVintage() {
    // KMKM's Solaris Urbino 15 #8731 isn't in the ZTM database.
    let m = catalog.match(number: 8731, kind: .bus).suggested
    #expect(m?.name == "Solaris Urbino 15" && m?.tier == .vintage)
    // A club Jelcz shares 1983 with a Yutong: the regular bus is suggested first.
    #expect(catalog.match(number: 1983, kind: .bus).suggested?.id == "bus-yutong-u12-b")
    // Club-owned 105Na sets are split from the regular 105Na.
    #expect(catalog.match(number: 1001, kind: .tram).suggested?.id == "tram-konstal-105n-vintage")
    // MZA's Urbino 12 #1400, renumbered as heritage bus #6900.
    let heritage = catalog.match(number: 6900, kind: .bus).suggested
    #expect(heritage?.id == "bus-solaris-urbino-12-vintage" && heritage?.tier == .vintage)
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

/// Issue #35: Apple names these points "Praga", "Grochów", "Saska Kępa", "Tarchomin", "Raków".
@Test func districtsFromCoordinates() {
    #expect(Districts.at(52.2525, 21.0400) == "Praga-Północ")
    #expect(Districts.at(52.2440, 21.0900) == "Praga-Południe")
    #expect(Districts.at(52.2330, 21.0560) == "Praga-Południe")
    #expect(Districts.at(52.3150, 20.9600) == "Białołęka")
    #expect(Districts.at(52.1950, 20.9450) == "Włochy")
    #expect(Districts.at(52.2297, 21.0122) == "Śródmieście")
    #expect(Districts.at(52.0730, 21.0260) == nil)  // Piaseczno
    #expect(Districts.at(52.3340, 20.8870) == nil)  // Łomianki
    #expect(Set(Achievements.districts) == Set(Districts.encoded.map(\.name)))

    // The coordinates win over the geocoder's name; the name still counts without them.
    let grochow = SightingRecord(number: 1, modelId: "x", date: .now, district: "Grochów", latitude: 52.2440, longitude: 21.0900)
    let named = SightingRecord(number: 2, modelId: "x", date: .now, district: "Stary Mokotów")
    #expect(badge("every-district", [grochow, named]).proof.compactMap(\.note) == ["MOKOTÓW", "PRAGA-POŁUDNIE"])
    // What's left, in the districts' own order (#35).
    let left = badge("every-district", [grochow, named]).missing.map(\.label)
    #expect(left.count == 16 && left.first == "Bemowo" && !left.contains("Praga-Południe"))
    #expect(left.allSatisfy { Achievements.districts.contains($0) })
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
    // Stamps carry the time since 2026-10-03, so a second push on one day still wins, and
    // they beat the date-only stamps phones already have.
    #expect(fleet("2026-10-03 13:12 UTC").isNewer(than: fleet("2026-10-03")))
    #expect(fleet("2026-10-03 15:40 UTC").isNewer(than: fleet("2026-10-03 13:12 UTC")))
    #expect(!fleet("2026-10-03 13:12 UTC").isNewer(than: fleet("2026-10-04")))
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
    #expect(collector.reached == "100 different vehicles")
    #expect(eval(Array(caught.prefix(9)))["collector"]!.reached == "10 different vehicles")
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

/// Issue #35: a model several operators run counts for the operator of the vehicle caught.
@Test func depotBadgesListTheModelsLeft() {
    let depot = Achievements.evaluate([], catalog: catalog).first { $0.isDepot && $0.goal >= 3 }!
    #expect(depot.missing.count == depot.goal)
    #expect(depot.missing.allSatisfy { m in catalog.model(id: m.modelId!)?.name == m.label })
    // Catching one takes it off the list.
    let id = depot.missing[0].modelId!
    let atDepot = catalog.model(id: id)!.batches.first { b in
        "depot-\(catalog.model(id: id)!.kind.rawValue)-\(b.depotCode)-\(b.depotName)" == depot.id
    }!
    let after = Achievements.evaluate([SightingRecord(number: atDepot.numbers[0], modelId: id, date: .now)], catalog: catalog)
        .first { $0.id == depot.id }!
    #expect(after.missing.count == depot.goal - 1 && !after.missing.contains { $0.modelId == id })
    // Models that share a name get their years.
    let kleszczowa = Achievements.evaluate([], catalog: catalog).first { $0.id == "depot-BUS-R-2-Kleszczowa" }!
    let conectos = kleszczowa.missing.map(\.label).filter { $0.hasPrefix("Mercedes-Benz Conecto G") }
    #expect(conectos == ["Mercedes-Benz Conecto G 2012", "Mercedes-Benz Conecto G 2016—2017"])
}

@Test func operatorsByTheVehiclesOwnBatch() {
    let cng = catalog.models.first { $0.id == "bus-solaris-urbino-18cng" }!
    let conecto = catalog.models.first { $0.id == "bus-mercedes-benz-628b02" }!
    let relobus = SightingRecord(number: 9925, modelId: cng.id, date: .now)
    let mza = SightingRecord(number: 6218, modelId: conecto.id, date: .now)
    let ops = badge("all-operators", [relobus, mza])
    #expect(ops.proof.compactMap(\.note) == ["MZA", "RELOBUS"])
    // Operators that are never a model's main one (Grygiel, Średnicki) are in the goal.
    #expect(ops.goal == 10)
    // The other eight are left to find, in Polish order: Średnicki after ReloBus, not after Z.
    let left = ops.missing.map(\.label)
    #expect(left.count == 8 && !left.contains("MZA") && !left.contains("ReloBus"))
    #expect(left.firstIndex(of: "Średnicki")! < left.firstIndex(of: "Tramwaje Warszawskie")!)
    #expect(ops.missing.allSatisfy { $0.modelId == nil })

    // #6306 is KMKM's, not part of MZA's 1993 Ikarus 260s at Stalowa (#36).
    let ikarus = catalog.models.first { $0.id == "bus-ikarus-260" }!
    #expect(ikarus.batch(containing: 6306)?.operator == "KMKM")
    #expect(ikarus.batch(containing: 6306)?.placeDisplay == "KMKM")
    #expect(ikarus.batch(containing: 6930)?.placeDisplay == "R-4 STALOWA")
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
    let (out, adj) = LiveHints.adjust([(8592, 3.0), (4235, 2.5)], nearby: nearby([live(4235)]), catalog: catalog)
    #expect(adj.boosted == [4235])
    #expect(out.max { $0.score < $1.score }?.number == 4235)
}

@Test func oneDigitRescueFixesTheCoachLogs() {
    // The camera read 1235 and 9215; the vehicles right there were 4235 and 4215.
    for (read, real) in [(1235, 4235), (9215, 4215)] {
        let (out, adj) = LiveHints.adjust([(read, 1.2)], nearby: nearby([live(real, .tram, metres: 60), live(8592, metres: 90)]), catalog: catalog)
        #expect(adj.rescued == [LiveHints.Rescue(from: read, to: real)])
        #expect(out.max { $0.score < $1.score }?.number == real)
    }
    #expect(LiveHints.oneDigitOff(1235, 4235))
    #expect(!LiveHints.oneDigitOff(1235, 4236))
    #expect(!LiveHints.oneDigitOff(123, 1234))
}

@Test func noRescueWithoutAVehicleRightThere() {
    let (out, adj) = LiveHints.adjust([(1235, 1.2)], nearby: nearby([live(4235, metres: 400)]), catalog: catalog)
    #expect(adj.rescued.isEmpty && adj.boosted.isEmpty)
    #expect(out.map(\.number) == [1235])
    // Two one-digit neighbours: can't tell which, so no guess.
    let two = LiveHints.adjust([(1235, 1.2)], nearby: nearby([live(4235, metres: 40), live(1285, metres: 60)]), catalog: catalog)
    #expect(two.adjustment.rescued.isEmpty)
    #expect(LiveHints.adjust([(1235, 1.2)], nearby: [], catalog: catalog).candidates.count == 1)
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

@Test func huntTargetsSpecsAndLineNarrow() {
    let lionG = catalog.model(id: "bus-man-a23")!
    let swing = catalog.model(id: "tram-pesa-120n")!
    // The 2019–20 Lion's City Gs are CNG, the 2010 ones diesel: drive goes by the vehicle.
    let cng = HuntTargets(drives: [.cng])
    #expect(cng.matches(lionG, number: 7200, line: "190") && !cng.matches(lionG, number: 3400, line: "190"))
    // Trams have no drive in the city's data, so a drive picked means buses.
    #expect(!HuntTargets(drives: [.electric]).matches(swing, number: swing.numbers[0], line: "17"))
    // Bands of one kind add up; kinds of spec narrow each other.
    let long = HuntTargets(lengths: [.to20, .over30])
    #expect(long.matches(lionG, number: 7200, line: "1") && long.matches(swing, number: swing.numbers[0], line: "1"))
    #expect(!HuntTargets(lengths: [.over30], floors: [.high]).matches(swing, number: swing.numbers[0], line: "1"))
    #expect(HuntTargets.LengthBand.of(12_000) == .to13 && HuntTargets.LengthBand.of(30_120) == .over30)
    // A line narrows too, however it's written.
    let line = HuntTargets(line: "L-4")
    #expect(line.matches(lionG, number: 7200, line: "L4") && !line.matches(lionG, number: 7200, line: "L40"))
    // All of these hunt across the city; a type alone doesn't.
    #expect(cng.isCityWide && line.isCityWide && !cng.hasPicks && !HuntTargets(kind: .bus).isCityWide)
    // Round-trips, and older builds' tokens still read.
    let all = HuntTargets(tiers: [.gold], kind: .bus, line: "N83", lengths: [.to20], drives: [.cng, .lng], floors: [.low])
    #expect(all.count == 7)
    #expect(all.rawValue == "kind:BUS,tier:GOLD,line:N83,length:13-20,drive:cng,drive:lng,floor:LF")
    #expect(HuntTargets(rawValue: all.rawValue) == all)
    #expect(HuntTargets(rawValue: "drive:steam,length:99,line:,floor:XF") == HuntTargets())
}

@Test func huntTargetsAddingAModelKeepsItInView() {
    let lionG = catalog.model(id: "bus-man-a23")!
    let swing = catalog.model(id: "tram-pesa-120n")!
    // Other picks stay: the model adds to them.
    let gold = HuntTargets(tiers: [.gold]).adding(swing)
    #expect(gold.tiers == [.gold] && gold.models == [swing.id])
    // A line or the other type would hide it, so they go; a matching type stays.
    #expect(HuntTargets(line: "523").adding(swing) == HuntTargets(models: [swing.id]))
    #expect(HuntTargets(kind: .bus).adding(swing).kind == nil)
    #expect(HuntTargets(kind: .tram).adding(swing).kind == .tram)
    // Specs go only when none of its vehicles have them: some Lion's City Gs are CNG.
    #expect(HuntTargets(drives: [.cng]).adding(lionG).drives == [.cng])
    #expect(HuntTargets(drives: [.cng]).adding(swing).drives.isEmpty)
    let added = HuntTargets(tiers: [.gold], lengths: [.under10]).adding(lionG)
    #expect(added.lengths.isEmpty && added.matches(lionG, number: 7200, line: "190"))
    // Adding twice changes nothing.
    #expect(gold.adding(swing) == gold)
}

@Test func huntSearchFindsLinesAndNumbers() {
    let snap = LiveSnapshot(vehicles: [live(4235, .tram, line: "33"), live(4236, .tram, line: "33"),
                                       live(8592, .bus, line: "523"), live(1000, .bus, line: "L-4"),
                                       live(5100, .bus, line: "523")], fetched: fixtureNow)
    // Lines starting with what you typed, the exact one first.
    let r = HuntSearch.results(for: "52", snapshot: snap, catalog: catalog)
    #expect(r.lines.map(\.line) == ["523"] && r.lines.first?.count == 2)
    #expect(HuntSearch.results(for: "l4", snapshot: snap, catalog: catalog).lines.map(\.line) == ["L-4"])
    // A fleet number: every model that has it, the running one first.
    let n = HuntSearch.results(for: "1000", snapshot: snap, catalog: catalog)
    #expect(n.vehicles.count == 2 && n.vehicles.first?.live?.kind == .bus)
    #expect(n.vehicles.contains { $0.model.kind == .tram && $0.live == nil })
    // Nothing running: still found, just not live.
    #expect(HuntSearch.results(for: "4229", snapshot: nil, catalog: catalog).vehicles.first?.live == nil)
    #expect(HuntSearch.results(for: " ", snapshot: snap, catalog: catalog).isEmpty)
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
    // Club buses ZTM doesn't list share numbers with regular ones: the KMKM's 1977 Jelcz 272 MEX
    // #1983 isn't MZA's 2024 Yutong U12 #1983, so it doesn't get that bus's specs.
    #expect(catalog.model(id: "bus-jelcz-272-mex")?.specs == nil)
}

@Test func vehiclesOfAnotherTypeKeepTheirOwnSpecs() {
    // #26: 70 diesels from 2010 outvote 60 CNG buses from 2019–20 for the model's specs.
    let g = catalog.model(id: "bus-man-a23")!
    #expect(g.specs(of: 3400)?.drive == .diesel)
    #expect(g.specs(of: 7253)?.drive == .cng)
    #expect(g.specs(of: 7253)?.seats == 38)
    let spread = g.spread!
    #expect(spread.drives == [.diesel, .cng])
    #expect(spread.places == 139...156)
    #expect(spread.metres == 18...18)
    #expect(spread.airCon == .all)
    #expect(g.drive(of: g.batch(containing: 7253)!) == .cng)
    #expect(g.drive(of: g.batch(containing: 3400)!) == .diesel)
    // One drive throughout: batches don't repeat it.
    let e18 = catalog.model(id: "bus-solaris-urbino-18e")!
    #expect(e18.spread?.drives == [.electric])
    #expect(e18.drive(of: e18.batches[0]) == nil)
    // A batch that mixes types names no drive: MZA's 2015 Solbus SM18s are LNG and diesel.
    let sm18 = catalog.model(id: "bus-solbus-sm18")!
    #expect(sm18.drive(of: sm18.batches.first { $0.year == 2015 }!) == nil)
    // The 2017 Ursus CS2s are two operators' batches: MZA's 10 electric, KM Łomianki's 2 diesel.
    let cs2 = catalog.model(id: "bus-ursus-cs2")!
    #expect(cs2.spread?.drives == [.electric, .diesel])
    #expect(cs2.drive(of: cs2.batch(containing: 762)!) == .diesel)
}

@Test func spreadMixesAirConAndKeepsOldFilesWorking() throws {
    let a = ModelSpecs(length: 12000, drive: .diesel, seats: 28, places: 96, airCon: true)
    let b = ModelSpecs(length: 10500, drive: .diesel, seats: 26, places: 90, airCon: false)
    let m = VehicleModel(id: "x", name: "X", make: "X", kind: .bus, operators: [], fleet: 3, firstYear: nil,
                         lastYear: nil, batches: [Batch(year: 2020, depotCode: "", depotName: "", numbers: [1, 2, 3])],
                         specs: a, variants: [SpecVariant(specs: b, numbers: [3])])
    #expect(m.spread?.airCon == .some)
    #expect(m.spread?.metres == 10.5...12)
    #expect(m.specs(of: 1) == a && m.specs(of: 3) == b)
    // Without variants (every fleet.json before them) it's just the model's specs.
    let plain = VehicleModel(id: "x", name: "X", make: "X", kind: .bus, operators: [], fleet: 3, firstYear: nil,
                             lastYear: nil, batches: m.batches, specs: a)
    #expect(plain.spread?.places == 96...96 && plain.specs(of: 3) == a)
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
    // The number was read but the bus wasn't lifted: no sticker beats a portrait.
    #expect(SubjectPicker.rank([small, big], numberBox: CGRect(x: 0.6, y: 0.5, width: 0.05, height: 0.03)) == nil)
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

// MARK: - Coupled trams

private let n105 = catalog.model(id: "tram-konstal-105n")!
private let n105Vintage = catalog.model(id: "tram-konstal-105n-vintage")!
private let n2k = catalog.model(id: "tram-alstom-konstal-105n")!
private let n13 = catalog.model(id: "tram-konstal-13n")!

@Test func coupledCarIsKeptNotRescuedIntoItsLead() {
    // The feed reports the set as 1282; the camera read the other car, 1281.
    let (out, adj) = LiveHints.adjust([(1281, 1.2)], nearby: nearby([live(1282, .tram, metres: 60)]), catalog: catalog)
    #expect(adj.rescued.isEmpty)
    #expect(adj.partners == [LiveHints.Partner(number: 1281, lead: 1282)])
    #expect(out.map(\.number) == [1281])
    #expect(out[0].score == 1.2 + LiveHints.boost)
}

@Test func aRealNumberIsNotRescuedIntoItsNeighbour() {
    // From the debug logs: 1219 read clean, rescued into 1212 at 33 m; 4229 and 4219, the
    // trams at the Wilanów loop, swapped both ways. Each time the read was right.
    for (read, near, kind) in [(1219, 1212, VehicleKind.bus), (4229, 4219, .tram), (4219, 4229, .tram)] {
        let (out, adj) = LiveHints.adjust([(read, 3.1)], nearby: nearby([live(near, kind, metres: 60)]), catalog: catalog)
        #expect(adj.rescued.isEmpty)
        #expect(out.max { $0.score < $1.score }?.number == read)
        // Still offered, below the read.
        #expect(out.map(\.number) == [read, near])
    }
    // 1393 is a 105Na, 1392 a 105N2k: not the same set, and both real, so 1393 stands.
    let other = LiveHints.adjust([(1393, 1.2)], nearby: nearby([live(1392, .tram, metres: 60)]), catalog: catalog)
    #expect(other.adjustment.rescued.isEmpty && other.adjustment.partners.isEmpty)
    #expect(other.candidates.max { $0.score < $1.score }?.number == 1393)
    // A number no tram has is still rescued: 4729 by the 4229 right there.
    let stranger = LiveHints.adjust([(4729, 1.0)], nearby: nearby([live(4229, .tram, metres: 28)]), catalog: catalog)
    #expect(stranger.adjustment.rescued == [LiveHints.Rescue(from: 4729, to: 4229)])
    // Two 105Na sets right there: no telling which is ours.
    let two = LiveHints.adjust([(1281, 1.2)], nearby: nearby([live(1282, .tram, metres: 60), live(1284, .tram, metres: 80)]),
                               catalog: catalog)
    #expect(two.adjustment.partners.isEmpty && two.adjustment.rescued.isEmpty)
}

@Test func coupledCarTakesItsSetsLine() {
    let snap = LiveSnapshot(vehicles: [live(1282, .tram, line: "9", metres: 60)], fetched: fixtureNow)
    let near = nearby([live(1282, .tram, line: "9", metres: 60)])
    #expect(LiveHints.line(for: 1281, kind: .tram, snapshot: snap, at: fixtureNow, model: n105, nearby: near) == "9")
    #expect(LiveHints.line(for: 1281, kind: .tram, snapshot: snap, at: fixtureNow) == nil)
    // No location: the one running neighbour, if there's only one.
    #expect(LiveHints.line(for: 1283, kind: .tram, snapshot: snap, at: fixtureNow, model: n105) == "9")
    let both = LiveSnapshot(vehicles: [live(1282, .tram, line: "9"), live(1284, .tram, line: "17")], fetched: fixtureNow)
    #expect(LiveHints.line(for: 1283, kind: .tram, snapshot: both, at: fixtureNow, model: n105) == nil)
    // Not a coupled car: nothing borrowed.
    #expect(LiveHints.line(for: 795, kind: .tram, snapshot: LiveSnapshot(vehicles: [live(796, .tram)], fetched: fixtureNow),
                           at: fixtureNow, model: n13) == nil)
}

@Test func runningSetSettlesTramOverBus() {
    let match = catalog.match(number: 1000)
    guard case .ambiguous = match else { Issue.record("1000 should be a bus and a tram"); return }
    #expect(LiveHints.resolve(match, number: 1000, nearby: nearby([live(1001, .tram)]), catalog: catalog) == .certain(n105Vintage))
    // The bus itself reporting right there wins.
    let bus = catalog.model(id: "bus-solaris-urbino-10")!
    #expect(LiveHints.resolve(match, number: 1000, nearby: nearby([live(1001, .tram), live(1000, .bus)]), catalog: catalog)
            == .certain(bus))
}

@Test func partnerSuggestionsInOrder() {
    let s = CoupledSet.suggestions(for: 1283, model: n105, photoNumbers: [1286], nearby: nearby([live(1282, .tram)]), catalog: catalog)
    #expect(s.map(\.number) == [1286, 1282, 1284])
    #expect(s.map(\.source) == [.photo, .feed, .neighbour])
    let fixed = CoupledSet.suggestions(for: 1252, model: n105Vintage, photoNumbers: [1000], nearby: nearby([live(1001, .tram)]), catalog: catalog)
    #expect(fixed.map(\.number) == [1251, 1000, 1001])
    #expect(fixed.first?.source == .fixed)
    // The caught number and numbers not in the model are skipped, and three is the most.
    let capped = CoupledSet.suggestions(for: 1283, model: n105, photoNumbers: [1283, 99_999, 1286, 1289, 1290], nearby: [], catalog: catalog)
    #expect(capped.map(\.number) == [1286, 1289, 1290])
}

@Test func partnerSuggestionsStayInTheModel() {
    // 1393 is a 105Na: never offered for a 105N2k.
    let s = CoupledSet.suggestions(for: 1392, model: n2k, photoNumbers: [1393], nearby: nearby([live(1393, .tram)]), catalog: catalog)
    #expect(!s.map(\.number).contains(1393))
    #expect(s.map(\.number) == [1391])
    #expect(CoupledSet.suggestions(for: 821, model: n13, photoNumbers: [], nearby: [], catalog: catalog).map(\.number) == [818])
    #expect(CoupledSet.suggestions(for: 795, model: n13, photoNumbers: [796], nearby: [], catalog: catalog).isEmpty)
    let swing = catalog.model(id: "tram-pesa-120n")!
    #expect(CoupledSet.suggestions(for: swing.numbers[1], model: swing, photoNumbers: [], nearby: [], catalog: catalog).isEmpty)
}

@Test func coupledFleetData() throws {
    let coupled = Set(catalog.models.filter(\.coupled).map(\.id))
    #expect(coupled == ["tram-konstal-105n", "tram-alstom-konstal-105n", "tram-hcp-123n"])
    // The KMKM's vintage sets stay coupled through `sets`; #1006, the promotional car, runs alone.
    #expect(n105Vintage.isCoupled(1000) && n105Vintage.fixedPartner(of: 1000) == 1001)
    #expect(n105Vintage.has(1006) && !n105Vintage.isCoupled(1006) && !n105.has(1006))
    #expect(!n13.coupled && n13.isCoupled(821) && n13.isCoupled(818) && !n13.isCoupled(795))
    #expect(n13.fixedPartner(of: 821) == 818)
    #expect(n105Vintage.fixedPartner(of: 1252) == 1251)
    #expect(n105.fixedPartner(of: 1282) == nil)
    #expect(!n105.isCoupled(99_999))
    #expect(catalog.models.filter { $0.kind == .bus }.allSatisfy { !$0.coupled && $0.sets.isEmpty })
    // Fleet files from before coupling decode as single cars.
    let old = Data(#"{"id":"x","name":"X","make":"X","kind":"TRAM","operators":[],"fleet":1,"batches":[]}"#.utf8)
    let m = try JSONDecoder().decode(VehicleModel.self, from: old)
    #expect(!m.coupled && m.sets.isEmpty && m.trailers.isEmpty && !m.tows)
}

// MARK: - Vintage trailers (#33)

private let nModel = catalog.model(id: "tram-konstal-n")!
private let n4 = catalog.model(id: "tram-konstal-4n")!
private let kModel = catalog.model(id: "tram-gdanska-fabryka-wagonow-wiwk-k")!

@Test func trailerFleetData() {
    #expect(catalog.trailers == [1620, 1811])
    #expect(nModel.isTrailer(1620) && nModel.isTrailer(1811) && !nModel.pullsTrailers(1620))
    #expect(nModel.pullsTrailers(607) && n4.pullsTrailers(838) && kModel.pullsTrailers(445))
    #expect(nModel.takesSecondCar(1620) && !n13.takesSecondCar(795) && n13.takesSecondCar(821))
    // Works cars ZTM still lists are left out.
    #expect(!kModel.has(2405) && !kModel.has(2400) && !nModel.has(1770) && !n13.has(534) && !n105.has(1315))
}

@Test func trailerPairsAcrossModels() {
    #expect(catalog.secondCarModel(838, of: 1620, model: nModel)?.id == n4.id)
    #expect(catalog.secondCarModel(1811, of: 445, model: kModel)?.id == nModel.id)
    #expect(catalog.secondCarModel(607, of: 1620, model: nModel)?.id == nModel.id)
    // 1811 is an Urbino 12's number too: next to a motor car it's the trailer.
    #expect(catalog.secondCarModel(1811, of: 838, model: n4)?.id == nModel.id)
    // Two motor cars, two trailers, or a car that pulls none: not a pair.
    #expect(catalog.secondCarModel(838, of: 873, model: n4) == nil)
    #expect(catalog.secondCarModel(1811, of: 1620, model: nModel) == nil)
    #expect(catalog.secondCarModel(1620, of: 795, model: n13) == nil)
    #expect(Set(catalog.secondCarModels(of: 1620, model: nModel).map(\.id)) == [nModel.id, n4.id, kModel.id])
    #expect(catalog.secondCarModels(of: 838, model: n4).map(\.id) == [nModel.id])
}

@Test func trailerSuggestions() {
    // A motor car: a trailer read in the photo first, then the other one.
    let motor = CoupledSet.suggestions(for: 838, model: n4, photoNumbers: [1811], nearby: [], catalog: catalog)
    #expect(motor.map(\.number) == [1811, 1620])
    #expect(motor.map(\.source) == [.photo, .trailer])
    // A trailer: the one motor car running right there.
    let trailer = CoupledSet.suggestions(for: 1620, model: nModel, photoNumbers: [], nearby: nearby([live(838, .tram)]),
                                         catalog: catalog)
    #expect(trailer.map(\.number) == [838])
    #expect(trailer.first?.source == .feed)
}

@Test func trailerRunsWithItsMotorCar() {
    let snap = LiveSnapshot(vehicles: [live(838, .tram, line: "T", metres: 40)], fetched: fixtureNow)
    let near = nearby([live(838, .tram, line: "T", metres: 40)])
    #expect(LiveHints.line(for: 1620, kind: .tram, snapshot: snap, at: fixtureNow, model: nModel, nearby: near,
                           catalog: catalog) == "T")
    // Two motor cars right there: no telling which pulls it.
    let two = nearby([live(838, .tram, line: "T"), live(607, .tram, line: "W", metres: 80)])
    #expect(CoupledSet.partner(of: 1620, model: nModel, nearby: two, catalog: catalog) == nil)
    // A motor car running right there settles 1811 as the trailer, not the Urbino.
    #expect(LiveHints.resolve(catalog.match(number: 1811), number: 1811, nearby: near, catalog: catalog) == .certain(nModel))
    // In the shot with the motor car you caught, it's the second car, not another catch.
    #expect(AlsoInShot.isPartner(1620, of: 838, model: n4, catalog: catalog))
    #expect(!AlsoInShot.isPartner(873, of: 838, model: n4, catalog: catalog))
}

@Test func secondCarCountsForTheBookNotTheDayOut() {
    let pair = [SightingRecord(number: 1282, modelId: n105.id, date: day(2026, 5, 5), hasSticker: true),
                SightingRecord(number: 1281, modelId: n105.id, date: day(2026, 5, 5) - 0.001, hasSticker: true, pairedWith: 1282)]
    #expect(!eval(pair)["twins"]!.earned)
    // Caught on their own, they're twins.
    #expect(eval([pair[0], SightingRecord(number: 1281, modelId: n105.id, date: day(2026, 6, 6))])["twins"]!.earned)
    // Ten cars in ten catches, one of them a second car.
    let cars = Array(n105.numbers.prefix(10))
    let ten = cars.enumerated().map { i, n in
        SightingRecord(number: n, modelId: n105.id, date: day(2026, 5, 5), hasSticker: true, pairedWith: i == 9 ? cars[8] : nil)
    }
    #expect(eval(ten)["trams-day"]!.progress == 9)
    #expect(eval(ten)["photographer"]!.progress == 9)
    #expect(eval(ten)["collector"]!.level == 1)
    #expect(eval([SightingRecord(number: 1300, modelId: n105.id, date: .now, pairedWith: 1301)])["round-number"]!.earned)
    let batch = n105.batches.first { $0.numbers.count == 2 }!
    let both = [SightingRecord(number: batch.numbers[0], modelId: n105.id, date: .now),
                SightingRecord(number: batch.numbers[1], modelId: n105.id, date: .now, pairedWith: batch.numbers[0])]
    #expect(eval(both)["full-batch"]!.earned)
}

@Test func backupKeepsTheCoupledLink() throws {
    let second = BackupManifest.Sighting(id: UUID(), number: 1281, modelId: n105.id, date: Date(timeIntervalSince1970: 1_790_000_000),
                                         pairedWith: 1282)
    let back = try BackupManifest.decode(BackupManifest(sightings: [second], manual: []).encoded())
    #expect(back.sightings.first?.pairedWith == 1282)
    // Backups from before coupling have no such key.
    let old = Data(#"{"version":1,"exported":"2026-09-01T10:00:00Z","manual":[],"sightings":[{"id":"\#(UUID().uuidString)","number":1281,"modelId":"x","date":"2026-09-01T10:00:00Z"}]}"#.utf8)
    #expect(try BackupManifest.decode(old).sightings.first?.pairedWith == nil)
}

// MARK: - Erasing people

/// A 10×6 mask, row by row: "#" is in.
private func mask(_ rows: [String]) -> [UInt8] { rows.joined().map { $0 == "#" ? 255 : 0 } }

@Test func erasingSomeoneMidVehicleIsABite() {
    // A bus with someone standing in front of its middle (columns 4–5).
    let before = mask(["##########", "##########", "##########", "##########", "##########", "....##...."])
    let after = mask(["##########", "####..####", "####..####", "####..####", "####..####", ".........."])
    let person = CGRect(x: 0.4, y: 1.0 / 6, width: 0.2, height: 5.0 / 6)
    let share = Notch.shares(before: before, after: after, width: 10, height: 6, boxes: [person])[0]
    #expect(share > Notch.limit)
}

@Test func erasingSomeoneAtTheEndIsClean() {
    // Someone at the bus's left end: the bus carries on to one side of them only.
    let before = mask(["##########", "##########", "##########", "##########", "##########", "##........"])
    let after = mask(["..########", "..########", "..########", "..########", "..########", ".........."])
    let person = CGRect(x: 0, y: 0, width: 0.2, height: 1)
    #expect(Notch.shares(before: before, after: after, width: 10, height: 6, boxes: [person]) == [0])
}

// MARK: - Also in shot (#30)

private let tramicus = catalog.model(id: "tram-pesa-120n-tramicus")!
private func read(_ n: Int, _ score: Double, x: Double, y: Double = 0.5) -> AlsoInShot.Read {
    AlsoInShot.Read(number: n, score: score, boxes: [CGRect(x: x, y: y, width: 0.08, height: 0.03)])
}

@Test func passingVehicleIsOffered() {
    let reads = [read(3105, 4, x: 0.2), read(3200, 3.5, x: 0.7)]
    let found = AlsoInShot.vehicles(in: reads, caught: 3105, model: tramicus, partner: nil, catalog: catalog, nearby: [])
    #expect(found.map(\.number) == [3200])
    #expect(found.first?.model.id == "tram-pesa-120n")
    #expect(found.first?.box.minX == 0.7)
}

@Test func alsoInShotSkipsMisreadsAndGuesses() {
    func found(_ reads: [AlsoInShot.Read], caught: Int = 3105, model: VehicleModel = tramicus,
               nearby: [NearbyVehicle] = []) -> [Int] {
        AlsoInShot.vehicles(in: reads, caught: caught, model: model, partner: nil, catalog: catalog, nearby: nearby)
            .map(\.number)
    }
    // Vision's second reading of the caught number's own text.
    #expect(found([read(3105, 4, x: 0.2), read(3150, 3, x: 0.21)]).isEmpty)
    // Neighbours park side by side (9353 and 9355); the app checks it's another object.
    let urbino12 = catalog.model(id: "bus-solaris-urbino-12")!
    #expect(found([read(9353, 4, x: 0.3), read(9355, 3.8, x: 0.8)], caught: 9353, model: urbino12) == [9355])
    #expect(AlsoInShot.couldBeMisread(9355, of: 9353) && !AlsoInShot.couldBeMisread(9320, of: 9556))
    // Without the feed a 3-digit number could be a line on the display.
    #expect(found([read(3105, 4, x: 0.2), read(821, 3, x: 0.7)]).isEmpty)
    // The line on a bus's display, which is also a 13N tram's number.
    let urbino = catalog.model(id: "bus-solaris-urbino-18e")!
    #expect(found([read(5918, 4, x: 0.6), read(503, 3.5, x: 0.6, y: 0.3)], caught: 5918, model: urbino).isEmpty)
    // With the feed, it has to be running right there.
    #expect(found([read(3105, 4, x: 0.2), read(3200, 3, x: 0.7)], nearby: nearby([live(3105, .tram, line: "9")])).isEmpty)
    // Not written in the photo: a feed neighbour offered for a misread.
    #expect(found([read(3105, 4, x: 0.2), AlsoInShot.Read(number: 3200, score: 3, boxes: [])]).isEmpty)
    // The caught tram's own second car belongs to the SECOND CAR chip.
    #expect(found([read(1282, 4, x: 0.2), read(1281, 3, x: 0.7)], caught: 1282, model: n105).isEmpty)
}

@Test func numberOnABusAndATramGoesWithTheCaughtKind() {
    let urbino = catalog.model(id: "bus-solaris-urbino-18e")!
    func model(_ caught: Int, _ m: VehicleModel, nearby: [NearbyVehicle] = []) -> String? {
        AlsoInShot.vehicles(in: [read(caught, 4, x: 0.2), read(2022, 3, x: 0.7)], caught: caught, model: m,
                            partner: nil, catalog: catalog, nearby: nearby).first?.model.id
    }
    #expect(model(5941, urbino) == "bus-solbus-sm18")
    #expect(model(3105, tramicus) == "tram-alstom-konstal-105n")
    // The feed knows better: the tram 2022 is the one right there.
    #expect(model(5941, urbino, nearby: nearby([live(5941), live(2022, .tram, line: "17")])) == "tram-alstom-konstal-105n")
}

@Test func alsoInShotKeepsToTheLikeliestFew() {
    let reads = [read(3105, 4, x: 0.1), read(3200, 2, x: 0.3), read(3250, 3, x: 0.5), read(3290, 2.5, x: 0.7)]
    let found = AlsoInShot.vehicles(in: reads, caught: 3105, model: tramicus, partner: nil, catalog: catalog, nearby: [])
    #expect(found.map(\.number) == [3250, 3290])
}

@Test func displayLineGetsACloserLookAndLosesToTheBumper() {
    // A MAN on line 716 (TestFlight feedback): the board's "716" is a vintage Konstal N's
    // number, and the whole-photo read saw nothing else.
    let full = [TextObservation(text: "716", confidence: 1, height: 0.04),
                TextObservation(text: "CM.WOLSKI", confidence: 1, height: 0.04)]
    let first = NumberExtractor.candidates(in: full, mode: .auto, catalog: catalog)
    #expect(first.map(\.number) == [716])
    #expect(NumberExtractor.wantsCloserLook(first))
    // The tiles find the small fleet number on the front.
    let tiles = [TextObservation(text: "7205", confidence: 1, height: 0.015)]
    #expect(NumberExtractor.best(in: full + tiles, mode: .auto, catalog: catalog) == 7205)
    #expect(!NumberExtractor.wantsCloserLook([(7205, 3)]))
}

@Test func aPickedLineShowsAllOfItWhereverItIs() {
    // #37: the search said "4 out now", the map then showed nothing.
    let hrc = catalog.model(id: "tram-hrc-140n")!
    let caught = CollectionStats(sightings: [SightingRecord(number: hrc.numbers[0], modelId: hrc.id, date: .now)])
    let snap = LiveSnapshot(vehicles: [
        live(hrc.numbers[0], .tram, line: "4", metres: 300),         // already caught
        live(hrc.numbers[1], .tram, line: "4", metres: 90_000),      // past the 60 km a filter looks
        live(hrc.numbers[2], .tram, line: "4", metres: 1000),
        live(hrc.numbers[3], .tram, line: "14", metres: 100),        // another line
        live(hrc.numbers[4], .tram, line: "l-4", metres: 200),       // the L-4, not the 4
    ], fetched: fixtureNow)
    let pins = Wanted.onLine("4", snapshot: snap, catalog: catalog, caught: caught, lat: here.lat, lon: here.lon)
    #expect(pins.map(\.vehicle.number) == [hrc.numbers[0], hrc.numbers[2], hrc.numbers[1]])
    #expect(pins.first?.kind == .caught)
    // Written either way, the L-4 is the same line.
    #expect(Wanted.onLine("L4", snapshot: snap, catalog: catalog, caught: caught, lat: here.lat, lon: here.lon)
        .map(\.vehicle.number) == [hrc.numbers[4]])
}

@Test func catchLogMarksFirstsAndGroupsByDay() {
    let day: TimeInterval = 86_400
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    // Out of order, as a query might hand them over.
    let records = [
        SightingRecord(number: 7205, modelId: "man", date: t0 + day + 60),   // seen again, next day
        SightingRecord(number: 7205, modelId: "man", date: t0),              // first MAN
        SightingRecord(number: 7240, modelId: "man", date: t0 + 120),        // a new MAN
        SightingRecord(number: 3105, modelId: "tramicus", date: t0 + day),   // first Tramicus
    ]
    #expect(CatchLog.marks(records) == [.again, .newModel, .newVehicle, .newModel])
    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = TimeZone(identifier: "UTC")!
    let days = CatchLog.days(records.map(\.date), calendar: utc)
    #expect(days.map(\.indices) == [[0, 3], [2, 1]])
}

@Test func aFilteredHuntReachesWarsawFromAnywhere() {
    // #38: from Bydgoszcz, every filter counted 0.
    let hrc = catalog.model(id: "tram-hrc-140n")!
    let snap = LiveSnapshot(vehicles: [
        live(hrc.numbers[0], .tram, metres: 230_000),
        live(hrc.numbers[1], .tram, metres: 1_000),
    ], fetched: fixtureNow)
    let pins = Wanted.anywhere(snapshot: snap, catalog: catalog, caught: CollectionStats(sightings: []),
                               lat: here.lat, lon: here.lon)
    #expect(Set(pins.map(\.vehicle.number)) == [hrc.numbers[0], hrc.numbers[1]])
}

// MARK: - Stats

private func at(_ s: String) -> Date {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: "Europe/Warsaw")
    f.dateFormat = "yyyy-MM-dd HH:mm"
    return f.date(from: s)!
}

private var warsaw: Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "Europe/Warsaw")!
    c.firstWeekday = 2
    return c
}

@Test func periodStatsSplitNewFromSeenAgain() {
    let yutong = catalog.model(id: "bus-yutong-u12-b")!
    let urbino = catalog.model(id: "bus-solaris-urbino-18")!
    let y = yutong.numbers[0], u = urbino.numbers[0]
    let records = [
        SightingRecord(number: y, modelId: yutong.id, date: at("2026-09-27 16:10"), line: "229", district: "Wilanów", temperature: 18),
        SightingRecord(number: y, modelId: yutong.id, date: at("2026-10-01 08:05"), line: "229", district: "Wilanów", temperature: 9),
        SightingRecord(number: u, modelId: urbino.id, date: at("2026-10-01 16:40"), line: "519", district: "Powsin", temperature: 14),
    ]
    let october = PeriodStats(records, period: .month(year: 2026, month: 10), catalog: catalog, now: at("2026-10-04 12:00"), calendar: warsaw)
    #expect(october.catches == 2)
    #expect(october.vehicles == 2)
    #expect(october.newVehicles == 1) // the Yutong went in in September
    #expect(october.newModels == 1)
    #expect(october.daysOut == 1)
    #expect(october.hours[8] == 1 && october.hours[16] == 1)
    #expect(october.weekdays[4] == 2) // 1 Oct 2026 is a Thursday
    #expect(october.fleetShare == 1 / Double(catalog.totalFleet))
    #expect(october.records.coldest?.temperature == 9)
    #expect(october.records.rarest?.modelId == yutong.id)

    let all = PeriodStats(records, period: .all, catalog: catalog, now: at("2026-10-04 12:00"), calendar: warsaw)
    #expect(all.catches == 3 && all.vehicles == 2 && all.newVehicles == 2)
    #expect(all.topLines.first == RankedItem(name: "229", count: 2))
    #expect(all.topPlaces.first?.name == "Wilanów")
    #expect(all.records.mostSeen == VehicleCount(number: y, modelId: yutong.id, times: 2))
    #expect(all.fleetShare == 2 / Double(catalog.totalFleet))
}

@Test func secondCarsAreVehiclesButNotCatches() {
    let tram = catalog.models.first { $0.coupled }!
    let records = [
        SightingRecord(number: tram.numbers[0], modelId: tram.id, date: at("2026-09-28 12:00"), line: "16"),
        SightingRecord(number: tram.numbers[1], modelId: tram.id, date: at("2026-09-28 11:59"), line: "16", pairedWith: tram.numbers[0]),
    ]
    let s = PeriodStats(records, period: .all, catalog: catalog, calendar: warsaw)
    #expect(s.catches == 1)
    #expect(s.vehicles == 2)
    #expect(s.trams == 2)
    #expect(s.topLines == [RankedItem(name: "16", count: 1)])
}

@Test func bestStreakFindsTheLongestRun() {
    let dates = ["2026-09-23 08:00", "2026-09-25 09:00", "2026-09-26 10:00", "2026-09-26 18:00",
                 "2026-09-27 07:00", "2026-09-29 12:00"].map(at)
    let run = Streak.best(dates, calendar: warsaw)
    #expect(run?.days == 3)
    #expect(run?.start == warsaw.startOfDay(for: at("2026-09-25 12:00")))
    #expect(run?.end == warsaw.startOfDay(for: at("2026-09-27 12:00")))
    #expect(Streak.best([], calendar: warsaw) == nil)
}

@Test func periodsListNewestFirst() {
    let dates = ["2025-12-30 10:00", "2026-09-23 08:00", "2026-10-01 09:00"].map(at)
    #expect(StatsPeriod.available(dates, calendar: warsaw) == [
        .all, .year(2026), .year(2025), .month(year: 2026, month: 10), .month(year: 2026, month: 9), .month(year: 2025, month: 12),
    ])
}

@Test func memoryPrefersTheOldestAnniversary() {
    let today = at("2026-10-04 09:00")
    let caught: Set<Date> = [warsaw.startOfDay(for: at("2026-09-27 12:00")), warsaw.startOfDay(for: at("2026-09-04 12:00"))]
    let pick = Memory.pick(for: today, hasCatches: { caught.contains($0) }, randomCount: 3, calendar: warsaw)
    #expect(pick?.kind == .monthAgo)
    let nothing = Memory.pick(for: today, hasCatches: { _ in false }, randomCount: 3, calendar: warsaw)
    #expect(nothing?.kind == .first || nothing?.kind == .random)
}

// MARK: - Tracking

@Test func trackPlanRunsToYourStop() throws {
    let m = RouteMatch(shape: eastbound, along: 100, speed: 8)
    // Waiting just off the street by the third stop.
    let plan = try #require(TrackPlan.make(match: m, lat: routeLat + 0.0004, lon: 21.0151))
    let stop = try #require(eastbound.stops.first { $0.name == "east30" })
    #expect(plan.stop == "east30")
    #expect(plan.stops == 3)
    #expect(abs(plan.distance - (stop.along - 100)) < 1)
    #expect(plan.at == nil)
    // The path covers the vehicle and your stop, with some room either side.
    #expect(eastbound.project((plan.path.first!.latitude, plan.path.first!.longitude))!.along < 1)
    #expect(eastbound.project((plan.path.last!.latitude, plan.path.last!.longitude))!.along > stop.along + 300)
    #expect(plan.pathStops.map(\.name).prefix(3) == ["east10", "east20", "east30"])
}

@Test func trackPlanNeedsTheRouteToComePastYou() {
    let m = RouteMatch(shape: eastbound, along: 700, speed: 8)
    // Far off the street, and behind the vehicle: neither is coming your way.
    #expect(TrackPlan.make(match: m, lat: routeLat + 0.005, lon: 21.02) == nil)
    #expect(TrackPlan.make(match: m, lat: routeLat, lon: 21.002) == nil)
    let moving = TrackPlan.make(match: m, lat: routeLat, lon: 21.025)
    #expect(moving?.at == "east20")
}

// MARK: - Correction sheet's line

@Test func aTypedLineListsWhatRunsItNow() {
    let urbino18 = catalog.match(number: 8592, kind: .bus).suggested!
    let sibling = urbino18.numbers.first { $0 != 8592 }!
    let snap = LiveSnapshot(vehicles: [
        live(8592, line: "523", metres: 400), live(sibling, line: "523", metres: 100),
        live(4235, .tram, line: "33"), live(1000, line: "L-8"),
    ], fetched: fixtureNow)
    let r = LineLookup.lookup(" 523", snapshot: snap, routes: nil, near: here, catalog: catalog)
    #expect(r.running.map(\.vehicle.number) == [sibling, 8592])
    #expect(r.models == [urbino18])
    #expect(r.kind == .bus)
    #expect(LineLookup.lookup("33", snapshot: snap, routes: nil, near: nil, catalog: catalog).kind == .tram)
    // Typed the way people write it: "l8" is L-8.
    #expect(LineLookup.lookup("l8", snapshot: snap, routes: nil, near: nil, catalog: catalog).running.count == 1)
    #expect(LineLookup.lookup("", snapshot: snap, routes: nil, near: nil, catalog: catalog).running.isEmpty)

    // Nothing on it now: the timetable still says what kind it is.
    let book = RouteBook(shapes: [RouteBook.key(.bus, "166"): [shape("a", trips: 1, street(lat: 52.2, from: 21.0, to: 21.01))]])
    let quiet = LineLookup.lookup("166", snapshot: snap, routes: book, near: here, catalog: catalog)
    #expect(quiet.running.isEmpty && quiet.models.isEmpty && quiet.kind == .bus)
    #expect(LineLookup.lookup("167", snapshot: snap, routes: book, near: here, catalog: catalog).kind == nil)
}
