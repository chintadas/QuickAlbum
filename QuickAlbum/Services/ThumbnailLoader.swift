@preconcurrency import Photos
import UIKit
import os

@MainActor
final class ThumbnailLoader {
    static let shared = ThumbnailLoader()

    let gridImageManager = PHCachingImageManager()
    private let coverCache = NSCache<NSString, UIImage>()

    init() {
        coverCache.countLimit = 400
    }

    func cachedCover(for assetID: String) -> UIImage? {
        coverCache.object(forKey: assetID as NSString)
    }

    func loadCoverThumbnail(assetID: String, targetPixelSize: CGSize) async -> UIImage? {
        if let cached = coverCache.object(forKey: assetID as NSString) {
            return cached
        }

        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil)
        guard let asset = fetch.firstObject else {
            return nil
        }

        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        options.isSynchronous = false

        let image: UIImage? = await withCheckedContinuation { continuation in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            gridImageManager.requestImage(
                for: asset,
                targetSize: targetPixelSize,
                contentMode: .aspectFill,
                options: options
            ) { result, info in
                let isCancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if isDegraded && !isCancelled {
                    return
                }
                let shouldResume = resumed.withLock { state -> Bool in
                    guard !state else { return false }
                    state = true
                    return true
                }
                if shouldResume {
                    continuation.resume(returning: result)
                }
            }
        }

        if let image {
            coverCache.setObject(image, forKey: assetID as NSString)
        }
        return image
    }

    func previewImageStream(assetID: String, targetPixelSize: CGSize) -> AsyncStream<UIImage> {
        AsyncStream { continuation in
            let fetch = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil)
            guard let asset = fetch.firstObject else {
                continuation.finish()
                return
            }

            let options = PHImageRequestOptions()
            options.deliveryMode = .opportunistic
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = true
            options.isSynchronous = false

            let requestID = gridImageManager.requestImage(
                for: asset,
                targetSize: targetPixelSize,
                contentMode: .aspectFit,
                options: options
            ) { image, info in
                if let image {
                    continuation.yield(image)
                }
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                let isCancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
                let hasError = info?[PHImageErrorKey] != nil
                if !isDegraded || isCancelled || hasError {
                    continuation.finish()
                }
            }

            continuation.onTermination = { [weak gridImageManager] _ in
                Task { @MainActor in
                    gridImageManager?.cancelImageRequest(requestID)
                }
            }
        }
    }

    func invalidateCoverCache(for assetID: String) {
        coverCache.removeObject(forKey: assetID as NSString)
    }
}
