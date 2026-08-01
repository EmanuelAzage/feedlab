import UIKit

/// A full-screen feed page.
///
/// M1 renders a placeholder only. In M2 this cell gains a persistent `AVPlayerLayer` that
/// the pool attaches players to — persistent because the layer belongs to the *cell*, while
/// the player belongs to the *pool*, and the two recycle on different schedules.
final class FeedCell: UICollectionViewCell {
    private let placeholderView = UIView()
    private let scrimLayer = CAGradientLayer()
    private let titleLabel = UILabel()
    private let attributionLabel = UILabel()
    private let formatBadge = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureHierarchy()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("FeedCell is created programmatically; no storyboard support.")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // The scrim is a plain CALayer, so it is outside Auto Layout and must be resized here.
        scrimLayer.frame = CGRect(
            x: 0,
            y: bounds.height - Layout.scrimHeight,
            width: bounds.width,
            height: Layout.scrimHeight
        )
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        titleLabel.text = nil
        attributionLabel.text = nil
        formatBadge.text = nil
        placeholderView.backgroundColor = .black
    }

    func configure(with item: FeedItem) {
        placeholderView.backgroundColor = PlaceholderPalette.color(for: item.id)
        titleLabel.text = item.title
        attributionLabel.text = item.source.attribution
        // Surfaced in the UI because it changes which metrics are valid for this item:
        // a progressive file has no ladder, so bitrate-switch counts stay at zero by nature
        // rather than by merit.
        formatBadge.text = item.streamFormat == .hls ? "HLS" : "PROGRESSIVE"
    }

    // MARK: - Setup

    private func configureHierarchy() {
        contentView.backgroundColor = .black

        placeholderView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(placeholderView)

        scrimLayer.colors = [UIColor.clear.cgColor, UIColor.black.withAlphaComponent(0.75).cgColor]
        contentView.layer.addSublayer(scrimLayer)

        titleLabel.font = .systemFont(ofSize: 24, weight: .bold)
        titleLabel.textColor = .white
        titleLabel.numberOfLines = 2

        attributionLabel.font = .systemFont(ofSize: 13, weight: .regular)
        attributionLabel.textColor = UIColor.white.withAlphaComponent(0.7)
        attributionLabel.numberOfLines = 2

        formatBadge.font = .monospacedSystemFont(ofSize: 11, weight: .semibold)
        formatBadge.textColor = UIColor.white.withAlphaComponent(0.85)

        let stack = UIStackView(arrangedSubviews: [formatBadge, titleLabel, attributionLabel])
        stack.axis = .vertical
        stack.spacing = Layout.stackSpacing
        stack.setCustomSpacing(Layout.badgeSpacing, after: formatBadge)
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        let safeArea = contentView.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            placeholderView.topAnchor.constraint(equalTo: contentView.topAnchor),
            placeholderView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            placeholderView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            placeholderView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),

            stack.leadingAnchor.constraint(equalTo: safeArea.leadingAnchor, constant: Layout.margin),
            stack.trailingAnchor.constraint(equalTo: safeArea.trailingAnchor, constant: -Layout.margin),
            stack.bottomAnchor.constraint(equalTo: safeArea.bottomAnchor, constant: -Layout.margin)
        ])
    }

    private enum Layout {
        static let margin: CGFloat = 20
        static let stackSpacing: CGFloat = 6
        static let badgeSpacing: CGFloat = 10
        static let scrimHeight: CGFloat = 220
    }
}
