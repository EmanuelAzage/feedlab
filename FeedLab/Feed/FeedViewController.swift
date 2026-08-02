import UIKit

/// The paging feed surface.
///
/// M1 scope: paging and cell binding only — no playback. What matters here is that page
/// geometry is exactly the collection view's bounds, because in M2 "which item is current"
/// becomes the trigger for acquiring a player, and an off-by-a-few-points page boundary
/// would make playback intent fire at the wrong moment and corrupt time-to-first-frame.
final class FeedViewController: UIViewController {
    /// Reported when the settled page changes. In M2 the feed coordinator subscribes to this
    /// to drive playback intent; keeping it a closure avoids inventing a coordinator protocol
    /// before there is a second surface to justify one.
    var onCurrentIndexChanged: ((Int) -> Void)?

    private(set) var currentIndex: Int = 0 {
        didSet {
            guard currentIndex != oldValue else { return }
            Log.feed.debug("Current index → \(self.currentIndex, privacy: .public)")
            onCurrentIndexChanged?(currentIndex)
        }
    }

    let manifest: Manifest
    private lazy var collectionView = UICollectionView(
        frame: .zero,
        collectionViewLayout: Self.makeLayout()
    )
    private var dataSource: UICollectionViewDiffableDataSource<Section, FeedItem>?
    private var coordinator: FeedCoordinator?

    init(manifest: Manifest) {
        self.manifest = manifest
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("FeedViewController is created programmatically; no storyboard support.")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        configureCollectionView()
        applySnapshot()
        configureCoordinator()
        #if FEEDLAB_TOOLS
        installDebugAffordance()
        #endif
        Log.feed.info(
            "Feed loaded manifest '\(self.manifest.id, privacy: .public)' with \(self.manifest.items.count) items"
        )
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        #if FEEDLAB_TOOLS
        becomeFirstResponder()
        #endif
        // The first item never "settles" — it is current from the moment the feed appears.
        coordinator?.settled(on: currentIndex)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // Hand every player back rather than holding decode resources off-screen.
        coordinator?.teardownAll()
    }

    #if FEEDLAB_TOOLS
    // Motion events are delivered to the first responder, so the feed has to claim it.
    // `motionEnded` cannot live in the debug extension: Swift does not allow overriding
    // an inherited method from an extension.
    override var canBecomeFirstResponder: Bool { true }

    override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        guard motion == .motionShake else { return }
        presentDebugMenu()
    }
    #endif

    private func configureCoordinator() {
        let recorder = SessionRecorder(arm: Self.defaultArm)
        coordinator = FeedCoordinator(
            manifest: manifest,
            pool: PlayerPool(capacity: .bounded(Self.poolCapacity)),
            recorder: recorder
        ) { [weak self] index in
            self?.collectionView.cellForItem(at: IndexPath(item: index, section: 0)) as? FeedCell
        }
    }

    /// Until `ArmRegistry` exists (M5) every session is the control arm, which is what the current
    /// behaviour actually is: current item only, no preload.
    private static let defaultArm = "baseline"

    /// Default from `docs/playback-engine.md`: current, next, previous. Becomes an experiment
    /// variable once `ArmRegistry` exists (M5).
    private static let poolCapacity = 3

    // MARK: - Layout

    private static func makeLayout() -> UICollectionViewCompositionalLayout {
        let fullPage = NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1),
            heightDimension: .fractionalHeight(1)
        )
        let item = NSCollectionLayoutItem(layoutSize: fullPage)
        let group = NSCollectionLayoutGroup.vertical(layoutSize: fullPage, subitems: [item])
        let section = NSCollectionLayoutSection(group: group)

        let configuration = UICollectionViewCompositionalLayoutConfiguration()
        configuration.scrollDirection = .vertical
        return UICollectionViewCompositionalLayout(section: section, configuration: configuration)
    }

    private func configureCollectionView() {
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.backgroundColor = .black
        collectionView.isPagingEnabled = true
        collectionView.showsVerticalScrollIndicator = false
        collectionView.alwaysBounceVertical = true
        collectionView.delegate = self
        // Load-bearing, not cosmetic. `isPagingEnabled` steps by exactly `bounds.height`,
        // while `.fractionalHeight(1)` groups measure the container *minus adjusted insets*.
        // Leaving inset adjustment on makes those two heights differ by the safe-area amount,
        // so every page drifts a little further off until cells straddle the screen.
        collectionView.contentInsetAdjustmentBehavior = .never

        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])

        let registration = UICollectionView.CellRegistration<FeedCell, FeedItem> { cell, _, item in
            cell.configure(with: item)
        }
        dataSource = UICollectionViewDiffableDataSource<Section, FeedItem>(
            collectionView: collectionView
        ) { collectionView, indexPath, item in
            collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: item)
        }
    }

    private func applySnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<Section, FeedItem>()
        snapshot.appendSections([.main])
        snapshot.appendItems(manifest.items, toSection: .main)
        dataSource?.apply(snapshot, animatingDifferences: false)
    }

    private enum Section {
        case main
    }
}

// MARK: - UICollectionViewDelegate

extension FeedViewController: UICollectionViewDelegate {
    /// Tracks the index continuously for display purposes only. **Playback intent is not
    /// driven from here** — see `settle()`.
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        let pageHeight = scrollView.bounds.height
        guard pageHeight > 0 else { return }
        let page = Int((scrollView.contentOffset.y / pageHeight).rounded())
        currentIndex = min(max(page, 0), max(manifest.items.count - 1, 0))
    }

    // A page can come to rest three different ways, and all three have to be treated as a
    // settle or playback silently fails to start for that item.
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        settle()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        guard !decelerate else { return }
        settle()
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        settle()
    }

    func collectionView(
        _ collectionView: UICollectionView,
        willDisplay cell: UICollectionViewCell,
        forItemAt indexPath: IndexPath
    ) {
        coordinator?.cellWillDisplay(at: indexPath.item)
    }

    func collectionView(
        _ collectionView: UICollectionView,
        didEndDisplaying cell: UICollectionViewCell,
        forItemAt indexPath: IndexPath
    ) {
        coordinator?.cellDidEndDisplaying(at: indexPath.item)
    }

    private func settle() {
        coordinator?.settled(on: currentIndex)
    }
}
