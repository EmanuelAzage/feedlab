import UIKit

/// Builds the app's root view controller.
///
/// A manifest that fails validation produces a visible error screen rather than a crash or
/// an empty feed. `docs/product-spec.md`: "Degradation is visible, not hidden" — a rig that
/// silently shows nothing when its corpus is broken will waste a measurement session.
enum RootFactory {
    /// `@MainActor` because it builds view controllers, which are main-actor isolated.
    /// Manifest loading is synchronous file I/O of a few kilobytes at launch; when the
    /// manifest becomes user-selectable in the debug menu this moves off the main actor.
    @MainActor
    static func makeFeedViewController() -> UIViewController {
        do {
            let manifest = try ManifestLoader().load(resource: Self.manifestResource, in: .main)
            return FeedViewController(manifest: manifest)
        } catch {
            Log.content.error("Manifest failed validation: \(error.localizedDescription, privacy: .public)")
            return ManifestErrorViewController(message: error.localizedDescription)
        }
    }

    /// `-manifest <name>` selects the corpus, defaulting to the full one.
    ///
    /// The measurement corpus is `hls-only`: preload depth, buffer caps and the bitrate ladder are
    /// only meaningful levers on adaptive streams (`docs/decisions.md`), and 7 of the 22 items in
    /// `short-form` are HLS — too few for a per-run percentile, while the progressive remainder
    /// contributes a 27% never-reaches-playback rate that moves p90 startup more than any strategy
    /// does. Selecting the corpus at launch keeps the app's default the full, honest feed.
    private static var manifestResource: String {
        #if FEEDLAB_TOOLS
        guard let name = UserDefaults.standard.string(forKey: "manifest"), !name.isEmpty else {
            return "short-form"
        }
        Log.content.info("Manifest from launch argument: \(name, privacy: .public)")
        return name
        #else
        return "short-form"
        #endif
    }
}

/// Terminal state for an unloadable manifest.
final class ManifestErrorViewController: UIViewController {
    private let message: String

    init(message: String) {
        self.message = message
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ManifestErrorViewController is created programmatically; no storyboard support.")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        let titleLabel = UILabel()
        titleLabel.text = "Manifest failed validation"
        titleLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 0

        let detailLabel = UILabel()
        detailLabel.text = message
        detailLabel.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        detailLabel.textColor = UIColor.white.withAlphaComponent(0.7)
        detailLabel.textAlignment = .center
        detailLabel.numberOfLines = 0

        let stack = UIStackView(arrangedSubviews: [titleLabel, detailLabel])
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24)
        ])
    }
}
