import AVFoundation
import UIKit

/// A full-screen feed page.
///
/// The `AVPlayerLayer` is **persistent and owned by the cell**; players are borrowed from the
/// pool and come and go. That asymmetry is the point: the layer recycles with the cell on
/// scroll geometry, the player recycles on playback intent, and the two schedules differ.
///
/// Deliberately not `AVPlayerViewController` — see `docs/decisions.md`. Owning the layer is
/// what keeps attachment timing and first-frame behaviour observable.
final class FeedCell: UICollectionViewCell, PlayerRenderTarget {
    private let placeholderView = UIView()
    private let playerLayer = AVPlayerLayer()
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
        // Both are plain CALayers, outside Auto Layout, so they are sized here.
        // No implicit animation: the layer must be correct on the frame it first appears,
        // and an animated resize would show the video sliding into place.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        scrimLayer.frame = CGRect(
            x: 0,
            y: bounds.height - Layout.scrimHeight,
            width: bounds.width,
            height: Layout.scrimHeight
        )
        CATransaction.commit()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        titleLabel.text = nil
        attributionLabel.text = nil
        formatBadge.text = nil
        placeholderView.backgroundColor = .black
        // A recycled cell must never keep the previous item's player: the collection view can
        // reuse this cell for a different index before the coordinator has torn the old
        // attachment down, and the leftover layer would show one video inside another's cell.
        attachPlayer(nil)
    }

    // MARK: - PlayerRenderTarget

    func attachPlayer(_ player: (any PlayerProviding)?) {
        // The downcast is confined here. Only the AVFoundation adapter can render; fakes
        // resolve to nil, which lets the coordinator be exercised without a real player.
        playerLayer.player = (player as? AVPlayerAdapter)?.player
    }

    /// `true` once the layer has a frame to show — the `t1` endpoint for time-to-first-frame.
    var isReadyForDisplay: Bool {
        playerLayer.isReadyForDisplay
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

        // Above the placeholder so video covers it once frames arrive, below the scrim so the
        // title stays legible over bright footage.
        //
        // `.resizeAspect`, not `.resizeAspectFill`. A real short-form feed carries 9:16 content
        // and fills; our corpus is landscape 16:9 test streams, which aspect-fill crops so
        // aggressively that most of the frame is off-screen — including BipBop's clock, the
        // thing that makes it obvious at a glance which item is playing and whether it is
        // actually advancing. Legibility of the subject under test wins over feed cosmetics.
        playerLayer.videoGravity = .resizeAspect
        contentView.layer.addSublayer(playerLayer)

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
