import CoreTransferable
import Foundation
import UniformTypeIdentifiers

extension UTType {
    static let quickAlbumPhotoAssetIDs = UTType(
        exportedAs: "com.quickalbum.photo-asset-ids",
        conformingTo: .data
    )
}

struct QuickAlbumDragPayload: Codable, Sendable, Transferable {
    let assetIDs: [String]

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(contentType: .quickAlbumPhotoAssetIDs) { payload in
            try JSONEncoder().encode(payload)
        } importing: { data in
            try JSONDecoder().decode(QuickAlbumDragPayload.self, from: data)
        }
    }

    func makeItemProvider() -> NSItemProvider {
        let provider = NSItemProvider()
        let encoded = (try? JSONEncoder().encode(self)) ?? Data()
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.quickAlbumPhotoAssetIDs.identifier,
            visibility: .all
        ) { completion in
            completion(encoded, nil)
            return nil
        }
        return provider
    }
}
