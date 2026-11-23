import Foundation

public struct PhotoAlbumIndex: Equatable, Sendable {
    public private(set) var albumToAssets: [String: Set<String>]
    public private(set) var assetToAllUserAlbums: [String: Set<String>]
    public private(set) var albumAssetOrder: [String: [String]]

    public init(albums: [RawAlbumRecord]) {
        var albumToAssets: [String: Set<String>] = [:]
        var assetToAllUserAlbums: [String: Set<String>] = [:]
        var albumAssetOrder: [String: [String]] = [:]

        albumToAssets.reserveCapacity(albums.count)
        albumAssetOrder.reserveCapacity(albums.count)

        for album in albums {
            let assetSet = Set(album.assetIDs)
            albumToAssets[album.id] = assetSet
            albumAssetOrder[album.id] = album.assetIDs
            for assetID in assetSet {
                assetToAllUserAlbums[assetID, default: []].insert(album.id)
            }
        }

        self.albumToAssets = albumToAssets
        self.assetToAllUserAlbums = assetToAllUserAlbums
        self.albumAssetOrder = albumAssetOrder
    }

    public func countedAlbumIDs(
        for assetID: String,
        scope: MembershipScope,
        matchingAlbumIDs: Set<String>
    ) -> Set<String> {
        guard let allAlbums = assetToAllUserAlbums[assetID] else {
            return []
        }
        switch scope {
        case .allUserAlbums:
            return allAlbums
        case .formatMatchingOnly:
            return allAlbums.intersection(matchingAlbumIDs)
        }
    }

    public func countedAlbumCount(
        for assetID: String,
        scope: MembershipScope,
        matchingAlbumIDs: Set<String>
    ) -> Int {
        countedAlbumIDs(for: assetID, scope: scope, matchingAlbumIDs: matchingAlbumIDs).count
    }

    public func assetsAlreadyInAlbum(albumID: String) -> Set<String> {
        albumToAssets[albumID] ?? []
    }

    public func assetIDs(inAlbum albumID: String) -> [String] {
        albumAssetOrder[albumID] ?? []
    }

    public func adding(assetIDs: [String], toAlbum albumID: String) -> PhotoAlbumIndex {
        var copy = self
        var existingSet = copy.albumToAssets[albumID] ?? []
        var order = copy.albumAssetOrder[albumID] ?? []
        for id in assetIDs where !existingSet.contains(id) {
            existingSet.insert(id)
            order.append(id)
            copy.assetToAllUserAlbums[id, default: []].insert(albumID)
        }
        copy.albumToAssets[albumID] = existingSet
        copy.albumAssetOrder[albumID] = order
        return copy
    }

    public func removing(assetIDs: [String], fromAlbum albumID: String) -> PhotoAlbumIndex {
        var copy = self
        let removeSet = Set(assetIDs)
        var existingSet = copy.albumToAssets[albumID] ?? []
        existingSet.subtract(removeSet)
        copy.albumToAssets[albumID] = existingSet
        if let order = copy.albumAssetOrder[albumID] {
            copy.albumAssetOrder[albumID] = order.filter { !removeSet.contains($0) }
        }
        for id in removeSet {
            copy.assetToAllUserAlbums[id]?.remove(albumID)
            if copy.assetToAllUserAlbums[id]?.isEmpty == true {
                copy.assetToAllUserAlbums.removeValue(forKey: id)
            }
        }
        return copy
    }

    public func deleting(albumID: String) -> PhotoAlbumIndex {
        var copy = self
        let removedAssets = copy.albumToAssets.removeValue(forKey: albumID) ?? []
        copy.albumAssetOrder.removeValue(forKey: albumID)
        for id in removedAssets {
            copy.assetToAllUserAlbums[id]?.remove(albumID)
            if copy.assetToAllUserAlbums[id]?.isEmpty == true {
                copy.assetToAllUserAlbums.removeValue(forKey: id)
            }
        }
        return copy
    }
}
