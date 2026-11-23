import XCTest
#if canImport(QuickAlbumCore)
@testable import QuickAlbumCore
#else
@testable import QuickAlbum
#endif

final class AlbumPatternEngineTests: XCTestCase {
    private let utcCalendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        return cal
    }()

    private func makeDate(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
        let comps = DateComponents(calendar: utcCalendar, timeZone: utcCalendar.timeZone, year: year, month: month, day: day, hour: hour)
        return comps.date!
    }

    func testDefaultPatternParsingWithAndWithoutLabels() {
        let plain = AlbumPatternEngine.parse(title: "26.11.18.01", pattern: .default)
        XCTAssertEqual(
            plain,
            ParsedAlbumTitle(datePrefix: "26.11.18", counter: 1, label: nil, year: 2026, month: 11, day: 18)
        )

        let beach = AlbumPatternEngine.parse(title: "26.11.18.01 Beach", pattern: .default)
        XCTAssertEqual(
            beach,
            ParsedAlbumTitle(datePrefix: "26.11.18", counter: 1, label: "Beach", year: 2026, month: 11, day: 18)
        )

        let multiWord = AlbumPatternEngine.parse(title: "26.11.18.04  Sunset Cove", pattern: .default)
        XCTAssertEqual(
            multiWord,
            ParsedAlbumTitle(datePrefix: "26.11.18", counter: 4, label: "Sunset Cove", year: 2026, month: 11, day: 18)
        )

        let threeDigitRollover = AlbumPatternEngine.parse(title: "26.11.18.105", pattern: .default)
        XCTAssertEqual(threeDigitRollover?.counter, 105)
        XCTAssertEqual(threeDigitRollover?.year, 2026)
    }

    func testNonMatchingTitlesReturnNil() {
        XCTAssertNil(AlbumPatternEngine.parse(title: "Favorites", pattern: .default))
        XCTAssertNil(AlbumPatternEngine.parse(title: "26.11.18", pattern: .default))
        XCTAssertNil(AlbumPatternEngine.parse(title: "Beach 26.11.18.01", pattern: .default))
        XCTAssertNil(AlbumPatternEngine.parse(title: "26.11.18.1", pattern: .default))
        XCTAssertNil(AlbumPatternEngine.parse(title: "26.13.18.01", pattern: .default))
        XCTAssertNil(AlbumPatternEngine.parse(title: "26.11.00.01", pattern: .default))
    }

    func testAlternateTemplatesParsing() {
        let fullYearPattern = AlbumPattern(template: "YYYY.MM.DD.xx")
        let fullParsed = AlbumPatternEngine.parse(title: "1998.07.04.02 Fireworks", pattern: fullYearPattern)
        XCTAssertEqual(
            fullParsed,
            ParsedAlbumTitle(datePrefix: "1998.07.04", counter: 2, label: "Fireworks", year: 1998, month: 7, day: 4)
        )

        let yearlessPattern = AlbumPattern(template: "MM.DD.xx")
        let yearlessParsed = AlbumPatternEngine.parse(title: "11.18.03 Dinner", pattern: yearlessPattern)
        XCTAssertEqual(
            yearlessParsed,
            ParsedAlbumTitle(datePrefix: "11.18", counter: 3, label: "Dinner", year: nil, month: 11, day: 18)
        )

        let dashedTripleX = AlbumPattern(template: "YY-MM-DD-xxx")
        let dashedParsed = AlbumPatternEngine.parse(title: "26-11-18-009", pattern: dashedTripleX)
        XCTAssertEqual(
            dashedParsed,
            ParsedAlbumTitle(datePrefix: "26-11-18", counter: 9, label: nil, year: 2026, month: 11, day: 18)
        )
        XCTAssertNil(AlbumPatternEngine.parse(title: "26-11-18-09", pattern: dashedTripleX))
    }

    func testTemplateValidation() {
        let valid = AlbumPatternEngine.validate(template: "YY.MM.DD.xx", sampleDate: makeDate(2026, 11, 22), calendar: utcCalendar)
        XCTAssertTrue(valid.isValid)
        XCTAssertEqual(valid.previewPlain, "26.11.22.01")
        XCTAssertEqual(valid.previewWithLabel, "26.11.22.01 Beach")

        XCTAssertFalse(AlbumPatternEngine.validate(template: "").isValid)
        XCTAssertFalse(AlbumPatternEngine.validate(template: "YY.MM.DD").isValid)
        XCTAssertFalse(AlbumPatternEngine.validate(template: "YY.MM.DD.x").isValid)
        XCTAssertFalse(AlbumPatternEngine.validate(template: "xx").isValid)
        XCTAssertFalse(AlbumPatternEngine.validate(template: "YY.MM.xx.xx").isValid)
        XCTAssertFalse(AlbumPatternEngine.validate(template: "YY.MMM.DD.xx").isValid)
    }

    func testCounterMonotonicityGapsRolloverAndHighWaterUndo() {
        let store = InMemoryCounterHistoryStore()
        let date = makeDate(2026, 11, 18)

        // Empty history -> 01
        let c1 = AlbumPatternEngine.computeNextAlbum(for: date, existingAlbums: [], pattern: .default, counterStore: store, calendar: utcCalendar)
        XCTAssertEqual(c1.title, "26.11.18.01")
        XCTAssertEqual(c1.counter, 1)
        XCTAssertEqual(c1.priorHighWaterMark, 0)

        // Existing [01, 03] (gap at 02) -> 04 (never reuses gap)
        let albumsWithGap = [
            AlbumSummary(id: "a1", title: "26.11.18.01", parsed: AlbumPatternEngine.parse(title: "26.11.18.01", pattern: .default), assetCount: 1, coverAssetID: nil, latestAssetDate: nil),
            AlbumSummary(id: "a3", title: "26.11.18.03", parsed: AlbumPatternEngine.parse(title: "26.11.18.03", pattern: .default), assetCount: 1, coverAssetID: nil, latestAssetDate: nil)
        ]
        let c4 = AlbumPatternEngine.computeNextAlbum(for: date, existingAlbums: albumsWithGap, pattern: .default, counterStore: store, calendar: utcCalendar)
        XCTAssertEqual(c4.title, "26.11.18.04")
        XCTAssertEqual(c4.counter, 4)

        // Commit 04, then simulate deleting 04 externally -> still proposes 05 via high-water mark
        AlbumPatternEngine.commitCounter(key: c4.highWaterKey, counter: c4.counter, store: store)
        let c5 = AlbumPatternEngine.computeNextAlbum(for: date, existingAlbums: albumsWithGap, pattern: .default, counterStore: store, calendar: utcCalendar)
        XCTAssertEqual(c5.title, "26.11.18.05")

        // Undo rollback restores prior high-water mark (3)
        AlbumPatternEngine.rollbackCounter(key: c4.highWaterKey, previousHighWaterMark: c4.priorHighWaterMark, store: store)
        let afterRollback = AlbumPatternEngine.computeNextAlbum(for: date, existingAlbums: albumsWithGap, pattern: .default, counterStore: store, calendar: utcCalendar)
        XCTAssertEqual(afterRollback.title, "26.11.18.04")

        // Rollover 99 -> 100
        let album99 = [
            AlbumSummary(id: "a99", title: "26.11.19.99", parsed: AlbumPatternEngine.parse(title: "26.11.19.99", pattern: .default), assetCount: 1, coverAssetID: nil, latestAssetDate: nil)
        ]
        let nextDayRollover = AlbumPatternEngine.computeNextAlbum(for: makeDate(2026, 11, 19), existingAlbums: album99, pattern: .default, counterStore: store, calendar: utcCalendar)
        XCTAssertEqual(nextDayRollover.title, "26.11.19.100")
    }

    func testEarliestDateAndReplacingLabel() {
        let d1 = makeDate(2026, 11, 20)
        let d2 = makeDate(2026, 11, 18)
        let fallback = makeDate(2026, 11, 22)

        XCTAssertEqual(AlbumPatternEngine.earliestDate(from: [d1, nil, d2], fallback: fallback), d2)
        XCTAssertEqual(AlbumPatternEngine.earliestDate(from: [nil, nil], fallback: fallback), fallback)

        let parsed = AlbumPatternEngine.parse(title: "26.11.18.02 Old Label", pattern: .default)!
        XCTAssertEqual(AlbumPatternEngine.replacingLabel(in: parsed, with: "Beach", pattern: .default), "26.11.18.02 Beach")
        XCTAssertEqual(AlbumPatternEngine.replacingLabel(in: parsed, with: "   ", pattern: .default), "26.11.18.02")
    }
}
