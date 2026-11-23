import XCTest
#if canImport(QuickAlbumCore)
@testable import QuickAlbumCore
#else
@testable import QuickAlbum
#endif

actor MockPhotoLibraryService: PhotoLibraryServing {
    private var status: PhotoAuthorizationStatus
    private var snapshot: PhotoLibrarySnapshot
    private var nextCreatedIndex = 1
    var shouldThrowCancelledOnDelete = false
    var createDelay: Duration = .zero
    private(set) var createdAlbumTitles: [String] = []
    private(set) var removedAssetsLog: [(albumID: String, assetIDs: [String])] = []

    init(
        status: PhotoAuthorizationStatus = .authorized,
        snapshot: PhotoLibrarySnapshot
    ) {
        self.status = status
        self.snapshot = snapshot
    }

    func setShouldThrowCancelledOnDelete(_ value: Bool) {
        shouldThrowCancelledOnDelete = value
    }

    func setCreateDelay(_ delay: Duration) {
        createDelay = delay
    }

    nonisolated func authorizationStatus() -> PhotoAuthorizationStatus {
        .authorized
    }

    func requestFullAuthorization() async -> PhotoAuthorizationStatus {
        status
    }

    func buildInitialIndex() async -> PhotoLibrarySnapshot {
        snapshot
    }

    nonisolated func libraryChanges() -> AsyncStream<PhotoLibrarySnapshot> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }

    func addAssets(_ assetIDs: [String], toAlbum albumID: String) async throws -> AddAssetsResult {
        guard let idx = snapshot.albums.firstIndex(where: { $0.id == albumID }) else {
            throw PhotoLibraryError.albumNotFound
        }
        let existing = Set(snapshot.albums[idx].assetIDs)
        let added = assetIDs.filter { !existing.contains($0) }
        let skipped = assetIDs.filter { existing.contains($0) }
        let updatedIDs = snapshot.albums[idx].assetIDs + added
        let updated = RawAlbumRecord(
            id: snapshot.albums[idx].id,
            title: snapshot.albums[idx].title,
            assetIDs: updatedIDs,
            coverAssetID: updatedIDs.last,
            latestAssetDate: snapshot.albums[idx].latestAssetDate
        )
        var albums = snapshot.albums
        albums[idx] = updated
        snapshot = PhotoLibrarySnapshot(photos: snapshot.photos, albums: albums)
        return AddAssetsResult(addedAssetIDs: added, skippedAssetIDs: skipped)
    }

    func createAlbum(title: String, addingAssetIDs: [String]) async throws -> RawAlbumRecord {
        if createDelay > .zero {
            try? await Task.sleep(for: createDelay)
        }
        createdAlbumTitles.append(title)
        let id = "created-\(nextCreatedIndex)"
        nextCreatedIndex += 1
        let record = RawAlbumRecord(
            id: id,
            title: title,
            assetIDs: addingAssetIDs,
            coverAssetID: addingAssetIDs.last,
            latestAssetDate: nil
        )
        snapshot = PhotoLibrarySnapshot(photos: snapshot.photos, albums: [record] + snapshot.albums)
        return record
    }

    func removeAssets(_ assetIDs: [String], fromAlbum albumID: String) async throws {
        removedAssetsLog.append((albumID, assetIDs))
        guard let idx = snapshot.albums.firstIndex(where: { $0.id == albumID }) else {
            throw PhotoLibraryError.albumNotFound
        }
        let removeSet = Set(assetIDs)
        let remaining = snapshot.albums[idx].assetIDs.filter { !removeSet.contains($0) }
        var albums = snapshot.albums
        albums[idx] = RawAlbumRecord(
            id: snapshot.albums[idx].id,
            title: snapshot.albums[idx].title,
            assetIDs: remaining,
            coverAssetID: remaining.last,
            latestAssetDate: snapshot.albums[idx].latestAssetDate
        )
        snapshot = PhotoLibrarySnapshot(photos: snapshot.photos, albums: albums)
    }

    func renameAlbum(_ albumID: String, to newTitle: String) async throws {
        guard let idx = snapshot.albums.firstIndex(where: { $0.id == albumID }) else {
            throw PhotoLibraryError.albumNotFound
        }
        var albums = snapshot.albums
        let old = albums[idx]
        albums[idx] = RawAlbumRecord(
            id: old.id,
            title: newTitle,
            assetIDs: old.assetIDs,
            coverAssetID: old.coverAssetID,
            latestAssetDate: old.latestAssetDate
        )
        snapshot = PhotoLibrarySnapshot(photos: snapshot.photos, albums: albums)
    }

    func deleteAlbum(_ albumID: String) async throws {
        if shouldThrowCancelledOnDelete {
            throw PhotoLibraryError.userCancelled
        }
        let remaining = snapshot.albums.filter { $0.id != albumID }
        snapshot = PhotoLibrarySnapshot(photos: snapshot.photos, albums: remaining)
    }
}

