import UIKit

final class DaySectionHeaderView: UICollectionReusableView {
    static let reuseIdentifier = "DaySectionHeaderView"

    private let titleLabel = UILabel()
    private let countLabel = UILabel()
    private let selectDayButton = UIButton(type: .system)
    private var onToggleDay: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupViews() {
        backgroundColor = UIColor.systemBackground.withAlphaComponent(0.92)

        titleLabel.font = .preferredFont(forTextStyle: .subheadline).withWeight(.semibold)
        titleLabel.textColor = .label
        titleLabel.adjustsFontForContentSizeCategory = true

        countLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        countLabel.textColor = .secondaryLabel

        let leftStack = UIStackView(arrangedSubviews: [titleLabel, countLabel])
        leftStack.axis = .horizontal
        leftStack.alignment = .firstBaseline
        leftStack.spacing = 6
        leftStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(leftStack)

        selectDayButton.titleLabel?.font = .preferredFont(forTextStyle: .subheadline).withWeight(.medium)
        selectDayButton.translatesAutoresizingMaskIntoConstraints = false
        selectDayButton.addTarget(self, action: #selector(didTapSelectDay), for: .touchUpInside)
        addSubview(selectDayButton)

        NSLayoutConstraint.activate([
            leftStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            leftStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            leftStack.trailingAnchor.constraint(lessThanOrEqualTo: selectDayButton.leadingAnchor, constant: -8),

            selectDayButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            selectDayButton.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    func configure(
        title: String,
        count: Int,
        isFullySelected: Bool,
        onToggleDay: @escaping () -> Void
    ) {
        titleLabel.text = title
        countLabel.text = "\(count)"
        selectDayButton.setTitle(isFullySelected ? "Deselect Day" : "Select Day", for: .normal)
        self.onToggleDay = onToggleDay
    }

    @objc private func didTapSelectDay() {
        onToggleDay?()
    }
}

private extension UIFont {
    func withWeight(_ weight: UIFont.Weight) -> UIFont {
        let descriptor = fontDescriptor.addingAttributes([
            .traits: [UIFontDescriptor.TraitKey.weight: weight]
        ])
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}
