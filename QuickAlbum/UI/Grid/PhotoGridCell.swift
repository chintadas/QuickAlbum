import Photos
import UIKit

final class PhotoGridCell: UICollectionViewCell {
    static let reuseIdentifier = "PhotoGridCell"

    private let imageView = UIImageView()
    private let dimOverlayView = UIView()
    private let badgeContainer = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterialDark))
    private let badgeIconView = UIImageView()
    private let badgeCountLabel = UILabel()
    private let quickLookButton = UIButton(type: .system)
    private let checkmarkImageView = UIImageView()

    private var currentRequestID: PHImageRequestID = PHInvalidImageRequestID
    private weak var imageManager: PHImageManager?
    private var representedAssetID: String?
    private var onQuickLook: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        if currentRequestID != PHInvalidImageRequestID {
            imageManager?.cancelImageRequest(currentRequestID)
            currentRequestID = PHInvalidImageRequestID
        }
        representedAssetID = nil
        imageView.image = nil
        dimOverlayView.isHidden = true
        badgeContainer.isHidden = true
        checkmarkImageView.isHidden = true
        contentView.layer.borderWidth = 0
        onQuickLook = nil
    }

    private func setupViews() {
        contentView.backgroundColor = .secondarySystemBackground
        contentView.clipsToBounds = true
        contentView.layer.cornerRadius = 3

        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(imageView)

        dimOverlayView.backgroundColor = UIColor.black.withAlphaComponent(0.28)
        dimOverlayView.isUserInteractionEnabled = false
        dimOverlayView.isHidden = true
        dimOverlayView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(dimOverlayView)

        // Top-left album membership badge pill
        badgeContainer.clipsToBounds = true
        badgeContainer.layer.cornerRadius = 9
        badgeContainer.isUserInteractionEnabled = false
        badgeContainer.isHidden = true
        badgeContainer.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(badgeContainer)

        let stack = UIStackView(arrangedSubviews: [badgeIconView, badgeCountLabel])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false
        badgeContainer.contentView.addSubview(stack)

        let iconConfig = UIImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        badgeIconView.image = UIImage(systemName: "rectangle.stack.fill", withConfiguration: iconConfig)
        badgeIconView.tintColor = .white

        badgeCountLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .bold)
        badgeCountLabel.textColor = .white

        // Top-right quick-look preview button
        var buttonConfig = UIButton.Configuration.filled()
        buttonConfig.baseBackgroundColor = UIColor.black.withAlphaComponent(0.45)
        buttonConfig.baseForegroundColor = .white
        buttonConfig.cornerStyle = .capsule
        buttonConfig.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4)
        let expandSymbol = UIImage.SymbolConfiguration(pointSize: 9, weight: .bold)
        buttonConfig.image = UIImage(systemName: "arrow.up.left.and.arrow.down.right", withConfiguration: expandSymbol)
        quickLookButton.configuration = buttonConfig
        quickLookButton.translatesAutoresizingMaskIntoConstraints = false
        quickLookButton.addTarget(self, action: #selector(didTapQuickLook), for: .touchUpInside)
        contentView.addSubview(quickLookButton)

        // Bottom-right selection checkmark
        let checkConfig = UIImage.SymbolConfiguration(pointSize: 22, weight: .semibold)
            .applying(UIImage.SymbolConfiguration(paletteColors: [.white, .systemBlue]))
        checkmarkImageView.image = UIImage(systemName: "checkmark.circle.fill", withConfiguration: checkConfig)
        checkmarkImageView.isUserInteractionEnabled = false
        checkmarkImageView.isHidden = true
        checkmarkImageView.layer.shadowColor = UIColor.black.cgColor
        checkmarkImageView.layer.shadowOpacity = 0.25
        checkmarkImageView.layer.shadowRadius = 2
        checkmarkImageView.layer.shadowOffset = CGSize(width: 0, height: 1)
        checkmarkImageView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(checkmarkImageView)

        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: contentView.topAnchor),
            imageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            imageView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            dimOverlayView.topAnchor.constraint(equalTo: contentView.topAnchor),
            dimOverlayView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            dimOverlayView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            dimOverlayView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            badgeContainer.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 5),
            badgeContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 5),
            stack.topAnchor.constraint(equalTo: badgeContainer.contentView.topAnchor, constant: 2.5),
            stack.bottomAnchor.constraint(equalTo: badgeContainer.contentView.bottomAnchor, constant: -2.5),
            stack.leadingAnchor.constraint(equalTo: badgeContainer.contentView.leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: badgeContainer.contentView.trailingAnchor, constant: -6),

            quickLookButton.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 5),
            quickLookButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -5),
            quickLookButton.widthAnchor.constraint(equalToConstant: 22),
            quickLookButton.heightAnchor.constraint(equalToConstant: 22),

            checkmarkImageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -5),
            checkmarkImageView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -5)
        ])
    }

    func configure(
        assetID: String,
        asset: PHAsset?,
        countedAlbumCount: Int,
        isSelected: Bool,
        accessibilityDateText: String,
        imageManager: PHCachingImageManager,
        targetPixelSize: CGSize,
        onQuickLook: @escaping () -> Void
    ) {
        self.onQuickLook = onQuickLook
        self.imageManager = imageManager

        updateVisualState(
            countedAlbumCount: countedAlbumCount,
            isSelected: isSelected,
            accessibilityDateText: accessibilityDateText
        )

        guard representedAssetID != assetID else { return }
        representedAssetID = assetID

        if currentRequestID != PHInvalidImageRequestID {
            imageManager.cancelImageRequest(currentRequestID)
            currentRequestID = PHInvalidImageRequestID
        }

        imageView.image = nil
        guard let asset else { return }

        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true

        currentRequestID = imageManager.requestImage(
            for: asset,
            targetSize: targetPixelSize,
            contentMode: .aspectFill,
            options: options
        ) { [weak self] image, _ in
            guard let self, self.representedAssetID == assetID, let image else { return }
            self.imageView.image = image
        }
    }

    func updateVisualState(
        countedAlbumCount: Int,
        isSelected: Bool,
        accessibilityDateText: String
    ) {
        let isAssigned = countedAlbumCount >= 1
        dimOverlayView.isHidden = !isAssigned
        badgeContainer.isHidden = !isAssigned
        badgeCountLabel.text = "\(countedAlbumCount)"

        checkmarkImageView.isHidden = !isSelected
        contentView.layer.borderWidth = isSelected ? 2.5 : 0
        contentView.layer.borderColor = isSelected ? UIColor.systemBlue.cgColor : nil

        isAccessibilityElement = true
        accessibilityTraits = isSelected ? [.button, .selected] : [.button]
        let albumText = isAssigned
            ? "in \(countedAlbumCount) \(countedAlbumCount == 1 ? "album" : "albums")"
            : "not in any album"
        let selectedText = isSelected ? ", selected" : ""
        accessibilityLabel = "Photo, \(accessibilityDateText), \(albumText)\(selectedText)"
        accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: "Preview Photo") { [weak self] _ in
                self?.onQuickLook?()
                return true
            }
        ]
    }

    var currentThumbnailImage: UIImage? {
        imageView.image
    }

    @objc private func didTapQuickLook() {
        onQuickLook?()
    }
}