@MainActor
final class OrganizerViewModelTests: XCTestCase {
    private let utcCalendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        return cal
    }()

    private func makeDate(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
        DateComponents(calendar: utcCalendar, timeZone: utcCalendar.timeZone, year: year, month: month, day: day, hour: hour).date!
    }

    private func makeSampleSnapshot() -> PhotoLibrarySnapshot {
        let photos = [
            RawPhotoRecord(id: "p1", creationDate: makeDate(2026, 11, 18, 15), isScreenshot: false, pixelWidth: 4032, pixelHeight: 3024),
            RawPhotoRecord(id: "p2", creationDate: makeDate(2026, 11, 18, 10), isScreenshot: false, pixelWidth: 4032, pixelHeight: 3024),
            RawPhotoRecord(id: "p3", creationDate: makeDate(2026, 11, 19, 11), isScreenshot: true, pixelWidth: 1179, pixelHeight: 2556),
            RawPhotoRecord(id: "p4", creationDate: makeDate(2026, 11, 20, 9), isScreenshot: false, pixelWidth: 4032, pixelHeight: 3024)
        ]
        let albums = [
            RawAlbumRecord(id: "alb-user", title: "Screenshots Vault", assetIDs: ["p3"], coverAssetID: "p3", latestAssetDate: makeDate(2026, 11, 19, 11)),
            RawAlbumRecord(id: "alb-match", title: "26.11.20.01", assetIDs: ["p4"], coverAssetID: "p4", latestAssetDate: makeDate(2026, 11, 20, 9))
        ]
        return PhotoLibrarySnapshot(photos: photos, albums: albums)
    }

    func testFiltersMembershipScopesAndSelection() async {
        let service = MockPhotoLibraryService(snapshot: makeSampleSnapshot())
        let vm = OrganizerViewModel(
            service: service,
            counterStore: InMemoryCounterHistoryStore(),
            preferences: InMemoryPreferencesStore(),
            calendar: utcCalendar,
            nowProvider: { self.makeDate(2026, 11, 22) }
        )

        await vm.loadLibrary()

        // Default: allUserAlbums -> p1 & p2 unassigned
        XCTAssertEqual(vm.unassignedPhotoCount, 2)
        XCTAssertEqual(vm.flatVisiblePhotoIDs, ["p4", "p3", "p1", "p2"])

        // Filter to No Album
        vm.membershipFilter = .noAlbum
        XCTAssertEqual(vm.flatVisiblePhotoIDs, ["p1", "p2"])

        // Switch scope to formatMatchingOnly -> p3 (only in non-matching album) becomes unassigned
        vm.updateMembershipScope(.formatMatchingOnly)
        XCTAssertEqual(vm.unassignedPhotoCount, 3)
        XCTAssertEqual(vm.flatVisiblePhotoIDs, ["p3", "p1", "p2"])

        // Hide Screenshots
        vm.hideScreenshots = true
        XCTAssertEqual(vm.unassignedPhotoCount, 2)
        XCTAssertEqual(vm.flatVisiblePhotoIDs, ["p1", "p2"])

        // Sort oldest first
        vm.sortOrder = .oldestFirst
        XCTAssertEqual(vm.flatVisiblePhotoIDs, ["p2", "p1"])

        // Selection controls
        vm.selectAllVisible()
        XCTAssertEqual(vm.selectedAssetIDs, ["p1", "p2"])

        vm.toggleSelection("p1")
        XCTAssertEqual(vm.selectedAssetIDs, ["p2"])

        vm.setSelection("p1", selected: true)
        XCTAssertEqual(vm.selectedAssetIDs, ["p1", "p2"])

        vm.clearSelection()
        XCTAssertTrue(vm.selectedAssetIDs.isEmpty)
    }

    func testNoAlbumLiveRemovalAndUndoNewAlbumRollback() async {
        let service = MockPhotoLibraryService(snapshot: makeSampleSnapshot())
        let counterStore = InMemoryCounterHistoryStore()
        let vm = OrganizerViewModel(
            service: service,
            counterStore: counterStore,
            preferences: InMemoryPreferencesStore(),
            calendar: utcCalendar,
            nowProvider: { self.makeDate(2026, 11, 22) }
        )

        await vm.loadLibrary()
        vm.membershipFilter = .noAlbum
        XCTAssertEqual(vm.flatVisiblePhotoIDs, ["p1", "p2"])

        vm.toggleSelection("p1")
        vm.toggleSelection("p2")
        XCTAssertEqual(vm.nextPlaceholderTitle, "26.11.22.01")

        await vm.assignSelectedToNewPlaceholder()

        // Immediately animated out of No Album grid and selection cleared
        XCTAssertEqual(vm.flatVisiblePhotoIDs, [])
        XCTAssertEqual(vm.unassignedPhotoCount, 0)
        XCTAssertTrue(vm.selectedAssetIDs.isEmpty)
        XCTAssertEqual(vm.activeToast?.message, "Added 2 to 26.11.22.01")
        XCTAssertEqual(vm.activeToast?.canUndo, true)
        XCTAssertEqual(counterStore.highWaterMark(for: "YY.MM.DD.xx|26.11.22"), 1)

        // Undo deletes created album, restores photos, and rolls back counter
        await vm.performUndo()
        XCTAssertEqual(vm.flatVisiblePhotoIDs, ["p1", "p2"])
        XCTAssertEqual(vm.unassignedPhotoCount, 2)
        XCTAssertEqual(counterStore.highWaterMark(for: "YY.MM.DD.xx|26.11.22"), 0)
        XCTAssertEqual(vm.nextPlaceholderTitle, "26.11.22.01")
        vm.toggleSelection("p1")
        XCTAssertEqual(vm.nextPlaceholderTitle, "26.11.22.01")
    }

    func testUndoDeleteCancellationPreservesAlbumAndCounter() async {
        let service = MockPhotoLibraryService(snapshot: makeSampleSnapshot())
        let counterStore = InMemoryCounterHistoryStore()
        let vm = OrganizerViewModel(
            service: service,
            counterStore: counterStore,
            preferences: InMemoryPreferencesStore(),
            calendar: utcCalendar,
            nowProvider: { self.makeDate(2026, 11, 22) }
        )

        await vm.loadLibrary()
        vm.toggleSelection("p1")
        await vm.assignSelectedToNewPlaceholder()

        await service.setShouldThrowCancelledOnDelete(true)
        await vm.performUndo()

        // Album remains and counter high-water mark stays at 1
        XCTAssertEqual(counterStore.highWaterMark(for: "YY.MM.DD.xx|26.11.22"), 1)
        XCTAssertEqual(vm.activeToast?.message, "Album kept (deletion cancelled)")
        XCTAssertEqual(vm.activeToast?.canUndo, false)
        vm.toggleSelection("p1")
        XCTAssertEqual(vm.nextPlaceholderTitle, "26.11.22.02")
    }

    func testDuplicateDeduplicationAndUndoOnlyRemovesAddedAssets() async {
        let service = MockPhotoLibraryService(snapshot: makeSampleSnapshot())
        let vm = OrganizerViewModel(
            service: service,
            counterStore: InMemoryCounterHistoryStore(),
            preferences: InMemoryPreferencesStore(),
            calendar: utcCalendar,
            nowProvider: { self.makeDate(2026, 11, 22) }
        )

        await vm.loadLibrary()

        // p4 is already in alb-match; p1 is not
        await vm.assignAssets(["p4", "p1"], toExistingAlbum: "alb-match")
        XCTAssertEqual(vm.activeToast?.message, "Added 1 to 26.11.20.01 (1 already in album)")
        XCTAssertEqual(vm.activeToast?.addedAssetIDs, ["p1"])
        XCTAssertEqual(vm.albumSummary(for: "alb-match")?.assetCount, 2)

        await vm.performUndo()
        let removedLog = await service.removedAssetsLog
        XCTAssertEqual(removedLog.count, 1)
        XCTAssertEqual(removedLog[0].assetIDs, ["p1"])
        XCTAssertEqual(vm.albumSummary(for: "alb-match")?.assetCount, 1)

        // Dropping only already-present asset yields info-only toast
        await vm.assignAssets(["p4"], toExistingAlbum: "alb-match")
        XCTAssertEqual(vm.activeToast?.message, "All 1 photos already in 26.11.20.01")
        XCTAssertEqual(vm.activeToast?.canUndo, false)
    }

    func testConcurrentPlaceholderDropsAreSerializedWithoutDuplicateCounters() async {
        let service = MockPhotoLibraryService(snapshot: makeSampleSnapshot())
        await service.setCreateDelay(.milliseconds(40))
        let vm = OrganizerViewModel(
            service: service,
            counterStore: InMemoryCounterHistoryStore(),
            preferences: InMemoryPreferencesStore(),
            calendar: utcCalendar,
            nowProvider: { self.makeDate(2026, 11, 22) }
        )

        await vm.loadLibrary()

        async let firstDrop: Void = vm.assignAssets(["p1"], toNewPlaceholder: ())
        async let secondDrop: Void = vm.assignAssets(["p2"], toNewPlaceholder: ())
        _ = await (firstDrop, secondDrop)

        let titles = await service.createdAlbumTitles
        XCTAssertEqual(titles, ["26.11.22.01", "26.11.22.02"])
    }

    func testDragSessionFreezesTrayOrdering() async {
        let service = MockPhotoLibraryService(snapshot: PhotoLibrarySnapshot(
            photos: [
                RawPhotoRecord(id: "p1", creationDate: makeDate(2026, 11, 18), isScreenshot: false, pixelWidth: 100, pixelHeight: 100),
                RawPhotoRecord(id: "p2", creationDate: makeDate(2026, 11, 20), isScreenshot: false, pixelWidth: 100, pixelHeight: 100)
            ],
            albums: [
                RawAlbumRecord(id: "a20", title: "26.11.20.01", assetIDs: [], coverAssetID: nil, latestAssetDate: nil),
                RawAlbumRecord(id: "a18", title: "26.11.18.01", assetIDs: [], coverAssetID: nil, latestAssetDate: nil)
            ]
        ))

        let vm = OrganizerViewModel(
            service: service,
            counterStore: InMemoryCounterHistoryStore(),
            preferences: InMemoryPreferencesStore(),
            calendar: utcCalendar,
            nowProvider: { self.makeDate(2026, 11, 18) }
        )
        await vm.loadLibrary()

        // No selection -> newest first: a20, a18
        XCTAssertEqual(vm.trayAlbums.map(\.id), ["a20", "a18"])

        // Freeze while starting drag, then select p1 (today = 11.18, which would normally float a18 to front)
        vm.setDragSessionActive(true)
        vm.toggleSelection("p1")
        XCTAssertEqual(vm.trayAlbums.map(\.id), ["a20", "a18"])

        // End drag -> unfreezes and smart-orders a18 to front
        vm.setDragSessionActive(false)
        XCTAssertEqual(vm.trayAlbums.map(\.id), ["a18", "a20"])
    }
}
