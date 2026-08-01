import UIKit

/// Stable background colours for cells that have no poster image.
///
/// FeedLab ships no artwork and the manifest carries no thumbnails, so each cell needs a
/// distinguishable placeholder — distinguishable being the point: during a paging-smoothness
/// check, identical cells make it impossible to see whether the feed actually moved.
enum PlaceholderPalette {
    /// Deliberately **not** `id.hashValue`. Swift seeds `Hasher` per process, so hash-derived
    /// colours would differ on every launch — which would make before/after screenshots of the
    /// same manifest disagree for no real reason. FNV-1a is stable across launches and platforms.
    static func color(for id: String) -> UIColor {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in id.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        let hue = CGFloat(hash % 360) / 360
        return UIColor(hue: hue, saturation: 0.5, brightness: 0.38, alpha: 1)
    }
}
