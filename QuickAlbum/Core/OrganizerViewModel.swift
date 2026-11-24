import Foundation
import Observation
import os

@MainActor
@Observable
public final class OrganizerViewModel {
    private static let debugLog = Logger(subsystem: "com.quickalbum.app", category: "AlbumPerf")

    private static func formatMs(_ duration: Duration) -> String {
        let ms = Double(duration.components.seconds) * 1000.0 + Double(duration.components.attoseconds) / 1e15
        return String(format: "%.1fms", ms)
    }

    // MARK: - Dependencies

    private let service: PhotoLibraryServing
    private let counterStore: CounterHistoryStoring
    private var preferences: UserPreferencesStoring
    private let calendar: Calendar
    private let nowProvider: @MainActor () -> Date
    private let undoDuration: Duration

    // MARK: - Observable UI State

    public private(set) var authorizationStatus: PhotoAuthorizationStatus
    public private(set) var isLoading: Bool = false
    public var membershipFilter: MembershipFilter = .noAlbum {
        didSet {
            guard membershipFilter != oldValue else { return }
            rebuildVisibleGrid()
        }
    }
    public var sortOrder: SortOrder {
        didSet {
            guard sortOrder != oldValue else { return }
            preferences.sortOrder = sortOrder
            rebuildVisibleGrid()
        }
    }
    public var hideScreenshots: Bool {
        didSet {
            guard hideScreenshots != oldValue else { return }
            preferences.hideScreenshots = hideScreenshots
            rebuildVisibleGrid()
        }
    }
    public var columnCount: Int {
        didSet {
            let clamped = min(5, max(3, columnCount))
            if columnCount != clamped {
                columnCount = clamped
                return
            }
            guard columnCount != oldValue else { return }
            preferences.columnCount = columnCount
        }
    }
    public private(set) var pattern: AlbumPattern
    public private(set) var membershipScope: MembershipScope

    public private(set) var selectedAssetIDs: Set<String> = []
    public private(set) var activeToast: UndoAction?
    public var errorMessage: String?

    public private(set) var isDragSessionActive: Bool = false
    /// Asset IDs carried by the in-app drag currently in flight (empty when no drag is active).
    public private(set) var activeDragAssetIDs: [String] = []
    private var frozenTrayAlbumIDs: [String]?

    // MARK: - Cached Derived Collections

    private var snapshot: PhotoLibrarySnapshot = .empty
    private var rawPhotosByID: [String: RawPhotoRecord] = [:]
    private var rawAlbumsByID: [String: RawAlbumRecord] = [:]
    private var albumIndex = PhotoAlbumIndex(albums: [])
    private var matchingAlbumIDs: Set<String> = []
    public private(set) var allAlbumSummaries: [AlbumSummary] = []
    private var albumSummariesByID: [String: AlbumSummary] = [:]

    public private(set) var unassignedPhotoCount: Int = 0
    public private(set) var visiblePhotoItemsByID: [String: PhotoItem] = [:]
    public private(set) var flatVisiblePhotoIDs: [String] = []
    public private(set) var dataVersion: Int = 0

    // MARK: - Internal Tasks

    private var changesTask: Task<Void, Never>?
    private var pendingMutationTask: Task<Void, Never>?
    private var toastDismissTask: Task<Void, Never>?

    // MARK: - Initialization

    public init(
        service: PhotoLibraryServing,
        counterStore: CounterHistoryStoring = UserDefaultsCounterHistoryStore(),
        preferences: UserPreferencesStoring = UserDefaultsPreferencesStore(),
        calendar: Calendar = .current,
        nowProvider: @escaping @MainActor () -> Date = { Date() },
        undoDuration: Duration = .seconds(5)
    ) {
        self.service = service
        self.counterStore = counterStore
        self.preferences = preferences
        self.calendar = calendar
        self.nowProvider = nowProvider
        self.undoDuration = undoDuration

        self.authorizationStatus = service.authorizationStatus()
        self.pattern = preferences.pattern
        self.membershipScope = preferences.membershipScope
        self.sortOrder = preferences.sortOrder
        self.hideScreenshots = preferences.hideScreenshots
        self.columnCount = preferences.columnCount
    }

