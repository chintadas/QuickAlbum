import XCTest
#if canImport(QuickAlbumCore)
@testable import QuickAlbumCore
#else
@testable import QuickAlbum
#endif

final class PhotoAlbumIndexTests: XCTestCase {
    func testInvertedIndexCountsAcrossScopesAndMutations() {
        let albums = [
            RawAlbumRecord(id: "alb-match", title: "26.11.18.01", assetIDs: ["p1", "p2"], coverAssetID: "p2", latestAssetDate: nil),
            RawAlbumRecord(id: "alb-user", title: "Favorites Backup", assetIDs: ["p2", "p3"], coverAssetID: "p3", latestAssetDate: nil)
        ]
        let matchingIDs: Set<String> = ["alb-match"]

        var index = PhotoAlbumIndex(albums: albums)

        // p1 is in 1 matching album
        XCTAssertEqual(index.countedAlbumCount(for: "p1", scope: .allUserAlbums, matchingAlbumIDs: matchingIDs), 1)
        XCTAssertEqual(index.countedAlbumCount(for: "p1", scope: .formatMatchingOnly, matchingAlbumIDs: matchingIDs), 1)

        // p2 is in 2 user albums, 1 matching
        XCTAssertEqual(index.countedAlbumCount(for: "p2", scope: .allUserAlbums, matchingAlbumIDs: matchingIDs), 2)
        XCTAssertEqual(index.countedAlbumCount(for: "p2", scope: .formatMatchingOnly, matchingAlbumIDs: matchingIDs), 1)

        // p3 is only in non-matching user album
        XCTAssertEqual(index.countedAlbumCount(for: "p3", scope: .allUserAlbums, matchingAlbumIDs: matchingIDs), 1)
        XCTAssertEqual(index.countedAlbumCount(for: "p3", scope: .formatMatchingOnly, matchingAlbumIDs: matchingIDs), 0)

        // p4 is unassigned
        XCTAssertEqual(index.countedAlbumCount(for: "p4", scope: .allUserAlbums, matchingAlbumIDs: matchingIDs), 0)

        // Mutations
        index = index.adding(assetIDs: ["p4"], toAlbum: "alb-match")
        XCTAssertEqual(index.countedAlbumCount(for: "p4", scope: .formatMatchingOnly, matchingAlbumIDs: matchingIDs), 1)

        index = index.removing(assetIDs: ["p2"], fromAlbum: "alb-match")
        XCTAssertEqual(index.countedAlbumCount(for: "p2", scope: .formatMatchingOnly, matchingAlbumIDs: matchingIDs), 0)
        XCTAssertEqual(index.countedAlbumCount(for: "p2", scope: .allUserAlbums, matchingAlbumIDs: matchingIDs), 1)

        index = index.deleting(albumID: "alb-user")
        XCTAssertEqual(index.countedAlbumCount(for: "p3", scope: .allUserAlbums, matchingAlbumIDs: matchingIDs), 0)
    }
}
