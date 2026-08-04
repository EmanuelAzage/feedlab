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
    private(set) var coordinator: FeedCoordinator?

    #if FEEDLAB_TOOLS
    let toolsSettings = ToolsSettings()
    private(set) var hudController: HUDController?
    #endif

    /// Resolves an index to its visible cell, or nil when it is not on screen.
    func collectionViewCell(at index: Int) -> FeedCell? {
        collectionView.cellForItem(at: IndexPath(item: index, section: 0)) as? FeedCell
    }

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
        installPlaybackGestures()
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
        let arm = self.arm
        let recorder = SessionRecorder(arm: arm.name)
        coordinator = FeedCoordinator(
            manifest: manifest,
            arm: arm,
            pool: PlayerPool(capacity: arm.poolCapacity),
            recorder: recorder
        ) { [weak self] index in
            self?.collectionView.cellForItem(at: IndexPath(item: index, section: 0)) as? FeedCell
        }
        coordinator?.onProgress = { [weak self] index, elapsed, duration in
            self?.collectionViewCell(at: index)?.setProgress(elapsed: elapsed, duration: duration)
        }
        #if FEEDLAB_TOOLS
        if let coordinator {
            hudController = HUDController(coordinator: coordinator, host: view)
        }
        #endif
    }

    /// The experimental condition. Strategy *and* pool capacity both come from here, which is what
    /// makes an arm a single choice rather than two settings that could drift apart.
    ///
    /// Starts at the control, so a launch with nothing selected measures the same thing the engine
    /// did before arms existed. Selection from the debug menu arrives in the next change.
    private(set) var arm: Arm = ArmRegistry.control

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