    // MARK: - Computed Properties

    /// New albums are named after the date they are created (today), not the photos' capture dates.
    public var targetDate: Date {
        nowProvider()
    }

    public var targetDatePrefix: String {
        AlbumPatternEngine.renderDatePrefix(for: targetDate, pattern: pattern, calendar: calendar)
    }

    public var nextPlaceholderCandidate: NextAlbumCandidate {
        AlbumPatternEngine.computeNextAlbum(
            for: targetDate,
            existingAlbums: allAlbumSummaries,
            pattern: pattern,
            counterStore: counterStore,
            calendar: calendar
        )
    }

    public var nextPlaceholderTitle: String {
        nextPlaceholderCandidate.title
    }

    public var trayAlbums: [AlbumSummary] {
        let sorted = AlbumTraySorter.sortForTray(
            albums: allAlbumSummaries,
            targetDatePrefix: selectedAssetIDs.isEmpty ? nil : targetDatePrefix,
            includeNonMatching: false,
            searchQuery: ""
        )
        guard let frozenIDs = frozenTrayAlbumIDs else {
            return sorted
        }
        let byID = Dictionary(uniqueKeysWithValues: sorted.map { ($0.id, $0) })
        let frozenSet = Set(frozenIDs)
        let newlyCreated = sorted.filter { !frozenSet.contains($0.id) }
        let retained = frozenIDs.compactMap { byID[$0] }
        return newlyCreated + retained
    }

    public func expandedAlbums(searchQuery: String, showAllAlbums: Bool) -> [AlbumSummary] {
        AlbumTraySorter.sortForTray(
            albums: allAlbumSummaries,
            targetDatePrefix: selectedAssetIDs.isEmpty ? nil : targetDatePrefix,
            includeNonMatching: showAllAlbums,
            searchQuery: searchQuery
        )
    }

    public func albumSummary(for albumID: String) -> AlbumSummary? {
        albumSummariesByID[albumID]
    }

    public func photoItem(for assetID: String) -> PhotoItem? {
        if let cached = visiblePhotoItemsByID[assetID] {
            return cached
        }
        guard let raw = rawPhotosByID[assetID] else { return nil }
        return makePhotoItem(from: raw)
    }

    public func albumsContaining(assetID: String) -> [AlbumSummary] {
        let albumIDs = albumIndex.countedAlbumIDs(
            for: assetID,
            scope: membershipScope,
            matchingAlbumIDs: matchingAlbumIDs
        )
        let matchingAlbums = albumIDs.compactMap { albumSummariesByID[$0] }
        return AlbumTraySorter.sortForTray(
            albums: matchingAlbums,
            targetDatePrefix: nil,
            includeNonMatching: true,
            searchQuery: ""
        )
    }

    public func photos(inAlbum albumID: String) -> [PhotoItem] {
        let ids = albumIndex.assetIDs(inAlbum: albumID)
        return ids.compactMap { photoItem(for: $0) }
    }

    // MARK: - Lifecycle & Permissions

    public func start() async {
        authorizationStatus = service.authorizationStatus()
        startObservingLibraryChanges()
        if authorizationStatus == .authorized {
            await loadLibrary()
        }
    }

    public func stopObserving() {
        changesTask?.cancel()
        changesTask = nil
    }

    public func requestFullAccess() async {
        let status = await service.requestFullAuthorization()
        authorizationStatus = status
        if status == .authorized {
            startObservingLibraryChanges()
            await loadLibrary()
        }
    }

    public func handleScenePhaseActive() async {
        let current = service.authorizationStatus()
        let previous = authorizationStatus
        authorizationStatus = current
        if current == .authorized && previous != .authorized {
            startObservingLibraryChanges()
            await loadLibrary()
        } else if current != .authorized && previous == .authorized {
            snapshot = .empty
            selectedAssetIDs.removeAll()
            recomputeAll()
        }
    }

