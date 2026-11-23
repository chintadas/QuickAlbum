import SwiftUI

struct PhotoGridRepresentable: UIViewControllerRepresentable {
    var viewModel: OrganizerViewModel
    var onOpenPreview: (String) -> Void

    func makeUIViewController(context: Context) -> PhotoGridViewController {
        let controller = PhotoGridViewController()
        controller.onToggleSelection = { assetID in
            viewModel.toggleSelection(assetID)
        }
        controller.onSetSelection = { assetID, selected in
            viewModel.setSelection(assetID, selected: selected)
        }
        controller.onOpenPreview = { assetID in
            onOpenPreview(assetID)
        }
        controller.onChangeColumnCount = { newCount in
            viewModel.columnCount = newCount
        }
        controller.onDragSessionChanged = { active, assetIDs in
            viewModel.setDragSessionActive(active, assetIDs: assetIDs)
        }
        controller.onResolveDragAssetIDs = { pressedID in
            viewModel.resolvedDragAssetIDs(startingFrom: pressedID)
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: PhotoGridViewController, context: Context) {
        uiViewController.applyState(
            photoItemsByID: viewModel.visiblePhotoItemsByID,
            flatPhotoIDs: viewModel.flatVisiblePhotoIDs,
            selectedIDs: viewModel.selectedAssetIDs,
            columnCount: viewModel.columnCount,
            dataVersion: viewModel.dataVersion
        )
    }
}
