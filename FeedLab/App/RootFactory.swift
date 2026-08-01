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
            let manifest = try ManifestLoader().load(resource: "short-form", in: .main)
            return FeedViewController(manifest: manifest)
        } catch {
            Log.content.error("Manifest failed validation: \(error.localizedDescription, privacy: .public)")
            return ManifestErrorViewController(message: error.localizedDescription)
        }
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
