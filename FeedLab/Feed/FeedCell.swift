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
    private let pauseIndicator = UIImageView()
    private let timeLabel = UILabel()
    private let progressTrack = UIView()
    /// A plain layer rather than a constrained subview: this is updated 4×/s, and a layout pass at
    /// that cadence is avoidable work in a rig whose scroll smoothness is a measured output.
    private let progressFill = CALayer()
    private var progressFraction: Double = 0

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
        layoutProgressFill()
        CATransaction.commit()
    }

    private func layoutProgressFill() {
        progressFill.frame = CGRect(
            x: 0,
            y: 0,
            width: progressTrack.bounds.width * progressFraction,
            height: progressTrack.bounds.height
        )
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        titleLabel.text = nil
        attributionLabel.text = nil
        formatBadge.text = nil
        placeholderView.backgroundColor = .black
        setPaused(false)
        setProgress(elapsed: 0, duration: nil)
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

    /// The layer whose `isReadyForDisplay` marks the first rendered frame.
    var readinessLayer: AVPlayerLayer? {
        playerLayer
    }

    /// Shows a paused affordance. Without it a tap that stops playback is indistinguishable from
    /// the video having frozen — which in a rig about stalls is exactly the wrong ambiguity.
    func setPaused(_ isPaused: Bool) {
        pauseIndicator.isHidden = !isPaused
    }

    /// Elapsed / duration and the progress bar.
    ///
    /// Deliberately read-only: `product-spec.md` calls for a scrubber that is "minimal and
    /// non-blocking", and this "isn't a player UI showcase". A draggable scrubber would also let
    /// the operator seek mid-run, which the run protocol has no way to account for.
    func setProgress(elapsed: TimeInterval, duration: TimeInterval?) {
        if let duration, duration > 0, duration.isFinite {
            timeLabel.text = "\(Self.formatted(elapsed)) / \(Self.formatted(duration))"
            progressFraction = min(max(elapsed / duration, 0), 1)
        } else {
            // Live or not yet known. Show elapsed alone rather than a bar that means nothing.
            timeLabel.text = Self.formatted(elapsed)
            progressFraction = 0
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layoutProgressFill()
        CATransaction.commit()
    }

    private static func formatted(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--:--" }
        let total = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
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

    private func configureTextStyles() {
        titleLabel.font = .systemFont(ofSize: 24, weight: .bold)
        titleLabel.textColor = .white
        titleLabel.numberOfLines = 2

        attributionLabel.font = .systemFont(ofSize: 13, weight: .regular)
        attributionLabel.textColor = UIColor.white.withAlphaComponent(0.7)
        attributionLabel.numberOfLines = 2

        formatBadge.font = .monospacedSystemFont(ofSize: 11, weight: .semibold)
        formatBadge.textColor = UIColor.white.withAlphaComponent(0.85)

        // Monospaced digits so the numbers do not jitter as they tick — the same rule the HUD
        // follows (`docs/observability.md`).
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        timeLabel.textColor = UIColor.white.withAlphaComponent(0.6)
    }

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

        configureTextStyles()

        progressTrack.backgroundColor = UIColor.white.withAlphaComponent(0.2)
        progressTrack.translatesAutoresizingMaskIntoConstraints = false
        progressFill.backgroundColor = UIColor.white.withAlphaComponent(0.85).cgColor
        progressTrack.layer.addSublayer(progressFill)
        contentView.addSubview(progressTrack)

        pauseIndicator.image = UIImage(
            systemName: "play.fill",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 56, weight: .semibold)
        )
        pauseIndicator.tintColor = UIColor.white.withAlphaComponent(0.85)
        pauseIndicator.isHidden = true
        pauseIndicator.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(pauseIndicator)

        let stack = UIStackView(arrangedSubviews: [formatBadge, titleLabel, attributionLabel, timeLabel])
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

            pauseIndicator.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            pauseIndicator.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),

            progressTrack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            progressTrack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            progressTrack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            progressTrack.heightAnchor.constraint(equalToConstant: Layout.progressHeight),

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
        static let progressHeight: CGFloat = 2
    }
}
