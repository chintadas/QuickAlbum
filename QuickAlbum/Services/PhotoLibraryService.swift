import Foundation
import os
@preconcurrency import Photos

private final class PhotoLibraryObserverProxy: NSObject, PHPhotoLibraryChangeObserver, @unchecked Sendable {
    var onChange: (@Sendable (PHChange) -> Void)?

    func photoLibraryDidChange(_ changeInstance: PHChange) {
        onChange?(changeInstance)
    }
}

private struct LoadedPhotosState: @unchecked Sendable {
    let assetsFetch: PHFetchResult<PHAsset>
    let photosByID: [String: RawPhotoRecord]
    let photoOrder: [String]
}

private struct LoadedLibraryState: @unchecked Sendable {
    let assetsFetch: PHFetchResult<PHAsset>
    let albumsFetch: PHFetchResult<PHAssetCollection>
    let albumAssetResults: [String: PHFetchResult<PHAsset>]
    let photosByID: [String: RawPhotoRecord]
    let photoOrder: [String]
    let albumsByID: [String: RawAlbumRecord]
    let albumOrder: [String]
    let snapshot: PhotoLibrarySnapshot
}

actor PhotoLibraryService: PhotoLibraryServing {
    private static let debugLog = Logger(subsystem: "com.quickalbum.app", category: "AlbumPerf")

    private static func formatMs(_ duration: Duration) -> String {
        let ms = Double(duration.components.seconds) * 1000.0 + Double(duration.components.attoseconds) / 1e15
        return String(format: "%.1fms", ms)
    }

    private var continuations: [UUID: AsyncStream<PhotoLibrarySnapshot>.Continuation] = [:]
    private var observerProxy: PhotoLibraryObserverProxy?

    private var lastAssetsFetchResult: PHFetchResult<PHAsset>?
    private var lastAlbumsFetchResult: PHFetchResult<PHAssetCollection>?
    private var lastAlbumAssetResults: [String: PHFetchResult<PHAsset>] = [:]
    private var cachedPhotosByID: [String: RawPhotoRecord] = [:]
    private var cachedPhotoOrder: [String] = []
    private var cachedAlbumsByID: [String: RawAlbumRecord] = [:]
    private var cachedAlbumOrder: [String] = []
    private var assetReloadGeneration: Int = 0

    deinit {
        if let proxy = observerProxy {
            PHPhotoLibrary.shared().unregisterChangeObserver(proxy)
        }
    }

    // MARK: - Authorization

    nonisolated func authorizationStatus() -> PhotoAuthorizationStatus {
        Self.mapStatus(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    func requestFullAuthorization() async -> PhotoAuthorizationStatus {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        let mapped = Self.mapStatus(status)
        if mapped == .authorized {
            registerObserverIfNeeded()
        }
        return mapped
    }

    private static func mapStatus(_ status: PHAuthorizationStatus) -> PhotoAuthorizationStatus {
        switch status {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .authorized: return .authorized
        case .limited: return .limited
        @unknown default: return .denied
        }
    }

    // MARK: - Indexing & Change Observation

    func buildInitialIndex(createdAfter cutoffDate: Date?) async -> PhotoLibrarySnapshot {
        registerObserverIfNeeded()
        assetReloadGeneration += 1
        let generation = assetReloadGeneration
        let loaded = await loadFullSnapshotOffActor(reason: "initialIndex", createdAfter: cutoffDate)
        guard generation == assetReloadGeneration else {
            return makeCurrentSnapshot()
        }
        lastAssetsFetchResult = loaded.assetsFetch
        lastAlbumsFetchResult = loaded.albumsFetch
        lastAlbumAssetResults = loaded.albumAssetResults
        cachedPhotosByID = loaded.photosByID
        cachedPhotoOrder = loaded.photoOrder
        cachedAlbumsByID = loaded.albumsByID
        cachedAlbumOrder = loaded.albumOrder
        return loaded.snapshot
    }

    func reloadPhotos(createdAfter cutoffDate: Date?) async -> PhotoLibrarySnapshot {
        guard lastAlbumsFetchResult != nil else {
            return await buildInitialIndex(createdAfter: cutoffDate)
        }
        registerObserverIfNeeded()
        assetReloadGeneration += 1
        let generation = assetReloadGeneration
        let loadedPhotos = await loadPhotosOffActor(reason: "reloadPhotos", createdAfter: cutoffDate)
        guard generation == assetReloadGeneration else {
            return makeCurrentSnapshot()
        }
        lastAssetsFetchResult = loadedPhotos.assetsFetch
        cachedPhotosByID = loadedPhotos.photosByID
        cachedPhotoOrder = loadedPhotos.photoOrder
        return makeCurrentSnapshot()
    }

    nonisolated func libraryChanges() -> AsyncStream<PhotoLibrarySnapshot> {
        AsyncStream { continuation in
            let id = UUID()
            Task {
                await self.registerContinuation(id: id, continuation: continuation)
            }
            continuation.onTermination = { _ in
                Task {
                    await self.removeContinuation(id: id)
                }
            }
        }
    }

    private func registerContinuation(id: UUID, continuation: AsyncStream<PhotoLibrarySnapshot>.Continuation) {
        registerObserverIfNeeded()
        continuations[id] = continuation
    }

    private func removeContinuation(id: UUID) {
        continuations.removeValue(forKey: id)
    }

    private func registerObserverIfNeeded() {
        guard observerProxy == nil else { return }
        let proxy = PhotoLibraryObserverProxy()
        proxy.onChange = { [weak self] change in
            Task {
                await self?.handleLibraryChange(change)
            }
        }
        observerProxy = proxy
        PHPhotoLibrary.shared().register(proxy)
    }

    private func handleLibraryChange(_ change: PHChange) {
        guard lastAssetsFetchResult != nil || lastAlbumsFetchResult != nil else {
            return
        }

        let opStart = ContinuousClock.now
        var photosMutated = false
        var albumsMutated = false
        var dateChangedAssetIDs: Set<String> = []
        var alreadyUpdatedAlbumIDs: Set<String> = []

        var assetsInserted = 0
        var assetsRemoved = 0
        var assetsMetadataChanged = 0
        var albumsInserted = 0
        var albumsRemoved = 0
        var albumsRenamed = 0
        var albumMembershipsChanged = 0
        var checkedAlbums = 0

        // Step A: Incremental photo asset changes
        if let assetsResult = lastAssetsFetchResult,
           let details = change.changeDetails(for: assetsResult) {
            lastAssetsFetchResult = details.fetchResultAfterChanges

            if details.hasIncrementalChanges {
                var removedIDs: Set<String> = []
                for asset in details.removedObjects {
                    let id = asset.localIdentifier
                    if cachedPhotosByID.removeValue(forKey: id) != nil {
                        removedIDs.insert(id)
                        assetsRemoved += 1
                        photosMutated = true
                    }
                }

                var insertedIDs: [String] = []
                for asset in details.insertedObjects {
                    let record = Self.makeRawPhotoRecord(from: asset)
                    if cachedPhotosByID[record.id] == nil {
                        insertedIDs.append(record.id)
                    }
                    if cachedPhotosByID[record.id] != record {
                        cachedPhotosByID[record.id] = record
                        assetsInserted += 1
                        photosMutated = true
                    }
                }

                for asset in details.changedObjects {
                    let updated = Self.makeRawPhotoRecord(from: asset)
                    let previous = cachedPhotosByID[updated.id]
                    if previous != updated {
                        if previous?.creationDate != updated.creationDate {
                            dateChangedAssetIDs.insert(updated.id)
                        }
                        cachedPhotosByID[updated.id] = updated
                        assetsMetadataChanged += 1
                        photosMutated = true
                    }
                }

                if !removedIDs.isEmpty {
                    cachedPhotoOrder.removeAll { removedIDs.contains($0) }
                }
                if !insertedIDs.isEmpty {
                    let existingOrderSet = Set(cachedPhotoOrder)
                    for id in insertedIDs where !existingOrderSet.contains(id) {
                        cachedPhotoOrder.append(id)
                    }
                }
            } else {
                let afterFetch = details.fetchResultAfterChanges
                var rebuiltByID: [String: RawPhotoRecord] = [:]
                var rebuiltOrder: [String] = []
                rebuiltByID.reserveCapacity(afterFetch.count)
                rebuiltOrder.reserveCapacity(afterFetch.count)
                afterFetch.enumerateObjects { asset, _, _ in
                    let record = Self.makeRawPhotoRecord(from: asset)
                    if self.cachedPhotosByID[record.id]?.creationDate != record.creationDate {
                        dateChangedAssetIDs.insert(record.id)
                    }
                    rebuiltByID[record.id] = record
                    rebuiltOrder.append(record.id)
                }
                if rebuiltByID != cachedPhotosByID {
                    photosMutated = true
                }
                cachedPhotosByID = rebuiltByID
                cachedPhotoOrder = rebuiltOrder
            }
        }

        // Step B: Incremental album collection list changes (create / delete / rename)
        if let albumsResult = lastAlbumsFetchResult,
           let details = change.changeDetails(for: albumsResult) {
            lastAlbumsFetchResult = details.fetchResultAfterChanges

            if details.hasIncrementalChanges {
                for collection in details.removedObjects {
                    let id = collection.localIdentifier
                    if cachedAlbumsByID.removeValue(forKey: id) != nil {
                        albumsRemoved += 1
                        albumsMutated = true
                    }
                    lastAlbumAssetResults.removeValue(forKey: id)
                }

                for collection in details.insertedObjects {
                    let id = collection.localIdentifier
                    let title = collection.localizedTitle ?? "Untitled"
                    let assetsResult = PHAsset.fetchAssets(in: collection, options: nil)
                    lastAlbumAssetResults[id] = assetsResult
                    cachedAlbumsByID[id] = Self.makeRawAlbumRecord(
                        id: id,
                        title: title,
                        assetsResult: assetsResult,
                        photosByID: cachedPhotosByID
                    )
                    alreadyUpdatedAlbumIDs.insert(id)
                    albumsInserted += 1
                    albumsMutated = true
                }

                for collection in details.changedObjects {
                    let id = collection.localIdentifier
                    let title = collection.localizedTitle ?? "Untitled"
                    if let existing = cachedAlbumsByID[id] {
                        if existing.title != title {
                            cachedAlbumsByID[id] = RawAlbumRecord(
                                id: existing.id,
                                title: title,
                                assetIDs: existing.assetIDs,
                                coverAssetID: existing.coverAssetID,
                                latestAssetDate: existing.latestAssetDate
                            )
                            albumsRenamed += 1
                            albumsMutated = true
                        }
                    } else {
                        let assetsResult = PHAsset.fetchAssets(in: collection, options: nil)
                        lastAlbumAssetResults[id] = assetsResult
                        cachedAlbumsByID[id] = Self.makeRawAlbumRecord(
                            id: id,
                            title: title,
                            assetsResult: assetsResult,
                            photosByID: cachedPhotosByID
                        )
                        alreadyUpdatedAlbumIDs.insert(id)
                        albumsInserted += 1
                        albumsMutated = true
                    }
                }
            } else {
                let afterFetch = details.fetchResultAfterChanges
                var survivingIDs: Set<String> = []
                survivingIDs.reserveCapacity(afterFetch.count)

                afterFetch.enumerateObjects { collection, _, _ in
                    let id = collection.localIdentifier
                    let title = collection.localizedTitle ?? "Untitled"
                    survivingIDs.insert(id)

                    if let existing = self.cachedAlbumsByID[id] {
                        if existing.title != title {
                            self.cachedAlbumsByID[id] = RawAlbumRecord(
                                id: existing.id,
                                title: title,
                                assetIDs: existing.assetIDs,
                                coverAssetID: existing.coverAssetID,
                                latestAssetDate: existing.latestAssetDate
                            )
                            albumsRenamed += 1
                            albumsMutated = true
                        }
                    } else {
                        let assetsResult = PHAsset.fetchAssets(in: collection, options: nil)
                        self.lastAlbumAssetResults[id] = assetsResult
                        self.cachedAlbumsByID[id] = Self.makeRawAlbumRecord(
                            id: id,
                            title: title,
                            assetsResult: assetsResult,
                            photosByID: self.cachedPhotosByID
                        )
                        alreadyUpdatedAlbumIDs.insert(id)
                        albumsInserted += 1
                        albumsMutated = true
                    }
                }

                let staleIDs = cachedAlbumsByID.keys.filter { !survivingIDs.contains($0) }
                for id in staleIDs {
                    cachedAlbumsByID.removeValue(forKey: id)
                    lastAlbumAssetResults.removeValue(forKey: id)
                    albumsRemoved += 1
                    albumsMutated = true
                }
            }

            var newAlbumOrder: [String] = []
            newAlbumOrder.reserveCapacity(details.fetchResultAfterChanges.count)
            details.fetchResultAfterChanges.enumerateObjects { collection, _, _ in
                newAlbumOrder.append(collection.localIdentifier)
            }
            if newAlbumOrder != cachedAlbumOrder {
                cachedAlbumOrder = newAlbumOrder
                albumsMutated = true
            }
        }

        // Step C: Incremental per-album membership changes (only re-builds changed albums)
        for albumID in Array(lastAlbumAssetResults.keys) {
            if alreadyUpdatedAlbumIDs.contains(albumID) {
                continue
            }
            guard let existingRecord = cachedAlbumsByID[albumID],
                  let albumAssetsResult = lastAlbumAssetResults[albumID] else {
                continue
            }
            checkedAlbums += 1
            guard let details = change.changeDetails(for: albumAssetsResult) else {
                continue
            }
            lastAlbumAssetResults[albumID] = details.fetchResultAfterChanges

            if details.hasIncrementalChanges &&
                details.insertedObjects.isEmpty &&
                details.removedObjects.isEmpty &&
                !details.hasMoves {
                let hasDateChangeInAlbum = !dateChangedAssetIDs.isEmpty &&
                    details.changedObjects.contains { dateChangedAssetIDs.contains($0.localIdentifier) }
                if !hasDateChangeInAlbum {
                    continue
                }
            }

            let updatedRecord = Self.makeRawAlbumRecord(
                id: albumID,
                title: existingRecord.title,
                assetsResult: details.fetchResultAfterChanges,
                photosByID: cachedPhotosByID
            )
            if updatedRecord != existingRecord {
                cachedAlbumsByID[albumID] = updatedRecord
                albumMembershipsChanged += 1
                albumsMutated = true
            }
        }

        let elapsed = ContinuousClock.now - opStart
        guard photosMutated || albumsMutated else {
            return
        }

        let updatedSnapshot = makeCurrentSnapshot()
        Self.debugLog.debug(
            "[PHChange] incremental update in \(Self.formatMs(elapsed), privacy: .public): assets(+\(assetsInserted, privacy: .public)/-\(assetsRemoved, privacy: .public)/~\(assetsMetadataChanged, privacy: .public)) albums(+\(albumsInserted, privacy: .public)/-\(albumsRemoved, privacy: .public)/rename=\(albumsRenamed, privacy: .public)/membership=\(albumMembershipsChanged, privacy: .public)) checkedAlbums=\(checkedAlbums, privacy: .public)"
        )
        for continuation in continuations.values {
            continuation.yield(updatedSnapshot)
        }
    }

    private func makeCurrentSnapshot() -> PhotoLibrarySnapshot {
        let photos = cachedPhotoOrder.compactMap { cachedPhotosByID[$0] }
        let albums = cachedAlbumOrder.compactMap { cachedAlbumsByID[$0] }
        return PhotoLibrarySnapshot(photos: photos, albums: albums)
    }

    private static func makeRawPhotoRecord(from asset: PHAsset) -> RawPhotoRecord {
        RawPhotoRecord(
            id: asset.localIdentifier,
            creationDate: asset.creationDate,
            isScreenshot: asset.mediaSubtypes.contains(.photoScreenshot),
            pixelWidth: asset.pixelWidth,
            pixelHeight: asset.pixelHeight
        )
    }

    private static func makeRawAlbumRecord(
        id: String,
        title: String,
        assetsResult: PHFetchResult<PHAsset>,
        photosByID: [String: RawPhotoRecord]
    ) -> RawAlbumRecord {
        var entries: [(id: String, creationDate: Date?)] = []
        entries.reserveCapacity(assetsResult.count)
        assetsResult.enumerateObjects { asset, _, _ in
            let assetID = asset.localIdentifier
            if let cached = photosByID[assetID] {
                entries.append((id: assetID, creationDate: cached.creationDate))
            } else if asset.mediaType == .image {
                entries.append((id: assetID, creationDate: asset.creationDate))
            }
        }
        entries.sort { lhs, rhs in
            switch (lhs.creationDate, rhs.creationDate) {
            case let (l?, r?):
                if l != r { return l > r }
                return lhs.id < rhs.id
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            case (.none, .none):
                return lhs.id < rhs.id
            }
        }

        let sortedIDs = entries.map(\.id)
        return RawAlbumRecord(
            id: id,
            title: title,
            assetIDs: sortedIDs,
            coverAssetID: entries.first?.id,
            latestAssetDate: entries.first?.creationDate
        )
    }

    private static func makeAssetFetchOptions(createdAfter cutoffDate: Date?) -> PHFetchOptions? {
        guard let cutoffDate else { return nil }
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "creationDate >= %@", cutoffDate as NSDate)
        return options
    }

    private nonisolated func loadPhotosOffActor(
        reason: String,
        createdAfter cutoffDate: Date?
    ) async -> LoadedPhotosState {
        let assetsStart = ContinuousClock.now
        let options = Self.makeAssetFetchOptions(createdAfter: cutoffDate)
        let assetFetch = PHAsset.fetchAssets(with: .image, options: options)
        var photosByID: [String: RawPhotoRecord] = [:]
        var photoOrder: [String] = []
        photosByID.reserveCapacity(assetFetch.count)
        photoOrder.reserveCapacity(assetFetch.count)
        assetFetch.enumerateObjects { asset, _, _ in
            let record = Self.makeRawPhotoRecord(from: asset)
            photosByID[record.id] = record
            photoOrder.append(record.id)
        }
        let assetsDuration = ContinuousClock.now - assetsStart
        Self.debugLog.debug(
            "[Photos \(reason, privacy: .public)] assets=\(photoOrder.count, privacy: .public) cutoff=\(cutoffDate?.description ?? "none", privacy: .public) in \(Self.formatMs(assetsDuration), privacy: .public)"
        )
        return LoadedPhotosState(
            assetsFetch: assetFetch,
            photosByID: photosByID,
            photoOrder: photoOrder
        )
    }

    private nonisolated func loadFullSnapshotOffActor(
        reason: String,
        createdAfter cutoffDate: Date?
    ) async -> LoadedLibraryState {
        let totalStart = ContinuousClock.now

        let assetsStart = ContinuousClock.now
        let loadedPhotos = await loadPhotosOffActor(reason: reason, createdAfter: cutoffDate)
        let assetFetch = loadedPhotos.assetsFetch
        let photosByID = loadedPhotos.photosByID
        let photoOrder = loadedPhotos.photoOrder
        let assetsDuration = ContinuousClock.now - assetsStart

        let albumsStart = ContinuousClock.now
        let albumFetch = PHAssetCollection.fetchAssetCollections(
            with: .album,
            subtype: .albumRegular,
            options: nil
        )

        var collections: [(id: String, title: String, collection: PHAssetCollection)] = []
        var albumOrder: [String] = []
        collections.reserveCapacity(albumFetch.count)
        albumOrder.reserveCapacity(albumFetch.count)
        albumFetch.enumerateObjects { collection, _, _ in
            let id = collection.localIdentifier
            let title = collection.localizedTitle ?? "Untitled"
            collections.append((id: id, title: title, collection: collection))
            albumOrder.append(id)
        }

        var albumAssetResults: [String: PHFetchResult<PHAsset>] = [:]
        var albumsByID: [String: RawAlbumRecord] = [:]
        albumAssetResults.reserveCapacity(collections.count)
        albumsByID.reserveCapacity(collections.count)
        var totalAlbumAssetLinks = 0

        if !collections.isEmpty {
            let workerCount = min(4, collections.count)
            let chunkSize = (collections.count + workerCount - 1) / workerCount
            let photosLookup = photosByID

            let batchResults = await withTaskGroup(
                of: [(String, PHFetchResult<PHAsset>, RawAlbumRecord)].self,
                returning: [(String, PHFetchResult<PHAsset>, RawAlbumRecord)].self
            ) { group in
                for workerIndex in 0..<workerCount {
                    let start = workerIndex * chunkSize
                    let end = min(collections.count, start + chunkSize)
                    guard start < end else { continue }
                    let slice = Array(collections[start..<end])
                    group.addTask {
                        var results: [(String, PHFetchResult<PHAsset>, RawAlbumRecord)] = []
                        results.reserveCapacity(slice.count)
                        for item in slice {
                            let fetch = PHAsset.fetchAssets(in: item.collection, options: nil)
                            let record = Self.makeRawAlbumRecord(
                                id: item.id,
                                title: item.title,
                                assetsResult: fetch,
                                photosByID: photosLookup
                            )
                            results.append((item.id, fetch, record))
                        }
                        return results
                    }
                }

                var combined: [(String, PHFetchResult<PHAsset>, RawAlbumRecord)] = []
                combined.reserveCapacity(collections.count)
                for await part in group {
                    combined.append(contentsOf: part)
                }
                return combined
            }

            for (id, fetch, record) in batchResults {
                albumAssetResults[id] = fetch
                albumsByID[id] = record
                totalAlbumAssetLinks += record.assetIDs.count
            }
        }
        let albumsDuration = ContinuousClock.now - albumsStart

        let photos = photoOrder.compactMap { photosByID[$0] }
        let albums = albumOrder.compactMap { albumsByID[$0] }
        let snapshot = PhotoLibrarySnapshot(photos: photos, albums: albums)

        let totalDuration = ContinuousClock.now - totalStart
        Self.debugLog.debug(
            "[Snapshot \(reason, privacy: .public)] total=\(Self.formatMs(totalDuration), privacy: .public) assets=\(photos.count, privacy: .public) (\(Self.formatMs(assetsDuration), privacy: .public)) albums=\(albums.count, privacy: .public) albumLinks=\(totalAlbumAssetLinks, privacy: .public) (\(Self.formatMs(albumsDuration), privacy: .public))"
        )

        return LoadedLibraryState(
            assetsFetch: assetFetch,
            albumsFetch: albumFetch,
            albumAssetResults: albumAssetResults,
            photosByID: photosByID,
            photoOrder: photoOrder,
            albumsByID: albumsByID,
            albumOrder: albumOrder,
            snapshot: snapshot
        )
    }

    // MARK: - Album Mutations (Strictly Non-Destructive to Device Photos)

    func createAlbum(title: String, addingAssetIDs: [String]) async throws -> RawAlbumRecord {
        let opStart = ContinuousClock.now
        let assets = fetchOrderedAssets(identifiers: addingAssetIDs)
        let createdLocalID = OSAllocatedUnfairLock<String?>(initialState: nil)

        try await performLibraryChanges {
            let creationRequest = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: title)
            let placeholderID = creationRequest.placeholderForCreatedAssetCollection.localIdentifier
            createdLocalID.withLock { $0 = placeholderID }
            if !assets.isEmpty {
                creationRequest.addAssets(assets as NSArray)
            }
        }

        let albumID = createdLocalID.withLock { $0 } ?? UUID().uuidString
        let coverID = assets.first?.localIdentifier
        let latestDate = assets.compactMap(\.creationDate).max()

        Self.debugLog.debug(
            "[Service createAlbum] title=\(title, privacy: .public) count=\(assets.count, privacy: .public) in \(Self.formatMs(ContinuousClock.now - opStart), privacy: .public)"
        )

        return RawAlbumRecord(
            id: albumID,
            title: title,
            assetIDs: assets.map(\.localIdentifier),
            coverAssetID: coverID,
            latestAssetDate: latestDate
        )
    }

    func addAssets(_ assetIDs: [String], toAlbum albumID: String) async throws -> AddAssetsResult {
        let opStart = ContinuousClock.now
        guard let collection = fetchAlbumCollection(identifier: albumID) else {
            throw PhotoLibraryError.albumNotFound
        }

        let existingFetch = PHAsset.fetchAssets(in: collection, options: nil)
        var existingIDs: Set<String> = []
        existingFetch.enumerateObjects { asset, _, _ in
            existingIDs.insert(asset.localIdentifier)
        }

        let toAddIDs = assetIDs.filter { !existingIDs.contains($0) }
        let skippedIDs = assetIDs.filter { existingIDs.contains($0) }
        guard !toAddIDs.isEmpty else {
            return AddAssetsResult(addedAssetIDs: [], skippedAssetIDs: skippedIDs)
        }

        let assetsToAdd = fetchOrderedAssets(identifiers: toAddIDs)
        try await performLibraryChanges {
            guard let request = PHAssetCollectionChangeRequest(for: collection) else {
                return
            }
            request.addAssets(assetsToAdd as NSArray)
        }

        Self.debugLog.debug(
            "[Service addAssets] added=\(assetsToAdd.count, privacy: .public) skipped=\(skippedIDs.count, privacy: .public) in \(Self.formatMs(ContinuousClock.now - opStart), privacy: .public)"
        )

        return AddAssetsResult(
            addedAssetIDs: assetsToAdd.map(\.localIdentifier),
            skippedAssetIDs: skippedIDs
        )
    }

    func removeAssets(_ assetIDs: [String], fromAlbum albumID: String) async throws {
        let opStart = ContinuousClock.now
        guard let collection = fetchAlbumCollection(identifier: albumID) else {
            throw PhotoLibraryError.albumNotFound
        }

        let assetsToRemove = fetchOrderedAssets(identifiers: assetIDs)
        guard !assetsToRemove.isEmpty else { return }

        try await performLibraryChanges {
            guard let request = PHAssetCollectionChangeRequest(for: collection) else {
                return
            }
            request.removeAssets(assetsToRemove as NSArray)
        }

        Self.debugLog.debug(
            "[Service removeAssets] removed=\(assetsToRemove.count, privacy: .public) in \(Self.formatMs(ContinuousClock.now - opStart), privacy: .public)"
        )
    }

    func renameAlbum(_ albumID: String, to newTitle: String) async throws {
        guard let collection = fetchAlbumCollection(identifier: albumID) else {
            throw PhotoLibraryError.albumNotFound
        }
        try await performLibraryChanges {
            guard let request = PHAssetCollectionChangeRequest(for: collection) else {
                return
            }
            request.title = newTitle
        }
    }

    func deleteAlbum(_ albumID: String) async throws {
        guard let collection = fetchAlbumCollection(identifier: albumID) else {
            throw PhotoLibraryError.albumNotFound
        }
        try await performLibraryChanges {
            PHAssetCollectionChangeRequest.deleteAssetCollections([collection] as NSArray)
        }
    }

    // MARK: - Helpers

    private func fetchAlbumCollection(identifier: String) -> PHAssetCollection? {
        PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [identifier], options: nil).firstObject
    }

    private func fetchOrderedAssets(identifiers: [String]) -> [PHAsset] {
        guard !identifiers.isEmpty else { return [] }
        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        var byID: [String: PHAsset] = [:]
        byID.reserveCapacity(fetch.count)
        fetch.enumerateObjects { asset, _, _ in
            byID[asset.localIdentifier] = asset
        }
        return identifiers.compactMap { byID[$0] }
    }

    private func performLibraryChanges(_ changes: @escaping @Sendable () -> Void) async throws {
        do {
            try await PHPhotoLibrary.shared().performChanges(changes)
        } catch {
            Self.debugLog.error(
                "[PhotoKit] performChanges failed: \(error.localizedDescription, privacy: .public)"
            )
            let nsError = error as NSError
            if nsError.domain == PHPhotosErrorDomain && nsError.code == PHPhotosError.userCancelled.rawValue {
                throw PhotoLibraryError.userCancelled
            }
            if nsError.domain == NSCocoaErrorDomain && nsError.code == NSUserCancelledError {
                throw PhotoLibraryError.userCancelled
            }
            throw PhotoLibraryError.operationFailed(error.localizedDescription)
        }
    }
}
