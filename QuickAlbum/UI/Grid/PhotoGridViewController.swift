import Photos
import SwiftUI
import UIKit

@MainActor
final class PhotoGridViewController: UIViewController,
    UICollectionViewDelegate,
    UICollectionViewDataSourcePrefetching,
    UICollectionViewDragDelegate,
    UIGestureRecognizerDelegate {
    private enum GridSection: Hashable {
        case main
    }

    // MARK: - Callbacks

    var onToggleSelection: ((String) -> Void)?
    var onSetSelection: ((String, Bool) -> Void)?
    var onOpenPreview: ((String) -> Void)?
    var onChangeColumnCount: ((Int) -> Void)?
    var onDragSessionChanged: ((Bool, [String]) -> Void)?
    var onResolveDragAssetIDs: ((String) -> [String])?

    // MARK: - State

    private var photoItemsByID: [String: PhotoItem] = [:]
    private var flatPhotoIDs: [String] = []
    private var selectedIDs: Set<String> = []
    private var columnCount: Int = 4
    private var lastAppliedDataVersion: Int = -1

    private var cachedAssetsByID: [String: PHAsset] = [:]
    private let imageManager = ThumbnailLoader.shared.gridImageManager

    // MARK: - UI & Data Source

    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<GridSection, String>!
    private var lastTargetPixelSize: CGSize = CGSize(width: 220, height: 220)

    // MARK: - Gesture State

    private var tapRecognizer: UITapGestureRecognizer!
    private var scrubPanRecognizer: UIPanGestureRecognizer!
    private var pinchRecognizer: UIPinchGestureRecognizer!

    private var lastTap: (assetID: String, time: TimeInterval)?
    private var scrubTargetSelected: Bool = true
    private var lastScrubFlatIndex: Int?
    private var scrubDisplayLink: CADisplayLink?
    private var scrubAutoScrollSpeed: CGFloat = 0
    private var lastScrubPointInView: CGPoint = .zero
    private let selectionFeedback = UISelectionFeedbackGenerator()

    private let dateAccessibilityFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        configureCollectionView()
        configureDataSource()
        configureGestures()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateTargetPixelSize()
    }

    // MARK: - Public Update Entrypoint

    func applyState(
        photoItemsByID: [String: PhotoItem],
        flatPhotoIDs: [String],
        selectedIDs: Set<String>,
        columnCount: Int,
        dataVersion: Int
    ) {
        let previousColumnCount = self.columnCount
        let previousSelected = self.selectedIDs
        let structureChanged = self.lastAppliedDataVersion != dataVersion

        self.photoItemsByID = photoItemsByID
        self.flatPhotoIDs = flatPhotoIDs
        self.selectedIDs = selectedIDs
        self.columnCount = columnCount

        if previousColumnCount != columnCount {
            updateTargetPixelSize()
            collectionView?.collectionViewLayout.invalidateLayout()
        }

        guard isViewLoaded else { return }

        if structureChanged {
            self.lastAppliedDataVersion = dataVersion
            refreshPHAssetCache(for: flatPhotoIDs)
            applyDiffableSnapshot(animated: true)
        } else if previousSelected != selectedIDs {
            let changedIDs = previousSelected.symmetricDifference(selectedIDs)
            reconfigureVisibleCells(for: changedIDs)
        }
    }

    // MARK: - Setup

    private func configureCollectionView() {
        let layout = makeCompositionalLayout()
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.backgroundColor = .systemBackground
        collectionView.alwaysBounceVertical = true
        collectionView.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: 164, right: 0)
        collectionView.verticalScrollIndicatorInsets = UIEdgeInsets(top: 0, left: 0, bottom: 150, right: 0)

        collectionView.register(PhotoGridCell.self, forCellWithReuseIdentifier: PhotoGridCell.reuseIdentifier)

        collectionView.delegate = self
        collectionView.prefetchDataSource = self
        collectionView.dragDelegate = self
        collectionView.dragInteractionEnabled = true
        view.addSubview(collectionView)
    }

    private func makeCompositionalLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { [weak self] _, _ in
            let cols = max(3, min(5, self?.columnCount ?? 4))
            let fraction = 1.0 / CGFloat(cols)
            // `horizontal(layoutSize:repeatingSubitem:count:)` respects the item's widthDimension
            // (unlike the deprecated `subitem:count:` API), so each item must be `1 / cols` wide
            // to place `cols` square tiles per row instead of pushing columns 2..N off-screen.
            let itemSize = NSCollectionLayoutSize(
                widthDimension: .fractionalWidth(fraction),
                heightDimension: .fractionalHeight(1.0)
            )
            let item = NSCollectionLayoutItem(layoutSize: itemSize)
            item.contentInsets = NSDirectionalEdgeInsets(top: 1, leading: 1, bottom: 1, trailing: 1)

            let groupSize = NSCollectionLayoutSize(
                widthDimension: .fractionalWidth(1.0),
                heightDimension: .fractionalWidth(fraction)
            )
            let group = NSCollectionLayoutGroup.horizontal(
                layoutSize: groupSize,
                repeatingSubitem: item,
                count: cols
            )

            let section = NSCollectionLayoutSection(group: group)
            section.contentInsets = NSDirectionalEdgeInsets(top: 1, leading: 1, bottom: 8, trailing: 1)
            return section
        }
    }

    private func configureDataSource() {
        dataSource = UICollectionViewDiffableDataSource<GridSection, String>(
            collectionView: collectionView
        ) { [weak self] collectionView, indexPath, assetID in
            guard let self,
                  let cell = collectionView.dequeueReusableCell(
                    withReuseIdentifier: PhotoGridCell.reuseIdentifier,
                    for: indexPath
                  ) as? PhotoGridCell else {
                return UICollectionViewCell()
            }

            let item = self.photoItemsByID[assetID]
            let count = item?.countedAlbumCount ?? 0
            let isSelected = self.selectedIDs.contains(assetID)
            let dateText = item?.creationDate.map { self.dateAccessibilityFormatter.string(from: $0) } ?? "Undated"

            cell.configure(
                assetID: assetID,
                asset: self.cachedAssetsByID[assetID],
                countedAlbumCount: count,
                isSelected: isSelected,
                accessibilityDateText: dateText,
                imageManager: self.imageManager,
                targetPixelSize: self.lastTargetPixelSize,
                onQuickLook: { [weak self] in
                    self?.onOpenPreview?(assetID)
                }
            )
            return cell
        }
    }

    private func configureGestures() {
        tapRecognizer = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tapRecognizer.cancelsTouchesInView = false
        collectionView.addGestureRecognizer(tapRecognizer)

        scrubPanRecognizer = UIPanGestureRecognizer(target: self, action: #selector(handleScrubPan(_:)))
        scrubPanRecognizer.delegate = self
        scrubPanRecognizer.maximumNumberOfTouches = 1
        collectionView.addGestureRecognizer(scrubPanRecognizer)

        pinchRecognizer = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        collectionView.addGestureRecognizer(pinchRecognizer)
    }

    // MARK: - Snapshot & Cache Updates

    private func applyDiffableSnapshot(animated: Bool) {
        let existingIDs = Set(dataSource.snapshot().itemIdentifiers)
        var snapshot = NSDiffableDataSourceSnapshot<GridSection, String>()
        snapshot.appendSections([.main])
        snapshot.appendItems(flatPhotoIDs, toSection: .main)
        let itemsToReconfigure = flatPhotoIDs.filter { existingIDs.contains($0) }
        if !itemsToReconfigure.isEmpty {
            snapshot.reconfigureItems(itemsToReconfigure)
        }
        dataSource.apply(snapshot, animatingDifferences: animated)
    }

    private func reconfigureVisibleCells(for changedIDs: Set<String>) {
        for indexPath in collectionView.indexPathsForVisibleItems {
            guard let assetID = dataSource.itemIdentifier(for: indexPath),
                  changedIDs.contains(assetID),
                  let cell = collectionView.cellForItem(at: indexPath) as? PhotoGridCell else {
                continue
            }
            let item = photoItemsByID[assetID]
            let dateText = item?.creationDate.map { dateAccessibilityFormatter.string(from: $0) } ?? "Undated"
            cell.updateVisualState(
                countedAlbumCount: item?.countedAlbumCount ?? 0,
                isSelected: selectedIDs.contains(assetID),
                accessibilityDateText: dateText
            )
        }
    }

    private func refreshPHAssetCache(for ids: [String]) {
        let missing = ids.filter { cachedAssetsByID[$0] == nil }
        guard !missing.isEmpty else { return }
        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: missing, options: nil)
        fetch.enumerateObjects { [weak self] asset, _, _ in
            self?.cachedAssetsByID[asset.localIdentifier] = asset
        }
    }

    private func updateTargetPixelSize() {
        let width = max(view.bounds.width, 320)
        let cols = CGFloat(max(3, min(5, columnCount)))
        let cellPoints = (width / cols) - 2
        let scale = view.window?.screen.scale ?? traitCollection.displayScale
        let pixelDim = max(120, ceil(cellPoints * max(scale, 2.0)))
        lastTargetPixelSize = CGSize(width: pixelDim, height: pixelDim)
    }

    // MARK: - Gesture Handlers

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        let point = recognizer.location(in: collectionView)
        guard let indexPath = collectionView.indexPathForItem(at: point),
              let assetID = dataSource.itemIdentifier(for: indexPath) else {
            return
        }

        // Ignore taps inside the top-right quick-look button bounds
        if let cell = collectionView.cellForItem(at: indexPath) {
            let localPoint = recognizer.location(in: cell.contentView)
            if localPoint.x >= cell.contentView.bounds.width - 30 && localPoint.y <= 30 {
                return
            }
        }

        let now = CACurrentMediaTime()
        if let prev = lastTap, prev.assetID == assetID, now - prev.time < 0.24 {
            lastTap = nil
            // Revert interim toggle from tap #1 and present preview
            onToggleSelection?(assetID)
            onOpenPreview?(assetID)
        } else {
            lastTap = (assetID, now)
            onToggleSelection?(assetID)
        }
    }

    @objc private func handleScrubPan(_ recognizer: UIPanGestureRecognizer) {
        let point = recognizer.location(in: collectionView)
        lastScrubPointInView = recognizer.location(in: view)

        switch recognizer.state {
        case .began:
            selectionFeedback.prepare()
            if let indexPath = collectionView.indexPathForItem(at: point),
               let assetID = dataSource.itemIdentifier(for: indexPath),
               let flatIndex = flatPhotoIDs.firstIndex(of: assetID) {
                scrubTargetSelected = !selectedIDs.contains(assetID)
                lastScrubFlatIndex = flatIndex
                applyScrubRange(from: flatIndex, to: flatIndex)
            }
            startScrubAutoScrollDisplayLink()

        case .changed:
            updateScrubAutoScrollSpeed(viewLocation: lastScrubPointInView)
            applyScrubAtCurrentPoint(point)

        case .ended, .cancelled, .failed:
            stopScrubAutoScrollDisplayLink()
            lastScrubFlatIndex = nil

        default:
            break
        }
    }

    private func applyScrubAtCurrentPoint(_ pointInCollection: CGPoint) {
        guard let indexPath = collectionView.indexPathForItem(at: pointInCollection),
              let assetID = dataSource.itemIdentifier(for: indexPath),
              let currentFlatIndex = flatPhotoIDs.firstIndex(of: assetID) else {
            return
        }
        let startIdx = lastScrubFlatIndex ?? currentFlatIndex
        applyScrubRange(from: startIdx, to: currentFlatIndex)
        lastScrubFlatIndex = currentFlatIndex
    }

    private func applyScrubRange(from startIndex: Int, to endIndex: Int) {
        guard !flatPhotoIDs.isEmpty else { return }
        let lower = max(0, min(startIndex, endIndex))
        let upper = min(flatPhotoIDs.count - 1, max(startIndex, endIndex))
        var didChangeAny = false

        for idx in lower...upper {
            let id = flatPhotoIDs[idx]
            let isCurrentlySelected = selectedIDs.contains(id)
            if isCurrentlySelected != scrubTargetSelected {
                onSetSelection?(id, scrubTargetSelected)
                didChangeAny = true
            }
        }
        if didChangeAny {
            selectionFeedback.selectionChanged()
        }
    }

    private func updateScrubAutoScrollSpeed(viewLocation: CGPoint) {
        let edgeMargin: CGFloat = 68
        let topLimit = view.safeAreaInsets.top + edgeMargin
        let bottomLimit = view.bounds.height - 150 - edgeMargin

        if viewLocation.y < topLimit {
            let ratio = min(1, (topLimit - viewLocation.y) / edgeMargin)
            scrubAutoScrollSpeed = -ratio * 10
        } else if viewLocation.y > bottomLimit {
            let ratio = min(1, (viewLocation.y - bottomLimit) / edgeMargin)
            scrubAutoScrollSpeed = ratio * 10
        } else {
            scrubAutoScrollSpeed = 0
        }
    }

    private func startScrubAutoScrollDisplayLink() {
        stopScrubAutoScrollDisplayLink()
        let link = CADisplayLink(target: self, selector: #selector(handleScrubAutoScrollTick))
        link.add(to: .main, forMode: .common)
        scrubDisplayLink = link
    }

    private func stopScrubAutoScrollDisplayLink() {
        scrubDisplayLink?.invalidate()
        scrubDisplayLink = nil
        scrubAutoScrollSpeed = 0
    }

    @objc private func handleScrubAutoScrollTick() {
        guard scrubAutoScrollSpeed != 0 else { return }
        let minOffsetY = -collectionView.adjustedContentInset.top
        let maxOffsetY = max(minOffsetY, collectionView.contentSize.height - collectionView.bounds.height + collectionView.adjustedContentInset.bottom)
        let targetY = min(maxOffsetY, max(minOffsetY, collectionView.contentOffset.y + scrubAutoScrollSpeed))
        collectionView.contentOffset.y = targetY

        let collectionPoint = view.convert(lastScrubPointInView, to: collectionView)
        applyScrubAtCurrentPoint(collectionPoint)
    }

    @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
        guard recognizer.state == .changed else { return }
        if recognizer.scale > 1.18 && columnCount > 3 {
            onChangeColumnCount?(columnCount - 1)
            recognizer.scale = 1.0
        } else if recognizer.scale < 0.85 && columnCount < 5 {
            onChangeColumnCount?(columnCount + 1)
            recognizer.scale = 1.0
        }
    }

    // MARK: - UIGestureRecognizerDelegate

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer == scrubPanRecognizer else { return true }
        if collectionView.isDragging || collectionView.isDecelerating {
            return false
        }
        let velocity = scrubPanRecognizer.velocity(in: collectionView)
        return abs(velocity.x) > abs(velocity.y) * 1.4 && abs(velocity.x) > 40
    }

    // MARK: - UICollectionViewDataSourcePrefetching

    func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        let assets = indexPaths.compactMap { indexPath -> PHAsset? in
            guard let id = dataSource.itemIdentifier(for: indexPath) else { return nil }
            return cachedAssetsByID[id]
        }
        guard !assets.isEmpty else { return }
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        imageManager.startCachingImages(for: assets, targetSize: lastTargetPixelSize, contentMode: .aspectFill, options: options)
    }

    func collectionView(_ collectionView: UICollectionView, cancelPrefetchingForItemsAt indexPaths: [IndexPath]) {
        let assets = indexPaths.compactMap { indexPath -> PHAsset? in
            guard let id = dataSource.itemIdentifier(for: indexPath) else { return nil }
            return cachedAssetsByID[id]
        }
        guard !assets.isEmpty else { return }
        imageManager.stopCachingImages(for: assets, targetSize: lastTargetPixelSize, contentMode: .aspectFill, options: nil)
    }

    // MARK: - UICollectionViewDragDelegate

    func collectionView(
        _ collectionView: UICollectionView,
        itemsForBeginning session: UIDragSession,
        at indexPath: IndexPath
    ) -> [UIDragItem] {
        guard let pressedID = dataSource.itemIdentifier(for: indexPath) else {
            return []
        }

        let dragIDs = onResolveDragAssetIDs?(pressedID) ?? [pressedID]
        guard !dragIDs.isEmpty else { return [] }

        onDragSessionChanged?(true, dragIDs)

        let payload = QuickAlbumDragPayload(assetIDs: dragIDs)
        let dragItem = UIDragItem(itemProvider: payload.makeItemProvider())
        dragItem.localObject = dragIDs

        let cellThumb = (collectionView.cellForItem(at: indexPath) as? PhotoGridCell)?.currentThumbnailImage
        let count = dragIDs.count

        dragItem.previewProvider = { [weak self] in
            guard let self else { return nil }
            let previewView = self.makeDragStackPreview(primaryImage: cellThumb, count: count)
            let params = UIDragPreviewParameters()
            params.backgroundColor = .clear
            return UIDragPreview(view: previewView, parameters: params)
        }
        return [dragItem]
    }

    func collectionView(_ collectionView: UICollectionView, dragSessionDidEnd session: UIDragSession) {
        onDragSessionChanged?(false, [])
    }

    func collectionView(_ collectionView: UICollectionView, dragSessionAllowsMoveOperation session: UIDragSession) -> Bool {
        false
    }

    private func makeDragStackPreview(primaryImage: UIImage?, count: Int) -> UIView {
        let size = CGSize(width: 82, height: 82)
        let container = UIView(frame: CGRect(origin: .zero, size: CGSize(width: size.width + 14, height: size.height + 14)))
        container.backgroundColor = .clear

        if count > 2 {
            let backCard = UIView(frame: CGRect(x: 10, y: 2, width: size.width - 8, height: size.height - 8))
            backCard.backgroundColor = .systemGray4
            backCard.layer.cornerRadius = 10
            backCard.transform = CGAffineTransform(rotationAngle: 0.09)
            container.addSubview(backCard)
        }
        if count > 1 {
            let midCard = UIView(frame: CGRect(x: 6, y: 4, width: size.width - 6, height: size.height - 6))
            midCard.backgroundColor = .systemGray3
            midCard.layer.cornerRadius = 10
            midCard.transform = CGAffineTransform(rotationAngle: -0.06)
            container.addSubview(midCard)
        }

        let frontImageView = UIImageView(frame: CGRect(x: 4, y: 8, width: size.width - 4, height: size.height - 4))
        frontImageView.image = primaryImage
        frontImageView.backgroundColor = .secondarySystemBackground
        frontImageView.contentMode = .scaleAspectFill
        frontImageView.clipsToBounds = true
        frontImageView.layer.cornerRadius = 10
        frontImageView.layer.borderColor = UIColor.white.cgColor
        frontImageView.layer.borderWidth = 2
        container.addSubview(frontImageView)

        if count > 1 {
            let badge = UILabel()
            badge.text = "\(count)"
            badge.font = .monospacedDigitSystemFont(ofSize: 13, weight: .bold)
            badge.textColor = .white
            badge.backgroundColor = .systemBlue
            badge.textAlignment = .center
            badge.clipsToBounds = true
            let textWidth = max(24, badge.intrinsicContentSize.width + 12)
            badge.frame = CGRect(x: container.bounds.width - textWidth, y: 0, width: textWidth, height: 24)
            badge.layer.cornerRadius = 12
            badge.layer.borderColor = UIColor.white.cgColor
            badge.layer.borderWidth = 1.5
            container.addSubview(badge)
        }

        return container
    }
}