    public func loadLibrary() async {
        isLoading = true
        let fetched = await service.buildInitialIndex()
        applySnapshot(fetched)
        isLoading = false
    }

    private func startObservingLibraryChanges() {
        guard changesTask == nil else { return }
        let stream = service.libraryChanges()
        changesTask = Task { @MainActor [weak self] in
            for await updatedSnapshot in stream {
                guard let self, !Task.isCancelled else { break }
                if self.authorizationStatus == .authorized {
                    if self.isSnapshotEquivalentToCurrent(updatedSnapshot) {
                        continue
                    }
                    self.applySnapshot(updatedSnapshot)
                }
            }
        }
    }

    private func isSnapshotEquivalentToCurrent(_ incoming: PhotoLibrarySnapshot) -> Bool {
        guard incoming.photos.count == snapshot.photos.count,
              incoming.albums.count == rawAlbumsByID.count else {
            return false
        }
        for album in incoming.albums {
            if rawAlbumsByID[album.id] != album {
                return false
            }
        }
        if incoming.photos == snapshot.photos {
            return true
        }
        for photo in incoming.photos {
            if rawPhotosByID[photo.id] != photo {
                return false
            }
        }
        return true
    }

    // MARK: - Selection Controls

    public func toggleSelection(_ assetID: String) {
        if selectedAssetIDs.contains(assetID) {
            selectedAssetIDs.remove(assetID)
        } else {
            selectedAssetIDs.insert(assetID)
        }
    }

    public func setSelection(_ assetID: String, selected: Bool) {
        if selected {
            selectedAssetIDs.insert(assetID)
        } else {
            selectedAssetIDs.remove(assetID)
        }
    }

    public func selectAllVisible() {
        selectedAssetIDs.formUnion(flatVisiblePhotoIDs)
    }

    public func clearSelection() {
        selectedAssetIDs.removeAll()
    }

    // MARK: - Drag Session Freezing

    public func setDragSessionActive(_ active: Bool, assetIDs: [String] = []) {
        if active {
            if frozenTrayAlbumIDs == nil {
                frozenTrayAlbumIDs = trayAlbums.map(\.id)
            }
            activeDragAssetIDs = assetIDs
            isDragSessionActive = true
        } else {
            isDragSessionActive = false
            activeDragAssetIDs = []
            frozenTrayAlbumIDs = nil
        }
    }

    public func resolvedDragAssetIDs(startingFrom pressedAssetID: String) -> [String] {
        if selectedAssetIDs.contains(pressedAssetID) {
            let ordered = flatVisiblePhotoIDs.filter { selectedAssetIDs.contains($0) }
            return ordered.isEmpty ? Array(selectedAssetIDs) : ordered
        }
        return [pressedAssetID]
    }

    // MARK: - Album Assignment & Creation (Serialized)

    public func assignSelectedToNewPlaceholder() async {
        let ids = orderedSelectedAssetIDs()
        guard !ids.isEmpty else { return }
        await assignAssets(ids, toNewPlaceholder: ())
    }

    public func assignSelected(toExistingAlbum albumID: String) async {
        let ids = orderedSelectedAssetIDs()
        guard !ids.isEmpty else { return }
        await assignAssets(ids, toExistingAlbum: albumID)
    }

