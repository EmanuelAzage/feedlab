import Foundation

/// A named, ordered set of feed items.
///
/// Manifests are keyed by measurement scenario (`short-form`, `long-form`, `mixed`) so
/// the debug menu can switch corpora between runs. Item **order is significant**: the
/// run protocol in `docs/testing.md` requires the same manifest and the same item order
/// across every arm, or the comparison is not like-for-like.
struct Manifest: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let items: [FeedItem]

    /// Items whose metrics can legitimately include ABR behaviour.
    var hlsItems: [FeedItem] {
        items.filter { $0.streamFormat == .hls }
    }
}
