import UIKit

/// Playback gestures from `docs/product-spec.md`: tap toggles play/pause, double-tap seeks to
/// start, long-press shows the item's source and licensing.
///
/// The tap is not merely a convenience — it is what emits `.userPaused`/`.userResumed`, and
/// `qoe-metrics.md` requires those to exclude deliberate pauses from **both** the numerator and the
/// denominator of rebuffer ratio. Without them a user who pauses for a minute would read as a
/// minute of flawless playback, diluting every ratio in the session.
extension FeedViewController {
    func installPlaybackGestures() {
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap))
        doubleTap.numberOfTapsRequired = 2
        doubleTap.delegate = self

        let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap))
        singleTap.numberOfTapsRequired = 1
        singleTap.delegate = self
        // Otherwise the first tap of a double-tap toggles pause before the second arrives.
        singleTap.require(toFail: doubleTap)

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress))
        longPress.delegate = self

        for recognizer in [doubleTap, singleTap, longPress] {
            // The collection view's pan must keep winning; these only fire when the finger does
            // not travel, so scrolling is unaffected.
            recognizer.cancelsTouchesInView = false
            view.addGestureRecognizer(recognizer)
        }
    }

    @objc
    private func handleSingleTap() {
        guard let coordinator else { return }
        let isPaused = coordinator.toggleUserPause()
        currentCell?.setPaused(isPaused)
    }

    @objc
    private func handleDoubleTap() {
        coordinator?.seekCurrentItemToStart()
        currentCell?.setPaused(false)
    }

    @objc
    private func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began, let item = coordinator?.currentItem else { return }
        presentSourceInfo(for: item)
    }

    /// The attribution surface `docs/content-sources.md` requires alongside the Credits screen.
    private func presentSourceInfo(for item: FeedItem) {
        let details = """
        \(item.source.name)
        \(item.source.license)

        \(item.source.attribution)

        \(item.streamFormat == .hls ? "HLS (adaptive)" : "Progressive")
        \(item.url.host() ?? item.url.absoluteString)
        """

        let alert = UIAlertController(title: item.title, message: details, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Done", style: .cancel))
        present(alert, animated: true)
    }

    private var currentCell: FeedCell? {
        collectionViewCell(at: currentIndex)
    }
}

// MARK: - UIGestureRecognizerDelegate

extension FeedViewController: UIGestureRecognizerDelegate {
    public func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldReceive touch: UITouch
    ) -> Bool {
        // Never swallow taps meant for a control — the debug-menu button sits on this same view.
        !(touch.view is UIControl)
    }
}