    public func assignAssets(_ assetIDs: [String], toNewPlaceholder: Void) async {
        let uniqueIDs = orderedUniqueIDs(assetIDs)
        guard !uniqueIDs.isEmpty else { return }

        await enqueueMutation {
            let candidate = AlbumPatternEngine.computeNextAlbum(
                for: self.nowProvider(),
                existingAlbums: self.allAlbumSummaries,
                pattern: self.pattern,
                counterStore: self.counterStore,
                calendar: self.calendar
            )

            do {
                let opStart = ContinuousClock.now
                let createdRecord = try await self.service.createAlbum(
                    title: candidate.title,
                    addingAssetIDs: uniqueIDs
                )

                AlbumPatternEngine.commitCounter(
                    key: candidate.highWaterKey,
                    counter: candidate.counter,
                    store: self.counterStore
                )

                var updatedAlbums = self.snapshot.albums
                updatedAlbums.insert(createdRecord, at: 0)
                self.applySnapshot(PhotoLibrarySnapshot(photos: self.snapshot.photos, albums: updatedAlbums))

                self.selectedAssetIDs.subtract(uniqueIDs)

                let count = uniqueIDs.count
                let toast = UndoAction(
                    albumID: createdRecord.id,
                    albumTitle: createdRecord.title,
                    addedAssetIDs: uniqueIDs,
                    skippedCount: 0,
                    createdNewAlbum: true,
                    patternKey: candidate.highWaterKey,
                    previousHighWaterMark: candidate.priorHighWaterMark,
                    message: "Added \(count) to \(createdRecord.title)"
                )
                self.showToast(toast)
                Self.debugLog.debug(
                    "[VM createAlbum] title=\(createdRecord.title, privacy: .public) count=\(count, privacy: .public) in \(Self.formatMs(ContinuousClock.now - opStart), privacy: .public)"
                )
            } catch {
                Self.debugLog.error(
                    "[VM createAlbum] failed: \(error.localizedDescription, privacy: .public)"
                )
                self.errorMessage = error.localizedDescription
            }
        }
    }

