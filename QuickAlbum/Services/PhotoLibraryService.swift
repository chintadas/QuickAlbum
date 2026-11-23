import Foundation
import os
@preconcurrency import Photos

private final class PhotoLibraryObserverProxy: NSObject, PHPhotoLibraryChangeObserver, @unchecked Sendable {
    var onChange: (@Sendable (PHChange) -> Void)?

    func photoLibraryDidChange(_ changeInstance: PHChange) {
        onChange?(changeInstance)
    }
}

actor PhotoLibraryService: PhotoLibraryServing {
    private var continuations: [UUID: AsyncStream<PhotoLibrarySnapshot>.Continuation] = [:]
    private var observerProxy: PhotoLibraryObserverProxy?

    private var lastAssetsFetchResult: PHFetchResult<PHAsset>?
    private var lastAlbumsFetchResult: PHFetchResult<PHAssetCollection>?
    private var lastAlbumAssetResults: [String: PHFetchResult<PHAsset>] = [:]

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

    func buildInitialIndex() async -> PhotoLibrarySnapshot {
        registerObserverIfNeeded()
        return fetchFullSnapshot()
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
        var needsRefresh = false

        if let assetsResult = lastAssetsFetchResult,
           change.changeDetails(for: assetsResult) != nil {
            needsRefresh = true
        }
        if let albumsResult = lastAlbumsFetchResult,
           change.changeDetails(for: albumsResult) != nil {
            needsRefresh = true
        }
        if !needsRefresh {
            for (_, albumAssetsResult) in lastAlbumAssetResults {
                if change.changeDetails(for: albumAssetsResult) != nil {
                    needsRefresh = true
                    break
                }
            }
        }

        guard needsRefresh else { return }
        let updated = fetchFullSnapshot()
        for continuation in continuations.values {
            continuation.yield(updated)
        }
    }

    private func fetchFullSnapshot() -> PhotoLibrarySnapshot {
        let assetOptions = PHFetchOptions()
        assetOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let assetFetch = PHAsset.fetchAssets(with: .image, options: assetOptions)
        lastAssetsFetchResult = assetFetch

        var photos: [RawPhotoRecord] = []
        photos.reserveCapacity(assetFetch.count)
        assetFetch.enumerateObjects { asset, _, _ in
            let isScreenshot = asset.mediaSubtypes.contains(.photoScreenshot)
            photos.append(
                RawPhotoRecord(
                    id: asset.localIdentifier,
                    creationDate: asset.creationDate,
                    isScreenshot: isScreenshot,
                    pixelWidth: asset.pixelWidth,
                    pixelHeight: asset.pixelHeight
                )
            )
        }

        let albumFetch = PHAssetCollection.fetchAssetCollections(
            with: .album,
            subtype: .albumRegular,
            options: nil
        )
        lastAlbumsFetchResult = albumFetch

        let albumAssetOptions = PHFetchOptions()
        albumAssetOptions.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        albumAssetOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]

        var albums: [RawAlbumRecord] = []
        albums.reserveCapacity(albumFetch.count)
        var newAlbumAssetResults: [String: PHFetchResult<PHAsset>] = [:]
        newAlbumAssetResults.reserveCapacity(albumFetch.count)

        albumFetch.enumerateObjects { collection, _, _ in
            let assetsResult = PHAsset.fetchAssets(in: collection, options: albumAssetOptions)
            newAlbumAssetResults[collection.localIdentifier] = assetsResult

            var assetIDs: [String] = []
            assetIDs.reserveCapacity(assetsResult.count)
            assetsResult.enumerateObjects { asset, _, _ in
                assetIDs.append(asset.localIdentifier)
            }

            let coverAssetID = assetsResult.firstObject?.localIdentifier
            let latestDate = assetsResult.firstObject?.creationDate

            albums.append(
                RawAlbumRecord(
                    id: collection.localIdentifier,
                    title: collection.localizedTitle ?? "Untitled",
                    assetIDs: assetIDs,
                    coverAssetID: coverAssetID,
                    latestAssetDate: latestDate
                )
            )
        }

        lastAlbumAssetResults = newAlbumAssetResults
        return PhotoLibrarySnapshot(photos: photos, albums: albums)
    }

    // MARK: - Album Mutations (Strictly Non-Destructive to Device Photos)

    func createAlbum(title: String, addingAssetIDs: [String]) async throws -> RawAlbumRecord {
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

        return RawAlbumRecord(
            id: albumID,
            title: title,
            assetIDs: assets.map(\.localIdentifier),
            coverAssetID: coverID,
            latestAssetDate: latestDate
        )
    }

    func addAssets(_ assetIDs: [String], toAlbum albumID: String) async throws -> AddAssetsResult {
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

        return AddAssetsResult(
            addedAssetIDs: assetsToAdd.map(\.localIdentifier),
            skippedAssetIDs: skippedIDs
        )
    }

    func removeAssets(_ assetIDs: [String], fromAlbum albumID: String) async throws {
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
