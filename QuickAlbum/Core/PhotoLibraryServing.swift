import Foundation

public enum PhotoLibraryError: Error, Equatable, LocalizedError, Sendable {
    case notAuthorized
    case albumNotFound
    case userCancelled
    case operationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notAuthorized:
            return "Full Photo Library access is required."
        case .albumNotFound:
            return "The target album could not be found."
        case .userCancelled:
            return "The operation was cancelled."
        case .operationFailed(let message):
            return message
        }
    }
}

public protocol PhotoLibraryServing: Sendable {
    func authorizationStatus() -> PhotoAuthorizationStatus
    func requestFullAuthorization() async -> PhotoAuthorizationStatus
    func buildInitialIndex() async -> PhotoLibrarySnapshot
    func libraryChanges() -> AsyncStream<PhotoLibrarySnapshot>
    func addAssets(_ assetIDs: [String], toAlbum albumID: String) async throws -> AddAssetsResult
    func createAlbum(title: String, addingAssetIDs: [String]) async throws -> RawAlbumRecord
    func removeAssets(_ assetIDs: [String], fromAlbum albumID: String) async throws
    func renameAlbum(_ albumID: String, to newTitle: String) async throws
    func deleteAlbum(_ albumID: String) async throws
}