    public func assignAssets(_ assetIDs: [String], toExistingAlbum albumID: String) async {
        let uniqueIDs = orderedUniqueIDs(assetIDs)
        guard !uniqueIDs.isEmpty else { return }

        await enqueueMutation {
            guard let targetAlbum = self.rawAlbumsByID[albumID] else {
                self.errorMessage = PhotoLibraryError.albumNotFound.localizedDescription
                return
            }

            let existingInAlbum = self.albumIndex.assetsAlreadyInAlbum(albumID: albumID)
            let newIDs = uniqueIDs.filter { !existingInAlbum.contains($0) }
            let skippedCount = uniqueIDs.count - newIDs.count

            if newIDs.isEmpty {
                self.selectedAssetIDs.subtract(uniqueIDs)
                let infoToast = UndoAction(
                    albumID: albumID,
                    albumTitle: targetAlbum.title,
                    addedAssetIDs: [],
                    skippedCount: skippedCount,
                    createdNewAlbum: false,
                    patternKey: nil,
                    previousHighWaterMark: nil,
                    message: "All \(uniqueIDs.count) photos already in \(targetAlbum.title)"
                )
                self.showToast(infoToast)
                return
            }

            do {
                let opStart = ContinuousClock.now
                let result = try await self.service.addAssets(newIDs, toAlbum: albumID)
                let actuallyAdded = result.addedAssetIDs
                let totalSkipped = skippedCount + result.skippedAssetIDs.count

                let updatedAlbums = self.snapshot.albums.map { record -> RawAlbumRecord in
                    guard record.id == albumID else { return record }
                    let combined = record.assetIDs + actuallyAdded.filter { !existingInAlbum.contains($0) }
                    let latestDate = combined
                        .compactMap { self.rawPhotosByID[$0]?.creationDate }
                        .max() ?? record.latestAssetDate
                    return RawAlbumRecord(
                        id: record.id,
                        title: record.title,
                        assetIDs: combined,
                        coverAssetID: record.coverAssetID ?? actuallyAdded.first,
                        latestAssetDate: latestDate
                    )
                }
                self.applySnapshot(PhotoLibrarySnapshot(photos: self.snapshot.photos, albums: updatedAlbums))
                self.selectedAssetIDs.subtract(uniqueIDs)

                let message: String
                if totalSkipped > 0 {
                    message = "Added \(actuallyAdded.count) to \(targetAlbum.title) (\(totalSkipped) already in album)"
                } else {
                    message = "Added \(actuallyAdded.count) to \(targetAlbum.title)"
                }

                let toast = UndoAction(
                    albumID: albumID,
                    albumTitle: targetAlbum.title,
                    addedAssetIDs: actuallyAdded,
                    skippedCount: totalSkipped,
                    createdNewAlbum: false,
                    patternKey: nil,
                    previousHighWaterMark: nil,
                    message: message
                )
                self.showToast(toast)
                Self.debugLog.debug(
                    "[VM addAssets] album=\(targetAlbum.title, privacy: .public) added=\(actuallyAdded.count, privacy: .public) skipped=\(totalSkipped, privacy: .public) in \(Self.formatMs(ContinuousClock.now - opStart), privacy: .public)"
                )
            } catch {
                Self.debugLog.error(
                    "[VM addAssets] failed: \(error.localizedDescription, privacy: .public)"
                )
                self.errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Undo & Album Management

    public func performUndo() async {
        guard let toast = activeToast, toast.canUndo else { return }
        dismissToast()

        await enqueueMutation {
            if toast.createdNewAlbum {
                do {
                    try await self.service.deleteAlbum(toast.albumID)
                    if let key = toast.patternKey, let prev = toast.previousHighWaterMark {
                        AlbumPatternEngine.rollbackCounter(
                            key: key,
                            previousHighWaterMark: prev,
                            store: self.counterStore
                        )
                    }
                    let remainingAlbums = self.snapshot.albums.filter { $0.id != toast.albumID }
                    self.applySnapshot(PhotoLibrarySnapshot(photos: self.snapshot.photos, albums: remainingAlbums))
                } catch PhotoLibraryError.userCancelled {
                    let keptToast = UndoAction(
                        albumID: toast.albumID,
                        albumTitle: toast.albumTitle,
                        addedAssetIDs: [],
                        skippedCount: 0,
                        createdNewAlbum: false,
                        patternKey: nil,
                        previousHighWaterMark: nil,
                        message: "Album kept (deletion cancelled)"
                    )
                    self.showToast(keptToast)
                } catch {
                    Self.debugLog.error(
                        "[VM undoDeleteAlbum] failed: \(error.localizedDescription, privacy: .public)"
                    )
                    self.errorMessage = error.localizedDescription
                }
            } else {
                do {
                    try await self.service.removeAssets(toast.addedAssetIDs, fromAlbum: toast.albumID)
                    let removeSet = Set(toast.addedAssetIDs)
                    let updatedAlbums = self.snapshot.albums.map { record -> RawAlbumRecord in
                        guard record.id == toast.albumID else { return record }
                        let remainingIDs = record.assetIDs.filter { !removeSet.contains($0) }
                        return RawAlbumRecord(
                            id: record.id,
                            title: record.title,
                            assetIDs: remainingIDs,
                            coverAssetID: remainingIDs.first,
                            latestAssetDate: remainingIDs.compactMap { self.rawPhotosByID[$0]?.creationDate }.max()
                        )
                    }
                    self.applySnapshot(PhotoLibrarySnapshot(photos: self.snapshot.photos, albums: updatedAlbums))
                } catch {
                    Self.debugLog.error(
                        "[VM undoRemoveAssets] failed: \(error.localizedDescription, privacy: .public)"
                    )
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    public func dismissToast() {
        toastDismissTask?.cancel()
        toastDismissTask = nil
        activeToast = nil
    }

    public func removeAssets(_ assetIDs: [String], fromAlbum albumID: String) async {
        let uniqueIDs = orderedUniqueIDs(assetIDs)
        guard !uniqueIDs.isEmpty else { return }

        await enqueueMutation {
            do {
                let opStart = ContinuousClock.now
                try await self.service.removeAssets(uniqueIDs, fromAlbum: albumID)
                let removeSet = Set(uniqueIDs)
                let updatedAlbums = self.snapshot.albums.map { record -> RawAlbumRecord in
                    guard record.id == albumID else { return record }
                    let remainingIDs = record.assetIDs.filter { !removeSet.contains($0) }
                    return RawAlbumRecord(
                        id: record.id,
                        title: record.title,
                        assetIDs: remainingIDs,
                        coverAssetID: remainingIDs.first,
                        latestAssetDate: remainingIDs.compactMap { self.rawPhotosByID[$0]?.creationDate }.max()
                    )
                }
                self.applySnapshot(PhotoLibrarySnapshot(photos: self.snapshot.photos, albums: updatedAlbums))
                Self.debugLog.debug(
                    "[VM removeAssets] count=\(uniqueIDs.count, privacy: .public) in \(Self.formatMs(ContinuousClock.now - opStart), privacy: .public)"
                )
            } catch {
                Self.debugLog.error(
                    "[VM removeAssets] failed: \(error.localizedDescription, privacy: .public)"
                )
                self.errorMessage = error.localizedDescription
            }
        }
    }

    public func renameAlbum(_ albumID: String, to newTitle: String) async {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        await enqueueMutation {
            do {
                try await self.service.renameAlbum(albumID, to: trimmed)
                let updatedAlbums = self.snapshot.albums.map { record -> RawAlbumRecord in
                    guard record.id == albumID else { return record }
                    return RawAlbumRecord(
                        id: record.id,
                        title: trimmed,
                        assetIDs: record.assetIDs,
                        coverAssetID: record.coverAssetID,
                        latestAssetDate: record.latestAssetDate
                    )
                }
                self.applySnapshot(PhotoLibrarySnapshot(photos: self.snapshot.photos, albums: updatedAlbums))
            } catch {
                self.errorMessage = error.localizedDescription
            }
        }
    }

    public func editAlbumLabel(_ albumID: String, label: String) async {
        guard let summary = albumSummariesByID[albumID],
              let parsed = summary.parsed else {
            await renameAlbum(albumID, to: label)
            return
        }
        let updatedTitle = AlbumPatternEngine.replacingLabel(in: parsed, with: label, pattern: pattern)
        await renameAlbum(albumID, to: updatedTitle)
    }

    public func deleteAlbum(_ albumID: String) async {
        await enqueueMutation {
            do {
                try await self.service.deleteAlbum(albumID)
                let remaining = self.snapshot.albums.filter { $0.id != albumID }
                self.applySnapshot(PhotoLibrarySnapshot(photos: self.snapshot.photos, albums: remaining))
            } catch PhotoLibraryError.userCancelled {
                // User declined system delete confirmation; keep album intact.
            } catch {
                self.errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Settings Actions

    @discardableResult
    public func updatePattern(_ newPattern: AlbumPattern) -> PatternValidationResult {
        let validation = AlbumPatternEngine.validate(template: newPattern.template)
        guard validation.isValid else {
            return validation
        }
        pattern = newPattern
        preferences.pattern = newPattern
        recomputeAll()
        return validation
    }

    public func updateMembershipScope(_ newScope: MembershipScope) {
        guard membershipScope != newScope else { return }
        membershipScope = newScope
        preferences.membershipScope = newScope
        rebuildMembershipCountsAndGrid()
    }

    public func resetCounterHistory() {
        counterStore.resetAll()
        dataVersion += 1
    }

    // MARK: - Private Index & Grid Rebuilders

    private func enqueueMutation(_ work: @escaping @MainActor () async -> Void) async {
        let previous = pendingMutationTask
        let task = Task { @MainActor in
            await previous?.value
            await work()
        }
        pendingMutationTask = task
        await task.value
    }

    private func showToast(_ toast: UndoAction) {
        toastDismissTask?.cancel()
        activeToast = toast
        let toastID = toast.id
        toastDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: self?.undoDuration ?? .seconds(5))
            guard let self, !Task.isCancelled else { return }
            if self.activeToast?.id == toastID {
                self.activeToast = nil
            }
        }
    }

    private func applySnapshot(_ newSnapshot: PhotoLibrarySnapshot) {
        self.snapshot = newSnapshot
        self.rawPhotosByID = Dictionary(uniqueKeysWithValues: newSnapshot.photos.map { ($0.id, $0) })
        self.rawAlbumsByID = Dictionary(uniqueKeysWithValues: newSnapshot.albums.map { ($0.id, $0) })
        self.albumIndex = PhotoAlbumIndex(albums: newSnapshot.albums)
        self.selectedAssetIDs = self.selectedAssetIDs.filter { self.rawPhotosByID[$0] != nil }
        recomputeAll()
    }

    private func recomputeAll() {
        var summaries: [AlbumSummary] = []
        var matchingIDs: Set<String> = []
        summaries.reserveCapacity(snapshot.albums.count)

        for album in snapshot.albums {
            let parsed = AlbumPatternEngine.parse(title: album.title, pattern: pattern)
            if parsed != nil {
                matchingIDs.insert(album.id)
            }
            summaries.append(
                AlbumSummary(
                    id: album.id,
                    title: album.title,
                    parsed: parsed,
                    assetCount: album.assetIDs.count,
                    coverAssetID: album.coverAssetID,
                    latestAssetDate: album.latestAssetDate
                )
            )
        }

        self.allAlbumSummaries = summaries
        self.albumSummariesByID = Dictionary(uniqueKeysWithValues: summaries.map { ($0.id, $0) })
        self.matchingAlbumIDs = matchingIDs
        rebuildMembershipCountsAndGrid()
    }

    private func rebuildMembershipCountsAndGrid() {
        rebuildVisibleGrid()
    }

    private func rebuildVisibleGrid() {
        var unassigned = 0
        var filtered: [PhotoItem] = []
        filtered.reserveCapacity(snapshot.photos.count)

        for raw in snapshot.photos {
            if hideScreenshots && raw.isScreenshot {
                continue
            }
            let count = albumIndex.countedAlbumCount(
                for: raw.id,
                scope: membershipScope,
                matchingAlbumIDs: matchingAlbumIDs
            )
            if count == 0 {
                unassigned += 1
            }
            if membershipFilter == .noAlbum && count > 0 {
                continue
            }
            filtered.append(
                PhotoItem(
                    id: raw.id,
                    creationDate: raw.creationDate,
                    isScreenshot: raw.isScreenshot,
                    countedAlbumCount: count,
                    pixelWidth: raw.pixelWidth,
                    pixelHeight: raw.pixelHeight
                )
            )
        }

        self.unassignedPhotoCount = unassigned

        filtered.sort { lhs, rhs in
            switch (lhs.creationDate, rhs.creationDate) {
            case let (lDate?, rDate?):
                if lDate != rDate {
                    return sortOrder == .newestFirst ? lDate > rDate : lDate < rDate
                }
                return lhs.id < rhs.id
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            case (.none, .none):
                return lhs.id < rhs.id
            }
        }

        var itemsByID: [String: PhotoItem] = [:]
        itemsByID.reserveCapacity(filtered.count)
        for item in filtered {
            itemsByID[item.id] = item
        }

        self.visiblePhotoItemsByID = itemsByID
        self.flatVisiblePhotoIDs = filtered.map(\.id)
        self.dataVersion += 1
    }

    private func makePhotoItem(from raw: RawPhotoRecord) -> PhotoItem {
        let count = albumIndex.countedAlbumCount(
            for: raw.id,
            scope: membershipScope,
            matchingAlbumIDs: matchingAlbumIDs
        )
        return PhotoItem(
            id: raw.id,
            creationDate: raw.creationDate,
            isScreenshot: raw.isScreenshot,
            countedAlbumCount: count,
            pixelWidth: raw.pixelWidth,
            pixelHeight: raw.pixelHeight
        )
    }

    private func orderedSelectedAssetIDs() -> [String] {
        orderedUniqueIDs(Array(selectedAssetIDs))
    }

    private func orderedUniqueIDs(_ ids: [String]) -> [String] {
        var seen: Set<String> = []
        var unique: [String] = []
        for id in ids where !seen.contains(id) {
            seen.insert(id)
            unique.append(id)
        }
        let visibleRank = Dictionary(uniqueKeysWithValues: flatVisiblePhotoIDs.enumerated().map { ($1, $0) })
        return unique.sorted { lhs, rhs in
            switch (visibleRank[lhs], visibleRank[rhs]) {
            case let (l?, r?): return l < r
            case (.some, .none): return true
            case (.none, .some): return false
            case (.none, .none): return lhs < rhs
            }
        }
    }
}
