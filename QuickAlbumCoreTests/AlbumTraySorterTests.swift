import XCTest
#if canImport(QuickAlbumCore)
@testable import QuickAlbumCore
#else
@testable import QuickAlbum
#endif

final class AlbumTraySorterTests: XCTestCase {
    private func makeAlbum(
        id: String,
        title: String,
        pattern: AlbumPattern = .default,
        latestAssetDate: Date? = nil
    ) -> AlbumSummary {
        AlbumSummary(
            id: id,
            title: title,
            parsed: AlbumPatternEngine.parse(title: title, pattern: pattern),
            assetCount: 3,
            coverAssetID: nil,
            latestAssetDate: latestAssetDate
        )
    }

    func testSmartOrderingWithActiveTargetDatePrefix() {
        let albums = [
            makeAlbum(id: "1", title: "26.11.20.01"),
            makeAlbum(id: "2", title: "26.11.18.01 Beach"),
            makeAlbum(id: "3", title: "26.11.18.03"),
            makeAlbum(id: "4", title: "25.12.31.02"),
            makeAlbum(id: "5", title: "26.11.18.02"),
            makeAlbum(id: "6", title: "Vacation")
        ]

        let sorted = AlbumTraySorter.sortForTray(
            albums: albums,
            targetDatePrefix: "26.11.18",
            includeNonMatching: false,
            searchQuery: ""
        )

        XCTAssertEqual(
            sorted.map(\.title),
            ["26.11.18.03", "26.11.18.02", "26.11.18.01 Beach", "26.11.20.01", "25.12.31.02"]
        )
    }

    func testYearlessTemplateTieBreakerUsesLatestAssetDate() {
        let pattern = AlbumPattern(template: "MM.DD.xx")
        let olderDate = Date(timeIntervalSince1970: 1_700_000_000)
        let newerDate = Date(timeIntervalSince1970: 1_760_000_000)

        let albums = [
            makeAlbum(id: "old", title: "11.18.01", pattern: pattern, latestAssetDate: olderDate),
            makeAlbum(id: "new", title: "11.18.02", pattern: pattern, latestAssetDate: newerDate)
        ]

        let sorted = AlbumTraySorter.sortForTray(
            albums: albums,
            targetDatePrefix: nil,
            includeNonMatching: false,
            searchQuery: ""
        )
        XCTAssertEqual(sorted.map(\.id), ["new", "old"])
    }

    func testSearchAndIncludeNonMatching() {
        let albums = [
            makeAlbum(id: "1", title: "26.11.18.01 Beach"),
            makeAlbum(id: "2", title: "26.11.19.01"),
            makeAlbum(id: "3", title: "Alpha Family"),
            makeAlbum(id: "4", title: "Beach Memories")
        ]

        let allWithNonMatching = AlbumTraySorter.sortForTray(
            albums: albums,
            targetDatePrefix: nil,
            includeNonMatching: true,
            searchQuery: ""
        )
        XCTAssertEqual(allWithNonMatching.map(\.title), ["26.11.19.01", "26.11.18.01 Beach", "Alpha Family", "Beach Memories"])

        let beachMatches = AlbumTraySorter.sortForTray(
            albums: albums,
            targetDatePrefix: nil,
            includeNonMatching: true,
            searchQuery: "beach"
        )
        XCTAssertEqual(beachMatches.map(\.title), ["26.11.18.01 Beach", "Beach Memories"])
    }
}
